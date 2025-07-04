// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {HelperConfig, NetworkConfig} from "./HelperConfig.s.sol";

import {VaultFactory} from "../../../src/contracts/VaultFactory.sol";
import {DelegatorFactory} from "../../../src/contracts/DelegatorFactory.sol";
import {SlasherFactory} from "../../../src/contracts/SlasherFactory.sol";
import {L1Registry} from "../../../src/contracts/L1Registry.sol";
import {OperatorRegistry} from "../../../src/contracts/OperatorRegistry.sol";
import {OperatorVaultOptInService} from "../../../src/contracts/service/OperatorVaultOptInService.sol";
import {OperatorL1OptInService} from "../../../src/contracts/service/OperatorL1OptInService.sol";
import {VaultTokenized} from "../../../src/contracts/vault/VaultTokenized.sol";
import {L1RestakeDelegator} from "../../../src/contracts/delegator/L1RestakeDelegator.sol";
import {IVaultTokenized} from "../../../src/interfaces/vault/IVaultTokenized.sol";
import {IL1RestakeDelegator} from "../../../src/interfaces/delegator/IL1RestakeDelegator.sol";
import {IBaseDelegator} from "../../../src/interfaces/delegator/IBaseDelegator.sol";
import {ISlasher} from "../../../src/interfaces/slasher/ISlasher.sol";
import {IVetoSlasher} from "../../../src/interfaces/slasher/IVetoSlasher.sol";
import {IBaseSlasher} from "../../../src/interfaces/slasher/IBaseSlasher.sol";
import {Token} from "../../../test/mocks/MockToken.sol"; // A simple ERC20 for collateral

