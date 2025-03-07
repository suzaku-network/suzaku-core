// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO
pragma solidity 0.8.25;

import {MockDelegator} from "./MockDelegator.sol";
import {MockVault} from "./MockVault.sol";

contract MockVaultManager {
    address[] public vaults;

    function addVault(
        address vault
    ) external {
        vaults.push(vault);
    }

    function deployAndAddVault(
        address collateralAddress
    ) external returns (address vaultAddress, address delegatorAddress) {
        // First deploy the delegator
        MockDelegator delegator = new MockDelegator();
        delegatorAddress = address(delegator);

        // Then deploy the vault with reference to the delegator
        MockVault newVault = new MockVault(collateralAddress, delegatorAddress);
        vaultAddress = address(newVault);

        vaults.push(vaultAddress);
    }

    function getVaultCount() external view returns (uint256) {
        return vaults.length;
    }

    function getVaultAtWithTimes(
        uint256 index
    ) external view returns (address, uint48, uint48) {
        require(index < vaults.length, "Invalid index");
        return (vaults[index], 1, 0); // Return dummy timestamps for now
    }
}
