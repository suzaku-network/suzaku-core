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
}
