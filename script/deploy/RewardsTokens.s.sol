// script/deploy/RewardsToken.s.sol
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import {Script} from "forge-std/Script.sol";
import {Token} from "../../test/mocks/MockToken.sol";

contract DeployRewardsTokens is Script {
    function run() external returns (Token[] memory) {
        vm.startBroadcast();
        Token[] memory rewardsTokens = new Token[](3);
        rewardsTokens[0] = new Token("RewardsToken1");
        rewardsTokens[1] = new Token("RewardsToken2");
        rewardsTokens[2] = new Token("RewardsToken3");
        vm.stopBroadcast();

        return rewardsTokens;
    }
}
