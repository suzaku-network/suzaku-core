// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockFeeOnTransferToken is ERC20 {
    constructor(
        string memory name_
    ) ERC20(name_, "") {
        _mint(msg.sender, 1_000_000 * 10 ** decimals());
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);

        if (from != address(0) && to != address(0)) {
            if (value != 0) {
                super._update(to, address(0), 1);
            }
        }
    }
}
