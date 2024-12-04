// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

contract MockDelegatorFactory {
    function isEntity(address entity) external pure returns (bool) {
        return entity != address(0);
    }
}
