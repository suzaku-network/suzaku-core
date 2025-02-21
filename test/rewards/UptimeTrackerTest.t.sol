// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {
    UptimeTracker,
    LastUptimeCheckpoint,
    UptimeTracker__ValidatorUptimeNotRecorded
} from "../../src/contracts/rewards/UptimeTracker.sol";
import {
    AvalancheL1MiddlewareSettings,
    AvalancheL1Middleware
} from "../../src/contracts/middleware/AvalancheL1Middleware.sol";

import {MockAvalancheL1Middleware} from "../mocks/MockAvalancheL1Middleware.sol";

contract UptimeTrackerTest is Test {
    bytes32 constant VALIDATION_ID = keccak256(abi.encode("Validator1"));

    event ValidatorUptimeComputed(
        bytes32 indexed validationID, uint256 indexed uptime, uint256 indexed numberOfEpochs, uint48 firstEpoch
    );

    event OperatorUptimeComputed(address indexed operator, uint256 indexed uptime, uint48 indexed epoch);

    UptimeTracker uptimeTracker;
    MockAvalancheL1Middleware middleware;
    address operator;

    function setUp() public {
        middleware = new MockAvalancheL1Middleware();
        uptimeTracker = new UptimeTracker(address(middleware));
        operator = makeAddr("Operator");
    }

    modifier initializeValidator() {
        uptimeTracker.setInitialCheckpoint(VALIDATION_ID, 1000);
        _;
    }

    modifier initializeValidators() {
        bytes32[] memory operatorActiveNodes = middleware.getActiveNodesForEpoch(operator, 1);
        for (uint256 i = 0; i < operatorActiveNodes.length; i++) {
            uptimeTracker.setInitialCheckpoint(operatorActiveNodes[i], 1000);
        }
        _;
    }

    function test_CalculateUptimeValidator() public initializeValidator {
        uptimeTracker.calculateValidatorUptimeCoverage(VALIDATION_ID, 3 hours, 5 hours);
        uptimeTracker.calculateValidatorUptimeCoverage(VALIDATION_ID, 7 hours, 13 hours);

        uint256 validatorUptimeEpoch2 = uptimeTracker.validatorUptimePerEpoch(2, VALIDATION_ID);

        assertEq(validatorUptimeEpoch2, 2 hours);
    }

    function test_EmitsOnValidatorUptimeComputed() public initializeValidator {
        vm.expectEmit(true, true, false, false, address(uptimeTracker));
        emit ValidatorUptimeComputed(VALIDATION_ID, 3 hours, 1, 0);
        uptimeTracker.calculateValidatorUptimeCoverage(VALIDATION_ID, 3 hours, 5 hours);
    }

    function test_CalculateUptimeOperator() public initializeValidators {
        bytes32[] memory operatorActiveNodes = middleware.getActiveNodesForEpoch(operator, 1);
        for (uint256 i = 0; i < operatorActiveNodes.length; i++) {
            uint256 uptime = (i + 1) * 2000;
            uptimeTracker.calculateValidatorUptimeCoverage(operatorActiveNodes[i], uptime, 9 hours);
        }

        uptimeTracker.calculateOperatorUptimeCoverageAt(operator, 1);

        uint256 operatorUptime = uptimeTracker.operatorUptimePerEpoch(1, operator);

        assertEq(operatorUptime, 3000);
    }

    function test_RevertIfValidatorUptimeNotRecorded() public initializeValidators {
        vm.expectRevert(abi.encodeWithSelector(UptimeTracker__ValidatorUptimeNotRecorded.selector, 1, VALIDATION_ID));
        uptimeTracker.calculateOperatorUptimeCoverageAt(operator, 1);
    }

    function test_EmitsOnOperatorUptimeComputed() public initializeValidator {
        bytes32[] memory operatorActiveNodes = middleware.getActiveNodesForEpoch(operator, 1);
        for (uint256 i = 0; i < operatorActiveNodes.length; i++) {
            uint256 uptime = (i + 1) * 2000;
            uptimeTracker.calculateValidatorUptimeCoverage(operatorActiveNodes[i], uptime, 9 hours);
        }

        vm.expectEmit(true, true, false, false, address(uptimeTracker));
        emit OperatorUptimeComputed(operator, 3000, 1);
        uptimeTracker.calculateOperatorUptimeCoverageAt(operator, 1);
    }
}
