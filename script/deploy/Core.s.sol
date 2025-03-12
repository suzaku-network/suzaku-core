// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";

import {VaultConfig, DelegatorConfig, SlasherConfig, FactoryConfig, RolesConfig} from "./VaultConfigTypes.s.sol";

import {VaultFactory} from "../../src/contracts/VaultFactory.sol";
import {DelegatorFactory} from "../../src/contracts/DelegatorFactory.sol";
import {SlasherFactory} from "../../src/contracts/SlasherFactory.sol";
import {L1Registry} from "../../src/contracts/L1Registry.sol";
import {OperatorRegistry} from "../../src/contracts/OperatorRegistry.sol";
import {OperatorVaultOptInService} from "../../src/contracts/service/OperatorVaultOptInService.sol";
import {OperatorL1OptInService} from "../../src/contracts/service/OperatorL1OptInService.sol";
import {VaultTokenized} from "../../src/contracts/vault/VaultTokenized.sol";
import {L1RestakeDelegator} from "../../src/contracts/delegator/L1RestakeDelegator.sol";

import {IVaultTokenized} from "../../src/interfaces/vault/IVaultTokenized.sol";
import {IL1RestakeDelegator} from "../../src/interfaces/delegator/IL1RestakeDelegator.sol";
import {IBaseDelegator} from "../../src/interfaces/delegator/IBaseDelegator.sol";
import {ISlasher} from "../../src/interfaces/slasher/ISlasher.sol";
import {IVetoSlasher} from "../../src/interfaces/slasher/IVetoSlasher.sol";
import {IBaseSlasher} from "../../src/interfaces/slasher/IBaseSlasher.sol";

