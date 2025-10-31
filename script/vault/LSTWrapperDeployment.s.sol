// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {LSTWrapper} from "../../src/contracts/vault/LSTWrapper.sol";

import {LSTWrapperConfig} from "./LSTWrapperTypes.s.sol";

/**
 * @dev Deploy LSTWrapper contract
 */
contract DeployLSTWrapper is Script {
    function executeLSTWrapperDeployment(
        LSTWrapperConfig memory config
    ) public returns (address lstWrapper) {
        vm.startBroadcast();

        // Deploy LSTWrapper contract
        LSTWrapper lstWrapperContract = new LSTWrapper();
        
        // Initialize LSTWrapper contract
        lstWrapperContract.initialize(
            config.admin,
            config.vault,
            config.rewards,
            config.helper,
            config.name,
            config.symbol
        );

        vm.stopBroadcast();

        // Return address
        lstWrapper = address(lstWrapperContract);

        console2.log("LSTWrapper deployed at:", lstWrapper);
        console2.log("Using vault:", config.vault);
        console2.log("Using rewards:", config.rewards);
        console2.log("Using helper:", config.helper);
        console2.log("Token name:", config.name);
        console2.log("Token symbol:", config.symbol);
    }
}

