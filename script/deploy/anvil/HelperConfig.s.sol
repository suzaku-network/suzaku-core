// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/*//////////////////////////////////////////////////////////////
                            STRUCTS
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

struct OptinConfig {
    address operatorVaultOptInService;
    address operatorL1OptInService;
}

struct NetworkConfig {
    GeneralConfig generalConfig;
    VaultConfig vaultConfig;
    DelegatorConfig delegatorConfig;
    SlasherConfig slasherConfig;
    FactoryConfig factoryConfig;
    OptinConfig optinConfig;
}

contract HelperConfig is Script {
    NetworkConfig public activeNetworkConfig;

    constructor() {
        activeNetworkConfig = getAnvilConfig();
    }

    function getAnvilConfig() internal pure returns (NetworkConfig memory) {
        // Hardcode owner to the default Anvil #1 address:
        address ownerAddr = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
        // Hardcoded operator to the default Anvil #2 address:
        address operatorAddr = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

        console2.log("Using Owner Address:", ownerAddr);
        console2.log("Using Operator Address:", operatorAddr);

        return NetworkConfig({
            generalConfig: GeneralConfig({owner: ownerAddr, initialVaultVersion: 1, defaultIncludeSlasher: false}),
            vaultConfig: VaultConfig({
                collateralTokenAddress: address(0), // will be set after deploying mock token
                epochDuration: 3600,
                depositWhitelist: true,
                depositLimit: 1_000_000_000_000_000_000_000,
                name: "TEST",
                symbol: "Test"
            }),
            delegatorConfig: DelegatorConfig({delegatorIndex: 0, operator: operatorAddr, resolverEpochsDelay: 10}),
            slasherConfig: SlasherConfig({slasherIndex: 0, vetoDuration: 3600, includeSlasher: false}),
            factoryConfig: FactoryConfig({
                vaultFactory: address(0),
                delegatorFactory: address(0),
                slasherFactory: address(0),
                l1Registry: address(0),
                operatorRegistry: address(0)
            }),
            optinConfig: OptinConfig({operatorVaultOptInService: address(0), operatorL1OptInService: address(0)})
        });
    }

    function getConfig() external view returns (NetworkConfig memory) {
        return activeNetworkConfig;
    }
}
