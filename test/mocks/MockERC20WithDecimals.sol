// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ERC20WithDecimals is ERC20 {
    uint8 private _customDecimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _customDecimals = decimals_;
        _mint(msg.sender, type(uint256).max / 2);
    }

    function decimals() public view virtual override returns (uint8) {
        return _customDecimals;
    }
} 
