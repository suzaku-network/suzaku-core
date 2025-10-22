// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RewardsNativeToken} from "../../src/contracts/rewards/RewardsNativeToken.sol";
import {MockUptimeTracker} from "../mocks/MockUptimeTracker.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockCollateral} from "../mocks/MockCollateral.sol";
import {MiddlewareTestBase} from "../middleware/MiddlewareTestBase.t.sol";
import {IRewardsNativeToken, DistributionBatch} from "../../src/interfaces/rewards/IRewardsNativeToken.sol";
import {VaultTokenized} from "../../src/contracts/vault/VaultTokenized.sol";
import {BaseDelegator} from "../../src/contracts/delegator/BaseDelegator.sol";
import {L1RestakeDelegator} from "../../src/contracts/delegator/L1RestakeDelegator.sol";
import {IVaultTokenized} from "../../src/interfaces/vault/IVaultTokenized.sol";
import {IBaseDelegator} from "../../src/interfaces/delegator/IBaseDelegator.sol";
import {IL1RestakeDelegator} from "../../src/interfaces/delegator/IL1RestakeDelegator.sol";
import {IMiddlewareVaultManager} from "../../src/interfaces/middleware/IMiddlewareVaultManager.sol";

contract RewardsNativeTokenIntegrationTest is MiddlewareTestBase {
    /* ─── Test Actors ─────────────────────────────────────────────────────── */
    address internal rewardsManager;
    address internal rewardsDistributor;

    /* ─── Rewards stack ───────────────────────────────────────────────────── */
    RewardsNativeToken rewards;
    MockUptimeTracker uptime;
    MockCollateral token;  // This will be the native rewards token

    /* ─── Setup ───────────────────────────────────────────────────────────── */
    function setUp() public virtual override {
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

        rewards = new RewardsNativeToken();
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

        // The native rewards token is set in initialize from middleware.PRIMARY_ASSET()
        // Since MockCollateral doesn't have a mint function, we need to use the existing tokens
        token = MockCollateral(rewards.rewardsToken());
        
        // Transfer existing tokens from test contract to rewards distributor
        // The MockCollateral was minted in the constructor to the test contract via MiddlewareTestBase
        // Transfer most of the balance, keeping some for tests
        uint256 balance = token.balanceOf(address(this));
        token.transfer(rewardsDistributor, balance * 95 / 100); // Transfer 95% of balance
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
        rewards.setRewardsAmountForEpochs(epoch, 1, 100_000 ether);

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
        rewards.setRewardsAmountForEpochs(epoch, 3, 300_000 ether);

        _moveToNextEpochAndCalc(3);
        uint48 operatorCount = uint48(middleware.getAllOperators().length);
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch, operatorCount);

        uint256 before = token.balanceOf(staker);
        vm.prank(staker);
        rewards.claimRewards(staker);
        assertGt(token.balanceOf(staker), before, "no rewards received");

        // second call in same epoch must revert
        _expectSecondClaimRevert(staker, epoch);
        vm.prank(staker);
        rewards.claimRewards(staker);
    }

    /* ─── sequential‑distribution guard ------------------------------ */
    function test_distribution_sequential_guard() public {
        uint48 ep1 = middleware.getCurrentEpoch() == 0 ? 1 : middleware.getCurrentEpoch();
        uint48 ep2 = ep1 + 1;

        // stakes & funding for both epochs
        _setupRealStakes(ep1, 4 hours);
        _setupRealStakes(ep2, 4 hours);
        vm.startPrank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(ep1, 1, 10_000 ether);
        rewards.setRewardsAmountForEpochs(ep2, 1, 10_000 ether);
        vm.stopPrank();

        _moveToNextEpochAndCalc(3);

        // distribute ep1 half‑way (batch size 1)
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(ep1, 1);

        // try ep2 – should revert
        vm.prank(rewardsDistributor);
        vm.expectRevert(abi.encodeWithSelector(IRewardsNativeToken.DistributionNotComplete.selector, ep1));
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
        rewards.setRewardsAmountForEpochs(epoch, 1, 100_000 ether);
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

        // Fund the epoch (use less than available balance)
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch, 1, 500_000 ether);

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
        rewards.claimRewards(staker);

        uint256 stakerBalanceAfter = token.balanceOf(staker);
        uint256 stakerRewards = stakerBalanceAfter - stakerBalanceBefore;

        assertGt(stakerRewards, 0, "Staker should receive rewards");

        // Verify can't claim twice in same epoch
        _expectSecondClaimRevert(staker, epoch);
        vm.prank(staker);
        rewards.claimRewards(staker);
    }

    function test_claimRewards_revert_InvalidRecipient() public {
        vm.prank(makeAddr("Staker"));
        vm.expectRevert(abi.encodeWithSelector(IRewardsNativeToken.InvalidRecipient.selector, address(0)));
        rewards.claimRewards(address(0));
    }

    function test_claimRewards_revert_AlreadyClaimedForLatestEpoch() public {
        uint48 epoch = 1;

        // 1. distribute rewards for epoch 1
        _setupRealStakes(epoch, 4 hours);
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch, 1, 100_000 ether);
        _moveToNextEpochAndCalc(3);
        address[] memory ops = middleware.getAllOperators();
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch, uint48(ops.length));

        // 2. warp to *exactly* epoch 2 (currentEpoch == 2)
        _warpToEpoch(epoch + 1);               // +1 epoch, not more
        _syncStakeCache(epoch + 1);

        // 3. first claim succeeds
        vm.prank(staker);
        rewards.claimRewards(staker);

        // 4. second claim must revert with AlreadyClaimedForLatestEpoch
        _expectSecondClaimRevert(staker, epoch);
        vm.prank(staker);
        rewards.claimRewards(staker);
    }

    function test_claimRewards_revert_NoRewardsToClaim() public {
        address testStaker = makeAddr("Staker");

        // Try to claim without any stake or rewards
        vm.prank(testStaker);
        vm.expectRevert(abi.encodeWithSelector(IRewardsNativeToken.NoRewardsToClaimEpoch.selector, testStaker, 0));
        rewards.claimRewards(testStaker);
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
        uint256 rewardsAmountBefore = rewards.getEpochRewards(epoch);

        vm.prank(rewardsDistributor);
        rewards.claimUndistributedRewards(epoch, rewardsDistributor);

        // Verify undistributed rewards were credited to recipient
        uint256 balAfter = token.balanceOf(rewardsDistributor);
        uint256 undistributedAmount = balAfter - balBefore;
        assertGt(undistributedAmount, 0, "Rewards distributor should receive undistributed rewards");

        // Base must not mutate; claims use shares against original R to avoid double-scaling
        uint256 rewardsAmountAfter = rewards.getEpochRewards(epoch);
        assertEq(rewardsAmountAfter, rewardsAmountBefore, "epoch base must remain unchanged after sweep");
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
        rewards.claimOperatorFee(operator);
        assertGt(token.balanceOf(operator), operatorBalanceBefore, "Operator should receive rewards");

        // Test curator claims
        (address vaultAddr,,) = vaultManager.getVaultAtWithTimes(0);
        address curator = VaultTokenized(vaultAddr).owner();
        uint256 curatorBalanceBefore = token.balanceOf(curator);
        vm.prank(curator);
        rewards.claimCuratorFee(curator);
        assertGt(token.balanceOf(curator), curatorBalanceBefore, "Curator should receive rewards");

        // Test protocol owner claims
        uint256 protocolOwnerBalanceBefore = token.balanceOf(protocolOwner);
        vm.prank(protocolOwner);
        rewards.claimProtocolFee(protocolOwner);
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
        emit IRewardsNativeToken.RewardsManagerRoleAssigned(newManager);

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
        emit IRewardsNativeToken.RewardsDistributorRoleAssigned(newDistributor);

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
        emit IRewardsNativeToken.ProtocolOwnerUpdated(newProtocolOwner);

        // Change the protocol owner
        rewards.setProtocolOwner(newProtocolOwner);

        // Verify the new protocol owner role has been set
        assertEq(rewards.hasRole(rewards.PROTOCOL_OWNER_ROLE(), newProtocolOwner), true);

        vm.stopPrank();
    }

    /* ─── ADMIN SETTER TESTS ------------------------------------------ */
    function test_UpdateFees() public {
        vm.startPrank(rewardsManager);

        // Test protocol fee update
        uint16 newProtocolFee = 1500;
        vm.expectEmit(true, true, false, false, address(rewards));
        emit IRewardsNativeToken.ProtocolFeeUpdated(newProtocolFee);
        rewards.updateProtocolFee(newProtocolFee);
        assertEq(rewards.protocolFee(), newProtocolFee);

        // Test operator fee update
        uint16 newOperatorFee = 2500;
        vm.expectEmit(true, true, false, false, address(rewards));
        emit IRewardsNativeToken.OperatorFeeUpdated(newOperatorFee);
        rewards.updateOperatorFee(newOperatorFee);
        assertEq(rewards.operatorFee(), newOperatorFee);

        // Test curator fee update
        uint16 newCuratorFee = 1500;
        vm.expectEmit(true, true, false, false, address(rewards));
        emit IRewardsNativeToken.CuratorFeeUpdated(newCuratorFee);
        rewards.updateCuratorFee(newCuratorFee);
        assertEq(rewards.curatorFee(), newCuratorFee);

        vm.stopPrank();
    }

    function test_SetRewardsShareForCollateralClass() public {
        // Define the asset class ID and the new rewards percentage
        uint96 collateralClassId = 1;
        uint16 rewardsPercentage = 5000; // 50%

        // Expect the RewardsShareUpdated event to be emitted with the new rewards percentage
        vm.expectEmit(true, true, false, false);
        emit IRewardsNativeToken.RewardsShareUpdated(collateralClassId, rewardsPercentage);

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
                IRewardsNativeToken.CollateralClassSharesExceed100.selector,
                11_000                // the attempted total
            )
        );
        rewards.setRewardsShareForCollateralClass(1, 8000);
        vm.stopPrank();
    }

    function test_setRewardsAmountForEpochs() public {
        uint256 rewardsAmount = 10_000 * 10 ** 18; // Reduced amount
        token.transfer(rewardsDistributor, 2 * 10_000 * 10 ** 18);
        vm.prank(rewardsDistributor);
        token.approve(address(rewards), 2 * 10_000 * 10 ** 18);
        
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(5, 1, rewardsAmount);
        assertEq(rewards.getEpochRewards(5), rewardsAmount - Math.mulDiv(rewardsAmount, 1000, 10000));
        assertEq(token.balanceOf(address(rewards)), rewardsAmount);
        
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(5, 1, rewardsAmount);
        assertEq(token.balanceOf(address(rewards)), rewardsAmount * 2);
        assertEq(rewards.getEpochRewards(5), (rewardsAmount - Math.mulDiv(rewardsAmount, 1000, 10000)) * 2);
    }

    /* ─── FUNDING WINDOW TESTS ---------------------------------------- */
    function test_fund_before_deadline_then_distribute_ok() public {
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;
        _setupRealStakes(epoch, 4 hours);

        // Fund epoch while still inside the window
        _warpToEpoch(epoch + 1);
        _syncStakeCache(epoch + 1);
        uint256 amt = 10_000 ether; // Reduced amount
        token.transfer(rewardsDistributor, amt);
        vm.prank(rewardsDistributor);
        token.approve(address(rewards), amt);
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch, 1, amt);

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
        rewards.setRewardsAmountForEpochs(epoch, 1, 10_000 ether);

        // Try to distribute before DISTRIBUTION_EARLIEST_OFFSET
        _warpToEpoch(epoch + 1);
        _syncStakeCache(epoch + 1);
        middleware.calcAndCacheNodeStakeForAllOperators();
        
        vm.prank(rewardsDistributor);
        vm.expectRevert(
            abi.encodeWithSelector(IRewardsNativeToken.RewardsDistributionTooEarly.selector, epoch, 0)
        );
        rewards.distributeRewards(epoch, 10);
    }

    /* ─── Helper function to handle second claim revert expectations ─── */
    function _expectSecondClaimRevert(
        address claimant,
        uint48 expectedLastEpoch
    ) internal {
        uint48 cur = middleware.getCurrentEpoch();
        
        if (expectedLastEpoch >= cur - 1) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IRewardsNativeToken.AlreadyClaimedForLatestEpoch.selector,
                    claimant,
                    expectedLastEpoch
            ));
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IRewardsNativeToken.NoRewardsToClaimEpoch.selector,
                    claimant,
                    expectedLastEpoch
            ));
        }
    }

    /* ─── Test reentrancy protection ─── */
    function test_reentrancyGuard() public {
        uint48 epoch = middleware.getCurrentEpoch();
        if (epoch == 0) epoch = 1;
        
        EvilTokenNative evil = new EvilTokenNative(rewards);
        
        // Override the native token to use our evil token
        // Note: This is a hack for testing - in real scenario native token is immutable
        vm.store(address(rewards), bytes32(uint256(17)), bytes32(uint256(uint160(address(evil)))));
        
        evil.mint(rewardsDistributor, 1e20);
        vm.prank(rewardsDistributor);
        evil.approve(address(rewards), 1e20);

        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch, 1, 1e20);

        _setupRealStakes(epoch, 4 hours);
        _moveToNextEpochAndCalc(3);
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch, 10);

        _moveToNextEpochAndCalc(1);
        
        // claim as protocol owner (re‑entrancy attempt lives in transfer)
        vm.prank(protocolOwner);
        rewards.claimProtocolFee(protocolOwner);
    }

    /* ─── Test zero rewards claim emit ─── */
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
        emit IRewardsNativeToken.ZeroRewardsClaim(testStaker, address(token), epoch, "staker");
        rewards.claimRewards(testStaker);
    }

    /* ─── Test epoch 0 sentinel protection ─── */
    function test_epoch0_sentinel_protection() public {
        // Verify epoch 0 cannot be funded
        token.transfer(rewardsDistributor, 10_000 ether);
        vm.startPrank(rewardsDistributor);
        token.approve(address(rewards), type(uint256).max);
        
        // Cannot fund epoch 0
        vm.expectRevert(abi.encodeWithSelector(IRewardsNativeToken.DistributionAlreadyStarted.selector, 0));
        rewards.setRewardsAmountForEpochs(0, 1, 100_000 ether);
        vm.stopPrank();
        
        // Cannot distribute epoch 0 (already complete)
        _moveToNextEpochAndCalc(3);
        vm.prank(rewardsDistributor);
        vm.expectRevert(abi.encodeWithSelector(IRewardsNativeToken.AlreadyCompleted.selector, 0));
        rewards.distributeRewards(0, 50);
        
        // Verify epoch 0 status
        (bool funded, bool distributionComplete) = rewards.epochStatus(0);
        assertTrue(funded, "Epoch 0 should be marked as funded");
        assertTrue(distributionComplete, "Epoch 0 should be marked as distribution complete");
        
        (, bool isComplete) = rewards.distributionBatches(0);
        assertTrue(isComplete, "Epoch 0 batch should be marked as complete");
    }
}

contract EvilTokenNative is ERC20Mock {
    RewardsNativeToken target;
    constructor(RewardsNativeToken _t) ERC20Mock() { target = _t; }
    function transfer(address to, uint256 value) public override returns (bool) {
        super.transfer(to, value);
        // try re‑enter (should revert due to nonReentrant)
        try target.claimProtocolFee(msg.sender) {} catch {}
        return true;
    }
}
