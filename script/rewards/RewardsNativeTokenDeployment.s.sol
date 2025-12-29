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
        bool isTest = block.chainid == 31337;
        if (!isTest) {
            vm.startBroadcast();
        }

        uptimeTracker = _deployUptimeTracker(config);
        (rewardsNativeToken, implementation) = _deployRewardsNativeToken(config, uptimeTracker);

        if (!isTest) {
            vm.stopBroadcast();
        }

        proxyAdmin = Upgrades.getAdminAddress(rewardsNativeToken);
        _logDeployment(rewardsNativeToken, implementation, proxyAdmin, uptimeTracker, config);
    }

    function _deployUptimeTracker(RewardsNativeTokenConfig memory config) internal returns (address) {
        return address(new UptimeTracker(
            payable(config.middleware),
            config.uptimeBlockchainID
        ));
    }

    function _deployRewardsNativeToken(
        RewardsNativeTokenConfig memory config,
        address uptimeTracker
    ) internal returns (address proxy, address implementation) {
        implementation = address(new RewardsNativeToken());
        bytes memory initData = _encodeInitData(config, uptimeTracker);

        proxy = address(new TransparentUpgradeableProxy(
            implementation,
            config.admin,
            initData
        ));
    }

    function _encodeInitData(
        RewardsNativeTokenConfig memory config,
        address uptimeTracker
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            RewardsNativeToken.initialize.selector,
            config.admin,
            config.protocolOwner,
            payable(config.middleware),
            uptimeTracker,
            config.protocolFee,
            config.operatorFee,
            config.curatorFee,
            config.minRequiredUptime
        );
    }

    function _logDeployment(
        address rewardsNativeToken,
        address implementation,
        address proxyAdmin,
        address uptimeTracker,
        RewardsNativeTokenConfig memory config
    ) internal pure {
        console2.log("RewardsNativeToken deployment:");
        console2.log("- Proxy:", rewardsNativeToken);
        console2.log("- Implementation:", implementation);
        console2.log("- ProxyAdmin:", proxyAdmin);
        console2.log("- UptimeTracker:", uptimeTracker);
        console2.log("- L1Middleware:", config.middleware);
        console2.log("- uptimeBlockchainID:", uint256(config.uptimeBlockchainID));
    }
}

