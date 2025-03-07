// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

/**
 * @title IRewards
 * @notice Interface for the Rewards contract, which manages the distribution and claiming of staking rewards.
 */
interface IRewards {
    // ============================
    //         ERRORS
    // ============================
    /**
     * @dev Error thrown when trying to distribute rewards for an epoch that has already been processed.
     * @param epoch The epoch for which rewards are already distributed.
     */
    error RewardsAlreadyDistributed(uint48 epoch);

    /**
     * @dev Error thrown when trying to distribute rewards too early.
     * @param epoch The epoch being processed.
     * @param requiredEpoch The minimum epoch that must have passed before distribution.
     */
    error RewardsDistributionTooEarly(uint48 epoch, uint48 requiredEpoch);

    /**
     * @dev Error thrown when a user attempts to claim rewards but has no claimable balance.
     * @param user The address of the user attempting to claim.
     */
    error NoRewardsToClaim(address user);

    /**
     * @dev Error thrown when the recipient address is invalid (zero address).
     * @param recipient The invalid recipient address.
     */
    error InvalidRecipient(address recipient);

    /**
     * @dev Error thrown when the user has already claimed all available rewards.
     * @param staker The staker address.
     * @param epoch The epoch at which they last claimed.
     */
    error AlreadyClaimedForLatestEpoch(address staker, uint48 epoch);

    /**
     * @dev Error thrown when the operator does not have
     * @param operator The address of the operator.
     * @param epoch The epoch at which the operator's uptime was checked.
     */
    error OperatorUptimeNotSet(address operator, uint48 epoch);

    /**
     * @dev Error thrown when the vault stake is zero, preventing valid reward computation.
     * @param vault The vault in which the stake is zero.
     * @param epoch The epoch for which the stake was checked.
     */
    error ZeroVaultStake(address vault, uint48 epoch);

    // ============================
    //         EVENTS
    // ============================
    /**
     * @notice Emitted when rewards are distributed for an epoch.
     * @param epoch The epoch for which rewards were distributed.
     */
    event RewardsDistributed(uint48 indexed epoch);

    event DEBUG(uint256 indexed value);

    event DEBUG(address indexed value);

    /**
     * @notice Emitted when a user claims their staking rewards.
     * @param rewardToken The address of the reward token.
     * @param recipient The address receiving the claimed rewards.
     * @param amount The amount of rewards claimed.
     */
    event RewardsClaimed(address indexed rewardToken, address indexed recipient, uint256 amount);

    /**
     * @notice Emitted when a curator claims their fee.
     * @param rewardsToken The address of the reward token.
     * @param recipient The address receiving the curator fee.
     * @param amount The amount of rewards claimed.
     */
    event CuratorFeeClaimed(address indexed rewardsToken, address indexed recipient, uint256 amount);

    /**
     * @notice Emitted when an operator claims their fee.
     * @param rewardsToken The address of the reward token.
     * @param recipient The address receiving the operator fee.
     * @param amount The amount of rewards claimed.
     */
    event OperatorFeeClaimed(address indexed rewardsToken, address indexed recipient, uint256 amount);

    /**
     * @notice Emitted when the protocol owner claims fees.
     * @param rewardsToken The address of the reward token.
     * @param recipient The address receiving the protocol fee.
     * @param amount The amount of rewards claimed.
     */
    event ProtocolFeeClaimed(address indexed rewardsToken, address indexed recipient, uint256 amount);

    /**
     * @notice Emitted when a new admin role is assigned.
     * @param newAdmin The address of the new admin.
     */
    event AdminRoleAssigned(address indexed newAdmin);

    /**
     * @notice Emitted when a new protocol owner is set.
     * @param newProtocolOwner The address of the new protocol owner.
     */
    event ProtocolOwnerUpdated(address indexed newProtocolOwner);

    /**
     * @notice Emitted when the protocol fee is updated.
     * @param newFee The new protocol fee in basis points.
     */
    event ProtocolFeeUpdated(uint16 newFee);

    /**
     * @notice Emitted when the operator fee is updated.
     * @param newFee The new operator fee in basis points.
     */
    event OperatorFeeUpdated(uint16 newFee);

    /**
     * @notice Emitted when the curator fee is updated.
     * @param newFee The new curator fee in basis points.
     */
    event CuratorFeeUpdated(uint16 newFee);

    /**
     * @notice Emitted when the reward share percentage for an asset class is updated.
     * @param assetClassId The ID of the asset class.
     * @param rewardsPercentage The new reward percentage in basis points.
     */
    event RewardsShareUpdated(uint96 indexed assetClassId, uint16 rewardsPercentage);

