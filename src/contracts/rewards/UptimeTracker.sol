// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {AvalancheL1Middleware} from "../middleware/AvalancheL1Middleware.sol";
import {IUptimeTracker, LastUptimeCheckpoint} from "../../interfaces/rewards/IUptimeTracker.sol";
import {BalancerValidatorManager} from
    "@suzaku/contracts-library/contracts/ValidatorManager/BalancerValidatorManager.sol";
import {Validator} from "@avalabs/icm-contracts/validator-manager/interfaces/IACP99Manager.sol";
import {ValidatorMessages} from "@avalabs/icm-contracts/validator-manager/ValidatorMessages.sol";
import {
    IWarpMessenger, WarpMessage
} from "@avalabs/subnet-evm-contracts@1.2.0/contracts/interfaces/IWarpMessenger.sol";

/**
 * @title UptimeTracker
 * @dev Tracks validator uptime and calculates uptime percentages per epoch.
 * Used to monitor validator and operator performance.
 */
contract UptimeTracker is IUptimeTracker {
    AvalancheL1Middleware private immutable middleware;
    BalancerValidatorManager private immutable validatorManager;
    bytes32 private immutable uptimeBlockchainID; // blockchainID of the L1

    IWarpMessenger public constant WARP_MESSENGER = IWarpMessenger(0x0200000000000000000000000000000000000005);

    /// @notice Mapping of validation ID to the last recorded uptime checkpoint.
    mapping(bytes32 validationID => LastUptimeCheckpoint lastUptimeCheckpoint) public validatorLastUptimeCheckpoint;

    /// @notice Mapping of epoch to validator uptime (in seconds).
    mapping(uint48 epoch => mapping(bytes32 validationID => uint256 uptime)) public validatorUptimePerEpoch;

    /// @notice Mapping of epoch to validator uptime set.
    mapping(uint48 epoch => mapping(bytes32 validationID => bool isSet)) public isValidatorUptimeSet;

    /// @notice Mapping of epoch to operator uptime (in seconds).
    mapping(uint48 epoch => mapping(address operator => uint256 uptime)) public operatorUptimePerEpoch;

    /// @notice Mapping of epoch to operator uptime set.
    mapping(uint48 epoch => mapping(address operator => bool isSet)) public isOperatorUptimeSet;

    constructor(
        address payable middleware_,
        bytes32 uptimeBlockchainID_
    ) {
        middleware = AvalancheL1Middleware(middleware_);
        validatorManager = BalancerValidatorManager(middleware.L1_VALIDATOR_MANAGER());
        uptimeBlockchainID = uptimeBlockchainID_;
    }

    /**
     * @inheritdoc IUptimeTracker
     */
    function computeValidatorUptime(uint32 messageIndex) external {
        (bytes32 vID, uint256 uptime) = _readUptimeMessage(messageIndex);

        // Current epoch context
        uint48  currentEpoch      = middleware.getCurrentEpoch();
        uint256 currentEpochStart = middleware.getEpochStartTs(currentEpoch);

        // Ensure we have an initial checkpoint (clamped to <= current epoch start)
        _ensureCheckpoint(vID, currentEpochStart);

        LastUptimeCheckpoint storage chk = validatorLastUptimeCheckpoint[vID];

        // Clamp checkpoint timestamp so it never points into the future
        uint256 checkpointTs = chk.timestamp;
        if (checkpointTs > currentEpochStart) checkpointTs = currentEpochStart;

        uint48 lastEpoch      = middleware.getEpochAtTs(uint48(checkpointTs));
        uint48 elapsedEpochs  = currentEpoch - lastEpoch;

        // Monotonic accumulate: ignore regressions to avoid underflow on (uptime - attributed)
        uint256 delta     = uptime >= chk.attributedUptime ? uptime - chk.attributedUptime : 0;
        uint256 recorded  = chk.remainingUptime + delta;

        // If no full epoch has elapsed, just carry forward and return
        if (elapsedEpochs == 0) {
            chk.remainingUptime  = recorded;
            chk.attributedUptime = uptime;
            chk.timestamp        = currentEpochStart;
            emit ValidatorUptimeComputed(vID, lastEpoch, 0, 0);
            return;
        }

        // Bound distribution to actual elapsed wall time across full epochs
        uint256 lastEpochStart  = middleware.getEpochStartTs(lastEpoch);
        uint256 elapsedTime     = currentEpochStart - lastEpochStart;
        uint256 toDistribute    = recorded <= elapsedTime ? recorded : elapsedTime;
        uint256 carry           = recorded - toDistribute;

        // Move checkpoint to current epoch start
        chk.remainingUptime  = carry;
        chk.attributedUptime = uptime;
        chk.timestamp        = currentEpochStart;

        if (toDistribute > 0) {
            uint256 need = _countUnsetEpochs(lastEpoch, elapsedEpochs, vID);
            if (need == 0) {
                // All epochs already had values; carry everything forward
                chk.remainingUptime += toDistribute;
            } else {
                _fillUptime(lastEpoch, elapsedEpochs, vID, toDistribute, need);
            }
        }

        emit ValidatorUptimeComputed(vID, lastEpoch, toDistribute, elapsedEpochs);
    }

    /**
     * @inheritdoc IUptimeTracker
     */
    function computeOperatorUptimeAt(address operator, uint48 epoch) external {
        bytes32[] memory operatorNodes = middleware.getActiveNodesForEpoch(operator, epoch);
        uint256 numberOfValidators = operatorNodes.length;
        if (numberOfValidators == 0) revert UptimeTracker__NoValidators(operator, epoch);
        uint256 sumValidatorsUptime = 0;
        
        for (uint256 i = 0; i < numberOfValidators; i++) {
            bytes32 validationID = validatorManager.getNodeValidationID(abi.encodePacked(uint160(uint256(operatorNodes[i]))));
            if (isValidatorUptimeSet[epoch][validationID] == false) {
                revert UptimeTracker__ValidatorUptimeNotRecorded(epoch, validationID);
            }
            uint256 uptimeValidator = validatorUptimePerEpoch[epoch][validationID];
            sumValidatorsUptime += uptimeValidator;
        }

        operatorUptimePerEpoch[epoch][operator] = sumValidatorsUptime / numberOfValidators;
        isOperatorUptimeSet[epoch][operator] = true;

        emit OperatorUptimeComputed(operator, epoch, sumValidatorsUptime / numberOfValidators);
    }

    /**
     * @inheritdoc IUptimeTracker
     */
    function getLastUptimeCheckpoint(
        bytes32 validationID
    ) external view returns (LastUptimeCheckpoint memory) {
        return validatorLastUptimeCheckpoint[validationID];
    }

    // --- helpers ----------------------------------------------------------------

    function _readUptimeMessage(uint32 index) internal view returns (bytes32 vID, uint256 up) {
        (WarpMessage memory msg_, bool ok) = WARP_MESSENGER.getVerifiedWarpMessage(index);
        if (!ok) revert InvalidWarpMessage();
        if (msg_.sourceChainID != uptimeBlockchainID) revert InvalidWarpSourceChainID(msg_.sourceChainID);
        if (msg_.originSenderAddress != address(0))   revert InvalidWarpOriginSenderAddress(msg_.originSenderAddress);
        (vID, up) = ValidatorMessages.unpackValidationUptimeMessage(msg_.payload);
    }

    function _ensureCheckpoint(bytes32 vID, uint256 currentEpochStart) internal {
        LastUptimeCheckpoint storage chk = validatorLastUptimeCheckpoint[vID];
        if (chk.timestamp != 0) return;
        Validator memory v = validatorManager.getValidator(vID);
        uint256 ts = v.startTime;
        if (ts > currentEpochStart) ts = currentEpochStart; // clamp initial ts
        validatorLastUptimeCheckpoint[vID] = LastUptimeCheckpoint({
            remainingUptime:  0,
            attributedUptime: 0,
            timestamp:        ts
        });
    }

    function _countUnsetEpochs(uint48 startEpoch, uint48 elapsed, bytes32 vID) internal view returns (uint256 n) {
        for (uint48 i = 0; i < elapsed; ) {
            uint48 e;
            unchecked { e = startEpoch + i; ++i; }
            if (!isValidatorUptimeSet[e][vID]) n++;
        }
    }

    function _fillUptime(
        uint48 startEpoch,
        uint48 elapsed,
        bytes32 vID,
        uint256 total,
        uint256 count
    ) internal {
        uint256 base = total / count;
        uint256 rem  = total % count;
        for (uint48 i = 0; i < elapsed; ) {
            uint48 e;
            unchecked { e = startEpoch + i; ++i; }
            if (isValidatorUptimeSet[e][vID]) continue;
            uint256 u = base;
            if (rem > 0) { u += 1; rem -= 1; }
            validatorUptimePerEpoch[e][vID] = u;
            isValidatorUptimeSet[e][vID]    = true;
        }
    }
}
