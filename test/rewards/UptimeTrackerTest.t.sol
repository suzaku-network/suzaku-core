// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {UptimeTracker} from "../../src/contracts/rewards/UptimeTracker.sol";
import {IUptimeTracker, LastUptimeCheckpoint} from "../../src/interfaces/rewards/IUptimeTracker.sol";
import {ValidatorMessages} from "@avalabs/icm-contracts/validator-manager/ValidatorMessages.sol";

import {MockAvalancheL1Middleware} from "../mocks/MockAvalancheL1Middleware.sol";
import {MockBalancerValidatorManager} from "../mocks/MockBalancerValidatorManager2.sol";
import {MockWarpMessenger} from "../mocks/MockWarpMessenger.sol";
import {
    WarpMessage, IWarpMessenger
} from "@avalabs/subnet-evm-contracts@1.2.0/contracts/interfaces/IWarpMessenger.sol";

contract UptimeTrackerTest is Test {
    UptimeTracker public uptimeTracker;
    MockBalancerValidatorManager public validatorManager;
    MockAvalancheL1Middleware public middleware;
    MockWarpMessenger public warpMessenger;

    address public operator;
    bytes32[] public operatorNodes;
    uint48 constant EPOCH_DURATION = 4 hours;
    address constant WARP_MESSENGER_ADDR = 0x0200000000000000000000000000000000000005;
    bytes32 constant L1_CHAIN_ID = bytes32(uint256(1));

    // Utility to derive validation ID from node ID
    function getDerivedValidationID(bytes32 fullNodeID) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(uint256(fullNodeID))));
    }

    event ValidatorUptimeComputed(
        bytes32 indexed validationID, uint48 indexed firstEpoch, uint256 uptimeSecondsAdded, uint256 numberOfEpochs
    );

    event OperatorUptimeComputed(address indexed operator, uint48 indexed epoch, uint256 uptime);

   function setUp() public {
        // Setup operator with 3 nodes
        uint256[] memory nodesPerOperator = new uint256[](1);
        nodesPerOperator[0] = 3;

        validatorManager = new MockBalancerValidatorManager();
        middleware = new MockAvalancheL1Middleware(1, nodesPerOperator, address(validatorManager), address(0));
        uptimeTracker = new UptimeTracker(payable(address(middleware)), L1_CHAIN_ID);

        operator = middleware.getAllOperators()[0];
        operatorNodes = middleware.getActiveNodesForEpoch(operator, 0);

        // Setup mock warp messenger
        warpMessenger = new MockWarpMessenger();
        vm.etch(WARP_MESSENGER_ADDR, address(warpMessenger).code);
    }

    // Helper for packing uptime message data
    function packValidationUptimeMessage(bytes32 validationID, uint256 uptime) public pure returns (bytes memory) {
        return ValidatorMessages.packValidationUptimeMessage(validationID, uint64(uptime));
    }

    function test_ComputeValidatorUptime() public {
        // Start at epoch 1
        vm.warp(EPOCH_DURATION + 1);

        bytes32 derivedNode0ID = getDerivedValidationID(operatorNodes[0]);

        uptimeTracker.computeValidatorUptime(0);

        uint256 validatorUptime = uptimeTracker.validatorUptimePerEpoch(0, derivedNode0ID);
        assertEq(validatorUptime, 2 hours);
        assertTrue(uptimeTracker.isValidatorUptimeSet(0, derivedNode0ID));

        // Move to epoch 2
        vm.warp(2 * EPOCH_DURATION + 1);

        uptimeTracker.computeValidatorUptime(1);

        validatorUptime = uptimeTracker.validatorUptimePerEpoch(1, derivedNode0ID);
        assertEq(validatorUptime, 1 hours);
        assertTrue(uptimeTracker.isValidatorUptimeSet(1, derivedNode0ID));
    }

    function test_ComputeOperatorUptime() public {
        // Start at epoch 1
        vm.warp(EPOCH_DURATION + 1);

        // Set validator uptime
        uptimeTracker.computeValidatorUptime(2);
        uptimeTracker.computeValidatorUptime(3);
        uptimeTracker.computeValidatorUptime(4);

        uptimeTracker.computeOperatorUptimeAt(operator, 0);

        uint256 operatorUptime = uptimeTracker.operatorUptimePerEpoch(0, operator);
        assertEq(operatorUptime, 2 hours);

        // Move to epoch 2
        vm.warp(2 * EPOCH_DURATION + 1);

        uptimeTracker.computeValidatorUptime(5);
        uptimeTracker.computeValidatorUptime(6);
        uptimeTracker.computeValidatorUptime(7);

        uptimeTracker.computeOperatorUptimeAt(operator, 1);

        operatorUptime = uptimeTracker.operatorUptimePerEpoch(1, operator);
        assertEq(operatorUptime, 2 hours);

        // Move to epoch 3
        vm.warp(3 * EPOCH_DURATION + 1);

        uptimeTracker.computeValidatorUptime(8);
        uptimeTracker.computeValidatorUptime(9);
        uptimeTracker.computeValidatorUptime(10);

        uptimeTracker.computeOperatorUptimeAt(operator, 2);

        operatorUptime = uptimeTracker.operatorUptimePerEpoch(2, operator);
        assertEq(operatorUptime, 2 hours);

        // Verify epochs are set
        assertTrue(uptimeTracker.isOperatorUptimeSet(0, operator));
        assertTrue(uptimeTracker.isOperatorUptimeSet(1, operator));
        assertTrue(uptimeTracker.isOperatorUptimeSet(2, operator));
    }

    function test_RevertIfValidatorUptimeNotRecorded() public {
        vm.warp(EPOCH_DURATION + 1);

        bytes32 expectedMissingDerivedID = getDerivedValidationID(operatorNodes[0]);

        vm.expectRevert(
            abi.encodeWithSelector(
                IUptimeTracker.UptimeTracker__ValidatorUptimeNotRecorded.selector, 1, expectedMissingDerivedID
            )
        );
        uptimeTracker.computeOperatorUptimeAt(operator, 1);
    }


    function test_ValidatorUptimeEvent() public {
        vm.warp(EPOCH_DURATION + 1);

        bytes32 derivedNode0ID = getDerivedValidationID(operatorNodes[0]);

        vm.expectEmit(true, true, false, true);
        emit ValidatorUptimeComputed(derivedNode0ID, 0, 2 hours, 1);

        uptimeTracker.computeValidatorUptime(0);
    }

    function test_OperatorUptimeEvent() public {
        vm.warp(EPOCH_DURATION + 1);

        uptimeTracker.computeValidatorUptime(2);
        uptimeTracker.computeValidatorUptime(3);
        uptimeTracker.computeValidatorUptime(4);

        vm.expectEmit(true, true, false, true);
        emit OperatorUptimeComputed(operator, 0, 2 hours);

        uptimeTracker.computeOperatorUptimeAt(operator, 0);
    }

    function test_EdgeCases() public {
        bytes32 derivedNode0ID = getDerivedValidationID(operatorNodes[0]);
        bytes32 derivedNode1ID = getDerivedValidationID(operatorNodes[1]);

        // Test max uptime
        vm.warp(EPOCH_DURATION + 1);
        uptimeTracker.computeValidatorUptime(11);
        assertEq(uptimeTracker.validatorUptimePerEpoch(0, derivedNode0ID), EPOCH_DURATION);

        // Test zero uptime
        uptimeTracker.computeValidatorUptime(12);
        assertEq(uptimeTracker.validatorUptimePerEpoch(0, derivedNode1ID), 0);

        // Test non-consecutive epochs
        vm.warp(3 * EPOCH_DURATION + 1);
        uptimeTracker.computeValidatorUptime(13);
        assertEq(uptimeTracker.validatorUptimePerEpoch(1, derivedNode0ID), EPOCH_DURATION);
        assertEq(uptimeTracker.validatorUptimePerEpoch(2, derivedNode0ID), EPOCH_DURATION);
    }
}
