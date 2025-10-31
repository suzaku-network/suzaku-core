// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity ^0.8.25;

/**
 * @title IMerkleDistributor
 * @notice Interface for Merkl Distributor contract
 * @dev Based on Angle Protocol's Merkl contracts
 */
interface IMerkleDistributor {
    /**
     * @notice Claims rewards for a given set of users
     * @param users Addresses for which claiming is taking place
     * @param tokens ERC20 token claimed
     * @param amounts Amount of tokens that will be sent to the corresponding users
     * @param proofs Array of hashes bridging from a leaf `(hash of user | token | amount)` to the Merkle root
     */
    function claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external;

    /**
     * @notice Same as claim but allows setting recipients and passing data
     * @param users Addresses for which claiming is taking place
     * @param tokens ERC20 token claimed
     * @param amounts Amount of tokens that will be sent to the corresponding users
     * @param proofs Array of hashes bridging from a leaf `(hash of user | token | amount)` to the Merkle root
     * @param recipients Recipient addresses for each claim (can be zero to use default)
     * @param datas Optional data to pass to claim recipient callback
     */
    function claimWithRecipient(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs,
        address[] calldata recipients,
        bytes[] memory datas
    ) external;

    /**
     * @notice Returns the Merkle root that is currently live for the contract
     * @return The current Merkle root
     */
    function getMerkleRoot() external view returns (bytes32);
}


