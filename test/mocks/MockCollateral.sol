// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Token} from "./MockToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockCollateral is Token {
    address public immutable asset;
    
    constructor(string memory name, address _asset) Token(name) {
        asset = _asset;
    }
    
    // Implement deposit function for VaultHelper compatibility
    function deposit(address receiver, uint256 assets) external returns (uint256 shares) {
        // Pull native tokens from sender
        IERC20(asset).transferFrom(msg.sender, address(this), assets);
        
        // Mint collateral tokens 1:1
        shares = assets;
        _mint(receiver, shares);
        
        return shares;
    }
}
