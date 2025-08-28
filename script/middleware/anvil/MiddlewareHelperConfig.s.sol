// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {Script} from "forge-std/Script.sol";
import {Token} from "../../../test/mocks/MockToken.sol";

contract MiddlewareHelperConfig is Script {
    struct NetworkConfig {
        uint256 proxyAdminOwnerKey;
        uint256 protocolOwnerKey;
        bytes32 l1ID;
        uint64 churnPeriodSeconds;
        uint8 maximumChurnPercentage;
        address primaryCollateral;
        uint256 primaryCollateralMaxStake;
        uint256 primaryCollateralMinStake;
        uint256 primaryCollateralWeightScaleFactor;
    }

    NetworkConfig public activeNetworkConfig;

    constructor() {
        // if (block.chainid == 43_113) {
        //     activeNetworkConfig = getAvalancheFujiConfig();
        // } else {
        activeNetworkConfig = getOrCreateAnvilConfig();
        // }
    }

    function getOrCreateAnvilConfig() public returns (NetworkConfig memory) {
        (, uint256 proxyAdminOwnerKey) = makeAddrAndKey("proxyAdminOwner");
        (, uint256 protocolOwnerKey) = makeAddrAndKey("protocolOwner");

        Token localToken = new Token("collateral");

        return NetworkConfig({
            proxyAdminOwnerKey: proxyAdminOwnerKey,
            protocolOwnerKey: protocolOwnerKey,
            l1ID: 0x5f4c8570d996184af03052f1b3acc1c7b432b0a41e7480de1b72d4c6f5983eb9,
            churnPeriodSeconds: 1 hours,
            maximumChurnPercentage: 20,
            primaryCollateral: address(localToken),
            primaryCollateralMaxStake: 100_000_000_000_000_000_000,
            primaryCollateralMinStake: 100_000_000_000_000,
            // Scale so minStake (1e14) -> weight 1, and maxStake (1e20) -> weight 1,000,000
            // This aligns test stake sizes with a 1,000,000-weight L1 and 20% churn budget (200,000).
            primaryCollateralWeightScaleFactor: 1e14
        });
    }
}
