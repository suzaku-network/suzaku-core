// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity ^0.8.25;

import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

library MapWithTimeData {
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    error MapWithTimeData__AlreadyAdded();
    error MapWithTimeData__NotEnabled();
    error MapWithTimeData__AlreadyEnabled();
    error MapWithTimeData__AlreadyDisabled();

    function add(EnumerableMap.AddressToUintMap storage self, address addr) internal {
        if (!self.set(addr, uint256(0))) {
            revert MapWithTimeData__AlreadyAdded();
        }
    }

    function disable(EnumerableMap.AddressToUintMap storage self, address addr) internal {
        uint256 value = self.get(addr);
        uint48 enabledTime = uint48(value);
        uint48 disabledTime = uint48(value >> 48);

        if (enabledTime == 0) {
            revert MapWithTimeData__NotEnabled();
        }

        if (disabledTime != 0) {
            revert MapWithTimeData__AlreadyDisabled();
        }

        value |= uint256(Time.timestamp()) << 48;
        self.set(addr, value);
    }

    function enable(EnumerableMap.AddressToUintMap storage self, address addr) internal {
        uint256 value = self.get(addr);

        if (uint48(value) != 0 && uint48(value >> 48) == 0) {
            revert MapWithTimeData__AlreadyEnabled();
        }

        value = uint256(Time.timestamp());
        self.set(addr, value);
    }

    function atWithTimes(
        EnumerableMap.AddressToUintMap storage self,
        uint256 idx
    ) internal view returns (address key, uint48 enabledTime, uint48 disabledTime) {
        uint256 value;
        (key, value) = self.at(idx);
        enabledTime = uint48(value);
        disabledTime = uint48(value >> 48);
    }

    function getTimes(
        EnumerableMap.AddressToUintMap storage self,
        address addr
    ) internal view returns (uint48 enabledTime, uint48 disabledTime) {
        uint256 value = self.get(addr);
        enabledTime = uint48(value);
        disabledTime = uint48(value >> 48);
    }
}
