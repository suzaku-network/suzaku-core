// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

import {VaultFactory} from "../../src/contracts/VaultFactory.sol";
import {DelegatorFactory} from "../../src/contracts/DelegatorFactory.sol";
import {SlasherFactory} from "../../src/contracts/SlasherFactory.sol";
import {L1Registry} from "../../src/contracts/L1Registry.sol";
import {OperatorRegistry} from "../../src/contracts/OperatorRegistry.sol";

contract FactoryAndRegistryScript is Script {
    function run() public {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();

        console2.log("Deploying on chain ID:", block.chainid);
        console2.log("Owner Address:", config.generalConfig.owner);

        vm.startBroadcast();

        // Deploy main factories
        VaultFactory vaultFactory = new VaultFactory(config.generalConfig.owner);
        DelegatorFactory delegatorFactory = new DelegatorFactory(config.generalConfig.owner);
        SlasherFactory slasherFactory = new SlasherFactory(config.generalConfig.owner);
        L1Registry l1Registry = new L1Registry();
        OperatorRegistry operatorRegistry = new OperatorRegistry();

        console2.log("VaultFactory deployed at:", address(vaultFactory));
        console2.log("DelegatorFactory deployed at:", address(delegatorFactory));
        console2.log("SlasherFactory deployed at:", address(slasherFactory));
        console2.log("L1Registry deployed at:", address(l1Registry));
        console2.log("OperatorRegistry deployed at:", address(operatorRegistry));

        // Log the addresses of the deployed contracts for verification
        string memory deploymentFileName = "deploymentDetails.json";
        string memory filePath = string.concat("./deployments/", deploymentFileName);

        if (vm.exists(filePath)) {
            // If file exists, delete it
            vm.removeFile(filePath);
        }

        string memory factoryContracts = "factory contracts key";
        vm.serializeAddress(factoryContracts, "VaultFactory", address(vaultFactory));
        vm.serializeAddress(factoryContracts, "DelegatorFactory", address(delegatorFactory));
        vm.serializeAddress(factoryContracts, "SlasherFactory", address(slasherFactory));
        vm.serializeAddress(factoryContracts, "L1Registry", address(l1Registry));
        vm.serializeAddress(factoryContracts, "OperatorRegistry", address(operatorRegistry));

        string memory factoryOutput = vm.serializeAddress(factoryContracts, "VaultFactory", address(vaultFactory));
        vm.writeJson(factoryOutput, filePath);

        vm.stopBroadcast();
    }
}
