**Rewards Native Token System:**
Per‑epoch rewards are split by collateral‑class weights, operator uptime, and stake routing through vaults. Funding deposits the native L1 token and sets `funded`. Distribution runs in batches per operator and locks the epoch with `distributionComplete`. Claims only walk completed epochs and advance a per‑claimer pointer. Leftovers from rounding or unused share get swept after a grace period.

**Key Difference:** This system operates with a **single native token** (L1 primary collateral) instead of supporting multiple reward tokens.

---

## Lifecycle

* **Fund**

  * `setRewardsAmountForEpochs(start, n, amtPerEpoch)`
  * Transfers `n * amtPerEpoch` in **native token only**. Takes protocol fee upfront.

    * `protocolRewards += total * protocolFee / 10_000`
    * Per‑epoch pool = `amtPerEpoch * (1 - protocolFee/10_000)`
  * Marks each target epoch `funded = true`.
  * Cannot call if distribution for `start` already began.

* **Distribute**

  * `distributeRewards(epoch, batchSize)` by `REWARDS_DISTRIBUTOR_ROLE`.
  * Time gates:

    * Earliest distribution: `currentEpoch >= epoch + 2`.
    * If `currentEpoch <= epoch + 4` and epoch **not** funded **and** there are operators → revert `EpochNotFunded`.
    * Past the funding window (`currentEpoch > epoch + 4`): allowed even if unfunded.
  * Sequential: must finish `epoch-1` before `epoch`.
  * Batches over operators. On completion: `distributionBatches[epoch].isComplete = true` and `epochStatus[epoch].distributionComplete = true`.

* **Claim**

  * Once per epoch per claimer type (no token parameter needed).
  * Iterate from `lastEpochClaimedX[claimer] + 1` forward:

    * Stop at first epoch where `distributionComplete == false`.
    * **Maximum of `MAX_EPOCHS_PER_CLAIM` (64) epochs processed per call to prevent out-of-gas.**
    * Sum rewards for each settled epoch.
    * Always advance pointer to the last settled epoch visited.
    * If sum == 0 and pointer moved → emit `ZeroRewardsClaim` and return.
  * Functions:

    * `claimRewards(recipient)` for stakers.
    * `claimOperatorFee(recipient)` for operators.
    * `claimCuratorFee(recipient)` for curators.
    * `claimProtocolFee(recipient)` for protocol owner (aggregated bucket, no epochs).
  * **Note:** Users with long unclaimed backlogs can call claim functions multiple times to process all epochs.

* **Sweep leftovers**

  * `claimUndistributedRewards(epoch, recipient)` by distributor.
  * Allowed when `distributionComplete` and `currentEpoch >= epoch + 2 + 1`.
  * Computes:

    * `usedShares = min(ΣoperatorShares + ΣvaultShares + ΣcuratorShares, 10_000)`
    * `undistributed = epochPool * (1 - usedShares/10_000)`
  * Transfers `undistributed` and shrinks the epoch pool so users can still claim the remaining part. One‑time per epoch.

---

## Share math (basis points, all floors via `mulDiv`)

* **Uptime source**
   * From `UptimeTracker`. For epoch `e`, `operatorUptimePerEpoch[e][op]` is the arithmetic mean of the uptimes of all active validators for `op` in `e`.
   * Uses `middleware.getOperatorValidationIDs(op)` to get all historical validationIDs, then filters by validator start/end times to find validators active during the epoch.
   * Units: seconds.
   * **Write-once guard**: `computeOperatorUptimeAt` can only be called once per (epoch, operator). Subsequent calls revert with `UptimeTracker__OperatorUptimeAlreadySet`. This prevents manipulation after node removals.
   * Guard: if `operatorUptimePerEpoch[e][op] < minRequiredUptime` then `rawShare = 0` for all classes for that operator in `e`. 

