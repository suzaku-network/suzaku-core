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
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

contract Rewards is AccessControlUpgradeable, ReentrancyGuardUpgradeable, IRewards {
    using SafeERC20 for IERC20;
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    using EnumerableSet for EnumerableSet.AddressSet;

    // Constants
    uint16 public constant BASIS_POINTS_DENOMINATOR = 10_000;
    bytes32 public constant REWARDS_MANAGER_ROLE = keccak256("REWARDS_MANAGER_ROLE");
    bytes32 public constant REWARDS_DISTRIBUTOR_ROLE = keccak256("REWARDS_DISTRIBUTOR_ROLE");
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
    mapping(uint48 epoch => mapping(address operator => uint256 share)) public operatorBeneficiariesShares;
    mapping(uint48 epoch => mapping(address operator => uint256 share)) public operatorShares;
    mapping(uint48 epoch => mapping(address vault => uint256 share)) public vaultShares; // vault stakes owners shares
    mapping(uint48 epoch => mapping(address curator => uint256 share)) public curatorShares; // vault owner shares

    // Protocol rewards
    mapping(address rewardsToken => uint256 rewardsAmount) public protocolRewards;

    // Reward token amounts per epoch
    mapping(uint48 epoch => EnumerableMap.AddressToUintMap rewardsTokenToAmount) private rewardsAmountPerTokenFromEpoch;

    // Last claimed epoch tracking
    mapping(address staker => mapping(address rewardToken => uint48 epoch)) public lastEpochClaimedStaker;
    mapping(address curator => mapping(address rewardToken => uint48 epoch)) public lastEpochClaimedCurator;
    mapping(address operator => mapping(address rewardToken => uint48 epoch)) public lastEpochClaimedOperator;
    mapping(address protocolOwner => mapping(address rewardToken => uint48 epoch)) public lastEpochClaimedProtocol;

    // Asset class configuration
    mapping(uint96 assetClass => uint16 rewardsShare) public rewardsSharePerAssetClass;

    // Epoch curators tracking
    mapping(uint48 epoch => EnumerableSet.AddressSet curators) private _epochCurators;

    // INITIALIZER
    function initialize(
        address admin_,
        address protocolOwner_,
        address payable l1Middleware_,
        address uptimeTracker_,
        uint16 protocolFee_,
        uint16 operatorFee_,
        uint16 curatorFee_,
        uint256 minRequiredUptime_
    ) public initializer {
        if (l1Middleware_ == address(0)) revert InvalidL1Middleware(l1Middleware_);
        if (uptimeTracker_ == address(0)) revert InvalidUptimeTracker(uptimeTracker_);
        if (admin_ == address(0)) revert InvalidAdmin(admin_);
        if (protocolOwner_ == address(0)) revert InvalidProtocolOwner(protocolOwner_);
        if (protocolFee_ + operatorFee_ + curatorFee_ > BASIS_POINTS_DENOMINATOR)
            revert FeeConfigurationExceeds100(protocolFee_ + operatorFee_ + curatorFee_);

        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(REWARDS_MANAGER_ROLE, admin_);
        _grantRole(REWARDS_DISTRIBUTOR_ROLE, admin_);
        _grantRole(PROTOCOL_OWNER_ROLE, protocolOwner_);

        l1Middleware = AvalancheL1Middleware(l1Middleware_);
        middlewareVaultManager = MiddlewareVaultManager(l1Middleware.getVaultManager());
        uptimeTracker = UptimeTracker(uptimeTracker_);
        epochDuration = l1Middleware.EPOCH_DURATION();

        _checkFees(protocolFee_, operatorFee_, curatorFee_);

        protocolFee = protocolFee_;
        operatorFee = operatorFee_;
        curatorFee = curatorFee_;
        minRequiredUptime = minRequiredUptime_;
    }

    // EXTERNAL FUNCTIONS
    // Distribution
    /// @inheritdoc IRewards
    function distributeRewards(uint48 epoch, uint48 batchSize) external onlyRole(REWARDS_DISTRIBUTOR_ROLE) {
        DistributionBatch storage batch = distributionBatches[epoch];
        uint48 currentEpoch = l1Middleware.getCurrentEpoch();

        if (batch.isComplete) revert AlreadyCompleted(epoch);
        // We need to wait for 2 epochs before we can distribute rewards
        if (epoch >= currentEpoch - 2) revert RewardsDistributionTooEarly(epoch, currentEpoch - 2);

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
    function claimRewards(address rewardsToken, address recipient) external nonReentrant {
        if (recipient == address(0)) revert InvalidRecipient(recipient);

        uint48 lastClaimedEpoch = lastEpochClaimedStaker[msg.sender][rewardsToken];
        uint48 currentEpoch = l1Middleware.getCurrentEpoch();

        if (currentEpoch > 0 && lastClaimedEpoch >= currentEpoch - 1) {
            revert AlreadyClaimedForLatestEpoch(msg.sender, lastClaimedEpoch);
        }

        uint256 totalRewards = 0;

        for (uint48 epoch = lastClaimedEpoch + 1; epoch < currentEpoch; epoch++) {
            (bool found, uint256 epochRewards) =
                rewardsAmountPerTokenFromEpoch[epoch].tryGet(rewardsToken);
            if (!found || epochRewards == 0) continue;
            address[] memory vaults = _getStakerVaults(msg.sender, epoch);
            uint48 epochTs = l1Middleware.getEpochStartTs(epoch);

            for (uint256 i = 0; i < vaults.length; i++) {
                address vault = vaults[i];
                uint256 vaultShare = vaultShares[epoch][vault];
                if (vaultShare == 0) continue;

                uint256 stakerVaultShare = IVaultTokenized(vault).activeSharesOfAt(msg.sender, epochTs, new bytes(0));
                if (stakerVaultShare == 0) continue;

                // Get total raw shares in this specific vault at that time
                uint256 totalRawSharesInVault = IVaultTokenized(vault).activeSharesAt(epochTs, new bytes(0));
                if (totalRawSharesInVault == 0) continue;

                uint256 tokensForVault = Math.mulDiv(
                    epochRewards,
                    vaultShare,
                    BASIS_POINTS_DENOMINATOR
                );

                uint256 rewards = Math.mulDiv(
                    tokensForVault,
                    stakerVaultShare,
                    totalRawSharesInVault
                );
                
                totalRewards += rewards;
            }
        }

        if (totalRewards == 0) revert NoRewardsToClaim(msg.sender);

        lastEpochClaimedStaker[msg.sender][rewardsToken] = currentEpoch - 1;
        IERC20(rewardsToken).safeTransfer(recipient, totalRewards);
    }

    /// @inheritdoc IRewards
    function claimOperatorFee(address rewardsToken, address recipient) external nonReentrant {
        if (recipient == address(0)) revert InvalidRecipient(recipient);

        uint48 currentEpoch = l1Middleware.getCurrentEpoch();
        uint48 lastClaimedEpoch = lastEpochClaimedOperator[msg.sender][rewardsToken];

        if (currentEpoch > 0 && lastClaimedEpoch >= currentEpoch - 1) {
            revert AlreadyClaimedForLatestEpoch(msg.sender, lastClaimedEpoch);
        }

        uint256 totalRewards = 0;

        for (uint48 epoch = lastClaimedEpoch + 1; epoch < currentEpoch; epoch++) {
            (bool found, uint256 rewardsAmount) =
                rewardsAmountPerTokenFromEpoch[epoch].tryGet(rewardsToken);
            if (!found || rewardsAmount == 0) continue;

            uint256 operatorShare = operatorShares[epoch][msg.sender];
            if (operatorShare == 0) continue;

            uint256 operatorRewards = Math.mulDiv(rewardsAmount, operatorShare, BASIS_POINTS_DENOMINATOR);
            totalRewards += operatorRewards;
        }

        if (totalRewards == 0) revert NoRewardsToClaim(msg.sender);
        lastEpochClaimedOperator[msg.sender][rewardsToken] = currentEpoch - 1;
        IERC20(rewardsToken).safeTransfer(recipient, totalRewards);
    }

    /// @inheritdoc IRewards
    function claimCuratorFee(address rewardsToken, address recipient) external nonReentrant {
        if (recipient == address(0)) revert InvalidRecipient(recipient);

        uint48 currentEpoch = l1Middleware.getCurrentEpoch();
        uint48 lastClaimedEpoch = lastEpochClaimedCurator[msg.sender][rewardsToken];

        if (currentEpoch > 0 && lastClaimedEpoch >= currentEpoch - 1) {
            revert AlreadyClaimedForLatestEpoch(msg.sender, lastClaimedEpoch);
        }

        uint256 totalCuratorRewards = 0;
        for (uint48 epoch = lastClaimedEpoch + 1; epoch < currentEpoch; epoch++) {
            (bool found, uint256 rewardsAmount) =
                rewardsAmountPerTokenFromEpoch[epoch].tryGet(rewardsToken);
            if (!found || rewardsAmount == 0) continue;

            uint256 curatorShare = curatorShares[epoch][msg.sender];
            if (curatorShare == 0) continue;

            uint256 curatorRewards = Math.mulDiv(rewardsAmount, curatorShare, BASIS_POINTS_DENOMINATOR);
            totalCuratorRewards += curatorRewards;
        }
        if (totalCuratorRewards == 0) revert NoRewardsToClaim(msg.sender);

        lastEpochClaimedCurator[msg.sender][rewardsToken] = currentEpoch - 1;
        IERC20(rewardsToken).safeTransfer(recipient, totalCuratorRewards);
    }

    /// @inheritdoc IRewards
    function claimProtocolFee(address rewardsToken, address recipient) external nonReentrant onlyRole(PROTOCOL_OWNER_ROLE) {
        if (recipient == address(0)) revert InvalidRecipient(recipient);

        uint256 rewards = protocolRewards[rewardsToken];
        if (rewards == 0) revert NoRewardsToClaim(msg.sender);

        protocolRewards[rewardsToken] = 0;
        IERC20(rewardsToken).safeTransfer(recipient, rewards);
    }

    /// @inheritdoc IRewards
    function claimUndistributedRewards(
        uint48 epoch,
        address rewardsToken,
        address recipient
    ) external nonReentrant onlyRole(REWARDS_DISTRIBUTOR_ROLE) {
        if (recipient == address(0)) revert InvalidRecipient(recipient);

        // Check if epoch distribution is complete
        DistributionBatch storage batch = distributionBatches[epoch];
        if (!batch.isComplete) revert DistributionNotComplete(epoch);

        // Check if current epoch is at least 2 epochs ahead (to ensure all claims are done)
        uint48 currentEpoch = l1Middleware.getCurrentEpoch();
        if (currentEpoch < epoch + 2) revert EpochStillClaimable(epoch);

        // Get total rewards for the epoch
        (bool foundRewards, uint256 totalRewardsForEpoch) =
            rewardsAmountPerTokenFromEpoch[epoch].tryGet(rewardsToken);
        if (!foundRewards || totalRewardsForEpoch == 0) revert NoRewardsToClaim(msg.sender);

        // Calculate total distributed shares for the epoch
        uint256 totalDistributedShares = 0;

        // Sum operator shares
        address[] memory operators = l1Middleware.getAllOperators();
        for (uint256 i = 0; i < operators.length; i++) {
            totalDistributedShares += operatorShares[epoch][operators[i]];
        }

        // Sum vault shares
        address[] memory vaults = middlewareVaultManager.getVaults(epoch);
        for (uint256 i = 0; i < vaults.length; i++) {
            totalDistributedShares += vaultShares[epoch][vaults[i]];
        }

        // Sum curator shares (unique curators)
        address[] memory curators = _epochCurators[epoch].values();
        for (uint256 i = 0; i < curators.length; ++i) {
            totalDistributedShares += curatorShares[epoch][curators[i]];
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
    ) external onlyRole(REWARDS_DISTRIBUTOR_ROLE) {
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
            uint48 targetEpoch = startEpoch + i;
            (, uint256 existing) = rewardsAmountPerTokenFromEpoch[targetEpoch].tryGet(rewardsToken);
            rewardsAmountPerTokenFromEpoch[targetEpoch].set(rewardsToken, existing + rewardsAmount);
        }

        emit RewardsAmountSet(startEpoch, numberOfEpochs, rewardsToken, rewardsAmount);
    }

    /// @inheritdoc IRewards
    function setRewardsShareForAssetClass(uint96 assetClass, uint16 share) external onlyRole(REWARDS_MANAGER_ROLE) {
        if (share > BASIS_POINTS_DENOMINATOR) revert InvalidShare(share);

        uint16 prev = rewardsSharePerAssetClass[assetClass];
        uint256 newTotal = _totalAssetClassShares() - prev + share;
        if (newTotal > BASIS_POINTS_DENOMINATOR) revert AssetClassSharesExceed100(newTotal);

        rewardsSharePerAssetClass[assetClass] = share;
        emit RewardsShareUpdated(assetClass, share);
    }

    /// @inheritdoc IRewards
    function setMinRequiredUptime(
        uint256 newMinUptime
    ) external onlyRole(REWARDS_MANAGER_ROLE) {
        if (newMinUptime > epochDuration) revert InvalidMinUptime(newMinUptime);
        minRequiredUptime = newMinUptime;
    }

    /// @inheritdoc IRewards
    function setRewardsDistributorRole(
        address newRewardsDistributor
    ) external onlyRole(REWARDS_MANAGER_ROLE) {
        if (newRewardsDistributor == address(0)) revert InvalidRecipient(newRewardsDistributor);
        _grantRole(REWARDS_DISTRIBUTOR_ROLE, newRewardsDistributor);
        emit RewardsDistributorRoleAssigned(newRewardsDistributor);
    }

    /// @inheritdoc IRewards
    function setRewardsManagerRole(
        address newRewardsManager
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRewardsManager == address(0)) revert InvalidRecipient(newRewardsManager);
        _grantRole(REWARDS_MANAGER_ROLE, newRewardsManager);
        emit RewardsManagerRoleAssigned(newRewardsManager);
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
    ) external override onlyRole(REWARDS_MANAGER_ROLE) {
        if (newFee > BASIS_POINTS_DENOMINATOR) revert InvalidFee(newFee);
        _checkFees(newFee, operatorFee, curatorFee);
        protocolFee = newFee;
        emit ProtocolFeeUpdated(newFee);
    }

    /// @inheritdoc IRewards
    function updateOperatorFee(
        uint16 newFee
    ) external override onlyRole(REWARDS_MANAGER_ROLE) {
        if (newFee > BASIS_POINTS_DENOMINATOR) revert InvalidFee(newFee);
        _checkFees(protocolFee, newFee, curatorFee);
        operatorFee = newFee;
        emit OperatorFeeUpdated(newFee);
    }

    /// @inheritdoc IRewards
    function updateCuratorFee(
        uint16 newFee
    ) external override onlyRole(REWARDS_MANAGER_ROLE) {
        if (newFee > BASIS_POINTS_DENOMINATOR) revert InvalidFee(newFee);
        _checkFees(protocolFee, operatorFee, newFee);
        curatorFee = newFee;
        emit CuratorFeeUpdated(newFee);
    }

    /// @notice Updates all fees at once to avoid order dependency issues
    /// @param newProtocolFee New protocol fee in basis points
    /// @param newOperatorFee New operator fee in basis points  
    /// @param newCuratorFee New curator fee in basis points
    function updateAllFees(
        uint16 newProtocolFee,
        uint16 newOperatorFee,
        uint16 newCuratorFee
    ) external onlyRole(REWARDS_MANAGER_ROLE) {
        if (newProtocolFee > BASIS_POINTS_DENOMINATOR) revert InvalidFee(newProtocolFee);
        if (newOperatorFee > BASIS_POINTS_DENOMINATOR) revert InvalidFee(newOperatorFee);
        if (newCuratorFee > BASIS_POINTS_DENOMINATOR) revert InvalidFee(newCuratorFee);
        
        _checkFees(newProtocolFee, newOperatorFee, newCuratorFee);
        
        protocolFee = newProtocolFee;
        operatorFee = newOperatorFee;
        curatorFee = newCuratorFee;
        
        emit ProtocolFeeUpdated(newProtocolFee);
        emit OperatorFeeUpdated(newOperatorFee);
        emit CuratorFeeUpdated(newCuratorFee);
    }

    // Getter functions
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
    // Helper functions
    function _totalAssetClassShares() internal view returns (uint256 total) {
        uint96[] memory ids = l1Middleware.getAssetClassIds();
        for (uint256 i; i < ids.length; ++i) total += rewardsSharePerAssetClass[ids[i]];
    }

    /// @dev Reverts if fees exceed 100 % (10 000 bp)
    function _checkFees(uint16 p, uint16 o, uint16 c) internal pure {
        if (p + o + c > BASIS_POINTS_DENOMINATOR)
            revert FeeConfigurationExceeds100(p + o + c);
    }

    // Calculation functions
    /**
     * @dev Calculates the operator share for a given epoch and operator
     * @param epoch The epoch to calculate the operator share for
     * @param operator The operator to calculate the share for
     */
    function _calculateOperatorShare(uint48 epoch, address operator) internal {
        uint256 uptime = uptimeTracker.operatorUptimePerEpoch(epoch, operator);
        if (uptime < minRequiredUptime) {
            operatorBeneficiariesShares[epoch][operator] = 0;
            operatorShares[epoch][operator] = 0;
            return;
        }

        uint256 operatorUptime = Math.mulDiv(uptime, BASIS_POINTS_DENOMINATOR, epochDuration);
        uint256 totalShare = 0;

        uint96[] memory assetClasses = l1Middleware.getAssetClassIds();
        for (uint256 i = 0; i < assetClasses.length; i++) {
            uint256 totalStake = l1Middleware.totalStakeCache(epoch, assetClasses[i]);
            uint16 assetClassShare = rewardsSharePerAssetClass[assetClasses[i]];
            if (totalStake == 0 || assetClassShare == 0) continue;

            uint256 operatorStake = l1Middleware.getOperatorUsedStakeCachedPerEpoch(epoch, operator, assetClasses[i]);

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

        operatorBeneficiariesShares[epoch][operator] = totalShare;
    }

    /**
     * @dev Calculates and stores the vault shares for a given epoch and operator
     * @param epoch The epoch to calculate the vault shares for
     * @param operator The operator to calculate the vault shares for
     */
    function _calculateAndStoreVaultShares(uint48 epoch, address operator) internal {
        uint256 operatorShare = operatorBeneficiariesShares[epoch][operator];
        if (operatorShare == 0) return;

        address[] memory vaults = middlewareVaultManager.getVaults(epoch);
        uint48 epochTs = l1Middleware.getEpochStartTs(epoch);

        // First pass: calculate raw shares and total
        for (uint256 i = 0; i < vaults.length; i++) {
            address vault = vaults[i];
            uint96 vaultAssetClass = middlewareVaultManager.getVaultAssetClass(vault);

            uint256 vaultStake = BaseDelegator(IVaultTokenized(vault).delegator()).stakeAt(
                l1Middleware.L1_VALIDATOR_MANAGER(), vaultAssetClass, operator, epochTs, new bytes(0)
            );

            if (vaultStake > 0) {
                uint256 operatorActiveStake =
                    l1Middleware.getOperatorUsedStakeCachedPerEpoch(epoch, operator, vaultAssetClass);
                if (operatorActiveStake == 0) continue;
                
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
                address curator = VaultTokenized(vault).owner();
                curatorShares[epoch][curator] += curatorShare;
                _epochCurators[epoch].add(curator);

                // Store vault share after removing curator share
                vaultShares[epoch][vault] += vaultShare - curatorShare;
            }
        }
    }

    // Getter functions
    /**
     * @dev Gets the vaults for a given staker and epoch
     * @param staker The staker to get the vaults for
     * @param epoch The epoch to get the vaults for
     * @return The vaults for the given staker and epoch
     */
    function _getStakerVaults(address staker, uint48 epoch) internal view returns (address[] memory) {
        address[] memory vaults = middlewareVaultManager.getVaults(epoch);
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
}
