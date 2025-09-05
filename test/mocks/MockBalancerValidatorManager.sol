// SPDX-License-Identifier: Ecosystem
pragma solidity ^0.8.25;

import {Test, console2} from "forge-std/Test.sol";

import {
    Validator,
    ValidatorStatus,
    PChainOwner,
    ConversionData
} from "@avalabs/icm-contracts/validator-manager/interfaces/IACP99Manager.sol";
import {IValidatorManager} from "@avalabs/icm-contracts/validator-manager/interfaces/IValidatorManager.sol";
import {ValidatorChurnPeriod, ValidatorManagerSettings} from "@avalabs/icm-contracts/validator-manager/ValidatorManager.sol";
import {IBalancerValidatorManager} from
    "@suzaku/contracts-library/interfaces/ValidatorManager/IBalancerValidatorManager.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// Declare missing event (do not duplicate events already in IBalancerValidatorManager)
event ValidationPeriodRegistered(bytes32 indexed validationID, uint64 weight, uint256 startTime);

contract MockBalancerValidatorManager is IBalancerValidatorManager, Ownable {
    // --- Validator storage ---
    mapping(bytes32 => Validator) public validators;
    mapping(bytes32 => bool) public pendingWeightUpdate;
    mapping(bytes32 => bool) public pendingTermination;

    // --- Security module storage ---
    mapping(address => uint256) public securityModuleMaxWeight; // maximum allowed weight per module
    mapping(address => uint64) public securityModuleWeight; // current total weight per module
    mapping(address => bool) public isSecurityModuleRegistered; // tracks if a module is registered
    address[] private registeredSecurityModules; // array of registered modules

    // Add a new mapping at the top of the contract:
    mapping(bytes32 => uint64) public pendingNewWeight;

    // --- Mapping from validationID to security module ---
    mapping(bytes32 => address) public validatorSecurityModule;

    // --- Pending registration messages (simulated) ---
    mapping(uint32 => bytes32) public pendingRegistrationMessages;
    mapping(uint32 => bytes32) public pendingWeightUpdateMessages; // Track which validationID corresponds to each messageIndex for weight updates
    uint32 public nextMessageIndex;

    // mapping from nodeID => validationID ---
    mapping(bytes => bytes32) public _registeredValidators; // <-- ADD

    constructor(
        address initialOwner
    ) Ownable(initialOwner) {}

    // --- IValidatorManager stubs for functions not needed by middleware ---
    function completeValidatorRegistration(
        uint32 messageIndex
    ) external override returns (bytes32) {
        // Retrieve the pending registration message (simulated via messageIndex)
        bytes32 validationID = pendingRegistrationMessages[messageIndex];
        require(validationID != bytes32(0), "Invalid validationID");

        // Ensure validator exists and is in PendingAdded status
        Validator storage validator = validators[validationID];
        require(validator.status == ValidatorStatus.PendingAdded, "Invalid validator status");

        // Complete registration: activate and record start time
        validator.status = ValidatorStatus.Active;
        validator.startTime = uint64(block.timestamp);

        // Remove pending registration entry and emit event
        delete pendingRegistrationMessages[messageIndex];
        emit ValidationPeriodRegistered(validationID, validator.weight, block.timestamp);
        
        return validationID;
    }

    function resendRegisterValidatorMessage(
        bytes32 /* validationID */
    ) external pure override {
        revert("resendRegisterValidatorMessage not implemented in mock");
    }

    // --- IBalancerValidatorManager functions ---
    function getChurnPeriodSeconds() external pure override returns (uint64 churnPeriodSeconds) {
        return 3600; // dummy value (1 hour)
    }

    function getSecurityModules() external view override returns (address[] memory) {
        return registeredSecurityModules;
    }

    function getL1ID() external pure returns (bytes32) {
        return bytes32(uint256(1));
    }

    function getSecurityModuleWeights(
        address securityModule
    ) external view override returns (uint64 weight, uint64 maxWeight) {
        weight = securityModuleWeight[securityModule];
        maxWeight = uint64(securityModuleMaxWeight[securityModule]);
    }

    function isValidatorPendingWeightUpdate(
        bytes32 validationID
    ) external view override returns (bool) {
        return pendingWeightUpdate[validationID];
    }

    function setupSecurityModule(address securityModule, uint64 maxWeight) external onlyOwner {
        if (isSecurityModuleRegistered[securityModule]) {
            uint64 currentWeight = securityModuleWeight[securityModule];
            require(maxWeight >= currentWeight, "New max weight lower than current weight");
            securityModuleMaxWeight[securityModule] = maxWeight;
        } else {
            isSecurityModuleRegistered[securityModule] = true;
            securityModuleMaxWeight[securityModule] = maxWeight;
            registeredSecurityModules.push(securityModule);
        }
        emit SetUpSecurityModule(securityModule, maxWeight);
    }

    function initiateValidatorRegistration(
        bytes memory nodeID,
        bytes memory blsPublicKey,
        PChainOwner memory remainingBalanceOwner,
        PChainOwner memory disableOwner,
        uint64 weight
    ) external override returns (bytes32 validationID) {
        validationID = keccak256(abi.encodePacked(nodeID, weight, block.timestamp));
        validators[validationID] = Validator({
            status: ValidatorStatus.PendingAdded,
            nodeID: nodeID,
            startingWeight: weight,
            sentNonce: 0,
            receivedNonce: 0,
            weight: weight,
            startTime: 0,
            endTime: 0
        });
        if (!isSecurityModuleRegistered[msg.sender]) {
            revert("Security module not registered");
        }
        validatorSecurityModule[validationID] = msg.sender;
        securityModuleWeight[msg.sender] += weight;

        // Simulate storing a pending registration message linked to a messageIndex
        pendingRegistrationMessages[nextMessageIndex] = validationID;
        nextMessageIndex++;
        _registeredValidators[nodeID] = validationID; // <-- ADD
        return validationID;
    }

    function initiateValidatorRemoval(
        bytes32 validationID
    ) external override {
        Validator storage v = validators[validationID];
        v.status = ValidatorStatus.PendingRemoved;
        pendingTermination[validationID] = true;
        address secMod = validatorSecurityModule[validationID];
        if (securityModuleWeight[secMod] >= v.weight) {
            securityModuleWeight[secMod] -= v.weight;
        }
        v.endTime = uint64(block.timestamp);
        pendingRegistrationMessages[nextMessageIndex] = validationID;
        nextMessageIndex++;
        console2.log("validationID", uint256(validationID));
        console2.log("nextMessageIndex", nextMessageIndex);
    }

    function initiateValidatorWeightUpdate(
        bytes32 validationID,
        uint64 newWeight
    ) external override returns (uint64, bytes32) {
        Validator memory v = validators[validationID];
        require(v.status == ValidatorStatus.Active, "Validator not active");
        require(!pendingWeightUpdate[validationID], "Pending weight update exists");
        require(newWeight != 0, "New weight is zero");
        require(validatorSecurityModule[validationID] == msg.sender, "Not validator's security module");
        pendingWeightUpdate[validationID] = true;
        // Store the new weight pending completion.
        pendingNewWeight[validationID] = newWeight;
        address secMod = msg.sender;
        if (newWeight > v.weight) {
            uint64 delta = uint64(newWeight - v.weight);
            securityModuleWeight[secMod] += delta;
            require(securityModuleWeight[secMod] <= securityModuleMaxWeight[secMod], "Module max weight exceeded");
        } else if (v.weight > newWeight) {
            uint64 delta = uint64(v.weight - newWeight);
            securityModuleWeight[secMod] -= delta;
        }
        
        // Enqueue a "message" so tests can complete it later
        pendingWeightUpdateMessages[nextMessageIndex] = validationID;
        nextMessageIndex++;
        
        return (1, validationID); // Return nonce and validationID
    }

    function completeValidatorWeightUpdate(uint32 messageIndex) external override returns (bytes32, uint64) {
        bytes32 validationID = pendingWeightUpdateMessages[messageIndex];
        require(validationID != bytes32(0), "Invalid messageIndex");
        require(pendingWeightUpdate[validationID], "No pending weight update");

        uint64 newWeight = pendingNewWeight[validationID];
        Validator storage v = validators[validationID];
        require(v.status == ValidatorStatus.Active, "Validator not active");

        v.weight = newWeight;

        // Clear pending markers
        delete pendingWeightUpdate[validationID];
        delete pendingNewWeight[validationID];
        delete pendingWeightUpdateMessages[messageIndex];

        return (validationID, newWeight);
    }

    // --- Additional IValidatorManager function stubs ---
    function initializeValidatorSet(
        ConversionData calldata, /* conversionData */
        uint32 /* messageIndex */
    ) external pure {
        revert("initializeValidatorSet not implemented in mock");
    }

    function resendEndValidatorMessage(
        bytes32 /* validationID */
    ) external pure {
        revert("resendEndValidatorMessage not implemented in mock");
    }

    function completeValidatorRemoval(
        uint32 messageIndex
    ) external override returns (bytes32) {
        bytes32 validationID = pendingRegistrationMessages[messageIndex];
        console2.log("validationID 1", uint256(pendingRegistrationMessages[1]));
        console2.log("validationID 2", uint256(pendingRegistrationMessages[2]));
        console2.log("validationID 3", uint256(pendingRegistrationMessages[3]));
        console2.log("validationID 4", uint256(pendingRegistrationMessages[4]));
        require(validationID != bytes32(0), "Invalid validationID");
        console2.log("validationID", uint256(validationID));

        Validator storage validator = validators[validationID];
        require(validator.status == ValidatorStatus.PendingRemoved, "Validator not PendingRemoved");

        // Mark it ended/completed
        validator.status = ValidatorStatus.Completed;
        // validator.endTime = uint64(block.timestamp);

        // Clean up
        delete pendingRegistrationMessages[messageIndex];
        delete pendingTermination[validationID];
        delete _registeredValidators[validator.nodeID];
        
        return validationID;
    }

    // --- Additional helper functions ---
    function getValidator(
        bytes32 validationID
    ) external view returns (Validator memory) {
        return validators[validationID];
    }

    function simulateWeightUpdate(bytes32 validationID, uint64 newWeight) external {
        Validator storage validator = validators[validationID];
        validator.weight = newWeight;
    }

    function simulateActivateValidator(
        bytes32 validationID
    ) external {
        Validator storage validator = validators[validationID];
        require(validator.status == ValidatorStatus.PendingAdded, "Validator must be PendingAdded");
        validator.status = ValidatorStatus.Active;
        validator.startTime = uint64(block.timestamp);
    }

    function registeredValidators(
        bytes calldata nodeID
    ) public view returns (bytes32) {
        return _registeredValidators[nodeID];
    }

    function getNodeValidationID(
        bytes calldata nodeID
    ) external view override returns (bytes32) {
        return _registeredValidators[nodeID];
    }

    function getCurrentChurnPeriod() external pure override returns (ValidatorChurnPeriod memory) {
        revert("getCurrentChurnPeriod not implemented in mock");
    }

    function getMaximumChurnPercentage() external pure override returns (uint64) {
        return 20; // Example value
    }

    function resendValidatorWeightUpdate(
        bytes32 validationID
    ) external pure override {
        console2.log("resendValidatorWeightUpdate", uint256(validationID));
        revert("resendValidatorWeightUpdate not implemented in mock");
    }

    function setUpSecurityModule(address securityModule, uint64 maxWeight) external override {
        this.setupSecurityModule(securityModule, maxWeight); // reuse the implemented version
    }
    
    // Missing functions from the interface
    function getValidatorSecurityModule(bytes32 validationID) external view override returns (address) {
        return validatorSecurityModule[validationID];
    }
    
    function l1TotalWeight() external pure override returns (uint64) {
        return 1000; // Mock value
    }
    
    function migrateFromV1(bytes32 validationID, uint32 receivedNonce) external pure override {
        revert("migrateFromV1 not implemented in mock");
    }
    
    function resendValidatorRemovalMessage(bytes32 validationID) external pure override {
        revert("resendValidatorRemovalMessage not implemented in mock");
    }
    
    function subnetID() external pure override returns (bytes32) {
        return bytes32(uint256(1)); // Mock value
    }
    
    function transferValidatorManagerOwnership(address newOwner) external override onlyOwner {
        // In the mock, we can use the standard Ownable transferOwnership
        transferOwnership(newOwner);
    }
}
