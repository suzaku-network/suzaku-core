// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";

import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {AssetClassRegistry} from "./AssetClassRegistry.sol";

import {IOperatorRegistry} from "../../interfaces/IOperatorRegistry.sol";
import {IRegistry} from "../../interfaces/common/IRegistry.sol";
import {IEntity} from "../../interfaces/common/IEntity.sol";
import {IVaultTokenized} from "../../interfaces/vault/IVaultTokenized.sol";
import {BaseDelegator} from "../../contracts/delegator/BaseDelegator.sol";
import {IOptInService} from "../../interfaces/service/IOptInService.sol";
import {ISlasher} from "../../interfaces/slasher/ISlasher.sol";
import {IVetoSlasher} from "../../interfaces/slasher/IVetoSlasher.sol";

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

import {SimpleKeyRegistry32} from "./SimpleKeyRegistry32.sol";
import {MapWithTimeData} from "./libraries/MapWithTimeData.sol";
import {MapWithTimeDataBytes32} from "./libraries/MapWithTimeDataBytes32.sol";
import {SimpleNodeRegistry32} from "./SimpleNodeRegistry32.sol";

struct AvalancheL1MiddlewareSettings {
    address l1ValidatorManager;
    address operatorRegistry;
    address vaultRegistry;
    address operatorL1Optin;
    uint48 epochDuration;
    uint48 slashingWindow;
}

struct OperatorData {
    uint256 stake;
    bytes32 key;
}

error AvalancheL1Middleware__ActiveSecondaryAssetCLass();
error AvalancheL1Middleware__AssetClassNotActive();
error AvalancheL1Middleware__AssetIsPrimaryAsset();
error AvalancheL1Middleware__AssetStillInUse();
error AvalancheL1Middleware__AlreadyRebalanced();
error AvalancheL1Middleware__WeightUpdateNotPending();
error AvalancheL1Middleware__CollateralNotInAssetClass();
error AvalancheL1Middleware__InvalidEpoch();
error AvalancheL1Middleware__MaxL1LimitZero();
error AvalancheL1Middleware__NoSlasher();
error AvalancheL1Middleware__NotVault();
error AvalancheL1Middleware__NotEnoughSecondaryAssetClasses();
error AvalancheL1Middleware__NodeNotActive();
error AvalancheL1Middleware__NotEnoughFreeStake();
error AvalancheL1Middleware__WeightTooHigh();
error AvalancheL1Middleware__WeightTooLow();
error AvalancheL1Middleware__OperatorGracePeriodNotPassed();
error AvalancheL1Middleware__OperatorAlreadyRegistered();
error AvalancheL1Middleware__OperatorNotOptedIn();
error AvalancheL1Middleware__OperatorNotRegistered();
error AvalancheL1Middleware__SlashingWindowTooShort();
error AvalancheL1Middleware__TooBigSlashAmount();
error AvalancheL1Middleware__TooOldEpoch();
error AvalancheL1Middleware__UnknownSlasherType();
error AvalancheL1Middleware__VaultAlreadyRegistered();
error AvalancheL1Middleware__VaultEpochTooShort();
error AvalancheL1Middleware__VaultGracePeriodNotPassed();
error AvalancheL1Middleware__WrongVaultAssetClass();
error AvalancheL1Middleware__ZeroVaultMaxL1Limit();
error AvalancheL1Middleware__NodeNotFound();
error AvalancheL1Middleware__NodeWeightNotCached();
error AvalancheL1Middleware__SecutiryModuleCapacityNotEnough();
error AvalancheL1Middleware__WeightUpdatePending();
error AvalancheL1Middleware__NodeStateNotUpdated();

/**
 * @title AvalancheL1Middleware
 * @notice Manages operator registration, vault registration, stake accounting, and slashing for Avalanche L1
 */
