// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

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
    address operatorVaultOptInService;
    address operatorL1OptInService;
}

struct RolesConfig {
    address depositWhitelistSetRoleHolder;
    address depositorWhitelistRoleHolder;
    address depositLimitSetRoleHolder;
    address isDepositLimitSetRoleHolder;
    address l1LimitSetRoleHolders;
    address operatorL1SharesSetRoleHolders;
}

struct VaultConfig {
    address owner;
    address collateralAsset;
    uint48 epochDuration;
    bool depositWhitelist;
    uint256 depositLimit;
    uint64 initialVaultVersion;
    string name;
    string symbol;
    DelegatorConfig delegatorConfig;
    SlasherConfig slasherConfig;
    FactoryConfig factoryConfig;
    RolesConfig rolesConfig;
}
