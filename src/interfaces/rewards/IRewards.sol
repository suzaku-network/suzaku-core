// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

struct DistributionBatch {
    uint256 lastProcessedOperator;
    bool isComplete;
}

/**
 * @title IRewards
 * @notice Interface for managing distribution and claiming of staking rewards
 */
interface IRewards {
    // ============================
    //         ERRORS
    // ============================
    /**
     * @dev Error thrown when trying to distribute rewards for an epoch that has already been processed
     * @param epoch The epoch for which rewards were already distributed
     */
    error RewardsAlreadyDistributed(uint48 epoch);

    /**
     * @dev Error thrown when trying to distribute rewards too early
     * @param epoch Current epoch
     * @param requiredEpoch Minimum required epoch for distribution
     */
    error RewardsDistributionTooEarly(uint48 epoch, uint48 requiredEpoch);

    /**
     * @dev Error thrown when a user attempts to claim rewards but has no claimable balance
     * @param user Address of user attempting to claim
     */
    error NoRewardsToClaim(address user);

    /**
     * @dev Error thrown when the recipient address is invalid (zero address)
     * @param recipient Invalid recipient address
     */
    error InvalidRecipient(address recipient);

    /**
     * @dev Error thrown when the user has already claimed all available rewards
     * @param staker Address of the staker
     * @param epoch Epoch at which they last claimed
     */
    error AlreadyClaimedForLatestEpoch(address staker, uint48 epoch);

    /**
     * @dev Error thrown when an invalid rewards token address is provided
     * @param rewardsToken Invalid rewards token address
     */
    error InvalidRewardsToken(address rewardsToken);

    /**
     * @dev Error thrown when an invalid rewards amount is provided
     * @param rewardsAmount Invalid rewards amount
     */
    error InvalidRewardsAmount(uint256 rewardsAmount);

    /**
     * @dev Error thrown when an invalid number of epochs is provided
     * @param numberOfEpochs Invalid number of epochs
     */
    error InvalidNumberOfEpochs(uint48 numberOfEpochs);

    /**
     * @dev Error thrown when an invalid share percentage is provided
     * @param share Invalid share percentage
     */
    error InvalidShare(uint16 share);

    /**
     * @dev Error thrown when an invalid fee percentage is provided
     * @param fee Invalid fee percentage
     */
    error InvalidFee(uint16 fee);

    /**
     * @dev Error thrown when an invalid minimum uptime is provided
     * @param minUptime Invalid minimum uptime
     */
    error InvalidMinUptime(uint256 minUptime);

    /**
     * @dev Error thrown when a vault's asset class cannot be found
     * @param vault Address of the vault
     */
    error AssetClassNotFound(address vault);

    /**
     * @dev Error thrown when trying to operate on an unfinished epoch
     * @param epoch Unfinished epoch
     */
    error EpochNotFinished(uint48 epoch);

    /**
     * @dev Error thrown when an invalid operator address is provided
     * @param operator Invalid operator address
     */
    error InvalidOperator(address operator);

    /**
     * @dev Error thrown when the operator does not have uptime set for the epoch
     * @param operator Address of the operator
     * @param epoch Epoch at which the operator's uptime was checked
     */
    error OperatorUptimeNotSet(address operator, uint48 epoch);

    /**
     * @dev Error thrown when the vault stake is zero, preventing reward computation
     * @param vault Address of the vault with zero stake
     * @param epoch Epoch for which the stake was checked
     */
    error ZeroVaultStake(address vault, uint48 epoch);

    /**
     * @notice Error thrown when a fee percentage exceeds 100%
     * @param fee Fee percentage that exceeds 100%
     */
    error FeePercentageTooHigh(uint16 fee);

    /**
     * @notice Error thrown when the sum of all fees exceeds 100%
     * @param totalFees Sum of all fees that exceeds 100%
     */
    error TotalFeesExceed100(uint16 totalFees);

    /**
     * @notice Error thrown when trying to distribute rewards for an epoch that has already been completed
     * @param epoch Epoch for which rewards were already distributed
     */
    error AlreadyCompleted(uint48 epoch);

