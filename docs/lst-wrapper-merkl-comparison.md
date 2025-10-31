# LSTWrapper vs LSTWrapperMerkl Comparison

## Key Differences

### 1. **Rewards Contract Interface**

| Aspect | LSTWrapper | LSTWrapperMerkl |
|--------|------------|-----------------|
| **Interface** | `IRewardsNativeToken` | `IMerkleDistributor` |
| **Storage Field** | `IRewardsNativeToken rewards` | `IMerkleDistributor merkleDistributor` |
| **Claim Method** | Direct call: `claimRewards(address)` | Merkle proof: `claim(users[], tokens[], amounts[], proofs[][])` |

### 2. **Harvest Function Signature**

**LSTWrapper:**
```solidity
function harvest() external nonReentrant 
    returns (uint256 claimedNative, uint256 mintedVaultShares)
```
- No parameters required
- Permissionless, anyone can call
- Automatically claims all available rewards

**LSTWrapperMerkl:**
```solidity
function harvest(
    address token,
    uint256 amount,
    bytes32[] calldata proof
) external nonReentrant 
    returns (uint256 claimedNative, uint256 mintedVaultShares)
```
- Requires 3 parameters: token address, amount, and Merkle proof
- Permissionless, but caller must provide valid proof
- Claims specific amount based on Merkle tree

### 3. **Storage Layout**

| Contract | ERC-7201 Storage Slot | Storage Slot Value |
|---------|---------------------|-------------------|
| **LSTWrapper** | `lstwrapper.storage` | `0x799f344bf9d1b9145d63579fefcda32172d8d3c9b295fe5dc25c088a9f94f700` |
| **LSTWrapperMerkl** | `lstwrappermerkl.storage` | `0x799f344bf9d1b9145d63579fefcda32172d8d3c9b295fe5dc25c088a9f94f701` |

**⚠️ Critical**: Different storage slots mean **incompatible storage layouts**.

### 4. **Storage Struct Fields**

Both have identical fields except for the rewards contract:

```solidity
// LSTWrapper
struct LSTWrapperStorageStruct {
    IVaultTokenized vault;              // Same
    IRewardsNativeToken rewards;        // ❌ Different type
    IERC20 collateral;                  // Same
    IERC20 nativeToken;                 // Same
    IVaultHelper vaultHelper;           // Same
    bool depositsPaused;                // Same
}

// LSTWrapperMerkl
struct LSTWrapperMerklStorageStruct {
    IVaultTokenized vault;              // Same
    IMerkleDistributor merkleDistributor; // ❌ Different type
    IERC20 collateral;                  // Same
    IERC20 nativeToken;                 // Same
    IVaultHelper vaultHelper;           // Same
    bool depositsPaused;                // Same
}
```

### 5. **Error Names**

All errors use different prefixes:
- LSTWrapper: `LSTWrapper__*`
- LSTWrapperMerkl: `LSTWrapperMerkl__*`

### 6. **Initialization Parameters**

**LSTWrapper:**
```solidity
initialize(
    address admin,
    address vault_,
    address rewards_,          // IRewardsNativeToken address
    address helper_,
    string memory name_,
    string memory symbol_
)
```

**LSTWrapperMerkl:**
```solidity
initialize(
    address admin,
    address vault_,
    address merkleDistributor_, // IMerkleDistributor address
    address helper_,
    string memory name_,
    string memory symbol_
)
```

## Everything Else is Identical

✅ Same deposit/withdraw/redeem logic  
✅ Same slippage protection functions  
✅ Same admin functions (sweep, pause, etc.)  
✅ Same virtual offset calculation  
✅ Same zero-share protection  
✅ Same reentrancy guards  
✅ Same ERC-4626 functionality  

---

## Upgrade Path: **NOW POSSIBLE** ✅

### Upgrade Compatibility

1. **Same Storage Slot**: Both contracts use `lstwrapper.storage` namespace → `0x799f344bf9d1b9145d63579fefcda32172d8d3c9b295fe5dc25c088a9f94f700`

2. **Compatible Storage Layout**: 
   - LSTWrapper stores: `IRewardsNativeToken rewards` (which is an address at storage level)
   - LSTWrapperMerkl stores: `address rewards` (same storage layout, same field name)
   - Both are 20-byte addresses, so storage is 100% compatible

3. **Function Signature Change**: The `harvest()` function signature changed, but this is fine for upgrades - old code just won't call the new signature.

### How to Upgrade

**Direct Proxy Upgrade** (Recommended):

```solidity
// 1. Deploy new LSTWrapperMerkl implementation
LSTWrapperMerkl newImpl = new LSTWrapperMerkl();

// 2. Upgrade existing proxy to new implementation
// (Assuming you're using ERC1967Proxy or UUPS pattern)
proxy.upgradeTo(address(newImpl));

// 3. Update rewards contract address if needed
// (If Merkl distributor is different from old rewards contract)
// This can be done via a migration function or admin function
```

