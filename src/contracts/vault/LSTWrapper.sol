// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {ERC4626Upgradeable, IERC4626} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IVaultTokenized} from "../../interfaces/vault/IVaultTokenized.sol";
import {ILSTWrapper} from "../../interfaces/vault/ILSTWrapper.sol";
import {IRewards} from "../../interfaces/rewards/IRewards.sol";
import {IVaultHelper} from "../../interfaces/IVaultHelper.sol";
import {ICollateral} from "../../interfaces/ICollateral.sol";

/**
 * @title LSTWrapper
 * @notice An upgradeable ERC-4626 non-rebasing yield wrapper for VaultTokenized shares.
 * @dev Users deposit VaultTokenized shares (asset). The wrapper claims the native
 * collateral rewards from the Rewards contract and auto-compounds them back
 * into the underlying VaultTokenized instance, increasing the value per share (PPS)
 * of this LSTWrapper token over time.
 */
contract LSTWrapper is
    Initializable,
    ERC4626Upgradeable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable,
    ILSTWrapper
{
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:lstwrapper.storage
    struct LSTWrapperStorageStruct {
        /// @notice The underlying VaultTokenized contract instance being wrapped. Its shares are the asset.
        IVaultTokenized vault;
        /// @notice The Rewards contract associated with the underlying vault.
        IRewards rewards;
        /// @notice The collateral token used by the vault.
        IERC20 collateral;
        /// @notice The native token (underlying of collateral) paid by Rewards contract.
        IERC20 nativeToken;
        /// @notice Helper used for native->collateral conversion and staking.
        IVaultHelper vaultHelper;
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
     * @param helper_ Address of the VaultHelper to use.
     * @param name_ ERC20 name for this new LST wrapper token.
     * @param symbol_ ERC20 symbol for this new LST wrapper token.
     */
    function initialize(
        address admin,
        address vault_,
        address rewards_,
        address helper_,
        string memory name_,
        string memory symbol_
    ) external initializer {
        // Input Validation
        if (admin == address(0)) revert LSTWrapper__ZeroAddress("admin");
        if (vault_ == address(0)) revert LSTWrapper__ZeroAddress("vault");
        if (rewards_ == address(0)) revert LSTWrapper__ZeroAddress("rewards");
        if (helper_ == address(0)) revert LSTWrapper__InvalidVaultHelper();

        // Initialize Inherited Contracts
        __ERC20_init(name_, symbol_); // name/symbol for this wrapper token
        __ERC4626_init(IERC20(vault_)); // set VaultTokenized shares as asset
        __ReentrancyGuard_init();
        __Ownable_init(admin); // Initialize OwnableUpgradeable with the admin address

        // Set State Variables
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        lws.vault = IVaultTokenized(vault_);
        lws.rewards = IRewards(rewards_);

        // Determine the collateral token
        address collateralAddr = lws.vault.collateral();
        if (collateralAddr == address(0)) revert LSTWrapper__InvalidVaultCollateral();
        
        // Determine the native token from collateral
        address nativeTokenAddr = ICollateral(collateralAddr).asset();
        if (nativeTokenAddr == address(0)) revert LSTWrapper__InvalidRewardsToken();
        
        lws.collateral = IERC20(collateralAddr);
        lws.nativeToken = IERC20(nativeTokenAddr);
        lws.vaultHelper = IVaultHelper(helper_);
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
     */
    function rewards() external view returns (address) {
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        return address(lws.rewards);
    }

    /**
     * @inheritdoc ILSTWrapper
     */
    function collateral() external view returns (address collateral_) {
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        collateral_ = address(lws.collateral);
    }

    function nativeToken() external view returns (address token) {
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        token = address(lws.nativeToken);
    }

    function vaultHelper() external view returns (address helper) {
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        helper = address(lws.vaultHelper);
    }

    /**
     * @inheritdoc ILSTWrapper
     */
    function harvest() external onlyOwner nonReentrant returns (uint256 claimedNative, uint256 mintedVaultShares) {
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        // --- Preflight: refuse if deposit is certainly blocked (helper is depositor) ---
        if (lws.vault.depositWhitelist() && !lws.vault.isDepositorWhitelisted(address(lws.vaultHelper))) {
            revert LSTWrapper__DepositRestricted();
        }
        if (lws.vault.isDepositLimit()) {
            uint256 active = lws.vault.activeStake();
            uint256 limit = lws.vault.depositLimit();
            if (active >= limit) {
                revert LSTWrapper__DepositLimitExceeded(0);
            }
        }

        // Use cached native token (validated at initialization)
        address nativeTokenAddr = address(lws.nativeToken);
        
        // Track balance before claim to compute actual claimed amount
        uint256 nativeBalanceBefore = lws.nativeToken.balanceOf(address(this));
        
        // Claim rewards (native token), catch expected reverts.
        try lws.rewards.claimRewards(nativeTokenAddr, address(this)) { }
        catch (bytes memory reason) {
            emit RewardsClaimFailed(reason);
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

        // Headroom hint (best-effort). Exact enforcement happens in vault on helper call.
        if (lws.vault.isDepositLimit()) {
            uint256 active2  = lws.vault.activeStake();
            uint256 limit2   = lws.vault.depositLimit();
            if (active2 >= limit2) revert LSTWrapper__DepositLimitExceeded(0);
        }

        uint256 sharesBefore = IERC20(asset()).balanceOf(address(this));
        // Approve helper to pull native token exactly once (use total balance to include dust)
        lws.nativeToken.forceApprove(address(lws.vaultHelper), 0);
        lws.nativeToken.forceApprove(address(lws.vaultHelper), totalNativeBalance);
        lws.vaultHelper.stakeAssetInVault(
            address(lws.vault),
            address(this),
            address(lws.collateral),
            nativeTokenAddr,
            totalNativeBalance
        );
        lws.nativeToken.forceApprove(address(lws.vaultHelper), 0);

        uint256 sharesAfter = IERC20(asset()).balanceOf(address(this));
        mintedVaultShares = sharesAfter - sharesBefore;
        if (mintedVaultShares == 0) revert LSTWrapper__ZeroSharesMinted();
        emit Harvest(msg.sender, claimedNative, mintedVaultShares);

        return (claimedNative, mintedVaultShares);
    }

    /**
     * @inheritdoc ILSTWrapper
     */
    function sweep(address token, address recipient, uint256 amount) external onlyOwner {
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        if (token == address(asset())) revert LSTWrapper__CannotSweepAsset();
        if (token == address(lws.collateral)) revert LSTWrapper__CannotSweepCollateral();
        if (recipient == address(0)) revert LSTWrapper__InvalidRecipient();

        IERC20(token).safeTransfer(recipient, amount);
        emit Sweep(msg.sender, token, recipient, amount);
    }
    
    /**
     * @notice Recovers collateral dust that was accidentally sent to the wrapper.
     * @param recipient The address to send the dust to
     * @param amount The amount of collateral dust to recover
     * @dev Only callable by owner. This is safe because the wrapper should never
     *      intentionally hold collateral - it only holds vault shares and native tokens.
     */
    function sweepCollateralDust(address recipient, uint256 amount) external onlyOwner {
        if (recipient == address(0)) revert LSTWrapper__InvalidRecipient();
        
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        
        // Safety check: only allow sweeping small amounts to prevent accidents
        uint256 collateralBalance = lws.collateral.balanceOf(address(this));
        uint256 maxDustAmount = 1e18; // Configurable threshold (1 token with 18 decimals)
        
        if (amount > maxDustAmount || amount > collateralBalance) {
            revert LSTWrapper__ExcessiveAmount();
        }
        
        lws.collateral.safeTransfer(recipient, amount);
        emit CollateralDustSwept(msg.sender, recipient, amount);
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

    function _lstWrapperStorage() internal pure returns (LSTWrapperStorageStruct storage lws) {
        bytes32 slot = _LSTWRAPPER_STORAGE_SLOT;
        assembly {
            lws.slot := slot
        }
    }

    // --- Admin setters ---
    function setVaultHelper(address helper_) external onlyOwner {
        if (helper_ == address(0)) revert LSTWrapper__InvalidVaultHelper();
        LSTWrapperStorageStruct storage lws = _lstWrapperStorage();
        lws.vaultHelper = IVaultHelper(helper_);
        emit VaultHelperUpdated(helper_);
    }
}
