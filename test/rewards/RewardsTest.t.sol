// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {MockAvalancheL1Middleware} from "../mocks/MockAvalancheL1Middleware.sol";
import {MockUptimeTracker} from "../mocks/MockUptimeTracker.sol";
import {MockVaultManager} from "../mocks/MockVaultManager.sol";
import {MockDelegator} from "../mocks/MockDelegator.sol";
import {MockVault} from "../mocks/MockVault.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {Rewards} from "../../src/contracts/rewards/Rewards.sol";

contract RewardsTest is Test {
    // EVENTS
    event AdminRoleAssigned(address indexed newAdmin);
    event ProtocolOwnerUpdated(address indexed newProtocolOwner);
    event ProtocolFeeUpdated(uint16 newFee);
    event OperatorFeeUpdated(uint16 newFee);
    event CuratorFeeUpdated(uint16 newFee);
    event RewardsShareUpdated(uint96 indexed assetClassId, uint16 rewardsPercentage);
    event RewardsAmountSet(
        uint48 indexed startEpoch, uint256 numberOfEpochs, address indexed rewardsToken, uint256 rewardsAmount
    );
    event RewardsDistributed(uint48 indexed epoch);

    // ROLES
    address immutable ADMIN = makeAddr("Admin");
    address immutable PROTOCOL_OWNER = makeAddr("Protocol owner");

    // MOCK CONTRACTS
    MockAvalancheL1Middleware public middleware;
    MockUptimeTracker public uptimeTracker;
    MockDelegator[] public delegators;
    MockVaultManager public vaultManager;

    // MAIN
    Rewards public rewards;

    function setUp() public {
        // set number of operator on L1 and number of nodes per operator
        uint256 operatorCount = 3;
        uint256[] memory nodesPerOperator = new uint256[](3);
        nodesPerOperator[0] = 2;
        nodesPerOperator[1] = 3;
        nodesPerOperator[2] = 1;

        middleware = new MockAvalancheL1Middleware(operatorCount, nodesPerOperator);
        vaultManager = new MockVaultManager();
        uptimeTracker = new MockUptimeTracker();

        rewards = new Rewards();

        uint16 protocolFee = 1000;
        uint16 operatorFee = 2000;
        uint16 curatorFee = 1000;

        // INITIALIZE ROLES, FEES, AND CONTRACT DEPENDANCES
        rewards.initialize(
            ADMIN,
            PROTOCOL_OWNER,
            address(middleware),
            address(vaultManager),
            address(uptimeTracker),
            protocolFee,
            operatorFee,
            curatorFee
        );

        // Setup mock vaults
        // Vault 1 (Primary Asset Class)
        address mockCollateral1 = makeAddr("Collateral1");
        (address vaultAddress1, address delegatorAddress1) = vaultManager.deployAndAddVault(mockCollateral1);
        middleware.setAssetInAssetClass(1, vaultAddress1);

        // Vault 2 (Secondary Asset Class 1)
        address mockCollateral2 = makeAddr("Collateral2");
        (address vaultAddress2, address delegatorAddress2) = vaultManager.deployAndAddVault(mockCollateral2);
        middleware.setAssetInAssetClass(2, vaultAddress2);

        // Vault 3 (Secondary Asset Class 2)
        address mockCollateral3 = makeAddr("Collateral3");
        (address vaultAddress3, address delegatorAddress3) = vaultManager.deployAndAddVault(mockCollateral3);
        middleware.setAssetInAssetClass(3, vaultAddress3);

        delegators.push(MockDelegator(delegatorAddress1));
        delegators.push(MockDelegator(delegatorAddress2));
        delegators.push(MockDelegator(delegatorAddress3));
    }

    // TEST ROLE FUNCTIONS
    function test_ChangeAdminRole() public {
        vm.startPrank(ADMIN);

        // Check current admin
        assertEq(rewards.hasRole(rewards.ADMIN_ROLE(), ADMIN), true);

        address newAdmin = makeAddr("newAdmin");

        // Expect the AdminRoleAssigned event to be emitted with the new admin address
        vm.expectEmit(true, true, false, false, address(rewards));
        emit AdminRoleAssigned(newAdmin);

        // Change the admin role
        rewards.setAdminRole(newAdmin);

        // Verify the new admin role has been set
        assertEq(rewards.hasRole(rewards.ADMIN_ROLE(), newAdmin), true);

        // Verify the old admin role has been revoked (if that's the intended behavior)
        assertEq(rewards.hasRole(rewards.ADMIN_ROLE(), ADMIN), false);

        vm.stopPrank();
    }

    function test_ChangeProtocolOwner() public {
        vm.startPrank(ADMIN);

        // Check current protocol owner
        assertEq(rewards.hasRole(rewards.PROTOCOL_OWNER_ROLE(), PROTOCOL_OWNER), true);

        address newProtocolOwner = makeAddr("newProtocolOwner");

        // Expect the ProtocolOwnerUpdated event to be emitted with the new protocol owner address
        vm.expectEmit(true, true, false, false, address(rewards));
        emit ProtocolOwnerUpdated(newProtocolOwner);

        // Change the protocol owner
        rewards.setProtocolOwner(newProtocolOwner);

        // Verify the new protocol owner role has been set
        assertEq(rewards.hasRole(rewards.PROTOCOL_OWNER_ROLE(), newProtocolOwner), true);

        vm.stopPrank();
    }

    // TEST ADMIN SETTER FUNCTIONS
    function test_SetMinRequiredUptime() public {
        vm.startPrank(ADMIN);

        // Define the new uptime value
        uint256 newUptime = 100;

        // Set the new minimum required uptime
        rewards.setMinRequiredUptime(newUptime);

        // Verify the new minimum required uptime has been set
        assertEq(rewards.minRequiredUptime(), newUptime);

        vm.stopPrank();
    }

    function test_UpdateProtocolFee() public {
        vm.startPrank(ADMIN);

        // Define the new protocol fee value
        uint16 newFee = 1500;

        // Expect the ProtocolFeeUpdated event to be emitted with the new fee
        vm.expectEmit(true, true, false, false, address(rewards));
        emit ProtocolFeeUpdated(newFee);

        // Update the protocol fee
        rewards.updateProtocolFee(newFee);

        // Verify the new protocol fee has been set
        assertEq(rewards.protocolFee(), newFee);

        vm.stopPrank();
    }

    function test_UpdateOperatorFee() public {
        vm.startPrank(ADMIN);

        // Define the new operator fee value
        uint16 newFee = 1500;

        // Expect the OperatorFeeUpdated event to be emitted with the new fee
        vm.expectEmit(true, true, false, false, address(rewards));
        emit OperatorFeeUpdated(newFee);

        // Update the operator fee
        rewards.updateOperatorFee(newFee);

        // Verify the new operator fee has been set
        assertEq(rewards.operatorFee(), newFee);

        vm.stopPrank();
    }

    function test_UpdateCuratorFee() public {
        vm.startPrank(ADMIN);

        // Define the new curator fee value
        uint16 newFee = 1500;

        // Expect the CuratorFeeUpdated event to be emitted with the new fee
        vm.expectEmit(true, true, false, false, address(rewards));
        emit CuratorFeeUpdated(newFee);

        // Update the curator fee
        rewards.updateCuratorFee(newFee);

        // Verify the new curator fee has been set
        assertEq(rewards.curatorFee(), newFee);

        vm.stopPrank();
    }

    function test_SetRewardsShareForAssetClass() public {
        vm.startPrank(ADMIN);

        // Define the asset class ID and the new rewards percentage
        uint96 assetClassId = 1;
        uint16 rewardsPercentage = 5000; // 50%

        // Expect the RewardsShareUpdated event to be emitted with the new rewards percentage
        vm.expectEmit(true, true, false, false);
        emit RewardsShareUpdated(assetClassId, rewardsPercentage);

        // Set the rewards share for the asset class
        rewards.setRewardsShareForAssetClass(assetClassId, rewardsPercentage);

        // Verify the new rewards share has been set
        assertEq(rewards.rewardsSharePerAssetClass(assetClassId), rewardsPercentage);

        vm.stopPrank();
    }

    function test_SetRewardsAmountForEpochs() public {
        vm.startPrank(ADMIN);

        // Define the parameters for the function
        uint48 startEpoch = 1;
        uint256 numberOfEpochs = 5;
        address rewardsToken = makeAddr("RewardsToken");
        uint256 rewardsAmount = 10_000 * 1e18; // 10,000 tokens with 18 decimals

        // Assume protocolFee is set to 10% (1000 basis points)
        uint16 protocolFee = 1000;
        rewards.updateProtocolFee(protocolFee);

        // Calculate the expected protocol rewards
        uint256 protocolRewards = (rewardsAmount * protocolFee) / 10_000;

        // Expect the RewardsAmountSet event to be emitted with the correct parameters
        vm.expectEmit(true, true, false, false);
        emit RewardsAmountSet(startEpoch, numberOfEpochs, rewardsToken, rewardsAmount);

        // Set the rewards amount for the epochs
        rewards.setRewardsAmountForEpochs(startEpoch, numberOfEpochs, rewardsToken, rewardsAmount);

        // Verify the protocol rewards amount has been set correctly
        assertEq(rewards.protocolRewardsAmountPerToken(rewardsToken), protocolRewards * numberOfEpochs);

        // Verify the rewards amount per token from epoch has been set correctly
        for (uint48 i = 0; i < numberOfEpochs; i++) {
            (address[] memory tokens, uint256[] memory amounts) =
                rewards.getRewardsAmountPerTokenFromEpoch(startEpoch + i);
            assertEq(tokens.length, 1);
            assertEq(tokens[0], rewardsToken);
            assertEq(amounts[0], rewardsAmount - protocolRewards);
        }

        vm.stopPrank();
    }

    // MAIN FUNCTIONS
    function test_DistributeRewards() public {
        uint48 epoch = 3;
        address rewardToken = makeAddr("RewardToken");
        uint256 rewardsAmount = 1000 * 1e18;

        // Set up test parameters
        uint16[] memory assetClassShares = new uint16[](3);
        assetClassShares[0] = 5000; // Primary asset class - 50%
        assetClassShares[1] = 2500; // Secondary asset class 1 - 25%
        assetClassShares[2] = 2500; // Secondary asset class 2 - 25%

        uint256[] memory assetClassTotalStakes = new uint256[](3);
        assetClassTotalStakes[0] = 500 * 1e18; // Primary asset class
        assetClassTotalStakes[1] = 200 * 1e18; // Secondary asset class 1
        assetClassTotalStakes[2] = 200 * 1e18; // Secondary asset class 2

        // Set up rewards and configurations
        _setupRewardsConfig(epoch, rewardToken, rewardsAmount, assetClassShares);

        // Set up operators with stakes across asset classes
        address[] memory operators = middleware.getAllOperators();
        uint256[] memory operatorPrimaryStakes = new uint256[](operators.length);
        uint256[][] memory operatorSecondaryStakes = new uint256[][](operators.length);
        uint256[] memory operatorUptimes = new uint256[](operators.length);

        for (uint256 i = 0; i < operators.length; i++) {
            operatorPrimaryStakes[i] = 100 * 1e18;

            operatorSecondaryStakes[i] = new uint256[](2); // For 2 secondary asset classes
            operatorSecondaryStakes[i][0] = 50 * 1e18;
            operatorSecondaryStakes[i][1] = 50 * 1e18;

            operatorUptimes[i] = 3600 * 3 + (i + 1) * 1000;
        }

        _setupOperators(epoch, operators, operatorPrimaryStakes, operatorSecondaryStakes, operatorUptimes);

        // Set total stake caches
        _setupTotalStakes(epoch, assetClassTotalStakes);

        // Execute and verify distribution
        _executeAndVerifyDistribution(epoch, rewardToken, operators);
    }

    // function testFuzz_DistributeRewards(
    //     uint48 epoch,
    //     uint256 rewardsAmount,
    //     uint16[3] calldata assetClassSharesRaw
    // ) public {
    //     // Bound inputs to reasonable values
    //     vm.assume(epoch > 0);
    //     vm.assume(epoch < 5);
    //     rewardsAmount = bound(rewardsAmount, 100, 1e24);

    //     // Process asset class shares to ensure they sum to 10000 (100%)
    //     uint16[] memory assetClassShares = new uint16[](3);
    //     uint32 shareSum = 0;
    //     for (uint256 i = 0; i < 3; i++) {
    //         // Ensure each share is at least 500 (5%) and at most 5000 (50%)
    //         uint16 share = uint16(bound(assetClassSharesRaw[i], 500, 5000));
    //         assetClassShares[i] = share;
    //         shareSum += share;
    //     }

    //     // Adjust shares to ensure they sum to 10000 (100%)
    //     if (shareSum != 10_000) {
    //         // Adjust the primary share to make the total 100%
    //         assetClassShares[0] = uint16(10_000 - assetClassShares[1] - assetClassShares[2]);
    //     }

    //     // Distribute total stake proportionally according to asset class shares
    //     uint256[] memory assetClassTotalStakes = new uint256[](3);
    //     for (uint256 i = 0; i < 3; i++) {
    //         assetClassTotalStakes[i] = (rewardsAmount * assetClassShares[i]) / 10_000;

    //         // Ensure minimum stake for each asset class
    //         if (assetClassTotalStakes[i] < 1e18) {
    //             assetClassTotalStakes[i] = 1e18;
    //         }
    //     }

    //     address rewardToken = makeAddr("RewardToken");

    //     // Set up rewards and configurations
    //     _setupRewardsConfig(epoch, rewardToken, rewardsAmount, assetClassShares);

    //     // Set up operators with stakes across asset classes
    //     address[] memory operators = middleware.getAllOperators();
    //     uint256[] memory operatorPrimaryStakes = new uint256[](operators.length);
    //     uint256[][] memory operatorSecondaryStakes = new uint256[][](operators.length);
    //     uint256[] memory operatorUptimes = new uint256[](operators.length);

    //     // Calculate operator stakes based on total stakes
    //     for (uint256 i = 0; i < operators.length; i++) {
    //         // Distribute stakes proportionally among operators
    //         operatorPrimaryStakes[i] = assetClassTotalStakes[0] / operators.length;

    //         operatorSecondaryStakes[i] = new uint256[](2);
    //         operatorSecondaryStakes[i][0] = assetClassTotalStakes[1] / operators.length;
    //         operatorSecondaryStakes[i][1] = assetClassTotalStakes[2] / operators.length;

    //         // Set some uptime that meets minimum requirements
    //         operatorUptimes[i] = 11_520 + i * 100;
    //     }

    //     _setupOperators(epoch, operators, operatorPrimaryStakes, operatorSecondaryStakes, operatorUptimes);

    //     // Set total stake caches
    //     _setupTotalStakes(epoch, assetClassTotalStakes);

    //     // Execute and verify distribution
    //     _executeAndVerifyDistribution(epoch, rewardToken, operators);
    // }

    // function test_ClaimProtocolFee() public {
    //     // Setup
    //     address rewardToken = makeAddr("RewardToken");
    //     address recipient = makeAddr("FeeRecipient");
    //     uint256 rewardsAmount = 1000 * 1e18;
    //     uint48 startEpoch = 3;
    //     uint256 numberOfEpochs = 10;

    //     // Calculate expected protocol fee amount based on the protocolFee percentage (1000 = 10%)
    //     uint256 expectedProtocolRewards = (rewardsAmount * 1000) / 10_000 * numberOfEpochs;

    //     // Mock the reward token and mint enough tokens to the rewards contract
    //     ERC20Mock mockToken = new ERC20Mock();
    //     mockToken.mint(address(rewards), expectedProtocolRewards);

    //     // Admin sets rewards which should increment protocolRewardsAmountPerToken
    //     vm.startPrank(ADMIN);
    //     rewards.setRewardsAmountForEpochs(startEpoch, numberOfEpochs, address(mockToken), rewardsAmount);
    //     vm.stopPrank();

    //     // Verify balance before claim
    //     assertEq(mockToken.balanceOf(recipient), 0, "Recipient should have 0 tokens before claim");
    //     assertEq(
    //         mockToken.balanceOf(address(rewards)),
    //         expectedProtocolRewards,
    //         "Rewards contract should have expected protocol rewards"
    //     );

    //     // Call claimProtocolFee as PROTOCOL_OWNER
    //     vm.startPrank(PROTOCOL_OWNER);
    //     rewards.claimProtocolFee(address(mockToken), recipient);
    //     vm.stopPrank();

    //     // Verify balance after claim
    //     assertEq(
    //         mockToken.balanceOf(recipient), expectedProtocolRewards, "Recipient should have received protocol rewards"
    //     );
    //     assertEq(mockToken.balanceOf(address(rewards)), 0, "Rewards contract should have 0 tokens after claim");

    //     // Verify protocolRewardsAmountPerToken was reset to 0
    //     vm.startPrank(PROTOCOL_OWNER);
    //     vm.expectRevert(abi.encodeWithSelector(Rewards.NoRewardsToClaim.selector, PROTOCOL_OWNER));
    //     rewards.claimProtocolFee(address(mockToken), recipient);
    //     vm.stopPrank();
    // }

    // HELPER FUNCTIONS
    // Set up rewards configuration
    function _setupRewardsConfig(
        uint48 epoch,
        address rewardToken,
        uint256 rewardsAmount,
        uint16[] memory assetClassShares
    ) internal {
        (uint96 primaryAssetClass, uint96[] memory secondaryAssetClasses) = middleware.getActiveAssetClasses();

        vm.startPrank(ADMIN);
        // Set up reward distribution
        rewards.setRewardsAmountForEpochs(epoch, 1, rewardToken, rewardsAmount);

        // Set rewards share per asset class
        rewards.setRewardsShareForAssetClass(primaryAssetClass, assetClassShares[0]);
        for (uint256 i = 0; i < secondaryAssetClasses.length; i++) {
            rewards.setRewardsShareForAssetClass(secondaryAssetClasses[i], assetClassShares[i + 1]);
        }

        // Set the minimum required uptime
        rewards.setMinRequiredUptime(11_520);
        vm.stopPrank();
    }

    // Set up operators with their stakes and uptimes
    function _setupOperators(
        uint48 epoch,
        address[] memory operators,
        uint256[] memory primaryStakes,
        uint256[][] memory secondaryStakes,
        uint256[] memory uptimes
    ) internal {
        (uint96 primaryAssetClass, uint96[] memory secondaryAssetClasses) = middleware.getActiveAssetClasses();

        for (uint256 i = 0; i < operators.length; i++) {
            // Set operator uptime
            uptimeTracker.setOperatorUptimePerEpoch(epoch, operators[i], uptimes[i]);

            // Set primary asset class stake
            middleware.setOperatorStake(epoch, operators[i], uint96(primaryAssetClass), primaryStakes[i]);

            // Set secondary asset class stakes
            for (uint256 j = 0; j < secondaryAssetClasses.length; j++) {
                middleware.setOperatorStake(
                    epoch, operators[i], uint96(secondaryAssetClasses[j]), secondaryStakes[i][j]
                );
            }

            // Set up node stakes for each operator
            _setupNodeStakes(epoch, operators[i]);

            // Set delegator stakes
            _setupDelegatorStakes(epoch, operators[i]);
        }
    }

    // Set up node stakes for an operator
    function _setupNodeStakes(uint48 epoch, address operator) internal {
        bytes32[] memory nodeIds = middleware.getActiveNodesForEpoch(operator, epoch);
        for (uint256 j = 0; j < nodeIds.length; j++) {
            middleware.setNodeStake(epoch, nodeIds[j], 50 * 1e18);
        }
    }

    // Set up delegator stakes for an operator
    function _setupDelegatorStakes(uint48 epoch, address operator) internal {
        uint256 timestamp = middleware.getEpochStartTs(epoch);
        for (uint256 j = 0; j < delegators.length; j++) {
            delegators[j].setStake(
                middleware.L1_VALIDATOR_MANAGER(), uint96(j + 1), operator, uint48(timestamp), 10 * 1e18
            );
        }
    }

    // Set up total stakes for asset classes
    function _setupTotalStakes(uint48 epoch, uint256[] memory totalStakes) internal {
        (uint96 primaryAssetClass, uint96[] memory secondaryAssetClasses) = middleware.getActiveAssetClasses();

        middleware.setTotalStakeCache(epoch, uint96(primaryAssetClass), totalStakes[0]);

        for (uint256 i = 0; i < secondaryAssetClasses.length; i++) {
            middleware.setTotalStakeCache(epoch, uint96(secondaryAssetClasses[i]), totalStakes[i + 1]);
        }
    }

    // Execute and verify the distribution
    function _executeAndVerifyDistribution(uint48 epoch, address rewardToken, address[] memory operators) internal {
        // Ensure rewards haven't been distributed yet
        for (uint256 i = 0; i < operators.length; i++) {
            assertEq(rewards.operatorsRewardsPerToken(rewardToken, operators[i]), 0);
        }

        // Expect rewards distribution event
        vm.expectEmit(true, true, false, false, address(rewards));
        emit RewardsDistributed(epoch);

        // Distribute rewards
        rewards.distributeRewards(epoch);

        // Check if rewards were distributed
        for (uint256 i = 0; i < operators.length; i++) {
            uint256 rewardsForOperator = rewards.operatorsRewardsPerToken(rewardToken, operators[i]);
            assertGt(rewardsForOperator, 0, "Operator should have received rewards");
        }
    }
}
