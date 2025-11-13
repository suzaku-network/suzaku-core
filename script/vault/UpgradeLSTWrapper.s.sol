// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {LSTWrapper} from "../../src/contracts/vault/LSTWrapper.sol";
import {LSTWrapperMerkl} from "../../src/contracts/vault/LSTWrapperMerkl.sol";
import {ILSTWrapper} from "../../src/interfaces/vault/ILSTWrapper.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Upgrades} from "@openzeppelin/foundry-upgrades/Upgrades.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {LSTWrapperUpgradeConfig} from "./LSTWrapperUpgradeTypes.s.sol";

/**
 * @dev Upgrade LSTWrapper proxy to any implementation
 * @notice This script upgrades an existing LSTWrapper proxy between implementations
 */
contract UpgradeLSTWrapper is Script {
    function executeLSTWrapperUpgrade(
        LSTWrapperUpgradeConfig memory config
    ) public returns (address newImplementation) {
        // Get ProxyAdmin address from existing proxy
        address proxyAdminAddr = Upgrades.getAdminAddress(config.proxyAddress);
        ProxyAdmin proxyAdmin = ProxyAdmin(proxyAdminAddr);
        
        console2.log("Upgrading LST Wrapper at:", config.proxyAddress);
        console2.log("ProxyAdmin:", proxyAdminAddr);
        console2.log("New implementation type:", config.newImplementation);
        console2.log("New rewards contract:", config.newRewards);
        
        vm.startBroadcast();
        
        // Deploy new implementation based on config
        if (Strings.equal(config.newImplementation, "LSTWrapper")) {
            LSTWrapper impl = new LSTWrapper();
            newImplementation = address(impl);
        } else if (Strings.equal(config.newImplementation, "LSTWrapperMerkl")) {
            LSTWrapperMerkl impl = new LSTWrapperMerkl();
            newImplementation = address(impl);
        } else {
            revert(string(abi.encodePacked("Invalid implementation: ", config.newImplementation)));
        }
        
        console2.log("New implementation deployed at:", newImplementation);
        
        // Prepare calldata to set new rewards contract
        bytes memory callData = abi.encodeWithSelector(
            ILSTWrapper.setRewards.selector,
            config.newRewards
        );
        
        // Upgrade proxy and set new rewards in one transaction
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(payable(config.proxyAddress)),
            newImplementation,
            callData
        );
        
        vm.stopBroadcast();
        
        console2.log("Upgrade complete!");
        console2.log("LST Wrapper upgraded at:", config.proxyAddress);
        console2.log("New implementation:", newImplementation);
        console2.log("Rewards updated to:", config.newRewards);
        
        // Verify upgrade
        address currentImpl = Upgrades.getImplementationAddress(config.proxyAddress);
        require(currentImpl == newImplementation, "Upgrade verification failed");
        
        // Verify rewards update
        address currentRewards = ILSTWrapper(config.proxyAddress).rewards();
        require(currentRewards == config.newRewards, "Rewards update verification failed");
    }
    
    /**
     * @dev Entry point for forge script - reads config from JSON
     * @param configFile The JSON file containing upgrade configuration
     */
    function run(string memory configFile) external {
        string memory json = vm.readFile(string(abi.encodePacked("configs/", configFile)));
        
        LSTWrapperUpgradeConfig memory config = LSTWrapperUpgradeConfig({
            newImplementation: vm.parseJsonString(json, ".newImplementation"),
            proxyAddress: vm.parseJsonAddress(json, ".proxyAddress"),
            newRewards: vm.parseJsonAddress(json, ".newRewards")
        });
        
        executeLSTWrapperUpgrade(config);
    }
}
