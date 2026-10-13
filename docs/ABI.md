# ABI and integration guide

Machine-readable ABIs:

- [LaunchToken.json](abi/LaunchToken.json)
- [Ponziramid.json](abi/Ponziramid.json)
- [StoneVault.json](abi/StoneVault.json)
- [PonziRewards.json](abi/PonziRewards.json)

Regenerate with `forge build && python3 scripts/export_abis.py`. Verify exports with `python3 scripts/export_abis.py --check`. These are JSON ABI arrays, including events, errors, constructors and public getters. All amounts are integers: **wei** for ETH and **18-decimal minor units** for PONZIRAM. Keep amounts as big integers; do not calculate transaction values with JavaScript floating-point numbers.

## Deployment discovery

Obtain the verified Ethereum token and game addresses from the service handoff. Read `game.vault()`, `game.rewards()`, `game.owner()`, `rewards.token()`, and both child `game()` getters and cross-check the immutable bindings. The children are created inside the game constructor, not deployed separately by the manifest. `CustodyCreated(vault, rewards)` provides their discovery event. Do not accept matching event signatures from unrelated contracts as proof of a deployment or funding.

The token's on-chain symbol is `PONZIRAM`. The pool key, distribution wallet, deployment block, and receipt links come from the deployment handoff. There are intentionally no invented address configurations in this source contribution.

## Transaction flows

| User action | Target and call | Requirements and effect |
| --- | --- | --- |
| Approve a permanent deposit | Token: `approve(rewards, amount)` | Exact amount; approval itself does not fund a round. |
| Fund PONZIRAM | Rewards: `fund(amount)` | Positive approved amount, pulled from caller. No withdrawal or cancellation. |
| Build | Game: `build(expectedRoundId, expectedPrice)`, ETH value `expectedPrice` | Quote both arguments immediately before signing. Exact value, live/unpaused round, cooldown, and non-consecutive builder required. First build reserves a funded round. |
| Withdraw Stone | **Vault**: `withdrawStone(brickId, recipient)` | Caller owns that unwithdrawn brick. Entire Stone only; works while paused, expired, or unfinalized. No rewards claim is required. |
| Claim brick ETH | Game: `claimBrickETH(brickId, recipient)` | Caller owns the brick. Pays pending dividends and any finalized diamond prize; leaves principal untouched. |
| Claim credited ETH | Game: `claimETH(recipient)` | Pays the caller's Pharaoh prize(s) and/or earned owner Mortar fees. |
| Claim PONZIRAM | Rewards: `claim(roundId, recipient)` | Finalized round, verified participant, not previously claimed. Pharaoh automatically includes participation plus the 300K bonus. |
| Finalize expired round | Game: `finalize()` | Anyone; `timestamp >= expiresAt`; not already finalized. No payment required. |
| Pause/unpause building | Game: `setPaused(bool)` | Immutable owner only. Time, refunds, claims and finalization continue. |

Claims and refunds accept a nonzero alternate recipient so a contract wallet with a rejecting receive function can still retrieve its funds. The brick owner/participant must initiate; the recipient does not acquire claim rights. An unsuccessful transfer reverts the transaction and preserves the original balance. Claim each brick independently; there is no unbounded “claim all” loop on-chain. A diamond claim of zero wei can succeed to settle rounding bookkeeping; an otherwise empty repeat claim reverts.

`reserveRound`, `recordParticipant`, `finalizeRound`, `deposit`, and `onStoneWithdrawal` are immutable internal-contract interfaces, **not** frontend transaction entry points. They reject callers other than the bound game/vault.

## Public reads

