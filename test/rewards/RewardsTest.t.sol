// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {MockAvalancheL1Middleware} from "../mocks/MockAvalancheL1Middleware.sol";
import {MockUptimeTracker} from "../mocks/MockUptimeTracker.sol";
import {MockVaultManager} from "../mocks/MockVaultManager.sol";
import {MockDelegator} from "../mocks/MockDelegator.sol";
import {MockVault} from "../mocks/MockVault.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {Rewards} from "../../src/contracts/rewards/Rewards.sol";
import {IRewards, DistributionBatch} from "../../src/interfaces/rewards/IRewards.sol";
import {BaseDelegator} from "../../src/contracts/delegator/BaseDelegator.sol";
import {IVaultTokenized} from "../../src/interfaces/vault/IVaultTokenized.sol";
import {IMiddlewareVaultManager} from "../../src/interfaces/middleware/IMiddlewareVaultManager.sol";

contract RewardsTest is Test {
    // EVENTS
    event ZeroRewardsClaim(address indexed claimer, address indexed rewardsToken, uint48 lastEpoch, string claimType);
    event AdminRoleAssigned(address indexed mewManager);
    event RewardsManagerRoleAssigned(address indexed rewardsManager);
    event RewardsDistributorRoleAssigned(address indexed rewardsDistributor);
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
    address immutable REWARDS_MANAGER_ROLE = makeAddr("Rewards manager");
    address immutable REWARDS_DISTRIBUTOR_ROLE = makeAddr("Rewards distributor");
    // MOCK CONTRACTS
    MockAvalancheL1Middleware public middleware;
    MockUptimeTracker public uptimeTracker;
    MockVaultManager public vaultManager;
    MockDelegator[] public delegators;

    // MAIN
    Rewards public rewards;
    ERC20Mock public rewardsToken;

    function setUp() public {
        // set number of operator on L1 and number of nodes per operator
        uint256 operatorCount = 10;
        uint256[] memory nodesPerOperator = new uint256[](operatorCount);

        for (uint256 i = 0; i < operatorCount; i++) {
            nodesPerOperator[i] = 3;
        }

        // deploy mock contracts
        console2.log("Deploying mock contracts...");
        vaultManager = new MockVaultManager();
        console2.log("Vault manager deployed");
        middleware = new MockAvalancheL1Middleware(operatorCount, nodesPerOperator, address(0), address(vaultManager));
        console2.log("Middleware deployed");
        
        // Link the middleware to the vault manager
        vaultManager.setMiddleware(address(middleware));
        console2.log("Vault manager and middleware linked");
        uptimeTracker = new MockUptimeTracker();
        console2.log("Uptime tracker deployed");

        // Deploy RewardsV2 contract
        console2.log("Deploying Rewards contract...");
        rewards = new Rewards();
        console2.log("Rewards deployed");

        uint16 protocolFee = 1000;
        uint16 operatorFee = 2000;
        uint16 curatorFee = 1000;
        uint256 minRequiredUptime = 11_520;

        // INITIALIZE ROLES, FEES, AND CONTRACT DEPENDANCIES
        console2.log("Initializing roles, fees, and contract dependencies...");
        rewards.initialize(
            ADMIN,
            PROTOCOL_OWNER,
            payable(address(middleware)),
            address(uptimeTracker),
            protocolFee,
            operatorFee,
            curatorFee,
            minRequiredUptime
        );
        console2.log("Roles, fees, and contract dependencies initialized");

        vm.prank(ADMIN);
        rewards.setRewardsManagerRole(REWARDS_MANAGER_ROLE);
        
        vm.prank(REWARDS_MANAGER_ROLE);
        rewards.setRewardsDistributorRole(REWARDS_DISTRIBUTOR_ROLE);

        // create rewards token and mint supply to REWARDS_MANAGER_ROLE
        console2.log("Creating rewards token and minting supply to REWARDS_MANAGER_ROLE...");
        rewardsToken = new ERC20Mock();
        rewardsToken.mint(REWARDS_DISTRIBUTOR_ROLE, 100_000 * 10 ** 18);
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewardsToken.approve(address(rewards), 100_000 * 10 ** 18);

        // Setup mock vaults
        console2.log("Setting up mock vaults...");
        // Vault 1 (Primary Asset Class)
        console2.log("Deploying and adding vault 1...");
        address mockCollateral1 = makeAddr("Collateral1");
        address mockOwner1 = makeAddr("Owner1");
        (address vaultAddress1, address delegatorAddress1) = vaultManager.deployAndAddVault(mockCollateral1, mockOwner1);
        middleware.setAssetInAssetClass(1, vaultAddress1);
        vaultManager.setVaultAssetClass(vaultAddress1, 1);
        console2.log("Vault 1 deployed and added");

        // Vault 2 (Secondary Asset Class 1)
        console2.log("Deploying and adding vault 2...");
        address mockCollateral2 = makeAddr("Collateral2");
        address mockOwner2 = makeAddr("Owner2");
        (address vaultAddress2, address delegatorAddress2) = vaultManager.deployAndAddVault(mockCollateral2, mockOwner2);
        middleware.setAssetInAssetClass(2, vaultAddress2);
        vaultManager.setVaultAssetClass(vaultAddress2, 2);
        console2.log("Vault 2 deployed and added");

        // Vault 3 (Secondary Asset Class 2)
        console2.log("Deploying and adding vault 3...");
        address mockCollateral3 = makeAddr("Collateral3");
        address mockOwner3 = makeAddr("Owner3");
        (address vaultAddress3, address delegatorAddress3) = vaultManager.deployAndAddVault(mockCollateral3, mockOwner3);
        middleware.setAssetInAssetClass(3, vaultAddress3);
        vaultManager.setVaultAssetClass(vaultAddress3, 3);
        console2.log("Vault 3 deployed and added");

        delegators.push(MockDelegator(delegatorAddress1));
        delegators.push(MockDelegator(delegatorAddress2));
        delegators.push(MockDelegator(delegatorAddress3));

        // Setup rewards distribution per epoch
        console2.log("Setting up rewards distribution per epoch...");
        uint48 startEpoch = 1;
        uint48 numberOfEpochs = 1;
        uint256 rewardsAmount = 100_000 * 10 ** 18;

        vm.startPrank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.setRewardsAmountForEpochs(startEpoch, numberOfEpochs, address(rewardsToken), rewardsAmount);
        console2.log("Rewards distribution per epoch set");

        console2.log("Setting rewards share for asset classes...");
        vm.startPrank(REWARDS_MANAGER_ROLE);
        rewards.setRewardsShareForAssetClass(1, 5000); // 50% for primary
        rewards.setRewardsShareForAssetClass(2, 3000); // 30% for secondary 1
        rewards.setRewardsShareForAssetClass(3, 2000); // 20% for secondary 2
        console2.log("Rewards share for asset classes set");
        vm.stopPrank();
    }

    // TESTS
    function test_distributeRewards(
        uint256 uptime
    ) public {
        uint48 epoch = 1;
        uptime = bound(uptime, 0, 4 hours);

        // Set up stakes for operators, nodes, delegators and l1 middleware
        _setupStakes(epoch, uptime);

        // Get total number of operators
        address[] memory operators = middleware.getAllOperators();
        uint256 batchSize = 3; // Process 3 operators at a time
        uint256 remainingOperators = operators.length;

        // Execute distribution in batches until all operators are processed
        vm.warp((epoch + 3) * middleware.EPOCH_DURATION());
        while (remainingOperators > 0) {
            vm.prank(REWARDS_DISTRIBUTOR_ROLE);
            rewards.distributeRewards(epoch, uint48(batchSize));
            remainingOperators = remainingOperators > batchSize ? remainingOperators - batchSize : 0;
        }

        // Verify distribution is complete
        (, bool isComplete) = rewards.distributionBatches(epoch);
        assertTrue(isComplete, "Distribution should be complete");

        // Log rewards distribution
        uint256 totalShares;
        for (uint256 i = 0; i < operators.length; i++) {
            uint256 operatorShare = rewards.operatorShares(epoch, operators[i]);
            totalShares += operatorShare;
        }

        address[] memory vaults = new address[](vaultManager.getVaultCount());
        for (uint256 i = 0; i < vaults.length; i++) {
            (vaults[i],,) = vaultManager.getVaultAtWithTimes(i);
        }
        for (uint256 i = 0; i < vaults.length; i++) {
            uint256 vaultShare = rewards.vaultShares(epoch, vaults[i]);
            totalShares += vaultShare;
        }

        for (uint256 i = 0; i < vaults.length; i++) {
            address vaultOwner = MockVault(vaults[i]).owner();
            uint256 curatorShare = rewards.curatorShares(epoch, vaultOwner);
            totalShares += curatorShare;
        }

        // Verify total rewards shares under or equal to 100%
        assertLe(totalShares, rewards.BASIS_POINTS_DENOMINATOR(), "Total shares should not exceed 100%");
    }

    function test_distributeRewards_multipleBatch() public {
        uint48 epoch = 1;
        _setupStakes(epoch, 4 hours);

        // Process all operators in one large batch
        uint256 operatorCount = middleware.getAllOperators().length;
        vm.warp((epoch + 3) * middleware.EPOCH_DURATION());
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.distributeRewards(epoch, uint48(operatorCount));

        // Verify completion
        (, bool isComplete) = rewards.distributionBatches(epoch);
        assertTrue(isComplete, "Distribution should be complete");

        // Verify all operators processed
        address[] memory operators = middleware.getAllOperators();
        for (uint256 i = 0; i < operators.length; i++) {
            assertTrue(
                rewards.operatorShares(epoch, operators[i]) > 0
                    || uptimeTracker.operatorUptimePerEpoch(epoch, operators[i]) < rewards.minRequiredUptime(),
                "Each operator should either have shares or insufficient uptime"
            );
        }
    }

    function test_distributeRewards_partialBatch() public {
        uint48 epoch = 1;
        _setupStakes(epoch, 4 hours);

        uint256 batchSize = 2;

        // First batch
        vm.warp((epoch + 3) * middleware.EPOCH_DURATION());
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.distributeRewards(epoch, uint48(batchSize));
        (uint256 lastProcessed, bool isComplete) = rewards.distributionBatches(epoch);
        assertEq(lastProcessed, batchSize, "Should process exactly batchSize operators");
        assertFalse(isComplete, "Should not be complete after first batch");
    }

    function test_distributeRewards_completionFlag() public {
        uint48 epoch = 1;
        _setupStakes(epoch, 4 hours);

        // Process all operators
        address[] memory operators = middleware.getAllOperators();
        vm.warp((epoch + 3) * middleware.EPOCH_DURATION());
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.distributeRewards(epoch, uint48(operators.length));

        // Verify completion flag
        (, bool isComplete) = rewards.distributionBatches(epoch);
        assertTrue(isComplete, "Should be marked complete");

        // Try to process again
        vm.expectRevert(abi.encodeWithSelector(IRewards.AlreadyCompleted.selector, epoch));
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.distributeRewards(epoch, uint48(operators.length));
    }

    function test_distributeRewards_zeroUptime() public {
        uint48 epoch = 1;
        _setupStakes(epoch, 4 hours);

        // Set zero uptime for first operator
        address[] memory operators = middleware.getAllOperators();
        uptimeTracker.setOperatorUptimePerEpoch(epoch, operators[0], 0);

        // Distribute rewards
        vm.warp((epoch + 3) * middleware.EPOCH_DURATION());
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.distributeRewards(epoch, 1);

        // Verify no shares for operator with zero uptime
        assertEq(rewards.operatorShares(epoch, operators[0]), 0, "Operator with zero uptime should have zero shares");
    }

    function test_distributeRewards_zeroStake() public {
        uint48 epoch = 1;

        // Setup stakes but set zero stake for first operator
        _setupStakes(epoch, 4 hours);
        address[] memory operators = middleware.getAllOperators();
        bytes32[] memory nodes = middleware.getOperatorNodes(operators[0]);

        // Set zero stake for all nodes of first operator
        for (uint256 i = 0; i < nodes.length; i++) {
            middleware.setNodeStake(epoch, nodes[i], 0);
        }
        middleware.setOperatorStake(epoch, operators[0], 2, 0);
        middleware.setOperatorStake(epoch, operators[0], 3, 0);

        // Distribute rewards
        vm.warp((epoch + 3) * middleware.EPOCH_DURATION());
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.distributeRewards(epoch, 1);

        // Verify no shares for operator with zero stake
        assertEq(rewards.operatorShares(epoch, operators[0]), 0, "Operator with zero stake should have zero shares");
    }

    function _setupStakes(uint48 epoch, uint256 uptime) internal {
        // Get operators and epoch timestamp
        address[] memory operators = middleware.getAllOperators();
        uint256 timestamp = middleware.getEpochStartTs(epoch);

        // Define operator stake percentages (must sum to 100%)
        uint256[] memory operatorPercentages = new uint256[](10);
        operatorPercentages[0] = 10; // 10%
        operatorPercentages[1] = 10; // 10%
        operatorPercentages[2] = 10; // 10%
        operatorPercentages[3] = 10; // 10%
        operatorPercentages[4] = 10; // 10%
        operatorPercentages[5] = 10; // 10%
        operatorPercentages[6] = 10; // 10%
        operatorPercentages[7] = 10; // 10%
        operatorPercentages[8] = 10; // 10%
        operatorPercentages[9] = 10; // 10%

        // Define total stake for each asset class (e.g., 3 million tokens)
        uint256 totalStakePerClass = 3_000_000 ether;

        // Track total stakes for verification
        uint256 totalPrimaryStake = 0;
        uint256 totalSecondaryStake1 = 0;
        uint256 totalSecondaryStake2 = 0;

        for (uint256 i = 0; i < operators.length; i++) {
            address operator = operators[i];
            bytes32[] memory operatorNodes = middleware.getOperatorNodes(operator);

            // Calculate this operator's stake based on their percentage
            uint256 operatorStake = (totalStakePerClass * operatorPercentages[i]) / 100;

            // Set node stakes (divide operator stake among their nodes)
            uint256 stakePerNode = operatorStake / operatorNodes.length;
            for (uint256 j = 0; j < operatorNodes.length; j++) {
                middleware.setNodeStake(epoch, operatorNodes[j], stakePerNode);
                totalPrimaryStake += stakePerNode;
            }

            // Set same stake percentage for secondary asset classes
            middleware.setOperatorStake(epoch, operator, 2, operatorStake);
            middleware.setOperatorStake(epoch, operator, 3, operatorStake);
            totalSecondaryStake1 += operatorStake;
            totalSecondaryStake2 += operatorStake;

            // Set vault delegations proportional to operator's stake
            for (uint256 j = 0; j < delegators.length; j++) {
                delegators[j].setStake(
                    middleware.L1_VALIDATOR_MANAGER(),
                    uint96(j + 1), // asset class
                    operator,
                    uint48(timestamp),
                    operatorStake // Delegate proportional to operator's stake
                );
            }

            // Set operator uptime
            uptimeTracker.setOperatorUptimePerEpoch(epoch, operator, uptime);
        }

        // Set total stakes in L1 middleware
        middleware.setTotalStakeCache(epoch, 1, totalPrimaryStake);
        middleware.setTotalStakeCache(epoch, 2, totalSecondaryStake1);
        middleware.setTotalStakeCache(epoch, 3, totalSecondaryStake2);
    }

    function testFuzz_distributeRewards(
        uint256 totalStakePerClass,
        uint256[] calldata operatorUptimes,
        uint256[] calldata operatorPercentages
    ) public {
        uint48 epoch = 1;

        // Create config struct
        StakeConfig memory config = StakeConfig({
            totalStakePerClass: totalStakePerClass,
            operatorUptimes: operatorUptimes,
            operatorPercentages: operatorPercentages
        });

        // Setup stakes with fuzzed parameters
        _setupStakesFuzz(epoch, config);

        // Get total number of operators
        address[] memory operators = middleware.getAllOperators();
        uint256 batchSize = 3; // Process 3 operators at a time
        uint256 remainingOperators = operators.length;

        // Execute distribution in batches until all operators are processed
        vm.warp((epoch + 3) * middleware.EPOCH_DURATION());
        while (remainingOperators > 0) {
            vm.prank(REWARDS_DISTRIBUTOR_ROLE);
            rewards.distributeRewards(epoch, uint48(batchSize));
            remainingOperators = remainingOperators > batchSize ? remainingOperators - batchSize : 0;
        }

        // Verify distribution is complete
        (, bool isComplete) = rewards.distributionBatches(epoch);
        assertTrue(isComplete, "Distribution should be complete");

        // Calculate and verify total shares
        uint256 totalShares;

        // Sum operator shares
        for (uint256 i = 0; i < operators.length; i++) {
            totalShares += rewards.operatorShares(epoch, operators[i]);
        }

        // Sum vault shares
        address[] memory vaults = new address[](vaultManager.getVaultCount());
        for (uint256 i = 0; i < vaults.length; i++) {
            (vaults[i],,) = vaultManager.getVaultAtWithTimes(i);
            totalShares += rewards.vaultShares(epoch, vaults[i]);
        }

        // Sum curator shares
        for (uint256 i = 0; i < vaults.length; i++) {
            address vaultOwner = MockVault(vaults[i]).owner();
            totalShares += rewards.curatorShares(epoch, vaultOwner);
        }

        // Verify invariants
        assertLe(totalShares, rewards.BASIS_POINTS_DENOMINATOR(), "Total shares should not exceed 100%");

        // Additional invariants
        for (uint256 i = 0; i < operators.length; i++) {
            uint256 operatorShare = rewards.operatorShares(epoch, operators[i]);
            if (operatorShare > 0) {
                assertTrue(
                    uptimeTracker.operatorUptimePerEpoch(epoch, operators[i]) >= rewards.minRequiredUptime(),
                    "Operator with shares must meet minimum uptime"
                );
            }
        }
    }

    struct StakeConfig {
        uint256 totalStakePerClass;
        uint256[] operatorUptimes;
        uint256[] operatorPercentages;
    }

    function _setupStakesFuzz(uint48 epoch, StakeConfig memory config) internal {
        config.totalStakePerClass = bound(config.totalStakePerClass, 1000 ether, 10_000_000 ether);

        // Get operators and epoch timestamp
        address[] memory operators = middleware.getAllOperators();
        uint256 timestamp = middleware.getEpochStartTs(epoch);

        // Normalize operator percentages to sum to 100%
        uint256[] memory normalizedPercentages = new uint256[](operators.length);
        uint256 totalPercentage = 0;

        // Use provided percentages or generate them if array is too small
        for (uint256 i = 0; i < operators.length; i++) {
            uint256 percentage;
            if (i < config.operatorPercentages.length) {
                percentage = bound(config.operatorPercentages[i], 1, 10_000);
            } else {
                percentage = 10_000 / operators.length; // Equal distribution for remaining operators
            }
            normalizedPercentages[i] = percentage;
            totalPercentage += percentage;
        }

        // Track total stakes for verification
        uint256 totalPrimaryStake = 0;
        uint256 totalSecondaryStake1 = 0;
        uint256 totalSecondaryStake2 = 0;

        for (uint256 i = 0; i < operators.length; i++) {
            address operator = operators[i];
            bytes32[] memory operatorNodes = middleware.getOperatorNodes(operator);

            // Calculate this operator's stake based on their percentage
            uint256 operatorStake = (config.totalStakePerClass * normalizedPercentages[i]) / totalPercentage;

            // Set node stakes
            uint256 stakePerNode = operatorStake / operatorNodes.length;
            for (uint256 j = 0; j < operatorNodes.length; j++) {
                middleware.setNodeStake(epoch, operatorNodes[j], stakePerNode);
                totalPrimaryStake += stakePerNode;
            }

            // Set secondary asset class stakes
            middleware.setOperatorStake(epoch, operator, 2, operatorStake);
            middleware.setOperatorStake(epoch, operator, 3, operatorStake);
            totalSecondaryStake1 += operatorStake;
            totalSecondaryStake2 += operatorStake;

            // Set vault delegations
            for (uint256 j = 0; j < delegators.length; j++) {
                delegators[j].setStake(
                    middleware.L1_VALIDATOR_MANAGER(), uint96(j + 1), operator, uint48(timestamp), operatorStake
                );
            }

            // Set operator uptime (use provided uptimes or generate)
            uint256 uptime;
            if (i < config.operatorUptimes.length) {
                uptime = bound(config.operatorUptimes[i], 3 hours, 4 hours);
            } else {
                uptime = 4 hours; // Default uptime
            }
            uptimeTracker.setOperatorUptimePerEpoch(epoch, operator, uptime);
        }

        // Set total stakes in L1 middleware
        middleware.setTotalStakeCache(epoch, 1, totalPrimaryStake);
        middleware.setTotalStakeCache(epoch, 2, totalSecondaryStake1);
        middleware.setTotalStakeCache(epoch, 3, totalSecondaryStake2);
    }

    function _setupStakesAudit(uint48 epoch, uint256 uptime) internal {
        address[] memory operators = middleware.getAllOperators();
        uint256 timestamp = middleware.getEpochStartTs(epoch);

        // Define operator stake percentages (must sum to 100%)
        uint256[] memory operatorPercentages = new uint256[](10);
        operatorPercentages[0] = 10;
        operatorPercentages[1] = 10;
        operatorPercentages[2] = 10;
        operatorPercentages[3] = 10;
        operatorPercentages[4] = 10;
        operatorPercentages[5] = 10;
        operatorPercentages[6] = 10;
        operatorPercentages[7] = 10;
        operatorPercentages[8] = 10;
        operatorPercentages[9] = 10;

        uint256 totalStakePerClass = 3_000_000 ether;

        // Track total stakes for each asset class
        uint256[] memory totalStakes = new uint256[](3); // [primary, secondary1, secondary2]

        for (uint256 i = 0; i < operators.length; i++) {
            address operator = operators[i];
            uint256 operatorStake = (totalStakePerClass * operatorPercentages[i]) / 100;
            uint256 stakePerNode = operatorStake / middleware.getOperatorNodes(operator).length;

            _setupOperatorStakes(epoch, operator, operatorStake, stakePerNode, totalStakes);
            _setupVaultDelegations(epoch, operator, operatorStake, timestamp);
            uptimeTracker.setOperatorUptimePerEpoch(epoch, operator, uptime);
        }

        // Set total stakes in L1 middleware
        middleware.setTotalStakeCache(epoch, 1, totalStakes[0]);
        middleware.setTotalStakeCache(epoch, 2, totalStakes[1]);
        middleware.setTotalStakeCache(epoch, 3, totalStakes[2]);
    }

    // Sets up stakes for a single operator's nodes and asset classes
    function _setupOperatorStakes(
    uint48 epoch,
    address operator,
    uint256 operatorStake,
    uint256 stakePerNode,
    uint256[] memory totalStakes
    ) internal {
        bytes32[] memory operatorNodes = middleware.getOperatorNodes(operator);
        for (uint256 j = 0; j < operatorNodes.length; j++) {
            middleware.setNodeStake(epoch, operatorNodes[j], stakePerNode);
            totalStakes[0] += stakePerNode; // Primary stake
        }
        middleware.setOperatorStake(epoch, operator, 2, operatorStake);
        middleware.setOperatorStake(epoch, operator, 3, operatorStake);
        totalStakes[1] += operatorStake; // Secondary stake 1
        totalStakes[2] += operatorStake; // Secondary stake 2
    }

    // Sets up vault delegations for a single operator
    function _setupVaultDelegations(
        uint48,
        address operator,
        uint256 operatorStake,
        uint256 timestamp
    ) internal {
        for (uint256 j = 0; j < delegators.length; j++) {
            delegators[j].setStake(
            middleware.L1_VALIDATOR_MANAGER(),
            uint96(j + 1),
            operator,
            uint48(timestamp),
            operatorStake
            );
        }
    }

    function test_claimRewards() public {
        uint48 epoch = 1;
        address staker = makeAddr("Staker");

        // Set staker balance in vault
        address vault = vaultManager.vaults(0);
        MockVault(vault).setActiveBalance(staker, 300_000 * 1e18);
        
        // Set total active shares
        uint256 epochTs = middleware.getEpochStartTs(epoch);
        MockVault(vault).setTotalActiveShares(uint48(epochTs), 400_000 * 1e18);

        // Distribute rewards
        test_distributeRewards(4 hours);

        vm.warp((epoch + 1) * middleware.EPOCH_DURATION());

        uint256 stakerBalanceBefore = rewardsToken.balanceOf(staker);

        vm.prank(staker);
        rewards.claimRewards(address(rewardsToken), staker);

        uint256 stakerBalanceAfter = rewardsToken.balanceOf(staker);

        uint256 stakerRewards = stakerBalanceAfter - stakerBalanceBefore;

        assertGt(stakerRewards, 0, "Staker should receive rewards");

        // Verify can't claim twice in same epoch
        vm.prank(staker);
        vm.expectRevert(abi.encodeWithSelector(IRewards.AlreadyClaimedForLatestEpoch.selector, staker, epoch));
        rewards.claimRewards(address(rewardsToken), staker);
    }

    function test_claimRewards_revert_InvalidRecipient() public {
        vm.prank(makeAddr("Staker"));
        vm.expectRevert(abi.encodeWithSelector(IRewards.InvalidRecipient.selector, address(0)));
        rewards.claimRewards(address(rewardsToken), address(0));
    }

    function test_claimRewards_revert_AlreadyClaimedForLatestEpoch() public {
        uint48 epoch = 1;
        address staker = makeAddr("Staker");

        // Setup staker balance and distribute rewards
        address vault = vaultManager.vaults(0);
        MockVault(vault).setActiveBalance(staker, 300_000 * 1e18);
        
        // Set total active shares for the epoch timestamp
        uint256 epochTs = middleware.getEpochStartTs(epoch);
        MockVault(vault).setTotalActiveShares(uint48(epochTs), 400_000 * 1e18);
        
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        test_distributeRewards(4 hours);

        // Warp to next epoch
        vm.warp((epoch + 1) * middleware.EPOCH_DURATION());

        // First claim should succeed
        vm.prank(staker);
        rewards.claimRewards(address(rewardsToken), staker);

        // Second claim should fail
        vm.prank(staker);
        vm.expectRevert(abi.encodeWithSelector(IRewards.AlreadyClaimedForLatestEpoch.selector, staker, epoch));
        rewards.claimRewards(address(rewardsToken), staker);
    }

    function test_claimRewards_revert_NoRewardsToClaim() public {
        address staker = makeAddr("Staker");

        // Try to claim without any stake or rewards
        vm.prank(staker);
        vm.expectRevert(abi.encodeWithSelector(IRewards.NoRewardsToClaimEpoch.selector, staker, 0));
        rewards.claimRewards(address(rewardsToken), staker);
    }

    function test_claimRewards_EmitZeroRewardsClaim_NoStakeInVault() public {
        uint48 epoch = 1;
        address staker = makeAddr("Staker");

        // Set up total shares but no staker balance
        address vault = vaultManager.vaults(0);
        uint256 epochTs = middleware.getEpochStartTs(epoch);
        MockVault(vault).setTotalActiveShares(uint48(epochTs), 400_000 * 1e18);

        // Distribute rewards but don't give staker any stake
        test_distributeRewards(4 hours);

        // Warp to next epoch
        vm.warp((epoch + 1) * middleware.EPOCH_DURATION());

        vm.prank(staker);
        vm.expectEmit(true, true, false, true, address(rewards));
        emit IRewards.ZeroRewardsClaim(staker, address(rewardsToken), 1, "staker");
        rewards.claimRewards(address(rewardsToken), staker);
    }

    function test_claimRewards_revert_NoVaultShares() public {
        uint48 epoch = 1;
        address staker = makeAddr("Staker");

        // Give staker balance but don't distribute rewards
        address vault = vaultManager.vaults(0);
        MockVault(vault).setActiveBalance(staker, 300_000 * 1e18);
        
        // Set total active shares
        uint256 epochTs = middleware.getEpochStartTs(epoch);
        MockVault(vault).setTotalActiveShares(uint48(epochTs), 400_000 * 1e18);

        // Warp to next epoch
        vm.warp((epoch + 1) * middleware.EPOCH_DURATION());

        vm.prank(staker);
        vm.expectRevert(abi.encodeWithSelector(IRewards.NoRewardsToClaimEpoch.selector, staker, 0));
        rewards.claimRewards(address(rewardsToken), staker);
    }

    function test_claimRewards_revert_DistributionNotComplete() public {
        address staker = makeAddr("Staker");

        // Setup stakes
        uint48 epoch = 1;
        _setupStakes(epoch, 4 hours);

        // Only distribute partially (don't complete distribution)
        vm.warp((epoch + 3) * middleware.EPOCH_DURATION());
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.distributeRewards(epoch, 1);

        // Try to claim
        vm.expectRevert();
        vm.prank(staker);
        rewards.claimRewards(address(rewardsToken), staker);
    }

    function test_claimUndistributedRewards() public {
        uint48 epoch = 1;

        // Setup and distribute rewards
        // Put an uptime of 3.9 hours to leave some rewards undistributed
        test_distributeRewards(3.9 hours);

        // Warp to 2 epochs ahead to allow claiming
        vm.warp(block.timestamp + 3 * middleware.EPOCH_DURATION());

        // Record balances and rewards amount before claim
        uint256 recipientBalanceBefore = rewardsToken.balanceOf(REWARDS_DISTRIBUTOR_ROLE);
        uint256 rewardsAmountBefore = rewards.getRewardsAmountPerTokenFromEpoch(epoch, address(rewardsToken));

        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.claimUndistributedRewards(epoch, address(rewardsToken), REWARDS_DISTRIBUTOR_ROLE);

        // Verify rewards were transferred
        uint256 recipientBalanceAfter = rewardsToken.balanceOf(REWARDS_DISTRIBUTOR_ROLE);
        uint256 undistributedAmount = recipientBalanceAfter - recipientBalanceBefore;
        assertGt(undistributedAmount, 0, "Should receive undistributed rewards");

        // Verify rewards amount was reduced by undistributed amount (maintaining accounting invariant)
        uint256 rewardsAmountAfter = rewards.getRewardsAmountPerTokenFromEpoch(epoch, address(rewardsToken));
        uint256 expectedRemaining = rewardsAmountBefore - undistributedAmount;
        assertEq(rewardsAmountAfter, expectedRemaining, "Rewards amount should be reduced by swept amount");
        assertGt(rewardsAmountAfter, 0, "Some rewards should remain claimable by users");
        
        // Verify accounting invariant: remaining + swept = original
        assertEq(rewardsAmountAfter + undistributedAmount, rewardsAmountBefore, "Accounting invariant should hold");
    }

    function test_claimUndistributedRewards_revert_InvalidRecipient() public {
        uint48 epoch = 1;

        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        vm.expectRevert(abi.encodeWithSelector(IRewards.InvalidRecipient.selector, address(0)));
        rewards.claimUndistributedRewards(epoch, address(rewardsToken), address(0));
    }

    function test_claimUndistributedRewards_revert_DistributionNotComplete() public {
        uint48 epoch = 1;

        // Setup stakes
        _setupStakes(epoch, 4 hours);

        // Only distribute partially
        vm.warp((epoch + 3) * middleware.EPOCH_DURATION());
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.distributeRewards(epoch, 1);

        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        vm.expectRevert(abi.encodeWithSelector(IRewards.DistributionNotComplete.selector, epoch));
        rewards.claimUndistributedRewards(epoch, address(rewardsToken), REWARDS_DISTRIBUTOR_ROLE);
    }

    function test_claimUndistributedRewards_revert_EpochStillClaimable() public {
        uint48 epoch = 1;

        // Complete distribution
        test_distributeRewards(4 hours);

        // Try to claim before 2 epochs have passed
        vm.warp((epoch + 1) * middleware.EPOCH_DURATION());

        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        vm.expectRevert(abi.encodeWithSelector(IRewards.EpochStillClaimable.selector, epoch));
        rewards.claimUndistributedRewards(epoch, address(rewardsToken), REWARDS_DISTRIBUTOR_ROLE);
    }

    function test_claimUndistributedRewards_revert_NoUndistributedRewards() public {
        uint48 epoch = 1;

        // Setup a scenario where all rewards are distributed
        test_distributeRewards(4 hours);

        // Warp to after claimable period
        vm.warp(block.timestamp + 3 * middleware.EPOCH_DURATION());

        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        vm.expectRevert(abi.encodeWithSelector(IRewards.NoRewardsToClaim.selector, REWARDS_DISTRIBUTOR_ROLE));
        rewards.claimUndistributedRewards(epoch, address(rewardsToken), REWARDS_DISTRIBUTOR_ROLE);
    }

    function test_claimUndistributedRewards_revert_AlreadyClaimed() public {
        uint48 epoch = 1;

        // Complete distribution
        test_distributeRewards(3.9 hours);

        // Warp to after claimable period
        vm.warp(block.timestamp + 3 * middleware.EPOCH_DURATION());

        // First claim
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.claimUndistributedRewards(epoch, address(rewardsToken), REWARDS_DISTRIBUTOR_ROLE);

        // Try to claim again
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        vm.expectRevert(abi.encodeWithSelector(IRewards.NoRewardsToClaim.selector, REWARDS_DISTRIBUTOR_ROLE));
        rewards.claimUndistributedRewards(epoch, address(rewardsToken), REWARDS_DISTRIBUTOR_ROLE);
    }

    function test_claimUndistributedRewards_usersCanStillClaim() public {
        uint48 epoch = 1;
        address staker = makeAddr("Staker");
        
        // Setup staker balance
        address vault = vaultManager.vaults(0);
        MockVault(vault).setActiveBalance(staker, 300_000 * 1e18);
        uint256 epochTs = middleware.getEpochStartTs(epoch);
        MockVault(vault).setTotalActiveShares(uint48(epochTs), 400_000 * 1e18);

        // Setup and distribute rewards with partial uptime to create undistributed rewards
        test_distributeRewards(3.9 hours);

        // Warp to after grace period to allow undistributed rewards claim
        vm.warp(block.timestamp + 3 * middleware.EPOCH_DURATION());

        // Record initial state
        uint256 rewardsAmountBefore = rewards.getRewardsAmountPerTokenFromEpoch(epoch, address(rewardsToken));
        uint256 stakerBalanceBefore = rewardsToken.balanceOf(staker);

        // Claim undistributed rewards
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.claimUndistributedRewards(epoch, address(rewardsToken), REWARDS_DISTRIBUTOR_ROLE);

        // Verify remaining rewards are still available
        uint256 rewardsAmountAfter = rewards.getRewardsAmountPerTokenFromEpoch(epoch, address(rewardsToken));
        assertGt(rewardsAmountAfter, 0, "Should have remaining rewards for users");
        assertLt(rewardsAmountAfter, rewardsAmountBefore, "Should have reduced rewards after undistributed claim");

        // User should still be able to claim their allocated rewards
        vm.prank(staker);
        rewards.claimRewards(address(rewardsToken), staker);

        uint256 stakerBalanceAfter = rewardsToken.balanceOf(staker);
        assertGt(stakerBalanceAfter, stakerBalanceBefore, "Staker should receive their allocated rewards");
    }

    function test_claimRewardsForOtherParties() public {
        uint48 epoch = 1;

        // Setup and distribute rewards with partial uptime to ensure undistributed rewards
        test_distributeRewards(3.9 hours);

        // Warp to next epoch
        vm.warp((epoch + 1) * middleware.EPOCH_DURATION());

        // Test operator claims
        address operator = middleware.getAllOperators()[0];
        uint256 operatorBalanceBefore = rewardsToken.balanceOf(operator);
        vm.prank(operator);
        rewards.claimOperatorFee(address(rewardsToken), operator);
        assertGt(rewardsToken.balanceOf(operator), operatorBalanceBefore, "Operator should receive rewards");

        // Test curator claims
        address vault = vaultManager.vaults(0);
        address curator = MockVault(vault).owner();
        uint256 curatorBalanceBefore = rewardsToken.balanceOf(curator);
        vm.prank(curator);
        rewards.claimCuratorFee(address(rewardsToken), curator);
        assertGt(rewardsToken.balanceOf(curator), curatorBalanceBefore, "Curator should receive rewards");

        // Test protocol owner claims
        uint256 protocolOwnerBalanceBefore = rewardsToken.balanceOf(PROTOCOL_OWNER);
        vm.prank(PROTOCOL_OWNER);
        rewards.claimProtocolFee(address(rewardsToken), PROTOCOL_OWNER);
        assertGt(
            rewardsToken.balanceOf(PROTOCOL_OWNER), protocolOwnerBalanceBefore, "Protocol owner should receive rewards"
        );
    }

    // TEST ROLE FUNCTIONS
    function test_ChangeAdminRole() public {
        vm.startPrank(ADMIN);

        // Check current admin
        assertEq(rewards.hasRole(rewards.REWARDS_MANAGER_ROLE(), REWARDS_MANAGER_ROLE), true);

        address mewManager = makeAddr("mewManager");

        // Expect the AdminRoleAssigned event to be emitted with the new admin address
        vm.expectEmit(true, true, false, false, address(rewards));
        emit RewardsManagerRoleAssigned(mewManager);

        // Change the admin role
        rewards.setRewardsManagerRole(mewManager);

        // Verify the new admin role has been set
        assertEq(rewards.hasRole(rewards.REWARDS_MANAGER_ROLE(), mewManager), true);

        vm.stopPrank();
    }

    function test_ChangeRewardsDistributorRole() public {
        vm.startPrank(REWARDS_MANAGER_ROLE);

        // Check current distributor
        assertEq(rewards.hasRole(rewards.REWARDS_DISTRIBUTOR_ROLE(), REWARDS_DISTRIBUTOR_ROLE), true);

        address newDistributor = makeAddr("newDistributor");

        // Expect the RewardsDistributorRoleAssigned event to be emitted with the new distributor address
        vm.expectEmit(true, true, false, false, address(rewards));
        emit RewardsDistributorRoleAssigned(newDistributor);

        // Change the distributor role
        rewards.setRewardsDistributorRole(newDistributor);

        // Verify the new distributor role has been set
        assertEq(rewards.hasRole(rewards.REWARDS_DISTRIBUTOR_ROLE(), newDistributor), true);

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
        vm.startPrank(REWARDS_MANAGER_ROLE);

        // Define the new uptime value
        uint256 newUptime = 100;

        // Set the new minimum required uptime
        rewards.setMinRequiredUptime(newUptime);

        // Verify the new minimum required uptime has been set
        assertEq(rewards.minRequiredUptime(), newUptime);

        vm.stopPrank();
    }

    function test_UpdateProtocolFee() public {
        vm.startPrank(REWARDS_MANAGER_ROLE);

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
        vm.startPrank(REWARDS_MANAGER_ROLE);

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
        vm.startPrank(REWARDS_MANAGER_ROLE);

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

        // Define the asset class ID and the new rewards percentage
        uint96 assetClassId = 1;
        uint16 rewardsPercentage = 5000; // 50%

        // Expect the RewardsShareUpdated event to be emitted with the new rewards percentage
        vm.expectEmit(true, true, false, false);
        emit RewardsShareUpdated(assetClassId, rewardsPercentage);

        vm.prank(REWARDS_MANAGER_ROLE);
        // Set the rewards share for the asset class
        rewards.setRewardsShareForAssetClass(assetClassId, rewardsPercentage);

        // Verify the new rewards share has been set
        assertEq(rewards.rewardsSharePerAssetClass(assetClassId), rewardsPercentage);
    }

//   function test_DOS_RewardShareSumGreaterThan100Pct() public {
//         console2.log("=== TEST BEGINS ===");

        
//         // 1: Modify fee structure to make operators get 100% of rewards
//         // this is done just to demonstrate insolvency  
//         vm.startPrank(REWARDS_MANAGER_ROLE);
//         rewards.updateProtocolFee(0);     // 0% - no protocol fee  
//         rewards.updateOperatorFee(10000); // 100% - operators get everything
//         rewards.updateCuratorFee(0);      // 0% - no curator fee
//         vm.stopPrank();

//         // 2: Set asset class shares > 100%
//         vm.startPrank(REWARDS_MANAGER_ROLE);
//         rewards.setRewardsShareForAssetClass(1, 8000); // 80%
//         rewards.setRewardsShareForAssetClass(2, 7000); // 70% 
//         rewards.setRewardsShareForAssetClass(3, 5000); // 50%
//         // Total: 200% 
//         vm.stopPrank();

//         // 3: Use existing working setup for stakes
//         uint48 epoch = 1;
//         _setupStakes(epoch, 4 hours);

//         // 4: Distribute rewards
//         vm.warp((epoch + 3) * middleware.EPOCH_DURATION());
//         vm.prank(REWARDS_DISTRIBUTOR_ROLE);
//         rewards.distributeRewards(epoch, 10);

//         //5: Check operator shares (should be inflated due to 200% asset class shares)
//         address[] memory operators = middleware.getAllOperators();
//         uint256 totalOperatorShares = 0;
 
//         for (uint256 i = 0; i < operators.length; i++) {
//             uint256 opShare = rewards.operatorShares(epoch, operators[i]);
//             totalOperatorShares += opShare;
//         }
//         console2.log("Total operator shares: ", totalOperatorShares);
//         assertGt(totalOperatorShares, rewards.BASIS_POINTS_DENOMINATOR(), 
//                 "VULNERABILITY: Total operator shares exceed 100%");
        
//         //DOS when 6'th operator tries to claim rewards
//         vm.warp((epoch + 1) * middleware.EPOCH_DURATION());
//         for (uint256 i = 0; i < 5; i++) {
//              vm.prank(operators[i]);
//             rewards.claimOperatorFee(address(rewardsToken), operators[i]);
//         }

//         vm.expectRevert();
//         vm.prank(operators[5]);
//         rewards.claimOperatorFee(address(rewardsToken), operators[5]);        

//     }
 
  function test_DOS_RewardShareSumGreaterThan100PctFix() public {
    console2.log("=== TEST BEGINS ===");

    // 1: Modify fees to demonstrate that 100% is allowed for operator
    vm.startPrank(REWARDS_MANAGER_ROLE);
    rewards.updateAllFees(0, 10000, 0); // 0% protocol, 100% operator, 0% curator
    vm.stopPrank();

    // 2: First reduce class 3 to make room, set class 1 to 70% (total = 100%)
    vm.startPrank(REWARDS_MANAGER_ROLE);
    rewards.setRewardsShareForAssetClass(3, 0); // Remove class 3 (now 50% + 30% + 0% = 80%)
    rewards.setRewardsShareForAssetClass(1, 7000); // Set class 1 to 70% (now 70% + 30% + 0% = 100%)
    
    // 3: Now try to set class 1 to 80% - this should fail because 80% + 30% = 110%
    vm.expectRevert(
        abi.encodeWithSelector(
            IRewards.AssetClassSharesExceed100.selector,
            11000 // 80% + 30% + 0% = 110%
        )
    );
    rewards.setRewardsShareForAssetClass(1, 8000); // This should fail 
    vm.stopPrank();
    }

    // function test_claimRewards_multipleTokens_staker() public {
    //     // Deploy a second reward token
    //     ERC20Mock rewardsToken2 = new ERC20Mock();
    //     rewardsToken2.mint(REWARDS_DISTRIBUTOR_ROLE, 1_000_000 * 10 ** 18);
    //     vm.prank(REWARDS_DISTRIBUTOR_ROLE);
    //     rewardsToken2.approve(address(rewards), 1_000_000 * 10 ** 18);
        
    //     // Mint additional tokens for the original rewardsToken to cover 3 epochs
    //     rewardsToken.mint(REWARDS_DISTRIBUTOR_ROLE, 300_000 * 10 ** 18);
    //     vm.prank(REWARDS_DISTRIBUTOR_ROLE);
    //     rewardsToken.approve(address(rewards), 400_000 * 10 ** 18); // Total: 100k (from setup) + 300k = 400k
        
    //     uint48 startEpoch = 1;
    //     uint48 numberOfEpochs = 3;
    //     uint256 rewardsAmount = 100_000 * 10 ** 18;

    //     // Set rewards for both tokens
    //     vm.startPrank(REWARDS_DISTRIBUTOR_ROLE);
    //     rewards.setRewardsAmountForEpochs(startEpoch, numberOfEpochs, address(rewardsToken), rewardsAmount);
    //     rewards.setRewardsAmountForEpochs(startEpoch, numberOfEpochs, address(rewardsToken2), rewardsAmount);
    //     vm.stopPrank();

    //     // Setup staker
    //     address staker = makeAddr("Staker");
    //     address vault = vaultManager.vaults(0);
    //     uint256 epochTs = middleware.getEpochStartTs(startEpoch);
    //     MockVault(vault).setActiveBalance(staker, 300_000 * 1e18);
    //     MockVault(vault).setTotalActiveShares(uint48(epochTs), 400_000 * 1e18);

    //     // Distribute rewards for epochs 1 to 3
    //     for (uint48 epoch = startEpoch; epoch < startEpoch + numberOfEpochs; epoch++) {
    //         _setupStakesAudit(epoch, 4 hours);
    //         vm.warp((epoch + 3) * middleware.EPOCH_DURATION());
    //         address[] memory operators = middleware.getAllOperators();
    //         vm.prank(REWARDS_DISTRIBUTOR_ROLE);
    //         rewards.distributeRewards(epoch, uint48(operators.length));
    //     }

    //     // Warp to epoch 4
    //     vm.warp((startEpoch + numberOfEpochs) * middleware.EPOCH_DURATION());

    //     // Claim for rewardsToken (should succeed)
    //     vm.prank(staker);
    //     rewards.claimRewards(address(rewardsToken), staker);
    //     assertGt(rewardsToken.balanceOf(staker), 0, "Staker should receive rewardsToken");

    //     // Try to claim for rewardsToken2 (should revert)
    //     vm.prank(staker);
    //     vm.expectRevert(abi.encodeWithSelector(IRewards.AlreadyClaimedForLatestEpoch.selector, staker, numberOfEpochs));
    //     rewards.claimRewards(address(rewardsToken2), staker);
    // }

    // function test_claimOperatorFee_multipleTokens_operator() public {
    //     // Deploy a second reward token
    //     ERC20Mock rewardsToken2 = new ERC20Mock();
    //     rewardsToken2.mint(REWARDS_DISTRIBUTOR_ROLE, 1_000_000 * 10 ** 18);
    //     vm.prank(REWARDS_DISTRIBUTOR_ROLE);
    //     rewardsToken2.approve(address(rewards), 1_000_000 * 10 ** 18);

    //     // Mint additional tokens for the original rewardsToken to cover 3 epochs
    //     rewardsToken.mint(REWARDS_DISTRIBUTOR_ROLE, 300_000 * 10 ** 18);
    //     vm.prank(REWARDS_DISTRIBUTOR_ROLE);
    //     rewardsToken.approve(address(rewards), 400_000 * 10 ** 18); // Total: 100k (from setup) + 300k = 400k

    //     uint48 startEpoch = 1;
    //     uint48 numberOfEpochs = 3;
    //     uint256 rewardsAmount = 100_000 * 10 ** 18;

    //     // Set rewards for both tokens
    //     vm.startPrank(REWARDS_DISTRIBUTOR_ROLE);
    //     rewards.setRewardsAmountForEpochs(startEpoch, numberOfEpochs, address(rewardsToken), rewardsAmount);
    //     rewards.setRewardsAmountForEpochs(startEpoch, numberOfEpochs, address(rewardsToken2), rewardsAmount);
    //     vm.stopPrank();

    //     // Distribute rewards for epochs 1 to 3
    //     for (uint48 epoch = startEpoch; epoch < startEpoch + numberOfEpochs; epoch++) {
    //         _setupStakesAudit(epoch, 4 hours);
    //         vm.warp((epoch + 3) * middleware.EPOCH_DURATION());
    //         address[] memory operators = middleware.getAllOperators();
    //         vm.prank(REWARDS_DISTRIBUTOR_ROLE);
    //         rewards.distributeRewards(epoch, uint48(operators.length));
    //     }

    //     // Warp to epoch 4
    //     vm.warp((startEpoch + numberOfEpochs) * middleware.EPOCH_DURATION());

    //     address operator = middleware.getAllOperators()[0];

    //     // Claim for rewardsToken (should succeed)
    //     vm.prank(operator);
    //     rewards.claimOperatorFee(address(rewardsToken), operator);
    //     assertGt(rewardsToken.balanceOf(operator), 0, "Operator should receive rewardsToken");

    //     // Try to claim for rewardsToken2 (should revert)
    //     vm.prank(operator);
    //     vm.expectRevert(abi.encodeWithSelector(IRewards.AlreadyClaimedForLatestEpoch.selector, operator, numberOfEpochs));
    //     rewards.claimOperatorFee(address(rewardsToken2), operator);
    // }

    // function test_claimCuratorFee_multipleTokens_curator() public {
    //     // Deploy a second reward token
    //     ERC20Mock rewardsToken2 = new ERC20Mock();
    //     rewardsToken2.mint(REWARDS_DISTRIBUTOR_ROLE, 1_000_000 * 10 ** 18);
    //     vm.prank(REWARDS_DISTRIBUTOR_ROLE);
    //     rewardsToken2.approve(address(rewards), 1_000_000 * 10 ** 18);

    //     // Mint additional tokens for the original rewardsToken to cover 3 epochs
    //     rewardsToken.mint(REWARDS_DISTRIBUTOR_ROLE, 300_000 * 10 ** 18);
    //     vm.prank(REWARDS_DISTRIBUTOR_ROLE);
    //     rewardsToken.approve(address(rewards), 400_000 * 10 ** 18); // Total: 100k (from setup) + 300k = 400k

    //     uint48 startEpoch = 1;
    //     uint48 numberOfEpochs = 3;
    //     uint256 rewardsAmount = 100_000 * 10 ** 18;

    //     // Set rewards for both tokens
    //     vm.startPrank(REWARDS_DISTRIBUTOR_ROLE);
    //     rewards.setRewardsAmountForEpochs(startEpoch, numberOfEpochs, address(rewardsToken), rewardsAmount);
    //     rewards.setRewardsAmountForEpochs(startEpoch, numberOfEpochs, address(rewardsToken2), rewardsAmount);
    //     vm.stopPrank();

    //     // Distribute rewards for epochs 1 to 3
    //     for (uint48 epoch = startEpoch; epoch < startEpoch + numberOfEpochs; epoch++) {
    //         _setupStakesAudit(epoch, 4 hours);
    //         vm.warp((epoch + 3) * middleware.EPOCH_DURATION());
    //         address[] memory operators = middleware.getAllOperators();
    //         vm.prank(REWARDS_DISTRIBUTOR_ROLE);
    //         rewards.distributeRewards(epoch, uint48(operators.length));
    //     }

    //     // Warp to epoch 4
    //     vm.warp((startEpoch + numberOfEpochs) * middleware.EPOCH_DURATION());

    //     address vault = vaultManager.vaults(0);
    //     address curator = MockVault(vault).owner();

    //     // Claim for rewardsToken (should succeed)
    //     vm.prank(curator);
    //     rewards.claimCuratorFee(address(rewardsToken), curator);
    //     assertGt(rewardsToken.balanceOf(curator), 0, "Curator should receive rewardsToken");

    //     // Try to claim for rewardsToken2 (should revert)
    //     vm.prank(curator);
    //     vm.expectRevert(abi.encodeWithSelector(IRewards.AlreadyClaimedForLatestEpoch.selector, curator, numberOfEpochs));
    //     rewards.claimCuratorFee(address(rewardsToken2), curator);
    // }

    function test_claimRewards_multipleTokens_staker_Fix() public {
        // Deploy a second reward token
        ERC20Mock rewardsToken2 = new ERC20Mock();
        rewardsToken2.mint(REWARDS_DISTRIBUTOR_ROLE, 1_000_000 * 10 ** 18);
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewardsToken2.approve(address(rewards), 1_000_000 * 10 ** 18);
        
        // Mint additional tokens for the original rewardsToken to cover 3 epochs
        rewardsToken.mint(REWARDS_DISTRIBUTOR_ROLE, 300_000 * 10 ** 18);
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewardsToken.approve(address(rewards), 400_000 * 10 ** 18); // Total: 100k (from setup) + 300k = 400k
        
        uint48 startEpoch = 1;
        uint48 numberOfEpochs = 3;
        uint256 rewardsAmount = 100_000 * 10 ** 18;

        // Set rewards for both tokens
        vm.startPrank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.setRewardsAmountForEpochs(startEpoch, numberOfEpochs, address(rewardsToken), rewardsAmount);
        rewards.setRewardsAmountForEpochs(startEpoch, numberOfEpochs, address(rewardsToken2), rewardsAmount);
        vm.stopPrank();

        // Setup staker
        address staker = makeAddr("Staker");
        address vault = vaultManager.vaults(0);
        uint256 epochTs = middleware.getEpochStartTs(startEpoch);
        MockVault(vault).setActiveBalance(staker, 300_000 * 1e18);
        MockVault(vault).setTotalActiveShares(uint48(epochTs), 400_000 * 1e18);

        // Distribute rewards for epochs 1 to 3
        for (uint48 epoch = startEpoch; epoch < startEpoch + numberOfEpochs; epoch++) {
            _setupStakesAudit(epoch, 4 hours);
            vm.warp((epoch + 3) * middleware.EPOCH_DURATION());
            address[] memory operators = middleware.getAllOperators();
            vm.prank(REWARDS_DISTRIBUTOR_ROLE);
            rewards.distributeRewards(epoch, uint48(operators.length));
        }

        // Warp to epoch 4
        vm.warp((startEpoch + numberOfEpochs) * middleware.EPOCH_DURATION());

        // --- claim rewardsToken --------------------------------------------------
        uint256 bal1Before = rewardsToken.balanceOf(staker);
        vm.prank(staker);
        rewards.claimRewards(address(rewardsToken), staker);
        uint256 bal1After = rewardsToken.balanceOf(staker);
        assertGt(bal1After, bal1Before, "Staker received token1");

        // --- claim rewardsToken2 -------------------------------------------------
        uint256 bal2Before = rewardsToken2.balanceOf(staker);
        vm.prank(staker);
        rewards.claimRewards(address(rewardsToken2), staker);
        uint256 bal2After = rewardsToken2.balanceOf(staker);
        assertGt(bal2After, bal2Before, "Staker received token2");

        // --- re‑claim in same epoch must now revert -----------------------------
        vm.prank(staker);
        vm.expectRevert(
            abi.encodeWithSelector(IRewards.AlreadyClaimedForLatestEpoch.selector, staker, numberOfEpochs)
        );
        rewards.claimRewards(address(rewardsToken), staker);
    }

    function test_claimOperatorFee_multipleTokens_operator_Fix() public {
        // Deploy a second reward token
        ERC20Mock rewardsToken2 = new ERC20Mock();
        rewardsToken2.mint(REWARDS_DISTRIBUTOR_ROLE, 1_000_000 * 10 ** 18);
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewardsToken2.approve(address(rewards), 1_000_000 * 10 ** 18);

        // Mint additional tokens for the original rewardsToken to cover 3 epochs
        rewardsToken.mint(REWARDS_DISTRIBUTOR_ROLE, 300_000 * 10 ** 18);
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewardsToken.approve(address(rewards), 400_000 * 10 ** 18); // Total: 100k (from setup) + 300k = 400k

        uint48 startEpoch = 1;
        uint48 numberOfEpochs = 3;
        uint256 rewardsAmount = 100_000 * 10 ** 18;

        // Set rewards for both tokens
        vm.startPrank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.setRewardsAmountForEpochs(startEpoch, numberOfEpochs, address(rewardsToken), rewardsAmount);
        rewards.setRewardsAmountForEpochs(startEpoch, numberOfEpochs, address(rewardsToken2), rewardsAmount);
        vm.stopPrank();

        // Distribute rewards for epochs 1 to 3
        for (uint48 epoch = startEpoch; epoch < startEpoch + numberOfEpochs; epoch++) {
            _setupStakesAudit(epoch, 4 hours);
            vm.warp((epoch + 3) * middleware.EPOCH_DURATION());
            address[] memory operators = middleware.getAllOperators();
            vm.prank(REWARDS_DISTRIBUTOR_ROLE);
            rewards.distributeRewards(epoch, uint48(operators.length));
        }

        // Warp to epoch 4
        vm.warp((startEpoch + numberOfEpochs) * middleware.EPOCH_DURATION());
        address operator = middleware.getAllOperators()[0];

        // --- claim rewardsToken --------------------------------------------------
        uint256 bal1Before = rewardsToken.balanceOf(operator);
        vm.prank(operator);
        rewards.claimOperatorFee(address(rewardsToken), operator);
        uint256 bal1After = rewardsToken.balanceOf(operator);
        assertGt(bal1After, bal1Before, "Operator received token1");

        // --- claim rewardsToken2 -------------------------------------------------
        uint256 bal2Before = rewardsToken2.balanceOf(operator);
        vm.prank(operator);
        rewards.claimOperatorFee(address(rewardsToken2), operator);
        uint256 bal2After = rewardsToken2.balanceOf(operator);
        assertGt(bal2After, bal2Before, "Operator received token2");

        // --- re‑claim must revert ----------------------------------------------
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IRewards.AlreadyClaimedForLatestEpoch.selector, operator, numberOfEpochs)
        );
        rewards.claimOperatorFee(address(rewardsToken), operator);
    }

    function test_claimCuratorFee_multipleTokens_curator_Fix() public {
        // Deploy a second reward token
        ERC20Mock rewardsToken2 = new ERC20Mock();
        rewardsToken2.mint(REWARDS_DISTRIBUTOR_ROLE, 1_000_000 * 10 ** 18);
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewardsToken2.approve(address(rewards), 1_000_000 * 10 ** 18);

        // Mint additional tokens for the original rewardsToken to cover 3 epochs
        rewardsToken.mint(REWARDS_DISTRIBUTOR_ROLE, 300_000 * 10 ** 18);
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewardsToken.approve(address(rewards), 400_000 * 10 ** 18); // Total: 100k (from setup) + 300k = 400k

        uint48 startEpoch = 1;
        uint48 numberOfEpochs = 3;
        uint256 rewardsAmount = 100_000 * 10 ** 18;

        // Set rewards for both tokens
        vm.startPrank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.setRewardsAmountForEpochs(startEpoch, numberOfEpochs, address(rewardsToken), rewardsAmount);
        rewards.setRewardsAmountForEpochs(startEpoch, numberOfEpochs, address(rewardsToken2), rewardsAmount);
        vm.stopPrank();

        // Distribute rewards for epochs 1 to 3
        for (uint48 epoch = startEpoch; epoch < startEpoch + numberOfEpochs; epoch++) {
            _setupStakesAudit(epoch, 4 hours);
            vm.warp((epoch + 3) * middleware.EPOCH_DURATION());
            address[] memory operators = middleware.getAllOperators();
            vm.prank(REWARDS_DISTRIBUTOR_ROLE);
            rewards.distributeRewards(epoch, uint48(operators.length));
        }

        // Warp to epoch 4
        vm.warp((startEpoch + numberOfEpochs) * middleware.EPOCH_DURATION());
        address vault  = vaultManager.vaults(0);
        address curator = MockVault(vault).owner();

        // --- claim rewardsToken --------------------------------------------------
        uint256 bal1Before = rewardsToken.balanceOf(curator);
        vm.prank(curator);
        rewards.claimCuratorFee(address(rewardsToken), curator);
        uint256 bal1After = rewardsToken.balanceOf(curator);
        assertGt(bal1After, bal1Before, "Curator received token1");

        // --- claim rewardsToken2 -------------------------------------------------
        uint256 bal2Before = rewardsToken2.balanceOf(curator);
        vm.prank(curator);
        rewards.claimCuratorFee(address(rewardsToken2), curator);
        uint256 bal2After = rewardsToken2.balanceOf(curator);
        assertGt(bal2After, bal2Before, "Curator received token2");

        // --- re‑claim must revert ----------------------------------------------
        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(IRewards.AlreadyClaimedForLatestEpoch.selector, curator, numberOfEpochs)
        );
        rewards.claimCuratorFee(address(rewardsToken), curator);
    }

    // Sparse claiming is not supported anymore
    // function test_claimSparseEpochs() public {
    //     /* Fund only epoch 5, stake epochs 4 & 5, then claim at epoch 10 */
    //     uint48 fundEpoch = 5;
    //     uint256 amount = 1e20;
        
    //     // Fund epoch 5 within window
    //     rewardsToken.mint(REWARDS_DISTRIBUTOR_ROLE, amount);
    //     vm.prank(REWARDS_DISTRIBUTOR_ROLE);
    //     rewardsToken.approve(address(rewards), amount);
    //     vm.prank(REWARDS_DISTRIBUTOR_ROLE);
    //     rewards.setRewardsAmountForEpochs(fundEpoch, 1, address(rewardsToken), amount);

    //     // Set up stakes for epochs 4 & 5
    //     _setupStakesAudit(4, 4 hours);
    //     _setupStakesAudit(fundEpoch, 4 hours);

    //     // Move to currentEpoch = fundEpoch + FUNDING_DEADLINE_OFFSET so funding window for epoch 4 is closed
    //     vm.warp((fundEpoch + rewards.FUNDING_DEADLINE_OFFSET()) * middleware.EPOCH_DURATION());

    //     // Sequential requirement: distribute epoch 4 (unfunded, now allowed) then epoch 5
    //     vm.prank(REWARDS_DISTRIBUTOR_ROLE);
    //     rewards.distributeRewards(4, 10);
    //     vm.prank(REWARDS_DISTRIBUTOR_ROLE);
    //     rewards.distributeRewards(fundEpoch, 10);

    //     // Fast-forward to epoch 10 and claim
    //     vm.warp(10 * middleware.EPOCH_DURATION());

    //     address staker = makeAddr("SparseStaker");
    //     address vault = vaultManager.vaults(0);
    //     uint256 ts = middleware.getEpochStartTs(fundEpoch);
    //     MockVault(vault).setActiveBalance(staker, 1e18);
    //     MockVault(vault).setTotalActiveShares(uint48(ts), 1e18);

    //     vm.prank(staker);
    //     rewards.claimRewards(address(rewardsToken), staker);
    // }

    function test_reentrancyGuard() public {
        EvilToken evil = new EvilToken(rewards);
        evil.mint(REWARDS_DISTRIBUTOR_ROLE, 1e20);
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        evil.approve(address(rewards), 1e20);

        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.setRewardsAmountForEpochs(1, 1, address(evil), 1e20);

        _setupStakesAudit(1, 4 hours);
        vm.warp((4) * middleware.EPOCH_DURATION());
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.distributeRewards(1, 10);

        // claim as protocol owner (re‑entrancy attempt lives in transfer)
        vm.prank(PROTOCOL_OWNER);
        rewards.claimProtocolFee(address(evil), PROTOCOL_OWNER);
    }

    // function test_RewardsDistribution_DivisionByZero_NewAssetClass() public {
    //     uint48 epoch = 1;
    //     _setupStakes(epoch, 4 hours);
        
    //     vm.warp((epoch + 1) * middleware.EPOCH_DURATION());
        
    //     // Add a new asset class (4) after epoch 1 has passed    
    //     uint96 newAssetClass = 4;
    //     uint96[] memory currentAssetClasses = middleware.getAssetClassIds();
    //     uint96[] memory newAssetClasses = new uint96[](currentAssetClasses.length + 1);
    //     for (uint256 i = 0; i < currentAssetClasses.length; i++) {
    //         newAssetClasses[i] = currentAssetClasses[i];
    //     }
    //     newAssetClasses[currentAssetClasses.length] = newAssetClass;
        
    //     // Update the middleware to return the new asset class list
    //     middleware.setAssetClassIds(newAssetClasses);
        
    //     // Re‑balance so that the overall sum stays 100 %
    //     vm.startPrank(REWARDS_MANAGER_ROLE);
    //     rewards.setRewardsShareForAssetClass(3, 1000);         // drop class 3 from 20 % → 10 %
    //     rewards.setRewardsShareForAssetClass(newAssetClass, 1000); // give 10 % to class 4
    //     vm.stopPrank();

    //     // distribute rewards   
    //     vm.warp((epoch + 3) * middleware.EPOCH_DURATION());
    //     assertEq(middleware.totalStakeCache(epoch, newAssetClass), 0, "New asset class should have zero stake for historical epoch 1");

    //     vm.prank(REWARDS_DISTRIBUTOR_ROLE);    
    //     vm.expectRevert(); // Division by zero in Math.mulDiv when totalStake = 0
    //     rewards.distributeRewards(epoch, 1);
    // }

    function test_RewardsDistribution_DivisionByZero_NewAssetClass_Fix() public {
        uint48 epoch = 1;
        _setupStakes(epoch, 4 hours);
        
        vm.warp((epoch + 1) * middleware.EPOCH_DURATION());
        
        // Add a new asset class (4) after epoch 1 has passed    
        uint96 newAssetClass = 4;
        uint96[] memory currentAssetClasses = middleware.getAssetClassIds();
        uint96[] memory newAssetClasses = new uint96[](currentAssetClasses.length + 1);
        for (uint256 i = 0; i < currentAssetClasses.length; i++) {
            newAssetClasses[i] = currentAssetClasses[i];
        }
        newAssetClasses[currentAssetClasses.length] = newAssetClass;
        
        // Update the middleware to return the new asset class list
        middleware.setAssetClassIds(newAssetClasses);
        
        // Re‑balance so that the overall sum stays 100 %
        vm.startPrank(REWARDS_MANAGER_ROLE);
        rewards.setRewardsShareForAssetClass(3, 1000);         // drop class 3 from 20 % → 10 %
        rewards.setRewardsShareForAssetClass(newAssetClass, 1000); // give 10 % to class 4
        vm.stopPrank();

        // distribute rewards   
        vm.warp((epoch + 3) * middleware.EPOCH_DURATION());
        assertEq(middleware.totalStakeCache(epoch, newAssetClass), 0, "New asset class should have zero stake for historical epoch 1");

        // after the contract fix this must succeed (guard skips the div‑0 path)
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.distributeRewards(epoch, 1);
    }

    function test_distributeRewards_removedOperator() public {
        uint48 epoch = 1;
        uint256 uptime = 4 hours;

        // Set up stakes for operators in epoch 1
        _setupStakes(epoch, uptime);

        // Get the list of operators
        address[] memory operators = middleware.getAllOperators();
        address removedOperator = operators[0]; // Operator to be removed
        address activeOperator = operators[1]; // Operator to remain active

        // Disable operator[0] at the start of epoch 2
        uint256 epoch2Start = middleware.getEpochStartTs(epoch + 1); // T = 8h
        vm.warp(epoch2Start);
        middleware.disableOperator(removedOperator);

        // Warp to after the slashing window to allow removal
        uint256 removalTime = epoch2Start + middleware.SLASHING_WINDOW()
            + (middleware.REMOVAL_DELAY_EPOCHS() * middleware.EPOCH_DURATION()); // T = 37h (8h + 5h + 24h)
        vm.warp(removalTime);
        middleware.removeOperator(removedOperator);

        // Warp to epoch 4 to distribute rewards for epoch 1
        uint256 distributionTime = middleware.getEpochStartTs(epoch + 3); // T = 16h
        vm.warp(distributionTime);

        // Distribute rewards in batches
        uint256 batchSize = 3;
        uint256 remainingOperators = middleware.getAllOperators().length; // Now 9 operators
        while (remainingOperators > 0) {
            vm.prank(REWARDS_DISTRIBUTOR_ROLE);
            rewards.distributeRewards(epoch, uint48(batchSize));
            remainingOperators = remainingOperators > batchSize ? remainingOperators - batchSize : 0;
        }

        // Verify that the removed operator has zero shares
        assertEq(
            rewards.operatorShares(epoch, removedOperator),
            0,
            "Removed operator should have zero shares if the delay period passed and they were removed"
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
        ERC20Mock rewardsToken1 = new ERC20Mock();
        rewardsToken1.mint(REWARDS_DISTRIBUTOR_ROLE, 2 * 1_000_000 * 10 ** 18);
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewardsToken1.approve(address(rewards), 2 * 1_000_000 * 10 ** 18);
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.setRewardsAmountForEpochs(5, 1, address(rewardsToken1), rewardsAmount);
        assertEq(rewards.getRewardsAmountPerTokenFromEpoch(5, address(rewardsToken1)), rewardsAmount - Math.mulDiv(rewardsAmount, 1000, 10000));
        assertEq(rewardsToken1.balanceOf(address(rewards)), rewardsAmount);
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.setRewardsAmountForEpochs(5, 1, address(rewardsToken1), rewardsAmount);
        assertEq(rewardsToken1.balanceOf(address(rewards)), rewardsAmount * 2 );
        assertEq(rewards.getRewardsAmountPerTokenFromEpoch(5, address(rewardsToken1)), (rewardsAmount - Math.mulDiv(rewardsAmount, 1000, 10000)) * 2);
    }

    function test_distributeRewards_claimFee(uint256 uptime) public {
        uint48 epoch = 1;
        uptime = bound(uptime, 0, 4 hours);
        
        // Ensure we start at beginning to fund within window
        vm.warp(0);
        
        _setupStakes(epoch, uptime);
        _setupStakes(epoch + 2, uptime);

        // fund epochs 1 **and 3** (epoch+2) so both can be distributed
        uint256 amount = 100_000 * 1e18;
        uint48 numberOfEpochs = 3;
        // Mint additional tokens needed for this test
        rewardsToken.mint(REWARDS_DISTRIBUTOR_ROLE, amount * numberOfEpochs);
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewardsToken.approve(address(rewards), amount * numberOfEpochs);
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.setRewardsAmountForEpochs(epoch, numberOfEpochs, address(rewardsToken), amount);

        address[] memory operators = middleware.getAllOperators();
        uint256 batchSize = 3;
        uint256 remainingOperators = operators.length;
        vm.warp((epoch + 3) * middleware.EPOCH_DURATION());
        while (remainingOperators > 0) {
            vm.prank(REWARDS_DISTRIBUTOR_ROLE);
            rewards.distributeRewards(epoch, uint48(batchSize));
            remainingOperators = remainingOperators > batchSize ? remainingOperators - batchSize : 0;
        }
        vm.warp((epoch + 4) * middleware.EPOCH_DURATION());
        for (uint256 i = 0; i < operators.length; i++) {
            uint256 operatorShare = rewards.operatorShares(epoch, operators[i]);
            if (operatorShare > 0) {
                vm.prank(operators[i]);
                rewards.claimOperatorFee(address(rewardsToken), operators[i]);
                assertGt(rewardsToken.balanceOf(operators[i]), 0, "Operator should receive rewards ");
                vm.stopPrank();
                break;
            }
        }
        vm.warp((epoch + 5) * middleware.EPOCH_DURATION());
        
        // Try to distribute epoch 3 before epoch 2 (should fail due to sequential enforcement)
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
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
            vm.prank(REWARDS_DISTRIBUTOR_ROLE);
            rewards.distributeRewards(epoch + 1, uint48(batchSize)); // epoch 2
            remainingOperators = remainingOperators > batchSize ? remainingOperators - batchSize : 0;
        }
        
        // Now epoch 3 can be distributed
        vm.warp((epoch + 6) * middleware.EPOCH_DURATION());
        remainingOperators = operators.length;
        while (remainingOperators > 0) {
            vm.prank(REWARDS_DISTRIBUTOR_ROLE);
            rewards.distributeRewards(epoch + 2, uint48(batchSize)); // epoch 3
            remainingOperators = remainingOperators > batchSize ? remainingOperators - batchSize : 0;
        }

        vm.warp((epoch + 7) * middleware.EPOCH_DURATION());
        for (uint256 i = 0; i < operators.length; i++) {
            uint256 operatorShare = rewards.operatorShares(epoch + 2, operators[i]);
            if (operatorShare > 0) {
                vm.prank(operators[i]);
                rewards.claimOperatorFee(address(rewardsToken), operators[i]);
                vm.stopPrank();
                break;
            }
        }
    }

    function test_fund_before_deadline_then_distribute_ok() public {
        uint48 epoch = 1;
        _setupStakes(epoch, 4 hours);

        // Fund epoch 1 while still well inside the window
        // Current epoch = epoch + 1, well within funding deadline
        vm.warp((epoch + 1) * middleware.EPOCH_DURATION());
        uint256 amt = 100_000 ether;
        rewardsToken.mint(REWARDS_DISTRIBUTOR_ROLE, amt);
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewardsToken.approve(address(rewards), amt);
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.setRewardsAmountForEpochs(epoch, 1, address(rewardsToken), amt);

        // Earliest legal distribution moment is epoch + DISTRIBUTION_EARLIEST_OFFSET
        vm.warp((epoch + rewards.DISTRIBUTION_EARLIEST_OFFSET() + 1) * middleware.EPOCH_DURATION());
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.distributeRewards(epoch, 10);
    }

    function test_distribution_too_early_reverts() public {
        uint48 epoch = 1;
        _setupStakes(epoch, 4 hours);

        // Try to distribute before DISTRIBUTION_EARLIEST_OFFSET
        // Current epoch = epoch + 1 = 2, which is < epoch + DISTRIBUTION_EARLIEST_OFFSET = 3
        vm.warp((epoch + 1) * middleware.EPOCH_DURATION());
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        vm.expectRevert(
            abi.encodeWithSelector(IRewards.RewardsDistributionTooEarly.selector, epoch, 0)
        );
        rewards.distributeRewards(epoch, 10);
    }

    function test_distributionWithoutFunding_withinWindow_revert() public {
        uint48 epoch = 2;
        _setupStakes(epoch, 4 hours);

        // Distribution within funding window should revert for unfunded epoch
        // Current epoch = epoch + DISTRIBUTION_EARLIEST_OFFSET + 1, still within funding window
        vm.warp((epoch + rewards.DISTRIBUTION_EARLIEST_OFFSET() + 1) * middleware.EPOCH_DURATION());

        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        vm.expectRevert(abi.encodeWithSelector(IRewards.EpochNotFunded.selector, epoch));
        rewards.distributeRewards(epoch, 1);
    }

    function test_distributionWithoutFunding_afterWindow_ok() public {
        _setupStakes(1, 4 hours);
        _setupStakes(2, 4 hours);

        // Jump so funding window for epoch 1 is closed
        // Current epoch = 1 + FUNDING_DEADLINE_OFFSET + 3, well beyond funding window
        vm.warp((1 + rewards.FUNDING_DEADLINE_OFFSET() + 3) * middleware.EPOCH_DURATION());

        // Sequential requirement: distribute epoch 1 first, then epoch 2
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.distributeRewards(1, 10);
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.distributeRewards(2, 10);

        (, bool complete) = rewards.distributionBatches(2);
        assertTrue(complete, "Epoch 2 should distribute even when unfunded once window closed");
    }

    function test_fundOldEpoch_afterWindow_beforeDistribution_ok() public {
        uint48 epoch = 3;
        uint256 amt = 50_000 * 1e18;

        // Funding after window but before distribution should be allowed
        // Current epoch = epoch + FUNDING_DEADLINE_OFFSET + 1, beyond funding window
        vm.warp((epoch + rewards.FUNDING_DEADLINE_OFFSET() + 1) * middleware.EPOCH_DURATION());

        rewardsToken.mint(REWARDS_DISTRIBUTOR_ROLE, amt);
        vm.startPrank(REWARDS_DISTRIBUTOR_ROLE);
        rewardsToken.approve(address(rewards), amt);
        rewards.setRewardsAmountForEpochs(epoch, 1, address(rewardsToken), amt);
        vm.stopPrank();

        (bool funded,) = rewards.epochStatus(epoch);
        assertTrue(funded, "epoch must be flagged as funded");
    }

    function test_pastFundingWindow_distributeAll_thenClaim() public {
        // Use epochs 4, 5, 6 which are not funded (epoch 1 is already funded in setup)
        uint48 startEpoch = 4;
        uint48 numEpochs = 3;
        
        // First need to distribute epoch 1 (funded in setup) to satisfy sequential requirement
        _setupStakes(1, 4 hours);
        vm.warp((1 + rewards.DISTRIBUTION_EARLIEST_OFFSET() + 1) * middleware.EPOCH_DURATION());
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.distributeRewards(1, 10);
        
        // Setup stakes for unfunded epochs
        for (uint48 epoch = startEpoch; epoch < startEpoch + numEpochs; epoch++) {
            _setupStakes(epoch, 4 hours);
        }

        // Warp past funding window for the unfunded epochs
        // Current epoch = startEpoch + numEpochs + FUNDING_DEADLINE_OFFSET, beyond all funding windows
        vm.warp((startEpoch + numEpochs + rewards.FUNDING_DEADLINE_OFFSET()) * middleware.EPOCH_DURATION());

        // Distribute ALL epochs from 2 up to our target epochs to maintain sequential order
        // This ensures the claim loop won't break early on undistributed epochs
        for (uint48 epoch = 2; epoch < startEpoch + numEpochs; epoch++) {
            vm.prank(REWARDS_DISTRIBUTOR_ROLE);
            rewards.distributeRewards(epoch, 10);
            
            // Verify distribution completed
            (, bool complete) = rewards.distributionBatches(epoch);
            assertTrue(complete, "Distribution should be complete for each epoch");
        }

        // Setup staker for claiming
        address staker = makeAddr("TestStaker");
        address vault = vaultManager.vaults(0);
        uint256 epochTs = middleware.getEpochStartTs(startEpoch);
        MockVault(vault).setActiveBalance(staker, 300_000 * 1e18);
        MockVault(vault).setTotalActiveShares(uint48(epochTs), 400_000 * 1e18);

        // Warp to next epoch to allow claiming
        vm.warp((startEpoch + numEpochs + rewards.FUNDING_DEADLINE_OFFSET() + 1) * middleware.EPOCH_DURATION());

        // Test the UX fix: claiming from unfunded epochs should advance pointer and succeed (no revert)
        ERC20Mock unfundedToken = new ERC20Mock();
        
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
        address curator = MockVault(vault).owner();
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
        _setupStakes(fundedEpoch, 4 hours);
        
        // Fund epoch 8
        unfundedToken.mint(REWARDS_DISTRIBUTOR_ROLE, futureRewards);
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        unfundedToken.approve(address(rewards), futureRewards);
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.setRewardsAmountForEpochs(fundedEpoch, 1, address(unfundedToken), futureRewards);
        
        // Distribute intermediate unfunded epoch 7 first (sequential requirement)
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.distributeRewards(7, 10);
        
        // Now distribute the funded epoch 8
        vm.warp((fundedEpoch + rewards.DISTRIBUTION_EARLIEST_OFFSET() + 1) * middleware.EPOCH_DURATION());
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.distributeRewards(fundedEpoch, 10);
        
        // Move to next epoch to allow claiming
        vm.warp((fundedEpoch + 1) * middleware.EPOCH_DURATION());
        
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
        _setupStakes(1, 4 hours);
        _setupStakes(2, 4 hours);

        // Close funding window and distribute epoch 1 completely
        // Current epoch = 1 + FUNDING_DEADLINE_OFFSET + 3, well beyond funding window
        vm.warp((1 + rewards.FUNDING_DEADLINE_OFFSET() + 3) * middleware.EPOCH_DURATION());
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.distributeRewards(1, 10);

        // Start epoch 2 distribution (only first batch)
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.distributeRewards(2, 1);

        // Funding after distribution has started should revert
        uint256 amt = 10_000 * 1e18;
        rewardsToken.mint(REWARDS_DISTRIBUTOR_ROLE, amt);
        vm.startPrank(REWARDS_DISTRIBUTOR_ROLE);
        rewardsToken.approve(address(rewards), amt);
        vm.expectRevert(abi.encodeWithSelector(IRewards.DistributionAlreadyStarted.selector, 2));
        rewards.setRewardsAmountForEpochs(2, 1, address(rewardsToken), amt);
        vm.stopPrank();
    }

    function test_RewardsDistributionDOS_With_UncachedSecondaryAssetClasses() public {
        uint48 epoch = 1;
        uint256 uptime = 4 hours;

        // Setup stakes for operators normally
        _setupStakes(epoch, uptime);

        // Set totalStakeCache to 0 for secondary asset classes to simulate uncached state
        middleware.setTotalStakeCache(epoch, 2, 0); // Secondary asset class 2
        middleware.setTotalStakeCache(epoch, 3, 0); // Secondary asset class 3

        // Keep primary asset class cached (this would be cached by addNode/forceUpdateNodes)
        middleware.setTotalStakeCache(epoch, 1, 100000); // This stays cached

        // Move to epoch where distribution is allowed (must be at least 2 epochs ahead)
        vm.warp((epoch + 3) * middleware.EPOCH_DURATION());

        // With the fix, this should now succeed instead of reverting
        vm.prank(REWARDS_DISTRIBUTOR_ROLE);
        rewards.distributeRewards(epoch, 3);

        // Verify that the stakes were cached on-demand
        assertGt(middleware.totalStakeCache(epoch, 2), 0, "Secondary asset class 2 stake should be cached");
        assertGt(middleware.totalStakeCache(epoch, 3), 0, "Secondary asset class 3 stake should be cached");

        // Verify distribution progressed as expected
        (uint256 lastProcessed, ) = rewards.distributionBatches(epoch);
        assertEq(lastProcessed, 3, "Should have processed 3 operators");
    }

    function test_distributeRewards_andRemoveVault(
        uint256 uptime
    ) public {
        uint48 epoch = 1;
        uptime = bound(uptime, 0, 4 hours);
        address staker = makeAddr("Staker");
        address staker1 = makeAddr("Staker1");
        // Set staker balance in vault
        address vault = vaultManager.vaults(0);
        MockVault(vault).setActiveBalance(staker, 300_000 * 1e18);
        MockVault(vault).setActiveBalance(staker1, 300_000 * 1e18);
        // Set up stakes for operators, nodes, delegators and l1 middleware
        _setupStakes(epoch, uptime);
        vm.warp((epoch + 3) * middleware.EPOCH_DURATION());
        uint256 epochTs = middleware.getEpochStartTs(epoch);
        MockVault(vault).setTotalActiveShares(uint48(epochTs), 400_000 * 1e18);
        // Distribute rewards
        test_distributeRewards(4 hours);
        vm.warp((epoch + 4) * middleware.EPOCH_DURATION());
        uint256 stakerBalanceBefore = rewardsToken.balanceOf(staker);
        vm.prank(staker);
        rewards.claimRewards(address(rewardsToken), staker);
        uint256 stakerBalanceAfter = rewardsToken.balanceOf(staker);
        uint256 stakerRewards = stakerBalanceAfter - stakerBalanceBefore;
        assertGt(stakerRewards, 0, "Staker should receive rewards");
        
        // Properly disable the vault first, wait for grace period, then remove it
        address vaultToRemove = vaultManager.vaults(0);
        uint96 assetClass = vaultManager.getVaultAssetClass(vaultToRemove);
        vaultManager.updateVaultMaxL1Limit(vaultToRemove, assetClass, 0); // Disable vault
        
        vm.expectRevert(abi.encodeWithSelector(IMiddlewareVaultManager.MiddlewareVaultManager__VaultGracePeriodNotPassed.selector));
        vaultManager.removeVault(vaultToRemove);

        // Wait for the vault removal epoch delay to pass
        uint48 epochDuration = middleware.EPOCH_DURATION();
        uint48 epochsToWait = vaultManager.VAULT_REMOVAL_EPOCH_DELAY() + 1;
        vm.warp(block.timestamp + (epochsToWait * epochDuration));
        
        vaultManager.removeVault(vaultToRemove); // Now remove it
        
        uint256 stakerBalanceBefore1 = rewardsToken.balanceOf(staker1);
        vm.prank(staker1);
        rewards.claimRewards(address(rewardsToken), staker1);
        uint256 stakerBalanceAfter1 = rewardsToken.balanceOf(staker1);
        uint256 stakerRewards1 = stakerBalanceAfter1 - stakerBalanceBefore1;
        assertEq(stakerRewards1, 0, "Now staker should have 0 rewards");
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
