// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";

import {VaultFactory} from "../../src/contracts/VaultFactory.sol";
import {DelegatorFactory} from "../../src/contracts/DelegatorFactory.sol";
import {SlasherFactory} from "../../src/contracts/SlasherFactory.sol";
import {L1Registry} from "../../src/contracts/L1Registry.sol";
import {OperatorRegistry} from "../../src/contracts/OperatorRegistry.sol";
// import {NetworkMiddlewareService} from "../../src/contracts/service/NetworkMiddlewareService.sol";
import {OperatorL1OptInService} from "../../src/contracts/service/OperatorL1OptInService.sol";
import {OperatorVaultOptInService} from "../../src/contracts/service/OperatorVaultOptInService.sol";

import {VaultTokenized} from "../../src/contracts/vault/VaultTokenized.sol";
import {L1RestakeDelegator} from "../../src/contracts/delegator/L1RestakeDelegator.sol";

import {IVaultTokenized} from "../../src/interfaces/vault/IVaultTokenized.sol";
import {IL1RestakeDelegator} from "../../src/interfaces/delegator/IL1RestakeDelegator.sol";
import {IBaseDelegator} from "../../src/interfaces/delegator/IBaseDelegator.sol";
import {ISlasher} from "../../src/interfaces/slasher/ISlasher.sol";
import {IBaseSlasher} from "../../src/interfaces/slasher/IBaseSlasher.sol";

