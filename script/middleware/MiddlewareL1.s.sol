// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {
    AvalancheL1Middleware,
    AvalancheL1MiddlewareSettings
} from "../../src/contracts/middleware/AvalancheL1Middleware.sol";
import {MiddlewareVaultManager} from "../../src/contracts/middleware/MiddlewareVaultManager.sol";

import {MiddlewareConfig} from "./MiddlewareL1Types.s.sol";

/**
 * @dev Deploy only AvalancheL1Middleware + MiddlewareVaultManager.
 * @dev All other addresses (validatorManager, operatorRegistry, vaultFactory, operatorL1OptIn) must be passed in from JSON.
 */
contract DeployTestAvalancheL1Middleware is Script {
    function executeMiddlewareL1Deployment(
        MiddlewareConfig memory middlewareConfig
    ) public returns (address middlewareL1, address vaultManager) {
        vm.startBroadcast();

        // Deploy the AvalancheL1Middleware
        AvalancheL1Middleware l1Middleware = new AvalancheL1Middleware(
            AvalancheL1MiddlewareSettings({
                l1ValidatorManager: middlewareConfig.validatorManager,
                operatorRegistry: middlewareConfig.operatorRegistry,
                vaultRegistry: middlewareConfig.vaultFactory,
                operatorL1Optin: middlewareConfig.operatorL1OptIn,
                epochDuration: middlewareConfig.epochDuration,
                slashingWindow: middlewareConfig.slashingWindow,
                weightUpdateWindow: middlewareConfig.weightUpdateWindow
            }),
            middlewareConfig.l1MiddlewareOwnerKey, // Set the owner
            middlewareConfig.primaryAsset,
            middlewareConfig.primaryAssetMaxStake,
            middlewareConfig.primaryAssetMinStake
        );

        // Deploy the MiddlewareVaultManager
        // Linking both to the same validator manager
        MiddlewareVaultManager middlewareVaultManager = new MiddlewareVaultManager(
            middlewareConfig.vaultFactory, middlewareConfig.l1MiddlewareOwnerKey, middlewareConfig.validatorManager
        );

        vm.stopBroadcast();

        // Configure the vault manager in the middleware
        vm.startBroadcast(middlewareConfig.l1MiddlewareOwnerKey);
        l1Middleware.setVaultManager(address(middlewareVaultManager));
        vm.stopBroadcast();

        // Return addresses
        middlewareL1 = address(l1Middleware);
        vaultManager = address(middlewareVaultManager);

        console2.log("AvalancheL1Middleware deployed at:", middlewareL1);
        console2.log("MiddlewareVaultManager deployed at:", vaultManager);
        console2.log("Using validatorManager at:", middlewareConfig.validatorManager);
        console2.log("Using operatorRegistry at:", middlewareConfig.operatorRegistry);
        console2.log("Using vaultFactory at:", middlewareConfig.vaultFactory);
        console2.log("Using operatorL1OptIn at:", middlewareConfig.operatorL1OptIn);
    }
}
