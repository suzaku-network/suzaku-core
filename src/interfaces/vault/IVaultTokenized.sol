// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity ^0.8.0;

// import {IMigratableEntity} from "../common/IMigratableEntity.sol";

interface IVaultTokenized {
    error Vault__AlreadyClaimed();
    error Vault__AlreadySet();
    error Vault__DelegatorAlreadyInitialized();
    error Vault__DepositLimitReached();
    error Vault__InsufficientClaim();
    error Vault__InsufficientDeposit();
    error Vault__InsufficientRedemption();
    error Vault__InsufficientWithdrawal();
    error Vault__InvalidAccount();
    error Vault__InvalidCaptureEpoch();
    error Vault__InvalidClaimer();
    error Vault__InvalidCollateral();
    error Vault__InvalidDelegator();
    error Vault__InvalidEpoch();
    error Vault__InvalidEpochDuration();
    error Vault__InvalidLengthEpochs();
    error Vault__InvalidOnBehalfOf();
    error Vault__InvalidRecipient();
    error Vault__InvalidSlasher();
    error Vault__MissingRoles();
    error Vault__InconsistentRoles();
    error Vault__NotDelegator();
    error Vault__NotSlasher();
    error Vault__NotWhitelistedDepositor();
    error Vault__SlasherAlreadyInitialized();
    error Vault__TooMuchRedeem();
    error Vault__TooMuchWithdraw();
    error Vault__InvalidTimestamp();
    error Vault__NoPreviousEpoch();
    error Vault__MigrationNotImplemented();
    error Vault__InvalidFactory();
    
    // Structs
    /**
     * @notice Initial parameters needed for a vault deployment.
     * @param collateral vault's underlying collateral
     * @param burner vault's burner to issue debt to (e.g., 0xdEaD or some unwrapper contract)
     * @param epochDuration duration of the vault epoch (it determines sync points for withdrawals)
     * @param depositWhitelist if enabling deposit whitelist
     * @param isDepositLimit if enabling deposit limit
     * @param depositLimit deposit limit (maximum amount of the collateral that can be in the vault simultaneously)
     * @param defaultAdminRoleHolder address of the initial DEFAULT_ADMIN_ROLE holder
     * @param depositWhitelistSetRoleHolder address of the initial DEPOSIT_WHITELIST_SET_ROLE holder
     * @param depositorWhitelistRoleHolder address of the initial DEPOSITOR_WHITELIST_ROLE holder
     * @param isDepositLimitSetRoleHolder address of the initial IS_DEPOSIT_LIMIT_SET_ROLE holder
     * @param depositLimitSetRoleHolder address of the initial DEPOSIT_LIMIT_SET_ROLE holder
     * @param name name for the ERC20 tokenized vault
     * @param symbol symbol for the ERC20 tokenized vault
     */
    struct InitParams {
        address collateral;
        address burner;
        uint48 epochDuration;
        bool depositWhitelist;
        bool isDepositLimit;
        uint256 depositLimit;
        address defaultAdminRoleHolder;
        address depositWhitelistSetRoleHolder;
        address depositorWhitelistRoleHolder;
        address isDepositLimitSetRoleHolder;
        address depositLimitSetRoleHolder;
        string name;
        string symbol;
    }

    /**
     * @notice Get the factory's address.
     * @return address of the factory
     */
    function FACTORY() external view returns (address);

    /**
     * @notice Get the entity's version.
     * @return version of the entity
     * @dev Starts from 1.
     */
    function version() external view returns (uint64);

    /**
     * @notice Initialize this entity contract by using a given data and setting a particular version and owner.
     * @param initialVersion initial version of the entity
     * @param owner initial owner of the entity
     * @param data some data to use
     * @param delegatorFactory Address of the delegator factory.
     * @param slasherFactory Address of the slasher factory.
     *
     */
    function initialize(
        uint64 initialVersion,
        address owner,
        bytes calldata data,
        address delegatorFactory,
        address slasherFactory
    ) external;

    /**
     * @notice Migrate this entity to a particular newer version using a given data.
     * @param newVersion new version of the entity
     * @param data some data to use
     */
    function migrate(uint64 newVersion, bytes calldata data) external;

    /**
     * @notice Hints for an active balance.
     * @param activeSharesOfHint hint for the active shares of checkpoint
     * @param activeStakeHint hint for the active stake checkpoint
     * @param activeSharesHint hint for the active shares checkpoint
     */
    struct ActiveBalanceOfHints {
        bytes activeSharesOfHint;
        bytes activeStakeHint;
        bytes activeSharesHint;
    }

    // Events
    /**
     * @notice Emitted when a deposit is made.
     * @param depositor account that made the deposit
     * @param onBehalfOf account the deposit was made on behalf of
     * @param amount amount of the collateral deposited
     * @param shares amount of the active shares minted
     */
    event Deposit(address indexed depositor, address indexed onBehalfOf, uint256 amount, uint256 shares);

