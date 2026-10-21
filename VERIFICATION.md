# Verification record

Completed on 2026-10-21 using Foundry 1.8.5 and the repository-pinned Solidity 0.8.26 compiler.

## Final checks

| Check | Result |
| --- | --- |
| `forge build` | Passed |
| `forge test -vv` | **55 passed, 0 failed, 2 skipped** |
| `forge fmt --check` | Passed |
| Robinhood fork suites, block **94,383,299** | **36 passed, 0 failed, 0 skipped** |
| Stateful invariant | **128 runs, 4,096 calls, 0 reverts**; recovery succeeds after every sequence |
| Fuzz cases per fuzz test | **1,000**, with the assignment's seed |
| TestHook runtime | **6,774 bytes**, below EIP-170 |
| TestToken runtime | **1,722 bytes**, below EIP-170 |
| External library link references | None in either deployment artifact |

All build/test commands used the default configuration. The required seed was also supplied explicitly on the final runs:

```text
FOUNDRY_FUZZ_SEED=0xcb8802c1378c88621b85eee40a357d15aaa363d0bf988b09883cc6602dba9541
```

The two default skips are the opt-in fork suites. They check `vm.activeFork()` without reading environment variables. The final fork command was:

```sh
forge test --match-contract 'Robinhood.*ForkTest' \
  --fork-url https://rpc.mainnet.chain.robinhood.com \
  --fork-block-number 94383299 -vv
```

Fork setup confirmed chain ID 4663 and the deployed IMD token's symbol and 18 decimals. Tests used real IMD bytecode/state, funding only the trader's balance with a cheatcode, and deployed canonical v4 PoolManagers locally on the fork. Both currency sort orders passed the same economic suite. This is not a claim that the unknown future factory-selected manager or factory transaction was exercised.

An earlier 32-test fork run passed at block 94,373,437. A later retry of that block failed with RPC error `-32000: historical state ... is not available`; the expanded final suite passed at the fresh block above. The public RPC's retention window is not sufficient for indefinite historical reproduction. Use an archive RPC for the recorded block, or omit the block argument to rehearse current state.

## Scoped security review

Reviewed the hook's reachable entry points, its v4 permissions, fee math, claim settlement, and the token's supply/transfer behavior against the supplied protected-check definitions and security references. The checks below describe concrete coverage; this is a contributor self-review, not an independent audit.

* **Authority:** each enabled hook callback and `unlockCallback` rejects non-manager callers. The constructor fixes the manager, token, and factory. Initialization checks the complete pool ID and factory, records time once, and cannot be reset. Wrong-factory initialization through a real manager fails. Deployment works without external code or constructor calls.
* **Immutability:** neither deployment ABI includes ownership, mint-after-deployment, settings, pause, blacklist, upgrade, or discretionary transfer functions. Common mutation selectors fail even from the factory. Arbitrary swap `hookData` cannot redirect fees. Runtime tests scan reachable opcodes, skipping PUSH data, and find no DELEGATECALL, CALLCODE, or SELFDESTRUCT.
* **Permissions:** the mined address and `getHookPermissions` agree on `0x20cc`. Return deltas are limited to the IMD fee. The real AMM executes the swap; no full-input NoOp/custom-fill branch exists. No liquidity callback can interfere with factory LP fee collection or withdrawals.
* **Accounting:** positive hook deltas charge the trader exactly what the hook takes or mints as claims. A failed external `take` rolls back its manager delta before the claim is minted. Redemption burns then takes, or burns then re-mints on failure, leaving zero net delta in either path. Every completed test swap checks both currencies' hook/router deltas and the manager's global nonzero-delta count. No TEST or IMD is retained as a direct hook balance.
* **Fee math:** all four swap modes and both currency orderings satisfy independent floor inequalities and IMD conservation. The buy curve is checked at 0, 900, 1799, 1800, and later times, plus fuzzed elapsed times. Sells pay no compensation portion. Exact-output fills preserve the specified net output when liquidity permits. Partial fills and empty pools do not pay fees on unexecuted amounts.
* **Quote rollback:** only the hook can enter its quote helper, which always reverts. The quoted nested swap skips self-hooks and has no ERC-20 transfer or lasting pool effect. Price-limited tests check the final real swap price and fee against the actual delivered delta. This depends on the standard fixed IMD token not reentering and altering pool state during fee transfers.
* **Delivery failures:** fresh TEST-only liquidity succeeds without preexisting manager IMD. Either or both fee recipients may reject transfers while valid swaps continue. Claims remain assigned to the correct recipients, can be retried by an arbitrary caller, and cannot be redeemed twice. Large partial-fill buys also exercise deferred delivery when the fee exceeds a seeded manager's current balance.
* **Stateful recovery:** random swaps, time changes, recipient failures, and redemptions preserve total IMD and the equality between pending entitlements and hook-owned claims within the handler's action model. Every sequence finishes by unblocking recipients and redeeming all pending fees. Unsolicited third-party claim gifts are outside that equality model and confer no withdrawal authority.
* **Failure atomicity:** invalid price limits and insufficient trader funds revert without paying fees or retaining claims. Initialization time starts at pool initialization rather than deployment. The token's launch allocations and contract-to-wallet flows move exact amounts without taxes, changing supply, or privileged balance control.

The constructor and callback paths were also reviewed for narrow casts and integer bounds. Fee deltas use v4 SafeCast; FullMath avoids multiplication overflow. The unchecked absolute-value helper handles the minimum signed integer. Native v4 limits still apply to gross fee-inclusive amounts. Rounding favors the trader by less than one IMD unit per fee calculation.

`forge build` reports lint warnings for the intended timestamp comparison, explicit numeric/selector casts, events emitted after manager calls, and the unused bytes payload of `unlock`. The timestamp is the requested clock, casts have bounded inputs or intentional selector extraction, events follow successful delivery/deferral, and `unlock` failures propagate normally; it returns an unused empty callback payload rather than a success flag. These are reviewed warnings, not a claim of a lint-clean build. Slither, Mythril, formal verification, and independent external audit were not run.

Operational limits, exact fee bases, deployment arguments, and permissionless redemption responsibilities are documented in [README.md](README.md). No production transaction was signed or broadcast.
