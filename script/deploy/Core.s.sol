// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import "forge-std/StdJson.sol";

import {HelperConfig} from "./HelperConfig.s.sol"; // Import HelperConfig for network-specific config

import {VaultFactory} from "../../src/contracts/VaultFactory.sol";
import {DelegatorFactory} from "../../src/contracts/DelegatorFactory.sol";
import {SlasherFactory} from "../../src/contracts/SlasherFactory.sol";
import {L1Registry} from "../../src/contracts/L1Registry.sol";
import {OperatorRegistry} from "../../src/contracts/OperatorRegistry.sol";

import {VaultTokenized} from "../../src/contracts/vault/VaultTokenized.sol";
import {INetworkRestakeDelegator} from "../../src/interfaces/delegator/INetworkRestakeDelegator.sol";
import {IFullRestakeDelegator} from "../../src/interfaces/delegator/IFullRestakeDelegator.sol";
import {IOperatorSpecificDelegator} from "../../src/interfaces/delegator/IOperatorSpecificDelegator.sol";
import {ISlasher} from "../../src/interfaces/slasher/ISlasher.sol";
import {IVetoSlasher} from "../../src/interfaces/slasher/IVetoSlasher.sol";
import {IBaseSlasher} from "../../src/interfaces/slasher/IBaseSlasher.sol";
import {IBaseDelegator} from "../../src/interfaces/delegator/IBaseDelegator.sol";
import {IVaultTokenized} from "../../src/interfaces/vault/IVaultTokenized.sol";


