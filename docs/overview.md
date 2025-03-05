# Suzaku Protocol Overview

---

## 1. Introduction Suzaku Protocol
- **Suzaku’s Goal**: Help Avalanche L1 builders decentralize their L1, orchestrating Operators, Curators and L1 builders. 
- **Inspired By**: Symbiotic, Eigenlayer and other restaking protocols—adapting these ideas to the Avalanche ecosystem.

### Protocol Participants & Key Features

- **Participants**:
  - **L1s**: Avalanche-based networks that define their own staking and slashing rules; leverage Suzaku reference modules.
  - **Stakers**: Provide collateral (L1 tokens, restaked assets) to secure networks; receive rewards via curated operators.
  - **Operators**: Run validation infrastructure, opting into the vault and L1; must meet each network’s stake requirements.
  - **Curators**: Select networks and reliable operators; pool staker collateral and distribute rewards.

- **Core Features**:
  - **Build Avalanche L1**: Use Avalanche Stack to build an L1 securedy by Suzaku restaking
  - **PoS, Liquid Staking & Restaking**: Combine native token staking with restaking of stable or blue-chip assets; enable liquid staking tokens for added yield.
  - **Dual Staking Model**: Require both native and whitelisted collateral for validator nodes, mitigating token volatility risks.
  - **Slashing**: Suzaku’s architecture currently doesn't have slashing, only implicit through holding rewards for validators with bad uptime. 

## 2. Code Architecture & Main Components

Below is a summarized explanation of the key smart contracts/interfaces within Suzaku.

### 2.1 VaultTokenized (owner Curator)
- **Purpose**: An upgradable tokenized vault (ERC4626-like) that manages deposits, withdrawals, and staking shares.
- **Epoch-Based Withdrawals**: Redeemed amounts become claimable in the **next** epoch, ensuring stable stake across each epoch.
- **Checkpointing**: Tracks historical balances (active stake/shares) for record-keeping.
- **Deployed Behind an ERC1967 Proxy**: The vault factory (`VaultFactory`) deploys each vault as a `MigratableEntityProxy` (an ERC1967 proxy).
- **Initialization**: The vault’s `initialize()` sets up roles, collateral, deposit limits, and admin addresses.
- **Upgrades**:
  1. **Factory as Proxy Admin**: Only the factory can invoke `upgradeToAndCall(...)` on the proxy.
  2. **Versioned Migrations**: Internally, the vault uses `_migrateInternal(...)` + `reinitializer(newVersion)` to handle logic changes or data migrations.
  3. **`migrate(newVersion, data)`** is called on the vault after pointing the proxy to a new implementation, allowing for safe re-initialization.
- Core Roles & Access Control
  - **DEFAULT_ADMIN_ROLE:** overall admin within the vault.
  - **DEPOSIT_WHITELIST_SET_ROLE:** enable/disable deposit whitelist requirement.
  - **DEPOSITOR_WHITELIST_ROLE:** whitelist specific addresses for deposits.
  - **IS_DEPOSIT_LIMIT_SET_ROLE:** enable/disable the deposit limit fea

### 2.2 Delegators (Owner Curator)
**BaseDelegator**  
- Tracks maximum stake an entity can allocate to each L1+assetClass pair.
- Uses a vault reference to ensure operators’ stake does not exceed available active stake.

1. **Stake Retrieval**  
   - `stake(l1, assetClass, operator)` → returns the operator’s staked amount (for that L1 & asset class).  
   - `stakeAt(l1, assetClass, operator, timestamp, hints)` → historical version of `stake` (useful for a past `timestamp`).  

2. **L1 Limits**  
   - `maxL1Limit[l1][assetClass]`: the maximum capacity any delegator is willing to allocate to that L1/assetClass.  
   - `setMaxL1Limit(l1, assetClass, amount)` → sets the maximum limit for a given L1/assetClass pair.  

3. **Opt-In Checks**  
   - The delegator checks if an operator is “opted in” to both the vault and the L1. If not, the staked amount is considered **0**.  

4. **Roles**  
   - `HOOK_SET_ROLE` (unused if you’re not focusing on hooking/slashing).  
   - Default admin manages other roles.

5. **Vault Link**  
   - Each delegator references a **vault** (`vault` address). Operators deposit assets in that vault.  
   - The delegator enforces that each L1’s stake cannot exceed the vault’s available active stake or the L1 limit.  


**L1RestakeDelegator**  
- Allocates vault stake among multiple L1s/operators using a **shares** model.
- Staked amount = `(operatorShares / totalShares) * min(vault.activeStake, l1Limit)`.
- Offers historical queries (checkpointing) for stake data.
1. **Shares-Based Model**  
   - Instead of storing staked amounts directly, this delegator uses “shares”:  
     - **`operatorL1Shares[l1][assetClass][operator]`**: how many shares an operator has for a specific L1/assetClass.  
     - **`totalOperatorL1Shares[l1][assetClass]`**: total shares across *all* operators on that L1/assetClass.  
   - The actual staked amount is derived by:  
     \[
       \text{operatorShares} * \min(\text{vault.activeStake}, \text{l1Limit}) / \text{totalShares}
     \]

2. **Setting L1 Limits**  
   - `setL1Limit(l1, assetClass, amount)` → updates the subnetwork’s “live” limit.  
   - Must not exceed `maxL1Limit[l1][assetClass]` from BaseDelegator.  