    /**
     * @notice Emitted when rewards are set for a range of epochs.
     * @param startEpoch The starting epoch for which rewards were set.
     * @param numberOfEpochs The number of epochs affected.
     * @param rewardsToken The address of the reward token.
     * @param rewardsAmount The amount of rewards allocated per epoch.
     */
    event RewardsAmountSet(
        uint48 indexed startEpoch, uint256 numberOfEpochs, address indexed rewardsToken, uint256 rewardsAmount
    );

    // ============================
    //         FUNCTIONS
    // ============================
    /**
     * @notice Distributes rewards for a given epoch.
     * @dev Rewards are allocated to operators, curators, and stakers based on predefined logic.
     * @param epoch The epoch for which rewards should be distributed.
     */
    function distributeRewards(
        uint48 epoch
    ) external;

    /**
     * @notice Allows a user to claim their staking rewards.
     * @param rewardToken The address of the reward token to be claimed.
     * @param recipient The address to which the claimed rewards should be sent.
     */
    function claimRewards(address rewardToken, address recipient) external;

    /**
     * @notice Allows a curator to claim their accumulated curator fee.
     * @param rewardsToken The address of the reward token to be claimed.
     * @param recipient The address to which the claimed rewards should be sent.
     */
    function claimCuratorFee(address rewardsToken, address recipient) external;

    /**
     * @notice Allows an operator to claim their accumulated operator fee.
     * @param rewardsToken The address of the reward token to be claimed.
     * @param recipient The address to which the claimed rewards should be sent.
     */
    function claimOperatorFee(address rewardsToken, address recipient) external;

    /**
     * @notice Allows the protocol owner to claim accumulated protocol fees.
     * @dev Only callable by an address with the PROTOCOL_OWNER_ROLE.
     * @param rewardsToken The address of the reward token to be claimed.
     * @param recipient The address to which the claimed rewards should be sent.
     */
    function claimProtocolFee(address rewardsToken, address recipient) external;

    /**
     * @notice Grants the admin role to a new address.
     * @dev Only callable by an address with the DEFAULT_ADMIN_ROLE.
     * @param newAdmin The address to be granted the admin role.
     */
    function setAdminRole(
        address newAdmin
    ) external;

    /**
     * @notice Sets a new protocol owner.
     * @dev Only callable by an address with the DEFAULT_ADMIN_ROLE.
     * @param newProtocolOwner The address of the new protocol owner.
     */
    function setProtocolOwner(
        address newProtocolOwner
    ) external;

    /**
     * @notice Sets a new min required uptime.
     * @dev Only callable by an address with the ADMIN_ROLE.
     * @param uptime Uptime for an epoch in seconds.
     */
    function setMinRequiredUptime(
        uint256 uptime
    ) external;

    /**
     * @notice Updates the protocol fee percentage.
     * @dev Only callable by an address with the ADMIN_ROLE.
     * @param fee The new protocol fee percentage (in basis points).
     */
    function updateProtocolFee(
        uint16 fee
    ) external;

    /**
     * @notice Updates the operator fee percentage.
     * @dev Only callable by an address with the ADMIN_ROLE.
     * @param fee The new operator fee percentage (in basis points).
     */
    function updateOperatorFee(
        uint16 fee
    ) external;

    /**
     * @notice Updates the curator fee percentage.
     * @dev Only callable by an address with the ADMIN_ROLE.
     * @param fee The new curator fee percentage (in basis points).
     */
    function updateCuratorFee(
        uint16 fee
    ) external;

    /**
     * @notice Sets the rewards share percentage for a specific asset class.
     * @dev Only callable by an address with the ADMIN_ROLE.
     * @param assetClassId The ID of the asset class.
     * @param rewardsPercentage The new reward percentage for the asset class (in basis points).
     */
    function setRewardsShareForAssetClass(uint96 assetClassId, uint16 rewardsPercentage) external;

    /**
     * @notice Sets the rewards amount for a range of epochs.
     * @dev Only callable by an address with the ADMIN_ROLE.
     * @param startEpoch The starting epoch for which rewards should be set.
     * @param numberOfEpochs The number of epochs for which the rewards should be applied.
     * @param rewardsToken The address of the reward token.
     * @param rewardsAmount The total reward amount for each epoch.
     */
    function setRewardsAmountForEpochs(
        uint48 startEpoch,
        uint256 numberOfEpochs,
        address rewardsToken,
        uint256 rewardsAmount
    ) external;

    /**
     *  @notice Retrieves the rewards tokens and their respective amounts for a given epoch.
     *  @dev This function allows external callers to view the rewards distributed per token for a specific epoch.
     *  @param epoch The epoch for which to fetch reward token information.
     *  @return tokens An array of reward token addresses.
     *  @return amounts An array of reward amounts corresponding to each token in the `tokens` array.
     */
    function getRewardsAmountPerTokenFromEpoch(
        uint48 epoch
    ) external view returns (address[] memory tokens, uint256[] memory amounts);
}