contract CoreScript is Script {
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

    function executeCoreDeployment(
        VaultConfig memory vaultConfig
    ) public returns (address vaultTokenized, address delegator, address slasher) {
        vm.startBroadcast(vaultConfig.owner);

        vaultFactory = VaultFactory(vaultConfig.factoryConfig.vaultFactory);
        delegatorFactory = DelegatorFactory(vaultConfig.factoryConfig.delegatorFactory);
        slasherFactory = SlasherFactory(vaultConfig.factoryConfig.slasherFactory);
        l1Registry = L1Registry(vaultConfig.factoryConfig.l1Registry);
        operatorRegistry = OperatorRegistry(vaultConfig.factoryConfig.operatorRegistry);

        console2.log("Deploying core contracts...", vaultConfig.factoryConfig.vaultFactory);

        // Whitelist VaultTokenized implementation
        address vaultTokenizedImpl = address(new VaultTokenized(vaultConfig.factoryConfig.vaultFactory));
        vaultFactory.whitelist(vaultTokenizedImpl);
        console2.log("VaultTokenized implementation whitelisted at version:", vaultFactory.lastVersion());

        // Whitelist L1RestakeDelegator
        address l1RestakeDelegatorImpl = address(
            new L1RestakeDelegator(
                vaultConfig.owner,
                vaultConfig.factoryConfig.vaultFactory,
                vaultConfig.factoryConfig.operatorVaultOptInService,
                vaultConfig.factoryConfig.operatorL1OptInService,
                vaultConfig.factoryConfig.delegatorFactory,
                delegatorFactory.totalTypes()
            )
        );
        delegatorFactory.whitelist(l1RestakeDelegatorImpl);
        console2.log("L1RestakeDelegator implementation whitelisted at type:", delegatorFactory.totalTypes() - 1);

        console2.log("Initializing VaultTokenized with factory:", vaultConfig.factoryConfig.vaultFactory);
        console2.log("Collateral:", vaultConfig.collateralAsset);
        console2.log("Epoch Duration:", vaultConfig.epochDuration);

        // Build VaultTokenized.InitParams
        bytes memory vaultParams = abi.encode(
            IVaultTokenized.InitParams({
                collateral: vaultConfig.collateralAsset,
                burner: address(0xdEaD),
                epochDuration: vaultConfig.epochDuration,
                depositWhitelist: vaultConfig.depositWhitelist,
                isDepositLimit: vaultConfig.depositLimit != 0,
                depositLimit: vaultConfig.depositLimit,
                defaultAdminRoleHolder: vaultConfig.owner,
                depositWhitelistSetRoleHolder: vaultConfig.rolesConfig.depositWhitelistSetRoleHolder,
                depositorWhitelistRoleHolder: vaultConfig.rolesConfig.depositorWhitelistRoleHolder,
                isDepositLimitSetRoleHolder: vaultConfig.rolesConfig.isDepositLimitSetRoleHolder,
                depositLimitSetRoleHolder: vaultConfig.rolesConfig.depositLimitSetRoleHolder,
                name: vaultConfig.name,
                symbol: vaultConfig.symbol
            })
        );

        // Delegator logic
        address[] memory l1LimitSetRoleHolders = new address[](1);
        l1LimitSetRoleHolders[0] = vaultConfig.rolesConfig.l1LimitSetRoleHolders;

        address[] memory operatorL1SharesSetRoleHolders = new address[](1);
        operatorL1SharesSetRoleHolders[0] = vaultConfig.rolesConfig.operatorL1SharesSetRoleHolders;

        bytes memory delegatorParams = abi.encode(
            IL1RestakeDelegator.InitParams({
                baseParams: IBaseDelegator.BaseParams({
                    defaultAdminRoleHolder: vaultConfig.owner,
                    hook: address(0),
                    hookSetRoleHolder: vaultConfig.owner
                }),
                l1LimitSetRoleHolders: l1LimitSetRoleHolders,
                operatorL1SharesSetRoleHolders: operatorL1SharesSetRoleHolders
            })
        );

        // Slasher logic
        bool withSlasher = vaultConfig.slasherConfig.includeSlasher;
        bytes memory slasherParams;
        if (withSlasher) {
            if (vaultConfig.slasherConfig.slasherIndex == 0) {
                slasherParams =
                    abi.encode(ISlasher.InitParams({baseParams: IBaseSlasher.BaseParams({isBurnerHook: false})}));
            } else if (vaultConfig.slasherConfig.slasherIndex == 1) {
                slasherParams = abi.encode(
                    IVetoSlasher.InitParams({
                        baseParams: IBaseSlasher.BaseParams({isBurnerHook: false}),
                        vetoDuration: vaultConfig.slasherConfig.vetoDuration,
                        resolverSetEpochsDelay: vaultConfig.delegatorConfig.resolverEpochsDelay
                    })
                );
            }
        }

        // Build InitParams
        InitParams memory params = InitParams({
            version: vaultConfig.initialVaultVersion,
            owner: vaultConfig.owner,
            vaultParams: vaultParams,
            delegatorIndex: vaultConfig.delegatorConfig.delegatorIndex,
            delegatorParams: delegatorParams,
            withSlasher: withSlasher,
            slasherIndex: vaultConfig.slasherConfig.slasherIndex,
            slasherParams: slasherParams
        });

        // Create Vault
        vaultTokenized = vaultFactory.create(
            params.version, params.owner, params.vaultParams, address(delegatorFactory), address(slasherFactory)
        );

        console2.log("Vault deployed at:", vaultTokenized);

        // Create Delegator
        delegator = delegatorFactory.create(params.delegatorIndex, abi.encode(vaultTokenized, params.delegatorParams));
        console2.log("Delegator deployed at:", delegator);

        // Set delegator in the vault
        VaultTokenized(vaultTokenized).setDelegator(delegator);

        slasher;
        if (params.withSlasher) {
            slasher = slasherFactory.create(params.slasherIndex, abi.encode(vaultTokenized, params.slasherParams));
            console2.log("Slasher deployed at:", slasher);
            VaultTokenized(vaultTokenized).setSlasher(slasher);
        }

        console2.log("Full local deployment completed successfully.");

        vm.stopBroadcast();

        return (vaultTokenized, delegator, slasher);
    }
}
