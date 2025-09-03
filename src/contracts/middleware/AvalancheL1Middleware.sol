// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {
    Validator,
    ValidatorStatus,
    PChainOwner
} from "@avalabs/icm-contracts/validator-manager/interfaces/IACP99Manager.sol";
import {IBalancerValidatorManager} from
    "@suzaku/contracts-library/interfaces/ValidatorManager/IBalancerValidatorManager.sol";

import {IOperatorRegistry} from "../../interfaces/IOperatorRegistry.sol";
import {IVaultTokenized} from "../../interfaces/vault/IVaultTokenized.sol";
import {IAvalancheL1Middleware} from "../../interfaces/middleware/IAvalancheL1Middleware.sol";
import {IOptInService} from "../../interfaces/service/IOptInService.sol";

import {CollateralClassRegistry} from "./CollateralClassRegistry.sol";
import {MiddlewareVaultManager} from "./MiddlewareVaultManager.sol";
import {MapWithTimeData} from "./libraries/MapWithTimeData.sol";
import {StakeConversion} from "./libraries/StakeConversion.sol";
import {BaseDelegator} from "../../contracts/delegator/BaseDelegator.sol";

struct AvalancheL1MiddlewareSettings {
    address balancer;
    address operatorRegistry;
    address vaultRegistry;
    address operatorL1Optin;
    uint48 epochDuration;
    uint48 slashingWindow;
    uint48 stakeUpdateWindow;
}

/**
 * @title AvalancheL1Middleware
 * @notice Manages operator registration, vault registration, stake accounting, and slashing for Avalanche L1
 */
