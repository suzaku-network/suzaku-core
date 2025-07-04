// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {UptimeTracker} from "../../src/contracts/rewards/UptimeTracker.sol";
import {IUptimeTracker, LastUptimeCheckpoint} from "../../src/interfaces/rewards/IUptimeTracker.sol";
import {ValidatorMessages} from "@avalabs/icm-contracts/validator-manager/ValidatorMessages.sol";

import {MockAvalancheL1Middleware} from "../mocks/MockAvalancheL1Middleware.sol";
import {MockBalancerValidatorManager} from "../mocks/MockBalancerValidatorManager2.sol";
import {MockWarpMessenger} from "../mocks/MockWarpMessenger.sol";
import {
    WarpMessage, IWarpMessenger
} from "@avalabs/subnet-evm-contracts@1.2.0/contracts/interfaces/IWarpMessenger.sol";

abstract contract UptimeTrackerTestBase is Test {
    UptimeTracker public uptimeTracker;
    MockBalancerValidatorManager public validatorManager;
    MockAvalancheL1Middleware public middleware;
    MockWarpMessenger public warpMessenger;

    address public operator;
    bytes32[] public operatorNodes;
    uint48 constant EPOCH_DURATION = 4 hours;
    address constant WARP_MESSENGER_ADDR = 0x0200000000000000000000000000000000000005;
    bytes32 constant L1_CHAIN_ID = bytes32(uint256(1));

    // Utility to derive validation ID from node ID
    function getDerivedValidationID(bytes32 fullNodeID) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(uint256(fullNodeID))));
    }

    event ValidatorUptimeComputed(
        bytes32 indexed validationID, uint48 indexed firstEpoch, uint256 uptimeSecondsAdded, uint256 numberOfEpochs
    );

    event OperatorUptimeComputed(address indexed operator, uint48 indexed epoch, uint256 uptime);

   function setUp() public {
        // Setup operator with 3 nodes
        uint256[] memory nodesPerOperator = new uint256[](1);
        nodesPerOperator[0] = 3;

        validatorManager = new MockBalancerValidatorManager();
        middleware = new MockAvalancheL1Middleware(1, nodesPerOperator, address(validatorManager), address(0));
        uptimeTracker = new UptimeTracker(payable(address(middleware)), L1_CHAIN_ID);

        operator = middleware.getAllOperators()[0];
        operatorNodes = middleware.getActiveNodesForEpoch(operator, 0);

        // Setup mock warp messenger
        warpMessenger = new MockWarpMessenger();
        vm.etch(WARP_MESSENGER_ADDR, address(warpMessenger).code);
    }

    // Helper for packing uptime message data
    function packValidationUptimeMessage(bytes32 validationID, uint256 uptime) public pure returns (bytes memory) {
        return ValidatorMessages.packValidationUptimeMessage(validationID, uint64(uptime));
    }

}