    /**
     * @notice Emitted when a withdrawal is made.
     * @param withdrawer account that made the withdrawal
     * @param claimer account that needs to claim the withdrawal
     * @param amount amount of the collateral withdrawn
     * @param burnedShares amount of the active shares burned
     * @param mintedShares amount of the epoch withdrawal shares minted
     */
    event Withdraw(
        address indexed withdrawer, address indexed claimer, uint256 amount, uint256 burnedShares, uint256 mintedShares
    );

    /**
     * @notice Emitted when a claim is made.
     * @param claimer account that claimed
     * @param recipient account that received the collateral
     * @param epoch epoch the collateral was claimed for
     * @param amount amount of the collateral claimed
     */
    event Claim(address indexed claimer, address indexed recipient, uint256 epoch, uint256 amount);

    /**
     * @notice Emitted when a batch claim is made.
     * @param claimer account that claimed
     * @param recipient account that received the collateral
     * @param epochs epochs the collateral was claimed for
     * @param amount amount of the collateral claimed
     */
    event ClaimBatch(address indexed claimer, address indexed recipient, uint256[] epochs, uint256 amount);

    /**
     * @notice Emitted when a slash happens.
     * @param amount amount of the collateral to slash
     * @param captureTimestamp time point when the stake was captured
     * @param slashedAmount real amount of the collateral slashed
     */
    event OnSlash(uint256 amount, uint48 captureTimestamp, uint256 slashedAmount);

    /**
     * @notice Emitted when a deposit whitelist status is enabled/disabled.
     * @param status if enabled deposit whitelist
     */
    event SetDepositWhitelist(bool status);

    /**
     * @notice Emitted when a depositor whitelist status is set.
     * @param account account for which the whitelist status is set
     * @param status if whitelisted the account
     */
    event SetDepositorWhitelistStatus(address indexed account, bool status);

    /**
     * @notice Emitted when a deposit limit status is enabled/disabled.
     * @param status if enabled deposit limit
     */
    event SetIsDepositLimit(bool status);

    /**
     * @notice Emitted when a deposit limit is set.
     * @param limit deposit limit (maximum amount of the collateral that can be in the vault simultaneously)
     */
    event SetDepositLimit(uint256 limit);

    /**
     * @notice Emitted when a delegator is set.
     * @param delegator vault's delegator to delegate the stake to networks and operators
     * @dev Can be set only once.
     */
    event SetDelegator(address indexed delegator);

    /**
     * @notice Emitted when a slasher is set.
     * @param slasher vault's slasher to provide a slashing mechanism to networks
     * @dev Can be set only once.
     */
    event SetSlasher(address indexed slasher);

    // Functions
    // Ex IVaultStorage
    /**
     * @notice Get the delegator factory's address.
     * @return address of the delegator factory
     */
    function DELEGATOR_FACTORY() external view returns (address);

    /**
     * @notice Get the slasher factory's address.
     * @return address of the slasher factory
     */
    function SLASHER_FACTORY() external view returns (address);

    /**
     * @notice Get a vault collateral.
     * @return address of the underlying collateral
     */
    function collateral() external view returns (address);

    /**
     * @notice Get a burner to issue debt to (e.g., 0xdEaD or some unwrapper contract).
     * @return address of the burner
     */
    function burner() external view returns (address);

    /**
     * @notice Get a delegator (it delegates the vault's stake to networks and operators).
     * @return address of the delegator
     */
    function delegator() external view returns (address);

    /**
     * @notice Get if the delegator is initialized.
     * @return if the delegator is initialized
     */
    function isDelegatorInitialized() external view returns (bool);

    /**
     * @notice Get a slasher (it provides networks a slashing mechanism).
     * @return address of the slasher
     */
    function slasher() external view returns (address);

    /**
     * @notice Get if the slasher is initialized.
     * @return if the slasher is initialized
     */
    function isSlasherInitialized() external view returns (bool);

    /**
     * @notice Get a time point of the epoch duration set.
     * @return time point of the epoch duration set
     */
    function epochDurationInit() external view returns (uint48);

    /**
     * @notice Get a duration of the vault epoch.
     * @return duration of the epoch
     */
    function epochDuration() external view returns (uint48);

    /**
     * @notice Get an epoch at a given timestamp.
     * @param timestamp time point to get the epoch at
     * @return epoch at the timestamp
     * @dev Reverts if the timestamp is less than the start of the epoch 0.
     */
    function epochAt(
        uint48 timestamp
    ) external view returns (uint256);

    /**
     * @notice Get a current vault epoch.
     * @return current epoch
     */
    function currentEpoch() external view returns (uint256);

