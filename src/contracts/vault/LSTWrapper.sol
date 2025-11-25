// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {ERC4626Upgradeable, IERC4626} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ERC20VotesUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {NoncesUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {IVaultTokenized} from "../../interfaces/vault/IVaultTokenized.sol";
import {ILSTWrapper} from "../../interfaces/vault/ILSTWrapper.sol";
import {IRewardsNativeToken} from "../../interfaces/rewards/IRewardsNativeToken.sol";
import {IDefaultCollateral} from "../../interfaces/defaultCollateral/IDefaultCollateral.sol";

/**
 * @title LSTWrapper
 * @notice An upgradeable ERC-4626 non-rebasing yield wrapper for VaultTokenized shares with 
 *         integrated voting and permit functionality.
 * @dev Users deposit VaultTokenized shares (asset). The wrapper claims the native
 * collateral rewards from the Rewards contract and auto-compounds them back
 * into the underlying VaultTokenized instance, increasing the price per share (PPS)
 * of this LSTWrapper token over time.
 * @dev Implements ERC20Votes for governance participation and ERC20Permit for gasless approvals.
 */
contract LSTWrapper is
    Initializable,
    ERC4626Upgradeable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable,
    ERC20PermitUpgradeable,
    ERC20VotesUpgradeable,
    ILSTWrapper
{
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:lstwrapper.storage
    struct LSTWrapperStorageStruct {
        /// @notice The underlying VaultTokenized contract instance being wrapped. Its shares are the asset.
        IVaultTokenized vault;
        /// @notice The Rewards contract associated with the underlying vault.
        address rewards;
        /// @notice The collateral token used by the vault.
        IERC20 collateral;
        /// @notice The native token (underlying of collateral) paid by Rewards contract.
        IERC20 nativeToken;
        bool depositsPaused;
    }

    // bytes32(uint256(keccak256(abi.encodePacked(uint256(keccak256("lstwrapper.storage")) - 1))) & ~uint256(0xff));
    bytes32 public constant _LSTWRAPPER_STORAGE_SLOT = 0x799f344bf9d1b9145d63579fefcda32172d8d3c9b295fe5dc25c088a9f94f700;

    constructor() {
        _disableInitializers(); // Required for upgradeable contracts
    }

    /**
     * @notice Initializes the LST Wrapper contract.
     * @param admin The initial owner and admin of this wrapper.
     * @param vault_ Address of the specific VaultTokenized instance to wrap.
     * @param rewards_ Address of the associated Rewards contract.
     * @param name_ ERC20 name for this new LST wrapper token.
     * @param symbol_ ERC20 symbol for this new LST wrapper token.
     */
    function initialize(
        address admin,
        address vault_,
        address rewards_,
        string memory name_,
        string memory symbol_
    ) external initializer {
        // Input Validation
        if (admin == address(0)) revert LSTWrapper__ZeroAddress("admin");
        if (vault_ == address(0)) revert LSTWrapper__ZeroAddress("vault");
        if (rewards_ == address(0)) revert LSTWrapper__ZeroAddress("rewards");

        // Initialize Inherited Contracts
        __ERC20_init(name_, symbol_); // name/symbol for this wrapper token
        __ERC4626_init(IERC20(vault_)); // set VaultTokenized shares as asset
        __ReentrancyGuard_init();
        __Ownable_init(admin); // Initialize OwnableUpgradeable with the admin address
        __ERC20Permit_init(name_);
        __ERC20Votes_init();

        // Set State Variables
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        lws.vault = IVaultTokenized(vault_);
        lws.rewards = rewards_;

        // Determine the collateral token
        address collateralAddr = lws.vault.collateral();
        if (collateralAddr == address(0)) revert LSTWrapper__InvalidVaultCollateral();
        
        // Determine the native token from collateral
        address nativeTokenAddr = IDefaultCollateral(collateralAddr).asset();
        if (nativeTokenAddr == address(0)) revert LSTWrapper__InvalidRewardsToken();
        
        lws.collateral = IERC20(collateralAddr);
        lws.nativeToken = IERC20(nativeTokenAddr);
        // Start paused
        lws.depositsPaused = true;
        // No infinite approvals; per‑harvest allowances only.
    }

    /**
     * @inheritdoc ILSTWrapper
     */
    function initializeVotes() external reinitializer(2) {
        // ProxyAdmin-only (typically via upgradeAndCall)
        if (msg.sender != ERC1967Utils.getAdmin()) revert OwnableUnauthorizedAccount(msg.sender);
        __ERC20Permit_init(name());
        __ERC20Votes_init();
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
     */
    function rewards() external view returns (address) {
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
    function harvest(uint256 /*amount*/, bytes32[] calldata /*proof*/)
        external
        nonReentrant
        returns (uint256 claimedNative, uint256 mintedVaultShares)
    {
        return _harvestNative();
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
    function setRewards(address rewards_) external {
        if (rewards_ == address(0)) revert LSTWrapper__ZeroAddress("rewards");
        // ProxyAdmin-only (typically via upgradeAndCall)
        if (msg.sender != ERC1967Utils.getAdmin()) revert OwnableUnauthorizedAccount(msg.sender);
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        lws.rewards = rewards_;
    }

    /**
     * @inheritdoc ILSTWrapper
     */
    function paused() external view returns (bool) {
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        return lws.depositsPaused;
    }

    /**
     * @inheritdoc ILSTWrapper
     */
    function setDepositsPaused(bool paused_) external onlyOwner {
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        lws.depositsPaused = paused_;
        emit DepositsPaused(paused_);
    }

    /**
     * @inheritdoc IERC4626
     */
    function totalAssets() public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /**
     * @inheritdoc IERC20Metadata
     */
    function decimals()
        public
        view
        virtual
        override(ERC4626Upgradeable, ERC20Upgradeable, IERC20Metadata)
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
     * @dev Internal harvest implementation for native rewards.
     */
    function _harvestNative() internal returns (uint256 claimedNative, uint256 mintedVaultShares) {
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        
        // Track balance before claim to compute actual claimed amount
        uint256 nativeBalanceBefore = lws.nativeToken.balanceOf(address(this));
        
        // Legacy distributor claim
        try IRewardsNativeToken(lws.rewards).claimRewards(address(this)) { }
        catch {
            emit RewardsClaimFailed(bytes(""));
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
            if (!lws.vault.isDepositorWhitelisted(address(this))) revert LSTWrapper__DepositRestricted();
        }
        // Deposit limit check only when depositing
        if (lws.vault.isDepositLimit()) {
            uint256 active  = lws.vault.activeStake();
            uint256 limit   = lws.vault.depositLimit();
            if (active >= limit) revert LSTWrapper__DepositLimitExceeded(0);
        }

        // Inline staking: native token → collateral → vault shares
        
        // Approve collateral contract to pull native tokens
        lws.nativeToken.forceApprove(address(lws.collateral), totalNativeBalance);
        
        // Deposit native tokens into collateral, minting collateral tokens to this contract
        uint256 collateralMinted = IDefaultCollateral(address(lws.collateral)).deposit(address(this), totalNativeBalance);
        if (collateralMinted == 0) revert LSTWrapper__ZeroSharesMinted();
        lws.nativeToken.forceApprove(address(lws.collateral), 0);
        
        // Approve vault to pull collateral tokens
        lws.collateral.forceApprove(address(lws.vault), collateralMinted);
        
        // Deposit collateral into vault, minting vault shares to this contract
        (, mintedVaultShares) = lws.vault.deposit(address(this), collateralMinted);
        if (mintedVaultShares == 0) revert LSTWrapper__ZeroSharesMinted();
        lws.collateral.forceApprove(address(lws.vault), 0);

        emit Harvest(msg.sender, claimedNative, mintedVaultShares);
        return (claimedNative, mintedVaultShares);
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
     * @dev Internal hook called on all token transfers, mints, and burns.
     * @dev Overrides both ERC20Upgradeable and ERC20VotesUpgradeable to ensure
     *      vote tracking is properly updated on balance changes.
     * @param from Address tokens are transferred from (zero for mints)
     * @param to Address tokens are transferred to (zero for burns)
     * @param value Amount of tokens transferred
     */
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20VotesUpgradeable)
    {
        super._update(from, to, value);
    }

    /**
     * @dev Required override to resolve conflict between ERC20PermitUpgradeable
     *      and NoncesUpgradeable in the inheritance graph.
     * @inheritdoc NoncesUpgradeable
     */
    function nonces(address owner)
        public
        view
        override(ERC20PermitUpgradeable, NoncesUpgradeable)
        returns (uint256)
    {
        return super.nonces(owner);
    }

    function _lstWrapperStorage() internal pure returns (LSTWrapperStorageStruct storage lws) {
        bytes32 slot = _LSTWRAPPER_STORAGE_SLOT;
        assembly {
            lws.slot := slot
        }
    }

}
