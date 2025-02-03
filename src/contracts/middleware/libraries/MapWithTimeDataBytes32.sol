// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

library MapWithTimeDataBytes32 {
    using EnumerableMap for EnumerableMap.Bytes32ToUintMap;

    error AlreadyAdded();
    error NotEnabled();
    error AlreadyEnabled();

    function add(EnumerableMap.Bytes32ToUintMap storage self, bytes32 nodeId) internal {
        if (!self.set(nodeId, uint256(0))) {
            revert AlreadyAdded();
        }
    }

    function enable(EnumerableMap.Bytes32ToUintMap storage self, bytes32 nodeId) internal {
        uint256 value = self.get(nodeId);
        uint48 enabledTime = uint48(value);
        uint48 disabledTime = uint48(value >> 48);
        if (enabledTime != 0 && disabledTime == 0) {
            revert AlreadyEnabled();
        }
        value = uint256(Time.timestamp()); // set enabledTime = now, disabledTime=0
        self.set(nodeId, value);
    }

    function disable(EnumerableMap.Bytes32ToUintMap storage self, bytes32 nodeId) internal {
        uint256 value = self.get(nodeId);
        uint48 enabledTime = uint48(value);
        uint48 disabledTime = uint48(value >> 48);
        if (enabledTime == 0 || disabledTime != 0) {
            revert NotEnabled();
        }
        value |= uint256(Time.timestamp()) << 48; // set disabledTime=now
        self.set(nodeId, value);
    }

    // function remove(EnumerableMap.Bytes32ToUintMap storage self, bytes32 nodeId) internal {
    //     self.remove(nodeId);
    // }

    function atWithTimes(
        EnumerableMap.Bytes32ToUintMap storage self,
        uint256 idx
    ) internal view returns (bytes32 nodeId, uint48 enabledTime, uint48 disabledTime) {
        uint256 value;
        (nodeId, value) = self.at(idx);
        enabledTime = uint48(value);
        disabledTime = uint48(value >> 48);
    }

    function getTimes(
        EnumerableMap.Bytes32ToUintMap storage self,
        bytes32 nodeId
    ) internal view returns (uint48 enabledTime, uint48 disabledTime) {
        uint256 value = self.get(nodeId);
        enabledTime = uint48(value);
        disabledTime = uint48(value >> 48);
    }
}
