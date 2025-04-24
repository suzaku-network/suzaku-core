// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";

import {ValidatorManagerSettings} from "@avalabs/teleporter/validator-manager/interfaces/IValidatorManager.sol";
import {PoAValidatorManager} from "@avalabs/teleporter/validator-manager/PoAValidatorManager.sol";
import {UnsafeUpgrades} from "@openzeppelin/foundry-upgrades/Upgrades.sol";
import {ICMInitializable} from "@avalabs/teleporter/utilities/ICMInitializable.sol";
import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";

import {
    AvalancheL1Middleware,
    AvalancheL1MiddlewareSettings
} from "../../src/contracts/middleware/AvalancheL1Middleware.sol";
import {MiddlewareVaultManager} from "../../src/contracts/middleware/MiddlewareVaultManager.sol";
import {AssetClassRegistry} from "../../src/contracts/middleware/AssetClassRegistry.sol";
import {VaultFactory} from "../../src/contracts/VaultFactory.sol";
import {DelegatorFactory} from "../../src/contracts/DelegatorFactory.sol";
import {SlasherFactory} from "../../src/contracts/SlasherFactory.sol";
import {L1Registry} from "../../src/contracts/L1Registry.sol";
import {OperatorRegistry} from "../../src/contracts/OperatorRegistry.sol";
import {OperatorL1OptInService} from "../../src/contracts/service/OperatorL1OptInService.sol";
import {OperatorVaultOptInService} from "../../src/contracts/service/OperatorVaultOptInService.sol";
import {VaultTokenized} from "../../src/contracts/vault/VaultTokenized.sol";
import {L1RestakeDelegator} from "../../src/contracts/delegator/L1RestakeDelegator.sol";
import {MiddlewareHelperConfig} from "../../script/middleware/anvil/MiddlewareHelperConfig.s.sol";
import {MockBalancerValidatorManager} from "../mocks/MockBalancerValidatorManager.sol";

import {BalancerValidatorManager} from
    "@suzaku/contracts-library/contracts/ValidatorManager/BalancerValidatorManager.sol";
import {ACP77WarpMessengerTestMock} from "@suzaku/contracts-library/contracts/mocks/ACP77WarpMessengerTestMock.sol";
import {IBalancerValidatorManager} from
    "@suzaku/contracts-library/interfaces/ValidatorManager/IBalancerValidatorManager.sol";
import {IWarpMessenger} from "@avalabs/subnet-evm-contracts@1.2.0/contracts/interfaces/IWarpMessenger.sol";
import {
    ConversionData,
    InitialValidator,
    PChainOwner,
    Validator,
    ValidatorRegistrationInput,
    ValidatorStatus
} from "@avalabs/teleporter/validator-manager/interfaces/IValidatorManager.sol";

import {Token} from "../mocks/MockToken.sol";

import {IBaseDelegator} from "../../src/interfaces/delegator/IBaseDelegator.sol";
import {IOperatorRegistry} from "../../src/interfaces/IOperatorRegistry.sol";
import {IVaultTokenized} from "../../src/interfaces/vault/IVaultTokenized.sol";
import {IL1RestakeDelegator} from "../../src/interfaces/delegator/IL1RestakeDelegator.sol";
import {IAvalancheL1Middleware} from "../../src/interfaces/middleware/IAvalancheL1Middleware.sol";
import {StakeConversion} from "../../src/contracts/middleware/libraries/StakeConversion.sol";

