// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {LSTWrapper} from "../../src/contracts/vault/LSTWrapper.sol";
import {LSTWrapperMerkl} from "../../src/contracts/vault/LSTWrapperMerkl.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Upgrades} from "@openzeppelin/foundry-upgrades/Upgrades.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {LSTWrapperConfig} from "./LSTWrapperTypes.s.sol";

/**
 * @dev Deploy LSTWrapper or LSTWrapperMerkl contract as a proxy
 */
contract DeployLSTWrapper is Script {
    function executeLSTWrapperDeployment(
        LSTWrapperConfig memory config
    ) public returns (address proxy, address implementation, address proxyAdminAddr) {
        // Only broadcast if not in test (chainid 31337 is Anvil/test)
        bool isTest = block.chainid == 31337;
        if (!isTest) {
            vm.startBroadcast();
        }

        // Deploy implementation based on config
        if (Strings.equal(config.implementation, "LSTWrapper")) {
            LSTWrapper impl = new LSTWrapper();
            implementation = address(impl);
        } else if (Strings.equal(config.implementation, "LSTWrapperMerkl")) {
            LSTWrapperMerkl impl = new LSTWrapperMerkl();
            implementation = address(impl);
        } else {
            revert(string(abi.encodePacked("Invalid implementation: ", config.implementation)));
        }

        // Same initialization selector for both implementations
        bytes memory initData = abi.encodeWithSelector(
            LSTWrapper.initialize.selector,  // Same selector for both
            config.admin,
            config.vault,
            config.rewards,
            config.name,
            config.symbol
        );
        
        TransparentUpgradeableProxy p = new TransparentUpgradeableProxy(
            implementation,
            config.admin,
            initData
        );
        
        // Only stop broadcast if we started one
        if (!isTest) {
            vm.stopBroadcast();
        }

        proxy = address(p);
        // Get the ProxyAdmin address using OZ utilities
        proxyAdminAddr = Upgrades.getAdminAddress(proxy);

        console2.log("LST Wrapper deployment:");
        console2.log("- Implementation type:", config.implementation);
        console2.log("- Proxy:", proxy);
        console2.log("- Implementation:", implementation);
        console2.log("- ProxyAdmin:", proxyAdminAddr);
        console2.log("- Vault:", config.vault);
        console2.log("- Rewards:", config.rewards);
        console2.log("- Name:", config.name);
        console2.log("- Symbol:", config.symbol);
    }
    
    /**
     * @dev Entry point for forge script - reads config from JSON
     * @param configFile The JSON file containing deployment configuration
     */
    function run(string memory configFile) external {
        string memory json = vm.readFile(string(abi.encodePacked("configs/", configFile)));
        
        LSTWrapperConfig memory config = LSTWrapperConfig({
            implementation: vm.parseJsonString(json, ".implementation"),
            admin: vm.parseJsonAddress(json, ".admin"),
            vault: vm.parseJsonAddress(json, ".vault"),
            rewards: vm.parseJsonAddress(json, ".rewards"),
            name: vm.parseJsonString(json, ".name"),
            symbol: vm.parseJsonString(json, ".symbol")
        });
        
        executeLSTWrapperDeployment(config);
    }
}

