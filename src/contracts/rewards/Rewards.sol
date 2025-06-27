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
    /// @dev Epoch N must be funded no later than N-FUNDING_DEADLINE_OFFSET.
    ///      If funded earlier, distribution can proceed; otherwise, must wait for the deadline.
    uint48 public constant FUNDING_DEADLINE_OFFSET = 4;

    /// @dev Epoch N may be distributed no earlier than N+DISTRIBUTION_EARLIEST_OFFSET.
    ///      It has to wait for state to be finalized across all contracts.
    uint48 public constant DISTRIBUTION_EARLIEST_OFFSET = 2;

    /// @dev The number of epochs after distribution is possible that users have to claim
    ///      before undistributed rewards can be swept.
    uint48 public constant CLAIM_GRACE_PERIOD_EPOCHS = 1;

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

    // Epoch status tracking
    struct EpochStatus {
        bool funded;
        bool distributionComplete;
    }
    mapping(uint48 => EpochStatus) public epochStatus;

    // Share tracking
    mapping(uint48 epoch => mapping(address operator => uint256 share)) public operatorShares;
    mapping(uint48 epoch => mapping(address vault => uint256 share)) public vaultShares; // vault stakes owners shares
    mapping(uint48 epoch => mapping(address curator => uint256 share)) public curatorShares; // vault owner shares
    mapping(uint48 epoch => mapping(address operator => mapping(uint96 assetClass => uint256 share)))
        public operatorBeneficiariesSharesPerAssetClass;

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

    // Undistributed rewards tracking - epoch => token => swept
    mapping(uint48 => mapping(address => bool)) private _undistributedClaimed;

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

        __ReentrancyGuard_init();
        __AccessControl_init();

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
        EpochStatus storage st = epochStatus[epoch];
        uint48 currentEpoch = l1Middleware.getCurrentEpoch();

        // window guards 
        uint48 earliestDistributionEpoch = currentEpoch - DISTRIBUTION_EARLIEST_OFFSET;
        if (epoch > earliestDistributionEpoch)
            revert RewardsDistributionTooEarly(epoch, earliestDistributionEpoch);
            
        bool fundingWindowOpen = epoch + FUNDING_DEADLINE_OFFSET >= currentEpoch;
        if (fundingWindowOpen && !st.funded) {
            if (l1Middleware.getAllOperators().length != 0)
                revert EpochNotFunded(epoch);
        }

        // Enforce sequential distribution - cannot skip epochs
        if (epoch > 1) {
            EpochStatus storage prevSt = epochStatus[epoch - 1];
            if (!prevSt.distributionComplete) {
                revert DistributionNotComplete(epoch - 1);
            }
        }

        if (batch.isComplete) revert AlreadyCompleted(epoch);

        address[] memory operators = l1Middleware.getAllOperators();
        uint48 operatorCount = 0;

        for (uint256 i = batch.lastProcessedOperator; i < operators.length && operatorCount < batchSize; ++i) {
            _processOperator(epoch, operators[i]);
            batch.lastProcessedOperator = uint48(i + 1);
            unchecked { ++operatorCount; }
        }

        if (batch.lastProcessedOperator >= operators.length) {
            batch.isComplete = true;
            st.distributionComplete = true;
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
        uint48 newLast = lastClaimedEpoch;

        for (uint48 epoch = lastClaimedEpoch + 1; epoch < currentEpoch; ++epoch) {
            EpochStatus memory st = epochStatus[epoch];

            if (!st.distributionComplete) break;

            (bool funded, uint256 epochRewards) = rewardsAmountPerTokenFromEpoch[epoch].tryGet(rewardsToken);
            if (funded && epochRewards > 0) {
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
            newLast = epoch;
        }

        // Always update pointer
        lastEpochClaimedStaker[msg.sender][rewardsToken] = newLast;

        if (totalRewards == 0) {
            if (newLast > lastClaimedEpoch) {
                emit ZeroRewardsClaim(msg.sender, rewardsToken, newLast, "staker");
                return;
            }
            revert NoRewardsToClaimEpoch(msg.sender, lastClaimedEpoch);
        }

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
        uint48 newLast = lastClaimedEpoch;

        for (uint48 epoch = lastClaimedEpoch + 1; epoch < currentEpoch; ++epoch) {
            EpochStatus memory st = epochStatus[epoch];

            if (!st.distributionComplete) break;

            (bool funded, uint256 epochRewards) = rewardsAmountPerTokenFromEpoch[epoch].tryGet(rewardsToken);
            if (funded && epochRewards > 0) {
                uint256 share = operatorShares[epoch][msg.sender];
                if (share > 0) {
                    totalRewards += Math.mulDiv(epochRewards, share, BASIS_POINTS_DENOMINATOR);
                }
            }
            newLast = epoch;
        }

        // Update pointer
        lastEpochClaimedOperator[msg.sender][rewardsToken] = newLast;

        if (totalRewards == 0) {
            if (newLast > lastClaimedEpoch) {
                emit ZeroRewardsClaim(msg.sender, rewardsToken, newLast, "operator");
                return;
            }
            revert NoRewardsToClaimEpoch(msg.sender, lastClaimedEpoch);
        }
        
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

        uint256 totalRewards = 0;
        uint48 newLast = lastClaimedEpoch;

        for (uint48 epoch = lastClaimedEpoch + 1; epoch < currentEpoch; ++epoch) {
            EpochStatus memory st = epochStatus[epoch];

            if (!st.distributionComplete) break;

            (bool funded, uint256 epochRewards) = rewardsAmountPerTokenFromEpoch[epoch].tryGet(rewardsToken);
            if (funded && epochRewards > 0) {
                uint256 share = curatorShares[epoch][msg.sender];
                if (share > 0) {
                    totalRewards += Math.mulDiv(epochRewards, share, BASIS_POINTS_DENOMINATOR);
                }
            }
            newLast = epoch;
        }

        // Update pointer
        lastEpochClaimedCurator[msg.sender][rewardsToken] = newLast;

        if (totalRewards == 0) {
            if (newLast > lastClaimedEpoch) {
                emit ZeroRewardsClaim(msg.sender, rewardsToken, newLast, "curator");
                return;
            }
            revert NoRewardsToClaimEpoch(msg.sender, lastClaimedEpoch);
        }

        IERC20(rewardsToken).safeTransfer(recipient, totalRewards);
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

        // prevent double‑sweep
        if (_undistributedClaimed[epoch][rewardsToken]) revert NoRewardsToClaim(msg.sender);

        // Check if epoch distribution is complete
        DistributionBatch storage batch = distributionBatches[epoch];
        if (!batch.isComplete) revert DistributionNotComplete(epoch);

        // The sweep can only happen after the distribution offset AND the claim grace period have passed.
        uint48 currentEpoch = l1Middleware.getCurrentEpoch();
        uint48 requiredEpoch = epoch + DISTRIBUTION_EARLIEST_OFFSET + CLAIM_GRACE_PERIOD_EPOCHS;
        
        if (currentEpoch < requiredEpoch) {
            revert EpochStillClaimable(epoch);
        }

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

    // Keep pool consistent for later user claims
    uint256 remaining = totalRewardsForEpoch - undistributedRewards;
    rewardsAmountPerTokenFromEpoch[epoch].set(rewardsToken, remaining);

    // mark as swept *before* transfer - prevents second sweep
    _undistributedClaimed[epoch][rewardsToken] = true;

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

        DistributionBatch storage startBatch = distributionBatches[startEpoch];
        if (startBatch.lastProcessedOperator > 0 || startBatch.isComplete) {
            revert DistributionAlreadyStarted(startEpoch);
        }

        uint256 totalRewards = rewardsAmount * numberOfEpochs;
        IERC20(rewardsToken).safeTransferFrom(msg.sender, address(this), totalRewards);

        uint256 protocolRewardsAmount = Math.mulDiv(totalRewards, protocolFee, BASIS_POINTS_DENOMINATOR);
        protocolRewards[rewardsToken] += protocolRewardsAmount;

        rewardsAmount -= Math.mulDiv(rewardsAmount, protocolFee, BASIS_POINTS_DENOMINATOR);

        for (uint48 i = 0; i < numberOfEpochs; i++) {
            uint48 targetEpoch = startEpoch + i;
            EpochStatus storage st = epochStatus[targetEpoch];

            st.funded = true;
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
    /// @dev Ensures the total stake cache is populated for the given epoch and asset class
    function _ensureStakeCache(uint48 epoch, uint96 assetClass) internal returns (uint256 totalStake) {
        totalStake = l1Middleware.totalStakeCache(epoch, assetClass);
        if (totalStake == 0) {
            try l1Middleware.calcAndCacheStakes(epoch, assetClass) {} catch {}
            totalStake = l1Middleware.totalStakeCache(epoch, assetClass);
        }
    }

    /**
     * @dev Calculates the operator share for a given epoch and operator
     * @param epoch The epoch to calculate the operator share for
     * @param operator The operator to calculate the share for
     */
    function _calculateOperatorShare(uint48 epoch, address operator) internal {
        uint256 uptime = uptimeTracker.operatorUptimePerEpoch(epoch, operator);
        if (uptime < minRequiredUptime) {
            operatorShares[epoch][operator] = 0;
            return;
        }

        uint256 operatorUptime = Math.mulDiv(uptime, BASIS_POINTS_DENOMINATOR, epochDuration);

        uint256 totalBeneficiaryShare = 0;
        uint256 totalOperatorFeeShare = 0;

        uint96[] memory assetClasses = l1Middleware.getAssetClassIds();
        uint256 rawShare;
        uint256 operatorFeeShare;
        for (uint256 i = 0; i < assetClasses.length; i++) {
            uint96 assetClass = assetClasses[i];
            uint16 assetClassShare = rewardsSharePerAssetClass[assetClass];
            uint256 totalStake = _ensureStakeCache(epoch, assetClass);
            if (totalStake == 0 || assetClassShare == 0) continue;

            uint256 operatorStake = l1Middleware.getOperatorUsedStakeCachedPerEpoch(epoch, operator, assetClass);

            rawShare = Math.mulDiv(
                Math.mulDiv(operatorStake, BASIS_POINTS_DENOMINATOR, totalStake),
                assetClassShare,
                BASIS_POINTS_DENOMINATOR
            );
            rawShare = Math.mulDiv(rawShare, operatorUptime, BASIS_POINTS_DENOMINATOR);

            operatorFeeShare = Math.mulDiv(rawShare, operatorFee, BASIS_POINTS_DENOMINATOR);

            operatorBeneficiariesSharesPerAssetClass[epoch][operator][assetClass] = rawShare - operatorFeeShare;

            totalOperatorFeeShare += operatorFeeShare;
            totalBeneficiaryShare += rawShare - operatorFeeShare;
        }

        operatorShares[epoch][operator] = totalOperatorFeeShare;
    }

    /**
     * @dev Calculates and stores the vault shares for a given epoch and operator
     * @param epoch The epoch to calculate the vault shares for
     * @param operator The operator to calculate the vault shares for
     */
    function _calculateAndStoreVaultShares(uint48 epoch, address operator) internal {
        address[] memory vaults = middlewareVaultManager.getVaults(epoch);
        uint48 epochTs = l1Middleware.getEpochStartTs(epoch);

        for (uint256 i = 0; i < vaults.length; i++) {
            address vault = vaults[i];
            uint96 vaultAssetClass = middlewareVaultManager.getVaultAssetClass(vault);

            uint256 operatorAssetClassShare = operatorBeneficiariesSharesPerAssetClass[epoch][operator][vaultAssetClass];
            if (operatorAssetClassShare == 0) continue;

            uint256 vaultStake = BaseDelegator(IVaultTokenized(vault).delegator()).stakeAt(
                l1Middleware.L1_VALIDATOR_MANAGER(), vaultAssetClass, operator, epochTs, new bytes(0)
            );

            if (vaultStake > 0) {
                uint256 operatorActiveStake =
                    l1Middleware.getOperatorUsedStakeCachedPerEpoch(epoch, operator, vaultAssetClass);
                if (operatorActiveStake == 0) continue;
                
                uint256 vaultShare = Math.mulDiv(vaultStake, BASIS_POINTS_DENOMINATOR, operatorActiveStake);
                vaultShare = Math.mulDiv(vaultShare, operatorAssetClassShare, BASIS_POINTS_DENOMINATOR);

                uint256 curatorShare = Math.mulDiv(vaultShare, curatorFee, BASIS_POINTS_DENOMINATOR);
                address curator = VaultTokenized(vault).owner();
                curatorShares[epoch][curator] += curatorShare;
                _epochCurators[epoch].add(curator);

                vaultShares[epoch][vault] += vaultShare - curatorShare;
            }
        }
    }

    function _processOperator(uint48 epoch, address operator) private {
        _calculateOperatorShare(epoch, operator);
        _calculateAndStoreVaultShares(epoch, operator);
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
