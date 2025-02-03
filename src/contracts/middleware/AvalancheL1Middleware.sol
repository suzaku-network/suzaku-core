// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

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
import {IBaseSlasher} from "../../interfaces/slasher/IBaseSlasher.sol";
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
import {IBalancerValidatorManager} from
    "@suzaku/contracts-library/interfaces/ValidatorManager/IBalancerValidatorManager.sol";
import {BalancerValidatorManager} from
    "@suzaku/contracts-library/contracts/ValidatorManager/BalancerValidatorManager.sol";

import {SimpleKeyRegistry32} from "./SimpleKeyRegistry32.sol";
import {MapWithTimeData} from "./libraries/MapWithTimeData.sol";
import {SimpleNodeRegistry32} from "./SimpleNodeRegistry32.sol";
import {MapWithTimeDataBytes32} from "./libraries/MapWithTimeDataBytes32.sol";

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

    error AvalancheL1Middleware__ActiveSecondaryAssetCLass();
    error AvalancheL1Middleware__AssetClassNotActive();
    error AvalancheL1Middleware__AssetIsPrimaryAsset();
    error AvalancheL1Middleware__AssetStillInUse();
    error AvalancheL1Middleware__CollateralNotInAssetClass();
    error AvalancheL1Middleware__InvalidEpoch();
    error AvalancheL1Middleware__MaxL1LimitZero();
    error AvalancheL1Middleware__NoSlasher();
    error AvalancheL1Middleware__NotOperator();
    error AvalancheL1Middleware__NotVault();
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
    error AvalancheL1Middleware__IncorrectValidatorMaxStake();
    error AvalancheL1Middleware__IncorrectValidatorMinStake();
    error AvalancheL1Middleware__NodeWeightNotCached();

    // added
    event NodeAdded(
        address indexed operator, bytes32 indexed nodeId, bytes blsKey, uint256 stake, bytes32 validationID
    );
    event NodeRemoved(address indexed operator, bytes32 indexed nodeId);
    event NodeForceRemoved(address indexed operator);
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

    BalancerValidatorManager balancerValidatorManager;

    EnumerableSet.UintSet private secondaryAssetClasses;

    EnumerableMap.AddressToUintMap private operators;
    EnumerableMap.AddressToUintMap private vaults;

    mapping(uint48 => mapping(uint96 => uint256)) public totalStakeCache;
    mapping(uint48 => mapping(uint96 => bool)) public totalStakeCached;
    mapping(address => uint96) public vaultToAssetClass;

    // added
    // For time-based enable/disable
    mapping(address => EnumerableMap.Bytes32ToUintMap) private operatorNodes;
    // For node indexing
    mapping(address => bytes32[]) private operatorNodesArray;           // dynamic array for stable index
    // mapping(address => NodeInfo[]) private operatorNodes;
    mapping(uint48 => mapping(uint96 => mapping(address => uint256))) public operatorStakeCache;
    mapping(address => mapping(uint48 => bool)) private rebalancedThisEpoch;
    mapping(uint48 => mapping(bytes32 => uint256)) public nodeWeightCache;
    mapping(uint48 => mapping(bytes32 => bool)) public nodeWeightCached;

    // Local stake accounting (reserved stake)
    mapping(address => uint256) public operatorAvailableStake;
    mapping(address => uint256) public operatorLockedStake;


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
     * @notice Activates a secondary asset class
     * @param assetClassId The asset class ID to activate
     */
    function activateSecondaryAssetClass(uint256 assetClassId) external onlyOwner {
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
    function deactivateSecondaryAssetClass(uint256 assetClassId) external onlyOwner {
        if (!secondaryAssetClasses.contains(assetClassId)) {
            revert AssetClassRegistry__AssetClassNotFound();
        }

        if (_isUsedAssetClass(assetClassId)) {
            revert AvalancheL1Middleware__AssetStillInUse();
        }

        secondaryAssetClasses.remove(assetClassId);
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
    function _isActiveAssetClass(uint256 assetClassId) internal view returns (bool) {
        return (assetClassId == PRIMARY_ASSET_CLASS || secondaryAssetClasses.contains(assetClassId));
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
    function removeAssetClass(uint256 assetClassId) external override {
        if (secondaryAssetClasses.contains(assetClassId)) {
            revert AvalancheL1Middleware__ActiveSecondaryAssetCLass();
        }

        _removeAssetClass(assetClassId);
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
    function _isUsedAssetClass(uint256 assetClassId) internal view returns (bool) {
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
    function getEpochStartTs(uint48 epoch) public view returns (uint48 timestamp) {
        return START_TIME + epoch * EPOCH_DURATION;
    }

    /**
     * @notice Gets the epoch number at a given timestamp
     * @param timestamp The timestamp
     * @return epoch The epoch at that time
     */
    function getEpochAtTs(uint48 timestamp) public view returns (uint48 epoch) {
        return (timestamp - START_TIME) / EPOCH_DURATION;
    }

    /**
     * @notice Gets the current epoch based on the current block time
     * @return epoch The current epoch
     */
    function getCurrentEpoch() public view returns (uint48 epoch) {
        return getEpochAtTs(Time.timestamp());
    }

    /**
     * @notice Registers a new operator and enables it
     * @param operator The operator address
     * @param key Operator's key
     */
    function registerOperator(address operator, bytes32 key) external onlyOwner {
        if (operators.contains(operator)) {
            revert AvalancheL1Middleware__OperatorAlreadyRegistered();
        }
        if (!IOperatorRegistry(OPERATOR_REGISTRY).isRegistered(operator)) {
            revert AvalancheL1Middleware__NotOperator();
        }
        if (!IOptInService(OPERATOR_L1_OPTIN).isOptedIn(operator, L1_VALIDATOR_MANAGER)) {
            revert AvalancheL1Middleware__OperatorNotOptedIn();
        }

        // updateKey(operator, key);
        operators.add(operator);
        operators.enable(operator);
    }

    /**
     * @notice Disables an operator
     * @param operator The operator address
     */
    function disableOperator(address operator) external onlyOwner {
        operators.disable(operator);
    }

    /**
     * @notice Enables an operator
     * @param operator The operator address
     */
    function enableOperator(address operator) external onlyOwner {
        operators.enable(operator);
    }

    /**
     * @notice Removes an operator if grace period has passed
     * @param operator The operator address
     */
    function removeOperator(address operator) external onlyOwner {
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
    function removeVault(address vault) external onlyOwner {
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
            return operatorStakeCache[epoch][assetClassId][operator];
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

            stake += BaseDelegator(IVaultTokenized(vault).delegator()).stakeAt(
                L1_VALIDATOR_MANAGER, assetClassId, operator, epochStartTs, new bytes(0)
            );
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

            // bytes32 key = getOperatorKeyAt(operator, epochStartTs);
            // if (key == bytes32(0)) {
            //     continue;
            // }

            uint256 stake = getOperatorStake(operator, epoch, assetClassId);
            if (stake == 0) {
                continue;
            }

            // operatorsData[valIdx++] = OperatorData(stake, key);
        }

        // shrink array to skip unused slots
        /// @solidity memory-safe-assembly
        assembly {
            mstore(operatorsData, valIdx)
        }
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

        // for epoch older than SLASHING_WINDOW total stake can be invalidated (use cache)
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

    // --- Helper: getEffectiveNodeWeight ---
    // Returns the confirmed weight (from cache). Until an async update completes,
    // rebalancing functions use the confirmed (cached) value.
    function getEffectiveNodeWeight(uint48 epoch, bytes32 validationID) internal view returns (uint256) {
        return nodeWeightCache[epoch][validationID];
    }

    /**
     * @notice Add a new node => create a new validator.
     * Check the new node stake also ensure security module capacity.
     * @param nodeId The node ID
     * @param blsKey The BLS key
     * @param registrationExpiry The Unix timestamp after which the reigistration is no longer valid on the P-Chain
     * @param remainingBalanceOwner The owner of a validator's remaining balance
     * @param disableOwner The owner of a validator's disable owner on the P-Chain
     */
    function addNode(
        bytes32 nodeId,
        bytes calldata blsKey,
        uint64 registrationExpiry,
        PChainOwner calldata remainingBalanceOwner,
        PChainOwner calldata disableOwner
    ) external {
        address operator = msg.sender;
        if (!operators.contains(operator)) {
            revert AvalancheL1Middleware__OperatorNotRegistered();
        }

        uint48 epochNow = getCurrentEpoch();
        if (!totalStakeCached[epochNow][PRIMARY_ASSET_CLASS]) {
            calcAndCacheStakes(epochNow, PRIMARY_ASSET_CLASS);
        }

        _syncOperatorStake(operator);
        uint256 available = operatorAvailableStake[operator];

        if (available < assetClasses[PRIMARY_ASSET_CLASS].minValidatorStake) {
            revert("Not enough free stake to add node");
        }

        uint256 newWeight = (available > assetClasses[PRIMARY_ASSET_CLASS].maxValidatorStake)
            ? assetClasses[PRIMARY_ASSET_CLASS].maxValidatorStake
            : available;
        (uint64 currentModuleWeight, uint64 moduleMaxWeight) =
            balancerValidatorManager.getSecurityModuleWeights(address(this));
        if (currentModuleWeight + newWeight > moduleMaxWeight) {
            uint256 modCapacity = moduleMaxWeight - currentModuleWeight;
            if (modCapacity < assetClasses[PRIMARY_ASSET_CLASS].minValidatorStake) {
                revert("SecurityModule has insufficient capacity for a new node");
            }
            if (newWeight > modCapacity) {
                newWeight = modCapacity;
            }
        }

        ValidatorRegistrationInput memory input = ValidatorRegistrationInput({
            nodeID: abi.encodePacked(nodeId),
            blsPublicKey: blsKey,
            registrationExpiry: registrationExpiry,
            remainingBalanceOwner: remainingBalanceOwner,
            disableOwner: disableOwner
        });
        bytes32 validationID = balancerValidatorManager.initializeValidatorRegistration(input, uint64(newWeight));

        updateNodeKey(nodeId, keccak256(blsKey));
        updateNodeValidationID(nodeId, validationID);

        // Track node in our time-based map a d dynamic array
        operatorNodes[operator].add(nodeId);
        operatorNodes[operator].enable(nodeId);
        operatorNodesArray[operator].push(nodeId);

        // Reserve stake immediately.
        operatorAvailableStake[operator] -= newWeight;
        operatorLockedStake[operator] += newWeight;
        // Immediately cache the node weight (registration is assumed confirmed or will update via external call).
        uint48 epoch = getCurrentEpoch();
        nodeWeightCache[epoch][validationID] = newWeight;
        nodeWeightCached[epoch][validationID] = true;

        emit NodeAdded(operator, nodeId, blsKey, newWeight, validationID);
    }

    /**
     * @notice Remove a node => end its validator. Checks still to be done.
     * @param nodeId The node ID
     */
    function _removeNode(address operator, bytes32 nodeId) internal {
        if (!operators.contains(operator)) {
            revert AvalancheL1Middleware__OperatorNotRegistered();
        }
        // check if node is in the operator's map
        if (!operatorNodes[operator].contains(nodeId)) {
            revert AvalancheL1Middleware__NodeNotFound();
        }

        bytes32 valID = getCurrentValidationID(nodeId);
        _initializeEndValidationAndCache(operator, valID, nodeId);
    }

    /**
     * @notice Force remove node => also calls `updateAllNodeWeights` for that operator
     */
    function forceRemoveNode(address operator) external {
        if (!operators.contains(operator)) {
            revert AvalancheL1Middleware__OperatorNotRegistered();
        }
        bytes32[] storage nodesArr = operatorNodesArray[operator];
        // Loop backwards to safely remove nodes from the dynamic array.
        for (uint256 i = nodesArr.length; i > 0; i--) {
            bytes32 nodeId = nodesArr[i - 1];
            _removeNode(operator, nodeId);
        }
    }

    /**
     * @notice Finalizes node removal if/when manager says it ended.
     * If the validator is indeed ended, remove it from the operator’s node set.
     * @param nodeId The node ID.
     * @param messageIndex The message index.
     */
    function _completeNodeRemoval(address operator, bytes32 nodeId, uint32 messageIndex) internal {
        if (!operatorNodes[operator].contains(nodeId)) {
            revert AvalancheL1Middleware__NodeNotFound();
        }
        balancerValidatorManager.completeEndValidation(messageIndex);

        bytes32 valID = getCurrentValidationID(nodeId);
        Validator memory validator = balancerValidatorManager.getValidator(valID);
        if (validator.status == ValidatorStatus.Completed || validator.status == ValidatorStatus.Invalidated) {
            operatorNodes[operator].remove(nodeId);
            _removeNodeFromArray(operator, nodeId);
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
     * @notice Finalize a pending weight update for the given node.
     * @param nodeId The node ID.
     * @param messageIndex The message index.
     */
    function _completeNodeWeightUpdate(address operator, bytes32 nodeId, uint32 messageIndex) internal {
        if (!operatorNodes[operator].contains(nodeId)) {
            revert AvalancheL1Middleware__NodeNotFound();
        }
        bytes32 valID = getCurrentValidationID(nodeId);
        _completeWeightUpdateAndCache(valID, messageIndex, operator);
    }

    /**
     * @notice Rebalance node weights once per epoch for an operator.
     * @param operator The operator address
     */
    function updateAllNodeWeights(address operator) internal {
        uint48 epochNow = getCurrentEpoch();
        if (rebalancedThisEpoch[operator][epochNow]) {
            return;
        }
        rebalancedThisEpoch[operator][epochNow] = true;

        if (!operators.contains(operator)) {
            revert AvalancheL1Middleware__OperatorNotRegistered();
        }
        if (!totalStakeCached[epochNow][PRIMARY_ASSET_CLASS]) {
            calcAndCacheStakes(epochNow, PRIMARY_ASSET_CLASS);
        }
        uint256 newTotalStake = operatorStakeCache[epochNow][PRIMARY_ASSET_CLASS][operator];

        calcAndCacheNodeWeightsForOperator(operator, epochNow);

        (uint64 securityModuleWeight, uint64 securityModuleMaxWeight) =
            balancerValidatorManager.getSecurityModuleWeights(address(this));
        if (newTotalStake > (securityModuleMaxWeight - securityModuleWeight)) {
            newTotalStake = (securityModuleMaxWeight - securityModuleWeight);
        }

        uint256 registeredWeight;
        bytes32[] storage nodesArr = operatorNodesArray[operator];
        for (uint256 i = 0; i < nodesArr.length; i++) {
            bytes32 nodeId = nodesArr[i];
            bytes32 valID = getCurrentValidationID(nodeId);
            registeredWeight += getEffectiveNodeWeight(epochNow, valID);
        }

        if (newTotalStake == registeredWeight) {
            return;
        } else if (newTotalStake > registeredWeight) {
            uint256 diff = newTotalStake - registeredWeight;
            if (nodesArr.length == 0) {
                emit OperatorHasLeftoverStake(operator, diff);
                return;
            }
            uint256 lastIndex = nodesArr.length - 1;
            bytes32 lastNodeId = nodesArr[lastIndex];
            bytes32 lastValID = getCurrentValidationID(lastNodeId);
            Validator memory lastValidator = balancerValidatorManager.getValidator(lastValID);
            if (
                (lastValidator.status == ValidatorStatus.Active ||
                 lastValidator.status == ValidatorStatus.PendingAdded) &&
                !balancerValidatorManager.isValidatorPendingWeightUpdate(lastValID)
            ) {
                uint256 previousWeight = nodeWeightCache[epochNow][lastValID];
                uint256 capacity = (previousWeight < assetClasses[PRIMARY_ASSET_CLASS].maxValidatorStake)
                    ? (assetClasses[PRIMARY_ASSET_CLASS].maxValidatorStake - previousWeight)
                    : 0;
                if (capacity > 0) {
                    uint256 toAdd = (diff < capacity) ? diff : capacity;
                    uint64 newWeight = uint64(previousWeight + toAdd);
                    diff -= toAdd;
                    _setValidatorWeightAndCache(operator, lastValID, newWeight);
                    emit NodeWeightUpdated(operator, lastNodeId, newWeight);
                }
                if (diff > 0) {
                    emit OperatorHasLeftoverStake(operator, diff);
                }
            } else {
                emit OperatorHasLeftoverStake(operator, diff);
            }
        } else {
            uint256 diff = registeredWeight - newTotalStake;
            for (uint256 i = nodesArr.length; i > 0 && diff > 0;) {
                i--;
                bytes32 nodeId = nodesArr[i];
                bytes32 valID = getCurrentValidationID(nodeId);

                if (balancerValidatorManager.isValidatorPendingWeightUpdate(valID)) {
                    continue;
                }
                Validator memory validator = _getValidator(valID);
                if (validator.status != ValidatorStatus.Active && validator.status != ValidatorStatus.PendingAdded) {
                    continue;
                }
                uint256 previousWeight = nodeWeightCache[epochNow][valID];
                if (previousWeight == 0) continue;

                uint256 toRemove = (diff < previousWeight) ? diff : previousWeight;
                uint256 newWeight = previousWeight - toRemove;
                diff -= toRemove;

                if (newWeight > 0 && newWeight < assetClasses[PRIMARY_ASSET_CLASS].minValidatorStake) {
                    newWeight = 0;
                    _initializeEndValidationAndCache(operator, valID, nodeId);
                } else if (newWeight == 0) {
                    _initializeEndValidationAndCache(operator, valID, nodeId);
                } else {
                    _setValidatorWeightAndCache(operator, valID, uint64(newWeight));
                    emit NodeWeightUpdated(operator, nodeId, newWeight);
                }
            }
        }

        emit AllNodeWeightsUpdated(operator, newTotalStake);
    }

    /**
     * @notice Finalize a pending weight update
     * @param nodeId The node ID
     * @param messageIndex The message index
     */
    function completeNodeWeightUpdate(bytes32 nodeId, uint32 messageIndex) external {
        if (!operatorNodes[msg.sender].contains(nodeId)) {
            revert AvalancheL1Middleware__NodeNotFound();
        }
        _completeNodeWeightUpdate(msg.sender, nodeId, messageIndex);
    }

    /**
     * @notice Caches manager-based weight for each node of `operator` in epoch `epochNow`.
     * @param operator The operator address
     * @param epochNow The current epoch
     */
    function calcAndCacheNodeWeightsForOperator(address operator, uint48 epochNow) public {
        bytes32[] storage nodesArr = operatorNodesArray[operator];
        for (uint256 i = 0; i < nodesArr.length; i++) {
            bytes32 nodeId = nodesArr[i];
            bytes32 valID = getCurrentValidationID(nodeId);
            if (nodeWeightCached[epochNow][valID]) {
                continue;
            }
            Validator memory validator = balancerValidatorManager.getValidator(valID);
            if (validator.status == ValidatorStatus.Active || validator.status == ValidatorStatus.PendingAdded) {
                nodeWeightCache[epochNow][valID] = validator.weight;
            } else {
                nodeWeightCache[epochNow][valID] = 0;
            }
            nodeWeightCached[epochNow][valID] = true;
        }
    }

    /**
     * @notice Summation of node weights from the nodeWeightCache.
     * @param operator The operator address.
     * @param epochNow The current epoch.
     * @return registeredWeight The sum of node weights.
     */
    function getOperatorUsedWeightCached(
        address operator,
        uint48 epochNow
    ) public view returns (uint256 registeredWeight) {
        bytes32[] storage nodesArr = operatorNodesArray[operator];
        for (uint256 i = 0; i < nodesArr.length; i++) {
            bytes32 nodeId = nodesArr[i];
            bytes32 valID = getCurrentValidationID(nodeId);
            registeredWeight += getEffectiveNodeWeight(epochNow, valID);
        }
    }

    function getNodeStake(uint48 epoch, bytes32 nodeId) external view returns (uint256) {
        bytes32 validationID = getCurrentValidationID(nodeId);
        return nodeWeightCache[epoch][validationID];
    }

    function _getValidator(bytes32 validationID) internal view returns (Validator memory) {
        return balancerValidatorManager.getValidator(validationID);
    }

    function _initializeValidatorRegistrationAndCache(
        ValidatorRegistrationInput memory input,
        uint64 weight
    ) internal returns (bytes32 validationID) {
        validationID = balancerValidatorManager.initializeValidatorRegistration(input, weight);
        uint48 epochNow = getCurrentEpoch();
        nodeWeightCache[epochNow][validationID] = weight;
        nodeWeightCached[epochNow][validationID] = true;
    }

    function _setValidatorWeightAndCache(address operator, bytes32 validationID, uint64 newWeight) internal {
        uint48 epochNow = getCurrentEpoch();
        uint256 oldWeight = nodeWeightCache[epochNow][validationID];
        if (newWeight > oldWeight) {
            uint256 delta = newWeight - oldWeight;
            require(operatorAvailableStake[operator] >= delta, "Not enough free stake");
            operatorAvailableStake[operator] -= delta;
            operatorLockedStake[operator] += delta;
        } else if (newWeight < oldWeight) {
            // not release stake until confirmation.
        }
        balancerValidatorManager.initializeValidatorWeightUpdate(validationID, newWeight);
        // Does not update nodeWeightCache immediately, it will be updated in _completeWeightUpdateAndCache.
    }

    function _initializeEndValidationAndCache(address operator, bytes32 validationID, bytes32 nodeId) internal {
        balancerValidatorManager.initializeEndValidation(validationID);
        uint48 epochNow = getCurrentEpoch();
        nodeWeightCache[epochNow][validationID] = 0;
        nodeWeightCached[epochNow][validationID] = true;
        operatorNodes[operator].disable(nodeId);
        emit NodeRemoved(operator, nodeId);
    }

    function _completeWeightUpdateAndCache(bytes32 validationID, uint32 messageIndex, address operator) internal {
        uint48 epochNow = getCurrentEpoch();
        uint256 oldConfirmed = nodeWeightCache[epochNow][validationID];
        balancerValidatorManager.completeValidatorWeightUpdate(validationID, messageIndex);
        uint64 finalWeight = balancerValidatorManager.getValidator(validationID).weight;
        nodeWeightCache[epochNow][validationID] = finalWeight;
        nodeWeightCached[epochNow][validationID] = true;
        if (finalWeight < oldConfirmed) {
            uint256 delta = oldConfirmed - finalWeight;
            operatorLockedStake[operator] -= delta;
            operatorAvailableStake[operator] += delta;
        }
        calcAndCacheNodeWeightsForOperator(operator, epochNow);
    }

    function _syncOperatorStake(address operator) internal {
        uint48 epochNow = getCurrentEpoch();
        uint256 totalStake = getOperatorStake(operator, epochNow, PRIMARY_ASSET_CLASS);
        uint256 available = totalStake - operatorLockedStake[operator];
        if (available < assetClasses[PRIMARY_ASSET_CLASS].minValidatorStake) {
            revert("Not enough free stake to add node");
        }
        require(totalStake >= operatorLockedStake[operator], "Locked stake exceeds total");
        operatorAvailableStake[operator] = available;
    }
}
