// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";

import {VaultFactory} from "../../src/contracts/VaultFactory.sol";
import {DelegatorFactory} from "../../src/contracts/DelegatorFactory.sol";
import {SlasherFactory} from "../../src/contracts/SlasherFactory.sol";
import {L1Registry} from "../../src/contracts/L1Registry.sol";
import {OperatorRegistry} from "../../src/contracts/OperatorRegistry.sol";
// import {MetadataService} from "../../src/contracts/service/MetadataService.sol";
// import {L1MiddlewareService} from "../../src/contracts/service/L1MiddlewareService.sol";
import {OperatorL1OptInService} from "../../src/contracts/service/OperatorL1OptInService.sol";
import {OperatorVaultOptInService} from "../../src/contracts/service/OperatorVaultOptInService.sol";

import {VaultTokenized} from "../../src/contracts/vault/VaultTokenized.sol";
import {L1RestakeDelegator} from "../../src/contracts/delegator/L1RestakeDelegator.sol";
// import {FullRestakeDelegator} from "../../src/contracts/delegator/FullRestakeDelegator.sol";
// import {OperatorSpecificDelegator} from "../../src/contracts/delegator/OperatorSpecificDelegator.sol";
// import {Slasher} from "../../src/contracts/slasher/Slasher.sol";
// import {VetoSlasher} from "../../src/contracts/slasher/VetoSlasher.sol";

// import {IVault} from "../../src/interfaces/vault/IVaultTokenized.sol";
import {IVaultTokenized} from "../../src/interfaces/vault/IVaultTokenized.sol";

import {Token} from "../mocks/MockToken.sol";
import {MockFeeOnTransferToken} from "../mocks/MockFeeOnTransferToken.sol";

// import {FeeOnTransferToken} from "../mocks/FeeOnTransferToken.sol";
// import {VaultConfigurator} from "../../src/contracts/VaultConfigurator.sol";
// import {IVaultConfigurator} from "../../src/interfaces/IVaultConfigurator.sol";
import {IL1RestakeDelegator} from "../../src/interfaces/delegator/IL1RestakeDelegator.sol";
import {IBaseDelegator} from "../../src/interfaces/delegator/IBaseDelegator.sol";
import {ISlasher} from "../../src/interfaces/slasher/ISlasher.sol";
import {IBaseSlasher} from "../../src/interfaces/slasher/IBaseSlasher.sol";
import {MockVaultTokenizedV2} from "../mocks/MockVaultTokenizedV2.sol";

// import {IVaultTokenized} from "../../src/interfaces/vault/IVaultTokenized.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// import {VaultHints} from "../../src/contracts/hints/VaultHints.sol";
// import {Subl1} from "../../src/contracts/libraries/Subl1.sol";

