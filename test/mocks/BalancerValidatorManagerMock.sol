// // SPDX-License-Identifier: MIT
// pragma solidity 0.8.25;

// import {
//     IValidatorManager,
//     Validator,
//     ValidatorStatus,
//     ValidatorRegistrationInput,
//     PChainOwner,
//     ValidatorManagerSettings
// } from "@avalabs/teleporter/validator-manager/interfaces/IValidatorManager.sol";

// import {IBalancerValidatorManager} from "@suzaku/contracts-library/interfaces/ValidatorManager/IBalancerValidatorManager.sol";

// /**
//  * @notice Minimal mock that satisfies IBalancerValidatorManager / IValidatorManager
//  * for testing AvalancheL1Middleware node functionality.
//  */
// contract BalancerValidatorManagerMock is IBalancerValidatorManager {
//     // ------------------------------
//     // Storage
//     // ------------------------------

//     struct SecurityModuleWeights {
//         uint64 weight;
//         uint64 maxWeight;
//     }

//     // validationID => Validator
//     mapping(bytes32 => Validator) private _validators;

//     // Tracks if a validator is pending weight update
//     mapping(bytes32 => bool) private _pendingWeightUpdate;

//     // securityModule => (weight, maxWeight)
//     mapping(address => SecurityModuleWeights) private _securityModules;
//     address[] private _securityModulesList;

//     // Mock churn period
//     uint64 private _churnPeriodSeconds = 120;

//     // ------------------------------
//     // Helper set functions for tests
//     // ------------------------------

//     function mockSetValidator(
//         bytes32 validationID,
//         ValidatorStatus status,
//         uint64 weight
//     ) external {
//         Validator storage v = _validators[validationID];
//         v.status = status;
//         v.weight = weight;
//         v.messageNonce = 1; // non-zero so we can do "weight updates" in the mock
//     }

//     function mockSetSecurityModuleWeights(
//         address module,
//         uint64 weight,
//         uint64 maxWeight
//     ) external {
//         if (_securityModules[module].maxWeight == 0) {
//             _securityModulesList.push(module);
//         }
//         _securityModules[module] = SecurityModuleWeights(weight, maxWeight);
//     }

//     // ------------------------------
//     // IValidatorManager required stubs
//     // ------------------------------

//     function initializeValidatorSet(Validator[] calldata /*validators*/) external override {
//         // no-op for mock
//     }

//     function resendRegisterValidatorMessage(bytes32 /*validationID*/) external override {
//         // no-op for mock
//     }

//     function resendEndValidatorMessage(bytes32 /*validationID*/) external override {
//         // no-op for mock
//     }

//     function completeValidatorRegistration(uint32 /*messageIndex*/) external pure override {
//         // no-op for mock
//     }

//     function cancelValidatorRegistration(uint32 /*messageIndex*/) external pure override {
//         // no-op for mock
//     }

//     function getValidators() external view override returns (bytes32[] memory) {
//         // Return an empty array in the mock
//         return new bytes32[](0);
//     }

//     function getValidator(bytes32 validationID)
//         external
//         view
//         override
//         returns (Validator memory)
//     {
//         return _validators[validationID];
//     }

//     // ------------------------------
//     // IBalancerValidatorManager required stubs
//     // ------------------------------

//     function getChurnPeriodSeconds()
//         external
//         view
//         override
//         returns (uint64)
//     {
//         return _churnPeriodSeconds;
//     }

//     function getSecurityModules()
//         external
//         view
//         override
//         returns (address[] memory)
//     {
//         return _securityModulesList;
//     }

//     function getSecurityModuleWeights(
//         address securityModule
//     )
//         external
//         view
//         override
//         returns (uint64 weight, uint64 maxWeight)
//     {
//         SecurityModuleWeights storage sm = _securityModules[securityModule];
//         return (sm.weight, sm.maxWeight);
//     }

//     function isValidatorPendingWeightUpdate(
//         bytes32 validationID
//     )
//         external
//         view
//         override
//         returns (bool)
//     {
//         return _pendingWeightUpdate[validationID];
//     }

//     function setupSecurityModule(
//         address securityModule,
//         uint64 maxWeight
//     )
//         external
//         override
//     {
//         SecurityModuleWeights storage sm = _securityModules[securityModule];

//         // If new module and not removing, track it
//         if (sm.maxWeight == 0 && maxWeight != 0) {
//             _securityModulesList.push(securityModule);
//         }
//         // If removing, reset the current weight to 0
//         if (maxWeight == 0) {
//             sm.weight = 0;
//         }
//         sm.maxWeight = maxWeight;

//         emit SetupSecurityModule(securityModule, maxWeight);
//     }

//     function initializeValidatorRegistration(
//         ValidatorRegistrationInput calldata registrationInput,
//         uint64 weight
//     )
//         external
//         override
//         returns (bytes32 validationID)
//     {
//         // Minimal ID derivation for mock
//         validationID = keccak256(
//             abi.encodePacked(block.timestamp, msg.sender, registrationInput.nodeID)
//         );

//         Validator storage v = _validators[validationID];
//         v.status = ValidatorStatus.PendingAdded;
//         v.weight = weight;
//         v.messageNonce = 1;

//         // Increase this module’s weight in the mock
//         _securityModules[msg.sender].weight += weight;
//     }

//     function initializeEndValidation(
//         bytes32 validationID
//     )
//         external
//         override
//     {
//         Validator storage v = _validators[validationID];
//         require(
//             v.status == ValidatorStatus.Active ||
//             v.status == ValidatorStatus.PendingAdded,
//             "Invalid status"
//         );

//         // Decrease module's weight in the mock
//         _securityModules[msg.sender].weight -= v.weight;

//         // Mark the validator as PendingRemoved
//         v.status = ValidatorStatus.PendingRemoved;
//     }

//     function completeEndValidation(
//         uint32 /*messageIndex*/
//     )
//         external
//         override
//     {
//         // no-op for mock
//     }

//     function initializeValidatorWeightUpdate(
//         bytes32 validationID,
//         uint64 newWeight
//     )
//         external
//         override
//     {
//         require(newWeight > 0, "New weight is zero");

//         Validator storage v = _validators[validationID];
//         require(v.status == ValidatorStatus.Active, "Validator not active");
//         require(!_pendingWeightUpdate[validationID], "Already pending update");

//         uint64 oldWeight = v.weight;

//         // Adjust module weight
//         _securityModules[msg.sender].weight =
//             _securityModules[msg.sender].weight + newWeight - oldWeight;

//         // Mark that we have a weight update in progress
//         _pendingWeightUpdate[validationID] = true;

//         // Put the new weight in the validator struct so "complete" can finalize
//         v.weight = newWeight;
//     }

//     function completeValidatorWeightUpdate(
//         bytes32 validationID,
//         uint32 /*messageIndex*/
//     )
//         external
//         override
//     {
//         require(_pendingWeightUpdate[validationID], "No pending update");

//         Validator storage v = _validators[validationID];
//         require(v.status == ValidatorStatus.Active, "Validator not active");

//         // Mark update as done
//         _pendingWeightUpdate[validationID] = false;
//     }

//     // ------------------------------
//     // Extra local test helper (not in any interface)
//     // ------------------------------
//     function lastPChainBlockTime() external pure returns (uint64) {
//         return 0; // Just a no-op mock
//     }
// }
