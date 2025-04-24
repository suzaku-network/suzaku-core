// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

struct GeneralConfig {
    address owner;
    uint64 initialVaultVersion;
    bool defaultIncludeSlasher;
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

struct L1RegistryConfig {   
    address feeCollector;
    uint256 initialRegisterFee;
    uint256 maxRegisterFee;
    address owner;
}

struct BootstraperConfig {
    GeneralConfig generalConfig;
    FactoryConfig factoryConfig;
    OptinConfig optinConfig;
    L1RegistryConfig l1RegistryConfig;
}
