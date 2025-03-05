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
- **Upgradability**: Uses ERC1967 proxy (deployed by `VaultFactory`), allowing safe migrations of vault logic.

### 2.2 Delegators (Owner Curator)
**BaseDelegator**  
- Tracks maximum stake an entity can allocate to each L1+assetClass pair.
- Uses a vault reference to ensure operators’ stake does not exceed available active stake.

**L1RestakeDelegator**  
- Allocates vault stake among multiple L1s/operators using a **shares** model.
- Staked amount = `(operatorShares / totalShares) * min(vault.activeStake, l1Limit)`.
- Offers historical queries (checkpointing) for stake data.

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
  - Manages epoch logic (weight caching, node removal, forced updates) to ensure consistent stake during each epoch.

### 2.7 MiddlewareVaultManager (Owner L1)
- Oversees vault registration for a given L1, enforcing stake limits per vault.
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
