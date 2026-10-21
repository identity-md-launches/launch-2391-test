# Test (TEST)

An immutable Uniswap v4 fee hook for the TEST/IMD launch on Robinhood Chain (chain ID **4663**), plus the launch's plain fixed-supply ERC-20. Logo: <https://www.si-md.xyz/logo.jpg>.

Only **TestToken** and **TestHook** are deployment contracts. Neither has an owner, admin, setter, upgrade mechanism, pause, blacklist, external mint function, or discretionary withdrawal. No vault, distributor, conversion market, or additional token is deployed by this project.

## Fixed launch terms

| Item | Value |
| --- | --- |
| Token | `Test`, `TEST`, 18 decimals |
| Supply | 1,000,000,000 TEST = `1000000000000000000000000000` units |
| IMD | `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127`, 18 decimals |
| SIMD Vault | `0xbBa92992309C61E1c483ab630d0530F2C9edEDE7` |
| CompensationVault | `0x9f4419712cc22f615e393cC846b927BE3d7D802c` |
| Pool LP fee | `12500` = 1.25%, static |
| Pool tick spacing | `60` |
| Standing hook fee | 0.75% of the gross IMD side |
| Buy anti-sniper duration | 1,800 seconds from the pool initialization timestamp |

The token constructor takes **no arguments** and mints its entire supply once to its deployer, the launch factory. The factory allocates 80% to liquidity, 10% to the swarm's MerkleDistributor, and **10% to the CompensationVault**. The hook never distributes or reserves supply. The factory derives the opening price from the launch policy's 2,500 IMD opening market cap and currency ordering; the hook does not assume a 1:1 price or a particular token address ordering. The 1:1 prices in integration tests are test fixtures.

The existing SIMD Vault is responsible for the weekly holder, Identity.md swarm job, developer, and marketing splits. The existing CompensationVault is responsible for migration claims, eligibility, and refunds. Their implementation and payout policies are outside this assignment. The hook only pays the specified addresses in **IMD**; it never exchanges IMD for ETH or calls either vault's application functions.

## Fee accounting

A buy inputs IMD and outputs TEST. A sell inputs TEST and outputs IMD, independent of address sorting or the router used. The hook ignores `hookData`; no caller can request an exemption or choose a recipient.

For elapsed seconds `t`, the total buy rate is:

```text
r(t) = 0.0075 + 0.4925 × max(1800 - t, 0) / 1800
```

| Elapsed time | Total buy hook fee | SIMD Vault | CompensationVault |
| --- | --- | --- | --- |
| 0 seconds | 50% | 0.75% | 49.25% |
| 900 seconds | 25.375% | 0.75% | 24.625% |
| 1,800 seconds onward | 0.75% | 0.75% | 0% |
| Any sell | 0.75% | 0.75% | 0% |

The exact rate is `feeNumerator(buy) / FEE_DENOMINATOR`; the denominator is `1,800,000,000`. Keeping the 1,800 factor avoids rounding the time curve to whole basis points or ppm. The timestamp is recorded once in `beforeInitialize`, including when deployment preceded initialization or the timestamp is zero. There is no reset.

Fees round down to the smallest IMD unit. The SIMD Vault receives `floor(grossIMD × 7500 / 1,000,000)`. Compensation receives the total rounded fee minus that standing portion, so the two portions exactly sum to the charged fee.

* **Exact-input buy:** the input budget includes the hook fee. The AMM receives the remainder.
* **Exact-output buy:** the AMM's required IMD input is grossed up to include the hook fee. The requested TEST output is preserved.
* **Exact-input sell:** the hook deducts its fee from actual gross IMD output.
* **Exact-output sell:** the AMM output is grossed up so the trader receives the requested net IMD when fully filled.

For gross-up, if the AMM input or requested net output is `a`, the fee is `floor(a × n / (D - n))`, where `n/D` is the current rate. Price-limited partial fills pay on **executed amounts**, with unused input staying with the trader. v4 can return partial exact-output fills; callers must check their desired output/slippage as usual. An empty-liquidity swap pays no fee.

The quoted **2%** is the sum of the 1.25% LP and 0.75% hook rates. Their bases follow v4 settlement: for a fully filled exact-input buy after 30 minutes, 100 IMD pays 0.75 IMD to the vault and 1.240625 IMD as the LP fee on the remaining 99.25 IMD, before rounding. Thus the combined deduction on that original input is **1.990625%**, not a separate flat 2% surcharge. Sells incur the LP fee on TEST input and the hook fee on IMD output. The hook never overrides the LP fee to manufacture an additive rate.

## v4 integration and payment resilience

The enabled callbacks are `beforeInitialize`, `beforeSwap`, and `afterSwap`, with both swap return-delta permissions. All other permissions are disabled. The low 14 address bits must equal **`0x20cc` (8396)**. `HookFlags` supplies the same constants for address mining. The constructor validates its address flags.

`beforeInitialize` permits only the constructor-supplied factory, through the constructor-supplied PoolManager, with the exact token, IMD, fee, tick spacing, and hook address. This prevents reuse for a different pool or starting the clock through a foreign pool. The factory has no authority after initialization. No liquidity callbacks run, so adding, removing, or collecting LP fees with zero liquidity change works normally.

