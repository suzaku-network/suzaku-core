// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

//
// PoC – "Phantom" / Irremovable Node
// Shows how a node can be removed *logically* on the P-Chain yet remain stuck
// inside `operatorNodesArray`, blowing up storage & breaking future logic.
//
import {MiddlewareTestBase} from "./MiddlewareTestBase.t.sol";
import {PChainOwner} from "@avalabs/icm-contracts/validator-manager/interfaces/IACP99Manager.sol";
import {StakeConversion} from "src/contracts/middleware/libraries/StakeConversion.sol";
import {console2} from "forge-std/console2.sol";
import {IBalancerValidatorManager} from "@suzaku/contracts-library/interfaces/ValidatorManager/IBalancerValidatorManager.sol";

contract AvalancheL1MiddlewareNodeRemovalTest is MiddlewareTestBase {
    /// Demonstrates *expected* vs *buggy* behaviour side-by-side
    function test_PhantomNodeRemovalBehavior() public {
        //
        // 1) NORMAL FLOW – node can be removed
        //
        console2.log("=== NORMAL FLOW ===");
        bytes32 nodeId = keccak256(abi.encodePacked(alice, "node-A", block.timestamp));

        // Add & confirm
        vm.prank(alice);
        middleware.addNode(nodeId, new bytes(48), _pOwner1(alice), _pOwner1(alice), 100_000_000_000_000);

        // Resolve L1 validationID for this nodeId
        bytes32 valId = IBalancerValidatorManager(balancer).getNodeValidationID(_nodeBytes(nodeId));

        // Push registration ack, then complete(0)
        _pushRegistrationAck(valId, true);
        middleware.completeValidatorRegistration(0);

        assertEq(middleware.getOperatorNodesLength(alice), 1);

        // Remove
        vm.prank(alice);
        middleware.removeNode(nodeId);

        // Advance one epoch so stake cache rolls over
        _calcAndWarpOneEpoch();

        // Push removal ack, then complete(0)
        _pushRemovalAck(valId);
        middleware.completeValidatorRemoval(0);

        // Array should be empty now
        assertEq(middleware.getOperatorNodesLength(alice), 0);
        console2.log("NORMAL FLOW success: array length = 0\n");

        //
        // 2) SAME-EPOCH RE-REGISTER & REMOVE – ensure no phantom entry
        //
        console2.log("=== SAME-EPOCH RE-REGISTER ===");

        // Re-use *same* nodeId; add & confirm again
        vm.prank(alice);
        middleware.addNode(nodeId, new bytes(48), _pOwner1(alice), _pOwner1(alice), 100_000_000_000_000);

        bytes32 valId2 = IBalancerValidatorManager(balancer).getNodeValidationID(_nodeBytes(nodeId));
        _pushRegistrationAck(valId2, true);
        middleware.completeValidatorRegistration(0);

        assertEq(middleware.getOperatorNodesLength(alice), 1);

        // Remove immediately in the same epoch
        vm.prank(alice);
        middleware.removeNode(nodeId);

        // Complete removal in the same epoch (push ack, then complete)
        _pushRemovalAck(valId2);
        middleware.completeValidatorRemoval(0);

        // Advance to next epoch to finalize caches
        _calcAndWarpOneEpoch();

        // No phantom: length must be 0 after fix
        uint256 lenAfter = middleware.getOperatorNodesLength(alice);
        assertEq(lenAfter, 0, "Phantom node should have changed to 0 after fix");
    }
}
