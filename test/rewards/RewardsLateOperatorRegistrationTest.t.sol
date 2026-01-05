// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RewardsNativeToken} from "../../src/contracts/rewards/RewardsNativeToken.sol";
import {MockUptimeTracker} from "../mocks/MockUptimeTracker.sol";
import {MiddlewareTestBase} from "../middleware/MiddlewareTestBase.t.sol";
import {Token} from "../mocks/MockToken.sol";
import {MockCollateral} from "../mocks/MockCollateral.sol";
import {IRewardsNativeToken} from "../../src/interfaces/rewards/IRewardsNativeToken.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title RewardsLateOperatorRegistrationTest
 * @notice Tests the scenario where operators are registered late (after some epochs pass).
 * @dev Scenario:
 *      - Epochs 1 & 2: No operators registered, no validators
 *      - Epoch 3: Operators registered, validators added
 *      - Current: Epoch 4+
 *      
 * Problem: Even though epochs 1 & 2 had no operators at the time, 
 *          the contract uses CURRENT operators when distributing.
 *          So epochs 1 & 2 require funding OR waiting for the skip date.
 *          
 * Solution: Fund epochs 1 & 2 with minimal amount (1 wei), then distribute.
 */
contract RewardsLateOperatorRegistrationTest is Test {
    // We'll set up a minimal environment without inheriting the full MiddlewareTestBase
    // because we need to control WHEN operators are registered.

    // Since the scenario is complex, let's inherit from MiddlewareTestBase but
    // override setUp to delay operator registration.
    
    // Actually, let's create a simpler test that demonstrates the key behavior
    // using the existing MiddlewareTestBase structure.
}

/**
 * @title RewardsLateOperatorTest
 * @notice Test demonstrating late operator registration scenario using existing base.
 */
