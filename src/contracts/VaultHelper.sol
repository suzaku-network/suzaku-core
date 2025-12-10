    // SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {IVaultTokenized} from "../interfaces/vault/IVaultTokenized.sol";
import {RewardsNativeToken} from "../contracts/rewards/RewardsNativeToken.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IDefaultCollateral} from "../interfaces/defaultCollateral/IDefaultCollateral.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRegistry} from "../interfaces/common/IRegistry.sol";
import {ILSTWrapper} from "../interfaces/vault/ILSTWrapper.sol";

struct ClaimAmountsPerToken {
    address token;
    uint256 amount;
}

struct PendingWithdraw {
    uint256 amount;
    uint256 epoch;
}

contract VaultHelper is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 constant BASIS_POINTS_DENOMINATOR = 10_000;
    uint256 constant MAX_EPOCH_SPAN = 5000;

    IRegistry public immutable VAULT_FACTORY;
    IRegistry public immutable LST_WRAPPER_FACTORY;

    constructor(address vaultFactory_, address lstWrapperFactory_) {
        if (vaultFactory_ == address(0)) revert VaultHelper__ZeroAddress("vaultFactory");
        if (lstWrapperFactory_ == address(0)) revert VaultHelper__ZeroAddress("lstWrapperFactory");
        VAULT_FACTORY = IRegistry(vaultFactory_);
        LST_WRAPPER_FACTORY = IRegistry(lstWrapperFactory_);
    }

    // Custom errors
    error VaultHelper__InvalidUser(address user);
    error VaultHelper__InvalidAmount(uint256 amount);
    error VaultHelper__ZeroAddress(string param);
    error VaultHelper__ZeroCollateralMint(uint256 depositAmount, address collateral);
    error VaultHelper__InvalidVaultShare(uint256 share);
    error VaultHelper__InvalidVault(address vault);
    error VaultHelper__InvalidRange();
    error VaultHelper__ZeroVaultSharesMinted(uint256 collateralAmount);
    error VaultHelper__ZeroLSTWrapperSharesMinted(uint256 lstSharesMinted);
    error VaultHelper__ZeroLSTWrapperSharesBurned(uint256 lstSharesBurned);
    error VaultHelper__ZeroCollateralWithdraw(uint256 collateralAmount);
    error VaultHelper__LSTWrapperMismatch(address lstWrapper);

    // -------------------------------
    // Proxy function
    // -------------------------------

    /**
     * @notice Stakes an asset in a vault on behalf of a receiver.
     * @dev The caller (msg.sender) needs to approve the VaultHelper to pull the underlying tokens from them.
     *      Handles fee-on-transfer tokens by staking the actually received amount
     *      (`actualAmount <= amount`).
     * @param vault Address of the vault.
     * @param user Address of the receiver who will get the vault shares.
     * @param collateral Address of the collateral.
     * @param underlying Address of the underlying asset.
     * @param amount Amount of the underlying asset to stake.
     */
    function stakeAssetInVault(
        address vault,
        address user,
        address collateral,
        address underlying,
        uint256 amount
    ) external nonReentrant returns (uint256 collateralAmount, uint256 sharesMinted) {
        if (vault == address(0)) revert VaultHelper__ZeroAddress("vault");
        if (!VAULT_FACTORY.isEntity(vault)) revert VaultHelper__InvalidVault(vault);
        if (collateral == address(0)) revert VaultHelper__ZeroAddress("collateral");
        if (underlying == address(0)) revert VaultHelper__ZeroAddress("underlying");
        if (user == address(0)) revert VaultHelper__InvalidUser(user);
        if (amount == 0) revert VaultHelper__InvalidAmount(amount);

        // --- Step 1: Measure balance before the transfer ---
        uint256 balanceBefore = IERC20(underlying).balanceOf(address(this));

        // --- Step 2: Pull underlying tokens from msg.sender into proxy ---
        IERC20(underlying).safeTransferFrom(msg.sender, address(this), amount);

        // --- Step 3: Calculate the actual amount received ---
        uint256 actualAmount = IERC20(underlying).balanceOf(address(this)) - balanceBefore;

        // --- Step 4: Approve collateral contract to pull the actual amount from proxy ---
        IERC20(underlying).forceApprove(collateral, actualAmount);

        // --- Step 5: Deposit actual amount into collateral, minting collateral tokens to proxy ---
        collateralAmount = IDefaultCollateral(collateral).deposit(address(this), actualAmount);
        if (collateralAmount == 0) revert VaultHelper__ZeroCollateralMint(actualAmount, collateral);
        IERC20(underlying).forceApprove(collateral, 0);

        // --- Step 6: Approve vault to pull collateral tokens from proxy ---
        IERC20(collateral).forceApprove(vault, collateralAmount);

        // --- Step 7: Deposit collateral into vault on behalf of the receiver (`user`) ---
        (, sharesMinted) = IVaultTokenized(vault).deposit(user, collateralAmount);
        if (sharesMinted == 0) revert VaultHelper__ZeroVaultSharesMinted(collateralAmount);
        IERC20(collateral).forceApprove(vault, 0);

        return (collateralAmount, sharesMinted);
    }

    /**
     * @notice Stakes an asset in a wrapped vault on behalf of a receiver.
     * @dev The caller (msg.sender) needs to approve the VaultHelper to pull the underlying tokens from them.
     *      Handles fee-on-transfer tokens by staking the actually received amount
     *      (`actualAmount <= amount`).
     * @param user Address of the receiver who will get the vault shares.
     * @param lstWrapper Address of the LSTWrapper contract to stake in.
     * @param amount Amount of the underlying asset to stake.
     */
    function stakeAssetInWrappedVault(
        address user,
        address lstWrapper,
        uint256 amount
    ) external nonReentrant returns (uint256 collateralAmount, uint256 lstSharesMinted) {
        if (user == address(0)) revert VaultHelper__InvalidUser(user);
        if (amount == 0) revert VaultHelper__InvalidAmount(amount);
        if (lstWrapper == address(0)) revert VaultHelper__ZeroAddress("lstWrapper");
        if (LST_WRAPPER_FACTORY != IRegistry(address(0)) && !LST_WRAPPER_FACTORY.isEntity(lstWrapper)) {
            revert VaultHelper__LSTWrapperMismatch(lstWrapper);
        }

        // --- Step 1: Measure balance before the transfer ---
        uint256 balanceBefore = IERC20(ILSTWrapper(lstWrapper).nativeToken()).balanceOf(address(this));

        // --- Step 2: Pull underlying tokens from msg.sender into proxy ---
        IERC20(ILSTWrapper(lstWrapper).nativeToken()).safeTransferFrom(msg.sender, address(this), amount);

        // --- Step 3: Calculate the actual amount received ---
        uint256 actualAmount = IERC20(ILSTWrapper(lstWrapper).nativeToken()).balanceOf(address(this)) - balanceBefore;

        // --- Step 4: Approve collateral contract to pull the actual amount from proxy ---
        IERC20(ILSTWrapper(lstWrapper).nativeToken()).forceApprove(ILSTWrapper(lstWrapper).collateral(), actualAmount);

        // --- Step 5: Deposit actual amount into collateral, minting collateral tokens to proxy ---
        collateralAmount = IDefaultCollateral(ILSTWrapper(lstWrapper).collateral()).deposit(address(this), actualAmount);
        if (collateralAmount == 0) {
            revert VaultHelper__ZeroCollateralMint(actualAmount, ILSTWrapper(lstWrapper).collateral());
        }
        IERC20(ILSTWrapper(lstWrapper).nativeToken()).forceApprove(ILSTWrapper(lstWrapper).collateral(), 0);

        // --- Step 6: Approve vault to pull collateral tokens from proxy ---
        IERC20(ILSTWrapper(lstWrapper).collateral()).forceApprove(ILSTWrapper(lstWrapper).vault(), collateralAmount);

        // --- Step 7: Deposit collateral into vault, minting the vault shares tokens to proxy ---
        (, uint256 vaultSharesMinted) =
            IVaultTokenized(ILSTWrapper(lstWrapper).vault()).deposit(address(this), collateralAmount);
        if (vaultSharesMinted == 0) revert VaultHelper__ZeroVaultSharesMinted(collateralAmount);
        IERC20(ILSTWrapper(lstWrapper).collateral()).forceApprove(ILSTWrapper(lstWrapper).vault(), 0);

        // --- Step 8: Approve LSTWrapper to pull vault shares from proxy ---
        IERC20(ILSTWrapper(lstWrapper).vault()).forceApprove(lstWrapper, vaultSharesMinted);

        // --- Step 9: Deposit vault shares into LSTWrapper on behalf of the receiver (`user`) ---
        lstSharesMinted = ILSTWrapper(lstWrapper).deposit(vaultSharesMinted, user);
        if (lstSharesMinted == 0) revert VaultHelper__ZeroLSTWrapperSharesMinted(lstSharesMinted);
        IERC20(ILSTWrapper(lstWrapper).vault()).forceApprove(lstWrapper, 0);

        return (collateralAmount, lstSharesMinted);
    }

    function withdrawFromWrappedVault(
        address lstWrapper,
        uint256 amount
    ) external nonReentrant returns (uint256 collateralAmount, uint256 lstSharesBurned) {
        if (amount == 0) revert VaultHelper__InvalidAmount(amount);
        if (lstWrapper == address(0)) revert VaultHelper__ZeroAddress("lstWrapper");
        if (!LST_WRAPPER_FACTORY.isEntity(lstWrapper)) revert VaultHelper__LSTWrapperMismatch(lstWrapper);

        // --- Step 1: Burn LST shares to receive vault shares ---
        uint256 vaultSharesReceived = ILSTWrapper(lstWrapper).redeem(amount, address(this), msg.sender);
        if (vaultSharesReceived == 0) revert VaultHelper__ZeroLSTWrapperSharesBurned(vaultSharesReceived);

        lstSharesBurned = amount;

        // --- Step 2: Redeem vault shares into underlying collateral (sent to caller) ---
        (collateralAmount,) = IVaultTokenized(ILSTWrapper(lstWrapper).vault()).redeem(msg.sender, vaultSharesReceived);
        if (collateralAmount == 0) revert VaultHelper__ZeroCollateralWithdraw(collateralAmount);

        return (collateralAmount, lstSharesBurned);
    }

    // -------------------------------
    // Lens functions
    // -------------------------------

    /**
     * @notice Returns the pending withdraws for a user.
     * @param vault Address of the vault.
     * @param user Address of the user.
     */
    function getUserPendingWithdraws(
        address vault,
        address user
    ) external view returns (PendingWithdraw[] memory pendingWithdraws) {
        if (vault == address(0)) revert VaultHelper__ZeroAddress("vault");
        if (user == address(0)) revert VaultHelper__InvalidUser(user);
        if (!VAULT_FACTORY.isEntity(vault)) revert VaultHelper__InvalidVault(vault);
        uint256 currentEpoch = IVaultTokenized(vault).currentEpoch();
        // Limit scan to the last MAX_EPOCH_SPAN epochs to avoid reverting for long‑lived vaults
        uint256 startEpoch = 0;
        if (currentEpoch > MAX_EPOCH_SPAN) {
            startEpoch = currentEpoch - MAX_EPOCH_SPAN;
        }

        uint256 count;
        for (uint256 i = startEpoch; i < currentEpoch; i++) {
            if (IVaultTokenized(vault).withdrawalSharesOf(i, user) > 0) {
                if (!IVaultTokenized(vault).isWithdrawalsClaimed(i, user)) {
                    count++;
                }
            }
        }

        pendingWithdraws = new PendingWithdraw[](count);

        uint256 index;
        for (uint256 i = startEpoch; i < currentEpoch; i++) {
            uint256 userWithdrawalShares = IVaultTokenized(vault).withdrawalSharesOf(i, user);
            if (userWithdrawalShares > 0) {
                if (!IVaultTokenized(vault).isWithdrawalsClaimed(i, user)) {
                    pendingWithdraws[index] = PendingWithdraw({amount: userWithdrawalShares, epoch: i});
                    index++;
                }
            }
        }
    }

    /**
     * @notice Returns the pending withdraws for a user within a specific epoch range.
     * @param vault Address of the vault.
     * @param user Address of the user.
     * @param fromEpoch Starting epoch (inclusive).
     * @param toEpoch Ending epoch (exclusive).
     */
    function getUserPendingWithdrawsInRange(
        address vault,
        address user,
        uint256 fromEpoch,
        uint256 toEpoch
    ) external view returns (PendingWithdraw[] memory pendingWithdraws) {
        if (vault == address(0)) revert VaultHelper__ZeroAddress("vault");
        if (user == address(0)) revert VaultHelper__InvalidUser(user);
        if (!VAULT_FACTORY.isEntity(vault)) revert VaultHelper__InvalidVault(vault);
        uint256 currentEpoch = IVaultTokenized(vault).currentEpoch();
        if (toEpoch > currentEpoch) toEpoch = currentEpoch;
        if (toEpoch <= fromEpoch) revert VaultHelper__InvalidRange();
        uint256 span = toEpoch - fromEpoch;
        if (span > MAX_EPOCH_SPAN) revert VaultHelper__InvalidRange();

        uint256 count;
        for (uint256 i = fromEpoch; i < toEpoch; i++) {
            if (IVaultTokenized(vault).withdrawalSharesOf(i, user) > 0) {
                if (!IVaultTokenized(vault).isWithdrawalsClaimed(i, user)) {
                    count++;
                }
            }
        }

        pendingWithdraws = new PendingWithdraw[](count);
        uint256 index;
        for (uint256 i = fromEpoch; i < toEpoch; i++) {
            uint256 userWithdrawalShares = IVaultTokenized(vault).withdrawalSharesOf(i, user);
            if (userWithdrawalShares > 0) {
                if (!IVaultTokenized(vault).isWithdrawalsClaimed(i, user)) {
                    pendingWithdraws[index] = PendingWithdraw({amount: userWithdrawalShares, epoch: i});
                    index++;
                }
            }
        }
    }

    /**
     * @notice Returns the future pending withdraws for a user.
     * @param vault Address of the vault.
     * @param user Address of the user.
     */
    function getUserFuturePendingWithdraws(
        address vault,
        address user
    ) external view returns (PendingWithdraw[] memory pendingWithdraws) {
        if (vault == address(0)) revert VaultHelper__ZeroAddress("vault");
        if (user == address(0)) revert VaultHelper__InvalidUser(user);
        if (!VAULT_FACTORY.isEntity(vault)) revert VaultHelper__InvalidVault(vault);
        uint256 currentEpoch = IVaultTokenized(vault).currentEpoch();

        uint256 count;
        for (uint256 i = currentEpoch; i < currentEpoch + 5; i++) {
            if (IVaultTokenized(vault).withdrawalSharesOf(i, user) > 0) {
                count++;
            }
        }

        pendingWithdraws = new PendingWithdraw[](count);

        uint256 index;
        for (uint256 i = currentEpoch; i < currentEpoch + 5; i++) {
            if (IVaultTokenized(vault).withdrawalSharesOf(i, user) > 0) {
                pendingWithdraws[index] =
                    PendingWithdraw({amount: IVaultTokenized(vault).withdrawalSharesOf(i, user), epoch: i});
                index++;
            }
        }
    }

    /**
     * @notice Returns the claimable rewards for a staker.
     * @param staker Address of the staker.
     * @param rewards Address of the rewards contract.
     * @param vault Address of the vault.
     * @param rewardsTokens Addresses of the rewards tokens.
     */
    function getStakerClaimableRewards(
        address staker,
        address rewards,
        address vault,
        address[] memory rewardsTokens
    ) external view returns (ClaimAmountsPerToken[] memory) {
        if (staker == address(0)) revert VaultHelper__InvalidUser(staker);
        if (rewards == address(0)) revert VaultHelper__ZeroAddress("rewards");
        if (vault == address(0)) revert VaultHelper__ZeroAddress("vault");
        if (!VAULT_FACTORY.isEntity(vault)) revert VaultHelper__InvalidVault(vault);
        ClaimAmountsPerToken[] memory claimAmountsPerToken = new ClaimAmountsPerToken[](rewardsTokens.length);
        for (uint256 i = 0; i < rewardsTokens.length; i++) {
            claimAmountsPerToken[i] = getStakerClaimableReward(staker, rewards, vault, rewardsTokens[i]);
        }
        return claimAmountsPerToken;
    }

    /**
     * @notice Returns aggregated rewards per token for a staker across unclaimed epochs.
     * @param staker Address of the staker.
     * @param rewards Address of the rewards contract.
     * @param vault Address of the vault.
     * @param rewardsToken Address of the rewards token.
     */
    function getStakerClaimableReward(
        address staker,
        address rewards,
        address vault,
        address rewardsToken
    ) public view returns (ClaimAmountsPerToken memory) {
        if (staker == address(0)) revert VaultHelper__InvalidUser(staker);
        if (rewards == address(0)) revert VaultHelper__ZeroAddress("rewards");
        if (vault == address(0)) revert VaultHelper__ZeroAddress("vault");
        if (rewardsToken == address(0)) revert VaultHelper__ZeroAddress("rewardsToken");
        if (!VAULT_FACTORY.isEntity(vault)) revert VaultHelper__InvalidVault(vault);
        uint48 currentEpoch = RewardsNativeToken(rewards).middleware().getCurrentEpoch();
        uint48 lastClaimedEpoch = RewardsNativeToken(rewards).lastEpochClaimedStaker(staker);

        // Nothing to claim -> return empty array
        if (currentEpoch <= lastClaimedEpoch + 1) {
            return ClaimAmountsPerToken({token: RewardsNativeToken(rewards).rewardsToken(), amount: 0});
        }

        uint256 span = uint256(currentEpoch) - uint256(lastClaimedEpoch + 1);
        if (span > MAX_EPOCH_SPAN) revert VaultHelper__InvalidRange();
        uint256 totalAmount = 0;

        // Iterate through epochs after last claimed and before current epoch
        for (uint48 epoch = lastClaimedEpoch + 1; epoch < currentEpoch; epoch++) {
            uint48 epochTs = RewardsNativeToken(rewards).middleware().getEpochStartTs(epoch);

            uint256 rewardsAmount = RewardsNativeToken(rewards).getEpochRewards(epoch);

            uint256 vaultShare = RewardsNativeToken(rewards).vaultShares(epoch, vault);
            if (vaultShare == 0) continue;
            if (vaultShare > BASIS_POINTS_DENOMINATOR) revert VaultHelper__InvalidVaultShare(vaultShare);

            uint256 stakerVaultShare = IVaultTokenized(vault).activeSharesOfAt(staker, epochTs, "");
            if (stakerVaultShare == 0) continue;

            uint256 vaultTotalShares = IVaultTokenized(vault).activeSharesAt(epochTs, "");
            if (vaultTotalShares == 0) continue;

            uint256 vaultRewardsAmount = Math.mulDiv(rewardsAmount, vaultShare, BASIS_POINTS_DENOMINATOR);

            uint256 stakerRewardsAmount = Math.mulDiv(vaultRewardsAmount, stakerVaultShare, vaultTotalShares);
            if (stakerRewardsAmount == 0) continue;

            totalAmount += stakerRewardsAmount;
        }

        return ClaimAmountsPerToken({token: RewardsNativeToken(rewards).rewardsToken(), amount: totalAmount});
    }

    /**
     * @notice Returns aggregated rewards per token for a staker within a specific epoch range.
     * @param staker Address of the staker.
     * @param rewards Address of the rewards contract.
     * @param vault Address of the vault.
     * @param rewardsToken Address of the rewards token.
     * @param fromEpoch Starting epoch (inclusive).
     * @param toEpoch Ending epoch (exclusive).
     */
    function getStakerClaimableRewardInRange(
        address staker,
        address rewards,
        address vault,
        address rewardsToken,
        uint48 fromEpoch,
        uint48 toEpoch
    ) external view returns (ClaimAmountsPerToken memory) {
        if (staker == address(0)) revert VaultHelper__InvalidUser(staker);
        if (rewards == address(0)) revert VaultHelper__ZeroAddress("rewards");
        if (vault == address(0)) revert VaultHelper__ZeroAddress("vault");
        if (rewardsToken == address(0)) revert VaultHelper__ZeroAddress("rewardsToken");
        if (toEpoch <= fromEpoch) revert VaultHelper__InvalidRange();
        if (!VAULT_FACTORY.isEntity(vault)) revert VaultHelper__InvalidVault(vault);

        uint48 currentEpoch = RewardsNativeToken(rewards).middleware().getCurrentEpoch();
        if (toEpoch > currentEpoch) toEpoch = currentEpoch;
        uint256 span = uint256(toEpoch) - uint256(fromEpoch);
        if (span > MAX_EPOCH_SPAN) revert VaultHelper__InvalidRange();

        uint256 totalAmount;
        for (uint48 epoch = fromEpoch; epoch < toEpoch; epoch++) {
            uint48 epochTs = RewardsNativeToken(rewards).middleware().getEpochStartTs(epoch);
            uint256 rewardsAmount = RewardsNativeToken(rewards).getEpochRewards(epoch);
            uint256 vaultShare = RewardsNativeToken(rewards).vaultShares(epoch, vault);
            if (vaultShare == 0) continue;
            if (vaultShare > BASIS_POINTS_DENOMINATOR) revert VaultHelper__InvalidVaultShare(vaultShare);

            uint256 stakerVaultShare = IVaultTokenized(vault).activeSharesOfAt(staker, epochTs, "");
            if (stakerVaultShare == 0) continue;

            uint256 vaultTotalShares = IVaultTokenized(vault).activeSharesAt(epochTs, "");
            if (vaultTotalShares == 0) continue;

            uint256 vaultRewardsAmount = Math.mulDiv(rewardsAmount, vaultShare, BASIS_POINTS_DENOMINATOR);
            uint256 stakerRewardsAmount = Math.mulDiv(vaultRewardsAmount, stakerVaultShare, vaultTotalShares);
            if (stakerRewardsAmount == 0) continue;

            totalAmount += stakerRewardsAmount;
        }

        return ClaimAmountsPerToken({token: RewardsNativeToken(rewards).rewardsToken(), amount: totalAmount});
    }
}
