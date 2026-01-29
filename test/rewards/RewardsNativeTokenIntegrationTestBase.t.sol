// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RewardsNativeToken} from "../../src/contracts/rewards/RewardsNativeToken.sol";
import {MockUptimeTracker} from "../mocks/MockUptimeTracker.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MiddlewareTestBase} from "../middleware/MiddlewareTestBase.t.sol";
import {Token} from "../mocks/MockToken.sol";
import {MockCollateral} from "../mocks/MockCollateral.sol";
import {IRewardsNativeToken} from "../../src/interfaces/rewards/IRewardsNativeToken.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {VaultTokenized} from "../../src/contracts/vault/VaultTokenized.sol";
import {BaseDelegator} from "../../src/contracts/delegator/BaseDelegator.sol";
import {L1RestakeDelegator} from "../../src/contracts/delegator/L1RestakeDelegator.sol";
import {IVaultTokenized} from "../../src/interfaces/vault/IVaultTokenized.sol";
import {IBaseDelegator} from "../../src/interfaces/delegator/IBaseDelegator.sol";
import {IL1RestakeDelegator} from "../../src/interfaces/delegator/IL1RestakeDelegator.sol";
import {IMiddlewareVaultManager} from "../../src/interfaces/middleware/IMiddlewareVaultManager.sol";

/**
 * @title RewardsNativeTokenIntegrationTestBase
 * @notice Base class providing native token rewards system setup without test functions.
 * @dev This allows other test contracts to inherit the setup without inheriting all tests.
 */
contract RewardsNativeTokenIntegrationTestBase is MiddlewareTestBase {
    /* ─── Test Actors ─────────────────────────────────────────────────────── */
    address internal rewardsManager;
    address internal rewardsDistributor;

    /* ─── Rewards stack ───────────────────────────────────────────────────── */
    RewardsNativeToken rewards;
    MockUptimeTracker uptime;
    Token token;

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

        // Deploy implementation contract (with _disableInitializers in constructor)
        RewardsNativeToken implementation = new RewardsNativeToken();
        
        // Encode initialization data
        bytes memory initData = abi.encodeWithSelector(
            RewardsNativeToken.initialize.selector,
            l1Owner,  // Rewards should be owned by l1Owner according to the new ownership model
            protocolOwner,
            payable(address(middleware)),             // real middleware
            address(uptime),
            1000,  // protocolFee (bp)
            2000,  // operatorFee
            1000,  // curatorFee
            11_520  // minRequiredUptime (3.2 h)
        );
        
        // Deploy proxy and initialize in one transaction
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        rewards = RewardsNativeToken(address(proxy));

        vm.prank(l1Owner);
        rewards.setRewardsManagerRole(rewardsManager);
        vm.prank(rewardsManager);
        rewards.setRewardsDistributorRole(rewardsDistributor);

        // The rewards token is the underlying asset of the primary collateral
        address rewardsTokenAddr = rewards.rewardsToken();
        address expectedNativeToken = MockCollateral(address(collateral)).asset();
        require(rewardsTokenAddr == expectedNativeToken, "Rewards token should be underlying asset");
        token = Token(rewardsTokenAddr);
        
        // Transfer native tokens to rewards distributor for funding
        uint256 balance = token.balanceOf(address(this));
        token.transfer(rewardsDistributor, balance * 95 / 100);
        vm.prank(rewardsDistributor);
        token.approve(address(rewards), type(uint256).max);

        // 50‑30‑20 asset‑class split (matches MiddlewareTestBase)
        vm.startPrank(rewardsManager);
        rewards.setRewardsBipsForCollateralClass(1, 5000);
        rewards.setRewardsBipsForCollateralClass(2, 3000);
        rewards.setRewardsBipsForCollateralClass(3, 2000);
        vm.stopPrank();
    }

    /* ─── Helper: fund rewards for epoch ────────────────────────────────────── */
    function _fundEpoch(uint48 epoch, uint256 amount) internal {
        vm.prank(rewardsDistributor);
        rewards.setRewardsAmountForEpochs(epoch, 1, amount);
    }

    /* ─── Helper: distribute rewards for epoch ──────────────────────────────── */
    function _distributeEpoch(uint48 epoch) internal {
        uint256 operatorCount = middleware.getAllOperators().length;
        vm.prank(rewardsDistributor);
        rewards.distributeRewards(epoch, uint48(operatorCount));
    }
}
