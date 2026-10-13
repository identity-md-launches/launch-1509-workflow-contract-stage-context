# Additional adversarial tests

These tests extend the accepted implementation's existing suite. They require only the repository's
vendored dependencies and Solidity 0.8.26. Run `forge build` and `forge test`; no RPC, environment
variables, FFI, downloads, or deployment credentials are used.

- `AdversarialBoundaries.t.sol` checks rejected quotes and payments without state changes, timestamp-zero
  cooldowns, pauses across expiry, unknown brick IDs, funding allowance/balance failures, vault deposit
  validation and full refunds. Its depletion test drives 700 actual game rounds, verifies that the last
  reserved round still accepts builders, checks old refunds and claims, then replenishes one wei short
  of the next reservation before completing it.
- `AdversarialBoundaries.t.sol` also holds `FundingGateArgumentTest`, which deploys fresh games with other
  creator allocations now that the funding gate is a constructor argument rather than a compiled 700M
  constant. It fuzzes the whole accepted range: the pool holding one wei less than the deployed allocation,
  through `fund()` or a plain transfer in either order, never starts a round and never latches, while the
  exact amount does. It fuzzes rejected allocations below one round reward and above the supply through
  both constructors, pins the minimum gate (one round, then an empty pool that stays latched and needs
  exactly one more round reward), the maximum gate (every token in existence, with the last wei donated),
  and checks that the gate is per pool and has no setter.
- `invariant/FundingGateInvariant.t.sol` starts a game with a 3,000,000 PONZIRAM gate from an empty pool.
  Random sequences fund it in chunks, donate directly, build, finalize, claim and pause, so the pool is
  repeatedly drained and refilled. Rejected starts are asserted to leave commitments, bricks and the latch
  untouched. Invariants: the gate never changes; no round starts before the latch; the latch equals a ghost
  flag set only by a `fund()` call that reaches the gate or by a successful reservation, so a plain
  transfer that reaches it reports funded by balance but does not latch until the first round starts;
  the pool balance equals funding plus donations minus claims;
  committed equals reservations minus payouts minus recycled dust and never exceeds the balance; nothing
  is reserved beyond what was deposited. Every sequence ends by finalizing and claiming all rewards.
- `invariant/LaunchTokenInvariant.t.sol` tracks five actors' balances and every approval independently.
  Random sequences mix transfers, self transfers, finite/infinite approvals, delegated spending, full
  balance transfers and rejected calls. The campaign finishes by consolidating the entire supply.
- `invariant/PayoutOracleInvariant.t.sol` uses a simple per-brick ledger instead of the contract's
  accumulator. Each placement directly credits every earlier active brick in the model. It checks
  individual dividends, weighted Tomb shares, distinct-wallet token rewards, principal, timers and
  actual recipient balances through random builds, withdrawals, claims, pauses and finalizations.
  Forced ETH and direct token donations must not change player entitlements. Every sequence ends by
  collecting all outstanding claims and refunds, even if the game is paused.

The token and payout-oracle campaigns use five actors; the funding-gate campaign uses three. All run
256 runs at depth 96 with unexpected reverts treated as failures. Stateless fuzz cases use 1,000 runs.
Settings are inline in the test files. The fixture's 700M deposit is read from the deployed pool rather
than assumed, so these tests follow whatever allocation the manifest writes.

The oracle intentionally uses bounded actor sets and call sequences. Passing these tests is evidence
for the exercised properties, not a complete security review. They do not simulate publication,
admission, deployment, creator funding receipts, or frontend behavior.
