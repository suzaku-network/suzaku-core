// SPDX-License-Identifier: MIT
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
import {MiddlewareHelperConfig} from "../../script/middleware/MiddlewareHelperConfig.s.sol";
import {MockBalancerValidatorManager} from "../mocks/MockBalancerValidatorManager.sol";

import {DeployBalancerValidatorManager} from "../../script/validator-manager/DeployBalancerValidatorManager.s.sol";
import {HelperConfig} from "../../script/validator-manager/HelperConfig.s.sol";
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
    Token internal collateral;
    MockBalancerValidatorManager internal mockValidatorManager;

    function setUp() public {
        owner = address(this);
        (alice, alicePrivateKey) = makeAddrAndKey("alice");
        (bob, bobPrivateKey) = makeAddrAndKey("bob");
        (l1, l1PrivateKey) = makeAddrAndKey("l1");
        tokenA = makeAddr("tokenA");
        tokenB = makeAddr("tokenB");

        vaultFactory = new VaultFactory(owner);
        delegatorFactory = new DelegatorFactory(owner);
        slasherFactory = new SlasherFactory(owner);
        l1Registry = new L1Registry();
        operatorRegistry = new OperatorRegistry();

        MiddlewareHelperConfig helperConfig = new MiddlewareHelperConfig();
        (
            uint256 proxyAdminOwnerKey,
            uint256 protocolOwnerKey,
            bytes32 subnetID,
            uint64 churnPeriodSeconds,
            uint8 maximumChurnPercentage,
            address primaryAsset,
            uint256 primaryAssetMaxStake,
            uint256 primaryAssetMinStake
        ) = helperConfig.activeNetworkConfig();
        address proxyAdminOwnerAddress = vm.addr(proxyAdminOwnerKey);
        address protocolOwnerAddress = vm.addr(protocolOwnerKey);

        ValidatorManagerSettings memory validatorSettings = ValidatorManagerSettings({
            subnetID: subnetID,
            churnPeriodSeconds: churnPeriodSeconds,
            maximumChurnPercentage: maximumChurnPercentage
        });

        mockValidatorManager = new MockBalancerValidatorManager();
        validatorManagerAddress = address(mockValidatorManager);
        // validatorManagerAddress =
        //     _deployValidatorManager(validatorSettings, proxyAdminOwnerAddress, protocolOwnerAddress);

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
        vault.setDelegator(delegatorAddress);

        // Deploy the middleware
        AvalancheL1MiddlewareSettings memory middlewareSettings = AvalancheL1MiddlewareSettings({
            l1ValidatorManager: validatorManagerAddress,
            operatorRegistry: address(operatorRegistry),
            vaultRegistry: address(vaultFactory),
            operatorL1Optin: address(operatorL1OptInService),
            epochDuration: 4 hours,
            slashingWindow: 5 hours
        });

        middleware = new AvalancheL1Middleware(
            middlewareSettings, owner, primaryAsset, primaryAssetMaxStake, primaryAssetMinStake
        );

        // middleware.addAssetClass(2, primaryAssetMinStake, primaryAssetMaxStake);
        // middleware.activateSecondaryAssetClass(0);

        middleware.transferOwnership(validatorManagerAddress);

        // middleware = new AvalancheL1Middleware();
        uint64 maxWeight = 18 ether;
        mockValidatorManager.setupSecurityModule(address(middleware), maxWeight);
    }

    function test_ConstructorValues() public view {
        assertEq(middleware.SLASHING_WINDOW(), 5 hours);
        assertEq(middleware.EPOCH_DURATION(), 4 hours);

        // Check that START_TIME is close to block.timestamp
        uint256 blockTime = block.timestamp;
        assertApproxEqAbs(middleware.START_TIME(), blockTime, 2);

        assertEq(middleware.L1_VALIDATOR_MANAGER(), validatorManagerAddress);
    }

    function test_registerVault() public {
        uint96 assetClassId = 1;
        uint256 maxVaultL1Limit = 2000 ether;

        _registerL1(validatorManagerAddress, address(middleware));

        vm.startPrank(validatorManagerAddress); // Check if this should change
        middleware.registerVault(address(vault), assetClassId, maxVaultL1Limit);
        vm.stopPrank();
    }

    function test_RegisterOperator() public {
        _registerL1(validatorManagerAddress, address(middleware));
        _registerOperator(alice, "metadata");
        _optInOperatorL1(alice, validatorManagerAddress);

        vm.startPrank(validatorManagerAddress);

        middleware.registerOperator(alice);
        vm.stopPrank();
    }

    function test_DepositAndGetOperatorStake() public {
        uint96 assetClassId = 1;
        uint256 maxVaultL1Limit = 2000 ether;
        // middleware.addAssetToClass(1, address(collateral));

        _registerL1(validatorManagerAddress, address(middleware));

        vm.startPrank(validatorManagerAddress);
        middleware.registerVault(address(vault), assetClassId, maxVaultL1Limit);
        vm.stopPrank();

        _grantDepositorWhitelistRole(bob, alice);
        (uint256 depositedAmount, uint256 mintedShares) = _deposit(alice, 500 ether);

        _setL1Limit(bob, validatorManagerAddress, assetClassId, depositedAmount);

        _registerOperator(alice, "alice metadata");
        _optInOperatorVault(alice);
        _optInOperatorL1(alice, validatorManagerAddress);

        _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, alice, mintedShares);

        uint48 epoch = middleware.getCurrentEpoch();
        uint256 stakeAlice = middleware.getOperatorStake(alice, epoch, assetClassId);
        console2.log("Alice stake:", stakeAlice);
        assertGt(stakeAlice, 0, "Bob's stake should be > 0 now");
    }

    function test_AddNodeFailsWithNoStake() public {
        // Register L1 and vault but do not deposit any stake.
        _registerL1(validatorManagerAddress, address(middleware));
        vm.startPrank(validatorManagerAddress);
        // Register vault (L1 limit can later be set if needed)
        middleware.registerVault(address(vault), 1, 2000 ether);
        vm.stopPrank();

        // Register the operator in the OperatorRegistry and opt in on L1.
        _registerOperator(alice, "alice metadata");
        _optInOperatorL1(alice, validatorManagerAddress);

        // Now register the operator in the middleware.
        vm.startPrank(validatorManagerAddress);
        middleware.registerOperator(alice);
        vm.stopPrank();

        // Do NOT deposit any funds for alice.
        // Try to add a node—this should revert because there is no free stake.
        bytes32 nodeId = bytes32("nodeNoStake");
        bytes memory blsKey = hex"deadbeef";
        uint64 registrationExpiry = uint64(block.timestamp + 1 days);
        address[] memory owners = new address[](1);
        owners[0] = alice;
        PChainOwner memory ownerStruct = PChainOwner({threshold: 1, addresses: owners});

        vm.prank(alice);
        vm.expectRevert(bytes4(keccak256("AvalancheL1Middleware__NotEnoughFreeStake()")));
        middleware.addNode(nodeId, blsKey, registrationExpiry, ownerStruct, ownerStruct, 0);
    }

    function test_AddNodeWithStakeAndTimeAdvance() public {
        // Register L1 and vault, then deposit stake.
        _registerL1(validatorManagerAddress, address(middleware));
        uint96 assetClassId = 1;
        uint256 maxVaultL1Limit = 2000 ether;
        vm.startPrank(validatorManagerAddress);
        middleware.registerVault(address(vault), assetClassId, maxVaultL1Limit);
        console2.log("L1Limit set to", maxVaultL1Limit);
        console2.log("L1Limit set actually", delegator.l1Limit(validatorManagerAddress, assetClassId));
        // console2.log("L1Limit set actually", delegator.maxL1Limit[validatorManagerAddress][assetClassId]);
        console2.log("Current VAULT epoch start:", vault.currentEpochStart());

        vm.stopPrank();

        // Register and opt in the operator.
        _registerOperator(alice, "alice metadata");
        _optInOperatorL1(alice, validatorManagerAddress);
        _optInOperatorVault(alice);
        vm.startPrank(validatorManagerAddress);
        middleware.registerOperator(alice);
        vm.stopPrank();

        // Deposit funds into the vault (the user deposits stake).
        _grantDepositorWhitelistRole(bob, alice);
        // _grantL1LimiteRole(bob, alice);
        (uint256 depositedAmount, uint256 mintedShares) = _deposit(alice, 500 ether);
        _setL1Limit(bob, validatorManagerAddress, assetClassId, depositedAmount);
        _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, alice, mintedShares);

        // Capture the current epoch and time
        uint48 currentEpoch = middleware.getCurrentEpoch();
        uint256 operatorStake = middleware.getOperatorStake(alice, currentEpoch, assetClassId);
        console2.log("Operator stake after deposit (epoch", currentEpoch, "):", operatorStake);
        assertGt(operatorStake, 0, "Operator stake should be higher than 0 in the current epoch"); // It should be 0, but it's updated immediately.
        
        // Advance time into the next middleware epoch.
        // uint48 nextEpoch = currentEpoch + 1;
        // uint256 nextEpochStart = middleware.getEpochStartTs(nextEpoch);
        // uint256 nextEpochStart = middleware.getEpochStartTs(currentEpoch) + middleware.getEpochDuration();
        uint256 newEpochStart = vault.currentEpochStart() + vault.epochDuration() + vault.epochDuration();
        vm.warp(newEpochStart); // move just past the start of the next epoch
        console2.log("New VAULT epoch start:", vault.currentEpochStart());
        console2.log("New VAULT epoch:", vault.currentEpoch());
        console2.log("Vault stake:", vault.totalStake());
        // Now, recalc stakes for the new epoch.
        uint48 newEpoch = middleware.getCurrentEpoch();
        console2.log("New MIDDLEWARE epoch:", newEpoch);
        middleware.calcAndCacheStakes(newEpoch, assetClassId);
        console2.log("New epoch:", newEpoch);
        uint256 newStake = middleware.getOperatorStake(alice, newEpoch, assetClassId);
        console2.log("Operator stake in new epoch:", newStake);
        assertGe(newStake, operatorStake, "Operator stake in new epoch should reflect the deposit");

        // Add a node.
        bytes32 nodeId = bytes32("nodeWithStake");
        bytes memory blsKey = hex"1234";
        uint64 registrationExpiry = uint64(block.timestamp + 1 days);
        address[] memory owners = new address[](1);
        owners[0] = alice;
        PChainOwner memory ownerStruct = PChainOwner({threshold: 1, addresses: owners});

        vm.prank(alice);
        middleware.addNode(nodeId, blsKey, registrationExpiry, ownerStruct, ownerStruct, 0);

        // Check that the node weight cached is zero and that operatorLockedStake was updated.
        bytes32 validationID = middleware.getCurrentValidationID(nodeId);
        uint256 nodeWeight = middleware.nodeWeightCache(newEpoch, validationID);
        console2.log("Node weight:", nodeWeight);
        assertEq(nodeWeight, 0, "Node actual weight must be zero until next epoch if it's activated");
        uint256 lockedStake = middleware.operatorLockedStake(alice);
        assertGt(lockedStake, 0, "LockedStake should be positive after adding a node");
    }

    /// @notice Test that an operator can add a node.
    function test_AddNodeSimple() public {
        // Register L1 and vault, then register the operator on the registry.
        _registerL1(validatorManagerAddress, address(middleware));

        uint96 assetClassId = 1;
        uint256 maxVaultL1Limit = 2000 ether;
        vm.startPrank(validatorManagerAddress);
        // Register the vault first so that L1 limit can be set later.
        middleware.registerVault(address(vault), assetClassId, maxVaultL1Limit);
        vm.stopPrank();

        // Register the operator on the OperatorRegistry BEFORE calling registerOperator on middleware.
        _registerOperator(alice, "alice metadata");
        _optInOperatorL1(alice, validatorManagerAddress);
        _optInOperatorVault(alice);

        // Now register the operator in the middleware.
        vm.startPrank(validatorManagerAddress);
        middleware.registerOperator(alice);
        vm.stopPrank();

        _grantDepositorWhitelistRole(bob, alice);
        (uint256 depositedAmount, uint256 mintedShares) = _deposit(alice, 500 ether);
        _setL1Limit(bob, validatorManagerAddress, assetClassId, depositedAmount);
        _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, alice, mintedShares);

        uint256 newEpochStart = vault.currentEpochStart() + vault.epochDuration() + 1;
        vm.warp(newEpochStart);
        uint48 epoch = middleware.getCurrentEpoch();
        uint256 totalStake = middleware.getOperatorStake(alice, epoch, assetClassId);
        assertGt(totalStake, 0);

        // Add a node.
        bytes32 nodeId = bytes32("node1");
        bytes memory blsKey = hex"1234";
        uint64 registrationExpiry = uint64(block.timestamp + 1 days);
        address[] memory ownerArr = new address[](1);
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct = PChainOwner({threshold: 1, addresses: ownerArr});

        vm.prank(alice);
        middleware.addNode(nodeId, blsKey, registrationExpiry, ownerStruct, ownerStruct, 0);

        // Check that the node weight cached is zero and that operatorLockedStake was updated.
        bytes32 validationID = middleware.getCurrentValidationID(nodeId);
        uint256 nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        console2.log("Node weight:", nodeWeight);
        assertEq(nodeWeight, 0, "Node actual weight must be zero until next epoch if it's activated");
        uint256 lockedStake = middleware.operatorLockedStake(alice);
        assertGt(lockedStake, 0, "LockedStake should be positive after adding a node");

        vm.prank(alice);
        middleware.completeValidatorRegistration(nodeId, 0);

        // Move Middleware Epoch + 1
        epoch = middleware.getCurrentEpoch();
        uint48 newMiddlewareEpochStart = middleware.getEpochStartTs(epoch) + middleware.getEpochDuration() + 1;

        vm.warp(newMiddlewareEpochStart);
        epoch = middleware.getCurrentEpoch();
        middleware.calcAndCacheNodeWeightsForOperator(alice);
        validationID = middleware.getCurrentValidationID(nodeId);
        nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        console2.log("Node weight:", nodeWeight);

        // Check that the node weight is still not updated in the middleware until next epoch.
        assertGt(nodeWeight, 0, "Node actual weight must be positive after confirmation");
        lockedStake = middleware.operatorLockedStake(alice);
        assertEq(lockedStake, 0, "LockedStake should be 0 after node weight is confirmed");
    }

    /// @notice Test that an operator can add a node.
    function test_AddNodeLateCompletition() public {
        // Register L1 and vault, then register the operator on the registry.
        _registerL1(validatorManagerAddress, address(middleware));

        uint96 assetClassId = 1;
        uint256 maxVaultL1Limit = 2000 ether;
        vm.startPrank(validatorManagerAddress);
        // Register the vault first so that L1 limit can be set later.
        middleware.registerVault(address(vault), assetClassId, maxVaultL1Limit);
        vm.stopPrank();

        // Register the operator on the OperatorRegistry BEFORE calling registerOperator on middleware.
        _registerOperator(alice, "alice metadata");
        _optInOperatorL1(alice, validatorManagerAddress);
        _optInOperatorVault(alice);

        // Now register the operator in the middleware.
        vm.startPrank(validatorManagerAddress);
        middleware.registerOperator(alice);
        vm.stopPrank();

        _grantDepositorWhitelistRole(bob, alice);
        (uint256 depositedAmount, uint256 mintedShares) = _deposit(alice, 500 ether);
        _setL1Limit(bob, validatorManagerAddress, assetClassId, depositedAmount);
        _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, alice, mintedShares);

        uint256 newEpochStart = vault.currentEpochStart() + vault.epochDuration() + 1;
        vm.warp(newEpochStart);
        uint48 epoch = middleware.getCurrentEpoch();
        uint256 totalStake = middleware.getOperatorStake(alice, epoch, assetClassId);
        assertGt(totalStake, 0);

        // Add a node.
        bytes32 nodeId = bytes32("node1");
        bytes memory blsKey = hex"1234";
        uint64 registrationExpiry = uint64(block.timestamp + 1 days);
        address[] memory ownerArr = new address[](1);
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct = PChainOwner({threshold: 1, addresses: ownerArr});

        vm.prank(alice);
        middleware.addNode(nodeId, blsKey, registrationExpiry, ownerStruct, ownerStruct, 0);

        // Check that the node weight cached is zero and that operatorLockedStake was updated.
        bytes32 validationID = middleware.getCurrentValidationID(nodeId);
        uint256 nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        console2.log("Node weight:", nodeWeight);
        assertEq(nodeWeight, 0, "Node actual weight must be zero until next epoch if it's activated");
        uint256 lockedStake = middleware.operatorLockedStake(alice);
        assertGt(lockedStake, 0, "LockedStake should be positive after adding a node");
        epoch = middleware.getCurrentEpoch();
        uint48 newMiddlewareEpochStart = middleware.getEpochStartTs(epoch) + middleware.getEpochDuration() + 1;

        // Move Middleware Epoch + 1 and check that the node weight is still not updated
        vm.warp(newMiddlewareEpochStart);
        epoch = middleware.getCurrentEpoch();
        validationID = middleware.getCurrentValidationID(nodeId);
        nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        console2.log("Node weight:", nodeWeight);

        // Should be zero until confirmed in the balancer
        assertEq(nodeWeight, 0, "Node actual weight must be zero until next epoch if it's activated");
        lockedStake = middleware.operatorLockedStake(alice);
        assertGt(lockedStake, 0, "LockedStake should be positive after adding a node");

        // Complete the node registration, won't be enabled until next epoch
        vm.startPrank(alice);
        console2.log("nodePendingUpdate[valId]", middleware.nodePendingUpdate(middleware.getCurrentValidationID(nodeId)));
        middleware.completeValidatorRegistration(nodeId, 0);
        middleware.calcAndCacheNodeWeightsForOperator(alice);
        vm.stopPrank();
        
        // Check that the node weight is still not updated in the middleware until next epoch.
        nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        assertEq(nodeWeight, 0, "Node actual weight must be zero until next epoch if it's activated");
        lockedStake = middleware.operatorLockedStake(alice);
        assertGt(lockedStake, 0, "LockedStake should be positive after adding a node");
        
        // Move to the next epoch
        newMiddlewareEpochStart = middleware.getEpochStartTs(epoch) + middleware.getEpochDuration() + 1;
        vm.warp(newMiddlewareEpochStart);
        epoch = middleware.getCurrentEpoch();

        vm.prank(alice);
        middleware.calcAndCacheNodeWeightsForOperator(alice);
        
        nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        // Check that the node weight is still not updated in the middleware until next epoch.
        assertGt(nodeWeight, 0, "Node actual weight must be positive after confirmation");
        lockedStake = middleware.operatorLockedStake(alice);
        assertEq(lockedStake, 0, "LockedStake should be 0 after node weight is confirmed");
    }

    function test_CompleteNodeWeightUpdate() public {
        uint96 assetClassId = 1;
        // Register L1 and the vault first.
        _registerL1(validatorManagerAddress, address(middleware));
        vm.prank(validatorManagerAddress);
        middleware.registerVault(address(vault), 1, 20 ether);

        _registerOperator(alice, "alice metadata");
        _optInOperatorL1(alice, validatorManagerAddress);
        _optInOperatorVault(alice);
        vm.prank(validatorManagerAddress);
        middleware.registerOperator(alice);

        _grantDepositorWhitelistRole(bob, alice);
        (uint256 depositedAmount, uint256 mintedShares) = _deposit(alice, 10 ether);
        _setL1Limit(bob, validatorManagerAddress, 1, depositedAmount);
        _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, alice, mintedShares);

        uint256 newEpochStart = vault.currentEpochStart() + vault.epochDuration() + 1;
        vm.warp(newEpochStart);
        uint48 epoch = middleware.getCurrentEpoch();
        bytes32 nodeId = bytes32("node2");
        bytes memory blsKey = hex"5678";
        uint64 registrationExpiry = uint64(block.timestamp + 1 days);
        address[] memory ownerArr = new address[](1);
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct = PChainOwner({threshold: 1, addresses: ownerArr});

        // Add node
        vm.prank(alice);
        middleware.addNode(nodeId, blsKey, registrationExpiry, ownerStruct, ownerStruct, 0);
        bytes32 validationID = middleware.getCurrentValidationID(nodeId);
        // Check initial node weight in the middleware is still 0
        uint256 initialNodeWeight = middleware.nodeWeightCache(epoch, validationID);
        assertEq(initialNodeWeight, 0, "Node actual weight must be zero until next epoch if it's activated");
        assertGt(middleware.operatorLockedStake(alice), 0, "LockedStake should be positive after adding a node");

        // Simulate activation of the validator in the mock before updating weight
        // mockValidatorManager.simulateActivateValidator(validationID);

        // Complete node registration and calculate and cache node weights for the operator, 
        vm.prank(alice);
        middleware.completeValidatorRegistration(nodeId, 0);
        middleware.calcAndCacheNodeWeightsForOperator(alice);
        initialNodeWeight = middleware.nodeWeightCache(epoch, validationID);
        // Still 0 until next epoch
        assertEq(initialNodeWeight, 0, "Node actual weight must be zero until next epoch if it's activated");
        assertGt(middleware.operatorLockedStake(alice), 0, "LockedStake should be positive after adding a node");

        // Run calcAndCacheNodeWeightsForOperator twice to check
        middleware.calcAndCacheNodeWeightsForOperator(alice);
        initialNodeWeight = middleware.nodeWeightCache(epoch, validationID);
        // Still 0 until next epoch
        assertEq(initialNodeWeight, 0, "Node actual weight must be zero until next epoch if it's activated");
        assertGt(middleware.operatorLockedStake(alice), 0, "LockedStake should be positive after adding a node");
        assertEq(middleware.operatorLockedStake(alice), 10 ether, "LockedStake should be 1000 ether after node weight is confirmed");

        epoch = middleware.getCurrentEpoch();
        uint48 newMiddlewareEpochStart = middleware.getEpochStartTs(epoch) + middleware.getEpochDuration() + 1;

        vm.warp(newMiddlewareEpochStart);
        epoch = middleware.getCurrentEpoch();
        validationID = middleware.getCurrentValidationID(nodeId);
        uint256 nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        console2.log("Node weight:", nodeWeight);

        // Should be registered in next epoch
        vm.prank(alice);
        // middleware.completeValidatorRegistration(nodeId, 0);
        middleware.calcAndCacheNodeWeightsForOperator(alice);
        uint256 lockedStake = middleware.operatorLockedStake(alice);
        nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        
        // Check that the node weight is now positive and that operatorLockedStake was updated.
        assertGt(nodeWeight, 0, "Node actual weight must be positive after confirmation");
        assertEq(lockedStake, 0, "LockedStake should be 0 after node weight is confirmed");

        // Reduce weight by 100
        uint64 newWeight = uint64(nodeWeight - 100);

        vm.prank(alice);
        middleware.initializeValidatorWeightUpdateAndLock(nodeId, newWeight);
        assertEq(middleware.nodePendingUpdate(validationID), true, "Should be set on pending");
        uint256 updatedNodeWeight = middleware.nodeWeightCache(epoch, validationID);
        // this shouldn't happen before completition, nor before the next epoch..
        assertEq(updatedNodeWeight - newWeight, 100, "Node weight should be still not updated to the new value and bigger than new weight");
        assertEq(middleware.operatorLockedStake(alice), 0, "LockedStake should be 0 after updating a node, since it's still cached");

        vm.prank(alice);
        middleware.completeNodeWeightUpdate(nodeId, 0);
        console2.log("Node weight:", nodeWeight);
        middleware.calcAndCacheNodeWeightsForOperator(alice);

        // Weight updated this actually should only be done by the next epoch?
        updatedNodeWeight = middleware.nodeWeightCache(epoch, validationID);
        console2.log("Node weight:", updatedNodeWeight);
        console2.log("New weight:", newWeight);
        assertEq(updatedNodeWeight - newWeight, 100, "Node weight should be still not updated to the new value and bigger than new weight");
        assertEq(middleware.operatorLockedStake(alice), 0, "LockedStake should be 0 as it's a negative update");

        newMiddlewareEpochStart = middleware.getEpochStartTs(epoch) + middleware.getEpochDuration() + 1;

        vm.warp(newMiddlewareEpochStart);
        updatedNodeWeight = middleware.nodeWeightCache(epoch, validationID);
        assertEq(updatedNodeWeight - newWeight, 100, "Node weight should be still not updated to the new value and bigger than new weight");
        assertEq(middleware.operatorLockedStake(alice), 0, "LockedStake should be 0 as it's a negative update");

        vm.prank(alice);
        middleware.calcAndCacheNodeWeightsForOperator(alice);
        epoch = middleware.getCurrentEpoch();
        updatedNodeWeight = middleware.nodeWeightCache(epoch, validationID);
        epoch = middleware.getCurrentEpoch();
        assertEq(updatedNodeWeight, newWeight, "Node weight should be updated");
        assertEq(middleware.operatorLockedStake(alice), 0, "LockedStake should be still 0");
        assertEq(middleware.nodePendingCompletedUpdate(epoch, validationID), false, "Should be set on false");
    }

    function test_CompleteLateNodeWeightUpdate() public {
        uint96 assetClassId = 1;
        // Register L1 and the vault first.
        _registerL1(validatorManagerAddress, address(middleware));
        vm.prank(validatorManagerAddress);
        middleware.registerVault(address(vault), 1, 20 ether);

        _registerOperator(alice, "alice metadata");
        _optInOperatorL1(alice, validatorManagerAddress);
        _optInOperatorVault(alice);
        vm.prank(validatorManagerAddress);
        middleware.registerOperator(alice);

        _grantDepositorWhitelistRole(bob, alice);
        (uint256 depositedAmount, uint256 mintedShares) = _deposit(alice, 10 ether);
        _setL1Limit(bob, validatorManagerAddress, 1, depositedAmount);
        _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, alice, mintedShares);

        uint256 newEpochStart = vault.currentEpochStart() + vault.epochDuration() + 1;
        vm.warp(newEpochStart);
        uint48 epoch = middleware.getCurrentEpoch();
        bytes32 nodeId = bytes32("node2");
        bytes memory blsKey = hex"5678";
        uint64 registrationExpiry = uint64(block.timestamp + 1 days);
        address[] memory ownerArr = new address[](1);
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct = PChainOwner({threshold: 1, addresses: ownerArr});

        // Add node
        vm.prank(alice);
        middleware.addNode(nodeId, blsKey, registrationExpiry, ownerStruct, ownerStruct, 0);
        bytes32 validationID = middleware.getCurrentValidationID(nodeId);
        // Check initial node weight in the middleware is still 0
        uint256 initialNodeWeight = middleware.nodeWeightCache(epoch, validationID);
        assertEq(initialNodeWeight, 0, "Node actual weight must be zero until next epoch if it's activated");
        assertGt(middleware.operatorLockedStake(alice), 0, "LockedStake should be positive after adding a node");

        // Simulate activation of the validator in the mock before updating weight
        // mockValidatorManager.simulateActivateValidator(validationID);

        // Complete node registration and calculate and cache node weights for the operator, 
        vm.prank(alice);
        middleware.completeValidatorRegistration(nodeId, 0);
        middleware.calcAndCacheNodeWeightsForOperator(alice);
        initialNodeWeight = middleware.nodeWeightCache(epoch, validationID);
        // Still 0 until next epoch
        assertEq(initialNodeWeight, 0, "Node actual weight must be zero until next epoch if it's activated");
        assertGt(middleware.operatorLockedStake(alice), 0, "LockedStake should be positive after adding a node");

        // Run calcAndCacheNodeWeightsForOperator twice to check
        middleware.calcAndCacheNodeWeightsForOperator(alice);
        initialNodeWeight = middleware.nodeWeightCache(epoch, validationID);
        // Still 0 until next epoch
        assertEq(initialNodeWeight, 0, "Node actual weight must be zero until next epoch if it's activated");
        assertGt(middleware.operatorLockedStake(alice), 0, "LockedStake should be positive after adding a node");
        assertEq(middleware.operatorLockedStake(alice), 10 ether, "LockedStake should be 1000 ether after node weight is confirmed");

        epoch = middleware.getCurrentEpoch();
        uint48 newMiddlewareEpochStart = middleware.getEpochStartTs(epoch) + middleware.getEpochDuration() + 1;

        vm.warp(newMiddlewareEpochStart);
        epoch = middleware.getCurrentEpoch();
        validationID = middleware.getCurrentValidationID(nodeId);
        uint256 nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        console2.log("Node weight:", nodeWeight);

        // Should be registered in next epoch
        vm.prank(alice);
        // middleware.completeValidatorRegistration(nodeId, 0);
        middleware.calcAndCacheNodeWeightsForOperator(alice);
        uint256 lockedStake = middleware.operatorLockedStake(alice);
        nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        
        // Check that the node weight is now positive and that operatorLockedStake was updated.
        assertGt(nodeWeight, 0, "Node actual weight must be positive after confirmation");
        assertEq(lockedStake, 0, "LockedStake should be 0 after node weight is confirmed");

        // Reduce weight by 100
        uint64 newWeight = uint64(nodeWeight - 100);

        vm.prank(alice);
        middleware.initializeValidatorWeightUpdateAndLock(nodeId, newWeight);
        assertEq(middleware.nodePendingUpdate(validationID), true, "Should be set on pending");
        uint256 updatedNodeWeight = middleware.nodeWeightCache(epoch, validationID);
        // this shouldn't happen before completition, nor before the next epoch..
        assertEq(updatedNodeWeight - newWeight, 100, "Node weight should be still not updated to the new value and bigger than new weight");
        assertEq(middleware.operatorLockedStake(alice), 0, "LockedStake should be 0 after updating a node, since it's still cached");

        vm.warp(newMiddlewareEpochStart);
        updatedNodeWeight = middleware.nodeWeightCache(epoch, validationID);
        assertEq(updatedNodeWeight - newWeight, 100, "Node weight should be still not updated to the new value and bigger than new weight");
        assertEq(middleware.operatorLockedStake(alice), 0, "1 LockedStake should be 0 as it's a negative update");

        vm.warp(newMiddlewareEpochStart);
        updatedNodeWeight = middleware.nodeWeightCache(epoch, validationID);
        assertEq(updatedNodeWeight - newWeight, 100, "Node weight should be still not updated to the new value and bigger than new weight");
        assertEq(middleware.operatorLockedStake(alice), 0, "2 LockedStake should be 0 as it's a negative update");
        vm.prank(alice);
        middleware.calcAndCacheNodeWeightsForOperator(alice);
        assertEq(updatedNodeWeight - newWeight, 100, "Node weight should be still not updated to the new value and bigger than new weight");
        assertEq(middleware.operatorLockedStake(alice), 0, "3 LockedStake should be 0 as it's a negative update");

        vm.prank(alice);
        middleware.completeNodeWeightUpdate(nodeId, 0);
        console2.log("Node weight:", nodeWeight);
        // fails as it wasn't launched in EACH round, and therefor cached weight is not updated
        middleware.calcAndCacheNodeWeightsForOperator(alice);

        // Weight updated this actually should only be done by the next epoch?
        updatedNodeWeight = middleware.nodeWeightCache(epoch, validationID);
        console2.log("Node weight:", updatedNodeWeight);
        console2.log("New weight:", newWeight);
        assertEq(updatedNodeWeight - newWeight, 100, "Node weight should be still not updated to the new value and bigger than new weight");
        assertEq(middleware.operatorLockedStake(alice), 0, "4 LockedStake should be 0 as it's a negative update");

        newMiddlewareEpochStart = middleware.getEpochStartTs(epoch) + middleware.getEpochDuration() + 1;

        vm.warp(newMiddlewareEpochStart);
        updatedNodeWeight = middleware.nodeWeightCache(epoch, validationID);
        assertEq(updatedNodeWeight - newWeight, 100, "Node weight should be still not updated to the new value and bigger than new weight");
        assertEq(middleware.operatorLockedStake(alice), 0, "5 LockedStake should be 0 as it's a negative update");

        vm.prank(alice);
        middleware.calcAndCacheNodeWeightsForOperator(alice);
        epoch = middleware.getCurrentEpoch();
        updatedNodeWeight = middleware.nodeWeightCache(epoch, validationID);
        epoch = middleware.getCurrentEpoch();
        assertEq(updatedNodeWeight, newWeight, "Node weight should be updated");
        assertEq(middleware.operatorLockedStake(alice), 0, "LockedStake should be still 0");
        assertEq(middleware.nodePendingCompletedUpdate(epoch, validationID), false, "Should be set on false");
    }


    /// @notice Test that an operator can add a node.
    function test_RemoveNodeSimple() public {
        // Register L1 and vault, then register the operator on the registry.
        _registerL1(validatorManagerAddress, address(middleware));

        uint96 assetClassId = 1;
        uint256 maxVaultL1Limit = 2000 ether;
        vm.startPrank(validatorManagerAddress);
        // Register the vault first so that L1 limit can be set later.
        middleware.registerVault(address(vault), assetClassId, maxVaultL1Limit);
        vm.stopPrank();

        // Register the operator on the OperatorRegistry BEFORE calling registerOperator on middleware.
        _registerOperator(alice, "alice metadata");
        _optInOperatorL1(alice, validatorManagerAddress);
        _optInOperatorVault(alice);

        // Now register the operator in the middleware.
        vm.startPrank(validatorManagerAddress);
        middleware.registerOperator(alice);
        vm.stopPrank();

        _grantDepositorWhitelistRole(bob, alice);
        (uint256 depositedAmount, uint256 mintedShares) = _deposit(alice, 500 ether);
        _setL1Limit(bob, validatorManagerAddress, assetClassId, depositedAmount);
        _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, alice, mintedShares);

        uint256 newEpochStart = vault.currentEpochStart() + vault.epochDuration() + 1;
        vm.warp(newEpochStart);
        uint48 epoch = middleware.getCurrentEpoch();
        uint256 totalStake = middleware.getOperatorStake(alice, epoch, assetClassId);
        assertGt(totalStake, 0);

        // Add a node.
        bytes32 nodeId = bytes32("node1");
        bytes memory blsKey = hex"1234";
        uint64 registrationExpiry = uint64(block.timestamp + 1 days);
        address[] memory ownerArr = new address[](1);
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct = PChainOwner({threshold: 1, addresses: ownerArr});

        vm.prank(alice);
        middleware.addNode(nodeId, blsKey, registrationExpiry, ownerStruct, ownerStruct, 0);

        // Check that the node weight cached is zero and that operatorLockedStake was updated.
        bytes32 validationID = middleware.getCurrentValidationID(nodeId);
        uint256 nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        console2.log("Node weight:", nodeWeight);
        assertEq(nodeWeight, 0, "Node actual weight must be zero until next epoch if it's activated");
        uint256 lockedStake = middleware.operatorLockedStake(alice);
        assertGt(lockedStake, 0, "LockedStake should be positive after adding a node");

        vm.prank(alice);
        middleware.completeValidatorRegistration(nodeId, 0);

        // Move Middleware Epoch + 1
        epoch = middleware.getCurrentEpoch();
        uint48 newMiddlewareEpochStart = middleware.getEpochStartTs(epoch) + middleware.getEpochDuration() + 1;

        vm.warp(newMiddlewareEpochStart);
        epoch = middleware.getCurrentEpoch();

        middleware.calcAndCacheNodeWeightsForOperator(alice);
        validationID = middleware.getCurrentValidationID(nodeId);
        nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        console2.log("Node weight:", nodeWeight);

        // Check that the node weight is still not updated in the middleware until next epoch.
        assertGt(nodeWeight, 0, "Node actual weight must be positive after confirmation");
        lockedStake = middleware.operatorLockedStake(alice);
        assertEq(lockedStake, 0, "LockedStake should be 0 after node weight is confirmed");

        // Remove the node
        vm.prank(alice);
        middleware.removeNode(nodeId);

        // Check that the node weight is still up until next epoch and nodePendingUpdate is set
        nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        assertGt(nodeWeight, 0, "Node actual weight must be positive after confirmation");
        assertEq(middleware.nodePendingUpdate(validationID), true, "Node should be pending update after removal");

        // Move to the next epoch
        newMiddlewareEpochStart = middleware.getEpochStartTs(epoch) + middleware.getEpochDuration() + 1;
        vm.warp(newMiddlewareEpochStart);
        epoch = middleware.getCurrentEpoch();
        

        middleware.calcAndCacheNodeWeightsForOperator(alice);
        nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        assertGt(nodeWeight, 0, "Node 1 actual weight must be positive after confirmation");
        assertEq(middleware.nodePendingUpdate(validationID), true, "Node should be pending update after removal");

        // Confirm the removal
        vm.prank(alice);
        middleware.completeValidatorRemoval(nodeId, 1);

        // middleware.calcAndCacheNodeWeightsForOperator(alice);
        nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        assertGt(nodeWeight, 0, "Node 2 actual weight must be positive after confirmation");
        assertEq(middleware.nodePendingUpdate(validationID), true, "Node should be pending update after removal");

        // Move Middleware Epoch + 1
        epoch = middleware.getCurrentEpoch();
        newMiddlewareEpochStart = middleware.getEpochStartTs(epoch) + middleware.getEpochDuration() + 1;

        vm.warp(newMiddlewareEpochStart);
        epoch = middleware.getCurrentEpoch();
        middleware.calcAndCacheNodeWeightsForOperator(alice);
        nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        console2.log("Node weight:", nodeWeight);

        // Check that the node weight is now zero and that operatorLockedStake was updated.
        assertEq(nodeWeight, 0, "Node actual weight must be zero after removal");
        assertEq(middleware.nodePendingUpdate(validationID), false, "Node should not be pending update after removal");
    }

    /// @notice Test that an operator can add a node.
    function test_RemoveNodeLate() public {
        // Register L1 and vault, then register the operator on the registry.
        _registerL1(validatorManagerAddress, address(middleware));

        uint96 assetClassId = 1;
        uint256 maxVaultL1Limit = 2000 ether;
        vm.startPrank(validatorManagerAddress);
        // Register the vault first so that L1 limit can be set later.
        middleware.registerVault(address(vault), assetClassId, maxVaultL1Limit);
        vm.stopPrank();

        // Register the operator on the OperatorRegistry BEFORE calling registerOperator on middleware.
        _registerOperator(alice, "alice metadata");
        _optInOperatorL1(alice, validatorManagerAddress);
        _optInOperatorVault(alice);

        // Now register the operator in the middleware.
        vm.startPrank(validatorManagerAddress);
        middleware.registerOperator(alice);
        vm.stopPrank();

        _grantDepositorWhitelistRole(bob, alice);
        (uint256 depositedAmount, uint256 mintedShares) = _deposit(alice, 500 ether);
        _setL1Limit(bob, validatorManagerAddress, assetClassId, depositedAmount);
        _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, alice, mintedShares);

        uint256 newEpochStart = vault.currentEpochStart() + vault.epochDuration() + 1;
        vm.warp(newEpochStart);
        uint48 epoch = middleware.getCurrentEpoch();
        uint256 totalStake = middleware.getOperatorStake(alice, epoch, assetClassId);
        assertGt(totalStake, 0);

        // Add a node.
        bytes32 nodeId = bytes32("node1");
        bytes memory blsKey = hex"1234";
        uint64 registrationExpiry = uint64(block.timestamp + 1 days);
        address[] memory ownerArr = new address[](1);
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct = PChainOwner({threshold: 1, addresses: ownerArr});

        vm.prank(alice);
        middleware.addNode(nodeId, blsKey, registrationExpiry, ownerStruct, ownerStruct, 0);

        // Check that the node weight cached is zero and that operatorLockedStake was updated.
        bytes32 validationID = middleware.getCurrentValidationID(nodeId);
        uint256 nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        console2.log("Node weight:", nodeWeight);
        assertEq(nodeWeight, 0, "Node actual weight must be zero until next epoch if it's activated");
        uint256 lockedStake = middleware.operatorLockedStake(alice);
        assertGt(lockedStake, 0, "LockedStake should be positive after adding a node");

        vm.prank(alice);
        middleware.completeValidatorRegistration(nodeId, 0);

        // Move Middleware Epoch + 1
        epoch = middleware.getCurrentEpoch();
        uint48 newMiddlewareEpochStart = middleware.getEpochStartTs(epoch) + middleware.getEpochDuration() + 1;

        vm.warp(newMiddlewareEpochStart);
        epoch = middleware.getCurrentEpoch();
        
        middleware.calcAndCacheNodeWeightsForOperator(alice);
        validationID = middleware.getCurrentValidationID(nodeId);
        nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        console2.log("Node weight:", nodeWeight);

        // Check that the node weight is still not updated in the middleware until next epoch.
        assertGt(nodeWeight, 0, "Node actual weight must be positive after confirmation");
        lockedStake = middleware.operatorLockedStake(alice);
        assertEq(lockedStake, 0, "LockedStake should be 0 after node weight is confirmed");

        // Remove the node
        vm.prank(alice);
        middleware.removeNode(nodeId);

        // Check that the node weight is still up until next epoch and nodePendingUpdate is set
        nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        assertGt(nodeWeight, 0, "Node actual weight must be positive after confirmation");
        assertEq(middleware.nodePendingUpdate(validationID), true, "Node should be pending update after removal");

        // Move to the next epoch
        newMiddlewareEpochStart = middleware.getEpochStartTs(epoch) + middleware.getEpochDuration() + 1;
        vm.warp(newMiddlewareEpochStart);
        epoch = middleware.getCurrentEpoch();
        

        middleware.calcAndCacheNodeWeightsForOperator(alice);
        nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        assertGt(nodeWeight, 0, "Node 1 actual weight must be positive after confirmation");
        assertEq(middleware.nodePendingUpdate(validationID), true, "Node should be pending update after removal");

        // Move to the next epoch
        newMiddlewareEpochStart = middleware.getEpochStartTs(epoch) + middleware.getEpochDuration() + 1;
        vm.warp(newMiddlewareEpochStart);
        epoch = middleware.getCurrentEpoch();

        middleware.calcAndCacheNodeWeightsForOperator(alice);
        nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        assertGt(nodeWeight, 0, "Node 1 actual weight must be positive after confirmation");
        assertEq(middleware.nodePendingUpdate(validationID), true, "Node should be pending update after removal");

        // Move to the next epoch
        newMiddlewareEpochStart = middleware.getEpochStartTs(epoch) + middleware.getEpochDuration() + 1;
        vm.warp(newMiddlewareEpochStart);
        epoch = middleware.getCurrentEpoch();
        middleware.calcAndCacheNodeWeightsForOperator(alice);

        // Confirm the removal
        vm.prank(alice);
        middleware.completeValidatorRemoval(nodeId, 1);

        // middleware.calcAndCacheNodeWeightsForOperator(alice);
        nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        assertGt(nodeWeight, 0, "Node 2 actual weight must be positive after confirmation");
        assertEq(middleware.nodePendingUpdate(validationID), true, "Node should be pending update after removal");

        // Move Middleware Epoch + 1
        epoch = middleware.getCurrentEpoch();
        newMiddlewareEpochStart = middleware.getEpochStartTs(epoch) + middleware.getEpochDuration() + 1;

        vm.warp(newMiddlewareEpochStart);
        epoch = middleware.getCurrentEpoch();
        middleware.calcAndCacheNodeWeightsForOperator(alice);
        nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        console2.log("Node weight:", nodeWeight);

        // Check that the node weight is now zero and that operatorLockedStake was updated.
        assertEq(nodeWeight, 0, "Node actual weight must be zero after removal");
        assertEq(middleware.nodePendingUpdate(validationID), false, "Node should not be pending update after removal");
    }

    /// @notice Test that an operator can add a node.
    function test_multipleNodes() public {
        // Register L1 and vault, then register the operator on the registry.
        _registerL1(validatorManagerAddress, address(middleware));

        uint96 assetClassId = 1;
        uint256 maxVaultL1Limit = 2000 ether;
        vm.startPrank(validatorManagerAddress);
        // Register the vault first so that L1 limit can be set later.
        middleware.registerVault(address(vault), assetClassId, maxVaultL1Limit);
        vm.stopPrank();

        // Register the operator on the OperatorRegistry BEFORE calling registerOperator on middleware.
        _registerOperator(alice, "alice metadata");
        _optInOperatorL1(alice, validatorManagerAddress);
        _optInOperatorVault(alice);

        // Now register the operator in the middleware.
        vm.startPrank(validatorManagerAddress);
        middleware.registerOperator(alice);
        vm.stopPrank();

        _grantDepositorWhitelistRole(bob, alice);
        (uint256 depositedAmount, uint256 mintedShares) = _deposit(alice, 500 ether);
        _setL1Limit(bob, validatorManagerAddress, assetClassId, depositedAmount);
        _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, alice, mintedShares);

        uint256 newEpochStart = vault.currentEpochStart() + vault.epochDuration() + 1;
        vm.warp(newEpochStart);
        uint48 epoch = middleware.getCurrentEpoch();
        uint256 totalStake = middleware.getOperatorStake(alice, epoch, assetClassId);
        assertGt(totalStake, 0);

        // Add a node.
        bytes32 nodeId1 = bytes32("node1");
        bytes memory blsKey1 = hex"1234";
        uint64 registrationExpiry = uint64(block.timestamp + 4 days);
        address[] memory ownerArr = new address[](1);
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct1 = PChainOwner({threshold: 1, addresses: ownerArr});

        // Get min stake
        uint256 iniitialStake = 100_000_000_000_000 + 1_000;
        vm.prank(alice);
        middleware.addNode(nodeId1, blsKey1, registrationExpiry, ownerStruct1, ownerStruct1, iniitialStake);

        // Add a node.
        bytes32 nodeId2 = bytes32("node2");
        bytes memory blsKey2 = hex"1235";
        registrationExpiry = uint64(block.timestamp + 4 days);
        ownerArr = new address[](1);
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct2 = PChainOwner({threshold: 1, addresses: ownerArr});

        vm.prank(alice);
        middleware.addNode(nodeId2, blsKey2, registrationExpiry, ownerStruct2, ownerStruct2, iniitialStake);

        // Check that the node weight cached is zero and that operatorLockedStake was updated.
        bytes32 validationID = middleware.getCurrentValidationID(nodeId1);
        uint256 nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        console2.log("Node weight:", nodeWeight);
        assertEq(nodeWeight, 0, "Node actual weight must be zero until next epoch if it's activated");
        uint256 lockedStake = middleware.operatorLockedStake(alice);
        assertGt(lockedStake, 0, "LockedStake should be positive after adding a node");

        bytes32 validationID2 = middleware.getCurrentValidationID(nodeId2);
        uint256 nodeWeight2 = middleware.nodeWeightCache(epoch, validationID2);
        console2.log("Node weight:", nodeWeight);
        assertEq(nodeWeight2, 0, "Node actual weight must be zero until next epoch if it's activated");
        lockedStake = middleware.operatorLockedStake(alice);
        assertGt(lockedStake, 0, "LockedStake should be positive after adding a node");

        vm.prank(alice);
        middleware.completeValidatorRegistration(nodeId1, 0);

        // Move Middleware Epoch + 1
        epoch = middleware.getCurrentEpoch();
        uint48 newMiddlewareEpochStart = middleware.getEpochStartTs(epoch) + middleware.getEpochDuration() + 1;

        vm.warp(newMiddlewareEpochStart);
        epoch = middleware.getCurrentEpoch();

        middleware.calcAndCacheNodeWeightsForOperator(alice);
        validationID = middleware.getCurrentValidationID(nodeId1);
        nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        console2.log("Node weight:", nodeWeight);

        // Check that the node weight is still not updated in the middleware until next epoch.
        assertGt(nodeWeight, 0, "Node actual weight must be positive after confirmation");
        lockedStake = middleware.operatorLockedStake(alice);
        assertEq(lockedStake, iniitialStake, "LockedStake should be stake of a single node weight after it is confirmed");

        vm.prank(alice);
        middleware.completeValidatorRegistration(nodeId2, 1);

        // Move Middleware Epoch + 1
        epoch = middleware.getCurrentEpoch();
        newMiddlewareEpochStart = middleware.getEpochStartTs(epoch) + middleware.getEpochDuration() + 1;

        vm.warp(newMiddlewareEpochStart);
        epoch = middleware.getCurrentEpoch();

        middleware.calcAndCacheNodeWeightsForOperator(alice);
        validationID2 = middleware.getCurrentValidationID(nodeId2);
        nodeWeight = middleware.nodeWeightCache(epoch, validationID2);
        console2.log("Node weight:", nodeWeight);

        // Check that the node weight is still not updated in the middleware until next epoch.
        assertGt(nodeWeight, 0, "Node actual weight must be positive after confirmation");
        lockedStake = middleware.operatorLockedStake(alice);
        assertEq(lockedStake, 0, "LockedStake should be 0 after node weight is confirmed");

        // Remove the node
        vm.prank(alice);
        middleware.removeNode(nodeId1);

        // Check that the node weight is still up until next epoch and nodePendingUpdate is set
        nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        assertGt(nodeWeight, 0, "Node actual weight must be positive only after confirmation");
        assertEq(middleware.nodePendingUpdate(validationID), true, "Node should be pending update after removal");

        // Move to the next epoch
        newMiddlewareEpochStart = middleware.getEpochStartTs(epoch) + middleware.getEpochDuration() + 1;
        vm.warp(newMiddlewareEpochStart);
        epoch = middleware.getCurrentEpoch();
        

        middleware.calcAndCacheNodeWeightsForOperator(alice);
        nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        assertGt(nodeWeight, 0, "Node 1 actual weight must be positive after confirmation");
        assertEq(middleware.nodePendingUpdate(validationID), true, "Node should be pending update after removal");

        // Confirm the removal
        vm.prank(alice);
        middleware.completeValidatorRemoval(nodeId1, 2);

        // middleware.calcAndCacheNodeWeightsForOperator(alice);
        nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        assertGt(nodeWeight, 0, "Node 2 actual weight must be positive after confirmation");
        assertEq(middleware.nodePendingUpdate(validationID), true, "Node should be pending update after removal");

        // Move Middleware Epoch + 1
        epoch = middleware.getCurrentEpoch();
        newMiddlewareEpochStart = middleware.getEpochStartTs(epoch) + middleware.getEpochDuration() + 1;

        vm.warp(newMiddlewareEpochStart);
        epoch = middleware.getCurrentEpoch();
        middleware.calcAndCacheNodeWeightsForOperator(alice);
        nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        console2.log("Node weight:", nodeWeight);

        // Check that the node weight is now zero and that operatorLockedStake was updated.
        assertEq(nodeWeight, 0, "Node actual weight must be zero after removal");
        assertEq(middleware.nodePendingUpdate(validationID), false, "Node should not be pending update after removal");
    }



    /// @notice Test that an operator can add a node.
    function test_forceUpdate() public {
        // Register L1 and vault, then register the operator on the registry.
        _registerL1(validatorManagerAddress, address(middleware));

        uint96 assetClassId = 1;
        uint256 maxVaultL1Limit = 2000 ether;
        vm.startPrank(validatorManagerAddress);
        // Register the vault first so that L1 limit can be set later.
        middleware.registerVault(address(vault), assetClassId, maxVaultL1Limit);
        vm.stopPrank();

        // Register the operator on the OperatorRegistry BEFORE calling registerOperator on middleware.
        _registerOperator(alice, "alice metadata");
        _optInOperatorL1(alice, validatorManagerAddress);
        _optInOperatorVault(alice);

        // Now register the operator in the middleware.
        vm.startPrank(validatorManagerAddress);
        middleware.registerOperator(alice);
        vm.stopPrank();

        _grantDepositorWhitelistRole(bob, alice);
        (uint256 depositedAmount, uint256 mintedShares) = _deposit(alice, 200_000_000_002_000);
        _setL1Limit(bob, validatorManagerAddress, assetClassId, depositedAmount);
        console2.log("Deposited amount:", depositedAmount);
        console2.log("Minted shares:", mintedShares);
        _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, alice, mintedShares);

        uint256 newEpochStart = vault.currentEpochStart() + vault.epochDuration() + 1;
        vm.warp(newEpochStart);
        uint48 epoch = middleware.getCurrentEpoch();
        uint256 totalStake = middleware.getOperatorStake(alice, epoch, assetClassId);
        assertGt(totalStake, 0);

        // Add a node.
        bytes32 nodeId1 = bytes32("node1");
        bytes memory blsKey1 = hex"1234";
        uint64 registrationExpiry = uint64(block.timestamp + 4 days);
        address[] memory ownerArr = new address[](1);
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct1 = PChainOwner({threshold: 1, addresses: ownerArr});

        // Get min stake
        uint256 iniitialStake = 100_000_000_000_000 + 1_000;
        vm.prank(alice);
        middleware.addNode(nodeId1, blsKey1, registrationExpiry, ownerStruct1, ownerStruct1, iniitialStake);

        // Add a node.
        bytes32 nodeId2 = bytes32("node2");
        bytes memory blsKey2 = hex"1235";
        registrationExpiry = uint64(block.timestamp + 4 days);
        ownerArr = new address[](1);
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct2 = PChainOwner({threshold: 1, addresses: ownerArr});

        vm.prank(alice);
        middleware.addNode(nodeId2, blsKey2, registrationExpiry, ownerStruct2, ownerStruct2, iniitialStake);

        // Check that the node weight cached is zero and that operatorLockedStake was updated.
        bytes32 validationID = middleware.getCurrentValidationID(nodeId1);
        uint256 nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        console2.log("Node weight:", nodeWeight);
        assertEq(nodeWeight, 0, "Node actual weight must be zero until next epoch if it's activated");
        uint256 lockedStake = middleware.operatorLockedStake(alice);
        assertGt(lockedStake, 0, "LockedStake should be positive after adding a node");

        bytes32 validationID2 = middleware.getCurrentValidationID(nodeId2);
        uint256 nodeWeight2 = middleware.nodeWeightCache(epoch, validationID2);
        console2.log("Node weight:", nodeWeight);
        assertEq(nodeWeight2, 0, "Node actual weight must be zero until next epoch if it's activated");
        lockedStake = middleware.operatorLockedStake(alice);
        assertGt(lockedStake, 0, "LockedStake should be positive after adding a node");

        vm.prank(alice);
        middleware.completeValidatorRegistration(nodeId1, 0);

        // Move Middleware Epoch + 1
        epoch = middleware.getCurrentEpoch();
        uint48 newMiddlewareEpochStart = middleware.getEpochStartTs(epoch) + middleware.getEpochDuration() + 1;

        vm.warp(newMiddlewareEpochStart);
        epoch = middleware.getCurrentEpoch();

        middleware.calcAndCacheNodeWeightsForOperator(alice);
        validationID = middleware.getCurrentValidationID(nodeId1);
        nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        console2.log("Node weight:", nodeWeight);

        // Check that the node weight is still not updated in the middleware until next epoch.
        assertGt(nodeWeight, 0, "Node actual weight must be positive after confirmation");
        lockedStake = middleware.operatorLockedStake(alice);
        assertEq(lockedStake, iniitialStake, "LockedStake should be stake of a single node weight after it is confirmed");

        vm.prank(alice);
        middleware.completeValidatorRegistration(nodeId2, 1);

        // Move Middleware Epoch + 1
        epoch = middleware.getCurrentEpoch();
        newMiddlewareEpochStart = middleware.getEpochStartTs(epoch) + middleware.getEpochDuration() + 1;

        vm.warp(newMiddlewareEpochStart);
        epoch = middleware.getCurrentEpoch();
        console2.log("Current middleware epoch:", middleware.getCurrentEpoch());


        middleware.calcAndCacheNodeWeightsForOperator(alice);
        validationID2 = middleware.getCurrentValidationID(nodeId2);
        nodeWeight = middleware.nodeWeightCache(epoch, validationID2);
        console2.log("Node weight:", nodeWeight);

        // Check that the node weight is still not updated in the middleware until next epoch.
        assertGt(nodeWeight, 0, "Node actual weight must be positive after confirmation");
        lockedStake = middleware.operatorLockedStake(alice);
        assertEq(lockedStake, 0, "LockedStake should be 0 after node weight is confirmed");

        _moveToNextEpochAndCalc(alice, 1);

        // Move forward to next vault epoch so that a withdrawal is scheduled into the next epoch
        // uint48 nextVaultEpoch = vault.currentEpochStart() + vault.epochDuration() + 1;
        // vm.warp(nextVaultEpoch);
        _moveToNextEpochAndCalc(alice, 2);
        uint256 withdrawAmount = 50_000_000_000_000; 
        // (just an example portion of what was deposited)
        _withdraw(alice, withdrawAmount);
        console2.log("Withdrawn from vault:", withdrawAmount);

        // Move to the middleware  epoch
        _moveToNextEpochAndCalc(alice, 1);
        middleware.updateAllNodeWeights(alice, 0);

        vm.prank(alice);
        middleware.completeValidatorRemoval(nodeId2, 2);

        _moveToNextEpochAndCalc(alice, 1);
        epoch = middleware.getCurrentEpoch();
        uint256 updatedStake = middleware.getOperatorStake(alice, epoch, assetClassId);
        console2.log("Operator stake after partial withdraw & updateAllNodeWeights:", updatedStake);
        nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        nodeWeight2 = middleware.nodeWeightCache(epoch, validationID2);
        console2.log("Node weight 1 after partial withdraw & updateAllNodeWeights:", nodeWeight);
        console2.log("Node weight 2 after partial withdraw & updateAllNodeWeights:", nodeWeight2);

        // Move forward another vault epoch so the user can claim
        _moveToNextEpochAndCalc(alice, 2);
        console2.log("previous epoch:", vault.currentEpoch() - 1);    
        uint256 claimEpoch = vault.currentEpoch() - 1;
        uint256 claimed = _claim(alice, claimEpoch);
        console2.log("Claimed after partial withdraw from vault:", claimed);

        _moveToNextEpochAndCalc(alice, 1);

        // Now call updateAllNodeWeights to recalc node weights based on lower stake
        vm.prank(alice);
        // middleware.updateAllNodeWeights(alice, 0);

        // At this point you can add checks/logs to verify the operator’s node weights 
        // reflect a smaller total stake. Something like:
        middleware.calcAndCacheNodeWeightsForOperator(alice);
        epoch = middleware.getCurrentEpoch();
        updatedStake = middleware.getOperatorStake(alice, epoch, assetClassId);
        console2.log("Operator stake after partial withdraw & updateAllNodeWeights:", updatedStake);
        nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        nodeWeight2 = middleware.nodeWeightCache(epoch, validationID2);
        console2.log("Node weight 1 after partial withdraw & updateAllNodeWeights:", nodeWeight);
        console2.log("Node weight 2 after partial withdraw & updateAllNodeWeights:", nodeWeight2);
    }


    // function test_ForceRemoveNode() public {
    //     uint96 assetClassId = 1;
    //     // Register L1 and vault first.
    //     _registerL1(validatorManagerAddress, address(middleware));
    //     vm.startPrank(validatorManagerAddress);
    //     middleware.registerVault(address(vault), 1, 2000 ether);
    //     vm.stopPrank();

    //     _registerOperator(alice, "alice metadata");
    //     _optInOperatorL1(alice, validatorManagerAddress);
    //     _optInOperatorVault(alice);

    //     vm.startPrank(validatorManagerAddress);
    //     middleware.registerOperator(alice);
    //     vm.stopPrank();

    //     _grantDepositorWhitelistRole(bob, alice);
    //     (uint256 depositedAmount, uint256 mintedShares) = _deposit(alice, 500 ether);
    //     _setL1Limit(bob, validatorManagerAddress, 1, depositedAmount);
    //     _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, alice, mintedShares);

    //     uint48 epoch = middleware.getCurrentEpoch();
    //     bytes32 nodeId = bytes32("node3");
    //     bytes memory blsKey = hex"9abc";
    //     uint64 registrationExpiry = uint64(block.timestamp + 1 days);
    //     address[] memory ownerArr = new address[](1);
    //     ownerArr[0] = alice;
    //     PChainOwner memory ownerStruct = PChainOwner({threshold: 1, addresses: ownerArr});

    //     vm.prank(alice);
    //     middleware.addNode(nodeId, blsKey, registrationExpiry, ownerStruct, ownerStruct, 0);
    //     bytes32 validationID = middleware.getCurrentValidationID(nodeId);
    //     uint256 initialNodeWeight = middleware.nodeWeightCache(epoch, validationID);
    //     assertGt(initialNodeWeight, 0);

    //     // Act: Force-remove the node. Have to fix adding function
    //     // vm.prank(validatorManagerAddress);
    //     // middleware.forceRemoveNode(alice);

    //     // // Assert: Node weight is now zero.
    //     // uint256 finalNodeWeight = middleware.nodeWeightCache(epoch, validationID);
    //     // assertEq(finalNodeWeight, 0, "Node weight should be zero after force removal");
    // }

    // /**
    //  * @dev Demonstrates multiple nodes for a single operator, calling updateAllNodeWeights,
    //  *      then adjusting stake to see how weights re-balance.
    //  */
    // function test_MultipleNodesUpdateAllWeights() public {
    //     // 1) Register L1 + Vault
    //     _registerL1(validatorManagerAddress, address(middleware));
    //     vm.startPrank(validatorManagerAddress);
    //     middleware.registerVault(address(vault), 1, 5 ether);
    //     vm.stopPrank();

    //     // 2) Register operator
    //     _registerOperator(alice, "alice metadata");
    //     _optInOperatorL1(alice, validatorManagerAddress);
    //     _optInOperatorVault(alice);
    //     vm.startPrank(validatorManagerAddress);
    //     middleware.registerOperator(alice);
    //     vm.stopPrank();

    //     // 3) Alice deposits
    //     _grantDepositorWhitelistRole(bob, alice);
    //     (uint256 depositedAmount, uint256 mintedShares) = _deposit(alice, 2 ether);

    //     // 4) Set L1 Limit + operator shares
    //     _grantL1LimiteRole(bob, alice);
    //     _setL1Limit(bob, validatorManagerAddress, 1, depositedAmount);
    //     _setOperatorL1Shares(bob, validatorManagerAddress, 1, alice, mintedShares);

    //     // 5) Advance epoch so stake is recognized in the new epoch
    //     uint256 nextEpochStart = vault.currentEpochStart() + vault.epochDuration() + 1;
    //     vm.warp(nextEpochStart);
    //     uint48 epochNow = middleware.getCurrentEpoch();
    //     middleware.calcAndCacheStakes(epochNow, 1);

    //     // 6) Add multiple nodes
    //     bytes32 node1 = bytes32("nodeA");
    //     bytes32 node2 = bytes32("nodeB");

    //     // mock manager says it's all good:
    //     // mockValidatorManager.simulateActivateValidator(bytes32("dummy"));

    //     {
    //         // Node1
    //         bytes memory blsKey = hex"111111";
    //         address[] memory owners = new address[](1);
    //         owners[0] = alice;
    //         PChainOwner memory pOwner = PChainOwner({threshold: 1, addresses: owners});
    //         console2.log("Adding node1");
    //         vm.prank(alice);
    //         middleware.addNode(node1, blsKey, uint64(block.timestamp + 1 days), pOwner, pOwner, 0);
    //         bytes32 _valId1 = middleware.getCurrentValidationID(node1);
    //         // Now the manager “knows” about this node as “pending”
    //         mockValidatorManager.simulateActivateValidator(_valId1);
    //     }

    //     {
    //         // Node2
    //         bytes memory blsKey = hex"222222";
    //         address[] memory owners = new address[](1);
    //         owners[0] = alice;
    //         PChainOwner memory pOwner = PChainOwner({threshold: 1, addresses: owners});
    //         console2.log("Adding node2");
    //         vm.prank(alice);
    //         middleware.addNode(node2, blsKey, uint64(block.timestamp + 1 days), pOwner, pOwner, 0);
    //         bytes32 _valId2 = middleware.getCurrentValidationID(node2);
    //         mockValidatorManager.simulateActivateValidator(_valId2);
    //     }

    //     // 7) Check initial locked stake across both nodes
    //     uint48 ep = middleware.getCurrentEpoch();
    //     bytes32 valId1 = middleware.getCurrentValidationID(node1);
    //     bytes32 valId2 = middleware.getCurrentValidationID(node2);
    //     uint256 node1Weight = middleware.nodeWeightCache(ep, valId1);
    //     uint256 node2Weight = middleware.nodeWeightCache(ep, valId2);

    //     // 8) Now let's reduce the shares for operator => effectively reduce stake
    //     // We'll do it by removing half the deposit from the vault
    //     uint256 half = 0.4 ether;
    //     vm.prank(alice);
    //     vault.withdraw(alice, half); // remove 1000
    //     // In the next epoch, total stake for alice should drop drastically.

    //     // 9) Advance to next epoch => then call updateAllNodeWeights
    //     uint256 secondEpochStart = vault.currentEpochStart() + vault.epochDuration() + 1;
    //     vm.warp(secondEpochStart);
    //     uint48 newEpoch = middleware.getCurrentEpoch();
    //     // must recalc base stake
    //     middleware.calcAndCacheStakes(newEpoch, 1);
    //     // triggers a rebalancing of node weights
    //     vm.prank(alice);
    //     // This uses the internal logic to see if some node must be ended or weight lowered
    //     middleware.updateAllNodeWeights(alice, 0);




    //     // Suppose node2 is the one that got rebalanced to a lower stake
    //     // We'll do a final "confirm" step so the nodeWeightCache actually sees the new weight

    //     // 1) Check that operatorLockedStake is still elevated (some stake is locked for the pending update)
    //     uint256 lockedBefore = middleware.operatorLockedStake(alice);
    //     uint256 operatorAvailableBefore = middleware.getOperatorAvailableStake(alice);
    //     console2.log("Locked stake before confirmation:", lockedBefore);
    //     console2.log("Available stake before confirmation:", operatorAvailableBefore);

    //     // 2) The manager sees a pending weight update for node2.  
    //     //    We emulate finalization:
    //     uint64 finalWeight = 600_000_000_000_000_000; // e.g. 0.6 ETH, as rebalanced
    //     mockValidatorManager.simulateWeightUpdate(valId2, finalWeight);

    //     // 3) Now we call completeNodeWeightUpdate(...) on the middleware to finalize
    //     vm.prank(alice);
    //     middleware.completeNodeWeightUpdate(node2, 0); 
    //     // The "messageIndex" param is normally the cross-chain message index, 
    //     // but in a local mock scenario you might pass 0 or 1, 
    //     // depending on your mock’s implementation.

    //     uint256 lockedAfter = middleware.operatorLockedStake(alice);
    //     console2.log("Locked stake after confirm:", lockedAfter);

    //     // 4) Re-check the node weight
    //     newEpoch = middleware.getCurrentEpoch();
    //     uint256 val2NewWeight = middleware.nodeWeightCache(newEpoch, valId2);
    //     console2.log("node2 final weight:", val2NewWeight);

    //     // 5) Now your test's final assertion sees node2 weight < the old 1.0 ETH
    //     assertTrue(val2NewWeight < 1 ether, "node2 weight must be below the old 1.0 ETH");

    //     // 10) Check updated weights
    //     uint256 val1NewWeight = middleware.nodeWeightCache(newEpoch, valId1);
    //     // Because half the stake was removed, likely each node's weight will be reduced
    //     // or one might be removed if the new total is below min stake. We'll just check it changed.
    //     assertTrue(val1NewWeight < node1Weight || val2NewWeight < node2Weight, "At least one node weight should be smaller");
    // }

    // /**
    //  * @dev Checks that we can read older epochs' stake from the cache,
    //  *      plus we confirm nodeIDs / validationIDs differ across time.
    //  */
    // function test_PastEpochWeightsAndIDs() public {
    //     // 1) Prepare vault and operator
    //     _registerL1(validatorManagerAddress, address(middleware));
    //     vm.startPrank(validatorManagerAddress);
    //     middleware.registerVault(address(vault), 1, 3000 ether);
    //     vm.stopPrank();

    //     _registerOperator(alice, "opAlice");
    //     _optInOperatorL1(alice, validatorManagerAddress);
    //     _optInOperatorVault(alice);

    //     vm.startPrank(validatorManagerAddress);
    //     middleware.registerOperator(alice);
    //     vm.stopPrank();

    //     // 2) Alice deposits 1500
    //     _grantDepositorWhitelistRole(bob, alice);
    //     _grantL1LimiteRole(bob, alice);
    //     (uint256 depAmt, uint256 minted) = _deposit(alice, 1500 ether);
    //     _setL1Limit(bob, validatorManagerAddress, 1, depAmt);
    //     _setOperatorL1Shares(bob, validatorManagerAddress, 1, alice, minted);

    //     // 3) Advance 1 epoch => store that stake in cache
    //     uint256 epochStart1 = vault.currentEpochStart() + vault.epochDuration() + 1;
    //     vm.warp(epochStart1);
    //     uint48 epoch1 = middleware.getCurrentEpoch();
    //     middleware.calcAndCacheStakes(epoch1, 1);

    //     // 4) Alice deposits an additional 500 => total 2000
    //     (uint256 depAmt2, uint256 minted2) = _deposit(alice, 500 ether);
    //     _setL1Limit(bob, validatorManagerAddress, 1, depAmt + depAmt2);
    //     _setOperatorL1Shares(bob, validatorManagerAddress, 1, alice, depAmt + depAmt2);

    //     // 5) Advance to epoch2, stake ~2000
    //     uint256 epochStart2 = vault.currentEpochStart() + vault.epochDuration() + 1;
    //     vm.warp(epochStart2);
    //     uint48 epoch2 = middleware.getCurrentEpoch();
    //     middleware.calcAndCacheStakes(epoch2, 1);

    //     // 6) Add a node now => validationID is assigned
    //     bytes32 nodeId = bytes32("testNode");
    //     bytes memory blsKey = hex"abcdef";
    //     address[] memory owners = new address[](1);
    //     owners[0] = alice;
    //     PChainOwner memory pOwner = PChainOwner({threshold: 1, addresses: owners});

    //     vm.prank(alice);
    //     middleware.addNode(nodeId, blsKey, uint64(block.timestamp + 1 days), pOwner, pOwner, 0);
    //     bytes32 valIdNow = middleware.getCurrentValidationID(nodeId);

    //     // 7) Advance to epoch3
    //     uint256 epochStart3 = vault.currentEpochStart() + vault.epochDuration() + 1;
    //     vm.warp(epochStart3);
    //     uint48 epoch3 = middleware.getCurrentEpoch();
    //     middleware.calcAndCacheStakes(epoch3, 1);

    //     // 8) Check historical operator stake
    //     uint256 stakeE1 = middleware.getOperatorStake(alice, epoch1, 1);
    //     uint256 stakeE2 = middleware.getOperatorStake(alice, epoch2, 1);
    //     uint256 stakeE3 = middleware.getOperatorStake(alice, epoch3, 1);
    //     assertEq(stakeE1, 1500 ether, "Epoch1 stake must be 1500");
    //     assertEq(stakeE2, 2000 ether, "Epoch2 stake must be 2000");
    //     assertEq(stakeE3, 2000 ether, "Epoch3 stake must be 2000");

    //     // 9) Check node's validationID at older epochs => should be zero
    //     bytes32 oldValE1 = middleware.getValidationIDAt(nodeId, uint48(epochStart1));
    //     bytes32 oldValE2 = middleware.getValidationIDAt(nodeId, uint48(epochStart2));
    //     assertEq(oldValE1, bytes32(0), "No validationID at epoch1");
    //     assertEq(oldValE2, bytes32(0), "No validationID at epoch2");
    //     // At epoch3 time => it should be the current valId
    //     bytes32 valE3 = middleware.getValidationIDAt(nodeId, uint48(epochStart3));
    //     assertEq(valE3, valIdNow, "Epoch3's val ID must match the new one");
    // }


    // /**
    //  * @dev Full scenario with multiple operators and multiple nodes. Then removal of a node.
    //  */
    // function test_MultipleOperatorsAndNodes() public {
    //     // 1) Register L1 + Vault
    //     _registerL1(validatorManagerAddress, address(middleware));
    //     vm.startPrank(validatorManagerAddress);
    //     middleware.registerVault(address(vault), 1, 10000 ether);
    //     vm.stopPrank();

    //     // 2) Register 2 operators: alice + charlie
    //     _registerOperator(alice, "alice meta");
    //     _optInOperatorL1(alice, validatorManagerAddress);
    //     _optInOperatorVault(alice);

    //     _registerOperator(charlie, "charlie meta");
    //     _optInOperatorL1(charlie, validatorManagerAddress);
    //     _optInOperatorVault(charlie);

    //     vm.startPrank(validatorManagerAddress);
    //     middleware.registerOperator(alice);
    //     middleware.registerOperator(charlie);
    //     vm.stopPrank();

    //     // 3) Both deposit
    //     _grantDepositorWhitelistRole(bob, alice);
    //     _grantDepositorWhitelistRole(bob, charlie);
    //     _grantL1LimiteRole(bob, alice);
    //     _grantL1LimiteRole(bob, charlie);

    //     // Alice
    //     (uint256 aliceAmt, uint256 aliceShares) = _deposit(alice, 4000 ether);
    //     _setL1Limit(bob, validatorManagerAddress, 1, aliceAmt);
    //     _setOperatorL1Shares(bob, validatorManagerAddress, 1, alice, aliceShares);

    //     // Bob
    //     (uint256 charlieAmt, uint256 charlieShares) = _deposit(charlie, 3000 ether);
    //     _setL1Limit(bob, validatorManagerAddress, 1, charlieAmt);
    //     _setOperatorL1Shares(bob, validatorManagerAddress, 1, charlie, charlieShares);

    //     // 4) Advance epoch
    //     uint256 nextEpoch = vault.currentEpochStart() + vault.epochDuration() + 1;
    //     vm.warp(nextEpoch);
    //     uint48 ep1 = middleware.getCurrentEpoch();
    //     middleware.calcAndCacheStakes(ep1, 1);

    //     // 5) Each operator adds multiple nodes
    //     vm.prank(alice);
    //     middleware.addNode(bytes32("aliceNode1"), hex"AA11", uint64(block.timestamp + 1 days), _makePChainOwner(alice), _makePChainOwner(alice), 0);
    //     vm.prank(alice);
    //     middleware.addNode(bytes32("aliceNode2"), hex"AA22", uint64(block.timestamp + 1 days), _makePChainOwner(alice), _makePChainOwner(alice), 0);

    //     vm.prank(charlie);
    //     middleware.addNode(bytes32("charlieNode1"), hex"BB11", uint64(block.timestamp + 1 days), _makePChainOwner(charlie), _makePChainOwner(charlie), 0);
    //     vm.prank(charlie);
    //     middleware.addNode(bytes32("charlieNode2"), hex"BB22", uint64(block.timestamp + 1 days), _makePChainOwner(charlie), _makePChainOwner(charlie), 0);
    //     vm.prank(charlie);
    //     middleware.addNode(bytes32("charlieNode3"), hex"BB33", uint64(block.timestamp + 1 days), _makePChainOwner(charlie), _makePChainOwner(charlie), 0);

    //     // 6) Next epoch => re-check total stake
    //     uint256 nextEpoch2 = vault.currentEpochStart() + vault.epochDuration() + 1;
    //     vm.warp(nextEpoch2);
    //     uint48 ep2 = middleware.getCurrentEpoch();
    //     middleware.calcAndCacheStakes(ep2, 1);

    //     // 7) Suppose Bob forcibly removes one node
    //     vm.prank(validatorManagerAddress);
    //     middleware.forceRemoveNode(charlie);

    //     // 8) Check that after forceRemoveNode, charlie's node weights in ep2 are zero
    //     // for the forcibly removed nodes
    //     // The method sets them all to zero. We'll just check one of them:
    //     bytes32 valBobNode1 = middleware.getCurrentValidationID(bytes32("charlieNode1"));
    //     uint256 nodeWeight1 = middleware.nodeWeightCache(ep2, valBobNode1);
    //     assertEq(nodeWeight1, 0, "Force removed node weight must be 0 in ep2");

    //     // 9) All done
    // }
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
        l1Registry.registerL1(_l1, _middleware, "metadataURL");
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

    function _optInOperatorVault(address user) internal {
        vm.startPrank(user);
        operatorVaultOptInService.optIn(address(vault));
        vm.stopPrank();
    }

    function _optOutOperatorVault(address user) internal {
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
    
    function _moveToNextEpochAndCalc(address operator, uint256 numberOfEpochs) internal {
        for (uint256 i = 0; i < numberOfEpochs; i++) {
            uint256 newMiddlewareEpochStart = middleware.getEpochStartTs(middleware.getCurrentEpoch()) + middleware.getEpochDuration() + 1;
            vm.warp(newMiddlewareEpochStart);
            middleware.calcAndCacheNodeWeightsForOperator(operator);
            console2.log("Current middleware epoch:", middleware.getCurrentEpoch());
            console2.log("Current vault epoch:", vault.currentEpoch());
        }
    }

}
