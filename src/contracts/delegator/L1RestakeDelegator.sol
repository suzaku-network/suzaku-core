// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {BaseDelegator} from "./BaseDelegator.sol";

import {IBaseDelegator} from "../../interfaces/delegator/IBaseDelegator.sol";
import {IL1RestakeDelegator} from "../../interfaces/delegator/IL1RestakeDelegator.sol";
import {IVaultTokenized} from "../../interfaces/vault/IVaultTokenized.sol";

import {ExtendedCheckpoints} from "../libraries/Checkpoints.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";

contract L1RestakeDelegator is BaseDelegator, IL1RestakeDelegator {
    using ExtendedCheckpoints for ExtendedCheckpoints.Trace256;
    using Math for uint256;

    /**
     * @inheritdoc IL1RestakeDelegator
     */
    bytes32 public constant L1_LIMIT_SET_ROLE = keccak256("L1_LIMIT_SET_ROLE");

    /**
     * @inheritdoc IL1RestakeDelegator
     */
    bytes32 public constant OPERATOR_L1_SHARES_SET_ROLE = keccak256("OPERATOR_L1_SHARES_SET_ROLE");

    mapping(address => mapping(uint96 => ExtendedCheckpoints.Trace256)) internal _l1Limit;
    mapping(address => mapping(uint96 => ExtendedCheckpoints.Trace256)) internal _totalOperatorL1Shares;
    mapping(address => mapping(uint96 => mapping(address => ExtendedCheckpoints.Trace256))) internal _operatorL1Shares;

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
    function l1LimitAt(
        address l1,
        uint96 assetClass,
        uint48 timestamp,
        bytes memory hint
    ) public view returns (uint256) {
        return _l1Limit[l1][assetClass].upperLookupRecent(timestamp, hint);
    }

    /**
     * @inheritdoc IL1RestakeDelegator
     */
    function l1Limit(address l1, uint96 assetClass) public view returns (uint256) {
        return _l1Limit[l1][assetClass].latest();
    }

    /**
     * @inheritdoc IL1RestakeDelegator
     */
    function totalOperatorL1SharesAt(
        address l1,
        uint96 assetClass,
        uint48 timestamp,
        bytes memory hint
    ) public view returns (uint256) {
        return _totalOperatorL1Shares[l1][assetClass].upperLookupRecent(timestamp, hint);
    }

    /**
     * @inheritdoc IL1RestakeDelegator
     */
    function totalOperatorL1Shares(address l1, uint96 assetClass) public view returns (uint256) {
        return _totalOperatorL1Shares[l1][assetClass].latest();
    }

    /**
     * @inheritdoc IL1RestakeDelegator
     */
    function operatorL1SharesAt(
        address l1,
        uint96 assetClass,
        address operator,
        uint48 timestamp,
        bytes memory hint
    ) public view returns (uint256) {
        return _operatorL1Shares[l1][assetClass][operator].upperLookupRecent(timestamp, hint);
    }

    /**
     * @inheritdoc IL1RestakeDelegator
     */
    function operatorL1Shares(address l1, uint96 assetClass, address operator) public view returns (uint256) {
        return _operatorL1Shares[l1][assetClass][operator].latest();
    }

    /**
     * @inheritdoc IL1RestakeDelegator
     */
    function setL1Limit(address l1, uint96 assetClass, uint256 amount) external onlyRole(L1_LIMIT_SET_ROLE) {
        uint256 maxLimit = maxL1Limit[l1][assetClass];
        if (maxLimit == 0) {
            revert L1RestakeDelegator__MaxL1LimitNotSet();
        }
        if (amount > maxLimit) {
            revert L1RestakeDelegator__ExceedsMaxL1Limit();
        }

        if (l1Limit(l1, assetClass) == amount) {
            revert BaseDelegator__AlreadySet();
        }

        _l1Limit[l1][assetClass].push(Time.timestamp(), amount);

        emit SetL1Limit(l1, assetClass, amount);
    }

    /**
     * @inheritdoc IL1RestakeDelegator
     */
    function setOperatorL1Shares(
        address l1,
        uint96 assetClass,
        address operator,
        uint256 shares
    ) external onlyRole(OPERATOR_L1_SHARES_SET_ROLE) {
        uint256 operatorL1Shares_ = operatorL1Shares(l1, assetClass, operator);
        if (operatorL1Shares_ == shares) {
            revert BaseDelegator__AlreadySet();
        }

        _totalOperatorL1Shares[l1][assetClass].push(
            Time.timestamp(), totalOperatorL1Shares(l1, assetClass) - operatorL1Shares_ + shares
        );
        _operatorL1Shares[l1][assetClass][operator].push(Time.timestamp(), shares);

        emit SetOperatorL1Shares(l1, assetClass, operator, shares);
    }

    function _stakeAt(
        address l1,
        uint96 assetClass,
        address operator,
        uint48 timestamp,
        bytes memory hints
    ) internal view override returns (uint256, bytes memory) {
        StakeHints memory stakesHints;
        if (hints.length > 0) {
            stakesHints = abi.decode(hints, (StakeHints));
        }

        uint256 totalOperatorL1SharesAt_ =
            totalOperatorL1SharesAt(l1, assetClass, timestamp, stakesHints.totalOperatorL1SharesHint);
        return totalOperatorL1SharesAt_ == 0
            ? (0, stakesHints.baseHints)
            : (
                operatorL1SharesAt(l1, assetClass, operator, timestamp, stakesHints.operatorL1SharesHint).mulDiv(
                    Math.min(
                        IVaultTokenized(vault).activeStakeAt(timestamp, stakesHints.activeStakeHint),
                        l1LimitAt(l1, assetClass, timestamp, stakesHints.l1LimitHint)
                    ),
                    totalOperatorL1SharesAt_
                ),
                stakesHints.baseHints
            );
    }

    function _stake(address l1, uint96 assetClass, address operator) internal view override returns (uint256) {
        uint256 totalOperatorL1Shares_ = totalOperatorL1Shares(l1, assetClass);
        return totalOperatorL1Shares_ == 0
            ? 0
            : operatorL1Shares(l1, assetClass, operator).mulDiv(
                Math.min(IVaultTokenized(vault).activeStake(), l1Limit(l1, assetClass)), totalOperatorL1Shares_
            );
    }

    function _setMaxL1Limit(address l1, uint96 assetClass, uint256 amount) internal override {
        (bool exists,, uint256 latestValue) = _l1Limit[l1][assetClass].latestCheckpoint();
        if (exists && latestValue > amount) {
            _l1Limit[l1][assetClass].push(Time.timestamp(), amount);
        }
    }

    function __initialize(address, bytes memory data) internal override returns (IBaseDelegator.BaseParams memory) {
        InitParams memory params = abi.decode(data, (InitParams));

        if (
            params.baseParams.defaultAdminRoleHolder == address(0)
                && (params.l1LimitSetRoleHolders.length == 0 || params.operatorL1SharesSetRoleHolders.length == 0)
        ) {
            revert L1RestakeDelegator__MissingRoleHolders();
        }

        for (uint256 i; i < params.l1LimitSetRoleHolders.length; ++i) {
            if (params.l1LimitSetRoleHolders[i] == address(0)) {
                revert L1RestakeDelegator__ZeroAddressRoleHolder();
            }

            if (!_grantRole(L1_LIMIT_SET_ROLE, params.l1LimitSetRoleHolders[i])) {
                revert L1RestakeDelegator__DuplicateRoleHolder();
            }
        }

        for (uint256 i; i < params.operatorL1SharesSetRoleHolders.length; ++i) {
            if (params.operatorL1SharesSetRoleHolders[i] == address(0)) {
                revert L1RestakeDelegator__ZeroAddressRoleHolder();
            }

            if (!_grantRole(OPERATOR_L1_SHARES_SET_ROLE, params.operatorL1SharesSetRoleHolders[i])) {
                revert L1RestakeDelegator__DuplicateRoleHolder();
            }
        }

        return params.baseParams;
    }
}
