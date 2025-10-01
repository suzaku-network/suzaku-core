// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

contract MockVaultScan {
    uint256 public immutable currentEpochFixed;

    constructor(uint256 currentEpoch_) {
        currentEpochFixed = currentEpoch_;
    }

    function currentEpoch() external view returns (uint256) {
        return currentEpochFixed;
    }

    // Always 1 share to maximize hits
    function withdrawalSharesOf(uint256, address) external pure returns (uint256) {
        return 1;
    }

    // Never claimed
    function isWithdrawalsClaimed(uint256, address) external pure returns (bool) {
        return false;
    }

    // Stubs for other IVaultTokenized methods if ever called in other tests
    function activeSharesOf(address) external pure returns (uint256) { return 0; }
    function activeSharesOfAt(address, uint48, bytes memory) external pure returns (uint256) { return 0; }
    function activeSharesAt(uint48, bytes memory) external pure returns (uint256) { return 0; }
}
