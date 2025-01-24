// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

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

// If you have a custom Time library, replace this import accordingly
// import {Time} from "@openzeppelin/contracts/utils/types/Time.sol"; // <-- doesn't exist in OpenZeppelin

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

struct AvalancheL1MiddlewareSettings {
    address l1ValidatorManager;
    address operatorRegistry;
    address vaultRegistry;
    address operatorL1Optin;
    uint48 epochDuration;
    uint48 slashingWindow;
}

struct ValidatorData {
    uint256 stake;
    bytes32 key;
}

// added (keeping NodeInfo minimal: no local stake, no pendingRemoval)
struct NodeInfo {
    bytes32 nodeId;
    bytes blsKey;
    bytes32 validationID;
}

/**
 * @title AvalancheL1Middleware
 * @notice Manages operator registration, vault registration, stake accounting, and slashing for Avalanche L1
 */
contract AvalancheL1Middleware is SimpleKeyRegistry32, Ownable, AssetClassRegistry {
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;
    using MapWithTimeData for EnumerableMap.AddressToUintMap;

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
    error AvalancheL1Middleware__IncorrectNodeMaxStake();
    error AvalancheL1Middleware__IncorrectNodeMinStake();
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

    // NOTE: This Time.timestamp() call must come from your own custom library or replaced with `block.timestamp`
    // e.g. you can define: function _now() internal view returns (uint48) { return uint48(block.timestamp); }
    // and swap out references to Time.timestamp() below.

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
    mapping(address => NodeInfo[]) private operatorNodes;
    mapping(address => uint256) private nodeMaxStake;
    mapping(address => uint256) private nodeMinStake;
    mapping(uint48 => mapping(uint96 => mapping(address => uint256))) public operatorStakeCache;
    mapping(address => mapping(uint48 => bool)) private rebalancedThisEpoch;
    mapping(uint48 => mapping(bytes32 => uint256)) public nodeWeightCache;
    mapping(uint48 => mapping(bytes32 => bool)) public nodeWeightCached;

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
    ) SimpleKeyRegistry32() Ownable(owner) {
        if (settings.slashingWindow < settings.epochDuration) {
            revert AvalancheL1Middleware__SlashingWindowTooShort();
        }

        START_TIME = uint48(block.timestamp); // replaced Time.timestamp() with block.timestamp
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
        return getEpochAtTs(uint48(block.timestamp));
    }

    /**
     * @notice Registers a new operator and enables it
     * @param operator The operator address
     * @param key Operator's key
     */
    function registerOperator(
        address operator,
        bytes32 key,
        uint256 _nodeMaxStake,
        uint256 _nodeMinStake
    ) external onlyOwner {
        if (operators.contains(operator)) {
            revert AvalancheL1Middleware__OperatorAlreadyRegistered();
        }
        if (!IOperatorRegistry(OPERATOR_REGISTRY).isRegistered(operator)) {
            revert AvalancheL1Middleware__NotOperator();
        }
        if (!IOptInService(OPERATOR_L1_OPTIN).isOptedIn(operator, L1_VALIDATOR_MANAGER)) {
            revert AvalancheL1Middleware__OperatorNotOptedIn();
        }
        if (_nodeMaxStake == 0 || _nodeMaxStake >= assetClasses[PRIMARY_ASSET_CLASS].maxValidatorStake) {
            revert AvalancheL1Middleware__IncorrectNodeMaxStake();
        }
        if (_nodeMinStake == 0 || _nodeMinStake <= assetClasses[PRIMARY_ASSET_CLASS].minValidatorStake) {
            revert AvalancheL1Middleware__IncorrectNodeMinStake();
        }

        updateKey(operator, key);
        operators.add(operator);
        operators.enable(operator);

        nodeMaxStake[operator] = _nodeMaxStake;
        nodeMinStake[operator] = _nodeMinStake;
    }

    /**
     * @notice Updates an existing operator's key
     * @param operator The operator address
     * @param key The new key
     */
    function updateOperatorKey(address operator, bytes32 key) external onlyOwner {
        if (!operators.contains(operator)) {
            revert AvalancheL1Middleware__OperatorNotRegistered();
        }
        updateKey(operator, key);
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
        if (disabledTime == 0 || disabledTime + SLASHING_WINDOW > block.timestamp) {
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
        if (disabledTime == 0 || disabledTime + SLASHING_WINDOW > block.timestamp) {
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
     * @notice Returns validator data (stake and key) for an epoch
     * @param epoch The epoch number
     * @param assetClassId The asset class ID
     * @return validatorsData An array of ValidatorData (stake and key)
     */
    function getValidatorSet(
        uint48 epoch,
        uint96 assetClassId
    ) public view returns (ValidatorData[] memory validatorsData) {
        uint48 epochStartTs = getEpochStartTs(epoch);

        validatorsData = new ValidatorData[](operators.length());
        uint256 valIdx = 0;

        for (uint256 i; i < operators.length(); ++i) {
            (address operator, uint48 enabledTime, uint48 disabledTime) = operators.atWithTimes(i);

            if (!_wasActiveAt(enabledTime, disabledTime, epochStartTs)) {
                continue;
            }

            bytes32 key = getOperatorKeyAt(operator, epochStartTs);
            if (key == bytes32(0)) {
                continue;
            }

            uint256 stake = getOperatorStake(operator, epoch, assetClassId);
            if (stake == 0) {
                continue;
            }

            validatorsData[valIdx++] = ValidatorData(stake, key);
        }

        // shrink array to skip unused slots
        /// @solidity memory-safe-assembly
        assembly {
            mstore(validatorsData, valIdx)
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

        if (epochStartTs < block.timestamp - SLASHING_WINDOW) {
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
            // ^ NOTE: if assetClassId can exceed 255, consider using a larger type or revert
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
        if (epochStartTs < block.timestamp - SLASHING_WINDOW) {
            revert AvalancheL1Middleware__TooOldEpoch();
        }
        if (epochStartTs > block.timestamp) {
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
        if (epochStartTs < block.timestamp - SLASHING_WINDOW) {
            revert AvalancheL1Middleware__TooOldEpoch();
        }
        if (epochStartTs > block.timestamp) {
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

    /**
     * @notice Returns an array of NodeInfo for the given operator
     * @param operator The operator address
     * @return nodes An array of NodeInfo
     */
    function getOperatorNodes(address operator) external view returns (NodeInfo[] memory) {
        return operatorNodes[operator];
    }

    /**
     * @notice Add a new node => create a new validator.
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
        uint256 totalOpStake = getOperatorStake(operator, epochNow, uint96(PRIMARY_ASSET_CLASS));

        calcAndCacheNodeWeightsForOperator(operator, epochNow);
        uint256 usedWeight = getOperatorUsedWeightCached(operator, epochNow);

        uint256 available = (totalOpStake > usedWeight) ? (totalOpStake - usedWeight) : 0;
        if (available < nodeMinStake[operator]) {
            revert("Not enough free stake to add node");
        }

        uint256 newWeight = (available > nodeMaxStake[operator]) ? nodeMaxStake[operator] : available;
        (uint64 currentModuleWeight, uint64 moduleMaxWeight) =
            balancerValidatorManager.getSecurityModuleWeights(address(this));
        if (currentModuleWeight + newWeight > moduleMaxWeight) {
            uint256 modCapacity = moduleMaxWeight - currentModuleWeight;
            if (modCapacity < nodeMinStake[operator]) {
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

        operatorNodes[operator].push(NodeInfo({nodeId: nodeId, blsKey: blsKey, validationID: validationID}));
        emit NodeAdded(operator, nodeId, blsKey, newWeight, validationID);
    }

    /**
     * @notice Remove a node => end its validator. Checks still to be done.
     * @param nodeId The node ID
     */
    function removeNode(bytes32 nodeId) external {
        if (!operators.contains(msg.sender)) {
            revert AvalancheL1Middleware__OperatorNotRegistered();
        }
        NodeInfo[] storage nodes = operatorNodes[msg.sender];
        bool found;
        for (uint256 i; i < nodes.length; i++) {
            if (nodes[i].nodeId == nodeId) {
                _initializeEndValidationAndCache(nodes[i].validationID);
                emit NodeRemoved(msg.sender, nodeId);
                found = true;
                break;
            }
        }
        if (!found) {
            revert AvalancheL1Middleware__NodeNotFound();
        }
    }

    /**
     * @notice Force remove node => also calls `updateAllNodeWeights` for that operator
     */
    function forceRemoveNode(address operator) external {
        if (!operators.contains(operator)) {
            revert AvalancheL1Middleware__OperatorNotRegistered();
        }
        emit NodeForceRemoved(operator);
        updateAllNodeWeights(operator);
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

        (uint64 currModWeight, uint64 maxModWeight) = balancerValidatorManager.getSecurityModuleWeights(address(this));
        if (newTotalStake > (maxModWeight - currModWeight)) {
            newTotalStake = (maxModWeight - currModWeight);
        }

        uint256 usedWeight;
        NodeInfo[] storage nodes = operatorNodes[operator];
        for (uint256 i = 0; i < nodes.length; i++) {
            bytes32 vid = nodes[i].validationID;
            if (balancerValidatorManager.isValidatorPendingWeightUpdate(vid)) {
                continue;
            }
            Validator memory val = _getValidator(vid);
            if (val.status == ValidatorStatus.Active || val.status == ValidatorStatus.PendingAdded) {
                usedWeight += nodeWeightCache[epochNow][vid];
            }
        }

        if (newTotalStake == usedWeight) {
            return;
        } else if (newTotalStake > usedWeight) {
            uint256 diff = newTotalStake - usedWeight;
            if (nodes.length == 0) {
                emit OperatorHasLeftoverStake(operator, diff);
                return;
            }
            uint256 lastIndex = nodes.length - 1;
            bytes32 lastValID = nodes[lastIndex].validationID;
            Validator memory lastVal = _getValidator(lastValID);
            if (
                (lastVal.status == ValidatorStatus.Active || lastVal.status == ValidatorStatus.PendingAdded)
                    && !balancerValidatorManager.isValidatorPendingWeightUpdate(lastValID)
            ) {
                uint256 oldW = nodeWeightCache[epochNow][lastValID];
                uint256 capacity = (oldW < nodeMaxStake[operator]) ? (nodeMaxStake[operator] - oldW) : 0;
                if (capacity > 0) {
                    uint256 toAdd = (diff < capacity) ? diff : capacity;
                    uint64 newW = uint64(oldW + toAdd);
                    diff -= toAdd;

                    _setValidatorWeightAndCache(lastValID, newW);
                    emit NodeWeightUpdated(operator, nodes[lastIndex].nodeId, newW);
                }
                if (diff > 0) {
                    emit OperatorHasLeftoverStake(operator, diff);
                }
            } else {
                emit OperatorHasLeftoverStake(operator, diff);
            }
        } else {
            uint256 diff = usedWeight - newTotalStake;
            for (uint256 i = nodes.length; i > 0 && diff > 0;) {
                i--;
                bytes32 vid = nodes[i].validationID;
                if (balancerValidatorManager.isValidatorPendingWeightUpdate(vid)) {
                    continue;
                }
                Validator memory val = _getValidator(vid);
                if (val.status != ValidatorStatus.Active && val.status != ValidatorStatus.PendingAdded) {
                    continue;
                }
                uint256 oldW = nodeWeightCache[epochNow][vid];
                if (oldW == 0) continue;

                uint256 toRemove = (diff < oldW) ? diff : oldW;
                uint256 newW = oldW - toRemove;
                diff -= toRemove;

                if (newW > 0 && newW < nodeMinStake[operator]) {
                    newW = 0;
                    _initializeEndValidationAndCache(vid);
                    emit NodeRemoved(operator, nodes[i].nodeId);
                } else if (newW == 0) {
                    _initializeEndValidationAndCache(vid);
                    emit NodeRemoved(operator, nodes[i].nodeId);
                } else {
                    _setValidatorWeightAndCache(vid, uint64(newW));
                    emit NodeWeightUpdated(operator, nodes[i].nodeId, newW);
                }
            }
        }

        emit AllNodeWeightsUpdated(operator, newTotalStake);
    }

    /**
     * @notice Finalizes node removal if manager says it's ended
     * @param nodeId The node ID
     */
    function completeNodeRemoval(bytes32 nodeId, uint32 messageIndex) external {
        NodeInfo[] storage nodes = operatorNodes[msg.sender];
        bool found;
        uint256 idx;
        for (uint256 i; i < nodes.length; i++) {
            if (nodes[i].nodeId == nodeId) {
                found = true;
                idx = i;
                break;
            }
        }
        if (!found) {
            revert AvalancheL1Middleware__NodeNotFound();
        }

        balancerValidatorManager.completeEndValidation(messageIndex);
        Validator memory validator = _getValidator(nodes[idx].validationID);
        if (validator.status == ValidatorStatus.Completed || validator.status == ValidatorStatus.Invalidated) {
            uint256 length = nodes.length;
            nodes[idx] = nodes[length - 1];
            nodes.pop();
        }
    }

    /**
     * @notice Finalize a pending weight update
     * @param nodeId The node ID
     * @param messageIndex The message index
     */
    function completeNodeWeightUpdate(bytes32 nodeId, uint32 messageIndex) external {
        NodeInfo[] storage nodes = operatorNodes[msg.sender];
        bool found;
        uint256 idx;
        for (uint256 i; i < nodes.length; i++) {
            if (nodes[i].nodeId == nodeId) {
                found = true;
                idx = i;
                break;
            }
        }
        if (!found) {
            revert AvalancheL1Middleware__NodeNotFound();
        }

        // Added lines for refreshing nodeWeightCache after finalization
        _completeWeightUpdateAndCache(nodes[idx].validationID, messageIndex, msg.sender);
    }

    /**
     * @notice Caches manager-based weight for each node of `operator` in epoch `epochNow`.
     * @param operator The operator address
     * @param epochNow The current epoch
     */
    function calcAndCacheNodeWeightsForOperator(address operator, uint48 epochNow) public {
        NodeInfo[] storage nodes = operatorNodes[operator];
        for (uint256 i = 0; i < nodes.length; i++) {
            bytes32 valID = nodes[i].validationID;
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
     * @notice Summation of node weights from the nodeWeightCache
     * @param operator The operator address
     * @param epochNow The current epoch
     * @return usedWeight The sum of node weights
     */
    function getOperatorUsedWeightCached(address operator, uint48 epochNow) public view returns (uint256 usedWeight) {
        NodeInfo[] storage nodes = operatorNodes[operator];
        for (uint256 i = 0; i < nodes.length; i++) {
            bytes32 valID = nodes[i].validationID;
            if (nodeWeightCached[epochNow][valID]) {
                usedWeight += nodeWeightCache[epochNow][valID];
            }
        }
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

    function _setValidatorWeightAndCache(bytes32 validationID, uint64 newWeight) internal {
        balancerValidatorManager.initializeValidatorWeightUpdate(validationID, newWeight);
        uint48 epochNow = getCurrentEpoch();
        nodeWeightCache[epochNow][validationID] = newWeight;
        nodeWeightCached[epochNow][validationID] = true;
    }

    function _initializeEndValidationAndCache(bytes32 validationID) internal {
        balancerValidatorManager.initializeEndValidation(validationID);
        uint48 epochNow = getCurrentEpoch();
        nodeWeightCache[epochNow][validationID] = 0;
        nodeWeightCached[epochNow][validationID] = true;
    }

    // Added operator param to refresh nodeWeightCache in the same epoch
    function _completeWeightUpdateAndCache(bytes32 validationID, uint32 messageIndex, address operator) internal {
        balancerValidatorManager.completeValidatorWeightUpdate(validationID, messageIndex);
        uint48 epochNow = getCurrentEpoch();
        uint64 finalW = balancerValidatorManager.getValidator(validationID).weight;
        nodeWeightCache[epochNow][validationID] = finalW;
        nodeWeightCached[epochNow][validationID] = true;

        // Added lines for refreshing nodeWeightCache after finalization
        // So if the operator's node weight changed within this epoch, re-run caching so it's not stale.
        calcAndCacheNodeWeightsForOperator(operator, epochNow);
    }
}
