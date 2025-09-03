// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

struct MiddlewareConfig {
    address middlewareOwnerAddress;
    address balancer;
    address operatorRegistry;
    address vaultFactory;
    address operatorL1OptIn;
    address primaryCollateral;
    uint256 primaryCollateralMaxStake;
    uint256 primaryCollateralMinStake;
    uint256 primaryCollateralWeightScaleFactor;
    uint48 epochDuration;
    uint48 slashingWindow;
    uint48 stakeUpdateWindow;
    uint48 vaultRemovalEpochDelay;
}
