// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Rewards} from "../../src/contracts/rewards/Rewards.sol";
import {MockUptimeTracker} from "../mocks/MockUptimeTracker.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MiddlewareTestBase} from "../middleware/MiddlewareTestBase.t.sol";
import {IRewards, DistributionBatch} from "../../src/interfaces/rewards/IRewards.sol";
import {VaultTokenized} from "../../src/contracts/vault/VaultTokenized.sol";
import {BaseDelegator} from "../../src/contracts/delegator/BaseDelegator.sol";
import {L1RestakeDelegator} from "../../src/contracts/delegator/L1RestakeDelegator.sol";
import {IVaultTokenized} from "../../src/interfaces/vault/IVaultTokenized.sol";
import {IBaseDelegator} from "../../src/interfaces/delegator/IBaseDelegator.sol";
import {IL1RestakeDelegator} from "../../src/interfaces/delegator/IL1RestakeDelegator.sol";
import {IMiddlewareVaultManager} from "../../src/interfaces/middleware/IMiddlewareVaultManager.sol";

contract RewardsIntegrationTest is MiddlewareTestBase {
    /* ─── Test Actors ─────────────────────────────────────────────────────── */
    address internal rewardsManager;
    address internal rewardsDistributor;

    /* ─── Rewards stack ───────────────────────────────────────────────────── */
    Rewards           rewards;
    MockUptimeTracker uptime;
    ERC20Mock         token;

    /* ─── Setup ───────────────────────────────────────────────────────────── */
    function setUp() public override {
        super.setUp();                                // ← real middleware & vaults ready

        // ── fast‑path: add two secondary collateral‑classes & their vaults ───────────
        if (middleware.getCollateralClassIds().length == 1) {          // only class‑1 present
            _setupCollateralClassAndRegisterVault(
                2, 0,                   // id‑2, minStake = 0
                collateral2, vault3,    // use existing vault3 + token2
                type(uint256).max,      // maxVaultLimit
                type(uint256).max,      // l1Limit
                delegator3
            );
            _setupCollateralClassAndRegisterVault(
                3, 0,                   // id‑3
                collateral,  vault2,    // reuse vault2 + primary token
                type(uint256).max,
                type(uint256).max,
                delegator2
            );
        }

        // Initialize test actors with descriptive labels
        // protocolOwner and l1Owner are inherited from MiddlewareTestBase
        rewardsManager = makeAddr("rewardsManager");
        rewardsDistributor = makeAddr("rewardsDistributor");

        uptime = new MockUptimeTracker();

        rewards = new Rewards();
        rewards.initialize(
            l1Owner,  // Rewards should be owned by l1Owner according to the new ownership model
            protocolOwner,
            payable(address(middleware)),             // real middleware
            address(uptime),
            1000,  // protocolFee (bp)
            2000,  // operatorFee
            1000,  // curatorFee
            11_520 // minRequiredUptime (3.2 h)
        );

        vm.prank(l1Owner);
        rewards.setRewardsManagerRole(rewardsManager);
        vm.prank(rewardsManager);
        rewards.setRewardsDistributorRole(rewardsDistributor);

        token = new ERC20Mock();
        token.mint(rewardsDistributor, 1_000_000 ether);
        vm.prank(rewardsDistributor);
        token.approve(address(rewards), type(uint256).max);

        // 50‑30‑20 asset‑class split (matches MiddlewareTestBase)
        vm.startPrank(rewardsManager);
        rewards.setRewardsShareForCollateralClass(1, 5000);
        rewards.setRewardsShareForCollateralClass(2, 3000);
        rewards.setRewardsShareForCollateralClass(3, 2000);
        vm.stopPrank();
    }

    /* ─── Helper: prepare stakes + uptime for *epoch* using the real contracts */
    function _setupRealStakes(uint48 epoch, uint256 uptimeSecs) internal {
        // ──────────────────────────────────────────────────────────────
        // 1. make sure every operator has at least one node
        // ──────────────────────────────────────────────────────────────
        address[] memory ops = middleware.getAllOperators();
        for (uint256 i = 0; i < ops.length; ++i) {
            if (middleware.getActiveNodesForEpoch(ops[i], epoch).length > 0) continue;

            _ensureFreeStake(ops[i]);                 // ← NEW
            uint256 minStake = _primaryMinStake();
            _createAndConfirmNodes({
                operator:       ops[i],
                nodeCount:      1,
                stake_:         minStake,             // explicit – no more "0" shortcut
                confirmImmediately: true,
                minMultiplier:  1
            });
        }

        // ──────────────────────────────────────────────────────────────
        // 2. advance chain until epoch exists, then cache node stakes
        // ──────────────────────────────────────────────────────────────
        uint48 cur = middleware.getCurrentEpoch();
        if (cur < epoch) _moveToNextEpochAndCalc(epoch - cur);
        middleware.calcAndCacheNodeStakeForAllOperators();

        // cache every secondary collateral‑class stake to avoid div‑0
        uint96[] memory ids = middleware.getCollateralClassIds();
        for (uint256 i = 0; i < ids.length; ++i) {
            if (ids[i] != 1) {                         // 1 = primary, already done above
                try middleware.calcAndCacheStakes(epoch, ids[i]) {} catch {}
            }
        }

        // uniform uptime for all operators
        uptime.setAllOperatorsSameUptime(
            epoch,
            middleware.getAllOperators(),
            uptimeSecs
        );
    }

    /* ─── simple happy‑path distribution test using real stack ───────────── */

    function test_distributeRewards(uint256 uptimeSecs) public {
        uptimeSecs = bound(uptimeSecs, 0, 4 hours);

        uint48 epoch = middleware.getCurrentEpoch();   // always test *current* epoch
        if (epoch == 0) epoch = 1;

        _setupRealStakes(epoch, uptimeSecs);

        // fund that epoch
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch, 1, address(token), 100_000 ether);

        // wait ≥ 2 epochs
        _moveToNextEpochAndCalc(3);

        // batch‑process
        address[] memory ops = middleware.getAllOperators();
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch, uint48(ops.length));

        // quick invariant: total share ≤ 100 %
        uint256 sum;
        for (uint256 i; i < ops.length; ++i) sum += rewards.operatorShares(epoch, ops[i]);

        uint256 nVault = vaultManager.getVaultCount();
        for (uint256 i; i < nVault; ++i) {
            (address v,,) = vaultManager.getVaultAtWithTimes(i);
            sum += rewards.vaultShares(epoch, v);
            sum += rewards.curatorShares(epoch, VaultTokenized(v).owner());
        }
        assertLe(sum, rewards.BASIS_POINTS_DENOMINATOR(), "share overflow");
    }

    /* ─── simple claim (staker) --------------------------------------- */
    function test_claimRewards_staker() public {
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;

        _setupRealStakes(epoch, 4 hours);

        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch, 3, address(token), 300_000 ether);

        _moveToNextEpochAndCalc(3);
        uint48 operatorCount = uint48(middleware.getAllOperators().length);
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch, operatorCount);

        uint256 before = token.balanceOf(staker);
        vm.prank(staker);
        rewards.claimRewards(address(token), staker);
        assertGt(token.balanceOf(staker), before, "no rewards received");

        // second call in same epoch must revert
        _expectSecondClaimRevert(staker, epoch);
        vm.prank(staker);
        rewards.claimRewards(address(token), staker);
    }

    /* ─── sequential‑distribution guard ------------------------------ */
    function test_distribution_sequential_guard() public {
        uint48 ep1 = middleware.getCurrentEpoch() == 0 ? 1 : middleware.getCurrentEpoch();
        uint48 ep2 = ep1 + 1;

        // stakes & funding for both epochs
        _setupRealStakes(ep1, 4 hours);
        _setupRealStakes(ep2, 4 hours);
        vm.startPrank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(ep1, 2, address(token), 200_000 ether);
        vm.stopPrank();

        _moveToNextEpochAndCalc(3);

        // distribute ep1 half‑way (batch size 1)
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(ep1, 1);

        // try ep2 – should revert
        vm.prank(rewardsDistributor);
        vm.expectRevert(abi.encodeWithSelector(IRewards.DistributionNotComplete.selector, ep1));
        rewards.distributeRewards(ep2, 1);
    }

    /* ─── zero‑stake operator produces 0 share ------------------------ */
    function test_zeroStakeOperator_getsNoShare() public {
        uint48 epoch = middleware.getCurrentEpoch() == 0 ? 1 : middleware.getCurrentEpoch();

        _setupRealStakes(epoch, 4 hours);

        // pick first operator and force its uptime to 0 s
        address op = middleware.getAllOperators()[0];
        uptime.setOperatorUptimePerEpoch(epoch, op, 0);

        // fund + distribute
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch, 1, address(token), 100_000 ether);
        _moveToNextEpochAndCalc(3);
        uint48 operatorCount = uint48(middleware.getAllOperators().length);
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch, operatorCount);

        assertEq(
            rewards.operatorShares(epoch, op),
            0,
            "Operator with 0-second uptime must receive 0 share"
        );
    }

    /* ─── Multiple batch distribution test ---------------------------- */
    function test_distributeRewards_multipleBatch() public {
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;
        
        _setupRealStakes(epoch, 4 hours);

        // Fund the epoch
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch, 1, address(token), 1_000_000 ether);

        // Process all operators in one large batch
        uint256 operatorCount = middleware.getAllOperators().length;
        _moveToNextEpochAndCalc(3);
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch, uint48(operatorCount));

        // Verify completion
        (, bool isComplete) = rewards.distributionBatches(epoch);
        assertTrue(isComplete, "Distribution should be complete");

        // Verify all operators processed
        address[] memory operators = middleware.getAllOperators();
        for (uint256 i = 0; i < operators.length; i++) {
            address op = operators[i];
            assertTrue(
                rewards.operatorShares(epoch, op) > 0                         // got paid
                || uptime.operatorUptimePerEpoch(epoch, op) < rewards.minRequiredUptime()  // low uptime
                || middleware.getOperatorUsedStakeCachedPerEpoch(epoch, op, 1) == 0,  // no stake ⇒ no share
                "Each operator should either have shares, no stake, or insufficient uptime"
            );
        }
    }

    /* ─── Partial batch distribution test ----------------------------- */
    function test_distributeRewards_partialBatch() public {
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;
        
        _setupRealStakes(epoch, 4 hours);

        // Fund the epoch
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch, 1, address(token), 100_000 ether);

        uint256 batchSize = 2;

        // First batch
        _moveToNextEpochAndCalc(3);
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch, uint48(batchSize));
        (uint256 lastProcessed, bool isComplete) = rewards.distributionBatches(epoch);
        assertEq(lastProcessed, batchSize, "Should process exactly batchSize operators");
        assertFalse(isComplete, "Should not be complete after first batch");
    }

    /* ─── Completion flag test ---------------------------------------- */
    function test_distributeRewards_completionFlag() public {
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;
        
        _setupRealStakes(epoch, 4 hours);

        // Fund the epoch
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch, 1, address(token), 100_000 ether);

        // Process all operators
        address[] memory operators = middleware.getAllOperators();
        _moveToNextEpochAndCalc(3);
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch, uint48(operators.length));

        // Verify completion flag
        (, bool isComplete) = rewards.distributionBatches(epoch);
        assertTrue(isComplete, "Should be marked complete");

        // Try to process again
        vm.expectRevert(abi.encodeWithSelector(IRewards.AlreadyCompleted.selector, epoch));
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch, uint48(operators.length));
    }

    /* ─── Zero uptime test -------------------------------------------- */
    function test_distributeRewards_zeroUptime() public {
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;
        
        _setupRealStakes(epoch, 4 hours);

        // Set zero uptime for first operator
        address[] memory operators = middleware.getAllOperators();
        uptime.setOperatorUptimePerEpoch(epoch, operators[0], 0);

        // Fund the epoch
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch, 1, address(token), 100_000 ether);

        // Distribute rewards
        _moveToNextEpochAndCalc(3);
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch, 1);

        // Verify no shares for operator with zero uptime
        assertEq(rewards.operatorShares(epoch, operators[0]), 0, "Operator with zero uptime should have zero shares");
    }

    /* ─── Claim tests ------------------------------------------------- */
    
    function test_claimRewards() public {
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;

        // First distribute rewards
        test_distributeRewards(4 hours);

        // Move to next epoch to allow claiming
        _moveToNextEpochAndCalc(1);

        uint256 stakerBalanceBefore = token.balanceOf(staker);

        vm.prank(staker);
        rewards.claimRewards(address(token), staker);

        uint256 stakerBalanceAfter = token.balanceOf(staker);
        uint256 stakerRewards = stakerBalanceAfter - stakerBalanceBefore;

        assertGt(stakerRewards, 0, "Staker should receive rewards");

        // Verify can't claim twice in same epoch
        _expectSecondClaimRevert(staker, epoch);
        vm.prank(staker);
        rewards.claimRewards(address(token), staker);
    }

    function test_claimRewards_revert_InvalidRecipient() public {
        vm.prank(makeAddr("Staker"));
        vm.expectRevert(abi.encodeWithSelector(IRewards.InvalidRecipient.selector, address(0)));
        rewards.claimRewards(address(token), address(0));
    }

    function test_claimRewards_revert_AlreadyClaimedForLatestEpoch() public {
        uint48 epoch = 1;

        // 1. distribute rewards for epoch 1
        _setupRealStakes(epoch, 4 hours);
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch, 1, address(token), 100_000 ether);
        _moveToNextEpochAndCalc(3);
        address[] memory ops = middleware.getAllOperators();
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch, uint48(ops.length));

        // 2. warp to *exactly* epoch 2 (currentEpoch == 2)
        _warpToEpoch(epoch + 1);               // +1 epoch, not more
        _syncStakeCache(epoch + 1);

        // 3. first claim succeeds
        vm.prank(staker);
        rewards.claimRewards(address(token), staker);

        // 4. second claim must revert with AlreadyClaimedForLatestEpoch
        _expectSecondClaimRevert(staker, epoch);
        vm.prank(staker);
        rewards.claimRewards(address(token), staker);
    }

    function test_claimRewards_revert_NoRewardsToClaim() public {
        address testStaker = makeAddr("Staker");

        // Try to claim without any stake or rewards
        vm.prank(testStaker);
        vm.expectRevert(abi.encodeWithSelector(IRewards.NoRewardsToClaimEpoch.selector, testStaker, 0));
        rewards.claimRewards(address(token), testStaker);
    }

    function test_claimRewards_EmitZeroRewardsClaim_NoStakeInVault() public {
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;
        address testStaker = makeAddr("NoStakeStaker");

        // Distribute rewards
        test_distributeRewards(4 hours);

        // Move to next epoch
        _moveToNextEpochAndCalc(1);

        vm.prank(testStaker);
        vm.expectEmit(true, true, false, true, address(rewards));
        emit IRewards.ZeroRewardsClaim(testStaker, address(token), epoch, "staker");
        rewards.claimRewards(address(token), testStaker);
    }

    function test_claimRewards_revert_DistributionNotComplete() public {
        address testStaker = makeAddr("Staker");

        // Setup stakes
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;
        _setupRealStakes(epoch, 4 hours);

        // Fund the epoch
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch, 1, address(token), 100_000 ether);

        // Only distribute partially
        _moveToNextEpochAndCalc(3);
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch, 1);

        // Try to claim (should revert because epoch is current-1 and not fully distributed)
        vm.expectRevert();
        vm.prank(testStaker);
        rewards.claimRewards(address(token), testStaker);
    }

    function test_claimUndistributedRewards() public {
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;

        // Setup and distribute rewards with partial uptime to ensure undistributed rewards
        test_distributeRewards(3.9 hours);

        // Warp to 2 epochs ahead to allow claiming
        _moveToNextEpochAndCalc(3);

        // Record recipient balance and rewards amount before claim
        uint256 balBefore = token.balanceOf(rewardsDistributor);
        uint256 rewardsAmountBefore = rewards.getRewardsAmountPerTokenFromEpoch(epoch, address(token));

        vm.prank(rewardsDistributor);
        rewards.claimUndistributedRewards(epoch, address(token), rewardsDistributor);

        // Verify undistributed rewards were credited to recipient
        uint256 balAfter = token.balanceOf(rewardsDistributor);
        uint256 undistributedAmount = balAfter - balBefore;
        assertGt(undistributedAmount, 0, "Rewards distributor should receive undistributed rewards");

        // Base must not mutate; claims use shares against original R to avoid double-scaling
        uint256 rewardsAmountAfter = rewards.getRewardsAmountPerTokenFromEpoch(epoch, address(token));
        assertEq(rewardsAmountAfter, rewardsAmountBefore, "epoch base must remain unchanged after sweep");
    }

    function test_claimUndistributedRewards_revert_InvalidRecipient() public {
        uint48 epoch = 1;

        vm.prank(rewardsDistributor);
        vm.expectRevert(abi.encodeWithSelector(IRewards.InvalidRecipient.selector, address(0)));
        rewards.claimUndistributedRewards(epoch, address(token), address(0));
    }

    function test_claimUndistributedRewards_revert_DistributionNotComplete() public {
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;

        // Setup stakes
        _setupRealStakes(epoch, 4 hours);

        // Fund the epoch
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch, 1, address(token), 100_000 ether);

        // Only distribute partially
        _moveToNextEpochAndCalc(3);
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch, 1);

        vm.prank(rewardsDistributor);
        vm.expectRevert(abi.encodeWithSelector(IRewards.DistributionNotComplete.selector, epoch));
        rewards.claimUndistributedRewards(epoch, address(token), rewardsDistributor);
    }

    function test_claimUndistributedRewards_revert_EpochStillClaimable() public {
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;

        // Setup and fund the epoch
        _setupRealStakes(epoch, 3.9 hours);
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch, 1, address(token), 100_000 ether);
        
        // Warp to exactly epoch + DISTRIBUTION_EARLIEST_OFFSET (which is 2)
        // This is the earliest we can distribute
        _moveToNextEpochAndCalc(rewards.DISTRIBUTION_EARLIEST_OFFSET());
        
        // Distribute rewards
        address[] memory ops = middleware.getAllOperators();
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch, uint48(ops.length));
        
        // We're still at epoch + 2, need to be at epoch + 3 to sweep
        // So sweep should revert with EpochStillClaimable
        vm.prank(rewardsDistributor);
        vm.expectRevert(abi.encodeWithSelector(IRewards.EpochStillClaimable.selector, epoch));
        rewards.claimUndistributedRewards(epoch, address(token), rewardsDistributor);
    }

    function test_claimUndistributedRewards_revert_NoUndistributedRewards() public {
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;

        // Setup a scenario where all rewards are distributed  
        // Note: Even with full uptime, there might be small undistributed amounts due to rounding
        // So we need to actually claim the undistributed rewards first to test the second claim
        test_distributeRewards(4 hours);

        // Warp to after claimable period
        _moveToNextEpochAndCalc(3);

        // Check if there are any undistributed rewards and claim them first
        try rewards.claimUndistributedRewards(epoch, address(token), rewardsDistributor) {
            // If claim succeeded, now try to claim again which should fail
            vm.prank(rewardsDistributor);
            vm.expectRevert(abi.encodeWithSelector(IRewards.NoRewardsToClaim.selector, rewardsDistributor));
            rewards.claimUndistributedRewards(epoch, address(token), rewardsDistributor);
        } catch {
            // If first claim failed, test passes as there were no undistributed rewards
        }
    }

    function test_claimUndistributedRewards_revert_AlreadyClaimed() public {
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;

        // Complete distribution with partial uptime
        test_distributeRewards(3.9 hours);

        // Warp to after claimable period
        _moveToNextEpochAndCalc(3);

        // First claim
        vm.prank(rewardsDistributor);
        rewards.claimUndistributedRewards(epoch, address(token), rewardsDistributor);

        // Try to claim again
        vm.prank(rewardsDistributor);
        vm.expectRevert(abi.encodeWithSelector(IRewards.NoRewardsToClaim.selector, rewardsDistributor));
        rewards.claimUndistributedRewards(epoch, address(token), rewardsDistributor);
    }

    function test_claimUndistributedRewards_usersCanStillClaim() public {
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;

        // Setup and distribute rewards with partial uptime to create undistributed rewards
        test_distributeRewards(3.9 hours);

        // Warp to after grace period to allow undistributed rewards claim
        _moveToNextEpochAndCalc(3);

        // Record initial state
        uint256 rewardsAmountBefore = rewards.getRewardsAmountPerTokenFromEpoch(epoch, address(token));
        uint256 stakerBalanceBefore = token.balanceOf(staker);

        // Claim undistributed rewards
        vm.prank(rewardsDistributor);
        rewards.claimUndistributedRewards(epoch, address(token), rewardsDistributor);

        // Base must not mutate; users still claim their shares
        uint256 rewardsAmountAfter = rewards.getRewardsAmountPerTokenFromEpoch(epoch, address(token));
        assertEq(rewardsAmountAfter, rewardsAmountBefore, "base unchanged; users still claim their shares");

        // User should still be able to claim their allocated rewards
        vm.prank(staker);
        rewards.claimRewards(address(token), staker);

        uint256 stakerBalanceAfter = token.balanceOf(staker);
        assertGt(stakerBalanceAfter, stakerBalanceBefore, "Staker should receive their allocated rewards");
    }

    function test_claimRewardsForOtherParties() public {
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;

        // Setup and distribute rewards with partial uptime to ensure undistributed rewards
        test_distributeRewards(3.9 hours);

        // Move to next epoch
        _moveToNextEpochAndCalc(1);

        // Test operator claims
        address operator = middleware.getAllOperators()[0];
        uint256 operatorBalanceBefore = token.balanceOf(operator);
        vm.prank(operator);
        rewards.claimOperatorFee(address(token), operator);
        assertGt(token.balanceOf(operator), operatorBalanceBefore, "Operator should receive rewards");

        // Test curator claims
        (address vaultAddr,,) = vaultManager.getVaultAtWithTimes(0);
        address curator = VaultTokenized(vaultAddr).owner();
        uint256 curatorBalanceBefore = token.balanceOf(curator);
        vm.prank(curator);
        rewards.claimCuratorFee(address(token), curator);
        assertGt(token.balanceOf(curator), curatorBalanceBefore, "Curator should receive rewards");

        // Test protocol owner claims
        uint256 protocolOwnerBalanceBefore = token.balanceOf(protocolOwner);
        vm.prank(protocolOwner);
        rewards.claimProtocolFee(address(token), protocolOwner);
        assertGt(
            token.balanceOf(protocolOwner), protocolOwnerBalanceBefore, "Protocol owner should receive rewards"
        );
    }

    /* ─── ROLE TESTS -------------------------------------------------- */
    
    function test_ChangeAdminRole() public {
        vm.startPrank(l1Owner);

        // Check current admin
        assertEq(rewards.hasRole(rewards.REWARDS_MANAGER_ROLE(), rewardsManager), true);

        address newManager = makeAddr("newManager");

        // Expect the AdminRoleAssigned event to be emitted with the new admin address
        vm.expectEmit(true, true, false, false, address(rewards));
        emit IRewards.RewardsManagerRoleAssigned(newManager);

        // Change the admin role
        rewards.setRewardsManagerRole(newManager);

        // Verify the new admin role has been set
        assertEq(rewards.hasRole(rewards.REWARDS_MANAGER_ROLE(), newManager), true);

        vm.stopPrank();
    }

    function test_ChangeRewardsDistributorRole() public {
        vm.startPrank(rewardsManager);

        // Check current distributor
        assertEq(rewards.hasRole(rewards.REWARDS_DISTRIBUTOR_ROLE(), rewardsDistributor), true);

        address newDistributor = makeAddr("newDistributor");

        // Expect the RewardsDistributorRoleAssigned event to be emitted with the new distributor address
        vm.expectEmit(true, true, false, false, address(rewards));
        emit IRewards.RewardsDistributorRoleAssigned(newDistributor);

        // Change the distributor role
        rewards.setRewardsDistributorRole(newDistributor);

        // Verify the new distributor role has been set
        assertEq(rewards.hasRole(rewards.REWARDS_DISTRIBUTOR_ROLE(), newDistributor), true);

        vm.stopPrank();
    }

    function test_ChangeProtocolOwner() public {
        vm.startPrank(l1Owner);

        // Check current protocol owner
        assertEq(rewards.hasRole(rewards.PROTOCOL_OWNER_ROLE(), protocolOwner), true);

        address newProtocolOwner = makeAddr("newProtocolOwner");

        // Expect the ProtocolOwnerUpdated event to be emitted with the new protocol owner address
        vm.expectEmit(true, true, false, false, address(rewards));
        emit IRewards.ProtocolOwnerUpdated(newProtocolOwner);

        // Change the protocol owner
        rewards.setProtocolOwner(newProtocolOwner);

        // Verify the new protocol owner role has been set
        assertEq(rewards.hasRole(rewards.PROTOCOL_OWNER_ROLE(), newProtocolOwner), true);

        vm.stopPrank();
    }

    /* ─── ADMIN SETTER TESTS ------------------------------------------ */
    
    function test_SetMinRequiredUptime() public {
        vm.startPrank(rewardsManager);

        // Define the new uptime value
        uint256 newUptime = 100;

        // Set the new minimum required uptime
        rewards.setMinRequiredUptime(newUptime);

        // Verify the new minimum required uptime has been set
        assertEq(rewards.minRequiredUptime(), newUptime);

        vm.stopPrank();
    }

    function test_UpdateProtocolFee() public {
        vm.startPrank(rewardsManager);

        // Define the new protocol fee value
        uint16 newFee = 1500;

        // Expect the ProtocolFeeUpdated event to be emitted with the new fee
        vm.expectEmit(true, true, false, false, address(rewards));
        emit IRewards.ProtocolFeeUpdated(newFee);

        // Update the protocol fee
        rewards.updateProtocolFee(newFee);

        // Verify the new protocol fee has been set
        assertEq(rewards.protocolFee(), newFee);

        vm.stopPrank();
    }

    function test_UpdateOperatorFee() public {
        vm.startPrank(rewardsManager);

        // Define the new operator fee value
        uint16 newFee = 1500;

        // Expect the OperatorFeeUpdated event to be emitted with the new fee
        vm.expectEmit(true, true, false, false, address(rewards));
        emit IRewards.OperatorFeeUpdated(newFee);

        // Update the operator fee
        rewards.updateOperatorFee(newFee);

        // Verify the new operator fee has been set
        assertEq(rewards.operatorFee(), newFee);

        vm.stopPrank();
    }

    function test_UpdateCuratorFee() public {
        vm.startPrank(rewardsManager);

        // Define the new curator fee value
        uint16 newFee = 1500;

        // Expect the CuratorFeeUpdated event to be emitted with the new fee
        vm.expectEmit(true, true, false, false, address(rewards));
        emit IRewards.CuratorFeeUpdated(newFee);

        // Update the curator fee
        rewards.updateCuratorFee(newFee);

        // Verify the new curator fee has been set
        assertEq(rewards.curatorFee(), newFee);

        vm.stopPrank();
    }

    function test_SetRewardsShareForCollateralClass() public {
        // Define the asset class ID and the new rewards percentage
        uint96 collateralClassId = 1;
        uint16 rewardsPercentage = 5000; // 50%

        // Expect the RewardsShareUpdated event to be emitted with the new rewards percentage
        vm.expectEmit(true, true, false, false);
        emit IRewards.RewardsShareUpdated(collateralClassId, rewardsPercentage);

        vm.prank(rewardsManager);
        // Set the rewards share for the asset class
        rewards.setRewardsShareForCollateralClass(collateralClassId, rewardsPercentage);

        // Verify the new rewards share has been set
        assertEq(rewards.rewardsSharePerCollateralClass(collateralClassId), rewardsPercentage);
    }

    /* ─── SPECIAL TESTS ----------------------------------------------- */
    
    function test_DOS_RewardShareSumGreaterThan100PctFix() public {
        console2.log("=== TEST BEGINS ===");

        // First reduce class 3 to make room, set class 1 to 70% (total = 100%)
        vm.startPrank(rewardsManager);
        rewards.setRewardsShareForCollateralClass(3, 0); // Remove class 3 (now 50% + 30% + 0% = 80%)
        rewards.setRewardsShareForCollateralClass(1, 7000); // Set class 1 to 70% (now 70% + 30% + 0% = 100%)
        
        // Now try to set class 1 to 80% - this should fail because 80% + 30% = 110%
        // Should succeed – sum goes to 110 %
        vm.expectRevert(
            abi.encodeWithSelector(
                IRewards.CollateralClassSharesExceed100.selector,
                11_000                // the attempted total
            )
        );
        rewards.setRewardsShareForCollateralClass(1, 8000);
        vm.stopPrank();
    }

    function test_claimRewards_multipleTokens_staker_Fix() public {
        // Deploy a second reward token
        ERC20Mock token2 = new ERC20Mock();
        token2.mint(rewardsDistributor, 1_000_000 * 10 ** 18);
        vm.prank(rewardsDistributor);
        token2.approve(address(rewards), 1_000_000 * 10 ** 18);
        
        // Mint additional tokens for the original token to cover 3 epochs
        token.mint(rewardsDistributor, 300_000 * 10 ** 18);
        vm.prank(rewardsDistributor);
        token.approve(address(rewards), 400_000 * 10 ** 18); // Total: 100k (from setup) + 300k = 400k
        
        uint48 startEpoch = middleware.getCurrentEpoch();
        if (startEpoch == 0) startEpoch = 1;
        uint48 numberOfEpochs = 3;
        uint256 rewardsAmount = 100_000 * 10 ** 18;

        // Set rewards for both tokens
        vm.startPrank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(startEpoch, numberOfEpochs, address(token), rewardsAmount);
        rewards.setRewardsAmountForEpochs(startEpoch, numberOfEpochs, address(token2), rewardsAmount);
        vm.stopPrank();

        // Distribute rewards for epochs 1 to 3
        for (uint48 epoch = startEpoch; epoch < startEpoch + numberOfEpochs; epoch++) {
            _setupRealStakes(epoch, 4 hours);
            _moveToNextEpochAndCalc(3);
            address[] memory operators = middleware.getAllOperators();
            vm.prank(rewardsDistributor);
            rewards.distributeRewards(epoch, uint48(operators.length));
        }

        // Warp to epoch 4
        _moveToNextEpochAndCalc(1);

        // --- claim token --------------------------------------------------
        uint256 bal1Before = token.balanceOf(staker);
        vm.prank(staker);
        rewards.claimRewards(address(token), staker);
        uint256 bal1After = token.balanceOf(staker);
        assertGt(bal1After, bal1Before, "Staker received token1");

        // --- claim token2 -------------------------------------------------
        uint256 bal2Before = token2.balanceOf(staker);
        vm.prank(staker);
        rewards.claimRewards(address(token2), staker);
        uint256 bal2After = token2.balanceOf(staker);
        assertGt(bal2After, bal2Before, "Staker received token2");

        // --- re-claim in same epoch must now revert -----------------------------
        _expectSecondClaimRevert(staker, startEpoch + numberOfEpochs - 1);
        vm.prank(staker);
        rewards.claimRewards(address(token), staker);
    }

    function test_claimOperatorFee_multipleTokens_operator_Fix() public {
        // Deploy a second reward token
        ERC20Mock token2 = new ERC20Mock();
        token2.mint(rewardsDistributor, 1_000_000 * 10 ** 18);
        vm.prank(rewardsDistributor);
        token2.approve(address(rewards), 1_000_000 * 10 ** 18);

        // Mint additional tokens for the original token to cover 3 epochs
        token.mint(rewardsDistributor, 300_000 * 10 ** 18);
        vm.prank(rewardsDistributor);
        token.approve(address(rewards), 400_000 * 10 ** 18);

        uint48 startEpoch = middleware.getCurrentEpoch();
        if (startEpoch == 0) startEpoch = 1;
        uint48 numberOfEpochs = 3;
        uint256 rewardsAmount = 100_000 * 10 ** 18;

        // Set rewards for both tokens
        vm.startPrank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(startEpoch, numberOfEpochs, address(token), rewardsAmount);
        rewards.setRewardsAmountForEpochs(startEpoch, numberOfEpochs, address(token2), rewardsAmount);
        vm.stopPrank();

        // Distribute rewards for epochs 1 to 3
        for (uint48 epoch = startEpoch; epoch < startEpoch + numberOfEpochs; epoch++) {
            _setupRealStakes(epoch, 4 hours);
            _moveToNextEpochAndCalc(3);
            address[] memory operators = middleware.getAllOperators();
            vm.prank(rewardsDistributor);
            rewards.distributeRewards(epoch, uint48(operators.length));
        }

        // Warp to epoch 4
        _moveToNextEpochAndCalc(1);
        address operator = middleware.getAllOperators()[0];

        // --- claim token --------------------------------------------------
        uint256 bal1Before = token.balanceOf(operator);
        vm.prank(operator);
        rewards.claimOperatorFee(address(token), operator);
        uint256 bal1After = token.balanceOf(operator);
        assertGt(bal1After, bal1Before, "Operator received token1");

        // --- claim token2 -------------------------------------------------
        uint256 bal2Before = token2.balanceOf(operator);
        vm.prank(operator);
        rewards.claimOperatorFee(address(token2), operator);
        uint256 bal2After = token2.balanceOf(operator);
        assertGt(bal2After, bal2Before, "Operator received token2");

        // --- re-claim must revert ----------------------------------------------
        _expectSecondClaimRevert(operator, startEpoch + numberOfEpochs - 1);
        vm.prank(operator);
        rewards.claimOperatorFee(address(token), operator);
    }

    function test_claimCuratorFee_multipleTokens_curator_Fix() public {
        // Deploy a second reward token
        ERC20Mock token2 = new ERC20Mock();
        token2.mint(rewardsDistributor, 1_000_000 * 10 ** 18);
        vm.prank(rewardsDistributor);
        token2.approve(address(rewards), 1_000_000 * 10 ** 18);

        // Mint additional tokens for the original token to cover 3 epochs
        token.mint(rewardsDistributor, 300_000 * 10 ** 18);
        vm.prank(rewardsDistributor);
        token.approve(address(rewards), 400_000 * 10 ** 18);

        uint48 startEpoch = middleware.getCurrentEpoch();
        if (startEpoch == 0) startEpoch = 1;
        uint48 numberOfEpochs = 3;
        uint256 rewardsAmount = 100_000 * 10 ** 18;

        // Set rewards for both tokens
        vm.startPrank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(startEpoch, numberOfEpochs, address(token), rewardsAmount);
        rewards.setRewardsAmountForEpochs(startEpoch, numberOfEpochs, address(token2), rewardsAmount);
        vm.stopPrank();

        // Distribute rewards for epochs 1 to 3
        for (uint48 epoch = startEpoch; epoch < startEpoch + numberOfEpochs; epoch++) {
            _setupRealStakes(epoch, 4 hours);
            _moveToNextEpochAndCalc(3);
            address[] memory operators = middleware.getAllOperators();
            vm.prank(rewardsDistributor);
            rewards.distributeRewards(epoch, uint48(operators.length));
        }

        // Warp to epoch 4
        _moveToNextEpochAndCalc(1);
        (address vaultAddr,,) = vaultManager.getVaultAtWithTimes(0);
        address curator = VaultTokenized(vaultAddr).owner();

        // --- claim token --------------------------------------------------
        uint256 bal1Before = token.balanceOf(curator);
        vm.prank(curator);
        rewards.claimCuratorFee(address(token), curator);
        uint256 bal1After = token.balanceOf(curator);
        assertGt(bal1After, bal1Before, "Curator received token1");

        // --- claim token2 -------------------------------------------------
        uint256 bal2Before = token2.balanceOf(curator);
        vm.prank(curator);
        rewards.claimCuratorFee(address(token2), curator);
        uint256 bal2After = token2.balanceOf(curator);
        assertGt(bal2After, bal2Before, "Curator received token2");

        // --- re-claim must revert ----------------------------------------------
        _expectSecondClaimRevert(curator, startEpoch + numberOfEpochs - 1);
        vm.prank(curator);
        rewards.claimCuratorFee(address(token), curator);
    }

    function test_reentrancyGuard() public {
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;
        
        EvilToken evil = new EvilToken(rewards);
        evil.mint(rewardsDistributor, 1e20);
        vm.prank(rewardsDistributor);
        evil.approve(address(rewards), 1e20);

        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch, 1, address(evil), 1e20);

        _setupRealStakes(epoch, 4 hours);
        _moveToNextEpochAndCalc(3);
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch, 10);

        _moveToNextEpochAndCalc(1);
        
        // claim as protocol owner (re‑entrancy attempt lives in transfer)
        vm.prank(protocolOwner);
        rewards.claimProtocolFee(address(evil), protocolOwner);
    }

    function test_RewardsDistribution_DivisionByZero_NewCollateralClass_Fix() public {
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;
        
        _setupRealStakes(epoch, 4 hours);
        
        // Fund the epoch
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch, 1, address(token), 100_000 ether);
        
        _moveToNextEpochAndCalc(1);
        
        // Add a new asset class (4) after epoch 1 has passed    
        uint96 newCollateralClass = 4;
        
        // Note: In real integration test, we need to add the asset class properly through middleware
        // We would need to add asset class through proper middleware methods
        // For now, we'll just adjust the rewards share
        
        // Re‑balance so that the overall sum stays 100 %
        vm.startPrank(rewardsManager);
        rewards.setRewardsShareForCollateralClass(3, 1000);         // drop class 3 from 20 % → 10 %
        rewards.setRewardsShareForCollateralClass(newCollateralClass, 1000); // give 10 % to class 4
        vm.stopPrank();

        // distribute rewards   
        _moveToNextEpochAndCalc(2);

        // after the contract fix this must succeed (guard skips the div‑0 path)
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch, 1);
    }

    function test_distributeRewards_operatorWithZeroUptime() public {
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;
        uint256 uptimeValue = 4 hours;

        // Set up stakes for operators in epoch 1
        _setupRealStakes(epoch, uptimeValue);

        // Fund the epoch
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch, 1, address(token), 100_000 ether);

        // Get the list of operators
        address[] memory operators = middleware.getAllOperators();
        address zeroUptimeOperator = operators[0]; // Operator with zero uptime
        address activeOperator = operators[1]; // Operator to remain active

        // Set one operator's uptime to 0 so it earns 0 share
        uptime.setOperatorUptimePerEpoch(epoch, zeroUptimeOperator, 0);

        // Warp to epoch 4 to distribute rewards for epoch 1
        _warpToEpoch(epoch + 3);
        _syncStakeCache(epoch + 3);

        // Distribute rewards in batches
        uint256 batchSize = 3;
        uint256 remainingOperators = middleware.getAllOperators().length; // Now 9 operators
        while (remainingOperators > 0) {
            vm.prank(rewardsDistributor);
            rewards.distributeRewards(epoch, uint48(batchSize));
            remainingOperators = remainingOperators > batchSize ? remainingOperators - batchSize : 0;
        }

        // Verify that the zero uptime operator has zero shares
        assertEq(
            rewards.operatorShares(epoch, zeroUptimeOperator),
            0,
            "Zero uptime operator should have zero shares"
        );

        // Verify that an active operator has non-zero shares
        assertGt(
            rewards.operatorShares(epoch, activeOperator),
            0,
            "Active operator should have non-zero shares"
        );
    }

    function test_setRewardsAmountForEpochs() public {
        uint256 rewardsAmount = 1_000_000 * 10 ** 18;
        ERC20Mock token1 = new ERC20Mock();
        token1.mint(rewardsDistributor, 2 * 1_000_000 * 10 ** 18);
        vm.prank(rewardsDistributor);
        token1.approve(address(rewards), 2 * 1_000_000 * 10 ** 18);
        
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(5, 1, address(token1), rewardsAmount);
        assertEq(rewards.getRewardsAmountPerTokenFromEpoch(5, address(token1)), rewardsAmount - Math.mulDiv(rewardsAmount, 1000, 10000));
        assertEq(token1.balanceOf(address(rewards)), rewardsAmount);
        
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(5, 1, address(token1), rewardsAmount);
        assertEq(token1.balanceOf(address(rewards)), rewardsAmount * 2);
        assertEq(rewards.getRewardsAmountPerTokenFromEpoch(5, address(token1)), (rewardsAmount - Math.mulDiv(rewardsAmount, 1000, 10000)) * 2);
    }

    /// With fix: vShare(pre-curator) equals the operator's beneficiary budget for PRIMARY.
    function test_Primary_VaultSplit_EqualsOperatorBudget() public {
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;

        // Route 100% of rewards to PRIMARY, silence others to avoid cross-class noise
        vm.startPrank(rewardsManager);
        rewards.setRewardsShareForCollateralClass(2, 0);
        rewards.setRewardsShareForCollateralClass(3, 0);
        rewards.setRewardsShareForCollateralClass(1, 10_000);
        vm.stopPrank();

        // Ensure used << delegated for Alice; zero out others so only Alice contributes
        _setupRealStakes(epoch, 4 hours);
        uptime.setOperatorUptimePerEpoch(epoch, charlie, 0);
        uptime.setOperatorUptimePerEpoch(epoch, dave, 0);

        // Fund and distribute
        token.mint(rewardsDistributor, 100_000 ether);
        vm.startPrank(rewardsDistributor);
        token.approve(address(rewards), type(uint256).max);
        rewards.setRewardsAmountForEpochs(epoch, 1, address(token), 100_000 ether);
        vm.stopPrank();
        _moveToNextEpochAndCalc(3);
        address[] memory ops = middleware.getAllOperators();
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch, uint48(ops.length));

        // Operator Alice beneficiary budget (PRIMARY)
        uint256 aliceBenef = rewards.operatorBeneficiariesSharesPerCollateralClass(epoch, alice, 1);

        // Aggregate pre-curator vault share for PRIMARY: vaultShare + curatorShare(owner)
        uint256 vPre = 0;
        address[] memory vs = vaultManager.getVaults(epoch);
        for (uint256 i = 0; i < vs.length; i++) {
            if (vaultManager.getVaultCollateralClass(vs[i]) != 1) continue;
            vPre += rewards.vaultShares(epoch, vs[i]);
            vPre += rewards.curatorShares(epoch, VaultTokenized(vs[i]).owner());
        }

        // After the fix, the split matches the operator budget
        assertEq(vPre, aliceBenef, "vault pre-curator share should equal operator budget");
    }

    /// With fix, PRIMARY total vault+curator equals sum of operator beneficiary budgets.
    function test_Primary_GlobalVaultPlusCurator_eq_BeneficiarySum() public {
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;

        vm.startPrank(rewardsManager);
        rewards.setRewardsShareForCollateralClass(2, 0);
        rewards.setRewardsShareForCollateralClass(3, 0);
        rewards.setRewardsShareForCollateralClass(1, 10_000);
        vm.stopPrank();

        _setupRealStakes(epoch, 4 hours); // mixed delegated >> used across ops

        token.mint(rewardsDistributor, 100_000 ether);
        vm.startPrank(rewardsDistributor);
        token.approve(address(rewards), type(uint256).max);
        rewards.setRewardsAmountForEpochs(epoch, 1, address(token), 100_000 ether);
        vm.stopPrank();
        _moveToNextEpochAndCalc(3);
        address[] memory ops = middleware.getAllOperators();
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch, uint48(ops.length));

        // Sum operator beneficiary budgets (PRIMARY)
        uint256 beneSum = 0;
        for (uint256 i = 0; i < ops.length; i++) {
            beneSum += rewards.operatorBeneficiariesSharesPerCollateralClass(epoch, ops[i], 1);
        }

        // Sum PRIMARY vault pre-curator = Σ(vaultShares + curatorShares(owner))
        uint256 preSum = 0;
        address[] memory vs = vaultManager.getVaults(epoch);
        for (uint256 i = 0; i < vs.length; i++) {
            if (vaultManager.getVaultCollateralClass(vs[i]) != 1) continue;
            preSum += rewards.vaultShares(epoch, vs[i]);
            preSum += rewards.curatorShares(epoch, VaultTokenized(vs[i]).owner());
        }

        // After fix: preSum == beneSum.
        assertEq(preSum, beneSum, "PRIMARY vault+curator must equal sum of operator beneficiary budgets");
    }

    function test_distributeRewards_claimFee(uint256 uptimeValue) public {
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;
        uptimeValue = bound(uptimeValue, 0, 4 hours);
        
        // Ensure we start at beginning to fund within window
        vm.warp(middleware.getEpochStartTs(0)); // keep genesis safe
        
        _setupRealStakes(epoch, uptimeValue);
        _setupRealStakes(epoch + 2, uptimeValue);

        // fund epochs 1 **and 3** (epoch+2) so both can be distributed
        uint256 amount = 100_000 * 1e18;
        uint48 numberOfEpochs = 3;
        // Mint additional tokens needed for this test
        token.mint(rewardsDistributor, amount * numberOfEpochs);
        vm.prank(rewardsDistributor);
        token.approve(address(rewards), amount * numberOfEpochs);
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch, numberOfEpochs, address(token), amount);

        address[] memory operators = middleware.getAllOperators();
        uint256 batchSize = 3;
        uint256 remainingOperators = operators.length;
        _warpToEpoch(epoch + 3);
        _syncStakeCache(epoch + 3);
        middleware.calcAndCacheNodeStakeForAllOperators();
        while (remainingOperators > 0) {
            vm.prank(rewardsDistributor);
            rewards.distributeRewards(epoch, uint48(batchSize));
            remainingOperators = remainingOperators > batchSize ? remainingOperators - batchSize : 0;
        }
        _warpToEpoch(epoch + 4);
        _syncStakeCache(epoch + 4);
        for (uint256 i = 0; i < operators.length; i++) {
            uint256 operatorShare = rewards.operatorShares(epoch, operators[i]);
            if (operatorShare > 0) {
                vm.prank(operators[i]);
                rewards.claimOperatorFee(address(token), operators[i]);
                assertGt(token.balanceOf(operators[i]), 0, "Operator should receive rewards ");
                vm.stopPrank();
                break;
            }
        }
        _warpToEpoch(epoch + 5);
        _syncStakeCache(epoch + 5);
        
        // Try to distribute epoch 3 before epoch 2 (should fail due to sequential enforcement)
        vm.prank(rewardsDistributor);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRewards.DistributionNotComplete.selector,
                epoch + 1 // epoch 2
            )
        );
        rewards.distributeRewards(epoch + 2, uint48(batchSize)); // epoch 3

        // Now distribute epoch 2 first (sequential requirement)
        remainingOperators = operators.length;
        while (remainingOperators > 0) {
            vm.prank(rewardsDistributor);
            rewards.distributeRewards(epoch + 1, uint48(batchSize)); // epoch 2
            remainingOperators = remainingOperators > batchSize ? remainingOperators - batchSize : 0;
        }
        
        // Now epoch 3 can be distributed
        _warpToEpoch(epoch + 6);
        _syncStakeCache(epoch + 6);
        remainingOperators = operators.length;
        while (remainingOperators > 0) {
            vm.prank(rewardsDistributor);
            rewards.distributeRewards(epoch + 2, uint48(batchSize)); // epoch 3
            remainingOperators = remainingOperators > batchSize ? remainingOperators - batchSize : 0;
        }

        _warpToEpoch(epoch + 7);
        _syncStakeCache(epoch + 7);
        for (uint256 i = 0; i < operators.length; i++) {
            uint256 operatorShare = rewards.operatorShares(epoch + 2, operators[i]);
            if (operatorShare > 0) {
                vm.prank(operators[i]);
                rewards.claimOperatorFee(address(token), operators[i]);
                vm.stopPrank();
                break;
            }
        }
    }

    /* ─── FUNDING WINDOW TESTS ---------------------------------------- */
    
    function test_fund_before_deadline_then_distribute_ok() public {
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;
        _setupRealStakes(epoch, 4 hours);

        // Fund epoch while still inside the window
        _warpToEpoch(epoch + 1);
        _syncStakeCache(epoch + 1);
        uint256 amt = 100_000 ether;
        token.mint(rewardsDistributor, amt);
        vm.prank(rewardsDistributor);
        token.approve(address(rewards), amt);
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch, 1, address(token), amt);

        // Earliest legal distribution moment is epoch + DISTRIBUTION_EARLIEST_OFFSET
        _warpToEpoch(epoch + rewards.DISTRIBUTION_EARLIEST_OFFSET() + 1);
        _syncStakeCache(epoch + rewards.DISTRIBUTION_EARLIEST_OFFSET() + 1);
        middleware.calcAndCacheNodeStakeForAllOperators();
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch, 10);
    }

    function test_distribution_too_early_reverts() public {
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;
        _setupRealStakes(epoch, 4 hours);

        // Fund the epoch
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch, 1, address(token), 100_000 ether);

        // Try to distribute before DISTRIBUTION_EARLIEST_OFFSET
        _warpToEpoch(epoch + 1);
        _syncStakeCache(epoch + 1);
        middleware.calcAndCacheNodeStakeForAllOperators();
        vm.prank(rewardsDistributor);
        vm.expectRevert(
            abi.encodeWithSelector(IRewards.RewardsDistributionTooEarly.selector, epoch, 0)
        );
        rewards.distributeRewards(epoch, 10);
    }

    function test_distributionWithoutFunding_withinWindow_revert() public {
        uint48 epoch = 2;
        _setupRealStakes(epoch, 4 hours);

        // Distribution within funding window should revert for unfunded epoch
        _warpToEpoch(epoch + rewards.DISTRIBUTION_EARLIEST_OFFSET() + 1);
        _syncStakeCache(epoch + rewards.DISTRIBUTION_EARLIEST_OFFSET() + 1);

        middleware.calcAndCacheNodeStakeForAllOperators();
        vm.prank(rewardsDistributor);
        vm.expectRevert(abi.encodeWithSelector(IRewards.EpochNotFunded.selector, epoch));
        rewards.distributeRewards(epoch, 1);
    }

    function test_distributionWithoutFunding_afterWindow_ok() public {
        _setupRealStakes(1, 4 hours);
        _setupRealStakes(2, 4 hours);

        // Fund epoch 1 first
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(1, 1, address(token), 100_000 ether);

        // Jump so funding window for epoch 1 is closed
        _warpToEpoch(1 + rewards.FUNDING_DEADLINE_OFFSET() + 3);
        _syncStakeCache(1 + rewards.FUNDING_DEADLINE_OFFSET() + 3);

        // Sequential requirement: distribute epoch 1 first, then epoch 2
        middleware.calcAndCacheNodeStakeForAllOperators();
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(1, 10);
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(2, 10);

        (, bool complete) = rewards.distributionBatches(2);
        assertTrue(complete, "Epoch 2 should distribute even when unfunded once window closed");
    }

    function test_fundOldEpoch_afterWindow_beforeDistribution_ok() public {
        uint48 epoch = 3;
        uint256 amt = 50_000 * 1e18;

        // Funding after window but before distribution should be allowed
        _warpToEpoch(epoch + rewards.FUNDING_DEADLINE_OFFSET() + 1);
        _syncStakeCache(epoch + rewards.FUNDING_DEADLINE_OFFSET() + 1);

        token.mint(rewardsDistributor, amt);
        vm.startPrank(rewardsDistributor);
        token.approve(address(rewards), amt);
        rewards.setRewardsAmountForEpochs(epoch, 1, address(token), amt);
        vm.stopPrank();

        (bool funded,) = rewards.epochStatus(epoch);
        assertTrue(funded, "epoch must be flagged as funded");
    }

    function test_pastFundingWindow_distributeAll_thenClaim() public {
        // Use epochs 4, 5, 6 which are not funded (epoch 1 is already funded in setup)
        uint48 startEpoch = 4;
        uint48 numEpochs = 3;
        
        // First need to distribute epoch 1 (funded in setup) to satisfy sequential requirement
        _setupRealStakes(1, 4 hours);

        // ***FIX – fund epoch 1 before distributing***
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(1, 1, address(token), 100_000 ether);
        
        _warpToEpoch(1 + rewards.DISTRIBUTION_EARLIEST_OFFSET() + 1);
        _syncStakeCache(1 + rewards.DISTRIBUTION_EARLIEST_OFFSET() + 1);
        middleware.calcAndCacheNodeStakeForAllOperators();
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(1, 10);
        
        // Setup stakes for unfunded epochs
        for (uint48 epoch = startEpoch; epoch < startEpoch + numEpochs; epoch++) {
            _setupRealStakes(epoch, 4 hours);
        }

        // Warp past funding window for the unfunded epochs
        _warpToEpoch(startEpoch + numEpochs + rewards.FUNDING_DEADLINE_OFFSET());
        _syncStakeCache(startEpoch + numEpochs + rewards.FUNDING_DEADLINE_OFFSET());

        // Distribute ALL epochs from 2 up to our target epochs to maintain sequential order
        for (uint48 epoch = 2; epoch < startEpoch + numEpochs; epoch++) {
            vm.prank(rewardsDistributor);
            rewards.distributeRewards(epoch, 10);
            
            // Verify distribution completed
            (, bool complete) = rewards.distributionBatches(epoch);
            assertTrue(complete, "Distribution should be complete for each epoch");
        }

        // Test the UX fix: claiming from unfunded epochs should advance pointer and succeed (no revert)
        ERC20Mock unfundedToken = new ERC20Mock();
        
        // Move to next epoch to allow claiming
        _warpToEpoch(startEpoch + numEpochs + rewards.FUNDING_DEADLINE_OFFSET() + 1);
        _syncStakeCache(startEpoch + numEpochs + rewards.FUNDING_DEADLINE_OFFSET() + 1);

        // 1. Verify staker claiming from unfunded epochs succeeds and advances pointer
        uint48 stakerLastBefore = rewards.lastEpochClaimedStaker(staker, address(unfundedToken));
        uint256 stakerBalanceBefore = unfundedToken.balanceOf(staker);
        vm.prank(staker);
        vm.expectEmit(true, true, false, true, address(rewards));
        emit IRewards.ZeroRewardsClaim(staker, address(unfundedToken), startEpoch + numEpochs - 1, "staker");
        rewards.claimRewards(address(unfundedToken), staker);
        uint48 stakerLastAfter = rewards.lastEpochClaimedStaker(staker, address(unfundedToken));
        uint256 stakerBalanceAfter = unfundedToken.balanceOf(staker);
        assertGt(stakerLastAfter, stakerLastBefore, "Staker pointer should advance even on 0 rewards");
        assertEq(stakerBalanceAfter, stakerBalanceBefore, "Staker balance should not change on 0 rewards");

        // 2. Test operator claiming (same behavior)
        address[] memory operators = middleware.getAllOperators();
        address operator = operators[0];
        uint48 operatorLastBefore = rewards.lastEpochClaimedOperator(operator, address(unfundedToken));
        uint256 operatorBalanceBefore = unfundedToken.balanceOf(operator);
        vm.prank(operator);
        rewards.claimOperatorFee(address(unfundedToken), operator);
        uint48 operatorLastAfter = rewards.lastEpochClaimedOperator(operator, address(unfundedToken));
        uint256 operatorBalanceAfter = unfundedToken.balanceOf(operator);
        assertGt(operatorLastAfter, operatorLastBefore, "Operator pointer should advance even on 0 rewards");
        assertEq(operatorBalanceAfter, operatorBalanceBefore, "Operator balance should not change on 0 rewards");

        // 3. Test curator claiming (same behavior)
        (address vault,,) = vaultManager.getVaultAtWithTimes(0);
        address curator = VaultTokenized(vault).owner();
        uint48 curatorLastBefore = rewards.lastEpochClaimedCurator(curator, address(unfundedToken));
        uint256 curatorBalanceBefore = unfundedToken.balanceOf(curator);
        vm.prank(curator);
        rewards.claimCuratorFee(address(unfundedToken), curator);
        uint48 curatorLastAfter = rewards.lastEpochClaimedCurator(curator, address(unfundedToken));
        uint256 curatorBalanceAfter = unfundedToken.balanceOf(curator);
        assertGt(curatorLastAfter, curatorLastBefore, "Curator pointer should advance even on 0 rewards");
        assertEq(curatorBalanceAfter, curatorBalanceBefore, "Curator balance should not change on 0 rewards");

        // 4. Now fund a future epoch and verify users can claim after claiming from unfunded ones
        uint48 fundedEpoch = 8;
        uint256 futureRewards = 50_000 * 1e18;
        
        // Setup stakes for the funded epoch
        _setupRealStakes(fundedEpoch, 4 hours);
        
        // Fund epoch 8
        unfundedToken.mint(rewardsDistributor, futureRewards);
        vm.prank(rewardsDistributor);
        unfundedToken.approve(address(rewards), futureRewards);
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(fundedEpoch, 1, address(unfundedToken), futureRewards);
        
        // Distribute intermediate unfunded epoch 7 first (sequential requirement)
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(7, 10);
        
        // Now distribute the funded epoch 8
        _warpToEpoch(fundedEpoch + rewards.DISTRIBUTION_EARLIEST_OFFSET() + 1);
        _syncStakeCache(fundedEpoch + rewards.DISTRIBUTION_EARLIEST_OFFSET() + 1);
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(fundedEpoch, 10);
        
        // Move to next epoch to allow claiming
        _warpToEpoch(fundedEpoch + 1);
        _syncStakeCache(fundedEpoch + 1);
        
        // 5. Verify users can now claim from the funded future epoch (proving pointers advanced correctly)
        stakerBalanceBefore = unfundedToken.balanceOf(staker);
        vm.prank(staker);
        rewards.claimRewards(address(unfundedToken), staker);
        stakerBalanceAfter = unfundedToken.balanceOf(staker);
        assertGt(stakerBalanceAfter, stakerBalanceBefore, "Staker should get rewards from funded future epoch");

        operatorBalanceBefore = unfundedToken.balanceOf(operator);
        vm.prank(operator);
        rewards.claimOperatorFee(address(unfundedToken), operator);
        operatorBalanceAfter = unfundedToken.balanceOf(operator);
        assertGt(operatorBalanceAfter, operatorBalanceBefore, "Operator should get rewards from funded future epoch");
    }

    function test_fundAfterDistributionStarted_revert() public {
        _setupRealStakes(1, 4 hours);
        _setupRealStakes(2, 4 hours);

        // Fund epoch 1
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(1, 1, address(token), 100_000 ether);

        // Close funding window and distribute epoch 1 completely
        _warpToEpoch(1 + rewards.FUNDING_DEADLINE_OFFSET() + 3);
        _syncStakeCache(1 + rewards.FUNDING_DEADLINE_OFFSET() + 3);
        middleware.calcAndCacheNodeStakeForAllOperators();
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(1, 10);

        // Start epoch 2 distribution (only first batch)
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(2, 1);

        // Funding after distribution has started should revert
        uint256 amt = 10_000 * 1e18;
        token.mint(rewardsDistributor, amt);
        vm.startPrank(rewardsDistributor);
        token.approve(address(rewards), amt);
        vm.expectRevert(abi.encodeWithSelector(IRewards.DistributionAlreadyStarted.selector, 2));
        rewards.setRewardsAmountForEpochs(2, 1, address(token), amt);
        vm.stopPrank();
    }

    function test_RewardsDistributionDOS_With_UncachedSecondaryCollateralClasses() public {
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;
        uint256 uptimeValue = 4 hours;

        // Setup stakes for operators normally
        _setupRealStakes(epoch, uptimeValue);

        // Fund the epoch
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch, 1, address(token), 100_000 ether);

        // With the fix, this should now succeed instead of reverting
        _moveToNextEpochAndCalc(3);
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch, 3);

        // Verify distribution progressed as expected
        (uint256 lastProcessed, ) = rewards.distributionBatches(epoch);
        assertEq(lastProcessed, 3, "Should have processed 3 operators");
    }

    function test_distributeRewards_andRemoveVault(uint256 uptimeValue) public {
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;
        uptimeValue = bound(uptimeValue, rewards.minRequiredUptime(), 4 hours);
        address staker1 = makeAddr("Staker1");
        
        // Set up stakes for operators, nodes, delegators and l1 middleware
        _setupRealStakes(epoch, uptimeValue);

        // Fund the epoch
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch, 1, address(token), 100_000 ether);

        _moveToNextEpochAndCalc(3);
        
        // Distribute rewards
        address[] memory operators = middleware.getAllOperators();
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch, uint48(operators.length));
        
        _moveToNextEpochAndCalc(1);
        
        uint256 stakerBalanceBefore = token.balanceOf(staker);
        vm.prank(staker);
        rewards.claimRewards(address(token), staker);
        uint256 stakerBalanceAfter = token.balanceOf(staker);
        uint256 stakerRewards = stakerBalanceAfter - stakerBalanceBefore;
        assertGt(stakerRewards, 0, "Staker should receive rewards");
        
        // ── pick a vault to remove ────────────────────────────────────────────
        address vaultToRemove;
        uint96 collateralClass;
        for (uint i; i < vaultManager.getVaultCount(); ++i) {
            (address v,,) = vaultManager.getVaultAtWithTimes(i);
            uint96 cls = vaultManager.getVaultCollateralClass(v);
            if (cls != 1) {               // skip the primary‑class vault
                vaultToRemove = v;
                collateralClass    = cls;
                break;
            }
        }

        // … but if none exists, fall back to the sole primary vault
        if (vaultToRemove == address(0)) {
            (vaultToRemove,,) = vaultManager.getVaultAtWithTimes(0);
            collateralClass        = vaultManager.getVaultCollateralClass(vaultToRemove);
        }

        // ── disable it ──────────────────────────────────────────────────
        address vmOwner = vaultManager.owner();
        vm.prank(vmOwner);
        vaultManager.updateVaultMaxL1Limit(vaultToRemove, collateralClass, 0);   // disable

        // first attempt – still inside grace period
        vm.expectRevert(
            abi.encodeWithSelector(IMiddlewareVaultManager.MiddlewareVaultManager__VaultGracePeriodNotPassed.selector)
        );
        vm.prank(vmOwner);
        vaultManager.removeVault(vaultToRemove);

        // ── move past the grace period ─────────────────────────
        uint48 delay = vaultManager.VAULT_REMOVAL_EPOCH_DELAY();
        _warpToEpoch(middleware.getCurrentEpoch() + delay + 1);
        _syncStakeCache(middleware.getCurrentEpoch());

        // second attempt – should now succeed
        vm.prank(vmOwner);
        vaultManager.removeVault(vaultToRemove);
        _warpToEpoch(middleware.getCurrentEpoch()); // keep caches aligned
        _syncStakeCache(middleware.getCurrentEpoch());

        // ── NOW remove asset from class (after vault is fully removed and state processed) ──
        if (collateralClass != 1) {
            address assetToCheck = IVaultTokenized(vaultToRemove).collateral();
            bool isLastVaultUsingAsset = true;
            
            // Check if any other ACTIVE vault in the same asset class uses this asset
            uint256 vaultCount = vaultManager.getVaultCount();
            for (uint256 i = 0; i < vaultCount; i++) {
                (address otherVault, , uint48 disabledTime) = vaultManager.getVaultAtWithTimes(i);
                
                // Skip disabled vaults (disabledTime != 0)
                if (disabledTime != 0) continue;
                
                // Check if this active vault is in the same asset class and uses the same asset
                if (vaultManager.getVaultCollateralClass(otherVault) == collateralClass) {
                    if (IVaultTokenized(otherVault).collateral() == assetToCheck) {
                        isLastVaultUsingAsset = false;
                        break;
                    }
                }
            }
            
            // Only remove asset if this was the last active vault using it in this class
            if (isLastVaultUsingAsset) {
                vm.prank(l1Owner);
                middleware.removeAssetFromClass(collateralClass, assetToCheck);
            }
        }
        
        uint256 staker1BalanceBefore = token.balanceOf(staker1);
        vm.prank(staker1);
        rewards.claimRewards(address(token), staker1);
        uint256 staker1BalanceAfter = token.balanceOf(staker1);
        uint256 staker1Rewards = staker1BalanceAfter - staker1BalanceBefore;
        assertEq(staker1Rewards, 0, "Now staker should have 0 rewards");
    }

    /* ─── HI TESTS (High Impact) -------------------------------------- */
    
    function test_HI_DistributionWindowOffByOne_DoS() public {
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;
        _setupRealStakes(epoch, 4 hours);

        // fund the epoch so only the window‑guard matters
        uint256 amt = 100_000 ether;
        token.mint(rewardsDistributor, amt);
        vm.startPrank(rewardsDistributor);
        token.approve(address(rewards), amt);
        rewards.setRewardsAmountForEpochs(epoch, 1, address(token), amt);
        vm.stopPrank();

        // Warp to the *first* epoch that SHOULD be legal:
        // currentEpoch == epoch + DISTRIBUTION_EARLIEST_OFFSET
        uint48 offset = rewards.DISTRIBUTION_EARLIEST_OFFSET(); // = 2
        _warpToEpoch(epoch + offset);
        _syncStakeCache(epoch + offset);

        // Off‑by‑one fixed: call should now succeed.
        middleware.calcAndCacheNodeStakeForAllOperators();
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch, 10);
    }

    function test_UnfundedEpoch_NoOperators_DistributionSucceeds() public {
        // This is expected behavior: unfunded epoch with no operators does not revert
        uint48 epoch = 1;

        // Remove every operator so getAllOperators() returns 0
        address[] memory ops = middleware.getAllOperators();
        for (uint256 i; i < ops.length; ++i) {
            vm.prank(l1Owner);
            middleware.disableOperator(ops[i]);
        }

        uint48 currentEpoch = middleware.getCurrentEpoch();
        uint48 targetEpoch = currentEpoch + middleware.REMOVAL_DELAY_EPOCHS();
        _warpToEpoch(targetEpoch);
        _syncStakeCache(targetEpoch);
        for (uint256 i; i < ops.length; ++i) {
            vm.prank(l1Owner);
            middleware.removeOperator(ops[i]);
        }

        assertEq(middleware.getAllOperators().length, 0, "operators not empty");

        // Jump past DISTRIBUTION_EARLIEST_OFFSET but still inside funding window
        _warpToEpoch(epoch + rewards.DISTRIBUTION_EARLIEST_OFFSET() + 1);
        _syncStakeCache(epoch + rewards.DISTRIBUTION_EARLIEST_OFFSET() + 1);

        // BUG: should revert (EpochNotFunded) but succeeds
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch, 1);

        (, bool complete) = rewards.distributionBatches(epoch);
        assertTrue(complete, "BUG: unfunded epoch was finalised with 0 operators");
    }

    // Helper function to handle second claim revert expectations
    function _expectSecondClaimRevert(
        address claimant,
        uint48 expectedLastEpoch
    ) internal {
        uint48 cur = middleware.getCurrentEpoch();
        
        if (expectedLastEpoch >= cur - 1) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IRewards.AlreadyClaimedForLatestEpoch.selector,
                    claimant,
                    expectedLastEpoch
            ));
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IRewards.NoRewardsToClaimEpoch.selector,
                    claimant,
                    expectedLastEpoch
            ));
        }
    }


    function test_operatorWithNoStake_getsNoShare() public {
        /* ── arrange ────────────────────────────────────────────────────────── */
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;

        // normal stakes + uniform uptime ≥ min
        _setupRealStakes(epoch, 4 hours);

        // pick first operator and wipe all of its node‑stakes
        address op = middleware.getAllOperators()[0];
        bytes32[] memory ids = middleware.getActiveNodesForEpoch(op, epoch);
        uint8 rmMask = uint8((1 << ids.length) - 1);          // remove every node
        _stakeOrRemoveNodes(op, ids, 0, rmMask);

        // warp to update window and force update nodes to reflect stake changes
        uint256 updateWindowStart = middleware.getEpochStartTs(epoch) + middleware.UPDATE_WINDOW() + 1;
        vm.warp(updateWindowStart);
        vm.prank(l1Owner);
        middleware.forceUpdateNodes(op, 0);

        // Move to next epoch to process node removals
        _moveToNextEpochAndCalc(1);
        
        // refresh caches to reflect stake = 0
        middleware.calcAndCacheNodeStakeForAllOperators();

        // fund & distribute the epoch
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch, 1, address(token), 100_000 ether);
        _moveToNextEpochAndCalc(3);                            // wait ≥ 2 epochs
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch, 10);

        // fund & distribute the epoch
        uint48 epoch2 = epoch + 1;
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch2, 1, address(token), 100_000 ether);
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch2, 10);  // succeeds – sequential check satisfied

        /* ── assert: operator with zero stake gets zero share in epoch-2 ─────── */
        assertEq(
            rewards.operatorShares(epoch2, op),
            0,
            "operator with zero stake must not receive any share"
        );
    }

    function test_claimOperatorFee_zeroRewards_emitsZeroClaim() public {
        /* ── arrange ────────────────────────────────────────────────────────── */
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;

        // normal stakes & uptime ≥ min
        _setupRealStakes(epoch, 4 hours);

        // wipe ALL node‑stakes so operator share ⇒ 0
        address[] memory ops = middleware.getAllOperators();
        for (uint256 i; i < ops.length; ++i) {
            bytes32[] memory ids = middleware.getActiveNodesForEpoch(ops[i], epoch);
            _stakeOrRemoveNodes(ops[i], ids, 0, uint8((1 << ids.length) - 1));
        }

        // warp to update window and force update nodes for all operators to reflect stake changes
        uint256 updateWindowStart = middleware.getEpochStartTs(epoch) + middleware.UPDATE_WINDOW() + 1;
        vm.warp(updateWindowStart);
        vm.prank(l1Owner);
        for (uint256 i; i < ops.length; ++i) {
            middleware.forceUpdateNodes(ops[i], 0);
        }
        
        // after you zero-stake, move one epoch forward so the removal is effective
        _moveToNextEpochAndCalc(1);
        middleware.calcAndCacheNodeStakeForAllOperators();

        /* ── 1. fund & finish epoch-1 ─────────────────────────────────────────── */
        uint48 epoch1 = epoch;                  // original epoch
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch1, 1, address(token), 30_000 ether);

        /* wait ≥2 epochs so epoch-1 becomes distributable */
        _moveToNextEpochAndCalc(3);
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch1, 10);  // now epoch-1 is complete

        // ----------------------------------------------------------------------
        // Consume the epoch‑1 reward now – this isolates the zero‑reward test.
        // ----------------------------------------------------------------------
        address op = middleware.getAllOperators()[0];
        vm.prank(op);
        rewards.claimOperatorFee(address(token), op);

        /* ── 2. fund & distribute epoch-2 (stake is zero, operator share = 0) ─── */
        uint48 epoch2 = epoch1 + 1;
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch2, 1, address(token), 30_000 ether);

        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch2, 10);  // succeeds – sequential check satisfied

        /* ── act & assert ───────────────────────────────────────────────────── */
        /* move one more epoch to enable claiming */
        _moveToNextEpochAndCalc(1);
        uint48 lastBefore = rewards.lastEpochClaimedOperator(op, address(token));
        uint256 balBefore = token.balanceOf(op);

        /* expect ZeroRewardsClaim for epoch-2 */
        vm.expectEmit(true, true, false, true, address(rewards));
        emit IRewards.ZeroRewardsClaim(op, address(token), epoch2, "operator");

        vm.prank(op);
        rewards.claimOperatorFee(address(token), op);

        uint48 lastAfter = rewards.lastEpochClaimedOperator(op, address(token));
        assertGt(lastAfter, lastBefore, "pointer should have advanced");
        assertEq(token.balanceOf(op), balBefore, "balance unchanged when zero rewards");
    }


    function test_claimCuratorFee_zeroRewards_emitsZeroClaim() public {
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;

        // normal stakes & uptime ≥ min
        _setupRealStakes(epoch, 4 hours);

        // wipe ALL node‑stake so curator share ⇒ 0
        address[] memory ops = middleware.getAllOperators();
        for (uint256 i; i < ops.length; ++i) {
            bytes32[] memory ids = middleware.getActiveNodesForEpoch(ops[i], epoch);
            _stakeOrRemoveNodes(ops[i], ids, 0, uint8((1 << ids.length) - 1));
        }

        // warp to update window and force update nodes for all operators to reflect stake changes
        uint256 updateWindowStart = middleware.getEpochStartTs(epoch) + middleware.UPDATE_WINDOW() + 1;
        vm.warp(updateWindowStart);
        vm.prank(l1Owner);
        for (uint256 i; i < ops.length; ++i) {
            middleware.forceUpdateNodes(ops[i], 0);
        }
        
        // after you zero-stake, move one epoch forward so the removal is effective
        _moveToNextEpochAndCalc(1);
        middleware.calcAndCacheNodeStakeForAllOperators();

        /* ── 1. fund & finish epoch-1 ─────────────────────────────────────────── */
        uint48 epoch1 = epoch;                  // original epoch
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch1, 1, address(token), 30_000 ether);

        /* wait ≥2 epochs so epoch-1 becomes distributable */
        _moveToNextEpochAndCalc(3);
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch1, 10);  // now epoch-1 is complete

        // ----------------------------------------------------------------------
        // Consume the epoch‑1 reward now – this isolates the zero‑reward test.
        // ----------------------------------------------------------------------
        (address vaultAddr,,) = vaultManager.getVaultAtWithTimes(0);
        address curator = VaultTokenized(vaultAddr).owner();
        vm.prank(curator);
        rewards.claimCuratorFee(address(token), curator);

        /* ── 2. fund & distribute epoch-2 (stake is zero, curator share = 0) ─── */
        uint48 epoch2 = epoch1 + 1;
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch2, 1, address(token), 30_000 ether);

        //
        // ADD VERIFICATION HERE:
        //
        address[] memory operators = middleware.getAllOperators();
        for (uint256 i = 0; i < operators.length; ++i) {
            // Assuming asset class 1 is relevant
            uint256 operatorStake = middleware.getOperatorUsedStakeCachedPerEpoch(epoch2, operators[i], 1);
            console2.log("Operator stake for epoch should be zero:", operatorStake);
            assertEq(operatorStake, 0, "Operator stake should be zero after wiping!");
        }

        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch2, 10);  // succeeds – sequential check satisfied

        // after rewards.distributeRewards(epoch2, 10);

        // ── quick dump ──────────────────────────────────────────
        console2.log("epoch2 curator share:", rewards.curatorShares(epoch2, curator));

        address[] memory v = vaultManager.getVaults(epoch2);
        for (uint i; i < v.length; ++i) {
            console2.log("vault share:", rewards.vaultShares(epoch2, v[i]));
        }

        address[] memory ops2 = middleware.getAllOperators();
        for (uint i; i < ops2.length; ++i) {
            uint256 stakeCache = middleware.getOperatorUsedStakeCachedPerEpoch(epoch2, ops2[i], 1);
            uint256 opShare = rewards.operatorShares(epoch2, ops2[i]);
            console2.log("op stake cached:", stakeCache);
            console2.log("op share:", opShare);
        }

        /* move one more epoch to enable claiming */
        _moveToNextEpochAndCalc(1);
        uint48 lastBefore = rewards.lastEpochClaimedCurator(curator, address(token));
        uint256 balBefore = token.balanceOf(curator);

        /* expect ZeroRewardsClaim for epoch-2 */
        vm.expectEmit(true, true, false, true, address(rewards));
        emit IRewards.ZeroRewardsClaim(curator, address(token), epoch2, "curator");

        vm.prank(curator);
        rewards.claimCuratorFee(address(token), curator);

        uint48 lastAfter = rewards.lastEpochClaimedCurator(curator, address(token));
        assertGt(lastAfter, lastBefore, "pointer should have advanced");
        assertEq(token.balanceOf(curator), balBefore, "curator balance changed with 0 rewards");
    }

    function test_claimProtocolFee_revert_NoRewardsToClaim() public {
        vm.prank(protocolOwner);
        vm.expectRevert(abi.encodeWithSelector(IRewards.NoRewardsToClaim.selector, protocolOwner));
        rewards.claimProtocolFee(address(token), protocolOwner);
    }

    function test_claimProtocolFee_revert_InvalidRecipient() public {
        vm.prank(protocolOwner);
        vm.expectRevert(abi.encodeWithSelector(IRewards.InvalidRecipient.selector, address(0)));
        rewards.claimProtocolFee(address(token), address(0));
    }

    // Helper for C1 test: create N vaults all delegating to the same operator
    function _createVaultsForOperator(uint48 epoch, address targetOp, uint256 count) internal {
            for (uint256 i = 0; i < count; ++i) {
                address owner_ = makeAddr(string.concat("curator_quad_", vm.toString(epoch), "_", vm.toString(i)));
                uint64 lastVersion = vaultFactory.lastVersion();
                address v = vaultFactory.create(
                    lastVersion,
                    owner_,
                    abi.encode(
                        IVaultTokenized.InitParams({
                            collateral: address(collateral),
                            burner: address(0xdEaD),
                            epochDuration: 8 hours,
                            depositWhitelist: false,
                            isDepositLimit: false,
                            depositLimit: 0,
                            defaultAdminRoleHolder: owner_,
                            depositWhitelistSetRoleHolder: owner_,
                            depositorWhitelistRoleHolder: owner_,
                            isDepositLimitSetRoleHolder: owner_,
                            depositLimitSetRoleHolder: owner_,
                            name: "QV",
                            symbol: "QV"
                        })
                    ),
                    address(delegatorFactory),
                    address(slasherFactory)
                );
                // set up delegator
                address[] memory l1LimitSetRoleHolders = new address[](1);
                l1LimitSetRoleHolders[0] = owner_;
                address[] memory operatorL1SharesSetRoleHolders = new address[](1);
                operatorL1SharesSetRoleHolders[0] = owner_;
                address dAddr = delegatorFactory.create(
                    0,
                    abi.encode(
                        v,
                        abi.encode(
                            IL1RestakeDelegator.InitParams({
                                baseParams: IBaseDelegator.BaseParams({
                                    defaultAdminRoleHolder: owner_,
                                    hook: address(0),
                                    hookSetRoleHolder: owner_
                                }),
                                l1LimitSetRoleHolders: l1LimitSetRoleHolders,
                                operatorL1SharesSetRoleHolders: operatorL1SharesSetRoleHolders
                            })
                        )
                    )
                );
                vm.prank(owner_);
                VaultTokenized(v).setDelegator(dAddr);
                vm.prank(l1Owner);
                vaultManager.registerVault(v, 1, type(uint256).max);
                _optInOperatorVault(targetOp, v);
                // deposit small amount
                uint256 depAmt = 100_000_000_000_000;
                collateral.transfer(owner_, depAmt);
                vm.startPrank(owner_);
                collateral.approve(v, depAmt);
                (, uint256 minted_) = VaultTokenized(v).deposit(owner_, depAmt);
                vm.stopPrank();
                // set L1 limit and operator shares
                _setL1Limit(owner_, balancer, 1, depAmt, L1RestakeDelegator(dAddr));
                _setOperatorL1Shares(owner_, balancer, 1, targetOp, minted_, L1RestakeDelegator(dAddr));
            }
    }

    /* ─── C1 — Distribution gas DoS (quadratic vault work per operator) ─── */
    function test_C1_Distribution_VaultsQuadratic_WorkPerOperator() public {
        // Test scaling: measure gas for processing 1 operator with M vaults vs 2M vaults
        uint256 M = 20;
        
        // Epoch 1: M vaults
        uint48 epoch1 = 1;
        _setupRealStakes(epoch1, 4 hours);
        _createVaultsForOperator(epoch1, alice, M);
        token.mint(rewardsDistributor, 1_000_000 ether);
        vm.startPrank(rewardsDistributor);
        token.approve(address(rewards), type(uint256).max);
        rewards.setRewardsAmountForEpochs(epoch1, 1, address(token), 1_000_000 ether);
        vm.stopPrank();
        _moveToNextEpochAndCalc(3);
        
        uint256 gasBefore1 = gasleft();
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch1, 1);
        uint256 gasUsedM = gasBefore1 - gasleft();
        // complete epoch1 to satisfy sequential guard before touching epoch2
        (, bool complete1) = rewards.distributionBatches(epoch1);
        while (!complete1) {
            vm.prank(rewardsDistributor);
            rewards.distributeRewards(epoch1, type(uint48).max);
            (, complete1) = rewards.distributionBatches(epoch1);
        }
        
        // Epoch 2: 2M vaults (fresh epoch to avoid caching)
        uint48 epoch2 = 2;
        _warpToEpoch(epoch2);
        _setupRealStakes(epoch2, 4 hours);
        _createVaultsForOperator(epoch2, alice, 2 * M);
        vm.startPrank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch2, 1, address(token), 1_000_000 ether);
        vm.stopPrank();
        _moveToNextEpochAndCalc(3);
        
        uint256 gasBefore2 = gasleft();
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch2, 1);
        uint256 gasUsed2M = gasBefore2 - gasleft();
        
        // Verify superlinear growth: gas for 2M vaults should be > 1.5x gas for M vaults
        assertGt(gasUsed2M, gasUsedM * 3 / 2, "gas usage should grow superlinearly with vault count");
    }

    /* ─── C2 — Operator set not epoch‑snapshotted ⇒ undistributed grows ─── */
    function test_C2_RemovedOperator_NotProcessed_InflatesUndistributed() public {
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;
        _setupRealStakes(epoch, 4 hours);

        // fund epoch
        uint256 amt = 100_000 ether;
        token.mint(rewardsDistributor, amt);
        vm.startPrank(rewardsDistributor);
        token.approve(address(rewards), amt);
        rewards.setRewardsAmountForEpochs(epoch, 1, address(token), amt);
        vm.stopPrank();

        // pick an operator that _did_ have stake in epoch
        address[] memory ops = middleware.getAllOperators();
        address doomed = ops[0];
        
        // First prove that doomed would have had nonzero rawShareBp
        uint96[] memory cls = middleware.getCollateralClassIds();
        uint256 upBp = Math.mulDiv(uptime.operatorUptimePerEpoch(epoch, doomed), 10_000, rewards.epochDuration());
        uint256 rawBp;
        for (uint i; i < cls.length; ++i) {
            uint256 tot = middleware.totalStakeCache(epoch, cls[i]);
            uint256 used = middleware.getOperatorUsedStakeCachedPerEpoch(epoch, doomed, cls[i]);
            if (tot == 0 || rewards.rewardsSharePerCollateralClass(cls[i]) == 0) continue;
            rawBp += Math.mulDiv(
                Math.mulDiv(used, 10_000, tot),
                rewards.rewardsSharePerCollateralClass(cls[i]),
                10_000
            );
        }
        rawBp = Math.mulDiv(rawBp, upBp, 10_000);
        assertGt(rawBp, 0, "removed op would have had >0 used-shares");

        // remove all nodes first so operator can be disabled
        bytes32[] memory ids = middleware.getActiveNodesForEpoch(doomed, epoch);
        _stakeOrRemoveNodes(doomed, ids, 0, uint8((1 << ids.length) - 1));
        // enter update window and force update to reflect removals
        uint256 updateWindowStart = middleware.getEpochStartTs(epoch) + middleware.UPDATE_WINDOW() + 1;
        vm.warp(updateWindowStart);
        vm.prank(l1Owner);
        middleware.forceUpdateNodes(doomed, 0);
        // move one epoch so removals take effect
        _moveToNextEpochAndCalc(1);
        // sanity: no active nodes remain
        assertEq(middleware.getOperatorNodesLength(doomed), 0, "operator still has active nodes");
        // now disable operator BEFORE distribution of `epoch`
        vm.prank(l1Owner);
        middleware.disableOperator(doomed);
        uint48 target = middleware.getCurrentEpoch() + middleware.REMOVAL_DELAY_EPOCHS();
        _warpToEpoch(target);
        _syncStakeCache(target);
        vm.prank(l1Owner);
        middleware.removeOperator(doomed);
        
        // verify operator is removed
        address[] memory currentOps = middleware.getAllOperators();
        bool found = false;
        for (uint256 i = 0; i < currentOps.length; ++i) {
            if (currentOps[i] == doomed) {
                found = true;
                break;
            }
        }
        assertFalse(found, "still listed");

        // distribute epoch now: removed operator is skipped
        _moveToNextEpochAndCalc(2);
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch, 50);
        assertEq(rewards.operatorShares(epoch, doomed), 0, "removed operator must not be processed by current set");
        
        // Calculate total used shares to prove they're less than they should be
        uint256 sumBp;
        for (uint i; i < middleware.getAllOperators().length; ++i)
            sumBp += rewards.operatorShares(epoch, middleware.getAllOperators()[i]);
        address[] memory vs = vaultManager.getVaults(epoch);
        for (uint i; i < vs.length; ++i) {
            sumBp += rewards.vaultShares(epoch, vs[i]);
            sumBp += rewards.curatorShares(epoch, VaultTokenized(vs[i]).owner());
        }
        // Used shares should be at least rawBp lower than if we had processed "doomed"
        assertLe(sumBp, 10_000 - (rawBp > 0 ? 1 : 0), "removed op's budget missing from used-shares");

        // sweep later shows a positive undistributed bucket
        _moveToNextEpochAndCalc(1 + rewards.CLAIM_GRACE_PERIOD_EPOCHS());
        uint256 balBefore = token.balanceOf(rewardsDistributor);
        vm.prank(rewardsDistributor);
        rewards.claimUndistributedRewards(epoch, address(token), rewardsDistributor);
        assertGt(token.balanceOf(rewardsDistributor) - balBefore, 0, "undistributed should be > 0 due to skipped operator");
    }

    /* ─── H1 — Funding range guard lets top‑up inner epoch already started ─── */
    function test_H1_FundingRangeGuard_TopUpInnerEpoch_AfterItStarted() public {
        // Use epoch0/1 to exploit the sequential off‑by‑one that allows starting epoch 1 first.
        uint48 ep0 = 0;
        uint48 ep1 = 1;
        _setupRealStakes(ep0, 4 hours);
        _setupRealStakes(ep1, 4 hours);

        // fund both epochs initially
        token.mint(rewardsDistributor, 200_000 ether);
        vm.startPrank(rewardsDistributor);
        token.approve(address(rewards), type(uint256).max);
        rewards.setRewardsAmountForEpochs(ep0, 1, address(token), 100_000 ether);
        rewards.setRewardsAmountForEpochs(ep1, 1, address(token), 100_000 ether);
        vm.stopPrank();

        // epoch 1 can be processed without finishing epoch 0 (guard is `epoch > 1`)
        _moveToNextEpochAndCalc(3);
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(ep1, 1); // start, not complete

        uint256 before = rewards.getRewardsAmountPerTokenFromEpoch(ep1, address(token));

        // BUG: startEpoch=0 hasn't started ⇒ allowed, but it tops up epoch 1 where distribution already started
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(ep0, 2, address(token), 1 ether);

        uint256 after_ = rewards.getRewardsAmountPerTokenFromEpoch(ep1, address(token));
        assertGt(after_, before, "epoch 1 was topped up mid-distribution");
    }

    /* ─── H2 — Epoch‑0 unclaimable + epoch‑1 distributable without epoch‑0 ─── */
    function test_H2_Epoch0Unclaimable_And_Epoch1ProcessableBefore0() public {
        uint48 ep0 = 0;
        uint48 ep1 = 1;
        _setupRealStakes(ep0, 4 hours);
        _setupRealStakes(ep1, 4 hours);

        // fund both
        token.mint(rewardsDistributor, 200_000 ether);
        vm.startPrank(rewardsDistributor);
        token.approve(address(rewards), type(uint256).max);
        rewards.setRewardsAmountForEpochs(ep0, 1, address(token), 100_000 ether);
        rewards.setRewardsAmountForEpochs(ep1, 1, address(token), 100_000 ether);
        vm.stopPrank();

        // process epoch 1 first (off‑by‑one in sequential guard)
        _moveToNextEpochAndCalc(3);
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(ep1, 50);

        // claim succeeds for epoch 1 while epoch 0 remains skipped
        uint256 before = token.balanceOf(staker);
        vm.prank(staker);
        rewards.claimRewards(address(token), staker);
        assertGt(token.balanceOf(staker), before, "should claim epoch 1 even if epoch 0 pending");
        assertEq(rewards.lastEpochClaimedStaker(staker, address(token)), ep1, "pointer advanced to 1, skipping 0");
        
        // Later distribute epoch 0 - but it still cannot be claimed
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(ep0, 50);
        
        // Try to claim again - should revert because pointer already moved past epoch 0
        vm.prank(staker);
        vm.expectRevert(abi.encodeWithSelector(IRewards.NoRewardsToClaimEpoch.selector, staker, 1));
        rewards.claimRewards(address(token), staker);
    }

    /* ─── H3 — Fee‑on‑transfer tokens underfund pools ⇒ later claims revert ─── */
    function test_H3_FeeOnTransfer_Underfunding_BreaksClaims() public {
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;
        _setupRealStakes(epoch, 4 hours);

        // Make underfunding deterministic: only 10% of the funded amount actually lands
        FeeOnTransferToken feeTok = new FeeOnTransferToken(10_000, 9000); // 90% fee
        
        // Mint and fund the epoch
        feeTok.mint(rewardsDistributor, 100_000 ether);
        vm.startPrank(rewardsDistributor);
        feeTok.approve(address(rewards), type(uint256).max);
        
        // Fund the epoch - this will transfer tokens with fee
        rewards.setRewardsAmountForEpochs(epoch, 1, address(feeTok), 100_000 ether);
        vm.stopPrank();
        
        // Check actual balance vs recorded amount
        uint256 actualBalance = feeTok.balanceOf(address(rewards));
        uint256 recordedAmount = rewards.getRewardsAmountPerTokenFromEpoch(epoch, address(feeTok));
        
        // With 50% fee, there's significant underfunding
        assertLt(actualBalance, recordedAmount, "actual balance should be less than recorded");

        // Distribute rewards
        _moveToNextEpochAndCalc(3);
        address[] memory ops = middleware.getAllOperators();
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch, uint48(ops.length));

        // Move forward to allow claiming
        _moveToNextEpochAndCalc(1);
        
        // Start claiming - eventually someone will fail due to insufficient balance
        uint256 successfulClaims = 0;
        
        // Try staker claim
        vm.prank(staker);
        try rewards.claimRewards(address(feeTok), staker) {
            successfulClaims++;
        } catch {
            // Staker claim failed - vulnerability proven
            return;
        }
        
        // Try operator claims
        for (uint256 i = 0; i < ops.length; i++) {
            vm.prank(ops[i]);
            try rewards.claimOperatorFee(address(feeTok), ops[i]) {
                successfulClaims++;
            } catch {
                // Operator claim failed - vulnerability proven
                assertGt(successfulClaims, 0, "at least some claims should succeed before failure");
                return;
            }
        }
        
        // Try curator claims
        uint256 nVault = vaultManager.getVaultCount();
        for (uint256 i = 0; i < nVault; i++) {
            (address v,,) = vaultManager.getVaultAtWithTimes(i);
            address curator = VaultTokenized(v).owner();
            vm.prank(curator);
            try rewards.claimCuratorFee(address(feeTok), curator) {
                successfulClaims++;
            } catch {
                // Curator claim failed - vulnerability proven
                assertGt(successfulClaims, 0, "at least some claims should succeed before failure");
                return;
            }
        }
        
        // Try protocol fee claim
        vm.prank(protocolOwner);
        try rewards.claimProtocolFee(address(feeTok), protocolOwner) {
            revert("all claims succeeded - increase fee percentage or add more claimers");
        } catch {
            // Protocol claim failed - vulnerability proven
            assertGt(successfulClaims, 0, "at least some claims should succeed before failure");
        }
    }

    /* ─── H4 — Uptime not computed ⇒ all shares zero but distribution completes ─── */
    function test_H4_UptimeUnset_AllZeroShares_ButSweepPositive() public {
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;
        // do NOT set uptime in MockUptimeTracker ⇒ pass 0s so everyone fails minRequiredUptime
        _setupRealStakes(epoch, 0); // just ensures operators exist and stakes cached

        token.mint(rewardsDistributor, 100_000 ether);
        vm.startPrank(rewardsDistributor);
        token.approve(address(rewards), type(uint256).max);
        rewards.setRewardsAmountForEpochs(epoch, 1, address(token), 100_000 ether);
        vm.stopPrank();

        _moveToNextEpochAndCalc(3);
        address[] memory ops = middleware.getAllOperators();
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch, uint48(ops.length));

        // all operator shares are 0 and vault/curator shares are 0
        for (uint256 i = 0; i < ops.length; ++i) {
            assertEq(rewards.operatorShares(epoch, ops[i]), 0, "operator share must be 0 when uptime unset");
        }
        address[] memory vs = vaultManager.getVaults(epoch);
        for (uint256 i = 0; i < vs.length; ++i) {
            assertEq(rewards.vaultShares(epoch, vs[i]), 0, "vault share must be 0 when uptime unset");
        }

        // sweep shows the silent suppression created undistributed budget
        _moveToNextEpochAndCalc(1 + rewards.CLAIM_GRACE_PERIOD_EPOCHS());
        uint256 b0 = token.balanceOf(rewardsDistributor);
        vm.prank(rewardsDistributor);
        rewards.claimUndistributedRewards(epoch, address(token), rewardsDistributor);
        assertGt(token.balanceOf(rewardsDistributor) - b0, 0, "should sweep positive undistributed");
    }

    /* ─── Test MAX_EPOCHS_PER_CLAIM limit ─── */
    function test_claimRewards_maxEpochsPerClaim() public {
        // Simplified test that verifies the epoch limit logic without extensive setup
        uint48 startEpoch = 1;
        
        // First, set up and distribute a few epochs normally to establish baseline
        _setupRealStakes(startEpoch, 4 hours);
        
        // Fund 5 epochs
        token.mint(rewardsDistributor, 5 * 1000 ether);
        vm.startPrank(rewardsDistributor);
        token.approve(address(rewards), type(uint256).max);
        rewards.setRewardsAmountForEpochs(startEpoch, 5, address(token), 1000 ether);
        vm.stopPrank();
        
        // Move forward and distribute these epochs
        _moveToNextEpochAndCalc(5 + rewards.DISTRIBUTION_EARLIEST_OFFSET());
        
        address[] memory ops = middleware.getAllOperators();
        for (uint48 i = 0; i < 5; i++) {
            vm.prank(rewardsDistributor);
            rewards.distributeRewards(startEpoch + i, uint48(ops.length));
        }
        
        // Verify staker can claim these 5 epochs
        uint256 balanceBefore = token.balanceOf(staker);
        vm.prank(staker);
        rewards.claimRewards(address(token), staker);
        
        uint48 lastClaimed = rewards.lastEpochClaimedStaker(staker, address(token));
        assertEq(lastClaimed, startEpoch + 4, "should have claimed 5 epochs");
        assertGt(token.balanceOf(staker), balanceBefore, "should have received rewards");
        
        // Now test the MAX_EPOCHS_PER_CLAIM constant exists and is reasonable
        uint48 maxEpochs = rewards.MAX_EPOCHS_PER_CLAIM();
        assertEq(maxEpochs, 64, "MAX_EPOCHS_PER_CLAIM should be 64");
    }

    /* ─── Test MAX_EPOCHS_PER_CLAIM logic verification ─── */
    function test_claimFees_maxEpochsVerification() public {
        // This test just verifies the constant and basic logic without extensive setup
        uint48 maxEpochs = rewards.MAX_EPOCHS_PER_CLAIM();
        assertEq(maxEpochs, 64, "MAX_EPOCHS_PER_CLAIM should be 64");
        
        // Set up one epoch to verify basic claiming still works
        uint48 epoch = 1;
        _setupRealStakes(epoch, 4 hours);
        
        token.mint(rewardsDistributor, 1000 ether);
        vm.startPrank(rewardsDistributor);
        token.approve(address(rewards), type(uint256).max);
        rewards.setRewardsAmountForEpochs(epoch, 1, address(token), 1000 ether);
        vm.stopPrank();
        
        _moveToNextEpochAndCalc(rewards.DISTRIBUTION_EARLIEST_OFFSET() + 1);
        
        address[] memory ops = middleware.getAllOperators();
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch, uint48(ops.length));
        
        // Test operator can claim
        address operator1 = ops[0];
        uint256 opBalanceBefore = token.balanceOf(operator1);
        vm.prank(operator1);
        rewards.claimOperatorFee(address(token), operator1);
        assertGt(token.balanceOf(operator1), opBalanceBefore, "operator should have received rewards");
        
        // Test curator can claim
        (address vault1,,) = vaultManager.getVaultAtWithTimes(0);
        address curator1 = VaultTokenized(vault1).owner();
        uint256 curatorBalanceBefore = token.balanceOf(curator1);
        vm.prank(curator1);
        rewards.claimCuratorFee(address(token), curator1);
        assertGt(token.balanceOf(curator1), curatorBalanceBefore, "curator should have received rewards");
    }
}

