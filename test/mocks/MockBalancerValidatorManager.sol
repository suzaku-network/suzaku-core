// SPDX-License-Identifier: Ecosystem
pragma solidity ^0.8.25;

import {
    IValidatorManager,
    Validator,
    ValidatorStatus,
    ValidatorRegistrationInput,
    PChainOwner,
    ValidatorManagerSettings,
    ConversionData
} from "@avalabs/teleporter/validator-manager/interfaces/IValidatorManager.sol";
import {IBalancerValidatorManager} from "@suzaku/contracts-library/interfaces/ValidatorManager/IBalancerValidatorManager.sol";

contract MockBalancerValidatorManager is IBalancerValidatorManager {
    // --- Validator storage ---
    mapping(bytes32 => Validator) public validators;
    mapping(bytes32 => bool) public pendingWeightUpdate;
    mapping(bytes32 => bool) public pendingTermination;

    // --- Security module storage ---
    mapping(address => uint256) public securityModuleMaxWeight; // maximum allowed weight per module
    mapping(address => uint64) public securityModuleWeight;       // current total weight per module
    mapping(address => bool) public isSecurityModuleRegistered;   // tracks if a module is registered
    address[] private registeredSecurityModules;                 // array of registered modules

    // --- Mapping from validationID to security module ---
    mapping(bytes32 => address) public validatorSecurityModule;

    // --- IValidatorManager stubs for functions not needed by middleware ---
    function completeValidatorRegistration(uint32 /* messageIndex */) external pure override {
        revert("completeValidatorRegistration not implemented in mock");
    }

    function resendRegisterValidatorMessage(bytes32 /* validationID */) external pure override {
        revert("resendRegisterValidatorMessage not implemented in mock");
    }

    // (We omit registeredValidators to avoid duplicate declaration issues.)

    // --- IBalancerValidatorManager functions ---
    function getChurnPeriodSeconds() external pure override returns (uint64 churnPeriodSeconds) {
        return 3600; // dummy value (1 hour)
    }

    function getSecurityModules() external view override returns (address[] memory) {
        return registeredSecurityModules;
    }

    function getSecurityModuleWeights(address securityModule) external view override returns (uint64 weight, uint64 maxWeight) {
        weight = securityModuleWeight[securityModule];
        maxWeight = uint64(securityModuleMaxWeight[securityModule]);
    }

    function isValidatorPendingWeightUpdate(bytes32 validationID) external view override returns (bool) {
        return pendingWeightUpdate[validationID];
    }

    function setupSecurityModule(address securityModule, uint64 maxWeight) external override {
        if (isSecurityModuleRegistered[securityModule]) {
            uint64 currentWeight = securityModuleWeight[securityModule];
            require(maxWeight >= currentWeight, "New max weight lower than current weight");
            securityModuleMaxWeight[securityModule] = maxWeight;
        } else {
            isSecurityModuleRegistered[securityModule] = true;
            securityModuleMaxWeight[securityModule] = maxWeight;
            registeredSecurityModules.push(securityModule);
        }
        emit SetupSecurityModule(securityModule, maxWeight);
    }

    function initializeValidatorRegistration(
        ValidatorRegistrationInput calldata registrationInput,
        uint64 weight
    ) external override returns (bytes32 validationID) {
        validationID = keccak256(abi.encodePacked(registrationInput.nodeID, weight, block.timestamp));
        validators[validationID] = Validator({
            status: ValidatorStatus.PendingAdded,
            nodeID: registrationInput.nodeID,
            startingWeight: weight,
            messageNonce: 0,
            weight: weight,
            startedAt: 0,
            endedAt: 0
        });
        if (!isSecurityModuleRegistered[msg.sender]) {
            revert("Security module not registered");
        }
        validatorSecurityModule[validationID] = msg.sender;
        securityModuleWeight[msg.sender] += weight;
    }

    function initializeEndValidation(bytes32 validationID) external override {
        Validator storage v = validators[validationID];
        v.status = ValidatorStatus.PendingRemoved;
        pendingTermination[validationID] = true;
        address secMod = validatorSecurityModule[validationID];
        if (securityModuleWeight[secMod] >= v.weight) {
            securityModuleWeight[secMod] -= v.weight;
        }
    }

    function initializeValidatorWeightUpdate(bytes32 validationID, uint64 newWeight) external override {
        Validator memory v = validators[validationID];
        require(v.status == ValidatorStatus.Active, "Validator not active");
        require(!pendingWeightUpdate[validationID], "Pending weight update exists");
        require(newWeight != 0, "New weight is zero");
        require(validatorSecurityModule[validationID] == msg.sender, "Not validator's security module");
        pendingWeightUpdate[validationID] = true;
        address secMod = msg.sender;
        if (newWeight > v.weight) {
            uint64 delta = uint64(newWeight - v.weight);
            securityModuleWeight[secMod] += delta;
            require(securityModuleWeight[secMod] <= securityModuleMaxWeight[secMod], "Module max weight exceeded");
        } else if (v.weight > newWeight) {
            uint64 delta = uint64(v.weight - newWeight);
            securityModuleWeight[secMod] -= delta;
        }
        // The validator's weight is not updated here; it will be updated in completeValidatorWeightUpdate.
    }

    function completeValidatorWeightUpdate(bytes32 validationID, uint32 /* messageIndex */) external override {
        require(pendingWeightUpdate[validationID], "No pending weight update");
        pendingWeightUpdate[validationID] = false;
        // For testing, we assume an external process has updated validators[validationID].weight.
    }

    // --- Additional IValidatorManager functions stubs ---
    function initializeValidatorSet(ConversionData calldata /* conversionData */, uint32 /* messageIndex */) external override {
        revert("initializeValidatorSet not implemented in mock");
    }

    function resendEndValidatorMessage(bytes32 /* validationID */) external override {
        revert("resendEndValidatorMessage not implemented in mock");
    }

    function completeEndValidation(uint32 /* messageIndex */) external override {
        // For testing, do nothing.
    }

    // --- Additional helper (not declared in the interface) ---
    function getValidator(bytes32 validationID) external view returns (Validator memory) {
        return validators[validationID];
    }

    function simulateWeightUpdate(bytes32 validationID, uint64 newWeight) external {
        // Directly update the validator weight for testing purposes.
        Validator storage validator = validators[validationID];
        validator.weight = newWeight;
    }

    function simulateActivateValidator(bytes32 validationID) external {
        Validator storage validator = validators[validationID];
        require(validator.status == ValidatorStatus.PendingAdded, "Validator must be PendingAdded");
        validator.status = ValidatorStatus.Active;
        validator.startedAt = uint64(block.timestamp);
    }

}