contract AvalancheL1Middleware is SimpleNodeRegistry32, Ownable, AssetClassRegistry {
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;
    using MapWithTimeData for EnumerableMap.AddressToUintMap;
    using EnumerableMap for EnumerableMap.Bytes32ToUintMap;
    using MapWithTimeDataBytes32 for EnumerableMap.Bytes32ToUintMap;

    event NodeAdded(
        address indexed operator, bytes32 indexed nodeId, bytes blsKey, uint256 stake, bytes32 validationID
    );
    event NodeRemoved(address indexed operator, bytes32 indexed nodeId);
    event NodeWeightUpdated(address indexed operator, bytes32 indexed nodeId, uint256 newStake);
    event OperatorHasLeftoverStake(address indexed operator, uint256 leftoverStake);
    event AllNodeWeightsUpdated(address indexed operator, uint256 newStake);

    address public immutable L1_VALIDATOR_MANAGER;
    address public immutable OPERATOR_REGISTRY;
    address public immutable VAULT_REGISTRY;
    address public immutable OPERATOR_L1_OPTIN;
    address public immutable OWNER;
    address public immutable PRIMARY_ASSET;
    uint48 public immutable EPOCH_DURATION;
    uint48 public immutable SLASHING_WINDOW;
    uint48 public immutable START_TIME;

    uint48 private constant INSTANT_SLASHER_TYPE = 0;
    uint48 private constant VETO_SLASHER_TYPE = 1;
    uint96 public constant PRIMARY_ASSET_CLASS = 1;
    uint256 public constant WEIGHT_SCALE_FACTOR = 1e8;

    BalancerValidatorManager balancerValidatorManager;
    EnumerableSet.UintSet private secondaryAssetClasses;
    EnumerableMap.AddressToUintMap private operators;
    EnumerableMap.AddressToUintMap private vaults;

    mapping(uint48 => mapping(uint96 => uint256)) public totalStakeCache;
    mapping(uint48 => mapping(uint96 => bool)) public totalStakeCached;
    mapping(address => uint96) public vaultToAssetClass;
    mapping(address => EnumerableMap.Bytes32ToUintMap) private operatorNodes;
    mapping(address => bytes32[]) private operatorNodesArray;
    mapping(uint48 => mapping(uint96 => mapping(address => uint256))) public operatorStakeCache;
    mapping(address => mapping(uint48 => bool)) private rebalancedThisEpoch;
    mapping(uint48 => mapping(bytes32 => uint256)) public nodeWeightCache;
    mapping(bytes32 => uint256) public nodePendingWeight;
    mapping(bytes32 => bool) public nodePendingUpdate;
    mapping(uint48 => mapping(bytes32 => bool)) public nodePendingCompletedUpdate;
    mapping(address => uint256) public operatorLockedStake;

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
    ) SimpleNodeRegistry32() Ownable(owner) {
        if (settings.slashingWindow < settings.epochDuration) {
            revert AvalancheL1Middleware__SlashingWindowTooShort();
        }

        START_TIME = Time.timestamp();
        EPOCH_DURATION = settings.epochDuration;
        L1_VALIDATOR_MANAGER = settings.l1ValidatorManager;
        OWNER = owner;
        OPERATOR_REGISTRY = settings.operatorRegistry;
        VAULT_REGISTRY = settings.vaultRegistry;
        OPERATOR_L1_OPTIN = settings.operatorL1Optin;
        SLASHING_WINDOW = settings.slashingWindow;
        PRIMARY_ASSET = primaryAsset;

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
     * @notice Activates a secondary asset class
     * @param assetClassId The asset class ID to activate
     */
    function activateSecondaryAssetClass(
        uint256 assetClassId
    ) external onlyOwner {
        if (!assetClassIds.contains(assetClassId)) {
            revert AssetClassRegistry__AssetClassNotFound();
        }
        if (assetClassId == PRIMARY_ASSET_CLASS) {
            revert AssetClassRegistry__AssetClassAlreadyExists();
        }

        secondaryAssetClasses.add(assetClassId);
    }

    /**
     * @notice Deactivates a secondary asset class
     * @param assetClassId The asset class ID to deactivate
     */
    function deactivateSecondaryAssetClass(
        uint256 assetClassId
    ) external onlyOwner {
        if (!secondaryAssetClasses.contains(assetClassId)) {
            revert AssetClassRegistry__AssetClassNotFound();
        }

        if (_isUsedAssetClass(assetClassId)) {
            revert AvalancheL1Middleware__AssetStillInUse();
        }

        secondaryAssetClasses.remove(assetClassId);
    }

    /**
     * @notice Removes an asset from an asset class, except primary asset
     * @param assetClassId The ID of the asset class
     * @param asset The address of the asset to remove
     */
    function removeAssetFromClass(uint256 assetClassId, address asset) external override {
        if (assetClassId == 1 && asset == PRIMARY_ASSET) {
            revert AssetClassRegistry__AssetIsPrimaryAsset();
        }

        if (_isUsedAsset(assetClassId, asset)) {
            revert AvalancheL1Middleware__AssetStillInUse();
        }

        _removeAssetFromClass(assetClassId, asset);
    }

    /**
     * @notice Removes an asset class
     * @param assetClassId The asset class ID
     */
    function removeAssetClass(
        uint256 assetClassId
    ) external override {
        if (secondaryAssetClasses.contains(assetClassId)) {
            revert AvalancheL1Middleware__ActiveSecondaryAssetCLass();
        }

        _removeAssetClass(assetClassId);
    }

    /**
     * @notice Registers a new operator and enables it
     * @param operator The operator address
     */
    function registerOperator(
        address operator
    ) external onlyOwner {
        if (operators.contains(operator)) {
            revert AvalancheL1Middleware__OperatorAlreadyRegistered();
        }
        if (!IOperatorRegistry(OPERATOR_REGISTRY).isRegistered(operator)) {
            revert AvalancheL1Middleware__OperatorNotRegistered();
        }
        if (!IOptInService(OPERATOR_L1_OPTIN).isOptedIn(operator, L1_VALIDATOR_MANAGER)) {
            revert AvalancheL1Middleware__OperatorNotOptedIn();
        }

        operators.add(operator);
        operators.enable(operator);
    }

    /**
     * @notice Disables an operator
     * @param operator The operator address
     */
    function disableOperator(
        address operator
    ) external onlyOwner {
        operators.disable(operator);
    }

    /**
     * @notice Enables an operator
     * @param operator The operator address
     */
    function enableOperator(
        address operator
    ) external onlyOwner {
        operators.enable(operator);
    }

    /**
     * @notice Removes an operator if grace period has passed
     * @param operator The operator address
     */
    function removeOperator(
        address operator
    ) external onlyOwner {
        (, uint48 disabledTime) = operators.getTimes(operator);
        if (disabledTime == 0 || disabledTime + SLASHING_WINDOW > Time.timestamp()) {
            revert AvalancheL1Middleware__OperatorGracePeriodNotPassed();
        }
        operators.remove(operator);
    }

    /**
     * @notice Registers a vault to a specific asset class, sets the max stake.
     * @param vault The vault address
     * @param assetClassId The asset class ID for that vault
     * @param vaultMaxL1Limit The maximum stake allowed for this vault
     */
    function registerVault(address vault, uint96 assetClassId, uint256 vaultMaxL1Limit) external onlyOwner {
        if (vaultMaxL1Limit == 0) {
            revert AvalancheL1Middleware__ZeroVaultMaxL1Limit();
        }
        if (vaults.contains(vault)) {
            revert AvalancheL1Middleware__VaultAlreadyRegistered();
        }

        uint48 vaultEpoch = IVaultTokenized(vault).epochDuration();
        address slasher = IVaultTokenized(vault).slasher();
        if (slasher != address(0) && IEntity(slasher).TYPE() == VETO_SLASHER_TYPE) {
            vaultEpoch -= IVetoSlasher(slasher).vetoDuration();
        }
        if (vaultEpoch < SLASHING_WINDOW) {
            revert AvalancheL1Middleware__VaultEpochTooShort();
        }

        vaultToAssetClass[vault] = assetClassId;
        _setVaultMaxL1Limit(vault, assetClassId, vaultMaxL1Limit);

        vaults.add(vault);
        vaults.enable(vault);
    }

    /**
     * @notice Updates a vault's max L1 stake limit. Disables or enables the vault based on the new limit
     * @param vault The vault address
     * @param assetClassId The asset class ID
     * @param vaultMaxL1Limit The new maximum stake
     */
    function updateVaultMaxL1Limit(address vault, uint96 assetClassId, uint256 vaultMaxL1Limit) external onlyOwner {
        if (!vaults.contains(vault)) {
            revert AvalancheL1Middleware__NotVault();
        }
        if (vaultToAssetClass[vault] != assetClassId) {
            revert AvalancheL1Middleware__WrongVaultAssetClass();
        }

        _setVaultMaxL1Limit(vault, assetClassId, vaultMaxL1Limit);

        if (vaultMaxL1Limit == 0) {
            vaults.disable(vault);
        } else {
            vaults.enable(vault);
        }
    }

    /**
     * @notice Removes a vault if the grace period has passed
     * @param vault The vault address
     */
    function removeVault(
        address vault
    ) external onlyOwner {
        if (!vaults.contains(vault)) {
            revert AvalancheL1Middleware__NotVault();
        }

        (, uint48 disabledTime) = vaults.getTimes(vault);
        if (disabledTime == 0 || disabledTime + SLASHING_WINDOW > Time.timestamp()) {
            revert AvalancheL1Middleware__VaultGracePeriodNotPassed();
        }

        _setVaultMaxL1Limit(vault, vaultToAssetClass[vault], 0);

        vaults.remove(vault);
        delete vaultToAssetClass[vault];
    }

    /**
     * @notice Add a new node => create a new validator.
     * Check the new node stake also ensure security module capacity.
     * @param nodeId The node ID
     * @param blsKey The BLS key
     * @param registrationExpiry The Unix timestamp after which the reigistration is no longer valid on the P-Chain
     * @param remainingBalanceOwner The owner of a validator's remaining balance
     * @param disableOwner The owner of a validator's disable owner on the P-Chain
     * @param initialWeight The initial weight of the node (optional)
     */
    function addNode(
        bytes32 nodeId,
        bytes calldata blsKey,
        uint64 registrationExpiry,
        PChainOwner calldata remainingBalanceOwner,
        PChainOwner calldata disableOwner,
        uint256 initialWeight // optional
    ) external updateStakeCache(getCurrentEpoch(), PRIMARY_ASSET_CLASS) {
        address operator = msg.sender;
        if (!operators.contains(operator)) {
            revert AvalancheL1Middleware__OperatorNotRegistered();
        }
        if (!_requireMinSecondaryAssetClasses(1, operator)) {
            revert AvalancheL1Middleware__NotEnoughSecondaryAssetClasses();
        }

        uint256 available = _getOperatorAvailableStake(operator);
        uint256 minStake = assetClasses[PRIMARY_ASSET_CLASS].minValidatorStake;
        uint256 maxStake = assetClasses[PRIMARY_ASSET_CLASS].maxValidatorStake;
        if (available < minStake) {
            revert AvalancheL1Middleware__NotEnoughFreeStake();
        }
        uint256 newWeight = (available > maxStake) ? maxStake : available;

        if (initialWeight != 0) {
            if (initialWeight < minStake) {
                revert AvalancheL1Middleware__NotEnoughFreeStake();
            }
            if (initialWeight > available) {
                revert AvalancheL1Middleware__NotEnoughFreeStake();
            }
            // Respect maxStake
            newWeight = (initialWeight > maxStake) ? maxStake : initialWeight;
        }

        (uint64 currentSecurityModuleWeight, uint64 securitymoduleMaxWeight) =
            balancerValidatorManager.getSecurityModuleWeights(address(this));
        uint256 convertedCurrentSecurityModuleWeight = weightToStake(currentSecurityModuleWeight);
        uint256 convertedSecuritymoduleMaxWeight = weightToStake(securitymoduleMaxWeight);
        if (convertedCurrentSecurityModuleWeight + newWeight > convertedSecuritymoduleMaxWeight) {
            uint256 securityModuleCapacity = convertedSecuritymoduleMaxWeight - convertedCurrentSecurityModuleWeight;

            if (securityModuleCapacity < minStake) {
                revert AvalancheL1Middleware__SecutiryModuleCapacityNotEnough();
            }
            if (newWeight > securityModuleCapacity) {
                newWeight = securityModuleCapacity;
            }
        }

        ValidatorRegistrationInput memory input = ValidatorRegistrationInput({
            nodeID: abi.encodePacked(nodeId),
            blsPublicKey: blsKey,
            registrationExpiry: registrationExpiry,
            remainingBalanceOwner: remainingBalanceOwner,
            disableOwner: disableOwner
        });

        bytes32 validationID = balancerValidatorManager.initializeValidatorRegistration(input, stakeToWeight(newWeight));

        updateNodeKey(nodeId, keccak256(blsKey));
        updateNodeValidationID(nodeId, validationID);

        // Track node in our time-based map and dynamic array.
        operatorNodes[operator].add(nodeId);
        // operatorNodes[operator].enable(nodeId); // should enable when it's active
        operatorNodesArray[operator].push(nodeId);

        // Reserve stake immediately.
        operatorLockedStake[operator] += newWeight;

        uint48 epoch = getCurrentEpoch();
        nodeWeightCache[epoch][validationID] = 0;
        nodePendingUpdate[validationID] = true;
        nodePendingWeight[validationID] = newWeight;

        emit NodeAdded(operator, nodeId, blsKey, newWeight, validationID);
    }

    function removeNode(
        bytes32 nodeId
    ) external {
        address operator = msg.sender;
        _removeNode(operator, nodeId);
    }

    /**
     * @notice Rebalance node weights once per epoch for an operator.
     * @param operator The operator address
     * @param limitWeight The maximum weight adjustment (add or remove) allowed per node per call.
     */
    function updateAllNodeWeights(
        address operator,
        uint256 limitWeight
    ) external updateStakeCache(getCurrentEpoch(), PRIMARY_ASSET_CLASS) {
        uint48 currentEpoch = getCurrentEpoch();
        // if (rebalancedThisEpoch[operator][currentEpoch]) {
        //     revert AvalancheL1Middleware__AlreadyRebalanced();
        // }
        // if (rebalancedThisEpoch[operator][currentEpoch]) {
        //     operatorLockedStake[operator] = 0;
        // }
        // rebalancedThisEpoch[operator][currentEpoch] = true;

        if (!operators.contains(operator)) {
            revert AvalancheL1Middleware__OperatorNotRegistered();
        }
        // updates state of node weights cache based on prior actions
        calcAndCacheNodeWeightsForOperator(operator);

        // Calculate the new total stake for the operator and compare it to the registered weight
        uint256 newTotalStake = operatorStakeCache[currentEpoch][PRIMARY_ASSET_CLASS][operator];
        (, uint64 securityModuleMaxWeight) = balancerValidatorManager.getSecurityModuleWeights(address(this));
        if (newTotalStake > securityModuleMaxWeight) {
            newTotalStake = securityModuleMaxWeight;
        }

        // substraction of locked stake for pending changes
        newTotalStake = newTotalStake - operatorLockedStake[operator];

        uint256 registeredStake = getOperatorUsedWeightCached(operator);

        bytes32[] storage nodesArr = operatorNodesArray[operator];
        if (newTotalStake == registeredStake) {
            return;
        } else if (newTotalStake > registeredStake) {
            uint256 unusedStake = newTotalStake - registeredStake;
            if (nodesArr.length == 0) {
                emit OperatorHasLeftoverStake(operator, unusedStake);
                return;
            }
            if (!_requireMinSecondaryAssetClasses(0, operator)) {
                revert AvalancheL1Middleware__NotEnoughSecondaryAssetClasses();
            }
            for (uint256 i = nodesArr.length; i > 0 && unusedStake > 0;) {
                i--;
                bytes32 nodeId = nodesArr[i];
                bytes32 valID = getCurrentValidationID(nodeId);
                Validator memory validator = balancerValidatorManager.getValidator(valID);
                if (
                    validator.status == ValidatorStatus.Active
                        && !balancerValidatorManager.isValidatorPendingWeightUpdate(valID)
                ) {
                    uint256 previousWeight = getEffectiveNodeWeight(currentEpoch, valID);
                    uint256 capacity = previousWeight < assetClasses[PRIMARY_ASSET_CLASS].maxValidatorStake
                        ? assetClasses[PRIMARY_ASSET_CLASS].maxValidatorStake - previousWeight
                        : 0;
                    if (capacity > 0) {
                        uint256 stakeToAdd = (unusedStake < capacity) ? unusedStake : capacity;
                        if (limitWeight > 0 && stakeToAdd > limitWeight) {
                            stakeToAdd = limitWeight;
                        }
                        uint64 newWeight = uint64(previousWeight + stakeToAdd);
                        unusedStake -= stakeToAdd;
                        // update locked stake
                        _initializeValidatorWeightUpdateAndLock(operator, valID, newWeight);
                        emit NodeWeightUpdated(operator, nodeId, newWeight);
                    }
                }
            }
            if (unusedStake > 0) {
                emit OperatorHasLeftoverStake(operator, unusedStake);
            }
        } else {
            uint256 overusedStake = registeredStake - newTotalStake;
            for (uint256 i = nodesArr.length; i > 0 && overusedStake > 0;) {
                i--;
                bytes32 nodeId = nodesArr[i];
                bytes32 valId = getCurrentValidationID(nodeId);

                if (balancerValidatorManager.isValidatorPendingWeightUpdate(valId)) {
                    continue;
                }
                Validator memory validator = balancerValidatorManager.getValidator(valId);
                if (validator.status != ValidatorStatus.Active) {
                    continue;
                }
                uint256 previousWeight = getEffectiveNodeWeight(currentEpoch, valId);
                if (previousWeight == 0) continue;

                uint256 stakeToRemove = overusedStake < previousWeight ? overusedStake : previousWeight;
                if (limitWeight > 0 && stakeToRemove > limitWeight) {
                    stakeToRemove = limitWeight;
                }
                uint256 newWeight = previousWeight - stakeToRemove;
                overusedStake -= stakeToRemove;

                if (
                    newWeight >= 0 && newWeight < assetClasses[PRIMARY_ASSET_CLASS].minValidatorStake
                        || !_requireMinSecondaryAssetClasses(0, operator)
                ) {
                    newWeight = 0;
                    _initializeEndValidationAndFlag(operator, valId, nodeId);
                } else {
                    // not release stake until confirmation.
                    _initializeValidatorWeightUpdateAndLock(operator, valId, uint64(newWeight));
                    // mising update action
                    emit NodeWeightUpdated(operator, nodeId, newWeight);
                }
            }
        }

        emit AllNodeWeightsUpdated(operator, newTotalStake);
    }

    /**
     * @notice Update the weight of a validator.
     * @param nodeId The node ID.
     * @param newWeight The new weight.
     */
    function initializeValidatorWeightUpdateAndLock(bytes32 nodeId, uint64 newWeight) external {
        if (!operatorNodes[msg.sender].contains(nodeId)) {
            revert AvalancheL1Middleware__NodeNotFound();
        }

        uint256 minStake = assetClasses[PRIMARY_ASSET_CLASS].minValidatorStake;
        uint256 maxStake = assetClasses[PRIMARY_ASSET_CLASS].maxValidatorStake;

        if (newWeight > maxStake) {
            revert AvalancheL1Middleware__WeightTooHigh();
        }

        if (newWeight != 0 && newWeight < minStake) {
            revert AvalancheL1Middleware__WeightTooLow();
        }
        bytes32 valId = getCurrentValidationID(nodeId);
        // updates weight up, down it dosn't yet.
        _initializeValidatorWeightUpdateAndLock(msg.sender, valId, newWeight);
    }

    /**
     * @notice Finalize a pending validator registration
     * @param nodeId The node ID
     * @param messageIndex The message index
     */
    function completeValidatorRegistration(bytes32 nodeId, uint32 messageIndex) external {
        _requireRegisteredOperatorAndNode(msg.sender, nodeId);
        _completeValidatorRegistration(msg.sender, nodeId, messageIndex);
    }

    /**
     * @notice Finalize a pending weight update
     * @param nodeId The node ID
     * @param messageIndex The message index
     */
    function completeNodeWeightUpdate(bytes32 nodeId, uint32 messageIndex) external {
        _requireRegisteredOperatorAndNode(msg.sender, nodeId);
        _completeWeightUpdateAndCache(msg.sender, nodeId, messageIndex);
    }

    function completeValidatorRemoval(bytes32 nodeId, uint32 messageIndex) external {
        _requireRegisteredOperatorAndNode(msg.sender, nodeId);
        _completeValidatorRemoval(msg.sender, nodeId, messageIndex);
    }

    /**
     * @notice Slashes an operator's stake
     * @param epoch The epoch of the slash
     * @param operator The operator being slashed
     * @param amount The slash amount
     * @param assetClassId The asset class ID
     */
    function slash(
        uint48 epoch,
        address operator,
        uint256 amount,
        uint96 assetClassId
    ) public onlyOwner updateStakeCache(epoch, assetClassId) {
        uint48 epochStartTs = getEpochStartTs(epoch);

        if (epochStartTs < Time.timestamp() - SLASHING_WINDOW) {
            revert AvalancheL1Middleware__TooOldEpoch();
        }

        uint256 totalOperatorStake = getOperatorStake(operator, epoch, assetClassId);
        if (totalOperatorStake < amount) {
            revert AvalancheL1Middleware__TooBigSlashAmount();
        }

        // Simple pro-rata slash
        for (uint256 i; i < vaults.length(); ++i) {
            (address vault, uint48 enabledTime, uint48 disabledTime) = vaults.atWithTimes(i);
            if (!_wasActiveAt(enabledTime, disabledTime, epochStartTs)) {
                continue;
            }

            if (vaultToAssetClass[vault] != assetClassId) {
                continue;
            }

            uint256 vaultStake = BaseDelegator(IVaultTokenized(vault).delegator()).stakeAt(
                L1_VALIDATOR_MANAGER, assetClassId, operator, epochStartTs, new bytes(0)
            );

            if (vaultStake == 0) continue;

            uint256 slashAmt = (amount * vaultStake) / totalOperatorStake;
            _slashVault(epochStartTs, vault, uint8(assetClassId), operator, slashAmt);
        }
    }

    /**
     * @notice Calculates and caches total stake for an epoch
     * @param epoch The epoch number
     * @param assetClassId The asset class ID
     * @return totalStake The total stake calculated and cached
     */
    function calcAndCacheStakes(uint48 epoch, uint96 assetClassId) public returns (uint256 totalStake) {
        uint48 epochStartTs = getEpochStartTs(epoch);

        // Check for too-old epoch: note that if Time.timestamp() < SLASHING_WINDOW this subtraction underflows.
        if (epochStartTs < Time.timestamp() - SLASHING_WINDOW) {
            revert AvalancheL1Middleware__TooOldEpoch();
        }
        if (epochStartTs > Time.timestamp()) {
            revert AvalancheL1Middleware__InvalidEpoch();
        }

        for (uint256 i; i < operators.length(); ++i) {
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
     * @notice Caches manager-based weight for each node of `operator` in epoch `currentEpoch`.
     * @param operator The operator address
     */
    function calcAndCacheNodeWeightsForOperator(
        address operator
    ) public {
        uint48 currentEpoch = getCurrentEpoch();
        uint48 previousEpoch = currentEpoch == 0 ? 0 : currentEpoch - 1;

        bytes32[] storage nodesArr = operatorNodesArray[operator];
        for (uint256 i = 0; i < nodesArr.length; i++) {
            bytes32 nodeId = nodesArr[i];
            bytes32 valId = getCurrentValidationID(nodeId);
            // If no pending update, carry over previous weight to current epoch
            // Should be replaced with checkpoints
            if (nodeWeightCache[currentEpoch][valId] == 0) {
                nodeWeightCache[currentEpoch][valId] = nodeWeightCache[previousEpoch][valId];
            }
            if (
                !nodePendingUpdate[valId]
                    || (
                        !nodePendingCompletedUpdate[previousEpoch][valId] && nodePendingCompletedUpdate[currentEpoch][valId]
                    )
            ) {
                continue;
            }
            Validator memory validator = balancerValidatorManager.getValidator(valId);

            if (
                validator.status == ValidatorStatus.Active
                    && !balancerValidatorManager.isValidatorPendingWeightUpdate(valId)
            ) {
                if (nodePendingCompletedUpdate[previousEpoch][valId]) {
                    _updateNode(operator, nodeId, valId);
                } else {
                    _enableNode(operator, nodeId, valId);
                }
            } else if (validator.status == ValidatorStatus.Completed) {
                _disableNode(operator, nodeId, valId);
            }
        }
    }

    /**
     * @notice Sets a vault's max L1 stake limit
     * @param vault The vault address
     * @param assetClassId The asset class ID
     * @param amount The new maximum stake
     */
    function _setVaultMaxL1Limit(address vault, uint96 assetClassId, uint256 amount) internal onlyOwner {
        if (!IRegistry(VAULT_REGISTRY).isEntity(vault)) {
            revert AvalancheL1Middleware__NotVault();
        }
        if (!_isActiveAssetClass(assetClassId)) {
            revert AvalancheL1Middleware__AssetClassNotActive();
        }
        address vaultCollateral = IVaultTokenized(vault).collateral();
        if (!assetClasses[assetClassId].assets.contains(vaultCollateral)) {
            revert AvalancheL1Middleware__CollateralNotInAssetClass();
        }
        address delegator = IVaultTokenized(vault).delegator();
        BaseDelegator(delegator).setMaxL1Limit(L1_VALIDATOR_MANAGER, assetClassId, amount);
    }

    /**
     * @notice Remove a node => end its validator. Checks still to be done.
     * @param nodeId The node ID
     */
    function _removeNode(address operator, bytes32 nodeId) internal {
        _requireRegisteredOperatorAndNode(operator, nodeId);

        bytes32 valId = getCurrentValidationID(nodeId);
        _initializeEndValidationAndFlag(operator, valId, nodeId);
    }

    function _initializeEndValidationAndFlag(address operator, bytes32 validationID, bytes32 nodeId) internal {
        balancerValidatorManager.initializeEndValidation(validationID);
        nodePendingUpdate[validationID] = true;
        // operatorNodes[operator].disable(nodeId); // have to check node removal next epoch
        emit NodeRemoved(operator, nodeId);
    }

    /**
     * @notice Enables a node, updating the operator's locked stake accordingly.
     * @param operator The operator who owns the validator
     * @param nodeId The unique ID of the validator whose registration is being finalized
     * @param valId The unique ID of the validator
     */
    function _enableNode(address operator, bytes32 nodeId, bytes32 valId) internal {
        (uint48 enabledTime,) = operatorNodes[operator].getTimes(nodeId);
        Validator memory validator = balancerValidatorManager.getValidator(valId);
        uint48 currentEpoch = getCurrentEpoch();
        uint48 effectiveEpoch = getEpochAtTs(uint48(validator.startedAt));

        if (enabledTime == 0 && effectiveEpoch < currentEpoch) {
            operatorNodes[operator].enable(nodeId);
            operatorLockedStake[operator] -= nodePendingWeight[valId];
            nodeWeightCache[currentEpoch][valId] = nodePendingWeight[valId];
            nodePendingWeight[valId] = 0;
            nodePendingUpdate[valId] = false;
        } else if (enabledTime == 0 && effectiveEpoch == currentEpoch) {
            // if the node was added in the current epoch, calcAndCacheNodeWeightsForOperator will update the cache in the next epoch
            return;
        } else {
            revert AvalancheL1Middleware__NodeStateNotUpdated();
        }
    }

    /**
     * @notice Disables a node, updating the operator's locked stake accordingly.
     * @param operator The operator who owns the validator
     * @param nodeId The unique ID of the validator whose registration is being finalized
     * @param valId The unique ID of the validator
     */
    function _disableNode(address operator, bytes32 nodeId, bytes32 valId) internal {
        (uint48 enabledTime, uint48 disabledTime) = operatorNodes[operator].getTimes(nodeId);
        Validator memory validator = balancerValidatorManager.getValidator(valId);
        uint48 currentEpoch = getCurrentEpoch();
        uint48 endEpoch = uint48(validator.endedAt) > 0 ? getEpochAtTs(uint48(validator.endedAt)) : 0;
        // uint48 effectiveEpoch = getEpochAtTs(uint48(validator.endedAt));

        if (enabledTime != 0 && disabledTime == 0 && endEpoch < currentEpoch) {
            operatorNodes[operator].disable(nodeId);
            nodeWeightCache[currentEpoch][valId] = 0;
            nodePendingUpdate[valId] = false;
            nodePendingWeight[valId] = 0;
            _removeNodeFromArray(operator, nodeId);
        } else if (enabledTime != 0 && disabledTime == 0 && endEpoch == currentEpoch) {
            // if the node was removed in the current epoch, calcAndCacheNodeWeightsForOperator will update the cache in the next epoch
            return;
        } else {
            revert AvalancheL1Middleware__NodeStateNotUpdated();
        }
    }

    /**
     * @notice Updates the weight of nodes
     * @param operator The operator address
     * @param nodeId The node ID
     * @param valId The validation ID
     */
    function _updateNode(address operator, bytes32 nodeId, bytes32 valId) internal {
        (uint48 enabledTime, uint48 disabledTime) = operatorNodes[operator].getTimes(nodeId);
        Validator memory validator = balancerValidatorManager.getValidator(valId);
        uint48 currentEpoch = getCurrentEpoch();

        uint256 oldConfirmed = getEffectiveNodeWeight(currentEpoch, valId);
        uint256 finalWeight = nodePendingWeight[valId];
        if (
            validator.status == ValidatorStatus.Active && enabledTime != 0 && disabledTime == 0
                && nodePendingUpdate[valId]
        ) {
            if (finalWeight < oldConfirmed) {
                // no lock should happen, it's locked in the cache
                // uint256 delta = oldConfirmed - finalWeight;
                // operatorLockedStake[operator] -= delta;
            } else if (finalWeight > oldConfirmed) {
                uint256 delta = finalWeight - oldConfirmed;
                operatorLockedStake[operator] -= delta;
            }
            nodeWeightCache[currentEpoch][valId] = finalWeight;
            nodePendingUpdate[valId] = false;
            nodePendingWeight[valId] = 0;
            nodePendingCompletedUpdate[currentEpoch][valId] = false;
        }
    }

    /**
     * @notice Remove the node from the dynamic array (swap and pop).
     * @param nodeId The node ID.
     */
    function _removeNodeFromArray(address operator, bytes32 nodeId) internal {
        bytes32[] storage arr = operatorNodesArray[operator];
        // Find the node index by looping (O(n)), then swap+pop
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == nodeId) {
                uint256 lastIndex = arr.length - 1;
                if (i != lastIndex) {
                    arr[i] = arr[lastIndex];
                }
                arr.pop();
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
    function _completeValidatorRegistration(address operator, bytes32 nodeId, uint32 messageIndex) internal {
        _requireRegisteredOperatorAndNode(operator, nodeId);
        balancerValidatorManager.completeValidatorRegistration(messageIndex);
    }

    /**
     * @notice Completes a validator's removal.
     * @param operator The operator who owns the validator
     * @param nodeId The unique ID of the validator whose removal is being finalized
     * @param messageIndex The message index from the BalancerValidatorManager (used for ordering/verification)
     */
    function _completeValidatorRemoval(address operator, bytes32 nodeId, uint32 messageIndex) internal {
        _requireRegisteredOperatorAndNode(operator, nodeId);
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
    function _completeWeightUpdateAndCache(address operator, bytes32 nodeId, uint32 messageIndex) internal {
        _requireRegisteredOperatorAndNode(operator, nodeId);
        bytes32 valId = getCurrentValidationID(nodeId);

        if (!balancerValidatorManager.isValidatorPendingWeightUpdate(valId)) {
            revert AvalancheL1Middleware__WeightUpdateNotPending();
        }
        nodePendingCompletedUpdate[getCurrentEpoch()][valId] = true;
        // if the completeValidatorWeightUpdate fails, not sure if the previous bool is secure.
        balancerValidatorManager.completeValidatorWeightUpdate(valId, messageIndex);
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
        // Shouldn't be pending at thiss stage
        if (balancerValidatorManager.isValidatorPendingWeightUpdate(validationID)) {
            revert AvalancheL1Middleware__WeightUpdatePending();
        }

        if (newWeight > cachedWeight) {
            uint256 delta = newWeight - cachedWeight;
            if (delta > _getOperatorAvailableStake(operator)) {
                revert AvalancheL1Middleware__NotEnoughFreeStake();
            }
            operatorLockedStake[operator] += delta;
        } else if (newWeight < cachedWeight) {
            // no lock should happen, it's locked in the cache
        }
        balancerValidatorManager.initializeValidatorWeightUpdate(validationID, stakeToWeight(newWeight));
        nodePendingUpdate[validationID] = true;
        nodePendingWeight[validationID] = newWeight;
        // Does not update nodeWeightCache immediately, it will be updated in _completeWeightUpdateAndCache.
    }

    function _requireRegisteredOperatorAndNode(address operator, bytes32 nodeId) internal view {
        if (!operators.contains(operator)) {
            revert AvalancheL1Middleware__OperatorNotRegistered();
        }
        if (!operatorNodes[operator].contains(nodeId)) {
            revert AvalancheL1Middleware__NodeNotFound();
        }
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
            console2.log("stake", stake);
            console2.log("nodeCount", nodeCount);
            console2.log("minValidatorStake", assetClasses[classId].minValidatorStake);
            // Check ratio vs. class's min stake
            if (stake / (nodeCount + extraNode) < assetClasses[classId].minValidatorStake) {
                return false;
                // revert AvalancheL1Middleware__NotEnoughSecondaryAssetClasses();
            }
        }
        return true;
    }

    /**
     * @notice Convert a full 256-bit stake amount into a 64-bit weight
     * @dev Anything < WEIGHT_SCALE_FACTOR becomes 0
     */
    function stakeToWeight(
        uint256 stakeAmount
    ) public pure returns (uint64) {
        uint256 weight = stakeAmount / WEIGHT_SCALE_FACTOR;
        require(weight <= type(uint64).max, "Overflow in stakeToWeight");
        return uint64(weight);
    }

    /**
     * @notice Convert a 64-bit weight back into its 256-bit stake amount
     */
    function weightToStake(
        uint64 weight
    ) public pure returns (uint256) {
        // Multiply by the same scale factor to recover the original stake
        return uint256(weight) * WEIGHT_SCALE_FACTOR;
    }

    /**
     * @notice Helper that slashes a vault based on slasher type and if it's initialized
     * @param timestamp The epoch start timestamp
     * @param vault The vault address
     * @param assetClass The asset class ID
     * @param operator The operator address
     * @param amount The slash amount
     */
    function _slashVault(uint48 timestamp, address vault, uint8 assetClass, address operator, uint256 amount) private {
        if (!IVaultTokenized(vault).isSlasherInitialized()) {
            revert AvalancheL1Middleware__NoSlasher();
        }
        address slasher = IVaultTokenized(vault).slasher();
        uint256 slasherType = IEntity(slasher).TYPE();
        if (slasherType == INSTANT_SLASHER_TYPE) {
            ISlasher(slasher).slash(L1_VALIDATOR_MANAGER, assetClass, operator, amount, timestamp, new bytes(0));
        } else if (slasherType == VETO_SLASHER_TYPE) {
            IVetoSlasher(slasher).requestSlash(
                L1_VALIDATOR_MANAGER, assetClass, operator, amount, timestamp, new bytes(0)
            );
        } else {
            revert AvalancheL1Middleware__UnknownSlasherType();
        }
    }

    /**
     * @notice Fetches the primary and secondary asset classes
     * @return primary The primary asset class
     * @return secondaries An array of secondary asset classes
     */
    function getActiveAssetClasses() external view returns (uint256 primary, uint256[] memory secondaries) {
        primary = PRIMARY_ASSET_CLASS;
        secondaries = secondaryAssetClasses.values();
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
     * @notice Gets the start timestamp for a given epoch
     * @param epoch The epoch number
     * @return timestamp The start time of that epoch
     */
    function getEpochStartTs(
        uint48 epoch
    ) public view returns (uint48 timestamp) {
        return START_TIME + epoch * EPOCH_DURATION;
    }

    /**
     * @notice Gets the epoch number at a given timestamp
     * @param timestamp The timestamp
     * @return epoch The epoch at that time
     */
    function getEpochAtTs(
        uint48 timestamp
    ) public view returns (uint48 epoch) {
        return (timestamp - START_TIME) / EPOCH_DURATION;
    }

    /**
     * @notice Gets the current epoch based on the current block time
     * @return epoch The current epoch
     */
    function getCurrentEpoch() public view returns (uint48 epoch) {
        return getEpochAtTs(Time.timestamp());
    }

    function getEpochDuration() public view returns (uint48) {
        return EPOCH_DURATION;
    }

    /**
     * @notice Returns an operator's stake at a given epoch for a specific asset class
     * @param operator The operator address
     * @param epoch The epoch number
     * @param assetClassId The asset class ID
     * @return stake The operator's stake
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

        for (uint256 i; i < vaults.length(); ++i) {
            (address vault, uint48 enabledTime, uint48 disabledTime) = vaults.atWithTimes(i);

            // Skip if vault not active in the target epoch
            if (!_wasActiveAt(enabledTime, disabledTime, epochStartTs)) {
                continue;
            }

            // Skip if vault asset not in AssetClassID
            if (vaultToAssetClass[vault] != assetClassId) {
                continue;
            }

            uint256 vaultStake = BaseDelegator(IVaultTokenized(vault).delegator()).stakeAt(
                L1_VALIDATOR_MANAGER, assetClassId, operator, epochStartTs, new bytes(0)
            );

            stake += vaultStake;
        }
    }

    /**
     * @notice Returns total stake across all operators in a specific epoch
     * @param epoch The epoch number
     * @param assetClassId The asset class ID
     * @return The total stake in that epoch
     */
    function getTotalStake(uint48 epoch, uint96 assetClassId) public view returns (uint256) {
        if (totalStakeCached[epoch][assetClassId]) {
            return totalStakeCache[epoch][assetClassId];
        }
        return _calcTotalStake(epoch, assetClassId);
    }

    /**
     * @notice Returns operator data (stake and key) for an epoch
     * @param epoch The epoch number
     * @param assetClassId The asset class ID
     * @return operatorsData An array of OperatorData (stake and key)
     */
    function getOperatorSet(
        uint48 epoch,
        uint96 assetClassId
    ) public view returns (OperatorData[] memory operatorsData) {
        uint48 epochStartTs = getEpochStartTs(epoch);

        operatorsData = new OperatorData[](operators.length());
        uint256 valIdx = 0;

        for (uint256 i; i < operators.length(); ++i) {
            (address operator, uint48 enabledTime, uint48 disabledTime) = operators.atWithTimes(i);

            if (!_wasActiveAt(enabledTime, disabledTime, epochStartTs)) {
                continue;
            }

            uint256 stake = getOperatorStake(operator, epoch, assetClassId);
            if (stake == 0) {
                continue;
            }
        }

        // shrink array to skip unused slots
        /// @solidity memory-safe-assembly
        assembly {
            mstore(operatorsData, valIdx)
        }
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
        if (epochStartTs < Time.timestamp() - SLASHING_WINDOW) {
            revert AvalancheL1Middleware__TooOldEpoch();
        }
        if (epochStartTs > Time.timestamp()) {
            revert AvalancheL1Middleware__InvalidEpoch();
        }

        for (uint256 i; i < operators.length(); ++i) {
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

    /**
     * @notice Returns the cached stake for a given node in the specified epoch, based on its Validation ID.
     * @param epoch The target Not enough free stake to add nodeepoch.
     * @param validationId The node ID.
     * @return The node stake from the cache.
     */
    function getNodeStake(uint48 epoch, bytes32 validationId) external view returns (uint256) {
        return nodeWeightCache[epoch][validationId];
    }

    /**
     * @notice Returns the current epoch number
     * @param operator The operator address
     * @param epoch The epoch number
     * @return activeNodeIds The list of nodes
     */
    function getActiveNodesForEpoch(
        address operator,
        uint48 epoch
    ) external view returns (bytes32[] memory activeNodeIds) {
        uint48 epochStartTs = getEpochStartTs(epoch);

        // iterates over operator enumerable to find active nodes
        uint256 length = operatorNodes[operator].length();
        uint256 activeCount;

        // Count how many nodes were active at epochStartTs
        for (uint256 i = 0; i < length; i++) {
            (, uint48 enabledTime, uint48 disabledTime) = operatorNodes[operator].atWithTimes(i);

            if (_wasActiveAt(enabledTime, disabledTime, epochStartTs)) {
                activeCount++;
            }
        }

        // Collect them into the result array
        activeNodeIds = new bytes32[](activeCount);
        uint256 idx;
        for (uint256 i = 0; i < length; i++) {
            (bytes32 nodeId, uint48 enabledTime, uint48 disabledTime) = operatorNodes[operator].atWithTimes(i);

            if (_wasActiveAt(enabledTime, disabledTime, epochStartTs)) {
                activeNodeIds[idx++] = nodeId;
            }
        }
        return activeNodeIds;
    }

    /**
     * @notice Returns the available stake for an operator
     * @param operator The operator address
     * @return The available stake
     */
    function getOperatorAvailableStake(
        address operator
    ) external view returns (uint256) {
        return _getOperatorAvailableStake(operator);
    }

    /**
     * @notice Summation of node stakes from the nodeWeightCache.
     * @param operator The operator address.
     * @return registeredStake The sum of node stakes.
     */
    function getOperatorUsedWeightCached(
        address operator
    ) public view returns (uint256 registeredStake) {
        bytes32[] storage nodesArr = operatorNodesArray[operator];
        for (uint256 i = 0; i < nodesArr.length; i++) {
            bytes32 nodeId = nodesArr[i];
            bytes32 valId = getCurrentValidationID(nodeId);
            registeredStake += getEffectiveNodeWeight(getCurrentEpoch(), valId);
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
        return totalStake - operatorLockedStake[operator];
    }
}
