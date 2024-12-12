// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import {L1Registry} from "../L1Registry.sol";
import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import { ERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
// import {StaticDelegateCallable} from "../common/StaticDelegateCallable.sol";

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
    address public immutable L1_REGISTRY;

    mapping(bytes32 subnetwork => uint256 value) public maxL1Limit;


    constructor(
        address l1registry,
        address vaultFactory,
        address operatorVaultOptInService,
        address operatorL1OptInService,
        address delegatorFactory,
        uint64 entityType
    ) {
        _disableInitializers();
        VAULT_FACTORY = vaultFactory;
        OPERATOR_VAULT_OPT_IN_SERVICE = operatorVaultOptInService;
        OPERATOR_L1_OPT_IN_SERVICE = operatorL1OptInService;
        L1_REGISTRY = l1registry;
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
        bytes32 subnetwork,
        address operator,
        uint48 timestamp,
        bytes memory hints
    ) public view returns (uint256) {
        (uint256 stake_, bytes memory baseHints) = _stakeAt(subnetwork, operator, timestamp, hints);
        StakeBaseHints memory stakeBaseHints;
        if (baseHints.length > 0) {
            stakeBaseHints = abi.decode(baseHints, (StakeBaseHints));
        }

        (address validatorManager, ) = IL1Registry(L1_REGISTRY).getSubnetwork(subnetwork);

        if (
            stake_ == 0
                || !IOptInService(OPERATOR_VAULT_OPT_IN_SERVICE).isOptedInAt(
                    operator, vault, timestamp, stakeBaseHints.operatorVaultOptInHint
                )
                || !IOptInService(OPERATOR_L1_OPT_IN_SERVICE).isOptedInAt(
                    operator, validatorManager, timestamp, stakeBaseHints.operatorL1OptInHint
                )
        ) {
            return 0;
        }

        return stake_;
    }

    /**
     * @inheritdoc IBaseDelegator
     */
    function stake(bytes32 subnetwork, address operator) external view returns (uint256) {
        
        (address validatorManager, ) = IL1Registry(L1_REGISTRY).getSubnetwork(subnetwork);

        if (
            !IOptInService(OPERATOR_VAULT_OPT_IN_SERVICE).isOptedIn(operator, vault)
                || !IOptInService(OPERATOR_L1_OPT_IN_SERVICE).isOptedIn(operator, validatorManager)
        ) {
            return 0;
        }

        return _stake(subnetwork, operator);
    }

    /**
     * @inheritdoc IBaseDelegator
     */
    function setMaxL1Limit(uint256 identifier, uint256 amount) external nonReentrant {
        if (!IL1Registry(L1_REGISTRY).isRegistered(msg.sender)) {
            revert BaseDelegator__NotL1();
        }

        bytes32 subnetwork = IL1Registry(L1_REGISTRY).getSubnetworkByParams(msg.sender, identifier);
        if (maxL1Limit[subnetwork] == amount) {
            revert BaseDelegator__AlreadySet();
        }

        maxL1Limit[subnetwork] = amount;

        _setMaxL1Limit(subnetwork, amount);

        emit SetMaxL1Limit(subnetwork, amount);
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
        bytes32 subnetwork,
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
                abi.encodeCall(IDelegatorHook.onSlash, (subnetwork, operator, amount, captureTimestamp, data));

            if (gasleft() < HOOK_RESERVE + HOOK_GAS_LIMIT * 64 / 63) {
                revert BaseDelegator__InsufficientHookGas();
            }

            assembly ("memory-safe") {
                pop(call(HOOK_GAS_LIMIT, hook_, 0, add(calldata_, 0x20), mload(calldata_), 0, 0))
            }
        }

        emit OnSlash(subnetwork, operator, amount, captureTimestamp);
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
        bytes32 subnetwork,
        address operator,
        uint48 timestamp,
        bytes memory hints
    ) internal view virtual returns (uint256, bytes memory) {}

    function _stake(bytes32 subnetwork, address operator) internal view virtual returns (uint256) {}

    function _setMaxL1Limit(bytes32 subnetwork, uint256 amount) internal virtual {}

    function __initialize(address vault_, bytes memory data) internal virtual returns (BaseParams memory) {}

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, AccessControlUpgradeable) returns (bool) {
        return
            interfaceId == type(IEntity).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