contract FullLocalDeploymentScript is Script {
    HelperConfig internal helperConfig;
    NetworkConfig internal config;

    Token internal collateralAsset;
    VaultFactory internal vaultFactory;
    DelegatorFactory internal delegatorFactory;
    SlasherFactory internal slasherFactory;
    L1Registry internal l1Registry;
    OperatorRegistry internal operatorRegistry;

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
        helperConfig = new HelperConfig();
        config = helperConfig.getConfig();

        vm.startBroadcast();

        collateralAsset = new Token("CollateralToken");
        console2.log("Test Collateral Deployed at:", address(collateralAsset));

        collateralAsset.transfer(config.generalConfig.owner, 500_000 ether);

        vaultFactory = new VaultFactory(config.generalConfig.owner);
        delegatorFactory = new DelegatorFactory(config.generalConfig.owner);
        slasherFactory = new SlasherFactory(config.generalConfig.owner);
        l1Registry = new L1Registry(
            payable(config.generalConfig.owner), // fee collector
            0.01 ether, // initial register fee
            1 ether, // MAX_FEE
            config.generalConfig.owner // owner
        );
        operatorRegistry = new OperatorRegistry();

        console2.log("VaultFactory deployed at:", address(vaultFactory));
        console2.log("DelegatorFactory deployed at:", address(delegatorFactory));
        console2.log("SlasherFactory deployed at:", address(slasherFactory));
        console2.log("L1Registry deployed at:", address(l1Registry));
        console2.log("OperatorRegistry deployed at:", address(operatorRegistry));

        address vaultTokenizedImpl = address(new VaultTokenized(address(vaultFactory)));
        vaultFactory.whitelist(vaultTokenizedImpl);
        console2.log("VaultTokenized implementation whitelisted at version:", vaultFactory.lastVersion());

        OperatorVaultOptInService operatorVaultOptInService = new OperatorVaultOptInService(
            address(operatorRegistry), // WHO_REGISTRY (isRegistered)
            address(vaultFactory), // WHERE_REGISTRY (isRegistered)
            "OperatorVaultOptInService"
        );
        console2.log("OperatorVaultOptInService deployed at:", address(operatorVaultOptInService));

        OperatorL1OptInService operatorL1OptInService = new OperatorL1OptInService(
            address(operatorRegistry), // WHO_REGISTRY (isRegistered)
            address(l1Registry), // WHERE_REGISTRY (isEntity)
            "OperatorL1OptInService"
        );
        console2.log("OperatorL1OptInService deployed at:", address(operatorL1OptInService));

        address l1RestakeDelegatorImpl = address(
            new L1RestakeDelegator(
                address(l1Registry),
                address(vaultFactory),
                address(operatorVaultOptInService),
                address(operatorL1OptInService),
                address(delegatorFactory),
                delegatorFactory.totalTypes()
            )
        );
        delegatorFactory.whitelist(l1RestakeDelegatorImpl);
        console2.log("L1RestakeDelegator implementation whitelisted at type:", delegatorFactory.totalTypes() - 1);

        bytes memory vaultParams = abi.encode(
            IVaultTokenized.InitParams({
                collateral: address(collateralAsset),
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

        address[] memory l1LimitSetRoleHolders = new address[](1);
        l1LimitSetRoleHolders[0] = config.generalConfig.owner;
        address[] memory operatorL1SharesSetRoleHolders = new address[](1);
        operatorL1SharesSetRoleHolders[0] = config.generalConfig.owner;

        bytes memory delegatorParams;
        if (config.delegatorConfig.delegatorIndex == 0) {
            delegatorParams = abi.encode(
                IL1RestakeDelegator.InitParams({
                    baseParams: IBaseDelegator.BaseParams({
                        defaultAdminRoleHolder: config.generalConfig.owner,
                        hook: address(0),
                        hookSetRoleHolder: config.generalConfig.owner
                    }),
                    l1LimitSetRoleHolders: l1LimitSetRoleHolders,
                    operatorL1SharesSetRoleHolders: operatorL1SharesSetRoleHolders
                })
            );
        }

        bytes memory slasherParams;
        if (config.generalConfig.defaultIncludeSlasher) {
            if (config.slasherConfig.slasherIndex == 0) {
                slasherParams =
                    abi.encode(ISlasher.InitParams({baseParams: IBaseSlasher.BaseParams({isBurnerHook: false})}));
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

        address vault = vaultFactory.create(
            params.version, params.owner, params.vaultParams, address(delegatorFactory), address(slasherFactory)
        );
        VaultTokenized(vault).setDepositorWhitelistStatus(config.generalConfig.owner, true);
        console2.log("Vault deployed at:", vault);

        address delegator = delegatorFactory.create(params.delegatorIndex, abi.encode(vault, params.delegatorParams));
        console2.log("Delegator deployed at:", delegator);

        // Set delegator in the vault - use the Admin Role Holder
        vm.prank(params.owner);
        VaultTokenized(vault).setDelegator(delegator);

        // If slasher included, deploy slasher
        address slasher;
        if (params.withSlasher) {
            slasher = slasherFactory.create(params.slasherIndex, abi.encode(vault, params.slasherParams));
            console2.log("Slasher deployed at:", slasher);
            
            vm.prank(params.owner);
            VaultTokenized(vault).setSlasher(slasher);
        }

        console2.log("Full local deployment completed successfully.");

        // Optionally write out deployment details
        string memory deploymentFileName = "fullLocalDeployment.json";
        string memory filePath = string.concat("./deployments/", deploymentFileName);

        if (vm.exists(filePath)) {
            vm.removeFile(filePath);
        }

        string memory key = "full_deployment";
        vm.serializeAddress(key, "CollateralAsset", address(collateralAsset));
        vm.serializeAddress(key, "Vault", vault);
        vm.serializeAddress(key, "Delegator", delegator);
        if (params.withSlasher) {
            vm.serializeAddress(key, "Slasher", slasher);
        }
        vm.serializeAddress(key, "VaultFactory", address(vaultFactory));
        vm.serializeAddress(key, "DelegatorFactory", address(delegatorFactory));
        vm.serializeAddress(key, "SlasherFactory", address(slasherFactory));
        vm.serializeAddress(key, "L1Registry", address(l1Registry));
        vm.serializeAddress(key, "OperatorRegistry", address(operatorRegistry));
        vm.serializeAddress(key, "OperatorVaultOptInService", address(operatorVaultOptInService));
        vm.serializeAddress(key, "OperatorL1OptInService", address(operatorL1OptInService));
        string memory output = vm.serializeAddress(key, "OperatorRegistry", address(operatorRegistry));
        vm.writeJson(output, filePath);

        vm.stopBroadcast();
    }
}
