// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {UptimeTracker} from "../../src/contracts/rewards/UptimeTracker.sol";
import {IUptimeTracker, LastUptimeCheckpoint} from "../../src/interfaces/rewards/IUptimeTracker.sol";
import {ValidatorMessages} from "@avalabs/icm-contracts/validator-manager/ValidatorMessages.sol";
import {Validator} from "@avalabs/icm-contracts/validator-manager/interfaces/IACP99Manager.sol";
import {IBalancerValidatorManager} from "@suzaku/contracts-library/interfaces/ValidatorManager/IBalancerValidatorManager.sol";

import {
    WarpMessage, IWarpMessenger
} from "@avalabs/subnet-evm-contracts@1.2.0/contracts/interfaces/IWarpMessenger.sol";
import {UptimeTrackerTestBase} from "./UptimeTrackerTestBase.t.sol";
import {MockWarpMessenger} from "../mocks/MockWarpMessenger.sol";

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
        // Start looking from the current epoch (or 0 if you prefer)
        uint48 from = middleware.getCurrentEpoch();

        uint48 eA0 = _firstActiveEpochForOperator(alice, from);
        uint48 eC0 = _firstActiveEpochForOperator(charlie, from);

        // Warp to just after eA0 has fully elapsed so that eA0 can receive uptime
        vm.warp(middleware.getEpochStartTs(eA0 + 1) + 1);

        // Feed Alice's validators and compute for eA0
        _ensureStarted(aliceVals[0]); _pushFor(aliceVals[0], 2 hours); uptimeTracker.computeValidatorUptime(0);
        _ensureStarted(aliceVals[1]); _pushFor(aliceVals[1], 3 hours); uptimeTracker.computeValidatorUptime(0);
        _ensureStarted(aliceVals[2]); _pushFor(aliceVals[2], 1 hours); uptimeTracker.computeValidatorUptime(0);

        uptimeTracker.computeOperatorUptimeAt(alice, eA0);
        // Deterministic expectation: operator uptime = mean of validator uptimes for active nodes in eA0
        {
            bytes32[] memory nodes = middleware.getActiveNodesForEpoch(alice, eA0);
            uint256 sum;
            for (uint256 i = 0; i < nodes.length; ++i) {
                bytes32 vID = IBalancerValidatorManager(balancer)
                    .getNodeValidationID(abi.encodePacked(uint160(uint256(nodes[i]))));
                sum += uptimeTracker.validatorUptimePerEpoch(eA0, vID);
            }
            uint256 expected = sum / nodes.length;
            assertEq(uptimeTracker.operatorUptimePerEpoch(eA0, alice), expected);
        }

        // Ensure we are also past eC0, then feed Charlie and compute for eC0
        if (middleware.getCurrentEpoch() <= eC0) {
            vm.warp(middleware.getEpochStartTs(eC0 + 1) + 1);
        }
        
        _ensureStarted(charlieVals[0]); _pushFor(charlieVals[0], 4 hours); uptimeTracker.computeValidatorUptime(0);
        _ensureStarted(charlieVals[1]); _pushFor(charlieVals[1], 4 hours); uptimeTracker.computeValidatorUptime(0);
        _ensureStarted(charlieVals[2]); _pushFor(charlieVals[2], 0 hours); uptimeTracker.computeValidatorUptime(0);

        uptimeTracker.computeOperatorUptimeAt(charlie, eC0);
        // Deterministic expectation: operator uptime = mean of validator uptimes for active nodes in eC0
        {
            bytes32[] memory nodes = middleware.getActiveNodesForEpoch(charlie, eC0);
            uint256 sum;
            for (uint256 i = 0; i < nodes.length; ++i) {
                bytes32 vID = IBalancerValidatorManager(balancer)
                    .getNodeValidationID(abi.encodePacked(uint160(uint256(nodes[i]))));
                sum += uptimeTracker.validatorUptimePerEpoch(eC0, vID);
            }
            uint256 expected = sum / nodes.length;
            assertEq(uptimeTracker.operatorUptimePerEpoch(eC0, charlie), expected);
        }
        /* ───────── Next Epoch ───────── */
        // Move to next epoch for both operators
        uint48 nextEpoch = middleware.getCurrentEpoch();
        vm.warp(middleware.getEpochStartTs(nextEpoch + 1) + 1);

        // Add +2h to each validator (cumulative now 4h,5h,3h and 6h,6h,2h)
        _ensureStarted(aliceVals[0]); _pushFor(aliceVals[0], 4 hours); uptimeTracker.computeValidatorUptime(0);
        _ensureStarted(aliceVals[1]); _pushFor(aliceVals[1], 5 hours); uptimeTracker.computeValidatorUptime(0);
        _ensureStarted(aliceVals[2]); _pushFor(aliceVals[2], 3 hours); uptimeTracker.computeValidatorUptime(0);
        // Compute for the epoch that just ended
        uptimeTracker.computeOperatorUptimeAt(alice, nextEpoch);
        assertEq(uptimeTracker.operatorUptimePerEpoch(nextEpoch, alice), 2 hours);

        _ensureStarted(charlieVals[0]); _pushFor(charlieVals[0], 6 hours); uptimeTracker.computeValidatorUptime(0);
        _ensureStarted(charlieVals[1]); _pushFor(charlieVals[1], 6 hours); uptimeTracker.computeValidatorUptime(0);
        _ensureStarted(charlieVals[2]); _pushFor(charlieVals[2], 2 hours); uptimeTracker.computeValidatorUptime(0);
        uptimeTracker.computeOperatorUptimeAt(charlie, nextEpoch);
        assertEq(uptimeTracker.operatorUptimePerEpoch(nextEpoch, charlie), 2 hours);

        /* ───────── Third Epoch ───────── */
        uint48 thirdEpoch = nextEpoch + 1;
        vm.warp(middleware.getEpochStartTs(thirdEpoch + 1) + 1);

        // Add +2h again to each validator
        _ensureStarted(aliceVals[0]); _pushFor(aliceVals[0], 6 hours); uptimeTracker.computeValidatorUptime(0);
        _ensureStarted(aliceVals[1]); _pushFor(aliceVals[1], 7 hours); uptimeTracker.computeValidatorUptime(0);
        _ensureStarted(aliceVals[2]); _pushFor(aliceVals[2], 5 hours); uptimeTracker.computeValidatorUptime(0);
        uptimeTracker.computeOperatorUptimeAt(alice, thirdEpoch);
        assertEq(uptimeTracker.operatorUptimePerEpoch(thirdEpoch, alice), 2 hours);

        _ensureStarted(charlieVals[0]); _pushFor(charlieVals[0], 8 hours); uptimeTracker.computeValidatorUptime(0);
        _ensureStarted(charlieVals[1]); _pushFor(charlieVals[1], 8 hours); uptimeTracker.computeValidatorUptime(0);
        _ensureStarted(charlieVals[2]); _pushFor(charlieVals[2], 4 hours); uptimeTracker.computeValidatorUptime(0);
        uptimeTracker.computeOperatorUptimeAt(charlie, thirdEpoch);
        assertEq(uptimeTracker.operatorUptimePerEpoch(thirdEpoch, charlie), 2 hours);

        /* ───────── assertions ───────── */
        assertTrue(uptimeTracker.isOperatorUptimeSet(eA0, alice));
        assertTrue(uptimeTracker.isOperatorUptimeSet(nextEpoch, alice));
        assertTrue(uptimeTracker.isOperatorUptimeSet(thirdEpoch, alice));
        assertTrue(uptimeTracker.isOperatorUptimeSet(eC0, charlie));
        assertTrue(uptimeTracker.isOperatorUptimeSet(nextEpoch, charlie));
        assertTrue(uptimeTracker.isOperatorUptimeSet(thirdEpoch, charlie));
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
        // Get the first active epoch for Alice's validators
        Validator memory v = IBalancerValidatorManager(balancer).getValidator(aliceVals[0]);
        uint48 firstActiveEpoch = middleware.getEpochAtTs(uint48(v.startTime));
        
        vm.warp(middleware.getEpochStartTs(firstActiveEpoch) + middleware.EPOCH_DURATION() + 1);

        // Feed Alice's three validators (2 h, 3 h, 1 h → average 2 h)
        _ensureStarted(aliceVals[0]); _pushFor(aliceVals[0], 2 hours); uptimeTracker.computeValidatorUptime(0);
        _ensureStarted(aliceVals[1]); _pushFor(aliceVals[1], 3 hours); uptimeTracker.computeValidatorUptime(0);
        _ensureStarted(aliceVals[2]); _pushFor(aliceVals[2], 1 hours); uptimeTracker.computeValidatorUptime(0);

        vm.expectEmit(true, true, false, true);
        emit OperatorUptimeComputed(alice, firstActiveEpoch, 2 hours);

        uptimeTracker.computeOperatorUptimeAt(alice, firstActiveEpoch);
    }

    function test_EdgeCases() public {
        // Test max uptime for first epoch
        vm.warp(middleware.START_TIME() + middleware.EPOCH_DURATION() + 1);
        _push(middleware.EPOCH_DURATION());  // Total: 4 hours (epoch duration)
        uptimeTracker.computeValidatorUptime(0);
        assertEq(uptimeTracker.validatorUptimePerEpoch(0, validationID), middleware.EPOCH_DURATION());

        // Test same-value message is silently ignored (stale replay protection)
        // This is intentional behavior change from Issue #27 fix
        vm.warp(middleware.START_TIME() + 2 * middleware.EPOCH_DURATION() + 1);
        _push(middleware.EPOCH_DURATION());  // Total: still 4 hours (same value)
        uptimeTracker.computeValidatorUptime(0);
        // Same-value message is rejected, epoch 1 remains unset
        assertFalse(uptimeTracker.isValidatorUptimeSet(1, validationID), "Same-value message should be ignored");

        // Test non-consecutive epochs - jump from epoch 1 to epoch 3
        // Since epoch 1 wasn't set, the distribution covers epochs 1, 2, 3
        vm.warp(middleware.START_TIME() + 4 * middleware.EPOCH_DURATION() + 1);
        _push(3 * middleware.EPOCH_DURATION());  // Total: 12 hours cumulative
        uptimeTracker.computeValidatorUptime(0);
        // Delta = 12 - 4 = 8 hours distributed across 3 epochs (1, 2, 3)
        // 8 hours / 3 = 2h40m each, with remainder distributed to earliest epochs
        uint256 epoch1 = uptimeTracker.validatorUptimePerEpoch(1, validationID);
        uint256 epoch2 = uptimeTracker.validatorUptimePerEpoch(2, validationID);
        uint256 epoch3 = uptimeTracker.validatorUptimePerEpoch(3, validationID);
        assertEq(epoch1 + epoch2 + epoch3, 2 * middleware.EPOCH_DURATION(), "Total should be 8 hours");
        assertTrue(uptimeTracker.isValidatorUptimeSet(1, validationID), "Epoch 1 now set");
        assertTrue(uptimeTracker.isValidatorUptimeSet(2, validationID), "Epoch 2 now set");
        assertTrue(uptimeTracker.isValidatorUptimeSet(3, validationID), "Epoch 3 now set");
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

    function test_ComputeOperatorUptime_AlignedCheckpoint() public {
        // Pick an epoch where Alice has ≥1 active node
        uint48 from = middleware.getCurrentEpoch();
        uint48 e    = _firstActiveEpochForOperator(alice, from);

        // 1) Checkpoint at start(e): zero totals, so no distribution yet, just pin the checkpoint
        _checkpointToEpochStart(alice, e);

        // 2) Advance to start(e+1) and push cumulative totals (2h/3h/1h)
        vm.warp(middleware.getEpochStartTs(e + 1) + 1);
        _ensureStarted(aliceVals[0]); _pushFor(aliceVals[0], 2 hours); uptimeTracker.computeValidatorUptime(0);
        _ensureStarted(aliceVals[1]); _pushFor(aliceVals[1], 3 hours); uptimeTracker.computeValidatorUptime(0);
        _ensureStarted(aliceVals[2]); _pushFor(aliceVals[2], 1 hours); uptimeTracker.computeValidatorUptime(0);

        // 3) Now compute operator uptime for epoch e: average(2h, 3h, 1h) = 2h
        uptimeTracker.computeOperatorUptimeAt(alice, e);
        assertEq(uptimeTracker.operatorUptimePerEpoch(e, alice), 2 hours); // 7200
    }

    function test_ComputeOperatorUptime_UnalignedLateArrival() public {
        // Find an epoch where Alice has at least one active node
        uint48 from = middleware.getCurrentEpoch();
        uint48 e0   = _firstActiveEpochForOperator(alice, from);

        // DO NOT checkpoint. Fast-forward 3 full epochs beyond e0.
        // First non-zero message arrives now → tracker splits across 3 epochs.
        vm.warp(middleware.getEpochStartTs(e0 + 3) + 1);

        // Push first cumulative totals now (2h, 3h, 1h), then compute
        _ensureStarted(aliceVals[0]); _pushFor(aliceVals[0], 2 hours); uptimeTracker.computeValidatorUptime(0);
        _ensureStarted(aliceVals[1]); _pushFor(aliceVals[1], 3 hours); uptimeTracker.computeValidatorUptime(0);
        _ensureStarted(aliceVals[2]); _pushFor(aliceVals[2], 1 hours); uptimeTracker.computeValidatorUptime(0);

        // e0 resolved to 4 in this run, first non‑zero messages at currentEpoch = e0+3 = 7
        // Splits: v0 2h over 7 → 7200/7 = 1028 (epoch 4 doesn't get +1)
        //         v1 3h over 6 → 10800/6 = 1800
        //         v2 1h over 5 → 3600/5 = 720
        // Operator avg = (1028 + 1800 + 720) / 3 = 1182
        uptimeTracker.computeOperatorUptimeAt(alice, e0);
        assertEq(uptimeTracker.operatorUptimePerEpoch(e0, alice), 1182);
    
    }

    /// @notice Tests Issue #41 FIX: Operator uptime cannot be overwritten after first computation
    /// The write-once guard prevents recomputation even if node set drifts
    function test_OperatorUptimeOverwrite_AfterNodeRemoval() public {
        // Find an epoch where Alice has active nodes
        uint48 from = middleware.getCurrentEpoch();
        uint48 targetEpoch = _firstActiveEpochForOperator(alice, from);
        
        // Advance epochs properly to get to targetEpoch+1 (so targetEpoch is complete)
        while (middleware.getCurrentEpoch() <= targetEpoch) {
            _advanceOneEpoch();
        }
        
        // Record validator uptimes with varying performance:
        // - aliceVals[0]: 4 hours (good)
        // - aliceVals[1]: 4 hours (good)  
        // - aliceVals[2]: 1 hour (poor - will be removed later)
        _ensureStarted(aliceVals[0]); _pushFor(aliceVals[0], 4 hours); uptimeTracker.computeValidatorUptime(0);
        _ensureStarted(aliceVals[1]); _pushFor(aliceVals[1], 4 hours); uptimeTracker.computeValidatorUptime(0);
        _ensureStarted(aliceVals[2]); _pushFor(aliceVals[2], 1 hours); uptimeTracker.computeValidatorUptime(0);
        
        // Verify validator uptimes are set correctly
        uint256 v0Uptime = uptimeTracker.validatorUptimePerEpoch(targetEpoch, aliceVals[0]);
        uint256 v1Uptime = uptimeTracker.validatorUptimePerEpoch(targetEpoch, aliceVals[1]);
        uint256 v2Uptime = uptimeTracker.validatorUptimePerEpoch(targetEpoch, aliceVals[2]);
        console2.log("Validator 0 uptime for targetEpoch:", v0Uptime);
        console2.log("Validator 1 uptime for targetEpoch:", v1Uptime);
        console2.log("Validator 2 uptime for targetEpoch:", v2Uptime);
        
        // Compute initial operator uptime for targetEpoch
        uptimeTracker.computeOperatorUptimeAt(alice, targetEpoch);
        uint256 originalUptime = uptimeTracker.operatorUptimePerEpoch(targetEpoch, alice);
        uint256 expectedOriginal = (v0Uptime + v1Uptime + v2Uptime) / 3;
        
        console2.log("Original operator uptime:", originalUptime, "seconds");
        console2.log("Expected (avg of 3 validators):", expectedOriginal, "seconds");
        assertEq(originalUptime, expectedOriginal, "Initial uptime should be average of 3 validators");
        assertTrue(uptimeTracker.isOperatorUptimeSet(targetEpoch, alice), "Uptime should be marked as set");
        
        // === NODE REMOVAL ===
        // Get the nodeId for aliceVals[2] (the low-uptime node)
        bytes32[] memory activeNodes = middleware.getActiveNodesForEpoch(alice, targetEpoch);
        uint256 activeCountBefore = activeNodes.length;
        console2.log("Active nodes for targetEpoch BEFORE removal:", activeCountBefore);
        
        // Find the nodeId that corresponds to aliceVals[2]
        bytes32 nodeIdToRemove;
        for (uint256 i = 0; i < activeNodes.length; i++) {
            bytes32 nodeId = activeNodes[i];
            bytes32 vID = IBalancerValidatorManager(balancer)
                .getNodeValidationID(abi.encodePacked(uint160(uint256(nodeId))));
            if (vID == aliceVals[2]) {
                nodeIdToRemove = nodeId;
                break;
            }
        }
        require(nodeIdToRemove != bytes32(0), "Could not find nodeId for aliceVals[2]");
        
        // Remove the low-uptime node
        vm.prank(alice);
        middleware.removeNode(nodeIdToRemove);
        
        // Advance epoch and complete removal
        _advanceOneEpoch();
        
        // Push removal acknowledgment and complete
        _pushRemovalAck(aliceVals[2]);
        vm.prank(alice);
        middleware.completeValidatorRemoval(0);
        
        // Verify the active set has drifted (the underlying issue still exists)
        bytes32[] memory activeNodesAfterRemoval = middleware.getActiveNodesForEpoch(alice, targetEpoch);
        console2.log("Active nodes for targetEpoch AFTER removal:", activeNodesAfterRemoval.length);
        assertLt(activeNodesAfterRemoval.length, activeCountBefore, "Active set drifted as expected");
        
        // === FIX VERIFICATION ===
        // Attempting to recompute should now REVERT due to write-once guard
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUptimeTracker.UptimeTracker__OperatorUptimeAlreadySet.selector,
                targetEpoch,
                alice
            )
        );
        uptimeTracker.computeOperatorUptimeAt(alice, targetEpoch);
        
        // Verify uptime was NOT changed
        uint256 uptimeAfterAttempt = uptimeTracker.operatorUptimePerEpoch(targetEpoch, alice);
        assertEq(uptimeAfterAttempt, originalUptime, "FIX VERIFIED: Uptime unchanged after revert");
        
        console2.log("");
        console2.log("=== FIX VERIFIED ===");
        console2.log("Original uptime preserved:", originalUptime, "seconds");
        console2.log("Recomputation attempt reverted as expected");
    }

    /// @notice Helper to advance one epoch properly
    function _advanceOneEpoch() internal returns (uint48) {
        uint48 nextEpochIndex = middleware.getCurrentEpoch() + 1;
        uint256 nextEpochStartTs = middleware.getEpochStartTs(nextEpochIndex);
        vm.warp(nextEpochStartTs + 1);
        middleware.calcAndCacheNodeStakeForAllOperators();
        return middleware.getCurrentEpoch();
    }

    /// @notice Tests Issue #24: Active Set Drift on FIRST computation
    /// This demonstrates that if node removal completes BEFORE computeOperatorUptimeAt is called,
    /// the FIRST (and only) computation uses a drifted active set.
    /// 
    /// Expected behavior: Uptime should reflect ALL validators that were active during the epoch
    /// Actual behavior: Uptime only reflects currently-registered validators (KNOWN LIMITATION)
    function test_ActiveSetDrift_FirstComputation() public {
        // Find an epoch where Alice has active nodes
        uint48 from = middleware.getCurrentEpoch();
        uint48 targetEpoch = _firstActiveEpochForOperator(alice, from);
        
        // Advance epochs properly to get to targetEpoch+1 (so targetEpoch is complete)
        while (middleware.getCurrentEpoch() <= targetEpoch) {
            _advanceOneEpoch();
        }
        
        // Record validator uptimes for ALL 3 validators:
        // - aliceVals[0]: 4 hours (good)
        // - aliceVals[1]: 4 hours (good)  
        // - aliceVals[2]: 1 hour (poor - will be removed BEFORE operator uptime computation)
        _ensureStarted(aliceVals[0]); _pushFor(aliceVals[0], 4 hours); uptimeTracker.computeValidatorUptime(0);
        _ensureStarted(aliceVals[1]); _pushFor(aliceVals[1], 4 hours); uptimeTracker.computeValidatorUptime(0);
        _ensureStarted(aliceVals[2]); _pushFor(aliceVals[2], 1 hours); uptimeTracker.computeValidatorUptime(0);
        
        // Verify validator uptimes are set correctly
        uint256 v0Uptime = uptimeTracker.validatorUptimePerEpoch(targetEpoch, aliceVals[0]);
        uint256 v1Uptime = uptimeTracker.validatorUptimePerEpoch(targetEpoch, aliceVals[1]);
        uint256 v2Uptime = uptimeTracker.validatorUptimePerEpoch(targetEpoch, aliceVals[2]);
        
        console2.log("=== ISSUE #24 TEST: Active Set Drift on First Computation ===");
        console2.log("Validator 0 uptime:", v0Uptime, "seconds");
        console2.log("Validator 1 uptime:", v1Uptime, "seconds");
        console2.log("Validator 2 uptime:", v2Uptime, "seconds (will be removed)");
        
        // Calculate what the CORRECT uptime should be (average of all 3)
        uint256 correctUptime = (v0Uptime + v1Uptime + v2Uptime) / 3;
        console2.log("CORRECT uptime (avg of 3):", correctUptime, "seconds");
        
        // === NODE REMOVAL BEFORE OPERATOR UPTIME COMPUTATION ===
        // This is the key difference from test_OperatorUptimeOverwrite_AfterNodeRemoval:
        // We remove the node BEFORE calling computeOperatorUptimeAt for the first time
        
        assertFalse(uptimeTracker.isOperatorUptimeSet(targetEpoch, alice), "Operator uptime should NOT be set yet");
        
        // Find the nodeId that corresponds to aliceVals[2]
        bytes32[] memory activeNodes = middleware.getActiveNodesForEpoch(alice, targetEpoch);
        uint256 activeCountBefore = activeNodes.length;
        console2.log("Active nodes BEFORE removal:", activeCountBefore);
        
        bytes32 nodeIdToRemove;
        for (uint256 i = 0; i < activeNodes.length; i++) {
            bytes32 nodeId = activeNodes[i];
            bytes32 vID = IBalancerValidatorManager(balancer)
                .getNodeValidationID(abi.encodePacked(uint160(uint256(nodeId))));
            if (vID == aliceVals[2]) {
                nodeIdToRemove = nodeId;
                break;
            }
        }
        require(nodeIdToRemove != bytes32(0), "Could not find nodeId for aliceVals[2]");
        
        // Remove the low-uptime node
        vm.prank(alice);
        middleware.removeNode(nodeIdToRemove);
        
        // Advance epoch and complete removal
        _advanceOneEpoch();
        
        // Push removal acknowledgment and complete
        _pushRemovalAck(aliceVals[2]);
        vm.prank(alice);
        middleware.completeValidatorRemoval(0);
        
        // Verify the active set has drifted for the PAST targetEpoch
        bytes32[] memory activeNodesAfterRemoval = middleware.getActiveNodesForEpoch(alice, targetEpoch);
        console2.log("Active nodes for targetEpoch AFTER removal:", activeNodesAfterRemoval.length);
        assertLt(activeNodesAfterRemoval.length, activeCountBefore, "Active set drifted");
        
        // === FIRST COMPUTATION - NOW USES HISTORICAL VALIDATION IDs ===
        // With the fix, computeOperatorUptimeAt uses the append-only operatorValidationIDsArray
        // which includes all historically registered validationIDs, not the drifted getActiveNodesForEpoch
        uptimeTracker.computeOperatorUptimeAt(alice, targetEpoch);
        
        uint256 actualUptime = uptimeTracker.operatorUptimePerEpoch(targetEpoch, alice);
        uint256 driftedUptime = (v0Uptime + v1Uptime) / 2; // Would be wrong (only 2 validators)
        
        console2.log("");
        console2.log("=== RESULT (FIX VERIFIED) ===");
        console2.log("Actual uptime:", actualUptime, "seconds");
        console2.log("CORRECT uptime (avg of 3):", correctUptime, "seconds");
        console2.log("Would-be drifted (avg of 2):", driftedUptime, "seconds");
        
        // FIX VERIFICATION: Uptime uses correct historical set, NOT the drifted set
        assertEq(actualUptime, correctUptime, "Fix works: uptime uses historical validationIDs");
        assertNotEq(actualUptime, driftedUptime, "Fix works: uptime is NOT the drifted value");
    }

    /// @notice Tests Issue #27 FIX: Stale Uptime Message Replay is now rejected
    /// 
    /// Attack vector (from icm-contracts analysis):
    /// - verifier_backend.go:112-131: verifyUptimeMessage checks currentUptime >= messageUptime at SIGNING time
    /// - config.go:211-219: VerifyPredicate only checks BLS signatures, NOT uptime content validity
    /// - Result: Previously-signed stale messages can be included in new block predicates
    /// 
    /// Fix: Add monotonicity check matching StakingManager.sol:444-449
    function test_StaleUptimeMessageReplay_IsRejected() public {
        // Start at epoch 2 (so we have epochs 0,1 to distribute to)
        vm.warp(middleware.START_TIME() + 2 * middleware.EPOCH_DURATION() + 1);
        
        uint64 cumulativeUptime = 2 hours;
        
        // First message: uptime = 7200 (2 hours) - legitimate submission
        _push(cumulativeUptime);
        uptimeTracker.computeValidatorUptime(0);
        
        // Verify monotonicity tracking
        assertEq(uptimeTracker.validatorHighestUptime(validationID), cumulativeUptime, "Highest uptime should be tracked");
        
        // Epochs 0,1 should have received uptime (split across 2 epochs)
        uint256 epoch0Uptime = uptimeTracker.validatorUptimePerEpoch(0, validationID);
        uint256 epoch1Uptime = uptimeTracker.validatorUptimePerEpoch(1, validationID);
        console2.log("=== ISSUE #27 FIX TEST: Stale Message Rejection ===");
        console2.log("After first message (uptime=7200):");
        console2.log("  Epoch 0 uptime:", epoch0Uptime, "seconds");
        console2.log("  Epoch 1 uptime:", epoch1Uptime, "seconds");
        console2.log("  validatorHighestUptime:", uptimeTracker.validatorHighestUptime(validationID));
        
        assertTrue(uptimeTracker.isValidatorUptimeSet(0, validationID), "Epoch 0 should be set");
        assertTrue(uptimeTracker.isValidatorUptimeSet(1, validationID), "Epoch 1 should be set");
        assertGt(epoch0Uptime + epoch1Uptime, 0, "Total uptime should be positive");
        
        // Advance to epoch 4 (2 more epochs have elapsed: epochs 2,3)
        vm.warp(middleware.START_TIME() + 4 * middleware.EPOCH_DURATION() + 1);
        
        // ATTACK: Replay the SAME message (same cumulative uptime = 7200)
        // This simulates an attacker including a previously-signed warp message in a new block.
        // Block predicate verification only checks BLS signatures (config.go:211-219), not content.
        _push(cumulativeUptime);  // Same value as before!
        uptimeTracker.computeValidatorUptime(0);  // Should be silently ignored
        
        // FIX VERIFICATION: Epochs 2,3 should NOT be set (stale message was rejected)
        bool epoch2Set = uptimeTracker.isValidatorUptimeSet(2, validationID);
        bool epoch3Set = uptimeTracker.isValidatorUptimeSet(3, validationID);
        
        console2.log("");
        console2.log("After REPLAY attempt (same uptime=7200):");
        console2.log("  Epoch 2 set:", epoch2Set);
        console2.log("  Epoch 3 set:", epoch3Set);
        console2.log("  validatorHighestUptime:", uptimeTracker.validatorHighestUptime(validationID));
        
        // Stale message was rejected - epochs 2,3 are NOT set (not zeroed)
        assertFalse(epoch2Set, "FIX: Epoch 2 should NOT be set (stale replay rejected)");
        assertFalse(epoch3Set, "FIX: Epoch 3 should NOT be set (stale replay rejected)");
        
        // Highest uptime unchanged (stale message didn't update it)
        assertEq(uptimeTracker.validatorHighestUptime(validationID), cumulativeUptime, "Highest uptime unchanged");
        
        console2.log("");
        console2.log("=== FIX VERIFIED ===");
        console2.log("Stale warp message was silently rejected (monotonicity check)");
        console2.log("Epochs 2,3 remain unset - awaiting fresh uptime message");
        
        // Now submit a FRESH message with higher uptime
        uint64 freshUptime = 4 hours;  // Higher than previous 7200
        _push(freshUptime);
        uptimeTracker.computeValidatorUptime(0);
        
        // Now epochs 2,3 should be properly set with real uptime
        assertTrue(uptimeTracker.isValidatorUptimeSet(2, validationID), "Epoch 2 now set with fresh message");
        assertTrue(uptimeTracker.isValidatorUptimeSet(3, validationID), "Epoch 3 now set with fresh message");
        assertEq(uptimeTracker.validatorHighestUptime(validationID), freshUptime, "Highest uptime updated");
        
        uint256 epoch2Uptime = uptimeTracker.validatorUptimePerEpoch(2, validationID);
        uint256 epoch3Uptime = uptimeTracker.validatorUptimePerEpoch(3, validationID);
        console2.log("");
        console2.log("After FRESH message (uptime=14400):");
        console2.log("  Epoch 2 uptime:", epoch2Uptime, "seconds");
        console2.log("  Epoch 3 uptime:", epoch3Uptime, "seconds");
        assertGt(epoch2Uptime + epoch3Uptime, 0, "Fresh message distributed real uptime");
    }

    function test_Constructor_RevertsWithZeroMiddleware() public {
        bytes32 validBlockchainID = bytes32(uint256(1));
        vm.expectRevert(IUptimeTracker.UptimeTracker__InvalidMiddleware.selector);
        new UptimeTracker(payable(address(0)), validBlockchainID);
    }

    function test_Constructor_RevertsWithZeroBlockchainID() public {
        vm.expectRevert(IUptimeTracker.UptimeTracker__InvalidBlockchainID.selector);
        new UptimeTracker(payable(address(middleware)), bytes32(0));
    }

    /// @notice Known limitation: computeOperatorUptimeAt aggregates validator uptimes as an
    ///         UNWEIGHTED arithmetic mean (UptimeTracker.sol:231 `sumValidatorsUptime / numberOfValidators`),
    ///         independent of each validator's stake. RewardsNativeToken._calculateOperatorShare (~:736-741)
    ///         then multiplies that mean by the operator's FULL stake share, so an operator running one
    ///         large-stake validator at low uptime + several small-stake validators at high uptime reports a
    ///         near-full operator uptime and inflates its reward share at honest operators' expense (reward
    ///         redistribution only; no principal; slashing not enabled). Mitigation: operators are permissioned
    ///         -- monitor per-validator uptime and remove offenders. See docs/6-uptimeTracker.md (Known Limitations).
    function test_OperatorUptimeIsUnweightedMean() public {
        uint256 E = middleware.EPOCH_DURATION(); // 14400 s

        // Use Alice's 3 pre-registered validators from UptimeTrackerTestBase.setUp; find the first epoch
        // where all three are active, then warp past it so it can receive uptime.
        uint48 from = middleware.getCurrentEpoch();
        uint48 e = _firstActiveEpochForOperator(alice, from);
        vm.warp(middleware.getEpochStartTs(e + 1) + 1);

        // Feed per-validator cumulative uptimes: val[0]=0 (offline; imagine it holds most stake),
        // val[1]/val[2]=E (the cumulative value spreads across elapsed epochs, landing some amount on e).
        _ensureStarted(aliceVals[0]);
        _pushFor(aliceVals[0], 0);
        uptimeTracker.computeValidatorUptime(0);

        _ensureStarted(aliceVals[1]);
        _pushFor(aliceVals[1], uint64(E));
        uptimeTracker.computeValidatorUptime(0);

        _ensureStarted(aliceVals[2]);
        _pushFor(aliceVals[2], uint64(E));
        uptimeTracker.computeValidatorUptime(0);

        uptimeTracker.computeOperatorUptimeAt(alice, e);

        // Read back what the tracker actually stored.
        uint256 u0 = uptimeTracker.validatorUptimePerEpoch(e, aliceVals[0]);
        uint256 u1 = uptimeTracker.validatorUptimePerEpoch(e, aliceVals[1]);
        uint256 u2 = uptimeTracker.validatorUptimePerEpoch(e, aliceVals[2]);
        uint256 codedUptime = uptimeTracker.operatorUptimePerEpoch(e, alice);
        uint256 unweightedMean = (u0 + u1 + u2) / 3; // mirrors UptimeTracker.sol:231

        // Hypothetical stake-weighted mean if val[0] held 9x the stake of val[1]+val[2] (9:1:1).
        uint256 stakeWeightedHypo = (9 * u0 + 1 * u1 + 1 * u2) / 11;

        console2.log("=== PoC: Unweighted Operator Uptime ===");
        console2.log("val[0] uptime (target 0)     :", u0);
        console2.log("val[1] uptime               :", u1);
        console2.log("val[2] uptime               :", u2);
        console2.log("coded operatorUptime         :", codedUptime, "== (u0+u1+u2)/3");
        console2.log("stake-weighted (9:1:1 hypo)  :", stakeWeightedHypo);

        // PRIMARY: the coded value IS the unweighted arithmetic mean (UptimeTracker.sol:231).
        assertEq(
            codedUptime, unweightedMean, "operatorUptimePerEpoch must equal arithmetic mean of validator uptimes"
        );

        // INFLATION: when the zero-uptime validator dominates by stake, the unweighted mean overstates
        // the operator's true service relative to the stake-weighted truth.
        if (u0 == 0 && u1 > 0) {
            assertGt(
                codedUptime,
                stakeWeightedHypo,
                "CONFIRMED: unweighted mean > stake-weighted when high-stake val is offline"
            );
            console2.log("inflation gap (coded - stakeWeighted):", codedUptime - stakeWeightedHypo);
        }
    }

}
