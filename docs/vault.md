# VaultTokenized Documentation

## Overview

VaultTokenized is the core collateral management layer of Suzaku. It handles the crucial aspects of the restaking economy:

- **Accounting**: Manages deposits, withdrawals, and collateral tracking with epoch-based withdrawal delays
- **Delegation Integration**: Works with delegator contracts to enable restaking strategies across L1s and operators
- **Reward Distribution**: Facilitates staking rewards distribution from L1s to collateral depositors
- **Access Control**: Role-based permissions for deposits, withdrawals, and vault configuration

Vaults are deployed via the VaultFactory as upgradeable proxies, allowing curators to create differentiated restaking products:

- **Operator-Specific Vaults**: Operators create vaults with collateral restaked to their infrastructure across multiple L1s
- **Curated Multi-Operator Vaults**: Curated configurations with delegation strategies to diversified operator sets
- **Controlled Access Vaults**: Vaults with deposit whitelists and limits for institutional or specialized use cases

## Architecture

Each vault has a predefined collateral token (ERC20) obtained via the `collateral()` method. All operations and accounting are performed with this collateral token, though rewards can be distributed in different tokens. The vault uses a shares-based accounting system internally while exposing absolute amounts for external interactions.

The VaultTokenized contract consists of three main components:

1. **Accounting & Shares Management**
2. **Epoch-Based Withdrawals**
3. **Access Control & Limits**

### Key Differences from Symbiotic

- **No Slashing**: Suzaku currently does not implement slashing on principal, only validation rewards can be lost
- **Unified Contract**: Single VaultTokenized implementation rather than separate vault types
- **Role-Based Access**: Granular permission system for vault operations
- **Checkpointing**: Historical balance tracking for reward distribution and voting

## Epoch System

The epoch system provides time boundaries for operations and ensures stake stability:

- Epochs are consecutive and have equal duration defined by `EPOCH_DURATION`
- Current epoch is calculated as: `block.timestamp / EPOCH_DURATION`
- Withdrawal delays ensure collateral remains stable during validation periods

### Definitions

- **Active Balance**: Collateral available for delegation that is not in withdrawal process
- **Epoch**: Current epoch number
- **W[epoch]**: Withdrawals that will be claimable in epoch+1

### Constraints

- `totalSupply = active + W[epoch] + W[epoch+1]` - Total collateral in the vault

During withdrawal:
1. `active → active - amount`
2. `W[epoch+1] → W[epoch+1] + amount`

During deposit:
1. `active → active + amount`

- For all k > 0, W[epoch-k] is claimable
- For all k ≥ 0, W[epoch+k] is not yet claimable

## Core Operations

### Deposits

Any holder of the collateral token can deposit using the `deposit()` method:

```solidity
function deposit(address onBehalfOf, uint256 amount) external returns (uint256 shares)
```

- Instantly increases the active balance
- Mints shares to the specified recipient
- Subject to deposit limits and whitelist restrictions if enabled
- Emits `Deposit` event

### Withdrawals

Withdrawals follow a two-phase process: **request** and **claim**

#### Withdraw Request
```solidity
function withdraw(address claimer, uint256 amount) external returns (uint256 burnedShares, uint256 mintedShares)
```

- User requests withdrawal at epoch N
- Amount is immediately deducted from active balance
- Burns active shares and mints epoch withdrawal shares
- Withdrawal becomes claimable when epoch N+1 ends

#### Claim Withdrawal
```solidity
function claimBatch(address claimer, uint256[] calldata epochs) external returns (uint256 amount)
```

- Claims withdrawals from completed epochs
- Withdrawal delay varies from EPOCH_DURATION+1 to 2×EPOCH_DURATION
- Once claimable, funds cannot be affected by any vault operations

### Checkpointing

The vault maintains historical records of balances and shares:

```solidity
function activeBalanceOfAt(address account, uint48 timestamp, bytes calldata hints) 
    external view returns (uint256)

function activeSharesOfAt(address account, uint48 timestamp, bytes calldata hints) 
    external view returns (uint256)
```

These functions enable:
- Historical stake queries for reward calculations
- Voting power snapshots
- Delegation tracking at specific timestamps

## Access Control

### Roles

**DEFAULT_ADMIN_ROLE**
- Manages other roles
- Critical vault administration

**DEPOSIT_WHITELIST_SET_ROLE**
- Enable/disable deposit whitelist
- Set whitelist requirements

