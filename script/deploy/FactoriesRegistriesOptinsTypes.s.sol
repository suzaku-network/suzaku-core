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

/**
 * @dev This new, minimal BootstraperConfig has only the fields
 * relevant to general (network-level) ownership and any
 * factory/registry references. We remove VaultConfig,
 * DelegatorConfig, SlasherConfig since those are “vault-level.”
 */
struct BootstraperConfig {
    GeneralConfig generalConfig;
    FactoryConfig factoryConfig; // references to already-deployed factories, if desired
    OptinConfig optinConfig; // references to already-deployed opt-in services, if desired
}
