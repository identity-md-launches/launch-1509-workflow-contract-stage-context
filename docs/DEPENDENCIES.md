# Vendored dependencies

The repository includes ordinary source files and licenses, with no package-manager or Git submodule dependency. No network is required to resolve Solidity imports.

| Package | Pinned release | Upstream archive | Archive SHA-256 |
| --- | --- | --- | --- |
| OpenZeppelin Contracts | `v5.0.2` | `https://codeload.github.com/OpenZeppelin/openzeppelin-contracts/tar.gz/refs/tags/v5.0.2` | `18c7b7e949b9a82dcd8cd394426c9c2636dfc263aa2317d4749dbfa0c7b3925a` |
| forge-std | `v1.9.7` | `https://codeload.github.com/foundry-rs/forge-std/tar.gz/refs/tags/v1.9.7` | `45157353ab49eab01d294565866731e599b32401757229689ee459aa26b7ee94` |

OpenZeppelin's unmodified transitive source subset for `ERC20`, `SafeERC20`, `Math`, and `ReentrancyGuard` is under `lib/openzeppelin-contracts/contracts/`, with the upstream MIT license. forge-std's complete `src/` is under `lib/forge-std/`, with its MIT and Apache licenses. It is used only by tests.

All production library functions are internal and inlined: no deployed or externally linked library is required. The Solidity compiler is a toolchain dependency, pinned by version in `foundry.toml`, not vendored as a binary.
