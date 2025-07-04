// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";

import {ValidatorManagerSettings} from "@avalabs/teleporter/validator-manager/interfaces/IValidatorManager.sol";
import {PoAValidatorManager} from "@avalabs/teleporter/validator-manager/PoAValidatorManager.sol";
import {UnsafeUpgrades} from "@openzeppelin/foundry-upgrades/Upgrades.sol";
import {ICMInitializable} from "@avalabs/teleporter/utilities/ICMInitializable.sol";

import {VaultFactory} from "../../src/contracts/VaultFactory.sol";
import {DelegatorFactory} from "../../src/contracts/DelegatorFactory.sol";
import {SlasherFactory} from "../../src/contracts/SlasherFactory.sol";
import {L1Registry} from "../../src/contracts/L1Registry.sol";
import {OperatorRegistry} from "../../src/contracts/OperatorRegistry.sol";
import {
    AvalancheL1Middleware,
    AvalancheL1MiddlewareSettings
} from "../../src/contracts/middleware/AvalancheL1Middleware.sol";
import {OperatorL1OptInService} from "../../src/contracts/service/OperatorL1OptInService.sol";
import {OperatorVaultOptInService} from "../../src/contracts/service/OperatorVaultOptInService.sol";

import {VaultTokenized} from "../../src/contracts/vault/VaultTokenized.sol";
import {L1RestakeDelegator} from "../../src/contracts/delegator/L1RestakeDelegator.sol";
import {MiddlewareHelperConfig} from "../../script/middleware/anvil/MiddlewareHelperConfig.s.sol";

import {IVaultTokenized} from "../../src/interfaces/vault/IVaultTokenized.sol";
import {IL1RestakeDelegator} from "../../src/interfaces/delegator/IL1RestakeDelegator.sol";
import {IBaseDelegator} from "../../src/interfaces/delegator/IBaseDelegator.sol";
import {ISlasher} from "../../src/interfaces/slasher/ISlasher.sol";
import {IBaseSlasher} from "../../src/interfaces/slasher/IBaseSlasher.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Token} from "../mocks/MockToken.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract DummyL1 is Ownable {
    constructor(
        address initialOwner
    ) Ownable(initialOwner) {}
}

