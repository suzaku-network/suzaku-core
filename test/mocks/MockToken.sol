// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract Token is ERC20 {
    constructor(
        string memory name_
    ) ERC20(name_, "TOKEN") {
        _mint(msg.sender, 1_000_000 * 10 ** decimals());
    }
}
