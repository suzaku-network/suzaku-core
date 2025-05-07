// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {StaticDelegateCallable} from "../common/StaticDelegateCallable.sol";

import {IOptInService} from "../../interfaces/service/IOptInService.sol";
import {IOperatorRegistry} from "../../interfaces/IOperatorRegistry.sol";
import {IL1Registry} from "../../interfaces/IL1Registry.sol";

import {ExtendedCheckpoints} from "../libraries/Checkpoints.sol";

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";

contract OperatorL1OptInService is StaticDelegateCallable, EIP712, IOptInService {
    using ExtendedCheckpoints for ExtendedCheckpoints.Trace208;

    /**
     * @inheritdoc IOptInService
     */
    address public immutable WHO_REGISTRY;

    /**
     * @inheritdoc IOptInService
     */
    address public immutable WHERE_REGISTRY;

    bytes32 private constant OPT_IN_TYPEHASH =
        keccak256("OptIn(address who,address where,uint256 nonce,uint48 deadline)");

    bytes32 private constant OPT_OUT_TYPEHASH =
        keccak256("OptOut(address who,address where,uint256 nonce,uint48 deadline)");

    uint208 private constant OPT_IN_VALUE = 1;
    uint208 private constant OPT_OUT_VALUE = 0;

    /**
     * @inheritdoc IOptInService
     */
    mapping(address => mapping(address => uint256)) public nonces;
    mapping(address => mapping(address => ExtendedCheckpoints.Trace208)) internal _isOptedIn;

    modifier checkDeadline(
        uint48 deadline
    ) {
        if (deadline < Time.timestamp()) {
            revert OptInService__ExpiredSignature();
        }
        _;
    }

    constructor(address whoRegistry, address whereRegistry, string memory name) EIP712(name, "1") {
        WHO_REGISTRY = whoRegistry;
        WHERE_REGISTRY = whereRegistry;
    }

    /**
     * @inheritdoc IOptInService
     */
    function isOptedInAt(
        address who,
        address where,
        uint48 timestamp,
        bytes calldata hint
    ) external view returns (bool) {
        return _isOptedIn[who][where].upperLookupRecent(timestamp, hint) == OPT_IN_VALUE;
    }

    /**
     * @inheritdoc IOptInService
     */
    function isOptedIn(address who, address where) public view returns (bool) {
        return _isOptedIn[who][where].latest() == OPT_IN_VALUE;
    }

    /**
     * @inheritdoc IOptInService
     */
    function optIn(
        address where
    ) external {
        _optIn(msg.sender, where);
    }

    /**
     * @inheritdoc IOptInService
     */
    function optIn(
        address who,
        address where,
        uint48 deadline,
        bytes calldata signature
    ) external checkDeadline(deadline) {
        if (!SignatureChecker.isValidSignatureNow(who, _hash(true, who, where, deadline), signature)) {
            revert OptInService__InvalidSignature();
        }

        _optIn(who, where);

        _increaseNonce(who, where);
    }

    /**
     * @inheritdoc IOptInService
     */
    function optOut(
        address where
    ) external {
        _optOut(msg.sender, where);
    }

    /**
     * @inheritdoc IOptInService
     */
    function optOut(
        address who,
        address where,
        uint48 deadline,
        bytes calldata signature
    ) external checkDeadline(deadline) {
        if (!SignatureChecker.isValidSignatureNow(who, _hash(false, who, where, deadline), signature)) {
            revert OptInService__InvalidSignature();
        }

        _optOut(who, where);

        _increaseNonce(who, where);
    }

    /**
     * @inheritdoc IOptInService
     */
    function increaseNonce(
        address where
    ) external {
        _increaseNonce(msg.sender, where);
    }

    function _optIn(address who, address where) internal {
        // Instead of isEntity, we now rely on isRegistered
        if (!IOperatorRegistry(WHO_REGISTRY).isRegistered(who)) {
            revert OptInService__NotWho();
        }

        if (!IL1Registry(WHERE_REGISTRY).isRegistered(where)) {
            revert OptInService__NotWhereRegistered();
        }

        if (isOptedIn(who, where)) {
            revert OptInService__AlreadyOptedIn();
        }

        _isOptedIn[who][where].push(Time.timestamp(), OPT_IN_VALUE);

        emit OptIn(who, where);
    }

    function _optOut(address who, address where) internal {
        ExtendedCheckpoints.Trace208 storage trace = _isOptedIn[who][where];
        (, uint48 latestTimestamp, uint208 latestValue) = trace.latestCheckpoint();

        if (latestValue == 0) {
            revert OptInService__NotOptedIn();
        }

        if (latestTimestamp == Time.timestamp()) {
            revert OptInService__OptOutCooldown();
        }

        trace.push(Time.timestamp(), OPT_OUT_VALUE);

        emit OptOut(who, where);
    }

    function _hash(bool ifOptIn, address who, address where, uint48 deadline) internal view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(ifOptIn ? OPT_IN_TYPEHASH : OPT_OUT_TYPEHASH, who, where, nonces[who][where], deadline)
            )
        );
    }

    function _increaseNonce(address who, address where) internal {
        unchecked {
            ++nonces[who][where];
        }

        emit IncreaseNonce(who, where);
    }
}
