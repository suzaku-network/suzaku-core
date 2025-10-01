// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {LSTHelper} from "../../src/contracts/LSTHelper.sol";

/**
 * @title DeployLSTHelper
 * @notice Deployment script for LSTHelper contract
 */
contract DeployLSTHelper is Script {
    function run(address vaultFactory) public returns (address) {
        require(vaultFactory != address(0), "VaultFactory address cannot be zero");
        
        vm.startBroadcast();
        
        LSTHelper lstHelper = new LSTHelper(vaultFactory);
        
        vm.stopBroadcast();
        
        console2.log("LSTHelper deployed at:", address(lstHelper));
        console2.log("Using VaultFactory at:", vaultFactory);
        
        return address(lstHelper);
    }
    
    /**
     * @notice Deploy LSTHelper with addresses from environment variables
     * @dev Expects VAULT_FACTORY environment variable to be set
     */
    function runFromEnv() external returns (address) {
        address vaultFactory = vm.envAddress("VAULT_FACTORY");
        return run(vaultFactory);
    }
}