contract L1RestakeDelegatorTest is Test {
    using Math for uint256;

    address owner;
    address alice;
    uint256 alicePrivateKey;
    address bob;
    uint256 bobPrivateKey;
    address validatorManagerAddress;
    address feeCollectorAddress;

    VaultFactory vaultFactory;
    DelegatorFactory delegatorFactory;
    SlasherFactory slasherFactory;
    L1Registry l1Registry;
    OperatorRegistry operatorRegistry;
    AvalancheL1Middleware middleware;
    OperatorVaultOptInService operatorVaultOptInService;
    OperatorL1OptInService operatorL1OptInService;

    Token collateral;

    VaultTokenized vault;
    L1RestakeDelegator delegator;

    function setUp() public {
        owner = address(this);
        (alice, alicePrivateKey) = makeAddrAndKey("alice");
        (bob, bobPrivateKey) = makeAddrAndKey("bob");
        feeCollectorAddress = makeAddr("feeCollector");
        // Deploy a test collateral token
        collateral = new Token("Token");

        // Deploy factories and registries
        vaultFactory = new VaultFactory(owner);
        delegatorFactory = new DelegatorFactory(owner);
        slasherFactory = new SlasherFactory(owner);
        l1Registry = new L1Registry(
            payable(feeCollectorAddress), // fee collector
            0.01 ether, // initial register fee
            1 ether, // MAX_FEE
            owner
        );
        operatorRegistry = new OperatorRegistry();

        // Deploy middleware service
        MiddlewareHelperConfig helperConfig = new MiddlewareHelperConfig();
        (
            uint256 proxyAdminOwnerKey,
            uint256 protocolOwnerKey,
            bytes32 l1ID,
            uint64 churnPeriodSeconds,
            uint8 maximumChurnPercentage,
            ,
            uint256 primaryAssetMaxStake,
            uint256 primaryAssetMinStake,
            uint256 primaryAssetWeightScaleFactor
        ) = helperConfig.activeNetworkConfig();
        address proxyAdminOwnerAddress = vm.addr(proxyAdminOwnerKey);
        address protocolOwnerAddress = vm.addr(protocolOwnerKey);

        ValidatorManagerSettings memory validatorSettings = ValidatorManagerSettings({
            l1ID: l1ID,
            churnPeriodSeconds: churnPeriodSeconds,
            maximumChurnPercentage: maximumChurnPercentage
        });

        validatorManagerAddress =
            _deployValidatorManager(validatorSettings, proxyAdminOwnerAddress, protocolOwnerAddress);

        // Deploy opt-in services BEFORE middleware creation
        operatorVaultOptInService = new OperatorVaultOptInService(
            address(operatorRegistry), // WHO_REGISTRY (isRegistered)
            address(vaultFactory), // WHERE_REGISTRY (isRegistered)
            "OperatorVaultOptInService"
        );

        operatorL1OptInService = new OperatorL1OptInService(
            address(operatorRegistry), // WHO_REGISTRY (isRegistered)
            address(l1Registry), // WHERE_REGISTRY (isEntity)
            "OperatorL1OptInService"
        );

        AvalancheL1MiddlewareSettings memory middlewareSettings = AvalancheL1MiddlewareSettings({
            l1ValidatorManager: address(validatorManagerAddress),
            operatorRegistry: address(operatorRegistry),
            vaultRegistry: address(vaultFactory),
            operatorL1Optin: address(operatorL1OptInService),
            epochDuration: 4 hours,
            slashingWindow: 5 hours,
            stakeUpdateWindow: 3 hours
        });

        middleware = new AvalancheL1Middleware(
            middlewareSettings,
            owner,
            address(collateral),
            primaryAssetMaxStake,
            primaryAssetMinStake,
            primaryAssetWeightScaleFactor
        );

        vm.startPrank(owner); // the test contract is the current owner
        middleware.transferOwnership(alice);
        vm.stopPrank();

        vm.startPrank(alice);
        middleware.setVaultManager(address(middleware));
        vm.stopPrank();

        // Whitelist vault implementation
        address vaultImpl = address(new VaultTokenized(address(vaultFactory)));
        vaultFactory.whitelist(vaultImpl);

        // Whitelist L1RestakeDelegator
        address l1RestakeDelegatorImpl = address(
            new L1RestakeDelegator(
                address(l1Registry),
                address(vaultFactory),
                address(operatorVaultOptInService),
                address(operatorL1OptInService),
                address(delegatorFactory),
                delegatorFactory.totalTypes()
            )
        );
        delegatorFactory.whitelist(l1RestakeDelegatorImpl);
    }

    function test_Create(
        uint48 epochDuration
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 50 weeks));

        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        // Register an L1 and a subnetwork for testing
        address l1 = alice;
        DummyL1 dummyL1 = new DummyL1(alice);

        // Add funds for registration fee
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        uint256 fee = l1Registry.registerFee();
        vm.prank(alice);
        l1Registry.registerL1{value: fee}(address(dummyL1), address(0), "metadataURL");

        uint96 assetClass = 1;

        assertEq(delegator.VERSION(), 1);
        assertEq(delegator.L1_REGISTRY(), address(l1Registry));
        assertEq(delegator.VAULT_FACTORY(), address(vaultFactory));
        assertEq(delegator.OPERATOR_VAULT_OPT_IN_SERVICE(), address(operatorVaultOptInService));
        assertEq(delegator.OPERATOR_L1_OPT_IN_SERVICE(), address(operatorL1OptInService));
        assertEq(delegator.vault(), address(vault));
        assertEq(delegator.maxL1Limit(l1, assetClass), 0);
        assertEq(delegator.stakeAt(l1, assetClass, alice, 0, ""), 0);
        assertEq(delegator.stake(l1, assetClass, alice), 0);
        assertEq(delegator.L1_LIMIT_SET_ROLE(), keccak256("L1_LIMIT_SET_ROLE"));
        assertEq(delegator.OPERATOR_L1_SHARES_SET_ROLE(), keccak256("OPERATOR_L1_SHARES_SET_ROLE"));
        assertEq(delegator.l1LimitAt(l1, assetClass, 0, ""), 0);
        assertEq(delegator.l1Limit(l1, assetClass), 0);
        // Not set any operator L1 shares yet
        assertEq(delegator.totalOperatorL1SharesAt(l1, assetClass, 0, ""), 0);
        assertEq(delegator.totalOperatorL1Shares(l1, assetClass), 0);
        assertEq(delegator.operatorL1SharesAt(l1, assetClass, alice, 0, ""), 0);
        assertEq(delegator.operatorL1Shares(l1, assetClass, alice), 0);
    }

    function test_CreateRevertNotVault(
        uint48 epochDuration
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 50 weeks));
        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        address[] memory l1LimitSetRoleHolders = new address[](1);
        l1LimitSetRoleHolders[0] = bob;
        address[] memory operatorL1SharesSetRoleHolders = new address[](1);
        operatorL1SharesSetRoleHolders[0] = bob;

        vm.expectRevert(IBaseDelegator.BaseDelegator__NotVault.selector);
        delegatorFactory.create(
            0,
            abi.encode(
                address(1), // not a vault
                abi.encode(
                    IL1RestakeDelegator.InitParams({
                        baseParams: IBaseDelegator.BaseParams({
                            defaultAdminRoleHolder: bob,
                            hook: address(0),
                            hookSetRoleHolder: bob
                        }),
                        l1LimitSetRoleHolders: l1LimitSetRoleHolders,
                        operatorL1SharesSetRoleHolders: operatorL1SharesSetRoleHolders
                    })
                )
            )
        );
    }

    function test_CreateRevertMissingRoleHolders(
        uint48 epochDuration
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 50 weeks));
        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        address[] memory l1LimitSetRoleHolders = new address[](0);
        address[] memory operatorL1SharesSetRoleHolders = new address[](1);
        operatorL1SharesSetRoleHolders[0] = bob;

        vm.expectRevert(IL1RestakeDelegator.L1RestakeDelegator__MissingRoleHolders.selector);
        delegatorFactory.create(
            0,
            abi.encode(
                address(vault),
                abi.encode(
                    IL1RestakeDelegator.InitParams({
                        baseParams: IBaseDelegator.BaseParams({
                            defaultAdminRoleHolder: address(0),
                            hook: address(0),
                            hookSetRoleHolder: address(1)
                        }),
                        l1LimitSetRoleHolders: l1LimitSetRoleHolders,
                        operatorL1SharesSetRoleHolders: operatorL1SharesSetRoleHolders
                    })
                )
            )
        );
    }

    function test_CreateRevertZeroAddressRoleHolder1(
        uint48 epochDuration
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 50 weeks));
        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        address[] memory l1LimitSetRoleHolders = new address[](1);
        l1LimitSetRoleHolders[0] = address(0);
        address[] memory operatorL1SharesSetRoleHolders = new address[](1);
        operatorL1SharesSetRoleHolders[0] = bob;

        vm.expectRevert(IL1RestakeDelegator.L1RestakeDelegator__ZeroAddressRoleHolder.selector);
        delegatorFactory.create(
            0,
            abi.encode(
                address(vault),
                abi.encode(
                    IL1RestakeDelegator.InitParams({
                        baseParams: IBaseDelegator.BaseParams({
                            defaultAdminRoleHolder: address(0),
                            hook: address(0),
                            hookSetRoleHolder: address(1)
                        }),
                        l1LimitSetRoleHolders: l1LimitSetRoleHolders,
                        operatorL1SharesSetRoleHolders: operatorL1SharesSetRoleHolders
                    })
                )
            )
        );
    }

    function test_CreateRevert_DuplicateRoleHolder1(
        uint48 epochDuration
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 50 weeks));

        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        address[] memory l1LimitSetRoleHolders = new address[](2);
        l1LimitSetRoleHolders[0] = bob;
        l1LimitSetRoleHolders[1] = bob;
        address[] memory operatorL1SharesSetRoleHolders = new address[](1);
        operatorL1SharesSetRoleHolders[0] = bob;

        vm.expectRevert(IL1RestakeDelegator.L1RestakeDelegator__DuplicateRoleHolder.selector);
        delegatorFactory.create(
            0,
            abi.encode(
                address(vault),
                abi.encode(
                    IL1RestakeDelegator.InitParams({
                        baseParams: IBaseDelegator.BaseParams({
                            defaultAdminRoleHolder: address(0),
                            hook: address(0),
                            hookSetRoleHolder: address(1)
                        }),
                        l1LimitSetRoleHolders: l1LimitSetRoleHolders,
                        operatorL1SharesSetRoleHolders: operatorL1SharesSetRoleHolders
                    })
                )
            )
        );
    }

    function test_CreateRevert_DuplicateRoleHolder2(
        uint48 epochDuration
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 50 weeks));

        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        address[] memory l1LimitSetRoleHolders = new address[](1);
        l1LimitSetRoleHolders[0] = bob;
        address[] memory operatorL1SharesSetRoleHolders = new address[](2);
        operatorL1SharesSetRoleHolders[0] = bob;
        operatorL1SharesSetRoleHolders[1] = bob;

        vm.expectRevert(IL1RestakeDelegator.L1RestakeDelegator__DuplicateRoleHolder.selector);
        delegatorFactory.create(
            0,
            abi.encode(
                address(vault),
                abi.encode(
                    IL1RestakeDelegator.InitParams({
                        baseParams: IBaseDelegator.BaseParams({
                            defaultAdminRoleHolder: address(0),
                            hook: address(0),
                            hookSetRoleHolder: address(1)
                        }),
                        l1LimitSetRoleHolders: l1LimitSetRoleHolders,
                        operatorL1SharesSetRoleHolders: operatorL1SharesSetRoleHolders
                    })
                )
            )
        );
    }

    function test_SetL1Limit(
        uint48 epochDuration,
        uint256 amount1,
        uint256 amount2,
        uint256 amount3,
        uint256 amount4
    ) public {
        epochDuration = uint48(bound(uint256(epochDuration), 1, 100 days));

        vm.assume(0 != amount1);
        vm.assume(amount1 != amount2);
        vm.assume(amount2 != amount3);
        vm.assume(amount3 != amount4);

        uint256 blockTimestamp = vm.getBlockTimestamp();
        blockTimestamp += 1_720_700_948;
        vm.warp(blockTimestamp);

        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        address l1Owner = alice;
        // 1) get actual L1 contract address
        address dummyL1Addr = _registerL1(l1Owner, address(middleware));
        uint96 assetClass = 1;

        // 2) use dummyL1Addr in place of `l1`
        _setMaxL1Limit(dummyL1Addr, assetClass, type(uint256).max, address(middleware));

        // Calls that used `(alice, l1, ...)` now use `(alice, dummyL1Addr, ...)`
        _setL1Limit(alice, dummyL1Addr, assetClass, amount1);

        assertEq(delegator.l1LimitAt(dummyL1Addr, assetClass, uint48(blockTimestamp), ""), amount1);
        assertEq(delegator.l1LimitAt(dummyL1Addr, assetClass, uint48(blockTimestamp + 1), ""), amount1);
        assertEq(delegator.l1Limit(dummyL1Addr, assetClass), amount1);

        _setL1Limit(alice, dummyL1Addr, assetClass, amount2);

        assertEq(delegator.l1LimitAt(dummyL1Addr, assetClass, uint48(blockTimestamp), ""), amount2);
        assertEq(delegator.l1LimitAt(dummyL1Addr, assetClass, uint48(blockTimestamp + 1), ""), amount2);
        assertEq(delegator.l1Limit(dummyL1Addr, assetClass), amount2);

        blockTimestamp += 1;
        vm.warp(blockTimestamp);

        _setL1Limit(alice, dummyL1Addr, assetClass, amount3);

        assertEq(delegator.l1LimitAt(dummyL1Addr, assetClass, uint48(blockTimestamp - 1), ""), amount2);
        assertEq(delegator.l1LimitAt(dummyL1Addr, assetClass, uint48(blockTimestamp), ""), amount3);
        assertEq(delegator.l1LimitAt(dummyL1Addr, assetClass, uint48(blockTimestamp + 1), ""), amount3);
        assertEq(delegator.l1Limit(dummyL1Addr, assetClass), amount3);

        blockTimestamp++;
        vm.warp(blockTimestamp);

        _setL1Limit(alice, dummyL1Addr, assetClass, amount4);

        assertEq(delegator.l1LimitAt(dummyL1Addr, assetClass, uint48(blockTimestamp - 2), ""), amount2);
        assertEq(delegator.l1LimitAt(dummyL1Addr, assetClass, uint48(blockTimestamp - 1), ""), amount3);
        assertEq(delegator.l1LimitAt(dummyL1Addr, assetClass, uint48(blockTimestamp), ""), amount4);
        assertEq(delegator.l1LimitAt(dummyL1Addr, assetClass, uint48(blockTimestamp + 1), ""), amount4);
        assertEq(delegator.l1Limit(dummyL1Addr, assetClass), amount4);
    }

    function test_SetL1LimitRevertExceedsMaxL1Limit(uint48 epochDuration, uint256 amount1, uint256 maxL1Limit) public {
        epochDuration = uint48(bound(epochDuration, 1, 100 days));
        maxL1Limit = bound(maxL1Limit, 1, type(uint256).max);
        vm.assume(amount1 > maxL1Limit);

        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        address l1 = alice;
        address dummyL1Addr = _registerL1(l1, address(middleware));
        uint96 assetClass = 1;

        _setMaxL1Limit(dummyL1Addr, assetClass, maxL1Limit, address(middleware));

        vm.expectRevert(IL1RestakeDelegator.L1RestakeDelegator__ExceedsMaxL1Limit.selector);
        _setL1Limit(alice, dummyL1Addr, assetClass, amount1);
    }

    function test_SetL1LimitRevertAlreadySet(uint48 epochDuration, uint256 amount1, uint256 maxL1Limit) public {
        epochDuration = uint48(bound(epochDuration, 1, 100 days));
        maxL1Limit = bound(maxL1Limit, 1, type(uint256).max);
        amount1 = bound(amount1, 1, maxL1Limit);

        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        address dummyL1Addr = _registerL1(alice, address(middleware));
        uint96 assetClass = 1;

        _setMaxL1Limit(dummyL1Addr, assetClass, maxL1Limit, address(middleware));

        _setL1Limit(alice, dummyL1Addr, assetClass, amount1);

        vm.expectRevert(IBaseDelegator.BaseDelegator__AlreadySet.selector);
        _setL1Limit(alice, dummyL1Addr, assetClass, amount1);
    }

    function test_SetOperatorL1Limit(
        uint48 epochDuration,
        uint256 amount1,
        uint256 amount2,
        uint256 amount3,
        uint256 amount4
    ) public {
        epochDuration = uint48(bound(uint256(epochDuration), 1, 100 days));
        amount1 = bound(amount1, 1, type(uint256).max);
        vm.assume(amount3 < amount2);
        vm.assume(amount4 > amount2 && amount4 > amount1);

        vm.assume(0 != amount1);
        vm.assume(amount1 != amount2);
        vm.assume(amount2 != amount3);
        vm.assume(amount3 != amount4);

        uint256 blockTimestamp = vm.getBlockTimestamp() * vm.getBlockTimestamp() / vm.getBlockTimestamp()
            * vm.getBlockTimestamp() / vm.getBlockTimestamp();
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        address l1 = alice;
        _registerL1(l1, address(middleware));
        uint96 assetClass = 1;
        address operator = alice;
        _registerOperator(operator, "operatorMetadata");

        _setOperatorL1Shares(alice, l1, assetClass, operator, amount1);

        assertEq(delegator.operatorL1SharesAt(l1, assetClass, operator, uint48(blockTimestamp), ""), amount1);
        assertEq(delegator.operatorL1SharesAt(l1, assetClass, operator, uint48(blockTimestamp + 1), ""), amount1);
        assertEq(delegator.operatorL1Shares(l1, assetClass, operator), amount1);

        _setOperatorL1Shares(alice, l1, assetClass, operator, amount2);

        assertEq(delegator.operatorL1SharesAt(l1, assetClass, operator, uint48(blockTimestamp), ""), amount2);
        assertEq(delegator.operatorL1SharesAt(l1, assetClass, operator, uint48(blockTimestamp + 1), ""), amount2);
        assertEq(delegator.operatorL1Shares(l1, assetClass, operator), amount2);

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        _setOperatorL1Shares(alice, l1, assetClass, operator, amount3);

        assertEq(delegator.operatorL1SharesAt(l1, assetClass, operator, uint48(blockTimestamp - 1), ""), amount2);
        assertEq(delegator.operatorL1SharesAt(l1, assetClass, operator, uint48(blockTimestamp), ""), amount3);
        assertEq(delegator.operatorL1SharesAt(l1, assetClass, operator, uint48(blockTimestamp + 1), ""), amount3);
        assertEq(delegator.operatorL1Shares(l1, assetClass, operator), amount3);

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        _setOperatorL1Shares(alice, l1, assetClass, operator, amount4);

        assertEq(delegator.operatorL1SharesAt(l1, assetClass, operator, uint48(blockTimestamp - 2), ""), amount2);
        assertEq(delegator.operatorL1SharesAt(l1, assetClass, operator, uint48(blockTimestamp - 1), ""), amount3);
        assertEq(delegator.operatorL1SharesAt(l1, assetClass, operator, uint48(blockTimestamp), ""), amount4);
        assertEq(delegator.operatorL1SharesAt(l1, assetClass, operator, uint48(blockTimestamp + 1), ""), amount4);
        assertEq(delegator.operatorL1Shares(l1, assetClass, operator), amount4);
    }

    function test_SetOperatorL1LimitBoth(
        uint48 epochDuration,
        uint256 amount1,
        uint256 amount2,
        uint256 amount3
    ) public {
        epochDuration = uint48(bound(uint256(epochDuration), 1, 100 days));
        amount1 = bound(amount1, 1, type(uint256).max / 2);
        amount2 = bound(amount2, 1, type(uint256).max / 2);
        vm.assume(amount3 < amount2);

        uint256 blockTimestamp = vm.getBlockTimestamp();
        blockTimestamp += 1_720_700_948;
        vm.warp(blockTimestamp);

        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        address l1 = alice;
        // 1) capture the dummy L1 address
        address dummyL1Addr = _registerL1(l1, address(middleware));

        uint96 assetClass = 1;
        _registerOperator(alice, "aliceMetadata");
        _registerOperator(bob, "bobMetadata");

        // 2) wherever you used l1, now use dummyL1Addr
        _setOperatorL1Shares(alice, dummyL1Addr, assetClass, alice, amount1);

        assertEq(delegator.operatorL1SharesAt(dummyL1Addr, assetClass, alice, uint48(blockTimestamp + 1), ""), amount1);
        assertEq(delegator.operatorL1Shares(dummyL1Addr, assetClass, alice), amount1);

        _setOperatorL1Shares(alice, dummyL1Addr, assetClass, bob, amount2);

        assertEq(delegator.operatorL1SharesAt(dummyL1Addr, assetClass, bob, uint48(blockTimestamp + 1), ""), amount2);
        assertEq(delegator.operatorL1Shares(dummyL1Addr, assetClass, bob), amount2);

        blockTimestamp += 1;
        vm.warp(blockTimestamp);

        _setOperatorL1Shares(alice, dummyL1Addr, assetClass, bob, amount3);

        assertEq(delegator.operatorL1SharesAt(dummyL1Addr, assetClass, bob, uint48(blockTimestamp - 1), ""), amount2);
        assertEq(delegator.operatorL1SharesAt(dummyL1Addr, assetClass, bob, uint48(blockTimestamp + 1), ""), amount3);
        assertEq(delegator.operatorL1Shares(dummyL1Addr, assetClass, bob), amount3);
    }

    function test_SetOperatorL1LimitRevertAlreadySet(uint48 epochDuration, uint256 amount1) public {
        epochDuration = uint48(bound(uint256(epochDuration), 1, 100 days));
        amount1 = bound(amount1, 1, type(uint256).max / 2);

        uint256 blockTimestamp = vm.getBlockTimestamp();
        blockTimestamp += 1_720_700_948;
        vm.warp(blockTimestamp);

        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        address l1 = alice;
        // capture dummy address
        address dummyL1Addr = _registerL1(l1, address(middleware));

        uint96 assetClass = 1;
        _registerOperator(alice, "aliceMetadata");

        // now pass dummyL1Addr
        _setOperatorL1Shares(alice, dummyL1Addr, assetClass, alice, amount1);

        vm.startPrank(alice);
        vm.expectRevert(IBaseDelegator.BaseDelegator__AlreadySet.selector);
        delegator.setOperatorL1Shares(dummyL1Addr, assetClass, alice, amount1);
        // ^ using dummyL1Addr again
        vm.stopPrank();
    }

    function test_SetMaxL1Limit(
        uint48 epochDuration,
        uint256 maxL1Limit1,
        uint256 maxL1Limit2,
        uint256 l1Limit1
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 100 days));
        maxL1Limit1 = bound(maxL1Limit1, 1, type(uint256).max);
        vm.assume(maxL1Limit1 > maxL1Limit2);
        vm.assume(maxL1Limit1 >= l1Limit1 && l1Limit1 >= maxL1Limit2);
        vm.assume(l1Limit1 != 0);

        uint256 blockTimestamp = vm.getBlockTimestamp();
        blockTimestamp += 1_720_700_948;
        vm.warp(blockTimestamp);

        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        address l1 = alice;
        // store the actual L1 contract
        address dummyL1Addr = _registerL1(l1, address(middleware));

        uint96 assetClass = 1;

        // use dummyL1Addr
        _setMaxL1Limit(dummyL1Addr, assetClass, maxL1Limit1, address(middleware));

        assertEq(delegator.maxL1Limit(dummyL1Addr, assetClass), maxL1Limit1);

        _setL1Limit(alice, dummyL1Addr, assetClass, l1Limit1);

        assertEq(
            delegator.l1LimitAt(dummyL1Addr, assetClass, uint48(blockTimestamp + 2 * vault.epochDuration()), ""),
            l1Limit1
        );

        uint256 newEpochStart = vault.currentEpochStart() + vault.epochDuration();
        vm.warp(newEpochStart);

        assertEq(
            delegator.l1LimitAt(dummyL1Addr, assetClass, uint48(newEpochStart + vault.epochDuration()), ""), l1Limit1
        );
        assertEq(
            delegator.l1LimitAt(dummyL1Addr, assetClass, uint48(newEpochStart + 2 * vault.epochDuration()), ""),
            l1Limit1
        );

        _setMaxL1Limit(dummyL1Addr, assetClass, maxL1Limit2, address(middleware));

        assertEq(delegator.maxL1Limit(dummyL1Addr, assetClass), maxL1Limit2);
        assertEq(
            delegator.l1LimitAt(dummyL1Addr, assetClass, uint48(newEpochStart + vault.epochDuration()), ""), maxL1Limit2
        );
        assertEq(
            delegator.l1LimitAt(dummyL1Addr, assetClass, uint48(newEpochStart + 2 * vault.epochDuration()), ""),
            maxL1Limit2
        );
    }

    function test_SetMaxL1LimitRevertNotL1(uint48 epochDuration, uint256 maxL1Limit) public {
        epochDuration = uint48(bound(epochDuration, 1, 50 weeks));
        maxL1Limit = bound(maxL1Limit, 1, type(uint256).max);

        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        // capture the dummy L1 for alice
        address dummyL1Addr = _registerL1(alice, address(middleware));
        uint96 assetClass = 1;

        // Bob is not an L1 => revert
        vm.startPrank(bob);
        vm.expectRevert(IBaseDelegator.BaseDelegator__NotL1.selector);
        delegator.setMaxL1Limit(bob, assetClass, maxL1Limit);
        vm.stopPrank();
    }

    function test_SetMaxL1LimitRevertAlreadySet(uint48 epochDuration, uint256 maxL1Limit) public {
        epochDuration = uint48(bound(epochDuration, 1, 50 weeks));
        maxL1Limit = bound(maxL1Limit, 1, type(uint256).max);

        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        // again, store the actual L1 contract for alice
        address dummyL1Addr = _registerL1(alice, address(middleware));
        uint96 assetClass = 1;

        _setMaxL1Limit(dummyL1Addr, assetClass, maxL1Limit, address(middleware));

        vm.startPrank(address(middleware));
        vm.expectRevert(IBaseDelegator.BaseDelegator__AlreadySet.selector);
        delegator.setMaxL1Limit(dummyL1Addr, assetClass, maxL1Limit);
        vm.stopPrank();
    }

    function test_Stakes(
        uint48 epochDuration,
        uint256 depositAmount,
        uint256 withdrawAmount,
        uint256 l1Limit,
        uint256 operatorL1Shares1,
        uint256 operatorL1Shares2,
        uint256 operatorL1Shares3
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 10 days));
        depositAmount = bound(depositAmount, 1, 100 * 10 ** 18);
        withdrawAmount = bound(withdrawAmount, 1, 100 * 10 ** 18);
        l1Limit = bound(l1Limit, 1, type(uint256).max);
        operatorL1Shares1 = bound(operatorL1Shares1, 1, type(uint256).max / 2);
        operatorL1Shares2 = bound(operatorL1Shares2, 1, type(uint256).max / 2);
        operatorL1Shares3 = bound(operatorL1Shares3, 0, type(uint256).max / 2);
        vm.assume(withdrawAmount <= depositAmount);
        vm.assume(operatorL1Shares2 - 1 != operatorL1Shares3);

        uint256 blockTimestamp = vm.getBlockTimestamp();
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        address l1 = alice;
        // 1) Get the actual L1 contract address from _registerL1
        address dummyL1Addr = _registerL1(l1, address(middleware));

        uint96 assetClass = 1;
        // 2) Use the dummyL1Addr when setting the L1 limit
        _setMaxL1Limit(dummyL1Addr, assetClass, type(uint256).max, address(middleware));

        _registerOperator(alice, "aliceMetadata");
        _registerOperator(bob, "bobMetadata");

        // Initially no stake
        assertEq(delegator.stake(dummyL1Addr, assetClass, alice), 0);
        assertEq(delegator.stake(dummyL1Addr, assetClass, bob), 0);

        _optInOperatorVault(alice);
        _optInOperatorVault(bob);

        // Still no stake
        assertEq(delegator.stake(dummyL1Addr, assetClass, alice), 0);
        assertEq(delegator.stake(dummyL1Addr, assetClass, bob), 0);

        // 3) Use dummyL1Addr for operator L1 opt in
        _optInOperatorL1(alice, dummyL1Addr);
        _optInOperatorL1(bob, dummyL1Addr);

        // Deposit + withdraw
        _deposit(alice, depositAmount);
        _withdraw(alice, withdrawAmount);

        // No shares set => no stake
        assertEq(delegator.stake(dummyL1Addr, assetClass, alice), 0);
        assertEq(delegator.stake(dummyL1Addr, assetClass, bob), 0);

        // Now set L1 limit
        _setL1Limit(alice, dummyL1Addr, assetClass, l1Limit);

        assertEq(delegator.stake(dummyL1Addr, assetClass, alice), 0);
        assertEq(delegator.stake(dummyL1Addr, assetClass, bob), 0);

        // Set operator L1 shares for alice
        _setOperatorL1Shares(alice, dummyL1Addr, assetClass, alice, operatorL1Shares1);

        uint256 effectiveStake = Math.min(depositAmount - withdrawAmount, l1Limit);
        // At timestamp = blockTimestamp
        assertEq(
            delegator.stakeAt(dummyL1Addr, assetClass, alice, uint48(blockTimestamp), ""),
            operatorL1Shares1.mulDiv(effectiveStake, operatorL1Shares1)
        );
        assertEq(
            delegator.stake(dummyL1Addr, assetClass, alice), operatorL1Shares1.mulDiv(effectiveStake, operatorL1Shares1)
        );
        assertEq(delegator.stake(dummyL1Addr, assetClass, bob), 0);

        // Bob shares
        _setOperatorL1Shares(alice, dummyL1Addr, assetClass, bob, operatorL1Shares2);

        assertEq(
            delegator.stakeAt(dummyL1Addr, assetClass, alice, uint48(blockTimestamp), ""),
            operatorL1Shares1.mulDiv(effectiveStake, operatorL1Shares1 + operatorL1Shares2)
        );
        assertEq(
            delegator.stake(dummyL1Addr, assetClass, alice),
            operatorL1Shares1.mulDiv(effectiveStake, operatorL1Shares1 + operatorL1Shares2)
        );
        assertEq(
            delegator.stakeAt(dummyL1Addr, assetClass, bob, uint48(blockTimestamp), ""),
            operatorL1Shares2.mulDiv(effectiveStake, operatorL1Shares1 + operatorL1Shares2)
        );
        assertEq(
            delegator.stake(dummyL1Addr, assetClass, bob),
            operatorL1Shares2.mulDiv(effectiveStake, operatorL1Shares1 + operatorL1Shares2)
        );

        // Decrease bob's shares
        _setOperatorL1Shares(alice, dummyL1Addr, assetClass, bob, operatorL1Shares2 - 1);

        assertEq(
            delegator.stakeAt(dummyL1Addr, assetClass, alice, uint48(blockTimestamp), ""),
            operatorL1Shares1.mulDiv(effectiveStake, operatorL1Shares1 + operatorL1Shares2 - 1)
        );
        assertEq(
            delegator.stake(dummyL1Addr, assetClass, alice),
            operatorL1Shares1.mulDiv(effectiveStake, operatorL1Shares1 + operatorL1Shares2 - 1)
        );
        assertEq(
            delegator.stakeAt(dummyL1Addr, assetClass, bob, uint48(blockTimestamp), ""),
            (operatorL1Shares2 - 1).mulDiv(effectiveStake, operatorL1Shares1 + operatorL1Shares2 - 1)
        );
        assertEq(
            delegator.stake(dummyL1Addr, assetClass, bob),
            (operatorL1Shares2 - 1).mulDiv(effectiveStake, operatorL1Shares1 + operatorL1Shares2 - 1)
        );

        // Advance time
        blockTimestamp++;
        vm.warp(blockTimestamp);

        // Further reduce bob's shares
        _setOperatorL1Shares(alice, dummyL1Addr, assetClass, bob, operatorL1Shares3);

        // Check historical state at (blockTimestamp - 1)
        assertEq(
            delegator.stakeAt(dummyL1Addr, assetClass, alice, uint48(blockTimestamp - 1), ""),
            operatorL1Shares1.mulDiv(effectiveStake, operatorL1Shares1 + operatorL1Shares2 - 1)
        );
        assertEq(
            delegator.stakeAt(dummyL1Addr, assetClass, bob, uint48(blockTimestamp - 1), ""),
            (operatorL1Shares2 - 1).mulDiv(effectiveStake, operatorL1Shares1 + operatorL1Shares2 - 1)
        );

        // Current state
        assertEq(
            delegator.stakeAt(dummyL1Addr, assetClass, alice, uint48(blockTimestamp), ""),
            operatorL1Shares1.mulDiv(effectiveStake, operatorL1Shares1 + operatorL1Shares3)
        );
        assertEq(
            delegator.stake(dummyL1Addr, assetClass, alice),
            operatorL1Shares1.mulDiv(effectiveStake, operatorL1Shares1 + operatorL1Shares3)
        );
        assertEq(
            delegator.stakeAt(dummyL1Addr, assetClass, bob, uint48(blockTimestamp), ""),
            operatorL1Shares3.mulDiv(effectiveStake, operatorL1Shares1 + operatorL1Shares3)
        );
        assertEq(
            delegator.stake(dummyL1Addr, assetClass, bob),
            operatorL1Shares3.mulDiv(effectiveStake, operatorL1Shares1 + operatorL1Shares3)
        );

        // Advance again
        blockTimestamp++;
        vm.warp(blockTimestamp);

        // Historical checks
        assertEq(
            delegator.stakeAt(dummyL1Addr, assetClass, alice, uint48(blockTimestamp - 2), ""),
            operatorL1Shares1.mulDiv(effectiveStake, operatorL1Shares1 + operatorL1Shares2 - 1)
        );
        assertEq(
            delegator.stakeAt(dummyL1Addr, assetClass, bob, uint48(blockTimestamp - 2), ""),
            (operatorL1Shares2 - 1).mulDiv(effectiveStake, operatorL1Shares1 + operatorL1Shares2 - 1)
        );
    }

    function test_assetClassVariants() public {
        // Test with a few different assetClasss.
        uint96[] memory assets = new uint96[](3);
        assets[0] = 0;
        assets[1] = 1;
        assets[2] = 42;

        uint48 epochDuration = uint48(bound(uint256(1), 1, 10 days));
        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        address l1 = alice;
        address operatorA = alice;
        address operatorB = bob;
        address dummyL1Addr = _registerL1(l1, address(middleware));
        _registerOperator(operatorA, "operatorA");
        _registerOperator(operatorB, "operatorB");

        _optInOperatorVault(operatorA);
        _optInOperatorVault(operatorB);

        _optInOperatorL1(operatorA, dummyL1Addr);
        _optInOperatorL1(operatorB, dummyL1Addr);

        uint256 depositAmount = 100 * 10 ** 18;
        uint256 l1LimitAmount = 50 * 10 ** 18;
        uint256 operatorAShares = 10;
        uint256 operatorBShares = 5;

        _deposit(alice, depositAmount);

        for (uint256 i = 0; i < assets.length; i++) {
            uint96 asset = assets[i];

            // 3) Use 'dummyL1Addr' instead of 'l1'
            _setMaxL1Limit(dummyL1Addr, asset, type(uint256).max, address(middleware));
            _setL1Limit(alice, dummyL1Addr, asset, l1LimitAmount);

            _setOperatorL1Shares(alice, dummyL1Addr, asset, operatorA, operatorAShares);
            _setOperatorL1Shares(alice, dummyL1Addr, asset, operatorB, operatorBShares);

            // Check stakes
            uint256 totalShares = operatorAShares + operatorBShares;
            uint256 effectiveStake = Math.min(depositAmount, l1LimitAmount);

            uint256 stakeA = delegator.stake(dummyL1Addr, asset, operatorA);
            uint256 stakeB = delegator.stake(dummyL1Addr, asset, operatorB);

            assertEq(stakeA, operatorAShares * effectiveStake / totalShares, "Stake for Operator A mismatch");
            assertEq(stakeB, operatorBShares * effectiveStake / totalShares, "Stake for Operator B mismatch");

            // Adjust operator shares
            _setOperatorL1Shares(alice, dummyL1Addr, asset, operatorB, operatorBShares + 10);
            totalShares = operatorAShares + (operatorBShares + 10);
            stakeA = delegator.stake(dummyL1Addr, asset, operatorA);
            stakeB = delegator.stake(dummyL1Addr, asset, operatorB);

            assertEq(stakeA, operatorAShares * effectiveStake / totalShares, "Updated Stake A mismatch");
            assertEq(stakeB, (operatorBShares + 10) * effectiveStake / totalShares, "Updated Stake B mismatch");
        }
    }

    // TODO: Add slash tests

    function _getVaultAndDelegator(
        uint48 epochDuration
    ) internal returns (VaultTokenized v, L1RestakeDelegator d) {
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

        v = VaultTokenized(vaultAddress);

        address delegatorAddress = delegatorFactory.create(
            0,
            abi.encode(
                address(v),
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
        );

        d = L1RestakeDelegator(delegatorAddress);
        vm.prank(alice);
        v.setDelegator(delegatorAddress);

        return (v, d);
    }

    function _registerOperator(address user, string memory metadataURL) internal {
        vm.startPrank(user);
        operatorRegistry.registerOperator(metadataURL);
        vm.stopPrank();
    }

    function _registerL1(address l1, address _middleware) internal returns (address) {
        DummyL1 dummyL1 = new DummyL1(l1);

        vm.deal(l1, 100 ether);
        vm.startPrank(l1);
        uint256 fee = l1Registry.registerFee();
        l1Registry.registerL1{value: fee}(address(dummyL1), _middleware, "metadataURL");
        vm.stopPrank();

        return address(dummyL1);
    }

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

    function _optInOperatorVault(
        address user
    ) internal {
        vm.startPrank(user);
        operatorVaultOptInService.optIn(address(vault));
        vm.stopPrank();
    }

    function _optOutOperatorVault(
        address user
    ) internal {
        vm.startPrank(user);
        operatorVaultOptInService.optOut(address(vault));
        vm.stopPrank();
    }

    function _optInOperatorL1(address user, address l1) internal {
        vm.startPrank(user);
        operatorL1OptInService.optIn(l1);
        vm.stopPrank();
    }

    function _optOutOperatorL1(address user, address l1) internal {
        vm.startPrank(user);
        operatorL1OptInService.optOut(l1);
        vm.stopPrank();
    }

    function _setDepositWhitelist(address user, bool depositWhitelist) internal {
        vm.startPrank(user);
        vault.setDepositWhitelist(depositWhitelist);
        vm.stopPrank();
    }

    function _setDepositorWhitelistStatus(address user, address depositor, bool status) internal {
        vm.startPrank(user);
        vault.setDepositorWhitelistStatus(depositor, status);
        vm.stopPrank();
    }

    function _setL1Limit(address user, address l1, uint96 assetClass, uint256 amount) internal {
        vm.startPrank(user);
        delegator.setL1Limit(l1, assetClass, amount);
        vm.stopPrank();
    }

    function _setOperatorL1Shares(
        address user,
        address l1,
        uint96 assetClass,
        address operator,
        uint256 shares
    ) internal {
        vm.startPrank(user);
        delegator.setOperatorL1Shares(l1, assetClass, operator, shares);
        vm.stopPrank();
    }

    // function _slash(
    //     address user,
    //     address l1,
    //     address operator,
    //     uint256 amount,
    //     uint48 captureTimestamp,
    //     bytes memory hints
    // ) internal returns (uint256 slashAmount) {
    //     vm.startPrank(user);
    //     slashAmount = slasher.slash(l1.subnetwork(0), operator, amount, captureTimestamp, hints);
    //     vm.stopPrank();
    // }

    function _setMaxL1Limit(address l1, uint96 assetClass, uint256 amount, address _middleware) internal {
        vm.startPrank(_middleware);
        delegator.setMaxL1Limit(l1, assetClass, amount);
        vm.stopPrank();
    }

    // function _setHook(address user, address hook) internal {
    //     vm.startPrank(user);
    //     delegator.setHook(hook);
    //     vm.stopPrank();
    // }

    function _deployValidatorManager(
        ValidatorManagerSettings memory settings,
        address proxyAdminOwnerAddress,
        address protocolOwnerAddress
    ) private returns (address) {
        PoAValidatorManager validatorSetManager = new PoAValidatorManager(ICMInitializable.Allowed);

        address proxy = UnsafeUpgrades.deployTransparentProxy(
            address(validatorSetManager),
            proxyAdminOwnerAddress,
            abi.encodeCall(PoAValidatorManager.initialize, (settings, protocolOwnerAddress))
        );

        return proxy;
    }
}
