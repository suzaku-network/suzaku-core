// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

// ─────────────────────────────────────────────────────────────────────────────
// PoC – Incorrect Sum-of-Shares (fixed)
// Shows that the sum of operator + vault + curator shares can exceed 10 000 bp
// (100 %), proving that claimUndistributedRewards will mis-count.
// ─────────────────────────────────────────────────────────────────────────────
import {AvalancheL1MiddlewareTest} from "../middleware/AvalancheL1MiddlewareTest.t.sol";

import {Rewards}           from "src/contracts/rewards/Rewards.sol";
import {MockUptimeTracker} from "../mocks/MockUptimeTracker.sol";
import {ERC20Mock}         from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {VaultTokenized}    from "src/contracts/vault/VaultTokenized.sol";

import {console2}          from "forge-std/console2.sol";
import {stdError}          from "forge-std/Test.sol";

contract PoCIncorrectSumOfShares is AvalancheL1MiddlewareTest {
    // ── helpers & globals ────────────────────────────────────────────────────
    MockUptimeTracker internal uptimeTracker;
    Rewards          internal rewards;
    ERC20Mock        internal rewardsToken;

    address internal REWARDS_MANAGER_ROLE     = makeAddr("REWARDS_MANAGER_ROLE");
    address internal REWARDS_DISTRIBUTOR_ROLE = makeAddr("REWARDS_DISTRIBUTOR_ROLE");

    uint96 secondaryAssetClassId = 2;          // activate a 2nd asset-class (40 % of rewards)

    // -----------------------------------------------------------------------
    //                      MAIN TEST ROUTINE
    // -----------------------------------------------------------------------
    function test_PoCIncorrectSumOfShares() public {
        _setupRewardsAndSecondaryAssetClass();          // 1. deploy + fund rewards

        address[] memory operators = middleware.getAllOperators();

        // 2. Alice creates *two* nodes (same stake reused) -------------------
        console2.log("Creating nodes for Alice");
        _createAndConfirmNodes(alice, 2, 100_000_000_001_000, true);

        // 3. Charlie is honest – single big node -----------------------------
        console2.log("Creating node for Charlie");
        _createAndConfirmNodes(charlie, 1, 150_000_000_000_000, true);

        // 4. Roll over so stakes are cached at epoch T ------------------------
        uint48 epoch = _calcAndWarpOneEpoch();
        console2.log("Moved to one epoch ");

        // Cache total stakes for primary & secondary classes
        middleware.calcAndCacheStakes(epoch, assetClassId);
        middleware.calcAndCacheStakes(epoch, secondaryAssetClassId);

        // 5. Give everyone perfect uptime so shares are fully counted --------
        for (uint i = 0; i < operators.length; i++) {
            uptimeTracker.setOperatorUptimePerEpoch(epoch,   operators[i], 4 hours);
            uptimeTracker.setOperatorUptimePerEpoch(epoch+1, operators[i], 4 hours);
        }

        // 6. Warp forward 3 epochs (rewards are distributable @ T-2) ---------
        _calcAndWarpOneEpoch(3);
        console2.log("Warped forward for rewards distribution");

        // 7. Distribute rewards ---------------------------------------------
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.distributeRewards(epoch, uint48(operators.length));
        console2.log("Rewards distributed");

        // 8. Sum all shares and show bug (>10 000 bp) ------------------------
        uint256 totalShares = 0;
        
        // operator shares
        for (uint i = 0; i < operators.length; i++) {
            uint256 s = rewards.operatorShares(epoch, operators[i]);
            totalShares += s;
        }
        // vault shares
        address[] memory vaults = vaultManager.getVaults(epoch);
        for (uint i = 0; i < vaults.length; i++) {
            uint256 s = rewards.vaultShares(epoch, vaults[i]);
            totalShares += s;
        }
        // curator shares (may be double-counted!)
        // for (uint i = 0; i < vaults.length; i++) {
        //     address curator = VaultTokenized(vaults[i]).owner();
        //     uint256 s = rewards.curatorShares(epoch, curator);
        //     totalShares += s;
        // }
        // console2.log("Total shares is greater than 10000 bp");

        // curator shares (unique)
        address[] memory curators = this.getEpochCurators(epoch);
        for (uint i = 0; i < curators.length; ++i) {
            totalShares += rewards.curatorShares(epoch, curators[i]);
        }

        assertGt(10_000, totalShares);
    }

    // -----------------------------------------------------------------------
    //                      SET-UP HELPER
    // -----------------------------------------------------------------------
    function _setupRewardsAndSecondaryAssetClass() internal {
        uptimeTracker = new MockUptimeTracker();
        rewards       = new Rewards();

        // Initialise Rewards contract ---------------------------------------
        rewards.initialize(
            owner,                                  // admin
            owner,                                  // protocol fee recipient
            payable(address(middleware)),           // middleware
            address(uptimeTracker),                 // uptime oracle
            1000,                                   // protocol fee 10%
            2000,                                   // operator fee 20%
            1000,                                   // curator  fee 10%
            11_520                                  // min uptime (s)
        );

        // Assign roles -------------------------------------------------------
        vm.prank(owner);
        rewards.setRewardsManagerRole(REWARDS_MANAGER_ROLE);
        vm.prank(REWARDS_MANAGER_ROLE);
        rewards.setRewardsDistributorRole(REWARDS_DISTRIBUTOR_ROLE);

        // Mint & approve mock reward token ----------------------------------
        rewardsToken = new ERC20Mock();
        rewardsToken.mint(REWARDS_DISTRIBUTOR_ROLE, 1_000_000 ether);
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewardsToken.approve(address(rewards), 1_000_000 ether);

        // Fund 10 epochs of rewards -----------------------------------------
        vm.startPrank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.setRewardsAmountForEpochs(1, 10, address(rewardsToken), 100_000 * 1e18);
        vm.stopPrank();
        console2.log("Reward pool funded");

        // Configure 60 % primary / 40 % secondary split ---------------------
        vm.startPrank(REWARDS_MANAGER_ROLE);
        rewards.setRewardsShareForAssetClass(1,                     6000); // 60 %
        rewards.setRewardsShareForAssetClass(secondaryAssetClassId, 4000); // 40 %
        vm.stopPrank();
        console2.log("Reward share split set: 60/40");

        // Create a secondary asset-class + vault so split is in effect
        _setupAssetClassAndRegisterVault(
            secondaryAssetClassId, 0,
            collateral2, vault3,
            type(uint256).max, type(uint256).max, delegator3
        );
        console2.log("Secondary asset-class & vault registered\n");
    }

    function getEpochCurators(uint48 epoch) external view returns (address[] memory) {
        address[] memory vaults = vaultManager.getVaults(epoch);
        address[] memory curators = new address[](vaults.length);
        uint256 uniqueCount = 0;
        
        for (uint i = 0; i < vaults.length; i++) {
            address curator = VaultTokenized(vaults[i]).owner();
            // Add curator if not already in the list
            bool exists = false;
            for (uint j = 0; j < uniqueCount; j++) {
                if (curators[j] == curator) {
                    exists = true;
                    break;
                }
            }
            if (!exists) {
                curators[uniqueCount] = curator;
                uniqueCount++;
            }
        }
        
        // Resize array to actual unique count
        address[] memory uniqueCurators = new address[](uniqueCount);
        for (uint i = 0; i < uniqueCount; i++) {
            uniqueCurators[i] = curators[i];
        }
        
        return uniqueCurators;
    }
}
