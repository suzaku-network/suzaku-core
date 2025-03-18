// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {GeneralConfig, FactoryConfig, OptinConfig, BootstraperConfig} from "./FactoriesRegistriesOptinsTypes.s.sol";

import {VaultFactory} from "../../src/contracts/VaultFactory.sol";
import {DelegatorFactory} from "../../src/contracts/DelegatorFactory.sol";
import {SlasherFactory} from "../../src/contracts/SlasherFactory.sol";
import {L1Registry} from "../../src/contracts/L1Registry.sol";
import {OperatorRegistry} from "../../src/contracts/OperatorRegistry.sol";
import {OperatorVaultOptInService} from "../../src/contracts/service/OperatorVaultOptInService.sol";
import {OperatorL1OptInService} from "../../src/contracts/service/OperatorL1OptInService.sol";

contract DeployFactoriesRegistriesOptIns is Script {
    using stdJson for string;

    VaultFactory internal vaultFactory;
    DelegatorFactory internal delegatorFactory;
    SlasherFactory internal slasherFactory;
    L1Registry internal l1Registry;
    OperatorRegistry internal operatorRegistry;

    function executeFactoriesDeployment(
        BootstraperConfig memory bootstraperConfig
    )
        external
        returns (
            address vaultFactoryAddr,
            address delegatorFactoryAddr,
            address slasherFactoryAddr,
            address l1RegistryAddr,
            address operatorRegistryAddr,
            address operatorVaultOptInServiceAddr,
            address operatorL1OptInServiceAddr
        )
    {
        vm.startBroadcast();

        // Deploy factories, registries, and opt-in services
        vaultFactory = new VaultFactory(bootstraperConfig.generalConfig.owner);
        delegatorFactory = new DelegatorFactory(bootstraperConfig.generalConfig.owner);
        slasherFactory = new SlasherFactory(bootstraperConfig.generalConfig.owner);
        l1Registry = new L1Registry();
        operatorRegistry = new OperatorRegistry();

        OperatorVaultOptInService operatorVaultOptInService =
            new OperatorVaultOptInService(address(operatorRegistry), address(vaultFactory), "Vault Opt-In");

        OperatorL1OptInService operatorL1OptInService =
            new OperatorL1OptInService(address(operatorRegistry), address(l1Registry), "Suzaku Operator -> L1 Opt-In");

        vm.stopBroadcast();

        // Assign them to the return variables
        vaultFactoryAddr = address(vaultFactory);
        delegatorFactoryAddr = address(delegatorFactory);
        slasherFactoryAddr = address(slasherFactory);
        l1RegistryAddr = address(l1Registry);
        operatorRegistryAddr = address(operatorRegistry);
        operatorVaultOptInServiceAddr = address(operatorVaultOptInService);
        operatorL1OptInServiceAddr = address(operatorL1OptInService);

        return (
            vaultFactoryAddr,
            delegatorFactoryAddr,
            slasherFactoryAddr,
            l1RegistryAddr,
            operatorRegistryAddr,
            operatorVaultOptInServiceAddr,
            operatorL1OptInServiceAddr
        );
    }
}
