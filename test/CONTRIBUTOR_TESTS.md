# Additional adversarial tests

These tests extend the accepted implementation's existing suite. They require only the repository's
vendored dependencies and Solidity 0.8.26. Run `forge build` and `forge test`; no RPC, environment
variables, FFI, downloads, or deployment credentials are used.

- `AdversarialBoundaries.t.sol` checks rejected quotes and payments without state changes, timestamp-zero
  cooldowns, pauses across expiry, unknown brick IDs, funding allowance/balance failures, vault deposit
  validation and full refunds. Its depletion test drives 700 actual game rounds, verifies that the last
  reserved round still accepts builders, checks old refunds and claims, then replenishes one wei short
  of the next reservation before completing it.
- `invariant/LaunchTokenInvariant.t.sol` tracks five actors' balances and every approval independently.
  Random sequences mix transfers, self transfers, finite/infinite approvals, delegated spending, full
  balance transfers and rejected calls. The campaign finishes by consolidating the entire supply.
- `invariant/PayoutOracleInvariant.t.sol` uses a simple per-brick ledger instead of the contract's
  accumulator. Each placement directly credits every earlier active brick in the model. It checks
  individual dividends, weighted Tomb shares, distinct-wallet token rewards, principal, timers and
  actual recipient balances through random builds, withdrawals, claims, pauses and finalizations.
  Forced ETH and direct token donations must not change player entitlements. Every sequence ends by
  collecting all outstanding claims and refunds, even if the game is paused.

Both new invariant campaigns use five actors, 256 runs and depth 96, with unexpected reverts treated
as failures. Stateless fuzz cases use 1,000 runs. Settings are inline in the test files.

The oracle intentionally uses bounded actor sets and call sequences. Passing these tests is evidence
for the exercised properties, not a complete security review. They do not simulate publication,
admission, deployment, creator funding receipts, or frontend behavior.