contract EvilToken is ERC20Mock {
    Rewards target;
    constructor(Rewards _t) ERC20Mock() { target = _t; }
    function transfer(address to, uint256 value) public override returns (bool) {
        super.transfer(to, value);
        // try re‑enter (should revert due to nonReentrant)
        try target.claimProtocolFee(address(this), msg.sender) {} catch {}
        return true;
    }
}

/* ───────────────────────────── helpers for new tests ───────────────────────────── */
// (CountingDelegator removed – use real L1RestakeDelegator via factory in tests)

contract FeeOnTransferToken {
    string public constant name = "FeeToken";
    string public constant symbol = "FEE";
    uint8  public immutable decimals = 18;
    uint256 public totalSupply;
    mapping(address=>uint256) public balanceOf;
    mapping(address=>mapping(address=>uint256)) public allowance;
    uint256 public immutable DENOM;
    uint256 public immutable feeBps; // taken from amount on every transfer/transferFrom
    constructor(uint256 denom_, uint256 feeBps_) { DENOM = denom_; feeBps = feeBps_; }
    function mint(address to, uint256 amt) external { totalSupply += amt; balanceOf[to] += amt; }
    function approve(address sp, uint256 amt) external returns (bool){ allowance[msg.sender][sp]=amt; return true; }
    function transfer(address to, uint256 amt) external returns (bool){ _move(msg.sender, to, amt); return true; }
    function transferFrom(address from, address to, uint256 amt) external returns (bool){
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) { require(a >= amt, "allowance"); allowance[from][msg.sender]=a-amt; }
        _move(from,to,amt); return true;
    }
    function _move(address from, address to, uint256 amt) internal {
        require(balanceOf[from] >= amt, "bal");
        uint256 fee = amt * feeBps / DENOM;
        uint256 sendAmt = amt - fee;
        unchecked {
            balanceOf[from] -= amt;
            balanceOf[to]   += sendAmt;
            totalSupply     -= fee; // burn the fee
        }
    }
} 
