# Contract-stage handoff

This document supplies facts for the **separate** manifest and independent review assignments. It is not a manifest, deployment receipt, policy signature, admission, or claim of an independent audit.

## Manifest inputs

| Item | Value |
| --- | --- |
| Kind / chain | `evm_project`, Ethereum, `1` |
| Token source and Solidity name | `src/LaunchToken.sol`, `LaunchToken` |
| Token constructor arguments | None |
| Token display metadata | Name `PONZIRAMID`, symbol `PONZIRAM`, decimals `18` |
| Initial fixed supply | `1000000000000000000000000000`, all minted to deploying factory |
| Application source and Solidity name | `src/Ponziramid.sol`, `Ponziramid` |
| Application constructor fields, in declaration order | `address token_ = $token`, `address owner_ = $owner` |
| Top-level application count / dependency order | One: `Ponziramid`, after the launch token |
| Paired currency | Native ETH, encoded as the policy's zero Currency address |
| Fee / spacing | `12500` / `60` |
| Supplied initial-price field | `79228162514264337593543950336` |
| Policy's effective opening market cap | `10 ETH`; opening price derived by the deployer |
| Factory distribution | 10% swarm, 20% pool, 70% allocation wallet; no application allocation |

No constructor is payable or has a dynamic argument. There are no external linked libraries. The `Ponziramid` constructor creates `StoneVault` and `PonziRewards` using their compiled initcode; those constructors only validate/store addresses and initialize local state. There is no call to an existing token, registry, feed, factory, or other dependency, and no dependency code-length requirement. Empty-chain construction is covered by `DeploymentTest`.

Both children are fully configured and immutable. Their bound game is the newly created `Ponziramid` address; the reward token is the same `$token` passed to that game. The parent records their addresses in immutable getters and `CustodyCreated`. The service should verify all four source contracts but must **not** add separately deployed custody instances to the application's manifest list. Such instances would not be bound to the parent through its getters. The actual child constructor arguments for explorer verification are `StoneVault(game)` and `PonziRewards(token, game)`.

The only user-privileged constructor field is `owner_`, for Mortar fee credits and `setPaused`. Use `$owner`; do not substitute the factory, deployer, transaction origin, or a guessed wallet. The `game_` parameters in the custody contracts are contract authorization, bound internally by immutable construction; they do not give the owner a token/principal transfer path.

## Service responsibilities after source acceptance

1. Produce the complete canonical `launch.json` and independently review it together with the accepted source, including exact compiler settings, source names, constructor ordering, ownership, child creation, and distribution assumptions. Policy and signed-artifact linkage belong to the services; no fabricated linkage is supplied here.
2. Publish/attest/admit the accepted source and deploy through the authorized factory. Capture actual receipts and source-verification evidence for the token, game and both children. The token's deploy-time supply must still be entirely held by the factory before it applies its allocation.
3. Provide the actual allocation recipient, owner, block numbers, addresses, pool key, transaction hashes and ABI handoff. The protocol supplies the distributor, initialization guard, LP and trading-fee claims.
4. The allocation wallet makes a prior exact ERC-20 approval and one `PonziRewards.fund(entireCurrentBalance)` deposit. Verify the 700M threshold and resulting wallet balance, and publish the successful funding transaction hash. This cannot be simulated or completed by a contributor without the wallet and deployed contracts.
5. The subsequent frontend stage uses the verified addresses, live balances and indexed receipts to build/test/publish the requested mobile website, IPFS artifact and share image.

There is no deployment script that reads keys, no signed transaction, no fallback address, no backend signer, no owner-settable service dependency, and no additional initialization call to make. No transactions are required to keep Stone refundable. Finalization is permissionless and must be called by someone; it is constant-time and has no automatic keeper.

## Decisions requiring reviewer attention

- The initial 700M funding gate is **latched once**; later rounds need 1M uncommitted tokens rather than a perpetual 700M live balance. Otherwise the first legitimate reward payout would permanently prevent a second round.
- The launch token has the policy's billion-token fixed supply and plain transfers. It implements none of the game's fee, pause, or payout logic.
- A pre-expiry Stone withdrawal forfeits diamond-hands eligibility, but an at/after-expiry refund keeps the frozen eligibility even if finalization has not yet happened. No settlement is forced in the refund path.
- The last builder receives Pharaoh awards even if they withdrew their own Stone. Participation rewards are per distinct builder wallet, regardless of how many bricks it bought or withdrew.
- No-earlier-brick dividends, per-brick division dust, no-survivor diamond prizes, and Tomb split dust recycle into Tomb funding. Diamond division dust remains reserved until the last eligible brick settles; unclaimed player balances never expire.
- The owner can pause **only builds**, including near expiry, which can affect the last-builder outcome. This is an explicit trust/power assumption. The owner cannot refund themselves other users' principal, access permanent token funding, change economics, or replace dependencies.
- The game is based on confirmed ordering and timers, not randomness or identity. Multiple wallets and ordering can influence payouts. Gas/Mortar and token value are not guaranteed refundable.
- Forced ETH and unrelated accidentally transferred assets have no recovery mechanism. There are no emergency upgrades to immutable custody.

Local verification results and implementation review limits are recorded in [VALIDATION.md](VALIDATION.md). Independent review must assess application accounting and these choices, beyond the protected deployment/token floor.
