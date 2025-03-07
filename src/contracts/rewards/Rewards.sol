// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";

import {AvalancheL1Middleware} from "../middleware/AvalancheL1Middleware.sol";
import {MiddlewareVaultManager} from "../middleware/MiddlewareVaultManager.sol";
import {UptimeTracker} from "./UptimeTracker.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {BaseDelegator} from "../delegator/BaseDelegator.sol";
import {IVaultTokenized} from "../../interfaces/vault/IVaultTokenized.sol";
import {VaultTokenized} from "../vault/VaultTokenized.sol";
import {IRewards} from "../../interfaces/rewards/IRewards.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract Rewards is AccessControlUpgradeable, IRewards {
    using SafeERC20 for IERC20;
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    /// @notice Basis points denominator (1e4 = 100%)
    uint16 private constant BASIS_POINTS_DENOMINATOR = 10_000;

    /// @notice Roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant PROTOCOL_OWNER_ROLE = keccak256("PROTOCOL_OWNER_ROLE");

    /// @notice Protocol, operator and curator fees (in basis points)
    uint16 public protocolFee;
    uint16 public operatorFee;
    uint16 public curatorFee;

    /// @notice External contract references
    AvalancheL1Middleware public l1Middleware;
    MiddlewareVaultManager public middlewareVaultManager;
    UptimeTracker public uptimeTracker;

    /// @notice Epoch duration in seconds
    uint48 public epochDuration;

    /// @notice Min required uptime in seconds
    /// @dev If uptime less than 80% -> rewards = 0
    uint256 public minRequiredUptime;

    /// @notice Maps an epoch to a rewards' token and its reward amount
    mapping(uint48 epoch => EnumerableMap.AddressToUintMap rewardsTokenToAmount) private rewardsAmountPerTokenFromEpoch;

    /// @notice Protocol's rewards tracking
    mapping(address rewardsToken => uint256 rewardsAmount) public protocolRewardsAmountPerToken;

    /// @notice Operators' rewards tracking
    mapping(address operator => mapping(address rewardsToken => uint256 rewardsAmount)) public operatorsRewardsPerToken;

    /// @notice Curators' rewards tracking
    mapping(address curator => mapping(address rewardsToken => uint256 rewardsAmount)) public curatorsRewardsPerToken;

    /// @notice Vaults' rewards tracking
    mapping(uint48 epoch => mapping(address vault => mapping(address rewardsToken => uint256 rewardsAmount))) public
        vaultsRewardsPerTokenPerEpoch;

    /// @notice Stakers' last epoch rewards claimed
    mapping(address staker => uint48 epoch) public lastEpochClaimed;

    /// @notice Rewards share per asset class (in basis points)
    mapping(uint96 assetClass => uint16 rewardsShare) public rewardsSharePerAssetClass;

    /// @notice Rewards amount per asset class per rewards' token and per epoch
    mapping(uint48 epoch => mapping(uint96 assetClass => mapping(address rewardsToken => uint256 rewardsAmount))) public
        rewardsPerAssetClassPerTokenPerEpoch;

    /// @notice Tracks whether the operators' rewards have been distributed for an epoch
    mapping(uint48 epoch => mapping(address operator => bool distributed)) public operatorsRewardsDistributed;

    /// @notice Tracks whether the vaults' rewards have been distributed for an epoch and a rewards' token
    mapping(uint48 epoch => mapping(address rewardsToken => mapping(address vault => bool distributed))) public
        vaultsRewardsDistributed;

    /// @notice Tracks which vault delegates to which operator for an epoch
    mapping(uint48 epoch => mapping(address vault => address operator)) public vaultDelegatingToOperator;

    function initialize(
        address admin_,
        address protocolOwner_,
        address l1Middleware_,
        address middlewareVaultManager_,
        address uptimeTracker_,
        uint16 protocolFee_,
        uint16 curatorFee_,
        uint16 operatorFee_
    ) public initializer {
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
        _grantRole(PROTOCOL_OWNER_ROLE, protocolOwner_);

        middlewareVaultManager = MiddlewareVaultManager(middlewareVaultManager_);
        l1Middleware = AvalancheL1Middleware(l1Middleware_);
        uptimeTracker = UptimeTracker(uptimeTracker_);
        epochDuration = l1Middleware.EPOCH_DURATION();

        protocolFee = protocolFee_;
        curatorFee = curatorFee_;
        operatorFee = operatorFee_;
    }

    /// @inheritdoc IRewards
    function distributeRewards(
        uint48 epoch
    ) external _distributeEpochRewardsPerAssetClass(epoch) {
        // revert if epoch too recent
        uint48 currentEpoch = l1Middleware.getCurrentEpoch();
        if (currentEpoch < (epoch + 1)) {
            revert RewardsDistributionTooEarly(epoch, epoch + 1);
        }
        // fetch operators
        address[] memory operators = l1Middleware.getAllOperators();
        // get reward tokens
        address[] memory rewardTokens = rewardsAmountPerTokenFromEpoch[epoch].keys();

        for (uint256 i = 0; i < operators.length; i++) {
            for (uint256 j = 0; j < rewardTokens.length; j++) {
                // get the entire available rewards
                uint256 availableRewards = _computeAvailableRewards(epoch, operators[i], rewardTokens[j]);
                // compute operator rewards with the fee
                uint256 operatorRewards = Math.mulDiv(availableRewards, operatorFee, BASIS_POINTS_DENOMINATOR);
                // set the operator rewards if rewards were not already distributed
                bool rewardDistributed = operatorsRewardsDistributed[epoch][operators[i]];
                if (!rewardDistributed) operatorsRewardsPerToken[rewardTokens[j]][operators[i]] += operatorRewards;
                // compute remaining rewards
                availableRewards -= operatorRewards;
                // compute vaults rewards
                _computeVaultsRewards(operators[i], epoch, rewardTokens[j], availableRewards);
            }
            // mark operator's rewards as distributed for said epoch
            operatorsRewardsDistributed[epoch][operators[i]] = true;
        }

        emit RewardsDistributed(epoch);
    }

    /// @inheritdoc IRewards
    function claimRewards(address rewardToken, address recipient) external {
        if (recipient == address(0)) {
            revert InvalidRecipient(recipient);
        }
        uint48 lastClaimedEpoch = lastEpochClaimed[msg.sender];
        uint48 currentEpoch = l1Middleware.getCurrentEpoch();

        if (lastClaimedEpoch >= currentEpoch - 1) {
            revert AlreadyClaimedForLatestEpoch(msg.sender, lastClaimedEpoch);
        }

        uint256 claimableRewards = 0;

        for (uint48 i = lastClaimedEpoch + 1; i < currentEpoch; i++) {
            address[] memory vaults = _getStakerVaults(msg.sender, i);
            uint48 epochTs = l1Middleware.getEpochStartTs(i);
            for (uint256 j = 0; j < vaults.length; j++) {
                // get vault asset class
                uint96 vaultAssetClass = _getVaultAssetClassId(vaults[i]);
                // fetch stakes
                uint256 stakerStake = IVaultTokenized(vaults[i]).activeBalanceOfAt(msg.sender, epochTs, new bytes(0));
                uint256 vaultStake = BaseDelegator(IVaultTokenized(vaults[i]).delegator()).stakeAt(
                    l1Middleware.L1_VALIDATOR_MANAGER(),
                    vaultAssetClass,
                    vaultDelegatingToOperator[i][vaults[i]],
                    epochTs,
                    new bytes(0)
                );
                // if vaultStake is 0, reverts to prevent division by 0
                if (vaultStake == 0) {
                    revert ZeroVaultStake(vaults[j], i);
                }
                // compute staker share
                uint256 stakerShare = Math.mulDiv(stakerStake, vaultStake, BASIS_POINTS_DENOMINATOR);
                uint256 availableRewardsForVault = vaultsRewardsPerTokenPerEpoch[i][vaults[j]][rewardToken];
                // compute total staker rewards
                uint256 stakerRewards = Math.mulDiv(availableRewardsForVault, BASIS_POINTS_DENOMINATOR, stakerShare);
                // deduct curator fee
                uint256 curatorRewards = Math.mulDiv(stakerRewards, BASIS_POINTS_DENOMINATOR, curatorFee);
                curatorsRewardsPerToken[VaultTokenized(vaults[j]).owner()][rewardToken] += curatorRewards;
                stakerRewards -= curatorRewards;
                claimableRewards += stakerRewards;
            }
        }

        // if claimableRewards still 0, reverts to prevent unnecessary transaction and gas waste
        if (claimableRewards == 0) {
            revert NoRewardsToClaim(msg.sender);
        }

        IERC20(rewardToken).safeTransfer(recipient, claimableRewards);
        lastEpochClaimed[msg.sender] = currentEpoch - 1;
    }

    /// @inheritdoc IRewards
    function claimCuratorFee(address rewardsToken, address recipient) external {
        if (recipient == address(0)) {
            revert InvalidRecipient(recipient);
        }
        uint256 rewardsToClaim = curatorsRewardsPerToken[rewardsToken][msg.sender];
        if (rewardsToClaim == 0) {
            revert NoRewardsToClaim(msg.sender);
        }

        IERC20(rewardsToken).safeTransfer(recipient, rewardsToClaim);
        curatorsRewardsPerToken[rewardsToken][msg.sender] = 0;
    }

    /// @inheritdoc IRewards
    function claimOperatorFee(address rewardsToken, address recipient) external {
        if (recipient == address(0)) {
            revert InvalidRecipient(recipient);
        }
        uint256 rewardsToClaim = operatorsRewardsPerToken[rewardsToken][msg.sender];
        if (rewardsToClaim == 0) {
            revert NoRewardsToClaim(msg.sender);
        }

        IERC20(rewardsToken).safeTransfer(recipient, rewardsToClaim);
        operatorsRewardsPerToken[rewardsToken][msg.sender] = 0;
    }

    /// @inheritdoc IRewards
    function claimProtocolFee(address rewardsToken, address recipient) external onlyRole(PROTOCOL_OWNER_ROLE) {
        if (recipient == address(0)) {
            revert InvalidRecipient(recipient);
        }
        uint256 rewardsToClaim = protocolRewardsAmountPerToken[rewardsToken];
        if (rewardsToClaim == 0) {
            revert NoRewardsToClaim(msg.sender);
        }

        IERC20(rewardsToken).safeTransfer(recipient, rewardsToClaim);
        protocolRewardsAmountPerToken[rewardsToken] = 0;
    }

    /// @inheritdoc IRewards
    function setMinRequiredUptime(
        uint256 uptime
    ) external onlyRole(ADMIN_ROLE) {
        minRequiredUptime = uptime;
    }

    /// @inheritdoc IRewards
    function setAdminRole(
        address newAdmin
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(ADMIN_ROLE, newAdmin);
        revokeRole(ADMIN_ROLE, msg.sender);
        emit AdminRoleAssigned(newAdmin);
    }

    /// @inheritdoc IRewards
    function setProtocolOwner(
        address newProtocolOwner
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(PROTOCOL_OWNER_ROLE, newProtocolOwner);
        emit ProtocolOwnerUpdated(newProtocolOwner);
    }

    /// @inheritdoc IRewards
    function updateProtocolFee(
        uint16 fee
    ) external onlyRole(ADMIN_ROLE) {
        protocolFee = fee;
        emit ProtocolFeeUpdated(fee);
    }

    /// @inheritdoc IRewards
    function updateOperatorFee(
        uint16 fee
    ) external onlyRole(ADMIN_ROLE) {
        operatorFee = fee;
        emit OperatorFeeUpdated(fee);
    }

    /// @inheritdoc IRewards
    function updateCuratorFee(
        uint16 fee
    ) external onlyRole(ADMIN_ROLE) {
        curatorFee = fee;
        emit CuratorFeeUpdated(fee);
    }

    /// @inheritdoc IRewards
    function setRewardsShareForAssetClass(
        uint96 assetClassId,
        uint16 rewardsPercentage
    ) external onlyRole(ADMIN_ROLE) {
        rewardsSharePerAssetClass[assetClassId] = rewardsPercentage;
        emit RewardsShareUpdated(assetClassId, rewardsPercentage);
    }

    /// @inheritdoc IRewards
    function setRewardsAmountForEpochs(
        uint48 startEpoch,
        uint256 numberOfEpochs,
        address rewardsToken,
        uint256 rewardsAmount
    ) external onlyRole(ADMIN_ROLE) {
        uint256 protocolRewards = (rewardsAmount * protocolFee) / BASIS_POINTS_DENOMINATOR;

        for (uint48 i = 0; i < numberOfEpochs; i++) {
            protocolRewardsAmountPerToken[rewardsToken] += protocolRewards;
            rewardsAmountPerTokenFromEpoch[startEpoch + i].set(rewardsToken, rewardsAmount - protocolRewards);
        }

        emit RewardsAmountSet(startEpoch, numberOfEpochs, rewardsToken, rewardsAmount);
    }

    /// @inheritdoc IRewards
    function getRewardsAmountPerTokenFromEpoch(
        uint48 epoch
    ) external view returns (address[] memory tokens, uint256[] memory amounts) {
        uint256 length = rewardsAmountPerTokenFromEpoch[epoch].length();
        tokens = new address[](length);
        amounts = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            (tokens[i], amounts[i]) = rewardsAmountPerTokenFromEpoch[epoch].at(i);
        }
    }

    /**
     * @dev Modifier to distribute epoch rewards per asset class.
     * @param epoch The epoch for which rewards are being distributed.
     */
    modifier _distributeEpochRewardsPerAssetClass(
        uint48 epoch
    ) {
        // fetch assetClasses from the L1 Middleware
        uint96[] memory assetClasses = _getAssetClassIds();
        // fetch the amount of rewards per token for the given epoch
        EnumerableMap.AddressToUintMap storage rewards = rewardsAmountPerTokenFromEpoch[epoch];

        for (uint256 i = 0; i < assetClasses.length; i++) {
            uint16 rewardsShare = rewardsSharePerAssetClass[assetClasses[i]];
            for (uint256 j = 0; j < rewards.length(); j++) {
                (address rewardToken, uint256 rewardAmount) = rewards.at(j);

                // compute rewards for the asset class at index i
                uint256 assetClassRewardAmount = Math.mulDiv(rewardsShare, rewardAmount, BASIS_POINTS_DENOMINATOR);

                // set the value in the mapping
                rewardsPerAssetClassPerTokenPerEpoch[epoch][assetClasses[i]][rewardToken] = assetClassRewardAmount;
            }
        }
        _;
    }

    /**
     * @dev Computes the available rewards for an operator in a given epoch.
     * @param epoch The epoch for which rewards are computed.
     * @param operator The address of the operator.
     * @param rewardToken The address of the reward token.
     * @return The total rewards available for the operator in the given epoch.
     */
    function _computeAvailableRewards(uint48 epoch, address operator, address rewardToken) internal returns (uint256) {
        // if operator uptime not set, reverts
        bool isUptimeSet = uptimeTracker.isOperatorUptimeSet(epoch, operator);
        if (!isUptimeSet) {
            revert OperatorUptimeNotSet(operator, epoch);
        }
        // compute operator uptime (in basis points)
        uint256 uptime = uptimeTracker.operatorUptimePerEpoch(epoch, operator);
        // if uptime less than minRequiredUptime returns 0
        if (uptime < minRequiredUptime) {
            return 0;
        }
        uint256 operatorUptime = Math.mulDiv(uptime, BASIS_POINTS_DENOMINATOR, epochDuration);
        emit DEBUG(operatorUptime);
        // fetch the asset classes
        uint96[] memory assetClasses = _getAssetClassIds();
        // total rewards for this operator, for this epoch and reward token
        uint256 totalRewards = 0;
        emit DEBUG(operator);

        for (uint256 i = 0; i < assetClasses.length; i++) {
            emit DEBUG(assetClasses[i]);
            // fetch amount of rewards available
            uint256 rewards = rewardsPerAssetClassPerTokenPerEpoch[epoch][assetClasses[i]][rewardToken];

            // fetch stakes
            uint256 operatorStake = _getOperatorTrueStake(epoch, operator, assetClasses[i]);
            emit DEBUG(operatorStake);
            uint256 l1TotalStake = l1Middleware.totalStakeCache(epoch, assetClasses[i]);
            emit DEBUG(l1TotalStake);

            // compute operator's weight on the L1 (in basis points)
            uint256 operatorWeight = Math.mulDiv(operatorStake, BASIS_POINTS_DENOMINATOR, l1TotalStake);
            operatorWeight = Math.mulDiv(operatorWeight, operatorUptime, BASIS_POINTS_DENOMINATOR);
            emit DEBUG(operatorWeight);

            // compute operator's rewards for this asset class
            uint256 operatorRewards = Math.mulDiv(operatorWeight, rewards, BASIS_POINTS_DENOMINATOR);
            emit DEBUG(operatorRewards);

            totalRewards += operatorRewards;
        }

        emit DEBUG(totalRewards);
        return totalRewards;
    }

    /**
     * @dev Computes and distributes vault rewards for an operator.
     * @param operator The address of the operator.
     * @param epoch The epoch for which vault rewards are computed.
     * @param rewardToken The address of the reward token.
     * @param totalVaultRewards The total rewards allocated for vaults.
     */
    function _computeVaultsRewards(
        address operator,
        uint48 epoch,
        address rewardToken,
        uint256 totalVaultRewards
    ) internal {
        // fetch the vaults
        address[] memory vaults = _getVaults(epoch);
        // get the epoch's start timestamp
        uint48 epochStartTs = l1Middleware.getEpochStartTs(epoch);

        // iterate through the vaults
        for (uint256 i = 0; i < vaults.length; i++) {
            // get the vault's asset class
            uint96 vaultAssetClass = _getVaultAssetClassId(vaults[i]);
            // get the vault's asset class rewards share set by the admin
            uint16 vaultAssetClassShare = rewardsSharePerAssetClass[vaultAssetClass];
            // get the vault's stake
            uint256 vaultStake = BaseDelegator(IVaultTokenized(vaults[i]).delegator()).stakeAt(
                l1Middleware.L1_VALIDATOR_MANAGER(), vaultAssetClass, operator, epochStartTs, new bytes(0)
            );
            // get the operator's stake
            uint256 operatorStake = _getOperatorTrueStake(epoch, operator, vaultAssetClass);
            // get the weight of the vault (vaultStake compared to operatorStake)
            uint256 vaultWeight = Math.mulDiv(vaultStake, operatorStake, BASIS_POINTS_DENOMINATOR);
            // get the vault's share of rewards (vaultWeight * assetClassShare)
            uint256 vaultRewardsShare = Math.mulDiv(vaultWeight, BASIS_POINTS_DENOMINATOR, vaultAssetClassShare);
            // compute the vault rewards
            uint256 vaultRewards =
                Math.mulDiv(totalVaultRewards, BASIS_POINTS_DENOMINATOR * vaults.length, vaultRewardsShare);
            // set the vault's rewards for this reward token and epoch
            // if rewards not already distributed
            bool rewardDistributed = vaultsRewardsDistributed[epoch][rewardToken][vaults[i]];
            if (!rewardDistributed) {
                vaultsRewardsPerTokenPerEpoch[epoch][vaults[i]][rewardToken] = vaultRewards;
                vaultsRewardsDistributed[epoch][rewardToken][vaults[i]] = true;
            }
            // link the vault to the operator
            vaultDelegatingToOperator[epoch][vaults[i]] = operator;
        }
    }

    /**
     * @dev Fetches the active vaults for a given epoch.
     * @param epoch The epoch for which vaults are fetched.
     * @return An array of active vault addresses.
     */
    function _getVaults(
        uint48 epoch
    ) internal view returns (address[] memory) {
        uint256 vaultCount = middlewareVaultManager.getVaultCount();
        uint48 epochStart = l1Middleware.getEpochStartTs(epoch);
        address[] memory vaults = new address[](vaultCount);

        for (uint256 i = 0; i < vaultCount; i++) {
            (address vault, uint48 enabledTime, uint48 disabledTime) = middlewareVaultManager.getVaultAtWithTimes(i);
            if (enabledTime != 0 && enabledTime <= epochStart && (disabledTime == 0 || disabledTime >= epochStart)) {
                vaults[i] = vault;
            }
        }

        return vaults;
    }

    /**
     * @dev Fetches the vaults where a staker has an active balance.
     * @param staker The address of the staker.
     * @param epoch The epoch for which vaults are fetched.
     * @return An array of vault addresses where the staker has an active balance.
     */
    function _getStakerVaults(address staker, uint48 epoch) internal view returns (address[] memory) {
        address[] memory vaults = _getVaults(epoch);
        uint48 epochStart = l1Middleware.getEpochStartTs(epoch);

        uint256 count = 0;

        // First pass: Count non-zero balance vaults
        for (uint256 i = 0; i < vaults.length; i++) {
            uint256 balance = IVaultTokenized(vaults[i]).activeBalanceOfAt(staker, epochStart, new bytes(0));
            if (balance > 0) {
                count++;
            }
        }

        // Create a new array with the exact number of valid vaults
        address[] memory validVaults = new address[](count);
        uint256 index = 0;

        // Second pass: Populate the new array
        for (uint256 i = 0; i < vaults.length; i++) {
            uint256 balance = IVaultTokenized(vaults[i]).activeBalanceOfAt(staker, epochStart, new bytes(0));
            if (balance > 0) {
                validVaults[index] = vaults[i];
                index++;
            }
        }

        return validVaults;
    }

    /**
     * @dev Fetches the active asset class IDs from L1 Middleware.
     * @return An array of asset class IDs.
     */
    function _getAssetClassIds() internal view returns (uint96[] memory) {
        (uint256 primary, uint256[] memory secondaries) = l1Middleware.getActiveAssetClasses();
        uint96[] memory assetClassIds = new uint96[](secondaries.length + 1);
        assetClassIds[0] = uint96(primary);
        for (uint256 i = 1; i <= secondaries.length; i++) {
            assetClassIds[i] = uint96(secondaries[i - 1]);
        }

        return assetClassIds;
    }

    /**
     * @dev Fetches the asset class ID for a given vault.
     * @param vault The address of the vault.
     * @return The asset class ID of the vault.
     */
    function _getVaultAssetClassId(
        address vault
    ) internal view returns (uint96) {
        address asset = vault;
        uint96[] memory assetClasses = _getAssetClassIds();
        for (uint256 i = 0; i < assetClasses.length; i++) {
            if (l1Middleware.isAssetInClass(assetClasses[i], asset)) {
                return assetClasses[i];
            }
        }
        return 1; // not sure, revert would be better
    }

    function _getOperatorTrueStake(uint48 epoch, address operator, uint96 assetClass) internal view returns (uint256) {
        // primary asset class
        if (assetClass == 1) {
            // fetch operator active nodes
            bytes32[] memory operatorActiveNodeIds = l1Middleware.getActiveNodesForEpoch(operator, epoch);
            uint256 operatorStake = 0;
            // iterate through nodes to compute operator's stake
            for (uint256 i = 0; i < operatorActiveNodeIds.length; i++) {
                operatorStake += l1Middleware.getNodeStake(epoch, operatorActiveNodeIds[i]);
            }
            return operatorStake;
        } else {
            return l1Middleware.getOperatorStake(operator, epoch, assetClass);
        }
    }
}
