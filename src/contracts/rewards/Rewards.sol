// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {AvalancheL1Middleware} from "../middleware/AvalancheL1Middleware.sol";
import {MiddlewareVaultManager} from "../middleware/MiddlewareVaultManager.sol";
import {UptimeTracker} from "./UptimeTracker.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {BaseDelegator} from "../delegator/BaseDelegator.sol";
import {IVaultTokenized} from "../../interfaces/vault/IVaultTokenized.sol";
import {VaultTokenized} from "../vault/VaultTokenized.sol";
import {IRewards, DistributionBatch} from "../../interfaces/rewards/IRewards.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract Rewards is AccessControlUpgradeable, IRewards {
    using SafeERC20 for IERC20;
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    using EnumerableSet for EnumerableSet.AddressSet;

    // Constants
    uint16 public constant BASIS_POINTS_DENOMINATOR = 10_000;
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant PROTOCOL_OWNER_ROLE = keccak256("PROTOCOL_OWNER_ROLE");

    // STATE VARIABLES
    // Fee configuration
    uint16 public protocolFee;
    uint16 public operatorFee;
    uint16 public curatorFee;

    // External contracts
    AvalancheL1Middleware public l1Middleware;
    MiddlewareVaultManager public middlewareVaultManager;
    UptimeTracker public uptimeTracker;

    uint48 public epochDuration;
    uint256 public minRequiredUptime;

    // Batch tracking
    mapping(uint48 epoch => DistributionBatch) public distributionBatches;

    // Share tracking
    mapping(uint48 epoch => mapping(address operator => uint256 share)) public operatorTotalShares;
    mapping(uint48 epoch => mapping(address operator => uint256 share)) public operatorShares;
    mapping(uint48 epoch => mapping(address vault => uint256 share)) public vaultShares;
    mapping(uint48 epoch => mapping(address curator => uint256 share)) public curatorShares;

    // Protocol rewards
    mapping(address rewardsToken => uint256 rewardsAmount) public protocolRewards;

    // Reward token amounts per epoch
    mapping(uint48 epoch => EnumerableMap.AddressToUintMap rewardsTokenToAmount) private rewardsAmountPerTokenFromEpoch;

    // Last claimed epoch tracking
    mapping(address staker => uint48 epoch) public lastEpochClaimedStaker;
    mapping(address curator => uint48 epoch) public lastEpochClaimedCurator;
    mapping(address protocolOwner => uint48 epoch) public lastEpochClaimedProtocol;
    mapping(address operator => uint48 epoch) public lastEpochClaimedOperator;

    // Asset class configuration
    mapping(uint96 assetClass => uint16 rewardsShare) public rewardsSharePerAssetClass;

    // Operators vault delegator mapping
    mapping(uint48 epoch => mapping(address vault => EnumerableSet.AddressSet operators)) private vaultOperators;

    // INITIALIZER
    function initialize(
        address admin_,
        address protocolOwner_,
        address payable l1Middleware_,
        address uptimeTracker_,
        uint16 protocolFee_,
        uint16 operatorFee_,
        uint16 curatorFee_
    ) public initializer {
        if (l1Middleware_ == address(0)) revert InvalidL1Middleware(l1Middleware_);
        if (uptimeTracker_ == address(0)) revert InvalidUptimeTracker(uptimeTracker_);
        if (admin_ == address(0)) revert InvalidAdmin(admin_);
        if (protocolOwner_ == address(0)) revert InvalidProtocolOwner(protocolOwner_);

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
        _grantRole(PROTOCOL_OWNER_ROLE, protocolOwner_);

        l1Middleware = AvalancheL1Middleware(l1Middleware_);
        middlewareVaultManager = MiddlewareVaultManager(l1Middleware.getVaultManager());
        uptimeTracker = UptimeTracker(uptimeTracker_);
        epochDuration = l1Middleware.EPOCH_DURATION();

        protocolFee = protocolFee_;
        operatorFee = operatorFee_;
        curatorFee = curatorFee_;
    }

    // EXTERNAL FUNCTIONS
    // Distribution
    /// @inheritdoc IRewards
    function distributeRewards(uint48 epoch, uint48 batchSize) external {
        DistributionBatch storage batch = distributionBatches[epoch];

        if (batch.isComplete) revert AlreadyCompleted(epoch);

        address[] memory operators = l1Middleware.getAllOperators();
        uint256 operatorCount = 0;

        for (uint256 i = batch.lastProcessedOperator; i < operators.length && operatorCount < batchSize; i++) {
            // Calculate operator's total share based on stake and uptime
            _calculateOperatorShare(epoch, operators[i]);

            // Calculate and store vault shares
            _calculateAndStoreVaultShares(epoch, operators[i]);

            batch.lastProcessedOperator = i + 1;
            operatorCount++;
        }

        if (batch.lastProcessedOperator >= operators.length) {
            batch.isComplete = true;
        }
    }

    // Claiming functions
    /// @inheritdoc IRewards
    function claimRewards(address rewardsToken, address recipient) external {
        if (recipient == address(0)) revert InvalidRecipient(recipient);

        uint48 lastClaimedEpoch = lastEpochClaimedStaker[msg.sender];
        uint48 currentEpoch = l1Middleware.getCurrentEpoch();

        if (currentEpoch > 0 && lastClaimedEpoch >= currentEpoch - 1) {
            revert AlreadyClaimedForLatestEpoch(msg.sender, lastClaimedEpoch);
        }

        uint256 totalRewards = 0;

        for (uint48 epoch = lastClaimedEpoch + 1; epoch < currentEpoch; epoch++) {
            address[] memory vaults = _getStakerVaults(msg.sender, epoch);
            uint48 epochTs = l1Middleware.getEpochStartTs(epoch);

            for (uint256 i = 0; i < vaults.length; i++) {
                address vault = vaults[i];
                uint256 vaultShare = vaultShares[epoch][vault];
                if (vaultShare == 0) continue;

                // Get staker's share of the vault
                uint256 stakerVaultShare = IVaultTokenized(vault).activeSharesOfAt(msg.sender, epochTs, new bytes(0));

                uint256 stakerShare = Math.mulDiv(stakerVaultShare, vaultShare, BASIS_POINTS_DENOMINATOR);
                if (stakerShare == 0) continue;

                uint256 epochRewards = rewardsAmountPerTokenFromEpoch[epoch].get(rewardsToken);

                // Calculate staker rewards after curator fee
                uint256 rewards = Math.mulDiv(epochRewards, stakerShare, BASIS_POINTS_DENOMINATOR);
                totalRewards += rewards;
            }
        }

        if (totalRewards == 0) revert NoRewardsToClaim(msg.sender);

        IERC20(rewardsToken).safeTransfer(recipient, totalRewards);
        lastEpochClaimedStaker[msg.sender] = currentEpoch - 1;
    }

    /// @inheritdoc IRewards
    function claimOperatorFee(address rewardsToken, address recipient) external {
        if (recipient == address(0)) revert InvalidRecipient(recipient);

        uint48 currentEpoch = l1Middleware.getCurrentEpoch();
        uint48 lastClaimedEpoch = lastEpochClaimedOperator[msg.sender];

        if (currentEpoch > 0 && lastClaimedEpoch >= currentEpoch - 1) {
            revert AlreadyClaimedForLatestEpoch(msg.sender, lastClaimedEpoch);
        }

        uint256 totalRewards = 0;

        for (uint48 epoch = lastClaimedEpoch + 1; epoch < currentEpoch; epoch++) {
            uint256 operatorShare = operatorShares[epoch][msg.sender];
            if (operatorShare == 0) continue;

            // get rewards amount per token for epoch
            uint256 rewardsAmount = rewardsAmountPerTokenFromEpoch[epoch].get(rewardsToken);
            if (rewardsAmount == 0) continue;

            uint256 operatorRewards = Math.mulDiv(rewardsAmount, operatorShare, BASIS_POINTS_DENOMINATOR);
            totalRewards += operatorRewards;
        }

        if (totalRewards == 0) revert NoRewardsToClaim(msg.sender);
        IERC20(rewardsToken).safeTransfer(recipient, totalRewards);
        lastEpochClaimedOperator[msg.sender] = currentEpoch - 1;
    }

    /// @inheritdoc IRewards
    function claimCuratorFee(address rewardsToken, address recipient) external {
        if (recipient == address(0)) revert InvalidRecipient(recipient);

        uint48 currentEpoch = l1Middleware.getCurrentEpoch();
        uint48 lastClaimedEpoch = lastEpochClaimedCurator[msg.sender];

        if (currentEpoch > 0 && lastClaimedEpoch >= currentEpoch - 1) {
            revert AlreadyClaimedForLatestEpoch(msg.sender, lastClaimedEpoch);
        }

        uint256 totalCuratorRewards = 0;
        for (uint48 epoch = lastClaimedEpoch + 1; epoch < currentEpoch; epoch++) {
            uint256 curatorShare = curatorShares[epoch][msg.sender];
            if (curatorShare == 0) continue;

            uint256 rewardsAmount = rewardsAmountPerTokenFromEpoch[epoch].get(rewardsToken);
            if (rewardsAmount == 0) continue;

            uint256 curatorRewards = Math.mulDiv(rewardsAmount, curatorShare, BASIS_POINTS_DENOMINATOR);
            totalCuratorRewards += curatorRewards;
        }
        if (totalCuratorRewards == 0) revert NoRewardsToClaim(msg.sender);

        IERC20(rewardsToken).safeTransfer(recipient, totalCuratorRewards);
        lastEpochClaimedCurator[msg.sender] = currentEpoch - 1;
    }

    /// @inheritdoc IRewards
    function claimProtocolFee(address rewardsToken, address recipient) external onlyRole(PROTOCOL_OWNER_ROLE) {
        if (recipient == address(0)) revert InvalidRecipient(recipient);

        uint256 rewards = protocolRewards[rewardsToken];
        if (rewards == 0) revert NoRewardsToClaim(msg.sender);

        IERC20(rewardsToken).safeTransfer(recipient, rewards);
        protocolRewards[rewardsToken] = 0;
    }

    /// @inheritdoc IRewards
    function claimUndistributedRewards(
        uint48 epoch,
        address rewardsToken,
        address recipient
    ) external onlyRole(ADMIN_ROLE) {
        if (recipient == address(0)) revert InvalidRecipient(recipient);

        // Check if epoch distribution is complete
        DistributionBatch storage batch = distributionBatches[epoch];
        if (!batch.isComplete) revert DistributionNotComplete(epoch);

        // Check if current epoch is at least 2 epochs ahead (to ensure all claims are done)
        uint48 currentEpoch = l1Middleware.getCurrentEpoch();
        if (currentEpoch < epoch + 2) revert EpochStillClaimable(epoch);

        // Get total rewards for the epoch
        uint256 totalRewardsForEpoch = rewardsAmountPerTokenFromEpoch[epoch].get(rewardsToken);
        if (totalRewardsForEpoch == 0) revert NoRewardsToClaim(msg.sender);

        // Calculate total distributed shares for the epoch
        uint256 totalDistributedShares = 0;

        // Sum operator shares
        address[] memory operators = l1Middleware.getAllOperators();
        for (uint256 i = 0; i < operators.length; i++) {
            totalDistributedShares += operatorShares[epoch][operators[i]];
        }

        // Sum vault shares
        address[] memory vaults = _getVaults(epoch);
        for (uint256 i = 0; i < vaults.length; i++) {
            totalDistributedShares += vaultShares[epoch][vaults[i]];
        }

        // Sum curator shares
        for (uint256 i = 0; i < vaults.length; i++) {
            address curator = VaultTokenized(vaults[i]).owner();
            totalDistributedShares += curatorShares[epoch][curator];
        }

        // Calculate and transfer undistributed rewards
        uint256 undistributedRewards =
            totalRewardsForEpoch - Math.mulDiv(totalRewardsForEpoch, totalDistributedShares, BASIS_POINTS_DENOMINATOR);

        if (undistributedRewards == 0) revert NoRewardsToClaim(msg.sender);

        // Clear the rewards amount to prevent double claiming
        rewardsAmountPerTokenFromEpoch[epoch].set(rewardsToken, 0);

        IERC20(rewardsToken).safeTransfer(recipient, undistributedRewards);

        emit UndistributedRewardsClaimed(epoch, rewardsToken, recipient, undistributedRewards);
    }

    // Admin configuration functions
    /// @inheritdoc IRewards
    function setRewardsAmountForEpochs(
        uint48 startEpoch,
        uint48 numberOfEpochs,
        address rewardsToken,
        uint256 rewardsAmount
    ) external onlyRole(ADMIN_ROLE) {
        if (rewardsToken == address(0)) {
            revert InvalidRewardsToken(rewardsToken);
        }
        if (rewardsAmount == 0) revert InvalidRewardsAmount(rewardsAmount);
        if (numberOfEpochs == 0) revert InvalidNumberOfEpochs(numberOfEpochs);

        uint256 totalRewards = rewardsAmount * numberOfEpochs;
        IERC20(rewardsToken).safeTransferFrom(msg.sender, address(this), totalRewards);

        uint256 protocolRewardsAmount = Math.mulDiv(totalRewards, protocolFee, BASIS_POINTS_DENOMINATOR);
        protocolRewards[rewardsToken] += protocolRewardsAmount;

        rewardsAmount -= Math.mulDiv(rewardsAmount, protocolFee, BASIS_POINTS_DENOMINATOR);

        for (uint48 i = 0; i < numberOfEpochs; i++) {
            rewardsAmountPerTokenFromEpoch[startEpoch + i].set(rewardsToken, rewardsAmount);
        }

        emit RewardsAmountSet(startEpoch, numberOfEpochs, rewardsToken, rewardsAmount);
    }

    /// @inheritdoc IRewards
    function setRewardsShareForAssetClass(uint96 assetClass, uint16 share) external onlyRole(ADMIN_ROLE) {
        if (share > BASIS_POINTS_DENOMINATOR) revert InvalidShare(share);
        rewardsSharePerAssetClass[assetClass] = share;
        emit RewardsShareUpdated(assetClass, share);
    }

    /// @inheritdoc IRewards
    function setMinRequiredUptime(
        uint256 newMinUptime
    ) external onlyRole(ADMIN_ROLE) {
        if (newMinUptime > epochDuration) revert InvalidMinUptime(newMinUptime);
        minRequiredUptime = newMinUptime;
    }

    /// @inheritdoc IRewards
    function setAdminRole(
        address newAdmin
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAdmin == address(0)) revert InvalidRecipient(newAdmin);
        _grantRole(ADMIN_ROLE, newAdmin);
        emit AdminRoleAssigned(newAdmin);
    }

    /// @inheritdoc IRewards
    function setProtocolOwner(
        address newProtocolOwner
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newProtocolOwner == address(0)) revert InvalidRecipient(newProtocolOwner);
        _grantRole(PROTOCOL_OWNER_ROLE, newProtocolOwner);
        emit ProtocolOwnerUpdated(newProtocolOwner);
    }

    /// @inheritdoc IRewards
    function updateProtocolFee(
        uint16 newFee
    ) external override onlyRole(ADMIN_ROLE) {
        if (newFee > BASIS_POINTS_DENOMINATOR) revert InvalidFee(newFee);
        protocolFee = newFee;
        emit ProtocolFeeUpdated(newFee);
    }

    /// @inheritdoc IRewards
    function updateOperatorFee(
        uint16 newFee
    ) external override onlyRole(ADMIN_ROLE) {
        if (newFee > BASIS_POINTS_DENOMINATOR) revert InvalidFee(newFee);
        operatorFee = newFee;
        emit OperatorFeeUpdated(newFee);
    }

    /// @inheritdoc IRewards
    function updateCuratorFee(
        uint16 newFee
    ) external override onlyRole(ADMIN_ROLE) {
        if (newFee > BASIS_POINTS_DENOMINATOR) revert InvalidFee(newFee);
        curatorFee = newFee;
        emit CuratorFeeUpdated(newFee);
    }

    // getter functions
    /// @inheritdoc IRewards
    function getRewardsAmountPerTokenFromEpoch(
        uint48 epoch
    ) external view override returns (address[] memory tokens, uint256[] memory amounts) {
        tokens = rewardsAmountPerTokenFromEpoch[epoch].keys();
        amounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            amounts[i] = rewardsAmountPerTokenFromEpoch[epoch].get(tokens[i]);
        }
    }

    function getRewardsAmountPerTokenFromEpoch(uint48 epoch, address token) external view returns (uint256) {
        return rewardsAmountPerTokenFromEpoch[epoch].get(token);
    }

    // INTERNAL FUNCTIONS
    // Calculation functions
    /**
     * @dev Calculates the operator share for a given epoch and operator
     * @param epoch The epoch to calculate the operator share for
     * @param operator The operator to calculate the share for
     */
    function _calculateOperatorShare(uint48 epoch, address operator) internal {
        uint256 uptime = uptimeTracker.operatorUptimePerEpoch(epoch, operator);
        if (uptime < minRequiredUptime) {
            operatorTotalShares[epoch][operator] = 0;
            operatorShares[epoch][operator] = 0;
            return;
        }

        uint256 operatorUptime = Math.mulDiv(uptime, BASIS_POINTS_DENOMINATOR, epochDuration);
        uint256 totalShare = 0;

        uint96[] memory assetClasses = _getAssetClassIds();
        for (uint256 i = 0; i < assetClasses.length; i++) {
            uint256 operatorStake = _getOperatorTrueStake(epoch, operator, assetClasses[i]);
            uint256 totalStake = l1Middleware.totalStakeCache(epoch, assetClasses[i]);
            uint16 assetClassShare = rewardsSharePerAssetClass[assetClasses[i]];

            uint256 shareForClass = Math.mulDiv(
                Math.mulDiv(operatorStake, BASIS_POINTS_DENOMINATOR, totalStake),
                assetClassShare,
                BASIS_POINTS_DENOMINATOR
            );
            totalShare += shareForClass;
        }

        totalShare = Math.mulDiv(totalShare, operatorUptime, BASIS_POINTS_DENOMINATOR);

        // Calculate operator fee share and store it
        uint256 operatorFeeShare = Math.mulDiv(totalShare, operatorFee, BASIS_POINTS_DENOMINATOR);
        operatorShares[epoch][operator] = operatorFeeShare;

        // Remove operator fee share from total share
        totalShare -= operatorFeeShare;

        operatorTotalShares[epoch][operator] = totalShare;
    }

    /**
     * @dev Calculates and stores the vault shares for a given epoch and operator
     * @param epoch The epoch to calculate the vault shares for
     * @param operator The operator to calculate the vault shares for
     */
    function _calculateAndStoreVaultShares(uint48 epoch, address operator) internal {
        uint256 operatorShare = operatorTotalShares[epoch][operator];
        if (operatorShare == 0) return;

        address[] memory vaults = _getVaults(epoch);
        uint48 epochTs = l1Middleware.getEpochStartTs(epoch);

        // First pass: calculate raw shares and total
        for (uint256 i = 0; i < vaults.length; i++) {
            address vault = vaults[i];
            uint96 vaultAssetClass = _getVaultAssetClassId(vault);

            uint256 vaultStake = BaseDelegator(IVaultTokenized(vault).delegator()).stakeAt(
                l1Middleware.L1_VALIDATOR_MANAGER(), vaultAssetClass, operator, epochTs, new bytes(0)
            );

            if (vaultStake > 0) {
                vaultOperators[epoch][vault].add(operator);
                uint256 operatorActiveStake = _getOperatorTrueStake(epoch, operator, vaultAssetClass);

                uint256 vaultShare = Math.mulDiv(vaultStake, BASIS_POINTS_DENOMINATOR, operatorActiveStake);
                vaultShare =
                    Math.mulDiv(vaultShare, rewardsSharePerAssetClass[vaultAssetClass], BASIS_POINTS_DENOMINATOR);
                vaultShare = Math.mulDiv(vaultShare, operatorShare, BASIS_POINTS_DENOMINATOR);

                uint256 operatorTotalStake = l1Middleware.getOperatorStake(operator, epoch, vaultAssetClass);

                if (operatorTotalStake > 0) {
                    uint256 operatorStakeRatio =
                        Math.mulDiv(operatorActiveStake, BASIS_POINTS_DENOMINATOR, operatorTotalStake);
                    vaultShare = Math.mulDiv(vaultShare, operatorStakeRatio, BASIS_POINTS_DENOMINATOR);
                }

                // Calculate curator share
                uint256 curatorShare = Math.mulDiv(vaultShare, curatorFee, BASIS_POINTS_DENOMINATOR);
                curatorShares[epoch][VaultTokenized(vault).owner()] += curatorShare;

                // Store vault share after removing curator share
                vaultShares[epoch][vault] += vaultShare - curatorShare;
            }
        }
    }

    // Getter functions
    /**
     * @dev Gets the vaults for a given epoch
     * @param epoch The epoch to get the vaults for
     * @return The vaults for the given epoch
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
     * @dev Gets the vaults for a given staker and epoch
     * @param staker The staker to get the vaults for
     * @param epoch The epoch to get the vaults for
     * @return The vaults for the given staker and epoch
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
     * @dev Gets the asset class ids
     * @return The asset class ids
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
     * @dev Gets the asset class id for a given vault
     * @param vault The vault to get the asset class id for
     * @return The asset class id for the given vault
     */
    function _getVaultAssetClassId(
        address vault
    ) internal view returns (uint96) {
        uint96[] memory assetClasses = _getAssetClassIds();
        for (uint256 i = 0; i < assetClasses.length; i++) {
            if (l1Middleware.isAssetInClass(assetClasses[i], vault)) {
                return assetClasses[i];
            }
        }
        revert AssetClassNotFound(vault);
    }

    /**
     * @dev Gets the operator's true stake for a given epoch and asset class
     * @param epoch The epoch to get the operator's true stake for
     * @param operator The operator to get the true stake for
     * @param assetClass The asset class to get the true stake for
     * @return The operator's true stake for the given epoch and asset class
     */
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