| Display / decision | Read |
| --- | --- |
| Exact purchase terms | `game.quote()` → `(roundId, price, stone, mortar)` |
| Current round and pause | `game.currentRound()`, `game.paused()` |
| Timer and last builder | `game.rounds(roundId)` → `startedAt`, `expiresAt`, `pharaoh`, `finalized` |
| Tomb and end-of-round accounting | Round fields `tomb`, `diamondPool`, `diamondRemaining`, `diamondClaimsRemaining`; `game.nextTomb()` |
| Brick and confirmed rendering order | `game.bricks(brickId)` → owner, round, `indexInRound`, Stone, withdrawal/eligibility/claim fields |
| Wallet cooldown | `game.lastBuildAt(wallet)`; initial zero means no previous build on a normal post-genesis launch |
| Wallet's refundable principal | `vault.stoneOf(wallet)` |
| Per-brick refundable principal | `vault.deposits(brickId)` → `(player, amount)`; amount becomes zero only after successful withdrawal |
| Vault backing | Native ETH balance of vault; compare against `vault.totalStone()` |
| Earned brick ETH | `game.claimableBrickETH(brickId)` → `(dividends, finalizedDiamondPrize)` |
| Credited Pharaoh/owner ETH | `game.ethCredit(wallet)` |
| Reward pool | `token.balanceOf(rewards)`, `rewards.committed()`, `rewards.uncommitted()` |
| Funding status | `rewards.isFunded()`, `rewards.fundingReached()`, `rewards.INITIAL_FUNDING()` |
| Capacity for a new round | `rewards.canReserveRound()`; uncommitted tokens do not gate additional builds in an already-reserved round |
| Creator's live token balance | `token.balanceOf(actualCreatorAllocationWallet)` from the launch handoff |
| Token reward | `rewards.claimable(roundId, wallet)`, `participated`, `claimed`, `rounds` |

`quote()` by itself does not assert that building is currently allowed. An expired but unfinalized round continues to return its old quote; show Finalize, and refetch after finalization. `currentRound == 0` is idle, not an already expired round. A finalized round can be followed by a new one only when enough uncommitted tokens remain. Refresh at every confirmed build/withdrawal and relevant block; a withdrawal can bring expiry forward immediately.

Before expiry, `activeBricks` and `activeStone` are the current earning population. At expiry they freeze as the diamond-hands snapshot. They can exceed actual Stone still held in the vault after subsequent withdrawals. Use **the vault ledger** for refundable principal, not the frozen round totals. `tomb` remains the historical prize-pot amount after finalization; it is then allocated, not an additional unspent balance. `claimableBrickETH` includes no estimate of a live round's future diamond prize.

Enumerate a wallet's brick IDs from its `BrickPlaced` logs (global IDs start at 1; indices start at 0 each round). Sum the individual pending amounts off-chain. There is no on-chain player enumeration or aggregate loop. Withdrawn bricks retain their slot in the confirmed pyramid and should be rendered inactive, rather than moving later bricks. The website stage chooses the visual geometry while preserving this bottom-up index order.

## Event indexing and receipts

Index `RoundStarted`, `BrickPlaced`, `MortarAllocated`, `BrickDeactivated`, `RoundFinalized`, `DiamondDustRecycled`, `BrickETHClaimed`, `ETHClaimed` and `PauseChanged` at the verified game. Index `StoneDeposited`/`StoneWithdrawn` at its vault. Index `Funded`, `InitialFundingReached`, `RoundReserved`, `ParticipantRecorded`, `RewardsFinalized` and `RewardClaimed` at its reward pool.

Use successful receipt logs and handle chain reorganizations; a submitted transaction is not a confirmed brick. Retain the funder's transaction hash from the actual `Funded` receipt. `totalFunded` counts successful `fund()` deposits only. Direct ERC-20 donations still count toward the balance threshold, but are represented by the token's `Transfer` logs, not a `Funded` event. The creator deposit should use `fund()` for an explicit auditable receipt.

The initial funding threshold is a historical gate. `isFunded()` can be true before `fundingReached()` is latched if a direct transfer brought the balance to 700M; `reserveRound` latches it atomically. After rewards leave, balances below 700M are expected. The website must display the live numbers, not falsely report NOT FUNDED again. Depositing the creator allocation does not prevent that wallet from later buying/receiving/earning tokens; display its current balance without claiming a permanent zero-balance guarantee.

Before Build, display the exact Stone (refundable), Mortar (non-refundable), price, and gas separately, along with the disclaimer in the README. Read-only watching needs no wallet. The frontend contribution is responsible for wallet-network checks, receipts, mobile/browser testing, accessibility, reduced motion, and the real deployment-address configuration.
