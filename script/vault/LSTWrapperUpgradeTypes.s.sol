// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

struct LSTWrapperUpgradeConfig {
    string newImplementation;    // "LSTWrapper" or "LSTWrapperMerkl"
    address proxyAddress;        // Existing LST wrapper proxy
    address newRewards;          // New rewards contract (Merkle Distributor or RewardsNativeToken)
}
