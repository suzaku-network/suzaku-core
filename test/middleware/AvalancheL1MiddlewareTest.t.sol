// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {AvalancheL1Middleware} from "../../src/contracts/middleware/AvalancheL1Middleware.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {DeployTestAvalancheL1Middleware} from "../../script/middleware/DeployAvalancheL1Middleware.s.sol";

contract AvalancheL1MiddlewareTest is Test {
    AvalancheL1Middleware middleware;

    function setUp() public {
        DeployTestAvalancheL1Middleware deployer = new DeployTestAvalancheL1Middleware();
        address middlewareAddress = deployer.run();

        middleware = AvalancheL1Middleware(middlewareAddress);
    }

    function testCreate() public view {
        assertEq(middleware.subnetworksCount(), 1);
        assertEq(middleware.totalStakeCached(0), false);
        assertEq(middleware.START_TIME(), block.timestamp);
    }
}