    /**
     * @notice Error thrown when trying to claim rewards for an epoch that has not been distributed
     * @param epoch Epoch for which rewards are not distributed
     */
    error DistributionNotComplete(uint48 epoch);

    /**
     * @notice Error thrown when trying to claim rewards for an epoch that is still claimable
     * @param epoch Epoch for which rewards are still claimable
     */
    error EpochStillClaimable(uint48 epoch);

    // ============================
    //         EVENTS
    // ============================
    /**
     * @notice Emitted when rewards are distributed for an epoch
     * @param epoch Epoch for which rewards were distributed
     */
    event RewardsDistributed(uint48 indexed epoch);

    /**
     * @notice Emitted when a user claims their staking rewards
     * @param rewardsToken Address of the reward token
     * @param recipient Address receiving the claimed rewards
     * @param amount Amount of reward tokens claimed
     */
    event RewardsClaimed(address indexed rewardsToken, address indexed recipient, uint256 amount);

    /**
     * @notice Emitted when a curator claims their fee
     * @param rewardsToken Address of the reward token
     * @param recipient Address receiving the curator fee
     * @param amount Amount of reward tokens claimed
     */
    event CuratorFeeClaimed(address indexed rewardsToken, address indexed recipient, uint256 amount);

    /**
     * @notice Emitted when an operator claims their fee
     * @param rewardsToken Address of the reward token
     * @param recipient Address receiving the operator fee
     * @param amount Amount of reward tokens claimed
     */
    event OperatorFeeClaimed(address indexed rewardsToken, address indexed recipient, uint256 amount);

    /**
     * @notice Emitted when the protocol owner claims fees
     * @param rewardsToken Address of the reward token
     * @param recipient Address receiving the protocol fee
     * @param amount Amount of reward tokens claimed
     */
    event ProtocolFeeClaimed(address indexed rewardsToken, address indexed recipient, uint256 amount);

    /**
     * @notice Emitted when a new admin role is assigned
     * @param newAdmin Address of the new admin
     */
    event AdminRoleAssigned(address indexed newAdmin);

    /**
     * @notice Emitted when a new protocol owner is set
     * @param newProtocolOwner Address of the new protocol owner
     */
    event ProtocolOwnerUpdated(address indexed newProtocolOwner);

    /**
     * @notice Emitted when the protocol fee is updated
     * @param newFee New protocol fee in basis points
     */
    event ProtocolFeeUpdated(uint16 newFee);

    /**
     * @notice Emitted when the operator fee is updated
     * @param newFee New operator fee in basis points
     */
    event OperatorFeeUpdated(uint16 newFee);

    /**
     * @notice Emitted when the curator fee is updated
     * @param newFee New curator fee in basis points
     */
    event CuratorFeeUpdated(uint16 newFee);

    /**
     * @notice Emitted when the reward share percentage for an asset class is updated
     * @param assetClassId ID of the asset class
     * @param rewardsPercentage New reward percentage in basis points
     */
    event RewardsShareUpdated(uint96 indexed assetClassId, uint16 rewardsPercentage);

    /**
     * @notice Emitted when rewards are set for a range of epochs
     * @param startEpoch Starting epoch for which rewards were set
     * @param numberOfEpochs Number of epochs affected
     * @param rewardsToken Address of the reward token
     * @param rewardsAmount Amount of rewards allocated per epoch
     */
    event RewardsAmountSet(
        uint48 indexed startEpoch, uint256 numberOfEpochs, address indexed rewardsToken, uint256 rewardsAmount
    );

    /**
     * @notice Emitted when undistributed rewards are claimed
     * @param epoch Epoch for which undistributed rewards were claimed
     * @param rewardsToken Address of the reward token
     * @param recipient Address receiving the undistributed rewards
     * @param amount Amount of reward tokens claimed
     */
    event UndistributedRewardsClaimed(
        uint48 indexed epoch, address indexed rewardsToken, address indexed recipient, uint256 amount
    );

