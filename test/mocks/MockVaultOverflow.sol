// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

contract MockVaultOverflow {
    function currentEpoch() external pure returns (uint256) {
        return type(uint256).max - 1; // any value > max-5 will trigger overflow in (currentEpoch + 5)
    }
    // Unused in this test but harmless to include
    function withdrawalSharesOf(uint256, address) external pure returns (uint256) { return 0; }
    function isWithdrawalsClaimed(uint256, address) external pure returns (bool) { return true; }
}
