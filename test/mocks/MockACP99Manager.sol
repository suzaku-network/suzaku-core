// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import "@openzeppelin/contracts/access/Ownable.sol";

contract MockACP99Manager is Ownable {
    constructor(
        address initialOwner
    ) Ownable(initialOwner) {}

    function isValidManager() public pure returns (bool) {
        return true;
    }
}
