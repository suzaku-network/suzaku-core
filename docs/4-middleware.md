# Avalanche L1 Middleware

The middleware orchestrates validator management and stake tracking for Avalanche L1s, acting as a security module within the BalancerValidatorManager architecture.

---

## Index

- [Overview](#overview)
- [Architecture](#architecture)
  - [Security Module Integration](#security-module-integration)
  - [Collateral Classes](#collateral-classes)
- [Roles & Actors](#roles--actors)
- [Operator & Node Lifecycle](#operator--node-lifecycle)
  - [Registration Flow](#registration-flow)
  - [Node Operations](#node-operations)
- [Stake Management](#stake-management)
  - [Stake Calculation](#stake-calculation)
  - [Node Weight Calculation](#node-weight-calculation)
- [Epoch System](#epoch-system)
- [Time Windows](#time-windows)
- [Roles & Access Control](#roles--access-control)
- [Key Functions](#key-functions)
- [Storage Per Operator](#storage-per-operator)
- [Invariants](#invariants)
- [Integration Points](#integration-points)
- [Common Patterns](#common-patterns)
- [Error Handling](#error-handling)
- [Gas Optimizations](#gas-optimizations)
- [Security Considerations](#security-considerations)
- [Related Documentation](#related-documentation)

---

## Overview

**AvalancheL1Middleware** bridges restaking infrastructure with Avalanche's validator management system. It implements the `ISecurityModule` interface, managing operator lifecycle, node registration, and stake allocation across multiple collateral classes.

**Key responsibilities:**
- Operator and node lifecycle management
- Multi-collateral stake tracking and weight calculation
- Integration with BalancerValidatorManager for P-Chain communication
- Epoch-based state transitions and cache management

---

## Architecture

### Security Module Integration

```mermaid
graph TD
    A[Middleware<br/>Security Module] -->|implements| B[ISecurityModule]
    A -->|initiates operations| C[BalancerValidatorManager]
    C -->|owns| D[ValidatorManager v2.1.0<br/>ICM]
    D -->|communicates with| E[P-Chain]
    
    A:::middleware
    C:::balancer
    D:::icm
    E:::pchain
    
    classDef middleware fill:#e1f5e1,stroke:#4caf50,stroke-width:2px
    classDef balancer fill:#e3f2fd,stroke:#2196f3,stroke-width:2px
    classDef icm fill:#fff3e0,stroke:#ff9800,stroke-width:2px
    classDef pchain fill:#f3e5f5,stroke:#9c27b0,stroke-width:2px
```

The middleware initiates validator operations (registration, removal, weight updates) through the balancer, which enforces weight limits and coordinates with ICM's ValidatorManager for P-Chain messaging.

### Collateral Classes

**Primary Collateral Class (ID: 1):**
- Usually the L1's native token
- Required for all validators
- Has min and max stake requirements
- Uses `WEIGHT_SCALE_FACTOR` for stake-to-weight conversion

**Secondary Collateral Classes (ID: 2+):**
- Additional assets (stablecoins, LSTs, etc.)
- Optional, configured per L1
- Only have min stake requirement (no max)
- Active/inactive state per class

**CollateralClassRegistry** manages:
- Asset grouping by class
- Stake requirements (min/max)
- Asset decimal validation (all assets in a class must have matching decimals)

---

## Roles & Actors

### Protocol Admin Roles

**DEFAULT_ADMIN_ROLE**
- **Actor**: Protocol owner/DAO
- **Responsibilities**: Grant/revoke roles, critical system administration
- **Key Actions**: Role management, system upgrades

**OPERATORS_MANAGER_ROLE**  
- **Actor**: Protocol admin or delegated manager
- **Responsibilities**: Manage operator lifecycle
- **Key Actions**: `registerOperator`, `enableOperator`, `disableOperator`, `removeOperator`

**COLLATERAL_CLASS_MANAGER_ROLE**
- **Actor**: Protocol admin or treasury manager
- **Responsibilities**: Configure collateral classes and assets
- **Key Actions**: Add/remove collateral classes, activate/deactivate secondary classes, manage assets

**VAULTS_MANAGER_ROLE** (MiddlewareVaultManager)
- **Actor**: Protocol admin or vault manager
- **Responsibilities**: Register vaults and set limits
- **Key Actions**: `registerVault`, `updateVaultMaxL1Limit`, `removeVault`

### Operator Roles

**Validator Operators**
- **Actor**: Entities running validators
- **Responsibilities**: Node management, stake maintenance
- **Requirements**: Must opt-in to L1 and balancer
- **Key Actions**: `addNode`, `removeNode`, `initializeValidatorStakeUpdate`

### Permissionless Actors

**Anyone (Public)**
- **Actor**: Any EVM address
- **Responsibilities**: Maintain system health and complete pending operations
- **Key Actions**:
  - `forceUpdateNodes(operator, limitStake)` - Force node weight updates for any operator during update window
  - `completeValidatorRegistration(messageIndex)` - Complete pending node registrations
  - `completeValidatorRemoval(messageIndex)` - Complete pending node removals  
  - `completeValidatorWeightUpdate(messageIndex)` - Complete pending weight updates
  - `calcAndCacheStakes(epoch, collateralClass)` - Calculate and cache total stakes for rewards
  - `calcAndCacheNodeStakeForAllOperators()` - Update node stake cache for current epoch
  - `manualProcessNodeStakeCache(numEpochsToProcess)` - Process pending epoch updates when automatic fails

**Benefits of Permissionless Functions**:
- **System Liveness**: Prevents any single actor from blocking critical operations
- **Keeper Integration**: Allows automated bots to maintain system health
- **Gas Management**: Community can help process expensive operations
- **Forced Rebalancing**: Ensures validators maintain proper weights even if operators are inactive

---

## Operator & Node Lifecycle

### Registration Flow

1. **Operator Registration**
   - Register in `OperatorRegistry`
   - Opt-in to L1 via `OperatorL1OptInService`
   - Opt-in to balancer via `OperatorVaultOptInService`
   - Middleware registers operator: `registerOperator(operator)`

2. **Node Addition**
   - Call `addNode(nodeId, weight)` by operator
   - Validates operator has sufficient free stake
   - Locks stake to prevent over-allocation
   - Initiates registration via balancer → ValidatorManager → P-Chain
   - Node enters "pending registration" state

3. **Registration Completion**
   - Anyone can call `completeValidatorRegistration(messageIndex)` (permissionless)
   - P-Chain acknowledgment required
   - Node becomes active
   - Returns `validationID`

### Node Operations

**Weight Updates:**
- Anyone can call `forceUpdateNodes(operator, limitStake)` during update window
- Recalculates weight based on current stake
- Locks/unlocks stake delta
- Initiates weight update via balancer
- Completion via `completeValidatorWeightUpdate(messageIndex)` (permissionless)

**Node Removal:**
- Operator calls `removeNode(nodeId)`
- Initiates removal via balancer
- Completion via `completeValidatorRemoval(messageIndex)` (permissionless)
- Unlocks operator's stake

---

## Stake Management

### Stake Calculation

For each operator across all collateral classes:

```
operatorTotalStake = min(
    Σ(vaultDelegations for collateral class), 
    securityModuleMaxWeight * WEIGHT_SCALE_FACTOR
)
operatorUsedStake = Σ(node stakes from cache)
operatorLockedStake = stake locked in pending node updates
operatorFreeStake = operatorTotalStake - operatorUsedStake - operatorLockedStake
```

**Stake Cache:**
- `operatorStakeCache[epoch][operator][collateralClass]` stores historical stake
- Updated during epoch transitions via `_calcAndCacheNodeStakeForOperatorAtEpoch`
- Used by rewards system for distribution

**Weight Scale Factor:**
- Converts stake amount to validator weight (uint64)
- Must satisfy: `ceil(maxStake / 2^64-1) ≤ factor ≤ minStake`
- Balances precision vs overflow protection

### Node Weight Calculation

```
nodeWeight = min(
    operatorStake / WEIGHT_SCALE_FACTOR,
    maxWeight (from BalancerValidatorManager security module limit)
)
```

Ensures:
- Weight fits in uint64
- Respects security module weight allocation
- Reflects actual available stake

---

## Epoch System

**Epochs provide:**
- Time boundaries for state transitions
- Historical stake snapshots
- Coordination with rewards distribution

**Epoch Flow:**

```mermaid
graph LR
    subgraph "Epoch N"
        A[Operators have nodes<br/>with weights from N-1]
        B[Mid-epoch changes:<br/>locked stake, pending flags]
        C[Update window:<br/>force node updates]
    end
    
    subgraph "Epoch N → N+1 Transition"
        D[Resolve pending<br/>registrations/removals]
        E[Update node<br/>stake cache]
        F[Unlock stake deltas<br/>from completed updates]
        G[Carry forward<br/>active nodes]
    end
    
    A --> B
    B --> C
    C --> D
    D --> E
    E --> F
    F --> G
    
    style A fill:#e3f2fd
    style B fill:#fff3e0
    style C fill:#ffebee
    style D fill:#e8f5e9
    style E fill:#f3e5f5
    style F fill:#fce4ec
    style G fill:#e1f5fe
```

**Node Stake Cache Updates:**
- Automatic during first operation in new epoch (if gas permits)
- Manual via `manualProcessNodeStakeCache(operators, epoch)` if automatic update would exceed gas limits
- Tracks last processed epoch: `lastGlobalNodeStakeUpdateEpoch`

---

## Time Windows

**Slashing Window:**
- Duration: `SLASHING_WINDOW` (e.g., 7 days)
- Prevents withdrawal during potential slashing period
- Must be ≥ epoch duration

**Update Window:**
- Duration: `UPDATE_WINDOW` (final portion of epoch)
- When anyone can call `forceUpdateNodes` for any operator
- Ensures nodes start next epoch with correct weights

**Epoch Duration:**
- Fixed period: `EPOCH_DURATION` (e.g., 24 hours)
- All epochs have same length
- Synchronized with rewards system

---

## Roles & Access Control

**DEFAULT_ADMIN_ROLE:**
- Grant/revoke other roles
- Critical admin functions

**OPERATORS_MANAGER_ROLE:**
- `registerOperator`, `enableOperator`, `disableOperator`, `removeOperator`
- Manage operator lifecycle

**COLLATERAL_CLASS_MANAGER_ROLE:**
- `addCollateralClass`, `removeCollateralClass`
- `activateSecondaryCollateralClass`, `deactivateSecondaryCollateralClass`
- `addAssetToClass`, `removeAssetFromClass`
- Manage collateral configuration

**VAULTS_MANAGER_ROLE:** (in MiddlewareVaultManager)
- `registerVault`, `updateVaultMaxL1Limit`, `removeVault`
- Manage vault registration and limits

---

## Key Functions

### Operator Management
- `registerOperator(operator)` - Register operator to middleware
- `enableOperator(operator)` - Enable disabled operator
- `disableOperator(operator)` - Temporarily disable operator
- `removeOperator(operator)` - Permanently remove operator

### Node Operations (Operator-callable)
- `addNode(nodeId, blsKey, remainingBalanceOwner, disableOwner, stakeAmount)` - Register new validator node. Validates canonical nodeId format (high 96 bits must be zero).
- `removeNode(nodeId)` - Remove validator node  
- `initializeValidatorStakeUpdate(nodeId, stakeAmount)` - Manually update a specific node's weight

### Completion Functions (Permissionless)
- `completeValidatorRegistration(messageIndex)` - Complete node registration
- `completeValidatorRemoval(messageIndex)` - Complete node removal. Also handles cleanup for expired/invalidated registrations.
- `completeValidatorWeightUpdate(messageIndex)` - Complete weight update

### Query Functions
- `getOperatorValidationIDs(operator)` - Returns all validationIDs ever registered by an operator (append-only, for historical uptime tracking)

### Collateral Management
- `addCollateralClass(classId, minStake, maxStake, asset)` - Create new collateral class
- `activateSecondaryCollateralClass(classId)` - Activate secondary class for use
- `deactivateSecondaryCollateralClass(classId)` - Deactivate secondary class
- `addAssetToClass(classId, asset)` - Add asset to collateral class
- `removeAssetFromClass(classId, asset)` - Remove asset from collateral class

### State Management
- `manualProcessNodeStakeCache(operators, epoch)` - Manually update node stake cache
- `calcAndCacheStakes(epoch, collateralClass)` - Cache total stake for epoch

---

## Storage Per Operator

**Per operator:**
- `operators[operator]` - Registration status, enabled/disabled
- `operatorNodes[operator]` - EnumerableSet of nodeIds (permanent record)
- `operatorNodesArray[operator]` - Array of nodeIds for iteration (cleaned up on epoch transitions)
- `operatorValidationIDsArray[operator]` - Append-only array of all validationIDs ever registered (for historical uptime)
- `operatorStakeCache[epoch][operator][collateralClass]` - Historical stake snapshots

**Per node:**
- `validationIdToOperator[validationId]` - Operator owner (private)
- `pendingRemovalValId[nodeId]` - ValidationID pending removal for this nodeId
- `nodePendingUpdate[validationId]` - Weight update pending flag
- `nodePendingRemoval[validationId]` - Removal pending flag

**Global:**
- `lastGlobalNodeStakeUpdateEpoch` - Last epoch with cache updates
- `collateralClasses` - Collateral class configurations
- `secondaryCollateralClasses` - Active secondary class IDs

---

## Invariants

- **Stake Lock**: `Σ(nodeWeights * WEIGHT_SCALE_FACTOR) + lockedStake ≤ operatorUsedStake`
- **Weight Bounds**: `nodeWeight ≤ maxWeight` (from security module allocation)
- **Collateral Decimals**: All assets in a class have identical decimals
- **Epoch Monotonicity**: Epochs only increase, never decrease
- **Node Uniqueness**: Each nodeId maps to exactly one operator
- **Pending State**: Node cannot be both pending update and pending removal

---

## Integration Points

**Upstream (Uses):**
- `IBalancerValidatorManager` - Validator operations and weight limits
- `IOperatorRegistry` - Operator registration verification
- `IOperatorL1OptInService` - L1 opt-in verification
- `IOperatorVaultOptInService` - Balancer opt-in verification

**Downstream (Used by):**
- `MiddlewareVaultManager` - Vault registration and limits
- `RewardsNativeToken` - Stake cache for reward distribution
- `UptimeTracker` - Node validation ID lookups

---

## Common Patterns

### Adding a Validator Node

1. Ensure operator has sufficient free stake
2. Call `addNode(nodeId, desiredWeight)`
3. Wait for P-Chain processing
4. Anyone calls `completeValidatorRegistration(messageIndex)`
5. Node is active with calculated weight

### Updating Stake Mid-Epoch

1. Vault deposits/withdrawals change operator's delegated stake
2. Stake is NOT immediately reflected in node weights
3. During update window: operator (or anyone) calls `forceUpdateNodes(operator, limitStake)`
4. Wait for P-Chain processing
5. Anyone calls `completeValidatorWeightUpdate(messageIndex)`
6. Next epoch begins with new weight

### Adding a Secondary Collateral Class

1. Call `addCollateralClass(classId, minStake, 0, initialAsset)`
2. Optionally `addAssetToClass(classId, otherAssets)` for multiple assets
3. Call `activateSecondaryCollateralClass(classId)`
4. Register vaults with this collateral class via `MiddlewareVaultManager`
5. Set reward share via `RewardsNativeToken.setRewardsShareForCollateralClass(classId, basisPoints)`

---

## Error Handling

**Common errors:**
- `AvalancheL1Middleware__OperatorNotRegistered` - Operator not registered in middleware
- `AvalancheL1Middleware__OperatorNotOptedIn` - Operator hasn't opted into L1 or balancer
- `AvalancheL1Middleware__InsufficientStake` - Not enough free stake for operation
- `AvalancheL1Middleware__InvalidWindow` - Operation outside allowed time window
- `AvalancheL1Middleware__NodePending` - Node has pending operation (includes pending removal, weight update, or re-add attempt with pending removal)
- `AvalancheL1Middleware__NodeNotFound` - Node doesn't exist or not owned by operator
- `AvalancheL1Middleware__InvalidNodeIdFormat` - NodeId has non-zero high 96 bits (not canonical format)
- `CollateralClassRegistry__AssetDecimalsMismatch` - Asset decimals don't match class

**Known edge case:**
- Calling `removeOperator` on an operator that was never disabled will cause an underflow panic in `getEpochAtTs(0)`. Always call `disableOperator` first, then wait for the grace period before calling `removeOperator`.

---

## Gas Optimizations

- Modifiers converted to internal functions (reduces bytecode size)
- `unchecked` blocks in loops where overflow impossible
- Node stake cache updates batched, with manual processing for large operator sets
- Stake queries use cached values when available

---

## Security Considerations

**Stake Locking:**
- Prevents over-allocation by locking stake during pending operations
- Ensures node weights never exceed available stake

**Permissionless Completion:**
- Anyone can complete validator operations after P-Chain acknowledgment
- Improves liveness, prevents operators from blocking state transitions
- Completion functions verify P-Chain response before state changes

**Decimal Validation:**
- Enforces identical decimals across collateral class assets
- Prevents calculation errors in stake aggregation

**Operator Opt-Ins:**
- Double opt-in required (L1 + balancer)
- Operators explicitly consent to validation duties
- Can opt-out to stop accepting new delegations

---

## Related Documentation

- [BalancerValidatorManager](../lib/suzaku-contracts-library/src/contracts/ValidatorManager/README.md) - Security module architecture
- [RewardsNativeToken](./5-rewardsNativeToken.md) - Stake cache usage in reward distribution
- [Protocol Overview](./1-overview.md) - Full protocol architecture
- [Post-Audit Updates](../post-audit-updates.md) - Recent changes and migrations
