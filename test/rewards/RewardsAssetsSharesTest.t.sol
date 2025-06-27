// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {MockAvalancheL1Middleware} from "../mocks/MockAvalancheL1Middleware.sol";
import {MockUptimeTracker} from "../mocks/MockUptimeTracker.sol";
import {MockVaultManager} from "../mocks/MockVaultManager.sol";
import {MockDelegator} from "../mocks/MockDelegator.sol";
import {MockVault} from "../mocks/MockVault.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Rewards} from "../../src/contracts/rewards/Rewards.sol";
import {IRewards} from "../../src/interfaces/rewards/IRewards.sol";
import {BaseDelegator} from "../../src/contracts/delegator/BaseDelegator.sol";
import {IVaultTokenized} from "../../src/interfaces/vault/IVaultTokenized.sol";

contract RewardsAssetShareTest is Test {
    // Contracts
    MockAvalancheL1Middleware public middleware;
    MockUptimeTracker public uptimeTracker;
    MockVaultManager public vaultManager;
    Rewards public rewards;
    ERC20Mock public rewardsToken;

    // Test addresses
    address constant ADMIN = address(0x1);
    address constant PROTOCOL_OWNER = address(0x2);
    address constant REWARDS_MANAGER = address(0x3);
    address constant REWARDS_DISTRIBUTOR = address(0x4);
    address constant OPERATOR_A = address(0x1000);
    address constant OPERATOR_B = address(uint160(0x1000 + 1));

    function setUp() public {
        // Deploy mock contracts - simplified setup for our POC
        vaultManager = new MockVaultManager();
        //Set up 2 operators
        uint256[] memory nodesPerOperator = new uint256[](2);
        nodesPerOperator[0] = 1; // Operator 0x1000 has 1 node
        nodesPerOperator[1] = 1; // Operator A has 1 node
        middleware = new MockAvalancheL1Middleware(
            2,
            nodesPerOperator,
            address(0),
            address(vaultManager)
        );
        uptimeTracker = new MockUptimeTracker();

        // Deploy Rewards contract
        rewards = new Rewards();
        rewardsToken = new ERC20Mock();

        // Initialize with no fees to match our simplified example
        rewards.initialize(
            ADMIN,
            PROTOCOL_OWNER,
            payable(address(middleware)),
            address(uptimeTracker),
            0, // protocolFee = 0%
            0, // operatorFee = 0%
            0, // curatorFee = 0%
            0 // minRequiredUptime = 0
        );

        // Set up roles
        vm.prank(ADMIN);
        rewards.setRewardsManagerRole(REWARDS_MANAGER);
        vm.prank(REWARDS_MANAGER);
        rewards.setRewardsDistributorRole(REWARDS_DISTRIBUTOR);
        
        // Set up rewards token
        rewardsToken.mint(REWARDS_DISTRIBUTOR, 1_000_000 * 10**18);
        vm.prank(REWARDS_DISTRIBUTOR);
        rewardsToken.approve(address(rewards), 1_000_000 * 10**18);
    }

    function test_AssetShareFormula() public {
        uint48 epoch = 1;
        // Set Asset Class 1 to 50% rewards share (5000 basis points)
        vm.prank(REWARDS_MANAGER);
        rewards.setRewardsShareForAssetClass(1, 5000); // 50%
        vm.prank(REWARDS_MANAGER);
        rewards.setRewardsShareForAssetClass(2, 2000); // 20%
        vm.prank(REWARDS_MANAGER);
        rewards.setRewardsShareForAssetClass(3, 3000); // 30%

        // Set total stake in Asset Class 1 = 1000 tokens across network
        middleware.setTotalStakeCache(epoch, 1, 1000);
        middleware.setTotalStakeCache(epoch, 2, 100); // Asset Class 2: 100 tokens
        middleware.setTotalStakeCache(epoch, 3, 100); // Asset Class 3: 100 tokens

        // Set Operator A stake = 300 tokens (30% of network)
        middleware.setOperatorStake(epoch, OPERATOR_A, 1, 300);
        // Set operator A node stake (for primary asset class calculation)
        bytes32[] memory operatorNodes = middleware.getOperatorNodes(OPERATOR_A);
        middleware.setNodeStake(epoch, operatorNodes[0], 300);

        // No stake in other asset classes for Operator A
        middleware.setOperatorStake(epoch, OPERATOR_A, 2, 0);
        middleware.setOperatorStake(epoch, OPERATOR_A, 3, 0);
        bytes32[] memory operatorBNodes = middleware.getOperatorNodes(OPERATOR_B);
        middleware.setNodeStake(epoch, operatorBNodes[0], 700); // Remaining Asset Class 1 stake
        middleware.setOperatorStake(epoch, OPERATOR_B, 1, 700);
        middleware.setOperatorStake(epoch, OPERATOR_B, 2, 100);
        middleware.setOperatorStake(epoch, OPERATOR_B, 3, 100);

        // Set 100% uptime for Operator A & B
        uptimeTracker.setOperatorUptimePerEpoch(epoch, OPERATOR_A, 4 hours);
        uptimeTracker.setOperatorUptimePerEpoch(epoch, OPERATOR_B, 4 hours);

        // Create a vault for Asset Class 1 with 300 tokens staked (100% of operator's stake)
        address vault1Owner = address(0x500);
        (address vault1, address delegator1) = vaultManager.deployAndAddVault(
            address(0x123), // collateral
            vault1Owner
        );
        middleware.setAssetInAssetClass(1, vault1);
        vaultManager.setVaultAssetClass(vault1, 1);

        // Create vault for Asset Class 2
        address vault2Owner = address(0x600);
        (address vault2, address delegator2) = vaultManager.deployAndAddVault(address(0x123), vault2Owner);
        middleware.setAssetInAssetClass(2, vault2);
        vaultManager.setVaultAssetClass(vault2, 2);

        // Create vault for Asset Class 3
        address vault3Owner = address(0x700);
        (address vault3, address delegator3) = vaultManager.deployAndAddVault(
            address(0x125), // different collateral
            vault3Owner
        );
        middleware.setAssetInAssetClass(3, vault3);
        vaultManager.setVaultAssetClass(vault3, 3);

        // Set vault delegation: 300 tokens staked to Operator A
        uint256 epochTs = middleware.getEpochStartTs(epoch);
        MockDelegator(delegator1).setStake(
            middleware.L1_VALIDATOR_MANAGER(),
            1, // asset class
            OPERATOR_A,
            uint48(epochTs),
            300 // stake amount
        );
        MockDelegator(delegator1).setStake(middleware.L1_VALIDATOR_MANAGER(), 1, OPERATOR_B, uint48(epochTs), 700);
        MockDelegator(delegator2).setStake(
            middleware.L1_VALIDATOR_MANAGER(), 2, OPERATOR_B, uint48(epochTs), 100
        );
        MockDelegator(delegator3).setStake(
            middleware.L1_VALIDATOR_MANAGER(), 3, OPERATOR_B, uint48(epochTs), 100
        );

        // Set rewards for the epoch: 100,000 tokens
        vm.prank(REWARDS_DISTRIBUTOR);
        rewards.setRewardsAmountForEpochs(epoch, 1, address(rewardsToken), 100_000);

        // Wait 3 epochs as required by contract
        vm.warp((epoch + 3) * middleware.EPOCH_DURATION());

        // Distribute rewards
        vm.prank(REWARDS_DISTRIBUTOR);
        rewards.distributeRewards(epoch, 2);

        // Get calculated shares MANUALLY for the test
        uint256 operatorAShare_Class1 = rewards.operatorBeneficiariesSharesPerAssetClass(epoch, OPERATOR_A, 1);
        uint256 operatorAShare_Class2 = rewards.operatorBeneficiariesSharesPerAssetClass(epoch, OPERATOR_A, 2);
        uint256 operatorAShare_Class3 = rewards.operatorBeneficiariesSharesPerAssetClass(epoch, OPERATOR_A, 3);
        uint256 totalOperatorAShare = operatorAShare_Class1 + operatorAShare_Class2 + operatorAShare_Class3;

        uint256 operatorBShare_Class1 = rewards.operatorBeneficiariesSharesPerAssetClass(epoch, OPERATOR_B, 1);
        uint256 operatorBShare_Class2 = rewards.operatorBeneficiariesSharesPerAssetClass(epoch, OPERATOR_B, 2);
        uint256 operatorBShare_Class3 = rewards.operatorBeneficiariesSharesPerAssetClass(epoch, OPERATOR_B, 3);
        uint256 totalOperatorBShare = operatorBShare_Class1 + operatorBShare_Class2 + operatorBShare_Class3;

        uint256 vault1Share = rewards.vaultShares(epoch, vault1);
        uint256 vault2Share = rewards.vaultShares(epoch, vault2);
        uint256 vault3Share = rewards.vaultShares(epoch, vault3);

        console2.log("=== RESULTS ===");
        console2.log("Calculated totalOperatorAShare =", totalOperatorAShare, "basis points");
        console2.log("vaultShares[vault_1] =", vault1Share, "basis points");
        console2.log("Calculated totalOperatorBShare =", totalOperatorBShare, "basis points");
        console2.log("vaultShares[vault_2] =", vault2Share, "basis points");
        console2.log("vaultShares[vault_3] =", vault3Share, "basis points");

        // Assertions
        assertEq(totalOperatorAShare, 1500, "Operator A total share should be 1500 basis points (15%)");
        assertEq(totalOperatorBShare, 8500, "Operator B total share should be 8500 basis points (85%)");

        // The assertions for vault shares remain the same, but their comments need updating
        // because the old reasoning was based on the flawed logic.
        assertEq(vault1Share, 5000, "Vault 1 share should be 5000 basis points");
        assertEq(vault2Share, 2000, "Vault 2 share should now correctly be 2000 basis points");
        assertEq(vault3Share, 3000, "Vault 3 share should now correctly be 3000 basis points");
    }

    function test_UnusedStakeDoesNotLeakRewards() public {
        uint48 epoch = 1;

        // --- Setup ---
        // Asset Class 1 gets 100% of rewards for simplicity
        vm.prank(REWARDS_MANAGER);
        rewards.setRewardsShareForAssetClass(1, 10000); // 100%

        // Total stake in the asset class is 1000
        middleware.setTotalStakeCache(epoch, 1, 1000);

        // Operator A has 100 *active* stake, but 200 *total* stake
        // For asset class 1, used stake is calculated from node stakes
        bytes32[] memory operatorANodes = middleware.getOperatorNodes(OPERATOR_A);
        middleware.setNodeStake(epoch, operatorANodes[0], 100); // Active stake (via node)
        middleware.setOperatorStake(epoch, OPERATOR_A, 1, 200); // Total stake

        // Set 100% uptime
        uptimeTracker.setOperatorUptimePerEpoch(epoch, OPERATOR_A, 4 hours);

        // A single vault delegates the full 100 active stake to Operator A
        (address vault, address delegator) = vaultManager.deployAndAddVault(address(0x123), address(0x500));
        vaultManager.setVaultAssetClass(vault, 1);
        uint256 epochTs = middleware.getEpochStartTs(epoch);
        MockDelegator(delegator).setStake(middleware.L1_VALIDATOR_MANAGER(), 1, OPERATOR_A, uint48(epochTs), 100);

        // Set rewards for the epoch
        vm.prank(REWARDS_DISTRIBUTOR);
        rewards.setRewardsAmountForEpochs(epoch, 1, address(rewardsToken), 100_000);
        
        vm.warp((epoch + 3) * middleware.EPOCH_DURATION());

        // --- Action ---
        vm.prank(REWARDS_DISTRIBUTOR);
        rewards.distributeRewards(epoch, 1);

        // --- Assertion ---
        // Operator A's share of the asset class budget is 100/1000 = 10%
        // Since asset class share is 100%, this is 1000 basis points.
        uint256 operatorShare = rewards.operatorBeneficiariesSharesPerAssetClass(epoch, OPERATOR_A, 1);
        assertEq(operatorShare, 1000, "Operator A beneficiary share should be 10%");

        // The vault contributed 100% of the operator's active stake (100/100).
        // It should receive 100% of the operator's beneficiary share.
        uint256 vaultShare = rewards.vaultShares(epoch, vault);
        assertEq(vaultShare, 1000, "Vault should receive the full 1000bp, with no leakage");
    }
}
