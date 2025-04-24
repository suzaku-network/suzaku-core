// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {IAvalancheL1Middleware} from "../../src/interfaces/middleware/IAvalancheL1Middleware.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MockAvalancheL1Middleware is Ownable {
    address private vaultManager;

    constructor(address initialOwner, address _vaultManager) Ownable(initialOwner) {
        vaultManager = _vaultManager;
    }

    function getVaultManager() external view returns (address) {
        return vaultManager;
    }

    function setVaultManager(address _vaultManager) external {
        vaultManager = _vaultManager;
    }
} 
