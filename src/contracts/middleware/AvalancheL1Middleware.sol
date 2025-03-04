// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {
    IValidatorManager,
    Validator,
    ValidatorStatus,
    ValidatorRegistrationInput,
    PChainOwner
} from "@avalabs/teleporter/validator-manager/interfaces/IValidatorManager.sol";
import {ValidatorManager} from "@avalabs/teleporter/validator-manager/ValidatorManager.sol";
import {BalancerValidatorManager} from
    "@suzaku/contracts-library/contracts/ValidatorManager/BalancerValidatorManager.sol";

import {IOperatorRegistry} from "../../interfaces/IOperatorRegistry.sol";
import {IRegistry} from "../../interfaces/common/IRegistry.sol";
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
    uint48 weightUpdateWindow;
}

/**
 * @title AvalancheL1Middleware
 * @notice Manages operator registration, vault registration, stake accounting, and slashing for Avalanche L1
 */
contract AvalancheL1Middleware is IAvalancheL1Middleware, Ownable, AssetClassRegistry {
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    using EnumerableSet for EnumerableSet.UintSet;
    using MapWithTimeData for EnumerableMap.AddressToUintMap;
    using EnumerableMap for EnumerableMap.Bytes32ToUintMap;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    address public immutable L1_VALIDATOR_MANAGER;
    address public immutable OPERATOR_REGISTRY;
    address public immutable OPERATOR_L1_OPTIN;
    address public immutable PRIMARY_ASSET;
    address public immutable BALANCER_VALIDATOR_MANAGER;
    uint48 public immutable EPOCH_DURATION;
    uint48 public immutable SLASHING_WINDOW;
    uint48 public immutable START_TIME;
    uint48 public immutable UPDATE_WINDOW;
    uint48 private lastGlobalNodeWeightsUpdateEpoch;

    uint96 public constant PRIMARY_ASSET_CLASS = 1;
    uint256 public constant WEIGHT_SCALE_FACTOR = 1e8;

    MiddlewareVaultManager vaultManager;
    EnumerableMap.AddressToUintMap private operators;
    EnumerableMap.AddressToUintMap private vaults;
    EnumerableSet.UintSet private secondaryAssetClasses;

    BalancerValidatorManager public balancerValidatorManager;

    mapping(address => mapping(uint48 => bool)) public rebalancedThisEpoch;
    mapping(uint48 => mapping(uint96 => uint256)) public totalStakeCache;
    mapping(uint48 => mapping(uint96 => bool)) public totalStakeCached;
    mapping(address => uint96) public vaultToAssetClass;
    mapping(address => bytes32[]) public operatorNodesArray;
    mapping(uint48 => mapping(uint96 => mapping(address => uint256))) public operatorStakeCache;
    mapping(uint48 => mapping(bytes32 => uint256)) public nodeWeightCache;
    mapping(bytes32 => bool) public nodePendingUpdate;
    mapping(bytes32 => bool) public nodePendingRemoval;
    mapping(address => uint256) public operatorLockedStake;
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
        uint256 primaryAssetMinStake
    ) Ownable(owner) {
        if (settings.slashingWindow < settings.epochDuration) {
            revert AvalancheL1Middleware__SlashingWindowTooShort(settings.slashingWindow, settings.epochDuration);
        }

        START_TIME = Time.timestamp();
        EPOCH_DURATION = settings.epochDuration;
        L1_VALIDATOR_MANAGER = settings.l1ValidatorManager;
        OPERATOR_REGISTRY = settings.operatorRegistry;
        OPERATOR_L1_OPTIN = settings.operatorL1Optin;
        SLASHING_WINDOW = settings.slashingWindow;
        PRIMARY_ASSET = primaryAsset;
        UPDATE_WINDOW = settings.weightUpdateWindow;

        balancerValidatorManager = BalancerValidatorManager(settings.l1ValidatorManager);
        Ownable(owner);
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

    modifier updateGlobalNodeWeightsOncePerEpoch() {
        uint48 current = getCurrentEpoch();
        if (current > lastGlobalNodeWeightsUpdateEpoch) {
            calcAndCacheNodeWeightsForAllOperators();
            lastGlobalNodeWeightsUpdateEpoch = current;
        }
        _;
    }

    function setVaultManager(
        address vaultManager_
    ) external onlyOwner {
        vaultManager = MiddlewareVaultManager(vaultManager_);
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function activateSecondaryAssetClass(
        uint256 assetClassId
    ) external onlyOwner updateGlobalNodeWeightsOncePerEpoch {
        if (!assetClassIds.contains(assetClassId)) {
            revert AssetClassRegistry__AssetClassNotFound();
        }
        if (assetClassId == PRIMARY_ASSET_CLASS) {
            revert AssetClassRegistry__AssetClassAlreadyExists();
        }

        secondaryAssetClasses.add(assetClassId);
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function deactivateSecondaryAssetClass(
        uint256 assetClassId
    ) external onlyOwner updateGlobalNodeWeightsOncePerEpoch {
        if (!secondaryAssetClasses.contains(assetClassId)) {
            revert AssetClassRegistry__AssetClassNotFound();
        }

        if (_isUsedAssetClass(assetClassId)) {
            revert AvalancheL1Middleware__AssetStillInUse(assetClassId);
        }

        secondaryAssetClasses.remove(assetClassId);
    }

    /**
     * @notice Removes an asset from an asset class, except primary asset
     * @param assetClassId The ID of the asset class
     * @param asset The address of the asset to remove
     */
    function removeAssetFromClass(
        uint256 assetClassId,
        address asset
    ) external override updateGlobalNodeWeightsOncePerEpoch {
        if (assetClassId == 1 && asset == PRIMARY_ASSET) {
            revert AssetClassRegistry__AssetIsPrimarytAssetClass(assetClassId);
        }

        if (_isUsedAsset(assetClassId, asset)) {
            revert AvalancheL1Middleware__AssetStillInUse(assetClassId);
        }

        _removeAssetFromClass(assetClassId, asset);
    }

    /**
     * @notice Removes an asset class
     * @param assetClassId The asset class ID
     */
    function removeAssetClass(
        uint256 assetClassId
    ) external override updateGlobalNodeWeightsOncePerEpoch {
        if (secondaryAssetClasses.contains(assetClassId)) {
            revert AvalancheL1Middleware__ActiveSecondaryAssetCLass(assetClassId);
        }

        _removeAssetClass(assetClassId);
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function registerOperator(
        address operator
    ) external onlyOwner updateGlobalNodeWeightsOncePerEpoch {
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
    ) external onlyOwner updateGlobalNodeWeightsOncePerEpoch {
        operators.disable(operator);
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function enableOperator(
        address operator
    ) external onlyOwner updateGlobalNodeWeightsOncePerEpoch {
        operators.enable(operator);
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function removeOperator(
        address operator
    ) external onlyOwner updateGlobalNodeWeightsOncePerEpoch {
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
        uint256 weight // optional
    ) external updateStakeCache(getCurrentEpoch(), PRIMARY_ASSET_CLASS) updateGlobalNodeWeightsOncePerEpoch {
        address operator = msg.sender;
        if (!operators.contains(operator)) {
            revert AvalancheL1Middleware__OperatorNotRegistered(operator);
        }
        if (!_requireMinSecondaryAssetClasses(1, operator)) {
            revert AvalancheL1Middleware__NotEnoughFreeStakeSecondaryAssetClasses();
        }

        uint256 available = _getOperatorAvailableStake(operator);
        uint256 minStake = assetClasses[PRIMARY_ASSET_CLASS].minValidatorStake;
        uint256 maxStake = assetClasses[PRIMARY_ASSET_CLASS].maxValidatorStake;
        uint256 newWeight = (weight != 0) ? weight : available;

        if (newWeight < minStake || newWeight > available) {
            revert AvalancheL1Middleware__NotEnoughFreeStake(newWeight);
        }
        newWeight = (newWeight > maxStake) ? maxStake : newWeight;

        ValidatorRegistrationInput memory input = ValidatorRegistrationInput({
            nodeID: abi.encodePacked(nodeId),
            blsPublicKey: blsKey,
            registrationExpiry: registrationExpiry,
            remainingBalanceOwner: remainingBalanceOwner,
            disableOwner: disableOwner
        });

        bytes32 validationID =
            balancerValidatorManager.initializeValidatorRegistration(input, StakeConversion.stakeToWeight(newWeight));

        // Track node in our time-based map and dynamic array.
        operatorNodes[operator].add(nodeId);
        operatorNodesArray[operator].push(nodeId);

        uint48 epoch = getCurrentEpoch();
        nodeWeightCache[epoch][validationID] = newWeight;
        nodeWeightCache[epoch + 1][validationID] = newWeight;
        nodePendingUpdate[validationID] = true;

        emit NodeAdded(operator, nodeId, newWeight, validationID);
    }

    function removeNode(
        bytes32 nodeId
    ) external updateGlobalNodeWeightsOncePerEpoch {
        address operator = msg.sender;
        _removeNode(operator, nodeId);
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function forceUpdateNodes(
        address operator,
        uint256 limitWeight
    )
        external
        updateStakeCache(getCurrentEpoch(), PRIMARY_ASSET_CLASS)
        onlyDuringFinalWindowOfEpoch
        updateGlobalNodeWeightsOncePerEpoch
    {
        uint48 currentEpoch = getCurrentEpoch();
        if (rebalancedThisEpoch[operator][currentEpoch]) {
            revert AvalancheL1Middleware__AlreadyRebalanced(operator, currentEpoch);
        }
        rebalancedThisEpoch[operator][currentEpoch] = true;

        if (!operators.contains(operator)) {
            revert AvalancheL1Middleware__OperatorNotRegistered(operator);
        }

        // Calculate the new total stake for the operator and compare it to the registered stake
        uint256 newTotalStake = _getOperatorAvailableStake(operator);

        uint256 registeredStake = getOperatorUsedWeightCached(operator);

        bytes32[] storage nodesArr = operatorNodesArray[operator];
        uint256 length = nodesArr.length;

        if (newTotalStake == registeredStake) {
            return;
        }

        bool isAdding = (newTotalStake > registeredStake);
        uint256 diff = isAdding ? (newTotalStake - registeredStake) : (registeredStake - newTotalStake);

        // For adding stake, handle empty array / secondary asset checks
        if (isAdding) {
            if (length == 0) {
                emit OperatorHasLeftoverStake(operator, diff);
                return;
            }
            if (!_requireMinSecondaryAssetClasses(0, operator)) {
                revert AvalancheL1Middleware__NotEnoughFreeStakeSecondaryAssetClasses();
            }
        }

        // Single loop for either adding or removing
        for (uint256 i = length; i > 0 && diff > 0;) {
            i--;
            bytes32 nodeId = nodesArr[i];
            bytes32 valID = balancerValidatorManager.registeredValidators(abi.encodePacked(nodeId));
            if (balancerValidatorManager.isValidatorPendingWeightUpdate(valID)) {
                continue;
            }
            Validator memory validator = balancerValidatorManager.getValidator(valID);
            if (validator.status != ValidatorStatus.Active) {
                continue;
            }

            uint256 previousWeight = getEffectiveNodeWeight(currentEpoch, valID);
            if (isAdding) {
                // Add stake
                uint256 capacity = previousWeight < assetClasses[PRIMARY_ASSET_CLASS].maxValidatorStake
                    ? assetClasses[PRIMARY_ASSET_CLASS].maxValidatorStake - previousWeight
                    : 0;
                if (capacity == 0) {
                    continue;
                }
                uint256 stakeToAdd = diff < capacity ? diff : capacity;
                if (limitWeight > 0 && stakeToAdd > limitWeight) {
                    stakeToAdd = limitWeight;
                }
                uint64 newWeight = StakeConversion.stakeToWeight(previousWeight + stakeToAdd);
                diff -= stakeToAdd;
                _initializeValidatorWeightUpdateAndLock(operator, valID, newWeight);
                emit NodeWeightUpdated(operator, nodeId, newWeight, valID);
            } else {
                // Remove stake
                if (previousWeight == 0) {
                    continue;
                }
                uint256 stakeToRemove = diff < previousWeight ? diff : previousWeight;
                if (limitWeight > 0 && stakeToRemove > limitWeight) {
                    stakeToRemove = limitWeight;
                }
                uint256 newWeight = previousWeight - stakeToRemove;
                diff -= stakeToRemove;

                if (
                    (newWeight < assetClasses[PRIMARY_ASSET_CLASS].minValidatorStake)
                        || !_requireMinSecondaryAssetClasses(0, operator)
                ) {
                    newWeight = 0;
                    _initializeEndValidationAndFlag(operator, valID, nodeId);
                } else {
                    _initializeValidatorWeightUpdateAndLock(operator, valID, StakeConversion.stakeToWeight(newWeight));
                    emit NodeWeightUpdated(operator, nodeId, newWeight, valID);
                }
            }
        }

        // If there’s leftover after distributing (only relevant when adding)
        if (diff > 0 && isAdding) {
            emit OperatorHasLeftoverStake(operator, diff);
        }

        emit AllNodeWeightsUpdated(operator, newTotalStake);
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function initializeValidatorWeightUpdateAndLock(
        bytes32 nodeId,
        uint64 newWeight
    ) external updateGlobalNodeWeightsOncePerEpoch {
        if (!operatorNodes[msg.sender].contains(nodeId)) {
            revert AvalancheL1Middleware__NodeNotFound(nodeId);
        }

        uint256 minStake = assetClasses[PRIMARY_ASSET_CLASS].minValidatorStake;
        uint256 maxStake = assetClasses[PRIMARY_ASSET_CLASS].maxValidatorStake;

        if (newWeight > maxStake) {
            revert AvalancheL1Middleware__WeightTooHigh(newWeight, maxStake);
        }

        if (newWeight < minStake) {
            revert AvalancheL1Middleware__WeightTooLow(newWeight, minStake);
        }
        bytes32 validationID = balancerValidatorManager.registeredValidators(abi.encodePacked(nodeId));

        _initializeValidatorWeightUpdateAndLock(msg.sender, validationID, newWeight);
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function completeValidatorRegistration(
        address operator,
        bytes32 nodeId,
        uint32 messageIndex
    ) external updateGlobalNodeWeightsOncePerEpoch {
        _completeValidatorRegistration(operator, nodeId, messageIndex);
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function completeNodeWeightUpdate(
        bytes32 nodeId,
        uint32 messageIndex
    ) external onlyRegisteredOperatorNode(msg.sender, nodeId) updateGlobalNodeWeightsOncePerEpoch {
        _completeWeightUpdateAndCache(msg.sender, nodeId, messageIndex);
    }

    function completeValidatorRemoval(
        uint32 messageIndex
    ) external updateGlobalNodeWeightsOncePerEpoch {
        _completeValidatorRemoval(messageIndex);
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function slash(
        uint48 epoch,
        address operator,
        uint256 amount,
        uint96 assetClassId
    ) public onlyOwner updateStakeCache(epoch, assetClassId) updateGlobalNodeWeightsOncePerEpoch {
        revert AvalancheL1Middleware__NotImplemented();
    }

    /**
     * @inheritdoc IAvalancheL1Middleware
     */
    function calcAndCacheStakes(uint48 epoch, uint96 assetClassId) public returns (uint256 totalStake) {
        uint48 epochStartTs = getEpochStartTs(epoch);

        // Check for too-old epoch: note that if Time.timestamp() < SLASHING_WINDOW this subtraction underflows.
        if (epochStartTs > Time.timestamp() || epochStartTs < Time.timestamp() - SLASHING_WINDOW) {
            revert AvalancheL1Middleware__EpochError(epochStartTs);
        }

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

    function calcAndCacheNodeWeightsForAllOperators() public {
        uint48 current = getCurrentEpoch();
        // If we're already up to date, do nothing
        if (current <= lastGlobalNodeWeightsUpdateEpoch) {
            return;
        }

        // Update lastGlobalNodeWeightsUpdateEpoch + 1
        uint48 transitionEpoch = lastGlobalNodeWeightsUpdateEpoch + 1;
        for (uint256 i = 0; i < operators.length(); i++) {
            (address operator,,) = operators.atWithTimes(i);
            _calcAndCacheNodeWeightsForOperatorAtEpoch(operator, transitionEpoch);
        }

        if (transitionEpoch == current) {
            lastGlobalNodeWeightsUpdateEpoch = current;
            return;
        }
        // Copy transitionEpoch cache to all others
        for (uint48 epoch = transitionEpoch + 1; epoch <= current; epoch++) {
            for (uint256 i = 0; i < operators.length(); i++) {
                (address operator,,) = operators.atWithTimes(i);
                bytes32[] storage nodeArray = operatorNodesArray[operator];
                for (uint256 j; j < nodeArray.length; j++) {
                    bytes32 nodeId = nodeArray[j];
                    bytes32 validationID = balancerValidatorManager.registeredValidators(abi.encodePacked(nodeId));
                    nodeWeightCache[epoch][validationID] = nodeWeightCache[epoch - 1][validationID];
                }
            }
        }
        lastGlobalNodeWeightsUpdateEpoch = current;
    }

    /**
     * @notice Caches manager-based weight for each node of `operator` in epoch `currentEpoch`.
     * @param operator The operator address
     */
    function _calcAndCacheNodeWeightsForOperatorAtEpoch(address operator, uint48 epoch) internal {
        uint48 prevEpoch = (epoch == 0) ? 0 : epoch - 1;
        bytes32[] storage nodeArray = operatorNodesArray[operator];
        for (uint256 i = nodeArray.length; i > 0; ) {
            i--;
            bytes32 nodeId = nodeArray[i];
            bytes32 valID = balancerValidatorManager.registeredValidators(abi.encodePacked(nodeId));

            // If no removal/update, just carry over from prevEpoch (only if we haven’t set it yet)
            if (!nodePendingRemoval[valID] && !nodePendingUpdate[valID]) {
                if (nodeWeightCache[epoch][valID] == 0) {
                    nodeWeightCache[epoch][valID] = nodeWeightCache[prevEpoch][valID];
                }
                continue;
            }

            if (nodePendingRemoval[valID] && nodeWeightCache[epoch][valID] == 0 && nodeWeightCache[prevEpoch][valID] != 0) {
                _removeNodeFromArray(operator, nodeId);
                nodePendingRemoval[valID] = false;
            }

            // If there was a pending update, finalize and clear the pending markers
            if (nodePendingUpdate[valID]) {
                nodePendingUpdate[valID] = false;
                operatorLockedStake[operator] = 0;
            }
        }
    }

    /**
     * @notice Remove a node => end its validator. Checks still to be done.
     * @param nodeId The node ID
     */
    function _removeNode(address operator, bytes32 nodeId) internal onlyRegisteredOperatorNode(operator, nodeId) {
        bytes32 validationID = balancerValidatorManager.registeredValidators(abi.encodePacked(nodeId));
        _initializeEndValidationAndFlag(operator, validationID, nodeId);
    }

    function _initializeEndValidationAndFlag(address operator, bytes32 validationID, bytes32 nodeId) internal {
        balancerValidatorManager.initializeEndValidation(validationID);

        uint48 nextEpoch = getCurrentEpoch() + 1;
        nodeWeightCache[nextEpoch][validationID] = 0;
        nodePendingRemoval[validationID] = true;

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
     * @notice Completes a validator's weight update and flags the update as pending for re calculation.
     * @dev This function fetches the updated weight from the BalancerValidatorManager, compares it to the
     *      previously‐cached weight, updates operator stake balances, and stores the new weight.
     * @param operator The operator who owns the validator
     * @param nodeId The unique ID of the validator whose weight update is being finalized
     * @param messageIndex The message index from the BalancerValidatorManager (used for ordering/verification)
     */
    function _completeWeightUpdateAndCache(
        address operator,
        bytes32 nodeId,
        uint32 messageIndex
    ) internal onlyRegisteredOperatorNode(operator, nodeId) {
        bytes32 validationID = balancerValidatorManager.registeredValidators(abi.encodePacked(nodeId));

        if (!balancerValidatorManager.isValidatorPendingWeightUpdate(validationID)) {
            revert AvalancheL1Middleware__WeightUpdateNotPending(validationID);
        }
        // if the completeValidatorWeightUpdate fails, not sure if the previous bool is secure.
        balancerValidatorManager.completeValidatorWeightUpdate(validationID, messageIndex);
    }

    /**
     * @notice Sets the weight of a validator and updates the operator's locked stake accordingly.
     * @param operator The operator who owns the validator
     * @param validationID The unique ID of the validator whose weight is being updated
     * @param newWeight The new weight for the validator
     * @dev When updating the weight of a validator, the operator's locked stake is increased or decreased
     */
    function _initializeValidatorWeightUpdateAndLock(
        address operator,
        bytes32 validationID,
        uint64 newWeight
    ) internal {
        uint48 currentEpoch = getCurrentEpoch();
        uint256 cachedWeight = getEffectiveNodeWeight(currentEpoch, validationID);

        if (balancerValidatorManager.isValidatorPendingWeightUpdate(validationID)) {
            revert AvalancheL1Middleware__WeightUpdatePending(validationID);
        }
        uint256 delta;
        balancerValidatorManager.initializeValidatorWeightUpdate(validationID, StakeConversion.stakeToWeight(newWeight));
        if (newWeight > cachedWeight) {
            delta = newWeight - cachedWeight;
            if (delta > _getOperatorAvailableStake(operator)) {
                revert AvalancheL1Middleware__NotEnoughFreeStake(newWeight);
            }
        }
        operatorLockedStake[operator] += delta;
        nodePendingUpdate[validationID] = true;
        nodeWeightCache[currentEpoch + 1][validationID] = newWeight;
        // if newWeight < cachedWeight, no lock should happen, it's locked in the cache
    }

    function _requireMinSecondaryAssetClasses(uint256 extraNode, address operator) internal view returns (bool) {
        uint48 epoch = getCurrentEpoch();
        uint256 nodeCount = operatorNodesArray[operator].length; // existing nodes

        uint256 secCount = secondaryAssetClasses.length();
        if (secCount == 0) {
            return true;
        }
        for (uint256 i = 0; i < secCount; i++) {
            uint256 classId = secondaryAssetClasses.at(i);
            uint256 stake = getOperatorStake(operator, epoch, uint96(classId));
            // Check ratio vs. class's min stake, could add an emit here to debug
            if (stake / (nodeCount + extraNode) < assetClasses[classId].minValidatorStake) {
                return false;
            }
        }
        return true;
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
        for (uint256 i; i < vaults.length(); ++i) {
            (address vault,) = vaults.at(i);
            if (vaultToAssetClass[vault] == assetClassId && IVaultTokenized(vault).collateral() == asset) {
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
        for (uint256 i; i < vaults.length(); ++i) {
            (address vault,) = vaults.at(i);
            if (vaultToAssetClass[vault] == assetClassId) {
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
        return nodeWeightCache[epoch][validationID];
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
            bytes32 validationID = balancerValidatorManager.registeredValidators(abi.encodePacked(nodeId));
            Validator memory validator = balancerValidatorManager.getValidator(validationID);

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
    function getOperatorUsedWeightCached(
        address operator
    ) public view returns (uint256 registeredStake) {
        bytes32[] storage nodesArr = operatorNodesArray[operator];
        for (uint256 i = 0; i < nodesArr.length; i++) {
            bytes32 nodeId = nodesArr[i];
            bytes32 validationID = balancerValidatorManager.registeredValidators(abi.encodePacked(nodeId));
            registeredStake += getEffectiveNodeWeight(getCurrentEpoch(), validationID);
        }
    }

    /**
     * @notice  Gets the effective weight for a specific ValidationID.
     * @param epoch The epoch number
     * @param validationID The validation ID
     */
    function getEffectiveNodeWeight(uint48 epoch, bytes32 validationID) internal view returns (uint256) {
        return nodeWeightCache[epoch][validationID];
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
        uint256 convertedSecurityModuleMaxWeight = StakeConversion.weightToStake(securityModuleMaxWeight);
        if (totalStake > convertedSecurityModuleMaxWeight) {
            totalStake = convertedSecurityModuleMaxWeight;
        }

        // Subtract locked stake
        return totalStake - operatorLockedStake[operator];
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
        return enabledTime != 0 && enabledTime <= timestamp && (disabledTime == 0 || disabledTime >= timestamp);
    }
}
