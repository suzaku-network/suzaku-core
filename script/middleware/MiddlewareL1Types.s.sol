// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

struct MiddlewareConfig {
    uint256 proxyAdminOwnerKey;
    uint256 protocolOwnerKey;
    address validatorManager;
    address operatorRegistry;
    address vaultFactory;
    address operatorL1OptIn;
    address primaryAsset;
    uint256 primaryAssetMaxStake;
    uint256 primaryAssetMinStake;
    uint48 epochDuration;
    uint48 slashingWindow;
    uint48 weightUpdateWindow;
}
