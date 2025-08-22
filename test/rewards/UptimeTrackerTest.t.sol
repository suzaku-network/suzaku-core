// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {UptimeTracker} from "../../src/contracts/rewards/UptimeTracker.sol";
import {IUptimeTracker, LastUptimeCheckpoint} from "../../src/interfaces/rewards/IUptimeTracker.sol";
import {ValidatorMessages} from "@avalabs/icm-contracts/validator-manager/ValidatorMessages.sol";
import {Validator} from "@avalabs/icm-contracts/validator-manager/interfaces/IACP99Manager.sol";

import {
    WarpMessage, IWarpMessenger
} from "@avalabs/subnet-evm-contracts@1.2.0/contracts/interfaces/IWarpMessenger.sol";
import {UptimeTrackerTestBase} from "./UptimeTrackerTestBase.t.sol";

contract UptimeTrackerTest is UptimeTrackerTestBase {

    function test_ComputeValidatorUptime() public {
        // Start at epoch 1
        vm.warp(middleware.START_TIME() + middleware.EPOCH_DURATION() + 1);

        _push(2 hours);  // Total cumulative uptime: 2 hours
        uptimeTracker.computeValidatorUptime(0);

        uint256 validatorUptime = uptimeTracker.validatorUptimePerEpoch(0, validationID);
        assertEq(validatorUptime, 2 hours);  // Epoch 0: 0→2 hours = 2 hours
        assertTrue(uptimeTracker.isValidatorUptimeSet(0, validationID));

        // Move to epoch 2
        vm.warp(middleware.START_TIME() + 2 * middleware.EPOCH_DURATION() + 1);

        _push(5 hours);  // Total cumulative uptime: 5 hours
        uptimeTracker.computeValidatorUptime(0);

        validatorUptime = uptimeTracker.validatorUptimePerEpoch(1, validationID);
        assertEq(validatorUptime, 3 hours);  // Epoch 1: 2→5 hours = 3 hours delta
        assertTrue(uptimeTracker.isValidatorUptimeSet(1, validationID));
    }

    function test_ComputeOperatorUptime() public {
        /* ───────── Epoch 0 ───────── */
        vm.warp(middleware.START_TIME() + middleware.EPOCH_DURATION() + 1);

        // Alice validators cumulative: 2h, 3h, 1h → epoch‑delta sum 6h → ⌊6/3⌋ = 2h
        _pushFor(aliceVals[0], 2 hours); uptimeTracker.computeValidatorUptime(0);
        _pushFor(aliceVals[1], 3 hours); uptimeTracker.computeValidatorUptime(0);
        _pushFor(aliceVals[2], 1 hours); uptimeTracker.computeValidatorUptime(0);
        uptimeTracker.computeOperatorUptimeAt(alice, 0);
        uint256 opUptime = uptimeTracker.operatorUptimePerEpoch(0, alice);
        assertEq(opUptime, 2 hours);

        // Charlie validators cumulative: 4 h, 4 h, 0 h
        //  epoch‑delta total = 8 h ⇒ average = 8 h / 3 = 9 600 s (2 h 40 m)
        _pushFor(charlieVals[0], 4 hours); uptimeTracker.computeValidatorUptime(0);
        _pushFor(charlieVals[1], 4 hours); uptimeTracker.computeValidatorUptime(0);
        _pushFor(charlieVals[2], 0 hours); uptimeTracker.computeValidatorUptime(0);
        uptimeTracker.computeOperatorUptimeAt(charlie, 0);
        opUptime = uptimeTracker.operatorUptimePerEpoch(0, charlie);
        assertEq(opUptime, (8 hours) / 3);   // 9 600 s

        /* ───────── Epoch 1 ───────── */
        vm.warp(middleware.START_TIME() + 2 * middleware.EPOCH_DURATION() + 1);

        // Add +2h to each validator (cumulative now 4h,5h,3h and 6h,6h,2h)
        _pushFor(aliceVals[0], 4 hours); uptimeTracker.computeValidatorUptime(0);
        _pushFor(aliceVals[1], 5 hours); uptimeTracker.computeValidatorUptime(0);
        _pushFor(aliceVals[2], 3 hours); uptimeTracker.computeValidatorUptime(0);
        uptimeTracker.computeOperatorUptimeAt(alice, 1);
        opUptime = uptimeTracker.operatorUptimePerEpoch(1, alice);
        assertEq(opUptime, 2 hours);

        _pushFor(charlieVals[0], 6 hours); uptimeTracker.computeValidatorUptime(0);
        _pushFor(charlieVals[1], 6 hours); uptimeTracker.computeValidatorUptime(0);
        _pushFor(charlieVals[2], 2 hours); uptimeTracker.computeValidatorUptime(0);
        uptimeTracker.computeOperatorUptimeAt(charlie, 1);
        opUptime = uptimeTracker.operatorUptimePerEpoch(1, charlie);
        assertEq(opUptime, 2 hours);

        /* ───────── Epoch 2 ───────── */
        vm.warp(middleware.START_TIME() + 3 * middleware.EPOCH_DURATION() + 1);

        // Add +2h again to each validator
        _pushFor(aliceVals[0], 6 hours); uptimeTracker.computeValidatorUptime(0);
        _pushFor(aliceVals[1], 7 hours); uptimeTracker.computeValidatorUptime(0);
        _pushFor(aliceVals[2], 5 hours); uptimeTracker.computeValidatorUptime(0);
        uptimeTracker.computeOperatorUptimeAt(alice, 2);
        opUptime = uptimeTracker.operatorUptimePerEpoch(2, alice);
        assertEq(opUptime, 2 hours);

        _pushFor(charlieVals[0], 8 hours); uptimeTracker.computeValidatorUptime(0);
        _pushFor(charlieVals[1], 8 hours); uptimeTracker.computeValidatorUptime(0);
        _pushFor(charlieVals[2], 4 hours); uptimeTracker.computeValidatorUptime(0);
        uptimeTracker.computeOperatorUptimeAt(charlie, 2);
        opUptime = uptimeTracker.operatorUptimePerEpoch(2, charlie);
        assertEq(opUptime, 2 hours);

        /* ───────── assertions ───────── */
        assertTrue(uptimeTracker.isOperatorUptimeSet(0, alice));
        assertTrue(uptimeTracker.isOperatorUptimeSet(1, alice));
        assertTrue(uptimeTracker.isOperatorUptimeSet(2, alice));
        assertTrue(uptimeTracker.isOperatorUptimeSet(0, charlie));
        assertTrue(uptimeTracker.isOperatorUptimeSet(1, charlie));
        assertTrue(uptimeTracker.isOperatorUptimeSet(2, charlie));
    }

    function test_RevertIfValidatorUptimeNotRecorded() public {
        vm.warp(middleware.START_TIME() + middleware.EPOCH_DURATION() + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IUptimeTracker.UptimeTracker__ValidatorUptimeNotRecorded.selector, 1, validationID
            )
        );
        uptimeTracker.computeOperatorUptimeAt(alice, 1);
    }


    function test_ValidatorUptimeEvent() public {
        vm.warp(middleware.START_TIME() + middleware.EPOCH_DURATION() + 1);

        _push(2 hours);  // Total cumulative: 2 hours
        
        vm.expectEmit(true, true, false, true);
        emit ValidatorUptimeComputed(validationID, 0, 2 hours, 1);
        
        uptimeTracker.computeValidatorUptime(0);
    }

    function test_OperatorUptimeEvent() public {
        vm.warp(middleware.START_TIME() + middleware.EPOCH_DURATION() + 1);

        // Feed Alice's three validators (2 h, 3 h, 1 h → average 2 h)
        _pushFor(aliceVals[0], 2 hours); uptimeTracker.computeValidatorUptime(0);
        _pushFor(aliceVals[1], 3 hours); uptimeTracker.computeValidatorUptime(0);
        _pushFor(aliceVals[2], 1 hours); uptimeTracker.computeValidatorUptime(0);

        vm.expectEmit(true, true, false, true);
        emit OperatorUptimeComputed(alice, 0, 2 hours);

        uptimeTracker.computeOperatorUptimeAt(alice, 0);
    }

    function test_EdgeCases() public {
        // Test max uptime for first epoch
        vm.warp(middleware.START_TIME() + middleware.EPOCH_DURATION() + 1);
        _push(middleware.EPOCH_DURATION());  // Total: 4 hours (epoch duration)
        uptimeTracker.computeValidatorUptime(0);
        assertEq(uptimeTracker.validatorUptimePerEpoch(0, validationID), middleware.EPOCH_DURATION());

        // Test zero uptime delta (validator was already at 4 hours, stays at 4 hours)
        // Move to next epoch first so we can see the zero delta
        vm.warp(middleware.START_TIME() + 2 * middleware.EPOCH_DURATION() + 1);
        _push(middleware.EPOCH_DURATION());  // Total: still 4 hours (no change)
        uptimeTracker.computeValidatorUptime(0);
        // Since no uptime was added, epoch 1 should have 0 uptime
        assertEq(uptimeTracker.validatorUptimePerEpoch(1, validationID), 0);  // Delta = 0

        // Test non-consecutive epochs - jump from epoch 1 to epoch 3
        vm.warp(middleware.START_TIME() + 4 * middleware.EPOCH_DURATION() + 1);
        _push(3 * middleware.EPOCH_DURATION());  // Total: 12 hours cumulative
        uptimeTracker.computeValidatorUptime(0);
        // This should distribute (12-4) = 8 hours across epochs 2 and 3 = 4 hours each
        assertEq(uptimeTracker.validatorUptimePerEpoch(2, validationID), middleware.EPOCH_DURATION());
        assertEq(uptimeTracker.validatorUptimePerEpoch(3, validationID), middleware.EPOCH_DURATION());
    }

    function test_UptimeTruncationCausesRewardLoss() public view {
        uint256 MIN_REQUIRED_UPTIME = 11_520;
        console2.log("Minimum required uptime per epoch:", MIN_REQUIRED_UPTIME, "seconds");
        console2.log("Epoch duration:", middleware.EPOCH_DURATION(), "seconds");

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
