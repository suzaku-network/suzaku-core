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

    mapping(uint48 => uint256) public totalStakeCache;
    mapping(uint48 => bool) public totalStakeCached;
    mapping(uint48 => mapping(address => uint256)) public operatorStakeCache;

    EnumerableMap.AddressToUintMap private operators;
    EnumerableMap.AddressToUintMap private vaults;

    modifier updateStakeCache(
        uint48 epoch
    ) {
        if (!totalStakeCached[epoch]) {
            calcAndCacheStakes(epoch);
        }
        _;
    }

    // Owner is expected to be L1_VALIDATOR_MANAGER

    constructor(
        AvalancheL1MiddlewareSettings memory settings, 
        address owner,
        uint256 _maxStake,
        uint256 _minStake,
        address _defaultAsset
    ) 
        SimpleKeyRegistry32() 
        Ownable(owner) 
        AssetClassRegistry(_maxStake, _minStake, _defaultAsset) 
    {
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
    }

    function activateSecondaryAssetClass(uint256 classId) external onlyOwner {
        if (!assetClassIds.contains(classId)) {
            revert AssetClassRegistry__AssetClassNotFound();
        }
        secondaryAssetClasses.add(classId);
    }

    function deactivateSecondaryAssetClass(uint256 classId) external onlyOwner {
        if (!secondaryAssetClasses.contains(classId)) {
            revert AssetClassRegistry__AssetClassNotFound();
        }
        secondaryAssetClasses.remove(classId);
    }

    function _allActiveAssetClasses() internal view returns (uint256[] memory) {
        uint256 secCount = secondaryAssetClasses.length();
        uint256[] memory result = new uint256[](secCount + 1);
        result[0] = primaryAssetClass;
        for (uint256 i; i < secCount; i++) {
            result[i + 1] = secondaryAssetClasses.at(i);
        }
        return result;
    }

    function getActiveAssetClasses() external view returns (uint256[] memory) {
        return _allActiveAssetClasses();
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

    function registerVault(
        address vault,
        uint96 assetClassId,
        uint256 maxValidatorStake
    ) external onlyOwner {
        address delegator = IVaultTokenized(vault).delegator();


        // msg.sender is expected to be L1_VALIDATOR_MANAGER
        if (vaults.contains(vault) && BaseDelegator(delegator).maxL1Limit(msg.sender, assetClassId) != 0) {
            revert AvalancheL1Middleware__VaultAlreadyRegistered();
        }
        if (!IRegistry(VAULT_REGISTRY).isEntity(vault)) {
            revert AvalancheL1Middleware__NotVault();
        }
        if (!assetClassIds.contains(assetClassId)) {
            revert AssetClassRegistry__AssetClassNotFound();
        }

        uint48 vaultEpoch = IVaultTokenized(vault).epochDuration();
        address slasher = IVaultTokenized(vault).slasher();
        if (slasher != address(0) && IEntity(slasher).TYPE() == VETO_SLASHER_TYPE) {
            vaultEpoch -= IVetoSlasher(slasher).vetoDuration();
        }
        if (vaultEpoch < SLASHING_WINDOW) {
            revert AvalancheL1Middleware__VaultEpochTooShort();
        }

        _setVaultMaxL1Limit(vault, assetClassId, maxValidatorStake);
        if (maxValidatorStake == 0) {
            if (vaults.contains(vault)) {
                vaults.disable(vault);
            }
            return;
        }
        if (!vaults.contains(vault)) {
            vaults.add(vault);
        }
        vaults.enable(vault);
    }

    function _setVaultMaxL1Limit(
        address vault,
        uint96 assetClassId,
        uint256 amount
    ) internal onlyOwner {
        if (!IRegistry(VAULT_REGISTRY).isEntity(vault)) {
            revert AvalancheL1Middleware__NotVault();
        }
        address delegator = IVaultTokenized(vault).delegator();
        BaseDelegator(delegator).setMaxL1Limit(L1_VALIDATOR_MANAGER, assetClassId, amount);
    }

    function removeVault(address vault) external onlyOwner {
        (, uint48 disabledTime) = vaults.getTimes(vault);
        if (disabledTime == 0 || disabledTime + SLASHING_WINDOW > Time.timestamp()) {
            revert AvalancheL1Middleware__VaultGracePeriodNotPassed();
        }
        vaults.remove(vault);
    }

    function getOperatorStake(
        address operator, 
        uint48 epoch
    ) public view returns (uint256 stake) {
        if (totalStakeCached[epoch]) {
            return operatorStakeCache[epoch][operator];
        }

        uint48 epochStartTs = getEpochStartTs(epoch);
        uint256[] memory allClasses = _allActiveAssetClasses();

        for (uint256 i; i < vaults.length(); ++i) {
            (address vault, uint48 enabledTime, uint48 disabledTime) = vaults.atWithTimes(i);

            // Skip if vault not active in the target epoch
            if (!_wasActiveAt(enabledTime, disabledTime, epochStartTs)) {
                continue;
            }

            for (uint256 j; j < allClasses.length; j++) {
                stake += BaseDelegator(IVaultTokenized(vault).delegator())
                    .stakeAt(
                        L1_VALIDATOR_MANAGER, 
                        uint96(allClasses[j]),
                        operator, 
                        epochStartTs, 
                        new bytes(0)
                    );
            }
        }
        return stake;
    }

    function getTotalStake(
        uint48 epoch
    ) public view returns (uint256) {
        if (totalStakeCached[epoch]) {
            return totalStakeCache[epoch];
        }
        return _calcTotalStake(epoch);
    }

    function getValidatorSet(
        uint48 epoch
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

            uint256 stake = getOperatorStake(operator, epoch);

            validatorsData[valIdx++] = ValidatorData(stake, key);
        }

        // shrink array to skip unused slots
        /// @solidity memory-safe-assembly
        assembly {
            mstore(validatorsData, valIdx)
        }
    }

    function submission(bytes memory payload, bytes32[] memory signatures) public updateStakeCache(getCurrentEpoch()) {
        // validate signatures
        // validate payload
        // process payload
    }

    function slash(
        uint48 epoch, 
        address operator, 
        uint256 amount
    ) public onlyOwner updateStakeCache(epoch) {
        uint48 epochStartTs = getEpochStartTs(epoch);

        if (epochStartTs < Time.timestamp() - SLASHING_WINDOW) {
            revert AvalancheL1Middleware__TooOldEpoch();
        }

        uint256 totalOperatorStake = getOperatorStake(operator, epoch);
        if (totalOperatorStake < amount) {
            revert AvalancheL1Middleware__TooBigSlashAmount();
        }

        uint256[] memory allClasses = _allActiveAssetClasses();

        // simple pro-rata slasher
        for (uint256 i; i < vaults.length(); ++i) {
            (address vault, uint48 enabledTime, uint48 disabledTime) = vaults.atWithTimes(i);
            if (!_wasActiveAt(enabledTime, disabledTime, epochStartTs)) {
                continue;
            }

            for (uint256 j; j < allClasses.length; j++) {
                uint256 vaultStake = BaseDelegator(IVaultTokenized(vault).delegator())
                    .stakeAt(
                        L1_VALIDATOR_MANAGER,
                        uint96(allClasses[j]),
                        operator,
                        epochStartTs,
                        new bytes(0)
                    );

                _slashVault(
                    epochStartTs,
                    vault,
                    uint8(allClasses[j]),
                    operator,
                    (amount * vaultStake) / totalOperatorStake
                );
            }
        }
    }

    function calcAndCacheStakes(
            uint48 epoch
        ) public returns (uint256 totalStake) {
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

            uint256 operatorStake = getOperatorStake(operator, epoch);
            operatorStakeCache[epoch][operator] = operatorStake;

            totalStake += operatorStake;
        }

        totalStakeCached[epoch] = true;
        totalStakeCache[epoch] = totalStake;
    }

    function _calcTotalStake(
        uint48 epoch
    ) private view returns (uint256 totalStake) {
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

            uint256 operatorStake = getOperatorStake(operator, epoch);
            totalStake += operatorStake;
        }
    }

    function _wasActiveAt(uint48 enabledTime, uint48 disabledTime, uint48 timestamp) private pure returns (bool) {
        return enabledTime != 0 && enabledTime <= timestamp && (disabledTime == 0 || disabledTime >= timestamp);
    }

    function _slashVault(
        uint48 timestamp,
        address vault,
        uint8 assetClass,
        address operator,
        uint256 amount
    ) private {
        address slasher = IVaultTokenized(vault).slasher();
        uint256 slasherType = IEntity(slasher).TYPE();
        if (slasherType == INSTANT_SLASHER_TYPE) {
            ISlasher(slasher).slash(L1_VALIDATOR_MANAGER, assetClass, operator, amount, timestamp, new bytes(0));
        } else if (slasherType == VETO_SLASHER_TYPE) {
            IVetoSlasher(slasher).requestSlash(L1_VALIDATOR_MANAGER, assetClass, operator, amount, timestamp, new bytes(0));
        } else {
            revert AvalancheL1Middleware__UnknownSlasherType();
        }
    }
}
