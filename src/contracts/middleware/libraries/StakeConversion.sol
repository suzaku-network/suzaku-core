// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

library StakeConversion {
    error MiddlewareUtils__OverflowInStakeToWeight();

    /**
     * @notice Convert a full 256-bit stake amount into a 64-bit weight
     * @dev Anything < WEIGHT_SCALE_FACTOR becomes 0
     */
    function stakeToWeight(uint256 stakeAmount, uint256 scaleFactor) internal pure returns (uint64) {
        uint256 weight = stakeAmount / scaleFactor;
        if (weight > type(uint64).max) {
            revert MiddlewareUtils__OverflowInStakeToWeight();
        }
        return uint64(weight);
    }

    /**
     * @notice Convert a 64-bit weight back into its 256-bit stake amount
     */
    function weightToStake(uint64 weight, uint256 scaleFactor) internal pure returns (uint256) {
        return uint256(weight) * scaleFactor;
    }

    /**
     * @notice Remove the node from the dynamic array (swap and pop).
     * @dev Matches logic from _removeNodeFromArray() unchanged.
     */
    function removeNodeFromArray(bytes32[] storage arr, bytes32 nodeId) internal {
        uint256 arrLength = arr.length;
        for (uint256 i = 0; i < arrLength; i++) {
            if (arr[i] == nodeId) {
                uint256 lastIndex;
                unchecked {
                    lastIndex = arrLength - 1;
                }
                if (i != lastIndex) {
                    arr[i] = arr[lastIndex];
                }
                arr.pop();
                break;
            }
        }
    }
}
