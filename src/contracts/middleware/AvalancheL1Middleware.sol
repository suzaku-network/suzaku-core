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
import {IEntity} from "../../interfaces/common/IEntity.sol";
import {ISlasher} from "../../interfaces/slasher/ISlasher.sol";
import {IVetoSlasher} from "../../interfaces/slasher/IVetoSlasher.sol";

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

contract AvalancheL1Middleware is SimpleKeyRegistry32, Ownable, AssetClassRegistry {
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;
    using MapWithTimeData for EnumerableMap.AddressToUintMap;

    error AvalancheL1Middleware__NotOperator();
    error AvalancheL1Middleware__NotVault();
    error AvalancheL1Middleware__OperatorNotOptedIn();
    error AvalancheL1Middleware__OperatorNotRegistered();
    error AvalancheL1Middleware__OperarorGracePeriodNotPassed();
    error AvalancheL1Middleware__OperatorAlreadyRegistered();
    error AvalancheL1Middleware__VaultAlreadyRegistered();
    error AvalancheL1Middleware__VaultEpochTooShort();
    error AvalancheL1Middleware__VaultGracePeriodNotPassed();
    error AvalancheL1Middleware__TooOldEpoch();
    error AvalancheL1Middleware__InvalidEpoch();
    error AvalancheL1Middleware__SlashingWindowTooShort();
    error AvalancheL1Middleware__TooBigSlashAmount();
    error AvalancheL1Middleware__UnknownSlasherType();
    error AvalancheL1Middleware__CollateralNotInAssetClass();
    error AvalancheL1Middleware__AssetClassNotActive();
    error AvalancheL1Middleware__NoSlasher();

    address public immutable L1_VALIDATOR_MANAGER;
    address public immutable OPERATOR_REGISTRY;
    address public immutable VAULT_REGISTRY;
    address public immutable OPERATOR_L1_OPTIN;
    address public immutable OWNER;
    uint48 public immutable EPOCH_DURATION;
    uint48 public immutable SLASHING_WINDOW;
    uint48 public immutable START_TIME;

    uint48 private constant INSTANT_SLASHER_TYPE = 0;
    uint48 private constant VETO_SLASHER_TYPE = 1;

    uint256 public immutable primaryAssetClass;
    EnumerableSet.UintSet private secondaryAssetClasses;

    EnumerableMap.AddressToUintMap private operators;
    EnumerableMap.AddressToUintMap private vaults;

    mapping(uint48 => mapping(uint96 => uint256)) public totalStakeCache;
    mapping(uint48 => mapping(uint96 => bool)) public totalStakeCached;
    mapping(uint48 => mapping(uint96 => mapping(address => uint256))) public operatorStakeCache;

    mapping(address => uint96) public vaultToAssetClass;

    modifier updateStakeCache(uint48 epoch, uint96 assetClassId) {
        if (!totalStakeCached[epoch][assetClassId]) {
            calcAndCacheStakes(epoch, assetClassId);
        }
        _;
    }

    constructor(
        AvalancheL1MiddlewareSettings memory settings,
        address owner,
        uint256 primaryAssetMaxStake,
        uint256 primaryAssetMinStake,
        address primaryAsset
    ) SimpleKeyRegistry32() Ownable(owner) {
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

        primaryAssetClass = 1;
        assetClassIds.add(primaryAssetClass);
        assetClasses[primaryAssetClass].maxValidatorStake = primaryAssetMaxStake;
        assetClasses[primaryAssetClass].minValidatorStake = primaryAssetMinStake;
        assetClasses[primaryAssetClass].assets.add(primaryAsset);
    }

    function addAssetClass(uint256 _classId, uint256 _minValidatorStake, uint256 _maxValidatorStake) external {
        _addAssetClass(_classId, _minValidatorStake, _maxValidatorStake);
    }

    function addAssetToClass(uint256 _classId, address _asset) external {
        _addAssetToClass(_classId, _asset);
    }

    function removeAssetFromClass(uint256 _classId, address _asset) external {
        _removeAssetFromClass(_classId, _asset);
    }

    function activateSecondaryAssetClass(uint256 classId) external onlyOwner {
        if (!assetClassIds.contains(classId)) {
            revert AssetClassRegistry__AssetClassNotFound();
        }
        if (classId == primaryAssetClass) {
            revert AssetClassRegistry__AssetClassAlreadyExists();
        }

        secondaryAssetClasses.add(classId);
    }

    function deactivateSecondaryAssetClass(uint256 classId) external onlyOwner {
        if (!secondaryAssetClasses.contains(classId)) {
            revert AssetClassRegistry__AssetClassNotFound();
        }
        secondaryAssetClasses.remove(classId);
    }

    function getActiveAssetClasses() external view returns (uint256 primary, uint256[] memory secondaries) {
        primary = primaryAssetClass;
        secondaries = secondaryAssetClasses.values();
    }

    function _isActiveAssetClass(uint256 classId) internal view returns (bool) {
        return (classId == primaryAssetClass || secondaryAssetClasses.contains(classId));
    }

    function getEpochStartTs(uint48 epoch) public view returns (uint48 timestamp) {
        return START_TIME + epoch * EPOCH_DURATION;
    }

    function getEpochAtTs(uint48 timestamp) public view returns (uint48 epoch) {
        return (timestamp - START_TIME) / EPOCH_DURATION;
    }

    function getCurrentEpoch() public view returns (uint48 epoch) {
        return getEpochAtTs(Time.timestamp());
    }

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

        updateKey(operator, key);
        operators.add(operator);
        operators.enable(operator);
    }

    function updateOperatorKey(address operator, bytes32 key) external onlyOwner {
        if (!operators.contains(operator)) {
            revert AvalancheL1Middleware__OperatorNotRegistered();
        }
        updateKey(operator, key);
    }

    function disableOperator(address operator) external onlyOwner {
        operators.disable(operator);
    }

    function enableOperator(address operator) external onlyOwner {
        operators.enable(operator);
    }

    function removeOperator(address operator) external onlyOwner {
        (, uint48 disabledTime) = operators.getTimes(operator);
        if (disabledTime == 0 || disabledTime + SLASHING_WINDOW > Time.timestamp()) {
            revert AvalancheL1Middleware__OperarorGracePeriodNotPassed();
        }
        operators.remove(operator);
    }

    function registerVault(address vault, uint96 assetClassId, uint256 maxVaultStake) external onlyOwner {
        if (!IRegistry(VAULT_REGISTRY).isEntity(vault)) {
            revert AvalancheL1Middleware__NotVault();
        }

        address delegator = IVaultTokenized(vault).delegator();
        if (vaults.contains(vault) && BaseDelegator(delegator).maxL1Limit(msg.sender, assetClassId) != 0) {
            revert AvalancheL1Middleware__VaultAlreadyRegistered();
        }

        if (!_isActiveAssetClass(assetClassId)) {
            revert AvalancheL1Middleware__AssetClassNotActive();
        }

        address collateralAsset = IVaultTokenized(vault).collateral();
        if (!assetClasses[assetClassId].assets.contains(collateralAsset)) {
            revert AvalancheL1Middleware__CollateralNotInAssetClass();
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

        _setVaultMaxL1Limit(vault, assetClassId, maxVaultStake);

        if (!vaults.contains(vault)) {
            vaults.add(vault);
        }
        if (maxVaultStake == 0) {
            vaults.disable(vault);
        } else {
            vaults.enable(vault);
        }
    }

    function removeVault(address vault) external onlyOwner {
        (, uint48 disabledTime) = vaults.getTimes(vault);
        if (disabledTime == 0 || disabledTime + SLASHING_WINDOW > Time.timestamp()) {
            revert AvalancheL1Middleware__VaultGracePeriodNotPassed();
        }

        _setVaultMaxL1Limit(vault, vaultToAssetClass[vault], 0);

        vaults.remove(vault);
    }

    function _setVaultMaxL1Limit(address vault, uint96 assetClassId, uint256 amount) internal onlyOwner {
        if (!IRegistry(VAULT_REGISTRY).isEntity(vault)) {
            revert AvalancheL1Middleware__NotVault();
        }
        address delegator = IVaultTokenized(vault).delegator();
        BaseDelegator(delegator).setMaxL1Limit(L1_VALIDATOR_MANAGER, assetClassId, amount);
    }

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

    function getTotalStake(uint48 epoch, uint96 assetClassId) public view returns (uint256) {
        if (totalStakeCached[epoch][assetClassId]) {
            return totalStakeCache[epoch][assetClassId];
        }
        return _calcTotalStake(epoch, assetClassId);
    }

    function getValidatorSet(
        uint48 epoch,
        uint96 assetClassId
    ) public view returns (ValidatorData[] memory validatorsData) {
        uint48 epochStartTs = getEpochStartTs(epoch);

        validatorsData = new ValidatorData[](operators.length());
        uint256 valIdx = 0;

        for (uint256 i; i < operators.length(); ++i) {
            (address operator, uint48 enabledTime, uint48 disabledTime) = operators.atWithTimes(i);

            // just skip operator if it was added after the target epoch or paused
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

    function submission(
        bytes memory payload,
        bytes32[] memory signatures,
        uint96 assetClassId
    ) public updateStakeCache(getCurrentEpoch(), assetClassId) {
        // validate signatures
        // validate payload
        // process payload
    }

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

            // Skip if vault asset not in AssetClassID
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

            // just skip operator if it was added after the target epoch or paused
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

    function _wasActiveAt(uint48 enabledTime, uint48 disabledTime, uint48 timestamp) private pure returns (bool) {
        return enabledTime != 0 && enabledTime <= timestamp && (disabledTime == 0 || disabledTime >= timestamp);
    }

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
}