3. **Setting Operator Shares**  
   - `setOperatorL1Shares(l1, assetClass, operator, shares)` → updates an operator’s portion of the total.  
   - Adjusts `_operatorL1Shares` + `_totalOperatorL1Shares` accordingly.  

4. **Queries**  
   - `operatorL1Shares(l1, assetClass, operator)` → operator’s current shares.  
   - `totalOperatorL1Shares(l1, assetClass)` → total shares across all operators.  
   - `l1Limit(l1, assetClass)` → current L1 limit.  

5. **Checkpoints**  
   - Each variable uses checkpointing. Functions like `operatorL1SharesAt(...)` or `l1LimitAt(...)` provide historical lookups.  


### 2.3 Opt-In Services
- **OperatorL1OptInService**: Operators must explicitly “opt in” to a given L1 (verified by `IL1Registry`).
  - “where” = L1 from an `IL1Registry`.  
  - Operators must be registered in `OperatorRegistry` to opt in or out of an L1.
- **OperatorVaultOptInService**: Operators must “opt in” to each vault (verified by `IVaultFactory`).
  - “where” = vault from a `IVaultFactory`.  
  - Operators opt in or out of specific vaults they will accept collateral from.

- Both track each operator’s status (in or out) with signature-based calls and checkpointed records.

### 2.4 Registries
- **L1Registry**: Lists Avalanche-based L1s, each with a `validatorManager` and optional middleware references.
   - Registers Avalanche L1s with their middleware modules and metadata.  
   - `registerL1(...)`, `isRegistered(...)`, etc.
- **OperatorRegistry**: Tracks registered operators; they can set/update metadata.
   - Registers operators (EOAs or contracts) and tracks their metadata.  
   - `registerOperator(...)`, `isRegistered(...)`.
- **VaultFactory**: Deploys and upgrades vaults via proxies; also a registry of valid vault addresses.
   - Deploys and upgrades vaults (ERC1967 proxy pattern).  
   - Tracks all created vaults (`isEntity(...)`).

### 2.5. AssetClassRegistry
- Manages sets of assets (like stablecoins, LSTs) grouped under an “asset class”, for instance AVAX derivaties like sAVAX, with min/max validator stakes. Secondary asset classes have only a min validator stake.
- **Tracks** sets of ERC-20 tokens grouped by a class ID (e.g., primary token vs. multiple LSTs).  
- **Min/Max Stake** per asset class.  
- **Functions**: add/remove assets from a class, define stake bounds, query membership.

### 2.6 AvalancheL1Middleware (Owner L1)
- Ties everything together for each L1:
  - Registers operators, controls node lifecycle, coordinates with a `ValidatorManager` for node weights.
  - Inherits from `AssetClassRegistry` to handle multiple (re)staking asset classes.
  - **Node and Stake Management**:
    1. **Epoch Start**: Operators have node weights set from the previous epoch.  
    2. **Operators Make Changes** (optional):
       - Add or remove nodes, or partially update node weights.  
       - If mid-epoch, these changes are queued (`nodePendingUpdate`) until finalization messages from `balancerValidatorManager`.
    3. **Final Update Window**:  
       - Operators may call `forceUpdateNodes(...)` to ensure node weights align with their real available stake.  
       - The contract locks or unlocks stake accordingly.
    4. **Epoch Transitions**:  
       - `_calcAndCacheNodeWeightsForOperatorAtEpoch` is called to carry forward or finalize node statuses.  
       - If a node ended in the previous epoch, it’s removed from arrays.  
       - If a node had a pending update, it’s now resolved.
       - If this isn't called, it implies no change was done, it can be called retroactivelly for all nodes.
- The **BalancerValidatorManager** remains the ultimate source for each node’s status (active, ended, updated, etc.), while this middleware caches that data for fast lookups and consistent staking logic.

### 2.7 MiddlewareVaultManager (Owner L1)
- Oversees vault registration for a given L1, enforcing stake limits per vault.
- `registerVault(vault, assetClassId, vaultMaxL1Limit)`: links a vault to an asset class, imposing a max L1 stake limit. This is done through the Delegator and from there on the L1Registry.
- Facilitates slashing across multiple vaults based on each vault’s share of the total stake.
- Integrates with the L1 middleware to ensure correct staking capacity and slashing windows.
---

## 3. Overview
1. **Setup**: An L1 builder configures their chain and chooses how to incorporate PoS, restaking, or the dual-staking model.
2. **Registration**: 
   - The L1 is registered in `L1Registry`, and operators register in `OperatorRegistry`.
   - A vault is deployed via `VaultFactory`, with delegators deciding how to allocate stake.
3. **Opt-Ins**: Operators must opt in to both the vault and the L1. Curators manage these allocations on behalf of stakers.
4. **Epoch Flow**: 
   - Vaults checkpoint user deposits and handle epoch-based withdrawals.
   - The L1 middleware calculates node weights, triggers updates, and (in future) can slash underperforming operators based on it's own middleware epochs.
5. **Validator Manager**:
   - The Validator Manager is a separate contract which is handling the communicationg with the P-Chain in order to add-remove-upgrade validators and the L1.

## 4. Operator Flow
- **Register** with `OperatorRegistry` (metadata optional).
- **Opt In** to:
  - **Vault** (via `OperatorVaultOptInService`)  
  - **L1** (via `OperatorL1OptInService`)
- **Stake Allocation** is then managed by a delegator contract (e.g. `L1RestakeDelegator`), assigning a portion of the vault’s active stake to the operator for each L1.
- **Run Infrastructure** to validate or perform required off-chain tasks (depending on the L1 design).

---
