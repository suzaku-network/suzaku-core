// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {
    Validator,
    ValidatorStatus,
    ValidatorRegistrationInput,
    PChainOwner
} from "@avalabs/teleporter/validator-manager/interfaces/IValidatorManager.sol";
import {BalancerValidatorManager} from
    "@suzaku/contracts-library/contracts/ValidatorManager/BalancerValidatorManager.sol";

import {IOperatorRegistry} from "../../interfaces/IOperatorRegistry.sol";
import {IVaultTokenized} from "../../interfaces/vault/IVaultTokenized.sol";
import {IAvalancheL1Middleware} from "../../interfaces/middleware/IAvalancheL1Middleware.sol";
import {IOptInService} from "../../interfaces/service/IOptInService.sol";

import {AssetClassRegistry} from "./AssetClassRegistry.sol";
import {MiddlewareVaultManager} from "./MiddlewareVaultManager.sol";
import {MapWithTimeData} from "./libraries/MapWithTimeData.sol";
import {StakeConversion} from "./libraries/StakeConversion.sol";
import {BaseDelegator} from "../../contracts/delegator/BaseDelegator.sol";

struct AvalancheL1MiddlewareSettings {
    address l1ValidatorManager;
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
contract AvalancheL1Middleware is IAvalancheL1Middleware, AssetClassRegistry {
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    using EnumerableSet for EnumerableSet.UintSet;
    using MapWithTimeData for EnumerableMap.AddressToUintMap;
    using EnumerableMap for EnumerableMap.Bytes32ToUintMap;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    address public immutable L1_VALIDATOR_MANAGER;
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
    MiddlewareVaultManager private vaultManager;
    EnumerableMap.AddressToUintMap private operators;
    EnumerableSet.UintSet private secondaryAssetClasses;
    bool private vaultManagerSet;

    BalancerValidatorManager public balancerValidatorManager;

    mapping(address => mapping(uint48 => bool)) public rebalancedThisEpoch;
    mapping(uint48 => mapping(uint96 => uint256)) public totalStakeCache;
    mapping(address => bytes32[]) public operatorNodesArray;
    mapping(uint48 => mapping(uint96 => mapping(address => uint256))) public operatorStakeCache;
    mapping(uint48 => mapping(bytes32 => uint256)) public nodeStakeCache;
    mapping(bytes32 => bool) public nodePendingUpdate;
    mapping(bytes32 => bool) public nodePendingRemoval;
    mapping(address => uint256) public operatorLockedStake;
    mapping(uint48 => mapping(uint96 => bool)) public totalStakeCached;
    mapping(bytes32 => address) public validationIdToOperator;
    // operatorNodesArray[operator] is used for iteration during certain
    // rebalancing or node-update operations, and has nodes removed once
    // they are effectively retired. This means a node can remain in
    // operatorNodes while it is removed from operatorNodesArray.
    // operatorNodes[operator] is intended as a permanent record of all nodes
    // ever registered by the operator, used for historical/epoch-based queries.
    // We do *not* remove nodes from this set when they are "retired" so
    // getActiveNodesForEpoch(...) can still detect them for past epochs.
    mapping(address => EnumerableSet.Bytes32Set) private operatorNodes;

    /**
     * @notice Initializes contract settings
     * @param settings General contract parameters
     * @param owner Owner address
     * @param primaryAsset The primary asset address
     * @param primaryAssetMaxStake Max stake for the primary asset class
     * @param primaryAssetMinStake Min stake for the primary asset class
     */
    constructor(
        AvalancheL1MiddlewareSettings memory settings,
        address owner,
        address primaryAsset,
        uint256 primaryAssetMaxStake,
        uint256 primaryAssetMinStake,
        uint256 primaryAssetWeightScaleFactor
    ) AssetClassRegistry(owner) {
        if (settings.l1ValidatorManager == address(0)) {
            revert AvalancheL1Middleware__ZeroAddress("l1ValidatorManager");
        }
        if (settings.operatorRegistry == address(0)) {
            revert AvalancheL1Middleware__ZeroAddress("operatorRegistry");
        }
        if (settings.vaultRegistry == address(0)) {
            revert AvalancheL1Middleware__ZeroAddress("vaultRegistry");
        }
        if (settings.operatorL1Optin == address(0)) {
            revert AvalancheL1Middleware__ZeroAddress("operatorL1Optin");
        }
        if (owner == address(0)) {
            revert AvalancheL1Middleware__ZeroAddress("owner");
        }
        if (primaryAsset == address(0)) {
            revert AvalancheL1Middleware__ZeroAddress("primaryAsset");
        }
        if (settings.slashingWindow < settings.epochDuration) {
            revert AvalancheL1Middleware__SlashingWindowTooShort(settings.slashingWindow, settings.epochDuration);
        }
        if (primaryAssetWeightScaleFactor == 0) {
            revert AvalancheL1Middleware__InvalidScaleFactor();
        }

        START_TIME = Time.timestamp();
        EPOCH_DURATION = settings.epochDuration;
        L1_VALIDATOR_MANAGER = settings.l1ValidatorManager;
        OPERATOR_REGISTRY = settings.operatorRegistry;
        OPERATOR_L1_OPTIN = settings.operatorL1Optin;
        SLASHING_WINDOW = settings.slashingWindow;
        PRIMARY_ASSET = primaryAsset;
        UPDATE_WINDOW = settings.stakeUpdateWindow;
        WEIGHT_SCALE_FACTOR = primaryAssetWeightScaleFactor;

        balancerValidatorManager = BalancerValidatorManager(settings.l1ValidatorManager);
        _addAssetClass(PRIMARY_ASSET_CLASS, primaryAssetMinStake, primaryAssetMaxStake, PRIMARY_ASSET);
    }

    /**
     * @notice Updates stake cache before function execution
     * @param epoch The epoch to update
     * @param assetClassId The asset class ID
     */
    modifier updateStakeCache(uint48 epoch, uint96 assetClassId) {
        if (!totalStakeCached[epoch][assetClassId]) {
            calcAndCacheStakes(epoch, assetClassId);
        }
        _;
    }

    /**
     * @notice Window where a node update can be done manually, before the force update can be applied
     */
    modifier onlyDuringFinalWindowOfEpoch() {
        uint48 currentEpoch = getCurrentEpoch();
        uint48 epochStartTs = getEpochStartTs(currentEpoch);
        uint48 timeNow = Time.timestamp();
        uint48 epochUpdatePeriod = epochStartTs + UPDATE_WINDOW;

        if (timeNow < epochUpdatePeriod || timeNow > epochStartTs + EPOCH_DURATION) {
            revert AvalancheL1Middleware__NotEpochUpdatePeriod(timeNow, epochUpdatePeriod);
        }
        _;
    }

    modifier onlyRegisteredOperatorNode(address operator, bytes32 nodeId) {
        if (!operators.contains(operator)) {
            revert AvalancheL1Middleware__OperatorNotRegistered(operator);
        }
        if (!operatorNodes[operator].contains(nodeId)) {
            revert AvalancheL1Middleware__NodeNotFound(nodeId);
        }
        _;
    }

    modifier updateGlobalNodeStakeOncePerEpoch() {
        uint48 current = getCurrentEpoch();
        if (current > lastGlobalNodeStakeUpdateEpoch) {
            calcAndCacheNodeStakeForAllOperators();
            lastGlobalNodeStakeUpdateEpoch = current;
        }
        _;
    }

    function setVaultManager(
        address vaultManager_
    ) external onlyOwner {
        if (vaultManagerSet) {
            revert AvalancheL1Middleware__VaultManagerAlreadySet(address(vaultManager));
        }
        if (vaultManager_ == address(0)) {
            revert AvalancheL1Middleware__ZeroAddress("vaultManager");
        }
        vaultManagerSet = true;
        emit VaultManagerUpdated(address(vaultManager), vaultManager_);
        vaultManager = MiddlewareVaultManager(vaultManager_);
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function activateSecondaryAssetClass(
        uint256 assetClassId
    ) external onlyOwner updateGlobalNodeStakeOncePerEpoch {
        if (!assetClassIds.contains(assetClassId)) {
            revert AssetClassRegistry__AssetClassNotFound();
        }
        if (assetClassId == PRIMARY_ASSET_CLASS) {
            revert AssetClassRegistry__AssetClassAlreadyExists();
        }
        bool added = secondaryAssetClasses.add(assetClassId);
        if (!added) {
            revert AssetClassRegistry__AssetClassAlreadyExists();
        }
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function deactivateSecondaryAssetClass(
        uint256 assetClassId
    ) external onlyOwner updateGlobalNodeStakeOncePerEpoch {
        if (_isUsedAssetClass(assetClassId)) {
            revert AvalancheL1Middleware__AssetStillInUse(assetClassId);
        }
        bool removed = secondaryAssetClasses.remove(assetClassId);
        if (!removed) {
            revert AssetClassRegistry__AssetClassNotFound();
        }
    }

    /**
     * @notice Removes an asset from an asset class, except primary asset
     * @param assetClassId The ID of the asset class
     * @param asset The address of the asset to remove
     */
    function removeAssetFromClass(
        uint256 assetClassId,
        address asset
    ) public override onlyOwner updateGlobalNodeStakeOncePerEpoch {
        if (assetClassId == 1 && asset == PRIMARY_ASSET) {
            revert AssetClassRegistry__AssetIsPrimaryAssetClass(assetClassId);
        }

        if (_isUsedAsset(assetClassId, asset)) {
            revert AvalancheL1Middleware__AssetStillInUse(assetClassId);
        }

        super.removeAssetFromClass(assetClassId, asset);
    }

    /**
     * @notice Removes an asset class
     * @param assetClassId The asset class ID
     */
    function removeAssetClass(
        uint256 assetClassId
    ) public override updateGlobalNodeStakeOncePerEpoch {
        if (secondaryAssetClasses.contains(assetClassId)) {
            revert AvalancheL1Middleware__ActiveSecondaryAssetCLass(assetClassId);
        }

        super.removeAssetClass(assetClassId);
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function registerOperator(
        address operator
    ) external onlyOwner updateGlobalNodeStakeOncePerEpoch {
        if (operators.contains(operator)) {
            revert AvalancheL1Middleware__OperatorAlreadyRegistered(operator);
        }
        if (!IOperatorRegistry(OPERATOR_REGISTRY).isRegistered(operator)) {
            revert AvalancheL1Middleware__OperatorNotRegistered(operator);
        }
        if (!IOptInService(OPERATOR_L1_OPTIN).isOptedIn(operator, L1_VALIDATOR_MANAGER)) {
            revert AvalancheL1Middleware__OperatorNotOptedIn(operator, L1_VALIDATOR_MANAGER);
        }

        operators.add(operator);
        operators.enable(operator);
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function disableOperator(
        address operator
    ) external onlyOwner updateGlobalNodeStakeOncePerEpoch {
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
    ) external onlyOwner updateGlobalNodeStakeOncePerEpoch {
        operators.enable(operator);
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function removeOperator(
        address operator
    ) external onlyOwner updateGlobalNodeStakeOncePerEpoch {
        if (operatorNodesArray[operator].length > 0) {
            revert AvalancheL1Middleware__OperatorHasActiveNodes(operator, operatorNodesArray[operator].length);
        }
        (, uint48 disabledTime) = operators.getTimes(operator);
        if (disabledTime == 0 || disabledTime + SLASHING_WINDOW > Time.timestamp()) {
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
        uint64 registrationExpiry,
        PChainOwner calldata remainingBalanceOwner,
        PChainOwner calldata disableOwner,
        uint256 stakeAmount // optional
    ) external updateStakeCache(getCurrentEpoch(), PRIMARY_ASSET_CLASS) updateGlobalNodeStakeOncePerEpoch {
        address operator = msg.sender;
        if (!operators.contains(operator)) {
            revert AvalancheL1Middleware__OperatorNotRegistered(operator);
        }
        if (!_requireMinSecondaryAssetClasses(1, operator)) {
            revert AvalancheL1Middleware__NotEnoughFreeStakeSecondaryAssetClasses();
        }

        bytes32 valId = balancerValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId))));
        uint256 available = _getOperatorAvailableStake(operator);
        if (nodePendingRemoval[valId]) revert AvalancheL1Middleware__NodePendingRemoval(nodeId);
        if (nodePendingUpdate[valId]) revert AvalancheL1Middleware__NodePendingUpdate(nodeId);

        uint256 minStake = assetClasses[PRIMARY_ASSET_CLASS].minValidatorStake;
        uint256 maxStake = assetClasses[PRIMARY_ASSET_CLASS].maxValidatorStake;
        uint256 newStake = (stakeAmount != 0) ? stakeAmount : available;

        newStake = (newStake > maxStake) ? maxStake : newStake;

        if (newStake < minStake || newStake > available) {
            revert AvalancheL1Middleware__NotEnoughFreeStake(newStake);
        }

        ValidatorRegistrationInput memory input = ValidatorRegistrationInput({
            nodeID: abi.encodePacked(uint160(uint256(nodeId))),
            blsPublicKey: blsKey,
            registrationExpiry: registrationExpiry,
            remainingBalanceOwner: remainingBalanceOwner,
            disableOwner: disableOwner
        });

        // Track node in our time-based map and dynamic array.
        operatorNodes[operator].add(nodeId);
        operatorNodesArray[operator].push(nodeId);
        uint48 epoch = getCurrentEpoch();

        bytes32 validationID = balancerValidatorManager.initializeValidatorRegistration(
            input, StakeConversion.stakeToWeight(newStake, WEIGHT_SCALE_FACTOR)
        );

        validationIdToOperator[validationID] = operator;
        nodeStakeCache[epoch][validationID] = newStake;
        nodeStakeCache[epoch + 1][validationID] = newStake;
        nodePendingUpdate[validationID] = true;

        emit NodeAdded(operator, nodeId, newStake, validationID);
    }

    function removeNode(
        bytes32 nodeId
    ) external updateGlobalNodeStakeOncePerEpoch onlyRegisteredOperatorNode(msg.sender, nodeId) {
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
        updateStakeCache(getCurrentEpoch(), PRIMARY_ASSET_CLASS)
        onlyDuringFinalWindowOfEpoch
        updateGlobalNodeStakeOncePerEpoch
    {
        uint48 currentEpoch = getCurrentEpoch();
        if (rebalancedThisEpoch[operator][currentEpoch]) {
            revert AvalancheL1Middleware__AlreadyRebalanced(operator, currentEpoch);
        }

        if (!operators.contains(operator)) {
            revert AvalancheL1Middleware__OperatorNotRegistered(operator);
        }

        // Calculate the new total stake for the operator and compare it to the registered stake
        uint256 newTotalStake = _getOperatorAvailableStake(operator);
        uint256 registeredStake = getOperatorUsedStakeCached(operator);
        uint256 leftoverStake;

        bytes32[] storage nodesArr = operatorNodesArray[operator];
        uint256 length = nodesArr.length;

        // If nothing changed, do nothing
        if (newTotalStake == registeredStake) {
            return;
        }

        if (newTotalStake > registeredStake) {
            leftoverStake = newTotalStake - registeredStake;
            emit OperatorHasLeftoverStake(operator, leftoverStake);
            emit AllNodeStakesUpdated(operator, newTotalStake);
            return;
        }
        // We only handle the scenario newTotalStake < registeredStake, when removing stake
        leftoverStake = registeredStake - newTotalStake;

        // The minimum stake that results in a weight change of at least 1
        uint256 minMeaningfulStake = WEIGHT_SCALE_FACTOR;

        if (leftoverStake < minMeaningfulStake) {
            emit AllNodeStakesUpdated(operator, newTotalStake);
            return;
        }
        // If limitStake is provided, ensure it's at least the minimum meaningful amount
        if (limitStake > 0 && limitStake < minMeaningfulStake) {
            revert AvalancheL1Middleware__LimitStakeTooLow(limitStake, minMeaningfulStake);
        }

        bool hasUpdatedAnyNode = false;

        for (uint256 i = length; i > 0 && leftoverStake > 0;) {
            i--;
            bytes32 nodeId = nodesArr[i];
            bytes32 valID = balancerValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId))));
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
            uint256 stakeToRemove = leftoverStake < previousStake ? leftoverStake : previousStake;
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

            leftoverStake -= stakeToRemove;
            hasUpdatedAnyNode = true;


            if (
                (newStake < assetClasses[PRIMARY_ASSET_CLASS].minValidatorStake)
                    || !_requireMinSecondaryAssetClasses(0, operator)
            ) {
                newStake = 0;
                _initializeEndValidationAndFlag(operator, valID, nodeId);
            } else {
                _initializeValidatorStakeUpdate(operator, valID, newStake);
                emit NodeStakeUpdated(operator, nodeId, newStake, valID);
            }
        }

        if (!hasUpdatedAnyNode && leftoverStake >= minMeaningfulStake) {
            revert AvalancheL1Middleware__NoMeaningfulUpdatesAvailable(operator, leftoverStake);
        }

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
    ) external updateGlobalNodeStakeOncePerEpoch {
        if (!operatorNodes[msg.sender].contains(nodeId)) {
            revert AvalancheL1Middleware__NodeNotFound(nodeId);
        }

        uint256 minStake = assetClasses[PRIMARY_ASSET_CLASS].minValidatorStake;
        uint256 maxStake = assetClasses[PRIMARY_ASSET_CLASS].maxValidatorStake;

        if (stakeAmount > maxStake) {
            revert AvalancheL1Middleware__StakeTooHigh(stakeAmount, maxStake);
        }

        if (stakeAmount < minStake) {
            revert AvalancheL1Middleware__StakeTooLow(stakeAmount, minStake);
        }

        bytes32 validationID = balancerValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId))));

        _initializeValidatorStakeUpdate(msg.sender, validationID, stakeAmount);
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function completeValidatorRegistration(
        address operator,
        bytes32 nodeId,
        uint32 messageIndex
    ) external updateGlobalNodeStakeOncePerEpoch {
        _completeValidatorRegistration(operator, nodeId, messageIndex);
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function completeStakeUpdate(
        bytes32 nodeId,
        uint32 messageIndex
    ) external onlyRegisteredOperatorNode(msg.sender, nodeId) updateGlobalNodeStakeOncePerEpoch {
        _completeStakeUpdate(msg.sender, nodeId, messageIndex);
    }

    function completeValidatorRemoval(
        uint32 messageIndex
    ) external updateGlobalNodeStakeOncePerEpoch {
        _completeValidatorRemoval(messageIndex);
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function slash(
        uint48 epoch,
        address, /* operator */
        uint256, /* amount */
        uint96 assetClassId
    ) public onlyOwner updateStakeCache(epoch, assetClassId) updateGlobalNodeStakeOncePerEpoch {
        revert AvalancheL1Middleware__NotImplemented();
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function calcAndCacheStakes(uint48 epoch, uint96 assetClassId) public returns (uint256 totalStake) {
        if (epoch > getCurrentEpoch()) {
            revert AvalancheL1Middleware__CannotCacheFutureEpoch(epoch);
        }

        uint48 epochStartTs = getEpochStartTs(epoch);

        uint256 length = operators.length();

        for (uint256 i; i < length; ++i) {
            (address operator, uint48 enabledTime, uint48 disabledTime) = operators.atWithTimes(i);
            if (!_wasActiveAt(enabledTime, disabledTime, epochStartTs)) {
                continue;
            }
            uint256 operatorStake = getOperatorStake(operator, epoch, assetClassId);

            operatorStakeCache[epoch][assetClassId][operator] = operatorStake;
            totalStake += operatorStake;
        }
        totalStakeCache[epoch][assetClassId] = totalStake;
        totalStakeCached[epoch][assetClassId] = true;
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
            revert AvalancheL1Middleware__ManualEpochUpdateRequired(epochsPending, MAX_AUTO_EPOCH_UPDATES);
        }

        // Process pending epochs up to MAX_AUTO_EPOCH_UPDATES

        for (uint48 i = 0; i < epochsPending; i++) {
            bool processed = _processSingleEpochNodeStakeCacheUpdate();
            if (!processed) break; 
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
        for (uint256 i = 0; i < operators.length(); i++) {
            (address operator,,) = operators.atWithTimes(i);
            // _calcAndCacheNodeStakeForOperatorAtEpoch itself handles carry-over from epochToProcess - 1
            _calcAndCacheNodeStakeForOperatorAtEpoch(operator, epochToProcess);
        }

        lastGlobalNodeStakeUpdateEpoch = epochToProcess;
        return true;
    }
    
    /**
     * @notice Manually processes node stake cache updates for a specified number of epochs.
     * @dev Useful if automatic updates via modifier fail due to too many pending epochs.
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
        for (uint48 i = 0; i < numEpochsToProcess; i++) {
            if (lastGlobalNodeStakeUpdateEpoch >= currentEpoch) {
                break; // Caught up
            }
            bool processed = _processSingleEpochNodeStakeCacheUpdate();
            if (processed) {
                epochsProcessedCount++;
            } else {
                // Should not happen if currentEpoch > lastGlobalNodeStakeUpdateEpoch initially
                // and numEpochsToProcess is positive.
                break;
            }
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
            bytes32 valID = balancerValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId))));

            // If no removal/update, just carry over from prevEpoch (only if we haven't set it yet)
            if (!nodePendingRemoval[valID] && !nodePendingUpdate[valID]) {
                if (nodeStakeCache[epoch][valID] == 0) {
                    nodeStakeCache[epoch][valID] = nodeStakeCache[prevEpoch][valID];
                }
                continue;
            }

            if (nodePendingRemoval[valID] && nodeStakeCache[epoch][valID] == 0 && nodeStakeCache[prevEpoch][valID] != 0)
            {
                _removeNodeFromArray(operator, nodeId);
                nodePendingRemoval[valID] = false;
            }

            // If there was a pending update, finalize and clear the pending markers
            if (nodePendingUpdate[valID]) {
                nodePendingUpdate[valID] = false;
            }
        }

        // Reset operator locked stake once per epoch
        if (operatorLockedStake[operator] > 0) {
            operatorLockedStake[operator] = 0;
        }
    }

    /**
     * @notice Remove a node => end its validator. Checks still to be done.
     * @param nodeId The node ID
     */
    function _removeNode(address operator, bytes32 nodeId) internal {
        bytes32 validationID = balancerValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId))));
        _initializeEndValidationAndFlag(operator, validationID, nodeId);
    }

    function _initializeEndValidationAndFlag(address operator, bytes32 validationID, bytes32 nodeId) internal {
        uint48 nextEpoch = getCurrentEpoch() + 1;
        nodeStakeCache[nextEpoch][validationID] = 0;
        nodePendingRemoval[validationID] = true;

        balancerValidatorManager.initializeEndValidation(validationID);

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
        for (uint256 i = 0; i < length; i++) {
            if (nodesArr[i] == nodeId) {
                uint256 lastIndex = length - 1;
                if (i != lastIndex) {
                    nodesArr[i] = nodesArr[lastIndex];
                }
                nodesArr.pop();
                break;
            }
        }
    }

    /**
     * @notice Completes a validator's registration.
     * @param operator The operator who owns the validator
     * @param nodeId The unique ID of the validator whose registration is being finalized
     * @param messageIndex The message index from the BalancerValidatorManager (used for ordering/verification)
     */
    function _completeValidatorRegistration(
        address operator,
        bytes32 nodeId,
        uint32 messageIndex
    ) internal onlyRegisteredOperatorNode(operator, nodeId) {
        balancerValidatorManager.completeValidatorRegistration(messageIndex);
    }

    /**
     * @notice Completes a validator's removal.
     * @param messageIndex The message index from the BalancerValidatorManager (used for ordering/verification)
     */
    function _completeValidatorRemoval(
        uint32 messageIndex
    ) internal {
        balancerValidatorManager.completeEndValidation(messageIndex);
    }

    /**
     * @notice Completes a validator's stake update
     * @param operator The operator who owns the validator
     * @param nodeId The unique ID of the validator whose relative weight update is being finalized
     * @param messageIndex The message index from the BalancerValidatorManager (used for ordering/verification)
     */
    function _completeStakeUpdate(
        address operator,
        bytes32 nodeId,
        uint32 messageIndex
    ) internal onlyRegisteredOperatorNode(operator, nodeId) {
        bytes32 validationID = balancerValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId))));

        if (!balancerValidatorManager.isValidatorPendingWeightUpdate(validationID)) {
            revert AvalancheL1Middleware__WeightUpdateNotPending(validationID);
        }
        // if the completeValidatorWeightUpdate fails, not sure if the previous bool is secure.
        balancerValidatorManager.completeValidatorWeightUpdate(validationID, messageIndex);
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
        uint256 delta;
        if (newStake > cachedStake) {
            delta = newStake - cachedStake;
            if (delta > _getOperatorAvailableStake(operator)) {
                revert AvalancheL1Middleware__NotEnoughFreeStake(newStake);
            }
        }
        operatorLockedStake[operator] += delta;
        nodePendingUpdate[validationID] = true;
        nodeStakeCache[currentEpoch + 1][validationID] = newStake;
        // if newStake < cachedStake, no lock should happen, it's locked in the cache

        uint64 scaledWeight = StakeConversion.stakeToWeight(newStake, WEIGHT_SCALE_FACTOR);

        balancerValidatorManager.initializeValidatorWeightUpdate(validationID, scaledWeight);
    }

    function _requireMinSecondaryAssetClasses(uint256 extraNode, address operator) internal returns (bool) {
        uint48 epoch = getCurrentEpoch();
        
        // active nodes now excludes those already pending removal
        uint256 nodeCount = _getActiveNodeCount(operator) + extraNode;
        if (nodeCount == 0) return false;         // no active nodes ⇒ fail fast
        
        uint256 secCount = secondaryAssetClasses.length();
        if (secCount == 0) return true;           // nothing to check
        
        for (uint256 i = 0; i < secCount; ++i) {
            uint256 classId = secondaryAssetClasses.at(i);
            uint256 stake   = getOperatorStake(operator, epoch, uint96(classId));
            // Check ratio vs. class's min stake, could add an emit here to debug
            if (stake / nodeCount < assetClasses[classId].minValidatorStake) {
                emit DebugSecondaryAssetClassCheck(operator, classId, stake, nodeCount, assetClasses[classId].minValidatorStake);
                return false;
            }
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
        for (uint256 i; i < arr.length; ++i) {
            bytes32 valID = balancerValidatorManager.registeredValidators(
                abi.encodePacked(uint160(uint256(arr[i])))
            );
            if (!nodePendingRemoval[valID]) {
                unchecked { ++count; }
            }
        }
    }

    /**
     * @notice Checks if the classId is active
     * @param assetClassId The asset class ID
     * @return bool True if active
     */
    function _isActiveAssetClass(
        uint256 assetClassId
    ) internal view returns (bool) {
        return (assetClassId == PRIMARY_ASSET_CLASS || secondaryAssetClasses.contains(assetClassId));
    }

    /**
     * @notice Checks if the asset is still in use by a vault
     * @param assetClassId The asset class ID
     * @param asset The asset address
     * @return bool True if in use by any vault
     */
    function _isUsedAsset(uint256 assetClassId, address asset) internal view returns (bool) {
        for (uint256 i; i < vaultManager.getVaultCount(); ++i) {
            (address vault,,) = vaultManager.getVaultAtWithTimes(i);
            if (vaultManager.vaultToAssetClass(vault) == assetClassId && IVaultTokenized(vault).collateral() == asset) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Checks if the asset class is still in use by a vault
     * @param assetClassId The asset class ID
     * @return bool True if in use by any vault
     */
    function _isUsedAssetClass(
        uint256 assetClassId
    ) internal view returns (bool) {
        for (uint256 i; i < vaultManager.getVaultCount(); ++i) {
            (address vault,,) = vaultManager.getVaultAtWithTimes(i);
            if (vaultManager.vaultToAssetClass(vault) == assetClassId) {
                return true;
            }
        }
        return false;
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function getActiveAssetClasses() external view returns (uint256 primary, uint256[] memory secondaries) {
        primary = PRIMARY_ASSET_CLASS;
        secondaries = secondaryAssetClasses.values();
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
        uint96 assetClassId
    ) public view returns (uint256 stake) {
        if (totalStakeCached[epoch][assetClassId]) {
            uint256 cachedStake = operatorStakeCache[epoch][assetClassId][operator];

            return cachedStake;
        }

        uint48 epochStartTs = getEpochStartTs(epoch);

        uint256 totalVaults = vaultManager.getVaultCount();

        for (uint256 i; i < totalVaults; ++i) {
            (address vault, uint48 enabledTime, uint48 disabledTime) = vaultManager.getVaultAtWithTimes(i);

            // Skip if vault not active in the target epoch
            if (!_wasActiveAt(enabledTime, disabledTime, epochStartTs)) {
                continue;
            }

            // Skip if vault asset not in AssetClassID
            if (vaultManager.getVaultAssetClass(vault) != assetClassId) {
                continue;
            }

            uint256 vaultStake = BaseDelegator(IVaultTokenized(vault).delegator()).stakeAt(
                L1_VALIDATOR_MANAGER, assetClassId, operator, epochStartTs, new bytes(0)
            );

            stake += vaultStake;
        }
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function getTotalStake(uint48 epoch, uint96 assetClassId) public view returns (uint256) {
        if (totalStakeCached[epoch][assetClassId]) {
            return totalStakeCache[epoch][assetClassId];
        }
        return _calcTotalStake(epoch, assetClassId);
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

    function isActiveAssetClass(
        uint96 assetClassId
    ) external view returns (bool) {
        return _isActiveAssetClass(assetClassId);
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
            bytes32 validationID =
                balancerValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId))));
            Validator memory validator = balancerValidatorManager.getValidator(validationID);

            // Skip if no validator is registered for this nodeId
            if (validationID == bytes32(0) || validationIdToOperator[validationID] != operator) {
                continue;
            }

            if (_wasActiveAt(uint48(validator.startedAt), uint48(validator.endedAt), epochStartTs)) {
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
        for (uint256 i = 0; i < nodesArr.length; i++) {
            bytes32 nodeId = nodesArr[i];
            bytes32 validationID =
                balancerValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId))));
            registeredStake += getEffectiveNodeStake(getCurrentEpoch(), validationID);
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
        uint96 assetClass
    ) external view returns (uint256) {
        if (assetClass == PRIMARY_ASSET_CLASS) {
            bytes32[] memory nodesArr = this.getActiveNodesForEpoch(operator, epoch);
            uint256 operatorStake = 0;

            for (uint256 i = 0; i < nodesArr.length; i++) {
                bytes32 nodeId = nodesArr[i];
                bytes32 validationID =
                    balancerValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId))));
                operatorStake += getEffectiveNodeStake(epoch, validationID);
            }
            return operatorStake;
        } else {
            return getOperatorStake(operator, epoch, assetClass);
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
        if (totalStake <= lockedStake) {
            return 0;
        }
        return totalStake - lockedStake;
    }

    /**
     * @notice Helper to calculate total stake for an epoch
     * @param epoch The epoch number
     * @param assetClassId The asset class ID
     * @return totalStake The total stake across all operators
     */
    function _calcTotalStake(uint48 epoch, uint96 assetClassId) private view returns (uint256 totalStake) {
        uint48 epochStartTs = getEpochStartTs(epoch);

        // for epoch older than SLASHING_WINDOW total stake can be invalidated (use cache)
        if (epochStartTs > Time.timestamp() || epochStartTs < Time.timestamp() - SLASHING_WINDOW) {
            revert AvalancheL1Middleware__EpochError(epochStartTs);
        }

        uint256 length = operators.length();

        for (uint256 i; i < length; ++i) {
            (address operator, uint48 enabledTime, uint48 disabledTime) = operators.atWithTimes(i);
            // just skip operator if it was added after the target epoch or paused
            if (!_wasActiveAt(enabledTime, disabledTime, epochStartTs)) {
                continue;
            }
            uint256 operatorStake = getOperatorStake(operator, epoch, assetClassId);
            totalStake += operatorStake;
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
}
