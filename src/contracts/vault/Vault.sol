// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

// Compatible with OpenZeppelin Contracts ^5.0.0

pragma solidity 0.8.25;

import {IVault} from "../../interfaces/vault/IVault.sol";
import {Checkpoints} from "../libraries/Checkpoints.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";
import {IBaseDelegator} from "../../interfaces/delegator/IBaseDelegator.sol";
import {IBaseSlasher} from "../../interfaces/slasher/IBaseSlasher.sol";
import {ERC4626Math} from "../libraries/ERC4626Math.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Vault is AccessControl, IVault {
    using Checkpoints for Checkpoints.Trace256;
    using Math for uint256;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    /**
     * @inheritdoc IVault
     */
    bytes32 public constant DEPOSIT_WHITELIST_SET_ROLE = keccak256("DEPOSIT_WHITELIST_SET_ROLE");

    /**
     * @inheritdoc IVault
     */
    bytes32 public constant DEPOSITOR_WHITELIST_ROLE = keccak256("DEPOSITOR_WHITELIST_ROLE");

    /**
     * @inheritdoc IVault
     */
    bytes32 public constant IS_DEPOSIT_LIMIT_SET_ROLE = keccak256("IS_DEPOSIT_LIMIT_SET_ROLE");

    /**
     * @inheritdoc IVault
     */
    bytes32 public constant DEPOSIT_LIMIT_SET_ROLE = keccak256("DEPOSIT_LIMIT_SET_ROLE");

    /**
     * @inheritdoc IVault
     */
    address public immutable DELEGATOR_FACTORY;

    /**
     * @inheritdoc IVault
     */
    address public immutable SLASHER_FACTORY;

    /**
     * @inheritdoc IVault
     */
    bool public depositWhitelist;

    /**
     * @inheritdoc IVault
     */
    bool public isDepositLimit;

    /**
     * @inheritdoc IVault
     */
    address public collateral;

    /**
     * @inheritdoc IVault
     */
    address public burner;

    /**
     * @inheritdoc IVault
     */
    uint48 public epochDurationInit;

    /**
     * @inheritdoc IVault
     */
    uint48 public epochDuration;

    /**
     * @inheritdoc IVault
     */
    address public delegator;

    /**
     * @inheritdoc IVault
     */
    bool public isDelegatorInitialized;

    /**
     * @inheritdoc IVault
     */
    address public slasher;

    /**
     * @inheritdoc IVault
     */
    bool public isSlasherInitialized;

    /**
     * @inheritdoc IVault
     */
    uint256 public depositLimit;

    /**
     * @inheritdoc IVault
     */
    mapping(address account => bool value) public isDepositorWhitelisted;

    /**
     * @inheritdoc IVault
     */
    mapping(uint256 epoch => uint256 amount) public withdrawals;

    /**
     * @inheritdoc IVault
     */
    mapping(uint256 epoch => uint256 amount) public withdrawalShares;

    /**
     * @inheritdoc IVault
     */
    mapping(uint256 epoch => mapping(address account => uint256 amount)) public withdrawalSharesOf;

    /**
     * @inheritdoc IVault
     */
    mapping(uint256 epoch => mapping(address account => bool value)) public isWithdrawalsClaimed;

    Checkpoints.Trace256 internal _activeShares;

    Checkpoints.Trace256 internal _activeStake;

    mapping(address account => Checkpoints.Trace256 shares) internal _activeSharesOf;

    constructor(address delegatorFactory, address slasherFactory) {
        DELEGATOR_FACTORY = delegatorFactory;
        SLASHER_FACTORY = slasherFactory;
    }

    /**
     * @inheritdoc IVault
     */
    function epochAt(uint48 timestamp) public view returns (uint256) {
        if (timestamp < epochDurationInit) {
            revert Vault__InvalidTimestamp();
        }
        return (timestamp - epochDurationInit) / epochDuration;
    }

    /**
     * @inheritdoc IVault
     */
    function currentEpoch() public view returns (uint256) {
        return (Time.timestamp() - epochDurationInit) / epochDuration;
    }

    /**
     * @inheritdoc IVault
     */
    function currentEpochStart() public view returns (uint48) {
        return (epochDurationInit + currentEpoch() * epochDuration).toUint48();
    }

    /**
     * @inheritdoc IVault
     */
    function previousEpochStart() public view returns (uint48) {
        uint256 epoch = currentEpoch();
        if (epoch == 0) {
            revert Vault__NoPreviousEpoch();
        }
        return (epochDurationInit + (epoch - 1) * epochDuration).toUint48();
    }

    /**
     * @inheritdoc IVault
     */
    function nextEpochStart() public view returns (uint48) {
        return (epochDurationInit + (currentEpoch() + 1) * epochDuration).toUint48();
    }

    /**
     * @inheritdoc IVault
     */
    function activeSharesAt(uint48 timestamp, bytes memory hint) public view returns (uint256) {
        return _activeShares.upperLookupRecent(timestamp, hint);
    }

    /**
     * @inheritdoc IVault
     */
    function activeShares() public view returns (uint256) {
        return _activeShares.latest();
    }

    /**
     * @inheritdoc IVault
     */
    function activeStakeAt(uint48 timestamp, bytes memory hint) public view returns (uint256) {
        return _activeStake.upperLookupRecent(timestamp, hint);
    }

    /**
     * @inheritdoc IVault
     */
    function activeStake() public view returns (uint256) {
        return _activeStake.latest();
    }

    /**
     * @inheritdoc IVault
     */
    function activeSharesOfAt(address account, uint48 timestamp, bytes memory hint) public view returns (uint256) {
        return _activeSharesOf[account].upperLookupRecent(timestamp, hint);
    }

    /**
     * @inheritdoc IVault
     */
    function activeSharesOf(address account) public view returns (uint256) {
        return _activeSharesOf[account].latest();
    }
}
