# Changelog

All notable changes to `suzaku-core` are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/).

## [1.1.0] — Unreleased

Changes relative to **1.0** (current `main`). This release is the contents of the
`fix/issue-250-stake-inflation` PR.

### Fixed

- **#250 — cross-validator stake inflation (`AvalancheL1Middleware`).** Every node-stake read
  site now consistently uses the *effective committed* stake — `nodeStakeCache[epoch + 1]` when it
  is set (the post-completion committed value), otherwise `nodeStakeCache[epoch]` (the epoch-start
  snapshot) — via the new private helper `_effectiveNodeStakeOrPending`. Previously some sites read
  the epoch-start value while others read the pending next-epoch value, so an operator's effective
  stake could be over-counted across validators while weight updates were pending. The redundant
  available-stake pre-check in the manual `initializeValidatorStakeUpdate` path (which relied on the
  inconsistent read) was removed. Adds regression tests in `test/middleware/AvalancheL1MiddlewareTest.t.sol`.

### Changed

- **Refactor (`AvalancheL1Middleware`):** extracted the repeated `nodeStakeCache[epoch+1] > 0 ?
  nodeStakeCache[epoch+1] : nodeStakeCache[epoch]` ternary into `_effectiveNodeStakeOrPending`, used
  by all "what is actually committed for this validator?" read sites.
- **Removed the unused `symbiotic-core` (`lib/core`) submodule** and its `@symbiotic/core/` remapping.
  It was imported by zero files in `src/` and `test/`; removal declutters compilation scope, test
  discovery, and tooling/dev context. No functional change — `forge build` compiles clean.

### Documentation

- Clarified middleware stake-accounting versioning (`docs/4-middleware.md`).
- Documented the unweighted operator-uptime limitation and how to manage it off-chain
  (`docs/6-uptimeTracker.md` → *Known Limitations*; pointer added in `docs/5-rewardsNativeToken.md`).

### Known Limitations

- **Operator uptime is an unweighted mean (reward-share fairness).**
  - *What it is:* `UptimeTracker.computeOperatorUptimeAt` aggregates an operator's validators' uptimes
    as an **unweighted** arithmetic mean (`sumValidatorsUptime / numberOfValidators`), independent of
    each validator's stake; `RewardsNativeToken._calculateOperatorShare` then multiplies that mean by
    the operator's **full** stake share. An operator running one large-stake validator at low uptime
    alongside several small-stake validators at high uptime can therefore report a near-full operator
    uptime and over-collect reward share at honest operators' expense. Reward redistribution only —
    **no principal at risk** (slashing is not enabled); per-epoch distribution stays capped at 100%.
  - *What would resolve it on-chain:* stake-weighting the aggregation
    (`Σ(uptimeᵢ · stakeᵢ) / Σ stakeᵢ`). Deferred — it changes the core uptime formula and its
    interaction with `nodeStakeCache` ordering and is out of scope for 1.1.
  - *How it is managed today (off-chain):* operators are permissioned, so the control is governance —
    monitor **per-validator** uptime and remove offenders. The procedure is documented in
    [`docs/6-uptimeTracker.md` → Known Limitations](docs/6-uptimeTracker.md#known-limitations).
    Demonstrated by `test/rewards/UptimeTrackerTest.t.sol::test_OperatorUptimeIsUnweightedMean`.

- **Primary-class distribution iterates unbounded validator history (gas / liveness).** The reward path
  walks the append-only `operatorValidationIDsArray` per operator with no inner checkpoint, so a very
  high-rotation operator can stall distribution (and, sequentially, later epochs). Liveness only — **no
  principal at risk**. On-chain fix deferred (the bounded path undercounts historical stake; `try/catch`
  is moot since `getValidator` can't revert). Managed off-chain: operators are permissioned, governance
  monitors per-operator history and bounds registrations. See
  [`docs/5` → Known Limitations](docs/5-rewardsNativeToken.md#known-limitations).
