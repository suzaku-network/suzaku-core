// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.25;

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {DefaultCollateralFactory} from
    "src/contracts/defaultCollateral/DefaultCollateralFactory.sol";

contract DefaultCollateralFactoryScript is Script {
    using stdJson for string;

    function readInput(
        string memory input
    ) internal view returns (string memory) {
        string memory path = string.concat(
            vm.projectRoot(),
            "/script/collateral/configs/",
            input
        );
        return vm.readFile(path);
    }


    function run(string memory input) external {
        vm.startBroadcast();

        DefaultCollateralFactory factory = new DefaultCollateralFactory();

        vm.stopBroadcast();

        // Create a simplified deployment directory
        string memory path = "./deployments";
        vm.createDir(path, true);

        // Convert the address to a string before serializing
        string memory factoryAddressStr = vm.toString(address(factory));
        string memory outputJson = vm.serializeJson("factoryAddress", factoryAddressStr);

        // Write deployment data to JSON file
        string memory outFile = string.concat(path, "/defaultCollateralFactory.json");
        vm.writeFile(outFile, outputJson);
    }
}
