// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {IVaultTokenized} from "../interfaces/vault/IVaultTokenized.sol";
import {Rewards} from "../contracts/rewards/Rewards.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IDefaultCollateral} from "../interfaces/defaultCollateral/IDefaultCollateral.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

struct ClaimAmountsPerToken {
    address token;
    uint256 amount;
}

struct PendingWithdraw {
    uint256 amount;
    uint256 epoch;
}

contract LSTHelper {
    using SafeERC20 for IERC20;

    uint256 constant BASIS_POINTS_DENOMINATOR = 10_000;

    // -------------------------------
    // Proxy function
    // -------------------------------

    /**
     * @notice Stakes an asset in a vault.
     * @dev The user needs to approve the LSTHelper to pull the underlying tokens from them.
     * @param vault Address of the vault.
     * @param user Address of the user.
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
    ) external {
        require(user != address(0), "Invalid user");
        require(amount > 0, "Amount must be > 0");

        // --- Step 1: Pull underlying tokens from user into proxy ---
        IERC20(underlying).safeTransferFrom(msg.sender, address(this), amount);

        // --- Step 2: Approve collateral contract to pull underlying from proxy ---
        IERC20(underlying).forceApprove(collateral, amount);

        // --- Step 3: Deposit underlying into collateral, minting collateral tokens to proxy ---
        uint256 collateralAmount = IDefaultCollateral(collateral).deposit(address(this), amount);

        // --- Step 4: Approve vault to pull collateral tokens from proxy ---
        IERC20(collateral).forceApprove(vault, collateralAmount);

        // --- Step 5: Deposit collateral into vault on behalf of `user` ---
        IVaultTokenized(vault).deposit(user, collateralAmount);
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
        uint256 currentEpoch = IVaultTokenized(vault).currentEpoch();

        uint256 count;
        for (uint256 i = 0; i < currentEpoch; i++) {
            if (IVaultTokenized(vault).withdrawalSharesOf(i, user) > 0) {
                if (!IVaultTokenized(vault).isWithdrawalsClaimed(i, user)) {
                    count++;
                }
            }
        }

        pendingWithdraws = new PendingWithdraw[](count);

        uint256 index;
        for (uint256 i = 0; i < currentEpoch; i++) {
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
        ClaimAmountsPerToken[] memory claimAmountsPerToken = new ClaimAmountsPerToken[](rewardsTokens.length);
        for (uint256 i = 0; i < rewardsTokens.length; i++) {
            claimAmountsPerToken[i] = this.getStakerClaimableReward(staker, rewards, vault, rewardsTokens[i]);
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
    ) external view returns (ClaimAmountsPerToken memory) {
        uint48 currentEpoch = Rewards(rewards).middleware().getCurrentEpoch();
        uint48 lastClaimedEpoch = Rewards(rewards).lastEpochClaimedStaker(staker, rewardsToken);

        // Nothing to claim -> return empty array
        if (currentEpoch <= lastClaimedEpoch + 1) {
            return ClaimAmountsPerToken({token: rewardsToken, amount: 0});
        }

        uint256 totalAmount = 0;

        // Iterate through epochs after last claimed and before current epoch
        for (uint48 epoch = lastClaimedEpoch + 1; epoch < currentEpoch; epoch++) {
            uint48 epochTs = Rewards(rewards).middleware().getEpochStartTs(epoch);

            uint256 rewardsAmount = Rewards(rewards).getRewardsAmountPerTokenFromEpoch(epoch, rewardsToken);

            uint256 vaultShare = Rewards(rewards).vaultShares(epoch, vault);
            if (vaultShare == 0) continue;

            uint256 stakerVaultShare = IVaultTokenized(vault).activeSharesOfAt(staker, epochTs, "");
            if (stakerVaultShare == 0) continue;

            uint256 vaultTotalShares = IVaultTokenized(vault).activeSharesAt(epochTs, "");

            uint256 vaultRewardsAmount = Math.mulDiv(rewardsAmount, vaultShare, BASIS_POINTS_DENOMINATOR);

            uint256 stakerRewardsAmount = Math.mulDiv(vaultRewardsAmount, stakerVaultShare, vaultTotalShares);
            if (stakerRewardsAmount == 0) continue;

            totalAmount += stakerRewardsAmount;
        }

        return ClaimAmountsPerToken({token: rewardsToken, amount: totalAmount});
    }
}
