# Local implementation validation

This is the implementer's verification record, **not an independent security review or launch approval**. The protected source inputs were read but not edited or copied into environment-dependent project tests. Their token-supply, constructor-execution, runtime-size and opcode checks are additionally exercised by the local `DeploymentTest` without needing service-provided environment variables.

Toolchain: Foundry **1.8.3**, Solidity **0.8.26**, Cancun, optimizer enabled with 200 runs, metadata hash disabled. All dependencies used for compilation are vendored. No RPC, keys, network forks, broadcast, FFI, or Solidity filesystem permissions were used.

## Checks

| Check | Result |
| --- | --- |
| `forge build` | Passed with the pinned compiler. |
| `forge build --offline --force` | Passed rebuilding from the delivered source and vendored dependencies. |
| `forge test -vv` | **53 reported tests passed**, zero failed/skipped, across eight suites. |
| `forge test --offline --threads 4 -vv` | Passed with parallel execution and offline dependency resolution. |
| Parameter fuzz tests | 512 runs each for token transfers, brick price/wei allocation, and token participant rounding. |
| Stateful solvency test | Four properties checked together; 128 runs × 128 generated handler calls = **16,384 calls**, zero unexpected reverts. Every run concludes by refunding all remaining Stone and claiming all earned ETH/tokens. |
| `forge fmt --check` | Passed. |
| `python3 scripts/export_abis.py --check` | All four exports match their build artifacts. |

Generated handler calls include explicit precondition skips when an action is not currently available; the call count is not a claim that every generated action changed state. The fixture seeds two real bricks before fuzzing, and the end-of-run unwind must pay every remaining obligation. Stateful counters independently reconcile actual ETH/token receipts with custody balances and recorded liabilities.

## Production bytecode limits

| Contract | Runtime bytes | Creation bytecode bytes (before arguments) |
| --- | ---: | ---: |
| `LaunchToken` | 1,722 | 2,613 |
| `Ponziramid` | 7,044 | 14,388 |
| `StoneVault` | 1,564 | 1,746 |
| `PonziRewards` | 4,769 | 5,080 |

All are below EIP-170's 24,576-byte runtime limit and EIP-3860's 49,152-byte initcode limit. The complete parent deployment, including its two address arguments, is 14,452 bytes. The parent initcode includes creation of both custody children. A PUSH-aware opcode scan of all four deployed runtimes found no `DELEGATECALL`, `CALLCODE`, or `SELFDESTRUCT`.

`DeploymentTest` creates token and application through a CREATE2 probe, checks that the factory still holds the complete token supply after construction, verifies explicit ownership and child bindings, and independently deploys the game with a nonzero code-less token address to test empty-chain constructor compatibility. It does not simulate or claim a mainnet deployment.

## Success and failure coverage

- Exact factory supply, metadata, transfers, allowance consumption, invalid receivers, overspending, and rejection of common mint/admin selectors.
- Initial 700M funding threshold including one wei short, one-time threshold latching, direct donations, whole creator allocation deposit, permanent deposits, and immutable reward constants.
- Reservation of all 700 funded rounds without claiming them; a 701st reservation fails until new funding arrives. Paying an old claim does not create new uncommitted funds.
- Per-wallet cooldown, consecutive Pharaoh restrictions after withdrawal, exact price/round expectations, continuous price growth, timer resets, the seven-day cap, and exact expiry.
- A 144-brick bank run deducting a complete 24-hour timer, and a surviving global wallet cooldown across the resulting round boundary.
- Refunds before expiry, exactly at expiry before finalization, after finalization, during pauses, with unavailable token/reward code, and hundreds of days into later rounds.
- Earlier-active-brick dividends only; claims during a round; inactive bricks retaining earned dividends; no-active-brick allocations; pro-rata diamond prizes; partial claims; token and ETH rounding/dust recycling.
- Duplicate refunds/claims/finalization, attempts to impersonate the game or vault, owner/funder attempts to extract permanent rewards, and nonparticipant claims.
- Rejected ETH principal, dividend, diamond, Pharaoh and owner-credit payments with full rollback; token transfer failure with successful later retry; fee-charging test token rejection during funding.
- Reentry into Stone refunds, brick ETH, Pharaoh credit, token claims, and a cross-contract refund attempt during an ETH claim. These tests exercise authorized claimants' callbacks, not just unauthorized callers.
- Settlement without recipient transfers, including rejecting Pharaoh recipients; no dependency on token transfer success to finalize; forced ETH not creating unearned credits.

## Accounting review

The vault has exactly one payable deposit entry restricted to its immutable game and exactly one outgoing ETH call, in an authenticated depositor withdrawal. It reduces the principal ledger, invokes the immutable game's bookkeeping-only callback, and transfers the exact credit. A revert restores all state in both contracts. The game callback does not call the token/reward pool, finalize, send ETH, or check pause. No owner method exists in the vault.

All game payouts draw from the balance remaining after Stone is deposited into the separate vault. Owner fees and Pharaoh prizes become pull credits; dividends and diamond obligations are reserved per round. Withdrawals freeze each brick's accumulator ceiling, allowing earned dividends to remain payable without any per-player iteration. Frozen expiry eligibility is independent of subsequent principal custody. The final eligible diamond settlement recycles only the mathematical residue after every owed share is paid.

In `PonziRewards`, `fund` can only pull tokens **into** the pool. `reserveRound`, `recordParticipant`, and `finalizeRound` are bound to the immutable game and cannot transfer tokens. The only outgoing token call is `safeTransfer` inside authenticated `claim`, after the verified participant's claim bit and committed balance are updated. There are no approvals, owner/funder withdrawals, recovery methods, or configurable token/game addresses. Token recovery is intentionally absent even for unrelated assets.

## Lint review and limits

Foundry's built-in linter emits heuristic warnings. They were reviewed against the actual code rather than globally suppressed:

- Timestamp warnings reflect the requested deterministic cooldown/expiry rules, not an entropy source. Validator/order influence is documented. Test-time reads use `vm.getBlockTimestamp()` to avoid compiler caching across `vm.warp`.
- Division-before-multiplication calculates the precisely payable whole-wei dividend total; the remainder goes to the Tomb. It is deliberate, fuzz-tested rounding, not an accidentally truncated price formula.
- Arbitrary-ETH-destination warnings concern recipients chosen by the authenticated owner of a credit. Unauthorized claim/refund attempts fail; choosing an accepting alternate recipient is necessary for contract wallets whose receive function rejects ETH.
- Reentrancy/status warnings include the OpenZeppelin guard's reset after external calls. Claim/refund effects and payment events precede recipient calls; guard tests cover both same-contract and cross-contract attempts. Other external game calls are to immutable local custody children. Funding uses the fixed launch token and `SafeERC20`.
- The participation access-control event warning is a false positive: the write is accompanied by `ParticipantRecorded(roundId, player)` in the same branch. Constructor/round event warnings involve immutable local child creation/calls, not untrusted callback destinations.

Slither, Mythril, a formal proof, a mainnet fork, an independent contributor audit, real deployment verification, and browser/mobile wallet tests were **not** performed in this contract contribution. Independent source-and-manifest review and the subsequent deployment/frontend stages remain responsible for those release artifacts and their own appropriate checks. See the explicit timing, owner-power, funding, dust and custody assumptions in the README and launch handoff.
