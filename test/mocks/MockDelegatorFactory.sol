// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

contract MockDelegatorFactory {
    function isEntity(
        address entity
    ) external pure returns (bool) {
        return entity != address(0);
    }
}
