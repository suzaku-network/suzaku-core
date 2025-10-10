**Rewards System:**
Per‑epoch rewards are split by collateral‑class weights, operator uptime, and stake routing through vaults. Funding deposits tokens and sets `funded`. Distribution runs in batches per operator and locks the epoch with `distributionComplete`. Claims only walk completed epochs and advance a per‑token pointer. Leftovers from rounding or unused share get swept after a grace period.

---

## Lifecycle

* **Fund**

  * `setRewardsAmountForEpochs(start, n, token, amtPerEpoch)`
  * Transfers `n * amtPerEpoch` in. Takes protocol fee upfront.

    * `protocolRewards[token] += total * protocolFee / 10_000`
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

  * Once per epoch **per reward token** per claimer type.
  * Iterate from `lastEpochClaimedX[claimer][token] + 1` forward:

    * Stop at first epoch where `distributionComplete == false`.
    * **Maximum of `MAX_EPOCHS_PER_CLAIM` (64) epochs processed per call to prevent out-of-gas.**
    * Sum rewards for each settled epoch.
    * Always advance pointer to the last settled epoch visited.
    * If sum == 0 and pointer moved → emit `ZeroRewardsClaim` and return.
  * Functions:

    * `claimRewards(token, recipient)` for stakers.
    * `claimOperatorFee(token, recipient)` for operators.
    * `claimCuratorFee(token, recipient)` for curators.
    * `claimProtocolFee(token, recipient)` for protocol owner (aggregated bucket, no epochs).
  * **Note:** Users with long unclaimed backlogs can call claim functions multiple times to process all epochs.

* **Sweep leftovers**

  * `claimUndistributedRewards(epoch, token, recipient)` by distributor.
  * Allowed when `distributionComplete` and `currentEpoch >= epoch + 2 + 1`.
  * Computes:

    * `usedShares = min(ΣoperatorShares + ΣvaultShares + ΣcuratorShares, 10_000)`
    * `undistributed = epochPool * (1 - usedShares/10_000)`
  * Transfers `undistributed` and shrinks the epoch pool so users can still claim the remaining part. One‑time per `(epoch, token)`.

---

## Share math (basis points, all floors via `mulDiv`)

* **Uptime source**
   * From `UptimeTracker`. For epoch `e`, `operatorUptimePerEpoch[e][op]` is the arithmetic mean of the uptimes of all active validators for `op` in `e`.
   * Units: seconds.
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

* **Token payouts from an epoch pool `R`**

  * Operator `op`: `R * operatorShares[epoch][op] / 10_000`
  * Curator `c`: `R * curatorShares[epoch][c] / 10_000`
  * Staker `s` in vault `v`:

    * `tokensForVault = R * vaultShares[epoch][v] / 10_000`
    * `sReward = tokensForVault * activeSharesOfAt(s, epochStart) / activeSharesAt(epochStart)`

---

## Time windows

```mermaid
gantt
    title Epoch Timeline and Time Windows
    dateFormat X
    axisFormat %s
    
    section Past Epochs
    N-5         :done, n5, 0, 1
    N-4         :done, n4, 1, 1
    N-3         :done, n3, 2, 1
    N-2         :done, n2, 3, 1
    N-1         :done, n1, 4, 1
    
    section Target Epoch
    N           :active, n, 5, 1
    
    section Future Epochs
    N+1         :future, n_1, 6, 1
    N+2         :future, n_2, 7, 1
    N+3         :crit, current, 8, 1
    
    section Time Windows
    Funding Window  :done, funding, 1, 5
    Distribution Start :milestone, 7, 0
    Sweep Start     :milestone, 8, 0
```

**Key Time Constraints:**
- **Funding Window**: Epochs N-4 to N can be funded
- **Earliest Distribution**: When currentEpoch ≥ N+2
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

  * `rewardsAmountPerTokenFromEpoch[epoch][token]`
* Claim pointers (per token):

  * `lastEpochClaimedStaker`, `…Curator`, `…Operator`
* Sweep guard: `_undistributedClaimed[epoch][token]`
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
* Sequential enforcement: cannot distribute `epoch+1` before `epoch` completes.

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

→ Distribute epochs 98, 99 (now eligible)
→ Change weights: PRIMARY 6000→7000, SECONDARY 4000→3000
→ Fund epochs 101-110

Result: Epoch 100+ will use new weights when distributed
```

**If you must change mid-stream:** Document which historical epochs will be affected. Changes are permanent once distribution runs.

**Note:** Fees (`protocolFee`, `operatorFee`, `curatorFee`) behave identically—they also apply at distribution time, not funding time.

---

## Edge cases covered

* New or empty class: `totalStake == 0` → skipped, no div‑0.
* Zero‑uptime or zero‑stake operator: share = 0.
* Multiple reward tokens in same epoch: independent pointers and pools.
* No operators: inside window, unfunded epoch does not revert funding check; distribution completes with no shares.
* Vault removal and class changes: reads historical snapshots via `active*At` and `stakeAt`.

---

## Quick API reference

* `setRewardsAmountForEpochs(start, n, token, amtPerEpoch)` → fund and mark epochs.
* `distributeRewards(epoch, batchSize)` → compute shares, mark complete when done.
* `claimRewards(token, to)` → staker claim.
* `claimOperatorFee(token, to)` → operator claim.
* `claimCuratorFee(token, to)` → curator claim.
* `claimProtocolFee(token, to)` → protocol owner claim.
* `claimUndistributedRewards(epoch, token, to)` → sweep post‑grace.
* `setRewardsShareForCollateralClass(classId, bp)`, `setMinRequiredUptime(x)`.
* `updateProtocolFee/OperatorFee/CuratorFee`, `updateAllFees`.
* `setRewardsDistributorRole(addr)`, `setRewardsManagerRole(addr)`, `setProtocolOwner(addr)`.

---

## Invariants

* `Σshares(epoch) ≤ 10_000 bp` across operators + vaults + curators.
* Over time: `paidToClaimants(epoch,token) + swept(epoch,token) == rewardsAmountPerTokenFromEpoch[epoch][token]`.
* Claim pointers only advance over `distributionComplete` epochs, so early claims never skip future rewards.