    // ============================
    //         FUNCTIONS
    // ============================
    /**
     * @notice Distributes rewards for a given epoch
     * @dev Rewards are allocated to operators, curators, and stakers based on predefined logic
     * @param epoch Epoch for which rewards should be distributed
     * @param batchSize Size of the batch to distribute rewards in
     */
    function distributeRewards(uint48 epoch, uint48 batchSize) external;

    /**
     * @notice Claims staking rewards for a user
     * @param rewardsToken Address of the reward token
     * @param recipient Address receiving the claimed rewards
     */
    function claimRewards(address rewardsToken, address recipient) external;

    /**
     * @notice Claims accumulated curator fees
     * @param rewardsToken Address of the reward token
     * @param recipient Address receiving the curator fee
     */
    function claimCuratorFee(address rewardsToken, address recipient) external;

    /**
     * @notice Claims accumulated operator fees
     * @param rewardsToken Address of the reward token
     * @param recipient Address receiving the operator fee
     */
    function claimOperatorFee(address rewardsToken, address recipient) external;

    /**
     * @notice Claims accumulated protocol fees
     * @dev Only callable by an address with the PROTOCOL_OWNER_ROLE
     * @param rewardsToken Address of the reward token
     * @param recipient Address receiving the protocol fee
     */
    function claimProtocolFee(address rewardsToken, address recipient) external;

    /**
     * @notice Grants the admin role to a new address
     * @dev Only callable by an address with the DEFAULT_ADMIN_ROLE
     * @param newAdmin Address to be granted the admin role
     */
    function setAdminRole(
        address newAdmin
    ) external;

    /**
     * @notice Sets a new protocol owner
     * @dev Only callable by an address with the DEFAULT_ADMIN_ROLE
     * @param newProtocolOwner Address of the new protocol owner
     */
    function setProtocolOwner(
        address newProtocolOwner
    ) external;

    /**
     * @notice Sets a new minimum required uptime
     * @dev Only callable by an address with the ADMIN_ROLE
     * @param uptime Uptime for an epoch in seconds
     */
    function setMinRequiredUptime(
        uint256 uptime
    ) external;

    /**
     * @notice Updates the protocol fee percentage
     * @dev Only callable by an address with the ADMIN_ROLE
     * @param newFee New protocol fee percentage in basis points
     */
    function updateProtocolFee(
        uint16 newFee
    ) external;

    /**
     * @notice Updates the operator fee percentage
     * @dev Only callable by an address with the ADMIN_ROLE
     * @param newFee New operator fee percentage in basis points
     */
    function updateOperatorFee(
        uint16 newFee
    ) external;

    /**
     * @notice Updates the curator fee percentage
     * @dev Only callable by an address with the ADMIN_ROLE
     * @param newFee New curator fee percentage in basis points
     */
    function updateCuratorFee(
        uint16 newFee
    ) external;

    /**
     * @notice Sets the rewards share percentage for a specific asset class
     * @dev Only callable by an address with the ADMIN_ROLE
     * @param assetClassId ID of the asset class
     * @param rewardsPercentage New reward percentage in basis points
     */
    function setRewardsShareForAssetClass(uint96 assetClassId, uint16 rewardsPercentage) external;

    /**
     * @notice Sets the rewards amount for a range of epochs
     * @dev Only callable by an address with the ADMIN_ROLE
     * @param startEpoch The starting epoch for which rewards should be set
     * @param numberOfEpochs The number of epochs for which the rewards should be applied
     * @param rewardsToken The address of the reward token
     * @param rewardsAmount The total reward amount for each epoch
     */
    function setRewardsAmountForEpochs(
        uint48 startEpoch,
        uint48 numberOfEpochs,
        address rewardsToken,
        uint256 rewardsAmount
    ) external;

    /**
     *  @notice Retrieves the rewards tokens and their respective amounts for a given epoch
     *  @dev This function allows external callers to view the rewards distributed per token for a specific epoch
     *  @param epoch The epoch for which to fetch reward token information
     *  @return tokens An array of reward token addresses
     *  @return amounts An array of reward amounts corresponding to each token in the `tokens` array
     */
    function getRewardsAmountPerTokenFromEpoch(
        uint48 epoch
    ) external view returns (address[] memory tokens, uint256[] memory amounts);
}