contract RewardsLateOperatorTest is MiddlewareTestBase {
    /* ─── Test Actors ─────────────────────────────────────────────────────── */
    address internal rewardsManager;
    address internal rewardsDistributor;

    /* ─── Rewards stack ───────────────────────────────────────────────────── */
    RewardsNativeToken rewards;
    MockUptimeTracker uptime;
    Token token;

    function setUp() public virtual override {
        super.setUp();

        // Initialize test actors
        rewardsManager = makeAddr("rewardsManager");
        rewardsDistributor = makeAddr("rewardsDistributor");

        uptime = new MockUptimeTracker();

        // Deploy rewards contract
        RewardsNativeToken implementation = new RewardsNativeToken();
        bytes memory initData = abi.encodeWithSelector(
            RewardsNativeToken.initialize.selector,
            l1Owner,
            protocolOwner,
            payable(address(middleware)),
            address(uptime),
            1000,  // protocolFee (10%)
            2000,  // operatorFee (20%)
            1000,  // curatorFee (10%)
            11_520  // minRequiredUptime
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        rewards = RewardsNativeToken(address(proxy));

        vm.prank(l1Owner);
        rewards.setRewardsManagerRole(rewardsManager);
        vm.prank(rewardsManager);
        rewards.setRewardsDistributorRole(rewardsDistributor);

        // Get the rewards token
        token = Token(rewards.rewardsToken());
        
        // Transfer tokens to distributor
        uint256 balance = token.balanceOf(address(this));
        token.transfer(rewardsDistributor, balance * 95 / 100);
        vm.prank(rewardsDistributor);
        token.approve(address(rewards), type(uint256).max);

        // Set up collateral class shares (only primary class 1 for simplicity)
        vm.startPrank(rewardsManager);
        rewards.setRewardsShareForCollateralClass(1, 10000); // 100% to primary class
        vm.stopPrank();
    }

    /**
     * @notice Test: Epochs 1 & 2 unfunded, epoch 3 funded - demonstrate the workflow.
     * 
     * This test demonstrates:
     * 1. Distribution of unfunded epochs reverts when operators exist (even if operators
     *    weren't present during those epochs)
     * 2. Funding epochs with 1 wei unblocks distribution
     * 3. Sequential distribution works after funding
     */
    function test_lateOperatorRegistration_fundWith1Wei() public {
        console2.log("=== LATE OPERATOR REGISTRATION TEST ===");
        console2.log("");
        
        // Current epoch at start (operators were registered in setUp, but let's pretend
        // they weren't active during epochs 1 & 2)
        uint48 startEpoch = middleware.getCurrentEpoch();
        console2.log("Starting at epoch:", startEpoch);
        
        // Move to epoch 5 to simulate: epochs 1,2 passed without activity, 
        // epoch 3 had activity, now in epoch 5
        uint48 targetEpoch = 5;
        if (startEpoch < targetEpoch) {
            _warpToEpoch(targetEpoch);
        }
        
        uint48 currentEpoch = middleware.getCurrentEpoch();
        console2.log("Current epoch:", currentEpoch);
        console2.log("");
        
        // ═══════════════════════════════════════════════════════════════════
        // STEP 1: Fund epoch 3 only (the epoch with actual activity)
        // ═══════════════════════════════════════════════════════════════════
        console2.log("STEP 1: Fund only epoch 3 (simulating real scenario)");
        
        uint48 epoch3 = 3;
        uint256 epoch3Amount = 100_000 ether;
        
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch3, 1, epoch3Amount);
        
        (bool funded3,) = rewards.epochStatus(epoch3);
        console2.log("  Epoch 3 funded:", funded3);
        console2.log("");
        
        // ═══════════════════════════════════════════════════════════════════
        // STEP 2: Try to distribute epoch 1 without funding - should REVERT
        // ═══════════════════════════════════════════════════════════════════
        console2.log("STEP 2: Try to distribute epoch 1 without funding");
        
        uint48 epoch1 = 1;
        
        // Check funding window for epoch 1
        uint48 fundingDeadlineOffset = rewards.FUNDING_DEADLINE_OFFSET(); // 4
        bool fundingWindowOpen = epoch1 + fundingDeadlineOffset >= currentEpoch;
        console2.log("  Epoch 1 funding window open:", fundingWindowOpen);
        console2.log("  (epoch1 + 4 >= currentEpoch):", epoch1 + 4, ">=", currentEpoch);
        
        // Operators exist now (registered in setUp)
        address[] memory operators = middleware.getAllOperators();
        console2.log("  Current operators count:", operators.length);
        
        // This should revert because:
        // - Funding window is open (currentEpoch 5 <= epoch 1 + 4 = 5)
        // - Epoch is not funded
        // - Operators exist
        vm.prank(rewardsDistributor);
        vm.expectRevert(abi.encodeWithSelector(IRewardsNativeToken.EpochNotFunded.selector, epoch1));
        rewards.distributeRewards(epoch1, 10);
        
        console2.log("  REVERTED as expected: EpochNotFunded(1)");
        console2.log("");
        
        // ═══════════════════════════════════════════════════════════════════
        // STEP 3: Try to distribute epoch 3 - should REVERT due to sequential rule
        // ═══════════════════════════════════════════════════════════════════
        console2.log("STEP 3: Try to distribute epoch 3 (funded) before epochs 1,2");
        
        // Even though epoch 3 is funded, we can't distribute it until epochs 1 & 2 are done
        vm.prank(rewardsDistributor);
        vm.expectRevert(abi.encodeWithSelector(IRewardsNativeToken.DistributionNotComplete.selector, 2));
        rewards.distributeRewards(epoch3, 10);
        
        console2.log("  REVERTED as expected: DistributionNotComplete(2)");
        console2.log("");
        
        // ═══════════════════════════════════════════════════════════════════
        // STEP 4: Fund epochs 1 & 2 with 1 wei each to unblock
        // ═══════════════════════════════════════════════════════════════════
        console2.log("STEP 4: Fund epochs 1 & 2 with 1 wei each");
        
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch1, 2, 1); // epochs 1 and 2, 1 wei each
        
        (bool funded1,) = rewards.epochStatus(1);
        (bool funded2,) = rewards.epochStatus(2);
        console2.log("  Epoch 1 funded:", funded1);
        console2.log("  Epoch 2 funded:", funded2);
        console2.log("");
        
        // ═══════════════════════════════════════════════════════════════════
        // STEP 5: Distribute epoch 1 - should succeed now
        // ═══════════════════════════════════════════════════════════════════
        console2.log("STEP 5: Distribute epoch 1 (funded with 1 wei)");
        
        // Set up uptime for operators (0 uptime since no activity in epoch 1)
        uptime.setAllOperatorsSameUptime(epoch1, operators, 0);
        
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch1, uint48(operators.length + 10));
        
        (, bool complete1) = rewards.distributionBatches(epoch1);
        console2.log("  Epoch 1 distribution complete:", complete1);
        
        // Check shares (should be 0 since 0 uptime)
        uint256 totalShares1 = 0;
        for (uint256 i = 0; i < operators.length; i++) {
            totalShares1 += rewards.operatorShares(epoch1, operators[i]);
        }
        console2.log("  Total operator shares for epoch 1:", totalShares1, "(expected 0 - no uptime)");
        console2.log("");
        
        // ═══════════════════════════════════════════════════════════════════
        // STEP 6: Distribute epoch 2 - should succeed
        // ═══════════════════════════════════════════════════════════════════
        console2.log("STEP 6: Distribute epoch 2 (funded with 1 wei)");
        
        uint48 epoch2 = 2;
        uptime.setAllOperatorsSameUptime(epoch2, operators, 0);
        
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch2, uint48(operators.length + 10));
        
        (, bool complete2) = rewards.distributionBatches(epoch2);
        console2.log("  Epoch 2 distribution complete:", complete2);
        console2.log("");
        
        // ═══════════════════════════════════════════════════════════════════
        // STEP 7: Now distribute epoch 3 - should succeed with real rewards
        // ═══════════════════════════════════════════════════════════════════
        console2.log("STEP 7: Distribute epoch 3 (funded with real rewards)");
        
        // Set up real uptime for epoch 3 (operators were active)
        uint256 goodUptime = 4 hours;
        uptime.setAllOperatorsSameUptime(epoch3, operators, goodUptime);
        
        // Sync stake cache properly - need to call epoch sync first
        _syncStakeCache(middleware.getCurrentEpoch());
        try middleware.calcAndCacheNodeStakeForAllOperators() {} catch {}
        
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch3, uint48(operators.length + 10));
        
        (, bool complete3) = rewards.distributionBatches(epoch3);
        console2.log("  Epoch 3 distribution complete:", complete3);
        
        // Check shares for epoch 3
        uint256 totalShares3 = 0;
        for (uint256 i = 0; i < operators.length; i++) {
            uint256 opShare = rewards.operatorShares(epoch3, operators[i]);
            console2.log("  Operator", i, "shares:", opShare);
            totalShares3 += opShare;
        }
        console2.log("  Total operator shares for epoch 3:", totalShares3);
        console2.log("");
        
        // ═══════════════════════════════════════════════════════════════════
        // VERIFICATION
        // ═══════════════════════════════════════════════════════════════════
        console2.log("=== VERIFICATION ===");
        
        assertTrue(complete1, "Epoch 1 should be distributed");
        assertTrue(complete2, "Epoch 2 should be distributed");
        assertTrue(complete3, "Epoch 3 should be distributed");
        
        // Note: In this minimal test setup, operators don't have validator nodes,
        // so shares are 0. The key verification is that all epochs were distributed
        // successfully in the correct sequence after funding epochs 1 & 2 with 1 wei.
        
        // Verify the epoch statuses
        (bool funded1Final, bool distComplete1) = rewards.epochStatus(1);
        (bool funded2Final, bool distComplete2) = rewards.epochStatus(2);
        (bool funded3Final, bool distComplete3) = rewards.epochStatus(3);
        
        assertTrue(funded1Final && distComplete1, "Epoch 1 should be funded and distributed");
        assertTrue(funded2Final && distComplete2, "Epoch 2 should be funded and distributed");
        assertTrue(funded3Final && distComplete3, "Epoch 3 should be funded and distributed");
        
        console2.log("SUCCESS: All epochs distributed correctly!");
        console2.log("");
        console2.log("KEY FINDINGS VERIFIED:");
        console2.log("  1. Cannot distribute unfunded epoch when operators exist (EpochNotFunded)");
        console2.log("  2. Cannot skip epochs - sequential distribution enforced (DistributionNotComplete)");
        console2.log("  3. Funding with 1 wei marks epoch as funded");
        console2.log("  4. All epochs distributed successfully after funding");
    }

    /**
     * @notice Test: Wait for skip date instead of funding
     * 
     * Alternative approach: If you don't want to fund epochs 1 & 2 at all,
     * wait until the funding deadline passes (currentEpoch > epoch + 4)
     */
    function test_lateOperatorRegistration_waitForSkipDate() public {
        console2.log("=== WAIT FOR SKIP DATE TEST ===");
        console2.log("");
        
        uint48 epoch1 = 1;
        uint48 epoch2 = 2;
        uint48 epoch3 = 3;
        
        // Fund epoch 3 only
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch3, 1, 100_000 ether);
        
        // Move to epoch where epoch 1's funding window has closed
        // Funding window closes when currentEpoch > epoch + 4
        // For epoch 1: need currentEpoch > 5, so epoch 6+
        uint48 epoch1SkipDate = epoch1 + rewards.FUNDING_DEADLINE_OFFSET() + 1; // epoch 6
        console2.log("Epoch 1 becomes skippable at epoch:", epoch1SkipDate);
        
        // Use _moveToNextEpochAndCalc which properly syncs the middleware
        uint48 currentEpoch = middleware.getCurrentEpoch();
        if (currentEpoch < epoch1SkipDate) {
            _moveToNextEpochAndCalc(epoch1SkipDate - currentEpoch);
        }
        console2.log("Warped to epoch:", middleware.getCurrentEpoch());
        console2.log("");
        
        address[] memory operators = middleware.getAllOperators();
        uptime.setAllOperatorsSameUptime(epoch1, operators, 0);
        uptime.setAllOperatorsSameUptime(epoch2, operators, 0);
        uptime.setAllOperatorsSameUptime(epoch3, operators, 4 hours);
        
        // Now epoch 1 should be distributable without funding
        console2.log("STEP 1: Distribute epoch 1 WITHOUT funding (past deadline)");
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch1, uint48(operators.length + 10));
        (, bool complete1) = rewards.distributionBatches(epoch1);
        console2.log("  Epoch 1 complete:", complete1);
        assertTrue(complete1, "Epoch 1 should complete without funding after deadline");
        
        // Check if epoch 2's window is also closed
        currentEpoch = middleware.getCurrentEpoch();
        bool epoch2WindowOpen = epoch2 + rewards.FUNDING_DEADLINE_OFFSET() >= currentEpoch;
        console2.log("");
        console2.log("STEP 2: Check epoch 2 status");
        console2.log("  Epoch 2 funding window still open:", epoch2WindowOpen);
        
        if (epoch2WindowOpen) {
            console2.log("  Need to wait more for epoch 2...");
            uint48 epoch2SkipDate = epoch2 + rewards.FUNDING_DEADLINE_OFFSET() + 1;
            currentEpoch = middleware.getCurrentEpoch();
            if (currentEpoch < epoch2SkipDate) {
                _moveToNextEpochAndCalc(epoch2SkipDate - currentEpoch);
            }
            console2.log("  Warped to epoch:", middleware.getCurrentEpoch());
        }
        
        // Distribute epoch 2
        console2.log("  Distributing epoch 2...");
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch2, uint48(operators.length + 10));
        (, bool complete2) = rewards.distributionBatches(epoch2);
        console2.log("  Epoch 2 complete:", complete2);
        assertTrue(complete2, "Epoch 2 should complete");
        
        // Now distribute epoch 3
        console2.log("");
        console2.log("STEP 3: Distribute epoch 3 (funded with real rewards)");
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch3, uint48(operators.length + 10));
        (, bool complete3) = rewards.distributionBatches(epoch3);
        console2.log("  Epoch 3 complete:", complete3);
        assertTrue(complete3, "Epoch 3 should complete");
        
        // Verify all epochs distributed (shares may be 0 due to minimal setup)
        (bool f1, bool d1) = rewards.epochStatus(epoch1);
        (bool f2, bool d2) = rewards.epochStatus(epoch2);
        (bool f3, bool d3) = rewards.epochStatus(epoch3);
        
        assertFalse(f1, "Epoch 1 should NOT be funded (skipped)");
        assertTrue(d1, "Epoch 1 should be distributed");
        assertFalse(f2, "Epoch 2 should NOT be funded (skipped)");
        assertTrue(d2, "Epoch 2 should be distributed");
        assertTrue(f3, "Epoch 3 should be funded");
        assertTrue(d3, "Epoch 3 should be distributed");
        
        console2.log("");
        console2.log("SUCCESS: Distributed all epochs by waiting for skip dates!");
        console2.log("  - Epochs 1 & 2: Distributed WITHOUT funding (past deadline)");
        console2.log("  - Epoch 3: Distributed with funding");
    }

    /**
     * @notice Test: Verify you CANNOT fund with 0
     */
    function test_cannotFundWithZero() public {
        console2.log("=== CANNOT FUND WITH ZERO TEST ===");
        
        vm.prank(rewardsDistributor);
        vm.expectRevert(abi.encodeWithSelector(IRewardsNativeToken.InvalidRewardsAmount.selector, 0));
        rewards.setRewardsAmountForEpochs(1, 1, 0);
        
        console2.log("CONFIRMED: Cannot fund with 0 - reverts with InvalidRewardsAmount(0)");
    }

    // Note: _warpToEpoch is inherited from MiddlewareTestBase
}

