# LSTWrapper & LSTWrapperMerkl - Liquid Staking Token Wrappers

ERC-4626 compliant auto-compounding yield wrappers for VaultTokenized shares, providing a liquid staking token experience with reward harvesting and reinvestment. Two implementations support different reward distribution mechanisms.

---

## Index

- [Overview](#overview)
- [Architecture](#architecture)
  - [ERC-4626 Compliance](#erc-4626-compliance)
  - [Auto-Compounding Mechanism](#auto-compounding-mechanism)
- [ILSTWrapper Interface](#ilstwrapper-interface)
  - [Implementation Differences](#implementation-differences)
  - [Upgrading Between Implementations](#upgrading-between-implementations)
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
  - [Initial Deployment Flow](#initial-deployment-flow)
  - [Deployment Pattern](#deployment-pattern)
  - [Upgrading Between Implementations](#upgrading-between-implementations)
  - [Usage Patterns](#usage-patterns)
- [Security Considerations](#security-considerations)
- [Related Documentation](#related-documentation)

---

## Overview

**LSTWrapper** transforms VaultTokenized shares into a liquid staking token (LST) that automatically compounds rewards. There are **two implementations** available:

1. **LSTWrapper** - For RewardsNativeToken (direct claims)
2. **LSTWrapperMerkl** - For Merkle Distributor rewards (proof-based claims)

Both implement the same `ILSTWrapper` interface and are **upgrade-compatible** with each other.

**Key Value Proposition:**
- **Set-and-forget staking**: No manual reward claiming or reinvestment required
- **Liquid staking token**: ERC-4626 compliant, composable with DeFi protocols
- **Auto-compounding**: Rewards automatically reinvested to increase token value
- **Permissionless harvest**: Anyone can trigger reward harvesting for the community
6- **Permissionless deployment**: Anyone can deploy wrappers from protocol-approved implementations

---

## Factory Architecture

**LSTWrapperFactory** enables permissionless deployment with protocol-controlled quality:

- **Protocol Owner**: Whitelists safe implementations (version control)
- **Anyone**: Can deploy wrappers from whitelisted implementations
- **Registry**: All deployed wrappers automatically registered
- **VaultHelper**: Checks a wrapper is in the factory registry before depositing

This pattern matches `VaultFactory` for consistency across the protocol.

> Registry membership is an *existence* check, not a safety attestation: anyone can deploy a wrapper (with an admin of their choosing) and it is registered automatically. Only route funds to the protocol's canonical wrapper(s); do not treat arbitrary registered wrappers as trusted.

**Benefits:**
- Users/integrators can deploy their own wrappers without permission
- Protocol maintains quality control via implementation whitelist
- VaultHelper only accepts factory-registered wrappers
- Version tracking enables upgrades and deprecation

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

The wrapper integrates with two core components:

1. **VaultTokenized**: The underlying vault that generates rewards
2. **Rewards Contract**: Distributes native token rewards to vault participants

**Harvest Process:**
```
1. Claim rewards (native tokens) from Rewards contract
2. Convert native tokens to collateral (inline via DefaultCollateral)
3. Deposit collateral into VaultTokenized to mint more shares
4. LSTWrapper now owns more VaultTokenized shares → increased value per token
```

The staking logic is handled inline within the LSTWrapper contract - no external helper contract needed.

---

## ILSTWrapper Interface

Both implementations share the same interface (`ILSTWrapper`) which includes:

- **ERC-4626 Standard**: Full tokenized vault functionality
- **Harvest Function**: `harvest(uint256 amount, bytes32[] calldata proof)`
- **Admin Functions**: sweep, pause, configuration updates
- **Slippage Protection**: deposit/mint/withdraw/redeem with bounds
- **View Functions**: vault(), rewards(), collateral(), nativeToken()

### Implementation Differences

| Feature | LSTWrapper | LSTWrapperMerkl |
|---------|------------|-----------------|
| **Rewards Source** | RewardsNativeToken | Merkle Distributor |
| **Harvest Parameters** | Ignores amount/proof | Requires valid proof |
| **Claim Method** | Direct `claimRewards()` | Merkle `claim()` with proof |
| **Storage Slot** | Same (`0x...700`) | Same (`0x...700`) |

### Upgrading Between Implementations

Since both contracts use the **same storage layout**:

1. **Direct Upgrade**: Use proxy upgrade to switch implementations
2. **No Migration**: Users keep their positions
3. **Update Integrations**: Harvest callers must provide proof params after upgrade

Example upgrade:
```solidity
// Deploy new implementation
LSTWrapperMerkl newImpl = new LSTWrapperMerkl();

// Upgrade proxy (ProxyAdmin only)
proxy.upgradeToAndCall(
    address(newImpl),
    abi.encodeCall(ILSTWrapper.setRewards, merkleDistributor)
);
```
---

## Key Features

### Permissionless Harvest

Anyone can call `harvest()` to trigger reward compounding:

- **Whitelist Gating**: If the underlying vault has deposit whitelist enabled:
  - The LSTWrapper contract itself must be whitelisted as depositor
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
  - `setDepositsPaused()`: Pause or unpause deposits for emergency response
  - **First Mint Privilege**: Owner can deposit even when paused (for initial seed)
- **ProxyAdmin-Only Functions** (via upgradeAndCall):
  - `setRewards()`: Update the rewards contract address
  - Contract implementation upgrades
- **Permissionless Functions**:
  - `harvest()`: Anyone can harvest (subject to vault whitelist rules)
  - All ERC-4626 functions: Standard deposit/withdraw/mint/redeem operations
  - All view functions and getters

### Roles and Access Control

LSTWrapper has two roles:

#### **Owner**
Can do:
- Pause/unpause deposits (`setDepositsPaused`)
- Sweep non-critical tokens (`sweep`) - but NOT the vault shares, collateral, or native token
- Sweep tiny amounts of collateral dust (`sweepCollateralDust`) - max 0.0001% of balance
- Rescue vault shares when totalSupply == 0 (`rescueAssetWhenNoSupply`)
- Perform first mint even when paused

#### **ProxyAdmin** 
Can do (only via upgradeAndCall):
- Update rewards contract address (`setRewards`) 
- Upgrade the implementation contract

**Why ProxyAdmin instead of Owner for `setRewards`?**

These functions require ProxyAdmin (not Owner) because they control critical infrastructure that could be exploited to steal funds:

- **`setRewards`**: If compromised, owner could point to a malicious rewards contract

By requiring the same authority as contract upgrades (ProxyAdmin), these changes get the same security level. The ProxyAdmin should be a multisig or timelock for production deployments. The owner handles day-to-day operations (pausing, sweeping dust) but cannot modify the core infrastructure. This separation of powers prevents a compromised owner key from stealing user funds.

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

// Deposit availability checks
function maxDeposit(address) public view returns (uint256) // Returns 0 when paused or totalSupply == 0
function maxMint(address) public view returns (uint256) // Returns 0 when paused or totalSupply == 0
```

### Harvest Function

```solidity
function harvest(uint256 amount, bytes32[] calldata proof) external returns (uint256 claimedNative, uint256 mintedVaultShares)
```

**Implementation Notes**: 
- **LSTWrapper**: Ignores `amount` and `proof` parameters, claims all available rewards
- **LSTWrapperMerkl**: Requires valid `amount` and `proof` from Merkle tree

**Process:**
1. Claims rewards from Rewards contract (catches and logs failures)
2. Calculates actual claimed amount via balance delta
3. Checks vault whitelist and deposit limits (only when depositing)
4. Converts native tokens to collateral (inline via DefaultCollateral.deposit())
5. Stakes collateral in vault (inline via VaultTokenized.deposit())
6. Validates non-zero shares minted to prevent value loss
7. Emits `Harvest` event with claimed and minted amounts

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
// Token management (Owner only)
function sweep(address token, address recipient, uint256 amount) external onlyOwner
function sweepCollateralDust(address recipient, uint256 amount) external onlyOwner  
function rescueAssetWhenNoSupply(address recipient, uint256 amount) external onlyOwner
function setDepositsPaused(bool paused) external onlyOwner

// Configuration (ProxyAdmin only via upgradeAndCall)
function setRewards(address rewards_) external
```

**Security Features:**
- **Dust Sweeping**: Dual cap `min(1 token unit, 0.0001% of balance)` with no unsafe fallbacks
- **Asset Rescue**: Only when `totalSupply() == 0` and deposits are paused (prevents front-run DoS)
- **Deposit Pause**: Owner can pause deposits/mints for emergency situations or rescue operations

---

## Integration

### Initial Deployment Flow

1. Contract deploys with `depositsPaused = true`
2. Only owner can perform first mint (when `totalSupply == 0`)
3. Owner seeds the vault with initial deposit **while still paused**
   - The contract allows: `depositsPaused && isFirstMint && msg.sender == owner()`
   - Deposits remain paused after this initial mint
4. Owner must manually call `setDepositsPaused(false)` to open public deposits
5. Regular users can now deposit/mint

### Deployment Pattern

**Step 1: Deploy LSTWrapperFactory (Protocol Owner)**

The factory must be deployed once per protocol:

```solidity
LSTWrapperFactory factory = new LSTWrapperFactory(protocolOwner);
```

**Step 2: Whitelist Implementations (Protocol Owner)**

Whitelist approved LSTWrapper implementations:

```solidity
// Whitelist LSTWrapper
LSTWrapper impl1 = new LSTWrapper();
factory.whitelist(address(impl1));  // Creates version 1

// Whitelist LSTWrapperMerkl
LSTWrapperMerkl impl2 = new LSTWrapperMerkl();
factory.whitelist(address(impl2));  // Creates version 2
```

**Step 3: Deploy VaultHelper**

VaultHelper requires both factories:

```solidity
VaultHelper helper = new VaultHelper(
    address(vaultFactory),
    address(lstWrapperFactory)  // Required
);
```

**Step 4: Permissionless Wrapper Deployment**

Anyone can deploy wrappers from whitelisted implementations:

```solidity
address wrapper = factory.create(
    1,                          // version (1 = LSTWrapper, 2 = LSTWrapperMerkl)
    admin,                      // admin (owner and ProxyAdmin)
    vault,                      // VaultTokenized to wrap
    rewards,                    // RewardsNativeToken or Merkle Distributor
    "Liquid Staking Token",     // name
    "LST"                       // symbol
);
// Wrapper is automatically registered in factory
```

**Using Deployment Scripts:**

Scripts provide helper functions for complex deployments (see `script/vault/LSTWrapperDeploy.s.sol` and `script/deploy/anvil/FullLocalDeploymentScript.s.sol`).

**Important Security Note**: The `admin` parameter becomes BOTH:
- The contract owner (operational control)
- The ProxyAdmin (upgrade control)

This is convenient for testing but **NOT recommended for production**. Instead:
1. Deploy with a temporary admin address
2. Transfer ProxyAdmin to a high-security multisig/DAO (via `ProxyAdmin.transferOwnership`)
3. Transfer contract ownership to operational multisig (via `LSTWrapper.transferOwnership`)

### Upgrading Between Implementations

Since both contracts share the same storage layout, you can upgrade between implementations using the unified upgrade script.

Create an upgrade configuration:
```json
// configs/lstwrapper-upgrade.json
{
  "newImplementation": "LSTWrapperMerkl",   // Target implementation type
  "proxyAddress": "0x1234...",              // Existing proxy address
  "newRewards": "0x5678..."                 // New rewards contract address
}
```

Run the upgrade:
```bash
forge script script/vault/LSTWrapperUpgrade.s.sol:UpgradeLSTWrapper \
  --sig "run(string)" "lstwrapper-upgrade.json" \
  --broadcast \
  --rpc-url $RPC_URL \
  --private-key $PROXY_ADMIN_KEY \
  --verify
```

**Examples:**

To upgrade from LSTWrapper to LSTWrapperMerkl:
```json
{
  "newImplementation": "LSTWrapperMerkl",
  "proxyAddress": "0x1234...",
  "newRewards": "0x5678..."    // Merkle Distributor address
}
```

To downgrade from LSTWrapperMerkl to LSTWrapper:
```json
{
  "newImplementation": "LSTWrapper",
  "proxyAddress": "0x1234...",
  "newRewards": "0xABCD..."    // RewardsNativeToken address
}
```

The script will:
1. Deploy the new implementation contract
2. Upgrade the proxy to point to it
3. Update the rewards contract address
4. Verify the upgrade succeeded

**Note**: This script must be run by the ProxyAdmin owner.

**Important Upgrade Considerations:**
- Users keep their positions (no migration needed)
- Storage layout is preserved
- After upgrading to Merkl, harvest callers must provide valid Merkle proofs
- Consider pausing deposits during upgrade for safety
- Test the upgrade on testnet first

### Usage Patterns

```solidity
// Basic deposit/withdraw
uint256 shares = wrapper.deposit(1000e18, user);
uint256 assets = wrapper.redeem(shares, user, user);

// Slippage-protected operations
uint256 shares = wrapper.depositWithMinShares(1000e18, 950e18, user);
uint256 assets = wrapper.redeemWithMinAssets(shares, 1050e18, user, user);

// Community harvest
// For LSTWrapper (ignores params):
(uint256 claimed, uint256 minted) = wrapper.harvest(0, new bytes32[](0));

// For LSTWrapperMerkl (requires valid proof):
(uint256 claimed, uint256 minted) = wrapper.harvest(claimAmount, merkleProof);
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

- **Owner Trust**: Can pause deposits and sweep unexpected tokens (but not critical ones)
- **ProxyAdmin Trust**: Can upgrade contract and update rewards contract address
- **Underlying Vault**: Must be legitimate VaultTokenized instance with valid DefaultCollateral
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

- [LSTWrapper vs LSTWrapperMerkl Comparison](./lst-wrapper-merkl-comparison.md) - Detailed technical comparison
- [VaultTokenized](./3-vault.md) - Underlying vault mechanics
- [Rewards System](./5-rewardsNativeToken.md) - RewardsNativeToken distribution
- [RewardsNativeToken](./5-rewardsNativeToken.md) - Native token rewards (used by LSTWrapper)
- [Protocol Overview](./1-overview.md) - High-level architecture
- [Middleware](./4-middleware.md) - L1 validation orchestration

---

## Events

```solidity
// Core operations
event Harvest(address indexed caller, uint256 claimedNative, uint256 mintedVaultShares);
event Sweep(address indexed caller, address indexed token, address indexed recipient, uint256 amount);

// Admin operations  
event CollateralDustSwept(address indexed caller, address indexed recipient, uint256 amount);
event AssetRescued(address indexed recipient, uint256 amount);
event RewardsUpdated(address indexed rewards);
event DepositsPaused(bool paused);

// Error conditions
event RewardsClaimFailed(bytes reason);
```

## Errors

Both implementations use the same error names with different prefixes:
- **LSTWrapper**: `LSTWrapper__*`
- **LSTWrapperMerkl**: `LSTWrapperMerkl__*`

```solidity
// Input validation (showing LSTWrapper prefix)
error LSTWrapper__ZeroAddress(string param);
error LSTWrapper__InvalidRecipient();
error LSTWrapper__InvalidVaultCollateral();
error LSTWrapper__InvalidRewardsToken();

// Operation restrictions
error LSTWrapper__DepositRestricted();
error LSTWrapper__DepositLimitExceeded(uint256 headroom);
error LSTWrapper__ZeroSharesMinted();
error LSTWrapper__SlippageProtection();
error LSTWrapper__DepositsPaused();
error LSTWrapper__OnlyOwnerFirstMint();

// Admin restrictions
error LSTWrapper__CannotSweepAsset();
error LSTWrapper__CannotSweepCollateral();
error LSTWrapper__CannotSweepNativeToken();
error LSTWrapper__ExcessiveAmount();
error LSTWrapper__AssetRescueNotAllowed();
```