**DEPOSITOR_WHITELIST_ROLE**
- Add/remove addresses from deposit whitelist
- Manage approved depositors

**IS_DEPOSIT_LIMIT_SET_ROLE**
- Enable/disable deposit limits
- Configure maximum vault capacity

### Configuration Functions

```solidity
function setDepositWhitelist(bool status) external onlyRole(DEPOSIT_WHITELIST_SET_ROLE)
function setDepositorWhitelistStatus(address account, bool status) external onlyRole(DEPOSITOR_WHITELIST_ROLE)
function setDepositLimit(uint256 limit) external onlyRole(DEFAULT_ADMIN_ROLE)
function setIsDepositLimit(bool status) external onlyRole(IS_DEPOSIT_LIMIT_SET_ROLE)
```

## Integration with Delegators

Vaults work with delegator contracts to manage stake allocation:

1. **Vault deposits** increase available collateral
2. **Delegators** allocate this collateral to operators across L1s
3. **Operators** must opt into both vaults and L1s
4. **L1s** query delegators for operator stake guarantees

The delegation flow:
```
Vault (collateral) → Delegator (allocation) → Operator (validation) → L1 (security)
```

## Upgrade Mechanism

VaultTokenized is deployed as an upgradeable proxy:

1. **Factory as Proxy Admin**: Only VaultFactory can upgrade implementations
2. **Versioned Migrations**: Uses OpenZeppelin's `reinitializer` pattern
3. **Migration Function**: `migrate(uint64 newVersion, bytes calldata data)` handles upgrades

Example upgrade process:
```solidity
// Factory upgrades proxy to new implementation
factory.upgrade(vault, newImplementation);

// Vault migration is called with new version
vault.migrate(2, migrationData);
```

## Events

Key events emitted by the vault:

```solidity
event Deposit(address indexed depositor, address indexed onBehalfOf, uint256 amount, uint256 shares)
event Withdraw(address indexed withdrawer, address indexed claimer, uint256 amount, uint256 burnedShares, uint256 mintedShares)
event Claim(address indexed claimer, address indexed recipient, uint256 epoch, uint256 amount)
event DepositLimitSet(uint256 limit)
event IsDepositLimitSet(bool status)
event DepositWhitelistSet(bool status)
event DepositorWhitelistStatusSet(address indexed account, bool status)
```

## Security Considerations

### Withdrawal Delays
- Two-epoch delay ensures stake stability during validation
- Prevents gaming of reward distributions
- Protects against rapid stake changes affecting L1 security

### Access Control
- Role-based permissions prevent unauthorized changes
- Whitelist and limits protect against spam or attacks
- Admin functions have appropriate access restrictions

### Checkpointing
- Historical data cannot be manipulated retroactively
- Enables secure reward distribution based on past stakes
- Supports governance and voting mechanisms

## Gas Optimizations

- Batch claim functionality reduces transaction costs
- Checkpoint hints enable efficient historical queries
- Share-based accounting minimizes rounding errors
- Efficient epoch calculation using bit shifts

## Common Integration Patterns

### For Stakers
```solidity
// Deposit collateral
vault.deposit(myAddress, amount);

// Request withdrawal
vault.withdraw(myAddress, amount);

// Check claimable epochs and claim
uint256 claimable = vault.withdrawableOf(myAddress, currentEpoch - 1);
if (claimable > 0) {
    vault.claim(myAddress, currentEpoch - 1);
}
```

### For Curators
```solidity
// Enable whitelist for controlled access
vault.setDepositWhitelist(true);

// Add approved depositors
vault.setDepositorWhitelistStatus(approvedAddress, true);

// Set deposit cap
vault.setIsDepositLimit(true);
vault.setDepositLimit(maxCapacity);
```

### For Integrators
```solidity
// Query historical stake for rewards
uint256 stakeAtSnapshot = vault.activeBalanceOfAt(user, snapshotTime, "");

// Get current active balance
uint256 currentStake = vault.activeBalanceOf(user);

// Check total vault TVL
uint256 tvl = vault.totalSupply();
```

## Related Documentation

- [Protocol Overview](./overview.md) - Complete protocol architecture
- [Delegator Documentation](./overview.md#delegators-owner-curator) - Stake allocation mechanics
- [Middleware Documentation](./middleware.md) - Validator management integration
