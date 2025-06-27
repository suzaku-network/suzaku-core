//
// PoC – “Phantom” / Irremovable Node
// Shows how a node can be removed *logically* on the P-Chain yet remain stuck
// inside `operatorNodesArray`, blowing up storage & breaking future logic.
//
import {AvalancheL1MiddlewareTest} from "./AvalancheL1MiddlewareTest.t.sol";
import {PChainOwner} from "@avalabs/teleporter/validator-manager/interfaces/IValidatorManager.sol";
import {StakeConversion} from "src/contracts/middleware/libraries/StakeConversion.sol";
import {console2} from "forge-std/console2.sol";

contract PoCIrremovableNode is AvalancheL1MiddlewareTest {
    /// Demonstrates *expected* vs *buggy* behaviour side-by-side
    function test_PoCIrremovableNode() public {
        //
        // 1) NORMAL FLOW – node can be removed
        //
        console2.log("=== NORMAL FLOW ===");
        vm.startPrank(alice);
        // Create a fresh nodeId so it is unique for Alice
        bytes32 nodeId = keccak256(abi.encodePacked(alice, "node-A", block.timestamp));
        console2.log("Registering nodeA");
        middleware.addNode(
            nodeId,
            hex"ABABABAB",
            // dummy BLS key
            uint64(block.timestamp + 2 days),
            // expiry
            PChainOwner({threshold: 1, addresses: new address[](0)}),
            PChainOwner({threshold: 1, addresses: new address[](0)}),
            100_000_000_000_000
            // stake
        );
        // Complete registration on the mock validator manager
        uint32 regMsgIdx = mockValidatorManager.nextMessageIndex() - 1;
        middleware.completeValidatorRegistration(alice, nodeId, regMsgIdx);
        console2.log("nodeA registered");
        // Length should now be 1
        assertEq(middleware.getOperatorNodesLength(alice), 1);
        
        // Initiate removal
        console2.log("Removing nodeA");
        middleware.removeNode(nodeId);
        vm.stopPrank();
        
        // Advance 1 epoch so stake caches roll over
        _calcAndWarpOneEpoch();
        
        // Confirm removal from P-Chain and complete it on L1
        uint32 rmMsgIdx = mockValidatorManager.nextMessageIndex() - 1;
        vm.prank(alice);
        middleware.completeValidatorRemoval(rmMsgIdx);
        console2.log("nodeA removal completed");
        
        // Now node array should be empty
        assertEq(middleware.getOperatorNodesLength(alice), 0);
        console2.log("NORMAL FLOW success: array length = 0\n");
        
        //
        // 2) BUGGY FLOW – removal inside same epoch phantom entry
        //
        console2.log("=== BUGGY FLOW (same epoch) ===");
        vm.startPrank(alice);
        
        // Re-use *same* nodeId to simulate quick re-registration
        console2.log("Registering nodeA in the SAME epoch");
        middleware.addNode(
            nodeId,
            // same id!
            hex"ABABABAB",
            uint64(block.timestamp + 2 days),
            PChainOwner({threshold: 1, addresses: new address[](0)}),
            PChainOwner({threshold: 1, addresses: new address[](0)}),
            100_000_000_000_000
        );
        uint32 regMsgIdx2 = mockValidatorManager.nextMessageIndex() - 1;
        middleware.completeValidatorRegistration(alice, nodeId, regMsgIdx2);
        console2.log("nodeA (second time) registered");
        
        // Expect length == 1 again
        assertEq(middleware.getOperatorNodesLength(alice), 1);
        
        // Remove immediately
        console2.log("Immediately removing nodeA again");
        middleware.removeNode(nodeId);
        
        // Complete removal *still inside the same epoch* (simulating fast warp msg)
        uint32 rmMsgIdx2 = mockValidatorManager.nextMessageIndex() - 1;
        middleware.completeValidatorRemoval(rmMsgIdx2);
        console2.log("nodeA (second time) removal completed");
        vm.stopPrank();
        
        // Advance to next epoch
        _calcAndWarpOneEpoch();
        
        // BUG: array length is STILL 1 → phantom node stuck forever
        uint256 lenAfter = middleware.getOperatorNodesLength(alice);
        assertEq(lenAfter, 0, "Phantom node should have changed to 0 afer fix");
        console2.log("BUGGY FLOW reproduced: node is irremovable.");
    }
}
