// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import {
    IWarpMessenger,
    WarpMessage,
    WarpBlockHash
} from "@avalabs/subnet-evm-contracts@1.2.0/contracts/interfaces/IWarpMessenger.sol";
import {ValidatorMessages} from "@avalabs/icm-contracts/validator-manager/ValidatorMessages.sol";

contract MockWarpMessenger is IWarpMessenger {
    // Constants for uptime values from tests
    uint64 constant TWO_HOURS = 2 * 60 * 60;
    uint64 constant THREE_HOURS = 3 * 60 * 60;
    uint64 constant ONE_HOUR = 1 * 60 * 60;
    uint64 constant FOUR_HOURS = 4 * 60 * 60;
    uint64 constant FIVE_HOURS = 5 * 60 * 60;
    uint64 constant SEVEN_HOURS = 7 * 60 * 60;
    uint64 constant SIX_HOURS = 6 * 60 * 60;
    uint64 constant TWELVE_HOURS = 12 * 60 * 60;
    uint64 constant ZERO_HOURS = 0;

    // Hardcoded full node IDs based on previous test traces/deterministic generation
    // These values MUST match what operatorNodes would be in UptimeTrackerTest.setUp()
    // from your MockAvalancheL1Middleware.
    // If MockAvalancheL1Middleware changes its node generation, these must be updated.
    bytes32 constant OP_NODE_0_FULL = 0xe917244df122a1996142a1cd6c7269c136c20f47acd1ff079ee7247cae2f45c5;
    bytes32 constant OP_NODE_1_FULL = 0x69e183f32216866f48b0c092f70d99378e18023f7185e52eeee2f5bbd5255293;
    bytes32 constant OP_NODE_2_FULL = 0xfcc09d5775472c6fa988b216f5ce189894c14e093527f732b9b65da0880b5f81;

    // Constructor is now empty as we are not storing operatorNodes passed from test.
    // constructor() {} // Can be omitted for an empty constructor

    function getDerivedValidationID(bytes32 fullNodeID) internal pure returns (bytes32) {
        // Corrected conversion: bytes32 -> uint256 -> uint160 -> uint256 -> bytes32
        return bytes32(uint256(uint160(uint256(fullNodeID))));
    }

    function getVerifiedWarpMessage(
        uint32 messageIndex
    ) external view override returns (WarpMessage memory, bool) {
        // The 'require' for _operatorNodes.length is removed.

        bytes32 derivedNode0ID = getDerivedValidationID(OP_NODE_0_FULL);
        bytes32 derivedNode1ID = getDerivedValidationID(OP_NODE_1_FULL);
        bytes32 derivedNode2ID = getDerivedValidationID(OP_NODE_2_FULL);
        bytes memory payload;

        // test_ComputeValidatorUptime & test_ValidatorUptimeEvent
        if (messageIndex == 0) {
            payload = ValidatorMessages.packValidationUptimeMessage(derivedNode0ID, TWO_HOURS);
        } else if (messageIndex == 1) {
            payload = ValidatorMessages.packValidationUptimeMessage(derivedNode0ID, THREE_HOURS);
        }
        // test_ComputeOperatorUptime - first epoch (0) & test_OperatorUptimeEvent
        else if (messageIndex == 2) {
            payload = ValidatorMessages.packValidationUptimeMessage(derivedNode0ID, TWO_HOURS);
        } else if (messageIndex == 3) {
            payload = ValidatorMessages.packValidationUptimeMessage(derivedNode1ID, THREE_HOURS);
        } else if (messageIndex == 4) {
            payload = ValidatorMessages.packValidationUptimeMessage(derivedNode2ID, ONE_HOUR);
        }
        // test_ComputeOperatorUptime - second epoch (1)
        else if (messageIndex == 5) {
            payload = ValidatorMessages.packValidationUptimeMessage(derivedNode0ID, FOUR_HOURS);
        } else if (messageIndex == 6) {
            payload = ValidatorMessages.packValidationUptimeMessage(derivedNode1ID, FOUR_HOURS);
        } else if (messageIndex == 7) {
            payload = ValidatorMessages.packValidationUptimeMessage(derivedNode2ID, FOUR_HOURS);
        }
        // test_ComputeOperatorUptime - third epoch (2)
        else if (messageIndex == 8) {
            payload = ValidatorMessages.packValidationUptimeMessage(derivedNode0ID, FIVE_HOURS);
        } else if (messageIndex == 9) {
            payload = ValidatorMessages.packValidationUptimeMessage(derivedNode1ID, SEVEN_HOURS);
        } else if (messageIndex == 10) {
            payload = ValidatorMessages.packValidationUptimeMessage(derivedNode2ID, SIX_HOURS);
        }
        // test_EdgeCases
        else if (messageIndex == 11) {
            payload = ValidatorMessages.packValidationUptimeMessage(derivedNode0ID, FOUR_HOURS); // EPOCH_DURATION
        } else if (messageIndex == 12) {
            payload = ValidatorMessages.packValidationUptimeMessage(derivedNode1ID, ZERO_HOURS);
        } else if (messageIndex == 13) {
            payload = ValidatorMessages.packValidationUptimeMessage(derivedNode0ID, TWELVE_HOURS); // 3 * EPOCH_DURATION
        } else {
            return (WarpMessage({sourceChainID: bytes32(uint256(1)), originSenderAddress: address(0), payload: new bytes(0)}), false);
        }

        return (
            WarpMessage({
                sourceChainID: bytes32(uint256(1)),
                originSenderAddress: address(0),
                payload: payload
            }),
            true
        );
    }

    function sendWarpMessage(
        bytes memory // message
    ) external pure override returns (bytes32) { // messageID
        return bytes32(0);
    }

    function getBlockchainID() external pure override returns (bytes32) {
        return bytes32(uint256(1));
    }

    function getVerifiedWarpBlockHash(
        uint32 // messageIndex
    ) external pure override returns (WarpBlockHash memory warpBlockHash, bool valid) {
        warpBlockHash = WarpBlockHash({sourceChainID: bytes32(uint256(1)), blockHash: bytes32(0)});
        valid = true;
    }
}
