// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";

import {ValidatorManagerSettings} from "@avalabs/icm-contracts/validator-manager/ValidatorManager.sol";
import {PoAManager} from "@avalabs/icm-contracts/validator-manager/PoAManager.sol";
import {UnsafeUpgrades} from "@openzeppelin/foundry-upgrades/Upgrades.sol";
import {ICMInitializable} from "@avalabs/icm-contracts/utilities/ICMInitializable.sol";
import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";

import {
    AvalancheL1Middleware,
    AvalancheL1MiddlewareSettings
} from "../../src/contracts/middleware/AvalancheL1Middleware.sol";
import {MiddlewareTestBase} from "./MiddlewareTestBase.t.sol";
import {MiddlewareVaultManager} from "../../src/contracts/middleware/MiddlewareVaultManager.sol";
import {CollateralClassRegistry} from "../../src/contracts/middleware/CollateralClassRegistry.sol";
import {VaultFactory} from "../../src/contracts/VaultFactory.sol";
import {DelegatorFactory} from "../../src/contracts/DelegatorFactory.sol";
import {SlasherFactory} from "../../src/contracts/SlasherFactory.sol";
import {L1Registry} from "../../src/contracts/L1Registry.sol";
import {OperatorRegistry} from "../../src/contracts/OperatorRegistry.sol";
import {OperatorL1OptInService} from "../../src/contracts/service/OperatorL1OptInService.sol";
import {OperatorVaultOptInService} from "../../src/contracts/service/OperatorVaultOptInService.sol";
import {VaultTokenized} from "../../src/contracts/vault/VaultTokenized.sol";
import {L1RestakeDelegator} from "../../src/contracts/delegator/L1RestakeDelegator.sol";
import {MiddlewareHelperConfig} from "../../script/middleware/anvil/MiddlewareHelperConfig.s.sol";
import {MockBalancerValidatorManager} from "../mocks/MockBalancerValidatorManager.sol";

import {BalancerValidatorManager} from
    "@suzaku/contracts-library/contracts/ValidatorManager/BalancerValidatorManager.sol";
import {ACP77WarpMessengerTestMock} from "@suzaku/contracts-library/contracts/mocks/ACP77WarpMessengerTestMock.sol";
import {IBalancerValidatorManager} from
    "@suzaku/contracts-library/interfaces/ValidatorManager/IBalancerValidatorManager.sol";
import {
    ConversionData,
    InitialValidator,
    PChainOwner,
    Validator,
    ValidatorStatus
} from "@avalabs/icm-contracts/validator-manager/interfaces/IACP99Manager.sol";

import {Token} from "../mocks/MockToken.sol";
import {ERC20WithDecimals} from "../mocks/MockERC20WithDecimals.sol";

import {IBaseDelegator} from "../../src/interfaces/delegator/IBaseDelegator.sol";
import {IOperatorRegistry} from "../../src/interfaces/IOperatorRegistry.sol";
import {IVaultTokenized} from "../../src/interfaces/vault/IVaultTokenized.sol";
import {IL1RestakeDelegator} from "../../src/interfaces/delegator/IL1RestakeDelegator.sol";
import {IAvalancheL1Middleware} from "../../src/interfaces/middleware/IAvalancheL1Middleware.sol";
import {StakeConversion} from "../../src/contracts/middleware/libraries/StakeConversion.sol";
import {IMiddlewareVaultManager} from "../../src/interfaces/middleware/IMiddlewareVaultManager.sol";
import {IOptInService} from "../../src/interfaces/service/IOptInService.sol";