contract AvalancheL1MiddlewareTest is Test {
    address internal owner;
    address internal validatorManagerAddress;
    address internal alice;
    uint256 internal alicePrivateKey;
    address internal bob;
    uint256 internal bobPrivateKey;
    address internal charlie;
    uint256 internal charliePrivateKey;
    address internal tokenA;
    address internal tokenB;
    address internal l1;
    uint256 internal l1PrivateKey;
    uint96 internal assetClassId;
    uint256 internal maxVaultL1Limit;
    uint256 internal depositedAmount;
    uint256 internal mintedShares;
    address internal feeCollectorAddress;

    // Factories & Registries
    VaultFactory internal vaultFactory;
    DelegatorFactory internal delegatorFactory;
    SlasherFactory internal slasherFactory;
    L1Registry internal l1Registry;
    OperatorRegistry internal operatorRegistry;
    OperatorVaultOptInService internal operatorVaultOptInService;
    OperatorL1OptInService internal operatorL1OptInService;
    VaultTokenized internal vault;
    L1RestakeDelegator internal delegator;
    AvalancheL1Middleware internal middleware;
    MiddlewareVaultManager internal vaultManager;
    Token internal collateral;
    MockBalancerValidatorManager internal mockValidatorManager;

    function setUp() public {
        owner = address(this);
        (alice, alicePrivateKey) = makeAddrAndKey("alice");
        (bob, bobPrivateKey) = makeAddrAndKey("bob");
        (l1, l1PrivateKey) = makeAddrAndKey("l1");
        tokenA = makeAddr("tokenA");
        tokenB = makeAddr("tokenB");
        feeCollectorAddress = makeAddr("feeCollector");
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

        MiddlewareHelperConfig helperConfig = new MiddlewareHelperConfig();
        (
            ,
            ,
            ,
            ,
            ,
            address primaryAsset,
            uint256 primaryAssetMaxStake,
            uint256 primaryAssetMinStake,
            uint256 primaryAssetWeightScaleFactor
        ) = helperConfig.activeNetworkConfig();

        mockValidatorManager = new MockBalancerValidatorManager(owner);
        validatorManagerAddress = address(mockValidatorManager);

        operatorVaultOptInService = new OperatorVaultOptInService(
            address(operatorRegistry), // whoRegistry
            address(vaultFactory), // whereRegistry
            "OperatorVaultOptInService"
        );

        operatorL1OptInService = new OperatorL1OptInService(
            address(operatorRegistry), // whoRegistry
            address(l1Registry), // whereRegistry
            "OperatorL1OptInService"
        );

        // Whitelist a vault implementation
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

        // Create a test collateral token
        collateral = new Token("MockCollateral");
        primaryAsset = address(collateral);

        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        // Deploy vaultTokenized
        uint48 epochDuration = 8 hours;
        uint64 lastVersion = vaultFactory.lastVersion();
        address vaultAddress = vaultFactory.create(
            lastVersion,
            bob,
            abi.encode(
                IVaultTokenized.InitParams({
                    collateral: address(collateral),
                    burner: address(0xdEaD),
                    epochDuration: epochDuration,
                    depositWhitelist: false,
                    isDepositLimit: false,
                    depositLimit: 0,
                    defaultAdminRoleHolder: bob,
                    depositWhitelistSetRoleHolder: bob,
                    depositorWhitelistRoleHolder: bob,
                    isDepositLimitSetRoleHolder: bob,
                    depositLimitSetRoleHolder: bob,
                    name: "Test",
                    symbol: "TEST"
                })
            ),
            address(delegatorFactory),
            address(slasherFactory)
        );

        vault = VaultTokenized(vaultAddress);

        // Deploy delegator
        address[] memory l1LimitSetRoleHolders = new address[](1);
        l1LimitSetRoleHolders[0] = bob;
        address[] memory operatorL1SharesSetRoleHolders = new address[](1);
        operatorL1SharesSetRoleHolders[0] = bob;

        address delegatorAddress = delegatorFactory.create(
            0,
            abi.encode(
                address(vault),
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

        delegator = L1RestakeDelegator(delegatorAddress);

        // Set the delegator in the vault
        vm.prank(bob);
        vault.setDelegator(delegatorAddress);

        // Deploy the middleware
        AvalancheL1MiddlewareSettings memory middlewareSettings = AvalancheL1MiddlewareSettings({
            l1ValidatorManager: validatorManagerAddress,
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
            primaryAsset,
            primaryAssetMaxStake,
            primaryAssetMinStake,
            primaryAssetWeightScaleFactor
        );

        vaultManager = new MiddlewareVaultManager(address(vaultFactory), owner, address(middleware));
        // middleware.addAssetClass(2, primaryAssetMinStake, primaryAssetMaxStake);
        // middleware.activateSecondaryAssetClass(0);

        // Set the vault manager in the middleware
        middleware.setVaultManager(address(vaultManager));

        middleware.transferOwnership(validatorManagerAddress);
        vaultManager.transferOwnership(validatorManagerAddress);

        // middleware = new AvalancheL1Middleware();
        uint64 maxWeight = 18 ether;
        mockValidatorManager.setupSecurityModule(address(middleware), maxWeight);

        // Maybe not recomended, but passing the ownership to itself
        mockValidatorManager.transferOwnership(validatorManagerAddress);
        
        // Give validatorManager some ETH to pay the registration fee
        vm.deal(validatorManagerAddress, 1 ether);
        
        _registerL1(validatorManagerAddress, address(middleware));
        assetClassId = 1;
        maxVaultL1Limit = 2000 ether;
        vm.startPrank(validatorManagerAddress);
        vaultManager.registerVault(address(vault), assetClassId, maxVaultL1Limit);
        vm.stopPrank();

        _registerOperator(alice, "alice metadata");
        _optInOperatorL1(alice, validatorManagerAddress);
        _optInOperatorVault(alice);

        vm.startPrank(validatorManagerAddress);
        middleware.registerOperator(alice);
        vm.stopPrank();

        _grantDepositorWhitelistRole(bob, alice);
        (depositedAmount, mintedShares) = _deposit(alice, 200_000_000_002_000);
        uint256 l1Limit = 1500 ether;
        _setL1Limit(bob, validatorManagerAddress, assetClassId, l1Limit);
        _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, alice, mintedShares);
    }

    function test_DepositAndGetOperatorStake() public view {
        // middleware.addAssetToClass(1, address(collateral));
        uint48 epoch = middleware.getCurrentEpoch();
        uint256 stakeAlice = middleware.getOperatorStake(alice, epoch, assetClassId);
        console2.log("Alice stake:", stakeAlice);
        // Just a simple check
        assertGt(stakeAlice, 0, "Bob's stake should be > 0 now");
    }

    function test_AddNodeWithStakeAndTimeAdvance() public {
        // Move forward to let the vault roll epochs
        _calcAndWarpOneEpoch();

        uint48 currentEpoch = middleware.getCurrentEpoch();
        uint256 operatorStake = middleware.getOperatorStake(alice, currentEpoch, assetClassId);
        console2.log("Operator stake (epoch", currentEpoch, "):", operatorStake);
        assertGt(operatorStake, 0);

        // Move the vault epoch again
        _calcAndWarpOneEpoch();

        // Recalc stakes for new epoch
        uint48 newEpoch = middleware.getCurrentEpoch();
        middleware.calcAndCacheStakes(newEpoch, assetClassId);
        uint256 newStake = middleware.getOperatorStake(alice, newEpoch, assetClassId);
        console2.log("New epoch operator stake:", newStake);
        assertGe(newStake, operatorStake);

        // Add a node
        bytes32 nodeId = 0x00000000000000000000000039a662260f928d2d98ab5ad93aa7af8e0ee4d426;
        bytes memory blsKey = hex"1234";
        uint64 registrationExpiry = uint64(block.timestamp + 1 days);
        address[] memory owners = new address[](1);
        owners[0] = alice;
        PChainOwner memory ownerStruct = PChainOwner({threshold: 1, addresses: owners});

        vm.prank(alice);
        middleware.addNode(nodeId, blsKey, registrationExpiry, ownerStruct, ownerStruct, 0);
        bytes32 validationID = mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId))));
        uint256 nodeWeight = middleware.nodeStakeCache(newEpoch, validationID);
        console2.log("Node weight immediately after add:", nodeWeight);
        assertGt(nodeWeight, 0, "New node weight must be positive");
    }

    function test_AddNodeSimple() public {
        _calcAndWarpOneEpoch();
        uint48 epoch = middleware.getCurrentEpoch();
        uint256 totalStake = middleware.getOperatorStake(alice, epoch, assetClassId);
        assertGt(totalStake, 0);

        // Add node
        bytes32 nodeId = 0x00000000000000000000000039a662260f928d2d98ab5ad93aa7af8e0ee4d426;
        bytes memory blsKey = hex"1234";
        uint64 registrationExpiry = uint64(block.timestamp + 1 days);
        address[] memory ownerArr = new address[](1);
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct = PChainOwner({threshold: 1, addresses: ownerArr});

        vm.prank(alice);
        middleware.addNode(nodeId, blsKey, registrationExpiry, ownerStruct, ownerStruct, 0);

        bytes32 validationID = mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId))));
        uint256 nodeWeight = middleware.nodeStakeCache(epoch, validationID);
        console2.log("Node weight immediately:", nodeWeight);
        assertGt(nodeWeight, 0);

        vm.prank(alice);
        middleware.completeValidatorRegistration(alice, nodeId, 0);

        // Move epoch +1
        _calcAndWarpOneEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();

        validationID = mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId))));
        nodeWeight = middleware.nodeStakeCache(middleware.getCurrentEpoch(), validationID);
        console2.log("Node weight after confirmation:", nodeWeight);
        assertGt(nodeWeight, 0);
    }

    function test_AddNodeStakeClamping_Adaptive() public {
        // Get staking requirements from middleware
        middleware.getClassStakingRequirements(1);
        uint256 totalSupply = collateral.totalSupply();
        console2.log("Token total supply:", totalSupply);

        // Set up test values
        uint256 feasibleMax = 10_000_000_000_000_000_000;
        uint256 stakeWanted = feasibleMax + 1 ether;

        // Fund alice and deposit to vault
        collateral.transfer(alice, stakeWanted);

        vm.startPrank(alice);
        collateral.approve(address(vault), stakeWanted);
        vault.deposit(alice, stakeWanted);
        vm.stopPrank();

        // Set L1 limit
        vm.startPrank(bob);
        delegator.setL1Limit(validatorManagerAddress, assetClassId, stakeWanted);
        vm.stopPrank();

        // Verify available stake
        uint256 updatedAvail = middleware.getOperatorAvailableStake(alice);
        require(updatedAvail >= stakeWanted, "Still not enough to surpass testMaxStake+1");

        // Add node with stake that exceeds max
        bytes32 nodeId = keccak256("ClampTestAdaptive");
        console2.log("Requesting stakeWanted:", stakeWanted);

        vm.prank(alice);
        middleware.addNode(
            nodeId,
            hex"abcdef1234",
            uint64(block.timestamp + 1 days),
            PChainOwner({threshold:1, addresses:new address[](1)}),
            PChainOwner({threshold:1, addresses:new address[](1)}),
            stakeWanted
        );

        // Move to next epoch
        _calcAndWarpOneEpoch();

        // Verify stake was clamped to max
        uint48 epoch = middleware.getCurrentEpoch();
        bytes32 validationID =
            mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId))));
        uint256 finalStake = middleware.getNodeStake(epoch, validationID);

        console2.log("Final stake after clamp is:", finalStake);
        assertEq(finalStake, feasibleMax, "Expect clamp to feasibleMax in the test scenario");
    }

    function test_AddNodeSecondaryAsset() public {
        _calcAndWarpOneEpoch();
        uint48 epoch = middleware.getCurrentEpoch();
        uint256 totalStake = middleware.getOperatorStake(alice, epoch, assetClassId);
        assertGt(totalStake, 0);

        // Add node
        bytes32 nodeId = 0x00000000000000000000000039a662260f928d2d98ab5ad93aa7af8e0ee4d426;
        bytes memory blsKey = hex"1234";
        uint64 registrationExpiry = uint64(block.timestamp + 1 days);
        address[] memory ownerArr = new address[](1);
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct = PChainOwner({threshold: 1, addresses: ownerArr});

        vm.prank(alice);
        middleware.addNode(nodeId, blsKey, registrationExpiry, ownerStruct, ownerStruct, 0);

        bytes32 validationID = mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId))));
        uint256 nodeWeight = middleware.nodeStakeCache(epoch, validationID);
        console2.log("Node weight immediately:", nodeWeight);
        assertGt(nodeWeight, 0);

        vm.prank(alice);
        middleware.completeValidatorRegistration(alice, nodeId, 0);

        _calcAndWarpOneEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();

        nodeWeight = middleware.nodeStakeCache(middleware.getCurrentEpoch(), validationID);
        console2.log("Node weight after next epoch:", nodeWeight);
        assertGt(nodeWeight, 0);
    }

    function test_AddNodeLateCompletition() public {
        _calcAndWarpOneEpoch();
        uint48 epoch = middleware.getCurrentEpoch();
        uint256 totalStake = middleware.getOperatorStake(alice, epoch, assetClassId);
        console2.log("Operator stake in epoch", epoch, ":", totalStake);
        assertGt(totalStake, 0);

        // Add node
        bytes32 nodeId = 0x00000000000000000000000039a662260f928d2d98ab5ad93aa7af8e0ee4d426;
        bytes memory blsKey = hex"1234";
        uint64 registrationExpiry = uint64(block.timestamp + 1 days);
        address[] memory ownerArr = new address[](1);
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct = PChainOwner({threshold: 1, addresses: ownerArr});

        vm.prank(alice);
        middleware.addNode(nodeId, blsKey, registrationExpiry, ownerStruct, ownerStruct, 0);
        bytes32 validationID = mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId))));
        uint256 nodeWeight = middleware.nodeStakeCache(epoch, validationID);
        console2.log("Node weight immediately:", nodeWeight);
        assertGt(nodeWeight, 0);

        // Advance epoch
        _calcAndWarpOneEpoch();

        // Node still not confirmed
        nodeWeight = middleware.nodeStakeCache(middleware.getCurrentEpoch(), validationID);
        console2.log("Node weight second epoch (still unconfirmed):", nodeWeight);
        assertGt(nodeWeight, 0);

        // Confirm node
        vm.startPrank(alice);
        middleware.completeValidatorRegistration(alice, nodeId, 0);
        middleware.calcAndCacheNodeStakeForAllOperators();
        vm.stopPrank();

        // Should be active next epoch
        _calcAndWarpOneEpoch();
        vm.prank(alice);
        middleware.calcAndCacheNodeStakeForAllOperators();

        nodeWeight = middleware.nodeStakeCache(middleware.getCurrentEpoch(), validationID);
        console2.log("Node weight after full confirmation:", nodeWeight);
        assertGt(nodeWeight, 0);
    }

    function test_completeStakeUpdate() public {
        (depositedAmount, mintedShares) = _deposit(alice, 10 ether);
        _setL1Limit(bob, validatorManagerAddress, 1, depositedAmount);

        _calcAndWarpOneEpoch();
        bytes32 nodeId = 0x00000000000000000000000039a662260f928d2d98ab5ad93aa7af8e0ee4d426;
        bytes memory blsKey = hex"5678";
        uint64 registrationExpiry = uint64(block.timestamp + 1 days);
        address[] memory ownerArr = new address[](1);
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct = PChainOwner({threshold: 1, addresses: ownerArr});

        vm.prank(alice);
        middleware.addNode(nodeId, blsKey, registrationExpiry, ownerStruct, ownerStruct, 0);

        bytes32 validationID = mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId))));
        uint48 epoch = middleware.getCurrentEpoch();
        uint256 nodeWeight = middleware.nodeStakeCache(epoch, validationID);
        console2.log("Initial node weight:", nodeWeight);

        vm.prank(alice);
        middleware.completeValidatorRegistration(alice, nodeId, 0);
        middleware.calcAndCacheNodeStakeForAllOperators();

        _calcAndWarpOneEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();
        nodeWeight = middleware.nodeStakeCache(middleware.getCurrentEpoch(), validationID);
        console2.log("Confirmed node weight:", nodeWeight);

        // Decrease weight
        uint256 stakeAmount = uint256(nodeWeight - 100);
        vm.prank(alice);
        middleware.initializeValidatorStakeUpdate(nodeId, stakeAmount);
        uint256 updatedNodeWeight = middleware.nodeStakeCache(middleware.getCurrentEpoch(), validationID);
        console2.log("Node weight after init update (still old until next epoch):", updatedNodeWeight);

        vm.prank(alice);
        middleware.completeStakeUpdate(nodeId, 0);
        middleware.calcAndCacheNodeStakeForAllOperators();

        updatedNodeWeight = middleware.nodeStakeCache(middleware.getCurrentEpoch(), validationID);
        console2.log("Node weight after completion (still old until next epoch):", updatedNodeWeight);

        // Move to next epoch
        _calcAndWarpOneEpoch();
        updatedNodeWeight = middleware.nodeStakeCache(middleware.getCurrentEpoch(), validationID);
        console2.log("Node weight final:", updatedNodeWeight);
        assertEq(updatedNodeWeight, stakeAmount, "Node weight should be updated");
    }

    function test_CompleteLateNodeWeightUpdate() public {
        (depositedAmount, mintedShares) = _deposit(alice, 10 ether);
        _setL1Limit(bob, validatorManagerAddress, 1, depositedAmount);

        _calcAndWarpOneEpoch();
        bytes32 nodeId = 0x000000000000000000000000ece08438df2c7c362e75b02337dce4cf644a2ce2;
        bytes memory blsKey = hex"5678";
        uint64 registrationExpiry = uint64(block.timestamp + 1 days);
        address[] memory ownerArr = new address[](1);
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct = PChainOwner({threshold: 1, addresses: ownerArr});

        vm.prank(alice);
        middleware.addNode(nodeId, blsKey, registrationExpiry, ownerStruct, ownerStruct, 0);

        bytes32 validationID = mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId))));
        uint48 epoch = middleware.getCurrentEpoch();
        uint256 nodeWeight = middleware.nodeStakeCache(epoch, validationID);
        console2.log("Initial node weight:", nodeWeight);

        vm.prank(alice);
        middleware.completeValidatorRegistration(alice, nodeId, 0);
        middleware.calcAndCacheNodeStakeForAllOperators();

        _calcAndWarpOneEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();
        nodeWeight = middleware.nodeStakeCache(middleware.getCurrentEpoch(), validationID);
        console2.log("Node weight after confirmation:", nodeWeight);

        // Decrease
        uint256 stakeAmount = uint256(nodeWeight - 100);
        vm.prank(alice);
        middleware.initializeValidatorStakeUpdate(nodeId, stakeAmount);

        // Next epochs warp
        _calcAndWarpOneEpoch();
        _calcAndWarpOneEpoch();
        vm.prank(alice);
        middleware.calcAndCacheNodeStakeForAllOperators();

        vm.prank(alice);
        middleware.completeStakeUpdate(nodeId, 0);
        middleware.calcAndCacheNodeStakeForAllOperators();

        _calcAndWarpOneEpoch();
        vm.prank(alice);
        middleware.calcAndCacheNodeStakeForAllOperators();
        uint256 updatedNodeWeight = middleware.nodeStakeCache(middleware.getCurrentEpoch(), validationID);
        console2.log("Node weight final:", updatedNodeWeight);
        assertEq(updatedNodeWeight, stakeAmount);
    }

    function test_RemoveNodeSimple() public {
        _calcAndWarpOneEpoch();

        uint48 epoch = middleware.getCurrentEpoch();
        uint256 totalStake = middleware.getOperatorStake(alice, epoch, assetClassId);
        assertGt(totalStake, 0);

        bytes32 nodeId = 0x00000000000000000000000039a662260f928d2d98ab5ad93aa7af8e0ee4d426;
        bytes memory blsKey = hex"1234";
        uint64 registrationExpiry = uint64(block.timestamp + 1 days);
        address[] memory ownerArr = new address[](1);
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct = PChainOwner({threshold: 1, addresses: ownerArr});

        vm.prank(alice);
        middleware.addNode(nodeId, blsKey, registrationExpiry, ownerStruct, ownerStruct, 0);

        bytes32 validationID = mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId))));
        uint256 nodeWeight = middleware.nodeStakeCache(epoch, validationID);
        assertGt(nodeWeight, 0);
        assertEq(middleware.getOperatorNodesLength(alice), 1);

        vm.prank(alice);
        middleware.completeValidatorRegistration(alice, nodeId, 0);

        _calcAndWarpOneEpoch();
        nodeWeight = middleware.nodeStakeCache(middleware.getCurrentEpoch(), validationID);
        assertGt(nodeWeight, 0);

        vm.prank(alice);
        middleware.removeNode(nodeId);
        nodeWeight = middleware.nodeStakeCache(middleware.getCurrentEpoch(), validationID);
        assertGt(nodeWeight, 0);
        assertEq(middleware.getOperatorNodesLength(alice), 1);

        _calcAndWarpOneEpoch();
        nodeWeight = middleware.nodeStakeCache(middleware.getCurrentEpoch(), validationID);
        assertEq(nodeWeight, 0);
        assertEq(middleware.getOperatorNodesLength(alice), 0);
    }

    function test_RemoveNodeLate() public {
        _calcAndWarpOneEpoch();
        uint48 epoch = middleware.getCurrentEpoch();
        uint256 totalStake = middleware.getOperatorStake(alice, epoch, assetClassId);
        assertGt(totalStake, 0);

        // Add node
        bytes32 nodeId = 0x00000000000000000000000039a662260f928d2d98ab5ad93aa7af8e0ee4d426;
        bytes memory blsKey = hex"1234";
        uint64 registrationExpiry = uint64(block.timestamp + 1 days);
        address[] memory ownerArr = new address[](1);
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct = PChainOwner({threshold: 1, addresses: ownerArr});

        vm.prank(alice);
        middleware.addNode(nodeId, blsKey, registrationExpiry, ownerStruct, ownerStruct, 0);

        bytes32 validationID = mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId))));
        uint256 nodeWeight = middleware.nodeStakeCache(epoch, validationID);
        assertGt(nodeWeight, 0);
        assertEq(middleware.getOperatorNodesLength(alice), 1);

        vm.prank(alice);
        middleware.completeValidatorRegistration(alice, nodeId, 0);

        _calcAndWarpOneEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();
        nodeWeight = middleware.nodeStakeCache(middleware.getCurrentEpoch(), validationID);
        assertGt(nodeWeight, 0);

        vm.prank(alice);
        middleware.removeNode(nodeId);

        nodeWeight = middleware.nodeStakeCache(middleware.getCurrentEpoch(), validationID);
        assertGt(nodeWeight, 0);
        assertTrue(middleware.nodePendingRemoval(validationID));

        // Next epoch
        _calcAndWarpOneEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();
        nodeWeight = middleware.nodeStakeCache(middleware.getCurrentEpoch(), validationID);
        assertEq(nodeWeight, 0);
        assertFalse(middleware.nodePendingRemoval(validationID));
        assertEq(middleware.getOperatorNodesLength(alice), 0);

        // Next epoch
        _calcAndWarpOneEpoch();
        vm.prank(alice);
        middleware.completeValidatorRemoval(1);

        _calcAndWarpOneEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();
        nodeWeight = middleware.nodeStakeCache(middleware.getCurrentEpoch(), validationID);
        assertEq(nodeWeight, 0);
        assertFalse(middleware.nodePendingRemoval(validationID));
        assertEq(middleware.getOperatorNodesLength(alice), 0);
    }

    function test_multipleNodes() public {
        _calcAndWarpOneEpoch();
        uint48 epoch = middleware.getCurrentEpoch();
        uint256 totalStake = middleware.getOperatorStake(alice, epoch, assetClassId);
        assertGt(totalStake, 0);

        // Add node1
        bytes32 nodeId1 = 0x00000000000000000000000039a662260f928d2d98ab5ad93aa7af8e0ee4d426;
        bytes memory blsKey1 = hex"1234";
        address[] memory ownerArr = new address[](1);
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct1 = PChainOwner({threshold: 1, addresses: ownerArr});
        uint256 stake1 = 100_000_000_000_000 + 1000;

        vm.prank(alice);
        middleware.addNode(nodeId1, blsKey1, uint64(block.timestamp + 4 days), ownerStruct1, ownerStruct1, stake1);

        // Add node2
        bytes32 nodeId2 = 0x000000000000000000000000ece08438df2c7c362e75b02337dce4cf644a2ce2;
        bytes memory blsKey2 = hex"1235";
        PChainOwner memory ownerStruct2 = PChainOwner({threshold: 1, addresses: ownerArr});
        vm.prank(alice);
        middleware.addNode(nodeId2, blsKey2, uint64(block.timestamp + 4 days), ownerStruct2, ownerStruct2, stake1);

        bytes32 validationID1 = mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId1))));
        uint256 nodeWeight1 = middleware.nodeStakeCache(epoch, validationID1);
        assertGt(nodeWeight1, 0);

        bytes32 validationID2 = mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId2))));
        uint256 nodeWeight2 = middleware.nodeStakeCache(epoch, validationID2);
        assertGt(nodeWeight2, 0);

        vm.prank(alice);
        middleware.completeValidatorRegistration(alice, nodeId1, 0);

        _calcAndWarpOneEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();

        nodeWeight1 = middleware.nodeStakeCache(middleware.getCurrentEpoch(), validationID1);
        assertGt(nodeWeight1, 0);

        vm.prank(alice);
        middleware.completeValidatorRegistration(alice, nodeId2, 1);

        _calcAndWarpOneEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();
        nodeWeight2 = middleware.nodeStakeCache(middleware.getCurrentEpoch(), validationID2);
        assertGt(nodeWeight2, 0);

        // Remove node1
        vm.prank(alice);
        middleware.removeNode(nodeId1);
        _calcAndWarpOneEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();
        nodeWeight1 = middleware.nodeStakeCache(middleware.getCurrentEpoch(), validationID1);
        assertEq(nodeWeight1, 0);

        vm.prank(alice);
        middleware.completeValidatorRemoval(2);
        nodeWeight2 = middleware.nodeStakeCache(middleware.getCurrentEpoch(), validationID2);
        assertGt(nodeWeight2, 0);

        _calcAndWarpOneEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();
        nodeWeight1 = middleware.nodeStakeCache(middleware.getCurrentEpoch(), validationID1);
        assertEq(nodeWeight1, 0);
    }

    function test_HistoricalQueries_multiNodes() public {
        // 1) Move to epoch1
        _calcAndWarpOneEpoch();
        uint48 epoch1 = middleware.getCurrentEpoch();

        // 2) Add nodeId1
        bytes32 nodeId1 = 0x00000000000000000000000039a662260f928d2d98ab5ad93aa7af8e0ee4d426;
        bytes memory blsKey1 = hex"1234";
        address[] memory ownerArr = new address[](1);
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct1 = PChainOwner({threshold: 1, addresses: ownerArr});
        uint256 stake = 100_000_000_000_000 + 1000;

        vm.prank(alice);
        middleware.addNode(nodeId1, blsKey1, uint64(block.timestamp + 4 days), ownerStruct1, ownerStruct1, stake);
        middleware.calcAndCacheNodeStakeForAllOperators();

        vm.prank(alice);
        middleware.completeValidatorRegistration(alice, nodeId1, 0);

        // 3) Move to epoch2
        _calcAndWarpOneEpoch();
        uint48 epoch2 = middleware.getCurrentEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();

        // 4) Add nodeId2
        bytes32 nodeId2 = 0x000000000000000000000000ece08438df2c7c362e75b02337dce4cf644a2ce2;
        bytes memory blsKey2 = hex"1235";
        address[] memory ownerArr2 = new address[](1);
        ownerArr2[0] = alice;
        PChainOwner memory ownerStruct2 = PChainOwner({threshold: 1, addresses: ownerArr2});

        vm.prank(alice);
        middleware.addNode(nodeId2, blsKey2, uint64(block.timestamp + 4 days), ownerStruct2, ownerStruct2, stake);
        middleware.calcAndCacheNodeStakeForAllOperators();

        vm.prank(alice);
        middleware.completeValidatorRegistration(alice, nodeId2, 1);

        // 5) Move to epoch3
        _calcAndWarpOneEpoch();
        uint48 epoch3 = middleware.getCurrentEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();

        // 6) Remove nodeId1
        vm.prank(alice);
        middleware.removeNode(nodeId1);
        middleware.calcAndCacheNodeStakeForAllOperators();

        // 7) Move to epoch4
        _calcAndWarpOneEpoch();
        uint48 epoch4 = middleware.getCurrentEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();

        vm.prank(alice);
        middleware.completeValidatorRemoval(2);

        // Check active nodes at each epoch
        {
            bytes32[] memory epoch1Nodes = middleware.getActiveNodesForEpoch(alice, epoch1);
            console2.log("epoch1Nodes length:", epoch1Nodes.length);
        }
        {
            bytes32[] memory epoch2Nodes = middleware.getActiveNodesForEpoch(alice, epoch2);
            console2.log("epoch2Nodes length:", epoch2Nodes.length);
        }
        {
            bytes32[] memory epoch3Nodes = middleware.getActiveNodesForEpoch(alice, epoch3);
            console2.log("epoch3Nodes length:", epoch3Nodes.length);
        }
        {
            bytes32[] memory epoch4Nodes = middleware.getActiveNodesForEpoch(alice, epoch4);
            console2.log("epoch4Nodes length:", epoch4Nodes.length);
        }
    }

    function test_forceUpdate() public {
        _calcAndWarpOneEpoch();
        bytes32 nodeId1 = 0x00000000000000000000000039a662260f928d2d98ab5ad93aa7af8e0ee4d426;
        bytes memory blsKey1 = hex"1234";
        uint64 registrationExpiry = uint64(block.timestamp + 4 days);
        address[] memory ownerArr = new address[](1);
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct1 = PChainOwner({threshold: 1, addresses: ownerArr});
        uint256 stake = 100_000_000_000_000 + 1000;

        vm.prank(alice);
        middleware.addNode(nodeId1, blsKey1, registrationExpiry, ownerStruct1, ownerStruct1, stake);

        bytes32 nodeId2 = 0x000000000000000000000000ece08438df2c7c362e75b02337dce4cf644a2ce2;
        bytes memory blsKey2 = hex"1235";
        vm.prank(alice);
        middleware.addNode(nodeId2, blsKey2, registrationExpiry, ownerStruct1, ownerStruct1, stake);

        bytes32 validationID1 = mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId1))));
        uint48 epoch = middleware.getCurrentEpoch();
        uint256 nodeWeight = middleware.nodeStakeCache(epoch, validationID1);
        console2.log("Node weight1:", nodeWeight);

        bytes32 validationID2 = mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId2))));
        uint256 nodeWeight2 = middleware.nodeStakeCache(epoch, validationID2);
        console2.log("Node weight2:", nodeWeight2);

        vm.prank(alice);
        middleware.completeValidatorRegistration(alice, nodeId1, 0);

        _calcAndWarpOneEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();
        nodeWeight = middleware.nodeStakeCache(middleware.getCurrentEpoch(), validationID1);
        console2.log("Node1 weight after confirm:", nodeWeight);

        vm.prank(alice);
        middleware.completeValidatorRegistration(alice, nodeId2, 1);

        _calcAndWarpOneEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();
        nodeWeight2 = middleware.nodeStakeCache(middleware.getCurrentEpoch(), validationID2);
        console2.log("Node2 weight after confirm:", nodeWeight2);

        // Withdraw from vault to reduce stake
        _calcAndWarpOneEpoch(2);
        uint256 withdrawAmount = 50_000_000_000_000;
        _withdraw(alice, withdrawAmount);

        // Move to next epoch
        _calcAndWarpOneEpoch(1);
        vm.expectRevert();
        middleware.forceUpdateNodes(alice, 0);

        // Warp to last hour
        _warpToLastHourOfCurrentEpoch();
        middleware.forceUpdateNodes(alice, 0);

        vm.prank(alice);
        middleware.completeValidatorRemoval(2);

        _calcAndWarpOneEpoch(1);
        uint256 updatedStake = middleware.getOperatorStake(alice, middleware.getCurrentEpoch(), assetClassId);
        console2.log("Updated stake after partial withdraw & forceUpdateNodes:", updatedStake);

        // Claim
        _calcAndWarpOneEpoch(2);
        uint256 claimEpoch = vault.currentEpoch() - 1;
        uint256 claimed = _claim(alice, claimEpoch);
        console2.log("Claimed:", claimed);

        _calcAndWarpOneEpoch(1);
        middleware.calcAndCacheNodeStakeForAllOperators();
        epoch = middleware.getCurrentEpoch();
        updatedStake = middleware.getOperatorStake(alice, epoch, assetClassId);
        nodeWeight = middleware.nodeStakeCache(epoch, validationID1);
        nodeWeight2 = middleware.nodeStakeCache(epoch, validationID2);

        console2.log("Final operator stake:", updatedStake);
        console2.log("Node1 weight final:", nodeWeight);
        console2.log("Node2 weight final:", nodeWeight2);
    }

    function test_forceUpdateWithAdditionalStake() public {
        _calcAndWarpOneEpoch();

        uint48 epoch = middleware.getCurrentEpoch();

        bytes32 nodeId1 = 0x00000000000000000000000039a662260f928d2d98ab5ad93aa7af8e0ee4d426;
        bytes memory blsKey1 = hex"1234";
        uint64 registrationExpiry = uint64(block.timestamp + 4 days);
        address[] memory ownerArr = new address[](1);
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct1 = PChainOwner({threshold: 1, addresses: ownerArr});
        uint256 iniitialStake = 100_000_000_000_000 + 1000;

        vm.prank(alice);
        middleware.addNode(nodeId1, blsKey1, registrationExpiry, ownerStruct1, ownerStruct1, iniitialStake);

        bytes32 nodeId2 = 0x000000000000000000000000ece08438df2c7c362e75b02337dce4cf644a2ce2;
        bytes memory blsKey2 = hex"1235";
        registrationExpiry = uint64(block.timestamp + 4 days);
        ownerArr = new address[](1);
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct2 = PChainOwner({threshold: 1, addresses: ownerArr});

        vm.prank(alice);
        middleware.addNode(nodeId2, blsKey2, registrationExpiry, ownerStruct2, ownerStruct2, iniitialStake);

        bytes32 validationID1 = mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId1))));
        uint256 nodeWeight1 = middleware.nodeStakeCache(epoch, validationID1);
        assertGt(nodeWeight1, 0, "Node1 weight must be positive immediately");

        bytes32 validationID2 = mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId2))));
        uint256 nodeWeight2 = middleware.nodeStakeCache(epoch, validationID2);
        assertGt(nodeWeight2, 0, "Node2 weight must be positive immediately");

        vm.prank(alice);
        middleware.completeValidatorRegistration(alice, nodeId1, 0);

        epoch = middleware.getCurrentEpoch();
        uint48 newMiddlewareEpochStart = middleware.getEpochStartTs(epoch) + middleware.EPOCH_DURATION() + 1;
        vm.warp(newMiddlewareEpochStart);

        epoch = middleware.getCurrentEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();
        nodeWeight1 = middleware.nodeStakeCache(epoch, validationID1);
        assertGt(nodeWeight1, 0);

        vm.prank(alice);
        middleware.completeValidatorRegistration(alice, nodeId2, 1);

        epoch = middleware.getCurrentEpoch();
        newMiddlewareEpochStart = middleware.getEpochStartTs(epoch) + middleware.EPOCH_DURATION() + 1;
        vm.warp(newMiddlewareEpochStart);

        epoch = middleware.getCurrentEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();
        nodeWeight2 = middleware.nodeStakeCache(epoch, validationID2);
        assertGt(nodeWeight2, 0);

        uint256 extraDeposit = 50_000_000_000_000;
        console2.log("Making additional deposit:", extraDeposit);
        (uint256 newDeposit, uint256 newShares) = _deposit(alice, extraDeposit);
        uint256 totalShares = mintedShares + newShares;
        _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, alice, totalShares);
        console2.log("Additional deposit made. Amount:", newDeposit, "Shares:", newShares);

        _moveToNextEpochAndCalc(3);

        _warpToLastHourOfCurrentEpoch();
        epoch = middleware.getCurrentEpoch();
        uint256 updatedStake = middleware.getOperatorStake(alice, epoch, assetClassId);
        console2.log("Operator stake after extra deposit (before forceUpdate):", updatedStake);

        uint256 oldUsedStake = middleware.getOperatorUsedStakeCached(alice);
        uint256 leftover = updatedStake - oldUsedStake;
        assertGt(leftover, 0, "Expected leftover to be > 0");

        vm.expectEmit(true, true, true, true);
        emit IAvalancheL1Middleware.OperatorHasLeftoverStake(alice, leftover);

        middleware.forceUpdateNodes(alice, 0);

        uint256 newUsedStake = middleware.getOperatorUsedStakeCached(alice);
        assertEq(newUsedStake, oldUsedStake, "Used stake must remain unchanged if weight only decreases");
    }
    
    function test_AddRemoveAddNodeAgain() public {
        // Move to the next epoch so we have a clean slate
        _calcAndWarpOneEpoch();
        uint48 epoch = middleware.getCurrentEpoch();

        // Prepare node data
        bytes32 nodeId = 0x00000000000000000000000039a662260f928d2d98ab5ad93aa7af8e0ee4d426;
        bytes memory blsKey = hex"1234";
        uint64 registrationExpiry = uint64(block.timestamp + 2 days);
        address[] memory ownerArr = new address[](1);
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct = PChainOwner({threshold: 1, addresses: ownerArr});

        // Add node
        vm.prank(alice);
        middleware.addNode(nodeId, blsKey, registrationExpiry, ownerStruct, ownerStruct, 0);
        bytes32 validationID = mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId))));

        // Check node stake from the public getter
        uint256 nodeStake = middleware.getNodeStake(epoch, validationID);
        assertGt(nodeStake, 0, "Node stake should be >0 right after add");

        // Also confirm we have 0 or 1 active node at this epoch. 
        // Because the node is not yet "confirmed," it typically won't appear as active.
        // We simply show how to ensure it's not erroneously counted:
        bytes32[] memory activeNodesBeforeConfirm = middleware.getActiveNodesForEpoch(alice, epoch);
        assertEq(activeNodesBeforeConfirm.length, 0, "Node shouldn't appear active before confirmation");

        // Confirm node
        vm.prank(alice);
        // messageIndex = 0 in this scenario
        middleware.completeValidatorRegistration(alice, nodeId, 0);

        // Warp +1 epoch and check that the node is truly active
        _calcAndWarpOneEpoch();
        epoch = middleware.getCurrentEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();

        nodeStake = middleware.getNodeStake(epoch, validationID);
        assertGt(nodeStake, 0, "Node stake should persist after confirmation");

        bytes32[] memory activeNodesAfterConfirm = middleware.getActiveNodesForEpoch(alice, epoch);
        assertEq(activeNodesAfterConfirm.length, 1, "Should have exactly 1 active node");
        assertEq(activeNodesAfterConfirm[0], nodeId, "The active node ID should match");

        // Remove node
        vm.prank(alice);
        middleware.removeNode(nodeId);

        // Warp +1 epoch => node stake should become zero
        _calcAndWarpOneEpoch();
        epoch = middleware.getCurrentEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();

        nodeStake = middleware.getNodeStake(epoch, validationID);
        assertEq(nodeStake, 0, "Node stake must be zero after removal finalizes");

        bytes32[] memory activeNodesAfterRemove = middleware.getActiveNodesForEpoch(alice, epoch);
        assertEq(activeNodesAfterRemove.length, 0, "No active nodes after removal");

        // onfirm removal
        vm.prank(alice);

        middleware.completeValidatorRemoval(1);

        // Warp +1 epoch just for clarity
        _calcAndWarpOneEpoch();
        epoch = middleware.getCurrentEpoch();

        // Add the same node again (the system allows re-adding after full removal)
        vm.prank(alice);
        middleware.addNode(nodeId, blsKey, registrationExpiry, ownerStruct, ownerStruct, 0);

        bytes32 newValidationID = mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId))));
        uint256 nodeStake2 = middleware.getNodeStake(epoch, newValidationID);
        assertGt(nodeStake2, 0, "Node stake should be >0 on second add");

        // Confirm node again
        vm.prank(alice);
        // Next message index might be 2 or 3 by now
        middleware.completeValidatorRegistration(alice, nodeId, 2);

        // Warp another epoch and verify stake
        _calcAndWarpOneEpoch();
        epoch = middleware.getCurrentEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();

        nodeStake2 = middleware.getNodeStake(epoch, newValidationID);
        assertGt(nodeStake2, 0, "Node stake must be >0 after re-adding and confirming");

        // Confirm the newly re-added node is active
        bytes32[] memory activeNodesFinal = middleware.getActiveNodesForEpoch(alice, epoch);
        assertEq(activeNodesFinal.length, 1, "Should have 1 active node after second addition");
        assertEq(activeNodesFinal[0], nodeId, "Active node ID should match the re-added node");

        // Final check
        uint256 operatorAvailable = middleware.getOperatorAvailableStake(alice);
        // Confirm there's some leftover
        assertGt(operatorAvailable, 0, "Operator should have some leftover stake");
    }

    function testSingleNode_AddUpdateRemoveThenCompleteUpdate() public {
        // Suppose your system uses a known stake scale factor
        uint256 scaleFactor = middleware.WEIGHT_SCALE_FACTOR();

        // -----------------------------------------
        // STEP A: Add & confirm a single node
        // -----------------------------------------
        _calcAndWarpOneEpoch(); 
        uint48 epoch = middleware.getCurrentEpoch();

        bytes32 nodeId = keccak256("NODE_SINGLE_TEST");
        bytes memory blsKey = hex"abcd1234";
        address[] memory ownerArr = new address[](1);
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct = PChainOwner({ threshold: 1, addresses: ownerArr });

        // Add the node
        vm.prank(alice);
        middleware.addNode(nodeId, blsKey, uint64(block.timestamp + 2 days), ownerStruct, ownerStruct, 0);

        // Grab the manager’s messageIndex for the add
        uint32 addIndex = mockValidatorManager.nextMessageIndex() - 1;

        // Get the validationID
        bytes32 valID = mockValidatorManager.registeredValidators(
            abi.encodePacked(uint160(uint256(nodeId)))
        );

        //  => node is Active
        vm.prank(alice);
        middleware.completeValidatorRegistration(alice, nodeId, addIndex);

        // Warp => next epoch => truly active
        _calcAndWarpOneEpoch();
        epoch = middleware.getCurrentEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();

        uint256 initialStake = middleware.getNodeStake(epoch, valID);
        assertGt(initialStake, 0, "Node must have >0 stake after confirm");

        // Initialize a stake update (reduce stake by half)
        uint256 newStake = initialStake / 2;
        vm.prank(alice);
        middleware.initializeValidatorStakeUpdate(nodeId, newStake);

        // Check the manager’s internal pending weight
        uint64 scaledWeight = StakeConversion.stakeToWeight(newStake, scaleFactor);
        uint256 pendingWeight = mockValidatorManager.pendingNewWeight(valID);
        assertEq(pendingWeight, scaledWeight, "Pending new weight mismatch");

        bool isPending = mockValidatorManager.isValidatorPendingWeightUpdate(valID);
        assertTrue(isPending, "Stake update must be pending");

        // Remove node *while update is pending*
        vm.prank(alice);
        middleware.removeNode(nodeId);

        uint32 removeIndex = mockValidatorManager.nextMessageIndex() - 1;

        // Warp => next epoch => presumably stake=0
        _calcAndWarpOneEpoch();
        epoch = middleware.getCurrentEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();

        uint256 stakeNow = middleware.getNodeStake(epoch, valID);
        console2.log("Stake after removing while update pending:", stakeNow);

        // Confirm removal
        vm.prank(alice);
        middleware.completeValidatorRemoval(removeIndex);

        // Another epoch => finalize removal
        _calcAndWarpOneEpoch();
        epoch = middleware.getCurrentEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();

        uint256 finalStake = middleware.getNodeStake(epoch, valID);
        assertEq(finalStake, 0, "Node stake must be 0 after final removal");

        
        // Complete the stake update AFTER removal
        // Complete goes through but stake is 0

        uint32 stakeUpdateMsgIndex = mockValidatorManager.nextMessageIndex() - 1; 

        vm.prank(alice);
        // If your code is supposed to revert, do:
        // vm.expectRevert("AvalancheL1Middleware__WeightUpdateNotPending");
        middleware.completeStakeUpdate(nodeId, stakeUpdateMsgIndex);

        // If no revert, let's see if the manager truly cleared the pending update:
        bool stillPending = mockValidatorManager.isValidatorPendingWeightUpdate(valID);
        assertFalse(stillPending, "Stake update should be cleared after node removal + finalization");

        uint256 postCompleteStake = middleware.getNodeStake(epoch, valID);
        assertEq(postCompleteStake, 0, "Node stake must be 0 after final removal");

        console2.log("Completed stake update after the node was removed. Check if it no-ops or reverts.");
    }

    function testFuzz_MultipleNodes_AddRemoveReadd(
        uint8 seedNodeCount,
        uint8 seedRemoveMask
    ) public {
        // Force a small range for how many nodes to add (2–4)
        uint256 nodeCount = bound(seedNodeCount, 2, 4);

        // Move to next epoch, so we start from a clean point
        _calcAndWarpOneEpoch();
        uint48 epoch = middleware.getCurrentEpoch();

        // Arrays to store node info
        bytes32[] memory nodeIds = new bytes32[](nodeCount);
        bytes32[] memory validationIds = new bytes32[](nodeCount);
        bool[] memory isActive = new bool[](nodeCount);

        // Track message indexes for concurrency
        uint32[] memory addMsgIndex = new uint32[](nodeCount);
        uint32[] memory removeMsgIndex = new uint32[](nodeCount);
        uint32[] memory reAddMsgIndex = new uint32[](nodeCount);

        // Track expected final stake for each node
        uint256[] memory expectedFinalStake = new uint256[](nodeCount);

        // Track the old validation ID once removed
        bytes32[] memory oldRemovedValidationIds = new bytes32[](nodeCount);

        // BLS key and owners
        bytes memory blsKey = hex"abcd1234";
        address[] memory ownerArr = new address[](1);
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct = PChainOwner({threshold: 1, addresses: ownerArr});

        // Add each node (not yet confirmed)
        for (uint256 i = 0; i < nodeCount; i++) {
            bytes32 nodeId = keccak256(abi.encodePacked("NODE_", seedNodeCount, i));
            nodeIds[i] = nodeId;

            vm.prank(alice);
            middleware.addNode(nodeId, blsKey, uint64(block.timestamp + 2 days), ownerStruct, ownerStruct, 0);

            addMsgIndex[i] = mockValidatorManager.nextMessageIndex() - 1;

            bytes32 validationID = mockValidatorManager.registeredValidators(
                abi.encodePacked(uint160(uint256(nodeId)))
            );
            validationIds[i] = validationID;

            uint256 nodeStake = middleware.getNodeStake(epoch, validationID);
            assertGt(nodeStake, 0, "Node stake should be >0 right after add");
            isActive[i] = false; // not yet confirmed
        }

        // Confirm registration => active
        for (uint256 i = 0; i < nodeCount; i++) {
            vm.prank(alice);
            middleware.completeValidatorRegistration(alice, nodeIds[i], addMsgIndex[i]);
            isActive[i] = true;
        }

        // Warp => next epoch => nodes are truly active
        _calcAndWarpOneEpoch();
        epoch = middleware.getCurrentEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();

        bytes32[] memory currentActive = middleware.getActiveNodesForEpoch(alice, epoch);
        assertEq(currentActive.length, nodeCount, "All nodes should be active after confirm");

        // Track expected final stake for each node
        for (uint256 i = 0; i < nodeCount; i++) {
            if (isActive[i]) {
                expectedFinalStake[i] = middleware.getNodeStake(epoch, validationIds[i]);
            }
        }

        // Remove a subset of nodes
        for (uint256 i = 0; i < nodeCount; i++) {
            bool doRemove = ((seedRemoveMask >> uint8(i)) & 0x01) == 1;
            if (doRemove) {
                vm.prank(alice);
                middleware.removeNode(nodeIds[i]);

                removeMsgIndex[i] = mockValidatorManager.nextMessageIndex() - 1;
                isActive[i] = false;

                // Record the old validation ID *before* it’s replaced by re-add
                oldRemovedValidationIds[i] = validationIds[i];

                // Attempt to remove the same node again immediately, expecting a revert
                vm.prank(alice);
                // vm.expectRevert("AvalancheL1Middleware__NodePendingRemoval");
                middleware.removeNode(nodeIds[i]);
            }
        }

        // Warp => next epoch => removed node stakes => 0
        _calcAndWarpOneEpoch();
        epoch = middleware.getCurrentEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();

        // Confirm each removal
        for (uint256 i = 0; i < nodeCount; i++) {
            bool doRemove = ((seedRemoveMask >> uint8(i)) & 0x01) == 1;
            if (doRemove) {
                vm.prank(alice);
                middleware.completeValidatorRemoval(removeMsgIndex[i]);

                // Mark the stake in expectedFinalStake as 0
                expectedFinalStake[i] = 0;

                // Read the old validator from the mock
                // to confirm status=Completed and endedAt != 0
                {
                    bytes32 oldValID = oldRemovedValidationIds[i];
                    Validator memory oldVal = mockValidatorManager.getValidator(oldValID);
                    // Some mocks only finalize endedAt in initializeEndValidation, so check that
                    // we got endedAt there:
                    assertGt(oldVal.endedAt, 0, "Old val endedAt must be set");
                    // Also check status is Completed:
                    assertEq(uint256(oldVal.status), uint256(ValidatorStatus.Completed), "Old val must be completed");
                }
            }
        }

        // Re-add the removed nodes
        for (uint256 i = 0; i < nodeCount; i++) {
            bool wasRemoved = ((seedRemoveMask >> uint8(i)) & 0x01) == 1;
            if (wasRemoved) {
                // Re-add
                vm.prank(alice);
                middleware.addNode(nodeIds[i], blsKey, uint64(block.timestamp + 2 days), ownerStruct, ownerStruct, 0);

                reAddMsgIndex[i] = mockValidatorManager.nextMessageIndex() - 1;

                // Fetch the BRAND-NEW validationID for this re-add
                bytes32 newValID = mockValidatorManager.registeredValidators(
                    abi.encodePacked(uint160(uint256(nodeIds[i])))
                );
                // Overwrite old ID in validationIds[i] with the new one
                validationIds[i] = newValID;

                // Confirm the new registration
                vm.prank(alice);
                middleware.completeValidatorRegistration(alice, nodeIds[i], reAddMsgIndex[i]);
                isActive[i] = true;

                // Verify that the oldVal ID remains at stake=0
                {
                    bytes32 oldValID = oldRemovedValidationIds[i];
                    uint256 oldStakeCheck = middleware.getNodeStake(epoch, oldValID);
                    assertEq(oldStakeCheck, 0, "Old validationID must remain at 0 stake after re-add");
                }
            }
        }

        // Warp again => finalize re-add
        _calcAndWarpOneEpoch();
        epoch = middleware.getCurrentEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();

        // Track final stake for each node
        for (uint256 i = 0; i < nodeCount; i++) {
            if (isActive[i]) {
                expectedFinalStake[i] = middleware.getNodeStake(epoch, validationIds[i]);
            }
        }

        // Final checks
        uint256 shouldBeActive = 0;
        for (uint256 i = 0; i < nodeCount; i++) {
            if (isActive[i]) {
                shouldBeActive++;

                // The new (or never-removed) validator
                uint256 finalStake = middleware.getNodeStake(epoch, validationIds[i]);
                assertEq(finalStake, expectedFinalStake[i], "Active node stake mismatch");
            } else {
                // If never re-added => 0 stake
                uint256 finalStake = middleware.getNodeStake(epoch, validationIds[i]);
                assertEq(finalStake, 0, "Inactive node must have zero stake");
            }
        }

        bytes32[] memory finalNodes = middleware.getActiveNodesForEpoch(alice, epoch);
        assertEq(finalNodes.length, shouldBeActive, "Mismatch in final # of active nodes");
    }
    

    ///////////////////////////////
    // INTERNAL HELPERS
    ///////////////////////////////

    function _registerOperator(address user, string memory metadataURL) internal {
        vm.startPrank(user);
        operatorRegistry.registerOperator(metadataURL);
        vm.stopPrank();
    }

    function _registerL1(address _l1, address _middleware) internal {
        vm.prank(_l1);
        l1Registry.registerL1{value: 0.01 ether}(_l1, _middleware, "metadataURL");
    }

    function _grantDepositorWhitelistRole(address user, address account) internal {
        vm.startPrank(user);
        VaultTokenized(address(vault)).grantRole(vault.DEPOSITOR_WHITELIST_ROLE(), account);
        vm.stopPrank();
    }

    function _grantL1LimiteRole(address user, address account) internal {
        vm.startPrank(user);
        delegator.grantRole(delegator.L1_LIMIT_SET_ROLE(), account);
        vm.stopPrank();
    }

    function _deposit(
        address user,
        uint256 amount
    ) internal returns (uint256 depositedAmount_, uint256 mintedShares_) {
        collateral.transfer(user, amount);
        vm.startPrank(user);
        collateral.approve(address(vault), amount);
        (depositedAmount_, mintedShares_) = vault.deposit(user, amount);
        vm.stopPrank();
    }

    function _withdraw(address user, uint256 amount) internal returns (uint256 burnedShares, uint256 mintedShares_) {
        vm.startPrank(user);
        (burnedShares, mintedShares_) = vault.withdraw(user, amount);
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

    function _optInOperatorL1(address user, address _l1) internal {
        vm.startPrank(user);
        operatorL1OptInService.optIn(_l1);
        vm.stopPrank();
    }

    function _optOutOperatorL1(address user, address _l1) internal {
        vm.startPrank(user);
        operatorL1OptInService.optOut(_l1);
        vm.stopPrank();
    }

    function _setL1Limit(address user, address _l1, uint96 assetClass, uint256 amount) internal {
        vm.startPrank(user);
        delegator.setL1Limit(_l1, assetClass, amount);
        vm.stopPrank();
    }

    function _setOperatorL1Shares(
        address user,
        address _l1,
        uint96 assetClass,
        address operator,
        uint256 shares
    ) internal {
        vm.startPrank(user);
        delegator.setOperatorL1Shares(_l1, assetClass, operator, shares);
        vm.stopPrank();
    }

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

    function _moveToNextEpochAndCalc(
        uint256 numberOfEpochs
    ) internal {
        for (uint256 i = 0; i < numberOfEpochs; i++) {
            // 1. Figure out what the *next* epoch index would be
            uint48 nextEpochIndex = middleware.getCurrentEpoch() + 1;

            // 2. Warp to *just after* that epoch’s start
            uint256 nextEpochStartTs = middleware.getEpochStartTs(nextEpochIndex);
            vm.warp(nextEpochStartTs + 1);

            // 3. Do any housekeeping
            middleware.calcAndCacheNodeStakeForAllOperators();

            console2.log("Current middleware epoch:", middleware.getCurrentEpoch());
            console2.log("Current vault epoch:", vault.currentEpoch());
        }
    }

    function _warpToLastHourOfCurrentEpoch() internal {
        uint48 currentEpoch = middleware.getCurrentEpoch();
        uint48 currentEpochTs = middleware.getEpochStartTs(currentEpoch);

        // The final “window” starts at (epoch end - weightUpdateGracePeriod)
        uint256 finalHourStartTs = currentEpochTs + middleware.UPDATE_WINDOW();

        // If we want to be safe, warp a few seconds into that window
        vm.warp(finalHourStartTs + 10);
    }

    function _arrayContains(bytes32[] memory arr, bytes32 target) internal pure returns (bool) {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == target) return true;
        }
        return false;
    }

    function _calcAndWarpOneEpoch(
        uint256 numberOfEpochs
    ) internal {
        for (uint256 i = 0; i < numberOfEpochs; i++) {
            uint48 nextEpochIndex = middleware.getCurrentEpoch() + 1;
            uint256 nextEpochStartTs = middleware.getEpochStartTs(nextEpochIndex);
            vm.warp(nextEpochStartTs + 1);
            middleware.calcAndCacheNodeStakeForAllOperators();
        }
    }

    function _calcAndWarpOneEpoch() internal {
        _calcAndWarpOneEpoch(1);
    }
}
