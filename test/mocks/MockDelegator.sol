// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO
pragma solidity 0.8.25;

interface BaseDelegator {
    function stakeAt(
        address validatorManager,
        uint96 assetClass,
        address operator,
        uint48 timestamp,
        bytes memory data
    ) external view returns (uint256);
}

contract MockDelegator is BaseDelegator {
    mapping(bytes32 => uint256) private stakes;

    // Function to set stake values for testing
    function setStake(
        address validatorManager,
        uint96 assetClass,
        address operator,
        uint48 timestamp,
        uint256 stakeAmount
    ) external {
        bytes32 key = keccak256(abi.encodePacked(validatorManager, assetClass, operator, timestamp));
        stakes[key] = stakeAmount;
    }

    function stakeAt(
        address validatorManager,
        uint96 assetClass,
        address operator,
        uint48 timestamp,
        bytes memory
    ) external view override returns (uint256) {
        bytes32 key = keccak256(abi.encodePacked(validatorManager, assetClass, operator, timestamp));
        return stakes[key];
    }
}
