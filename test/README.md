This test contribution extends the existing TEST/IMD suite without changing the implementation, dependencies, or Foundry configuration. Tests use the vendored canonical Uniswap v4 PoolManager and deploy hooks at CREATE2 addresses with the required permission bits.

| Coverage added | What it checks |
| --- | --- |
| `HookAdversarial.t.sol` | Both currency orderings, all four swap modes, small-unit rounding, arbitrary hook data, zero-input atomicity, timestamp versus block-number timing, failed initialization rollback, and the minimum signed input budget with a price-limited partial fill. An identically seeded pool without a hook independently checks output, price, tick and LP fee growth, detecting lasting effects from the rollback quote. |
| `HookIsolation.t.sol` | Constructor rejection, every pool-key field, callbacks before initialization, unauthorized ERC-6909 claim transfer/burn, redemption inside an existing unlock, unsolicited claim gifts, two swaps in one unlock, mixed buy/sell net settlement, and complete rollback when the second swap fails. |
| `HookEntitlementInvariant.t.sol` | Independently computed cumulative entitlements for each vault, in both currency orderings. Random swaps, time advances, recipient failures, redemption and redirection attempts must preserve fees, claims, backing and both token balances. The oracle uses the executed PoolManager swap delta, not the hook's events or pending counters. |
| `TokenInvariant.t.sol` | Fixed supply and exact balance/allowance accounting across transfers, approvals, delegated spending, overdraw attempts and allowance failures among four participants. |
| `TestToken.t.sol` | The deployment fixture now uses a real factory helper. This removes a constructor-prank leak observed on Forge 1.8.0 while preserving the factory supply assertions. |

The new shared economic tests are inherited by the existing Robinhood fork suites as well as the local suites. A local IMD mock can reject individual recipients to exercise deferred claims and recovery. The fork suites use real IMD code and state, checking chain ID 4663, the IMD symbol and 18 decimals before testing; only trader funding is overridden. They deploy a fresh canonical PoolManager on the fork. They do not claim to exercise the eventual production launch factory or its manager, whose addresses are not supplied here.

The new invariants each use 256 sequences of 64 calls, set in the test sources. The existing invariant uses 128 sequences of 32 calls. All four ran without an unexpected handler revert: 53,248 total calls. Successful and rejected operations both contribute to the state model. Each hook sequence ends by unblocking recipients and verifying full delivery of both independently computed entitlements. The invariant model generates fee claims only; the separate unsolicited-gift test checks that an externally donated claim does not change either vault's fee entitlement.

Local validation used Forge 1.8.0 and Solidity 0.8.26 with the assignment seed:

| Final check | Result |
| --- | --- |
| Build | Passed |
| Default tests | 81 passed, 0 failed, 2 fork-suite setup skips |
| Robinhood fork, block 94,393,096 | 50 passed, 0 failed, 0 skipped |
| Stateful invariants | 53,248 calls, no unexpected handler reverts |
| Isolated defect proof | Reproduced the reported overflow; preserved in `.imd-findings.json` |

```sh
FOUNDRY_FUZZ_SEED=0xcb8802c1378c88621b85eee40a357d15aaa363d0bf988b09883cc6602dba9541 forge build
FOUNDRY_FUZZ_SEED=0xcb8802c1378c88621b85eee40a357d15aaa363d0bf988b09883cc6602dba9541 forge test
```

The default suite passes offline. Both fork suites explicitly skip if no fork is active; this is reported as skipped coverage. To exercise them:

```sh
FOUNDRY_FUZZ_SEED=0xcb8802c1378c88621b85eee40a357d15aaa363d0bf988b09883cc6602dba9541 \
  forge test --match-contract 'Robinhood.*ForkTest' \
  --fork-url https://rpc.mainnet.chain.robinhood.com \
  --fork-block-number 94393096 --no-storage-caching
```

No RPC credentials, environment mutations, new dependency installs, or network requests are required by the default suite. An RPC that retains the specified block is needed to repeat the pinned fork run. Historical-state availability is external to the tests.

One low-severity implementation defect is reported in the assignment's `.imd-findings.json`, with a full independent failing test. A price-limited exact-output sell with `amountSpecified = type(int256).max - 1e30` executes on canonical v4 but overflows in `TestHook.beforeSwap` while estimating the fee on the entire requested output. The executed amount and fee are small enough to fit all signed limits. The proof was run and failed with arithmetic panic `0x11`; it is carried in the findings report instead of asserting the rejected swap is correct in the passing suite.

The supplied contracts do not implement the external vault's weekly distribution or migration refund claims. The existing token allocation test models a factory's transfers, including the compensation tenth; it does not prove that an absent production factory makes that allocation automatically. The logo is off-chain metadata and is not exposed by these contracts. These tests cover the supplied token and hook, including IMD delivery and fixed destinations.
