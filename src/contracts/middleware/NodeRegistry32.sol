// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";

abstract contract NodeRegistry32 {
    using Checkpoints for Checkpoints.Trace208;

    error DuplicateNodeKey();
    error DuplicateValidationID();

    mapping(bytes32 => Checkpoints.Trace208) private nodeIdToKeyIndex;
    mapping(bytes32 => Checkpoints.Trace208) private nodeIdToValIndex;
    mapping(bytes32 => bytes32) private validationIDToNodeId;
    mapping(uint208 => bytes32) private indexToVal;
    uint208 private totalValIDs;
    uint208 internal constant EMPTY_KEY_IDX = 0;

    function getNodeByValidationID(bytes32 valID) public view returns (bytes32) {
        return validationIDToNodeId[valID];
    }

    function getCurrentValidationID(bytes32 nodeId) public view returns (bytes32) {
        uint208 valIdx = nodeIdToValIndex[nodeId].latest();
        if (valIdx == EMPTY_KEY_IDX) return bytes32(0);
        return indexToVal[valIdx];
    }

    function getValidationIDAt(bytes32 nodeId, uint48 timestamp) public view returns (bytes32) {
        uint208 valIdx = nodeIdToValIndex[nodeId].upperLookup(timestamp);
        if (valIdx == EMPTY_KEY_IDX) return bytes32(0);
        return indexToVal[valIdx];
    }

    function updateNodeValidationID(bytes32 nodeId, bytes32 valID) internal {
        if (validationIDToNodeId[valID] != bytes32(0)) revert DuplicateValidationID();
        uint208 newIdx = ++totalValIDs;
        indexToVal[newIdx] = valID;
        nodeIdToValIndex[nodeId].push(Time.timestamp(), newIdx);
        validationIDToNodeId[valID] = nodeId;
    }
}
