// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

struct RewardsConfig {
    address admin;
    address protocolOwner;
    address l1Middleware;
    address middlewareVaultManager;
    uint16 protocolFee;
    uint16 operatorFee;
    uint16 curatorFee;
} 