contract VaultTokenizedTest is Test {
    using Math for uint256;

    address owner;
    address alice;
    uint256 alicePrivateKey;
    address bob;
    uint256 bobPrivateKey;

    VaultFactory vaultFactory;
    DelegatorFactory delegatorFactory;
    SlasherFactory slasherFactory;
    // L1Registry l1Registry;
    // OperatorRegistry operatorRegistry;
    // MetadataService operatorMetadataService;
    // MetadataService l1MetadataService;
    // L1MiddlewareService l1MiddlewareService;
    OperatorVaultOptInService operatorVaultOptInService; // TODO add tests for this
    OperatorL1OptInService operatorL1OptInService; // TODO add tests for this
    L1Registry l1Registry;
    OperatorRegistry operatorRegistry;

    VaultTokenized vault;
    // MigratableEntityProxy proxy;
    Token collateral;
    MockFeeOnTransferToken feeOnTransferCollateral;

    // VaultTokenized vault;
    // FullRestakeDelegator delegator;
    // Slasher slasher;

    function setUp() public {
        owner = address(this);
        (alice, alicePrivateKey) = makeAddrAndKey("alice");
        (bob, bobPrivateKey) = makeAddrAndKey("bob");

        vaultFactory = new VaultFactory(owner);
        delegatorFactory = new DelegatorFactory(owner);
        slasherFactory = new SlasherFactory(owner);
        l1Registry = new L1Registry();
        operatorRegistry = new OperatorRegistry();
        address vaultImpl = address(new VaultTokenized(address(vaultFactory)));
        vaultFactory.whitelist(vaultImpl);

        collateral = new Token("Token");
        feeOnTransferCollateral = new MockFeeOnTransferToken("FeeOnTransferToken");

        // Whitelist L1RestakeDelegator implementation for type = 0
        address l1RestakeDelegatorImpl = address(
            new L1RestakeDelegator(
                address(l1Registry),
                address(vaultFactory),
                address(0), // operatorVaultOptInService
                address(0), // operatorL1OptInService
                address(delegatorFactory),
                delegatorFactory.totalTypes() // ensures correct TYPE indexing
            )
        );
        delegatorFactory.whitelist(l1RestakeDelegatorImpl);
    }

    function test_Create2(
        address burner,
        uint48 epochDuration,
        bool depositWhitelist,
        bool isDepositLimit,
        uint256 depositLimit
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 50 weeks));

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);
        // address new_owner = address(0);
        uint64 lastVersion = vaultFactory.lastVersion();
        address vaultAddress = vaultFactory.create(
            lastVersion,
            bob,
            abi.encode(
                IVaultTokenized.InitParams({
                    collateral: address(collateral),
                    burner: burner,
                    epochDuration: epochDuration,
                    depositWhitelist: depositWhitelist,
                    isDepositLimit: isDepositLimit,
                    depositLimit: depositLimit,
                    defaultAdminRoleHolder: alice,
                    depositWhitelistSetRoleHolder: alice,
                    depositorWhitelistRoleHolder: alice,
                    isDepositLimitSetRoleHolder: alice,
                    depositLimitSetRoleHolder: alice,
                    name: "Test",
                    symbol: "TEST"
                })
            ),
            address(delegatorFactory),
            address(slasherFactory)
        );

        vault = VaultTokenized(vaultAddress);

        assertEq(vault.DEPOSIT_WHITELIST_SET_ROLE(), keccak256("DEPOSIT_WHITELIST_SET_ROLE"));
        assertEq(vault.DEPOSITOR_WHITELIST_ROLE(), keccak256("DEPOSITOR_WHITELIST_ROLE"));
        assertEq(vault.DELEGATOR_FACTORY(), address(delegatorFactory));
        assertEq(vault.SLASHER_FACTORY(), address(slasherFactory));

        assertEq(vault.owner(), bob);
        assertEq(vault.collateral(), address(collateral));
        // assertEq(vault.delegator(), delegator_);
        assertEq(vault.slasher(), address(0));
        assertEq(vault.burner(), burner);
        assertEq(vault.epochDuration(), epochDuration);
        assertEq(vault.depositWhitelist(), depositWhitelist);
        assertEq(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), alice), true);
        assertEq(vault.hasRole(vault.DEPOSITOR_WHITELIST_ROLE(), alice), true);
        assertEq(vault.epochDurationInit(), blockTimestamp);
        assertEq(vault.epochDuration(), epochDuration);
        vm.expectRevert(IVaultTokenized.Vault__InvalidTimestamp.selector);
        assertEq(vault.epochAt(0), 0);
        assertEq(vault.epochAt(uint48(blockTimestamp)), 0);
        assertEq(vault.currentEpoch(), 0);
        assertEq(vault.currentEpochStart(), blockTimestamp);
        vm.expectRevert(IVaultTokenized.Vault__NoPreviousEpoch.selector);
        vault.previousEpochStart();
        assertEq(vault.nextEpochStart(), blockTimestamp + epochDuration);
        assertEq(vault.totalStake(), 0);
        assertEq(vault.activeSharesAt(uint48(blockTimestamp), ""), 0);
        assertEq(vault.activeShares(), 0);
        assertEq(vault.activeStakeAt(uint48(blockTimestamp), ""), 0);
        assertEq(vault.activeStake(), 0);
        assertEq(vault.activeSharesOfAt(alice, uint48(blockTimestamp), ""), 0);
        assertEq(vault.activeSharesOf(alice), 0);
        assertEq(vault.activeBalanceOfAt(alice, uint48(blockTimestamp), ""), 0);
        assertEq(vault.activeBalanceOf(alice), 0);
        assertEq(vault.withdrawals(0), 0);
        assertEq(vault.withdrawalShares(0), 0);
        assertEq(vault.isWithdrawalsClaimed(0, alice), false);
        assertEq(vault.depositWhitelist(), depositWhitelist);
        assertEq(vault.isDepositorWhitelisted(alice), false);
        assertEq(vault.slashableBalanceOf(alice), 0);
        assertEq(vault.isDelegatorInitialized(), false);
        // assertEq(vault.isSlasherInitialized(), true);
        assertEq(vault.isInitialized(), false);

        blockTimestamp = blockTimestamp + vault.epochDuration() - 1;
        vm.warp(blockTimestamp);

        assertEq(vault.epochAt(uint48(blockTimestamp)), 0);
        assertEq(vault.epochAt(uint48(blockTimestamp + 1)), 1);
        assertEq(vault.currentEpoch(), 0);
        assertEq(vault.currentEpochStart(), blockTimestamp - (vault.epochDuration() - 1));
        vm.expectRevert(IVaultTokenized.Vault__NoPreviousEpoch.selector);
        vault.previousEpochStart();
        assertEq(vault.nextEpochStart(), blockTimestamp + 1);

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        assertEq(vault.epochAt(uint48(blockTimestamp)), 1);
        assertEq(vault.epochAt(uint48(blockTimestamp + 2 * vault.epochDuration())), 3);
        assertEq(vault.currentEpoch(), 1);
        assertEq(vault.currentEpochStart(), blockTimestamp);
        assertEq(vault.previousEpochStart(), blockTimestamp - vault.epochDuration());
        assertEq(vault.nextEpochStart(), blockTimestamp + vault.epochDuration());

        blockTimestamp = blockTimestamp + vault.epochDuration() - 1;
        vm.warp(blockTimestamp);

        assertEq(vault.epochAt(uint48(blockTimestamp)), 1);
        assertEq(vault.epochAt(uint48(blockTimestamp + 1)), 2);
        assertEq(vault.currentEpoch(), 1);
        assertEq(vault.currentEpochStart(), blockTimestamp - (vault.epochDuration() - 1));
        assertEq(vault.previousEpochStart(), blockTimestamp - (vault.epochDuration() - 1) - vault.epochDuration());
        assertEq(vault.nextEpochStart(), blockTimestamp + 1);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.allowance(alice, alice), 0);
        assertEq(vault.decimals(), collateral.decimals());
        assertEq(vault.symbol(), "TEST");
        assertEq(vault.name(), "Test");
    }

    function test_CreateRevertInvalidEpochDuration() public {
        uint48 epochDuration = 0;

        address[] memory l1LimitSetRoleHolders = new address[](1);
        l1LimitSetRoleHolders[0] = alice;
        address[] memory operatorL1SharesSetRoleHolders = new address[](1);
        operatorL1SharesSetRoleHolders[0] = alice;
        uint64 lastVersion = vaultFactory.lastVersion();
        vm.expectRevert(IVaultTokenized.Vault__InvalidEpochDuration.selector);
        vaultFactory.create(
            lastVersion,
            alice,
            abi.encode(
                IVaultTokenized.InitParams({
                    collateral: address(collateral),
                    burner: address(0xdEaD),
                    epochDuration: epochDuration,
                    depositWhitelist: false,
                    isDepositLimit: false,
                    depositLimit: 0,
                    defaultAdminRoleHolder: alice,
                    depositWhitelistSetRoleHolder: alice,
                    depositorWhitelistRoleHolder: alice,
                    isDepositLimitSetRoleHolder: alice,
                    depositLimitSetRoleHolder: alice,
                    name: "Test",
                    symbol: "TEST"
                })
            ),
            address(delegatorFactory),
            address(slasherFactory)
        );
    }

    function test_CreateRevertInvalidCollateral(
        uint48 epochDuration
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 50 weeks));

        address[] memory l1LimitSetRoleHolders = new address[](1);
        l1LimitSetRoleHolders[0] = alice;
        address[] memory operatorL1SharesSetRoleHolders = new address[](1);
        operatorL1SharesSetRoleHolders[0] = alice;
        uint64 lastVersion = vaultFactory.lastVersion();
        vm.expectRevert(IVaultTokenized.Vault__InvalidCollateral.selector);
        vaultFactory.create(
            lastVersion,
            alice,
            abi.encode(
                IVaultTokenized.InitParams({
                    collateral: address(0),
                    burner: address(0xdEaD),
                    epochDuration: epochDuration,
                    depositWhitelist: false,
                    isDepositLimit: false,
                    depositLimit: 0,
                    defaultAdminRoleHolder: alice,
                    depositWhitelistSetRoleHolder: alice,
                    depositorWhitelistRoleHolder: alice,
                    isDepositLimitSetRoleHolder: alice,
                    depositLimitSetRoleHolder: alice,
                    name: "Test",
                    symbol: "TEST"
                })
            ),
            address(delegatorFactory),
            address(slasherFactory)
        );
    }

    function test_CreateRevertMissingRoles1(
        uint48 epochDuration
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 50 weeks));

        uint64 lastVersion = vaultFactory.lastVersion();

        vm.expectRevert(IVaultTokenized.Vault__MissingRoles.selector);
        vaultFactory.create(
            lastVersion,
            alice,
            abi.encode(
                IVaultTokenized.InitParams({
                    collateral: address(collateral),
                    burner: address(0xdEaD),
                    epochDuration: epochDuration,
                    depositWhitelist: true,
                    isDepositLimit: false,
                    depositLimit: 0,
                    defaultAdminRoleHolder: address(0),
                    depositWhitelistSetRoleHolder: address(0),
                    depositorWhitelistRoleHolder: address(0),
                    isDepositLimitSetRoleHolder: alice,
                    depositLimitSetRoleHolder: address(0),
                    name: "Test",
                    symbol: "TEST"
                })
            ),
            address(delegatorFactory),
            address(slasherFactory)
        );
    }

    function test_CreateRevertMissingRoles2(
        uint48 epochDuration
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 50 weeks));

        uint64 lastVersion = vaultFactory.lastVersion();

        vm.expectRevert(IVaultTokenized.Vault__MissingRoles.selector);
        vaultFactory.create(
            lastVersion,
            alice,
            abi.encode(
                IVaultTokenized.InitParams({
                    collateral: address(collateral),
                    burner: address(0xdEaD),
                    epochDuration: epochDuration,
                    depositWhitelist: false,
                    isDepositLimit: true,
                    depositLimit: 0,
                    defaultAdminRoleHolder: address(0),
                    depositWhitelistSetRoleHolder: alice,
                    depositorWhitelistRoleHolder: address(0),
                    isDepositLimitSetRoleHolder: address(0),
                    depositLimitSetRoleHolder: address(0),
                    name: "Test",
                    symbol: "TEST"
                })
            ),
            address(delegatorFactory),
            address(slasherFactory)
        );
    }

    function test_CreateRevertMissingRoles3(
        uint48 epochDuration
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 50 weeks));

        uint64 lastVersion = vaultFactory.lastVersion();

        vm.expectRevert(IVaultTokenized.Vault__MissingRoles.selector);
        vaultFactory.create(
            lastVersion,
            alice,
            abi.encode(
                IVaultTokenized.InitParams({
                    collateral: address(collateral),
                    burner: address(0xdEaD),
                    epochDuration: epochDuration,
                    depositWhitelist: false,
                    isDepositLimit: false,
                    depositLimit: 0,
                    defaultAdminRoleHolder: address(0),
                    depositWhitelistSetRoleHolder: alice,
                    depositorWhitelistRoleHolder: address(0),
                    isDepositLimitSetRoleHolder: address(0),
                    depositLimitSetRoleHolder: alice,
                    name: "Test",
                    symbol: "TEST"
                })
            ),
            address(delegatorFactory),
            address(slasherFactory)
        );
    }

    function test_CreateRevertMissingRoles4(
        uint48 epochDuration
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 50 weeks));

        uint64 lastVersion = vaultFactory.lastVersion();

        vm.expectRevert(IVaultTokenized.Vault__MissingRoles.selector);
        vaultFactory.create(
            lastVersion,
            alice,
            abi.encode(
                IVaultTokenized.InitParams({
                    collateral: address(collateral),
                    burner: address(0xdEaD),
                    epochDuration: epochDuration,
                    depositWhitelist: false,
                    isDepositLimit: false,
                    depositLimit: 1,
                    defaultAdminRoleHolder: address(0),
                    depositWhitelistSetRoleHolder: alice,
                    depositorWhitelistRoleHolder: address(0),
                    isDepositLimitSetRoleHolder: address(0),
                    depositLimitSetRoleHolder: address(0),
                    name: "Test",
                    symbol: "TEST"
                })
            ),
            address(delegatorFactory),
            address(slasherFactory)
        );
    }

    function test_CreateRevertMissingRoles5(
        uint48 epochDuration
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 50 weeks));

        uint64 lastVersion = vaultFactory.lastVersion();

        vm.expectRevert(IVaultTokenized.Vault__MissingRoles.selector);
        vaultFactory.create(
            lastVersion,
            alice,
            abi.encode(
                IVaultTokenized.InitParams({
                    collateral: address(collateral),
                    burner: address(0xdEaD),
                    epochDuration: epochDuration,
                    depositWhitelist: false,
                    isDepositLimit: false,
                    depositLimit: 0,
                    defaultAdminRoleHolder: address(0),
                    depositWhitelistSetRoleHolder: address(0),
                    depositorWhitelistRoleHolder: alice,
                    isDepositLimitSetRoleHolder: alice,
                    depositLimitSetRoleHolder: address(0),
                    name: "Test",
                    symbol: "TEST"
                })
            ),
            address(delegatorFactory),
            address(slasherFactory)
        );
    }

    function test_VaultUpgrade() public {
        MockVaultTokenizedV2 mockV2 = new MockVaultTokenizedV2(address(vaultFactory));

        vaultFactory.whitelist(address(mockV2));

        uint64 lastVersion = vaultFactory.lastVersion();
        address vaultToUpgrade = vaultFactory.create(
            lastVersion,
            alice,
            abi.encode(
                IVaultTokenized.InitParams({
                    collateral: address(collateral),
                    burner: address(0xdEaD),
                    epochDuration: 3,
                    depositWhitelist: false,
                    isDepositLimit: false,
                    depositLimit: 1000,
                    defaultAdminRoleHolder: alice,
                    depositWhitelistSetRoleHolder: alice,
                    depositorWhitelistRoleHolder: alice,
                    isDepositLimitSetRoleHolder: alice,
                    depositLimitSetRoleHolder: alice,
                    name: "Test",
                    symbol: "TEST"
                })
            ),
            address(delegatorFactory),
            address(slasherFactory)
        );

        VaultTokenized vaultContract = VaultTokenized(vaultToUpgrade);
        assertEq(vaultContract.version(), 1);

        vm.startPrank(alice);
        uint64 b = 2;
        vaultFactory.migrate(vaultToUpgrade, 2, abi.encode(b));
        vm.stopPrank();

        assertEq(vaultContract.version(), 2);

        // TODO - test further updates and storage changes available in the new version
        MockVaultTokenizedV2 vaultV2 = MockVaultTokenizedV2(vaultToUpgrade);
        assertEq(vaultV2.version2State(), 2);
    }

    function test_SetDelegator() public {
        uint64 lastVersion = vaultFactory.lastVersion();

        vault = VaultTokenized(
            vaultFactory.create(
                lastVersion,
                alice,
                abi.encode(
                    IVaultTokenized.InitParams({
                        collateral: address(collateral),
                        burner: address(0xdEaD),
                        epochDuration: 7 days,
                        depositWhitelist: false,
                        isDepositLimit: false,
                        depositLimit: 0,
                        defaultAdminRoleHolder: alice,
                        depositWhitelistSetRoleHolder: alice,
                        depositorWhitelistRoleHolder: alice,
                        isDepositLimitSetRoleHolder: alice,
                        depositLimitSetRoleHolder: alice,
                        name: "Test",
                        symbol: "TEST"
                    })
                ),
                address(delegatorFactory),
                address(slasherFactory)
            )
        );

        assertEq(vault.isDelegatorInitialized(), false);

        address[] memory l1LimitSetRoleHolders = new address[](1);
        l1LimitSetRoleHolders[0] = alice;
        address[] memory operatorL1SharesSetRoleHolders = new address[](1);
        operatorL1SharesSetRoleHolders[0] = alice;

        // Create L1RestakeDelegator (delegatorIndex = 0)
        L1RestakeDelegator delegator = L1RestakeDelegator(
            delegatorFactory.create(
                0,
                abi.encode(
                    address(vault),
                    abi.encode(
                        IL1RestakeDelegator.InitParams({
                            baseParams: IBaseDelegator.BaseParams({
                                defaultAdminRoleHolder: alice,
                                hook: address(0),
                                hookSetRoleHolder: alice
                            }),
                            l1LimitSetRoleHolders: l1LimitSetRoleHolders,
                            operatorL1SharesSetRoleHolders: operatorL1SharesSetRoleHolders
                        })
                    )
                )
            )
        );

        vault.setDelegator(address(delegator));

        assertEq(vault.delegator(), address(delegator));
        assertEq(vault.isDelegatorInitialized(), true);
        assertEq(vault.isInitialized(), false);
    }

    function test_SetDelegatorRevertDelegatorAlreadyInitialized() public {
        uint64 lastVersion = vaultFactory.lastVersion();

        vault = VaultTokenized(
            vaultFactory.create(
                lastVersion,
                alice,
                abi.encode(
                    IVaultTokenized.InitParams({
                        collateral: address(collateral),
                        burner: address(0xdEaD),
                        epochDuration: 7 days,
                        depositWhitelist: false,
                        isDepositLimit: false,
                        depositLimit: 0,
                        defaultAdminRoleHolder: alice,
                        depositWhitelistSetRoleHolder: alice,
                        depositorWhitelistRoleHolder: alice,
                        isDepositLimitSetRoleHolder: alice,
                        depositLimitSetRoleHolder: alice,
                        name: "Test",
                        symbol: "TEST"
                    })
                ),
                address(delegatorFactory),
                address(slasherFactory)
            )
        );

        address[] memory l1LimitSetRoleHolders = new address[](1);
        l1LimitSetRoleHolders[0] = alice;
        address[] memory operatorL1SharesSetRoleHolders = new address[](1);
        operatorL1SharesSetRoleHolders[0] = alice;

        L1RestakeDelegator delegator = L1RestakeDelegator(
            delegatorFactory.create(
                0,
                abi.encode(
                    address(vault),
                    abi.encode(
                        IL1RestakeDelegator.InitParams({
                            baseParams: IBaseDelegator.BaseParams({
                                defaultAdminRoleHolder: alice,
                                hook: address(0),
                                hookSetRoleHolder: alice
                            }),
                            l1LimitSetRoleHolders: l1LimitSetRoleHolders,
                            operatorL1SharesSetRoleHolders: operatorL1SharesSetRoleHolders
                        })
                    )
                )
            )
        );

        vault.setDelegator(address(delegator));

        vm.expectRevert(IVaultTokenized.Vault__DelegatorAlreadyInitialized.selector);
        vault.setDelegator(address(delegator));
    }

    function test_SetDelegatorRevertNotDelegator() public {
        uint64 lastVersion = vaultFactory.lastVersion();

        vault = VaultTokenized(
            vaultFactory.create(
                lastVersion,
                alice,
                abi.encode(
                    IVaultTokenized.InitParams({
                        collateral: address(collateral),
                        burner: address(0xdEaD),
                        epochDuration: 7 days,
                        depositWhitelist: false,
                        isDepositLimit: false,
                        depositLimit: 0,
                        defaultAdminRoleHolder: alice,
                        depositWhitelistSetRoleHolder: alice,
                        depositorWhitelistRoleHolder: alice,
                        isDepositLimitSetRoleHolder: alice,
                        depositLimitSetRoleHolder: alice,
                        name: "Test",
                        symbol: "TEST"
                    })
                ),
                address(delegatorFactory),
                address(slasherFactory)
            )
        );

        vm.expectRevert(IVaultTokenized.Vault__NotDelegator.selector);
        vault.setDelegator(address(1));
    }

    function test_SetDelegatorRevertInvalidDelegator() public {
        uint64 lastVersion = vaultFactory.lastVersion();

        vault = VaultTokenized(
            vaultFactory.create(
                lastVersion,
                alice,
                abi.encode(
                    IVaultTokenized.InitParams({
                        collateral: address(collateral),
                        burner: address(0xdEaD),
                        epochDuration: 7 days,
                        depositWhitelist: false,
                        isDepositLimit: false,
                        depositLimit: 0,
                        defaultAdminRoleHolder: alice,
                        depositWhitelistSetRoleHolder: alice,
                        depositorWhitelistRoleHolder: alice,
                        isDepositLimitSetRoleHolder: alice,
                        depositLimitSetRoleHolder: alice,
                        name: "Test",
                        symbol: "TEST"
                    })
                ),
                address(delegatorFactory),
                address(slasherFactory)
            )
        );

        VaultTokenized vault2 = VaultTokenized(
            vaultFactory.create(
                lastVersion,
                alice,
                abi.encode(
                    IVaultTokenized.InitParams({
                        collateral: address(collateral),
                        burner: address(0xdEaD),
                        epochDuration: 7 days,
                        depositWhitelist: false,
                        isDepositLimit: false,
                        depositLimit: 0,
                        defaultAdminRoleHolder: alice,
                        depositWhitelistSetRoleHolder: alice,
                        depositorWhitelistRoleHolder: alice,
                        isDepositLimitSetRoleHolder: alice,
                        depositLimitSetRoleHolder: alice,
                        name: "Test",
                        symbol: "TEST"
                    })
                ),
                address(delegatorFactory),
                address(slasherFactory)
            )
        );

        address[] memory l1LimitSetRoleHolders = new address[](1);
        l1LimitSetRoleHolders[0] = alice;
        address[] memory operatorL1SharesSetRoleHolders = new address[](1);
        operatorL1SharesSetRoleHolders[0] = alice;

        // Create a delegator bound to vault2
        L1RestakeDelegator delegator = L1RestakeDelegator(
            delegatorFactory.create(
                0,
                abi.encode(
                    address(vault2),
                    abi.encode(
                        IL1RestakeDelegator.InitParams({
                            baseParams: IBaseDelegator.BaseParams({
                                defaultAdminRoleHolder: alice,
                                hook: address(0),
                                hookSetRoleHolder: alice
                            }),
                            l1LimitSetRoleHolders: l1LimitSetRoleHolders,
                            operatorL1SharesSetRoleHolders: operatorL1SharesSetRoleHolders
                        })
                    )
                )
            )
        );

        // Trying to set a delegator that belongs to another vault
        vm.expectRevert(IVaultTokenized.Vault__InvalidDelegator.selector);
        vault.setDelegator(address(delegator));
    }

    // function test_SetDelegator() public {
    //     uint64 lastVersion = vaultFactory.lastVersion();

    //     vault = VaultTokenized(
    //         vaultFactory.create(
    //             lastVersion,
    //             alice,
    //             abi.encode(
    //                 IVaultTokenized.InitParamsTokenized({
    //                     baseParams: IVaultTokenized.InitParams({
    //                         collateral: address(collateral),
    //                         burner: address(0xdEaD),
    //                         epochDuration: 7 days,
    //                         depositWhitelist: false,
    //                         isDepositLimit: false,
    //                         depositLimit: 0,
    //                         defaultAdminRoleHolder: alice,
    //                         depositWhitelistSetRoleHolder: alice,
    //                         depositorWhitelistRoleHolder: alice,
    //                         isDepositLimitSetRoleHolder: alice,
    //                         depositLimitSetRoleHolder: alice,
    //                         name: "Test",
    //                         symbol: "TEST"
    //                     })
    //                 })
    //             )
    //         )
    //     );

    //     assertEq(vault.isDelegatorInitialized(), false);

    //     address[] memory l1LimitSetRoleHolders = new address[](1);
    //     l1LimitSetRoleHolders[0] = alice;
    //     address[] memory operatorL1LimitSetRoleHolders = new address[](1);
    //     operatorL1LimitSetRoleHolders[0] = alice;
    //     delegator = FullRestakeDelegator(
    //         delegatorFactory.create(
    //             1,
    //             abi.encode(
    //                 address(vault),
    //                 abi.encode(
    //                     IFullRestakeDelegator.InitParams({
    //                         baseParams: IBaseDelegator.BaseParams({
    //                             defaultAdminRoleHolder: alice,
    //                             hook: address(0),
    //                             hookSetRoleHolder: alice
    //                         }),
    //                         l1LimitSetRoleHolders: l1LimitSetRoleHolders,
    //                         operatorL1LimitSetRoleHolders: operatorL1LimitSetRoleHolders
    //                     })
    //                 )
    //             )
    //         )
    //     );

    //     vault.setDelegator(address(delegator));

    //     assertEq(vault.delegator(), address(delegator));
    //     assertEq(vault.isDelegatorInitialized(), true);
    //     assertEq(vault.isInitialized(), false);
    // }

    // function test_SetDelegatorRevertDelegatorAlreadyInitialized() public {
    //     uint64 lastVersion = vaultFactory.lastVersion();

    //     vault = VaultTokenized(
    //         vaultFactory.create(
    //             lastVersion,
    //             alice,
    //             abi.encode(
    //                 IVaultTokenized.InitParamsTokenized({
    //                     baseParams: IVaultTokenized.InitParams({
    //                         collateral: address(collateral),
    //                         burner: address(0xdEaD),
    //                         epochDuration: 7 days,
    //                         depositWhitelist: false,
    //                         isDepositLimit: false,
    //                         depositLimit: 0,
    //                         defaultAdminRoleHolder: alice,
    //                         depositWhitelistSetRoleHolder: alice,
    //                         depositorWhitelistRoleHolder: alice,
    //                         isDepositLimitSetRoleHolder: alice,
    //                         depositLimitSetRoleHolder: alice
    //                     }),
    //                     name: "Test",
    //                     symbol: "TEST"
    //                 })
    //             )
    //         )
    //     );

    //     address[] memory l1LimitSetRoleHolders = new address[](1);
    //     l1LimitSetRoleHolders[0] = alice;
    //     address[] memory operatorL1LimitSetRoleHolders = new address[](1);
    //     operatorL1LimitSetRoleHolders[0] = alice;
    //     delegator = FullRestakeDelegator(
    //         delegatorFactory.create(
    //             1,
    //             abi.encode(
    //                 address(vault),
    //                 abi.encode(
    //                     IFullRestakeDelegator.InitParams({
    //                         baseParams: IBaseDelegator.BaseParams({
    //                             defaultAdminRoleHolder: alice,
    //                             hook: address(0),
    //                             hookSetRoleHolder: alice
    //                         }),
    //                         l1LimitSetRoleHolders: l1LimitSetRoleHolders,
    //                         operatorL1LimitSetRoleHolders: operatorL1LimitSetRoleHolders
    //                     })
    //                 )
    //             )
    //         )
    //     );

    //     vault.setDelegator(address(delegator));

    //     vm.expectRevert(IVaultTokenized.Vault__DelegatorAlreadyInitialized.selector);
    //     vault.setDelegator(address(delegator));
    // }

    // function test_SetDelegatorRevertNotDelegator() public {
    //     uint64 lastVersion = vaultFactory.lastVersion();

    //     vault = VaultTokenized(
    //         vaultFactory.create(
    //             lastVersion,
    //             alice,
    //             abi.encode(
    //                 IVaultTokenized.InitParamsTokenized({
    //                     baseParams: IVaultTokenized.InitParams({
    //                         collateral: address(collateral),
    //                         burner: address(0xdEaD),
    //                         epochDuration: 7 days,
    //                         depositWhitelist: false,
    //                         isDepositLimit: false,
    //                         depositLimit: 0,
    //                         defaultAdminRoleHolder: alice,
    //                         depositWhitelistSetRoleHolder: alice,
    //                         depositorWhitelistRoleHolder: alice,
    //                         isDepositLimitSetRoleHolder: alice,
    //                         depositLimitSetRoleHolder: alice
    //                     }),
    //                     name: "Test",
    //                     symbol: "TEST"
    //                 })
    //             )
    //         )
    //     );

    //     vm.expectRevert(IVaultTokenized.Vault__NotDelegator.selector);
    //     vault.setDelegator(address(1));
    // }

    // function test_SetDelegatorRevertInvalidDelegator() public {
    //     uint64 lastVersion = vaultFactory.lastVersion();

    //     vault = VaultTokenized(
    //         vaultFactory.create(
    //             lastVersion,
    //             alice,
    //             abi.encode(
    //                 IVaultTokenized.InitParamsTokenized({
    //                     baseParams: IVaultTokenized.InitParams({
    //                         collateral: address(collateral),
    //                         burner: address(0xdEaD),
    //                         epochDuration: 7 days,
    //                         depositWhitelist: false,
    //                         isDepositLimit: false,
    //                         depositLimit: 0,
    //                         defaultAdminRoleHolder: alice,
    //                         depositWhitelistSetRoleHolder: alice,
    //                         depositorWhitelistRoleHolder: alice,
    //                         isDepositLimitSetRoleHolder: alice,
    //                         depositLimitSetRoleHolder: alice
    //                     }),
    //                     name: "Test",
    //                     symbol: "TEST"
    //                 })
    //             )
    //         )
    //     );

    //     VaultTokenized vault2 = VaultTokenized(
    //         vaultFactory.create(
    //             lastVersion,
    //             alice,
    //             abi.encode(
    //                 IVaultTokenized.InitParamsTokenized({
    //                     baseParams: IVaultTokenized.InitParams({
    //                         collateral: address(collateral),
    //                         burner: address(0xdEaD),
    //                         epochDuration: 7 days,
    //                         depositWhitelist: false,
    //                         isDepositLimit: false,
    //                         depositLimit: 0,
    //                         defaultAdminRoleHolder: alice,
    //                         depositWhitelistSetRoleHolder: alice,
    //                         depositorWhitelistRoleHolder: alice,
    //                         isDepositLimitSetRoleHolder: alice,
    //                         depositLimitSetRoleHolder: alice
    //                     }),
    //                     name: "Test",
    //                     symbol: "TEST"
    //                 })
    //             )
    //         )
    //     );

    //     address[] memory l1LimitSetRoleHolders = new address[](1);
    //     l1LimitSetRoleHolders[0] = alice;
    //     address[] memory operatorL1LimitSetRoleHolders = new address[](1);
    //     operatorL1LimitSetRoleHolders[0] = alice;
    //     delegator = FullRestakeDelegator(
    //         delegatorFactory.create(
    //             1,
    //             abi.encode(
    //                 address(vault2),
    //                 abi.encode(
    //                     IFullRestakeDelegator.InitParams({
    //                         baseParams: IBaseDelegator.BaseParams({
    //                             defaultAdminRoleHolder: alice,
    //                             hook: address(0),
    //                             hookSetRoleHolder: alice
    //                         }),
    //                         l1LimitSetRoleHolders: l1LimitSetRoleHolders,
    //                         operatorL1LimitSetRoleHolders: operatorL1LimitSetRoleHolders
    //                     })
    //                 )
    //             )
    //         )
    //     );

    //     vm.expectRevert(IVaultTokenized.Vault__InvalidDelegator.selector);
    //     vault.setDelegator(address(delegator));
    // }

    // function test_SetSlasher() public {
    //     uint64 lastVersion = vaultFactory.lastVersion();

    //     vault = VaultTokenized(
    //         vaultFactory.create(
    //             lastVersion,
    //             alice,
    //             abi.encode(
    //                 IVaultTokenized.InitParamsTokenized({
    //                     baseParams: IVaultTokenized.InitParams({
    //                         collateral: address(collateral),
    //                         burner: address(0xdEaD),
    //                         epochDuration: 7 days,
    //                         depositWhitelist: false,
    //                         isDepositLimit: false,
    //                         depositLimit: 0,
    //                         defaultAdminRoleHolder: alice,
    //                         depositWhitelistSetRoleHolder: alice,
    //                         depositorWhitelistRoleHolder: alice,
    //                         isDepositLimitSetRoleHolder: alice,
    //                         depositLimitSetRoleHolder: alice
    //                     }),
    //                     name: "Test",
    //                     symbol: "TEST"
    //                 })
    //             )
    //         )
    //     );

    //     assertEq(vault.isSlasherInitialized(), false);

    //     slasher = Slasher(
    //         slasherFactory.create(
    //             0,
    //             abi.encode(
    //                 address(vault),
    //                 abi.encode(ISlasher.InitParams({baseParams: IBaseSlasher.BaseParams({isBurnerHook: false})}))
    //             )
    //         )
    //     );

    //     vault.setSlasher(address(slasher));

    //     assertEq(vault.slasher(), address(slasher));
    //     assertEq(vault.isSlasherInitialized(), true);
    //     assertEq(vault.isInitialized(), false);
    // }

    // function test_SetSlasherRevertSlasherAlreadyInitialized() public {
    //     uint64 lastVersion = vaultFactory.lastVersion();

    //     vault = VaultTokenized(
    //         vaultFactory.create(
    //             lastVersion,
    //             alice,
    //             abi.encode(
    //                 IVaultTokenized.InitParamsTokenized({
    //                     baseParams: IVaultTokenized.InitParams({
    //                         collateral: address(collateral),
    //                         burner: address(0xdEaD),
    //                         epochDuration: 7 days,
    //                         depositWhitelist: false,
    //                         isDepositLimit: false,
    //                         depositLimit: 0,
    //                         defaultAdminRoleHolder: alice,
    //                         depositWhitelistSetRoleHolder: alice,
    //                         depositorWhitelistRoleHolder: alice,
    //                         isDepositLimitSetRoleHolder: alice,
    //                         depositLimitSetRoleHolder: alice
    //                     }),
    //                     name: "Test",
    //                     symbol: "TEST"
    //                 })
    //             )
    //         )
    //     );

    //     slasher = Slasher(
    //         slasherFactory.create(
    //             0,
    //             abi.encode(
    //                 address(vault),
    //                 abi.encode(ISlasher.InitParams({baseParams: IBaseSlasher.BaseParams({isBurnerHook: false})}))
    //             )
    //         )
    //     );

    //     vault.setSlasher(address(slasher));

    //     vm.expectRevert(IVaultTokenized.Vault__SlasherAlreadyInitialized.selector);
    //     vault.setSlasher(address(slasher));
    // }

    // function test_SetSlasherRevertNotSlasher() public {
    //     uint64 lastVersion = vaultFactory.lastVersion();

    //     vault = VaultTokenized(
    //         vaultFactory.create(
    //             lastVersion,
    //             alice,
    //             abi.encode(
    //                 IVaultTokenized.InitParamsTokenized({
    //                     baseParams: IVaultTokenized.InitParams({
    //                         collateral: address(collateral),
    //                         burner: address(0xdEaD),
    //                         epochDuration: 7 days,
    //                         depositWhitelist: false,
    //                         isDepositLimit: false,
    //                         depositLimit: 0,
    //                         defaultAdminRoleHolder: alice,
    //                         depositWhitelistSetRoleHolder: alice,
    //                         depositorWhitelistRoleHolder: alice,
    //                         isDepositLimitSetRoleHolder: alice,
    //                         depositLimitSetRoleHolder: alice
    //                     }),
    //                     name: "Test",
    //                     symbol: "TEST"
    //                 })
    //             )
    //         )
    //     );

    //     slasher = Slasher(
    //         slasherFactory.create(
    //             0,
    //             abi.encode(
    //                 address(vault),
    //                 abi.encode(ISlasher.InitParams({baseParams: IBaseSlasher.BaseParams({isBurnerHook: false})}))
    //             )
    //         )
    //     );

    //     vm.expectRevert(IVaultTokenized.Vault__NotSlasher.selector);
    //     vault.setSlasher(address(1));
    // }

    // function test_SetSlasherRevertInvalidSlasher() public {
    //     uint64 lastVersion = vaultFactory.lastVersion();

    //     vault = VaultTokenized(
    //         vaultFactory.create(
    //             lastVersion,
    //             alice,
    //             abi.encode(
    //                 IVaultTokenized.InitParamsTokenized({
    //                     baseParams: IVaultTokenized.InitParams({
    //                         collateral: address(collateral),
    //                         burner: address(0xdEaD),
    //                         epochDuration: 7 days,
    //                         depositWhitelist: false,
    //                         isDepositLimit: false,
    //                         depositLimit: 0,
    //                         defaultAdminRoleHolder: alice,
    //                         depositWhitelistSetRoleHolder: alice,
    //                         depositorWhitelistRoleHolder: alice,
    //                         isDepositLimitSetRoleHolder: alice,
    //                         depositLimitSetRoleHolder: alice
    //                     }),
    //                     name: "Test",
    //                     symbol: "TEST"
    //                 })
    //             )
    //         )
    //     );

    //     VaultTokenized vault2 = VaultTokenized(
    //         vaultFactory.create(
    //             lastVersion,
    //             alice,
    //             abi.encode(
    //                 IVaultTokenized.InitParamsTokenized({
    //                     baseParams: IVaultTokenized.InitParams({
    //                         collateral: address(collateral),
    //                         burner: address(0xdEaD),
    //                         epochDuration: 7 days,
    //                         depositWhitelist: false,
    //                         isDepositLimit: false,
    //                         depositLimit: 0,
    //                         defaultAdminRoleHolder: alice,
    //                         depositWhitelistSetRoleHolder: alice,
    //                         depositorWhitelistRoleHolder: alice,
    //                         isDepositLimitSetRoleHolder: alice,
    //                         depositLimitSetRoleHolder: alice
    //                     }),
    //                     name: "Test",
    //                     symbol: "TEST"
    //                 })
    //             )
    //         )
    //     );

    //     slasher = Slasher(
    //         slasherFactory.create(
    //             0,
    //             abi.encode(
    //                 address(vault2),
    //                 abi.encode(ISlasher.InitParams({baseParams: IBaseSlasher.BaseParams({isBurnerHook: false})}))
    //             )
    //         )
    //     );

    //     vm.expectRevert(IVaultTokenized.Vault__InvalidSlasher.selector);
    //     vault.setSlasher(address(slasher));
    // }

    // function test_SetSlasherZeroAddress() public {
    //     uint64 lastVersion = vaultFactory.lastVersion();

    //     vault = VaultTokenized(
    //         vaultFactory.create(
    //             lastVersion,
    //             alice,
    //             abi.encode(
    //                 IVaultTokenized.InitParamsTokenized({
    //                     baseParams: IVaultTokenized.InitParams({
    //                         collateral: address(collateral),
    //                         burner: address(0xdEaD),
    //                         epochDuration: 7 days,
    //                         depositWhitelist: false,
    //                         isDepositLimit: false,
    //                         depositLimit: 0,
    //                         defaultAdminRoleHolder: alice,
    //                         depositWhitelistSetRoleHolder: alice,
    //                         depositorWhitelistRoleHolder: alice,
    //                         isDepositLimitSetRoleHolder: alice,
    //                         depositLimitSetRoleHolder: alice
    //                     }),
    //                     name: "Test",
    //                     symbol: "TEST"
    //                 })
    //             )
    //         )
    //     );

    //     vault.setSlasher(address(0));
    // }

    function test_DepositTwice(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 1, 100 * 10 ** 18);
        amount2 = bound(amount2, 1, 100 * 10 ** 18);

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        uint48 epochDuration = 1;
        vault = _getVault(epochDuration);

        uint256 tokensBefore = collateral.balanceOf(address(vault));
        uint256 shares1 = amount1 * 10 ** 0;
        {
            (uint256 depositedAmount, uint256 mintedShares) = _deposit(alice, amount1);
            assertEq(depositedAmount, amount1);
            assertEq(mintedShares, shares1);

            assertEq(vault.balanceOf(alice), shares1);
            assertEq(vault.totalSupply(), shares1);
        }
        assertEq(collateral.balanceOf(address(vault)) - tokensBefore, amount1);

        assertEq(vault.totalStake(), amount1);
        assertEq(vault.activeSharesAt(uint48(blockTimestamp - 1), ""), 0);
        assertEq(vault.activeSharesAt(uint48(blockTimestamp), ""), shares1);
        assertEq(vault.activeShares(), shares1);
        assertEq(vault.activeStakeAt(uint48(blockTimestamp - 1), ""), 0);
        assertEq(vault.activeStakeAt(uint48(blockTimestamp), ""), amount1);
        assertEq(vault.activeStake(), amount1);
        assertEq(vault.activeSharesOfAt(alice, uint48(blockTimestamp - 1), ""), 0);
        assertEq(vault.activeSharesOfAt(alice, uint48(blockTimestamp), ""), shares1);
        assertEq(vault.activeSharesOf(alice), shares1);
        assertEq(vault.activeBalanceOfAt(alice, uint48(blockTimestamp - 1), ""), 0);
        assertEq(vault.activeBalanceOfAt(alice, uint48(blockTimestamp), ""), amount1);
        assertEq(vault.activeBalanceOf(alice), amount1);
        assertEq(vault.slashableBalanceOf(alice), amount1);

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        uint256 shares2 = amount2 * (shares1 + 10 ** 0) / (amount1 + 1);
        {
            (uint256 depositedAmount, uint256 mintedShares) = _deposit(alice, amount2);
            assertEq(depositedAmount, amount2);
            assertEq(mintedShares, shares2);

            assertEq(vault.balanceOf(alice), shares1 + shares2);
            assertEq(vault.totalSupply(), shares1 + shares2);
        }

        assertEq(vault.totalStake(), amount1 + amount2);
        assertEq(vault.activeSharesAt(uint48(blockTimestamp - 1), ""), shares1);
        assertEq(vault.activeSharesAt(uint48(blockTimestamp), ""), shares1 + shares2);
        assertEq(vault.activeShares(), shares1 + shares2);
        uint256 gasLeft = gasleft();
        assertEq(vault.activeSharesAt(uint48(blockTimestamp - 1), abi.encode(1)), shares1);
        uint256 gasSpent = gasLeft - gasleft();
        gasLeft = gasleft();
        assertEq(vault.activeSharesAt(uint48(blockTimestamp - 1), abi.encode(0)), shares1);
        assertGt(gasSpent, gasLeft - gasleft());
        gasLeft = gasleft();
        assertEq(vault.activeSharesAt(uint48(blockTimestamp), abi.encode(0)), shares1 + shares2);
        gasSpent = gasLeft - gasleft();
        gasLeft = gasleft();
        assertEq(vault.activeSharesAt(uint48(blockTimestamp), abi.encode(1)), shares1 + shares2);
        assertGt(gasSpent, gasLeft - gasleft());
        assertEq(vault.activeStakeAt(uint48(blockTimestamp - 1), ""), amount1);
        assertEq(vault.activeStakeAt(uint48(blockTimestamp), ""), amount1 + amount2);
        assertEq(vault.activeStake(), amount1 + amount2);
        gasLeft = gasleft();
        assertEq(vault.activeStakeAt(uint48(blockTimestamp - 1), abi.encode(1)), amount1);
        gasSpent = gasLeft - gasleft();
        gasLeft = gasleft();
        assertEq(vault.activeStakeAt(uint48(blockTimestamp - 1), abi.encode(0)), amount1);
        assertGt(gasSpent, gasLeft - gasleft());
        gasLeft = gasleft();
        assertEq(vault.activeStakeAt(uint48(blockTimestamp), abi.encode(0)), amount1 + amount2);
        gasSpent = gasLeft - gasleft();
        gasLeft = gasleft();
        assertEq(vault.activeStakeAt(uint48(blockTimestamp), abi.encode(1)), amount1 + amount2);
        assertGt(gasSpent, gasLeft - gasleft());
        assertEq(vault.activeStakeAt(uint48(blockTimestamp - 1), ""), shares1);
        assertEq(vault.activeStakeAt(uint48(blockTimestamp), ""), shares1 + shares2);
        assertEq(vault.activeSharesOf(alice), shares1 + shares2);
        gasLeft = gasleft();
        assertEq(vault.activeSharesOfAt(alice, uint48(blockTimestamp - 1), abi.encode(1)), shares1);
        gasSpent = gasLeft - gasleft();
        gasLeft = gasleft();
        assertEq(vault.activeSharesOfAt(alice, uint48(blockTimestamp - 1), abi.encode(0)), shares1);
        assertGt(gasSpent, gasLeft - gasleft());
        gasLeft = gasleft();
        assertEq(vault.activeSharesOfAt(alice, uint48(blockTimestamp), abi.encode(0)), shares1 + shares2);
        gasSpent = gasLeft - gasleft();
        gasLeft = gasleft();
        assertEq(vault.activeSharesOfAt(alice, uint48(blockTimestamp), abi.encode(1)), shares1 + shares2);
        assertGt(gasSpent, gasLeft - gasleft());
        assertEq(vault.activeBalanceOfAt(alice, uint48(blockTimestamp - 1), ""), amount1);
        assertEq(vault.activeBalanceOfAt(alice, uint48(blockTimestamp), ""), amount1 + amount2);
        assertEq(vault.activeBalanceOf(alice), amount1 + amount2);
        assertEq(vault.slashableBalanceOf(alice), amount1 + amount2);
        gasLeft = gasleft();
        assertEq(
            vault.activeBalanceOfAt(
                alice,
                uint48(blockTimestamp - 1),
                abi.encode(
                    IVaultTokenized.ActiveBalanceOfHints({
                        activeSharesOfHint: abi.encode(1),
                        activeStakeHint: abi.encode(1),
                        activeSharesHint: abi.encode(1)
                    })
                )
            ),
            amount1
        );
        gasSpent = gasLeft - gasleft();
        gasLeft = gasleft();
        assertEq(
            vault.activeBalanceOfAt(
                alice,
                uint48(blockTimestamp - 1),
                abi.encode(
                    IVaultTokenized.ActiveBalanceOfHints({
                        activeSharesOfHint: abi.encode(0),
                        activeStakeHint: abi.encode(0),
                        activeSharesHint: abi.encode(0)
                    })
                )
            ),
            amount1
        );
        assertGt(gasSpent, gasLeft - gasleft());
        gasLeft = gasleft();
        assertEq(
            vault.activeBalanceOfAt(
                alice,
                uint48(blockTimestamp),
                abi.encode(
                    IVaultTokenized.ActiveBalanceOfHints({
                        activeSharesOfHint: abi.encode(0),
                        activeStakeHint: abi.encode(0),
                        activeSharesHint: abi.encode(0)
                    })
                )
            ),
            amount1 + amount2
        );
        gasSpent = gasLeft - gasleft();
        gasLeft = gasleft();
        assertEq(
            vault.activeBalanceOfAt(
                alice,
                uint48(blockTimestamp),
                abi.encode(
                    IVaultTokenized.ActiveBalanceOfHints({
                        activeSharesOfHint: abi.encode(1),
                        activeStakeHint: abi.encode(1),
                        activeSharesHint: abi.encode(1)
                    })
                )
            ),
            amount1 + amount2
        );
        assertGt(gasSpent, gasLeft - gasleft());
    }

    function test_DepositTwiceFeeOnTransferCollateral(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 2, 100 * 10 ** 18);
        amount2 = bound(amount2, 2, 100 * 10 ** 18);

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        uint48 epochDuration = 1;
        {
            address[] memory l1LimitSetRoleHolders = new address[](1);
            l1LimitSetRoleHolders[0] = alice;
            address[] memory operatorL1SharesSetRoleHolders = new address[](1);
            operatorL1SharesSetRoleHolders[0] = alice;
            uint64 lastVersion = vaultFactory.lastVersion();
            address vaultAddress = vaultFactory.create(
                lastVersion,
                alice,
                abi.encode(
                    IVaultTokenized.InitParams({
                        collateral: address(feeOnTransferCollateral),
                        burner: address(0xdEaD),
                        epochDuration: epochDuration,
                        depositWhitelist: false,
                        isDepositLimit: false,
                        depositLimit: 0,
                        defaultAdminRoleHolder: alice,
                        depositWhitelistSetRoleHolder: alice,
                        depositorWhitelistRoleHolder: alice,
                        isDepositLimitSetRoleHolder: alice,
                        depositLimitSetRoleHolder: alice,
                        name: "Test",
                        symbol: "TEST"
                    })
                ),
                address(delegatorFactory),
                address(slasherFactory)
            );

            vault = VaultTokenized(vaultAddress);
        }

        uint256 tokensBefore = feeOnTransferCollateral.balanceOf(address(vault));
        uint256 shares1 = (amount1 - 1) * 10 ** 0;
        feeOnTransferCollateral.transfer(alice, amount1 + 1);
        vm.startPrank(alice);
        feeOnTransferCollateral.approve(address(vault), amount1);

        {
            (uint256 depositedAmount, uint256 mintedShares) = vault.deposit(alice, amount1);
            assertEq(depositedAmount, amount1 - 1);
            assertEq(mintedShares, shares1);
        }
        vm.stopPrank();
        assertEq(feeOnTransferCollateral.balanceOf(address(vault)) - tokensBefore, amount1 - 1);

        assertEq(vault.totalStake(), amount1 - 1);
        assertEq(vault.activeSharesAt(uint48(blockTimestamp - 1), ""), 0);
        assertEq(vault.activeSharesAt(uint48(blockTimestamp), ""), shares1);
        assertEq(vault.activeShares(), shares1);
        assertEq(vault.activeStakeAt(uint48(blockTimestamp - 1), ""), 0);
        assertEq(vault.activeStakeAt(uint48(blockTimestamp), ""), amount1 - 1);
        assertEq(vault.activeStake(), amount1 - 1);
        assertEq(vault.activeSharesOfAt(alice, uint48(blockTimestamp - 1), ""), 0);
        assertEq(vault.activeSharesOfAt(alice, uint48(blockTimestamp), ""), shares1);
        assertEq(vault.activeSharesOf(alice), shares1);
        assertEq(vault.activeBalanceOfAt(alice, uint48(blockTimestamp - 1), ""), 0);
        assertEq(vault.activeBalanceOfAt(alice, uint48(blockTimestamp), ""), amount1 - 1);
        assertEq(vault.activeBalanceOf(alice), amount1 - 1);
        assertEq(vault.slashableBalanceOf(alice), amount1 - 1);

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        uint256 shares2 = (amount2 - 1) * (shares1 + 10 ** 0) / (amount1 - 1 + 1);
        feeOnTransferCollateral.transfer(alice, amount2 + 1);
        vm.startPrank(alice);
        feeOnTransferCollateral.approve(address(vault), amount2);
        {
            (uint256 depositedAmount, uint256 mintedShares) = vault.deposit(alice, amount2);
            assertEq(depositedAmount, amount2 - 1);
            assertEq(mintedShares, shares2);
        }
        vm.stopPrank();

        assertEq(vault.totalStake(), amount1 - 1 + amount2 - 1);
        assertEq(vault.activeSharesAt(uint48(blockTimestamp - 1), ""), shares1);
        assertEq(vault.activeSharesAt(uint48(blockTimestamp), ""), shares1 + shares2);
        assertEq(vault.activeShares(), shares1 + shares2);
        uint256 gasLeft = gasleft();
        assertEq(vault.activeSharesAt(uint48(blockTimestamp - 1), abi.encode(1)), shares1);
        uint256 gasSpent = gasLeft - gasleft();
        gasLeft = gasleft();
        assertEq(vault.activeSharesAt(uint48(blockTimestamp - 1), abi.encode(0)), shares1);
        assertGt(gasSpent, gasLeft - gasleft());
        gasLeft = gasleft();
        assertEq(vault.activeSharesAt(uint48(blockTimestamp), abi.encode(0)), shares1 + shares2);
        gasSpent = gasLeft - gasleft();
        gasLeft = gasleft();
        assertEq(vault.activeSharesAt(uint48(blockTimestamp), abi.encode(1)), shares1 + shares2);
        assertGt(gasSpent, gasLeft - gasleft());
        assertEq(vault.activeStakeAt(uint48(blockTimestamp - 1), ""), amount1 - 1);
        assertEq(vault.activeStakeAt(uint48(blockTimestamp), ""), amount1 - 1 + amount2 - 1);
        assertEq(vault.activeStake(), amount1 - 1 + amount2 - 1);
        gasLeft = gasleft();
        assertEq(vault.activeStakeAt(uint48(blockTimestamp - 1), abi.encode(1)), amount1 - 1);
        gasSpent = gasLeft - gasleft();
        gasLeft = gasleft();
        assertEq(vault.activeStakeAt(uint48(blockTimestamp - 1), abi.encode(0)), amount1 - 1);
        assertGt(gasSpent, gasLeft - gasleft());
        gasLeft = gasleft();
        assertEq(vault.activeStakeAt(uint48(blockTimestamp), abi.encode(0)), amount1 - 1 + amount2 - 1);
        gasSpent = gasLeft - gasleft();
        gasLeft = gasleft();
        assertEq(vault.activeStakeAt(uint48(blockTimestamp), abi.encode(1)), amount1 - 1 + amount2 - 1);
        assertGt(gasSpent, gasLeft - gasleft());
        assertEq(vault.activeStakeAt(uint48(blockTimestamp - 1), ""), shares1);
        assertEq(vault.activeStakeAt(uint48(blockTimestamp), ""), shares1 + shares2);
        assertEq(vault.activeSharesOf(alice), shares1 + shares2);
        gasLeft = gasleft();
        assertEq(vault.activeSharesOfAt(alice, uint48(blockTimestamp - 1), abi.encode(1)), shares1);
        gasSpent = gasLeft - gasleft();
        gasLeft = gasleft();
        assertEq(vault.activeSharesOfAt(alice, uint48(blockTimestamp - 1), abi.encode(0)), shares1);
        assertGt(gasSpent, gasLeft - gasleft());
        gasLeft = gasleft();
        assertEq(vault.activeSharesOfAt(alice, uint48(blockTimestamp), abi.encode(0)), shares1 + shares2);
        gasSpent = gasLeft - gasleft();
        gasLeft = gasleft();
        assertEq(vault.activeSharesOfAt(alice, uint48(blockTimestamp), abi.encode(1)), shares1 + shares2);
        assertGt(gasSpent, gasLeft - gasleft());
        assertEq(vault.activeBalanceOfAt(alice, uint48(blockTimestamp - 1), ""), amount1 - 1);
        assertEq(vault.activeBalanceOfAt(alice, uint48(blockTimestamp), ""), amount1 - 1 + amount2 - 1);
        assertEq(vault.activeBalanceOf(alice), amount1 - 1 + amount2 - 1);
        assertEq(vault.slashableBalanceOf(alice), amount1 - 1 + amount2 - 1);
        gasLeft = gasleft();
        assertEq(
            vault.activeBalanceOfAt(
                alice,
                uint48(blockTimestamp - 1),
                abi.encode(
                    IVaultTokenized.ActiveBalanceOfHints({
                        activeSharesOfHint: abi.encode(1),
                        activeStakeHint: abi.encode(1),
                        activeSharesHint: abi.encode(1)
                    })
                )
            ),
            amount1 - 1
        );
        gasSpent = gasLeft - gasleft();
        gasLeft = gasleft();
        assertEq(
            vault.activeBalanceOfAt(
                alice,
                uint48(blockTimestamp - 1),
                abi.encode(
                    IVaultTokenized.ActiveBalanceOfHints({
                        activeSharesOfHint: abi.encode(0),
                        activeStakeHint: abi.encode(0),
                        activeSharesHint: abi.encode(0)
                    })
                )
            ),
            amount1 - 1
        );
        assertGt(gasSpent, gasLeft - gasleft());
        gasLeft = gasleft();
        assertEq(
            vault.activeBalanceOfAt(
                alice,
                uint48(blockTimestamp),
                abi.encode(
                    IVaultTokenized.ActiveBalanceOfHints({
                        activeSharesOfHint: abi.encode(0),
                        activeStakeHint: abi.encode(0),
                        activeSharesHint: abi.encode(0)
                    })
                )
            ),
            amount1 - 1 + amount2 - 1
        );
        gasSpent = gasLeft - gasleft();
        gasLeft = gasleft();
        assertEq(
            vault.activeBalanceOfAt(
                alice,
                uint48(blockTimestamp),
                abi.encode(
                    IVaultTokenized.ActiveBalanceOfHints({
                        activeSharesOfHint: abi.encode(1),
                        activeStakeHint: abi.encode(1),
                        activeSharesHint: abi.encode(1)
                    })
                )
            ),
            amount1 - 1 + amount2 - 1
        );
        assertGt(gasSpent, gasLeft - gasleft());
    }

    function test_DepositBoth(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 1, 100 * 10 ** 18);
        amount2 = bound(amount2, 1, 100 * 10 ** 18);

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        uint48 epochDuration = 1;
        vault = _getVault(epochDuration);

        uint256 shares1 = amount1 * 10 ** 0;
        {
            (uint256 depositedAmount, uint256 mintedShares) = _deposit(alice, amount1);
            assertEq(depositedAmount, amount1);
            assertEq(mintedShares, shares1);

            assertEq(vault.balanceOf(alice), shares1);
            assertEq(vault.totalSupply(), shares1);
        }

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        uint256 shares2 = amount2 * (shares1 + 10 ** 0) / (amount1 + 1);
        {
            (uint256 depositedAmount, uint256 mintedShares) = _deposit(bob, amount2);
            assertEq(depositedAmount, amount2);
            assertEq(mintedShares, shares2);

            assertEq(vault.balanceOf(bob), shares2);
            assertEq(vault.totalSupply(), shares1 + shares2);
        }

        assertEq(vault.totalStake(), amount1 + amount2);
        assertEq(vault.activeSharesAt(uint48(blockTimestamp - 1), ""), shares1);
        assertEq(vault.activeSharesAt(uint48(blockTimestamp), ""), shares1 + shares2);
        assertEq(vault.activeShares(), shares1 + shares2);
        assertEq(vault.activeStakeAt(uint48(blockTimestamp - 1), ""), amount1);
        assertEq(vault.activeStakeAt(uint48(blockTimestamp), ""), amount1 + amount2);
        assertEq(vault.activeStake(), amount1 + amount2);
        assertEq(vault.activeSharesOfAt(alice, uint48(blockTimestamp - 1), ""), shares1);
        assertEq(vault.activeSharesOfAt(alice, uint48(blockTimestamp), ""), shares1);
        assertEq(vault.activeSharesOf(alice), shares1);
        assertEq(vault.activeBalanceOfAt(alice, uint48(blockTimestamp - 1), ""), amount1);
        assertEq(vault.activeBalanceOfAt(alice, uint48(blockTimestamp), ""), amount1);
        assertEq(vault.activeBalanceOf(alice), amount1);
        assertEq(vault.slashableBalanceOf(alice), amount1);
        assertEq(vault.activeSharesOfAt(bob, uint48(blockTimestamp - 1), ""), 0);
        assertEq(vault.activeSharesOfAt(bob, uint48(blockTimestamp), ""), shares2);
        assertEq(vault.activeSharesOf(bob), shares2);
        assertEq(vault.activeBalanceOfAt(bob, uint48(blockTimestamp - 1), ""), 0);
        assertEq(vault.activeBalanceOfAt(bob, uint48(blockTimestamp), ""), amount2);
        assertEq(vault.activeBalanceOf(bob), amount2);
        assertEq(vault.slashableBalanceOf(bob), amount2);
    }

    function test_DepositRevertInvalidOnBehalfOf(
        uint256 amount1
    ) public {
        amount1 = bound(amount1, 1, 100 * 10 ** 18);

        uint48 epochDuration = 1;
        vault = _getVault(epochDuration);

        vm.startPrank(alice);
        vm.expectRevert(IVaultTokenized.Vault__InvalidOnBehalfOf.selector);
        vault.deposit(address(0), amount1);
        vm.stopPrank();
    }

    function test_DepositRevertInsufficientDeposit() public {
        uint48 epochDuration = 1;
        vault = _getVault(epochDuration);

        vm.startPrank(alice);
        vm.expectRevert(IVaultTokenized.Vault__InsufficientDeposit.selector);
        vault.deposit(alice, 0);
        vm.stopPrank();
    }

    function test_WithdrawTwice(uint256 amount1, uint256 amount2, uint256 amount3) public {
        amount1 = bound(amount1, 1, 100 * 10 ** 18);
        amount2 = bound(amount2, 1, 100 * 10 ** 18);
        amount3 = bound(amount3, 1, 100 * 10 ** 18);
        vm.assume(amount1 >= amount2 + amount3);

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        // uint48 epochDuration = 1;
        vault = _getVault(1);

        (, uint256 shares) = _deposit(alice, amount1);

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        uint256 burnedShares = amount2 * (shares + 10 ** 0) / (amount1 + 1);
        uint256 mintedShares = amount2 * 10 ** 0;
        (uint256 burnedShares_, uint256 mintedShares_) = _withdraw(alice, amount2);
        assertEq(burnedShares_, burnedShares);
        assertEq(mintedShares_, mintedShares);

        assertEq(vault.balanceOf(alice), amount1 - burnedShares_);
        assertEq(vault.totalSupply(), amount1 - burnedShares_);

        assertEq(vault.totalStake(), amount1);
        assertEq(vault.activeSharesAt(uint48(blockTimestamp - 1), ""), shares);
        assertEq(vault.activeSharesAt(uint48(blockTimestamp), ""), shares - burnedShares);
        assertEq(vault.activeShares(), shares - burnedShares);
        assertEq(vault.activeStakeAt(uint48(blockTimestamp - 1), ""), amount1);
        assertEq(vault.activeStakeAt(uint48(blockTimestamp), ""), amount1 - amount2);
        assertEq(vault.activeStake(), amount1 - amount2);
        assertEq(vault.activeSharesOfAt(alice, uint48(blockTimestamp - 1), ""), shares);
        assertEq(vault.activeSharesOfAt(alice, uint48(blockTimestamp), ""), shares - burnedShares);
        assertEq(vault.activeSharesOf(alice), shares - burnedShares);
        assertEq(vault.activeBalanceOfAt(alice, uint48(blockTimestamp - 1), ""), amount1);
        assertEq(vault.activeBalanceOfAt(alice, uint48(blockTimestamp), ""), amount1 - amount2);
        assertEq(vault.activeBalanceOf(alice), amount1 - amount2);
        assertEq(vault.withdrawals(vault.currentEpoch()), 0);
        assertEq(vault.withdrawals(vault.currentEpoch() + 1), amount2);
        assertEq(vault.withdrawals(vault.currentEpoch() + 2), 0);
        assertEq(vault.withdrawalShares(vault.currentEpoch()), 0);
        assertEq(vault.withdrawalShares(vault.currentEpoch() + 1), mintedShares);
        assertEq(vault.withdrawalShares(vault.currentEpoch() + 2), 0);
        assertEq(vault.withdrawalSharesOf(vault.currentEpoch(), alice), 0);
        assertEq(vault.withdrawalSharesOf(vault.currentEpoch() + 1, alice), mintedShares);
        assertEq(vault.withdrawalSharesOf(vault.currentEpoch() + 2, alice), 0);
        assertEq(vault.slashableBalanceOf(alice), amount1);

        shares -= burnedShares;

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        burnedShares = amount3 * (shares + 10 ** 0) / (amount1 - amount2 + 1);
        mintedShares = amount3 * 10 ** 0;
        (burnedShares_, mintedShares_) = _withdraw(alice, amount3);
        assertEq(burnedShares_, burnedShares);
        assertEq(mintedShares_, mintedShares);

        assertEq(vault.balanceOf(alice), amount1 - amount2 - amount3);
        assertEq(vault.totalSupply(), amount1 - amount2 - amount3);

        assertEq(vault.totalStake(), amount1);
        assertEq(vault.activeSharesAt(uint48(blockTimestamp - 1), ""), shares);
        assertEq(vault.activeSharesAt(uint48(blockTimestamp), ""), shares - burnedShares);
        assertEq(vault.activeShares(), shares - burnedShares);
        assertEq(vault.activeStakeAt(uint48(blockTimestamp - 1), ""), amount1 - amount2);
        assertEq(vault.activeStakeAt(uint48(blockTimestamp), ""), amount1 - amount2 - amount3);
        assertEq(vault.activeStake(), amount1 - amount2 - amount3);
        assertEq(vault.activeSharesOfAt(alice, uint48(blockTimestamp - 1), ""), shares);
        assertEq(vault.activeSharesOfAt(alice, uint48(blockTimestamp), ""), shares - burnedShares);
        assertEq(vault.activeSharesOf(alice), shares - burnedShares);
        assertEq(vault.activeBalanceOfAt(alice, uint48(blockTimestamp - 1), ""), amount1 - amount2);
        assertEq(vault.activeBalanceOfAt(alice, uint48(blockTimestamp), ""), amount1 - amount2 - amount3);
        assertEq(vault.activeBalanceOf(alice), amount1 - amount2 - amount3);
        assertEq(vault.withdrawals(vault.currentEpoch() - 1), 0);
        assertEq(vault.withdrawals(vault.currentEpoch()), amount2);
        assertEq(vault.withdrawals(vault.currentEpoch() + 1), amount3);
        assertEq(vault.withdrawals(vault.currentEpoch() + 2), 0);
        assertEq(vault.withdrawalShares(vault.currentEpoch() - 1), 0);
        assertEq(vault.withdrawalShares(vault.currentEpoch()), amount2 * 10 ** 0);
        assertEq(vault.withdrawalShares(vault.currentEpoch() + 1), amount3 * 10 ** 0);
        assertEq(vault.withdrawalShares(vault.currentEpoch() + 2), 0);
        assertEq(vault.withdrawalSharesOf(vault.currentEpoch() - 1, alice), 0);
        assertEq(vault.withdrawalSharesOf(vault.currentEpoch(), alice), amount2 * 10 ** 0);
        assertEq(vault.withdrawalSharesOf(vault.currentEpoch() + 1, alice), amount3 * 10 ** 0);
        assertEq(vault.withdrawalSharesOf(vault.currentEpoch() + 2, alice), 0);
        assertEq(vault.slashableBalanceOf(alice), amount1);

        shares -= burnedShares;

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        assertEq(vault.totalStake(), amount1 - amount2);

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        assertEq(vault.totalStake(), amount1 - amount2 - amount3);
    }

    function test_WithdrawRevertInvalidClaimer(
        uint256 amount1
    ) public {
        amount1 = bound(amount1, 1, 100 * 10 ** 18);

        uint48 epochDuration = 1;
        vault = _getVault(epochDuration);

        _deposit(alice, amount1);

        vm.expectRevert(IVaultTokenized.Vault__InvalidClaimer.selector);
        vm.startPrank(alice);
        vault.withdraw(address(0), amount1);
        vm.stopPrank();
    }

    function test_WithdrawRevertInsufficientWithdrawal(
        uint256 amount1
    ) public {
        amount1 = bound(amount1, 1, 100 * 10 ** 18);

        uint48 epochDuration = 1;
        vault = _getVault(epochDuration);

        _deposit(alice, amount1);

        vm.expectRevert(IVaultTokenized.Vault__InsufficientWithdrawal.selector);
        _withdraw(alice, 0);
    }

    function test_WithdrawRevertTooMuchWithdraw(
        uint256 amount1
    ) public {
        amount1 = bound(amount1, 1, 100 * 10 ** 18);

        uint48 epochDuration = 1;
        vault = _getVault(epochDuration);

        _deposit(alice, amount1);

        vm.expectRevert(IVaultTokenized.Vault__TooMuchWithdraw.selector);
        _withdraw(alice, amount1 + 1);
    }

    function test_HistoricalLookups(uint256 amount1, uint256 amount2, uint256 amount3) public {
        // 1) Bound the deposit/withdraw amounts so they're valid
        amount1 = bound(amount1, 1, 100 * 10 ** 18);
        amount2 = bound(amount2, 1, 100 * 10 ** 18);
        amount3 = bound(amount3, 1, 100 * 10 ** 18);
        vm.assume(amount1 >= amount2 + amount3);

        // 2) Warp to a large-ish starting time, same technique used in your other tests
        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        // 3) Deploy a vault with epochDuration=1 using your helper
        vault = _getVault(1);

        // 4) Alice deposit #1
        //    - record the time right after it, call it timeDeposit1
        //    - e.g. deposit 'amount1'
        (, uint256 mintedShares1) = _deposit(alice, amount1);
        uint256 timeDeposit1 = blockTimestamp; // right now

        // 5) Advance time by +1, do a second deposit (amount2)
        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);
        (, uint256 mintedShares2) = _deposit(alice, amount2);
        uint256 timeDeposit2 = blockTimestamp; // record second deposit time

        // 6) Advance time by +1, do a withdraw of 'amount3'
        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);
        (uint256 burnedShares,) = _withdraw(alice, amount3);
        uint256 timeWithdraw = blockTimestamp;

        // 7) Now do historical lookups at each earlier timestamp
        //    We'll use the *exact* style from your other tests:
        //    localVault.activeSharesAt(uint48(...), ""), etc.

        // 7.1) Check "before first deposit" = timeDeposit1 - 1
        uint48 queryT = uint48(timeDeposit1 - 1);
        assertEq(vault.activeStakeAt(queryT, ""), 0);
        assertEq(vault.activeSharesAt(queryT, ""), 0);
        assertEq(vault.activeSharesOfAt(alice, queryT, ""), 0);
        assertEq(vault.activeBalanceOfAt(alice, queryT, ""), 0);

        // 7.2) Check exactly at timeDeposit1 (just after deposit#1)
        queryT = uint48(timeDeposit1);
        // total stake = amount1
        assertEq(vault.activeStakeAt(queryT, ""), amount1);
        // total shares = mintedShares1
        assertEq(vault.activeSharesAt(queryT, ""), mintedShares1);
        // alice’s shares = mintedShares1
        assertEq(vault.activeSharesOfAt(alice, queryT, ""), mintedShares1);
        // alice’s active balance = amount1
        assertEq(vault.activeBalanceOfAt(alice, queryT, ""), amount1);

        // 7.3) Check exactly at timeDeposit2 (just after deposit#2)
        queryT = uint48(timeDeposit2);
        // total stake = amount1 + amount2
        assertEq(vault.activeStakeAt(queryT, ""), amount1 + amount2);
        // total shares = mintedShares1 + mintedShares2
        assertEq(vault.activeSharesAt(queryT, ""), mintedShares1 + mintedShares2);
        // alice’s shares = mintedShares1 + mintedShares2
        assertEq(vault.activeSharesOfAt(alice, queryT, ""), mintedShares1 + mintedShares2);
        // alice’s active balance = amount1 + amount2
        assertEq(vault.activeBalanceOfAt(alice, queryT, ""), amount1 + amount2);

        // 7.4) Check exactly at timeWithdraw (just after withdraw of amount3)
        queryT = uint48(timeWithdraw);
        // total stake = (amount1 + amount2) minus the withdrawn assets
        uint256 expectedStake = (amount1 + amount2) - amount3;
        // total shares = mintedShares1 + mintedShares2 - burnedShares
        uint256 expectedShares = (mintedShares1 + mintedShares2) - burnedShares;

        assertEq(vault.activeStakeAt(queryT, ""), expectedStake);
        assertEq(vault.activeSharesAt(queryT, ""), expectedShares);
        assertEq(vault.activeSharesOfAt(alice, queryT, ""), expectedShares);
        // alice’s balance = (amount1 + amount2) - amount3
        assertEq(vault.activeBalanceOfAt(alice, queryT, ""), expectedStake);
    }

    function test_RedeemTwice(uint256 amount1, uint256 amount2, uint256 amount3) public {
        amount1 = bound(amount1, 1, 100 * 10 ** 18);
        amount2 = bound(amount2, 1, 100 * 10 ** 18);
        amount3 = bound(amount3, 1, 100 * 10 ** 18);
        vm.assume(amount1 >= amount2 + amount3);

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        // uint48 epochDuration = 1;
        vault = _getVault(1);

        (, uint256 shares) = _deposit(alice, amount1);

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        uint256 withdrawnAssets2 = amount2 * (amount1 + 1) / (shares + 10 ** 0);
        uint256 mintedShares = amount2 * 10 ** 0;
        (uint256 withdrawnAssets_, uint256 mintedShares_) = _redeem(alice, amount2);
        assertEq(withdrawnAssets_, withdrawnAssets2);
        assertEq(mintedShares_, mintedShares);

        assertEq(vault.totalStake(), amount1);
        assertEq(vault.activeSharesAt(uint48(blockTimestamp - 1), ""), shares);
        assertEq(vault.activeSharesAt(uint48(blockTimestamp), ""), shares - amount2);
        assertEq(vault.activeShares(), shares - amount2);
        assertEq(vault.activeStakeAt(uint48(blockTimestamp - 1), ""), amount1);
        assertEq(vault.activeStakeAt(uint48(blockTimestamp), ""), amount1 - withdrawnAssets2);
        assertEq(vault.activeStake(), amount1 - withdrawnAssets2);
        assertEq(vault.activeSharesOfAt(alice, uint48(blockTimestamp - 1), ""), shares);
        assertEq(vault.activeSharesOfAt(alice, uint48(blockTimestamp), ""), shares - amount2);
        assertEq(vault.activeSharesOf(alice), shares - amount2);
        assertEq(vault.activeBalanceOfAt(alice, uint48(blockTimestamp - 1), ""), amount1);
        assertEq(vault.activeBalanceOfAt(alice, uint48(blockTimestamp), ""), amount1 - withdrawnAssets2);
        assertEq(vault.activeBalanceOf(alice), amount1 - withdrawnAssets2);
        assertEq(vault.withdrawals(vault.currentEpoch()), 0);
        assertEq(vault.withdrawals(vault.currentEpoch() + 1), withdrawnAssets2);
        assertEq(vault.withdrawals(vault.currentEpoch() + 2), 0);
        assertEq(vault.withdrawalShares(vault.currentEpoch()), 0);
        assertEq(vault.withdrawalShares(vault.currentEpoch() + 1), mintedShares);
        assertEq(vault.withdrawalShares(vault.currentEpoch() + 2), 0);
        assertEq(vault.withdrawalSharesOf(vault.currentEpoch(), alice), 0);
        assertEq(vault.withdrawalSharesOf(vault.currentEpoch() + 1, alice), mintedShares);
        assertEq(vault.withdrawalSharesOf(vault.currentEpoch() + 2, alice), 0);
        assertEq(vault.slashableBalanceOf(alice), amount1);

        shares -= amount2;

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        uint256 withdrawnAssets3 = amount3 * (amount1 - withdrawnAssets2 + 1) / (shares + 10 ** 0);
        mintedShares = amount3 * 10 ** 0;
        (withdrawnAssets_, mintedShares_) = _redeem(alice, amount3);
        assertEq(withdrawnAssets_, withdrawnAssets3);
        assertEq(mintedShares_, mintedShares);

        assertEq(vault.totalStake(), amount1);
        assertEq(vault.activeSharesAt(uint48(blockTimestamp - 1), ""), shares);
        assertEq(vault.activeSharesAt(uint48(blockTimestamp), ""), shares - amount3);
        assertEq(vault.activeShares(), shares - amount3);
        assertEq(vault.activeStakeAt(uint48(blockTimestamp - 1), ""), amount1 - withdrawnAssets2);
        assertEq(vault.activeStakeAt(uint48(blockTimestamp), ""), amount1 - withdrawnAssets2 - withdrawnAssets3);
        assertEq(vault.activeStake(), amount1 - withdrawnAssets2 - withdrawnAssets3);
        assertEq(vault.activeSharesOfAt(alice, uint48(blockTimestamp - 1), ""), shares);
        assertEq(vault.activeSharesOfAt(alice, uint48(blockTimestamp), ""), shares - amount3);
        assertEq(vault.activeSharesOf(alice), shares - amount3);
        assertEq(vault.activeBalanceOfAt(alice, uint48(blockTimestamp - 1), ""), amount1 - withdrawnAssets2);
        assertEq(
            vault.activeBalanceOfAt(alice, uint48(blockTimestamp), ""), amount1 - withdrawnAssets2 - withdrawnAssets3
        );
        assertEq(vault.activeBalanceOf(alice), amount1 - withdrawnAssets2 - withdrawnAssets3);
        assertEq(vault.withdrawals(vault.currentEpoch() - 1), 0);
        assertEq(vault.withdrawals(vault.currentEpoch()), withdrawnAssets2);
        assertEq(vault.withdrawals(vault.currentEpoch() + 1), withdrawnAssets3);
        assertEq(vault.withdrawals(vault.currentEpoch() + 2), 0);
        assertEq(vault.withdrawalShares(vault.currentEpoch() - 1), 0);
        assertEq(vault.withdrawalShares(vault.currentEpoch()), withdrawnAssets2 * 10 ** 0);
        assertEq(vault.withdrawalShares(vault.currentEpoch() + 1), withdrawnAssets3 * 10 ** 0);
        assertEq(vault.withdrawalShares(vault.currentEpoch() + 2), 0);
        assertEq(vault.withdrawalSharesOf(vault.currentEpoch() - 1, alice), 0);
        assertEq(vault.withdrawalSharesOf(vault.currentEpoch(), alice), withdrawnAssets2 * 10 ** 0);
        assertEq(vault.withdrawalSharesOf(vault.currentEpoch() + 1, alice), withdrawnAssets3 * 10 ** 0);
        assertEq(vault.withdrawalSharesOf(vault.currentEpoch() + 2, alice), 0);
        assertEq(vault.slashableBalanceOf(alice), amount1);

        shares -= amount3;

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        assertEq(vault.totalStake(), amount1 - withdrawnAssets2);

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        assertEq(vault.totalStake(), amount1 - withdrawnAssets2 - withdrawnAssets3);
    }

    function test_RedeemRevertInvalidClaimer(
        uint256 amount1
    ) public {
        amount1 = bound(amount1, 1, 100 * 10 ** 18);

        uint48 epochDuration = 1;
        vault = _getVault(epochDuration);

        _deposit(alice, amount1);

        vm.expectRevert(IVaultTokenized.Vault__InvalidClaimer.selector);
        vm.startPrank(alice);
        vault.redeem(address(0), amount1);
        vm.stopPrank();
    }

    function test_RedeemRevertInsufficientRedeemption(
        uint256 amount1
    ) public {
        amount1 = bound(amount1, 1, 100 * 10 ** 18);

        uint48 epochDuration = 1;
        vault = _getVault(epochDuration);

        _deposit(alice, amount1);

        vm.expectRevert(IVaultTokenized.Vault__InsufficientRedemption.selector);
        _redeem(alice, 0);
    }

    function test_RedeemRevertTooMuchRedeem(
        uint256 amount1
    ) public {
        amount1 = bound(amount1, 1, 100 * 10 ** 18);

        uint48 epochDuration = 1;
        vault = _getVault(epochDuration);

        _deposit(alice, amount1);

        vm.expectRevert(IVaultTokenized.Vault__TooMuchRedeem.selector);
        _redeem(alice, amount1 + 1);
    }

    function test_Claim(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 1, 100 * 10 ** 18);
        amount2 = bound(amount2, 1, 100 * 10 ** 18);
        vm.assume(amount1 >= amount2);

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        uint48 epochDuration = 1;
        vault = _getVault(epochDuration);

        _deposit(alice, amount1);

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        _withdraw(alice, amount2);

        blockTimestamp = blockTimestamp + 2;
        vm.warp(blockTimestamp);

        uint256 tokensBefore = collateral.balanceOf(address(vault));
        uint256 tokensBeforeAlice = collateral.balanceOf(alice);
        assertEq(_claim(alice, vault.currentEpoch() - 1), amount2);
        assertEq(tokensBefore - collateral.balanceOf(address(vault)), amount2);
        assertEq(collateral.balanceOf(alice) - tokensBeforeAlice, amount2);

        assertEq(vault.isWithdrawalsClaimed(vault.currentEpoch() - 1, alice), true);
    }

    function test_ClaimRevertInvalidRecipient(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 1, 100 * 10 ** 18);
        amount2 = bound(amount2, 1, 100 * 10 ** 18);
        vm.assume(amount1 >= amount2);

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        uint48 epochDuration = 1;
        vault = _getVault(epochDuration);

        _deposit(alice, amount1);

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        _withdraw(alice, amount2);

        blockTimestamp = blockTimestamp + 2;
        vm.warp(blockTimestamp);

        vm.startPrank(alice);
        uint256 currentEpoch = vault.currentEpoch();
        vm.expectRevert(IVaultTokenized.Vault__InvalidRecipient.selector);
        vault.claim(address(0), currentEpoch - 1);
        vm.stopPrank();
    }

    function test_ClaimRevertInvalidEpoch(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 1, 100 * 10 ** 18);
        amount2 = bound(amount2, 1, 100 * 10 ** 18);
        vm.assume(amount1 >= amount2);

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        uint48 epochDuration = 1;
        vault = _getVault(epochDuration);

        _deposit(alice, amount1);

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        _withdraw(alice, amount2);

        blockTimestamp = blockTimestamp + 2;
        vm.warp(blockTimestamp);

        uint256 currentEpoch = vault.currentEpoch();
        vm.expectRevert(IVaultTokenized.Vault__InvalidEpoch.selector);
        _claim(alice, currentEpoch);
    }

    function test_ClaimRevertAlreadyClaimed(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 1, 100 * 10 ** 18);
        amount2 = bound(amount2, 1, 100 * 10 ** 18);
        vm.assume(amount1 >= amount2);

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        uint48 epochDuration = 1;
        vault = _getVault(epochDuration);

        _deposit(alice, amount1);

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        _withdraw(alice, amount2);

        blockTimestamp = blockTimestamp + 2;
        vm.warp(blockTimestamp);

        uint256 currentEpoch = vault.currentEpoch();
        _claim(alice, currentEpoch - 1);

        vm.expectRevert(IVaultTokenized.Vault__AlreadyClaimed.selector);
        _claim(alice, currentEpoch - 1);
    }

    function test_ClaimRevertInsufficientClaim(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 1, 100 * 10 ** 18);
        amount2 = bound(amount2, 1, 100 * 10 ** 18);
        vm.assume(amount1 >= amount2);

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        uint48 epochDuration = 1;
        vault = _getVault(epochDuration);

        _deposit(alice, amount1);

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        _withdraw(alice, amount2);

        blockTimestamp = blockTimestamp + 2;
        vm.warp(blockTimestamp);

        uint256 currentEpoch = vault.currentEpoch();
        vm.expectRevert(IVaultTokenized.Vault__InsufficientClaim.selector);
        _claim(alice, currentEpoch - 2);
    }

    function test_ClaimBatch(uint256 amount1, uint256 amount2, uint256 amount3) public {
        amount1 = bound(amount1, 1, 100 * 10 ** 18);
        amount2 = bound(amount2, 1, 100 * 10 ** 18);
        amount3 = bound(amount3, 1, 100 * 10 ** 18);
        vm.assume(amount1 >= amount2 + amount3);

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        uint48 epochDuration = 1;
        vault = _getVault(epochDuration);

        _deposit(alice, amount1);

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        _withdraw(alice, amount2);

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        _withdraw(alice, amount3);

        blockTimestamp = blockTimestamp + 2;
        vm.warp(blockTimestamp);

        uint256[] memory epochs = new uint256[](2);
        epochs[0] = vault.currentEpoch() - 1;
        epochs[1] = vault.currentEpoch() - 2;

        uint256 tokensBefore = collateral.balanceOf(address(vault));
        uint256 tokensBeforeAlice = collateral.balanceOf(alice);
        assertEq(_claimBatch(alice, epochs), amount2 + amount3);
        assertEq(tokensBefore - collateral.balanceOf(address(vault)), amount2 + amount3);
        assertEq(collateral.balanceOf(alice) - tokensBeforeAlice, amount2 + amount3);

        assertEq(vault.isWithdrawalsClaimed(vault.currentEpoch() - 1, alice), true);
    }

    function test_ClaimBatchRevertInvalidRecipient(uint256 amount1, uint256 amount2, uint256 amount3) public {
        amount1 = bound(amount1, 1, 100 * 10 ** 18);
        amount2 = bound(amount2, 1, 100 * 10 ** 18);
        amount3 = bound(amount3, 1, 100 * 10 ** 18);
        vm.assume(amount1 >= amount2 + amount3);

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        uint48 epochDuration = 1;
        vault = _getVault(epochDuration);

        _deposit(alice, amount1);

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        _withdraw(alice, amount2);

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        _withdraw(alice, amount3);

        blockTimestamp = blockTimestamp + 2;
        vm.warp(blockTimestamp);

        uint256[] memory epochs = new uint256[](2);
        epochs[0] = vault.currentEpoch() - 1;
        epochs[1] = vault.currentEpoch() - 2;

        vm.expectRevert(IVaultTokenized.Vault__InvalidRecipient.selector);
        vm.startPrank(alice);
        vault.claimBatch(address(0), epochs);
        vm.stopPrank();
    }

    function test_ClaimBatchRevertInvalidLengthEpochs(uint256 amount1, uint256 amount2, uint256 amount3) public {
        amount1 = bound(amount1, 1, 100 * 10 ** 18);
        amount2 = bound(amount2, 1, 100 * 10 ** 18);
        amount3 = bound(amount3, 1, 100 * 10 ** 18);
        vm.assume(amount1 >= amount2 + amount3);

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        uint48 epochDuration = 1;
        vault = _getVault(epochDuration);

        _deposit(alice, amount1);

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        _withdraw(alice, amount2);

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        _withdraw(alice, amount3);

        blockTimestamp = blockTimestamp + 2;
        vm.warp(blockTimestamp);

        uint256[] memory epochs = new uint256[](0);
        vm.expectRevert(IVaultTokenized.Vault__InvalidLengthEpochs.selector);
        _claimBatch(alice, epochs);
    }

    function test_ClaimBatchRevertInvalidEpoch(uint256 amount1, uint256 amount2, uint256 amount3) public {
        amount1 = bound(amount1, 1, 100 * 10 ** 18);
        amount2 = bound(amount2, 1, 100 * 10 ** 18);
        amount3 = bound(amount3, 1, 100 * 10 ** 18);
        vm.assume(amount1 >= amount2 + amount3);

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        uint48 epochDuration = 1;
        vault = _getVault(epochDuration);

        _deposit(alice, amount1);

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        _withdraw(alice, amount2);

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        _withdraw(alice, amount3);

        blockTimestamp = blockTimestamp + 2;
        vm.warp(blockTimestamp);

        uint256[] memory epochs = new uint256[](2);
        epochs[0] = vault.currentEpoch() - 1;
        epochs[1] = vault.currentEpoch();

        vm.expectRevert(IVaultTokenized.Vault__InvalidEpoch.selector);
        _claimBatch(alice, epochs);
    }

    function test_ClaimBatchRevertAlreadyClaimed(uint256 amount1, uint256 amount2, uint256 amount3) public {
        amount1 = bound(amount1, 1, 100 * 10 ** 18);
        amount2 = bound(amount2, 1, 100 * 10 ** 18);
        amount3 = bound(amount3, 1, 100 * 10 ** 18);
        vm.assume(amount1 >= amount2 + amount3);

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        uint48 epochDuration = 1;
        vault = _getVault(epochDuration);

        _deposit(alice, amount1);

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        _withdraw(alice, amount2);

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        _withdraw(alice, amount3);

        blockTimestamp = blockTimestamp + 2;
        vm.warp(blockTimestamp);

        uint256[] memory epochs = new uint256[](2);
        epochs[0] = vault.currentEpoch() - 1;
        epochs[1] = vault.currentEpoch() - 1;

        vm.expectRevert(IVaultTokenized.Vault__AlreadyClaimed.selector);
        _claimBatch(alice, epochs);
    }

    function test_ClaimBatchRevertInsufficientClaim(uint256 amount1, uint256 amount2, uint256 amount3) public {
        amount1 = bound(amount1, 1, 100 * 10 ** 18);
        amount2 = bound(amount2, 1, 100 * 10 ** 18);
        amount3 = bound(amount3, 1, 100 * 10 ** 18);
        vm.assume(amount1 >= amount2 + amount3);

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        uint48 epochDuration = 1;
        vault = _getVault(epochDuration);

        _deposit(alice, amount1);

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        _withdraw(alice, amount2);

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        _withdraw(alice, amount3);

        blockTimestamp = blockTimestamp + 2;
        vm.warp(blockTimestamp);

        uint256[] memory epochs = new uint256[](2);
        epochs[0] = vault.currentEpoch() - 1;
        epochs[1] = vault.currentEpoch() - 3;

        vm.expectRevert(IVaultTokenized.Vault__InsufficientClaim.selector);
        _claimBatch(alice, epochs);
    }

    function test_SetDepositWhitelist() public {
        uint48 epochDuration = 1;

        vault = _getVault(epochDuration);

        _grantDepositWhitelistSetRole(alice, alice);
        _setDepositWhitelist(alice, true);
        assertEq(vault.depositWhitelist(), true);

        _setDepositWhitelist(alice, false);
        assertEq(vault.depositWhitelist(), false);
    }

    function test_SetDepositWhitelistRevertNotWhitelistedDepositor() public {
        uint48 epochDuration = 1;

        vault = _getVault(epochDuration);

        _deposit(alice, 1);

        _grantDepositWhitelistSetRole(alice, alice);
        _setDepositWhitelist(alice, true);

        vm.startPrank(alice);
        vm.expectRevert(IVaultTokenized.Vault__NotWhitelistedDepositor.selector);
        vault.deposit(alice, 1);
        vm.stopPrank();
    }

    function test_SetDepositWhitelistRevertAlreadySet() public {
        uint48 epochDuration = 1;

        vault = _getVault(epochDuration);

        _grantDepositWhitelistSetRole(alice, alice);
        _setDepositWhitelist(alice, true);

        vm.expectRevert(IVaultTokenized.Vault__AlreadySet.selector);
        _setDepositWhitelist(alice, true);
    }

    function test_SetDepositorWhitelistStatus() public {
        uint48 epochDuration = 1;

        vault = _getVault(epochDuration);

        _grantDepositWhitelistSetRole(alice, alice);
        _setDepositWhitelist(alice, true);

        _grantDepositorWhitelistRole(alice, alice);

        _setDepositorWhitelistStatus(alice, bob, true);
        assertEq(vault.isDepositorWhitelisted(bob), true);

        _deposit(bob, 1);

        _setDepositWhitelist(alice, false);

        _deposit(bob, 1);
    }

    function test_SetDepositorWhitelistStatusRevertInvalidAccount() public {
        uint48 epochDuration = 1;

        vault = _getVault(epochDuration);

        _grantDepositWhitelistSetRole(alice, alice);
        _setDepositWhitelist(alice, true);

        _grantDepositorWhitelistRole(alice, alice);

        vm.expectRevert(IVaultTokenized.Vault__InvalidAccount.selector);
        _setDepositorWhitelistStatus(alice, address(0), true);
    }

    function test_SetDepositorWhitelistStatusRevertAlreadySet() public {
        uint48 epochDuration = 1;

        vault = _getVault(epochDuration);

        _grantDepositWhitelistSetRole(alice, alice);
        _setDepositWhitelist(alice, true);

        _grantDepositorWhitelistRole(alice, alice);

        _setDepositorWhitelistStatus(alice, bob, true);

        vm.expectRevert(IVaultTokenized.Vault__AlreadySet.selector);
        _setDepositorWhitelistStatus(alice, bob, true);
    }

    function test_SetIsDepositLimit() public {
        uint48 epochDuration = 1;

        vault = _getVault(epochDuration);

        _grantIsDepositLimitSetRole(alice, alice);
        _setIsDepositLimit(alice, true);
        assertEq(vault.isDepositLimit(), true);

        _setIsDepositLimit(alice, false);
        assertEq(vault.isDepositLimit(), false);
    }

    function test_SetIsDepositLimitRevertAlreadySet() public {
        uint48 epochDuration = 1;

        vault = _getVault(epochDuration);

        _grantIsDepositLimitSetRole(alice, alice);
        _setIsDepositLimit(alice, true);

        vm.expectRevert(IVaultTokenized.Vault__AlreadySet.selector);
        _setIsDepositLimit(alice, true);
    }

    function test_SetDepositLimit(uint256 limit1, uint256 limit2, uint256 depositAmount) public {
        uint48 epochDuration = 1;

        vault = _getVault(epochDuration);

        _grantIsDepositLimitSetRole(alice, alice);
        _setIsDepositLimit(alice, true);
        assertEq(vault.depositLimit(), 0);

        limit1 = bound(limit1, 1, type(uint256).max);
        _grantDepositLimitSetRole(alice, alice);
        _setDepositLimit(alice, limit1);
        assertEq(vault.depositLimit(), limit1);

        limit2 = bound(limit2, 1, 1000 ether);
        vm.assume(limit2 != limit1);
        _setDepositLimit(alice, limit2);
        assertEq(vault.depositLimit(), limit2);

        depositAmount = bound(depositAmount, 1, limit2);
        _deposit(alice, depositAmount);
    }

    function test_SetDepositLimitToNull(
        uint256 limit1
    ) public {
        uint48 epochDuration = 1;

        vault = _getVault(epochDuration);

        limit1 = bound(limit1, 1, type(uint256).max);
        _grantIsDepositLimitSetRole(alice, alice);
        _setIsDepositLimit(alice, true);
        _grantDepositLimitSetRole(alice, alice);
        _setDepositLimit(alice, limit1);

        _setIsDepositLimit(alice, false);

        _setDepositLimit(alice, 0);

        assertEq(vault.depositLimit(), 0);
    }

    function test_SetDepositLimitRevertDepositLimitReached(uint256 depositAmount, uint256 limit) public {
        uint48 epochDuration = 1;

        vault = _getVault(epochDuration);

        _deposit(alice, 1);

        limit = bound(limit, 2, 1000 ether);
        _grantIsDepositLimitSetRole(alice, alice);
        _setIsDepositLimit(alice, true);
        _grantDepositLimitSetRole(alice, alice);
        _setDepositLimit(alice, limit);

        depositAmount = bound(depositAmount, limit, 2000 ether);

        collateral.transfer(alice, depositAmount);
        vm.startPrank(alice);
        collateral.approve(address(vault), depositAmount);
        vm.expectRevert(IVaultTokenized.Vault__DepositLimitReached.selector);
        vault.deposit(alice, depositAmount);
        vm.stopPrank();
    }

    function test_SetDepositLimitRevertAlreadySet(
        uint256 limit
    ) public {
        uint48 epochDuration = 1;

        vault = _getVault(epochDuration);

        limit = bound(limit, 1, type(uint256).max);
        _grantIsDepositLimitSetRole(alice, alice);
        _setIsDepositLimit(alice, true);
        _grantDepositLimitSetRole(alice, alice);
        _setDepositLimit(alice, limit);

        vm.expectRevert(IVaultTokenized.Vault__AlreadySet.selector);
        _setDepositLimit(alice, limit);
    }

    function test_OnSlashRevertNotSlasher() public {
        uint48 epochDuration = 1;

        vault = _getVault(epochDuration);

        vm.startPrank(alice);
        vm.expectRevert(IVaultTokenized.Vault__NotSlasher.selector);
        vault.onSlash(0, 0);
        vm.stopPrank();
    }

    struct Test_SlashStruct {
        uint256 slashAmountReal1;
        uint256 tokensBeforeBurner;
        uint256 activeStake1;
        uint256 withdrawals1;
        uint256 nextWithdrawals1;
        uint256 slashAmountSlashed2;
    }

    // function test_Slash(
    //     // uint48 epochDuration,
    //     uint256 depositAmount,
    //     uint256 withdrawAmount1,
    //     uint256 withdrawAmount2,
    //     uint256 slashAmount1,
    //     uint256 slashAmount2,
    //     uint256 captureAgo
    // ) public {
    //     // epochDuration = uint48(bound(epochDuration, 2, 10 days));
    //     depositAmount = bound(depositAmount, 1, 100 * 10 ** 18);
    //     withdrawAmount1 = bound(withdrawAmount1, 1, 100 * 10 ** 18);
    //     withdrawAmount2 = bound(withdrawAmount2, 1, 100 * 10 ** 18);
    //     slashAmount1 = bound(slashAmount1, 1, type(uint256).max / 2);
    //     slashAmount2 = bound(slashAmount2, 1, type(uint256).max / 2);
    //     captureAgo = bound(captureAgo, 1, 10 days);
    //     vm.assume(depositAmount > withdrawAmount1 + withdrawAmount2);
    //     vm.assume(depositAmount > slashAmount1);
    //     vm.assume(captureAgo <= 7 days);

    //     uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
    //     blockTimestamp = blockTimestamp + 1_720_700_948;
    //     vm.warp(blockTimestamp);

    //     (vault, delegator, slasher) = _getVaultAndDelegatorAndSlasher(7 days);

    //     // address l1 = alice;
    //     _registerL1(alice, alice);
    //     _setMaxL1Limit(alice, 0, type(uint256).max);

    //     _registerOperator(alice);
    //     _registerOperator(bob);

    //     _optInOperatorVault(alice);
    //     _optInOperatorVault(bob);

    //     _optInOperatorL1(alice, address(alice));
    //     _optInOperatorL1(bob, address(alice));

    //     _setL1Limit(alice, alice, type(uint256).max);

    //     _setOperatorL1Limit(alice, alice, alice, type(uint256).max / 2);
    //     _setOperatorL1Limit(alice, alice, bob, type(uint256).max / 2);

    //     _deposit(alice, depositAmount);
    //     _withdraw(alice, withdrawAmount1);

    //     blockTimestamp = blockTimestamp + vault.epochDuration();
    //     vm.warp(blockTimestamp);

    //     _withdraw(alice, withdrawAmount2);

    //     assertEq(vault.totalStake(), depositAmount);
    //     assertEq(vault.activeStake(), depositAmount - withdrawAmount1 - withdrawAmount2);
    //     assertEq(vault.withdrawals(vault.currentEpoch()), withdrawAmount1);
    //     assertEq(vault.withdrawals(vault.currentEpoch() + 1), withdrawAmount2);

    //     blockTimestamp = blockTimestamp + 1;
    //     vm.warp(blockTimestamp);

    //     Test_SlashStruct memory test_SlashStruct;

    //     if (vault.epochAt(uint48(blockTimestamp - captureAgo)) != vault.currentEpoch()) {
    //         test_SlashStruct.slashAmountReal1 = Math.min(slashAmount1, depositAmount - withdrawAmount1);
    //         test_SlashStruct.tokensBeforeBurner = collateral.balanceOf(address(vault.burner()));
    //         assertEq(
    //             _slash(alice, alice, alice, slashAmount1, uint48(blockTimestamp - captureAgo), ""),
    //             test_SlashStruct.slashAmountReal1
    //         );
    //         assertEq(
    //             collateral.balanceOf(address(vault.burner())) - test_SlashStruct.tokensBeforeBurner,
    //             test_SlashStruct.slashAmountReal1
    //         );

    //         test_SlashStruct.activeStake1 = depositAmount - withdrawAmount1 - withdrawAmount2
    //             - (depositAmount - withdrawAmount1 - withdrawAmount2).mulDiv(
    //                 test_SlashStruct.slashAmountReal1, depositAmount
    //             );
    //         test_SlashStruct.withdrawals1 =
    //             withdrawAmount1 - withdrawAmount1.mulDiv(test_SlashStruct.slashAmountReal1, depositAmount);
    //         test_SlashStruct.nextWithdrawals1 =
    //             withdrawAmount2 - withdrawAmount2.mulDiv(test_SlashStruct.slashAmountReal1, depositAmount);
    //         assertEq(vault.totalStake(), depositAmount - test_SlashStruct.slashAmountReal1);
    //         assertTrue(test_SlashStruct.withdrawals1 - vault.withdrawals(vault.currentEpoch()) <= 2);
    //         assertTrue(test_SlashStruct.nextWithdrawals1 - vault.withdrawals(vault.currentEpoch() + 1) <= 1);
    //         assertEq(vault.activeStake(), test_SlashStruct.activeStake1);

    //         test_SlashStruct.slashAmountSlashed2 = Math.min(
    //             depositAmount - test_SlashStruct.slashAmountReal1,
    //             Math.min(slashAmount2, depositAmount - withdrawAmount1)
    //         );
    //         test_SlashStruct.tokensBeforeBurner = collateral.balanceOf(address(vault.burner()));
    //         assertEq(
    //             _slash(alice, alice, bob, slashAmount2, uint48(blockTimestamp - captureAgo), ""),
    //             Math.min(slashAmount2, depositAmount - withdrawAmount1)
    //         );
    //         assertEq(
    //             collateral.balanceOf(address(vault.burner())) - test_SlashStruct.tokensBeforeBurner,
    //             test_SlashStruct.slashAmountSlashed2
    //         );

    //         assertEq(
    //             vault.totalStake(),
    //             depositAmount - test_SlashStruct.slashAmountReal1 - test_SlashStruct.slashAmountSlashed2
    //         );
    //         assertTrue(
    //             (
    //                 test_SlashStruct.withdrawals1
    //                     - test_SlashStruct.withdrawals1.mulDiv(
    //                         test_SlashStruct.slashAmountSlashed2, depositAmount - test_SlashStruct.slashAmountReal1
    //                     )
    //             ) - vault.withdrawals(vault.currentEpoch()) <= 4
    //         );
    //         assertTrue(
    //             (
    //                 test_SlashStruct.nextWithdrawals1
    //                     - test_SlashStruct.nextWithdrawals1.mulDiv(
    //                         test_SlashStruct.slashAmountSlashed2, depositAmount - test_SlashStruct.slashAmountReal1
    //                     )
    //             ) - vault.withdrawals(vault.currentEpoch() + 1) <= 2
    //         );
    //         assertEq(
    //             vault.activeStake(),
    //             test_SlashStruct.activeStake1
    //                 - test_SlashStruct.activeStake1.mulDiv(
    //                     test_SlashStruct.slashAmountSlashed2, depositAmount - test_SlashStruct.slashAmountReal1
    //                 )
    //         );
    //     } else {
    //         test_SlashStruct.slashAmountReal1 =
    //             Math.min(slashAmount1, depositAmount - withdrawAmount1 - withdrawAmount2);
    //         test_SlashStruct.tokensBeforeBurner = collateral.balanceOf(address(vault.burner()));
    //         assertEq(
    //             _slash(alice, alice, alice, slashAmount1, uint48(blockTimestamp - captureAgo), ""),
    //             test_SlashStruct.slashAmountReal1
    //         );
    //         assertEq(
    //             collateral.balanceOf(address(vault.burner())) - test_SlashStruct.tokensBeforeBurner,
    //             test_SlashStruct.slashAmountReal1
    //         );

    //         test_SlashStruct.activeStake1 = depositAmount - withdrawAmount1 - withdrawAmount2
    //             - (depositAmount - withdrawAmount1 - withdrawAmount2).mulDiv(
    //                 test_SlashStruct.slashAmountReal1, depositAmount - withdrawAmount1
    //             );
    //         test_SlashStruct.withdrawals1 = withdrawAmount1;
    //         test_SlashStruct.nextWithdrawals1 = withdrawAmount2
    //             - withdrawAmount2.mulDiv(test_SlashStruct.slashAmountReal1, depositAmount - withdrawAmount1);
    //         assertEq(vault.totalStake(), depositAmount - test_SlashStruct.slashAmountReal1);
    //         assertEq(vault.withdrawals(vault.currentEpoch()), test_SlashStruct.withdrawals1);
    //         assertTrue(test_SlashStruct.nextWithdrawals1 - vault.withdrawals(vault.currentEpoch() + 1) <= 1);
    //         assertEq(vault.activeStake(), test_SlashStruct.activeStake1);

    //         test_SlashStruct.slashAmountSlashed2 = Math.min(
    //             depositAmount - withdrawAmount1 - test_SlashStruct.slashAmountReal1,
    //             Math.min(slashAmount2, depositAmount - withdrawAmount1 - withdrawAmount2)
    //         );
    //         test_SlashStruct.tokensBeforeBurner = collateral.balanceOf(address(vault.burner()));
    //         assertEq(
    //             _slash(alice, alice, bob, slashAmount2, uint48(blockTimestamp - captureAgo), ""),
    //             Math.min(slashAmount2, depositAmount - withdrawAmount1 - withdrawAmount2)
    //         );
    //         assertEq(
    //             collateral.balanceOf(address(vault.burner())) - test_SlashStruct.tokensBeforeBurner,
    //             test_SlashStruct.slashAmountSlashed2
    //         );

    //         assertEq(
    //             vault.totalStake(),
    //             depositAmount - test_SlashStruct.slashAmountReal1 - test_SlashStruct.slashAmountSlashed2
    //         );
    //         assertEq(vault.withdrawals(vault.currentEpoch()), test_SlashStruct.withdrawals1);
    //         assertTrue(
    //             (
    //                 test_SlashStruct.nextWithdrawals1
    //                     - test_SlashStruct.nextWithdrawals1.mulDiv(
    //                         test_SlashStruct.slashAmountSlashed2,
    //                         depositAmount - withdrawAmount1 - test_SlashStruct.slashAmountReal1
    //                     )
    //             ) - vault.withdrawals(vault.currentEpoch() + 1) <= 2
    //         );
    //         assertEq(
    //             vault.activeStake(),
    //             test_SlashStruct.activeStake1
    //                 - test_SlashStruct.activeStake1.mulDiv(
    //                     test_SlashStruct.slashAmountSlashed2,
    //                     depositAmount - withdrawAmount1 - test_SlashStruct.slashAmountReal1
    //                 )
    //         );
    //     }
    // }

    // struct GasStruct {
    //     uint256 gasSpent1;
    //     uint256 gasSpent2;
    // }

    // struct HintStruct {
    //     uint256 num;
    //     bool back;
    //     uint256 secondsAgo;
    // }

    // function test_ActiveSharesHint(uint256 amount1, uint48 epochDuration, HintStruct memory hintStruct) public {
    //     amount1 = bound(amount1, 1, 100 * 10 ** 18);
    //     epochDuration = uint48(bound(epochDuration, 1, 7 days));
    //     hintStruct.num = bound(hintStruct.num, 0, 25);
    //     hintStruct.secondsAgo = bound(hintStruct.secondsAgo, 0, 1_720_700_948);

    //     uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
    //     blockTimestamp = blockTimestamp + 1_720_700_948;
    //     vm.warp(blockTimestamp);

    //     vault = _getVault(epochDuration);

    //     for (uint256 i; i < hintStruct.num; ++i) {
    //         _deposit(alice, amount1);

    //         blockTimestamp = blockTimestamp + epochDuration;
    //         vm.warp(blockTimestamp);
    //     }

    //     uint48 timestamp =
    //         uint48(hintStruct.back ? blockTimestamp - hintStruct.secondsAgo : blockTimestamp + hintStruct.secondsAgo);

    //     VaultHints vaultHints = new VaultHints();
    //     bytes memory hint = vaultHints.activeSharesHint(address(vault), timestamp);

    //     GasStruct memory gasStruct = GasStruct({gasSpent1: 1, gasSpent2: 1});
    //     vault.activeSharesAt(timestamp, new bytes(0));
    //     gasStruct.gasSpent1 = vm.lastCallGas().gasTotalUsed;
    //     vault.activeSharesAt(timestamp, hint);
    //     gasStruct.gasSpent2 = vm.lastCallGas().gasTotalUsed;
    //     assertApproxEqRel(gasStruct.gasSpent1, gasStruct.gasSpent2, 0.05e18);
    // }

    // function test_ActiveStakeHint(uint256 amount1, uint48 epochDuration, HintStruct memory hintStruct) public {
    //     amount1 = bound(amount1, 1, 100 * 10 ** 18);
    //     epochDuration = uint48(bound(epochDuration, 1, 7 days));
    //     hintStruct.num = bound(hintStruct.num, 0, 25);
    //     hintStruct.secondsAgo = bound(hintStruct.secondsAgo, 0, 1_720_700_948);

    //     uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
    //     blockTimestamp = blockTimestamp + 1_720_700_948;
    //     vm.warp(blockTimestamp);

    //     vault = _getVault(epochDuration);

    //     for (uint256 i; i < hintStruct.num; ++i) {
    //         _deposit(alice, amount1);

    //         blockTimestamp = blockTimestamp + epochDuration;
    //         vm.warp(blockTimestamp);
    //     }

    //     uint48 timestamp =
    //         uint48(hintStruct.back ? blockTimestamp - hintStruct.secondsAgo : blockTimestamp + hintStruct.secondsAgo);

    //     VaultHints vaultHints = new VaultHints();
    //     bytes memory hint = vaultHints.activeStakeHint(address(vault), timestamp);

    //     GasStruct memory gasStruct = GasStruct({gasSpent1: 1, gasSpent2: 1});
    //     vault.activeStakeAt(timestamp, new bytes(0));
    //     gasStruct.gasSpent1 = vm.lastCallGas().gasTotalUsed;
    //     vault.activeStakeAt(timestamp, hint);
    //     gasStruct.gasSpent2 = vm.lastCallGas().gasTotalUsed;
    //     assertGe(gasStruct.gasSpent1, gasStruct.gasSpent2);
    // }

    // function test_ActiveSharesOfHint(uint256 amount1, uint48 epochDuration, HintStruct memory hintStruct) public {
    //     amount1 = bound(amount1, 1, 100 * 10 ** 18);
    //     epochDuration = uint48(bound(epochDuration, 1, 7 days));
    //     hintStruct.num = bound(hintStruct.num, 0, 25);
    //     hintStruct.secondsAgo = bound(hintStruct.secondsAgo, 0, 1_720_700_948);

    //     uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
    //     blockTimestamp = blockTimestamp + 1_720_700_948;
    //     vm.warp(blockTimestamp);

    //     vault = _getVault(epochDuration);

    //     for (uint256 i; i < hintStruct.num; ++i) {
    //         _deposit(alice, amount1);

    //         blockTimestamp = blockTimestamp + epochDuration;
    //         vm.warp(blockTimestamp);
    //     }

    //     uint48 timestamp =
    //         uint48(hintStruct.back ? blockTimestamp - hintStruct.secondsAgo : blockTimestamp + hintStruct.secondsAgo);

    //     VaultHints vaultHints = new VaultHints();
    //     bytes memory hint = vaultHints.activeSharesOfHint(address(vault), alice, timestamp);

    //     GasStruct memory gasStruct = GasStruct({gasSpent1: 1, gasSpent2: 1});
    //     vault.activeSharesOfAt(alice, timestamp, new bytes(0));
    //     gasStruct.gasSpent1 = vm.lastCallGas().gasTotalUsed;
    //     vault.activeSharesOfAt(alice, timestamp, hint);
    //     gasStruct.gasSpent2 = vm.lastCallGas().gasTotalUsed;
    //     assertGe(gasStruct.gasSpent1, gasStruct.gasSpent2);
    // }

    // struct ActiveBalanceOfHintsUint32 {
    //     uint32 activeSharesOfHint;
    //     uint32 activeStakeHint;
    //     uint32 activeSharesHint;
    // }

    // function test_ActiveBalanceOfHint(
    //     uint256 amount1,
    //     uint48 epochDuration,
    //     HintStruct memory hintStruct,
    //     ActiveBalanceOfHintsUint32 memory activeBalanceOfHintsUint32
    // ) public {
    //     amount1 = bound(amount1, 1, 100 * 10 ** 18);
    //     epochDuration = uint48(bound(epochDuration, 1, 7 days));
    //     hintStruct.num = bound(hintStruct.num, 0, 25);
    //     hintStruct.secondsAgo = bound(hintStruct.secondsAgo, 0, 1_720_700_948);

    //     uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
    //     blockTimestamp = blockTimestamp + 1_720_700_948;
    //     vm.warp(blockTimestamp);

    //     vault = _getVault(epochDuration);

    //     for (uint256 i; i < hintStruct.num; ++i) {
    //         _deposit(alice, amount1);

    //         blockTimestamp = blockTimestamp + epochDuration;
    //         vm.warp(blockTimestamp);
    //     }

    //     uint48 timestamp =
    //         uint48(hintStruct.back ? blockTimestamp - hintStruct.secondsAgo : blockTimestamp + hintStruct.secondsAgo);

    //     VaultHints vaultHints = new VaultHints();
    //     bytes memory hint = vaultHints.activeBalanceOfHints(address(vault), alice, timestamp);

    //     GasStruct memory gasStruct = GasStruct({gasSpent1: 1, gasSpent2: 1});
    //     bytes memory activeBalanceOfHints = abi.encode(
    //         IVaultTokenized.ActiveBalanceOfHints({
    //             activeSharesOfHint: abi.encode(activeBalanceOfHintsUint32.activeSharesOfHint),
    //             activeStakeHint: abi.encode(activeBalanceOfHintsUint32.activeStakeHint),
    //             activeSharesHint: abi.encode(activeBalanceOfHintsUint32.activeSharesHint)
    //         })
    //     );
    //     try vault.activeBalanceOfAt(alice, timestamp, activeBalanceOfHints) {
    //         gasStruct.gasSpent1 = vm.lastCallGas().gasTotalUsed;
    //     } catch {
    //         vault.activeBalanceOfAt(alice, timestamp, "");
    //         gasStruct.gasSpent1 = vm.lastCallGas().gasTotalUsed;
    //     }

    //     vault.activeBalanceOfAt(alice, timestamp, hint);
    //     gasStruct.gasSpent2 = vm.lastCallGas().gasTotalUsed;
    //     assertGe(gasStruct.gasSpent1, gasStruct.gasSpent2);
    // }

    // function test_ActiveBalanceOfHintMany(
    //     uint256 amount1,
    //     uint48 epochDuration,
    //     HintStruct memory hintStruct
    // ) public {
    //     amount1 = bound(amount1, 1, 1 * 10 ** 18);
    //     epochDuration = uint48(bound(epochDuration, 1, 7 days));
    //     hintStruct.num = 500;
    //     hintStruct.secondsAgo = bound(hintStruct.secondsAgo, 0, 1_720_700_948);

    //     uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
    //     blockTimestamp = blockTimestamp + 1_720_700_948;
    //     vm.warp(blockTimestamp);

    //     vault = _getVault(epochDuration);

    //     for (uint256 i; i < hintStruct.num; ++i) {
    //         _deposit(alice, amount1);

    //         blockTimestamp = blockTimestamp + epochDuration;
    //         vm.warp(blockTimestamp);
    //     }

    //     uint48 timestamp =
    //         uint48(hintStruct.back ? blockTimestamp - hintStruct.secondsAgo : blockTimestamp + hintStruct.secondsAgo);

    //     VaultHints vaultHints = new VaultHints();
    //     bytes memory hint = vaultHints.activeBalanceOfHints(address(vault), alice, timestamp);

    //     GasStruct memory gasStruct = GasStruct({gasSpent1: 1, gasSpent2: 1});
    //     vault.activeBalanceOfAt(alice, timestamp, "");
    //     gasStruct.gasSpent1 = vm.lastCallGas().gasTotalUsed;
    //     vault.activeBalanceOfAt(alice, timestamp, hint);
    //     gasStruct.gasSpent2 = vm.lastCallGas().gasTotalUsed;
    //     assertGe(gasStruct.gasSpent1, gasStruct.gasSpent2);

    //     assertLt(gasStruct.gasSpent1 - gasStruct.gasSpent2, 10_000);
    // }

    function test_Transfer(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 1, 100 * 10 ** 18);
        amount2 = bound(amount2, 1, 100 * 10 ** 18);

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        uint48 epochDuration = 1;
        vault = _getVault(epochDuration);

        (, uint256 mintedShares) = _deposit(alice, amount1);

        assertEq(vault.balanceOf(alice), mintedShares);
        assertEq(vault.totalSupply(), mintedShares);
        assertEq(vault.activeSharesOf(alice), mintedShares);
        assertEq(vault.activeShares(), mintedShares);

        if (amount2 > mintedShares) {
            vm.startPrank(alice);

            vm.expectRevert();
            vault.transfer(bob, amount2);

            vm.stopPrank();
        } else {
            vm.startPrank(alice);

            vault.transfer(bob, amount2);

            assertEq(vault.balanceOf(alice), mintedShares - amount2);
            assertEq(vault.totalSupply(), mintedShares);
            assertEq(vault.activeSharesOf(alice), mintedShares - amount2);
            assertEq(vault.activeShares(), mintedShares);

            assertEq(vault.balanceOf(bob), amount2);
            assertEq(vault.activeSharesOf(bob), amount2);

            vm.stopPrank();

            vm.startPrank(bob);
            vault.approve(alice, amount2);
            vm.stopPrank();

            assertEq(vault.allowance(bob, alice), amount2);

            vm.startPrank(alice);
            vault.transferFrom(bob, alice, amount2);
            vm.stopPrank();

            assertEq(vault.balanceOf(alice), mintedShares);
            assertEq(vault.totalSupply(), mintedShares);
            assertEq(vault.activeSharesOf(alice), mintedShares);
            assertEq(vault.activeShares(), mintedShares);
        }
    }

    function _getVault(
        uint48 epochDuration
    ) internal returns (VaultTokenized) {
        // Start broadcasting transactions
        vm.startBroadcast();
        address[] memory l1LimitSetRoleHolders = new address[](1);
        l1LimitSetRoleHolders[0] = alice;
        address[] memory operatorNetworkSharesSetRoleHolders = new address[](1);
        operatorNetworkSharesSetRoleHolders[0] = alice;
        uint64 lastVersion = vaultFactory.lastVersion();
        address vaultAddress = vaultFactory.create(
            lastVersion,
            alice,
            abi.encode(
                IVaultTokenized.InitParams({
                    collateral: address(collateral),
                    burner: address(0xdEaD),
                    epochDuration: epochDuration,
                    depositWhitelist: false,
                    isDepositLimit: false,
                    depositLimit: 0,
                    defaultAdminRoleHolder: alice,
                    depositWhitelistSetRoleHolder: alice,
                    depositorWhitelistRoleHolder: alice,
                    isDepositLimitSetRoleHolder: alice,
                    depositLimitSetRoleHolder: alice,
                    name: "Test",
                    symbol: "TEST"
                })
            ),
            address(delegatorFactory),
            address(slasherFactory)
        );

        //     IL1RestakeDelegator.InitParams({
        //         baseParams: IBaseDelegator.BaseParams({
        //             defaultAdminRoleHolder: alice,
        //             hook: address(0),
        //             hookSetRoleHolder: alice
        //         }),
        //         l1LimitSetRoleHolders: new address,
        //         operatorNetworkSharesSetRoleHolders: new address
        //     })
        // );

        // DelegatorFactory(delegatorFactory).whitelist(address(new IL1RestakeDelegator(/* constructor params */)));
        // address delegatorAddress = delegatorFactory.create(0, abi.encode(vaultAddress, delegatorParams));

        // address slasherAddress = address(0);
        // bool withSlasher = false; // Change as needed

        // if (withSlasher) {
        //     bytes memory slasherParams = abi.encode(
        //         ISlasher.InitParams({
        //             baseParams: IBaseSlasher.BaseParams({isBurnerHook: false})
        //         })
        //     );
        //     slasherAddress = slasherFactory.create(0, abi.encode(vaultAddress, slasherParams));
        // }

        // vault.setDelegator(delegatorAddress);
        // if (withSlasher) {
        //     vault.setSlasher(slasherAddress);
        // }

        vm.stopBroadcast();

        return VaultTokenized(vaultAddress);
    }

    // function _getVaultAndDelegatorAndSlasher(
    //     uint48 epochDuration
    // ) internal returns (VaultTokenized, FullRestakeDelegator, Slasher) {
    //     address[] memory l1LimitSetRoleHolders = new address[](1);
    //     l1LimitSetRoleHolders[0] = alice;
    //     address[] memory operatorL1LimitSetRoleHolders = new address[](1);
    //     operatorL1LimitSetRoleHolders[0] = alice;
    //     (address vault_, address delegator_, address slasher_) = vaultConfigurator.create(
    //         IVaultConfigurator.InitParams({
    //             version: vaultFactory.lastVersion(),
    //             owner: alice,
    //             vaultParams: abi.encode(
    //                 IVaultTokenized.InitParamsTokenized({
    //                     baseParams: IVaultTokenized.InitParams({
    //                         collateral: address(collateral),
    //                         burner: address(0xdEaD),
    //                         epochDuration: epochDuration,
    //                         depositWhitelist: false,
    //                         isDepositLimit: false,
    //                         depositLimit: 0,
    //                         defaultAdminRoleHolder: alice,
    //                         depositWhitelistSetRoleHolder: alice,
    //                         depositorWhitelistRoleHolder: alice,
    //                         isDepositLimitSetRoleHolder: alice,
    //                         depositLimitSetRoleHolder: alice
    //                     }),
    //                     name: "Test",
    //                     symbol: "TEST"
    //                 })
    //             ),
    //             delegatorIndex: 1,
    //             delegatorParams: abi.encode(
    //                 IFullRestakeDelegator.InitParams({
    //                     baseParams: IBaseDelegator.BaseParams({
    //                         defaultAdminRoleHolder: alice,
    //                         hook: address(0),
    //                         hookSetRoleHolder: alice
    //                     }),
    //                     l1LimitSetRoleHolders: l1LimitSetRoleHolders,
    //                     operatorL1LimitSetRoleHolders: operatorL1LimitSetRoleHolders
    //                 })
    //             ),
    //             withSlasher: true,
    //             slasherIndex: 0,
    //             slasherParams: abi.encode(ISlasher.InitParams({baseParams: IBaseSlasher.BaseParams({isBurnerHook: false})}))
    //         })
    //     );

    //     return (VaultTokenized(vault_), FullRestakeDelegator(delegator_), Slasher(slasher_));
    // }

    // function _registerOperator(
    //     address user
    // ) internal {
    //     vm.startPrank(user);
    //     operatorRegistry.registerOperator();
    //     vm.stopPrank();
    // }

    // function _registerL1(address user, address middleware) internal {
    //     vm.startPrank(user);
    //     l1Registry.registerL1();
    //     l1MiddlewareService.setMiddleware(middleware);
    //     vm.stopPrank();
    // }

    function _grantDepositorWhitelistRole(address user, address account) internal {
        vm.startPrank(user);
        VaultTokenized(address(vault)).grantRole(vault.DEPOSITOR_WHITELIST_ROLE(), account);
        vm.stopPrank();
    }

    function _grantDepositWhitelistSetRole(address user, address account) internal {
        vm.startPrank(user);
        VaultTokenized(address(vault)).grantRole(vault.DEPOSIT_WHITELIST_SET_ROLE(), account);
        vm.stopPrank();
    }

    function _grantIsDepositLimitSetRole(address user, address account) internal {
        vm.startPrank(user);
        VaultTokenized(address(vault)).grantRole(vault.IS_DEPOSIT_LIMIT_SET_ROLE(), account);
        vm.stopPrank();
    }

    function _grantDepositLimitSetRole(address user, address account) internal {
        vm.startPrank(user);
        VaultTokenized(address(vault)).grantRole(vault.DEPOSIT_LIMIT_SET_ROLE(), account);
        vm.stopPrank();
    }

    function _deposit(address user, uint256 amount) internal returns (uint256 depositedAmount, uint256 mintedShares) {
        collateral.transfer(user, amount);
        vm.startPrank(user);
        collateral.approve(address(vault), amount);
        (depositedAmount, mintedShares) = vault.deposit(user, amount);
        vm.stopPrank();
    }

    function _withdraw(address user, uint256 amount) internal returns (uint256 burnedShares, uint256 mintedShares) {
        vm.startPrank(user);
        (burnedShares, mintedShares) = vault.withdraw(user, amount);
        vm.stopPrank();
    }

    function _redeem(address user, uint256 shares) internal returns (uint256 withdrawnAssets, uint256 mintedShares) {
        vm.startPrank(user);
        (withdrawnAssets, mintedShares) = vault.redeem(user, shares);
        vm.stopPrank();
    }

    function _claim(address user, uint256 epoch) internal returns (uint256 amount) {
        vm.startPrank(user);
        amount = vault.claim(user, epoch);
        vm.stopPrank();
    }

    function _claimBatch(address user, uint256[] memory epochs) internal returns (uint256 amount) {
        vm.startPrank(user);
        amount = vault.claimBatch(user, epochs);
        vm.stopPrank();
    }

    // function _optInOperatorVault(
    //     address user
    // ) internal {
    //     vm.startPrank(user);
    //     operatorVaultOptInService.optIn(address(vault));
    //     vm.stopPrank();
    // }

    // function _optOutOperatorVault(
    //     address user
    // ) internal {
    //     vm.startPrank(user);
    //     operatorVaultOptInService.optOut(address(vault));
    //     vm.stopPrank();
    // }

    // function _optInOperatorL1(address user, address l1) internal {
    //     vm.startPrank(user);
    //     operatorL1OptInService.optIn(l1);
    //     vm.stopPrank();
    // }

    // function _optOutOperatorL1(address user, address l1) internal {
    //     vm.startPrank(user);
    //     operatorL1OptInService.optOut(l1);
    //     vm.stopPrank();
    // }

    function _setDepositWhitelist(address user, bool status) internal {
        vm.startPrank(user);
        vault.setDepositWhitelist(status);
        vm.stopPrank();
    }

    function _setDepositorWhitelistStatus(address user, address depositor, bool status) internal {
        vm.startPrank(user);
        vault.setDepositorWhitelistStatus(depositor, status);
        vm.stopPrank();
    }

    function _setIsDepositLimit(address user, bool status) internal {
        vm.startPrank(user);
        vault.setIsDepositLimit(status);
        vm.stopPrank();
    }

    function _setDepositLimit(address user, uint256 amount) internal {
        vm.startPrank(user);
        vault.setDepositLimit(amount);
        vm.stopPrank();
    }

    // function _setL1Limit(address user, address l1, uint256 amount) internal {
    //     vm.startPrank(user);
    //     delegator.setL1Limit(l1.subl1(0), amount);
    //     vm.stopPrank();
    // }

    // function _setOperatorL1Limit(address user, address l1, address operator, uint256 amount) internal {
    //     vm.startPrank(user);
    //     delegator.setOperatorL1Limit(l1.subl1(0), operator, amount);
    //     vm.stopPrank();
    // }

    // function _slash(
    //     address user,
    //     address l1,
    //     address operator,
    //     uint256 amount,
    //     uint48 captureTimestamp,
    //     bytes memory hints
    // ) internal returns (uint256 slashAmount) {
    //     vm.startPrank(user);
    //     slashAmount = slasher.slash(l1.subl1(0), operator, amount, captureTimestamp, hints);
    //     vm.stopPrank();
    // }

    // function _setMaxL1Limit(address user, uint96 identifier, uint256 amount) internal {
    //     vm.startPrank(user);
    //     delegator.setMaxL1Limit(identifier, amount);
    //     vm.stopPrank();
    // }
}
