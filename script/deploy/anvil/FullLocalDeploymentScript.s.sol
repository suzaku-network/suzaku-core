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
import {LSTWrapperFactory} from "../../../src/contracts/vault/LSTWrapperFactory.sol";
import {VaultTokenized} from "../../../src/contracts/vault/VaultTokenized.sol";
import {L1RestakeDelegator} from "../../../src/contracts/delegator/L1RestakeDelegator.sol";
import {IVaultTokenized} from "../../../src/interfaces/vault/IVaultTokenized.sol";
import {IL1RestakeDelegator} from "../../../src/interfaces/delegator/IL1RestakeDelegator.sol";
import {IBaseDelegator} from "../../../src/interfaces/delegator/IBaseDelegator.sol";
import {ISlasher} from "../../../src/interfaces/slasher/ISlasher.sol";
import {IVetoSlasher} from "../../../src/interfaces/slasher/IVetoSlasher.sol";
import {IBaseSlasher} from "../../../src/interfaces/slasher/IBaseSlasher.sol";
import {Token} from "../../../test/mocks/MockToken.sol"; // A simple ERC20 for collateral
import {VaultHelper} from "../../../src/contracts/VaultHelper.sol";

contract FullLocalDeploymentScript is Script {
    HelperConfig internal helperConfig;
    NetworkConfig internal config;

    Token internal collateralAsset;
    VaultFactory internal vaultFactory;
    DelegatorFactory internal delegatorFactory;
    SlasherFactory internal slasherFactory;
    L1Registry internal l1Registry;
    OperatorRegistry internal operatorRegistry;

    // Storage for deployed addresses to reduce stack depth
    OperatorVaultOptInService internal s_operatorVaultOptInService;
    OperatorL1OptInService internal s_operatorL1OptInService;
    address internal s_vault;
    address internal s_delegator;
    address internal s_slasher;
    LSTWrapperFactory internal s_lstWrapperFactory;
    VaultHelper internal s_vaultHelper;

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

        _deployCoreContracts();
        _deployOptInServices();
        _deployDelegatorImpl();

        InitParams memory params = _buildInitParams();

        _deployVaultAndDelegator(params);
        _deployHelperContracts(params);

        console2.log("Full local deployment completed successfully.");

        _writeDeploymentJson(params);

        vm.stopBroadcast();
    }

    function _deployCoreContracts() internal {
        collateralAsset = new Token("CollateralToken");
        console2.log("Test Collateral Deployed at:", address(collateralAsset));

        collateralAsset.transfer(config.generalConfig.owner, 500_000 ether);

        vaultFactory = new VaultFactory(config.generalConfig.owner);
        delegatorFactory = new DelegatorFactory(config.generalConfig.owner);
        slasherFactory = new SlasherFactory(config.generalConfig.owner);
        l1Registry = new L1Registry(
            payable(config.generalConfig.owner),
            0.01 ether,
            1 ether,
            config.generalConfig.owner
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
    }

    function _deployOptInServices() internal {
        s_operatorVaultOptInService = new OperatorVaultOptInService(
            address(operatorRegistry),
            address(vaultFactory),
            "OperatorVaultOptInService"
        );
        console2.log("OperatorVaultOptInService deployed at:", address(s_operatorVaultOptInService));

        s_operatorL1OptInService = new OperatorL1OptInService(
            address(operatorRegistry),
            address(l1Registry),
            "OperatorL1OptInService"
        );
        console2.log("OperatorL1OptInService deployed at:", address(s_operatorL1OptInService));
    }

    function _deployDelegatorImpl() internal {
        address l1RestakeDelegatorImpl = address(
            new L1RestakeDelegator(
                address(l1Registry),
                address(vaultFactory),
                address(s_operatorVaultOptInService),
                address(s_operatorL1OptInService),
                address(delegatorFactory),
                delegatorFactory.totalTypes()
            )
        );
        delegatorFactory.whitelist(l1RestakeDelegatorImpl);
        console2.log("L1RestakeDelegator implementation whitelisted at type:", delegatorFactory.totalTypes() - 1);
    }

    function _buildInitParams() internal view returns (InitParams memory) {
        bytes memory vaultParams = _buildVaultParams();
        bytes memory delegatorParams = _buildDelegatorParams();
        bytes memory slasherParams = _buildSlasherParams();

        return InitParams({
            version: config.generalConfig.initialVaultVersion,
            owner: config.generalConfig.owner,
            vaultParams: vaultParams,
            delegatorIndex: config.delegatorConfig.delegatorIndex,
            delegatorParams: delegatorParams,
            withSlasher: config.generalConfig.defaultIncludeSlasher,
            slasherIndex: config.slasherConfig.slasherIndex,
            slasherParams: slasherParams
        });
    }

    function _buildVaultParams() internal view returns (bytes memory) {
        return abi.encode(
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
    }

    function _buildDelegatorParams() internal view returns (bytes memory delegatorParams) {
        if (config.delegatorConfig.delegatorIndex == 0) {
            address[] memory l1LimitSetRoleHolders = new address[](1);
            l1LimitSetRoleHolders[0] = config.generalConfig.owner;
            address[] memory operatorL1SharesSetRoleHolders = new address[](1);
            operatorL1SharesSetRoleHolders[0] = config.generalConfig.owner;

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
    }

    function _buildSlasherParams() internal view returns (bytes memory slasherParams) {
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
    }

    function _deployVaultAndDelegator(InitParams memory params) internal {
        s_vault = vaultFactory.create(
            params.version, params.owner, params.vaultParams, address(delegatorFactory), address(slasherFactory)
        );
        VaultTokenized(s_vault).setDepositorWhitelistStatus(config.generalConfig.owner, true);
        console2.log("Vault deployed at:", s_vault);

        s_delegator = delegatorFactory.create(params.delegatorIndex, abi.encode(s_vault, params.delegatorParams));
        console2.log("Delegator deployed at:", s_delegator);

        vm.prank(params.owner);
        VaultTokenized(s_vault).setDelegator(s_delegator);

        if (params.withSlasher) {
            s_slasher = slasherFactory.create(params.slasherIndex, abi.encode(s_vault, params.slasherParams));
            console2.log("Slasher deployed at:", s_slasher);

            vm.prank(params.owner);
            VaultTokenized(s_vault).setSlasher(s_slasher);
        }
    }

    function _deployHelperContracts(InitParams memory params) internal {
        s_lstWrapperFactory = new LSTWrapperFactory(params.owner, address(vaultFactory));
        console2.log("LSTWrapperFactory deployed at:", address(s_lstWrapperFactory));

        s_vaultHelper = new VaultHelper(address(vaultFactory), address(s_lstWrapperFactory));
        console2.log("VaultHelper deployed at:", address(s_vaultHelper));
    }

    function _writeDeploymentJson(InitParams memory params) internal {
        string memory filePath = "./deployments/fullLocalDeployment.json";

        if (vm.exists(filePath)) {
            vm.removeFile(filePath);
        }

        string memory key = "full_deployment";
        vm.serializeAddress(key, "CollateralAsset", address(collateralAsset));
        vm.serializeAddress(key, "Vault", s_vault);
        vm.serializeAddress(key, "Delegator", s_delegator);
        if (params.withSlasher) {
            vm.serializeAddress(key, "Slasher", s_slasher);
        }
        vm.serializeAddress(key, "VaultFactory", address(vaultFactory));
        vm.serializeAddress(key, "DelegatorFactory", address(delegatorFactory));
        vm.serializeAddress(key, "SlasherFactory", address(slasherFactory));
        vm.serializeAddress(key, "L1Registry", address(l1Registry));
        vm.serializeAddress(key, "OperatorRegistry", address(operatorRegistry));
        vm.serializeAddress(key, "OperatorVaultOptInService", address(s_operatorVaultOptInService));
        vm.serializeAddress(key, "OperatorL1OptInService", address(s_operatorL1OptInService));
        string memory output = vm.serializeAddress(key, "VaultHelper", address(s_vaultHelper));
        vm.writeJson(output, filePath);
    }
}
