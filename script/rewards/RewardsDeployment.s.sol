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
            payable(config.l1Middleware),
            config.l1ChainID
        );

        // Deploy Rewards contract
        Rewards rewardsContract = new Rewards();
        
        // Initialize Rewards contract
        rewardsContract.initialize(
            config.admin,
            config.protocolOwner,
            payable(config.l1Middleware),
            address(uptimeTrackerContract),
            config.protocolFee,
            config.operatorFee,
            config.curatorFee,
            config.minRequiredUptime
        );

        vm.stopBroadcast();

        // Return addresses
        rewards = address(rewardsContract);
        uptimeTracker = address(uptimeTrackerContract);

        console2.log("Rewards deployed at:", rewards);
        console2.log("UptimeTracker deployed at:", uptimeTracker);
        console2.log("Using L1Middleware:", config.l1Middleware);
        console2.log("Using L1ChainID:", uint256(config.l1ChainID));
    }
} 