* **Per operator, per class**

  * `uptimeFracBp = uptimeSecs * 10_000 / epochDuration`
  * `rawShare = classShareBp * (operatorUsedStake / totalStakeInClass) * uptimeFracBp / 10_000`
  * `operatorFeeShare = rawShare * operatorFee / 10_000`
  * `beneficiaryBudget[op][class] = rawShare - operatorFeeShare`
  * Store:

    * `operatorShares[epoch][op] += operatorFeeShare`
    * `operatorBeneficiariesSharesPerCollateralClass[epoch][op][class] = beneficiaryBudget`

* **Split beneficiary budget to vaults (per operator, class)**

  * For each vault `v` in `class`:

    * `vaultStakeToOp = stakeAt(v→delegator, class, op, epochStart)`
    * `opActiveStakeInClass = Σ vaultStakeToOp over all vaults in class`
    * `vaultSharePreCurator = beneficiaryBudget * (vaultStakeToOp / opActiveStakeInClass)`
    * `curatorCut = vaultSharePreCurator * curatorFee / 10_000`
    * Store:

      * `vaultShares[epoch][v] += vaultSharePreCurator - curatorCut`
      * `curatorShares[epoch][owner(v)] += curatorCut`

* **Token payouts from an epoch pool `R` (native token)**

  * Operator `op`: `R * operatorShares[epoch][op] / 10_000`
  * Curator `c`: `R * curatorShares[epoch][c] / 10_000`
  * Staker `s` in vault `v`:

    * `tokensForVault = R * vaultShares[epoch][v] / 10_000`
    * `sReward = tokensForVault * activeSharesOfAt(s, epochStart) / activeSharesAt(epochStart)`

---

## Time windows

```
                   ← past                                  now →
…  N-5  N-4  N-3  N-2  N-1   N   N+1  N+2  N+3  N+4 ... currentEpoch (e.g., N+2)
      └──── funding window ────┘
                    └─ earliest distribution for N is when currentEpoch == N+2
sweep(undistributed) allowed when currentEpoch ≥ N + 3 and distributionComplete
```

**Key Time Constraints:**
- **Funding Window**: Epochs N-4 to N can be funded (when currentEpoch = N)
- **Earliest Distribution**: When currentEpoch == N+2 (code checks currentEpoch ≥ N+2)
- **Sweep Allowed**: When currentEpoch ≥ N+3 and distributionComplete

* Unfunded epochs:

  * Inside window and operators exist → cannot distribute.
  * Outside window → can distribute to advance sequence, pays 0.

---

## Storage per epoch

* `epochStatus`: `{ funded, distributionComplete }`
* `distributionBatches`: `{ lastProcessedOperator, isComplete }`
* Shares:

  * `operatorShares`, `vaultShares`, `curatorShares`
  * `operatorBeneficiariesSharesPerCollateralClass`
* Pools:

  * `epochRewards[epoch]` (single native token amount)
* Claim pointers (no token dimension):

  * `lastEpochClaimedStaker`, `…Curator`, `…Operator`, `…Protocol`
* Sweep guard: `_undistributedSwept[epoch]`
* Curator index: `_epochCurators[epoch]` (unique set)

---

## Roles

* `DEFAULT_ADMIN_ROLE`: can assign manager, protocol owner.
* `REWARDS_MANAGER_ROLE`: set class weights, fees, min uptime, add distributor.
* `REWARDS_DISTRIBUTOR_ROLE`: fund epochs, run distribution, sweep leftovers.
* `PROTOCOL_OWNER_ROLE`: claim protocol fee.

---

## Admin knobs and guards

* Class weights: sum ≤ `10_000`. Per‑class `setRewardsShareForCollateralClass`.
* Fees: `protocolFee + operatorFee + curatorFee ≤ 10_000`. Update singly or `updateAllFees`.
* Min uptime: `≤ epochDuration`.
* Reentrancy: all external mutating flows are `nonReentrant`.
* Sequential enforcement: cannot distribute rewards for epoch N if distribution was not completed for epoch N-1.

---

## Changing Collateral Class Weights

### Why Change Weights?

**Purpose:** Market prices fluctuate. A collateral class worth 40% of TVL yesterday may be worth 20% today due to price changes. Weight adjustments maintain alignment between economic security and reward allocation.

### How Weights Work

**Key behavior:** `rewardsSharePerCollateralClass` is **not stored per epoch**. The contract reads the **current** value during distribution. This means:

