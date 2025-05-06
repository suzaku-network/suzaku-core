// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import {
    IWarpMessenger,
    WarpMessage,
    WarpBlockHash
} from "@avalabs/subnet-evm-contracts@1.2.0/contracts/interfaces/IWarpMessenger.sol";

contract MockWarpMessenger is IWarpMessenger {
    // mapping(uint32 => WarpMessage) private messages;
    // mapping(uint32 => bool) private messageValidity;

    // // Function to set a mock message for testing
    // function setWarpMessage(WarpMessage memory warpMessage, uint32 messageIndex) external {
    //     messages[messageIndex] = warpMessage;
    //     messageValidity[messageIndex] = true;
    // }

    function getVerifiedWarpMessage(
        uint32 messageIndex
    ) external pure returns (WarpMessage memory, bool) {
        // test_ComputeValidatorUptime
        if (messageIndex == 0) {
            return (
                WarpMessage({
                    sourceChainID: bytes32(0),
                    originSenderAddress: address(0),
                    payload: hex"000000000000e917244df122a1996142a1cd6c7269c136c20f47acd1ff079ee7247cae2f45c50000000000001c20" // 2 hours
                }),
                true
            );
        } else if (messageIndex == 1) {
            return (
                WarpMessage({
                    sourceChainID: bytes32(0),
                    originSenderAddress: address(0),
                    payload: hex"000000000000e917244df122a1996142a1cd6c7269c136c20f47acd1ff079ee7247cae2f45c50000000000002a30" // 3 hours
                }),
                true
            );
        }
        // test_ComputeOperatorUptime - first epoch (0)
        else if (messageIndex == 2) {
            return (
                WarpMessage({
                    sourceChainID: bytes32(0),
                    originSenderAddress: address(0),
                    payload: hex"000000000000e917244df122a1996142a1cd6c7269c136c20f47acd1ff079ee7247cae2f45c50000000000001c20" // 2 hours for node 0
                }),
                true
            );
        } else if (messageIndex == 3) {
            return (
                WarpMessage({
                    sourceChainID: bytes32(0),
                    originSenderAddress: address(0),
                    payload: hex"00000000000069e183f32216866f48b0c092f70d99378e18023f7185e52eeee2f5bbd52552930000000000002a30" // 3 hours for node 1
                }),
                true
            );
        } else if (messageIndex == 4) {
            return (
                WarpMessage({
                    sourceChainID: bytes32(0),
                    originSenderAddress: address(0),
                    payload: hex"000000000000fcc09d5775472c6fa988b216f5ce189894c14e093527f732b9b65da0880b5f810000000000000e10" // 1 hour for node 2
                }),
                true
            );
        }
        // test_ComputeOperatorUptime - second epoch (1)
        else if (messageIndex == 5) {
            return (
                WarpMessage({
                    sourceChainID: bytes32(0),
                    originSenderAddress: address(0),
                    payload: hex"000000000000e917244df122a1996142a1cd6c7269c136c20f47acd1ff079ee7247cae2f45c50000000000003840" // 4 hours for node 0
                }),
                true
            );
        } else if (messageIndex == 6) {
            return (
                WarpMessage({
                    sourceChainID: bytes32(0),
                    originSenderAddress: address(0),
                    payload: hex"00000000000069e183f32216866f48b0c092f70d99378e18023f7185e52eeee2f5bbd52552930000000000003840" // 4 hours for node 1
                }),
                true
            );
        } else if (messageIndex == 7) {
            return (
                WarpMessage({
                    sourceChainID: bytes32(0),
                    originSenderAddress: address(0),
                    payload: hex"000000000000fcc09d5775472c6fa988b216f5ce189894c14e093527f732b9b65da0880b5f810000000000003840" // 4 hours for node 2
                }),
                true
            );
        }
        // test_ComputeOperatorUptime - third epoch (2)
        else if (messageIndex == 8) {
            return (
                WarpMessage({
                    sourceChainID: bytes32(0),
                    originSenderAddress: address(0),
                    payload: hex"000000000000e917244df122a1996142a1cd6c7269c136c20f47acd1ff079ee7247cae2f45c50000000000004650" // 5 hours for node 0
                }),
                true
            );
        } else if (messageIndex == 9) {
            return (
                WarpMessage({
                    sourceChainID: bytes32(0),
                    originSenderAddress: address(0),
                    payload: hex"00000000000069e183f32216866f48b0c092f70d99378e18023f7185e52eeee2f5bbd52552930000000000006270" // 7 hours for node 1
                }),
                true
            );
        } else if (messageIndex == 10) {
            return (
                WarpMessage({
                    sourceChainID: bytes32(0),
                    originSenderAddress: address(0),
                    payload: hex"000000000000fcc09d5775472c6fa988b216f5ce189894c14e093527f732b9b65da0880b5f810000000000005460" // 6 hours for node 2
                }),
                true
            );
        }
        // test_EdgeCases
        else if (messageIndex == 11) {
            return (
                WarpMessage({
                    sourceChainID: bytes32(0),
                    originSenderAddress: address(0),
                    payload: hex"000000000000e917244df122a1996142a1cd6c7269c136c20f47acd1ff079ee7247cae2f45c50000000000003840" // EPOCH_DURATION (4 hours)
                }),
                true
            );
        } else if (messageIndex == 12) {
            return (
                WarpMessage({
                    sourceChainID: bytes32(0),
                    originSenderAddress: address(0),
                    payload: hex"00000000000069e183f32216866f48b0c092f70d99378e18023f7185e52eeee2f5bbd52552930000000000000000" // 0 hours
                }),
                true
            );
        } else if (messageIndex == 13) {
            return (
                WarpMessage({
                    sourceChainID: bytes32(0),
                    originSenderAddress: address(0),
                    payload: hex"000000000000e917244df122a1996142a1cd6c7269c136c20f47acd1ff079ee7247cae2f45c5000000000000a8c0" // 3 * EPOCH_DURATION (12 hours)
                }),
                true
            );
        }

        // Default return for any other message index
        return (WarpMessage({sourceChainID: bytes32(0), originSenderAddress: address(0), payload: new bytes(0)}), false);
    }

    // Add other interface functions with empty implementations
    function sendWarpMessage(
        bytes memory
    ) external pure returns (bytes32) {
        return bytes32(0);
    }

    function getBlockchainID() external pure returns (bytes32) {
        return bytes32(0);
    }

    function getVerifiedWarpBlockHash(
        uint32 index
    ) external view returns (WarpBlockHash memory warpBlockHash, bool valid) {
        warpBlockHash = WarpBlockHash({sourceChainID: bytes32(0), blockHash: bytes32(0)});
        valid = true;
    }
}
