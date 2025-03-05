// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity ^0.8.0;

import {IBaseSlasher} from "./IBaseSlasher.sol";

interface IVetoSlasher is IBaseSlasher {
    error AlreadySet();
    error InsufficientSlash();
    error InvalidCaptureTimestamp();
    error InvalidResolverSetEpochsDelay();
    error InvalidVetoDuration();
    error NoResolver();
    error NotNetwork();
    error NotResolver();
    error SlashPeriodEnded();
    error SlashRequestCompleted();
    error SlashRequestNotExist();
    error VetoPeriodEnded();
    error VetoPeriodNotEnded();

    /**
     * @notice Initial parameters needed for a slasher deployment.
     * @param baseParams base parameters for slashers' deployment
     * @param vetoDuration duration of the veto period for a slash request
     * @param resolverSetEpochsDelay delay in epochs for a network to update a resolver
     */
    struct InitParams {
        IBaseSlasher.BaseParams baseParams;
        uint48 vetoDuration;
        uint256 resolverSetEpochsDelay;
    }

    /**
     * @notice Structure for a slash request.
     * @param l1 address of the l1
     * @param assetClass the uint96 assetClass
     * @param operator operator that could be slashed (if the request is not vetoed)
     * @param amount maximum amount of the collateral to be slashed
     * @param captureTimestamp time point when the stake was captured
     * @param vetoDeadline deadline for the resolver to veto the slash (exclusively)
     * @param completed if the slash was vetoed/executed
     */
    struct SlashRequest {
        address l1;
        uint96 assetClass;
        address operator;
        uint256 amount;
        uint48 captureTimestamp;
        uint48 vetoDeadline;
        bool completed;
    }

    /**
     * @notice Hints for a slash request.
     * @param slashableStakeHints hints for the slashable stake checkpoints
     */
    struct RequestSlashHints {
        bytes slashableStakeHints;
    }

    /**
     * @notice Hints for a slash execute.
     * @param captureResolverHint hint for the resolver checkpoint at the capture time
     * @param currentResolverHint hint for the resolver checkpoint at the current time
     * @param slashableStakeHints hints for the slashable stake checkpoints
     */
    struct ExecuteSlashHints {
        bytes captureResolverHint;
        bytes currentResolverHint;
        bytes slashableStakeHints;
    }

    /**
     * @notice Hints for a slash veto.
     * @param captureResolverHint hint for the resolver checkpoint at the capture time
     * @param currentResolverHint hint for the resolver checkpoint at the current time
     */
    struct VetoSlashHints {
        bytes captureResolverHint;
        bytes currentResolverHint;
    }

    /**
     * @notice Hints for a resolver set.
     * @param resolverHint hint for the resolver checkpoint
     */
    struct SetResolverHints {
        bytes resolverHint;
    }

    /**
     * @notice Extra data for the delegator.
     * @param slashableStake amount of the slashable stake before the slash (cache)
     * @param stakeAt amount of the stake at the capture time (cache)
     * @param slashIndex index of the slash request
     */
    struct DelegatorData {
        uint256 slashableStake;
        uint256 stakeAt;
        uint256 slashIndex;
    }

    /**
     * @notice Emitted when a slash request is created.
     * @param slashIndex index of the slash request
     * @param l1 address of the l1
     * @param assetClass the uint96 assetClass
     * @param operator operator that could be slashed (if the request is not vetoed)
     * @param slashAmount maximum amount of the collateral to be slashed
     * @param captureTimestamp time point when the stake was captured
     * @param vetoDeadline deadline for the resolver to veto the slash (exclusively)
     */
    event RequestSlash(
        uint256 indexed slashIndex,
        address l1,
        uint96 assetClass,
        address indexed operator,
        uint256 slashAmount,
        uint48 captureTimestamp,
        uint48 vetoDeadline
    );

    /**
     * @notice Emitted when a slash request is executed.
     * @param slashIndex index of the slash request
     * @param slashedAmount virtual amount of the collateral slashed
     */
    event ExecuteSlash(uint256 indexed slashIndex, uint256 slashedAmount);

