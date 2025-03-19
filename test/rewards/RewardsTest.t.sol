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
import {IRewards} from "../../src/interfaces/rewards/IRewards.sol";
import {VaultTokenized} from "../../src/contracts/vault/VaultTokenized.sol";

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
    ERC20Mock public rewardsToken;

    function setUp() public {
        // set number of operator on L1 and number of nodes per operator
        uint256 operatorCount = 3;
        uint256[] memory nodesPerOperator = new uint256[](3);
        nodesPerOperator[0] = 2;
        nodesPerOperator[1] = 3;
        nodesPerOperator[2] = 1;

        middleware = new MockAvalancheL1Middleware(operatorCount, nodesPerOperator, address(0));
        vaultManager = new MockVaultManager();
        uptimeTracker = new MockUptimeTracker();

        rewards = new Rewards();

        uint16 protocolFee = 1000;
        uint16 operatorFee = 2000;
        uint16 curatorFee = 1000;

        // INITIALIZE ROLES, FEES, AND CONTRACT DEPENDANCIES
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

        // create rewards token and mint supply to ADMIN
        rewardsToken = new ERC20Mock();
        rewardsToken.mint(ADMIN, 1_000_000 * 10 ** 18);
        vm.prank(ADMIN);
        rewardsToken.approve(address(rewards), 1_000_000 * 10 ** 18);

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
        uint256 rewardsAmount = 10_000 * 1e18; // 10,000 tokens with 18 decimals

        rewardsToken.approve(address(rewards), rewardsAmount * 5);

        // Assume protocolFee is set to 10% (1000 basis points)
        uint16 protocolFee = 1000;
        rewards.updateProtocolFee(protocolFee);

        // Calculate the expected protocol rewards
        uint256 protocolRewards = (rewardsAmount * protocolFee) / 10_000;

        // Expect the RewardsAmountSet event to be emitted with the correct parameters
        vm.expectEmit(true, true, false, false);
        emit RewardsAmountSet(startEpoch, numberOfEpochs, address(rewardsToken), rewardsAmount);

        // Set the rewards amount for the epochs
        rewards.setRewardsAmountForEpochs(startEpoch, numberOfEpochs, address(rewardsToken), rewardsAmount);

        // Verify the protocol rewards amount has been set correctly
        assertEq(rewards.protocolRewardsAmountPerToken(address(rewardsToken)), protocolRewards * numberOfEpochs);

        // Verify the rewards amount per token from epoch has been set correctly
        for (uint48 i = 0; i < numberOfEpochs; i++) {
            (address[] memory tokens, uint256[] memory amounts) =
                rewards.getRewardsAmountPerTokenFromEpoch(startEpoch + i);
            assertEq(tokens.length, 1);
            assertEq(tokens[0], address(rewardsToken));
            assertEq(amounts[0], rewardsAmount - protocolRewards);
        }

        vm.stopPrank();
    }

    // MAIN FUNCTIONS
    function test_DistributeRewards() public {
        uint48 epoch = 1;
        uint256 rewardsAmount = 1000 * 1e18;
        vm.warp((epoch + 2) * middleware.EPOCH_DURATION());

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
        _setupRewardsConfig(epoch, rewardsAmount, assetClassShares);

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
        _executeAndVerifyDistribution(epoch, operators);
    }

    function testFuzz_DistributeRewards(
        uint48 epoch,
        uint256 rewardsAmount,
        uint16[3] calldata assetClassSharesRaw
    ) public {
        // Bound inputs to reasonable values
        epoch = uint48(bound(epoch, 1, 1000));
        rewardsAmount = bound(rewardsAmount, 1e18, 1000e18); // Between 1 and 1000 tokens
        vm.warp((epoch + 2) * middleware.EPOCH_DURATION());

        // Process asset class shares to ensure they sum to 10000 (100%)
        uint16[] memory assetClassShares = new uint16[](3);
        uint32 totalShares = 0;

        // First pass: bound each share between 1000 (10%) and 8000 (80%)
        for (uint256 i = 0; i < 3; i++) {
            assetClassShares[i] = uint16(bound(assetClassSharesRaw[i], 1000, 8000));
            totalShares += assetClassShares[i];
        }

        // Adjust shares proportionally to sum to 10000
        for (uint256 i = 0; i < 3; i++) {
            assetClassShares[i] = uint16((uint256(assetClassShares[i]) * 10_000) / totalShares);
        }

        // Ensure rounding errors don't affect total
        uint32 finalTotal = uint32(assetClassShares[0]) + uint32(assetClassShares[1]) + uint32(assetClassShares[2]);
        if (finalTotal != 10_000) {
            // Add any remainder to the first share
            assetClassShares[0] = uint16(uint32(assetClassShares[0]) + (10_000 - finalTotal));
        }

        // Set up minimum stakes for each asset class
        uint256[] memory assetClassTotalStakes = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            // Ensure each asset class has at least some stake proportional to its share
            assetClassTotalStakes[i] = (rewardsAmount * assetClassShares[i]) / 10_000;
            if (assetClassTotalStakes[i] < 1e18) {
                assetClassTotalStakes[i] = 1e18;
            }
        }

        // Set up rewards and configurations
        _setupRewardsConfig(epoch, rewardsAmount, assetClassShares);

        // Set up operators with stakes across asset classes
        address[] memory operators = middleware.getAllOperators();
        uint256[] memory operatorPrimaryStakes = new uint256[](operators.length);
        uint256[][] memory operatorSecondaryStakes = new uint256[][](operators.length);
        uint256[] memory operatorUptimes = new uint256[](operators.length);

        // Calculate operator stakes based on total stakes
        for (uint256 i = 0; i < operators.length; i++) {
            // Distribute stakes evenly among operators
            operatorPrimaryStakes[i] = assetClassTotalStakes[0] / operators.length;

            operatorSecondaryStakes[i] = new uint256[](2);
            operatorSecondaryStakes[i][0] = assetClassTotalStakes[1] / operators.length;
            operatorSecondaryStakes[i][1] = assetClassTotalStakes[2] / operators.length;

            // Set uptime above minimum required (11520)
            operatorUptimes[i] = 12_000 + i * 100; // Ensures all operators meet minimum uptime
        }

        _setupOperators(epoch, operators, operatorPrimaryStakes, operatorSecondaryStakes, operatorUptimes);

        // Set total stake caches
        _setupTotalStakes(epoch, assetClassTotalStakes);

        // Execute and verify distribution
        _executeAndVerifyDistribution(epoch, operators);
    }

    function test_ClaimProtocolFee_Success() public {
        // Setup
        address recipient = makeAddr("FeeRecipient");
        uint256 rewardsAmountPerEpoch = 1000 * 1e18;
        uint48 startEpoch = 3;
        uint256 numberOfEpochs = 10;
        uint256 totalRewardsAmount = rewardsAmountPerEpoch * numberOfEpochs;

        // Calculate expected protocol fee amount based on the protocolFee percentage (1000 = 10%)
        uint256 expectedProtocolRewards = (rewardsAmountPerEpoch * 1000) / 10_000 * numberOfEpochs;

        // Admin sets rewards which should increment protocolRewardsAmountPerToken
        vm.startPrank(ADMIN);
        rewards.setRewardsAmountForEpochs(startEpoch, numberOfEpochs, address(rewardsToken), rewardsAmountPerEpoch);
        vm.stopPrank();

        // Verify balance before claim
        assertEq(rewardsToken.balanceOf(recipient), 0, "Recipient should have 0 tokens before claim");
        assertEq(
            rewardsToken.balanceOf(address(rewards)),
            totalRewardsAmount,
            "Rewards should have been transferred to rewards contract"
        );
        assertEq(
            rewards.protocolRewardsAmountPerToken(address(rewardsToken)),
            expectedProtocolRewards,
            "The protocol rewards should have been set"
        );

        // Call claimProtocolFee as PROTOCOL_OWNER
        vm.startPrank(PROTOCOL_OWNER);
        rewards.claimProtocolFee(address(rewardsToken), recipient);
        vm.stopPrank();

        // Verify balance after claim
        assertEq(
            rewardsToken.balanceOf(recipient),
            expectedProtocolRewards,
            "Recipient should have received protocol rewards"
        );
        assertEq(
            rewardsToken.balanceOf(address(rewards)),
            totalRewardsAmount - expectedProtocolRewards,
            "Rewards contract should have less tokens after claim"
        );

        // Verify protocolRewardsAmountPerToken was reset to 0
        uint256 protocolRewardsAfter = rewards.protocolRewardsAmountPerToken(address(rewardsToken));
        assertEq(protocolRewardsAfter, 0, "Protocol rewards should be reset to zero");
    }

    function test_ClaimProtocolFee_RevertNoRewards() public {
        address recipient = makeAddr("FeeRecipient");

        // Ensure the protocol has no rewards available
        uint256 protocolRewards = rewards.protocolRewardsAmountPerToken(address(rewardsToken));
        assertEq(protocolRewards, 0, "Protocol should have zero rewards");

        // Expect revert due to no rewards
        vm.expectRevert(abi.encodeWithSelector(IRewards.NoRewardsToClaim.selector, PROTOCOL_OWNER));
        vm.startPrank(PROTOCOL_OWNER);
        rewards.claimProtocolFee(address(rewardsToken), recipient);
        vm.stopPrank();
    }

    function test_ClaimProtocolFee_RevertInvalidRecipient() public {
        // Setup
        uint256 rewardsAmountPerEpoch = 1000 * 1e18;
        uint48 startEpoch = 3;
        uint256 numberOfEpochs = 10;

        // Admin sets rewards to populate protocolRewardsAmountPerToken
        vm.startPrank(ADMIN);
        rewards.setRewardsAmountForEpochs(startEpoch, numberOfEpochs, address(rewardsToken), rewardsAmountPerEpoch);
        vm.stopPrank();

        // Ensure protocol has rewards
        uint256 protocolRewards = rewards.protocolRewardsAmountPerToken(address(rewardsToken));
        assertGt(protocolRewards, 0, "Protocol should have non-zero rewards");

        // Expect revert due to invalid recipient
        vm.expectRevert(abi.encodeWithSelector(IRewards.InvalidRecipient.selector, address(0)));
        vm.startPrank(PROTOCOL_OWNER);
        rewards.claimProtocolFee(address(rewardsToken), address(0));
        vm.stopPrank();
    }

    function test_ClaimOperatorFee_Success() public {
        // Get an operator from the list
        address operator = middleware.getAllOperators()[0];
        address recipient = makeAddr("recipient");

        // Set up test parameters and distribute rewards
        test_DistributeRewards(); // This will populate operatorsRewardsPerToken

        // Ensure the operator has received rewards
        uint256 operatorRewards = rewards.operatorRewardsAmountPerToken(operator, address(rewardsToken));
        assertGt(operatorRewards, 0, "Operator should have non-zero rewards");

        // Capture token balance before claim
        uint256 recipientBalanceBefore = rewardsToken.balanceOf(recipient);

        // Operator claims the rewards
        vm.prank(operator);
        rewards.claimOperatorFee(address(rewardsToken), recipient);

        // Validate that the recipient received the rewards
        uint256 recipientBalanceAfter = rewardsToken.balanceOf(recipient);
        assertEq(
            recipientBalanceAfter, recipientBalanceBefore + operatorRewards, "Recipient should receive the rewards"
        );

        // Ensure the rewards balance is reset
        uint256 operatorRewardsAfter = rewards.operatorRewardsAmountPerToken(operator, address(rewardsToken));
        assertEq(operatorRewardsAfter, 0, "Operator rewards should be reset to zero");
    }

    function test_ClaimOperatorFee_RevertNoRewards() public {
        // Get an operator from the list
        address operator = middleware.getAllOperators()[0];
        address recipient = makeAddr("recipient");

        // Ensure the operator has received rewards
        uint256 operatorRewards = rewards.operatorRewardsAmountPerToken(operator, address(rewardsToken));
        assertEq(operatorRewards, 0, "Operator should have zero rewards");

        // Expect revert due to no rewards
        vm.expectRevert(abi.encodeWithSelector(IRewards.NoRewardsToClaim.selector, operator));
        vm.prank(operator);
        rewards.claimOperatorFee(address(rewardsToken), recipient);
    }

    function test_ClaimOperatorFee_RevertInvalidRecipient() public {
        address operator = middleware.getAllOperators()[0];

        // Set up test parameters and distribute rewards
        test_DistributeRewards();

        // Ensure the operator has rewards
        uint256 operatorRewards = rewards.operatorRewardsAmountPerToken(operator, address(rewardsToken));
        assertGt(operatorRewards, 0, "Operator should have non-zero rewards");

        // Expect revert due to invalid recipient
        vm.expectRevert(abi.encodeWithSelector(IRewards.InvalidRecipient.selector, address(0)));
        vm.prank(operator);
        rewards.claimOperatorFee(address(rewardsToken), address(0));
    }

    function test_ClaimRewards_Success() public {
        uint48 epoch = 1;
        address staker = address(0x789);
        address recipient = makeAddr("recipient");

        // Distribute rewards
        test_DistributeRewards();

        vm.warp((epoch + 1) * middleware.EPOCH_DURATION());

        // Ensure the staker has claimable rewards
        uint256 initialBalance = rewardsToken.balanceOf(recipient);

        // Staker claims rewards
        vm.prank(staker);
        rewards.claimRewards(address(rewardsToken), recipient);

        // Verify recipient received rewards
        uint256 finalBalance = rewardsToken.balanceOf(recipient);
        assertGt(finalBalance, initialBalance, "Recipient should receive correct rewards");

        // Ensure last claimed epoch is updated
        uint48 lastEpoch = rewards.lastEpochClaimed(staker);
        assertEq(lastEpoch, epoch, "Last claimed epoch should be updated");
    }

    function test_ClaimRewards_RevertInvalidRecipient() public {
        // Try to claim rewards with zero address as recipient
        vm.expectRevert(abi.encodeWithSelector(IRewards.InvalidRecipient.selector, address(0)));
        rewards.claimRewards(address(rewardsToken), address(0));
    }

    function test_ClaimRewards_RevertAlreadyClaimedForLatestEpoch() public {
        address staker = address(0x789);
        address recipient = makeAddr("recipient");

        // First claim should succeed
        test_DistributeRewards();

        vm.warp((2) * middleware.EPOCH_DURATION());
        vm.prank(staker);
        rewards.claimRewards(address(rewardsToken), recipient);

        // Second claim should fail
        uint48 lastClaimedEpoch = rewards.lastEpochClaimed(staker);
        vm.expectRevert(
            abi.encodeWithSelector(IRewards.AlreadyClaimedForLatestEpoch.selector, staker, lastClaimedEpoch)
        );
        vm.prank(staker);
        rewards.claimRewards(address(rewardsToken), recipient);
    }

    function test_ClaimRewards_RevertZeroVaultStake() public {
        address staker = address(0x789);
        address recipient = makeAddr("recipient");
        uint48 epoch = 1;
        vm.warp((epoch + 2) * middleware.EPOCH_DURATION());

        // Set up test parameters
        uint256 rewardsAmount = 1000 * 1e18;
        uint16[] memory assetClassShares = new uint16[](3);
        assetClassShares[0] = 5000; // 50%
        assetClassShares[1] = 2500; // 25%
        assetClassShares[2] = 2500; // 25%

        uint256[] memory assetClassTotalStakes = new uint256[](3);
        assetClassTotalStakes[0] = 500 * 1e18; // Primary asset class
        assetClassTotalStakes[1] = 200 * 1e18; // Secondary asset class 1
        assetClassTotalStakes[2] = 200 * 1e18; // Secondary asset class 2

        // Set up rewards configuration
        _setupRewardsConfig(epoch, rewardsAmount, assetClassShares);

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

        (uint96 primaryAssetClass, uint96[] memory secondaryAssetClasses) = middleware.getActiveAssetClasses();

        for (uint256 i = 0; i < operators.length; i++) {
            // Set operator uptime
            uptimeTracker.setOperatorUptimePerEpoch(epoch, operators[i], operatorUptimes[i]);

            // Set primary asset class stake
            middleware.setOperatorStake(epoch, operators[i], uint96(primaryAssetClass), operatorPrimaryStakes[i]);

            // Set secondary asset class stakes
            for (uint256 j = 0; j < secondaryAssetClasses.length; j++) {
                middleware.setOperatorStake(
                    epoch, operators[i], uint96(secondaryAssetClasses[j]), operatorSecondaryStakes[i][j]
                );
            }

            // Set up node stakes for each operator
            _setupNodeStakes(epoch, operators[i]);
        }

        // Set total stake caches
        _setupTotalStakes(epoch, assetClassTotalStakes);

        // Get the first vault and its asset class
        (address vault,,) = vaultManager.getVaultAtWithTimes(0);
        uint96 assetClass = middleware.assetClassAsset(vault);

        // Set zero stake for the vault in the delegators
        for (uint256 i = 0; i < delegators.length; i++) {
            delegators[i].setStake(
                middleware.L1_VALIDATOR_MANAGER(),
                assetClass,
                middleware.getAllOperators()[0],
                uint48(middleware.getEpochStartTs(epoch)),
                0
            );
        }

        // Distribute rewards
        rewards.distributeRewards(epoch);

        // Attempt to claim rewards should revert due to zero vault stake
        vm.expectRevert(abi.encodeWithSelector(IRewards.ZeroVaultStake.selector, vault, epoch));
        vm.prank(staker);
        rewards.claimRewards(address(rewardsToken), recipient);
    }

    function test_ClaimRewards_RevertNoRewardsToClaim() public {
        address staker = makeAddr("staker");
        address recipient = makeAddr("recipient");

        // Distribute rewards but staker has no rewards to claim
        test_DistributeRewards();

        // Try to claim rewards without any rewards being distributed for the epoch
        vm.expectRevert(abi.encodeWithSelector(IRewards.NoRewardsToClaim.selector, staker));
        vm.prank(staker);
        rewards.claimRewards(address(rewardsToken), recipient);
    }

    function test_ClaimCuratorFee_Success() public {
        // Get the first vault
        address vaultOwner = address(0x12345689123567891235789);
        address recipient = makeAddr("recipient");
        address staker = address(0x789);

        // Set up test parameters and distribute rewards
        test_DistributeRewards();

        vm.warp((2) * middleware.EPOCH_DURATION());

        // First claim rewards as staker to generate curator fees
        vm.prank(staker);
        rewards.claimRewards(address(rewardsToken), staker);

        // Ensure the curator has received rewards
        uint256 curatorRewards = rewards.curatorRewardsAmountPerToken(vaultOwner, address(rewardsToken));
        assertGt(curatorRewards, 0, "Curator should have non-zero rewards");

        // Capture token balance before claim
        uint256 recipientBalanceBefore = rewardsToken.balanceOf(recipient);

        // Curator claims the rewards
        vm.prank(vaultOwner);
        rewards.claimCuratorFee(address(rewardsToken), recipient);

        // Validate that the recipient received the rewards
        uint256 recipientBalanceAfter = rewardsToken.balanceOf(recipient);
        assertEq(recipientBalanceAfter, recipientBalanceBefore + curatorRewards, "Recipient should receive the rewards");

        // Ensure the rewards balance is reset
        uint256 curatorRewardsAfter = rewards.curatorRewardsAmountPerToken(vaultOwner, address(rewardsToken));
        assertEq(curatorRewardsAfter, 0, "Curator rewards should be reset to zero");
    }

    function test_ClaimCuratorFee_RevertNoRewardsToClaim() public {
        address vaultOwner = address(0x12345689123567891235789);
        address recipient = makeAddr("recipient");

        // Ensure the curator has no rewards
        uint256 curatorRewards = rewards.curatorRewardsAmountPerToken(vaultOwner, address(rewardsToken));
        assertEq(curatorRewards, 0, "Curator should have zero rewards");

        // Expect revert due to no rewards
        vm.expectRevert(abi.encodeWithSelector(IRewards.NoRewardsToClaim.selector, vaultOwner));
        vm.prank(vaultOwner);
        rewards.claimCuratorFee(address(rewardsToken), recipient);
    }

    function test_ClaimCuratorFee_RevertInvalidRecipient() public {
        // Expect revert due to invalid recipient
        vm.expectRevert(abi.encodeWithSelector(IRewards.InvalidRecipient.selector, address(0)));
        rewards.claimCuratorFee(address(rewardsToken), address(0));
    }

    function test_RevertWhen_InvalidFeePercentages() public {
        vm.startPrank(ADMIN);

        // Test individual fee exceeding 100%
        vm.expectRevert(abi.encodeWithSelector(IRewards.FeePercentageTooHigh.selector, 10_001));
        rewards.updateProtocolFee(10_001);

        // Test total fees exceeding 100%
        uint16 expectedTotalFees = 9001 + rewards.protocolFee() + rewards.curatorFee();
        vm.expectRevert(abi.encodeWithSelector(IRewards.TotalFeesExceed100.selector, expectedTotalFees));
        rewards.updateOperatorFee(9001);

        vm.stopPrank();
    }

    // HELPER FUNCTIONS
    // Set up rewards configuration
    function _setupRewardsConfig(uint48 epoch, uint256 rewardsAmount, uint16[] memory assetClassShares) internal {
        (uint96 primaryAssetClass, uint96[] memory secondaryAssetClasses) = middleware.getActiveAssetClasses();

        vm.startPrank(ADMIN);
        // Set up reward distribution
        rewards.setRewardsAmountForEpochs(epoch, 1, address(rewardsToken), rewardsAmount);

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
    function _executeAndVerifyDistribution(uint48 epoch, address[] memory operators) internal {
        // Ensure rewards haven't been distributed yet
        for (uint256 i = 0; i < operators.length; i++) {
            assertEq(rewards.operatorRewardsAmountPerToken(operators[i], address(rewardsToken)), 0);
        }

        // Expect rewards distribution event
        vm.expectEmit(true, true, false, false, address(rewards));
        emit RewardsDistributed(epoch);

        // Distribute rewards
        rewards.distributeRewards(epoch);

        // Check if rewards were distributed
        for (uint256 i = 0; i < operators.length; i++) {
            uint256 rewardsForOperator = rewards.operatorRewardsAmountPerToken(operators[i], address(rewardsToken));
            assertGt(rewardsForOperator, 0, "Rewards should have been distributed for operators");
        }
    }
}
