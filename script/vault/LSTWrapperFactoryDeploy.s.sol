// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {LSTWrapperFactory} from "../../src/contracts/vault/LSTWrapperFactory.sol";

/**
 * @title DeployLSTWrapperFactory
 * @notice Deploys the LSTWrapperFactory registry contract
 * @dev For standalone deployment when upgrading from old factory scripts
 */
contract DeployLSTWrapperFactory is Script {
    /**
     * @notice Execute LSTWrapperFactory deployment
     * @param owner Owner of the factory (can whitelist/blacklist implementations)
     * @param vaultFactory VaultFactory address for vault validation
     * @return factory Address of deployed LSTWrapperFactory
     */
    function executeLSTWrapperFactoryDeployment(address owner, address vaultFactory)
        public
        returns (address factory)
    {
        // Only broadcast if not in test (chainid 31337 is Anvil/test)
        bool isTest = block.chainid == 31337;
        if (!isTest) {
            vm.startBroadcast();
        }

        LSTWrapperFactory lstWrapperFactory = new LSTWrapperFactory(owner, vaultFactory);
        factory = address(lstWrapperFactory);

        if (!isTest) {
            vm.stopBroadcast();
        }

        console2.log("LSTWrapperFactory deployed:");
        console2.log("- Address:", factory);
        console2.log("- Owner:", owner);
        console2.log("- VaultFactory:", vaultFactory);
    }
}