contract CoreScript is Script {
    bool public includeSlasher;
    VaultFactory vaultFactory;
    DelegatorFactory delegatorFactory;
    SlasherFactory slasherFactory;
    L1Registry l1Registry;
    OperatorRegistry operatorRegistry;

    struct InitParams {
        uint64 version;
        address owner;
        bytes vaultParams;
        uint64 delegatorIndex;
        bytes delegatorParams;
        bool withSlasher;
        uint64 slasherIndex;
        bytes slasherParams;
    }

    function run() public {

        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();

        console2.log("Deploying on chain ID:", block.chainid);
        console2.log("Owner Address:", config.generalConfig.owner);
        console2.log("Initial Vault Version:", config.generalConfig.initialVaultVersion);

        vm.startBroadcast();

        // Instantiate the main factories and registries
        vaultFactory = VaultFactory(config.factoryConfig.vaultFactory);
        delegatorFactory = DelegatorFactory(config.factoryConfig.delegatorFactory);
        slasherFactory = SlasherFactory(config.factoryConfig.slasherFactory);
        l1Registry = L1Registry(config.factoryConfig.l1Registry);
        operatorRegistry = OperatorRegistry(config.factoryConfig.operatorRegistry);

        console2.log("VaultFactory deployed at:", address(vaultFactory));
        console2.log("DelegatorFactory deployed at:", address(delegatorFactory));
        console2.log("SlasherFactory deployed at:", address(slasherFactory));
        console2.log("NetworkRegistry deployed at:", address(l1Registry));
        console2.log("OperatorRegistry deployed at:", address(operatorRegistry));

        // Check Slasher inclusion
        includeSlasher = config.slasherConfig.includeSlasher;
        console2.log("Include Slasher:", includeSlasher);
        
        // Deploy vault implementation contracts
        uint256 implementationCountBefore = vaultFactory.totalEntities();
        console2.log("Implementation count before whitelist:", implementationCountBefore);

        address vaultTokenizedImpl = address(new VaultTokenized(address(vaultFactory)));
        vaultFactory.whitelist(vaultTokenizedImpl);
        uint64 latestVersion = vaultFactory.lastVersion();
        console2.log("Latest implementation version:", latestVersion);

        // Verify that the implementation at the latest version is the one you just whitelisted
        require(vaultFactory.implementation(latestVersion) == vaultTokenizedImpl, "VaultTokenized implementation mismatch");

        console2.log("VaultTokenized implementation whitelisted.");

        // Deploy Delegator Implementations

        // Deploy Slasher Implementations

        // Prepare vaultParams
        bytes memory vaultParams = abi.encode(
            IVaultTokenized.InitParams({
                collateral: config.vaultConfig.collateralTokenAddress,
                burner: address(0xdEaD),
                epochDuration: config.vaultConfig.epochDuration,
                depositWhitelist: config.vaultConfig.depositWhitelist,
                isDepositLimit: config.vaultConfig.depositLimit != 0,
                depositLimit: config.vaultConfig.depositLimit,
                defaultAdminRoleHolder: config.generalConfig.owner,
                depositWhitelistSetRoleHolder: config.generalConfig.owner,
                depositorWhitelistRoleHolder: config.generalConfig.owner,
                isDepositLimitSetRoleHolder: config.generalConfig.owner,
                depositLimitSetRoleHolder: config.generalConfig.owner,
                name: config.vaultConfig.name,
                symbol: config.vaultConfig.symbol
            })
        );

        address[] memory networkLimitSetRoleHolders = new address[](1);
        networkLimitSetRoleHolders[0] = config.generalConfig.owner;
        address[] memory operatorNetworkLimitSetRoleHolders = new address[](1);
        operatorNetworkLimitSetRoleHolders[0] = config.generalConfig.owner;
        address[] memory operatorNetworkSharesSetRoleHolders = new address[](1);
        operatorNetworkSharesSetRoleHolders[0] = config.generalConfig.owner;

        // Prepare delegatorParams based on delegatorIndex
        bytes memory delegatorParams;
        if (config.delegatorConfig.delegatorIndex == 0) {
            delegatorParams = abi.encode(
                INetworkRestakeDelegator.InitParams({
                    baseParams: IBaseDelegator.BaseParams({
                        defaultAdminRoleHolder: config.generalConfig.owner,
                        hook: address(0),
                        hookSetRoleHolder: config.generalConfig.owner
                    }),
                    networkLimitSetRoleHolders: networkLimitSetRoleHolders,
                    operatorNetworkSharesSetRoleHolders: operatorNetworkSharesSetRoleHolders
                })
            );
        } else if (config.delegatorConfig.delegatorIndex == 1) {
            delegatorParams = abi.encode(
                IFullRestakeDelegator.InitParams({
                    baseParams: IBaseDelegator.BaseParams({
                        defaultAdminRoleHolder: config.generalConfig.owner,
                        hook: address(0),
                        hookSetRoleHolder: config.generalConfig.owner
                    }),
                    networkLimitSetRoleHolders: networkLimitSetRoleHolders,
                    operatorNetworkLimitSetRoleHolders: operatorNetworkSharesSetRoleHolders
                })
            );
        } else if (config.delegatorConfig.delegatorIndex == 2) {
            delegatorParams = abi.encode(
                IOperatorSpecificDelegator.InitParams({
                    baseParams: IBaseDelegator.BaseParams({
                        defaultAdminRoleHolder: config.generalConfig.owner,
                        hook: address(0),
                        hookSetRoleHolder: config.generalConfig.owner
                    }),
                    networkLimitSetRoleHolders: networkLimitSetRoleHolders,
                    operator: config.delegatorConfig.operator
                })
            );
        }

        // Prepare slasherParams if needed
        bytes memory slasherParams;
        if (config.generalConfig.defaultIncludeSlasher) {
            if (config.slasherConfig.slasherIndex == 0) {
                slasherParams = abi.encode(
                    ISlasher.InitParams({
                        baseParams: IBaseSlasher.BaseParams({isBurnerHook: false})
                    })
                );
            } else if (config.slasherConfig.slasherIndex == 1) {
                slasherParams = abi.encode(
                    IVetoSlasher.InitParams({
                        baseParams: IBaseSlasher.BaseParams({isBurnerHook: false}),
                        vetoDuration: config.slasherConfig.vetoDuration,
                        resolverSetEpochsDelay: config.delegatorConfig.resolverEpochsDelay
                    })
                );
            }
        }

        // Define InitParams based on configuration
        InitParams memory params = InitParams({
            version: config.generalConfig.initialVaultVersion,
            owner: config.generalConfig.owner,
            vaultParams: vaultParams,
            delegatorIndex: config.delegatorConfig.delegatorIndex,
            delegatorParams: delegatorParams,
            withSlasher: config.generalConfig.defaultIncludeSlasher,
            slasherIndex: config.slasherConfig.slasherIndex,
            slasherParams: slasherParams
        });

        // Create Vault
        address vault = vaultFactory.create(params.version, params.owner, params.vaultParams, address(delegatorFactory), address(slasherFactory));
        console2.log("Vault deployed at:", vault);

        // Create Delegator
        // address delegator = delegatorFactory.create(params.delegatorIndex, abi.encode(vault, params.delegatorParams));
        // console2.log("Delegator deployed at:", delegator);

        // // Conditionally Create Slasher
        // address slasher;
        // if (params.withSlasher) {
        //     slasher = slasherFactory.create(params.slasherIndex, abi.encode(vault, params.slasherParams));
        //     console2.log("Slasher deployed at:", slasher);
        // }

        // Set Delegator and Slasher in Vault
        // VaultTokenized(vault).setDelegator(delegator);
        // if (params.withSlasher) {
        //     VaultTokenized(vault).setSlasher(slasher);
        // }


        require(vaultFactory.owner() == config.generalConfig.owner, "VaultFactory ownership is incorrect");
        require(delegatorFactory.owner() == config.generalConfig.owner, "DelegatorFactory ownership transfer is incorrect");
        require(slasherFactory.owner() == config.generalConfig.owner, "SlasherFactory ownership transfer is incorrect");

        // Log the addresses of the deployed contracts for verification
        console2.log("VaultFactory: ", address(vaultFactory));
        console2.log("DelegatorFactory: ", address(delegatorFactory));
        console2.log("SlasherFactory: ", address(slasherFactory));
        // console2.log("NetworkRegistry: ", address(networkRegistry));
        console2.log("OperatorRegistry: ", address(operatorRegistry));
        // console2.log("OperatorMetadataService: ", address(operatorMetadataService));
        // console2.log("NetworkMetadataService: ", address(networkMetadataService));
        // console2.log("NetworkMiddlewareService: ", address(networkMiddlewareService));
        // console2.log("OperatorVaultOptInService: ", address(operatorVaultOptInService));
        // console2.log("OperatorNetworkOptInService: ", address(operatorNetworkOptInService));

        console2.log("Deployment completed.");

        string memory deploymentFileName = "codeDeploymentDetails.json";
        string memory filePath = string.concat("./deployments/", deploymentFileName);

        if (vm.exists(filePath)) {
            // If file exists, delete it
            vm.removeFile(filePath);
        }

        string memory coreContracts = "core contracts key";
        vm.serializeAddress(coreContracts, "VaultFactory", address(vaultFactory));
        vm.serializeAddress(coreContracts, "DelegatorFactory", address(delegatorFactory));
        vm.serializeAddress(coreContracts, "SlasherFactory", address(slasherFactory));
        vm.serializeAddress(coreContracts, "VaultTokenized", vault);
        // vm.serializeAddress(coreContracts, "Delegator", delegator);
        // if (params.withSlasher) {
        //     vm.serializeAddress(coreContracts, "Slasher", slasher);
        // }
        
        string memory coreOutput = vm.serializeAddress(coreContracts, "Vault", address(vault));

        vm.writeJson(coreOutput, filePath);

        vm.stopBroadcast();
    }
}
