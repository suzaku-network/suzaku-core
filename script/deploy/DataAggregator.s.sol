// script/deploy/DataAggregator.s.sol
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import {Script} from "forge-std/Script.sol";
import {DataAggregator} from "../../src/contracts/DataAggregator.sol";

contract DeployDataAggregator is Script {
    function run() external returns (DataAggregator) {
        // L1_REGISTRY address on Fuji testnet
        address l1Registry = 0xB9826Bbf0deB10cC3924449B93F418db6b16be36;

        vm.startBroadcast();
        DataAggregator dataAggregator = new DataAggregator(l1Registry);
        vm.stopBroadcast();

        return dataAggregator;
    }
}
