// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO
pragma solidity 0.8.25;

interface IVaultTokenized {
    function collateral() external view returns (address);
    function delegator() external view returns (address);
    function activeBalanceOfAt(address, uint48, bytes calldata) external view returns (uint256);
    function owner() external view returns (address);
}

contract MockVault is IVaultTokenized {
    address private _collateral;
    address private _delegator;
    mapping(address => uint256) public activeBalance;

    constructor(address collateralAddress, address delegatorAddress) {
        _collateral = collateralAddress;
        _delegator = delegatorAddress;

        // Populate mapping with dummy values
        activeBalance[address(0x123)] = 1000 * 1e15; // Example balance for address 0x123
        activeBalance[address(0x456)] = 500 * 1e15; // Example balance for address 0x456
        activeBalance[address(0x789)] = 750 * 1e15; // Example balance for address 0x789
    }

    function collateral() external view override returns (address) {
        return _collateral;
    }

    function delegator() external view override returns (address) {
        return _delegator;
    }

    function activeBalanceOfAt(address account, uint48, bytes calldata) public view returns (uint256) {
        return activeBalance[account];
    }

    function owner() public view virtual returns (address) {
        return address(0x12345689123567891235789);
    }
}
