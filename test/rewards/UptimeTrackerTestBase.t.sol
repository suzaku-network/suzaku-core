// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO
pragma solidity 0.8.25;

import {MiddlewareTestBase} from "../middleware/MiddlewareTestBase.t.sol";
import {UptimeTracker} from "../../src/contracts/rewards/UptimeTracker.sol";
import {MockWarpMessenger} from "../mocks/MockWarpMessenger.sol";
import {ValidatorMessages} from "@avalabs/icm-contracts/validator-manager/ValidatorMessages.sol";
import {WarpMessage} from "@avalabs/subnet-evm-contracts@1.2.0/contracts/interfaces/IWarpMessenger.sol";
import {IBalancerValidatorManager} from "@suzaku/contracts-library/interfaces/ValidatorManager/IBalancerValidatorManager.sol";
import {Validator} from "@avalabs/icm-contracts/validator-manager/interfaces/IACP99Manager.sol";

abstract contract UptimeTrackerTestBase is MiddlewareTestBase {
    UptimeTracker      public uptimeTracker;
    MockWarpMessenger  internal warpMessenger;
    bytes32            internal validationID;   // first validator of Alice

    bytes32[] internal aliceVals;      // Alice's three validationIDs
    bytes32[] internal charlieVals;    // Charlie's three validationIDs

    bytes32 private constant L1_CHAIN_ID = bytes32(uint256(1));
    address  private constant WARP_MESSENGER_ADDR =
        0x0200000000000000000000000000000000000005;

    event ValidatorUptimeComputed(
        bytes32 indexed validationID, uint48 indexed firstEpoch, uint256 uptimeSecondsAdded, uint256 numberOfEpochs
    );

    event OperatorUptimeComputed(address indexed operator, uint48 indexed epoch, uint256 uptime);

    function setUp() public virtual override {
        super.setUp();                          // real AvalancheL1Middleware ready

        warpMessenger = new MockWarpMessenger();
        vm.etch(WARP_MESSENGER_ADDR, address(warpMessenger).code);

        uptimeTracker = new UptimeTracker(payable(address(middleware)), L1_CHAIN_ID);

        // ── ensure Charlie can afford three validators ──
        // free‑stake check shows she comes up ~1 minStake short after two nodes,
        // so deposit an extra 2 × minStake to be safe
        _deposit(charlie, 2 * _primaryMinStake());

        // ─── create validators ───
        (, aliceVals,   ) = _createAndConfirmNodes(alice,   3, 0, true, 2);
        (, charlieVals,) = _createAndConfirmNodes(charlie, 3, 0, true, 1);

        validationID = aliceVals[0];   // legacy single‑validator tests still use this
    }

    /* helper: load a message for the single‑validator tests (Alice v0) */
    function _push(uint64 secs) internal {
        bytes memory p =
            ValidatorMessages.packValidationUptimeMessage(validationID, secs);
        MockWarpMessenger(WARP_MESSENGER_ADDR).push(
            WarpMessage({
                sourceChainID:        L1_CHAIN_ID,
                originSenderAddress:  address(0),
                payload:              p
            })
        );
    }

    /* helper: load uptime for ANY validator */
    function _pushFor(bytes32 vID, uint64 secs) internal {
        bytes memory p =
            ValidatorMessages.packValidationUptimeMessage(vID, secs);
        // push **via the precompile address** so the tracker can read it
        MockWarpMessenger(WARP_MESSENGER_ADDR).push(
            WarpMessage({
                sourceChainID:        L1_CHAIN_ID,
                originSenderAddress:  address(0),
                payload:              p
            })
        );
    }

    /// First epoch at/after `fromEpoch` where `operator` has ≥1 active node
    function _firstActiveEpochForOperator(address operator, uint48 fromEpoch)
        internal
        view
        returns (uint48 e)
    {
        // In your test environment epochs advance only a few steps,
        // so a short bounded scan is safe and deterministic.
        for (e = fromEpoch; e < fromEpoch + 32; ++e) {
            if (middleware.getActiveNodesForEpoch(operator, e).length > 0) {
                return e;
            }
        }
        revert("no active epoch found for operator within scan window");
    }

    /// First epoch at/after `fromEpoch` where *all* operators in `ops` have ≥1 active node
    function _firstEpochWhereAllHaveActiveNodes(address[] memory ops, uint48 fromEpoch)
        internal
        view
        returns (uint48 e)
    {
        for (e = fromEpoch; e < fromEpoch + 64; ++e) {
            bool allOk = true;
            for (uint256 i = 0; i < ops.length; ++i) {
                if (middleware.getActiveNodesForEpoch(ops[i], e).length == 0) {
                    allOk = false;
                    break;
                }
            }
            if (allOk) return e;
        }
        revert("no epoch where all operators have active nodes within scan window");
    }

    function _checkpointToEpochStart(address op, uint48 e) internal {
        // Move to the very start of epoch e
        vm.warp(middleware.getEpochStartTs(e) + 1);

        // For every active node in this epoch, push 0 and compute to pin the checkpoint at start(e)
        bytes32[] memory nodes = middleware.getActiveNodesForEpoch(op, e);
        for (uint256 i = 0; i < nodes.length; ++i) {
            bytes32 vID = IBalancerValidatorManager(balancer)
                .getNodeValidationID(abi.encodePacked(uint160(uint256(nodes[i]))));
            _pushFor(vID, 0);
            uptimeTracker.computeValidatorUptime(0);
        }
    }

    function _ensureStarted(bytes32 valID) internal {
        Validator memory v = IBalancerValidatorManager(balancer).getValidator(valID);
        uint48 startEpoch = middleware.getEpochAtTs(uint48(v.startTime));
        if (middleware.getCurrentEpoch() < startEpoch) {
            vm.warp(middleware.getEpochStartTs(startEpoch) + 1);
        }
    }

}