- Weight changes apply to all **future** distributions
- Weight changes apply to **past undistributed** epochs

### Safe Procedure

**Goal:** Avoid applying new weights to past epochs unintentionally.

**Process:**

1. **Distribute all pending epochs** - Complete distribution for all eligible epochs (currentEpoch - 2 or earlier)
2. **Change weights** - Call `setRewardsShareForCollateralClass(classId, newBasisPoints)` for each class
3. **Fund future epochs** - Use `setRewardsAmountForEpochs()` to fund upcoming epochs

**Example:**
```
Current epoch: 100
Last distributed: 97

→ Distribute epoch 98. Eligible because currentEpoch 100 >= epoch 98 + 2 (which is the DISTRIBUTION_EARLIEST_OFFSET)
→ Change weights: PRIMARY 6000→7000, SECONDARY 4000→3000
→ Fund epochs 101-110

Result: 
- Epoch 99 cannot be distributed yet (needs currentEpoch >= 101)
- Epochs 100+ will use new weights when distributed
```

**Distribution eligibility rule:** Epoch N can be distributed when `currentEpoch >= N + DISTRIBUTION_EARLIEST_OFFSET` (where `DISTRIBUTION_EARLIEST_OFFSET = 2`)

**Examples:**
- Epoch 98: needs currentEpoch >= 100 ✅ (eligible now)
- Epoch 99: needs currentEpoch >= 101 ❌ (not yet eligible)

**If you must change mid-stream:** Document which historical epochs will be affected. Changes are permanent once distribution runs.

**Note:** Fees (`protocolFee`, `operatorFee`, `curatorFee`) behave identically—they also apply at distribution time, not funding time.

---

## Native Token Model

### Key Differences from Multi-Token System

* **Single Token**: Only the L1 primary collateral token (from `middleware.PRIMARY_ASSET()`) is supported
* **Simplified Storage**: No token-indexed mappings - single values per epoch/claimer
* **Automatic Token Selection**: Token is set during initialization and cannot be changed
* **Simplified API**: No token parameters in claim functions

### Token Configuration

* **Rewards Token**: Set to the **underlying asset** of the primary collateral: `ICollateral(middleware.PRIMARY_ASSET()).asset()`. This is the native L1 token (e.g., WAVAX), not the collateral wrapper.
* **Validation**: Token address must be non-zero during setup
* **Immutable**: Cannot be changed after deployment

---

## Edge cases covered

* New or empty class: `totalStake == 0` → skipped, no div‑0.
* Zero‑uptime or zero‑stake operator: share = 0.
* Single reward token: simplified claim logic without token iteration.
* No operators: inside window, unfunded epoch does not revert funding check; distribution completes with no shares.
* Vault removal and class changes: reads historical snapshots via `active*At` and `stakeAt`.

---

## Quick API reference

* `setRewardsAmountForEpochs(start, n, amtPerEpoch)` → fund and mark epochs (native token only).
* `distributeRewards(epoch, batchSize)` → compute shares, mark complete when done.
* `claimRewards(recipient)` → staker claim (native token).
* `claimOperatorFee(recipient)` → operator claim (native token).
* `claimCuratorFee(recipient)` → curator claim (native token).
* `claimProtocolFee(recipient)` → protocol owner claim (native token).
* `claimUndistributedRewards(epoch, recipient)` → sweep post‑grace (native token).
* `setRewardsShareForCollateralClass(classId, bp)`, `setMinRequiredUptime(x)`.
* `updateProtocolFee/OperatorFee/CuratorFee`, `updateAllFees`.
* `setRewardsDistributorRole(addr)`, `setRewardsManagerRole(addr)`, `setProtocolOwner(addr)`.

---

## Invariants

* `Σshares(epoch) ≤ 10_000 bp` across operators + vaults + curators.
* Over time: `paidToClaimants(epoch) + swept(epoch) == epochRewards[epoch]`.
* Claim pointers only advance over `distributionComplete` epochs, so early claims never skip future rewards.
* Single token model: all rewards are denominated in the native L1 primary collateral token.
