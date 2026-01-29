// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {RewardsNativeToken} from "../../src/contracts/rewards/RewardsNativeToken.sol";
import {UptimeTracker} from "../../src/contracts/rewards/UptimeTracker.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Upgrades} from "@openzeppelin/foundry-upgrades/Upgrades.sol";

import {RewardsNativeTokenConfig} from "./RewardsNativeTokenTypes.s.sol";

/**
 * @dev Deploy RewardsNativeToken and UptimeTracker contracts
 */
contract DeployRewardsNativeToken is Script {
    function executeRewardsNativeTokenDeployment(
        RewardsNativeTokenConfig memory config
    ) public returns (address rewardsNativeToken, address uptimeTracker, address implementation, address proxyAdmin) {
        // Only broadcast if not in test (chainid 31337 is Anvil/test)
        bool isTest = block.chainid == 31337;
        if (!isTest) {
            vm.startBroadcast();
        }

        // Deploy UptimeTracker first
        UptimeTracker uptimeTrackerContract = new UptimeTracker(
            payable(config.middleware),
            config.uptimeBlockchainID
        );

        // Deploy RewardsNativeToken implementation
        RewardsNativeToken rewardsNativeTokenImpl = new RewardsNativeToken();

        // Encode initialization data
        bytes memory initData = abi.encodeWithSelector(
            RewardsNativeToken.initialize.selector,
            config.admin,
            config.protocolOwner,
            payable(config.middleware),
            address(uptimeTrackerContract),
            config.protocolFee,
            config.operatorFee,
            config.curatorFee,
            config.minRequiredUptime
        );

        // Deploy proxy with initialization
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(rewardsNativeTokenImpl),
            config.admin,
            initData
        );

        if (!isTest) {
            vm.stopBroadcast();
        }

        // Return addresses
        rewardsNativeToken = address(proxy);
        uptimeTracker = address(uptimeTrackerContract);
        implementation = address(rewardsNativeTokenImpl);
        proxyAdmin = Upgrades.getAdminAddress(rewardsNativeToken);

        console2.log("RewardsNativeToken deployment:");
        console2.log("- Proxy:", rewardsNativeToken);
        console2.log("- Implementation:", implementation);
        console2.log("- ProxyAdmin:", proxyAdmin);
        console2.log("- UptimeTracker:", uptimeTracker);
        console2.log("- L1Middleware:", config.middleware);
        console2.log("- uptimeBlockchainID:", uint256(config.uptimeBlockchainID));
    }
}

