// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {Rewards} from "../../src/contracts/rewards/Rewards.sol";
import {UptimeTracker} from "../../src/contracts/rewards/UptimeTracker.sol";

import {RewardsConfig} from "./RewardsTypes.s.sol";

/**
 * @dev Deploy Rewards and UptimeTracker contracts
 */
contract DeployRewards is Script {
    function executeRewardsDeployment(
        RewardsConfig memory config
    ) public returns (address rewards, address uptimeTracker) {
        vm.startBroadcast();

        // Deploy UptimeTracker first
        UptimeTracker uptimeTrackerContract = new UptimeTracker(
            config.l1Middleware
        );

        // Deploy Rewards contract
        Rewards rewardsContract = new Rewards();
        
        // Initialize Rewards contract
        rewardsContract.initialize(
            config.admin,
            config.protocolOwner,
            config.l1Middleware,
            config.middlewareVaultManager,
            address(uptimeTrackerContract),
            config.protocolFee,
            config.operatorFee,
            config.curatorFee
        );

        vm.stopBroadcast();

        // Return addresses
        rewards = address(rewardsContract);
        uptimeTracker = address(uptimeTrackerContract);

        console2.log("Rewards deployed at:", rewards);
        console2.log("UptimeTracker deployed at:", uptimeTracker);
        console2.log("Using L1Middleware:", config.l1Middleware);
        console2.log("Using MiddlewareVaultManager:", config.middlewareVaultManager);
    }
} 
