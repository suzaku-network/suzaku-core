// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO
pragma solidity 0.8.25;

import {Validator, ValidatorStatus} from "@avalabs/teleporter/validator-manager/interfaces/IValidatorManager.sol";

contract MockBalancerValidatorManager {
    function getValidator(
        bytes32
    ) external pure returns (Validator memory) {
        Validator memory validator = Validator({
            status: ValidatorStatus.Active,
            nodeID: "",
            startingWeight: 100,
            messageNonce: 0,
            weight: 100,
            startedAt: 1000,
            endedAt: 0
        });
        return validator;
    }
    
    function registeredValidators(bytes memory nodeID) external pure returns (bytes32) {
        if (nodeID.length == 32) {
            return abi.decode(nodeID, (bytes32));
        } else if (nodeID.length == 20) {
            return bytes32(uint256(uint160(bytes20(nodeID))));
        } else {
            return keccak256(nodeID);
        }
    }

    function getL1ID() external pure returns (bytes32) {
        return bytes32(uint256(1));
    }
}
