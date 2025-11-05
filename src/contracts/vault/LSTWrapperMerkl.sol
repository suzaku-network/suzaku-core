// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {ERC4626Upgradeable, IERC4626} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IVaultTokenized} from "../../interfaces/vault/IVaultTokenized.sol";
import {ILSTWrapper} from "../../interfaces/vault/ILSTWrapper.sol";
import {IMerkleDistributor} from "../../interfaces/rewards/IMerkleDistributor.sol";
import {IVaultHelper} from "../../interfaces/IVaultHelper.sol";
import {ICollateral} from "../../interfaces/ICollateral.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

/**
 * @title LSTWrapperMerkl
 * @notice An upgradeable ERC-4626 non-rebasing yield wrapper for VaultTokenized shares, integrated with Merkl rewards.
 * @dev Users deposit VaultTokenized shares (asset). The wrapper claims rewards from Merkl Distributor
 * using Merkle proofs and auto-compounds them back into the underlying VaultTokenized instance,
 * increasing the value per share (PPS) of this LSTWrapperMerkl token over time.
 * @dev Implements ILSTWrapper for upgrade compatibility - old harvest() signature reverts with error.
 */
contract LSTWrapperMerkl is
    Initializable,
    ERC4626Upgradeable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable,
    ILSTWrapper  // Implement ILSTWrapper for upgrade compatibility
{
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:lstwrapper.storage
    /// @notice Uses same storage slot as LSTWrapper for upgrade compatibility
    /// @dev Field name 'rewards' matches LSTWrapper exactly for storage compatibility.
    ///      At storage level, IRewardsNativeToken is just an address, so we can cast to IMerkleDistributor.
    struct LSTWrapperStorageStruct {
        /// @notice The underlying VaultTokenized contract instance being wrapped. Its shares are the asset.
        IVaultTokenized vault;
        /// @notice The rewards contract - can be IRewardsNativeToken or IMerkleDistributor (both are addresses at storage level)
        address rewards; // Same field name as LSTWrapper for storage compatibility
        /// @notice The collateral token used by the vault.
        IERC20 collateral;
        /// @notice The native token (underlying of collateral) paid by rewards contract.
        IERC20 nativeToken;
        /// @notice Helper used for native->collateral conversion and staking.
        IVaultHelper vaultHelper;
        bool depositsPaused;
    }

    // bytes32(uint256(keccak256(abi.encodePacked(uint256(keccak256("lstwrapper.storage")) - 1))) & ~uint256(0xff));
    bytes32 public constant _LSTWRAPPER_STORAGE_SLOT = 0x799f344bf9d1b9145d63579fefcda32172d8d3c9b295fe5dc25c088a9f94f700;

    constructor() {
        _disableInitializers(); // Required for upgradeable contracts
    }

    /**
     * @notice Initializes the LST Wrapper contract for Merkl.
     * @param admin The initial owner and admin of this wrapper.
     * @param vault_ Address of the specific VaultTokenized instance to wrap.
     * @param merkleDistributor_ Address of the Merkl Distributor contract.
     * @param helper_ Address of the VaultHelper to use.
     * @param name_ ERC20 name for this new LST wrapper token.
     * @param symbol_ ERC20 symbol for this new LST wrapper token.
     */
    function initialize(
        address admin,
        address vault_,
        address merkleDistributor_,
        address helper_,
        string memory name_,
        string memory symbol_
    ) external initializer {
        // Input Validation (using ILSTWrapper error names for compatibility)
        if (admin == address(0)) revert LSTWrapper__ZeroAddress("admin");
        if (vault_ == address(0)) revert LSTWrapper__ZeroAddress("vault");
        if (merkleDistributor_ == address(0)) revert LSTWrapper__ZeroAddress("rewards");
        if (helper_ == address(0)) revert LSTWrapper__InvalidVaultHelper();

        // Initialize Inherited Contracts
        __ERC20_init(name_, symbol_); // name/symbol for this wrapper token
        __ERC4626_init(IERC20(vault_)); // set VaultTokenized shares as asset
        __ReentrancyGuard_init();
        __Ownable_init(admin); // Initialize OwnableUpgradeable with the admin address

        // Set State Variables
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        lws.vault = IVaultTokenized(vault_);
        lws.rewards = merkleDistributor_; // Store as address (compatible with IRewardsNativeToken storage layout)

        // Determine the collateral token
        address collateralAddr = lws.vault.collateral();
        if (collateralAddr == address(0)) revert LSTWrapper__InvalidVaultCollateral();
        
        // Determine the native token from collateral
        address nativeTokenAddr = ICollateral(collateralAddr).asset();
        if (nativeTokenAddr == address(0)) revert LSTWrapper__InvalidRewardsToken();
        
        lws.collateral = IERC20(collateralAddr);
        lws.nativeToken = IERC20(nativeTokenAddr);
        lws.vaultHelper = IVaultHelper(helper_);
        // Start paused
        lws.depositsPaused = true;
        // No infinite approvals; per‑harvest allowances only.
    }

    /**
     * @inheritdoc ILSTWrapper
     */
    function vault() external view returns (address) {
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        return address(lws.vault);
    }

    /**
     * @inheritdoc ILSTWrapper
     * @dev Returns the Merkl Distributor address (same as rewards() for compatibility)
     */
    function rewards() external view returns (address) {
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        return lws.rewards;
    }

    /**
     * @notice Get the Merkl Distributor contract (alias for rewards() for clarity)
     * @return address of the Merkl Distributor contract
     */
    function merkleDistributor() external view returns (address) {
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        return lws.rewards;
    }
    
    /**
     * @inheritdoc ILSTWrapper
     */
    function collateral() external view returns (address collateral_) {
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        collateral_ = address(lws.collateral);
    }

    /**
     * @inheritdoc ILSTWrapper
     */
    function nativeToken() external view returns (address token) {
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        token = address(lws.nativeToken);
    }

    /**
     * @inheritdoc ILSTWrapper
     */
    function vaultHelper() external view returns (address helper) {
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        helper = address(lws.vaultHelper);
    }

    /**
     * @inheritdoc ILSTWrapper
     * @dev Old harvest() signature - reverts with error directing to new signature
     */
    function harvest() external pure returns (uint256, uint256) {
        revert LSTWrapper__HarvestSignatureChanged();
    }

    /**
     * @notice Harvest rewards from Merkl using Merkle proofs and reinvest into the vault.
     * @dev Claims rewards from Merkl Distributor using Merkle proofs and reinvests them.
     * @param token Address of the reward token to claim (must match nativeToken)
     * @param amount Amount of tokens to claim according to the Merkle tree
     * @param proof Merkle proof for the claim
     * @return claimedNative amount of native token claimed from rewards
     * @return mintedVaultShares amount of vault shares minted from reinvestment
     */
    function harvest(
        address token,
        uint256 amount,
        bytes32[] calldata proof
    ) external nonReentrant returns (uint256 claimedNative, uint256 mintedVaultShares) {
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        IMerkleDistributor distributor = IMerkleDistributor(lws.rewards); // Cast address to interface

        // Validate token matches expected native token
        address nativeTokenAddr = address(lws.nativeToken);
        if (token != nativeTokenAddr) revert LSTWrapper__InvalidRewardsToken();
        
        // Track balance before claim to compute actual claimed amount
        uint256 nativeBalanceBefore = lws.nativeToken.balanceOf(address(this));
        
        // Claim rewards from Merkl Distributor using Merkle proof
        // Merkl requires: users[], tokens[], amounts[], proofs[][]
        address[] memory users = new address[](1);
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](1);
        
        users[0] = address(this);
        tokens[0] = token;
        amounts[0] = amount;
        proofs[0] = proof;
        
        // Claim rewards (native token). Propagate errors from distributor.
        try distributor.claim(users, tokens, amounts, proofs) { }
        catch (bytes memory reason) {
            assembly { revert(add(32, reason), mload(reason)) }
        }

        // Calculate actual claimed amount as the delta
        uint256 nativeBalanceAfter = lws.nativeToken.balanceOf(address(this));
        claimedNative = nativeBalanceAfter - nativeBalanceBefore;
        
        // Use total balance for processing (includes any pre-existing dust)
        uint256 totalNativeBalance = nativeBalanceAfter;
        if (totalNativeBalance == 0) {
            emit Harvest(msg.sender, 0, 0);
            return (0, 0);
        }

        // Gate by underlying vault whitelist only when depositing
        if (lws.vault.depositWhitelist()) {
            if (!lws.vault.isDepositorWhitelisted(msg.sender)) revert LSTWrapper__DepositRestricted();
            if (!lws.vault.isDepositorWhitelisted(address(lws.vaultHelper))) revert LSTWrapper__DepositRestricted();
        }
        // Deposit limit check only when depositing
        if (lws.vault.isDepositLimit()) {
            uint256 active  = lws.vault.activeStake();
            uint256 limit   = lws.vault.depositLimit();
            if (active >= limit) revert LSTWrapper__DepositLimitExceeded(0);
        }

        // Approve helper to pull native token exactly once (use total balance to include dust)
        lws.nativeToken.forceApprove(address(lws.vaultHelper), 0);
        lws.nativeToken.forceApprove(address(lws.vaultHelper), totalNativeBalance);
        (, mintedVaultShares) = lws.vaultHelper.stakeAssetInVault(
            address(lws.vault),
            address(this),
            address(lws.collateral),
            nativeTokenAddr,
            totalNativeBalance
        );
        // Prevent silent value loss on rounding
        if (mintedVaultShares == 0) revert LSTWrapper__ZeroSharesMinted();
        lws.nativeToken.forceApprove(address(lws.vaultHelper), 0);
        emit Harvest(msg.sender, claimedNative, mintedVaultShares);

        return (claimedNative, mintedVaultShares);
    }

    /**
     * @notice Deposit assets into the vault with zero-share protection.
     * @dev Overrides ERC4626 to prevent zero-share mints from donation attacks.
     * @dev Also reverts if deposits are paused (except owner-only first mint) or if the first mint is attempted by a non-owner.
     * @param assets Amount of assets to deposit
     * @param receiver Address to receive the shares
     * @return shares Amount of shares minted
     */
    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626Upgradeable, IERC4626)
        nonReentrant
        returns (uint256 shares)
    {
        shares = previewDeposit(assets);
        if (shares == 0 && assets > 0) revert LSTWrapper__ZeroSharesMinted();
        
        // Check deposit limits before depositing
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        bool isFirstMint = totalSupply() == 0;
        // Owner can perform the initial seed even while paused.
        if (lws.depositsPaused && !(isFirstMint && msg.sender == owner())) revert LSTWrapper__DepositsPaused();
        if (isFirstMint && msg.sender != owner()) revert LSTWrapper__OnlyOwnerFirstMint();
        // Note: Deposit limit enforcement is handled by the underlying vault
        
        // For owner first mint, bypass maxDeposit check by calling _deposit directly
        // Otherwise, use super.deposit() which checks maxDeposit()
        if (isFirstMint && msg.sender == owner()) {
            _deposit(_msgSender(), receiver, assets, shares);
            return shares;
        }
        
        return super.deposit(assets, receiver);
    }

    /**
     * @notice Mint shares with zero-share protection.
     * @dev Overrides ERC4626 to prevent zero-share mints from donation attacks.
     * @dev Also reverts if deposits are paused (except owner-only first mint) or if the first mint is attempted by a non-owner.
     * @param shares Amount of shares to mint
     * @param receiver Address to receive the shares
     * @return assets Amount of assets required
     */
    function mint(uint256 shares, address receiver)
        public
        override(ERC4626Upgradeable, IERC4626)
        nonReentrant
        returns (uint256 assets)
    {
        if (shares == 0) revert LSTWrapper__ZeroSharesMinted();
        
        // Check deposit limits before minting (which deposits assets)
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        bool isFirstMint = totalSupply() == 0;
        // Owner can perform the initial seed even while paused.
        if (lws.depositsPaused && !(isFirstMint && msg.sender == owner())) revert LSTWrapper__DepositsPaused();
        if (isFirstMint && msg.sender != owner()) revert LSTWrapper__OnlyOwnerFirstMint();
        // Note: Deposit limit enforcement is handled by the underlying vault
        
        return super.mint(shares, receiver);
    }

    /**
     * @notice Withdraw assets with reentrancy protection.
     * @dev Overrides ERC4626 to add nonReentrant guard for safety.
     * @param assets Amount of assets to withdraw
     * @param receiver Address to receive the assets
     * @param owner Address that owns the shares
     * @return shares Amount of shares burned
     */
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override(ERC4626Upgradeable, IERC4626)
        nonReentrant
        returns (uint256 shares)
    {
        return super.withdraw(assets, receiver, owner);
    }

    /**
     * @notice Redeem shares with reentrancy protection.
     * @dev Overrides ERC4626 to add nonReentrant guard for safety.
     * @param shares Amount of shares to redeem
     * @param receiver Address to receive the assets
     * @param owner Address that owns the shares
     * @return assets Amount of assets received
     */
    function redeem(uint256 shares, address receiver, address owner)
        public
        override(ERC4626Upgradeable, IERC4626)
        nonReentrant
        returns (uint256 assets)
    {
        return super.redeem(shares, receiver, owner);
    }

    /**
     * @inheritdoc ILSTWrapper
     */
    function depositWithMinShares(uint256 assets, uint256 minShares, address receiver)
        external
        returns (uint256 shares)
    {
        shares = deposit(assets, receiver); // deposit() already guards zero‑share mints
        if (shares < minShares) revert LSTWrapper__SlippageProtection();
    }

    /**
     * @inheritdoc ILSTWrapper
     */
    function mintWithMaxAssets(uint256 shares, uint256 maxAssets, address receiver)
        external
        returns (uint256 assets)
    {
        assets = mint(shares, receiver);
        if (assets > maxAssets) revert LSTWrapper__SlippageProtection();
    }

    /**
     * @inheritdoc ILSTWrapper
     */
    function withdrawWithMaxShares(uint256 assets, uint256 maxShares, address receiver, address owner)
        external
        returns (uint256 shares)
    {
        shares = withdraw(assets, receiver, owner);
        if (shares > maxShares) revert LSTWrapper__SlippageProtection();
    }

    /**
     * @inheritdoc ILSTWrapper
     */
    function redeemWithMinAssets(uint256 shares, uint256 minAssets, address receiver, address owner)
        external
        returns (uint256 assets)
    {
        assets = redeem(shares, receiver, owner);
        if (assets < minAssets) revert LSTWrapper__SlippageProtection();
    }

    /**
     * @inheritdoc ILSTWrapper
     */
    function sweep(address token, address recipient, uint256 amount) external onlyOwner {
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        if (token == address(asset())) revert LSTWrapper__CannotSweepAsset();
        if (token == address(lws.collateral)) revert LSTWrapper__CannotSweepCollateral();
        if (token == address(lws.nativeToken)) revert LSTWrapper__CannotSweepNativeToken();
        if (recipient == address(0)) revert LSTWrapper__InvalidRecipient();

        IERC20(token).safeTransfer(recipient, amount);
        emit Sweep(msg.sender, token, recipient, amount);
    }
    
    /**
     * @inheritdoc ILSTWrapper
     */
    function sweepCollateralDust(address recipient, uint256 amount) external onlyOwner {
        if (recipient == address(0)) revert LSTWrapper__InvalidRecipient();
        
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        
        // Allow only very small "dust": min(1 whole token unit, 0.0001% of balance).
        uint256 collateralBalance = lws.collateral.balanceOf(address(this));
        uint256 maxDustAmount = _maxCollateralDust(lws);
        if (amount == 0 || amount > maxDustAmount || amount > collateralBalance) {
            revert LSTWrapper__ExcessiveAmount();
        }
        
        lws.collateral.safeTransfer(recipient, amount);
        emit CollateralDustSwept(msg.sender, recipient, amount);
    }

    /**
     * @inheritdoc ILSTWrapper
     */
    function rescueAssetWhenNoSupply(address recipient, uint256 amount) external onlyOwner {
        if (recipient == address(0)) revert LSTWrapper__InvalidRecipient();
        if (totalSupply() != 0) revert LSTWrapper__AssetRescueNotAllowed();
        // Prevent front-run deposits from reopening supply during rescue.
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        if (!lws.depositsPaused) revert LSTWrapper__DepositsPaused();

        IERC20(asset()).safeTransfer(recipient, amount);
        emit AssetRescued(recipient, amount);
    }

    /**
     * @inheritdoc ILSTWrapper
     */
    function setVaultHelper(address helper_) external onlyOwner {
        if (helper_ == address(0)) revert LSTWrapper__InvalidVaultHelper();
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        lws.vaultHelper = IVaultHelper(helper_);
        emit VaultHelperUpdated(helper_);
    }

    function totalAssets() public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    function decimals()
        public
        view
        virtual
        override(ERC4626Upgradeable, IERC20Metadata)
        returns (uint8)
    {
        try IERC20Metadata(address(asset())).decimals() returns (uint8 assetDecimals) {
            return assetDecimals;
        } catch {
            return 18; // Fallback
        }
    }

    /**
     * @inheritdoc IERC4626
     * @dev Returns 0 while paused. Also returns 0 during the seed phase (totalSupply==0) to avoid
     *      misleading integrators, since owner-only seeding depends on msg.sender which a view cannot know.
     */
    function maxDeposit(address) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        if (lws.depositsPaused) return 0;
        if (totalSupply() == 0) return 0;
        return type(uint256).max;
    }

    /**
     * @inheritdoc IERC4626
     * @dev Mirrors {maxDeposit} gating.
     */
    function maxMint(address) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        if (lws.depositsPaused) return 0;
        if (totalSupply() == 0) return 0;
        return type(uint256).max;
    }

    /**
     * @inheritdoc IERC4626
     */
    function convertToShares(uint256 assets)
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256)
    {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /**
     * @inheritdoc IERC4626
     */
    function convertToAssets(uint256 shares)
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256)
    {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    /**
     * @dev Internal conversion function (from assets to shares) with support for rounding direction.
     */
    function _convertToShares(uint256 assets, Math.Rounding rounding)
        internal
        view
        override(ERC4626Upgradeable)
        returns (uint256)
    {
        uint256 supply = totalSupply();
        uint256 totalAssetsAmount = totalAssets();
        uint256 virtualOffset = _virtualOffset(supply);
        return Math.mulDiv(assets, supply + virtualOffset, totalAssetsAmount + virtualOffset, rounding);
    }

    /**
     * @dev Internal conversion function (from shares to assets) with support for rounding direction.
     */
    function _convertToAssets(uint256 shares, Math.Rounding rounding)
        internal
        view
        override(ERC4626Upgradeable)
        returns (uint256)
    {
        uint256 supply = totalSupply();
        uint256 totalAssetsAmount = totalAssets();
        uint256 virtualOffset = _virtualOffset(supply);
        return Math.mulDiv(shares, totalAssetsAmount + virtualOffset, supply + virtualOffset, rounding);
    }

    /**
     * @dev Apply virtual offset only for the first mint (supply == 0) to avoid leftover yield.
     */
    function _virtualOffset(uint256 supply) internal view returns (uint256) {
        if (supply != 0) return 0;
        uint8 assetDecimals;
        try IERC20Metadata(address(asset())).decimals() returns (uint8 decimalsValue) {
            assetDecimals = decimalsValue;
        } catch {
            assetDecimals = 18;
        }
        if (assetDecimals > 36) assetDecimals = 36;
        return _safePow10(assetDecimals);
    }

    /**
     * @dev Calculate 10^exponent safely. Exponent <= 36 by construction.
     */
    function _safePow10(uint8 exponent) internal pure returns (uint256) {
        return 10 ** uint256(exponent);
    }

    /**
     * @dev Calculate maximum allowed collateral dust for sweeping.
     * @dev Percentage cap: 0.0001% of local balance, always defined.
     * @dev Absolute cap: 1 whole token unit if decimals known, else 1 base unit as fallback.
     */
    function _maxCollateralDust(LSTWrapperStorageStruct storage lws) internal view returns (uint256) {
        uint256 collateralBalance = lws.collateral.balanceOf(address(this));
        uint256 percentageCap = collateralBalance / 1_000_000;
        uint256 unitCap = 1; // Fallback: 1 base unit if decimals() is unknown
        try IERC20Metadata(address(lws.collateral)).decimals() returns (uint8 collateralDecimals) {
            if (collateralDecimals > 36) collateralDecimals = 36;
            unitCap = _safePow10(collateralDecimals);
        } catch { }
        return unitCap == 0 ? percentageCap : (percentageCap < unitCap ? percentageCap : unitCap);
    }

    /**
     * @notice Returns true if deposits/mints are paused.
     * @return true if deposits are paused, false otherwise
     */
    function paused() external view returns (bool) {
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        return lws.depositsPaused;
    }

    /// @notice Owner can pause or resume deposits/mints. Required for rescue.
    function setDepositsPaused(bool paused_) external onlyOwner {
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        lws.depositsPaused = paused_;
        emit DepositsPaused(paused_);
    }

    /**
     * @notice Post-upgrade initializer to set the Merkl distributor.
     * @dev Call via ProxyAdmin.upgradeAndCall or directly by owner after upgrade.
     *      During upgradeAndCall, msg.sender is ProxyAdmin (which enforces ownership).
     *      reinitializer(2) ensures this can only be called once.
     * @param distributor Address of the Merkl Distributor contract
     */
    function postUpgradeInit(address distributor) external reinitializer(2) {
        if (distributor == address(0)) revert LSTWrapper__ZeroAddress("rewards");
        
        // During upgradeAndCall, msg.sender is ProxyAdmin. ProxyAdmin already checks ownership.
        // For direct calls, require owner.
        address proxyAdmin = ERC1967Utils.getAdmin();
        if (msg.sender != owner() && msg.sender != proxyAdmin) {
            revert OwnableUnauthorizedAccount(msg.sender);
        }
        
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        lws.rewards = distributor; // same slot as v1 'rewards'
    }

    function _lstWrapperStorage() internal pure returns (LSTWrapperStorageStruct storage lws) {
        bytes32 slot = _LSTWRAPPER_STORAGE_SLOT;
        assembly {
            lws.slot := slot
        }
    }

}

