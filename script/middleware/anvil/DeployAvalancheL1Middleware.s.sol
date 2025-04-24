// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {ValidatorManagerSettings} from "@avalabs/teleporter/validator-manager/interfaces/IValidatorManager.sol";
import {MiddlewareHelperConfig} from "./MiddlewareHelperConfig.s.sol";
import {PoAValidatorManager} from "@avalabs/teleporter/validator-manager/PoAValidatorManager.sol";
import {Script} from "forge-std/Script.sol";
import {ICMInitializable} from "@avalabs/teleporter/utilities/ICMInitializable.sol";
import {UnsafeUpgrades} from "@openzeppelin/foundry-upgrades/Upgrades.sol";
import {OperatorRegistry} from "../../../src/contracts/OperatorRegistry.sol";
import {VaultFactory} from "../../../src/contracts/VaultFactory.sol";
import {OperatorL1OptInService} from "../../../src/contracts/service/OperatorL1OptInService.sol";
import {L1Registry} from "../../../src/contracts/L1Registry.sol";
import {
    AvalancheL1Middleware,
    AvalancheL1MiddlewareSettings
} from "../../../src/contracts/middleware/AvalancheL1Middleware.sol";
import {MiddlewareVaultManager} from "../../../src/contracts/middleware/MiddlewareVaultManager.sol";

/**
 * @dev Deploy a test Avalanche L1 Middleware
 * @dev DO NOT USE THIS IN PRODUCTION
 */
contract DeployTestAvalancheL1Middleware is Script {
    function run() external returns (address) {
        // Revert if not on Anvil
        if (block.chainid != 31_337) {
            revert("Not on Anvil");
        }

        MiddlewareHelperConfig helperConfig = new MiddlewareHelperConfig();
        (
            uint256 proxyAdminOwnerKey,
            uint256 protocolOwnerKey,
            bytes32 l1ID,
            uint64 churnPeriodSeconds,
            uint8 maximumChurnPercentage,
            address primaryAsset,
            uint256 primaryAssetMaxStake,
            uint256 primaryAssetMinStake,
            uint256 primaryAssetWeightScaleFactor
        ) = helperConfig.activeNetworkConfig();
        address proxyAdminOwnerAddress = vm.addr(proxyAdminOwnerKey);
        address protocolOwnerAddress = vm.addr(protocolOwnerKey);

        ValidatorManagerSettings memory settings = ValidatorManagerSettings({
            l1ID: l1ID,
            churnPeriodSeconds: churnPeriodSeconds,
            maximumChurnPercentage: maximumChurnPercentage
        });

        vm.startBroadcast(proxyAdminOwnerKey);

        address validatorManagerAddress =
            _deployValidatorManager(settings, proxyAdminOwnerAddress, protocolOwnerAddress);
        L1Registry l1Registry = new L1Registry(
            payable(protocolOwnerAddress), // fee collector
            0.01 ether, // initial register fee
            1 ether, // MAX_FEE
            protocolOwnerAddress // owner
        );
        OperatorRegistry operatorRegistry = new OperatorRegistry();
        VaultFactory vaultFactory = new VaultFactory(protocolOwnerAddress);
        OperatorL1OptInService operatorL1OptIn =
            new OperatorL1OptInService(address(operatorRegistry), address(l1Registry), "Suzaku Operator -> L1 Opt-In");

        AvalancheL1Middleware avalancheL1Middleware = new AvalancheL1Middleware(
            AvalancheL1MiddlewareSettings({
                l1ValidatorManager: validatorManagerAddress,
                operatorRegistry: address(operatorRegistry),
                vaultRegistry: address(vaultFactory),
                operatorL1Optin: address(operatorL1OptIn),
                epochDuration: 4 hours,
                slashingWindow: 5 hours,
                stakeUpdateWindow: 3 hours
            }),
            protocolOwnerAddress,
            primaryAsset,
            primaryAssetMaxStake,
            primaryAssetMinStake,
            primaryAssetWeightScaleFactor
        );

        MiddlewareVaultManager vaultManager =
            new MiddlewareVaultManager(address(vaultFactory), validatorManagerAddress, validatorManagerAddress);

        vm.stopBroadcast();

        vm.startBroadcast(protocolOwnerKey);
        avalancheL1Middleware.setVaultManager(address(vaultManager));
        vm.stopBroadcast();

        return address(avalancheL1Middleware);
    }

    function _deployValidatorManager(
        ValidatorManagerSettings memory settings,
        address proxyAdminOwnerAddress,
        address protocolOwnerAddress
    ) private returns (address) {
        PoAValidatorManager validatorSetManager = new PoAValidatorManager(ICMInitializable.Allowed);

        address proxy = UnsafeUpgrades.deployTransparentProxy(
            address(validatorSetManager),
            proxyAdminOwnerAddress,
            abi.encodeCall(PoAValidatorManager.initialize, (settings, protocolOwnerAddress))
        );

        return proxy;
    }
}
