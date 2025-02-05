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
    address internal alice;
    address internal validatorManagerAddress;
    uint256 internal alicePrivateKey;
    address internal bob;
    uint256 internal bobPrivateKey;
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
            epochDuration: 3 hours,
            slashingWindow: 4 hours
        });

        middleware = new AvalancheL1Middleware(
            middlewareSettings, owner, primaryAsset, primaryAssetMaxStake, primaryAssetMinStake
        );

        // middleware.addAssetClass(2, primaryAssetMinStake, primaryAssetMaxStake);
        // middleware.activateSecondaryAssetClass(0);

        middleware.transferOwnership(validatorManagerAddress);

        // middleware = new AvalancheL1Middleware();
        uint64 maxWeight = 1_000_000_000_000_000_000;
        mockValidatorManager.setupSecurityModule(address(middleware), maxWeight);
    }

    function test_ConstructorValues() public view {
        assertEq(middleware.SLASHING_WINDOW(), 4 hours);
        assertEq(middleware.EPOCH_DURATION(), 3 hours);

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

        middleware.registerOperator(alice, keccak256("myPubKey"));
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

    ///////////////////////////////
    // NEW NODE FUNCTIONALITY TESTS
    ///////////////////////////////

    function test_AddNodeFailsWithNoStake() public {
        // Arrange: Register L1 and vault but do not deposit any stake.
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
        middleware.registerOperator(alice, keccak256("myPubKey"));
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
        vm.expectRevert("Not enough free stake to add node");
        middleware.addNode(nodeId, blsKey, registrationExpiry, ownerStruct, ownerStruct);
    }

    function test_AddNodeWithStakeAndTimeAdvance() public {
        // Arrange: Register L1 and vault, then deposit stake.
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
        middleware.registerOperator(alice, keccak256("myPubKey"));
        vm.stopPrank();

        // Deposit funds into the vault (the user deposits stake).
        _grantDepositorWhitelistRole(bob, alice);
        // _grantL1LimiteRole(bob, alice);
        (uint256 depositedAmount, uint256 mintedShares) = _deposit(alice, 500 ether);
        _setL1Limit(bob, validatorManagerAddress, assetClassId, depositedAmount);
        _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, alice, mintedShares);

        // Capture the current epoch and time
        uint48 currentEpoch = middleware.getCurrentEpoch();
        uint256 currentTime = block.timestamp;
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
        middleware.addNode(nodeId, blsKey, registrationExpiry, ownerStruct, ownerStruct);

        // Assert: Check that the node weight is positive and that operatorLockedStake was updated.
        bytes32 validationID = middleware.getCurrentValidationID(nodeId);
        uint256 nodeWeight = middleware.nodeWeightCache(newEpoch, validationID);
        console2.log("Node weight:", nodeWeight);
        assertGt(nodeWeight, 0, "Node weight must be positive");
        uint256 lockedStake = middleware.operatorLockedStake(alice);
        assertEq(lockedStake, nodeWeight, "Locked stake should equal node weight");
    }

    /// @notice Test that an operator can add a node.
    function test_AddNode() public {
        // Arrange: Register L1 and vault, then register the operator on the registry.
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
        middleware.registerOperator(alice, keccak256("myPubKey"));
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

        // Act: Add a node.
        bytes32 nodeId = bytes32("node1");
        bytes memory blsKey = hex"1234";
        uint64 registrationExpiry = uint64(block.timestamp + 1 days);
        address[] memory ownerArr = new address[](1);
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct = PChainOwner({threshold: 1, addresses: ownerArr});

        vm.prank(alice);
        middleware.addNode(nodeId, blsKey, registrationExpiry, ownerStruct, ownerStruct);

        // Assert:
        bytes32 validationID = middleware.getCurrentValidationID(nodeId);
        uint256 nodeWeight = middleware.nodeWeightCache(epoch, validationID);
        console2.log("Node weight:", nodeWeight);
        assertGt(nodeWeight, 0, "Node weight must be positive");
        uint256 lockedStake = middleware.operatorLockedStake(alice);
        assertEq(lockedStake, nodeWeight, "Locked stake should equal node weight");
    }

    function test_CompleteNodeWeightUpdate() public {
        uint96 assetClassId = 1;
        // Arrange: Register L1 and the vault first.
        _registerL1(validatorManagerAddress, address(middleware));
        vm.startPrank(validatorManagerAddress);
        middleware.registerVault(address(vault), 1, 2000 ether);
        vm.stopPrank();

        _registerOperator(alice, "alice metadata");
        _optInOperatorL1(alice, validatorManagerAddress);
        _optInOperatorVault(alice);
        vm.startPrank(validatorManagerAddress);
        middleware.registerOperator(alice, keccak256("myPubKey"));
        vm.stopPrank();

        _grantDepositorWhitelistRole(bob, alice);
        (uint256 depositedAmount, uint256 mintedShares) = _deposit(alice, 1_000 ether);
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

        vm.prank(alice);
        middleware.addNode(nodeId, blsKey, registrationExpiry, ownerStruct, ownerStruct);
        bytes32 validationID = middleware.getCurrentValidationID(nodeId);
        uint256 initialNodeWeight = middleware.nodeWeightCache(epoch, validationID);
        assertGt(initialNodeWeight, 0);

        // Simulate activation of the validator in the mock before updating weight
        mockValidatorManager.simulateActivateValidator(validationID);

        // Reduce weight by 100
        uint64 newWeight = uint64(initialNodeWeight - 100);

        vm.prank(alice);
        middleware.requestNodeWeightUpdate(nodeId, newWeight);

        mockValidatorManager.simulateWeightUpdate(validationID, newWeight);

        vm.prank(alice);
        middleware.confirmWeightUpdate(nodeId, 0);

        // Weight updated
        uint256 updatedNodeWeight = middleware.nodeWeightCache(epoch, validationID);
        assertEq(updatedNodeWeight, newWeight, "Node weight should be updated to the new value");
    }

    function test_ForceRemoveNode() public {
        uint96 assetClassId = 1;
        // Arrange: Register L1 and vault first.
        _registerL1(validatorManagerAddress, address(middleware));
        vm.startPrank(validatorManagerAddress);
        middleware.registerVault(address(vault), 1, 2000 ether);
        vm.stopPrank();

        _registerOperator(alice, "alice metadata");
        _optInOperatorL1(alice, validatorManagerAddress);
        _optInOperatorVault(alice);

        vm.startPrank(validatorManagerAddress);
        middleware.registerOperator(alice, keccak256("myPubKey"));
        vm.stopPrank();

        _grantDepositorWhitelistRole(bob, alice);
        (uint256 depositedAmount, uint256 mintedShares) = _deposit(alice, 500 ether);
        _setL1Limit(bob, validatorManagerAddress, 1, depositedAmount);
        _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, alice, mintedShares);

        uint48 epoch = middleware.getCurrentEpoch();
        bytes32 nodeId = bytes32("node3");
        bytes memory blsKey = hex"9abc";
        uint64 registrationExpiry = uint64(block.timestamp + 1 days);
        address[] memory ownerArr = new address[](1);
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct = PChainOwner({threshold: 1, addresses: ownerArr});

        vm.prank(alice);
        middleware.addNode(nodeId, blsKey, registrationExpiry, ownerStruct, ownerStruct);
        bytes32 validationID = middleware.getCurrentValidationID(nodeId);
        uint256 initialNodeWeight = middleware.nodeWeightCache(epoch, validationID);
        assertGt(initialNodeWeight, 0);

        // Act: Force-remove the node.
        vm.prank(validatorManagerAddress);
        middleware.forceRemoveNode(alice);

        // Assert: Node weight is now zero.
        uint256 finalNodeWeight = middleware.nodeWeightCache(epoch, validationID);
        assertEq(finalNodeWeight, 0, "Node weight should be zero after force removal");
    }


    ///////////////////////////////
    // INTERNAL HELPERS
    ///////////////////////////////

    function _registerOperator(address user, string memory metadataURL) internal {
        vm.startPrank(user);
        operatorRegistry.registerOperator(metadataURL);
        vm.stopPrank();
    }

    function _registerL1(address l1, address _middleware) internal {
        vm.prank(l1);
        l1Registry.registerL1(l1, _middleware, "metadataURL");
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
}
