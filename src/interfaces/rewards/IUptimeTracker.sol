// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

interface IUptimeTracker {
    struct LastUptimeCheckpoint {
        uint256 remainingUptime;
        uint256 attributedUptime;
        uint256 timestamp;
    }

    error UptimeTracker__ValidatorUptimeNotRecorded(uint48 epoch, bytes32 validator);

    /**
     * @notice Emitted when a validator's uptime is computed.
     * @param validationID Unique ID of the validator's validation period.
     * @param firstEpoch First epoch included in this uptime calculation.
     * @param uptimeSecondsAdded Recorded uptime (in seconds) since the last proof.
     * @param numberOfEpochs Number of epochs covered by this uptime.
     */
    event ValidatorUptimeComputed(
        bytes32 indexed validationID, uint48 indexed firstEpoch, uint256 uptimeSecondsAdded, uint256 numberOfEpochs
    );

    /**
     * @notice Emitted when an operator's uptime is computed.
     * @param operator Operator's address.
     * @param epoch Epoch for which uptime was recorded.
     * @param uptime Average uptime (in seconds) of the operator's validators.
     */
    event OperatorUptimeComputed(address indexed operator, uint48 indexed epoch, uint256 uptime);

    /**
     * @notice Computes and records the validator's uptime for each epoch.
     * @dev TODO: get the (`validationID`, `uptime`) from a ValidationUptimeMessage or make this function permissioned as last resort
     * @param validationID ID of the validation period of a validator.
     * @param uptime Current uptime recorded.
     */
    function computeValidatorUptime(bytes32 validationID, uint256 uptime) external;

    /**
     * @notice Computes and records an operator’s uptime for a given epoch.
     * @dev Aggregates uptime from all validators operated by the given operator for a given epoch.
     * @param operator Address of the operator.
     * @param epoch Epoch for which uptime is computed.
     */
    function computeOperatorUptimeAt(address operator, uint48 epoch) external;

    /**
     * @notice Returns the last uptime checkpoint for a validator.
     * @param validationID The validator's unique validation ID.
     * @return Last recorded uptime checkpoint.
     */
    function getLastUptimeCheckpoint(
        bytes32 validationID
    ) external view returns (LastUptimeCheckpoint memory);
}
