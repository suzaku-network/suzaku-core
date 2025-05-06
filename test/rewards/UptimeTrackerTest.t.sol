// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {UptimeTracker} from "../../src/contracts/rewards/UptimeTracker.sol";
import {IUptimeTracker} from "../../src/interfaces/rewards/IUptimeTracker.sol";
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

    event ValidatorUptimeComputed(
        bytes32 indexed validationID, uint48 indexed firstEpoch, uint256 uptimeSecondsAdded, uint256 numberOfEpochs
    );

    event OperatorUptimeComputed(address indexed operator, uint48 indexed epoch, uint256 uptime);

    function setUp() public {
        // Setup operator with 3 nodes
        uint256[] memory nodesPerOperator = new uint256[](1);
        nodesPerOperator[0] = 3;

        // Initialize contracts
        validatorManager = new MockBalancerValidatorManager();
        middleware = new MockAvalancheL1Middleware(1, nodesPerOperator, address(validatorManager), address(0));
        uptimeTracker = new UptimeTracker(payable(address(middleware)));

        // Get operator
        operator = middleware.getAllOperators()[0];

        // Get operator's nodes
        operatorNodes = middleware.getActiveNodesForEpoch(operator, 0);

        // Set up mock warp messenger
        warpMessenger = new MockWarpMessenger();
        vm.etch(WARP_MESSENGER_ADDR, address(warpMessenger).code);
    }

    function packValidationUptimeMessage(bytes32 validationID, uint256 uptime) public pure returns (bytes memory) {
        return ValidatorMessages.packValidationUptimeMessage(validationID, uint64(uptime));
    }

    function test_ComputeValidatorUptime() public {
        // Start at beginning of epoch 1
        vm.warp(EPOCH_DURATION + 1);

        // First uptime computation during epoch 1
        uptimeTracker.computeValidatorUptime(0);

        uint256 validatorUptime = uptimeTracker.validatorUptimePerEpoch(0, operatorNodes[0]);
        assertEq(validatorUptime, 2 hours, "Incorrect validator uptime recorded for epoch 0");

        // Move to epoch 2
        vm.warp(2 * EPOCH_DURATION + 1);

        // Submit uptime proof after epoch 1 is finished
        // The 3 hours represents 1 hour of uptime in epoch 1 (3h - 2h from epoch 0)
        uptimeTracker.computeValidatorUptime(1);

        // Check recorded uptime for epoch 1
        validatorUptime = uptimeTracker.validatorUptimePerEpoch(1, operatorNodes[0]);
        assertEq(validatorUptime, 1 hours, "Incorrect validator uptime recorded for epoch 1");
    }

    function test_ComputeOperatorUptime() public {
        // Start at beginning of epoch 1
        vm.warp(EPOCH_DURATION + 1);

        // Set different uptimes for each validator node in epoch 0
        uptimeTracker.computeValidatorUptime(2);
        uptimeTracker.computeValidatorUptime(3);
        uptimeTracker.computeValidatorUptime(4);

        // Compute operator uptime for epoch 0
        uptimeTracker.computeOperatorUptimeAt(operator, 0);

        // Check operator uptime (should be average of validator uptimes)
        uint256 operatorUptime = uptimeTracker.operatorUptimePerEpoch(0, operator);
        assertEq(operatorUptime, 2 hours, "Incorrect operator uptime recorded for epoch 0");

        // Move to epoch 2
        vm.warp(2 * EPOCH_DURATION + 1);

        // Set new uptimes for each validator in epoch 1
        uptimeTracker.computeValidatorUptime(5); // +2h from previous
        uptimeTracker.computeValidatorUptime(6); // +1h from previous
        uptimeTracker.computeValidatorUptime(7); // +3h from previous

        // Compute operator uptime for epoch 1
        uptimeTracker.computeOperatorUptimeAt(operator, 1);

        // Check operator uptime for epoch 1 (should be average of incremental uptimes)
        operatorUptime = uptimeTracker.operatorUptimePerEpoch(1, operator);
        assertEq(operatorUptime, 2 hours, "Incorrect operator uptime recorded for epoch 1");

        // Move to epoch 3
        vm.warp(3 * EPOCH_DURATION + 1);

        // Set final uptimes for each validator
        uptimeTracker.computeValidatorUptime(8); // +1h from previous
        uptimeTracker.computeValidatorUptime(9); // +3h from previous
        uptimeTracker.computeValidatorUptime(10); // +2h from previous

        // Compute operator uptime for epoch 2
        uptimeTracker.computeOperatorUptimeAt(operator, 2);

        // Check operator uptime for epoch 2
        operatorUptime = uptimeTracker.operatorUptimePerEpoch(2, operator);
        assertEq(operatorUptime, 2 hours, "Incorrect operator uptime recorded for epoch 2");

        // Verify all epochs are properly set
        assertTrue(uptimeTracker.isOperatorUptimeSet(0, operator), "Epoch 0 uptime should be set");
        assertTrue(uptimeTracker.isOperatorUptimeSet(1, operator), "Epoch 1 uptime should be set");
        assertTrue(uptimeTracker.isOperatorUptimeSet(2, operator), "Epoch 2 uptime should be set");
    }

    function test_RevertIfValidatorUptimeNotRecorded() public {
        vm.warp(EPOCH_DURATION + 1); // Epoch 1

        vm.expectRevert(
            abi.encodeWithSelector(
                IUptimeTracker.UptimeTracker__ValidatorUptimeNotRecorded.selector, 1, operatorNodes[0]
            )
        );
        uptimeTracker.computeOperatorUptimeAt(operator, 1);
    }

    // function testFuzz_ComputeValidatorUptime(
    //     uint256 uptime
    // ) public {
    //     // Bound uptime between 0 and epoch duration
    //     uptime = bound(uptime, 0, EPOCH_DURATION);

    //     // Start at epoch 1
    //     vm.warp(EPOCH_DURATION + 1);

    //     // Set initial uptime
    //     uptimeTracker.computeValidatorUptime(packValidationUptimeMessage(operatorNodes[0], uptime));

    //     // Check uptime is recorded correctly for epoch 1
    //     uint256 recordedUptime = uptimeTracker.validatorUptimePerEpoch(1, operatorNodes[0]);
    //     assertLe(recordedUptime, uptime, "Recorded uptime should not exceed input uptime");
    //     assertTrue(uptimeTracker.isValidatorUptimeSet(0, operatorNodes[0]), "Epoch 1 uptime should be set");

    //     // Move to epoch 2
    //     vm.warp(2 * EPOCH_DURATION + 1);

    //     // Set new uptime
    //     uint256 newUptime = bound(uptime + 1 hours, 0, 2 * EPOCH_DURATION);
    //     uptimeTracker.computeValidatorUptime(packValidationUptimeMessage(operatorNodes[0], newUptime));

    //     // Check uptime is recorded correctly for epoch 1
    //     recordedUptime = uptimeTracker.validatorUptimePerEpoch(1, operatorNodes[0]);
    //     assertLe(recordedUptime, newUptime - uptime, "Recorded uptime should not exceed incremental uptime");
    //     assertTrue(uptimeTracker.isValidatorUptimeSet(1, operatorNodes[0]), "Epoch 1 uptime should be set");
    // }

    function test_ValidatorUptimeEvent() public {
        vm.warp(EPOCH_DURATION + 1); // Epoch 1

        vm.expectEmit(true, true, false, true);
        emit ValidatorUptimeComputed(operatorNodes[0], 0, 2 hours, 1);

        uptimeTracker.computeValidatorUptime(0);
    }

    function test_OperatorUptimeEvent() public {
        vm.warp(EPOCH_DURATION + 1); // Epoch 1

        // Set uptime for all validator nodes
        uptimeTracker.computeValidatorUptime(2);
        uptimeTracker.computeValidatorUptime(3);
        uptimeTracker.computeValidatorUptime(4);

        vm.expectEmit(true, true, false, true);
        emit OperatorUptimeComputed(operator, 0, 2 hours);

        uptimeTracker.computeOperatorUptimeAt(operator, 0);
    }

    function test_EdgeCases() public {
        // Test maximum uptime (exactly EPOCH_DURATION)
        vm.warp(EPOCH_DURATION + 1);
        uptimeTracker.computeValidatorUptime(11);
        assertEq(
            uptimeTracker.validatorUptimePerEpoch(0, operatorNodes[0]), EPOCH_DURATION, "Should accept maximum uptime"
        );

        // Test zero uptime
        uptimeTracker.computeValidatorUptime(12);
        assertEq(uptimeTracker.validatorUptimePerEpoch(0, operatorNodes[1]), 0, "Should accept zero uptime");

        // Test non-consecutive epochs
        vm.warp(3 * EPOCH_DURATION + 1); // Skip to epoch 3
        uptimeTracker.computeValidatorUptime(13); // add 2 full epochs
        assertEq(
            uptimeTracker.validatorUptimePerEpoch(1, operatorNodes[0]),
            EPOCH_DURATION,
            "Should handle non-consecutive epochs"
        );
    }
}