    /**
     * @notice Get a start of the current vault epoch.
     * @return start of the current epoch
     */
    function currentEpochStart() external view returns (uint48);

    /**
     * @notice Get a start of the previous vault epoch.
     * @return start of the previous epoch
     * @dev Reverts if the current epoch is 0.
     */
    function previousEpochStart() external view returns (uint48);

    /**
     * @notice Get a start of the next vault epoch.
     * @return start of the next epoch
     */
    function nextEpochStart() external view returns (uint48);

    /**
     * @notice Get if the deposit whitelist is enabled.
     * @return if the deposit whitelist is enabled
     */
    function depositWhitelist() external view returns (bool);

    /**
     * @notice Get if a given account is whitelisted as a depositor.
     * @param account address to check
     * @return if the account is whitelisted as a depositor
     */
    function isDepositorWhitelisted(
        address account
    ) external view returns (bool);

    /**
     * @notice Get if the deposit limit is set.
     * @return if the deposit limit is set
     */
    function isDepositLimit() external view returns (bool);

    /**
     * @notice Get a deposit limit (maximum amount of the active stake that can be in the vault simultaneously).
     * @return deposit limit
     */
    function depositLimit() external view returns (uint256);

    /**
     * @notice Get a total number of active shares in the vault at a given timestamp using a hint.
     * @param timestamp time point to get the total number of active shares at
     * @param hint hint for the checkpoint index
     * @return total number of active shares at the timestamp
     */
    function activeSharesAt(uint48 timestamp, bytes memory hint) external view returns (uint256);

    /**
     * @notice Get a total number of active shares in the vault.
     * @return total number of active shares
     */
    function activeShares() external view returns (uint256);

    /**
     * @notice Get a total amount of active stake in the vault at a given timestamp using a hint.
     * @param timestamp time point to get the total active stake at
     * @param hint hint for the checkpoint index
     * @return total amount of active stake at the timestamp
     */
    function activeStakeAt(uint48 timestamp, bytes memory hint) external view returns (uint256);

    /**
     * @notice Get a total amount of active stake in the vault.
     * @return total amount of active stake
     */
    function activeStake() external view returns (uint256);

    /**
     * @notice Get a total number of active shares for a particular account at a given timestamp using a hint.
     * @param account account to get the number of active shares for
     * @param timestamp time point to get the number of active shares for the account at
     * @param hint hint for the checkpoint index
     * @return number of active shares for the account at the timestamp
     */
    function activeSharesOfAt(address account, uint48 timestamp, bytes memory hint) external view returns (uint256);

    /**
     * @notice Get a number of active shares for a particular account.
     * @param account account to get the number of active shares for
     * @return number of active shares for the account
     */
    function activeSharesOf(
        address account
    ) external view returns (uint256);

    /**
     * @notice Get a total amount of the withdrawals at a given epoch.
     * @param epoch epoch to get the total amount of the withdrawals at
     * @return total amount of the withdrawals at the epoch
     */
    function withdrawals(
        uint256 epoch
    ) external view returns (uint256);

    /**
     * @notice Get a total number of withdrawal shares at a given epoch.
     * @param epoch epoch to get the total number of withdrawal shares at
     * @return total number of withdrawal shares at the epoch
     */
    function withdrawalShares(
        uint256 epoch
    ) external view returns (uint256);

    /**
     * @notice Get a number of withdrawal shares for a particular account at a given epoch (zero if claimed).
     * @param epoch epoch to get the number of withdrawal shares for the account at
     * @param account account to get the number of withdrawal shares for
     * @return number of withdrawal shares for the account at the epoch
     */
    function withdrawalSharesOf(uint256 epoch, address account) external view returns (uint256);

    /**
     * @notice Get if the withdrawals are claimed for a particular account at a given epoch.
     * @param epoch epoch to check the withdrawals for the account at
     * @param account account to check the withdrawals for
     * @return if the withdrawals are claimed for the account at the epoch
     */
    function isWithdrawalsClaimed(uint256 epoch, address account) external view returns (bool);

    //ex IVault

    /**
     * @notice Check if the vault is fully initialized (a delegator and a slasher are set).
     * @return if the vault is fully initialized
     */
    function isInitialized() external view returns (bool);

    /**
     * @notice Get a total amount of the collateral that can be slashed.
     * @return total amount of the slashable collateral
     */
    function totalStake() external view returns (uint256);

    /**
     * @notice Get an active balance for a particular account at a given timestamp using hints.
     * @param account account to get the active balance for
     * @param timestamp time point to get the active balance for the account at
     * @param hints hints for checkpoints' indexes
     * @return active balance for the account at the timestamp
     */
    function activeBalanceOfAt(
        address account,
        uint48 timestamp,
        bytes calldata hints
    ) external view returns (uint256);

