# Vendored dependencies

All listed files are ordinary repository files. No install step, git submodule, registry, or network connection is required to build them. Sources retain their upstream license notices. Unused upstream tests, package tooling, CI, and git metadata are not dependencies.

| Directory | Upstream | Immutable revision | Included content |
| --- | --- | --- | --- |
| `lib/v4-core` | https://github.com/Uniswap/v4-core | `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` | Production `src/`, excluding `src/test/`, and `licenses/` |
| `lib/forge-std` | https://github.com/foundry-rs/forge-std | `77041d2ce690e692d6e03cc812b57d1ddaa4d505` (v1.9.7) | `src/`, MIT and Apache licenses |
| `lib/openzeppelin-contracts` | https://github.com/OpenZeppelin/openzeppelin-contracts | `69c8def5f222ff96f2b5beff05dfba996368aa79` (v5.1.0) | `contracts/` and license |
| `lib/solmate` | https://github.com/transmissions11/solmate | `89365b880c4f3c786bdd453d4b8e8fe410344a69` | `src/auth/Owned.sol` and license, required by v4's local PoolManager |

The v4 revision exposes `SwapParams` and `ModifyLiquidityParams` through `src/types/PoolOperation.sol`, matching the protected checks. v4 core includes BUSL-1.1 and MIT licensed components; see its per-file notices and license texts. OpenZeppelin is MIT licensed, forge-std is MIT/Apache-2.0, and the included Solmate `Owned.sol` declares MIT. The launch hook and token use internal library functions only; their bytecode has no external library link placeholders. Forge-std, PoolManager deployment code, and Solmate's manager ownership are test dependencies, not ownership features of TestHook or TestToken.
