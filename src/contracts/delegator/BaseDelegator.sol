// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import { ERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {IBaseDelegator} from "../../interfaces/delegator/IBaseDelegator.sol";
import {IDelegatorHook} from "../../interfaces/delegator/IDelegatorHook.sol";
import {IOptInService} from "../../interfaces/service/IOptInService.sol";
import {IRegistry} from "../../interfaces/common/IRegistry.sol";
import {IVaultTokenized} from "../../interfaces/vault/IVaultTokenized.sol";
import {IVaultFactory} from "../../interfaces/IVaultFactory.sol";
import {IL1Registry} from "../../interfaces/IL1Registry.sol";
import {IEntity} from "../../interfaces/common/IEntity.sol";

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

abstract contract BaseDelegator is
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    IBaseDelegator,
    ERC165
{
    using ERC165Checker for address;

    /**
     * @inheritdoc IBaseDelegator
     */
    address public immutable FACTORY;

    /**
     * @inheritdoc IBaseDelegator
     */
    uint64 public immutable TYPE;

    /**
     * @inheritdoc IBaseDelegator
     */
    uint256 public constant HOOK_GAS_LIMIT = 250_000;

    /**
     * @inheritdoc IBaseDelegator
     */
    uint256 public constant HOOK_RESERVE = 20_000;

    /**
     * @inheritdoc IBaseDelegator
     */
    bytes32 public constant HOOK_SET_ROLE = keccak256("HOOK_SET_ROLE");

    /**
     * @inheritdoc IBaseDelegator
     */
    address public immutable L1_REGISTRY;

    /**
     * @inheritdoc IBaseDelegator
     */
    address public immutable VAULT_FACTORY;

    /**
     * @inheritdoc IBaseDelegator
     */
    address public immutable OPERATOR_VAULT_OPT_IN_SERVICE;

    /**
     * @inheritdoc IBaseDelegator
     */
    address public immutable OPERATOR_L1_OPT_IN_SERVICE;

    /**
     * @inheritdoc IBaseDelegator
     */
    address public vault;

    /**
     * @inheritdoc IBaseDelegator
     */
    address public hook;

    /**
     * @inheritdoc IBaseDelegator
     */
    mapping(address => mapping(uint96 => uint256)) public maxL1Limit;

    constructor(
        address l1Registry,
        address vaultFactory,
        address operatorVaultOptInService,
        address operatorL1OptInService,
        address delegatorFactory,
        uint64 entityType
    ) {
        _disableInitializers();
        L1_REGISTRY = l1Registry;
        VAULT_FACTORY = vaultFactory;
        OPERATOR_VAULT_OPT_IN_SERVICE = operatorVaultOptInService;
        OPERATOR_L1_OPT_IN_SERVICE = operatorL1OptInService;
        FACTORY = delegatorFactory;
        TYPE = entityType;
    }

    /**
     * @inheritdoc IBaseDelegator
     */
    function VERSION() external pure returns (uint64) {
        return 1;
    }

    /**
     * @inheritdoc IBaseDelegator
     */
    function stakeAt(
        address l1,
        uint96 stakableAsset,
        address operator,
        uint48 timestamp,
        bytes memory hints
    ) public view returns (uint256) {
        (uint256 stake_, bytes memory baseHints) = _stakeAt(l1, stakableAsset, operator, timestamp, hints);
        StakeBaseHints memory stakeBaseHints;
        if (baseHints.length > 0) {
            stakeBaseHints = abi.decode(baseHints, (StakeBaseHints));
        }

        if (
            stake_ == 0
            || !IOptInService(OPERATOR_VAULT_OPT_IN_SERVICE).isOptedInAt(
                operator, vault, timestamp, stakeBaseHints.operatorVaultOptInHint
            )
            || !IOptInService(OPERATOR_L1_OPT_IN_SERVICE).isOptedInAt(
                operator, l1, timestamp, stakeBaseHints.operatorL1OptInHint
            )
        ) {
            return 0;
        }

        return stake_;
    }

    /**
     * @inheritdoc IBaseDelegator
     */
    function stake(address l1, uint96 stakableAsset, address operator) external view returns (uint256) {
        if (
            !IOptInService(OPERATOR_VAULT_OPT_IN_SERVICE).isOptedIn(operator, vault)
            || !IOptInService(OPERATOR_L1_OPT_IN_SERVICE).isOptedIn(operator, l1)
        ) {
            return 0;
        }

        return _stake(l1, stakableAsset, operator);
    }

    /**
     * @inheritdoc IBaseDelegator
     */
    function setMaxL1Limit(address l1, uint96 stakableAsset, uint256 amount) external nonReentrant {
        if (!IL1Registry(L1_REGISTRY).isRegistered(msg.sender)) {
            revert BaseDelegator__NotL1();
        }

        if (maxL1Limit[l1][ stakableAsset] == amount) {
            revert BaseDelegator__AlreadySet();
        }

        maxL1Limit[l1][ stakableAsset] = amount;

        _setMaxL1Limit(l1, stakableAsset, amount);

        emit SetMaxL1Limit(l1, stakableAsset, amount);
    }

    /**
     * @inheritdoc IBaseDelegator
     */
    function setHook(
        address hook_
    ) external nonReentrant onlyRole(HOOK_SET_ROLE) {
        if (hook == hook_) {
            revert BaseDelegator__AlreadySet();
        }

        hook = hook_;

        emit SetHook(hook_);
    }

    /**
     * @inheritdoc IBaseDelegator
     */
    function onSlash(
        address l1,
        uint96 stakableAsset,
        address operator,
        uint256 amount,
        uint48 captureTimestamp,
        bytes memory data
    ) external nonReentrant {
        if (msg.sender != IVaultTokenized(vault).slasher()) {
            revert IVaultTokenized.Vault__NotSlasher();
        }

        address hook_ = hook;
        if (hook_ != address(0)) {
            bytes memory calldata_ =
                abi.encodeCall(IDelegatorHook.onSlash, (l1, stakableAsset, operator, amount, captureTimestamp, data));

            if (gasleft() < HOOK_RESERVE + HOOK_GAS_LIMIT * 64 / 63) {
                revert BaseDelegator__InsufficientHookGas();
            }

            assembly ("memory-safe") {
                pop(call(HOOK_GAS_LIMIT, hook_, 0, add(calldata_, 0x20), mload(calldata_), 0, 0))
            }
        }

        emit OnSlash(l1, stakableAsset, operator, amount, captureTimestamp);
    }

    /**
     * @inheritdoc IBaseDelegator
     */
    function initialize(
        bytes calldata data
    ) external initializer {
        _initialize(data);
    }

    function _initialize(
        bytes calldata data
    ) internal {
        (address vault_, bytes memory data_) = abi.decode(data, (address, bytes));

        if (!IRegistry(VAULT_FACTORY).isEntity(vault_)) {
            revert BaseDelegator__NotVault();
        }

        __ReentrancyGuard_init();

        vault = vault_;

        BaseParams memory baseParams = __initialize(vault_, data_);

        hook = baseParams.hook;

        if (baseParams.defaultAdminRoleHolder != address(0)) {
            _grantRole(DEFAULT_ADMIN_ROLE, baseParams.defaultAdminRoleHolder);
        }
        if (baseParams.hookSetRoleHolder != address(0)) {
            _grantRole(HOOK_SET_ROLE, baseParams.hookSetRoleHolder);
        }
    }

    function _stakeAt(
        address l1,
        uint96 stakableAsset,
        address operator,
        uint48 timestamp,
        bytes memory hints
    ) internal view virtual returns (uint256, bytes memory) {}

    function _stake(
        address l1,
        uint96 stakableAsset,
        address operator
    ) internal view virtual returns (uint256) {}

    function _setMaxL1Limit(address l1, uint96 stakableAsset, uint256 amount) internal virtual {}

    function __initialize(address vault_, bytes memory data) internal virtual returns (BaseParams memory) {}

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, AccessControlUpgradeable) returns (bool) {
        return
            interfaceId == type(IEntity).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
