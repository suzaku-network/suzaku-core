// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO
pragma solidity 0.8.25;

interface IVaultTokenized {
    function collateral() external view returns (address);
    function delegator() external view returns (address);
    function activeBalanceOfAt(address, uint48, bytes calldata) external view returns (uint256);
    function activeSharesOfAt(address, uint48, bytes calldata) external view returns (uint256);
    function activeSharesAt(uint48, bytes calldata) external view returns (uint256);
    function owner() external view returns (address);
}

contract MockVault is IVaultTokenized {
    address private _collateral;
    address private _delegator;
    address private _owner;
    mapping(address => uint256) public activeBalance;
    mapping(uint48 => uint256) private _totalActiveShares;

    constructor(address collateralAddress, address delegatorAddress, address owner_) {
        _collateral = collateralAddress;
        _delegator = delegatorAddress;
        _owner = owner_;
    }

    function collateral() external view override returns (address) {
        return _collateral;
    }

    function delegator() external view override returns (address) {
        return _delegator;
    }

    function activeBalanceOfAt(address account, uint48, bytes calldata) public view override returns (uint256) {
        return activeBalance[account];
    }

    function setActiveBalance(address account, uint256 balance) public {
        activeBalance[account] = balance;
    }

    function owner() public view override returns (address) {
        return _owner;
    }

    function activeSharesOfAt(address account, uint48, bytes calldata) public view override returns (uint256) {
        return 100;
    }

    function activeSharesAt(uint48 timestamp, bytes calldata) public view override returns (uint256) {
        uint256 totalShares = _totalActiveShares[timestamp];
        return totalShares > 0 ? totalShares : 200; // Default to 200 if not explicitly set
    }

    function setTotalActiveShares(uint48 timestamp, uint256 totalShares) public {
        _totalActiveShares[timestamp] = totalShares;
    }
}
