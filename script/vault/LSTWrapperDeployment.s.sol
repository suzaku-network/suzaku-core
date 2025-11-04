// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {LSTWrapper} from "../../src/contracts/vault/LSTWrapper.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {LSTWrapperConfig} from "./LSTWrapperTypes.s.sol";

/**
 * @dev Deploy LSTWrapper contract as a proxy
 */
contract DeployLSTWrapper is Script {
    function executeLSTWrapperDeployment(
        LSTWrapperConfig memory config
    ) public returns (address proxy, address implementation, address proxyAdminAddr) {
        vm.startBroadcast();

        LSTWrapper impl = new LSTWrapper();
        bytes memory initData = abi.encodeWithSelector(
            LSTWrapper.initialize.selector,
            config.admin,
            config.vault,
            config.rewards,
            config.helper,
            config.name,
            config.symbol
        );
        TransparentUpgradeableProxy p = new TransparentUpgradeableProxy(
            address(impl),
            config.admin,
            initData
        );
        vm.stopBroadcast();

        proxy = address(p);
        implementation = address(impl);
        // Read the EIP-1967 admin slot to get the internally created ProxyAdmin
        bytes32 ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        proxyAdminAddr = address(uint160(uint256(vm.load(proxy, ADMIN_SLOT))));

        console2.log("LSTWrapper proxy:", proxy);
        console2.log("Implementation:", implementation);
        console2.log("ProxyAdmin:", proxyAdminAddr);
        console2.log("Using vault:", config.vault);
        console2.log("Using rewards:", config.rewards);
        console2.log("Using helper:", config.helper);
        console2.log("Token name:", config.name);
        console2.log("Token symbol:", config.symbol);
    }
}