    /**
     * @notice Get an active balance for a particular account.
     * @param account account to get the active balance for
     * @return active balance for the account
     */
    function activeBalanceOf(
        address account
    ) external view returns (uint256);

    /**
     * @notice Get withdrawals for a particular account at a given epoch (zero if claimed).
     * @param epoch epoch to get the withdrawals for the account at
     * @param account account to get the withdrawals for
     * @return withdrawals for the account at the epoch
     */
    function withdrawalsOf(uint256 epoch, address account) external view returns (uint256);

    /**
     * @notice Get a total amount of the collateral that can be slashed for a given account.
     * @param account account to get the slashable collateral for
     * @return total amount of the account's slashable collateral
     */
    function slashableBalanceOf(
        address account
    ) external view returns (uint256);

    /**
     * @notice Deposit collateral into the vault.
     * @param onBehalfOf account the deposit is made on behalf of
     * @param amount amount of the collateral to deposit
     * @return depositedAmount real amount of the collateral deposited
     * @return mintedShares amount of the active shares minted
     */
    function deposit(
        address onBehalfOf,
        uint256 amount
    ) external returns (uint256 depositedAmount, uint256 mintedShares);

    /**
     * @notice Withdraw collateral from the vault (it will be claimable after the next epoch).
     * @param claimer account that needs to claim the withdrawal
     * @param amount amount of the collateral to withdraw
     * @return burnedShares amount of the active shares burned
     * @return mintedShares amount of the epoch withdrawal shares minted
     */
    function withdraw(address claimer, uint256 amount) external returns (uint256 burnedShares, uint256 mintedShares);

    /**
     * @notice Redeem collateral from the vault (it will be claimable after the next epoch).
     * @param claimer account that needs to claim the withdrawal
     * @param shares amount of the active shares to redeem
     * @return withdrawnAssets amount of the collateral withdrawn
     * @return mintedShares amount of the epoch withdrawal shares minted
     */
    function redeem(address claimer, uint256 shares) external returns (uint256 withdrawnAssets, uint256 mintedShares);

    /**
     * @notice Claim collateral from the vault.
     * @param recipient account that receives the collateral
     * @param epoch epoch to claim the collateral for
     * @return amount amount of the collateral claimed
     */
    function claim(address recipient, uint256 epoch) external returns (uint256 amount);

    /**
     * @notice Claim collateral from the vault for multiple epochs.
     * @param recipient account that receives the collateral
     * @param epochs epochs to claim the collateral for
     * @return amount amount of the collateral claimed
     */
    function claimBatch(address recipient, uint256[] calldata epochs) external returns (uint256 amount);

    /**
     * @notice Slash callback for burning collateral.
     * @param amount amount to slash
     * @param captureTimestamp time point when the stake was captured
     * @return slashedAmount real amount of the collateral slashed
     * @dev Only the slasher can call this function.
     */
    function onSlash(uint256 amount, uint48 captureTimestamp) external returns (uint256 slashedAmount);

    /**
     * @notice Enable/disable deposit whitelist.
     * @param status if enabling deposit whitelist
     * @dev Only a DEPOSIT_WHITELIST_SET_ROLE holder can call this function.
     */
    function setDepositWhitelist(
        bool status
    ) external;

    /**
     * @notice Set a depositor whitelist status.
     * @param account account for which the whitelist status is set
     * @param status if whitelisting the account
     * @dev Only a DEPOSITOR_WHITELIST_ROLE holder can call this function.
     */
    function setDepositorWhitelistStatus(address account, bool status) external;

    /**
     * @notice Enable/disable deposit limit.
     * @param status if enabling deposit limit
     * @dev Only a IS_DEPOSIT_LIMIT_SET_ROLE holder can call this function.
     */
    function setIsDepositLimit(
        bool status
    ) external;

    /**
     * @notice Set a deposit limit.
     * @param limit deposit limit (maximum amount of the collateral that can be in the vault simultaneously)
     * @dev Only a DEPOSIT_LIMIT_SET_ROLE holder can call this function.
     */
    function setDepositLimit(
        uint256 limit
    ) external;

    /**
     * @notice Set a delegator.
     * @param delegator vault's delegator to delegate the stake to networks and operators
     * @dev Can be set only once.
     */
    function setDelegator(
        address delegator
    ) external;

    /**
     * @notice Set a slasher.
     * @param slasher vault's slasher to provide a slashing mechanism to networks
     * @dev Can be set only once.
     */
    function setSlasher(
        address slasher
    ) external;

    /**
     * @notice Make a delegatecall from this contract to a given target contract with a particular data (always reverts with a return data).
     * @param target address of the contract to make a delegatecall to
     * @param data data to make a delegatecall with
     * @dev It allows to use this contract's storage on-chain.
     */
    function staticDelegateCall(address target, bytes calldata data) external;
}