When IMD is the specified currency, `beforeSwap` must calculate its fee before v4 executes the trade. It uses an internal, **rollback-only quote**: a self-only external helper calls the real PoolManager swap and always reverts with the actual IMD delta. The revert undoes the quote's price changes, accounting, fees, and events. v4 skips hooks on the hook's own nested swap. The subsequent real swap respects the original price limit. This extra simulation costs gas but prevents taxing unspent budgets and unfilled output requests. It does not replace the real AMM swap or return a delta that consumes the full input without a trade. When IMD is unspecified, `afterSwap` uses the actual swap delta directly.

The hook attempts `PoolManager.take(IMD, fixedRecipient, fee)` during the swap. If the manager has insufficient IMD before the router settles, or the IMD transfer to a recipient fails, the hook catches that failure and mints an IMD **ERC-6909 claim** to itself instead. `pendingVault` and `pendingCompensation` record the two fixed entitlements. A fresh manager seeded only with TEST therefore still accepts the first buy.

Anyone may call **`redeemFees()`** after the swap's unlock finishes. It opens its own manager unlock, burns pending claims, and sends IMD only to the original recipients. Failed redemptions restore the claim and pending amount; one recipient's failure does not block the other. Repeated calls cannot pay twice. No recipient address or amount is supplied by the caller. Per-call redemption is capped at the maximum positive `int128` per recipient to fit v4 deltas.

The hook has no intentional restriction on valid swaps in its initialized pool. Normal v4 errors, invalid price limits, insufficient trader funds, out-of-gas conditions, unsupported token behavior, and v4 integer bounds can still revert a transaction. Transfer rejection by a fee recipient, or insufficient manager IMD for fee delivery, is handled by the claim fallback. IMD itself must remain a standard ERC-20 without transfer taxes, rebases, or token-transfer callbacks that mutate pool state. A failure of the underlying token to transfer swap input/output cannot be repaired by a fee hook.

## Deployment parameters and responsibilities

`TestHook(IPoolManager manager_, address token_, address factory_)` takes exactly three address arguments:

| Argument | Launch manifest value | Responsibility |
| --- | --- | --- |
| `manager_` | `$poolManager` | Deployer supplies and verifies Robinhood's compatible v4 manager |
| `token_` | `$token` | Factory supplies its freshly deployed TestToken |
| `factory_` | `$factory` | Factory that deploys the hook and initializes the pool |

There is **no `$owner` argument**. No deployment-chain PoolManager address is hardcoded. The constructor makes no external calls and does not require deployed code at its arguments. It rejects zero arguments and using IMD itself as TEST.

The launch operator must use the pinned compiler/settings, mine CREATE2 against the actual factory address, creation bytecode and encoded arguments until the hook address matches `0x20cc`, and deploy and initialize atomically through that factory. Verify the chain ID, manager implementation, IMD behavior, fixed recipients, pool terms, and the policy-derived opening price before launch. Initialize before the first swap and preserve the original price limit when routing. The manifest is produced by the separate launch step; this repository intentionally does not supply `launch.json`, keys, or broadcast transactions.

After launch there are **no settings to apply**. Monitor `FeeAccrued`, `FeePaid`, `FeeDeferred`, and the pending balances. A permissionless keeper or either vault operator should call `redeemFees()` when fees are deferred. The caller pays gas and receives no reward. Weekly distributions and migration compensation remain the existing vault operators' responsibilities. Unsolicited transfers or claims sent to the hook have no administrative rescue path.

## Build and tests

Foundry is pinned to Solidity **0.8.26**, Cancun EVM, optimizer 200 runs, and `bytecode_hash = "none"`. Dependencies and licenses are vendored as ordinary files under `lib/`; see [DEPENDENCIES.md](DEPENDENCIES.md). There are no submodules, package downloads, environment reads in tests, FFI, or filesystem permissions. With the pinned compiler installed, the default build and tests work without network access.

```sh
forge build
forge test
forge fmt --check
```

The required fuzz seed is pinned in `foundry.toml`:

```text
0xcb8802c1378c88621b85eee40a357d15aaa363d0bf988b09883cc6602dba9541
```

The local suite uses a real, freshly deployed v4 PoolManager and a controllable IMD test token. It covers both currency orderings, four swap modes, fees and conservation, the initialization clock and curve boundaries, partial fills, fresh token-only liquidity, failed recipient transfers and redemption, callback access, immutable destinations, LP collection, and token launch allocations. Fuzz tests run 1,000 cases each. The handler invariant runs 128 sequences of 32 actions across swaps, time advancement, delivery failures, and redemptions, followed by recovery of all pending fees.

The fork suites run the same economic checks with the **real IMD contract state** on Robinhood and freshly deployed canonical v4 managers and TEST tokens. They do not substitute IMD code. Only test trader balances are funded with `deal`. Fork setup checks chain ID, deployed IMD code, symbol, and decimals. These suites explicitly skip when no fork is selected; a default offline pass is not presented as a fork pass.

```sh
forge test --match-contract 'Robinhood.*ForkTest' \
  --fork-url https://rpc.mainnet.chain.robinhood.com -vv
```

The final fork run passed **36 tests at block 94,383,299**. To reproduce that exact state, add `--fork-block-number 94383299` and use an archive-capable RPC. The public endpoint prunes historical state: it served an earlier run at 94,373,437, then returned `historical state ... is not available` on a later repeat. The command above selects current state instead. [VERIFICATION.md](VERIFICATION.md) records final results and the scoped security review. The fork rehearsal verifies real IMD interaction with the vendored v4 implementation; the final launch rehearsal must additionally verify the factory-selected deployed manager and factory transaction against current chain state.