    /**
     * @notice Emitted when a slash request is vetoed.
     * @param slashIndex index of the slash request
     * @param resolver address of the resolver that vetoed the slash
     */
    event VetoSlash(uint256 indexed slashIndex, address indexed resolver);

    /**
     * @notice Emitted when a resolver is set.
     * @param l1 address of the l1
     * @param assetClass the uint96 assetClass
     * @param resolver address of the resolver
     */
    event SetResolver(address indexed l1, uint96 indexed assetClass, address resolver);

    /**
     * @notice Get the network registry's address.
     * @return address of the network registry
     */
    function NETWORK_REGISTRY() external view returns (address);

    /**
     * @notice Get a duration during which resolvers can veto slash requests.
     * @return duration of the veto period
     */
    function vetoDuration() external view returns (uint48);

    /**
     * @notice Get a total number of slash requests.
     * @return total number of slash requests
     */
    function slashRequestsLength() external view returns (uint256);

    /**
     * @notice Get a particular slash request.
     * @param slashIndex index of the slash request
     * @return l1 address of the l1
     * @return assetClass the uint96 assetClass
     * @return operator operator that could be slashed (if the request is not vetoed)
     * @return amount maximum amount of the collateral to be slashed
     * @return captureTimestamp time point when the stake was captured
     * @return vetoDeadline deadline for the resolver to veto the slash (exclusively)
     * @return completed if the slash was vetoed/executed
     */
    function slashRequests(
        uint256 slashIndex
    )
        external
        view
        returns (
            address l1,
            uint96 assetClass,
            address operator,
            uint256 amount,
            uint48 captureTimestamp,
            uint48 vetoDeadline,
            bool completed
        );

    /**
     * @notice Get a delay for networks in epochs to update a resolver.
     * @return updating resolver delay in epochs
     */
    function resolverSetEpochsDelay() external view returns (uint256);

    /**
     * @notice Get a resolver for a given assset class at a particular timestamp using a hint.
     * @param l1 address of the l1
     * @param assetClass the uint96 assetClass
     * @param timestamp timestamp to get the resolver at
     * @param hint hint for the checkpoint index
     * @return address of the resolver
     */
    function resolverAt(
        address l1,
        uint96 assetClass,
        uint48 timestamp,
        bytes memory hint
    ) external view returns (address);

    /**
     * @notice Get a resolver for a given assset class using a hint.
     * @param l1 address of the l1
     * @param assetClass the uint96 assetClass
     * @param hint hint for the checkpoint index
     * @return address of the resolver
     */
    function resolver(address l1, uint96 assetClass, bytes memory hint) external view returns (address);

    /**
     * @notice Request a slash using a assset class for a particular operator by a given amount using hints.
     * @param l1 address of the l1
     * @param assetClass the uint96 assetClass
     * @param operator address of the operator
     * @param amount maximum amount of the collateral to be slashed
     * @param captureTimestamp time point when the stake was captured
     * @param hints hints for checkpoints' indexes
     * @return slashIndex index of the slash request
     * @dev Only a network middleware can call this function.
     */
    function requestSlash(
        address l1,
        uint96 assetClass,
        address operator,
        uint256 amount,
        uint48 captureTimestamp,
        bytes calldata hints
    ) external returns (uint256 slashIndex);

    /**
     * @notice Execute a slash with a given slash index using hints.
     * @param slashIndex index of the slash request
     * @param hints hints for checkpoints' indexes
     * @return slashedAmount virtual amount of the collateral slashed
     * @dev Only a network middleware can call this function.
     */
    function executeSlash(uint256 slashIndex, bytes calldata hints) external returns (uint256 slashedAmount);

    /**
     * @notice Veto a slash with a given slash index using hints.
     * @param slashIndex index of the slash request
     * @param hints hints for checkpoints' indexes
     * @dev Only a resolver can call this function.
     */
    function vetoSlash(uint256 slashIndex, bytes calldata hints) external;

    /**
     * @notice Set a resolver for a assset class using hints.
     * identifier identifier of the assset class
     * @param resolver address of the resolver
     * @param hints hints for checkpoints' indexes
     * @dev Only a network can call this function.
     */
    function setResolver(uint96 identifier, address resolver, bytes calldata hints) external;
}
