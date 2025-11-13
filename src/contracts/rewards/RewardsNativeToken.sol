// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {AvalancheL1Middleware} from "../middleware/AvalancheL1Middleware.sol";
import {MiddlewareVaultManager} from "../middleware/MiddlewareVaultManager.sol";
import {UptimeTracker} from "./UptimeTracker.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {BaseDelegator} from "../delegator/BaseDelegator.sol";
import {IVaultTokenized} from "../../interfaces/vault/IVaultTokenized.sol";
import {VaultTokenized} from "../vault/VaultTokenized.sol";
import {IRewardsNativeToken, DistributionBatch} from "../../interfaces/rewards/IRewardsNativeToken.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

contract RewardsNativeToken is AccessControlUpgradeable, ReentrancyGuardUpgradeable, IRewardsNativeToken {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // Constants
    uint16 public constant BASIS_POINTS_DENOMINATOR = 10_000;
    bytes32 public constant REWARDS_MANAGER_ROLE = keccak256("REWARDS_MANAGER_ROLE");
    bytes32 public constant REWARDS_DISTRIBUTOR_ROLE = keccak256("REWARDS_DISTRIBUTOR_ROLE");
    bytes32 public constant PROTOCOL_OWNER_ROLE = keccak256("PROTOCOL_OWNER_ROLE");
    /// @dev Epoch N must be funded no later than N-FUNDING_DEADLINE_OFFSET.
    ///      If funded earlier, distribution can proceed; if not funded earlier, it must wait for the deadline before distribution can proceed.
    uint48 public constant FUNDING_DEADLINE_OFFSET = 4;

    /// @dev Epoch N may be distributed no earlier than N+DISTRIBUTION_EARLIEST_OFFSET.
    ///      It has to wait for state to be finalized across all contracts.
    uint48 public constant DISTRIBUTION_EARLIEST_OFFSET = 2;

    /// @dev Grace period after distribution completes before undistributed rewards can be swept.
    ///      This ensures distribution is fully settled before reclaiming unallocated rewards.
    ///      Note: This does NOT affect user claims - allocated rewards can always be claimed.
    uint48 public constant CLAIM_GRACE_PERIOD_EPOCHS = 1;
    
    /// @dev Cap epochs processed in a single claim to prevent out-of-gas on long histories
    uint48 public constant MAX_EPOCHS_PER_CLAIM = 64;

    // STATE VARIABLES
    // Fee configuration
    uint16 public protocolFee;
    uint16 public operatorFee;
    uint16 public curatorFee;

    // External contracts
    AvalancheL1Middleware public middleware;
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
    mapping(uint48 epoch => mapping(address operator => mapping(uint96 collateralClass => uint256 share)))
        public operatorBeneficiariesSharesPerCollateralClass;

    // Single rewards token model
    /// @notice Sole rewards token (L1 primary collateral)
    address public rewardsToken;
    /// @notice Protocol rewards accrued in the sole token
    uint256 public protocolRewards;

    // Per-epoch reward pool (in sole token)
    mapping(uint48 epoch => uint256 amount) public epochRewards;

    // Last claimed epoch tracking
    mapping(address staker => uint48 epoch) public lastEpochClaimedStaker;
    mapping(address curator => uint48 epoch) public lastEpochClaimedCurator;
    mapping(address operator => uint48 epoch) public lastEpochClaimedOperator;

    // Asset class configuration
    mapping(uint96 collateralClass => uint16 rewardsShare) public rewardsSharePerCollateralClass;

    // Epoch curators tracking
    mapping(uint48 epoch => EnumerableSet.AddressSet curators) private _epochCurators;

    // Undistributed sweep guard - epoch => swept
    mapping(uint48 => bool) private _undistributedSwept;

    // Per-epoch total distributed shares in basis points (bp).
    mapping(uint48 epoch => uint256 totalSharesBp) private _epochTotalDistributedShares;

    // Epoch snapshots to avoid index drift and dynamic enumeration
    mapping(uint48 epoch => address[] operators) private _epochOperators;
    mapping(uint48 epoch => address[] vaults) private _epochVaults;
    mapping(uint48 epoch => EnumerableSet.AddressSet vaultsWithShares) private _epochVaultsWithShares;
    
    // Per-epoch vault buckets by collateral class
    mapping(uint48 epoch => mapping(uint96 collateralClass => address[] vaults)) private _epochVaultsByClass;
    mapping(uint48 epoch => bool vaultsBucketed) private _epochVaultsBucketed;
    // Cursor to bucket vaults across calls
    mapping(uint48 epoch => uint256 idx) private _vaultBucketCursor;

    // Caching flags and per-operator totals
    mapping(uint48 epoch => mapping(uint96 collateralClass => bool attempted)) private _totalStakeCacheAttempted;
    mapping(uint48 epoch => mapping(address operator => mapping(uint96 collateralClass => uint256 stake))) private _operatorActiveStake;
    mapping(uint48 epoch => mapping(address operator => mapping(uint96 collateralClass => bool computed))) private _operatorActiveStakeComputed;

    // INITIALIZER
    function initialize(
        address admin_,
        address protocolOwner_,
        address payable middleware_,
        address uptimeTracker_,
        uint16 protocolFee_,
        uint16 operatorFee_,
        uint16 curatorFee_,
        uint256 minRequiredUptime_
    ) public initializer {
        if (admin_ == address(0)) revert InvalidAdmin(admin_);
        if (protocolOwner_ == address(0)) revert InvalidProtocolOwner(protocolOwner_);
        if (middleware_ == address(0)) revert InvalidL1Middleware(middleware_);
        if (uptimeTracker_ == address(0)) revert InvalidUptimeTracker(uptimeTracker_);

        __AccessControl_init();
        __ReentrancyGuard_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(REWARDS_MANAGER_ROLE, admin_);
        _grantRole(REWARDS_DISTRIBUTOR_ROLE, admin_);
        _grantRole(PROTOCOL_OWNER_ROLE, protocolOwner_);

        middleware = AvalancheL1Middleware(middleware_);
        middlewareVaultManager = MiddlewareVaultManager(middleware.getVaultManager());
        uptimeTracker = UptimeTracker(uptimeTracker_);
        epochDuration = middleware.EPOCH_DURATION();
        // Set sole rewards token to the L1 primary collateral
        rewardsToken = middleware.PRIMARY_ASSET();
        if (rewardsToken == address(0)) revert InvalidRewardsToken(rewardsToken);

        _checkFees(protocolFee_, operatorFee_, curatorFee_);

        protocolFee = protocolFee_;
        operatorFee = operatorFee_;
        curatorFee = curatorFee_;
        if (minRequiredUptime_ > epochDuration) revert InvalidMinUptime(minRequiredUptime_);
        minRequiredUptime = minRequiredUptime_;
        // Sentinel: epoch 0 is never fundable/distributable
        epochStatus[0].distributionComplete = true;
        epochStatus[0].funded = true;
        distributionBatches[0].isComplete = true;
    }

    // EXTERNAL FUNCTIONS
    /**
     * @inheritdoc IRewardsNativeToken
     */
    function distributeRewards(uint48 epoch, uint48 batchSize)
        external
        nonReentrant
        onlyRole(REWARDS_DISTRIBUTOR_ROLE)
    {
        // Validate epoch
        EpochStatus storage st = epochStatus[epoch];
        if (st.distributionComplete) revert AlreadyCompleted(epoch);
        uint48 currentEpoch = middleware.getCurrentEpoch();
        // window guards (identical to multi‑token)
        if (currentEpoch < DISTRIBUTION_EARLIEST_OFFSET)
            revert RewardsDistributionTooEarly(epoch, 0);
        uint48 earliestDistributionEpoch = currentEpoch - DISTRIBUTION_EARLIEST_OFFSET;
        if (epoch > earliestDistributionEpoch)
            revert RewardsDistributionTooEarly(epoch, earliestDistributionEpoch);

        // Enforce sequential distribution, include epoch 0
        if (epoch > 0) {
            EpochStatus storage prevSt = epochStatus[epoch - 1];
            if (!prevSt.distributionComplete) {
                revert DistributionNotComplete(epoch - 1);
            }
        }

        // only auto-complete when there are no operators.
        bool fundingWindowClosedUnfunded = (currentEpoch > epoch + FUNDING_DEADLINE_OFFSET) && !st.funded;
        if (fundingWindowClosedUnfunded) {
            address[] memory opsNow = middleware.getAllOperators();
            if (opsNow.length == 0) {
                distributionBatches[epoch].isComplete = true;
                st.distributionComplete = true;
                emit RewardsDistributed(epoch);
                return;
            }
        }

        // Snapshot registries once per epoch to avoid index drift
        if (_epochOperators[epoch].length == 0) {
            _epochOperators[epoch] = middleware.getAllOperators();
        }
        if (_epochVaults[epoch].length == 0 && _epochOperators[epoch].length != 0) {
            _epochVaults[epoch] = middlewareVaultManager.getVaults(epoch);
        }

        // Funding window: during [epoch, epoch+FUNDING_DEADLINE_OFFSET] require funded if operators exist
        bool fundingWindowOpen = epoch + FUNDING_DEADLINE_OFFSET >= currentEpoch;
        if (fundingWindowOpen && !st.funded) {
            if (_epochOperators[epoch].length != 0) revert EpochNotFunded(epoch);
        }

        // Bucket vaults by class in batches to avoid gas spikes
        if (!_epochVaultsBucketed[epoch]) {
            address[] storage vaults = _epochVaults[epoch];
            uint256 start = _vaultBucketCursor[epoch];
            uint256 effective = (batchSize == 0) ? 1 : uint256(batchSize);
            uint256 end = Math.min(start + effective, vaults.length);
            for (uint256 i = start; i < end; i++) {
                address vault = vaults[i];
                uint96 collateralClass = middlewareVaultManager.getVaultCollateralClass(vault);
                _epochVaultsByClass[epoch][collateralClass].push(vault);
            }
            _vaultBucketCursor[epoch] = end;
            if (end == vaults.length) {
                _epochVaultsBucketed[epoch] = true;
            } else {
                // continue bucketing on next call
                return;
            }
        }

        // Execute distribution in batches
        DistributionBatch storage batch = distributionBatches[epoch];
        address[] storage operators = _epochOperators[epoch];
        uint256 operatorCount = operators.length;
        uint256 startIdx = batch.lastProcessedOperator;
        uint256 endIdx = Math.min(startIdx + batchSize, operatorCount);

        for (uint256 i = startIdx; i < endIdx; i++) {
            _processOperator(epoch, operators[i]);
            // finalize early if epoch cap is reached
            if (_epochTotalDistributedShares[epoch] >= BASIS_POINTS_DENOMINATOR) {
                batch.lastProcessedOperator = operatorCount;
                batch.isComplete = true;
                st.distributionComplete = true;
                emit RewardsDistributed(epoch);
                return;
            }
        }

        batch.lastProcessedOperator = endIdx;

        // Mark complete if all operators processed
        if (endIdx >= operatorCount) {
            batch.isComplete = true;
            st.distributionComplete = true;
            emit RewardsDistributed(epoch);
        }
    }

    /**
     * @inheritdoc IRewardsNativeToken
     */
    function claimRewards(address recipient) external nonReentrant {
        if (recipient == address(0)) revert InvalidRecipient(recipient);

        uint48 lastClaimedEpoch = lastEpochClaimedStaker[msg.sender];
        uint48 currentEpoch = middleware.getCurrentEpoch();

        if (currentEpoch > 0 && lastClaimedEpoch >= currentEpoch - 1) {
            revert AlreadyClaimedForLatestEpoch(msg.sender, lastClaimedEpoch);
        }

        uint256 totalRewards = 0;
        uint48 newLast = lastClaimedEpoch;

        uint48 maxEpoch = currentEpoch;
        uint48 maxClaimableEpoch = lastClaimedEpoch + 1 + MAX_EPOCHS_PER_CLAIM;
        if (maxEpoch > maxClaimableEpoch) maxEpoch = maxClaimableEpoch;
        
        for (uint48 epoch = lastClaimedEpoch + 1; epoch < maxEpoch; ++epoch) {
            EpochStatus memory st = epochStatus[epoch];

            if (!st.distributionComplete) break;

            uint256 epochAmt = epochRewards[epoch];
            if (epochAmt > 0) {
                uint48 epochTs = middleware.getEpochStartTs(epoch);
                uint256 vCount = _epochVaultsWithShares[epoch].length();
                for (uint256 i = 0; i < vCount; i++) {
                    address vault = _epochVaultsWithShares[epoch].at(i);
                    uint256 vaultShare = vaultShares[epoch][vault];
                    if (vaultShare == 0) continue;

                    uint256 stakerVaultShare;
                    // tolerate vault view failures to avoid claim DoS
                    try IVaultTokenized(vault).activeSharesOfAt(msg.sender, epochTs, new bytes(0)) returns (uint256 s) {
                        stakerVaultShare = s;
                    } catch { continue; }
                    if (stakerVaultShare == 0) continue;

                    // Get total raw shares in this specific vault at that time
                    uint256 totalRawSharesInVault;
                    try IVaultTokenized(vault).activeSharesAt(epochTs, new bytes(0)) returns (uint256 t) {
                        totalRawSharesInVault = t;
                    } catch { continue; }
                    if (totalRawSharesInVault == 0) continue;

                    uint256 tokensForVault = Math.mulDiv(
                        epochAmt,
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
        lastEpochClaimedStaker[msg.sender] = newLast;

        if (totalRewards == 0) {
            if (newLast > lastClaimedEpoch) {
                emit ZeroRewardsClaim(msg.sender, rewardsToken, newLast, "staker");
                return;
            }
            revert NoRewardsToClaimEpoch(msg.sender, lastClaimedEpoch);
        }

        IERC20(rewardsToken).safeTransfer(recipient, totalRewards);
    }

    /**
     * @inheritdoc IRewardsNativeToken
     */
    function claimOperatorFee(address recipient) external nonReentrant {
        if (recipient == address(0)) revert InvalidRecipient(recipient);

        uint48 currentEpoch = middleware.getCurrentEpoch();
        uint48 lastClaimedEpoch = lastEpochClaimedOperator[msg.sender];

        if (currentEpoch > 0 && lastClaimedEpoch >= currentEpoch - 1) {
            revert AlreadyClaimedForLatestEpoch(msg.sender, lastClaimedEpoch);
        }

        uint256 totalRewards = 0;
        uint48 newLast = lastClaimedEpoch;

        uint48 maxEpoch = currentEpoch;
        uint48 maxClaimableEpoch = lastClaimedEpoch + 1 + MAX_EPOCHS_PER_CLAIM;
        if (maxEpoch > maxClaimableEpoch) maxEpoch = maxClaimableEpoch;
        
        for (uint48 epoch = lastClaimedEpoch + 1; epoch < maxEpoch; ++epoch) {
            EpochStatus memory st = epochStatus[epoch];

            if (!st.distributionComplete) break;

            uint256 epochAmt = epochRewards[epoch];
            if (epochAmt > 0) {
                uint256 share = operatorShares[epoch][msg.sender];
                if (share > 0) {
                    totalRewards += Math.mulDiv(epochAmt, share, BASIS_POINTS_DENOMINATOR);
                }
            }
            newLast = epoch;
        }

        // Update pointer
        lastEpochClaimedOperator[msg.sender] = newLast;

        if (totalRewards == 0) {
            if (newLast > lastClaimedEpoch) {
                emit ZeroRewardsClaim(msg.sender, rewardsToken, newLast, "operator");
                return;
            }
            revert NoRewardsToClaimEpoch(msg.sender, lastClaimedEpoch);
        }
        
        IERC20(rewardsToken).safeTransfer(recipient, totalRewards);
    }

    /**
     * @inheritdoc IRewardsNativeToken
     */
    function claimCuratorFee(address recipient) external nonReentrant {
        if (recipient == address(0)) revert InvalidRecipient(recipient);

        uint48 currentEpoch = middleware.getCurrentEpoch();
        uint48 lastClaimedEpoch = lastEpochClaimedCurator[msg.sender];

        if (currentEpoch > 0 && lastClaimedEpoch >= currentEpoch - 1) {
            revert AlreadyClaimedForLatestEpoch(msg.sender, lastClaimedEpoch);
        }

        uint256 totalRewards = 0;
        uint48 newLast = lastClaimedEpoch;

        uint48 maxEpoch = currentEpoch;
        uint48 maxClaimableEpoch = lastClaimedEpoch + 1 + MAX_EPOCHS_PER_CLAIM;
        if (maxEpoch > maxClaimableEpoch) maxEpoch = maxClaimableEpoch;
        
        for (uint48 epoch = lastClaimedEpoch + 1; epoch < maxEpoch; ++epoch) {
            EpochStatus memory st = epochStatus[epoch];

            if (!st.distributionComplete) break;

            uint256 epochAmt = epochRewards[epoch];
            if (epochAmt > 0) {
                uint256 share = curatorShares[epoch][msg.sender];
                if (share > 0) {
                    totalRewards += Math.mulDiv(epochAmt, share, BASIS_POINTS_DENOMINATOR);
                }
            }
            newLast = epoch;
        }

        // Update pointer
        lastEpochClaimedCurator[msg.sender] = newLast;

        if (totalRewards == 0) {
            if (newLast > lastClaimedEpoch) {
                emit ZeroRewardsClaim(msg.sender, rewardsToken, newLast, "curator");
                return;
            }
            revert NoRewardsToClaimEpoch(msg.sender, lastClaimedEpoch);
        }

        IERC20(rewardsToken).safeTransfer(recipient, totalRewards);
    }

    /**
     * @inheritdoc IRewardsNativeToken
     */
    function claimProtocolFee(address recipient) external nonReentrant onlyRole(PROTOCOL_OWNER_ROLE) {
        if (recipient == address(0)) revert InvalidRecipient(recipient);

        uint256 rewards = protocolRewards;
        if (rewards == 0) revert NoRewardsToClaim(msg.sender);

        protocolRewards = 0;
        IERC20(rewardsToken).safeTransfer(recipient, rewards);
    }

    /**
     * @inheritdoc IRewardsNativeToken
     */
    function claimUndistributedRewards(
        uint48 epoch,
        address recipient
    ) external nonReentrant onlyRole(REWARDS_DISTRIBUTOR_ROLE) {
        if (recipient == address(0)) revert InvalidRecipient(recipient);

        // prevent double‑sweep
        if (_undistributedSwept[epoch]) revert NoRewardsToClaim(msg.sender);

        // Check if epoch distribution is complete
        EpochStatus storage st = epochStatus[epoch];
        if (!st.distributionComplete) revert DistributionNotComplete(epoch);

        // The sweep can only happen after the distribution offset AND the claim grace period have passed.
        uint48 currentEpoch = middleware.getCurrentEpoch();
        uint48 requiredEpoch = epoch + DISTRIBUTION_EARLIEST_OFFSET + CLAIM_GRACE_PERIOD_EPOCHS;
        
        if (currentEpoch < requiredEpoch) {
            revert EpochStillClaimable(epoch);
        }

        // Get total rewards for the epoch
        uint256 totalRewardsForEpoch = epochRewards[epoch];
        if (totalRewardsForEpoch == 0) revert NoRewardsToClaim(msg.sender);

        // O(1): use accumulated bp; fallback to legacy enumeration if zero (old epochs)
        uint256 totalDistributedShares = _epochTotalDistributedShares[epoch];
        // Treat cache as source of truth. If zero, sweep full epoch without enumeration.

        // If no shares were distributed, sweep all rewards
        if (totalDistributedShares == 0) {
            _undistributedSwept[epoch] = true;
            IERC20(rewardsToken).safeTransfer(recipient, totalRewardsForEpoch);
            emit UndistributedRewardsClaimed(epoch, rewardsToken, recipient, totalRewardsForEpoch);
            return;
        }

        // Clamp shares and compute undistributed
        uint256 usedShares = totalDistributedShares > BASIS_POINTS_DENOMINATOR
            ? BASIS_POINTS_DENOMINATOR
            : totalDistributedShares;
        uint256 undistributedRewards = totalRewardsForEpoch - Math.mulDiv(
            totalRewardsForEpoch,
            usedShares,
            BASIS_POINTS_DENOMINATOR
        );
        if (undistributedRewards == 0) revert NoRewardsToClaim(msg.sender);

        // Mark as swept before transfer to prevent reentrancy
        _undistributedSwept[epoch] = true;

        IERC20(rewardsToken).safeTransfer(recipient, undistributedRewards);

        emit UndistributedRewardsClaimed(epoch, rewardsToken, recipient, undistributedRewards);
    }

    /**
     * @inheritdoc IRewardsNativeToken
     */
    function updateAllFees(
        uint16 newProtocolFee,
        uint16 newOperatorFee,
        uint16 newCuratorFee
    ) external onlyRole(REWARDS_MANAGER_ROLE) {
        _checkFees(newProtocolFee, newOperatorFee, newCuratorFee);
        protocolFee = newProtocolFee;
        operatorFee = newOperatorFee;
        curatorFee = newCuratorFee;
        emit ProtocolFeeUpdated(newProtocolFee);
        emit OperatorFeeUpdated(newOperatorFee);
        emit CuratorFeeUpdated(newCuratorFee);
    }

    // Setter functions
    /**
     * @inheritdoc IRewardsNativeToken
     */
    function setRewardsAmountForEpochs(
        uint48 startEpoch,
        uint48 numberOfEpochs,
        uint256 rewardsAmount
    ) external nonReentrant onlyRole(REWARDS_DISTRIBUTOR_ROLE) {
        if (rewardsToken == address(0)) revert InvalidRewardsToken(rewardsToken);
        if (rewardsAmount == 0) revert InvalidRewardsAmount(rewardsAmount);
        if (numberOfEpochs == 0) revert InvalidNumberOfEpochs(numberOfEpochs);

        // Check if distribution has been initiated (vault bucketing started or operators processed)
        DistributionBatch storage startBatch = distributionBatches[startEpoch];
        if (_vaultBucketCursor[startEpoch] > 0 || startBatch.lastProcessedOperator > 0 || startBatch.isComplete) {
            revert DistributionAlreadyStarted(startEpoch);
        }

        // Credit by measured balance delta to support fee-on-transfer tokens
        uint256 balanceBefore = IERC20(rewardsToken).balanceOf(address(this));
        IERC20(rewardsToken).safeTransferFrom(msg.sender, address(this), rewardsAmount * numberOfEpochs);
        uint256 received = IERC20(rewardsToken).balanceOf(address(this)) - balanceBefore;

        // Split what actually arrived: protocol cut from received, remainder to epochs
        uint256 protocolRewardsAmount = Math.mulDiv(received, protocolFee, BASIS_POINTS_DENOMINATOR);
        protocolRewards += protocolRewardsAmount;
        uint256 totalRewardsForEpochs = received - protocolRewardsAmount;
        uint256 rewardsPerEpoch = totalRewardsForEpochs / numberOfEpochs;              // floor
        uint256 remainderRewards = totalRewardsForEpochs - rewardsPerEpoch * numberOfEpochs;       // carry remainder to last epoch

        for (uint48 i = 0; i < numberOfEpochs; i++) {
            uint48 targetEpoch = startEpoch + i;
            EpochStatus storage status = epochStatus[targetEpoch];
            uint256 epochAmount = rewardsPerEpoch + (i == numberOfEpochs - 1 ? remainderRewards : 0);
            if (epochAmount > 0) status.funded = true; // only flag funded if something actually landed
            epochRewards[targetEpoch] += epochAmount;
        }

        emit RewardsAmountSet(startEpoch, numberOfEpochs, rewardsToken, rewardsPerEpoch);
    }

    /**
     * @inheritdoc IRewardsNativeToken
     */
    function setRewardsShareForCollateralClass(uint96 collateralClass, uint16 share) external onlyRole(REWARDS_MANAGER_ROLE) {
        if (share > BASIS_POINTS_DENOMINATOR) revert InvalidShare(share);

        uint16 prev = rewardsSharePerCollateralClass[collateralClass];
        uint256 newTotal = _totalCollateralClassShares() - prev + share;
        if (newTotal > BASIS_POINTS_DENOMINATOR) revert CollateralClassSharesExceed100(newTotal);

        rewardsSharePerCollateralClass[collateralClass] = share;
        emit RewardsShareUpdated(collateralClass, share);
    }

    /**
     * @inheritdoc IRewardsNativeToken
     */
    function setRewardsManagerRole(address newRewardsManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRewardsManager == address(0)) revert InvalidAdmin(newRewardsManager);
        _grantRole(REWARDS_MANAGER_ROLE, newRewardsManager);
        emit RewardsManagerRoleAssigned(newRewardsManager);
    }

    /**
     * @inheritdoc IRewardsNativeToken
     */
    function setRewardsDistributorRole(address newRewardsDistributor) external onlyRole(REWARDS_MANAGER_ROLE) {
        if (newRewardsDistributor == address(0)) revert InvalidAdmin(newRewardsDistributor);
        _grantRole(REWARDS_DISTRIBUTOR_ROLE, newRewardsDistributor);
        emit RewardsDistributorRoleAssigned(newRewardsDistributor);
    }

    /**
     * @inheritdoc IRewardsNativeToken
     */
    function setProtocolOwner(address newProtocolOwner) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newProtocolOwner == address(0)) revert InvalidProtocolOwner(newProtocolOwner);
        _grantRole(PROTOCOL_OWNER_ROLE, newProtocolOwner);
        emit ProtocolOwnerUpdated(newProtocolOwner);
    }

    /**
     * @inheritdoc IRewardsNativeToken
     */
    function setMinRequiredUptime(uint256 uptime) external onlyRole(REWARDS_MANAGER_ROLE) {
        if (uptime > epochDuration) revert InvalidMinUptime(uptime);
        minRequiredUptime = uptime;
    }

    /**
     * @inheritdoc IRewardsNativeToken
     */
    function updateProtocolFee(uint16 newFee) external onlyRole(REWARDS_MANAGER_ROLE) {
        _checkFees(newFee, operatorFee, curatorFee);
        protocolFee = newFee;
        emit ProtocolFeeUpdated(newFee);
    }

    /**
     * @inheritdoc IRewardsNativeToken
     */
    function updateOperatorFee(uint16 newFee) external onlyRole(REWARDS_MANAGER_ROLE) {
        _checkFees(protocolFee, newFee, curatorFee);
        operatorFee = newFee;
        emit OperatorFeeUpdated(newFee);
    }

    /**
     * @inheritdoc IRewardsNativeToken
     */
    function updateCuratorFee(uint16 newFee) external onlyRole(REWARDS_MANAGER_ROLE) {
        _checkFees(protocolFee, operatorFee, newFee);
        curatorFee = newFee;
        emit CuratorFeeUpdated(newFee);
    }

    // Getter functions
    /**
     * @inheritdoc IRewardsNativeToken
     */
    function getEpochRewards(uint48 epoch) external view override returns (uint256) {
        return epochRewards[epoch];
    }

    // INTERNAL FUNCTIONS
    // Helper functions
    function _totalCollateralClassShares() internal view returns (uint256 total) {
        uint96[] memory ids = middleware.getCollateralClassIds();
        for (uint256 i; i < ids.length; ++i) total += rewardsSharePerCollateralClass[ids[i]];
    }

    /// @dev Reverts if fees exceed 100 % (10 000 bp)
    function _checkFees(uint16 protocolFee_, uint16 operatorFee_, uint16 curatorFee_) internal pure {
        if (protocolFee_ + operatorFee_ + curatorFee_ > BASIS_POINTS_DENOMINATOR)
            revert FeeConfigurationExceeds100(protocolFee_ + operatorFee_ + curatorFee_);
    }

    // Calculation functions
    /// @dev Ensures the total stake cache is populated for the given epoch and asset class
    function _ensureStakeCache(uint48 epoch, uint96 collateralClass) internal returns (uint256 totalStake) {
        totalStake = middleware.totalStakeCache(epoch, collateralClass);
        if (totalStake == 0 && !_totalStakeCacheAttempted[epoch][collateralClass]) {
            try middleware.calcAndCacheStakes(epoch, collateralClass) {
                totalStake = middleware.totalStakeCache(epoch, collateralClass);
                _totalStakeCacheAttempted[epoch][collateralClass] = true; // mark only after a successful attempt
            } catch {
                // leave attempted=false; allow future retries
            }
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

        uint96[] memory collateralClasses = middleware.getCollateralClassIds();
        uint256 rawShare;
        uint256 operatorFeeShare;
        for (uint256 i = 0; i < collateralClasses.length; i++) {
            uint96 collateralClass = collateralClasses[i];
            uint16 collateralClassShare = rewardsSharePerCollateralClass[collateralClass];
            if (collateralClassShare == 0) continue;
            uint256 totalStake = _ensureStakeCache(epoch, collateralClass);
            if (totalStake == 0) continue;

            uint256 operatorStake;
            // tolerate view-call failures to avoid epoch-wide DoS
            try middleware.getOperatorUsedStakeCachedPerEpoch(epoch, operator, collateralClass) returns (uint256 s) {
                operatorStake = s;
            } catch {
                operatorStake = 0;
            }

            rawShare = Math.mulDiv(
                Math.mulDiv(operatorStake, BASIS_POINTS_DENOMINATOR, totalStake),
                collateralClassShare,
                BASIS_POINTS_DENOMINATOR
            );
            rawShare = Math.mulDiv(rawShare, operatorUptime, BASIS_POINTS_DENOMINATOR);

            operatorFeeShare = Math.mulDiv(rawShare, operatorFee, BASIS_POINTS_DENOMINATOR);

            operatorBeneficiariesSharesPerCollateralClass[epoch][operator][collateralClass] = rawShare - operatorFeeShare;

            totalOperatorFeeShare += operatorFeeShare;
            totalBeneficiaryShare += rawShare - operatorFeeShare;
        }

        // Cap per-epoch distributed shares at 10_000 bp
        uint256 capRemaining = BASIS_POINTS_DENOMINATOR - _epochTotalDistributedShares[epoch];
        uint256 operatorBpToAdd = totalOperatorFeeShare > capRemaining ? capRemaining : totalOperatorFeeShare;
        // set once per operator; lastProcessedOperator prevents re-entry
        operatorShares[epoch][operator] = operatorBpToAdd;
        if (operatorBpToAdd > 0) {
            _epochTotalDistributedShares[epoch] += operatorBpToAdd;
        }
    }

    /**
     * @dev Calculates and stores the vault shares for a given epoch and operator
     * @param epoch The epoch to calculate the vault shares for
     * @param operator The operator to calculate the vault shares for
     */
    function _calculateAndStoreVaultShares(uint48 epoch, address operator) internal {
        uint48 epochTs = middleware.getEpochStartTs(epoch);
        uint96[] memory classes = middleware.getCollateralClassIds();
        uint256 addedBp; // bp actually credited in this call (stakers + curators)

        for (uint256 c = 0; c < classes.length; c++) {
            uint96 cls = classes[c];
            uint256 operatorClassShare = operatorBeneficiariesSharesPerCollateralClass[epoch][operator][cls];
            if (operatorClassShare == 0) continue;

            address[] storage vaultsForClass = _epochVaultsByClass[epoch][cls];
            for (uint256 i = 0; i < vaultsForClass.length; i++) {
                address vault = vaultsForClass[i];
                // stop if cap already reached by prior credits in this call
                uint256 capRemainingLocal = BASIS_POINTS_DENOMINATOR - (_epochTotalDistributedShares[epoch] + addedBp);
                if (capRemainingLocal == 0) { _epochTotalDistributedShares[epoch] += addedBp; return; }

                // delegator() may revert → read defensively
                address delegator;
                try IVaultTokenized(vault).delegator() returns (address d) {
                    delegator = d;
                } catch { continue; }

                uint256 vaultStake;
                // tolerate bad/misbehaving delegators
                try BaseDelegator(delegator).stakeAt(
                    middleware.BALANCER(), cls, operator, epochTs, new bytes(0)
                ) returns (uint256 s) { vaultStake = s; } catch { continue; }
                if (vaultStake == 0) continue;

                uint256 operatorActiveStake = _operatorActiveStake[epoch][operator][cls];
                if (!_operatorActiveStakeComputed[epoch][operator][cls]) {
                    uint256 sum;
                    // tolerate middleware view failure
                    try middleware.getOperatorStake(operator, epoch, cls) returns (uint256 s2) { sum = s2; } catch { sum = 0; }
                    _operatorActiveStakeComputed[epoch][operator][cls] = true;
                    _operatorActiveStake[epoch][operator][cls] = sum;
                    operatorActiveStake = sum;
                }
                if (operatorActiveStake == 0) continue;

                uint256 vaultShare = Math.mulDiv(vaultStake, BASIS_POINTS_DENOMINATOR, operatorActiveStake);
                vaultShare = Math.mulDiv(vaultShare, operatorClassShare, BASIS_POINTS_DENOMINATOR);

                uint256 curatorBp = Math.mulDiv(vaultShare, curatorFee, BASIS_POINTS_DENOMINATOR);
                uint256 stakerBp = vaultShare - curatorBp;

                // Stop when epoch cap would be exceeded. Leave remainder sweepable.
                if (stakerBp + curatorBp > capRemainingLocal) {
                    _epochTotalDistributedShares[epoch] += addedBp;
                    return;
                }

                // Credit curator if owner() available
                if (curatorBp > 0) {
                    address curator;
                    try VaultTokenized(vault).owner() returns (address o) { curator = o; } catch { curator = address(0); }
                    if (curator != address(0)) {
                        curatorShares[epoch][curator] += curatorBp;
                        _epochCurators[epoch].add(curator);
                        addedBp += curatorBp;
                    } else {
                        curatorBp = 0; // not credited; remains sweepable
                    }
                }

                // Credit stakers only if positive to keep claim set small
                if (stakerBp > 0) {
                    vaultShares[epoch][vault] += stakerBp;
                    _epochVaultsWithShares[epoch].add(vault);
                    addedBp += stakerBp;
                }
            }
        }
        if (addedBp > 0) {
            _epochTotalDistributedShares[epoch] += addedBp;
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
        uint48 epochStart = middleware.getEpochStartTs(epoch);

        // Use temporary array sized to maximum possible length
        address[] memory tempVaults = new address[](vaults.length);
        uint256 count = 0;

        // Single pass: Check balance and collect valid vaults
        for (uint256 i = 0; i < vaults.length;) {
            if (IVaultTokenized(vaults[i]).activeBalanceOfAt(staker, epochStart, new bytes(0)) > 0) {
                tempVaults[count] = vaults[i];
                count++;
            }
            unchecked { ++i; }
        }

        // Create final array with exact count and copy valid vaults
        address[] memory validVaults = new address[](count);
        for (uint256 i = 0; i < count;) {
            validVaults[i] = tempVaults[i];
            unchecked { ++i; }
        }

        return validVaults;
    }
}