contract AvalancheL1Middleware is IAvalancheL1Middleware, CollateralClassRegistry {
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    using EnumerableSet for EnumerableSet.UintSet;
    using MapWithTimeData for EnumerableMap.AddressToUintMap;
    using EnumerableMap for EnumerableMap.Bytes32ToUintMap;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    address public immutable BALANCER;
    address public immutable OPERATOR_REGISTRY;
    address public immutable OPERATOR_L1_OPTIN;
    address public immutable PRIMARY_ASSET;
    uint48 public immutable EPOCH_DURATION;
    uint48 public immutable SLASHING_WINDOW;
    uint48 public immutable START_TIME;
    uint48 public immutable UPDATE_WINDOW;
    uint256 public immutable WEIGHT_SCALE_FACTOR;
    uint48 public lastGlobalNodeStakeUpdateEpoch;

    uint96 public constant PRIMARY_ASSET_CLASS = 1;
    uint48 public constant MAX_AUTO_EPOCH_UPDATES = 1;
    uint48 public constant REMOVAL_DELAY_EPOCHS = 6;
    MiddlewareVaultManager private vaultManager;
    EnumerableMap.AddressToUintMap private operators;
    EnumerableSet.UintSet private secondaryCollateralClasses;
    bool private vaultManagerSet;

    IBalancerValidatorManager public balancerValidatorManager;

    mapping(address => mapping(uint48 => bool)) public rebalancedThisEpoch;
    mapping(uint48 => mapping(uint96 => uint256)) public totalStakeCache;
    mapping(address => bytes32[]) public operatorNodesArray;
    mapping(uint48 => mapping(bytes32 => uint256)) public nodeStakeCache;
    mapping(bytes32 => bool) public nodePendingRemoval;
    mapping(address => uint256) public operatorLockedStake;
    mapping(uint48 => mapping(uint96 => bool)) public totalStakeCached;
    mapping(bytes32 => address) private validationIdToOperator;
    // operatorNodesArray[operator] is used for iteration during certain
    // rebalancing or node-update operations, and has nodes removed once
    // they are effectively retired. This means a node can remain in
    // operatorNodes while it is removed from operatorNodesArray.
    // operatorNodes[operator] is intended as a permanent record of all nodes
    // ever registered by the operator, used for historical/epoch-based queries.
    // We do *not* remove nodes from this set when they are "retired" so
    // getActiveNodesForEpoch(...) can still detect them for past epochs.
    mapping(address => EnumerableSet.Bytes32Set) private operatorNodes;
    mapping(uint48 => mapping(uint96 => mapping(address => uint256))) private operatorStakeCache;
    mapping(bytes32 => bytes32) private pendingRemovalValId;        // nodeId -> valID (0x0 == not‑pending)
    mapping(bytes32 => uint256) private _pendingStake;

    /**
     * @notice Initializes contract settings
     * @param settings General contract parameters
     * @param owner Owner address
     * @param primaryCollateral The primary collateral address
     * @param primaryCollateralMaxStake Max stake for the primary collateral class
     * @param primaryCollateralMinStake Min stake for the primary collateral class
     */
    constructor(
        AvalancheL1MiddlewareSettings memory settings,
        address owner,
        address primaryCollateral,
        uint256 primaryCollateralMaxStake,
        uint256 primaryCollateralMinStake,
        uint256 primaryCollateralWeightScaleFactor
    ) CollateralClassRegistry(owner) {
        if (settings.balancer == address(0)) {
            revert AvalancheL1Middleware__ZeroAddress();
        }
        if (settings.operatorRegistry == address(0)) {
            revert AvalancheL1Middleware__ZeroAddress();
        }
        if (settings.vaultRegistry == address(0)) {
            revert AvalancheL1Middleware__ZeroAddress();
        }
        if (settings.operatorL1Optin == address(0)) {
            revert AvalancheL1Middleware__ZeroAddress();
        }
        if (owner == address(0)) {
            revert AvalancheL1Middleware__ZeroAddress();
        }
        if (primaryCollateral == address(0)) {
            revert AvalancheL1Middleware__ZeroAddress();
        }
        if (settings.slashingWindow < settings.epochDuration) {
            revert AvalancheL1Middleware__InvalidWindow();
        }

        // 0 < stakeUpdateWindow < epochDuration ≤ slashingWindow
        if (
            settings.stakeUpdateWindow == 0 ||
            settings.stakeUpdateWindow >= settings.epochDuration
        ) {
            revert AvalancheL1Middleware__InvalidWindow();
        }

        uint256 _minAllowed = (primaryCollateralMaxStake + type(uint64).max - 1)
            / type(uint64).max;  // ceiling (maxStake / (2⁶⁴‑1))
        if (_minAllowed == 0) _minAllowed = 1;
        uint256 _maxAllowed = primaryCollateralMinStake;   // ensures minStake implies weight ≥ 1

        if (
            primaryCollateralWeightScaleFactor < _minAllowed ||
            primaryCollateralWeightScaleFactor > _maxAllowed
        ) {
            revert AvalancheL1Middleware__ScaleFactorOutOfBounds(
                primaryCollateralWeightScaleFactor,
                _minAllowed,
                _maxAllowed
            );
        }

        START_TIME = Time.timestamp();
        EPOCH_DURATION = settings.epochDuration;
        BALANCER = settings.balancer;
        OPERATOR_REGISTRY = settings.operatorRegistry;
        OPERATOR_L1_OPTIN = settings.operatorL1Optin;
        SLASHING_WINDOW = settings.slashingWindow;
        PRIMARY_ASSET = primaryCollateral;
        UPDATE_WINDOW = settings.stakeUpdateWindow;
        WEIGHT_SCALE_FACTOR = primaryCollateralWeightScaleFactor;

        balancerValidatorManager = IBalancerValidatorManager(settings.balancer);
        _addCollateralClass(PRIMARY_ASSET_CLASS, primaryCollateralMinStake, primaryCollateralMaxStake, PRIMARY_ASSET);
    }

    /**
     * @notice Updates stake cache before function execution
     * @param epoch The epoch to update
     * @param collateralClassId The asset class ID
     */
    function _updateStakeCache(uint48 epoch, uint96 collateralClassId) private {
        if (!totalStakeCached[epoch][collateralClassId]) {
            calcAndCacheStakes(epoch, collateralClassId);
        }
    }

    /**
     * @notice Window where a node update can be done manually, before the force update can be applied
     */
    function _onlyDuringFinalWindowOfEpoch() private view {
        uint48 currentEpoch = getCurrentEpoch();
        uint48 epochStartTs = getEpochStartTs(currentEpoch);
        uint48 timeNow = Time.timestamp();
        uint48 epochUpdatePeriod = epochStartTs + UPDATE_WINDOW;

        if (timeNow < epochUpdatePeriod || timeNow > epochStartTs + EPOCH_DURATION) {
            revert AvalancheL1Middleware__NotEpochUpdatePeriod(timeNow, epochUpdatePeriod);
        }
    }

    function _onlyRegisteredOperatorNode(address operator, bytes32 nodeId) private view {
        if (!operators.contains(operator)) {
            revert AvalancheL1Middleware__OperatorNotRegistered(operator);
        }
        if (!operatorNodes[operator].contains(nodeId)) {
            revert AvalancheL1Middleware__NodeNotFound(nodeId);
        }
    }

    function _updateGlobalNodeStakeOncePerEpoch() private {
        uint48 current = getCurrentEpoch();
        if (current > lastGlobalNodeStakeUpdateEpoch) {
            calcAndCacheNodeStakeForAllOperators();
            lastGlobalNodeStakeUpdateEpoch = current;
        }
    }

    function setVaultManager(
        address vaultManager_
    ) external onlyOwner {
        if (vaultManagerSet) {
            revert AvalancheL1Middleware__VaultManagerAlreadySet(address(vaultManager));
        }
        if (vaultManager_ == address(0)) {
            revert AvalancheL1Middleware__ZeroAddress();
        }
        vaultManagerSet = true;
        vaultManager = MiddlewareVaultManager(vaultManager_);
        emit VaultManagerUpdated(address(vaultManager), vaultManager_);
    }



    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function activateSecondaryCollateralClass(
        uint256 collateralClassId
    ) external onlyOwner {
        _updateGlobalNodeStakeOncePerEpoch();
        if (!collateralClassIds.contains(collateralClassId)) {
            revert CollateralClassRegistry__CollateralClassNotFound();
        }
        if (collateralClassId == PRIMARY_ASSET_CLASS) {
            revert CollateralClassRegistry__CollateralClassAlreadyExists();
        }
        bool added = secondaryCollateralClasses.add(collateralClassId);
        if (!added) {
            revert CollateralClassRegistry__CollateralClassAlreadyExists();
        }
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function deactivateSecondaryCollateralClass(
        uint256 collateralClassId
    ) external onlyOwner {
        _updateGlobalNodeStakeOncePerEpoch();
        if (_isUsedCollateralClass(collateralClassId)) {
            revert AvalancheL1Middleware__AssetStillInUse(collateralClassId);
        }
        bool removed = secondaryCollateralClasses.remove(collateralClassId);
        if (!removed) {
            revert CollateralClassRegistry__CollateralClassNotFound();
        }
    }

    /**
     * @notice Removes an asset from an asset class, except primary collateral
     * @param collateralClassId The ID of the asset class
     * @param asset The address of the asset to remove
     */
    function removeAssetFromClass(
        uint256 collateralClassId,
        address asset
    ) public override onlyOwner {
        _updateGlobalNodeStakeOncePerEpoch();
        if (collateralClassId == 1 && asset == PRIMARY_ASSET) {
            revert CollateralClassRegistry__AssetIsPrimaryCollateralClass(collateralClassId);
        }

        if (_isUsedAsset(collateralClassId, asset)) {
            revert AvalancheL1Middleware__AssetStillInUse(collateralClassId);
        }

        super.removeAssetFromClass(collateralClassId, asset);
    }

    /**
     * @notice Removes an asset class
     * @param collateralClassId The asset class ID
     */
    function removeCollateralClass(
        uint256 collateralClassId
    ) public override onlyOwner {
        _updateGlobalNodeStakeOncePerEpoch();
        if (secondaryCollateralClasses.contains(collateralClassId)) {
            revert AvalancheL1Middleware__ActiveSecondaryCollateralClass(collateralClassId);
        }

        super.removeCollateralClass(collateralClassId);
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function registerOperator(
        address operator
    ) external onlyOwner {
        _updateGlobalNodeStakeOncePerEpoch();
        if (operators.contains(operator)) {
            revert AvalancheL1Middleware__OperatorAlreadyRegistered(operator);
        }
        if (!IOperatorRegistry(OPERATOR_REGISTRY).isRegistered(operator)) {
            revert AvalancheL1Middleware__OperatorNotRegistered(operator);
        }
        if (!IOptInService(OPERATOR_L1_OPTIN).isOptedIn(operator, BALANCER)) {
            revert AvalancheL1Middleware__OperatorNotOptedIn(operator, BALANCER);
        }

        operators.add(operator);
        operators.enable(operator);
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function disableOperator(
        address operator
    ) external onlyOwner {
        _updateGlobalNodeStakeOncePerEpoch();
        if (operatorNodesArray[operator].length > 0) {
            revert AvalancheL1Middleware__OperatorHasActiveNodes(operator, operatorNodesArray[operator].length);
        }
        operators.disable(operator);
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function enableOperator(
        address operator
    ) external onlyOwner {
        _updateGlobalNodeStakeOncePerEpoch();
        operators.enable(operator);
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function removeOperator(
        address operator
    ) external onlyOwner {
        _updateGlobalNodeStakeOncePerEpoch();
        if (operatorNodesArray[operator].length > 0) {
            revert AvalancheL1Middleware__OperatorHasActiveNodes(operator, operatorNodesArray[operator].length);
        }
        (, uint48 disabledTime) = operators.getTimes(operator);
        uint48 disabledEpoch = getEpochAtTs(disabledTime);
        if (disabledTime == 0 || disabledTime + SLASHING_WINDOW > Time.timestamp() || getCurrentEpoch() < disabledEpoch + REMOVAL_DELAY_EPOCHS) {
            revert AvalancheL1Middleware__OperatorGracePeriodNotPassed(disabledTime, SLASHING_WINDOW);
        }
        operators.remove(operator);
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function addNode(
        bytes32 nodeId,
        bytes calldata blsKey,
        PChainOwner calldata remainingBalanceOwner,
        PChainOwner calldata disableOwner,
        uint256 stakeAmount // optional
    ) external {
        _updateStakeCache(getCurrentEpoch(), PRIMARY_ASSET_CLASS);
        _updateGlobalNodeStakeOncePerEpoch();
        address operator = msg.sender;
        (, uint48 disabledTime) = operators.getTimes(operator);
        if (!operators.contains(operator) || disabledTime > 0) {
            revert AvalancheL1Middleware__OperatorNotRegistered(operator);
        }
        if (!_requireMinSecondaryCollateralClasses(1, operator)) {
            revert AvalancheL1Middleware__InsufficientStake();
        }

        bytes32 valId = _vid(nodeId);
        if (nodePendingRemoval[valId]) revert AvalancheL1Middleware__NodePending();
        if (balancerValidatorManager.isValidatorPendingWeightUpdate(valId)) revert AvalancheL1Middleware__NodePending();

        uint256 freeStake = _getOperatorAvailableStake(operator);

        uint256 minStake = collateralClasses[PRIMARY_ASSET_CLASS].minValidatorStake;
        uint256 maxStake = collateralClasses[PRIMARY_ASSET_CLASS].maxValidatorStake;
        uint256 newStake = (stakeAmount != 0) ? stakeAmount : minStake;

        newStake = (newStake > maxStake) ? maxStake : newStake;

        if (newStake < minStake) {
            revert AvalancheL1Middleware__InvalidStakeAmount();
        }

        if (newStake > freeStake) {
            revert AvalancheL1Middleware__InsufficientStake();
        }

        bytes32 validationID = balancerValidatorManager.initiateValidatorRegistration(
            _nodeKey(nodeId),
            blsKey,
            remainingBalanceOwner,
            disableOwner,
            StakeConversion.stakeToWeight(newStake, WEIGHT_SCALE_FACTOR)
        );

        operatorNodes[operator].add(nodeId);
        operatorNodesArray[operator].push(nodeId);
        uint48 epoch = getCurrentEpoch();

        validationIdToOperator[validationID] = operator;
        nodeStakeCache[epoch][validationID] = newStake;
        nodeStakeCache[epoch + 1][validationID] = newStake;

        emit NodeAdded(operator, nodeId, newStake, validationID);
    }

    function removeNode(
        bytes32 nodeId
    ) external {
        _updateGlobalNodeStakeOncePerEpoch();
        _onlyRegisteredOperatorNode(msg.sender, nodeId);
        _removeNode(msg.sender, nodeId);
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function forceUpdateNodes(
        address operator,
        uint256 limitStake
    )
        external
    {
        uint48 currentEpoch = getCurrentEpoch();
        _updateStakeCache(currentEpoch, PRIMARY_ASSET_CLASS);
        _onlyDuringFinalWindowOfEpoch();
        _updateGlobalNodeStakeOncePerEpoch();
        if (rebalancedThisEpoch[operator][currentEpoch]) {
            revert AvalancheL1Middleware__RebalanceNotRequired();
        }

        if (!operators.contains(operator)) {
            revert AvalancheL1Middleware__OperatorNotRegistered(operator);
        }

        uint256 newTotalStake = getOperatorStake(operator, currentEpoch, PRIMARY_ASSET_CLASS);
        
        // Enforce max security module weight cap
        (, uint64 securityModuleMaxWeight) = balancerValidatorManager.getSecurityModuleWeights(address(this));
        uint256 stakeCap = StakeConversion.weightToStake(securityModuleMaxWeight, WEIGHT_SCALE_FACTOR);
        if (newTotalStake > stakeCap) {
            newTotalStake = stakeCap;
        }
        
        uint256 registeredStake = getOperatorUsedStakeCached(operator) + operatorLockedStake[operator];
        uint256 leftoverStake;
        bool    secondaryOk     = _requireMinSecondaryCollateralClasses(0, operator);

        bytes32[] storage nodesArr = operatorNodesArray[operator];
        uint256 length = nodesArr.length;

        if (newTotalStake == registeredStake && secondaryOk) {
            return;
        }

        if (newTotalStake > registeredStake && secondaryOk) {
            leftoverStake = newTotalStake - registeredStake;
            emit OperatorHasLeftoverStake(operator, leftoverStake);
            emit AllNodeStakesUpdated(operator, newTotalStake);
            return;
        }

        leftoverStake = (newTotalStake < registeredStake)
            ? registeredStake - newTotalStake   // classic path
            : 0;                                // fix secondary only

        // The minimum stake that results in a weight change of at least 1
        uint256 minMeaningfulStake = WEIGHT_SCALE_FACTOR;

        if (leftoverStake < minMeaningfulStake && secondaryOk) {
            revert AvalancheL1Middleware__RebalanceNotRequired();
        }
        // If limitStake is provided, ensure it's at least the minimum meaningful amount
        if (limitStake > 0 && limitStake < minMeaningfulStake) {
            revert AvalancheL1Middleware__InvalidStakeAmount();
        }

        bool hasUpdatedAnyNode = false;

        for (uint256 i = length; i > 0 && (leftoverStake > 0 || !secondaryOk);) {
            i--;
            bytes32 nodeId = nodesArr[i];
            bytes32 valID = _vid(nodeId);
            if (balancerValidatorManager.isValidatorPendingWeightUpdate(valID)) {
                continue;
            }
            Validator memory validator = balancerValidatorManager.getValidator(valID);
            if (validator.status != ValidatorStatus.Active) {
                continue;
            }

            uint256 previousStake = getEffectiveNodeStake(currentEpoch, valID);

            // Remove stake
            if (previousStake == 0) {
                continue;
            }
            uint256 stakeToRemove = (leftoverStake == 0)
                ? previousStake                                   // secondary deficit: drop whole node
                : (leftoverStake < previousStake ? leftoverStake : previousStake);
            if (limitStake > 0 && stakeToRemove > limitStake) {
                stakeToRemove = limitStake;
            }

            if (stakeToRemove < minMeaningfulStake) {
                continue;
            }

            uint256 newStake = previousStake - stakeToRemove;
            uint64 oldWeight = StakeConversion.stakeToWeight(previousStake, WEIGHT_SCALE_FACTOR);
            uint64 newWeight = StakeConversion.stakeToWeight(newStake, WEIGHT_SCALE_FACTOR);

            // Skip this node if the weight wouldn't change (unless we're removing all stake)
            if (oldWeight == newWeight && newStake > 0) {
                continue;
            }

            if (leftoverStake > 0) {
                leftoverStake -= stakeToRemove;
            }


            if (newStake < collateralClasses[PRIMARY_ASSET_CLASS].minValidatorStake) {
                newStake = 0;
                _initializeEndValidationAndFlag(operator, valID, nodeId);
            } else {
                _initializeValidatorStakeUpdate(operator, valID, newStake);
                emit NodeStakeUpdated(operator, nodeId, newStake, valID);
            }

            hasUpdatedAnyNode = true;
            secondaryOk       = _requireMinSecondaryCollateralClasses(0, operator);
        }

        if (!hasUpdatedAnyNode)
            revert AvalancheL1Middleware__RebalanceNotRequired();

        if (hasUpdatedAnyNode) {
            rebalancedThisEpoch[operator][currentEpoch] = true;
        }

        emit AllNodeStakesUpdated(operator, newTotalStake);
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function initializeValidatorStakeUpdate(
        bytes32 nodeId,
        uint256 stakeAmount
    ) external {
        _updateGlobalNodeStakeOncePerEpoch();
        if (!operatorNodes[msg.sender].contains(nodeId)) {
            revert AvalancheL1Middleware__NodeNotFound(nodeId);
        }

        uint256 minStake = collateralClasses[PRIMARY_ASSET_CLASS].minValidatorStake;
        uint256 maxStake = collateralClasses[PRIMARY_ASSET_CLASS].maxValidatorStake;

        if (stakeAmount > maxStake) {
            revert AvalancheL1Middleware__InvalidStakeAmount();
        }

        if (stakeAmount < minStake) {
            revert AvalancheL1Middleware__InvalidStakeAmount();
        }

        bytes32 validationID = _vid(nodeId);
        
        // Check if operator has enough available stake for the increase
        uint48 currentEpoch = getCurrentEpoch();
        uint256 currentStake = getEffectiveNodeStake(currentEpoch, validationID);
        if (stakeAmount > currentStake) {
            uint256 delta = stakeAmount - currentStake;
            if (delta > _getOperatorAvailableStake(msg.sender)) {
                revert AvalancheL1Middleware__InsufficientStake();
            }
        }

        _initializeValidatorStakeUpdate(msg.sender, validationID, stakeAmount);
    }



    function completeValidatorRemoval(
        uint32 messageIndex
    ) external {
        _updateGlobalNodeStakeOncePerEpoch();
        _completeValidatorRemoval(messageIndex);
    }

    // --- Permissionless completes (messageIndex-only) ---

    function completeValidatorRegistration(uint32 messageIndex) external {
        _updateGlobalNodeStakeOncePerEpoch();

        bytes32 vid = balancerValidatorManager.completeValidatorRegistration(messageIndex);

        // Only act for validators owned by this module
        if (balancerValidatorManager.getValidatorSecurityModule(vid) != address(this)) {
            return;
        }
        // No local cache change needed on registration; stake was staged in addNode().
    }

    function completeStakeUpdate(uint32 messageIndex) external {
        _updateGlobalNodeStakeOncePerEpoch();

        (bytes32 vid, /*nonce*/) = balancerValidatorManager.completeValidatorWeightUpdate(messageIndex);

        // Only act for validators owned by this module
        if (balancerValidatorManager.getValidatorSecurityModule(vid) != address(this)) {
            return;
        }

        address operator = validationIdToOperator[vid];
        if (operator == address(0)) return; // not ours / unknown locally

        uint48 currentEpoch = getCurrentEpoch();
        uint256 newStake = _pendingStake[vid];

        // Cache next-epoch stake if still active and not pending removal
        Validator memory v = balancerValidatorManager.getValidator(vid);
        if (newStake != 0 && v.status == ValidatorStatus.Active && !nodePendingRemoval[vid]) {
            nodeStakeCache[currentEpoch + 1][vid] = newStake;
        }

        // Unlock delta on increases
        uint256 prevStake = getEffectiveNodeStake(currentEpoch, vid);
        if (newStake > prevStake) {
            uint256 release = newStake - prevStake;
            uint256 lockBal = operatorLockedStake[operator];
            operatorLockedStake[operator] = (release > lockBal) ? 0 : (lockBal - release);
        }

        delete _pendingStake[vid];
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function slash(
        uint48 epoch,
        address, /* operator */
        uint256, /* amount */
        uint96 collateralClassId
    ) external onlyOwner {
        _updateStakeCache(epoch, collateralClassId);
        _updateGlobalNodeStakeOncePerEpoch();
        revert AvalancheL1Middleware__NotImplemented();
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function calcAndCacheStakes(uint48 epoch, uint96 collateralClassId) public returns (uint256 totalStake) {
        if (epoch > getCurrentEpoch()) {
            revert AvalancheL1Middleware__CannotCacheFutureEpoch(epoch);
        }

        uint48 epochStartTs = getEpochStartTs(epoch);

        uint256 length = operators.length();

        for (uint256 i; i < length;) {
            (address operator, uint48 enabledTime, uint48 disabledTime) = operators.atWithTimes(i);
            if (!_wasActiveAt(enabledTime, disabledTime, epochStartTs)) {
                unchecked { ++i; }
                continue;
            }
            uint256 operatorStake = getOperatorStake(operator, epoch, collateralClassId);

            operatorStakeCache[epoch][collateralClassId][operator] = operatorStake;
            totalStake += operatorStake;
            unchecked { ++i; }
        }
        totalStakeCache[epoch][collateralClassId] = totalStake;
        totalStakeCached[epoch][collateralClassId] = true;
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */ 
    function calcAndCacheNodeStakeForAllOperators() public {
        uint48 current = getCurrentEpoch();
        if (current <= lastGlobalNodeStakeUpdateEpoch) {
            return; // Already up-to-date
        }

        uint48 epochsPending = current - lastGlobalNodeStakeUpdateEpoch;

        if (epochsPending > MAX_AUTO_EPOCH_UPDATES) {
            revert AvalancheL1Middleware__ManualEpochUpdateRequired(epochsPending);
        }

        // Process pending epochs up to MAX_AUTO_EPOCH_UPDATES

        for (uint48 i = 0; i < epochsPending;) {
            bool processed = _processSingleEpochNodeStakeCacheUpdate();
            if (!processed) break; 
            unchecked { ++i; }
        }
    }

    /**
     * @notice Processes node stake cache updates for the next pending epoch.
     * @dev Updates lastGlobalNodeStakeUpdateEpoch if an epoch is processed.
     * @return processed True if an epoch was processed, false if already up-to-date.
     */
    function _processSingleEpochNodeStakeCacheUpdate() internal returns (bool) {
        uint48 current = getCurrentEpoch();
        if (current <= lastGlobalNodeStakeUpdateEpoch) {
            return false; // Already up-to-date
        }

        uint48 epochToProcess = lastGlobalNodeStakeUpdateEpoch + 1;

        // Process this single epochToProcess
        for (uint256 i = 0; i < operators.length();) {
            (address operator,,) = operators.atWithTimes(i);
            // _calcAndCacheNodeStakeForOperatorAtEpoch itself handles carry-over from epochToProcess - 1
            _calcAndCacheNodeStakeForOperatorAtEpoch(operator, epochToProcess);
            unchecked { ++i; }
        }

        lastGlobalNodeStakeUpdateEpoch = epochToProcess;
        return true;
    }
    
    /**
     * @notice Manually processes node stake cache updates for a specified number of epochs.
     * @dev Useful if automatic updates via fail due to too many pending epochs.
     * @param numEpochsToProcess The number of pending epochs to process in this call.
     */
    function manualProcessNodeStakeCache(uint48 numEpochsToProcess) external {
        if (numEpochsToProcess == 0) {
            revert AvalancheL1Middleware__NoEpochsToProcess();
        }

        uint48 currentEpoch = getCurrentEpoch();
        uint48 epochsActuallyPending = 0;
        if (currentEpoch > lastGlobalNodeStakeUpdateEpoch) {
            epochsActuallyPending = currentEpoch - lastGlobalNodeStakeUpdateEpoch;
        }

        if (numEpochsToProcess > epochsActuallyPending) {
            // Cap processing at what's actually pending to avoid processing non-existent future states.
            if (epochsActuallyPending == 0) {
                // Effectively, nothing to do, could emit an event or just succeed.
                emit NodeStakeCacheManuallyProcessed(lastGlobalNodeStakeUpdateEpoch, 0);
                return;
            }
            numEpochsToProcess = epochsActuallyPending;
        }
        
        uint48 epochsProcessedCount = 0;
        for (uint48 i = 0; i < numEpochsToProcess;) {
            if (lastGlobalNodeStakeUpdateEpoch >= currentEpoch) {
                break; // Caught up
            }
            bool processed = _processSingleEpochNodeStakeCacheUpdate();
            if (processed) {
                unchecked { ++epochsProcessedCount; }
            } else {
                // Should not happen if currentEpoch > lastGlobalNodeStakeUpdateEpoch initially
                // and numEpochsToProcess is positive.
                break;
            }
            unchecked { ++i; }
        }

        emit NodeStakeCacheManuallyProcessed(lastGlobalNodeStakeUpdateEpoch, epochsProcessedCount);
    }
    
    /**
     * @notice Caches manager-based stake for each node of `operator` in epoch `currentEpoch`.
     * @param operator The operator address
     */
    function _calcAndCacheNodeStakeForOperatorAtEpoch(address operator, uint48 epoch) internal {
        uint48 prevEpoch = (epoch == 0) ? 0 : epoch - 1;
        bytes32[] storage nodeArray = operatorNodesArray[operator];
        for (uint256 i = nodeArray.length; i > 0;) {
            i--;
            bytes32 nodeId = nodeArray[i];
            bytes32 valID = _vid(nodeId);
            // validator already deleted on manager → use local cache
            if (valID == bytes32(0)) {
                bytes32 saved = pendingRemovalValId[nodeId];
                if (saved != bytes32(0)) {
                    _removeNodeFromArray(operator, nodeId);
                    nodePendingRemoval[saved] = false;
                    delete pendingRemovalValId[nodeId];
                }
                continue;
            }

            // If not pending removal, simply carry forward from previous epoch
            if (!nodePendingRemoval[valID]) {
                if (nodeStakeCache[epoch][valID] == 0) {
                    nodeStakeCache[epoch][valID] = nodeStakeCache[prevEpoch][valID];
                }
            } else {
                // Handle node removal if needed
                if (nodeStakeCache[epoch][valID] == 0 && nodeStakeCache[prevEpoch][valID] != 0) {
                    _removeNodeFromArray(operator, nodeId);
                    nodePendingRemoval[valID] = false;
                    delete pendingRemovalValId[nodeId];
                }
            }
        }

        // The lock is released only after completeValidatorWeightUpdate succeeds.
    }

    /**
     * @notice Remove a node => end its validator. Checks still to be done.
     * @param nodeId The node ID
     */
    function _removeNode(address operator, bytes32 nodeId) internal {
        bytes32 validationID = _vid(nodeId);
        if (balancerValidatorManager.isValidatorPendingWeightUpdate(validationID)) {
            revert AvalancheL1Middleware__NodePending();
        }
        _initializeEndValidationAndFlag(operator, validationID, nodeId);
    }

    function _initializeEndValidationAndFlag(address operator, bytes32 validationID, bytes32 nodeId) internal {
        uint48 nextEpoch = getCurrentEpoch() + 1;
        nodeStakeCache[nextEpoch][validationID] = 0;
        nodePendingRemoval[validationID] = true;
        pendingRemovalValId[nodeId] = validationID;

        balancerValidatorManager.initiateValidatorRemoval(validationID);

        emit NodeRemoved(operator, nodeId, validationID);
    }

    /**
     * @notice Remove the node from the dynamic array (swap and pop).
     * @param nodeId The node ID.
     */
    function _removeNodeFromArray(address operator, bytes32 nodeId) internal {
        bytes32[] storage nodesArr = operatorNodesArray[operator];
        // Find the node index by looping (O(n)), then swap+pop
        uint256 length = nodesArr.length;
        for (uint256 i = 0; i < length;) {
            if (nodesArr[i] == nodeId) {
                uint256 lastIndex = length - 1;
                if (i != lastIndex) {
                    nodesArr[i] = nodesArr[lastIndex];
                }
                nodesArr.pop();
                break;
            }
            unchecked { ++i; }
        }
    }



    /**
     * @notice Completes a validator's removal.
     * @param messageIndex The message index from the BalancerValidatorManager (used for ordering/verification)
     */
    function _completeValidatorRemoval(
        uint32 messageIndex
    ) internal {
        balancerValidatorManager.completeValidatorRemoval(messageIndex);
    }



    /**
     * @notice Sets the stake of a validator and updates the operator's locked stake accordingly.
     * @param operator The operator who owns the validator
     * @param validationID The unique ID of the validator whose stake is being updated
     * @param newStake The new stake for the validator
     * @dev When updating the relative weight of a validator, the operator's locked stake is increased or decreased
     */
    function _initializeValidatorStakeUpdate(address operator, bytes32 validationID, uint256 newStake) internal {
        uint48 currentEpoch = getCurrentEpoch();
        uint256 cachedStake = getEffectiveNodeStake(currentEpoch, validationID);

        if (balancerValidatorManager.isValidatorPendingWeightUpdate(validationID)) {
            revert AvalancheL1Middleware__WeightUpdatePending(validationID);
        }
        
        // Check if increase is valid and calculate delta
        if (newStake > cachedStake) {
            uint256 delta = newStake - cachedStake;
            if (delta > _getOperatorAvailableStake(operator)) {
                revert AvalancheL1Middleware__InsufficientStake();
            }
            // Lock the delta for the pending update
            operatorLockedStake[operator] += delta;
        }

        uint64 scaledWeight = StakeConversion.stakeToWeight(newStake, WEIGHT_SCALE_FACTOR);

        balancerValidatorManager.initiateValidatorWeightUpdate(validationID, scaledWeight);
        
        _pendingStake[validationID] = newStake;
    }

    function _requireMinSecondaryCollateralClasses(uint256 extraNode, address operator) internal view returns (bool) {
        uint48 epoch = getCurrentEpoch();
        
        // active nodes now excludes those already pending removal
        uint256 nodeCount = _getActiveNodeCount(operator) + extraNode;
        if (nodeCount == 0) return true;
        
        uint256 secCount = secondaryCollateralClasses.length();
        if (secCount == 0) return true;           // nothing to check
        
        for (uint256 i = 0; i < secCount;) {
            uint256 classId = secondaryCollateralClasses.at(i);
            uint256 stake   = getOperatorStake(operator, epoch, uint96(classId));
            // Check ratio vs. class's min stake, could add an emit here to debug
            if (stake / nodeCount < collateralClasses[classId].minValidatorStake) {
                return false;
            }
            unchecked { ++i; }
        }
        return true;
    }

    /**
     * @dev Returns active (non-pending-removal) node count for an operator
     * @param operator The operator address
     * @return count The number of active nodes
     */
    function _getActiveNodeCount(address operator) internal view returns (uint256 count) {
        bytes32[] storage arr = operatorNodesArray[operator];
        for (uint256 i; i < arr.length;) {
            bytes32 valID = _vid(arr[i]);
            if (!nodePendingRemoval[valID]) {
                unchecked { ++count; }
            }
            unchecked { ++i; }
        }
    }

    /**
     * @notice Checks if the classId is active
     * @param collateralClassId The asset class ID
     * @return bool True if active
     */
    function _isActiveCollateralClass(
        uint256 collateralClassId
    ) internal view returns (bool) {
        return (collateralClassId == PRIMARY_ASSET_CLASS || secondaryCollateralClasses.contains(collateralClassId));
    }

    /**
     * @notice Checks if the asset is still in use by a vault
     * @param collateralClassId The asset class ID
     * @param asset The asset address
     * @return bool True if in use by any vault
     */
    function _isUsedAsset(uint256 collateralClassId, address asset) internal view returns (bool) {
        for (uint256 i; i < vaultManager.getVaultCount();) {
            (address vault,,) = vaultManager.getVaultAtWithTimes(i);
            if (vaultManager.vaultToCollateralClass(vault) == collateralClassId && IVaultTokenized(vault).collateral() == asset) {
                return true;
            }
            unchecked { ++i; }
        }
        return false;
    }

    /**
     * @notice Checks if the asset class is still in use by a vault
     * @param collateralClassId The asset class ID
     * @return bool True if in use by any vault
     */
    function _isUsedCollateralClass(
        uint256 collateralClassId
    ) internal view returns (bool) {
        for (uint256 i; i < vaultManager.getVaultCount();) {
            (address vault,,) = vaultManager.getVaultAtWithTimes(i);
            if (vaultManager.vaultToCollateralClass(vault) == collateralClassId) {
                return true;
            }
            unchecked { ++i; }
        }
        return false;
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function getActiveCollateralClasses() external view returns (uint256 primary, uint256[] memory secondaries) {
        primary = PRIMARY_ASSET_CLASS;
        secondaries = secondaryCollateralClasses.values();
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function getEpochStartTs(
        uint48 epoch
    ) public view returns (uint48 timestamp) {
        return START_TIME + epoch * EPOCH_DURATION;
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function getEpochAtTs(
        uint48 timestamp
    ) public view returns (uint48 epoch) {
        return (timestamp - START_TIME) / EPOCH_DURATION;
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function getCurrentEpoch() public view returns (uint48 epoch) {
        return getEpochAtTs(Time.timestamp());
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function getOperatorStake(
        address operator,
        uint48 epoch,
        uint96 collateralClassId
    ) public view returns (uint256 stake) {
        if (totalStakeCached[epoch][collateralClassId]) {
            uint256 cachedStake = operatorStakeCache[epoch][collateralClassId][operator];

            return cachedStake;
        }

        uint48 epochStartTs = getEpochStartTs(epoch);

        uint256 totalVaults = vaultManager.getVaultCount();

        for (uint256 i; i < totalVaults;) {
            (address vault, uint48 enabledTime, uint48 disabledTime) = vaultManager.getVaultAtWithTimes(i);

            // Skip if vault not active in the target epoch
            if (!_wasActiveAt(enabledTime, disabledTime, epochStartTs)) {
                unchecked { ++i; }
                continue;
            }

            // Skip if vault asset not in CollateralClassID
            if (vaultManager.getVaultCollateralClass(vault) != collateralClassId) {
                unchecked { ++i; }
                continue;
            }

            uint256 vaultStake = BaseDelegator(IVaultTokenized(vault).delegator()).stakeAt(
                BALANCER, collateralClassId, operator, epochStartTs, new bytes(0)
            );

            address collateral = IVaultTokenized(vault).collateral();
            uint8 dec = IERC20Metadata(collateral).decimals();

            if (dec < 18) {
                vaultStake *= 10 ** uint256(18 - dec);
            } else if (dec > 18) {
                vaultStake /= 10 ** uint256(dec - 18);
            }

            stake += vaultStake;
            unchecked { ++i; }
        }
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function getTotalStake(uint48 epoch, uint96 collateralClassId) public view returns (uint256) {
        if (totalStakeCached[epoch][collateralClassId]) {
            return totalStakeCache[epoch][collateralClassId];
        }
        return _calcTotalStake(epoch, collateralClassId);
    }

    function getOperatorNodesLength(
        address operator
    ) public view returns (uint256) {
        return operatorNodesArray[operator].length;
    }



    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function getAllOperators() external view returns (address[] memory) {
        uint256 length = operators.length();
        address[] memory result = new address[](length);
        for (uint256 i; i < length; i++) {
            (address operator,,) = operators.atWithTimes(i);
            result[i] = operator;
        }
        return result;
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function getNodeStake(uint48 epoch, bytes32 validationID) external view returns (uint256) {
        return nodeStakeCache[epoch][validationID];
    }

    function isActiveCollateralClass(
        uint96 collateralClassId
    ) external view returns (bool) {
        return _isActiveCollateralClass(collateralClassId);
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function getActiveNodesForEpoch(
        address operator,
        uint48 epoch
    ) external view returns (bytes32[] memory activeNodeIds) {
        uint48 epochStartTs = getEpochStartTs(epoch);

        // Gather all nodes from the never-removed set
        bytes32[] memory allNodeIds = operatorNodes[operator].values();

        bytes32[] memory temp = new bytes32[](allNodeIds.length);
        uint256 activeCount;

        for (uint256 i = 0; i < allNodeIds.length; i++) {
            bytes32 nodeId = allNodeIds[i];
            bytes32 validationID = _vid(nodeId);
            Validator memory validator = balancerValidatorManager.getValidator(validationID);

            // Skip if no validator is registered for this nodeId
            if (validationID == bytes32(0) || validationIdToOperator[validationID] != operator) {
                continue;
            }

            if (_wasActiveAt(uint48(validator.startTime), uint48(validator.endTime), epochStartTs)) {
                temp[activeCount++] = nodeId;
            }
        }

        activeNodeIds = new bytes32[](activeCount);
        for (uint256 j = 0; j < activeCount; j++) {
            activeNodeIds[j] = temp[j];
        }
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function getOperatorAvailableStake(
        address operator
    ) external view returns (uint256) {
        return _getOperatorAvailableStake(operator);
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function getVaultManager() external view returns (address) {
        return address(vaultManager);
    }



    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function getOperatorUsedStakeCached(
        address operator
    ) public view returns (uint256 registeredStake) {
        bytes32[] storage nodesArr = operatorNodesArray[operator];
        for (uint256 i = 0; i < nodesArr.length;) {
            bytes32 nodeId = nodesArr[i];
            bytes32 validationID = _vid(nodeId);
            registeredStake += getEffectiveNodeStake(getCurrentEpoch(), validationID);
            unchecked { ++i; }
        }
    }

    /**
     * @notice  Gets the effective stake for a specific ValidationID.
     * @param epoch The epoch number
     * @param validationID The validation ID
     */
    function getEffectiveNodeStake(uint48 epoch, bytes32 validationID) internal view returns (uint256) {
        return nodeStakeCache[epoch][validationID];
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function getOperatorUsedStakeCachedPerEpoch(
        uint48 epoch,
        address operator,
        uint96 collateralClass
    ) external view returns (uint256) {
        if (collateralClass == PRIMARY_ASSET_CLASS) {
            bytes32[] memory nodesArr = this.getActiveNodesForEpoch(operator, epoch);
            uint256 operatorStake = 0;

            for (uint256 i = 0; i < nodesArr.length; i++) {
                bytes32 nodeId = nodesArr[i];
                bytes32 validationID = _vid(nodeId);
                operatorStake += getEffectiveNodeStake(epoch, validationID);
            }
            return operatorStake;
        } else {
            return getOperatorStake(operator, epoch, collateralClass);
        }
    }

    /**
     * @notice Get the validator per ValidationID.
     * @param validationID The validation ID.
     */
    function _getValidator(
        bytes32 validationID
    ) internal view returns (Validator memory) {
        return balancerValidatorManager.getValidator(validationID);
    }

    /**
     * @notice Returns the available stake for an operator
     * @param operator The operator address
     * @return The available stake
     */
    function _getOperatorAvailableStake(
        address operator
    ) internal view returns (uint256) {
        uint48 epoch = getCurrentEpoch();
        uint256 totalStake = getOperatorStake(operator, epoch, PRIMARY_ASSET_CLASS);

        // Enforce max security module weight
        (, uint64 securityModuleMaxWeight) = balancerValidatorManager.getSecurityModuleWeights(address(this));
        uint256 convertedSecurityModuleMaxWeight =
            StakeConversion.weightToStake(securityModuleMaxWeight, WEIGHT_SCALE_FACTOR);
        if (totalStake > convertedSecurityModuleMaxWeight) {
            totalStake = convertedSecurityModuleMaxWeight;
        }

        uint256 lockedStake = operatorLockedStake[operator];
        uint256 usedStake = getOperatorUsedStakeCached(operator);
        
        if (totalStake <= lockedStake + usedStake) {
            return 0;
        }
        return totalStake - lockedStake - usedStake;
    }

    /**
     * @notice Helper to calculate total stake for an epoch
     * @param epoch The epoch number
     * @param collateralClassId The asset class ID
     * @return totalStake The total stake across all operators
     */
    function _calcTotalStake(uint48 epoch, uint96 collateralClassId) private view returns (uint256 totalStake) {
        uint48 epochStartTs = getEpochStartTs(epoch);

        // for epoch older than SLASHING_WINDOW total stake can be invalidated (use cache)
        if (epochStartTs > Time.timestamp() || epochStartTs < Time.timestamp() - SLASHING_WINDOW) {
            revert AvalancheL1Middleware__EpochError(epochStartTs);
        }

        uint256 length = operators.length();

        for (uint256 i; i < length;) {
            (address operator, uint48 enabledTime, uint48 disabledTime) = operators.atWithTimes(i);
            // just skip operator if it was added after the target epoch or paused
            if (!_wasActiveAt(enabledTime, disabledTime, epochStartTs)) {
                unchecked { ++i; }
                continue;
            }
            uint256 operatorStake = getOperatorStake(operator, epoch, collateralClassId);
            totalStake += operatorStake;
            unchecked { ++i; }
        }
    }

    /**
     * @notice Checks if an operator or vault was active at a specific timestamp
     * @param enabledTime The time it was enabled
     * @param disabledTime The time it was disabled
     * @param timestamp The timestamp to check
     * @return bool True if active
     */
    function _wasActiveAt(uint48 enabledTime, uint48 disabledTime, uint48 timestamp) private pure returns (bool) {
        return enabledTime != 0 && enabledTime <= timestamp && (disabledTime == 0 || disabledTime > timestamp);
    }

    function _nodeKey(bytes32 nodeId) private pure returns (bytes memory) {
        return abi.encodePacked(uint160(uint256(nodeId)));
    }

    function _vid(bytes32 nodeId) private view returns (bytes32) {
        return balancerValidatorManager.getNodeValidationID(_nodeKey(nodeId));
    }
}
