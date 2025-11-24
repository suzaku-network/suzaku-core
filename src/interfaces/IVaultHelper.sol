// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity ^0.8.0;

interface IVaultHelper {
    // Errors
    error VaultHelper__InvalidUser(address user);
    error VaultHelper__InvalidAmount(uint256 amount);
    error VaultHelper__ZeroAddress(string param);
    error VaultHelper__ZeroCollateralMint(uint256 depositAmount, address collateral);
    error VaultHelper__InvalidVaultShare(uint256 share);
    error VaultHelper__InvalidVault(address vault);
    error VaultHelper__InvalidRange();

    // Structs
    struct PendingWithdraw {
        uint256 amount;
        uint256 epoch;
    }

    struct ClaimAmountsPerToken {
        address rewardsToken;
        uint256 amount;
    }

    // Functions
    /**
     * @notice Stake an underlying asset in a vault.
     * @dev Converts the underlying asset to collateral and deposits it in the vault on behalf of the user.
     *      Handles fee-on-transfer tokens by staking the actually received amount.
     * @param vault Address of the vault to stake in.
     * @param user Address of the user on whose behalf the staking is done.
     * @param collateral Address of the collateral asset for the vault.
     * @param underlying Address of the underlying asset to stake.
     * @param amount Max amount of underlying to pull; actual staked may be less if the token takes a fee.
     * @return collateralMinted amount of collateral minted from `underlying`
     * @return sharesMinted amount of `vault` shares minted to `user`
     */
    function stakeAssetInVault(
        address vault,
        address user,
        address collateral,
        address underlying,
        uint256 amount
    ) external returns (uint256 collateralMinted, uint256 sharesMinted);

    /**
     * @notice Stake an underlying asset in a LSTWrapper contract.
     * @dev Converts the underlying asset to collateral and deposits it in the vault on behalf of the user.
     *      Handles fee-on-transfer tokens by staking the actually received amount.
     * @param vault Address of the vault to stake in.
     * @param user Address of the user on whose behalf the staking is done.
     * @param collateral Address of the collateral asset for the vault.
     * @param lstWrapper Address of the LSTWrapper contract to stake in.
     * @param underlying Address of the underlying asset to stake.
     * @param amount Max amount of underlying to pull; actual staked may be less if the token takes a fee.
     * @return collateralMinted amount of collateral minted from `underlying`
     * @return sharesMinted amount of `vault` shares minted to `user`
     */
    function stakeAssetInWrappedVault(
        address vault,
        address user,
        address collateral,
        address underlying,
        address lstWrapper,
        uint256 amount
    ) external returns (uint256 collateralMinted, uint256 sharesMinted);

    /**
     * @notice Withdraw collateral from a wrapped vault.
     * @param vault Address of the vault to withdraw from.
     * @param user Address of the user to withdraw for.
     * @param lstWrapper Address of the LSTWrapper contract to withdraw from.
     * @param amount Amount of collateral to withdraw.
     * @return collateralAmount Amount of collateral withdrawn.
     * @return lstSharesBurned Amount of LST shares burned.
     */
    function withdrawFromWrappedVault(
        address vault,
        address user,
        address lstWrapper,
        uint256 amount
    ) external returns (uint256 collateralAmount, uint256 lstSharesBurned);

    /**
     * @notice Get all pending withdrawals for a user in a vault.
     * @param vault Address of the vault to query.
     * @param user Address of the user to query.
     * @return pendingWithdraws Array of pending withdrawals.
     */
    function getUserPendingWithdraws(
        address vault,
        address user
    ) external view returns (PendingWithdraw[] memory pendingWithdraws);

    /**
     * @notice Get pending withdrawals for a user in a vault within a specific epoch range.
     * @param vault Address of the vault to query.
     * @param user Address of the user to query.
     * @param fromEpoch Starting epoch (inclusive).
     * @param toEpoch Ending epoch (exclusive).
     * @return pendingWithdraws Array of pending withdrawals in the specified range.
     */
    function getUserPendingWithdrawsInRange(
        address vault,
        address user,
        uint256 fromEpoch,
        uint256 toEpoch
    ) external view returns (PendingWithdraw[] memory pendingWithdraws);

    /**
     * @notice Get future pending withdrawals for a user in a vault.
     * @param vault Address of the vault to query.
     * @param user Address of the user to query.
     * @return pendingWithdraws Array of future pending withdrawals.
     */
    function getUserFuturePendingWithdraws(
        address vault,
        address user
    ) external view returns (PendingWithdraw[] memory pendingWithdraws);

    /**
     * @notice Get claimable rewards for a staker across multiple reward tokens.
     * @param staker Address of the staker.
     * @param rewards Address of the rewards contract.
     * @param vault Address of the vault.
     * @param rewardsTokens Array of reward token addresses to check.
     * @return Array of claimable amounts per token.
     */
    function getStakerClaimableRewards(
        address staker,
        address rewards,
        address vault,
        address[] memory rewardsTokens
    ) external view returns (ClaimAmountsPerToken[] memory);

    /**
     * @notice Get claimable reward for a staker for a specific reward token.
     * @param staker Address of the staker.
     * @param rewards Address of the rewards contract.
     * @param vault Address of the vault.
     * @param rewardsToken Address of the reward token.
     * @return Claimable amount for the specified token.
     */
    function getStakerClaimableReward(
        address staker,
        address rewards,
        address vault,
        address rewardsToken
    ) external view returns (ClaimAmountsPerToken memory);

    /**
     * @notice Get claimable reward for a staker for a specific reward token within an epoch range.
     * @param staker Address of the staker.
     * @param rewards Address of the rewards contract.
     * @param vault Address of the vault.
     * @param rewardsToken Address of the reward token.
     * @param fromEpoch Starting epoch (inclusive).
     * @param toEpoch Ending epoch (exclusive).
     * @return Claimable amount for the specified token in the range.
     */
    function getStakerClaimableRewardInRange(
        address staker,
        address rewards,
        address vault,
        address rewardsToken,
        uint48 fromEpoch,
        uint48 toEpoch
    ) external view returns (ClaimAmountsPerToken memory);
}
