// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO
pragma solidity 0.8.25;

import {Validator, ValidatorStatus} from "@avalabs/teleporter/validator-manager/interfaces/IValidatorManager.sol";

contract MockBalancerValidatorManager {
    function getValidator(
        bytes32 validationID
    ) external view returns (Validator memory) {
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
}