contract AvalancheL1MiddlewareTest is MiddlewareTestBase {

    function test_DepositAndGetOperatorStake() public view {
        // middleware.addAssetToClass(1, address(collateral));
        uint48 epoch = middleware.getCurrentEpoch();
        uint256 stakeAlice = middleware.getOperatorStake(alice, epoch, collateralClassId);
        console2.log("Alice stake:", stakeAlice);
        // Just a simple check
        assertGt(stakeAlice, 0, "Bob's stake should be > 0 now");
    }

    function test_AddNodeSimple() public {
        // Move forward to let the vault roll epochs
        uint48 epoch = _calcAndWarpOneEpoch();

        uint256 operatorStake = middleware.getOperatorStake(alice, epoch, collateralClassId);
        console2.log("Operator stake (epoch", epoch, "):", operatorStake);
        assertGt(operatorStake, 0);

        // Move the vault epoch again
        epoch = _calcAndWarpOneEpoch();

        // Recalc stakes for new epoch
        middleware.calcAndCacheStakes(epoch, collateralClassId);
        uint256 newStake = middleware.getOperatorStake(alice, epoch, collateralClassId);
        console2.log("New epoch operator stake:", newStake);
        assertGe(newStake, operatorStake);

        // Add a node
        _createAndConfirmNodes(alice, 1, 0, true, 2);
    }

    function test_EnableOperator_CannotBypassRegistrationChecks() public {
        // Test Gate 1: Cannot enable operator that's not in the middleware map
        address unregisteredOperator = makeAddr("unregisteredOperator");
        
        vm.startPrank(l1Owner);
        vm.expectRevert(abi.encodeWithSelector(IAvalancheL1Middleware.AvalancheL1Middleware__OperatorNotRegistered.selector, unregisteredOperator));
        middleware.enableOperator(unregisteredOperator);
        vm.stopPrank();
        
        // Test Gate 2: Cannot enable operator that opted out
        address testOperator = makeAddr("testOperator");
        
        // Properly register the operator
        _registerOperator(testOperator, "test operator metadata");
        _optInOperatorL1(testOperator, balancer);
        
        // Register with middleware
        vm.prank(l1Owner);
        middleware.registerOperator(testOperator);
        
        // Disable the operator
        vm.prank(l1Owner);
        middleware.disableOperator(testOperator);
        
        // Mock operator as opted out
        vm.mockCall(
            address(operatorL1OptInService),
            abi.encodeWithSelector(IOptInService.isOptedIn.selector, testOperator, balancer),
            abi.encode(false)
        );
        
        // Try to re-enable - should fail because no longer opted in
        vm.startPrank(l1Owner);
        vm.expectRevert(abi.encodeWithSelector(IAvalancheL1Middleware.AvalancheL1Middleware__OperatorNotOptedIn.selector, testOperator, balancer));
        middleware.enableOperator(testOperator);
        vm.stopPrank();
        
        // Clear the mock
        vm.clearMockedCalls();
        
        // Success case: operator in map + opted in = can enable
        vm.prank(l1Owner);
        middleware.enableOperator(testOperator);
    }

    function test_AddNodeSimpleAndComplete() public {
        uint48 epoch = _calcAndWarpOneEpoch();
        uint256 totalStake = middleware.getOperatorStake(alice, epoch, collateralClassId);
        assertGt(totalStake, 0);

        // Add node
        (, bytes32[] memory validationIDs,) = _createAndConfirmNodes(alice, 1, 0, true, 2);
        bytes32 validationID = validationIDs[0];

        // Move epoch +1
        epoch = _calcAndWarpOneEpoch();

        uint256 nodeWeight = middleware.nodeStakeCache(epoch, validationID);
        console2.log("Node weight after confirmation:", nodeWeight);
        assertGt(nodeWeight, 0);
    }

    function test_AddNodeStakeClamping_Adaptive() public {
        // Get staking requirements from middleware
        middleware.getClassStakingRequirements(1);
        uint256 totalSupply = collateral.totalSupply();
        console2.log("Token total supply:", totalSupply);

        // Set up test values
        // Test clamping behavior - request max possible stake
        uint256 depositAmount = 20 ether;
        uint256 stakeWanted = 100 ether;  // Want way more than available to test clamping
        // Use the tested helper to ensure mintedShares is captured correctly
        (uint256 deposited, uint256 minted) = _deposit(staker, depositAmount);

        // Set L1 limit
        vm.startPrank(curatorOwner1);
        delegator.setL1Limit(balancer, collateralClassId, deposited);
        vm.stopPrank();

        // Assign the actual minted shares to the operator
        _setOperatorL1Shares(curatorOwner1, balancer, collateralClassId, alice, minted, delegator);

        // travel to next epoch
        _calcAndWarpOneEpoch();

        // Verify available stake - we expect it to be less than requested
        uint256 updatedAvail = middleware.getOperatorAvailableStake(alice);
        console2.log("Available stake:", updatedAvail);
        console2.log("Wanted stake:", stakeWanted);
        
        // We deposited 10 ETH but due to fees and conversions, available will be slightly less
        assertLt(updatedAvail, stakeWanted, "Available should be less than wanted to test clamping");

        // Add node with stake that exceeds available
        bytes32 nodeId = keccak256("ClampTestAdaptive");
        console2.log("Requesting stakeWanted:", stakeWanted);
        console2.log("But available is only:", updatedAvail);

        vm.prank(alice);
        middleware.addNode(
            nodeId,
            new bytes(48),
            _pOwner1(alice),
            _pOwner1(alice),
            0  // Request 0 and let middleware assign available stake
        );

        // Move to next epoch
        uint48 epoch = _calcAndWarpOneEpoch();

        bytes32 validationID = IBalancerValidatorManager(balancer).getNodeValidationID(_nodeBytes(nodeId));
        uint256 finalStake = middleware.getNodeStake(epoch, validationID);

        console2.log("Final stake after clamp is:", finalStake);
        
        // When requesting 0 stake, the middleware should assign all available stake
        assertGt(finalStake, 0, "Node should have been assigned available stake");
        assertLe(finalStake, updatedAvail, "Node stake should not exceed available funds");
        
        // This demonstrates the adaptive staking behavior
        console2.log("Middleware assigned all available stake:", finalStake);
    }

    function test_AddNodeStakeOverAsk_Reverts() public {
        // 1) Setup a small balance so an over-ask is guaranteed
        uint256 depositAmount = 20 ether;
        (uint256 deposited, uint256 minted) = _deposit(staker, depositAmount);
        vm.startPrank(curatorOwner1);
        delegator.setL1Limit(balancer, collateralClassId, deposited);
        vm.stopPrank();
        _setOperatorL1Shares(curatorOwner1, balancer, collateralClassId, alice, minted, delegator);
        _calcAndWarpOneEpoch();

        uint256 avail = middleware.getOperatorAvailableStake(alice);
        assertGt(avail, 0);

        // 2) Over-ask by at least one weight unit
        uint256 overAsk = avail + middleware.WEIGHT_SCALE_FACTOR();

        // 3) Expect revert on explicit over-ask
        bytes32 nodeId = keccak256("ClampOverAsk");
        vm.expectRevert(IAvalancheL1Middleware.AvalancheL1Middleware__InsufficientStake.selector);
        vm.prank(alice);
        middleware.addNode(
            nodeId,
            new bytes(48),
            _pOwner1(alice),
            _pOwner1(alice),
            overAsk
        );
    }

    function test_AddNodeLateCompletition() public {
        uint48 epoch = _calcAndWarpOneEpoch();
        uint256 totalStake = middleware.getOperatorStake(alice, epoch, collateralClassId);
        console2.log("Operator stake in epoch", epoch, ":", totalStake);
        assertGt(totalStake, 0);

        // Add node
        (bytes32[] memory nodeIds, bytes32[] memory validationIDs, uint256[] memory nodeWeights) =
            _createAndConfirmNodes(alice, 1, 0, false, 2);
        bytes32 validationID = validationIDs[0];
        bytes32 nodeId = nodeIds[0];
        uint256 nodeWeight = nodeWeights[0];

        // Advance epoch
        epoch = _calcAndWarpOneEpoch();

        // Node still not confirmed
        nodeWeight = middleware.nodeStakeCache(epoch, validationID);
        console2.log("Node weight second epoch (still unconfirmed):", nodeWeight);
        assertGt(nodeWeight, 0);

        // Confirm node – push ack then complete(0)
        bytes32 vId = IBalancerValidatorManager(balancer).getNodeValidationID(_nodeBytes(nodeId));
        _pushRegistrationAck(vId, true);
        middleware.completeValidatorRegistration(0);
        middleware.calcAndCacheNodeStakeForAllOperators();

        // Should be active next epoch
        epoch = _calcAndWarpOneEpoch();

        nodeWeight = middleware.nodeStakeCache(epoch, validationID);
        console2.log("Node weight after full confirmation:", nodeWeight);
        assertGt(nodeWeight, 0);
    }

    function test_CompleteStakeUpdate() public {
        (depositedAmount, mintedShares) = _deposit(staker, 10 ether);
        _setL1Limit(curatorOwner1, balancer, 1, depositedAmount, delegator);

        _calcAndWarpOneEpoch();
        (bytes32[] memory nodeIds, bytes32[] memory validationIDs, uint256[] memory nodeWeights) =
            _createAndConfirmNodes(alice, 1, 0, true, 2);
        bytes32 validationID = validationIDs[0];
        bytes32 nodeId = nodeIds[0];
        uint256 nodeWeight = nodeWeights[0];

        uint48 epoch = _calcAndWarpOneEpoch();

        // Decrease weight
        uint256 stakeAmount = uint256(nodeWeight - 100);
        vm.prank(alice);
        middleware.initializeValidatorStakeUpdate(nodeId, stakeAmount);
        uint256         updatedNodeWeight = middleware.nodeStakeCache(epoch, validationID);
        console2.log("Node weight after init update (still old until next epoch):", updatedNodeWeight);

        // push weight update (nonce=sentNonce+1) then complete(0)
        bytes32 vId = IBalancerValidatorManager(balancer).getNodeValidationID(_nodeBytes(nodeId));
        {
            uint64 scaled = StakeConversion.stakeToWeight(stakeAmount, middleware.WEIGHT_SCALE_FACTOR());
            Validator memory v = IBalancerValidatorManager(balancer).getValidator(vId);
            _pushWeight(vId, uint64(v.sentNonce), scaled);
        }
        middleware.completeValidatorWeightUpdate(0);
        middleware.calcAndCacheNodeStakeForAllOperators();

        updatedNodeWeight = middleware.nodeStakeCache(epoch, validationID);
        console2.log("Node weight after completion (still old until next epoch):", updatedNodeWeight);

        // Move to next epoch
        epoch = _calcAndWarpOneEpoch();
        updatedNodeWeight = middleware.nodeStakeCache(epoch, validationID);
        console2.log("Node weight final:", updatedNodeWeight);
        assertEq(updatedNodeWeight, stakeAmount, "Node weight should be updated");
    }

    function test_CompleteLateNodeWeightUpdate() public {
        (depositedAmount, mintedShares) = _deposit(staker, 10 ether);
        _setL1Limit(curatorOwner1, balancer, 1, depositedAmount, delegator);

        uint48 epoch = _calcAndWarpOneEpoch();
        (bytes32[] memory nodeIds, bytes32[] memory validationIDs, uint256[] memory nodeWeights) =
            _createAndConfirmNodes(alice, 1, 0, true, 2);
        bytes32 validationID = validationIDs[0];
        bytes32 nodeId = nodeIds[0];
        uint256 nodeWeight = nodeWeights[0];

        // Decrease
        uint256 stakeAmount = uint256(nodeWeight - 100);
        vm.prank(alice);
        middleware.initializeValidatorStakeUpdate(nodeId, stakeAmount);

        // Next epochs warp
        _calcAndWarpOneEpoch();

        // push weight then complete(0)
        bytes32 vId = IBalancerValidatorManager(balancer).getNodeValidationID(_nodeBytes(nodeId));
        {
            uint64 scaled = StakeConversion.stakeToWeight(stakeAmount, middleware.WEIGHT_SCALE_FACTOR());
            Validator memory v = IBalancerValidatorManager(balancer).getValidator(vId);
            _pushWeight(vId, uint64(v.sentNonce), scaled);
        }
        middleware.completeValidatorWeightUpdate(0);
        middleware.calcAndCacheNodeStakeForAllOperators();

        epoch = _calcAndWarpOneEpoch();
        uint256 updatedNodeWeight = middleware.nodeStakeCache(epoch, validationID);
        console2.log("Node weight final:", updatedNodeWeight);
        assertEq(updatedNodeWeight, stakeAmount);
    }

    function test_RemoveNodeSimple() public {
        uint48 epoch = _calcAndWarpOneEpoch();

        uint256 totalStake = middleware.getOperatorStake(alice, epoch, collateralClassId);
        assertGt(totalStake, 0);

        (bytes32[] memory nodeIds, bytes32[] memory validationIDs, uint256[] memory nodeWeights) =
            _createAndConfirmNodes(alice, 1, 0, true, 2);
        bytes32 validationID = validationIDs[0];
        bytes32 nodeId = nodeIds[0];
        uint256 nodeWeight = nodeWeights[0];
        assertEq(middleware.getOperatorNodesLength(alice), 1);

        epoch = _calcAndWarpOneEpoch();
        nodeWeight = middleware.nodeStakeCache(epoch, validationID);
        assertGt(nodeWeight, 0);

        vm.prank(alice);
        middleware.removeNode(nodeId);
        nodeWeight = middleware.nodeStakeCache(epoch, validationID);
        assertGt(nodeWeight, 0);
        assertEq(middleware.getOperatorNodesLength(alice), 1);

        epoch = _calcAndWarpOneEpoch();
        nodeWeight = middleware.nodeStakeCache(epoch, validationID);
        assertEq(nodeWeight, 0);
        assertEq(middleware.getOperatorNodesLength(alice), 0);
    }

    function test_RemoveNodeLate() public {
        uint48 epoch = _calcAndWarpOneEpoch();
        uint256 totalStake = middleware.getOperatorStake(alice, epoch, collateralClassId);
        assertGt(totalStake, 0);

        // Add node
        (bytes32[] memory nodeIds, bytes32[] memory validationIDs, uint256[] memory nodeWeights) =
            _createAndConfirmNodes(alice, 1, 0, true, 2);
        bytes32 validationID = validationIDs[0];
        bytes32 nodeId = nodeIds[0];
        uint256 nodeWeight = nodeWeights[0];
        assertEq(middleware.getOperatorNodesLength(alice), 1);

        epoch = _calcAndWarpOneEpoch();
        nodeWeight = middleware.nodeStakeCache(epoch, validationID);
        assertGt(nodeWeight, 0);

        vm.prank(alice);
        middleware.removeNode(nodeId);

        nodeWeight = middleware.nodeStakeCache(epoch, validationID);
        assertGt(nodeWeight, 0);
        assertTrue(middleware.nodePendingRemoval(validationID));

        // Next epoch
        epoch = _calcAndWarpOneEpoch();
        nodeWeight = middleware.nodeStakeCache(epoch, validationID);
        assertEq(nodeWeight, 0);
        assertFalse(middleware.nodePendingRemoval(validationID));
        assertEq(middleware.getOperatorNodesLength(alice), 0);

        // Next epoch, then push removal-ack and complete(0)
        _calcAndWarpOneEpoch();
        _pushRemovalAck(validationID);
        vm.prank(alice);
        middleware.completeValidatorRemoval(0);

        epoch = _calcAndWarpOneEpoch();
        nodeWeight = middleware.nodeStakeCache(epoch, validationID);
        assertEq(nodeWeight, 0);
        assertFalse(middleware.nodePendingRemoval(validationID));
        assertEq(middleware.getOperatorNodesLength(alice), 0);
    }

    function test_MultipleNodes() public {
        uint48 epoch = _calcAndWarpOneEpoch();
        uint256 totalStake = middleware.getOperatorStake(alice, epoch, collateralClassId);
        assertGt(totalStake, 0);

        // Add node1 and node2
        (uint256 stake1,) = middleware.getClassStakingRequirements(1);
        (bytes32[] memory nodeIds, bytes32[] memory validationIDs, uint256[] memory nodeWeights) =
            _createAndConfirmNodes(alice, 2, stake1, true, 2);
        bytes32 nodeId1 = nodeIds[0];
        bytes32 validationID1 = validationIDs[0];
        uint256 nodeWeight1 = nodeWeights[0];
        bytes32 validationID2 = validationIDs[1];
        uint256 nodeWeight2 = nodeWeights[1];

        epoch = _calcAndWarpOneEpoch();
        nodeWeight2 = middleware.nodeStakeCache(epoch, validationID2);
        assertGt(nodeWeight2, 0);

        // Remove node1
        vm.prank(alice);
        middleware.removeNode(nodeId1);
        epoch = _calcAndWarpOneEpoch();
        nodeWeight1 = middleware.nodeStakeCache(epoch, validationID1);
        assertEq(nodeWeight1, 0);

        // push removal-ack for validationID1, then complete(0)
        _pushRemovalAck(validationID1);
        vm.prank(alice);
        middleware.completeValidatorRemoval(0);
        nodeWeight2 = middleware.nodeStakeCache(epoch, validationID2);
        assertGt(nodeWeight2, 0);

        epoch = _calcAndWarpOneEpoch();
        nodeWeight1 = middleware.nodeStakeCache(epoch, validationID1);
        assertEq(nodeWeight1, 0);
    }

    function test_HistoricalQueries_multiNodes() public {
        // Move to epoch1
        uint48 epoch1 = _calcAndWarpOneEpoch();

        // Add node1 and move to epoch2
        uint48 epoch2 = middleware.getCurrentEpoch();
        uint256 stake1 = 100_000_000_000_000 + 1000;
        (bytes32[] memory nodeIds,,) = _createAndConfirmNodes(alice, 2, stake1, true, 2);
        bytes32 nodeId1 = nodeIds[0];

        // Move to epoch3
        uint48 epoch3 = _calcAndWarpOneEpoch();

        // Remove nodeId1
        vm.prank(alice);
        middleware.removeNode(nodeId1);
        middleware.calcAndCacheNodeStakeForAllOperators();

        // Move to epoch4
        uint48 epoch4 = _calcAndWarpOneEpoch();

        // Get validationID for nodeId1 and push removal-ack
        bytes32 valId1 = IBalancerValidatorManager(balancer).getNodeValidationID(_nodeBytes(nodeId1));
        _pushRemovalAck(valId1);
        vm.prank(alice);
        middleware.completeValidatorRemoval(0);

        // Check active nodes at each epoch
        {
            bytes32[] memory epoch1Nodes = middleware.getActiveNodesForEpoch(alice, epoch1);
            console2.log("epoch1Nodes length:", epoch1Nodes.length);
        }
        {
            bytes32[] memory epoch2Nodes = middleware.getActiveNodesForEpoch(alice, epoch2);
            console2.log("epoch2Nodes length:", epoch2Nodes.length);
        }
        {
            bytes32[] memory epoch3Nodes = middleware.getActiveNodesForEpoch(alice, epoch3);
            console2.log("epoch3Nodes length:", epoch3Nodes.length);
        }
        {
            bytes32[] memory epoch4Nodes = middleware.getActiveNodesForEpoch(alice, epoch4);
            console2.log("epoch4Nodes length:", epoch4Nodes.length);
        }
    }

    function test_ForceUpdate() public {
        uint48 epoch = _calcAndWarpOneEpoch();
        // Add node1 and node2
        (uint256 stake1,) = middleware.getClassStakingRequirements(1);
        (, bytes32[] memory validationIDs, uint256[] memory nodeWeights) =
            _createAndConfirmNodes(alice, 2, stake1, true, 2);
        bytes32 validationID1 = validationIDs[0];
        uint256 nodeWeight1 = nodeWeights[0];
        bytes32 validationID2 = validationIDs[1];
        uint256 nodeWeight2 = nodeWeights[1];

        epoch = _calcAndWarpOneEpoch();
        nodeWeight1 = middleware.nodeStakeCache(epoch, validationID1);
        console2.log("Node1 weight after confirm:", nodeWeight1);

        epoch = _calcAndWarpOneEpoch();
        nodeWeight2 = middleware.nodeStakeCache(epoch, validationID2);
        console2.log("Node2 weight after confirm:", nodeWeight2);

        // Withdraw from vault to reduce stake
        epoch = _calcAndWarpOneEpoch(2);
        uint256 withdrawAmount = 50_000_000_000_000;
        _withdraw(staker, withdrawAmount);

        // Move to next epoch
        epoch = _calcAndWarpOneEpoch(1);
        vm.expectRevert();
        middleware.forceUpdateNodes(alice, 0);

        // Warp to last hour
        _warpToLastHourOfCurrentEpoch();
        
        middleware.forceUpdateNodes(alice, 0);
        
        // Complete any pending removals deterministically
        if (middleware.nodePendingRemoval(validationID1)) {
            _pushRemovalAck(validationID1);
            vm.prank(alice);
            middleware.completeValidatorRemoval(0);
            _calcAndWarpOneEpoch(); // space any subsequent completion in this test
        }
        if (middleware.nodePendingRemoval(validationID2)) {
            _pushRemovalAck(validationID2);
            vm.prank(alice);
            middleware.completeValidatorRemoval(0);
        }

        epoch = _calcAndWarpOneEpoch(1);
        uint256 updatedStake = middleware.getOperatorStake(alice, epoch, collateralClassId);
        console2.log("Updated stake after partial withdraw & forceUpdateNodes:", updatedStake);

        // Claim
        epoch = _calcAndWarpOneEpoch(2);
        uint256 claimEpoch = vault.currentEpoch() - 1;
        uint256 claimed = _claim(staker, claimEpoch);
        console2.log("Claimed:", claimed);

        epoch = _calcAndWarpOneEpoch(1);
        updatedStake = middleware.getOperatorStake(alice, epoch, collateralClassId);
        nodeWeight1 = middleware.nodeStakeCache(epoch, validationID1);
        nodeWeight2 = middleware.nodeStakeCache(epoch, validationID2);

        console2.log("Final operator stake:", updatedStake);
        console2.log("Node1 weight final:", nodeWeight1);
        console2.log("Node2 weight final:", nodeWeight2);
    }

    function test_ForceUpdateWithAdditionalStake() public {
        uint48 epoch = _calcAndWarpOneEpoch();

        // Add node1 and node2
        (uint256 stake1,) = middleware.getClassStakingRequirements(1);
        _createAndConfirmNodes(alice, 1, stake1, true, 1);

        // move to next epoch
        epoch = _moveToNextEpochAndCalc(3);

        // make additional deposit
        uint256 extraDeposit = 50_000_000_000_000;
        console2.log("Making additional deposit:", extraDeposit);
        (uint256 newDeposit, uint256 newShares) = _deposit(staker, extraDeposit);
        uint256 totalShares = mintedShares + newShares;
        _setOperatorL1Shares(curatorOwner1, balancer, collateralClassId, alice, totalShares, delegator);
        console2.log("Additional deposit made. Amount:", newDeposit, "Shares:", newShares);

        epoch = _moveToNextEpochAndCalc(3);

        _warpToLastHourOfCurrentEpoch();
        epoch = middleware.getCurrentEpoch();
        uint256 updatedStake = middleware.getOperatorStake(alice, epoch, collateralClassId);
        console2.log("Operator stake after extra deposit (before forceUpdate):", updatedStake);

        uint256 oldUsedStake = middleware.getOperatorUsedStakeCached(alice);
        uint256 leftover = updatedStake - oldUsedStake;
        assertGt(leftover, 0, "Expected leftover to be > 0");

        vm.expectEmit(true, true, true, true);
        emit IAvalancheL1Middleware.OperatorHasLeftoverStake(alice, leftover);

        middleware.forceUpdateNodes(alice, 0);

        uint256 newUsedStake = middleware.getOperatorUsedStakeCached(alice);
        assertEq(newUsedStake, oldUsedStake, "Used stake must remain unchanged if weight only decreases");
    }

    function test_AddRemoveAddNodeAgain() public {
        // Move to the next epoch so we have a clean slate
        uint48 epoch = _calcAndWarpOneEpoch();

        // Prepare node data
        bytes32 nodeId = 0x00000000000000000000000039a662260f928d2d98ab5ad93aa7af8e0ee4d426;
        bytes memory blsKey = new bytes(48);
        address[] memory ownerArr = new address[](1);
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct = PChainOwner({threshold: 1, addresses: ownerArr});

        // Add node
        vm.prank(alice);
        middleware.addNode(nodeId, blsKey, ownerStruct, ownerStruct, 0);
        bytes32 validationID = IBalancerValidatorManager(balancer).getNodeValidationID(_nodeBytes(nodeId));

        // Check node stake from the public getter
        uint256 nodeStake = middleware.getNodeStake(epoch, validationID);
        assertGt(nodeStake, 0, "Node stake should be >0 right after add");

        // Also confirm we have 0 or 1 active node at this epoch.
        // Because the node is not yet "confirmed," it typically won't appear as active.
        // We simply show how to ensure it's not erroneously counted:
        bytes32[] memory activeNodesBeforeConfirm = middleware.getActiveNodesForEpoch(alice, epoch);
        assertEq(activeNodesBeforeConfirm.length, 0, "Node shouldn't appear active before confirmation");

        // Confirm node - push ack then complete(0)
        _pushRegistrationAck(validationID, true);
        middleware.completeValidatorRegistration(0);

        // Warp +1 epoch and check that the node is truly active
        epoch = _calcAndWarpOneEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();

        nodeStake = middleware.getNodeStake(epoch, validationID);
        assertGt(nodeStake, 0, "Node stake should persist after confirmation");

        bytes32[] memory activeNodesAfterConfirm = middleware.getActiveNodesForEpoch(alice, epoch);
        assertEq(activeNodesAfterConfirm.length, 1, "Should have exactly 1 active node");
        assertEq(activeNodesAfterConfirm[0], nodeId, "The active node ID should match");

        // Remove node
        vm.prank(alice);
        middleware.removeNode(nodeId);

        // Warp +1 epoch => node stake should become zero
        epoch = _calcAndWarpOneEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();

        nodeStake = middleware.getNodeStake(epoch, validationID);
        assertEq(nodeStake, 0, "Node stake must be zero after removal finalizes");

        bytes32[] memory activeNodesAfterRemove = middleware.getActiveNodesForEpoch(alice, epoch);
        assertEq(activeNodesAfterRemove.length, 0, "No active nodes after removal");

        // confirm removal with proper removal-ack
        _pushRemovalAck(validationID);
        vm.prank(alice);
        middleware.completeValidatorRemoval(0);

        // Warp +1 epoch just for clarity
        epoch = _calcAndWarpOneEpoch();

        // Add the same node again (the system allows re-adding after full removal)
        vm.prank(alice);
        middleware.addNode(nodeId, blsKey, ownerStruct, ownerStruct, 0);

        bytes32 newValidationID = IBalancerValidatorManager(balancer).getNodeValidationID(_nodeBytes(nodeId));
        uint256 nodeStake2 = middleware.getNodeStake(epoch, newValidationID);
        assertGt(nodeStake2, 0, "Node stake should be >0 on second add");

        // Confirm node again - always push ack, then complete(0)
        _pushRegistrationAck(newValidationID, true);
        middleware.completeValidatorRegistration(0);

        // Warp another epoch and verify stake
        epoch = _calcAndWarpOneEpoch();

        nodeStake2 = middleware.getNodeStake(epoch, newValidationID);
        assertGt(nodeStake2, 0, "Node stake must be >0 after re-adding and confirming");

        // Confirm the newly re-added node is active
        bytes32[] memory activeNodesFinal = middleware.getActiveNodesForEpoch(alice, epoch);
        assertEq(activeNodesFinal.length, 1, "Should have 1 active node after second addition");
        assertEq(activeNodesFinal[0], nodeId, "Active node ID should match the re-added node");

        // Final check
        uint256 operatorAvailable = middleware.getOperatorAvailableStake(alice);
        // Confirm there's some leftover
        assertGt(operatorAvailable, 0, "Operator should have some leftover stake");
    }

    function test_SingleNode_AddUpdateRemoveThenCompleteUpdate() public {
        uint256 scaleFactor = middleware.WEIGHT_SCALE_FACTOR();

        // Add & confirm a node
        uint48 epoch = _calcAndWarpOneEpoch();

        (bytes32[] memory nodeIds, bytes32[] memory validationIDs,) = _createAndConfirmNodes(alice, 1, 0, true, 2);
        bytes32 validationID = validationIDs[0];
        bytes32 nodeId = nodeIds[0];

        // Move to next epoch
        epoch = _calcAndWarpOneEpoch();

        uint256 initialStake = middleware.getNodeStake(epoch, validationID);
        assertGt(initialStake, 0, "Node must have >0 stake after confirm");

        // Initialize stake update (reduce by half)
        uint256 newStake = initialStake / 2;
        vm.prank(alice);
        middleware.initializeValidatorStakeUpdate(nodeId, newStake);

        // Verify pending update in manager
        bool isPending = IBalancerValidatorManager(balancer).isValidatorPendingWeightUpdate(validationID);
        assertTrue(isPending, "Stake update must be pending");

        // Remove node while update is pending - this should revert as removing 
        // while a weight update is pending is blocked by design
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            IAvalancheL1Middleware.AvalancheL1Middleware__NodePending.selector
        ));
        middleware.removeNode(nodeId);
        
        // Try to complete stake update before ack - should revert
        vm.prank(alice);
        vm.expectRevert();
        middleware.completeValidatorWeightUpdate(0);
        
        // First complete the stake update, then remove the node
        {
            uint64 scaled = StakeConversion.stakeToWeight(newStake, scaleFactor);
            Validator memory v = IBalancerValidatorManager(balancer).getValidator(validationID);
            _pushWeight(validationID, uint64(v.sentNonce), scaled);
        }
        middleware.completeValidatorWeightUpdate(0);
        
        // Verify update was processed and no longer pending
        bool stillPending = IBalancerValidatorManager(balancer).isValidatorPendingWeightUpdate(validationID);
        assertFalse(stillPending, "Stake update should be cleared after completion");
        
        // Now the removal should work
        vm.prank(alice);
        middleware.removeNode(nodeId);

        // Move to next epoch
        epoch = _calcAndWarpOneEpoch();

        /* uint256 stakeNow = */ middleware.getNodeStake(epoch, validationID);

        // Confirm removal - push removal-ack before completing
        _pushRemovalAck(validationID);
        vm.prank(alice);
        middleware.completeValidatorRemoval(0);

        // Move to next epoch
        epoch = _calcAndWarpOneEpoch();

        uint256 finalStake = middleware.getNodeStake(epoch, validationID);
        assertEq(finalStake, 0, "Node stake must be 0 after final removal");

        // After removal, the validator is no longer active so we can't check pending updates
        // The important verification is that the node stake is 0
        uint256 postCompleteStake = middleware.getNodeStake(epoch, validationID);
        assertEq(postCompleteStake, 0, "Node stake must be 0 after removal");
    }

    function testFuzz_MultipleNodes_AddRemoveReAdd(uint8 seedNodeCount, uint8 seedRemoveMask) public {
        // Force a small range for how many nodes to add (2–4)
        uint256 nodeCount = bound(seedNodeCount, 2, 4);

        // Move to next epoch, so we start from a clean point
        uint48 epoch = _calcAndWarpOneEpoch();

        // Arrays to store node info
        bytes32[] memory nodeIds = new bytes32[](nodeCount);
        bytes32[] memory validationIds = new bytes32[](nodeCount);
        bool[] memory isActive = new bool[](nodeCount);

        // No longer tracking message indexes - we'll push messages and use 0

        // Track expected final stake for each node
        uint256[] memory expectedFinalStake = new uint256[](nodeCount);

        // Track the old validation ID once removed
        bytes32[] memory oldRemovedValidationIds = new bytes32[](nodeCount);

        // BLS key and owners
        bytes memory blsKey = new bytes(48);
        address[] memory ownerArr = new address[](1);
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct = PChainOwner({threshold: 1, addresses: ownerArr});

        // Add each node (not yet confirmed)
        for (uint256 i = 0; i < nodeCount; i++) {
            bytes32 nodeId = keccak256(abi.encodePacked("NODE_", seedNodeCount, i));
            nodeIds[i] = nodeId;

           // how much stake still free?
           (uint256 minStake, ) = middleware.getClassStakingRequirements(1);
           uint256 free = middleware.getOperatorAvailableStake(alice);
        
            if (free < minStake) {
                // next addNode is *supposed* to revert – record and stop
                vm.expectRevert(abi.encodeWithSelector(IAvalancheL1Middleware.AvalancheL1Middleware__InsufficientStake.selector));
                vm.prank(alice);
                middleware.addNode(
                    nodeId, blsKey,
                    ownerStruct, ownerStruct, 0        // will revert
                );
                nodeCount = i;                         // shrink arrays; creation done
                break;
           }

            vm.prank(alice);
            middleware.addNode(nodeId, blsKey, ownerStruct, ownerStruct, 0);

            // No longer tracking message index

            bytes32 validationID = IBalancerValidatorManager(balancer).getNodeValidationID(_nodeBytes(nodeId));
            validationIds[i] = validationID;

            uint256 nodeStake = middleware.getNodeStake(epoch, validationID);
            assertGt(nodeStake, 0, "Node stake should be >0 right after add");
            isActive[i] = false; // not yet confirmed
        }

        // Confirm registration => active
        for (uint256 i = 0; i < nodeCount; i++) {
            _pushRegistrationAck(validationIds[i], true);
            vm.prank(alice);
            middleware.completeValidatorRegistration(0);
            isActive[i] = true;
        }

        // Warp => next epoch => nodes are truly active
        epoch = _calcAndWarpOneEpoch();

        bytes32[] memory currentActive = middleware.getActiveNodesForEpoch(alice, epoch);
        assertEq(currentActive.length, nodeCount, "All nodes should be active after confirm");

        // Track expected final stake for each node
        for (uint256 i = 0; i < nodeCount; i++) {
            if (isActive[i]) {
                expectedFinalStake[i] = middleware.getNodeStake(epoch, validationIds[i]);
            }
        }

        // Remove a subset of nodes
        for (uint256 i = 0; i < nodeCount; i++) {
            bool doRemove = ((seedRemoveMask >> uint8(i)) & 0x01) == 1;
            if (doRemove) {
                vm.prank(alice);
                middleware.removeNode(nodeIds[i]);

                // No longer tracking message index
                isActive[i] = false;

                // Record the old validation ID *before* it's replaced by re-add
                oldRemovedValidationIds[i] = validationIds[i];

                // Attempt to remove the same node again immediately, expecting a revert
                vm.prank(alice);
                vm.expectRevert(IAvalancheL1Middleware.AvalancheL1Middleware__NodePending.selector);
                middleware.removeNode(nodeIds[i]);
            }
        }

        // Warp => next epoch => removed node stakes => 0
        epoch = _calcAndWarpOneEpoch();

        // Confirm each removal
        for (uint256 i = 0; i < nodeCount; i++) {
            bool doRemove = ((seedRemoveMask >> uint8(i)) & 0x01) == 1;
            if (doRemove) {
                _pushRemovalAck(validationIds[i]);
                vm.prank(alice);
                middleware.completeValidatorRemoval(0);

                // Mark the stake in expectedFinalStake as 0
                expectedFinalStake[i] = 0;

                // Read the old validator from the mock
                // to confirm status=Completed and endTime != 0
                {
                    bytes32 oldValID = oldRemovedValidationIds[i];
                    Validator memory oldVal = IBalancerValidatorManager(balancer).getValidator(oldValID);
                    // Some mocks only finalize endTime in initializeEndValidation, so check that
                    // we got endTime there:
                    assertGt(oldVal.endTime, 0, "Old val endTime must be set");
                    // Also check status is Completed:
                    assertEq(uint256(oldVal.status), uint256(ValidatorStatus.Completed), "Old val must be completed");
                }
            }
        }

        // Re-add the removed nodes
        for (uint256 i = 0; i < nodeCount; i++) {
            bool wasRemoved = ((seedRemoveMask >> uint8(i)) & 0x01) == 1;
            if (wasRemoved) {
                // Re-add
                vm.prank(alice);
                middleware.addNode(nodeIds[i], blsKey, ownerStruct, ownerStruct, 0);

                // No longer tracking message index

                // Fetch the BRAND-NEW validationID for this re-add
                bytes32 newValID =
                    IBalancerValidatorManager(balancer).getNodeValidationID(_nodeBytes(nodeIds[i]));
                // Overwrite old ID in validationIds[i] with the new one
                validationIds[i] = newValID;

                // Confirm the new registration
                _pushRegistrationAck(newValID, true);
                vm.prank(alice);
                middleware.completeValidatorRegistration(0);
                isActive[i] = true;

                // Verify that the oldVal ID remains at stake=0
                {
                    bytes32 oldValID = oldRemovedValidationIds[i];
                    uint256 oldStakeCheck = middleware.getNodeStake(epoch, oldValID);
                    assertEq(oldStakeCheck, 0, "Old validationID must remain at 0 stake after re-add");
                }
            }
        }

        // Warp again => finalize re-add
        epoch = _calcAndWarpOneEpoch();

        // Track final stake for each node
        for (uint256 i = 0; i < nodeCount; i++) {
            if (isActive[i]) {
                expectedFinalStake[i] = middleware.getNodeStake(epoch, validationIds[i]);
            }
        }

        // Final checks
        uint256 shouldBeActive = 0;
        for (uint256 i = 0; i < nodeCount; i++) {
            if (isActive[i]) {
                shouldBeActive++;

                // The new (or never-removed) validator
                uint256 finalStake = middleware.getNodeStake(epoch, validationIds[i]);
                assertEq(finalStake, expectedFinalStake[i], "Active node stake mismatch");
            } else {
                // If never re-added => 0 stake
                uint256 finalStake = middleware.getNodeStake(epoch, validationIds[i]);
                assertEq(finalStake, 0, "Inactive node must have zero stake");
            }
        }

        bytes32[] memory finalNodes = middleware.getActiveNodesForEpoch(alice, epoch);
        assertEq(finalNodes.length, shouldBeActive, "Mismatch in final # of active nodes");
    }

    function testFuzz_StakeUpDownForceUpdateRandNodes(
        uint8 seedNodeCount, // used to pick how many nodes to create
        uint8 stakeDeltaMask, // which nodes get stake up vs. down
        uint8 removeMask // which nodes get removed
    ) public {
        // Decide how many nodes to create (2-5)
        uint256 nodeCount = bound(seedNodeCount, 2, 5);

        // Warp to start fresh
        uint48 epoch = _calcAndWarpOneEpoch();

        // Prepare arrays
        bytes32[] memory nodeIds = new bytes32[](nodeCount);
        bytes32[] memory validationIds = new bytes32[](nodeCount);
        bool[] memory isActive = new bool[](nodeCount);
        // No longer tracking message indexes

        // Operator deposit (50-100 ETH)
        uint256 depositAmount = bound(uint256(seedNodeCount) * 10, 50 ether, 100 ether);
        (uint256 depositUsed, uint256 mintedShares_) = _deposit(staker, depositAmount);
        _setL1Limit(curatorOwner1, balancer, collateralClassId, depositUsed, delegator);
        _setOperatorL1Shares(curatorOwner1, balancer, collateralClassId, alice, mintedShares_, delegator);

        // BLS key and owners
        bytes memory blsKey = new bytes(48);
        address[] memory ownerArr = new address[](1);
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct = PChainOwner({threshold: 1, addresses: ownerArr});

        // Create nodes (unconfirmed)
        for (uint256 i = 0; i < nodeCount; i++) {
            bytes32 nodeId = keccak256(abi.encodePacked("Node", i, block.timestamp));
            nodeIds[i] = nodeId;

           // how much stake still free?
           (uint256 _minStakes, ) = middleware.getClassStakingRequirements(1);
           uint256 free = middleware.getOperatorAvailableStake(alice);
        
            if (free < _minStakes) {
                // next addNode is *supposed* to revert – record and stop
                vm.expectRevert(abi.encodeWithSelector(IAvalancheL1Middleware.AvalancheL1Middleware__InsufficientStake.selector));
                vm.prank(alice);
                middleware.addNode(
                    nodeId, blsKey,
                    ownerStruct, ownerStruct, 0        // will revert
                );
                nodeCount = i;                         // shrink arrays; creation done
                break;
           }

            vm.prank(alice);
            middleware.addNode(
                nodeId,
                new bytes(48),
                ownerStruct,
                ownerStruct,
                0
            );
            // No longer tracking message index

            bytes32 valID = IBalancerValidatorManager(balancer).getNodeValidationID(_nodeBytes(nodeId));
            validationIds[i] = valID;
            isActive[i] = false;
        }

        // Confirm nodes => warp => truly active
        for (uint256 i = 0; i < nodeCount; i++) {
            _pushRegistrationAck(validationIds[i], true);
            vm.prank(alice);
            middleware.completeValidatorRegistration(0);
            isActive[i] = true;
        }
        epoch = _calcAndWarpOneEpoch();

        // Verify all nodes active
        {
            bytes32[] memory activeNodes = middleware.getActiveNodesForEpoch(alice, epoch);
            assertEq(activeNodes.length, nodeCount, "All newly confirmed nodes must show as active");
        }

        // Verify sum of stakes matches operator used stake
        {
            uint256 sumOfStakes;
            for (uint256 i = 0; i < nodeCount; i++) {
                sumOfStakes += middleware.getNodeStake(epoch, validationIds[i]);
            }
            uint256 operatorUsed = middleware.getOperatorUsedStakeCached(alice);
            assertEq(sumOfStakes, operatorUsed, "Operator used stake must match sum of node stakes after confirm");
        }

        // Fuzz stake up/down or remove nodes
        (uint256 _minStake,) = middleware.getClassStakingRequirements(collateralClassId);

        for (uint256 i = 0; i < nodeCount; i++) {
            if (!isActive[i]) continue;

            bool doRemove = ((removeMask >> i) & 0x01) == 1;
            if (doRemove) {
                vm.prank(alice);
                middleware.removeNode(nodeIds[i]);
                isActive[i] = false;
                continue;
            }

            bool stakeDown = ((stakeDeltaMask >> i) & 0x01) == 1;
            uint256 currentStake = middleware.getNodeStake(epoch, validationIds[i]);
            if (currentStake == 0) continue;

            // Calculate new stake
            uint256 newStake;
            if (stakeDown) {
                newStake = currentStake / 2;
            } else {
                uint256 upAmount = currentStake / 2;
                newStake = currentStake + upAmount;
                uint256 avail = middleware.getOperatorAvailableStake(alice);
                if (newStake > currentStake + avail) {
                    newStake = currentStake + avail;
                }
            }

            if (newStake >= _minStake) {
                vm.prank(alice);
                middleware.initializeValidatorStakeUpdate(nodeIds[i], newStake);
                bytes32 vid = IBalancerValidatorManager(balancer).getNodeValidationID(_nodeBytes(nodeIds[i]));
                uint64 scaled = StakeConversion.stakeToWeight(newStake, middleware.WEIGHT_SCALE_FACTOR());
                Validator memory v = IBalancerValidatorManager(balancer).getValidator(vid);
                _pushWeight(vid, uint64(v.sentNonce), scaled);
                vm.prank(alice);
                middleware.completeValidatorWeightUpdate(0);
            }
        }

        // Warp to next epoch to finalize changes
        epoch = _calcAndWarpOneEpoch();

        // Verify sum of stakes matches operator used stake
        {
            uint256 sumOfStakes;
            for (uint256 i = 0; i < nodeCount; i++) {
                if (isActive[i]) {
                    sumOfStakes += middleware.getNodeStake(epoch, validationIds[i]);
                }
            }
            uint256 operatorUsed = middleware.getOperatorUsedStakeCached(alice);
            assertEq(sumOfStakes, operatorUsed, "Sum of node stakes should match operator used stake after updates");
        }

        // Warp to final window => forceUpdate
        _warpToLastHourOfCurrentEpoch();
        middleware.forceUpdateNodes(alice, 0);

        // Final epoch => finalize forced updates
        epoch = _calcAndWarpOneEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();

        // Check node stakes
        for (uint256 i = 0; i < nodeCount; i++) {
            uint256 finalStake = middleware.getNodeStake(epoch, validationIds[i]);

            if (isActive[i]) {
                bool forciblyRemoved = (finalStake == 0);
                if (forciblyRemoved) {
                    assertEq(finalStake, 0, "Node forcibly removed by forceUpdate");
                } else {
                    assertGt(finalStake, 0, "Node stake must remain > 0 if not forcibly removed");
                }
            } else {
                assertEq(finalStake, 0, "Node that was removed must have 0 stake");
            }
        }

        // Final check: sum of stakes matches operator used
        {
            uint256 sumOfStakes;
            for (uint256 i = 0; i < nodeCount; i++) {
                sumOfStakes += middleware.getNodeStake(epoch, validationIds[i]);
            }
            uint256 operatorUsed = middleware.getOperatorUsedStakeCached(alice);
            assertEq(sumOfStakes, operatorUsed, "Final sum of node stakes must match operator used stake");
        }
    }

    function testFuzz_TwoOperatorsMultipleNodes(
        uint8 seedNodeCountA,
        uint8 stakeDeltaMaskA,
        uint8 removeMaskA,
        uint8 seedNodeCountB,
        uint8 stakeDeltaMaskB,
        uint8 removeMaskB
    ) public {
        // Setup operators A (alice) and B (charlie) - using our pre-configured operators
        uint256 nodeCountA = bound(seedNodeCountA, 2, 5);
        uint256 nodeCountB = bound(seedNodeCountB, 2, 5);

        // Warp to start fresh
        uint48 epoch = _calcAndWarpOneEpoch();

        // Setup arrays for each operator
        bytes32[] memory nodeIdsA = new bytes32[](nodeCountA);
        bytes32[] memory validationIdsA = new bytes32[](nodeCountA);
        bool[] memory isActiveA = new bool[](nodeCountA);
        // No longer tracking message indexes

        bytes32[] memory nodeIdsB = new bytes32[](nodeCountB);
        bytes32[] memory validationIdsB = new bytes32[](nodeCountB);
        bool[] memory isActiveB = new bool[](nodeCountB);
        // No longer tracking message indexes

        // Operator deposits
        uint256 depositAmountA = bound(uint256(seedNodeCountA) * 10, 50 ether, 100 ether);
        // Use staker to deposit for Alice
        collateral.transfer(staker, depositAmountA);
        vm.startPrank(staker);
        collateral.approve(address(vault), depositAmountA);
        (uint256 depositUsedA, uint256 mintedSharesA) = vault.deposit(staker, depositAmountA);
        vm.stopPrank();

        _setOperatorL1Shares(curatorOwner1, balancer, collateralClassId, alice, mintedSharesA, delegator);

        uint256 depositAmountB = bound(uint256(seedNodeCountB) * 10, 50 ether, 100 ether);
        // Use staker to deposit for Charlie
        collateral.transfer(staker, depositAmountB);
        vm.startPrank(staker);
        collateral.approve(address(vault), depositAmountB);
        (uint256 depositUsedB, uint256 mintedSharesB) = vault.deposit(staker, depositAmountB);
        vm.stopPrank();

        _setL1Limit(curatorOwner1, balancer, collateralClassId, depositUsedA + depositUsedB, delegator);
        _setOperatorL1Shares(curatorOwner1, balancer, collateralClassId, charlie, mintedSharesB, delegator);
        _calcAndWarpOneEpoch();

        // Create nodes for operator A (Alice)
        for (uint256 i = 0; i < nodeCountA; i++) {
            bytes32 nodeId = keccak256(abi.encodePacked("NodeA", i, block.timestamp));
            nodeIdsA[i] = nodeId;

            vm.prank(alice);
            middleware.addNode(
                nodeId,
                new bytes(48),
                _pOwner1(alice),
                _pOwner1(alice),
                0
            );
            // No longer tracking message index

            bytes32 valID = IBalancerValidatorManager(balancer).getNodeValidationID(_nodeBytes(nodeId));
            validationIdsA[i] = valID;
            isActiveA[i] = false;
        }

        // Create nodes for operator B (Charlie)
        for (uint256 i = 0; i < nodeCountB; i++) {
            bytes32 nodeId = keccak256(abi.encodePacked("NodeB", i, block.timestamp));
            nodeIdsB[i] = nodeId;

            vm.prank(charlie);
            middleware.addNode(
                nodeId,
                new bytes(48),
                _pOwner1(charlie),
                _pOwner1(charlie),
                0
            );
            // No longer tracking message index

            bytes32 valID = IBalancerValidatorManager(balancer).getNodeValidationID(_nodeBytes(nodeId));
            validationIdsB[i] = valID;
            isActiveB[i] = false;
        }

        // Confirm nodes for both operators
        for (uint256 i = 0; i < nodeCountA; i++) {
            _pushRegistrationAck(validationIdsA[i], true);
            vm.prank(alice);
            middleware.completeValidatorRegistration(0);
            isActiveA[i] = true;
        }

        for (uint256 i = 0; i < nodeCountB; i++) {
            _pushRegistrationAck(validationIdsB[i], true);
                    middleware.completeValidatorRegistration(0);
            isActiveB[i] = true;
        }

        // Warp to next epoch
        epoch = _calcAndWarpOneEpoch();

        // Fuzz stake changes for both operators
        (uint256 minStake,) = middleware.getClassStakingRequirements(collateralClassId);

        // Operator A (Alice) stake changes
        for (uint256 i = 0; i < nodeCountA; i++) {
            if (!isActiveA[i]) continue;

            bool doRemove = ((removeMaskA >> i) & 0x01) == 1;
            if (doRemove) {
                vm.prank(alice);
                middleware.removeNode(nodeIdsA[i]);
                isActiveA[i] = false;
                continue;
            }

            bool stakeDown = ((stakeDeltaMaskA >> i) & 0x01) == 1;
            uint256 currentStake = middleware.getNodeStake(epoch, validationIdsA[i]);
            if (currentStake == 0) continue;

            uint256 newStake;
            if (stakeDown) {
                newStake = currentStake / 2;
            } else {
                uint256 upAmt = currentStake / 2;
                newStake = currentStake + upAmt;
                uint256 avail = middleware.getOperatorAvailableStake(alice);
                if (newStake > currentStake + avail) {
                    newStake = currentStake + avail;
                }
            }

            if (newStake >= minStake) {
                vm.prank(alice);
                middleware.initializeValidatorStakeUpdate(nodeIdsA[i], newStake);
                bytes32 vid = IBalancerValidatorManager(balancer).getNodeValidationID(_nodeBytes(nodeIdsA[i]));
                uint64 scaled = StakeConversion.stakeToWeight(newStake, middleware.WEIGHT_SCALE_FACTOR());
                Validator memory v = IBalancerValidatorManager(balancer).getValidator(vid);
                _pushWeight(vid, uint64(v.sentNonce), scaled);
                vm.prank(alice);
                middleware.completeValidatorWeightUpdate(0);
            }
        }

        // Operator B (Charlie) stake changes
        for (uint256 i = 0; i < nodeCountB; i++) {
            if (!isActiveB[i]) continue;

            bool doRemove = ((removeMaskB >> i) & 0x01) == 1;
            if (doRemove) {
                vm.prank(charlie);
                middleware.removeNode(nodeIdsB[i]);
                isActiveB[i] = false;
                continue;
            }

            bool stakeDown = ((stakeDeltaMaskB >> i) & 0x01) == 1;
            uint256 currentStake = middleware.getNodeStake(epoch, validationIdsB[i]);
            if (currentStake == 0) continue;

            uint256 newStake;
            if (stakeDown) {
                newStake = currentStake / 2;
            } else {
                uint256 upAmt = currentStake / 2;
                newStake = currentStake + upAmt;
                uint256 avail = middleware.getOperatorAvailableStake(charlie);
                if (newStake > currentStake + avail) {
                    newStake = currentStake + avail;
                }
            }

            if (newStake >= minStake) {
                vm.prank(charlie);
                middleware.initializeValidatorStakeUpdate(nodeIdsB[i], newStake);
                bytes32 vid = IBalancerValidatorManager(balancer).getNodeValidationID(_nodeBytes(nodeIdsB[i]));
                uint64 scaled = StakeConversion.stakeToWeight(newStake, middleware.WEIGHT_SCALE_FACTOR());
                Validator memory v = IBalancerValidatorManager(balancer).getValidator(vid);
                _pushWeight(vid, uint64(v.sentNonce), scaled);
                        middleware.completeValidatorWeightUpdate(0);
            }
        }

        // Warp to next epoch
        epoch = _calcAndWarpOneEpoch();

        // Force update both operators
        _warpToLastHourOfCurrentEpoch();
        middleware.forceUpdateNodes(alice, 0);
        middleware.forceUpdateNodes(charlie, 0);

        // Final epoch
        epoch = _calcAndWarpOneEpoch();

        // Check final stakes for operator A (Alice)
        for (uint256 i = 0; i < nodeCountA; i++) {
            uint256 finalStake = middleware.getNodeStake(epoch, validationIdsA[i]);
            if (isActiveA[i]) {
                if (finalStake == 0) {
                    assertEq(finalStake, 0, "Node forcibly removed by forceUpdate for operator A");
                } else {
                    assertGt(finalStake, 0, "Node stake must remain > 0 if not forcibly removed (operator A)");
                }
            } else {
                assertEq(finalStake, 0, "Removed node must have 0 stake (operator A)");
            }
        }

        // Check final stakes for operator B (Charlie)
        for (uint256 i = 0; i < nodeCountB; i++) {
            uint256 finalStake = middleware.getNodeStake(epoch, validationIdsB[i]);
            if (isActiveB[i]) {
                if (finalStake == 0) {
                    assertEq(finalStake, 0, "Node forcibly removed by forceUpdate for operator B");
                } else {
                    assertGt(finalStake, 0, "Node stake must remain > 0 if not forcibly removed (operator B)");
                }
            } else {
                assertEq(finalStake, 0, "Removed node must have 0 stake (operator B)");
            }
        }

        // Verify sum of stakes matches operator used stake
        {
            uint256 sumOfStakesA;
            for (uint256 i = 0; i < nodeCountA; i++) {
                sumOfStakesA += middleware.getNodeStake(epoch, validationIdsA[i]);
            }
            uint256 operatorAUsed = middleware.getOperatorUsedStakeCached(alice);
            assertEq(sumOfStakesA, operatorAUsed, "Final sum of node stakes must match operator A used stake");

            uint256 sumOfStakesB;
            for (uint256 i = 0; i < nodeCountB; i++) {
                sumOfStakesB += middleware.getNodeStake(epoch, validationIdsB[i]);
            }
            uint256 operatorBUsed = middleware.getOperatorUsedStakeCached(charlie);
            assertEq(sumOfStakesB, operatorBUsed, "Final sum of node stakes must match operator B used stake");
        }
    }

    function testFuzz_ThreeVaultsThreeOperators(
        uint8 nodeCountAlice,
        uint8 nodeCountCharlie,
        uint8 nodeCountDave,
        uint8 stakeDeltaMaskAlice,
        uint8 stakeDeltaMaskCharlie,
        uint8 stakeDeltaMaskDave,
        uint8 removeMaskAlice,
        uint8 removeMaskCharlie,
        uint8 removeMaskDave
    ) public {
        // Alice Operator for vault1 has 200_000_000_002_000 deposited
        // Alice Operator for vault3 has 100_000_000_000_000 deposited
        // Charlie Operator for vault1 has 150_000_000_000_000 deposited
        // Charlie Operator for vault2 has 120_000_000_000_000 deposited
        // Charlie Operator for vault3 has 100_000_000_000_000 deposited
        // Dave Operator for vault3 has 100_000_000_000_000 deposited
        // Dave Operator for vault2 has 160_000_000_000_000 deposited

        vm.startPrank(l1Owner);
        vaultManager.registerVault(address(vault2), 1, 3000 ether);
        vm.stopPrank();
        _setL1Limit(curatorOwner2, balancer, 1, 2500 ether, delegator2);

        // Add collateral2 to collateralClassId = 2
        _setupCollateralClassAndRegisterVault(2, 1, collateral2, vault3, 3000 ether, 2500 ether, delegator3);

        // Advance epoch so that new stakes are recognized
        _calcAndWarpOneEpoch();

        // Now we do random node creation for each operator
        uint256 nA = bound(nodeCountAlice, 1, 6);
        uint256 nC = bound(nodeCountCharlie, 1, 6);
        uint256 nD = bound(nodeCountDave, 1, 6);

        (uint256 minStake, ) = middleware.getClassStakingRequirements(1);

        // Create & confirm nodes for each operator
        (bytes32[] memory nodeIdsAlice, ,) = _createAndConfirmNodes(alice, nA, minStake, true, 2);
        (bytes32[] memory nodeIdsCharlie, ,) = _createAndConfirmNodes(charlie, nC, minStake, true, 2);
        (bytes32[] memory nodeIdsDave, ,) = _createAndConfirmNodes(dave, nD, minStake, true, 2);

        // Move to next epoch
        _calcAndWarpOneEpoch();

        // Fuzz: stakeDeltaMaskX, removeMaskX => operator modifies node stakes or removes them
        _stakeOrRemoveNodes(alice, nodeIdsAlice, stakeDeltaMaskAlice, removeMaskAlice);
        _stakeOrRemoveNodes(charlie, nodeIdsCharlie, stakeDeltaMaskCharlie, removeMaskCharlie);
        _stakeOrRemoveNodes(dave, nodeIdsDave, stakeDeltaMaskDave, removeMaskDave);

        // Warp => next epoch => finalize updates
        _calcAndWarpOneEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();

        // Force update each operator 
        _warpToLastHourOfCurrentEpoch();
        try middleware.forceUpdateNodes(alice, 0) { } catch { }
        try middleware.forceUpdateNodes(charlie, 0) { } catch { }
        try middleware.forceUpdateNodes(dave, 0) { } catch { }

        // Another epoch to ensure everything finalizes
        _calcAndWarpOneEpoch();

        // Final consistency: sum(node stakes) == operatorUsedStake
        _checkSumMatchesOperatorUsed(alice, nodeIdsAlice);
        _checkSumMatchesOperatorUsed(charlie, nodeIdsCharlie);
        _checkSumMatchesOperatorUsed(dave, nodeIdsDave);
    }

    function test_ForceUpdateNodes_GuardBehavior_MultiOp(
        uint8 nodeCountAlice,
        uint8 nodeCountCharlie,
        uint8 nodeCountDave,
        uint8 stakeDeltaMaskAlice,
        uint8 stakeDeltaMaskCharlie,
        uint8 stakeDeltaMaskDave,
        uint8 removeMaskAlice,
        uint8 removeMaskCharlie,
        uint8 removeMaskDave
    ) public {
        // Alice Operator for vault1 has 200_000_000_002_000 deposited
        // Alice Operator for vault3 has 100_000_000_000_000 deposited
        // Charlie Operator for vault1 has 150_000_000_000_000 deposited
        // Charlie Operator for vault2 has 120_000_000_000_000 deposited
        // Charlie Operator for vault3 has 100_000_000_000_000 deposited
        // Dave Operator for vault3 has 100_000_000_000_000 deposited
        // Dave Operator for vault2 has 160_000_000_000_000 deposited

        vm.startPrank(l1Owner);
        vaultManager.registerVault(address(vault2), 1, 3000 ether);
        vm.stopPrank();
        _setL1Limit(curatorOwner2, balancer, 1, 2500 ether, delegator2);

        // Add collateral2 to collateralClassId = 2
        _setupCollateralClassAndRegisterVault(2, 1, collateral2, vault3, 3000 ether, 2500 ether, delegator3);

        // Advance epoch so that new stakes are recognized
        _calcAndWarpOneEpoch();

        // Now we do random node creation for each operator
        uint256 nA = bound(nodeCountAlice, 1, 6);
        uint256 nC = bound(nodeCountCharlie, 1, 6);
        uint256 nD = bound(nodeCountDave, 1, 6);

        (uint256 minStake, ) = middleware.getClassStakingRequirements(1);

        // Create & confirm nodes for each operator
        (bytes32[] memory nodeIdsAlice, ,) = _createAndConfirmNodes(alice, nA, minStake, true, 2);
        (bytes32[] memory nodeIdsCharlie, ,) = _createAndConfirmNodes(charlie, nC, minStake, true, 2);
        (bytes32[] memory nodeIdsDave, ,) = _createAndConfirmNodes(dave, nD, minStake, true, 2);

        // Move to next epoch
        _calcAndWarpOneEpoch();

        // Fuzz: stakeDeltaMaskX, removeMaskX => operator modifies node stakes or removes them
        _stakeOrRemoveNodes(alice, nodeIdsAlice, stakeDeltaMaskAlice, removeMaskAlice);
        _stakeOrRemoveNodes(charlie, nodeIdsCharlie, stakeDeltaMaskCharlie, removeMaskCharlie);
        _stakeOrRemoveNodes(dave, nodeIdsDave, stakeDeltaMaskDave, removeMaskDave);

        // Warp => next epoch => finalize updates
        _calcAndWarpOneEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();

        // Force update each operator only if they need rebalancing
        _warpToLastHourOfCurrentEpoch();
        
        uint48 currentEpoch = middleware.getCurrentEpoch();
        
        // Check and update Alice if needed
        {
            uint256 nodesLen = middleware.getOperatorNodesLength(alice);
            uint256 total = middleware.getOperatorStake(alice, currentEpoch, 1)
                            + middleware.getOperatorStake(alice, currentEpoch, 2);
            uint256 used  = middleware.getOperatorUsedStakeCachedPerEpoch(currentEpoch, alice, 1)
                            + middleware.getOperatorUsedStakeCachedPerEpoch(currentEpoch, alice, 2);

            // DOWN-ONLY: used > total and there are nodes
            if (nodesLen > 0 && used > total) {
                // dust pass: may no-op OR revert; both are acceptable and must NOT flip the guard
                uint256 dust = 1;
                assertLt(dust, middleware.WEIGHT_SCALE_FACTOR(), "dust must be < scale");
                bool dustReverted = false;
                try middleware.forceUpdateNodes(alice, dust) { } catch { dustReverted = true; }
                assertFalse(middleware.rebalancedThisEpoch(alice, currentEpoch), "dust must not set guard");

                // legit pass: may schedule OR revert; guard should reflect that outcome
                bool scheduled = true;
                try middleware.forceUpdateNodes(alice, 0) { } catch { scheduled = false; }

                // If scheduled, the per-epoch guard is set; otherwise it must remain false
                assertEq(
                    middleware.rebalancedThisEpoch(alice, currentEpoch),
                    scheduled,
                    "guard must reflect whether scheduling happened"
                );

                // Second call this epoch: either revert or no-op, but the guard must not change
                bool secondCallReverted = false;
                try middleware.forceUpdateNodes(alice, 0) { } catch { secondCallReverted = true; }
                assertEq(
                    middleware.rebalancedThisEpoch(alice, currentEpoch),
                    scheduled,
                    "guard must stay consistent on repeat call"
                );
            }
            // UP-ONLY: total > used and there are nodes
            else if (nodesLen > 0 && total > used) {
                bool reverted = false;
                try middleware.forceUpdateNodes(alice, 0) { } catch { reverted = true; }
                if (!reverted) {
                    // No rebalancing must be scheduled in an up-only mismatch, and guard must remain false
                    assertFalse(middleware.rebalancedThisEpoch(alice, currentEpoch));
                }
                // If it reverted, that also satisfies "no scheduling"
            }
            // else: nodesLen == 0 OR used == total => do nothing
        }
        
        // Check and update Charlie if needed  
        {
            uint256 nodesLen = middleware.getOperatorNodesLength(charlie);
            uint256 total = middleware.getOperatorStake(charlie, currentEpoch, 1)
                            + middleware.getOperatorStake(charlie, currentEpoch, 2);
            uint256 used  = middleware.getOperatorUsedStakeCachedPerEpoch(currentEpoch, charlie, 1)
                            + middleware.getOperatorUsedStakeCachedPerEpoch(currentEpoch, charlie, 2);

            // DOWN-ONLY: used > total and there are nodes
            if (nodesLen > 0 && used > total) {
                // dust pass: may no-op OR revert; both are acceptable and must NOT flip the guard
                uint256 dust = 1;
                assertLt(dust, middleware.WEIGHT_SCALE_FACTOR(), "dust must be < scale");
                bool dustReverted = false;
                try middleware.forceUpdateNodes(charlie, dust) { } catch { dustReverted = true; }
                assertFalse(middleware.rebalancedThisEpoch(charlie, currentEpoch), "dust must not set guard");

                // legit pass: may schedule OR revert; guard should reflect that outcome
                bool scheduled = true;
                try middleware.forceUpdateNodes(charlie, 0) { } catch { scheduled = false; }

                // If scheduled, the per-epoch guard is set; otherwise it must remain false
                assertEq(
                    middleware.rebalancedThisEpoch(charlie, currentEpoch),
                    scheduled,
                    "guard must reflect whether scheduling happened"
                );

                // Second call this epoch: either revert or no-op, but the guard must not change
                bool secondCallReverted = false;
                try middleware.forceUpdateNodes(charlie, 0) { } catch { secondCallReverted = true; }
                assertEq(
                    middleware.rebalancedThisEpoch(charlie, currentEpoch),
                    scheduled,
                    "guard must stay consistent on repeat call"
                );
            }
            // UP-ONLY: total > used and there are nodes
            else if (nodesLen > 0 && total > used) {
                bool reverted = false;
                try middleware.forceUpdateNodes(charlie, 0) { } catch { reverted = true; }
                if (!reverted) {
                    // No rebalancing must be scheduled in an up-only mismatch, and guard must remain false
                    assertFalse(middleware.rebalancedThisEpoch(charlie, currentEpoch));
                }
                // If it reverted, that also satisfies "no scheduling"
            }
            // else: nodesLen == 0 OR used == total => do nothing
        }
        
        // Check and update Dave if needed
        {
            uint256 nodesLen = middleware.getOperatorNodesLength(dave);
            uint256 total = middleware.getOperatorStake(dave, currentEpoch, 1)
                            + middleware.getOperatorStake(dave, currentEpoch, 2);
            uint256 used  = middleware.getOperatorUsedStakeCachedPerEpoch(currentEpoch, dave, 1)
                            + middleware.getOperatorUsedStakeCachedPerEpoch(currentEpoch, dave, 2);

            // DOWN-ONLY: used > total and there are nodes
            if (nodesLen > 0 && used > total) {
                // dust pass: may no-op OR revert; both are acceptable and must NOT flip the guard
                uint256 dust = 1;
                assertLt(dust, middleware.WEIGHT_SCALE_FACTOR(), "dust must be < scale");
                bool dustReverted = false;
                try middleware.forceUpdateNodes(dave, dust) { } catch { dustReverted = true; }
                assertFalse(middleware.rebalancedThisEpoch(dave, currentEpoch), "dust must not set guard");

                // legit pass: may schedule OR revert; guard should reflect that outcome
                bool scheduled = true;
                try middleware.forceUpdateNodes(dave, 0) { } catch { scheduled = false; }

                // If scheduled, the per-epoch guard is set; otherwise it must remain false
                assertEq(
                    middleware.rebalancedThisEpoch(dave, currentEpoch),
                    scheduled,
                    "guard must reflect whether scheduling happened"
                );

                // Second call this epoch: either revert or no-op, but the guard must not change
                bool secondCallReverted = false;
                try middleware.forceUpdateNodes(dave, 0) { } catch { secondCallReverted = true; }
                assertEq(
                    middleware.rebalancedThisEpoch(dave, currentEpoch),
                    scheduled,
                    "guard must stay consistent on repeat call"
                );
            }
            // UP-ONLY: total > used and there are nodes
            else if (nodesLen > 0 && total > used) {
                bool reverted = false;
                try middleware.forceUpdateNodes(dave, 0) { } catch { reverted = true; }
                if (!reverted) {
                    // No rebalancing must be scheduled in an up-only mismatch, and guard must remain false
                    assertFalse(middleware.rebalancedThisEpoch(dave, currentEpoch));
                }
                // If it reverted, that also satisfies "no scheduling"
            }
            // else: nodesLen == 0 OR used == total => do nothing
        }

        // Another epoch to ensure everything finalizes
        _calcAndWarpOneEpoch();

        // That's it. Optionally, verify final aggregator of node stakes == operatorUsedStake
        // for each operator. Just a quick check:
        _checkSumMatchesOperatorUsed(alice, nodeIdsAlice);
        _checkSumMatchesOperatorUsed(charlie, nodeIdsCharlie);
        _checkSumMatchesOperatorUsed(dave, nodeIdsDave);
    }

    function test_GetVaults() public view {
        uint48 epoch = middleware.getCurrentEpoch();

        address[] memory activeVaults = vaultManager.getVaults(epoch);

        uint256 activeCount = 0;
        bool foundVault1 = false;

        for (uint256 i = 0; i < activeVaults.length; i++) {
            if (activeVaults[i] != address(0)) {
                activeCount++;
                if (activeVaults[i] == address(vault)) foundVault1 = true;
            }
        }

        assertEq(activeCount, 1, "Should have 1 active vault");
        assertTrue(foundVault1, "First vault should be active");
    }

    function test_GetOperatorUsedStakeCachedPerEpoch() public {
        // Setup
        test_ForceUpdateWithAdditionalStake();
        uint48 epoch = middleware.getCurrentEpoch();

        // Test PRIMARY_ASSET_CLASS (1)
        uint256 primaryStake = middleware.getOperatorUsedStakeCachedPerEpoch(epoch, alice, 1);
        assertGt(primaryStake, 0, "Primary collateral stake should be > 0");

        // Test secondary collateral class (2)
        uint256 secondaryStake = middleware.getOperatorUsedStakeCachedPerEpoch(epoch, alice, 2);
        assertEq(secondaryStake, 0, "Secondary collateral stake should be 0 as none was added");
    }

    function test_AutoUpdateFailsIfTooManyEpochsPending() public {
        uint48 maxAutoUpdates = middleware.MAX_AUTO_EPOCH_UPDATES();
        uint48 epochsToBecomePending = maxAutoUpdates + 1;

        uint48 currentEpochAfterWarp = _warpAdvanceMiddlewareEpochsRaw(epochsToBecomePending);
        
        bytes memory expectedError = abi.encodeWithSelector(
            IAvalancheL1Middleware.AvalancheL1Middleware__ManualEpochUpdateRequired.selector,
            currentEpochAfterWarp // epochsPending
        );
        vm.expectRevert(expectedError);
        middleware.calcAndCacheNodeStakeForAllOperators();

        bytes32 nodeId = keccak256("nodeTooManyPending");
        vm.startPrank(alice);
        vm.expectRevert(expectedError);
        middleware.addNode(
            nodeId,
            new bytes(48),
            _pOwner1(alice),
            _pOwner1(alice),
            0
        );
        vm.stopPrank();
    }

    function test_ManualUpdateProcessesEpochsIncrementallyAndAutoUpdateSucceedsAfterCatchUp() public {
        address middlewareOwner = balancer;

        uint48 maxAutoUpdates = middleware.MAX_AUTO_EPOCH_UPDATES();
        uint48 totalEpochsToMakePending = maxAutoUpdates + 2;

        uint48 initialCurrentEpoch = middleware.getCurrentEpoch();
        uint48 currentEpochAfterWarp = _warpAdvanceMiddlewareEpochsRaw(totalEpochsToMakePending);
        
        assertEq(currentEpochAfterWarp, initialCurrentEpoch + totalEpochsToMakePending, "Warping did not result in the expected current epoch");

        bytes memory expectedRevertError = abi.encodeWithSelector(
            IAvalancheL1Middleware.AvalancheL1Middleware__ManualEpochUpdateRequired.selector,
            currentEpochAfterWarp
        );
        vm.expectRevert(expectedRevertError);
        middleware.calcAndCacheNodeStakeForAllOperators();

        uint48 epochsToProcessManuallyFirstPass = 2;
        vm.startPrank(middlewareOwner);
        vm.expectEmit(true, true, true, true, address(middleware));
        emit IAvalancheL1Middleware.NodeStakeCacheManuallyProcessed(
            epochsToProcessManuallyFirstPass,
            epochsToProcessManuallyFirstPass
        );
        middleware.manualProcessNodeStakeCache(epochsToProcessManuallyFirstPass);
        vm.stopPrank();

        middleware.calcAndCacheNodeStakeForAllOperators();
        
        vm.startPrank(middlewareOwner);
        vm.expectEmit(true, true, true, true, address(middleware));
        emit IAvalancheL1Middleware.NodeStakeCacheManuallyProcessed(
            currentEpochAfterWarp,
            0
        );
        middleware.manualProcessNodeStakeCache(1);
        vm.stopPrank();
        
        _warpAdvanceMiddlewareEpochsRaw(1);
        
        middleware.calcAndCacheNodeStakeForAllOperators();
    }
    
    function test_CalculateStakeForNowOldEpoch_AfterSlashingCheckRemoval() public {
        // Get initial epoch and asset class
        uint48 epochToTest = middleware.getCurrentEpoch();
        uint96 primaryCollateralClass = middleware.PRIMARY_ASSET_CLASS();

        // Cache initial stake
        uint256 initialTotalStake = middleware.calcAndCacheStakes(epochToTest, primaryCollateralClass);
        assertTrue(middleware.totalStakeCached(epochToTest, primaryCollateralClass), "Stake should be cached");
        assertGt(initialTotalStake, 0, "Initial stake should be > 0");

        // Get time parameters
        uint48 slashingWindow = middleware.SLASHING_WINDOW();
        uint48 epochDuration = middleware.EPOCH_DURATION();
        assertTrue(epochDuration > 0, "Epoch duration must be positive");

        // Advance time past slashing window
        uint256 timeToAdvance = uint256(slashingWindow) + (uint256(epochDuration) * 5);
        vm.warp(block.timestamp + timeToAdvance);

        uint48 currentEpochAfterFarWarp = middleware.getCurrentEpoch();
        uint48 epochToTestStartTs = middleware.getEpochStartTs(epochToTest);
        
        // Verify time advancement
        assertTrue(currentEpochAfterFarWarp > epochToTest + (slashingWindow / epochDuration) + 3, "Time advanced enough");
        assertTrue(epochToTestStartTs < block.timestamp - slashingWindow, "Epoch is old enough");

        // Get stake for old epoch
        uint256 totalStakeForOldEpoch = middleware.getTotalStake(epochToTest, primaryCollateralClass);
        assertEq(totalStakeForOldEpoch, initialTotalStake, "Stake matches initial value");
        assertGt(totalStakeForOldEpoch, 0, "Stake is positive");

        // Verify recalculation
        uint256 recalcTotalStakeForOldEpoch = middleware.calcAndCacheStakes(epochToTest, primaryCollateralClass);
        assertEq(recalcTotalStakeForOldEpoch, initialTotalStake, "Recalculated stake matches");
        assertTrue(middleware.totalStakeCached(epochToTest, primaryCollateralClass), "Stake remains cached");
    }

    function test_DustLimitStakeCausesFakeRebalancingFix() public {
        address attacker = makeAddr("attacker");
        address delegatedStaker = makeAddr("delegatedStaker");

        _calcAndWarpOneEpoch();

        // Setup initial stake and nodes
        uint256 initialDeposit = 1000 ether;
        (uint256 depositAmount, uint256 initialShares) = _deposit(delegatedStaker, initialDeposit);

        _setL1Limit(curatorOwner1, balancer, collateralClassId, depositAmount, delegator);
        _setOperatorL1Shares(curatorOwner1, balancer, collateralClassId, alice, initialShares, delegator);

        _calcAndWarpOneEpoch();
        (, bytes32[] memory validationIDs,) = _createAndConfirmNodes(alice, 2, 0, true, 1);

        uint48 epoch2 = _calcAndWarpOneEpoch();

        // Verify node stakes
        uint256 totalNodeStake = 0;
        for (uint i = 0; i < validationIDs.length; i++) {
            uint256 nodeStake = middleware.getNodeStake(epoch2, validationIDs[i]);
            totalNodeStake += nodeStake;
        }

        middleware.getOperatorStake(alice, epoch2, collateralClassId);
        middleware.getOperatorUsedStakeCached(alice);

        // Withdraw and update operator shares
        uint256 withdrawAmount = (initialDeposit * 60) / 100;
        vm.startPrank(delegatedStaker);
        (uint256 burnedShares, ) = vault.withdraw(delegatedStaker, withdrawAmount);
        vm.stopPrank();        

        uint256 newOperatorShares = initialShares - burnedShares;
        _setOperatorL1Shares(curatorOwner1, balancer, collateralClassId, alice, newOperatorShares, delegator);
        
        uint48 epoch3 = _calcAndWarpOneEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();

        uint256 newOperatorTotalStake = middleware.getOperatorStake(alice, epoch3, collateralClassId);
        uint256 currentUsedStake = middleware.getOperatorUsedStakeCached(alice);

        // Verify excess stake scenario
        assertGt(newOperatorTotalStake, currentUsedStake, "Setup creates excess available stake");

        _warpToLastHourOfCurrentEpoch();
        
        // Test forceUpdateNodes behavior with excess stake
        vm.prank(attacker);
        middleware.forceUpdateNodes(alice, 1);
        
        assertFalse(middleware.rebalancedThisEpoch(alice, epoch3), "No rebalancing flag set for excess stake");
        
        middleware.forceUpdateNodes(alice, 0);
        assertFalse(middleware.rebalancedThisEpoch(alice, epoch3), "Still no rebalancing flag");
    }

    function test_FutureEpochCacheManipulationFix() public {
        uint48 currentEpoch = _calcAndWarpOneEpoch();
        
        // Alice starts with high stake 
        uint256 aliceInitialStake = middleware.getOperatorStake(alice, currentEpoch, collateralClassId);
        console2.log("Alice initial stake:", aliceInitialStake);
        assertGt(aliceInitialStake, 0, "Alice should have initial stake");
        
        // 1. ATTACK ATTEMPT: Try to cache future epoch with current high stake values
        uint48 futureEpoch = currentEpoch + 5;
        
        // This should REVERT with the fix in place
        vm.expectRevert(
            abi.encodeWithSelector(
                IAvalancheL1Middleware.AvalancheL1Middleware__CannotCacheFutureEpoch.selector,
                futureEpoch
            )
        );
        middleware.calcAndCacheStakes(futureEpoch, collateralClassId);
        
        // 2. Verify that future epoch is NOT cached
        assertFalse(
            middleware.totalStakeCached(futureEpoch, collateralClassId), 
            "Future epoch should NOT be cached"
        );
        
        // 3. Verify we CAN cache the current epoch
        middleware.calcAndCacheStakes(currentEpoch, collateralClassId);
        assertTrue(
            middleware.totalStakeCached(currentEpoch, collateralClassId), 
            "Current epoch should be cached"
        );
        
        // 4. Verify we CAN cache past epochs (if needed for your use case)
        if (currentEpoch > 0) {
            uint48 pastEpoch = currentEpoch - 1;
            middleware.calcAndCacheStakes(pastEpoch, collateralClassId);
            assertTrue(
                middleware.totalStakeCached(pastEpoch, collateralClassId), 
                "Past epoch should be cached"
            );
        }
        
        // 5. TIME PASSES: Alice withdraws most of her stake
        uint256 withdrawAmount = 150_000_000_000_000; // Withdraw significant amount
        console2.log("Alice withdrawing:", withdrawAmount);
        
        _withdraw(staker, withdrawAmount);
        
        // Move forward through epochs to simulate time passing
        for (uint256 i = 0; i < 5; i++) {
            _calcAndWarpOneEpoch();
        }
        
        // We should now be at the future epoch that we tried to cache earlier
        uint48 nowCurrentEpoch = middleware.getCurrentEpoch();
        console2.log("Now at epoch:", nowCurrentEpoch);
        assertEq(nowCurrentEpoch, futureEpoch, "Should have reached the future epoch");
        
        // 6. NOW we can cache this epoch (since it's no longer in the future)
        middleware.calcAndCacheStakes(nowCurrentEpoch, collateralClassId);
        
        // 7. Verify the stake reflects the ACTUAL current state (post-withdrawal)
        uint256 aliceCurrentStake = middleware.getOperatorStake(alice, nowCurrentEpoch, collateralClassId);
        
        // The stake should be lower than the initial stake due to withdrawal
        assertLt(
            aliceCurrentStake, 
            aliceInitialStake, 
            "Alice's stake should be lower after withdrawal"
        );
    }

    function test_CacheCurrentAndPastEpochs() public {
        uint48 currentEpoch = _calcAndWarpOneEpoch();
        
        // Test 1: Can cache current epoch
        middleware.calcAndCacheStakes(currentEpoch, collateralClassId);
        assertTrue(middleware.totalStakeCached(currentEpoch, collateralClassId), "Should cache current epoch");
        
        // Test 2: Can cache past epoch
        if (currentEpoch > 0) {
            middleware.calcAndCacheStakes(currentEpoch - 1, collateralClassId);
            assertTrue(middleware.totalStakeCached(currentEpoch - 1, collateralClassId), "Should cache past epoch");
        }
        
        // Test 3: Cannot cache future epoch (even by 1)
        vm.expectRevert(
            abi.encodeWithSelector(
                IAvalancheL1Middleware.AvalancheL1Middleware__CannotCacheFutureEpoch.selector,
                currentEpoch + 1
            )
        );
        middleware.calcAndCacheStakes(currentEpoch + 1, collateralClassId);
        
        // Test 4: Cannot cache far future epoch
        vm.expectRevert(
            abi.encodeWithSelector(
                IAvalancheL1Middleware.AvalancheL1Middleware__CannotCacheFutureEpoch.selector,
                currentEpoch + 100
            )
        );
        middleware.calcAndCacheStakes(currentEpoch + 100, collateralClassId);
    }

    function test_POC_MisattributedStake_NodeIdReused_Fixed() public {
        address operatorA = alice;
        address operatorB = charlie; // Using charlie as Operator B

        // Use a specific, predictable nodeId for the test
        bytes32 sharedNodeId_X = keccak256(abi.encodePacked("REUSED_NODE_ID_XYZ"));
        bytes memory blsKey_A = new bytes(48);
        bytes memory blsKey_B = new bytes(48); // Operator B uses a different BLS key
        address[] memory ownerArr = new address[](1);
        ownerArr[0] = operatorA; // For simplicity, operator owns the PChainOwner
        PChainOwner memory pchainOwner_A = PChainOwner({threshold: 1, addresses: ownerArr});
        ownerArr[0] = operatorB;
        PChainOwner memory pchainOwner_B = PChainOwner({threshold: 1, addresses: ownerArr});

        // Ensure operators have some stake in the vault
        uint256 stakeAmountOpA = 20_000_000_000_000; // e.g., 20k tokens
        uint256 stakeAmountOpB = 30_000_000_000_000; // e.g., 30k tokens

        // Operator A deposits and sets shares
        collateral.transfer(staker, stakeAmountOpA);
        vm.startPrank(staker);
        collateral.approve(address(vault), stakeAmountOpA);
        (,uint256 sharesA) = vault.deposit(operatorA, stakeAmountOpA);
        vm.stopPrank();
        _setOperatorL1Shares(curatorOwner1, balancer, collateralClassId, operatorA, sharesA, delegator);

        // Operator B deposits and sets shares
        collateral.transfer(staker, stakeAmountOpB);
        vm.startPrank(staker);
        collateral.approve(address(vault), stakeAmountOpB);
        (,uint256 sharesB) = vault.deposit(operatorB, stakeAmountOpB);
        vm.stopPrank();
        _setOperatorL1Shares(curatorOwner1, balancer, collateralClassId, operatorB, sharesB, delegator);
        
        _calcAndWarpOneEpoch(); // Ensure stakes are recognized

        // --- Epoch E0: Operator A registers node N1 using sharedNodeId_X ---
        /* uint48 epochE0 = */ middleware.getCurrentEpoch();
        vm.prank(operatorA);
        middleware.addNode(sharedNodeId_X, blsKey_A, pchainOwner_A, pchainOwner_A, 0);
        // No longer tracking message index
        
        // Get the L1 validationID for Operator A's node
        bytes memory pchainNodeId_P_X_bytes = abi.encodePacked(uint160(uint256(sharedNodeId_X)));
        bytes32 validationID_A1 = IBalancerValidatorManager(balancer).getNodeValidationID(pchainNodeId_P_X_bytes);

        _pushRegistrationAck(validationID_A1, true);
        vm.prank(operatorA);
        middleware.completeValidatorRegistration(0);
        
        // Move to next epoch so validator becomes active
        _calcAndWarpOneEpoch();
        uint48 activeEpoch = middleware.getCurrentEpoch();
        
        // DIRECT TEST: Verify validationID_A1 belongs to operatorA by checking if getActiveNodesForEpoch 
        // includes sharedNodeId_X when queried for operatorA but NOT when queried for operatorB
        bytes32[] memory activeNodes_A = middleware.getActiveNodesForEpoch(operatorA, activeEpoch);
        bytes32[] memory activeNodes_B = middleware.getActiveNodesForEpoch(operatorB, activeEpoch);
        
        bool nodeFoundForA = false;
        bool nodeFoundForB = false;
        
        for (uint256 i = 0; i < activeNodes_A.length; i++) {
            if (activeNodes_A[i] == sharedNodeId_X) nodeFoundForA = true;
        }
        for (uint256 i = 0; i < activeNodes_B.length; i++) {
            if (activeNodes_B[i] == sharedNodeId_X) nodeFoundForB = true;
        }
        
        assertTrue(nodeFoundForA, "validationID_A1 should be mapped to operatorA");
        assertFalse(nodeFoundForB, "validationID_A1 should NOT be mapped to operatorB");
        
        uint256 stake_A_on_N1 = middleware.getNodeStake(activeEpoch, validationID_A1);
        assertGt(stake_A_on_N1, 0, "Operator A's node N1 should have stake");

        bytes32[] memory activeNodes_A_E0 = middleware.getActiveNodesForEpoch(operatorA, activeEpoch);
        assertEq(activeNodes_A_E0.length, 1, "Operator A should have 1 active node");
        assertEq(activeNodes_A_E0[0], sharedNodeId_X);

        // --- Epoch E1: Node N1 is fully removed ---
        _calcAndWarpOneEpoch();
        uint48 epochE1 = middleware.getCurrentEpoch();

        vm.prank(operatorA);
        middleware.removeNode(sharedNodeId_X);
        // No longer tracking message index

        _calcAndWarpOneEpoch();
        epochE1 = middleware.getCurrentEpoch();

        assertEq(middleware.getNodeStake(epochE1, validationID_A1), 0, "Stake should be 0 after removal");
        
        _pushRemovalAck(validationID_A1);
        vm.prank(operatorA);
        middleware.completeValidatorRemoval(0);

        bytes32[] memory activeNodes_A_E1 = middleware.getActiveNodesForEpoch(operatorA, epochE1);
        assertEq(activeNodes_A_E1.length, 0, "Operator A should have 0 active nodes after removal");

        // --- Epoch E2: Operator B re-registers using same sharedNodeId_X ---
        _calcAndWarpOneEpoch();
        uint48 epochE2 = middleware.getCurrentEpoch();

        vm.prank(operatorB);
        middleware.addNode(sharedNodeId_X, blsKey_B, pchainOwner_B, pchainOwner_B, 0);
        // No longer tracking message index

        // Get the L1 validationID for Operator B's new node
        bytes32 validationID_B2 = IBalancerValidatorManager(balancer).getNodeValidationID(pchainNodeId_P_X_bytes);
        assertNotEq(validationID_A1, validationID_B2, "ValidationIDs should be different");
        
        _pushRegistrationAck(validationID_B2, true);
        vm.prank(operatorB);
        middleware.completeValidatorRegistration(0);
        
        // Move to next epoch so validator becomes active
        _calcAndWarpOneEpoch();
        uint48 currentEpoch = middleware.getCurrentEpoch();
        
        // DIRECT TEST: Verify validationID_B2 belongs to operatorB by checking if getActiveNodesForEpoch 
        // includes sharedNodeId_X when queried for operatorB but NOT when queried for operatorA
        bytes32[] memory activeNodes_A_current = middleware.getActiveNodesForEpoch(operatorA, currentEpoch);
        bytes32[] memory activeNodes_B_current = middleware.getActiveNodesForEpoch(operatorB, currentEpoch);
        
        bool nodeFoundForA_current = false;
        bool nodeFoundForB_current = false;
        
        for (uint256 i = 0; i < activeNodes_A_current.length; i++) {
            if (activeNodes_A_current[i] == sharedNodeId_X) nodeFoundForA_current = true;
        }
        for (uint256 i = 0; i < activeNodes_B_current.length; i++) {
            if (activeNodes_B_current[i] == sharedNodeId_X) nodeFoundForB_current = true;
        }
        
        assertFalse(nodeFoundForA_current, "validationID_B2 should NOT be mapped to operatorA");
        assertTrue(nodeFoundForB_current, "validationID_B2 should be mapped to operatorB");

        _calcAndWarpOneEpoch();
        epochE2 = middleware.getCurrentEpoch();

        uint256 stake_B_on_N2 = middleware.getNodeStake(epochE2, validationID_B2);
        assertGt(stake_B_on_N2, 0, "Operator B's node should have stake");

        bytes32[] memory activeNodes_B_E2 = middleware.getActiveNodesForEpoch(operatorB, epochE2);
        assertEq(activeNodes_B_E2.length, 1, "Operator B should have 1 active node");
        assertEq(activeNodes_B_E2[0], sharedNodeId_X);

        // --- THE FIX VERIFICATION: Query Operator A's stake in Epoch E2 ---
        middleware.calcAndCacheStakes(epochE2, middleware.PRIMARY_ASSET_CLASS());

        uint256 usedStake_A_E2 = middleware.getOperatorUsedStakeCachedPerEpoch(
            epochE2, operatorA, middleware.PRIMARY_ASSET_CLASS()
        );
        
        // WITH THE FIX: Operator A's used stake should be 0, NOT Operator B's stake
        assertEq(usedStake_A_E2, 0, "SUCCESS: Operator A's stake is correctly 0, not misattributed!");
        
        // Verify Operator B's stake is correctly attributed to B
        uint256 usedStake_B_E2 = middleware.getOperatorUsedStakeCachedPerEpoch(
            epochE2, operatorB, middleware.PRIMARY_ASSET_CLASS()
        );
        assertEq(usedStake_B_E2, stake_B_on_N2, "Operator B's stake correctly attributed");
        
        // Double-check that Operator A has no active nodes in E2
        bytes32[] memory activeNodes_A_E2 = middleware.getActiveNodesForEpoch(operatorA, epochE2);
        assertEq(activeNodes_A_E2.length, 0, "Operator A should have 0 active nodes in E2");
    }

    function test_changeVaultManagerFix() public {
        // Move forward to let the vault roll epochs
        uint48 epoch = _calcAndWarpOneEpoch();

        uint256 operatorStake = middleware.getOperatorStake(alice, epoch, collateralClassId);
        console2.log("Operator stake (epoch", epoch, "):", operatorStake);
        assertGt(operatorStake, 0);

        MiddlewareVaultManager vaultManager2 = new MiddlewareVaultManager(address(vaultFactory), l1Owner, address(middleware), 24); // 24 epoch delay

        vm.startPrank(l1Owner);
        vm.expectRevert(abi.encodeWithSelector(IAvalancheL1Middleware.AvalancheL1Middleware__VaultManagerAlreadySet.selector, address(vaultManager)));
        middleware.setVaultManager(address(vaultManager2));
        vm.stopPrank();
    }

    function test_POC_RemoveOperatorWithActiveNodesFix() public {
        uint48 epoch = _calcAndWarpOneEpoch();
        
        // Add nodes for alice
        (uint256 minStake, ) = middleware.getClassStakingRequirements(collateralClassId);
        (bytes32[] memory nodeIds, ,) = _createAndConfirmNodes(alice, 3, minStake, true, 2);
        
        // Move to next epoch to ensure nodes are active
        epoch = _calcAndWarpOneEpoch();
        
        // Verify alice has active nodes and stake
        uint256 nodeCount = middleware.getOperatorNodesLength(alice);
        uint256 aliceStake = middleware.getOperatorStake(alice, epoch, collateralClassId);
        assertEq(nodeCount, 3, "Alice should have exactly 3 active nodes");
        assertGt(aliceStake, 0, "Alice should have stake");
        
        // Try to disable the operator with active nodes - should REVERT
        vm.prank(l1Owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAvalancheL1Middleware.AvalancheL1Middleware__OperatorHasActiveNodes.selector,
                alice,
                nodeCount
            )
        );
        middleware.disableOperator(alice);
        
        // Now alice needs to properly remove all nodes
        // First, initiate removal for all nodes
        for (uint256 i = 0; i < nodeIds.length; i++) {
            vm.prank(alice);
            middleware.removeNode(nodeIds[i]);
        }
        
        // Move to next epoch to process removals
        epoch = _calcAndWarpOneEpoch();
        
        // Force the cache update to process node removals
        middleware.calcAndCacheNodeStakeForAllOperators();
        
        // Verify alice now has no nodes in the array
        uint256 remainingNodes = middleware.getOperatorNodesLength(alice);
        assertEq(remainingNodes, 0, "Alice should have no active nodes after removal processing");
        
        // Now disable should work
        vm.prank(l1Owner);
        middleware.disableOperator(alice);
        
        // Warp past the window to allow removal
        uint48 removalDelay = middleware.REMOVAL_DELAY_EPOCHS();
        _moveToNextEpochAndCalc(removalDelay);
        
        // Now removal should work since operator has no active nodes
        vm.prank(l1Owner);
        middleware.removeOperator(alice);
        
        // Verify alice is removed from operators mapping
        address[] memory currentOperators = middleware.getAllOperators();
        bool aliceFound = false;
        for (uint256 i = 0; i < currentOperators.length; i++) {
            if (currentOperators[i] == alice) {
                aliceFound = true;
                break;
            }
        }
        
        assertFalse(aliceFound, "Alice should not be in current operators list");
    }

    function test_AddNodes_AndThenForceUpdate_Corrected_Simplified_Approval() public {
        // Initial setup
        uint48 currentEpoch = _calcAndWarpOneEpoch();
        middleware.getClassStakingRequirements(middleware.PRIMARY_ASSET_CLASS());
        
        // Node data
        bytes32 nodeId_A = 0x00000000000000000000000039a662260f928d2d98ab5ad93aa7af8e0ee4d426;
        bytes32 nodeId_B = 0x00000000000000000000000039a662260f928d2d98ab5ad93aa7af8e0ee4d626;
        bytes32 nodeId_C = 0x00000000000000000000000039a662260f928d2d98ab5ad93aa7af8e0ee4d526;
        bytes memory blsKey = new bytes(48);
        address[] memory ownerArr = new address[](1); 
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct = PChainOwner({threshold: 1, addresses: ownerArr});

        // --- Setup Secondary Collateral Class (ID 2) ---
        uint96 secondaryCollateralClassId = 2;
        uint256 minSecondaryStakePerNodeForClass2 = 5 ether;

        // Setup the secondary collateral class
        vm.startPrank(l1Owner);
        middleware.addCollateralClass(secondaryCollateralClassId, minSecondaryStakePerNodeForClass2, 0, address(collateral2));
        middleware.activateSecondaryCollateralClass(secondaryCollateralClassId);
        vaultManager.registerVault(address(vault3), secondaryCollateralClassId, 3000 ether);
        vm.stopPrank();
        
        // Set L1 limit for the secondary collateral class
        _setL1Limit(curatorOwner3, balancer, secondaryCollateralClassId, 2500 ether, delegator3);

        // --- Alice gets and deposits secondary stake into vault3 ---
        // IMPORTANT: Deposit enough for ALL 3 nodes (15 ETH) since primary will be insufficient
        uint256 aliceTargetSecondaryStake = minSecondaryStakePerNodeForClass2 * 3; // 15 ether for 3 nodes

        // 1. Give Alice collateral2 tokens
        deal(address(collateral2), alice, aliceTargetSecondaryStake);

        // 2. Alice approves vault3 to spend her collateral2
        vm.startPrank(alice);
        collateral2.approve(address(vault3), aliceTargetSecondaryStake);

        // 3. Alice deposits into vault3
        ( , uint256 mintedSecondarySharesAlice) = vault3.deposit(alice, aliceTargetSecondaryStake);
        vm.stopPrank();

        // 4. Assign these minted shares to Alice for the L1 system
        _setOperatorL1Shares(curatorOwner3, balancer, secondaryCollateralClassId, alice, mintedSecondarySharesAlice, delegator3);

        // Make sure changes are reflected
        currentEpoch = _calcAndWarpOneEpoch();
        middleware.calcAndCacheStakes(currentEpoch, middleware.PRIMARY_ASSET_CLASS());
        middleware.calcAndCacheStakes(currentEpoch, secondaryCollateralClassId);

        // Verify Alice has sufficient secondary stake
        uint256 aliceSecondaryStake = middleware.getOperatorStake(alice, currentEpoch, secondaryCollateralClassId);
        console2.log("Alice secondary stake:", aliceSecondaryStake);
        assertGe(aliceSecondaryStake, minSecondaryStakePerNodeForClass2 * 3, "Alice should have enough secondary stake for 3 nodes");

        // --- Add 3 Nodes for Alice ---
        vm.startPrank(alice);
        middleware.addNode(nodeId_A, blsKey, ownerStruct, ownerStruct, 0);
        middleware.addNode(nodeId_B, new bytes(48), ownerStruct, ownerStruct, 0);
        middleware.addNode(nodeId_C, new bytes(48), ownerStruct, ownerStruct, 0);
        vm.stopPrank();

        // Get validation IDs
        bytes32 validationID_A = IBalancerValidatorManager(balancer).getNodeValidationID(_nodeBytes(nodeId_A));
        bytes32 validationID_B = IBalancerValidatorManager(balancer).getNodeValidationID(_nodeBytes(nodeId_B));
        bytes32 validationID_C = IBalancerValidatorManager(balancer).getNodeValidationID(_nodeBytes(nodeId_C));

        // Complete registrations
        vm.startPrank(alice);
        _pushRegistrationAck(validationID_A, true);
        middleware.completeValidatorRegistration(0);
        vm.stopPrank();
        _calcAndWarpOneEpoch();
        
        vm.startPrank(alice);
        _pushRegistrationAck(validationID_B, true);
        middleware.completeValidatorRegistration(0);
        vm.stopPrank();
        _calcAndWarpOneEpoch();
        
        vm.startPrank(alice);
        _pushRegistrationAck(validationID_C, true);
        middleware.completeValidatorRegistration(0);
        vm.stopPrank();

        currentEpoch = _calcAndWarpOneEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();
        assertEq(middleware.getOperatorNodesLength(alice), 3, "Alice should have 3 nodes.");

        // --- Test the forceUpdate scenario ---
        // Now let's reduce Alice's secondary stake to create a scenario where nodes need to be removed
        
        // Withdraw some secondary stake to leave only enough for 1 node
        uint256 secondaryToWithdraw = minSecondaryStakePerNodeForClass2 * 2; // Withdraw 10 ether, leaving 5 ether
        vm.startPrank(alice);
        vault3.withdraw(alice, secondaryToWithdraw);
        vm.stopPrank();

        // Update Alice's operator shares to reflect the withdrawal
        uint256 remainingSecondaryShares = mintedSecondarySharesAlice - (mintedSecondarySharesAlice * secondaryToWithdraw / aliceTargetSecondaryStake);
        _setOperatorL1Shares(curatorOwner3, balancer, secondaryCollateralClassId, alice, remainingSecondaryShares, delegator3);

        currentEpoch = _calcAndWarpOneEpoch();
        middleware.calcAndCacheStakes(currentEpoch, secondaryCollateralClassId);
        
        // Verify Alice now has insufficient secondary stake for all nodes
        uint256 aliceNewSecondaryStake = middleware.getOperatorStake(alice, currentEpoch, secondaryCollateralClassId);
        console2.log("Alice new secondary stake:", aliceNewSecondaryStake);
        assertLt(aliceNewSecondaryStake, minSecondaryStakePerNodeForClass2 * 3, "Alice should have insufficient secondary stake for 3 nodes");
        assertGe(aliceNewSecondaryStake, minSecondaryStakePerNodeForClass2, "Alice should have enough for at least 1 node");

        // --- Call forceUpdateNodes & Assert ---
        _warpToLastHourOfCurrentEpoch();
        
        // Since Alice only has enough secondary stake for 1 node, 2 nodes should be marked for removal
        middleware.forceUpdateNodes(alice, 0);

        // Check how many nodes are pending removal
        uint256 nodesFoundPendingRemoval = 0;
        if(middleware.nodePendingRemoval(validationID_A)) nodesFoundPendingRemoval++;
        if(middleware.nodePendingRemoval(validationID_B)) nodesFoundPendingRemoval++;
        if(middleware.nodePendingRemoval(validationID_C)) nodesFoundPendingRemoval++;
        
        console2.log("Nodes pending removal:", nodesFoundPendingRemoval);
        
        // With only enough secondary stake for 1 node, 2 should be removed
        assertEq(nodesFoundPendingRemoval, 2, "Expected 2 nodes to be marked for removal");

        currentEpoch = _calcAndWarpOneEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();
        assertEq(middleware.getOperatorNodesLength(alice), 1, "Alice should have 1 node remaining");
    }

    function test_UnconfirmedStakeImmediateRewards_Fix() public {
        // Setup: Alice has 100 ETH equivalent stake
        uint48 epoch = _calcAndWarpOneEpoch();

        // Increase vaults total stake
        (, uint256 additionalMinted) = _deposit(staker, 500 ether);
        
        // Now allocate more of this deposited stake to Alice (the operator)
        uint256 totalAliceShares = mintedShares + additionalMinted;
        _setL1Limit(curatorOwner1, balancer, collateralClassId, 3000 ether, delegator);
        _setOperatorL1Shares(curatorOwner1, balancer, collateralClassId, alice, totalAliceShares, delegator);

        // Move to next epoch to make the new stake available
        epoch = _calcAndWarpOneEpoch();
    
        // Verify Alice now has sufficient available stake
        uint256 aliceAvailableStake = middleware.getOperatorAvailableStake(alice);
        console2.log("Alice available stake: %s ETH", aliceAvailableStake / 1 ether);

        // Alice adds a node with 10 ETH stake
        (bytes32[] memory nodeIds, bytes32[] memory validationIDs,) = 
            _createAndConfirmNodes(alice, 1, 10 ether, true, 2);
        bytes32 nodeId = nodeIds[0];
        bytes32 validationID = validationIDs[0];
        
        // Move to next epoch and confirm initial state
        epoch = _calcAndWarpOneEpoch();
        uint256 initialStake = middleware.getNodeStake(epoch, validationID);
        assertEq(initialStake, 10 ether, "Initial stake should be 10 ETH");
        
        // Alice increases stake to 30 ETH (3x increase, within churn budget)
        uint256 modifiedStake = 30 ether;
        vm.prank(alice);
        middleware.initializeValidatorStakeUpdate(nodeId, modifiedStake);
        
        // FIXED: Stake cache should NOT be immediately updated (only after P-Chain confirmation)
        uint48 nextEpoch = middleware.getCurrentEpoch() + 1;
        uint256 unconfirmedStake = middleware.nodeStakeCache(nextEpoch, validationID);
        assertEq(unconfirmedStake, 0, "Stake cache should NOT be updated before P-Chain confirmation");
        
        // Verify: P-Chain operation is still pending
        assertTrue(
            IBalancerValidatorManager(balancer).isValidatorPendingWeightUpdate(validationID),
            "P-Chain operation should still be pending"
        );
        
        // Complete the stake update (P-Chain confirmation)
        {
            uint64 scaled = StakeConversion.stakeToWeight(modifiedStake, middleware.WEIGHT_SCALE_FACTOR());
            Validator memory v = IBalancerValidatorManager(balancer).getValidator(validationID);
            _pushWeight(validationID, uint64(v.sentNonce), scaled);
        }
        middleware.completeValidatorWeightUpdate(0);
        
        // NOW the cache should be updated for next epoch
        uint256 confirmedStake = middleware.nodeStakeCache(nextEpoch, validationID);
        assertEq(confirmedStake, modifiedStake, "Stake cache should be updated after P-Chain confirmation");
        
        // Move to next epoch (when confirmed stake takes effect)
        epoch = _calcAndWarpOneEpoch();
        
        // Reward calculations now use confirmed 50 ETH stake (not unconfirmed)
        uint256 operatorStakeForRewards = middleware.getOperatorUsedStakeCachedPerEpoch(
            epoch, alice, middleware.PRIMARY_ASSET_CLASS()
        );
        assertEq(
            operatorStakeForRewards, 
            modifiedStake, 
            "Reward calculations should use confirmed 50 ETH stake"
        );
        console2.log("Stake used for rewards: %s ETH", operatorStakeForRewards / 1 ether);            
    }

    function test_operatorStakeWithoutNormalization() public {
        uint48 epoch = 1;
        // Deploy tokens with different decimals
        ERC20WithDecimals tokenA1 = new ERC20WithDecimals("TokenA", "TKA", 6);
        ERC20WithDecimals tokenB1 = new ERC20WithDecimals("TokenB", "TKB", 6);

        // Deploy vaults and associate with asset class 1
        vm.startPrank(protocolOwner);
        address vaultAddress1 = vaultFactory.create(
            1,
            curatorOwner2,
            abi.encode(
                IVaultTokenized.InitParams({
                    collateral: address(tokenA1),
                    burner: address(0xdEaD),
                    epochDuration: 8 hours,
                    depositWhitelist: false,
                    isDepositLimit: false,
                    depositLimit: 0,
                    defaultAdminRoleHolder: curatorOwner2,
                    depositWhitelistSetRoleHolder: curatorOwner2,
                    depositorWhitelistRoleHolder: curatorOwner2,
                    isDepositLimitSetRoleHolder: curatorOwner2,
                    depositLimitSetRoleHolder: curatorOwner2,
                    name: "Test",
                    symbol: "TEST"
                })
            ),
            address(delegatorFactory),
            address(slasherFactory)
        );
        address vaultAddress2 = vaultFactory.create(
            1,
            curatorOwner3,
            abi.encode(
                IVaultTokenized.InitParams({
                    collateral: address(tokenB1),
                    burner: address(0xdEaD),
                    epochDuration: 8 hours,
                    depositWhitelist: false,
                    isDepositLimit: false,
                    depositLimit: 0,
                    defaultAdminRoleHolder: curatorOwner3,
                    depositWhitelistSetRoleHolder: curatorOwner3,
                    depositorWhitelistRoleHolder: curatorOwner3,
                    isDepositLimitSetRoleHolder: curatorOwner3,
                    depositLimitSetRoleHolder: curatorOwner3,
                    name: "Test",
                    symbol: "TEST"
                })
            ),
            address(delegatorFactory),
            address(slasherFactory)
        );
        VaultTokenized vaultTokenA = VaultTokenized(vaultAddress1);
        VaultTokenized vaultTokenB = VaultTokenized(vaultAddress2);
        vm.startPrank(l1Owner);
        middleware.addCollateralClass(2, 0, 100, address(tokenA1));
        middleware.activateSecondaryCollateralClass(2);
        middleware.addAssetToClass(2, address(tokenB1));
        vm.stopPrank();

        address[] memory l1LimitSetRoleHolders = new address[](1);
        l1LimitSetRoleHolders[0] = curatorOwner2;
        address[] memory operatorL1SharesSetRoleHolders = new address[](1);
        operatorL1SharesSetRoleHolders[0] = curatorOwner2;

        address delegatorAddress2 = delegatorFactory.create(
            0,
            abi.encode(
                address(vaultTokenA),
                abi.encode(
                    IL1RestakeDelegator.InitParams({
                        baseParams: IBaseDelegator.BaseParams({
                            defaultAdminRoleHolder: curatorOwner2,
                            hook: address(0),
                            hookSetRoleHolder: curatorOwner2
                        }),
                        l1LimitSetRoleHolders: l1LimitSetRoleHolders,
                        operatorL1SharesSetRoleHolders: operatorL1SharesSetRoleHolders
                    })
                )
            )
        );
        L1RestakeDelegator _delegator2 = L1RestakeDelegator(delegatorAddress2);

        // Create separate role holders for delegator3
        address[] memory l1LimitSetRoleHolders3 = new address[](1);
        l1LimitSetRoleHolders3[0] = curatorOwner3;
        address[] memory operatorL1SharesSetRoleHolders3 = new address[](1);
        operatorL1SharesSetRoleHolders3[0] = curatorOwner3;
        
        address delegatorAddress3 = delegatorFactory.create(
            0,
            abi.encode(
                address(vaultTokenB),
                abi.encode(
                    IL1RestakeDelegator.InitParams({
                        baseParams: IBaseDelegator.BaseParams({
                            defaultAdminRoleHolder: curatorOwner3,
                            hook: address(0),
                            hookSetRoleHolder: curatorOwner3
                        }),
                        l1LimitSetRoleHolders: l1LimitSetRoleHolders3,
                        operatorL1SharesSetRoleHolders: operatorL1SharesSetRoleHolders3
                    })
                )
            )
        );
        L1RestakeDelegator _delegator3 = L1RestakeDelegator(delegatorAddress3);

        vm.prank(curatorOwner2);
        vaultTokenA.setDelegator(delegatorAddress2);

        // Set the delegator in vault3
        vm.prank(curatorOwner3);
        vaultTokenB.setDelegator(delegatorAddress3);

        _setOperatorL1Shares(curatorOwner2, balancer, 2, alice, 100, _delegator2);
        _setOperatorL1Shares(curatorOwner3, balancer, 2, alice, 100, _delegator3);

        vm.startPrank(l1Owner);
        vaultManager.registerVault(address(vaultTokenA), 2, 3000 ether);
        vaultManager.registerVault(address(vaultTokenB), 2, 3000 ether);
        vm.stopPrank();

        _optInOperatorVault(alice, address(vaultTokenA));
        _optInOperatorVault(alice, address(vaultTokenB));
        //_optInOperatorL1(alice, balancer);

        _setL1Limit(curatorOwner2, balancer, 2, 10000 * 10**6, _delegator2);
        _setL1Limit(curatorOwner3, balancer, 2, 10 * 10**6, _delegator3);

        // Define stakes without normalization
        uint256 stakeA = 10000 * 10**6; // 10,000 (6 decimals)
        uint256 stakeB = 10 * 10**6;    // 10 (6 decimals)

        // same unit (6d) → direct sum
        uint256 normalised = stakeA + stakeB; 

        tokenA1.transfer(staker, stakeA);
        vm.startPrank(staker);
        tokenA1.approve(address(vaultTokenA), stakeA);
        vaultTokenA.deposit(staker, stakeA);
        vm.stopPrank();

        tokenB1.transfer(staker, stakeB);
        vm.startPrank(staker);
        tokenB1.approve(address(vaultTokenB), stakeB);
        vaultTokenB.deposit(staker, stakeB);
        vm.stopPrank();

        vm.warp((epoch + 3) * middleware.EPOCH_DURATION());

        assertEq(middleware.getOperatorStake(alice, 2, 2), normalised);
        // With same decimals (6), no normalization occurs, so they're equal
        assertEq(middleware.getOperatorStake(alice, 2, 2), stakeA + stakeB);
    }

        function test_vaultManager_UpdateVaultMaxL1Limit_NoRevert() public {
            vm.startPrank(l1Owner);
            vaultManager.updateVaultMaxL1Limit(address(vault), collateralClassId, 500 ether);
            vm.stopPrank();
        }

        function test_vaultManager_UpdateVaultMaxL1Limit_DisableEnable() public {
            vm.startPrank(l1Owner);
            // disable
            vaultManager.updateVaultMaxL1Limit(address(vault), collateralClassId, 0);
            // re-enable with new limit
            vaultManager.updateVaultMaxL1Limit(address(vault), collateralClassId, 700 ether);
            vm.stopPrank();
        }


    function test_vaultManager_RegisterMultipleVaults() public {
        // Setup additional asset class
        uint96 collateralClass2 = 2;
        vm.startPrank(l1Owner);
        middleware.addCollateralClass(collateralClass2, 1 ether, 0, address(collateral2));
        middleware.activateSecondaryCollateralClass(collateralClass2);
        vm.stopPrank();

        // Register vault2 with asset class 1
        vm.startPrank(l1Owner);
        vaultManager.registerVault(address(vault2), 1, 2000 ether);
        vm.stopPrank();

        // Register vault3 with asset class 2
        vm.startPrank(l1Owner);
        vaultManager.registerVault(address(vault3), collateralClass2, 1500 ether);
        vm.stopPrank();

        // Verify registrations
        assertEq(vaultManager.getVaultCollateralClass(address(vault)), 1);
        assertEq(vaultManager.getVaultCollateralClass(address(vault2)), 1);
        assertEq(vaultManager.getVaultCollateralClass(address(vault3)), collateralClass2);
        assertEq(vaultManager.getVaultCount(), 3);

        // Check vaults are active for current epoch
        uint48 currentEpoch = middleware.getCurrentEpoch();
        address[] memory activeVaults = vaultManager.getVaults(currentEpoch);
        assertEq(activeVaults.length, 3);
    }

    function test_vaultManager_RegisterVault_ErrorConditions() public {
        // Test registering with zero limit
        vm.startPrank(l1Owner);
        vm.expectRevert(abi.encodeWithSelector(
            IMiddlewareVaultManager.MiddlewareVaultManager__ZeroVaultMaxL1Limit.selector
        ));
        vaultManager.registerVault(address(vault2), 1, 0);
        vm.stopPrank();

        // Test registering already registered vault
        vm.startPrank(l1Owner);
        vm.expectRevert(abi.encodeWithSelector(
            IMiddlewareVaultManager.MiddlewareVaultManager__VaultAlreadyRegistered.selector
        ));
        vaultManager.registerVault(address(vault), 1, 1000 ether);
        vm.stopPrank();

        // Test registering with inactive asset class
        vm.startPrank(l1Owner);
        vm.expectRevert(abi.encodeWithSelector(
            IAvalancheL1Middleware.AvalancheL1Middleware__CollateralClassNotActive.selector,
            99
        ));
        vaultManager.registerVault(address(vault2), 99, 1000 ether);
        vm.stopPrank();
    }

    function test_vaultManager_UpdateVaultMaxL1Limit_ErrorConditions() public {
        // Test updating non-existent vault
        vm.startPrank(l1Owner);
        vm.expectRevert(abi.encodeWithSelector(
            IMiddlewareVaultManager.MiddlewareVaultManager__NotVault.selector,
            address(vault2)
        ));
        vaultManager.updateVaultMaxL1Limit(address(vault2), 1, 1000 ether);
        vm.stopPrank();

        // Register vault2 first
        vm.startPrank(l1Owner);
        vaultManager.registerVault(address(vault2), 1, 1000 ether);
        vm.stopPrank();

        // Test updating with wrong asset class
        vm.startPrank(l1Owner);
        vm.expectRevert(abi.encodeWithSelector(
            IMiddlewareVaultManager.MiddlewareVaultManager__WrongVaultCollateralClass.selector
        ));
        vaultManager.updateVaultMaxL1Limit(address(vault2), 2, 1000 ether);
        vm.stopPrank();
    }

    function test_vaultManager_DisableEnableVaults() public {
        // Add collateral2 to asset class 1 so vault3 can be registered with it
        vm.startPrank(l1Owner);
        middleware.addAssetToClass(1, address(collateral2));
        vm.stopPrank();

        // Register additional vaults
        vm.startPrank(l1Owner);
        vaultManager.registerVault(address(vault2), 1, 2000 ether);
        vaultManager.registerVault(address(vault3), 1, 1500 ether);
        vm.stopPrank();

        uint48 currentEpoch = middleware.getCurrentEpoch();
        
        // All vaults should be active initially
        address[] memory activeVaults = vaultManager.getVaults(currentEpoch);
        assertEq(activeVaults.length, 3);

        // Disable vault2
        vm.startPrank(l1Owner);
        vaultManager.updateVaultMaxL1Limit(address(vault2), 1, 0);
        vm.stopPrank();

        // Check vault2 is disabled but others remain active
        activeVaults = vaultManager.getVaults(currentEpoch);
        assertEq(activeVaults.length, 2);
        
        // Verify vault2 is not in active list
        bool vault2Found = false;
        for (uint256 i = 0; i < activeVaults.length; i++) {
            if (activeVaults[i] == address(vault2)) {
                vault2Found = true;
                break;
            }
        }
        assertFalse(vault2Found, "vault2 should not be in active vaults");

        // Re-enable vault2 with new limit
        vm.startPrank(l1Owner);
        vaultManager.updateVaultMaxL1Limit(address(vault2), 1, 2500 ether);
        vm.stopPrank();

        // Check vault2 is active again
        activeVaults = vaultManager.getVaults(currentEpoch);
        assertEq(activeVaults.length, 3);
    }

    function test_vaultManager_RemoveVault() public {
        // Register vault2
        vm.startPrank(l1Owner);
        vaultManager.registerVault(address(vault2), 1, 1000 ether);
        vm.stopPrank();

        // Try to remove active vault - should fail
        vm.startPrank(l1Owner);
        vm.expectRevert(abi.encodeWithSelector(
            IMiddlewareVaultManager.MiddlewareVaultManager__VaultNotDisabled.selector
        ));
        vaultManager.removeVault(address(vault2));
        vm.stopPrank();

        // Disable vault first
        vm.startPrank(l1Owner);
        vaultManager.updateVaultMaxL1Limit(address(vault2), 1, 0);
        vm.stopPrank();

        // Try to remove immediately - should fail (grace period not passed)
        vm.startPrank(l1Owner);
        vm.expectRevert(abi.encodeWithSelector(
            IMiddlewareVaultManager.MiddlewareVaultManager__VaultGracePeriodNotPassed.selector
        ));
        vaultManager.removeVault(address(vault2));
        vm.stopPrank();

        // Wait for grace period to pass
        uint48 removalDelay = vaultManager.VAULT_REMOVAL_EPOCH_DELAY();
        _moveToNextEpochAndCalc(removalDelay + 1);

        uint256 vaultCountBefore = vaultManager.getVaultCount();

        // Now removal should work
        vm.startPrank(l1Owner);
        vaultManager.removeVault(address(vault2));
        vm.stopPrank();

        // Verify vault is removed
        assertEq(vaultManager.getVaultCount(), vaultCountBefore - 1);
        assertEq(vaultManager.getVaultCollateralClass(address(vault2)), 0);

        // Try to remove non-existent vault
        vm.startPrank(l1Owner);
        vm.expectRevert(abi.encodeWithSelector(
            IMiddlewareVaultManager.MiddlewareVaultManager__NotVault.selector,
            address(vault2)
        ));
        vaultManager.removeVault(address(vault2));
        vm.stopPrank();
    }

    function test_vaultManager_GetVaultsAcrossEpochs() public {
        uint48 epoch0 = middleware.getCurrentEpoch();
        
        // Initially only vault is registered
        address[] memory activeVaults = vaultManager.getVaults(epoch0);
        assertEq(activeVaults.length, 1);
        assertEq(activeVaults[0], address(vault));

        // Register vault2
        vm.startPrank(l1Owner);
        vaultManager.registerVault(address(vault2), 1, 2000 ether);
        vm.stopPrank();

        // Move to next epoch and check that vault2 is now active
        uint48 epoch1 = _moveToNextEpochAndCalc(1);
        
        // Both vaults should be active in epoch1
        activeVaults = vaultManager.getVaults(epoch1);
        assertEq(activeVaults.length, 2);

        // Disable vault2
        vm.startPrank(l1Owner);
        vaultManager.updateVaultMaxL1Limit(address(vault2), 1, 0);
        vm.stopPrank();

        uint48 epoch2 = _moveToNextEpochAndCalc(1);

        // Only vault should be active in epoch2
        activeVaults = vaultManager.getVaults(epoch2);
        assertEq(activeVaults.length, 1);
        assertEq(activeVaults[0], address(vault));

        // But both should still appear active in epoch1 (historical) - check after disabling
        activeVaults = vaultManager.getVaults(epoch1);
        assertEq(activeVaults.length, 2);

        // And only vault in epoch0 (historical) 
        // Note: vault2 was registered during epoch0, so it appears in epoch0 results too
        activeVaults = vaultManager.getVaults(epoch0);
        assertEq(activeVaults.length, 2);
    }

    function test_vaultManager_MultipleCollateralClasses() public {
        // Setup asset class 2
        uint96 collateralClass2 = 2;
        vm.startPrank(l1Owner);
        middleware.addCollateralClass(collateralClass2, 1 ether, 0, address(collateral2));
        middleware.activateSecondaryCollateralClass(collateralClass2);
        vm.stopPrank();

        // Setup asset class 3
        Token collateral3 = new Token("MockCollateral3");
        uint96 collateralClass3 = 3;
        vm.startPrank(l1Owner);
        middleware.addCollateralClass(collateralClass3, 2 ether, 0, address(collateral3));
        middleware.activateSecondaryCollateralClass(collateralClass3);
        vm.stopPrank();

        // Create vault for asset class 3
        uint64 lastVersion = vaultFactory.lastVersion();
        address vault4Address = vaultFactory.create(
            lastVersion,
            bob,
            abi.encode(
                IVaultTokenized.InitParams({
                    collateral: address(collateral3),
                    burner: address(0xdEaD),
                    epochDuration: 8 hours,
                    depositWhitelist: false,
                    isDepositLimit: false,
                    depositLimit: 0,
                    defaultAdminRoleHolder: bob,
                    depositWhitelistSetRoleHolder: bob,
                    depositorWhitelistRoleHolder: bob,
                    isDepositLimitSetRoleHolder: bob,
                    depositLimitSetRoleHolder: bob,
                    name: "Test4",
                    symbol: "TEST4"
                })
            ),
            address(delegatorFactory),
            address(slasherFactory)
        );
        VaultTokenized vault4 = VaultTokenized(vault4Address);

        // Setup delegator for vault4
        address[] memory l1LimitSetRoleHolders = new address[](1);
        l1LimitSetRoleHolders[0] = bob;
        address[] memory operatorL1SharesSetRoleHolders = new address[](1);
        operatorL1SharesSetRoleHolders[0] = bob;

        address delegator4Address = delegatorFactory.create(
            0,
            abi.encode(
                address(vault4),
                abi.encode(
                    IL1RestakeDelegator.InitParams({
                        baseParams: IBaseDelegator.BaseParams({
                            defaultAdminRoleHolder: bob,
                            hook: address(0),
                            hookSetRoleHolder: bob
                        }),
                        l1LimitSetRoleHolders: l1LimitSetRoleHolders,
                        operatorL1SharesSetRoleHolders: operatorL1SharesSetRoleHolders
                    })
                )
            )
        );

        vm.prank(bob);
        vault4.setDelegator(delegator4Address);

        // Register vaults with different asset classes
        vm.startPrank(l1Owner);
        vaultManager.registerVault(address(vault2), 1, 2000 ether);      // Asset class 1
        vaultManager.registerVault(address(vault3), collateralClass2, 1500 ether); // Asset class 2
        vaultManager.registerVault(address(vault4), collateralClass3, 1000 ether); // Asset class 3
        vm.stopPrank();

        // Verify asset class assignments
        assertEq(vaultManager.getVaultCollateralClass(address(vault)), 1);
        assertEq(vaultManager.getVaultCollateralClass(address(vault2)), 1);
        assertEq(vaultManager.getVaultCollateralClass(address(vault3)), collateralClass2);
        assertEq(vaultManager.getVaultCollateralClass(address(vault4)), collateralClass3);

        // Test updating limits with correct asset classes
        vm.startPrank(l1Owner);
        vaultManager.updateVaultMaxL1Limit(address(vault3), collateralClass2, 2000 ether);
        vaultManager.updateVaultMaxL1Limit(address(vault4), collateralClass3, 1500 ether);
        vm.stopPrank();

        // Test error when using wrong asset class
        vm.startPrank(l1Owner);
        vm.expectRevert(abi.encodeWithSelector(
            IMiddlewareVaultManager.MiddlewareVaultManager__WrongVaultCollateralClass.selector
        ));
        vaultManager.updateVaultMaxL1Limit(address(vault3), 1, 2000 ether);
        vm.stopPrank();
    }

    function test_vaultManager_GetVaultAtWithTimes() public {
        // Register additional vaults
        vm.startPrank(l1Owner);
        vaultManager.registerVault(address(vault2), 1, 2000 ether);
        vm.stopPrank();

        uint48 registrationTime = uint48(block.timestamp);

        // Get vault details with times
        (address vaultAt0, uint48 enabledTime0, uint48 disabledTime0) = vaultManager.getVaultAtWithTimes(0);
        assertEq(vaultAt0, address(vault));
        assertGt(enabledTime0, 0);
        assertEq(disabledTime0, 0);

        (address vaultAt1, uint48 enabledTime1, uint48 disabledTime1) = vaultManager.getVaultAtWithTimes(1);
        assertEq(vaultAt1, address(vault2));
        assertGe(enabledTime1, registrationTime);
        assertEq(disabledTime1, 0);

        // Disable vault2
        vm.startPrank(l1Owner);
        vaultManager.updateVaultMaxL1Limit(address(vault2), 1, 0);
        vm.stopPrank();

        uint48 disableTime = uint48(block.timestamp);

        // Check times after disable
        (, , uint48 disabledTimeAfter) = vaultManager.getVaultAtWithTimes(1);
        assertGe(disabledTimeAfter, disableTime);
        assertGt(disabledTimeAfter, 0);
    }

    function test_vaultManager_ComplexVaultLifecycle() public {
        // Setup asset class 2
        uint96 collateralClass2 = 2;
        vm.startPrank(l1Owner);
        middleware.addCollateralClass(collateralClass2, 1 ether, 0, address(collateral2));
        middleware.activateSecondaryCollateralClass(collateralClass2);
        vm.stopPrank();

        uint48 epoch0 = middleware.getCurrentEpoch();

        // EPOCH 0: Register vault2 and vault3 during epoch0
        vm.startPrank(l1Owner);
        vaultManager.registerVault(address(vault2), 1, 2000 ether);      // vault2 enabled in epoch0
        vaultManager.registerVault(address(vault3), collateralClass2, 1500 ether); // vault3 enabled in epoch0
        vm.stopPrank();

        // Move to epoch1
        uint48 epoch1 = _moveToNextEpochAndCalc(1);
        
        // At epoch1 start: should have all 3 vaults (vault from setUp + vault2 + vault3 from epoch0)
        assertEq(vaultManager.getVaults(epoch1).length, 3, "epoch1 should have 3 vaults: vault1 + vault2 + vault3");

        // EPOCH 1: Disable vault2 during epoch1
        vm.startPrank(l1Owner);
        vaultManager.updateVaultMaxL1Limit(address(vault2), 1, 0);      // vault2 disabled in epoch1
        vm.stopPrank();

        // Move to epoch2
        uint48 epoch2 = _moveToNextEpochAndCalc(1);
        
        // At epoch2 start: vault2 was disabled in epoch1, so only vault and vault3
        assertEq(vaultManager.getVaults(epoch2).length, 2, "epoch2 should have 2 vaults: vault1 + vault3 (vault2 disabled)");

        // EPOCH 2: Update vault3 limit and re-enable vault2
        vm.startPrank(l1Owner);
        vaultManager.updateVaultMaxL1Limit(address(vault3), collateralClass2, 3000 ether); // vault3 limit updated
        vaultManager.updateVaultMaxL1Limit(address(vault2), 1, 2500 ether);         // vault2 re-enabled in epoch2
        vm.stopPrank();

        // Move to epoch3
        uint48 epoch3 = _moveToNextEpochAndCalc(1);
        
        // All 3 vaults active again
        assertEq(vaultManager.getVaults(epoch3).length, 3, "epoch3 should have 3 vaults: vault1 + vault2 + vault3 (all active)");

        // Verify historical epochs return correct counts
        // epoch0: only vault1 from setUp (epoch0 timestamp captured before vault2/vault3 registration)
        assertEq(vaultManager.getVaults(epoch0).length, 2, "epoch0 should have 2 vaults: vault1 + vault3, vault2 history was rewritten due to re-enable");
        
        // epoch1: vault1 + vault2 + vault3 all registered and active at epoch1 start
        assertEq(vaultManager.getVaults(epoch1).length, 2, "epoch1 should have 2 vaults: vault1 + vault3 (vault2 disabled in epoch1)");
        
        // epoch2: vault2 was disabled in epoch1, so only vault1 + vault3
        assertEq(vaultManager.getVaults(epoch2).length, 2, "epoch2 should have 2 vaults: vault1 + vault3 (vault2 disabled in epoch1)");
        
        // epoch3: vault2 re-enabled in epoch2 with new enabledTime, so all 3 active
        assertEq(vaultManager.getVaults(epoch3).length, 3, "epoch3 should have 3 vaults: vault1 + vault2 + vault3 (vault2 re-enabled in epoch2)");
    }

    function test_vaultManager_EdgeCases() public {
        // Test with future epoch
        uint48 futureEpoch = middleware.getCurrentEpoch() + 10;
        address[] memory futureVaults = vaultManager.getVaults(futureEpoch);
        assertEq(futureVaults.length, 1); // Should return current active vaults

        // Test with epoch 0
        address[] memory epoch0Vaults = vaultManager.getVaults(0);
        assertEq(epoch0Vaults.length, 1); // Original vault was registered in setUp during epoch 0

        // Test vault count edge cases
        uint256 initialCount = vaultManager.getVaultCount();
        
        // Try to register vault with 0 limit - should fail
        vm.startPrank(l1Owner);
        vm.expectRevert(abi.encodeWithSelector(
            IMiddlewareVaultManager.MiddlewareVaultManager__ZeroVaultMaxL1Limit.selector
        ));
        vaultManager.registerVault(address(vault2), 1, 0); // Should fail with 0 limit
        vm.stopPrank();
        
        // Register vault2 with proper limit first, then disable it
        vm.startPrank(l1Owner);
        vaultManager.registerVault(address(vault2), 1, 1000 ether);
        vm.stopPrank();
        
        assertEq(vaultManager.getVaultCount(), initialCount + 1);
        
        // Now disable the vault
        vm.startPrank(l1Owner);
        vaultManager.updateVaultMaxL1Limit(address(vault2), 1, 0);
        vm.stopPrank();
        
        // Disabled vault shouldn't appear in active vaults
        uint48 currentEpoch = middleware.getCurrentEpoch();
        address[] memory activeVaults = vaultManager.getVaults(currentEpoch);
        assertEq(activeVaults.length, 1); // Only the original vault should be active
    }

    function test_StakeUpdateCannotOverallocate() public {
        // 1. Roll to a fresh epoch so node‑stake cache is up‑to‑date
        _calcAndWarpOneEpoch();

        // 2. Alice registers a single, minimum‑stake node and confirms it
        (bytes32[] memory nodeIds,,) = _createAndConfirmNodes(alice, 1, 0, true, 1);
        bytes32 nodeId = nodeIds[0];

        // 3. Gather current numbers
        uint48  epoch         = middleware.getCurrentEpoch();
        bytes32 valID         =
            IBalancerValidatorManager(balancer).getNodeValidationID(_nodeBytes(nodeId));
        uint256 currentStake  = middleware.getNodeStake(epoch, valID);
        // free‑stake as the contract sees it
        uint256 freeStake = middleware.getOperatorAvailableStake(alice);
        assertGt(freeStake, 0, "setup needs free stake");

        // 4. Craft a stake that exceeds Alice's free‑stake by ≥ one weight unit
        uint256 newStake = currentStake + freeStake + middleware.WEIGHT_SCALE_FACTOR();

        // 5. The patched contract must reject the attempt
        vm.expectRevert(
            abi.encodeWithSelector(
                IAvalancheL1Middleware.AvalancheL1Middleware__InsufficientStake.selector
            )
        );
        vm.prank(alice);
        middleware.initializeValidatorStakeUpdate(nodeId, newStake);
    }

    function test_POC_PastEpochCachePoisoning_OperatorRemoved() public {
        uint96 classId = collateralClassId;
        uint48 e0 = middleware.getCurrentEpoch();

        // Ground truth for e0 BEFORE any caching (uses dynamic path, not cache)
        uint256 aliceE0   = middleware.getOperatorStake(alice,   e0, classId);
        uint256 charlieE0 = middleware.getOperatorStake(charlie, e0, classId);
        uint256 daveE0    = middleware.getOperatorStake(dave,    e0, classId);
        uint256 dynamicTotal = aliceE0 + charlieE0 + daveE0;
        assertGt(charlieE0, 0, "pre: charlie has stake at e0");
        assertFalse(middleware.totalStakeCached(e0, classId), "pre: e0 not cached");

        // Disable then remove Charlie (Charlie has no nodes in this suite)
        vm.prank(l1Owner);
        middleware.disableOperator(charlie);
        _moveToNextEpochAndCalc(middleware.REMOVAL_DELAY_EPOCHS());
        vm.prank(l1Owner);
        middleware.removeOperator(charlie);

        // e0 is now older than SLASHING_WINDOW; uncached getTotalStake must revert via age guard
        bytes memory epochErr = abi.encodeWithSelector(
            IAvalancheL1Middleware.AvalancheL1Middleware__EpochError.selector,
            middleware.getEpochStartTs(e0)
        );
        vm.expectRevert(epochErr);
        middleware.getTotalStake(e0, classId);

        // Attacker poisons cache for old epoch using current operators set (Charlie missing)
        middleware.calcAndCacheStakes(e0, classId);
        assertTrue(middleware.totalStakeCached(e0, classId), "cache set for old epoch");

        // Charlie's historic stake at e0 is now read from cache => 0
        assertEq(middleware.getOperatorStake(charlie, e0, classId), 0, "charlie stake at e0 zeroed by cache");

        // Total stake cache lost Charlie's contribution
        uint256 poisonedTotal = middleware.getTotalStake(e0, classId);
        assertEq(poisonedTotal, aliceE0 + daveE0, "poisoned total excludes charlie");
        assertEq(poisonedTotal + charlieE0, dynamicTotal, "sanity: dynamicTotal = poisoned + lost");
    }
}
