// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

import {VaultFactory} from "../../../src/contracts/VaultFactory.sol";
import {DelegatorFactory} from "../../../src/contracts/DelegatorFactory.sol";
import {SlasherFactory} from "../../../src/contracts/SlasherFactory.sol";
import {L1Registry} from "../../../src/contracts/L1Registry.sol";
import {OperatorRegistry} from "../../../src/contracts/OperatorRegistry.sol";

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

        vm.startBroadcast();

        Token collateralAsset = new Token("CollateralToken");
        console2.log("Test Collateral Deployed at:", address(collateralAsset));

        collateralAsset.transfer(config.generalConfig.owner, 500_000 ether);

        VaultFactory vaultFactory = new VaultFactory(config.generalConfig.owner);
        DelegatorFactory delegatorFactory = new DelegatorFactory(config.generalConfig.owner);
        SlasherFactory slasherFactory = new SlasherFactory(config.generalConfig.owner);
        L1Registry l1Registry = new L1Registry();
        OperatorRegistry operatorRegistry = new OperatorRegistry();

        console2.log("VaultFactory deployed at:", address(vaultFactory));
        console2.log("DelegatorFactory deployed at:", address(delegatorFactory));
        console2.log("SlasherFactory deployed at:", address(slasherFactory));
        console2.log("L1Registry deployed at:", address(l1Registry));
        console2.log("OperatorRegistry deployed at:", address(operatorRegistry));

        address vaultTokenizedImpl = address(new VaultTokenized(address(vaultFactory)));
        vaultFactory.whitelist(vaultTokenizedImpl);
        console2.log("VaultTokenized implementation whitelisted at version:", vaultFactory.lastVersion());

        address l1RestakeDelegatorImpl = address(
            new L1RestakeDelegator(
                address(l1Registry),
                address(vaultFactory),
                address(0),
                address(0),
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

        // 6. Deploy Vault
        address vault = vaultFactory.create(
            params.version, 
            params.owner, 
            params.vaultParams, 
            address(delegatorFactory), 
            address(slasherFactory)
        );
        console2.log("Vault deployed at:", vault);

        // 7. Deploy Delegator
        address delegator = delegatorFactory.create(
            params.delegatorIndex,
            abi.encode(vault, params.delegatorParams)
        );
        console2.log("Delegator deployed at:", delegator);

        VaultTokenized(vault).setDelegator(delegator);

        // If slasher included, deploy slasher
        address slasher;
        if (params.withSlasher) {
            slasher = slasherFactory.create(params.slasherIndex, abi.encode(vault, params.slasherParams));
            console2.log("Slasher deployed at:", slasher);
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

        string memory output = vm.serializeAddress(key, "OperatorRegistry", address(operatorRegistry));
        vm.writeJson(output, filePath);

        vm.stopBroadcast();
    }
}
