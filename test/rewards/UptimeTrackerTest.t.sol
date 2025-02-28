// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {UptimeTracker} from "../../src/contracts/rewards/UptimeTracker.sol";
import {IUptimeTracker} from "../../src/interfaces/rewards/IUptimeTracker.sol";
import {
    AvalancheL1MiddlewareSettings,
    AvalancheL1Middleware
} from "../../src/contracts/middleware/AvalancheL1Middleware.sol";

import {MockAvalancheL1Middleware} from "../mocks/MockAvalancheL1Middleware.sol";
import {MockBalancerValidatorManager} from "../mocks/MockBalancerValidatorManager2.sol";

contract UptimeTrackerTest is Test {
    bytes32 constant VALIDATION_ID = keccak256(abi.encode("Validator1"));

    event ValidatorUptimeComputed(
        bytes32 indexed validationID, uint48 indexed firstEpoch, uint256 uptimeSecondsAdded, uint256 numberOfEpochs
    );

    event OperatorUptimeComputed(address indexed operator, uint48 indexed epoch, uint256 uptime);

    UptimeTracker uptimeTracker;
    MockBalancerValidatorManager validatorManager;
    MockAvalancheL1Middleware middleware;
    address operator;

    function setUp() public {
        validatorManager = new MockBalancerValidatorManager();
        middleware = new MockAvalancheL1Middleware(address(validatorManager));
        uptimeTracker = new UptimeTracker(address(middleware));
        operator = makeAddr("Operator");
    }

    modifier initializeValidator() {
        uptimeTracker.computeValidatorUptime(VALIDATION_ID, 0);
        _;
    }

    modifier initializeValidators() {
        bytes32[] memory operatorActiveNodes = middleware.getActiveNodesForEpoch(operator, 1);
        for (uint256 i = 0; i < operatorActiveNodes.length; i++) {
            uptimeTracker.computeValidatorUptime(operatorActiveNodes[i], 0);
        }
        _;
    }

    function test_ComputeUptimeValidator() public initializeValidator {
        vm.warp(5 hours);
        uptimeTracker.computeValidatorUptime(VALIDATION_ID, 3 hours);
        vm.warp(13 hours);
        uptimeTracker.computeValidatorUptime(VALIDATION_ID, 7 hours);

        uint256 validatorUptimeEpoch2 = uptimeTracker.validatorUptimePerEpoch(2, VALIDATION_ID);

        assertEq(validatorUptimeEpoch2, 2 hours);
    }

    function test_EmitsOnValidatorUptimeComputed() public initializeValidator {
        vm.expectEmit(true, true, false, false, address(uptimeTracker));
        emit ValidatorUptimeComputed(VALIDATION_ID, 0, 3 hours, 1);
        vm.warp(5 hours);
        uptimeTracker.computeValidatorUptime(VALIDATION_ID, 3 hours);
    }

    function test_ComputeUptimeOperator() public initializeValidators {
        bytes32[] memory operatorActiveNodes = middleware.getActiveNodesForEpoch(operator, 1);
        for (uint256 i = 0; i < operatorActiveNodes.length; i++) {
            uint256 uptime = (i + 1) * 2000;
            vm.warp(9 hours);
            uptimeTracker.computeValidatorUptime(operatorActiveNodes[i], uptime);
        }

        uptimeTracker.computeOperatorUptimeAt(operator, 1);

        uint256 operatorUptime = uptimeTracker.operatorUptimePerEpoch(1, operator);

        assertEq(operatorUptime, 3000);
    }

    function test_RevertIfValidatorUptimeNotRecorded() public initializeValidators {
        vm.expectRevert(
            abi.encodeWithSelector(IUptimeTracker.UptimeTracker__ValidatorUptimeNotRecorded.selector, 1, VALIDATION_ID)
        );
        uptimeTracker.computeOperatorUptimeAt(operator, 1);
    }

    function test_EmitsOnOperatorUptimeComputed() public initializeValidators {
        bytes32[] memory operatorActiveNodes = middleware.getActiveNodesForEpoch(operator, 1);
        for (uint256 i = 0; i < operatorActiveNodes.length; i++) {
            uint256 uptime = (i + 1) * 2000;
            vm.warp(9 hours);
            uptimeTracker.computeValidatorUptime(operatorActiveNodes[i], uptime);
        }

        vm.expectEmit(true, true, false, false, address(uptimeTracker));
        emit OperatorUptimeComputed(operator, 1, 3000);
        uptimeTracker.computeOperatorUptimeAt(operator, 1);
    }
}
