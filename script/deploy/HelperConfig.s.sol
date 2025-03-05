// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity ^0.8.25;

import {Script, console2} from "forge-std/Script.sol";

contract HelperConfig is Script {
    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/
    struct GeneralConfig {
        address owner;
        uint64 initialVaultVersion;
        bool defaultIncludeSlasher;
    }

    struct VaultConfig {
        address collateralTokenAddress;
        uint48 epochDuration;
        bool depositWhitelist;
        uint256 depositLimit;
        string name;
        string symbol;
    }

    struct DelegatorConfig {
        uint64 delegatorIndex;
        address operator;
        uint32 resolverEpochsDelay;
    }

    struct SlasherConfig {
        uint64 slasherIndex;
        uint48 vetoDuration;
        bool includeSlasher;
    }

    struct FactoryConfig {
        address vaultFactory;
        address delegatorFactory;
        address slasherFactory;
        address l1Registry;
        address operatorRegistry;
    }

    struct NetworkConfig {
        GeneralConfig generalConfig;
        VaultConfig vaultConfig;
        DelegatorConfig delegatorConfig;
        SlasherConfig slasherConfig;
        FactoryConfig factoryConfig;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    NetworkConfig public activeNetworkConfig;
    mapping(uint256 => NetworkConfig) public networkConfigs;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/
    error HelperConfig__InvalidChainId();
    error HelperConfig__MissingEnvironmentVariable(string variableName);

    constructor() {
        uint256 expectedChainId = vm.envUint("CHAIN_ID");
        require(block.chainid == expectedChainId, "Unexpected chain ID");

        activeNetworkConfig = getNetworkConfig();
        networkConfigs[block.chainid] = activeNetworkConfig;
    }

    /*//////////////////////////////////////////////////////////////
                                FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getNetworkConfig() internal view returns (NetworkConfig memory config) {
        console2.log("Deploying on chain ID:", block.chainid);

        config.generalConfig = getGeneralConfig();
        config.vaultConfig = getVaultConfig();
        config.delegatorConfig = getDelegatorConfig();
        config.slasherConfig = getSlasherConfig();
        config.factoryConfig = getFactoryConfig();

        return config;
    }

    function getGeneralConfig() internal view returns (GeneralConfig memory gc) {
        gc.owner = vm.envAddress("OWNER");
        gc.initialVaultVersion = uint64(vm.envUint("INITIAL_VAULT_VERSION"));
        gc.defaultIncludeSlasher = vm.envBool("DEFAULT_INCLUDE_SLASHER");
    }

    function getVaultConfig() internal view returns (VaultConfig memory vc) {
        vc.collateralTokenAddress = vm.envAddress("COLLATERAL_TOKEN_ADDRESS");
        vc.epochDuration = uint48(vm.envUint("EPOCH_DURATION"));
        vc.depositWhitelist = vm.envBool("DEPOSIT_WHITELIST");
        vc.depositLimit = vm.envUint("DEPOSIT_LIMIT");
        vc.name = vm.envString("NAME");
        vc.symbol = vm.envString("SYMBOL");
    }

    function getDelegatorConfig() internal view returns (DelegatorConfig memory dc) {
        dc.delegatorIndex = uint64(vm.envUint("DELEGATOR_INDEX"));
        dc.operator = vm.envAddress("OPERATOR");
        dc.resolverEpochsDelay = uint32(vm.envUint("RESOLVER_EPOCHS_DELAY"));
    }

    function getSlasherConfig() internal view returns (SlasherConfig memory sc) {
        sc.slasherIndex = uint64(vm.envUint("SLASHER_INDEX"));
        sc.vetoDuration = uint48(vm.envUint("VETO_DURATION"));
        sc.includeSlasher = vm.envBool("INCLUDE_SLASHER");
    }

    function getFactoryConfig() internal view returns (FactoryConfig memory fc) {
        fc.vaultFactory = vm.envOr("VAULT_FACTORY", address(0));
        fc.delegatorFactory = vm.envOr("DELEGATOR_FACTORY", address(0));
        fc.slasherFactory = vm.envOr("SLASHER_FACTORY", address(0));
        fc.l1Registry = vm.envOr("L1_REGISTRY", address(0));
        fc.operatorRegistry = vm.envOr("OPERATOR_REGISTRY", address(0));
    }

    function getConfig() external view returns (NetworkConfig memory) {
        return activeNetworkConfig;
    }

    function setConfig(uint256 chainId, NetworkConfig memory config) external {
        // Optionally add access control
        networkConfigs[chainId] = config;
    }

    function getConfigByChainId(
        uint256 chainId
    ) public view returns (NetworkConfig memory) {
        if (networkConfigs[chainId].generalConfig.owner != address(0)) {
            return networkConfigs[chainId];
        } else {
            revert HelperConfig__InvalidChainId();
        }
    }
}
