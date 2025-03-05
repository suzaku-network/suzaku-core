// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

library StakeConversion {
    uint256 internal constant WEIGHT_SCALE_FACTOR = 1e8;

    error MiddlewareUtils__OverflowInStakeToWeight();

    /**
     * @notice Convert a full 256-bit stake amount into a 64-bit weight
     * @dev Anything < WEIGHT_SCALE_FACTOR becomes 0
     */
    function stakeToWeight(
        uint256 stakeAmount
    ) internal pure returns (uint64) {
        uint256 weight = stakeAmount / WEIGHT_SCALE_FACTOR;
        if (weight > type(uint64).max) {
            revert MiddlewareUtils__OverflowInStakeToWeight();
        }
        // require(weight <= type(uint64).max, "Overflow in stakeToWeight");
        return uint64(weight);
    }

    /**
     * @notice Convert a 64-bit weight back into its 256-bit stake amount
     */
    function weightToStake(
        uint64 weight
    ) internal pure returns (uint256) {
        return uint256(weight) * WEIGHT_SCALE_FACTOR;
    }

    /**
     * @notice Remove the node from the dynamic array (swap and pop).
     * @dev Matches logic from _removeNodeFromArray() unchanged.
     */
    function removeNodeFromArray(bytes32[] storage arr, bytes32 nodeId) internal {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == nodeId) {
                uint256 lastIndex = arr.length - 1;
                if (i != lastIndex) {
                    arr[i] = arr[lastIndex];
                }
                arr.pop();
                break;
            }
        }
    }
}
