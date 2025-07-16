// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.25;

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IDefaultCollateralFactory} from "src/interfaces/defaultCollateral/IDefaultCollateralFactory.sol";
import {console2} from "forge-std/Script.sol";

contract DefaultCollateralScript is Script {
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
        // Read deployment parameters from the input JSON file
        string memory json = readInput(input);

        address collateralFactory = json.readAddress(".collateralFactory");
        address collateralAsset = json.readAddress(".collateralAsset");
        uint256 collateralInitLimit = json.readUint(".collateralInitLimit");
        address collateralLimitIncreaser = json.readAddress(".collateralLimitIncreaser");

        vm.startBroadcast();

        // Deploy the collateral
        address newCollateral = IDefaultCollateralFactory(collateralFactory).create(
            collateralAsset,
            collateralInitLimit,
            collateralLimitIncreaser
        );

        vm.stopBroadcast();

        // Create a simplified deployment directory
        string memory path = "./deployments";
        vm.createDir(path, true);

        // Serialize deployment data
        string memory label = "DefaultCollateralDeployment";
        string memory data = vm.serializeAddress(label, "collateralFactory", collateralFactory);
        data = vm.serializeAddress(label, "underlyingAsset", collateralAsset);
        data = vm.serializeUint(label, "collateralInitLimit", collateralInitLimit);
        data = vm.serializeAddress(label, "collateralLimitIncreaser", collateralLimitIncreaser);
        data = vm.serializeAddress(label, "collateralAsset", newCollateral);

        // Write deployment data to JSON file
        string memory outFile = string.concat(path, "/defaultCollateral.json");
        vm.writeJson(data, outFile);

        // Log the deployment output path
        console2.log("DeployCore script finished. Deployment data written to", outFile);
    }
}
