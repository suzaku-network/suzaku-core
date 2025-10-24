# LSTWrapper - Liquid Staking Token Wrapper

The LSTWrapper is an ERC-4626 compliant auto-compounding yield wrapper for VaultTokenized shares, providing a liquid staking token experience with automated reward harvesting and reinvestment.

---

## Index

- [Overview](#overview)
- [Architecture](#architecture)
  - [ERC-4626 Compliance](#erc-4626-compliance)
  - [Auto-Compounding Mechanism](#auto-compounding-mechanism)
- [Key Features](#key-features)
  - [Permissionless Harvest](#permissionless-harvest)
  - [Donation Attack Protection](#donation-attack-protection)
  - [Slippage Protection](#slippage-protection)
- [Security Features](#security-features)
  - [Virtual Offset Protection](#virtual-offset-protection)
  - [Reentrancy Protection](#reentrancy-protection)
  - [Access Controls](#access-controls)
- [Functions](#functions)
  - [Core ERC-4626 Functions](#core-erc-4626-functions)
  - [Harvest Function](#harvest-function)
  - [Slippage-Protected Helpers](#slippage-protected-helpers)
  - [Admin Functions](#admin-functions)
- [Integration](#integration)
- [Security Considerations](#security-considerations)
- [Related Documentation](#related-documentation)

---

## Overview

**LSTWrapper** transforms VaultTokenized shares into a liquid staking token (LST) that automatically compounds rewards. Users deposit VaultTokenized shares and receive LSTWrapper tokens that appreciate in value as rewards are harvested and reinvested.

**Key Value Proposition:**
- **Set-and-forget staking**: No manual reward claiming or reinvestment required
- **Liquid staking token**: ERC-4626 compliant, composable with DeFi protocols
- **Auto-compounding**: Rewards automatically reinvested to increase token value
- **Permissionless harvest**: Anyone can trigger reward harvesting for the community

---

## Architecture

### ERC-4626 Compliance

LSTWrapper implements the ERC-4626 Tokenized Vault Standard:

- **Asset**: VaultTokenized shares (the underlying vault tokens)
- **Shares**: LSTWrapper tokens (the liquid staking tokens issued to users)
- **Exchange Rate**: Increases over time as rewards are harvested and reinvested

```
User Flow:
1. User deposits VaultTokenized shares → receives LSTWrapper tokens
2. Rewards accumulate in the underlying vault
3. Anyone calls harvest() → rewards converted to more VaultTokenized shares
4. LSTWrapper token value increases (more VaultTokenized shares per LSTWrapper token)
5. User redeems LSTWrapper tokens → receives more VaultTokenized shares than originally deposited
```

### Auto-Compounding Mechanism

The wrapper integrates with three core components:

1. **VaultTokenized**: The underlying vault that generates rewards
2. **Rewards Contract**: Distributes native token rewards to vault participants  
3. **VaultHelper**: Converts native tokens back to collateral and stakes in vault

**Harvest Process:**
```
1. Claim rewards (native tokens) from Rewards contract
2. Convert native tokens to collateral via VaultHelper
3. Deposit collateral into VaultTokenized to mint more shares
4. LSTWrapper now owns more VaultTokenized shares → increased value per token
```

---

## Key Features

### Permissionless Harvest

Anyone can call `harvest()` to trigger reward compounding:

- **Whitelist Gating**: If the underlying vault has deposit whitelist enabled:
  - Caller must be whitelisted as depositor
  - VaultHelper must be whitelisted as depositor
- **No Whitelist**: Completely permissionless if vault has no deposit restrictions
- **Incentive Alignment**: Community members can harvest to benefit all token holders

### Donation Attack Protection

Multiple layers protect against donation-based manipulation:

1. **Zero-Share Prevention**: `deposit()` and `mint()` revert if they would mint 0 shares
2. **Virtual Offset**: Conversion functions use virtual offset to prevent rate manipulation
3. **Asset Rescue**: Owner can recover donated assets only when `totalSupply() == 0`

### Slippage Protection

Four helper functions provide slippage bounds for ERC-4626 operations:

- `depositWithMinShares()`: Deposit with minimum shares guarantee
- `mintWithMaxAssets()`: Mint with maximum assets limit  
- `withdrawWithMaxShares()`: Withdraw with maximum shares limit
- `redeemWithMinAssets()`: Redeem with minimum assets guarantee

---

## Security Features

### Virtual Offset Protection

Prevents inflation attacks by adding virtual offset to conversion calculations:

```solidity
// Instead of: shares = assets * totalSupply() / totalAssets()
// Uses: shares = assets * (totalSupply() + offset) / (totalAssets() + offset)
```

- **Bounded Offset**: `10^decimals` capped at `10^36` to prevent overflow
- **Consistent Math**: Uses `Math.mulDiv` with proper rounding like OpenZeppelin
- **Preview Alignment**: Internal `_convert*` overrides ensure `convertTo*` matches `preview*`

### Reentrancy Protection

All state-changing functions protected with `nonReentrant`:

- Core ERC-4626: `deposit()`, `mint()`, `withdraw()`, `redeem()`
- Slippage helpers: All four slippage-protected functions
- Harvest: `harvest()` function
- Admin: All admin functions where applicable

### Access Controls

- **Owner-Only Functions**: 
  - `sweep()`: Sweep unexpected tokens (cannot sweep asset, collateral, or native token)
  - `sweepCollateralDust()`: Recover small collateral amounts with strict limits
  - `rescueAssetWhenNoSupply()`: Recover donated assets only when no shares exist
  - `setVaultHelper()`: Update the vault helper contract
- **Permissionless Functions**:
  - `harvest()`: Anyone can harvest (subject to vault whitelist rules)
  - All ERC-4626 functions: Standard deposit/withdraw/mint/redeem operations

---

## Functions

### Core ERC-4626 Functions

Standard ERC-4626 interface with security enhancements:

```solidity
// Enhanced with zero-share protection and deposit limit checks
function deposit(uint256 assets, address receiver) public returns (uint256 shares)
function mint(uint256 shares, address receiver) public returns (uint256 assets)

// Enhanced with reentrancy protection  
function withdraw(uint256 assets, address receiver, address owner) public returns (uint256 shares)
function redeem(uint256 shares, address receiver, address owner) public returns (uint256 assets)

// Virtual offset protection for accurate conversions
function convertToShares(uint256 assets) public view returns (uint256)
function convertToAssets(uint256 shares) public view returns (uint256)
```

### Harvest Function

```solidity
function harvest() external returns (uint256 claimedNative, uint256 mintedVaultShares)
```

**Process:**
1. Claims rewards from Rewards contract (catches and logs failures)
2. Calculates actual claimed amount via balance delta
3. Checks vault whitelist and deposit limits (only when depositing)
4. Converts native tokens to collateral and stakes via VaultHelper
5. Validates non-zero shares minted to prevent value loss
6. Emits `Harvest` event with claimed and minted amounts

### Slippage-Protected Helpers

```solidity
function depositWithMinShares(uint256 assets, uint256 minShares, address receiver) external returns (uint256 shares)
function mintWithMaxAssets(uint256 shares, uint256 maxAssets, address receiver) external returns (uint256 assets)  
function withdrawWithMaxShares(uint256 assets, uint256 maxShares, address receiver, address owner) external returns (uint256 shares)
function redeemWithMinAssets(uint256 shares, uint256 minAssets, address receiver, address owner) external returns (uint256 assets)
```

All revert with `LSTWrapper__SlippageProtection()` if bounds are violated.

### Admin Functions

```solidity
// Token management
function sweep(address token, address recipient, uint256 amount) external onlyOwner
function sweepCollateralDust(address recipient, uint256 amount) external onlyOwner  
function rescueAssetWhenNoSupply(address recipient, uint256 amount) external onlyOwner

// Configuration
function setVaultHelper(address helper_) external onlyOwner
function setDepositsPaused(bool paused) external onlyOwner
```

**Security Features:**
- **Dust Sweeping**: Dual cap `min(1 token unit, 0.0001% of balance)` with no unsafe fallbacks
- **Asset Rescue**: Only when `totalSupply() == 0` and deposits are paused (prevents front-run DoS)
- **Deposit Pause**: Owner can pause deposits/mints for emergency situations or rescue operations

---

## Integration

### Deployment Pattern

```solidity
// 1. Deploy implementation
LSTWrapper implementation = new LSTWrapper();

// 2. Prepare initialization data
bytes memory initData = abi.encodeWithSelector(
    LSTWrapper.initialize.selector,
    admin,           // Owner address
    vault,           // VaultTokenized address
    rewards,         // Rewards contract address  
    vaultHelper,     // VaultHelper address
    "Liquid Vault",  // ERC20 name
    "liqVAULT"      // ERC20 symbol
);

// 3. Deploy proxy
ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
LSTWrapper wrapper = LSTWrapper(address(proxy));
```

### Usage Patterns

```solidity
// Basic deposit/withdraw
uint256 shares = wrapper.deposit(1000e18, user);
uint256 assets = wrapper.redeem(shares, user, user);

// Slippage-protected operations
uint256 shares = wrapper.depositWithMinShares(1000e18, 950e18, user);
uint256 assets = wrapper.redeemWithMinAssets(shares, 1050e18, user, user);

// Community harvest
(uint256 claimed, uint256 minted) = wrapper.harvest();
```

---

## Security Considerations

### Attack Vectors Mitigated

1. **Donation Attacks**: Virtual offset + zero-share prevention + asset rescue
2. **Inflation Attacks**: Bounded virtual offset with overflow protection
3. **Reentrancy Attacks**: Comprehensive `nonReentrant` protection
4. **Owner Theft**: Cannot sweep asset, collateral, or native tokens
5. **Value Loss**: Zero shares protection prevents silent rounding losses
6. **Slippage Attacks**: Bounds checking on all operations

### Trust Assumptions

- **Owner Trust**: Can sweep unexpected tokens and update vault helper
- **VaultHelper Trust**: Handles native token conversion and vault deposits
- **Underlying Vault**: Must be legitimate VaultTokenized instance
- **Rewards Contract**: Must distribute rewards fairly

### Operational Security

- **Deposit Limits**: Respects underlying vault deposit limits
- **Whitelist Compliance**: Enforces vault depositor whitelist rules
- **Dust Limits**: Strict caps on collateral dust recovery
- **Emergency Controls**: Asset rescue only when no shares outstanding

---

## Architectural Inspirations

The LSTWrapper design builds upon established, battle-tested patterns from leading DeFi protocols:

- **Lido (wstETH)**: Core concept of wrapping yield-bearing tokens into **non-rebasing, exchange-rate-based tokens** for DeFi composability
- **Frax (sfrxETH) & Yearn V3**: **ERC-4626 auto-compounding vault** pattern where share price increases as rewards are harvested and reinvested
- **Yearn V3 Vaults**: **Virtual offset protection** to prevent donation-based inflation attacks on share price
- **Compound III (CometWrapper)**: ERC-4626 adapter pattern over complex underlying yield assets with clean, standardized interface

---

## Related Documentation

- [VaultTokenized](./vault.md) - Underlying vault mechanics
- [Rewards System](./rewards.md) - Reward distribution and claiming
- [Protocol Overview](./overview.md) - High-level architecture
- [Middleware](./middleware.md) - L1 validation orchestration

---

## Events

```solidity
// Core operations
event Harvest(address indexed caller, uint256 claimedNative, uint256 mintedVaultShares);
event Sweep(address indexed caller, address indexed token, address indexed recipient, uint256 amount);

// Admin operations  
event CollateralDustSwept(address indexed caller, address indexed recipient, uint256 amount);
event AssetRescued(address indexed recipient, uint256 amount);
event VaultHelperUpdated(address indexed helper);
event DepositsPaused(bool paused);

// Error conditions
event RewardsClaimFailed(bytes reason);
```

## Errors

```solidity
// Input validation
error LSTWrapper__ZeroAddress(string param);
error LSTWrapper__InvalidRecipient();
error LSTWrapper__InvalidVaultCollateral();
error LSTWrapper__InvalidRewardsToken();
error LSTWrapper__InvalidVaultHelper();

// Operation restrictions
error LSTWrapper__DepositRestricted();
error LSTWrapper__DepositLimitExceeded(uint256 headroom);
error LSTWrapper__ZeroSharesMinted();
error LSTWrapper__SlippageProtection();
error LSTWrapper__DepositsPaused();

// Admin restrictions
error LSTWrapper__CannotSweepAsset();
error LSTWrapper__CannotSweepCollateral();
error LSTWrapper__CannotSweepNativeToken();
error LSTWrapper__ExcessiveAmount();
error LSTWrapper__AssetRescueNotAllowed();
```
