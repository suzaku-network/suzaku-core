// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO
pragma solidity 0.8.25;

contract MockUptimeTracker {
    mapping(uint48 => mapping(address => uint256)) public operatorUptimePerEpoch;
    mapping(uint48 => mapping(address => bool)) public isUptimeSet;

    function setOperatorUptimePerEpoch(uint48 epoch, address operator, uint256 uptime) external {
        operatorUptimePerEpoch[epoch][operator] = uptime;
        isUptimeSet[epoch][operator] = true;
    }

    function isOperatorUptimeSet(uint48 epoch, address operator) external view returns (bool) {
        return isUptimeSet[epoch][operator];
    }

    // Batch functions for easier integration testing
    function setMultipleOperatorsUptime(
        uint48 epoch, 
        address[] calldata operators, 
        uint256[] calldata uptimes
    ) external {
        require(operators.length == uptimes.length, "Arrays length mismatch");
        for (uint256 i = 0; i < operators.length; i++) {
            operatorUptimePerEpoch[epoch][operators[i]] = uptimes[i];
            isUptimeSet[epoch][operators[i]] = true;
        }
    }

    function setAllOperatorsSameUptime(
        uint48 epoch, 
        address[] calldata operators, 
        uint256 uptime
    ) external {
        for (uint256 i = 0; i < operators.length; i++) {
            operatorUptimePerEpoch[epoch][operators[i]] = uptime;
            isUptimeSet[epoch][operators[i]] = true;
        }
    }

    // Function to check if all operators have uptime set for an epoch
    function areAllOperatorsUptimeSet(uint48 epoch, address[] calldata operators) external view returns (bool) {
        for (uint256 i = 0; i < operators.length; i++) {
            if (!isUptimeSet[epoch][operators[i]]) {
                return false;
            }
        }
        return true;
    }
}
