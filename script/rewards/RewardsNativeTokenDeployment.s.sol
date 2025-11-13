// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {RewardsNativeToken} from "../../src/contracts/rewards/RewardsNativeToken.sol";
import {UptimeTracker} from "../../src/contracts/rewards/UptimeTracker.sol";

import {RewardsNativeTokenConfig} from "./RewardsNativeTokenTypes.s.sol";

/**
 * @dev Deploy RewardsNativeToken and UptimeTracker contracts
 */
contract DeployRewardsNativeToken is Script {
    function executeRewardsNativeTokenDeployment(
        RewardsNativeTokenConfig memory config
    ) public returns (address rewardsNativeToken, address uptimeTracker) {
        vm.startBroadcast();

        // Deploy UptimeTracker first
        UptimeTracker uptimeTrackerContract = new UptimeTracker(
            payable(config.middleware),
            config.uptimeBlockchainID
        );

        // Deploy RewardsNativeToken contract
        RewardsNativeToken rewardsNativeTokenContract = new RewardsNativeToken();
        
        // Initialize RewardsNativeToken contract
        rewardsNativeTokenContract.initialize(
            config.admin,
            config.protocolOwner,
            payable(config.middleware),
            address(uptimeTrackerContract),
            config.protocolFee,
            config.operatorFee,
            config.curatorFee,
            config.minRequiredUptime
        );

        vm.stopBroadcast();

        // Return addresses
        rewardsNativeToken = address(rewardsNativeTokenContract);
        uptimeTracker = address(uptimeTrackerContract);

        console2.log("RewardsNativeToken deployed at:", rewardsNativeToken);
        console2.log("UptimeTracker deployed at:", uptimeTracker);
        console2.log("Using L1Middleware:", config.middleware);
        console2.log("Using uptimeBlockchainID:", uint256(config.uptimeBlockchainID));
    }
}