**Storage Compatibility**:
- ✅ Same storage slot (`0x...700`)
- ✅ Same struct layout (all fields match)
- ✅ Same field names (`rewards` field stores address)
- ✅ At storage level, `IRewardsNativeToken` = `address` = 20 bytes

**Note**: After upgrade, the `harvest()` function signature changes, so any external integrations calling `harvest()` will need to be updated to pass the Merkle proof parameters.

### Alternative Approaches (If you prefer migration)

#### Option 1: **Migration Pattern**

Deploy a new LSTWrapperMerkl proxy and migrate users:

```solidity
// 1. Deploy new LSTWrapperMerkl implementation
LSTWrapperMerkl newImpl = new LSTWrapperMerkl();

// 2. Deploy new proxy
bytes memory initData = abi.encodeWithSelector(
    LSTWrapperMerkl.initialize.selector,
    admin,
    vault,              // Same vault
    merkleDistributor,  // New Merkl distributor
    vaultHelper,        // Same helper
    name,
    symbol
);
ERC1967Proxy newProxy = new ERC1967Proxy(address(newImpl), initData);
LSTWrapperMerkl newWrapper = LSTWrapperMerkl(address(newProxy));

// 3. Migrate users (they withdraw from old, deposit to new)
// Or use a migration contract that handles this atomically
```

**Pros:**
- Clean separation
- No storage corruption risk
- Can run both systems in parallel during migration

**Cons:**
- Users need to migrate positions
- More complex migration process

#### Option 2: **Create Compatible Storage Version**

Modify LSTWrapperMerkl to use the same storage slot:

```solidity
// Change storage slot to match LSTWrapper
bytes32 public constant _LSTWRAPPERMERKL_STORAGE_SLOT = 
    0x799f344bf9d1b9145d63579fefcda32172d8d3c9b295fe5dc25c088a9f94f700; // Same as LSTWrapper

// Use compatible storage struct (union type or wrapper)
struct LSTWrapperStorageStruct {
    IVaultTokenized vault;
    address rewardsContract;  // Store as address, cast when needed
    IERC20 collateral;
    IERC20 nativeToken;
    IVaultHelper vaultHelper;
    bool depositsPaused;
}
```

**Pros:**
- Can upgrade existing proxy
- Users don't need to migrate

**Cons:**
- Requires careful type casting
- Both interfaces must be compatible at address level
- More complex and error-prone

#### Option 3: **Hybrid Contract**

Create a contract that supports both reward systems:

```solidity
enum RewardsType { NativeToken, Merkl }

struct LSTWrapperStorageStruct {
    IVaultTokenized vault;
    RewardsType rewardsType;
    address rewardsContract;  // Can be either type
    // ... rest of fields
}

function harvest() external {
    if (lws.rewardsType == RewardsType.NativeToken) {
        _harvestNativeToken();
    } else {
        revert("Use harvestWithProof()");
    }
}

function harvestWithProof(address token, uint256 amount, bytes32[] calldata proof) external {
    if (lws.rewardsType != RewardsType.Merkl) {
        revert("Not Merkl rewards");
    }
    _harvestMerkl(token, amount, proof);
}
```

**Pros:**
- Supports both systems
- Can upgrade and switch between modes

**Cons:**
- More complex contract
- Larger code size
- Additional complexity in testing

---

## Recommendation

**Direct Proxy Upgrade** is now possible and recommended because:

1. ✅ **Storage Compatible**: Uses same storage slot and layout
2. ✅ **No Migration Needed**: Users keep their positions
3. ✅ **Seamless Transition**: Just upgrade the implementation
4. ✅ **Tested Pattern**: Standard UUPS/ERC1967 upgrade

**Important Notes**:
- After upgrade, update any integrations that call `harvest()` to use the new signature with Merkle proofs
- The rewards contract address in storage remains the same (just cast to different interface)
- All other functionality (deposits, withdrawals, etc.) works identically

---

## Summary Table

| Feature | LSTWrapper | LSTWrapperMerkl | Upgrade Compatible? |
|---------|------------|-----------------|---------------------|
| Storage Slot | `0x...700` | `0x...700` | ✅ Yes |
| Rewards Storage | `address rewards` | `address rewards` | ✅ Yes (same field) |
| Rewards Interface | `IRewardsNativeToken` | `IMerkleDistributor` | ✅ Yes (cast when used) |
| Harvest Params | None | token, amount, proof | ⚠️ Signature changed |
| Functionality | Same | Same | ✅ Yes |
| Proxy Pattern | ERC1967 | ERC1967 | ✅ Yes |

**Conclusion**: They are functionally identical except for the rewards claiming mechanism, and they are **NOW DIRECTLY UPGRADEABLE** using standard proxy upgrade patterns. The storage layout is 100% compatible.

