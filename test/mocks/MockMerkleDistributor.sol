// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMerkleDistributor} from "../../src/interfaces/rewards/IMerkleDistributor.sol";

/**
 * @title MockMerkleDistributor
 * @notice Mock Merkl Distributor for testing LSTWrapperMerkl
 * @dev Simulates Merkl's claim mechanism with Merkle proofs
 */
contract MockMerkleDistributor is IMerkleDistributor {
    using SafeERC20 for IERC20;

    /// @notice Mapping: user -> token -> amount (simulates Merkle tree)
    mapping(address => mapping(address => uint256)) public claimableAmounts;
    
    /// @notice Mapping: user -> token -> claimed amount
    mapping(address => mapping(address => uint256)) public claimed;
    
    /// @notice Current Merkle root (for testing)
    bytes32 public merkleRoot;
    
    /// @notice Token balances held by this distributor
    mapping(address => uint256) public tokenBalances;
    
    /// @notice Allow setting claimable amounts without proofs (for testing)
    bool public allowDirectClaims;
    
    constructor() {
        allowDirectClaims = true; // Enable for testing
    }
    
    /**
     * @notice Set claimable amount for a user/token (for testing)
     */
    function setClaimableAmount(address user, address token, uint256 amount) external {
        claimableAmounts[user][token] = amount;
        // Update Merkle root hash (simplified for testing)
        merkleRoot = keccak256(abi.encodePacked(merkleRoot, user, token, amount, block.timestamp));
    }
    
    /**
     * @notice Fund the distributor with tokens
     */
    function fund(address token, uint256 amount) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        tokenBalances[address(token)] += amount;
    }
    
    /**
     * @notice Internal claim logic shared by claim() and claimWithRecipient()
     */
    function _claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs,
        address[] memory recipients
    ) internal {
        require(users.length == tokens.length && tokens.length == amounts.length && amounts.length == proofs.length, "Invalid lengths");
        require(users.length == recipients.length, "Recipients length mismatch");
        
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            address token = tokens[i];
            uint256 amount = amounts[i];
            address recipient = recipients[i];
            
            // Verify claimable amount
            require(claimableAmounts[user][token] >= amount, "Amount exceeds claimable");
            
            // Verify Merkle proof (simplified - in real Merkl this would verify against merkleRoot)
            if (!allowDirectClaims) {
                bytes32 leaf = keccak256(abi.encodePacked(user, token, amount));
                // Simplified proof verification for testing
                require(proofs[i].length > 0, "Invalid proof");
            }
            
            // Calculate claimable (amount - already claimed)
            uint256 alreadyClaimed = claimed[user][token];
            uint256 toClaim = amount > alreadyClaimed ? amount - alreadyClaimed : 0;
            
            if (toClaim > 0) {
                require(tokenBalances[token] >= toClaim, "Insufficient balance");
                
                // Update claimed amount
                claimed[user][token] = amount;
                
                // Transfer tokens to recipient
                IERC20(token).safeTransfer(recipient, toClaim);
                tokenBalances[token] -= toClaim;
            }
        }
    }
    
    /**
     * @notice Claims rewards using Merkle proof
     * @dev In mock, we verify the proof and transfer tokens
     */
    function claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external override {
        // Use users as recipients for standard claim
        address[] memory recipients = new address[](users.length);
        for (uint256 i = 0; i < users.length; i++) {
            recipients[i] = users[i];
        }
        _claim(users, tokens, amounts, proofs, recipients);
    }
    
    /**
     * @notice Same as claim but with recipients
     */
    function claimWithRecipient(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs,
        address[] calldata recipients,
        bytes[] memory datas
    ) external override {
        require(users.length == recipients.length && users.length == datas.length, "Invalid lengths");
        
        // Use recipients array (or users if recipient is zero)
        address[] memory actualRecipients = new address[](users.length);
        for (uint256 i = 0; i < users.length; i++) {
            actualRecipients[i] = recipients[i] != address(0) ? recipients[i] : users[i];
        }
        
        _claim(users, tokens, amounts, proofs, actualRecipients);
    }
    
    /**
     * @notice Get claimable amount for user/token
     */
    function getClaimable(address user, address token) external view returns (uint256) {
        uint256 total = claimableAmounts[user][token];
        uint256 alreadyClaimed = claimed[user][token];
        return total > alreadyClaimed ? total - alreadyClaimed : 0;
    }
    
    /**
     * @notice Toggle direct claims (for testing proof validation)
     */
    function setAllowDirectClaims(bool allow) external {
        allowDirectClaims = allow;
    }
    
    /**
     * @notice Get Merkle root (required by IMerkleDistributor interface)
     */
    function getMerkleRoot() external view override returns (bytes32) {
        return merkleRoot;
    }
}

