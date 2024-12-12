// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import {BaseDelegator} from "./BaseDelegator.sol";

import {IBaseDelegator} from "../../interfaces/delegator/IBaseDelegator.sol";
import {IL1RestakeDelegator} from "../../interfaces/delegator/IL1RestakeDelegator.sol";
import {IVaultTokenized} from "../../interfaces/vault/IVaultTokenized.sol";

import {Checkpoints} from "../libraries/Checkpoints.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";

contract L1RestakeDelegator is BaseDelegator, IL1RestakeDelegator {
    using Checkpoints for Checkpoints.Trace256;
    using Math for uint256;

    /**
     * @inheritdoc IL1RestakeDelegator
     */
    bytes32 public constant L1_LIMIT_SET_ROLE = keccak256("L1_LIMIT_SET_ROLE");

    /**
     * @inheritdoc IL1RestakeDelegator
     */
    bytes32 public constant OPERATOR_L1_SHARES_SET_ROLE = keccak256("OPERATOR_L1_SHARES_SET_ROLE");

    mapping(bytes32 subnetwork => Checkpoints.Trace256 value) internal _l1Limit;

    mapping(bytes32 subnetwork => Checkpoints.Trace256 shares) internal _totalOperatorL1Shares;

    mapping(bytes32 subnetwork => mapping(address operator => Checkpoints.Trace256 shares)) internal
        _operatorL1Shares;

    constructor(
        address l1Registry,
        address vaultFactory,
        address operatorVaultOptInService,
        address operatorL1OptInService,
        address delegatorFactory,
        uint64 entityType
    )
        BaseDelegator(
            l1Registry,
            vaultFactory,
            operatorVaultOptInService,
            operatorL1OptInService,
            delegatorFactory,
            entityType
        )
    {}

    /**
     * @inheritdoc IL1RestakeDelegator
     */
    function l1LimitAt(bytes32 subnetwork, uint48 timestamp, bytes memory hint) public view returns (uint256) {
        return _l1Limit[subnetwork].upperLookupRecent(timestamp, hint);
    }

    /**
     * @inheritdoc IL1RestakeDelegator
     */
    function l1Limit(
        bytes32 subnetwork
    ) public view returns (uint256) {
        return _l1Limit[subnetwork].latest();
    }

    /**
     * @inheritdoc IL1RestakeDelegator
     */
    function totalOperatorL1SharesAt(
        bytes32 subnetwork,
        uint48 timestamp,
        bytes memory hint
    ) public view returns (uint256) {
        return _totalOperatorL1Shares[subnetwork].upperLookupRecent(timestamp, hint);
    }

    /**
     * @inheritdoc IL1RestakeDelegator
     */
    function totalOperatorL1Shares(
        bytes32 subnetwork
    ) public view returns (uint256) {
        return _totalOperatorL1Shares[subnetwork].latest();
    }

    /**
     * @inheritdoc IL1RestakeDelegator
     */
    function operatorL1SharesAt(
        bytes32 subnetwork,
        address operator,
        uint48 timestamp,
        bytes memory hint
    ) public view returns (uint256) {
        return _operatorL1Shares[subnetwork][operator].upperLookupRecent(timestamp, hint);
    }

    /**
     * @inheritdoc IL1RestakeDelegator
     */
    function operatorL1Shares(bytes32 subnetwork, address operator) public view returns (uint256) {
        return _operatorL1Shares[subnetwork][operator].latest();
    }

    /**
     * @inheritdoc IL1RestakeDelegator
     */
    function setL1Limit(bytes32 subnetwork, uint256 amount) external onlyRole(L1_LIMIT_SET_ROLE) {
        if (amount > maxL1Limit[subnetwork]) {
            revert ExceedsMaxL1Limit();
        }

        if (l1Limit(subnetwork) == amount) {
            revert BaseDelegator__AlreadySet();
        }

        _l1Limit[subnetwork].push(Time.timestamp(), amount);

        emit SetL1Limit(subnetwork, amount);
    }

    /**
     * @inheritdoc IL1RestakeDelegator
     */
    function setOperatorL1Shares(
        bytes32 subnetwork,
        address operator,
        uint256 shares
    ) external onlyRole(OPERATOR_L1_SHARES_SET_ROLE) {
        uint256 operatorL1Shares_ = operatorL1Shares(subnetwork, operator);
        if (operatorL1Shares_ == shares) {
            revert BaseDelegator__AlreadySet();
        }

        _totalOperatorL1Shares[subnetwork].push(
            Time.timestamp(), totalOperatorL1Shares(subnetwork) - operatorL1Shares_ + shares
        );
        _operatorL1Shares[subnetwork][operator].push(Time.timestamp(), shares);

        emit SetOperatorL1Shares(subnetwork, operator, shares);
    }

    function _stakeAt(
        bytes32 subnetwork,
        address operator,
        uint48 timestamp,
        bytes memory hints
    ) internal view override returns (uint256, bytes memory) {
        StakeHints memory stakesHints;
        if (hints.length > 0) {
            stakesHints = abi.decode(hints, (StakeHints));
        }

        uint256 totalOperatorL1SharesAt_ =
            totalOperatorL1SharesAt(subnetwork, timestamp, stakesHints.totalOperatorL1SharesHint);
        return totalOperatorL1SharesAt_ == 0
            ? (0, stakesHints.baseHints)
            : (
                operatorL1SharesAt(subnetwork, operator, timestamp, stakesHints.operatorL1SharesHint).mulDiv(
                    Math.min(
                        IVaultTokenized(vault).activeStakeAt(timestamp, stakesHints.activeStakeHint),
                        l1LimitAt(subnetwork, timestamp, stakesHints.l1LimitHint)
                    ),
                    totalOperatorL1SharesAt_
                ),
                stakesHints.baseHints
            );
    }

    function _stake(bytes32 subnetwork, address operator) internal view override returns (uint256) {
        uint256 totalOperatorL1Shares_ = totalOperatorL1Shares(subnetwork);
        return totalOperatorL1Shares_ == 0
            ? 0
            : operatorL1Shares(subnetwork, operator).mulDiv(
                Math.min(IVaultTokenized(vault).activeStake(), l1Limit(subnetwork)), totalOperatorL1Shares_
            );
    }

    function _setMaxL1Limit(bytes32 subnetwork, uint256 amount) internal override {
        (bool exists,, uint256 latestValue) = _l1Limit[subnetwork].latestCheckpoint();
        if (exists && latestValue > amount) {
            _l1Limit[subnetwork].push(Time.timestamp(), amount);
        }
    }

    function __initialize(address, bytes memory data) internal override returns (IBaseDelegator.BaseParams memory) {
        InitParams memory params = abi.decode(data, (InitParams));

        if (
            params.baseParams.defaultAdminRoleHolder == address(0)
                && (params.l1LimitSetRoleHolders.length == 0 || params.operatorL1SharesSetRoleHolders.length == 0)
        ) {
            revert MissingRoleHolders();
        }

        for (uint256 i; i < params.l1LimitSetRoleHolders.length; ++i) {
            if (params.l1LimitSetRoleHolders[i] == address(0)) {
                revert ZeroAddressRoleHolder();
            }

            if (!_grantRole(L1_LIMIT_SET_ROLE, params.l1LimitSetRoleHolders[i])) {
                revert DuplicateRoleHolder();
            }
        }

        for (uint256 i; i < params.operatorL1SharesSetRoleHolders.length; ++i) {
            if (params.operatorL1SharesSetRoleHolders[i] == address(0)) {
                revert ZeroAddressRoleHolder();
            }

            if (!_grantRole(OPERATOR_L1_SHARES_SET_ROLE, params.operatorL1SharesSetRoleHolders[i])) {
                revert DuplicateRoleHolder();
            }
        }

        return params.baseParams;
    }
}
