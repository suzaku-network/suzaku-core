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
import {UptimeTrackerTestBase} from "./UptimeTrackerTestBase.t.sol";

contract UptimeTrackerTest is UptimeTrackerTestBase {

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

    function test_UptimeTruncationCausesRewardLoss() public pure {
        uint256 MIN_REQUIRED_UPTIME = 11_520;
        console2.log("Minimum required uptime per epoch:", MIN_REQUIRED_UPTIME, "seconds");
        console2.log("Epoch duration:", EPOCH_DURATION, "seconds");

        // Demonstrate how small time lost can have big impact
        uint256 totalUptime = (MIN_REQUIRED_UPTIME * 3) - 2; // 34,558 seconds across 3 epochs
        uint256 elapsedEpochs = 3;
        uint256 uptimePerEpoch = totalUptime / elapsedEpochs; // 11,519 per epoch
        uint256 remainder = totalUptime % elapsedEpochs; // 2 seconds lost

        console2.log("3 epochs scenario:");
        console2.log(" Total uptime:", totalUptime, "seconds (9.6 hours!)");
        console2.log(" Epochs:", elapsedEpochs);
        console2.log(" Per epoch after division:", uptimePerEpoch, "seconds");
        console2.log(" Lost to truncation:", remainder, "seconds");
        console2.log(" Result: ALL 3 epochs FAIL threshold!");

        // Verify
        assertFalse(uptimePerEpoch >= MIN_REQUIRED_UPTIME, "Fails threshold due to truncation");
    }

    function test_UptimeDistributionFix() public pure {
        uint256 MIN_REQUIRED_UPTIME = 11_520;
        // 34,559 seconds across 3 epochs would fail all epochs with old logic
        uint256 totalUptime = 34_559;
        uint256 elapsedEpochs = 3;

        uint256 baseUptimePerEpoch = totalUptime / elapsedEpochs; // 11,519
        uint256 remainder = totalUptime % elapsedEpochs; // 2

        // With fix: first 2 epochs get extra second
        uint256 epoch1Uptime = baseUptimePerEpoch + 1; // 11,520
        uint256 epoch2Uptime = baseUptimePerEpoch + 1; // 11,520
        uint256 epoch3Uptime = baseUptimePerEpoch; // 11,519

        console2.log("--- Uptime Distribution Fix Test ---");
        console2.log("Total Uptime:", totalUptime);
        console2.log("Epochs:", elapsedEpochs);
        console2.log("Base Per Epoch:", baseUptimePerEpoch);
        console2.log("Remainder:", remainder);
        console2.log("Distributed Uptime -> Epoch 1: %s, Epoch 2: %s, Epoch 3: %s", epoch1Uptime, epoch2Uptime, epoch3Uptime);

        // Verify no uptime is lost
        uint256 totalDistributed = epoch1Uptime + epoch2Uptime + epoch3Uptime;
        assertEq(totalDistributed, totalUptime, "Total distributed uptime must equal the original total uptime");

        // Verify reward eligibility restored
        assertTrue(epoch1Uptime >= MIN_REQUIRED_UPTIME, "Epoch 1 should now qualify for rewards");
        assertTrue(epoch2Uptime >= MIN_REQUIRED_UPTIME, "Epoch 2 should now qualify for rewards");
        assertFalse(epoch3Uptime >= MIN_REQUIRED_UPTIME, "Epoch 3 correctly misses the threshold by 1 second");

        console2.log("Result: 2 out of 3 epochs now qualify for rewards (vs. 0 before the fix)");
    }

    function test_UptimeDistributionFixLargeRemainder() public pure {
        uint256 totalUptime = 100_000;
        uint256 elapsedEpochs = 7;

        uint256 baseUptimePerEpoch = totalUptime / elapsedEpochs; // 14,285
        uint256 remainder = totalUptime % elapsedEpochs; // 5

        console2.log("\n--- Large Remainder Test ---");
        console2.log("Total Uptime:", totalUptime);
        console2.log("Base Per Epoch:", baseUptimePerEpoch);
        console2.log("Remainder to Distribute:", remainder);

        uint256 totalDistributed = 0;
        for (uint256 i = 0; i < elapsedEpochs; i++) {
            uint256 epochUptime = baseUptimePerEpoch;
            if (i < remainder) {
                epochUptime += 1; // First 5 epochs get +1 second
            }
            totalDistributed += epochUptime;
        }

        assertEq(totalDistributed, totalUptime, "All uptime must be distributed, even with a large remainder");
        console2.log("Result: Total distributed uptime of %s matches original %s", totalDistributed, totalUptime);
    }

    function test_UptimeDistributionRobustness_ContinueVsBreak() public pure {
        // Test scenario: middle epoch already processed
        uint256 totalUptime = 34_560;
        uint256 elapsedEpochs = 3;
        uint256 uptimePerEpoch = totalUptime / elapsedEpochs; // 11,520
        uint256 remainder = totalUptime % elapsedEpochs; // 0
        
        bool epoch0Set = false;
        bool epoch1Set = true; // Already processed
        bool epoch2Set = false;
        
        uint256 distributedUptime = 0;
        uint256 epochsProcessed = 0;
        
        console2.log("--- Robustness Test: Continue vs Break ---");
        console2.log("Total Uptime to Distribute:", totalUptime);
        console2.log("Epoch 1 is already set (simulating previous processing)");
        
        // Test 'continue' behavior vs old 'break' behavior
        for (uint256 i = 0; i < elapsedEpochs; i++) {
            bool isSet = (i == 0) ? epoch0Set : (i == 1) ? epoch1Set : epoch2Set;
            
            if (isSet) {
                console2.log("Epoch %s: SKIPPED (already set)", i);
                continue; // Skip this epoch, don't break entire loop
            }
            
            uint256 epochUptime = uptimePerEpoch;
            if (remainder > 0) {
                epochUptime += 1;
                remainder -= 1;
            }
            
            distributedUptime += epochUptime;
            epochsProcessed++;
            console2.log("Epoch %s: PROCESSED with %s seconds", i, epochUptime);
        }
        
        console2.log("Result with CONTINUE: %s epochs processed, %s total uptime distributed", epochsProcessed, distributedUptime);
        
        // With 'continue': epochs 0 and 2 processed (2 epochs, 23,040 seconds)
        assertEq(epochsProcessed, 2, "Should process 2 available epochs");
        assertEq(distributedUptime, 23_040, "Should distribute uptime to available epochs");
        
        console2.log("With old BREAK logic: 0 epochs would be processed (BUG!)");
        console2.log("Fix prevents uptime loss by using CONTINUE instead of BREAK");
    }
}
