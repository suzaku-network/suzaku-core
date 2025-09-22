// script/deploy/MockRewards.s.sol
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import {Script} from "forge-std/Script.sol";
import {MockRewards} from "../../test/mocks/MockRewards.sol";

contract DeployMockRewards is Script {
    function run() external returns (MockRewards) {
        address middleware = 0xBE843C7d31e773acFf38575d7eC7A23358726d4e;
        address vault = 0xc2BC5788A769F3BF4C37255eF301c08D641416D4;
        vm.startBroadcast();
        MockRewards mockRewards = new MockRewards(middleware, vault);
        vm.stopBroadcast();

        return mockRewards;
    }
}
