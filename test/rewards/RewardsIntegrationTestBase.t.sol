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

/**
 * @title RewardsIntegrationTestBase
 * @notice Base class providing rewards system setup without test functions.
 * @dev This allows other test contracts to inherit the setup without inheriting all tests.
 */
contract RewardsIntegrationTestBase is MiddlewareTestBase {
    /* ─── Test Actors ─────────────────────────────────────────────────────── */
    address internal rewardsManager;
    address internal rewardsDistributor;

    /* ─── Rewards stack ───────────────────────────────────────────────────── */
    Rewards           rewards;
    MockUptimeTracker uptime;
    ERC20Mock         token;

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

    /* ─── Helper: fund rewards for epoch ────────────────────────────────────── */
    function _fundEpoch(uint48 epoch, uint256 amount) internal {
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch, 1, address(token), amount);
    }

    /* ─── Helper: distribute rewards for epoch ──────────────────────────────── */
    function _distributeEpoch(uint48 epoch) internal {
        uint256 operatorCount = middleware.getAllOperators().length;
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch, uint48(operatorCount));
    }
}
