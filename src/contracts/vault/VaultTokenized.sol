// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {IVaultTokenized} from "../../interfaces/vault/IVaultTokenized.sol";
import {IBaseDelegator} from "../../interfaces/delegator/IBaseDelegator.sol";
import {IBaseSlasher} from "../../interfaces/slasher/IBaseSlasher.sol";
import {IRegistry} from "../../interfaces/common/IRegistry.sol";
import {IDelegatorFactory} from "../../interfaces/IDelegatorFactory.sol";

import {ExtendedCheckpoints} from "../libraries/Checkpoints.sol";
import {ERC4626Math} from "../libraries/ERC4626Math.sol";

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

contract VaultTokenized is
    Initializable,
    AccessControlUpgradeable,
    ERC20Upgradeable,
    IVaultTokenized,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using ExtendedCheckpoints for ExtendedCheckpoints.Trace256;
    using Math for uint256;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    error AlreadyInitialized();
    error NotFactory();
    error NotInitialized();

    /**
     * @inheritdoc IVaultTokenized
     */
    address public immutable FACTORY;

    // Constants (roles)
    bytes32 public constant DEPOSIT_WHITELIST_SET_ROLE = keccak256("DEPOSIT_WHITELIST_SET_ROLE");
    bytes32 public constant DEPOSITOR_WHITELIST_ROLE = keccak256("DEPOSITOR_WHITELIST_ROLE");
    bytes32 public constant IS_DEPOSIT_LIMIT_SET_ROLE = keccak256("IS_DEPOSIT_LIMIT_SET_ROLE");
    bytes32 public constant DEPOSIT_LIMIT_SET_ROLE = keccak256("DEPOSIT_LIMIT_SET_ROLE");

    /// @custom:storage-location erc7201:vault.storage
    struct VaultStorageStruct {
        // State variables
        address DELEGATOR_FACTORY;
        address SLASHER_FACTORY;
        bool depositWhitelist;
        bool isDepositLimit;
        address collateral;
        address burner;
        uint48 epochDurationInit;
        uint48 epochDuration;
        address delegator;
        bool isDelegatorInitialized;
        address slasher;
        bool isSlasherInitialized;
        uint256 depositLimit;
        mapping(address => bool) isDepositorWhitelisted;
        mapping(uint256 => uint256) withdrawals;
        mapping(uint256 => uint256) withdrawalShares;
        mapping(uint256 => mapping(address => uint256)) withdrawalSharesOf;
        mapping(uint256 => mapping(address => bool)) isWithdrawalsClaimed;
        ExtendedCheckpoints.Trace256 _activeShares;
        ExtendedCheckpoints.Trace256 _activeStake;
        mapping(address => ExtendedCheckpoints.Trace256) _activeSharesOf;
    }

    // bytes32(uint256(keccak256(abi.encodePacked(uint256(keccak256("vault.storage")) - 1))) & ~uint256(0xff));
    bytes32 public constant _VAULT_STORAGE_SLOT = 0x8b11a41397fd1980a1e0d979c37e7161d100e59fa63c611bcc37f4f3fcd7b600;

    function _vaultStorage() internal pure returns (VaultStorageStruct storage vs) {
        bytes32 slot = _VAULT_STORAGE_SLOT;
        assembly {
            vs.slot := slot
        }
    }

    /**
     *
     * @param vaultFactory Address of the vault factory.
     */
    constructor(
        address vaultFactory
    ) {
        _disableInitializers();
        if (vaultFactory == address(0)) {
            revert Vault__InvalidFactory();
        }
        FACTORY = vaultFactory;
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function initialize(
        uint64 initialVersion,
        address owner_,
        bytes calldata data,
        address delegatorFactory,
        address slasherFactory
    ) external initializer {
        VaultStorageStruct storage vs = _vaultStorage();

        __Ownable_init(owner_);
        __AccessControl_init();
        __ReentrancyGuard_init();

        vs.DELEGATOR_FACTORY = delegatorFactory;
        vs.SLASHER_FACTORY = slasherFactory;

        _initialize(initialVersion, owner_, data);
    }

    /**
     * @dev Internal initialization function.
     * @param data Initialization data.
     */
    function _initialize(
        uint64, /* initialVersion */
        address, /* owner */
        bytes memory data
    ) internal onlyInitializing {
        VaultStorageStruct storage vs = _vaultStorage();

        (InitParams memory params) = abi.decode(data, (InitParams));

        __ERC20_init(params.name, params.symbol);

        if (params.collateral == address(0)) {
            revert Vault__InvalidCollateral();
        }

        if (params.burner == address(0)) {
            revert Vault__InvalidBurner();
        }

        if (params.epochDuration == 0) {
            revert Vault__InvalidEpochDuration();
        }

        if (params.defaultAdminRoleHolder == address(0)) {
            if (params.depositWhitelistSetRoleHolder == address(0)) {
                if (params.depositWhitelist) {
                    if (params.depositorWhitelistRoleHolder == address(0)) {
                        revert Vault__MissingRoles();
                    }
                } else if (params.depositorWhitelistRoleHolder != address(0)) {
                    revert Vault__InconsistentRoles();
                }
            }

            if (params.isDepositLimitSetRoleHolder == address(0)) {
                if (params.isDepositLimit) {
                    if (params.depositLimit == 0 && params.depositLimitSetRoleHolder == address(0)) {
                        revert Vault__MissingRoles();
                    }
                } else if (params.depositLimit != 0 || params.depositLimitSetRoleHolder != address(0)) {
                    revert Vault__InconsistentRoles();
                }
            }
            
            if (params.depositWhitelist && 
                params.depositWhitelistSetRoleHolder != address(0) && 
                params.depositorWhitelistRoleHolder == address(0)) {
                revert Vault__InconsistentRoles();
            }

            if (params.isDepositLimit && 
                params.depositLimit == 0 && 
                params.isDepositLimitSetRoleHolder != address(0) && 
                params.depositLimitSetRoleHolder == address(0)) {
                revert Vault__InconsistentRoles();
            }
        }

        vs.collateral = params.collateral;
        vs.burner = params.burner;
        vs.epochDurationInit = Time.timestamp();
        vs.epochDuration = params.epochDuration;
        vs.depositWhitelist = params.depositWhitelist;
        vs.isDepositLimit = params.isDepositLimit;
        vs.depositLimit = params.depositLimit;

        if (params.defaultAdminRoleHolder != address(0)) {
            _grantRole(DEFAULT_ADMIN_ROLE, params.defaultAdminRoleHolder);
        }
        if (params.depositWhitelistSetRoleHolder != address(0)) {
            _grantRole(DEPOSIT_WHITELIST_SET_ROLE, params.depositWhitelistSetRoleHolder);
        }
        if (params.depositorWhitelistRoleHolder != address(0)) {
            _grantRole(DEPOSITOR_WHITELIST_ROLE, params.depositorWhitelistRoleHolder);
        }
        if (params.isDepositLimitSetRoleHolder != address(0)) {
            _grantRole(IS_DEPOSIT_LIMIT_SET_ROLE, params.isDepositLimitSetRoleHolder);
        }
        if (params.depositLimitSetRoleHolder != address(0)) {
            _grantRole(DEPOSIT_LIMIT_SET_ROLE, params.depositLimitSetRoleHolder);
        }
    }

    /**
     * @notice Returns the version of the contract.
     */
    function version() external view returns (uint64) {
        return _getInitializedVersion();
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function migrate(uint64 newVersion, bytes calldata data) external nonReentrant {
        if (msg.sender != FACTORY) {
            revert NotFactory();
        }

        _migrateInternal(newVersion, data);
    }

    function _migrateInternal(uint64 newVersion, bytes calldata data) private reinitializer(newVersion) {
        _migrate(newVersion, data);
    }

    /**
     * @dev Internal migration function. Can be overridden by child contracts.
     */
    function _migrate(uint64, /* newVersion */ bytes calldata /* data */ ) internal virtual onlyInitializing {
        // Implement migration logic here
        revert Vault__MigrationNotImplemented();
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function isInitialized() external view returns (bool) {
        VaultStorageStruct storage vs = _vaultStorage();
        return vs.isDelegatorInitialized && vs.isSlasherInitialized;
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function DELEGATOR_FACTORY() external view override returns (address) {
        VaultStorageStruct storage vs = _vaultStorage();
        return vs.DELEGATOR_FACTORY;
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function SLASHER_FACTORY() external view override returns (address) {
        VaultStorageStruct storage vs = _vaultStorage();
        return vs.SLASHER_FACTORY;
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function burner() external view override returns (address) {
        VaultStorageStruct storage vs = _vaultStorage();
        return vs.burner;
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function collateral() external view override returns (address) {
        VaultStorageStruct storage vs = _vaultStorage();
        return vs.collateral;
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function delegator() external view override returns (address) {
        VaultStorageStruct storage vs = _vaultStorage();
        return vs.delegator;
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function depositLimit() external view override returns (uint256) {
        VaultStorageStruct storage vs = _vaultStorage();
        return vs.depositLimit;
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function depositWhitelist() external view override returns (bool) {
        VaultStorageStruct storage vs = _vaultStorage();
        return vs.depositWhitelist;
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function epochDuration() external view override returns (uint48) {
        VaultStorageStruct storage vs = _vaultStorage();
        return vs.epochDuration;
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function epochDurationInit() external view override returns (uint48) {
        VaultStorageStruct storage vs = _vaultStorage();
        return vs.epochDurationInit;
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function isDelegatorInitialized() external view override returns (bool) {
        VaultStorageStruct storage vs = _vaultStorage();
        return vs.isDelegatorInitialized;
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function isDepositLimit() external view override returns (bool) {
        VaultStorageStruct storage vs = _vaultStorage();
        return vs.isDepositLimit;
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function isDepositorWhitelisted(
        address account
    ) external view override returns (bool) {
        VaultStorageStruct storage vs = _vaultStorage();
        return vs.isDepositorWhitelisted[account];
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function isSlasherInitialized() external view override returns (bool) {
        VaultStorageStruct storage vs = _vaultStorage();
        return vs.isSlasherInitialized;
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function isWithdrawalsClaimed(uint256 epoch, address account) external view override returns (bool) {
        VaultStorageStruct storage vs = _vaultStorage();
        return vs.isWithdrawalsClaimed[epoch][account];
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function slasher() external view override returns (address) {
        VaultStorageStruct storage vs = _vaultStorage();
        return vs.slasher;
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function withdrawalShares(
        uint256 epoch
    ) external view override returns (uint256) {
        VaultStorageStruct storage vs = _vaultStorage();
        return vs.withdrawalShares[epoch];
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function withdrawalSharesOf(uint256 epoch, address account) external view override returns (uint256) {
        VaultStorageStruct storage vs = _vaultStorage();
        return vs.withdrawalSharesOf[epoch][account];
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function withdrawals(
        uint256 epoch
    ) external view override returns (uint256) {
        VaultStorageStruct storage vs = _vaultStorage();
        return vs.withdrawals[epoch];
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function totalStake() external view override returns (uint256) {
        VaultStorageStruct storage vs = _vaultStorage();
        uint256 epoch = currentEpoch();
        return activeStake() + vs.withdrawals[epoch] + vs.withdrawals[epoch + 1];
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function activeBalanceOfAt(address account, uint48 timestamp, bytes calldata hints) public view returns (uint256) {
        // VaultStorageStruct storage vs = _vaultStorage();
        ActiveBalanceOfHints memory activeBalanceOfHints;
        if (hints.length > 0) {
            activeBalanceOfHints = abi.decode(hints, (ActiveBalanceOfHints));
        }
        return ERC4626Math.previewRedeem(
            activeSharesOfAt(account, timestamp, activeBalanceOfHints.activeSharesOfHint),
            activeStakeAt(timestamp, activeBalanceOfHints.activeStakeHint),
            activeSharesAt(timestamp, activeBalanceOfHints.activeSharesHint)
        );
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function activeBalanceOf(
        address account
    ) public view returns (uint256) {
        return ERC4626Math.previewRedeem(activeSharesOf(account), activeStake(), activeShares());
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function withdrawalsOf(uint256 epoch, address account) public view returns (uint256) {
        VaultStorageStruct storage vs = _vaultStorage();
        return ERC4626Math.previewRedeem(
            vs.withdrawalSharesOf[epoch][account], vs.withdrawals[epoch], vs.withdrawalShares[epoch]
        );
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function slashableBalanceOf(
        address account
    ) external view returns (uint256) {
        uint256 epoch = currentEpoch();
        return activeBalanceOf(account) + withdrawalsOf(epoch, account) + withdrawalsOf(epoch + 1, account);
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function deposit(
        address onBehalfOf,
        uint256 amount
    ) public virtual nonReentrant returns (uint256 depositedAmount, uint256 mintedShares) {
        VaultStorageStruct storage vs = _vaultStorage();

        if (onBehalfOf == address(0)) {
            revert Vault__InvalidOnBehalfOf();
        }

        if (vs.depositWhitelist && !vs.isDepositorWhitelisted[msg.sender]) {
            revert Vault__NotWhitelistedDepositor();
        }

        uint256 balanceBefore = IERC20(vs.collateral).balanceOf(address(this));
        IERC20(vs.collateral).safeTransferFrom(msg.sender, address(this), amount);
        depositedAmount = IERC20(vs.collateral).balanceOf(address(this)) - balanceBefore;

        if (depositedAmount == 0) {
            revert Vault__InsufficientDeposit();
        }

        if (vs.isDepositLimit && activeStake() + depositedAmount > vs.depositLimit) {
            revert Vault__DepositLimitReached();
        }

        uint256 activeStake_ = activeStake();
        uint256 activeShares_ = activeShares();

        mintedShares = ERC4626Math.previewDeposit(depositedAmount, activeShares_, activeStake_);

        vs._activeStake.push(Time.timestamp(), activeStake_ + depositedAmount);
        vs._activeShares.push(Time.timestamp(), activeShares_ + mintedShares);
        vs._activeSharesOf[onBehalfOf].push(Time.timestamp(), activeSharesOf(onBehalfOf) + mintedShares);

        emit Deposit(msg.sender, onBehalfOf, depositedAmount, mintedShares);
        emit Transfer(address(0), onBehalfOf, mintedShares);
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function withdraw(
        address claimer,
        uint256 amount
    ) external nonReentrant returns (uint256 burnedShares, uint256 mintedShares) {
        // VaultStorageStruct storage vs = _vaultStorage();

        if (claimer == address(0)) {
            revert Vault__InvalidClaimer();
        }

        if (amount == 0) {
            revert Vault__InsufficientWithdrawal();
        }

        burnedShares = ERC4626Math.previewWithdraw(amount, activeShares(), activeStake());

        if (burnedShares > activeSharesOf(msg.sender)) {
            revert Vault__TooMuchWithdraw();
        }

        mintedShares = _withdraw(claimer, amount, burnedShares);
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function redeem(
        address claimer,
        uint256 shares
    ) external nonReentrant returns (uint256 withdrawnAssets, uint256 mintedShares) {
        // VaultStorageStruct storage vs = _vaultStorage();

        if (claimer == address(0)) {
            revert Vault__InvalidClaimer();
        }

        if (shares > activeSharesOf(msg.sender)) {
            revert Vault__TooMuchRedeem();
        }

        withdrawnAssets = ERC4626Math.previewRedeem(shares, activeStake(), activeShares());

        if (withdrawnAssets == 0) {
            revert Vault__InsufficientRedemption();
        }

        mintedShares = _withdraw(claimer, withdrawnAssets, shares);
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function claim(address recipient, uint256 epoch) external nonReentrant returns (uint256 amount) {
        VaultStorageStruct storage vs = _vaultStorage();

        if (recipient == address(0)) {
            revert Vault__InvalidRecipient();
        }

        amount = _claim(epoch);

        IERC20(vs.collateral).safeTransfer(recipient, amount);

        emit Claim(msg.sender, recipient, epoch, amount);
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function claimBatch(address recipient, uint256[] calldata epochs) external nonReentrant returns (uint256 amount) {
        VaultStorageStruct storage vs = _vaultStorage();

        if (recipient == address(0)) {
            revert Vault__InvalidRecipient();
        }

        uint256 length = epochs.length;
        if (length == 0) {
            revert Vault__InvalidLengthEpochs();
        }

        for (uint256 i; i < length; ++i) {
            amount += _claim(epochs[i]);
        }

        IERC20(vs.collateral).safeTransfer(recipient, amount);

        emit ClaimBatch(msg.sender, recipient, epochs, amount);
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function onSlash(uint256 amount, uint48 captureTimestamp) external nonReentrant returns (uint256 slashedAmount) {
        VaultStorageStruct storage vs = _vaultStorage();

        if (msg.sender != vs.slasher) {
            revert Vault__NotSlasher();
        }

        uint256 currentEpoch_ = currentEpoch();
        uint256 captureEpoch = epochAt(captureTimestamp);
        if ((currentEpoch_ > 0 && captureEpoch + 1 < currentEpoch_) || captureEpoch > currentEpoch_) {
            revert Vault__InvalidCaptureEpoch();
        }

        uint256 activeStake_ = activeStake();
        uint256 nextWithdrawals = vs.withdrawals[currentEpoch_ + 1];
        
        if (captureEpoch == currentEpoch_) {
            uint256 slashableStake = activeStake_ + nextWithdrawals;
            slashedAmount = Math.min(amount, slashableStake);
            if (slashedAmount > 0) {
                uint256 activeSlashed = slashedAmount.mulDiv(activeStake_, slashableStake);
                uint256 nextWithdrawalsSlashed = slashedAmount - activeSlashed;

                // Check for overflow and redistribute
                uint256 requestedNext = nextWithdrawalsSlashed;
                if (nextWithdrawals < requestedNext) {
                    uint256 deficit = requestedNext - nextWithdrawals;
                    nextWithdrawalsSlashed = nextWithdrawals;
                    activeSlashed += deficit;
                    
                    emit SlashWithRedistribution(
                        requestedNext,
                        nextWithdrawalsSlashed,
                        deficit,
                        currentEpoch_ + 1
                    );
                }

                vs._activeStake.push(Time.timestamp(), activeStake_ - activeSlashed);
                vs.withdrawals[currentEpoch_ + 1] = nextWithdrawals - nextWithdrawalsSlashed;
            }
        } else {
            uint256 withdrawals_ = vs.withdrawals[currentEpoch_];
            uint256 slashableStake = activeStake_ + withdrawals_ + nextWithdrawals;
            slashedAmount = Math.min(amount, slashableStake);
            if (slashedAmount > 0) {
                uint256 activeSlashed = slashedAmount.mulDiv(activeStake_, slashableStake);
                uint256 nextWithdrawalsSlashed = slashedAmount.mulDiv(nextWithdrawals, slashableStake);
                uint256 withdrawalsSlashed = slashedAmount - activeSlashed - nextWithdrawalsSlashed;

                if (withdrawals_ < withdrawalsSlashed) {
                    nextWithdrawalsSlashed += withdrawalsSlashed - withdrawals_;
                    withdrawalsSlashed = withdrawals_;
                }

                // Check for overflow and redistribute
                uint256 requestedNext = nextWithdrawalsSlashed;
                if (nextWithdrawals < requestedNext) {
                    uint256 deficit = requestedNext - nextWithdrawals;
                    nextWithdrawalsSlashed = nextWithdrawals;
                    activeSlashed += deficit;
                    
                    emit SlashWithRedistribution(
                        requestedNext,
                        nextWithdrawalsSlashed,
                        deficit,
                        currentEpoch_ + 1
                    );
                }

                vs._activeStake.push(Time.timestamp(), activeStake_ - activeSlashed);
                vs.withdrawals[currentEpoch_ + 1] = nextWithdrawals - nextWithdrawalsSlashed;
                vs.withdrawals[currentEpoch_] = withdrawals_ - withdrawalsSlashed;
            }
        }

        if (slashedAmount > 0) {
            IERC20(vs.collateral).safeTransfer(vs.burner, slashedAmount);
        }

        // Keep only the original event for normal cases
        emit OnSlash(amount, captureTimestamp, slashedAmount);
    }


    /**
     * @inheritdoc IVaultTokenized
     */
    function setDepositWhitelist(
        bool status
    ) external nonReentrant onlyRole(DEPOSIT_WHITELIST_SET_ROLE) {
        VaultStorageStruct storage vs = _vaultStorage();

        if (vs.depositWhitelist == status) {
            revert Vault__AlreadySet();
        }

        vs.depositWhitelist = status;

        emit SetDepositWhitelist(status);
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function setDepositorWhitelistStatus(
        address account,
        bool status
    ) external nonReentrant onlyRole(DEPOSITOR_WHITELIST_ROLE) {
        VaultStorageStruct storage vs = _vaultStorage();

        if (account == address(0)) {
            revert Vault__InvalidAccount();
        }

        if (vs.isDepositorWhitelisted[account] == status) {
            revert Vault__AlreadySet();
        }

        vs.isDepositorWhitelisted[account] = status;

        emit SetDepositorWhitelistStatus(account, status);
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function setIsDepositLimit(
        bool status
    ) external nonReentrant onlyRole(IS_DEPOSIT_LIMIT_SET_ROLE) {
        VaultStorageStruct storage vs = _vaultStorage();

        if (vs.isDepositLimit == status) {
            revert Vault__AlreadySet();
        }

        vs.isDepositLimit = status;

        emit SetIsDepositLimit(status);
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function setDepositLimit(
        uint256 limit
    ) external nonReentrant onlyRole(DEPOSIT_LIMIT_SET_ROLE) {
        VaultStorageStruct storage vs = _vaultStorage();

        if (vs.depositLimit == limit) {
            revert Vault__AlreadySet();
        }

        vs.depositLimit = limit;

        emit SetDepositLimit(limit);
    }

    function setDelegator(
        address delegator_
    ) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        VaultStorageStruct storage vs = _vaultStorage();

        if (vs.isDelegatorInitialized) {
            revert Vault__DelegatorAlreadyInitialized();
        }

        // replace by IDelegatorFactory
        if (!IDelegatorFactory(vs.DELEGATOR_FACTORY).isEntity(delegator_)) {
            revert Vault__NotDelegator();
        }

        if (IBaseDelegator(delegator_).vault() != address(this)) {
            revert Vault__InvalidDelegator();
        }

        vs.delegator = delegator_;

        vs.isDelegatorInitialized = true;

        emit SetDelegator(delegator_);
    }

    function setSlasher(
        address slasher_
    ) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        VaultStorageStruct storage vs = _vaultStorage();

        if (vs.isSlasherInitialized) {
            revert Vault__SlasherAlreadyInitialized();
        }

        // replace by ISlasherFactory
        if (slasher_ != address(0)) {
            if (!IRegistry(vs.SLASHER_FACTORY).isEntity(slasher_)) {
                revert Vault__NotSlasher();
            }

            if (IBaseSlasher(slasher_).vault() != address(this)) {
                revert Vault__InvalidSlasher();
            }

            vs.slasher = slasher_;
        }

        vs.isSlasherInitialized = true;

        emit SetSlasher(slasher_);
    }

    function _withdraw(
        address claimer,
        uint256 withdrawnAssets,
        uint256 burnedShares
    ) internal virtual returns (uint256 mintedShares) {
        VaultStorageStruct storage vs = _vaultStorage();

        vs._activeSharesOf[msg.sender].push(Time.timestamp(), activeSharesOf(msg.sender) - burnedShares);
        vs._activeShares.push(Time.timestamp(), activeShares() - burnedShares);
        vs._activeStake.push(Time.timestamp(), activeStake() - withdrawnAssets);

        uint256 epoch = currentEpoch() + 1;
        uint256 withdrawals_ = vs.withdrawals[epoch];
        uint256 withdrawalsShares_ = vs.withdrawalShares[epoch];

        mintedShares = ERC4626Math.previewDeposit(withdrawnAssets, withdrawalsShares_, withdrawals_);

        vs.withdrawals[epoch] = withdrawals_ + withdrawnAssets;
        vs.withdrawalShares[epoch] = withdrawalsShares_ + mintedShares;
        vs.withdrawalSharesOf[epoch][claimer] += mintedShares;

        emit Withdraw(msg.sender, claimer, withdrawnAssets, burnedShares, mintedShares);
        emit Transfer(msg.sender, address(0), burnedShares);
    }

    function _claim(
        uint256 epoch
    ) internal returns (uint256 amount) {
        VaultStorageStruct storage vs = _vaultStorage();
        if (epoch >= currentEpoch()) {
            revert Vault__InvalidEpoch();
        }
        
        // Cache the mapping lookup for the specific user and epoch
        mapping(address => bool) storage epochClaimsMap = vs.isWithdrawalsClaimed[epoch];
        if (epochClaimsMap[msg.sender]) {
            revert Vault__AlreadyClaimed();
        }

        amount = withdrawalsOf(epoch, msg.sender);

        if (amount == 0) {
            revert Vault__InsufficientClaim();
        }

        epochClaimsMap[msg.sender] = true;
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function epochAt(
        uint48 timestamp
    ) public view returns (uint256) {
        VaultStorageStruct storage vs = _vaultStorage();

        if (timestamp < vs.epochDurationInit) {
            revert Vault__InvalidTimestamp();
        }
        unchecked {
            return (timestamp - vs.epochDurationInit) / vs.epochDuration;
        }
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function currentEpoch() public view returns (uint256) {
        VaultStorageStruct storage vs = _vaultStorage();
        return (Time.timestamp() - vs.epochDurationInit) / vs.epochDuration;
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function currentEpochStart() public view returns (uint48) {
        VaultStorageStruct storage vs = _vaultStorage();
        return (vs.epochDurationInit + currentEpoch() * vs.epochDuration).toUint48();
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function previousEpochStart() public view returns (uint48) {
        VaultStorageStruct storage vs = _vaultStorage();
        uint256 epoch = currentEpoch();
        if (epoch == 0) {
            revert Vault__NoPreviousEpoch();
        }
        return (vs.epochDurationInit + (epoch - 1) * vs.epochDuration).toUint48();
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function nextEpochStart() public view returns (uint48) {
        VaultStorageStruct storage vs = _vaultStorage();
        return (vs.epochDurationInit + (currentEpoch() + 1) * vs.epochDuration).toUint48();
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function activeSharesAt(uint48 timestamp, bytes memory hint) public view returns (uint256) {
        VaultStorageStruct storage vs = _vaultStorage();
        return vs._activeShares.upperLookupRecent(timestamp, hint);
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function activeShares() public view returns (uint256) {
        VaultStorageStruct storage vs = _vaultStorage();
        return vs._activeShares.latest();
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function activeStakeAt(uint48 timestamp, bytes memory hint) public view returns (uint256) {
        VaultStorageStruct storage vs = _vaultStorage();
        return vs._activeStake.upperLookupRecent(timestamp, hint);
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function activeStake() public view returns (uint256) {
        VaultStorageStruct storage vs = _vaultStorage();
        return vs._activeStake.latest();
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function activeSharesOfAt(address account, uint48 timestamp, bytes memory hint) public view returns (uint256) {
        VaultStorageStruct storage vs = _vaultStorage();
        return vs._activeSharesOf[account].upperLookupRecent(timestamp, hint);
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function activeSharesOf(
        address account
    ) public view returns (uint256) {
        VaultStorageStruct storage vs = _vaultStorage();
        return vs._activeSharesOf[account].latest();
    }

    /**
     * @inheritdoc ERC20Upgradeable
     */
    function decimals() public view override returns (uint8) {
        VaultStorageStruct storage vs = _vaultStorage();
        return IERC20Metadata(vs.collateral).decimals();
    }

    /**
     * @inheritdoc ERC20Upgradeable
     */
    function totalSupply() public view override returns (uint256) {
        // VaultStorageStruct storage vs = _vaultStorage();
        return activeShares();
    }

    /**
     * @inheritdoc ERC20Upgradeable
     */
    function balanceOf(
        address account
    ) public view override returns (uint256) {
        // VaultStorageStruct storage vs = _vaultStorage();
        return activeSharesOf(account);
    }

    /**
     * @inheritdoc ERC20Upgradeable
     */
    function _update(address from, address to, uint256 value) internal override {
        VaultStorageStruct storage vs = _vaultStorage();
        if (from == address(0)) {
            // Overflow check required: The rest of the code assumes that totalSupply never overflows
            vs._activeShares.push(Time.timestamp(), totalSupply() + value);
        } else {
            uint256 fromBalance = balanceOf(from);
            if (fromBalance < value) {
                revert ERC20InsufficientBalance(from, fromBalance, value);
            }
            unchecked {
                // Overflow not possible: value <= fromBalance <= totalSupply.
                vs._activeSharesOf[from].push(Time.timestamp(), fromBalance - value);
            }
        }

        if (to == address(0)) {
            unchecked {
                // Overflow not possible: value <= totalSupply or value <= fromBalance <= totalSupply.
                vs._activeShares.push(Time.timestamp(), totalSupply() - value);
            }
        } else {
            unchecked {
                // Overflow not possible: balance + value is at most totalSupply, which we know fits into a uint256.
                vs._activeSharesOf[to].push(Time.timestamp(), balanceOf(to) + value);
            }
        }

        emit Transfer(from, to, value);
    }

    /**
     * @inheritdoc IVaultTokenized
     */
    function staticDelegateCall(address target, bytes calldata data) external onlyOwner {
        (bool success, bytes memory returndata) = target.delegatecall(data);
        bytes memory revertData = abi.encode(success, returndata);
        assembly {
            revert(add(32, revertData), mload(revertData))
        }
    }
}
