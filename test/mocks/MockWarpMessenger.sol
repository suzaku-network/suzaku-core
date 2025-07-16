// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import {
    IWarpMessenger,
    WarpMessage,
    WarpBlockHash
} from "@avalabs/subnet-evm-contracts@1.2.0/contracts/interfaces/IWarpMessenger.sol";

/// @dev A "mail-slot" messenger: the last message you push is the one the
///      contract-under-test will fetch.  The caller always passes index 0.
contract MockWarpMessenger is IWarpMessenger {
    WarpMessage private _slot;     // last message written
    bool        private _valid;    // always true after first write

    /* ---------- test helper ---------- */
    function push(WarpMessage memory m) external {
        _slot  = m;
        _valid = true;
    }

    /* ---------- IWarpMessenger ---------- */

    // index is ignored – the tracker will still supply 0
    function getVerifiedWarpMessage(
        uint32      /* messageIndex – always 0 */
    ) external view override returns (WarpMessage memory m, bool v) {
        return (_slot, _valid);
    }

    function sendWarpMessage(
        bytes memory // message
    ) external pure override returns (bytes32) { // messageID
        return bytes32(0);
    }

    function getBlockchainID() external pure override returns (bytes32) {
        return bytes32(uint256(1));
    }

    function getVerifiedWarpBlockHash(
        uint32 // messageIndex
    ) external pure override returns (WarpBlockHash memory warpBlockHash, bool valid) {
        warpBlockHash = WarpBlockHash({sourceChainID: bytes32(uint256(1)), blockHash: bytes32(0)});
        valid = true;
    }
}