import {Token} from "../mocks/MockToken.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract L1RestakeDelegatorTest is Test {
    using Math for uint256;

    address owner;
    address alice;
    uint256 alicePrivateKey;
    address bob;
    uint256 bobPrivateKey;

    VaultFactory vaultFactory;
    DelegatorFactory delegatorFactory;
    SlasherFactory slasherFactory;
    L1Registry l1Registry;
    OperatorRegistry operatorRegistry;
    // NetworkMiddlewareService networkMiddlewareService;
    OperatorVaultOptInService operatorVaultOptInService;
    OperatorL1OptInService operatorL1OptInService;

    Token collateral;

    VaultTokenized vault;
    L1RestakeDelegator delegator;

    function setUp() public {
        owner = address(this);
        (alice, alicePrivateKey) = makeAddrAndKey("alice");
        (bob, bobPrivateKey) = makeAddrAndKey("bob");

        // Deploy factories and registries
        vaultFactory = new VaultFactory(owner);
        delegatorFactory = new DelegatorFactory(owner);
        slasherFactory = new SlasherFactory(owner);
        l1Registry = new L1Registry();
        operatorRegistry = new OperatorRegistry();
        
        // Deploy middleware service
        // networkMiddlewareService = new NetworkMiddlewareService(address(l1Registry));

        // Deploy opt-in services
        operatorVaultOptInService = new OperatorVaultOptInService(
            address(operatorRegistry), // WHO_REGISTRY (isRegistered)
            address(vaultFactory),     // WHERE_REGISTRY (isRegistered)
            "OperatorVaultOptInService"
        );

        operatorL1OptInService = new OperatorL1OptInService(
            address(operatorRegistry), // WHO_REGISTRY (isRegistered)
            address(l1Registry),       // WHERE_REGISTRY (isEntity)
            "OperatorL1OptInService"
        );

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

        // Deploy a test collateral token
        collateral = new Token("Token");
    }

    function test_Create(uint48 epochDuration) public {
        epochDuration = uint48(bound(epochDuration, 1, 50 weeks));

        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        // Register an L1 and a subnetwork for testing
        l1Registry.registerL1(alice, address(0), "metadataURL");
        bytes32 subnetwork = l1Registry.registerSubnetwork(alice, 0);

        assertEq(delegator.VERSION(), 1);
        assertEq(delegator.L1_REGISTRY(), address(l1Registry));
        assertEq(delegator.VAULT_FACTORY(), address(vaultFactory));
        assertEq(delegator.OPERATOR_VAULT_OPT_IN_SERVICE(), address(operatorVaultOptInService));
        assertEq(delegator.OPERATOR_L1_OPT_IN_SERVICE(), address(operatorL1OptInService));
        assertEq(delegator.vault(), address(vault));
        assertEq(delegator.maxL1Limit(subnetwork), 0);
        assertEq(delegator.stakeAt(subnetwork, alice, 0, ""), 0);
        assertEq(delegator.stake(subnetwork, alice), 0);
        assertEq(delegator.L1_LIMIT_SET_ROLE(), keccak256("L1_LIMIT_SET_ROLE"));
        assertEq(delegator.OPERATOR_L1_SHARES_SET_ROLE(), keccak256("OPERATOR_L1_SHARES_SET_ROLE"));
        assertEq(delegator.l1LimitAt(subnetwork, 0, ""), 0);
        assertEq(delegator.l1Limit(subnetwork), 0);
        // Not set any operator L1 shares yet
        assertEq(delegator.totalOperatorL1SharesAt(subnetwork, 0, ""), 0);
        assertEq(delegator.totalOperatorL1Shares(subnetwork), 0);
        assertEq(delegator.operatorL1SharesAt(subnetwork, alice, 0, ""), 0);
        assertEq(delegator.operatorL1Shares(subnetwork, alice), 0);
    }

    function test_CreateRevertNotVault(uint48 epochDuration) public {
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

    function test_CreateRevertMissingRoleHolders(uint48 epochDuration) public {
        epochDuration = uint48(bound(epochDuration, 1, 50 weeks));
        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        address[] memory l1LimitSetRoleHolders = new address[](0);
        address[] memory operatorL1SharesSetRoleHolders = new address[](1);
        operatorL1SharesSetRoleHolders[0] = bob;

        vm.expectRevert(IL1RestakeDelegator.MissingRoleHolders.selector);
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

    function test_CreateRevertZeroAddressRoleHolder1(uint48 epochDuration) public {
        epochDuration = uint48(bound(epochDuration, 1, 50 weeks));
        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        address[] memory l1LimitSetRoleHolders = new address[](1);
        l1LimitSetRoleHolders[0] = address(0);
        address[] memory operatorL1SharesSetRoleHolders = new address[](1);
        operatorL1SharesSetRoleHolders[0] = bob;

        vm.expectRevert(IL1RestakeDelegator.ZeroAddressRoleHolder.selector);
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


    function test_CreateRevertDuplicateRoleHolder1(uint48 epochDuration) public {
        epochDuration = uint48(bound(epochDuration, 1, 50 weeks));

        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        address[] memory l1LimitSetRoleHolders = new address[](2);
        l1LimitSetRoleHolders[0] = bob;
        l1LimitSetRoleHolders[1] = bob;
        address[] memory operatorL1SharesSetRoleHolders = new address[](1);
        operatorL1SharesSetRoleHolders[0] = bob;

        vm.expectRevert(IL1RestakeDelegator.DuplicateRoleHolder.selector);
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

    function test_CreateRevertDuplicateRoleHolder2(uint48 epochDuration) public {
        epochDuration = uint48(bound(epochDuration, 1, 50 weeks));

        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        address[] memory l1LimitSetRoleHolders = new address[](1);
        l1LimitSetRoleHolders[0] = bob;
        address[] memory operatorL1SharesSetRoleHolders = new address[](2);
        operatorL1SharesSetRoleHolders[0] = bob;
        operatorL1SharesSetRoleHolders[1] = bob;

        vm.expectRevert(IL1RestakeDelegator.DuplicateRoleHolder.selector);
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

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        address l1 = bob;
        _registerL1(l1, bob);
        bytes32 subnetwork = l1Registry.registerSubnetwork(l1, 0);

        _setMaxL1Limit(l1, 0, type(uint256).max);

        _setL1Limit(alice, subnetwork, amount1);

        assertEq(delegator.l1LimitAt(subnetwork, uint48(blockTimestamp), ""), amount1);
        assertEq(delegator.l1LimitAt(subnetwork, uint48(blockTimestamp + 1), ""), amount1);
        assertEq(delegator.l1Limit(subnetwork), amount1);

        _setL1Limit(alice, subnetwork, amount2);

        assertEq(delegator.l1LimitAt(subnetwork, uint48(blockTimestamp), ""), amount2);
        assertEq(delegator.l1LimitAt(subnetwork, uint48(blockTimestamp + 1), ""), amount2);
        assertEq(delegator.l1Limit(subnetwork), amount2);

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        _setL1Limit(alice, subnetwork, amount3);

        assertEq(delegator.l1LimitAt(subnetwork, uint48(blockTimestamp - 1), ""), amount2);
        assertEq(delegator.l1LimitAt(subnetwork, uint48(blockTimestamp), ""), amount3);
        assertEq(delegator.l1LimitAt(subnetwork, uint48(blockTimestamp + 1), ""), amount3);
        assertEq(delegator.l1Limit(subnetwork), amount3);

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        _setL1Limit(alice, subnetwork, amount4);

        assertEq(delegator.l1LimitAt(subnetwork, uint48(blockTimestamp - 2), ""), amount2);
        assertEq(delegator.l1LimitAt(subnetwork, uint48(blockTimestamp - 1), ""), amount3);
        assertEq(delegator.l1LimitAt(subnetwork, uint48(blockTimestamp), ""), amount4);
        assertEq(delegator.l1LimitAt(subnetwork, uint48(blockTimestamp + 1), ""), amount4);
        assertEq(delegator.l1Limit(subnetwork), amount4);
    }

    function test_SetL1LimitRevertExceedsMaxL1Limit(
        uint48 epochDuration,
        uint256 amount1,
        uint256 maxL1Limit
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 100 days));
        maxL1Limit = bound(maxL1Limit, 1, type(uint256).max);
        vm.assume(amount1 > maxL1Limit);

        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        address l1 = bob;
        _registerL1(l1, bob);
        bytes32 subnetwork = l1Registry.registerSubnetwork(l1, 0);

        _setMaxL1Limit(l1, 0, maxL1Limit);

        vm.expectRevert(IL1RestakeDelegator.ExceedsMaxL1Limit.selector);
        _setL1Limit(alice, subnetwork, amount1);
    }

    function test_SetL1LimitRevertAlreadySet(
        uint48 epochDuration,
        uint256 amount1,
        uint256 maxL1Limit
    ) public {
        epochDuration = uint48(bound(epochDuration, 1, 100 days));
        maxL1Limit = bound(maxL1Limit, 1, type(uint256).max);
        amount1 = bound(amount1, 1, maxL1Limit);

        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        address l1 = bob;
        _registerL1(l1, bob);
        bytes32 subnetwork = l1Registry.registerSubnetwork(l1, 0);

        _setMaxL1Limit(l1, 0, maxL1Limit);

        _setL1Limit(alice, subnetwork, amount1);

        vm.expectRevert(IBaseDelegator.BaseDelegator__AlreadySet.selector);
        _setL1Limit(alice, subnetwork, amount1);
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

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        address l1 = bob;
        _registerL1(l1, bob);
        bytes32 subnetwork = l1Registry.registerSubnetwork(l1, 0);
        address operator = bob;
        _registerOperator(operator, "operatorMetadata");

        _setOperatorL1Shares(alice, subnetwork, operator, amount1);

        assertEq(delegator.operatorL1SharesAt(subnetwork, operator, uint48(blockTimestamp), ""), amount1);
        assertEq(delegator.operatorL1SharesAt(subnetwork, operator, uint48(blockTimestamp + 1), ""), amount1);
        assertEq(delegator.operatorL1Shares(subnetwork, operator), amount1);

        _setOperatorL1Shares(alice, subnetwork, operator, amount2);

        assertEq(delegator.operatorL1SharesAt(subnetwork, operator, uint48(blockTimestamp), ""), amount2);
        assertEq(delegator.operatorL1SharesAt(subnetwork, operator, uint48(blockTimestamp + 1), ""), amount2);
        assertEq(delegator.operatorL1Shares(subnetwork, operator), amount2);

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        _setOperatorL1Shares(alice, subnetwork, operator, amount3);

        assertEq(delegator.operatorL1SharesAt(subnetwork, operator, uint48(blockTimestamp - 1), ""), amount2);
        assertEq(delegator.operatorL1SharesAt(subnetwork, operator, uint48(blockTimestamp), ""), amount3);
        assertEq(delegator.operatorL1SharesAt(subnetwork, operator, uint48(blockTimestamp + 1), ""), amount3);
        assertEq(delegator.operatorL1Shares(subnetwork, operator), amount3);

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        _setOperatorL1Shares(alice, subnetwork, operator, amount4);

        assertEq(delegator.operatorL1SharesAt(subnetwork, operator, uint48(blockTimestamp - 2), ""), amount2);
        assertEq(delegator.operatorL1SharesAt(subnetwork, operator, uint48(blockTimestamp - 1), ""), amount3);
        assertEq(delegator.operatorL1SharesAt(subnetwork, operator, uint48(blockTimestamp), ""), amount4);
        assertEq(delegator.operatorL1SharesAt(subnetwork, operator, uint48(blockTimestamp + 1), ""), amount4);
        assertEq(delegator.operatorL1Shares(subnetwork, operator), amount4);
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

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        address l1 = bob;
        _registerL1(l1, bob);
        bytes32 subnetwork = l1Registry.registerSubnetwork(l1, 0);
        _registerOperator(alice, "aliceMetadata");
        _registerOperator(bob, "bobMetadata");

        _setOperatorL1Shares(alice, subnetwork, alice, amount1);

        assertEq(delegator.operatorL1SharesAt(subnetwork, alice, uint48(blockTimestamp + 1), ""), amount1);
        assertEq(delegator.operatorL1Shares(subnetwork, alice), amount1);

        _setOperatorL1Shares(alice, subnetwork, bob, amount2);

        assertEq(delegator.operatorL1SharesAt(subnetwork, bob, uint48(blockTimestamp + 1), ""), amount2);
        assertEq(delegator.operatorL1Shares(subnetwork, bob), amount2);

        blockTimestamp = blockTimestamp + 1;
        vm.warp(blockTimestamp);

        _setOperatorL1Shares(alice, subnetwork, bob, amount3);

        assertEq(delegator.operatorL1SharesAt(subnetwork, bob, uint48(blockTimestamp - 1), ""), amount2);
        assertEq(delegator.operatorL1SharesAt(subnetwork, bob, uint48(blockTimestamp + 1), ""), amount3);
        assertEq(delegator.operatorL1Shares(subnetwork, bob), amount3);
    }

    function test_SetOperatorL1LimitRevertAlreadySet(uint48 epochDuration, uint256 amount1) public {
        epochDuration = uint48(bound(uint256(epochDuration), 1, 100 days));
        amount1 = bound(amount1, 1, type(uint256).max / 2);

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        address l1 = bob;
        _registerL1(l1, bob);
        bytes32 subnetwork = l1Registry.registerSubnetwork(l1, 0);
        _registerOperator(alice, "aliceMetadata");

        _setOperatorL1Shares(alice, subnetwork, alice, amount1);

        vm.startPrank(alice);
        vm.expectRevert(IBaseDelegator.BaseDelegator__AlreadySet.selector);
        delegator.setOperatorL1Shares(subnetwork, alice, amount1);
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
        vm.assume(0 != l1Limit1);

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        address l1 = alice;
        _registerL1(l1, alice);
        bytes32 subnetwork = l1Registry.registerSubnetwork(l1, 0);

        _setMaxL1Limit(l1, 0, maxL1Limit1);

        assertEq(delegator.maxL1Limit(subnetwork), maxL1Limit1);

        _setL1Limit(alice, subnetwork, l1Limit1);

        assertEq(
            delegator.l1LimitAt(subnetwork, uint48(blockTimestamp + 2 * vault.epochDuration()), ""),
            l1Limit1
        );

        uint256 newEpochStart = vault.currentEpochStart() + vault.epochDuration();
        vm.warp(newEpochStart);

        assertEq(
            delegator.l1LimitAt(subnetwork, uint48(newEpochStart + vault.epochDuration()), ""),
            l1Limit1
        );
        assertEq(
            delegator.l1LimitAt(subnetwork, uint48(newEpochStart + 2 * vault.epochDuration()), ""),
            l1Limit1
        );

        _setMaxL1Limit(l1, 0, maxL1Limit2);

        assertEq(delegator.maxL1Limit(subnetwork), maxL1Limit2);
        assertEq(
            delegator.l1LimitAt(subnetwork, uint48(newEpochStart + vault.epochDuration()), ""),
            maxL1Limit2
        );
        assertEq(
            delegator.l1LimitAt(subnetwork, uint48(newEpochStart + 2 * vault.epochDuration()), ""),
            maxL1Limit2
        );
    }

    function test_SetMaxL1LimitRevertNotL1(uint48 epochDuration, uint256 maxL1Limit) public {
        epochDuration = uint48(bound(epochDuration, 1, 50 weeks));
        maxL1Limit = bound(maxL1Limit, 1, type(uint256).max);

        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        _registerL1(alice, alice);
        l1Registry.registerSubnetwork(alice, 0);

        // Bob is not an L1
        vm.startPrank(bob);
        vm.expectRevert(IBaseDelegator.BaseDelegator__NotL1.selector);
        delegator.setMaxL1Limit(0, maxL1Limit);
        vm.stopPrank();
    }

    function test_SetMaxL1LimitRevertAlreadySet(uint48 epochDuration, uint256 maxL1Limit) public {
        epochDuration = uint48(bound(epochDuration, 1, 50 weeks));
        maxL1Limit = bound(maxL1Limit, 1, type(uint256).max);

        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        _registerL1(alice, alice);
        l1Registry.registerSubnetwork(alice, 0);

        _setMaxL1Limit(alice, 0, maxL1Limit);

        vm.startPrank(alice);
        vm.expectRevert(IBaseDelegator.BaseDelegator__AlreadySet.selector);
        delegator.setMaxL1Limit(0, maxL1Limit);
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

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        // Creates the vault and delegator, ensures vault is registred "entity"
  
        (vault, delegator) = _getVaultAndDelegator(epochDuration);

        address l1 = alice;
        _registerL1(l1, alice);
        bytes32 subnetwork = l1Registry.registerSubnetwork(l1, 0);
        _setMaxL1Limit(l1, 0, type(uint256).max);

        _registerOperator(alice, "aliceMetadata");
        _registerOperator(bob, "bobMetadata");

        // Initially no stake
        assertEq(delegator.stake(subnetwork, alice), 0);
        assertEq(delegator.stake(subnetwork, bob), 0);

        _optInOperatorVault(alice);
        _optInOperatorVault(bob);

        assertEq(delegator.stake(subnetwork, alice), 0);
        assertEq(delegator.stake(subnetwork, bob), 0);

        _optInOperatorL1(alice, l1);
        _optInOperatorL1(bob, l1);

        assertEq(delegator.stake(subnetwork, alice), 0);
        assertEq(delegator.stake(subnetwork, bob), 0);

        // Deposit and withdraw before setting any limits/shares
        _deposit(alice, depositAmount);
        _withdraw(alice, withdrawAmount);

        assertEq(delegator.stake(subnetwork, alice), 0);
        assertEq(delegator.stake(subnetwork, bob), 0);

        // Set L1 limit
        _setL1Limit(alice, subnetwork, l1Limit);

        assertEq(delegator.stake(subnetwork, alice), 0);
        assertEq(delegator.stake(subnetwork, bob), 0);

        // Set operator L1 shares for alice
        _setOperatorL1Shares(alice, subnetwork, alice, operatorL1Shares1);
        // Checking if CURRENT timestamp is fine
        uint256 effectiveStake = Math.min(depositAmount - withdrawAmount, l1Limit);
        assertEq(
            delegator.stakeAt(subnetwork, alice, uint48(blockTimestamp), ""),
            operatorL1Shares1.mulDiv(effectiveStake, operatorL1Shares1)
        );
        assertEq(
            delegator.stake(subnetwork, alice),
            operatorL1Shares1.mulDiv(effectiveStake, operatorL1Shares1)
        );
        assertEq(delegator.stake(subnetwork, bob), 0);

        // Set operator L1 shares for bob
        _setOperatorL1Shares(alice, subnetwork, bob, operatorL1Shares2);
        // Check again current timestamp
        assertEq(
            delegator.stakeAt(subnetwork, alice, uint48(blockTimestamp), ""),
            operatorL1Shares1.mulDiv(effectiveStake, operatorL1Shares1 + operatorL1Shares2)
        );
        assertEq(
            delegator.stake(subnetwork, alice),
            operatorL1Shares1.mulDiv(effectiveStake, operatorL1Shares1 + operatorL1Shares2)
        );
        assertEq(
            delegator.stakeAt(subnetwork, bob, uint48(blockTimestamp), ""),
            operatorL1Shares2.mulDiv(effectiveStake, operatorL1Shares1 + operatorL1Shares2)
        );
        assertEq(
            delegator.stake(subnetwork, bob),
            operatorL1Shares2.mulDiv(effectiveStake, operatorL1Shares1 + operatorL1Shares2)
        );

        // Decrease bob's shares at current timestamp
        _setOperatorL1Shares(alice, subnetwork, bob, operatorL1Shares2 - 1);
        assertEq(
            delegator.stakeAt(subnetwork, alice, uint48(blockTimestamp), ""),
            operatorL1Shares1.mulDiv(effectiveStake, operatorL1Shares1 + operatorL1Shares2 - 1)
        );
        assertEq(
            delegator.stake(subnetwork, alice),
            operatorL1Shares1.mulDiv(effectiveStake, operatorL1Shares1 + operatorL1Shares2 - 1)
        );
        assertEq(
            delegator.stakeAt(subnetwork, bob, uint48(blockTimestamp), ""),
            (operatorL1Shares2 - 1).mulDiv(effectiveStake, operatorL1Shares1 + operatorL1Shares2 - 1)
        );
        assertEq(
            delegator.stake(subnetwork, bob),
            (operatorL1Shares2 - 1).mulDiv(effectiveStake, operatorL1Shares1 + operatorL1Shares2 - 1)
        );

        // Advance time
        blockTimestamp++;
        vm.warp(blockTimestamp);

        // Reduce bob's shares again
        _setOperatorL1Shares(alice, subnetwork, bob, operatorL1Shares3);

        // Check the state at blockTimestamp - 1
        assertEq(
            delegator.stakeAt(subnetwork, alice, uint48(blockTimestamp - 1), ""),
            operatorL1Shares1.mulDiv(effectiveStake, operatorL1Shares1 + operatorL1Shares2 - 1)
        );
        assertEq(
            delegator.stakeAt(subnetwork, bob, uint48(blockTimestamp - 1), ""),
            (operatorL1Shares2 - 1).mulDiv(effectiveStake, operatorL1Shares1 + operatorL1Shares2 - 1)
        );

        // Current state after changes
        assertEq(
            delegator.stakeAt(subnetwork, alice, uint48(blockTimestamp), ""),
            operatorL1Shares1.mulDiv(effectiveStake, operatorL1Shares1 + operatorL1Shares3)
        );
        assertEq(
            delegator.stake(subnetwork, alice),
            operatorL1Shares1.mulDiv(effectiveStake, operatorL1Shares1 + operatorL1Shares3)
        );
        assertEq(
            delegator.stakeAt(subnetwork, bob, uint48(blockTimestamp), ""),
            operatorL1Shares3.mulDiv(effectiveStake, operatorL1Shares1 + operatorL1Shares3)
        );
        assertEq(
            delegator.stake(subnetwork, bob),
            operatorL1Shares3.mulDiv(effectiveStake, operatorL1Shares1 + operatorL1Shares3)
        );

        // Advance time again
        blockTimestamp++;
        vm.warp(blockTimestamp);

        // Historical checks (blockTimestamp - 2), should be stable
        assertEq(
            delegator.stakeAt(subnetwork, alice, uint48(blockTimestamp - 2), ""),
            operatorL1Shares1.mulDiv(effectiveStake, operatorL1Shares1 + operatorL1Shares2 - 1)
        );
        assertEq(
            delegator.stakeAt(subnetwork, bob, uint48(blockTimestamp - 2), ""),
            (operatorL1Shares2 - 1).mulDiv(effectiveStake, operatorL1Shares1 + operatorL1Shares2 - 1)
        );


    }


    // Slash tests missing currently  


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
        v.setDelegator(delegatorAddress);

        return (v, d);
    }

    function _registerOperator(address user, string memory metadataURL) internal {
        vm.startPrank(user);
        operatorRegistry.registerOperator(metadataURL);
        vm.stopPrank();
    }

    function _registerL1(address l1, address middleware) internal {
        vm.prank(l1);
        l1Registry.registerL1(l1, middleware, "metadataURL");
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

    function _setL1Limit(address user, bytes32 subnetwork, uint256 amount) internal {
        vm.startPrank(user);
        delegator.setL1Limit(subnetwork, amount);
        vm.stopPrank();
    }

    function _setOperatorL1Shares(address user, bytes32 subnetwork, address operator, uint256 shares) internal {
        vm.startPrank(user);
        delegator.setOperatorL1Shares(subnetwork, operator, shares);
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

    function _setMaxL1Limit(address user, uint96 identifier, uint256 amount) internal {
        vm.startPrank(user);
        delegator.setMaxL1Limit(identifier, amount);
        vm.stopPrank();
    }

    // function _setHook(address user, address hook) internal {
    //     vm.startPrank(user);
    //     delegator.setHook(hook);
    //     vm.stopPrank();
    // }
}
