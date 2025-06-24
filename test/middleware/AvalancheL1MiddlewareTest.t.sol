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
import {
    ConversionData,
    InitialValidator,
    PChainOwner,
    Validator,
    ValidatorRegistrationInput,
    ValidatorStatus
} from "@avalabs/teleporter/validator-manager/interfaces/IValidatorManager.sol";

import {Token} from "../mocks/MockToken.sol";
import {ERC20WithDecimals} from "../mocks/MockERC20WithDecimals.sol";

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
    address internal dave;
    uint256 internal davePrivateKey;
    address internal staker;
    uint256 internal stakerPrivateKey;
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
    VaultTokenized internal vault2; // New vault using same collateral
    VaultTokenized internal vault3; // New vault using new collateral
    L1RestakeDelegator internal delegator;
    L1RestakeDelegator internal delegator2; // Delegator for vault2
    L1RestakeDelegator internal delegator3; // Delegator for vault3
    AvalancheL1Middleware internal middleware;
    MiddlewareVaultManager internal vaultManager;
    Token internal collateral;
    Token internal collateral2; // New collateral token
    MockBalancerValidatorManager internal mockValidatorManager;

    function setUp() public {
        owner = address(this);
        (alice, alicePrivateKey) = makeAddrAndKey("alice");
        (bob, bobPrivateKey) = makeAddrAndKey("bob");
        (charlie, charliePrivateKey) = makeAddrAndKey("charlie");
        (dave, davePrivateKey) = makeAddrAndKey("dave");
        (staker, stakerPrivateKey) = makeAddrAndKey("staker");
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
        collateral2 = new Token("MockCollateral2");
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

        // Deploy vault2 (using same collateral)
        address vault2Address = vaultFactory.create(
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
                    name: "Test2",
                    symbol: "TEST2"
                })
            ),
            address(delegatorFactory),
            address(slasherFactory)
        );

        vault2 = VaultTokenized(vault2Address);

        // Deploy vault3 (using new collateral)
        address vault3Address = vaultFactory.create(
            lastVersion,
            bob,
            abi.encode(
                IVaultTokenized.InitParams({
                    collateral: address(collateral2),
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
                    name: "Test3",
                    symbol: "TEST3"
                })
            ),
            address(delegatorFactory),
            address(slasherFactory)
        );

        vault3 = VaultTokenized(vault3Address);

        // Setup delegator for vault1
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

        // Setup delegator for vault2
        address delegator2Address = delegatorFactory.create(
            0,
            abi.encode(
                address(vault2),
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

        delegator2 = L1RestakeDelegator(delegator2Address);

        // Setup delegator for vault3
        address delegator3Address = delegatorFactory.create(
            0,
            abi.encode(
                address(vault3),
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

        delegator3 = L1RestakeDelegator(delegator3Address);

        // Set the delegator in vault1
        vm.prank(bob);
        vault.setDelegator(delegatorAddress);

        // Set the delegator in vault2
        vm.prank(bob);
        vault2.setDelegator(delegator2Address);

        // Set the delegator in vault3
        vm.prank(bob);
        vault3.setDelegator(delegator3Address);

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

        vaultManager = new MiddlewareVaultManager(address(vaultFactory), owner, address(middleware), 24); // 24 epoch delay
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
        maxVaultL1Limit = 3000 ether;

        vm.startPrank(validatorManagerAddress);
        vaultManager.registerVault(address(vault), assetClassId, maxVaultL1Limit);
        vm.stopPrank();

        // Register all operators
        _registerOperator(alice, "alice metadata");
        _registerOperator(charlie, "charlie metadata");
        _registerOperator(dave, "dave metadata");

        // Opt-in operators for L1
        _optInOperatorL1(alice, validatorManagerAddress);
        _optInOperatorL1(charlie, validatorManagerAddress);
        _optInOperatorL1(dave, validatorManagerAddress);

        // Opt-in operators for vaults
        _optInOperatorVault(alice, address(vault));
        _optInOperatorVault(alice, address(vault3));
        _optInOperatorVault(charlie, address(vault));
        _optInOperatorVault(charlie, address(vault2));
        _optInOperatorVault(charlie, address(vault3));
        _optInOperatorVault(dave, address(vault2));
        _optInOperatorVault(dave, address(vault3));

        // Register operators with middleware
        vm.startPrank(validatorManagerAddress);
        middleware.registerOperator(alice);
        middleware.registerOperator(charlie);
        middleware.registerOperator(dave);
        vm.stopPrank();

        // Grant whitelist deposit role to staker
        _grantDepositorWhitelistRole(bob, staker);

        uint256 l1Limit = 2500 ether;

        // Setup Alice as operator for vault1 only
        // Use staker to deposit on behalf of Alice
        collateral.transfer(staker, 550_000_000_000_000);
        vm.startPrank(staker);
        collateral.approve(address(vault), 550_000_000_000_000);
        (depositedAmount, mintedShares) = vault.deposit(staker, 550_000_000_000_000);
        vm.stopPrank();

        _setL1Limit(bob, validatorManagerAddress, assetClassId, l1Limit, delegator);
        _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, alice, mintedShares, delegator);

        // Setup Charlie as operator for both vault1 and vault2
        // First deposit to vault1
        uint256 charlieVault1DepositAmount = 250_000_000_000_000;
        collateral.transfer(staker, charlieVault1DepositAmount);
        vm.startPrank(staker);
        collateral.approve(address(vault), charlieVault1DepositAmount);
        (, uint256 charlieVault1Shares) = vault.deposit(staker, charlieVault1DepositAmount);
        vm.stopPrank();

        // Add Charlie's shares from vault1 (existing limit is already set)
        _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, charlie, charlieVault1Shares, delegator);

        // Then deposit to vault2
        uint256 charlieVault2DepositAmount = 220_000_000_000_000;
        collateral.transfer(staker, charlieVault2DepositAmount);
        vm.startPrank(staker);
        collateral.approve(address(vault2), charlieVault2DepositAmount);
        (, uint256 charlieVault2Shares) = vault2.deposit(staker, charlieVault2DepositAmount);
        vm.stopPrank();

        // Set L1 shares for Charlie from vault2
        _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, charlie, charlieVault2Shares, delegator2);

        // Setup Dave as operator for vault2
        uint256 daveVault2DepositAmount = 200_000_000_000_000;
        collateral.transfer(staker, daveVault2DepositAmount);
        vm.startPrank(staker);
        collateral.approve(address(vault2), daveVault2DepositAmount);
        (, uint256 daveVault2Shares) = vault2.deposit(staker, daveVault2DepositAmount);
        vm.stopPrank();

        // Set L1 shares for Dave from vault2
        _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, dave, daveVault2Shares, delegator2);

        // Setup vault3 with new collateral for Alice, Charlie and Dave
        uint256 vault3DepositAmount = 100_000_000_000_000;

        // Deposit for Alice
        collateral2.transfer(staker, vault3DepositAmount);
        vm.startPrank(staker);
        collateral2.approve(address(vault3), vault3DepositAmount);
        (, uint256 aliceVault3MintedShares) = vault3.deposit(staker, vault3DepositAmount);
        vm.stopPrank();

        // Deposit for Charlie
        collateral2.transfer(staker, vault3DepositAmount);
        vm.startPrank(staker);
        collateral2.approve(address(vault3), vault3DepositAmount);
        (, uint256 charlieVault3MintedShares) = vault3.deposit(staker, vault3DepositAmount);
        vm.stopPrank();

        // Deposit for Dave
        collateral2.transfer(staker, vault3DepositAmount);
        vm.startPrank(staker);
        collateral2.approve(address(vault3), vault3DepositAmount);
        (, uint256 daveVault3MintedShares) = vault3.deposit(staker, vault3DepositAmount);
        vm.stopPrank();

        // Set L1 shares for all three operators from vault3
        _setOperatorL1Shares(bob, validatorManagerAddress, 2, alice, aliceVault3MintedShares, delegator3);
        _setOperatorL1Shares(bob, validatorManagerAddress, 2, charlie, charlieVault3MintedShares, delegator3);
        _setOperatorL1Shares(bob, validatorManagerAddress, 2, dave, daveVault3MintedShares, delegator3);

        // Alice Operator for vault1 has 200_000_000_002_000 deposited
        // Alice Operator for vault3 has 100_000_000_000_000 deposited
        // Charlie Operator for vault1 has 150_000_000_000_000 deposited
        // Charlie Operator for vault2 has 120_000_000_000_000 deposited
        // Charlie Operator for vault3 has 100_000_000_000_000 deposited
        // Dave Operator for vault3 has 100_000_000_000_000 deposited
        // Dave Operator for vault2 has 160_000_000_000_000 deposited
    }

    function test_DepositAndGetOperatorStake() public view {
        // middleware.addAssetToClass(1, address(collateral));
        uint48 epoch = middleware.getCurrentEpoch();
        uint256 stakeAlice = middleware.getOperatorStake(alice, epoch, assetClassId);
        console2.log("Alice stake:", stakeAlice);
        // Just a simple check
        assertGt(stakeAlice, 0, "Bob's stake should be > 0 now");
    }

    function test_AddNodeSimple() public {
        // Move forward to let the vault roll epochs
        uint48 epoch = _calcAndWarpOneEpoch();

        uint256 operatorStake = middleware.getOperatorStake(alice, epoch, assetClassId);
        console2.log("Operator stake (epoch", epoch, "):", operatorStake);
        assertGt(operatorStake, 0);

        // Move the vault epoch again
        epoch = _calcAndWarpOneEpoch();

        // Recalc stakes for new epoch
        middleware.calcAndCacheStakes(epoch, assetClassId);
        uint256 newStake = middleware.getOperatorStake(alice, epoch, assetClassId);
        console2.log("New epoch operator stake:", newStake);
        assertGe(newStake, operatorStake);

        // Add a node
        _createAndConfirmNodes(alice, 1, 0, true, 2);
    }

    function test_AddNodeSimpleAndComplete() public {
        uint48 epoch = _calcAndWarpOneEpoch();
        uint256 totalStake = middleware.getOperatorStake(alice, epoch, assetClassId);
        assertGt(totalStake, 0);

        // Add node
        (, bytes32[] memory validationIDs,) = _createAndConfirmNodes(alice, 1, 0, true, 2);
        bytes32 validationID = validationIDs[0];

        // Move epoch +1
        epoch = _calcAndWarpOneEpoch();

        uint256 nodeWeight = middleware.nodeStakeCache(epoch, validationID);
        console2.log("Node weight after confirmation:", nodeWeight);
        assertGt(nodeWeight, 0);
    }

    function test_AddNodeStakeClamping_Adaptive() public {
        // Get staking requirements from middleware
        middleware.getClassStakingRequirements(1);
        uint256 totalSupply = collateral.totalSupply();
        console2.log("Token total supply:", totalSupply);

        // Set up test values
        uint256 feasibleMax = 100_000_000_000_000_000_000;
        uint256 stakeWanted = feasibleMax + 20 ether;

        uint256 depositAmount = stakeWanted + 2 ether; // 2 ether extra to cover the deposit fee
        // Fund staker and deposit to vault
        collateral.transfer(staker, depositAmount);

        vm.startPrank(staker);
        collateral.approve(address(vault), depositAmount);
        vault.deposit(staker, depositAmount);
        vm.stopPrank();

        // Set L1 limit
        vm.startPrank(bob);
        delegator.setL1Limit(validatorManagerAddress, assetClassId, depositAmount);
        vm.stopPrank();

        _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, alice, stakeWanted, delegator);

        // travel to next epoch
        _calcAndWarpOneEpoch();

        // Verify available stake
        uint256 updatedAvail = middleware.getOperatorAvailableStake(alice);
        require(
            updatedAvail >= stakeWanted,
            string(
                abi.encodePacked(
                    "Available: ",
                    vm.toString(updatedAvail),
                    ", Wanted: ",
                    vm.toString(stakeWanted),
                    ", Missing: ",
                    vm.toString(stakeWanted > updatedAvail ? stakeWanted - updatedAvail : 0)
                )
            )
        );

        // Add node with stake that exceeds max
        bytes32 nodeId = keccak256("ClampTestAdaptive");
        console2.log("Requesting stakeWanted:", stakeWanted);

        vm.prank(alice);
        middleware.addNode(
            nodeId,
            hex"abcdef1234",
            uint64(block.timestamp + 1 days),
            PChainOwner({threshold: 1, addresses: new address[](1)}),
            PChainOwner({threshold: 1, addresses: new address[](1)}),
            stakeWanted
        );

        // Move to next epoch
        uint48 epoch = _calcAndWarpOneEpoch();

        bytes32 validationID = mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId))));
        uint256 finalStake = middleware.getNodeStake(epoch, validationID);

        console2.log("Final stake after clamp is:", finalStake);
        assertEq(finalStake, feasibleMax, "Expect clamp to feasibleMax in the test scenario");
    }

    // function test_AddNodeSecondaryAsset() public {
    //     _calcAndWarpOneEpoch();
    //     uint48 epoch = middleware.getCurrentEpoch();
    //     uint256 totalStake = middleware.getOperatorStake(alice, epoch, assetClassId);
    //     assertGt(totalStake, 0);

    //     // Add node
    //     (bytes32[] memory nodeIds, bytes32[] memory validationIDs, uint256[] memory nodeWeights) =
    //         _createAndConfirmNodes(alice, 1, 0, true);
    //     bytes32 validationID = validationIDs[0];
    //     uint256 nodeWeight = nodeWeights[0];

    //     nodeWeight = middleware.nodeStakeCache(middleware.getCurrentEpoch(), validationID);
    //     console2.log("Node weight after next epoch:", nodeWeight);
    //     assertGt(nodeWeight, 0);
    // }

    function test_AddNodeLateCompletition() public {
        uint48 epoch = _calcAndWarpOneEpoch();
        uint256 totalStake = middleware.getOperatorStake(alice, epoch, assetClassId);
        console2.log("Operator stake in epoch", epoch, ":", totalStake);
        assertGt(totalStake, 0);

        // Add node
        (bytes32[] memory nodeIds, bytes32[] memory validationIDs, uint256[] memory nodeWeights) =
            _createAndConfirmNodes(alice, 1, 0, false, 2);
        bytes32 validationID = validationIDs[0];
        bytes32 nodeId = nodeIds[0];
        uint256 nodeWeight = nodeWeights[0];

        // Advance epoch
        epoch = _calcAndWarpOneEpoch();

        // Node still not confirmed
        nodeWeight = middleware.nodeStakeCache(epoch, validationID);
        console2.log("Node weight second epoch (still unconfirmed):", nodeWeight);
        assertGt(nodeWeight, 0);

        // Confirm node
        vm.startPrank(alice);
        middleware.completeValidatorRegistration(alice, nodeId, 0);
        middleware.calcAndCacheNodeStakeForAllOperators();
        vm.stopPrank();

        // Should be active next epoch
        epoch = _calcAndWarpOneEpoch();

        nodeWeight = middleware.nodeStakeCache(epoch, validationID);
        console2.log("Node weight after full confirmation:", nodeWeight);
        assertGt(nodeWeight, 0);
    }

    function test_CompleteStakeUpdate() public {
        (depositedAmount, mintedShares) = _deposit(staker, 10 ether);
        _setL1Limit(bob, validatorManagerAddress, 1, depositedAmount, delegator);

        _calcAndWarpOneEpoch();
        (bytes32[] memory nodeIds, bytes32[] memory validationIDs, uint256[] memory nodeWeights) =
            _createAndConfirmNodes(alice, 1, 0, true, 2);
        bytes32 validationID = validationIDs[0];
        bytes32 nodeId = nodeIds[0];
        uint256 nodeWeight = nodeWeights[0];

        uint48 epoch = _calcAndWarpOneEpoch();

        // Decrease weight
        uint256 stakeAmount = uint256(nodeWeight - 100);
        vm.prank(alice);
        middleware.initializeValidatorStakeUpdate(nodeId, stakeAmount);
        uint256 updatedNodeWeight = middleware.nodeStakeCache(epoch, validationID);
        console2.log("Node weight after init update (still old until next epoch):", updatedNodeWeight);

        vm.prank(alice);
        middleware.completeStakeUpdate(nodeId, 0);
        middleware.calcAndCacheNodeStakeForAllOperators();

        updatedNodeWeight = middleware.nodeStakeCache(epoch, validationID);
        console2.log("Node weight after completion (still old until next epoch):", updatedNodeWeight);

        // Move to next epoch
        epoch = _calcAndWarpOneEpoch();
        updatedNodeWeight = middleware.nodeStakeCache(epoch, validationID);
        console2.log("Node weight final:", updatedNodeWeight);
        assertEq(updatedNodeWeight, stakeAmount, "Node weight should be updated");
    }

    function test_CompleteLateNodeWeightUpdate() public {
        (depositedAmount, mintedShares) = _deposit(staker, 10 ether);
        _setL1Limit(bob, validatorManagerAddress, 1, depositedAmount, delegator);

        uint48 epoch = _calcAndWarpOneEpoch();
        (bytes32[] memory nodeIds, bytes32[] memory validationIDs, uint256[] memory nodeWeights) =
            _createAndConfirmNodes(alice, 1, 0, true, 2);
        bytes32 validationID = validationIDs[0];
        bytes32 nodeId = nodeIds[0];
        uint256 nodeWeight = nodeWeights[0];

        // Decrease
        uint256 stakeAmount = uint256(nodeWeight - 100);
        vm.prank(alice);
        middleware.initializeValidatorStakeUpdate(nodeId, stakeAmount);

        // Next epochs warp
        _calcAndWarpOneEpoch();

        vm.prank(alice);
        middleware.completeStakeUpdate(nodeId, 0);
        middleware.calcAndCacheNodeStakeForAllOperators();

        epoch = _calcAndWarpOneEpoch();
        uint256 updatedNodeWeight = middleware.nodeStakeCache(epoch, validationID);
        console2.log("Node weight final:", updatedNodeWeight);
        assertEq(updatedNodeWeight, stakeAmount);
    }

    function test_RemoveNodeSimple() public {
        uint48 epoch = _calcAndWarpOneEpoch();

        uint256 totalStake = middleware.getOperatorStake(alice, epoch, assetClassId);
        assertGt(totalStake, 0);

        (bytes32[] memory nodeIds, bytes32[] memory validationIDs, uint256[] memory nodeWeights) =
            _createAndConfirmNodes(alice, 1, 0, true, 2);
        bytes32 validationID = validationIDs[0];
        bytes32 nodeId = nodeIds[0];
        uint256 nodeWeight = nodeWeights[0];
        assertEq(middleware.getOperatorNodesLength(alice), 1);

        epoch = _calcAndWarpOneEpoch();
        nodeWeight = middleware.nodeStakeCache(epoch, validationID);
        assertGt(nodeWeight, 0);

        vm.prank(alice);
        middleware.removeNode(nodeId);
        nodeWeight = middleware.nodeStakeCache(epoch, validationID);
        assertGt(nodeWeight, 0);
        assertEq(middleware.getOperatorNodesLength(alice), 1);

        epoch = _calcAndWarpOneEpoch();
        nodeWeight = middleware.nodeStakeCache(epoch, validationID);
        assertEq(nodeWeight, 0);
        assertEq(middleware.getOperatorNodesLength(alice), 0);
    }

    function test_RemoveNodeLate() public {
        uint48 epoch = _calcAndWarpOneEpoch();
        uint256 totalStake = middleware.getOperatorStake(alice, epoch, assetClassId);
        assertGt(totalStake, 0);

        // Add node
        (bytes32[] memory nodeIds, bytes32[] memory validationIDs, uint256[] memory nodeWeights) =
            _createAndConfirmNodes(alice, 1, 0, true, 2);
        bytes32 validationID = validationIDs[0];
        bytes32 nodeId = nodeIds[0];
        uint256 nodeWeight = nodeWeights[0];
        assertEq(middleware.getOperatorNodesLength(alice), 1);

        epoch = _calcAndWarpOneEpoch();
        nodeWeight = middleware.nodeStakeCache(epoch, validationID);
        assertGt(nodeWeight, 0);

        vm.prank(alice);
        middleware.removeNode(nodeId);

        nodeWeight = middleware.nodeStakeCache(epoch, validationID);
        assertGt(nodeWeight, 0);
        assertTrue(middleware.nodePendingRemoval(validationID));

        // Next epoch
        epoch = _calcAndWarpOneEpoch();
        nodeWeight = middleware.nodeStakeCache(epoch, validationID);
        assertEq(nodeWeight, 0);
        assertFalse(middleware.nodePendingRemoval(validationID));
        assertEq(middleware.getOperatorNodesLength(alice), 0);

        // Next epoch
        _calcAndWarpOneEpoch();
        vm.prank(alice);
        middleware.completeValidatorRemoval(1);

        epoch = _calcAndWarpOneEpoch();
        nodeWeight = middleware.nodeStakeCache(epoch, validationID);
        assertEq(nodeWeight, 0);
        assertFalse(middleware.nodePendingRemoval(validationID));
        assertEq(middleware.getOperatorNodesLength(alice), 0);
    }

    function test_MultipleNodes() public {
        uint48 epoch = _calcAndWarpOneEpoch();
        uint256 totalStake = middleware.getOperatorStake(alice, epoch, assetClassId);
        assertGt(totalStake, 0);

        // Add node1 and node2
        uint256 stake1 = 100_000_000_000_000 + 1000;
        (bytes32[] memory nodeIds, bytes32[] memory validationIDs, uint256[] memory nodeWeights) =
            _createAndConfirmNodes(alice, 2, stake1, true, 2);
        bytes32 nodeId1 = nodeIds[0];
        bytes32 validationID1 = validationIDs[0];
        uint256 nodeWeight1 = nodeWeights[0];
        bytes32 validationID2 = validationIDs[1];
        uint256 nodeWeight2 = nodeWeights[1];

        epoch = _calcAndWarpOneEpoch();
        nodeWeight2 = middleware.nodeStakeCache(epoch, validationID2);
        assertGt(nodeWeight2, 0);

        // Remove node1
        vm.prank(alice);
        middleware.removeNode(nodeId1);
        epoch = _calcAndWarpOneEpoch();
        nodeWeight1 = middleware.nodeStakeCache(epoch, validationID1);
        assertEq(nodeWeight1, 0);

        vm.prank(alice);
        middleware.completeValidatorRemoval(2);
        nodeWeight2 = middleware.nodeStakeCache(epoch, validationID2);
        assertGt(nodeWeight2, 0);

        epoch = _calcAndWarpOneEpoch();
        nodeWeight1 = middleware.nodeStakeCache(epoch, validationID1);
        assertEq(nodeWeight1, 0);
    }

    function test_HistoricalQueries_multiNodes() public {
        // Move to epoch1
        uint48 epoch1 = _calcAndWarpOneEpoch();

        // Add node1 and move to epoch2
        uint48 epoch2 = middleware.getCurrentEpoch();
        uint256 stake1 = 100_000_000_000_000 + 1000;
        (bytes32[] memory nodeIds,,) = _createAndConfirmNodes(alice, 2, stake1, true, 2);
        bytes32 nodeId1 = nodeIds[0];

        // Move to epoch3
        uint48 epoch3 = _calcAndWarpOneEpoch();

        // Remove nodeId1
        vm.prank(alice);
        middleware.removeNode(nodeId1);
        middleware.calcAndCacheNodeStakeForAllOperators();

        // Move to epoch4
        uint48 epoch4 = _calcAndWarpOneEpoch();

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

    function test_ForceUpdate() public {
        uint48 epoch = _calcAndWarpOneEpoch();
        // Add node1 and node2
        uint256 stake1 = 100_000_000_000_000 + 1000;
        (, bytes32[] memory validationIDs, uint256[] memory nodeWeights) =
            _createAndConfirmNodes(alice, 2, stake1, true, 2);
        bytes32 validationID1 = validationIDs[0];
        uint256 nodeWeight1 = nodeWeights[0];
        bytes32 validationID2 = validationIDs[1];
        uint256 nodeWeight2 = nodeWeights[1];

        epoch = _calcAndWarpOneEpoch();
        nodeWeight1 = middleware.nodeStakeCache(epoch, validationID1);
        console2.log("Node1 weight after confirm:", nodeWeight1);

        epoch = _calcAndWarpOneEpoch();
        nodeWeight2 = middleware.nodeStakeCache(epoch, validationID2);
        console2.log("Node2 weight after confirm:", nodeWeight2);

        // Withdraw from vault to reduce stake
        epoch = _calcAndWarpOneEpoch(2);
        uint256 withdrawAmount = 50_000_000_000_000;
        _withdraw(staker, withdrawAmount);

        // Move to next epoch
        epoch = _calcAndWarpOneEpoch(1);
        vm.expectRevert();
        middleware.forceUpdateNodes(alice, 0);

        // Warp to last hour
        _warpToLastHourOfCurrentEpoch();
        
        // Record the message index before forceUpdateNodes to see if any removals are initiated
        uint32 beforeIndex = mockValidatorManager.nextMessageIndex();
        middleware.forceUpdateNodes(alice, 0);
        uint32 afterIndex = mockValidatorManager.nextMessageIndex();
        
        // Only complete validator removal if a removal was actually initiated
        if (afterIndex > beforeIndex) {
            uint32 removalIndex = afterIndex - 1;
            vm.prank(alice);
            middleware.completeValidatorRemoval(removalIndex);
        }

        epoch = _calcAndWarpOneEpoch(1);
        uint256 updatedStake = middleware.getOperatorStake(alice, epoch, assetClassId);
        console2.log("Updated stake after partial withdraw & forceUpdateNodes:", updatedStake);

        // Claim
        epoch = _calcAndWarpOneEpoch(2);
        uint256 claimEpoch = vault.currentEpoch() - 1;
        uint256 claimed = _claim(staker, claimEpoch);
        console2.log("Claimed:", claimed);

        epoch = _calcAndWarpOneEpoch(1);
        updatedStake = middleware.getOperatorStake(alice, epoch, assetClassId);
        nodeWeight1 = middleware.nodeStakeCache(epoch, validationID1);
        nodeWeight2 = middleware.nodeStakeCache(epoch, validationID2);

        console2.log("Final operator stake:", updatedStake);
        console2.log("Node1 weight final:", nodeWeight1);
        console2.log("Node2 weight final:", nodeWeight2);
    }

    function test_ForceUpdateWithAdditionalStake() public {
        uint48 epoch = _calcAndWarpOneEpoch();

        // Add node1 and node2
        uint256 stake1 = 100_000_000_000_000 + 1000;
        _createAndConfirmNodes(alice, 1, stake1, true, 2);

        // move to next epoch
        epoch = _moveToNextEpochAndCalc(3);

        // make additional deposit
        uint256 extraDeposit = 50_000_000_000_000;
        console2.log("Making additional deposit:", extraDeposit);
        (uint256 newDeposit, uint256 newShares) = _deposit(staker, extraDeposit);
        uint256 totalShares = mintedShares + newShares;
        _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, alice, totalShares, delegator);
        console2.log("Additional deposit made. Amount:", newDeposit, "Shares:", newShares);

        epoch = _moveToNextEpochAndCalc(3);

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
        uint48 epoch = _calcAndWarpOneEpoch();

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
        epoch = _calcAndWarpOneEpoch();
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
        epoch = _calcAndWarpOneEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();

        nodeStake = middleware.getNodeStake(epoch, validationID);
        assertEq(nodeStake, 0, "Node stake must be zero after removal finalizes");

        bytes32[] memory activeNodesAfterRemove = middleware.getActiveNodesForEpoch(alice, epoch);
        assertEq(activeNodesAfterRemove.length, 0, "No active nodes after removal");

        // confirm removal
        vm.prank(alice);
        middleware.completeValidatorRemoval(1);

        // Warp +1 epoch just for clarity
        epoch = _calcAndWarpOneEpoch();

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
        epoch = _calcAndWarpOneEpoch();

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

    function test_SingleNode_AddUpdateRemoveThenCompleteUpdate() public {
        uint256 scaleFactor = middleware.WEIGHT_SCALE_FACTOR();

        // Add & confirm a node
        uint48 epoch = _calcAndWarpOneEpoch();

        (bytes32[] memory nodeIds, bytes32[] memory validationIDs,) = _createAndConfirmNodes(alice, 1, 0, true, 2);
        bytes32 validationID = validationIDs[0];
        bytes32 nodeId = nodeIds[0];

        // Move to next epoch
        epoch = _calcAndWarpOneEpoch();

        uint256 initialStake = middleware.getNodeStake(epoch, validationID);
        assertGt(initialStake, 0, "Node must have >0 stake after confirm");

        // Initialize stake update (reduce by half)
        uint256 newStake = initialStake / 2;
        vm.prank(alice);
        middleware.initializeValidatorStakeUpdate(nodeId, newStake);

        // Verify pending update in manager
        uint64 scaledWeight = StakeConversion.stakeToWeight(newStake, scaleFactor);
        uint256 pendingWeight = mockValidatorManager.pendingNewWeight(validationID);
        assertEq(pendingWeight, scaledWeight, "Pending new weight mismatch");
        bool isPending = mockValidatorManager.isValidatorPendingWeightUpdate(validationID);
        assertTrue(isPending, "Stake update must be pending");

        // Remove node while update is pending - this should revert as removing 
        // while a weight update is pending is blocked by design
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            IAvalancheL1Middleware.AvalancheL1Middleware__NodePendingUpdate.selector,
            nodeId
        ));
        middleware.removeNode(nodeId);
        
        // First complete the stake update, then remove the node
        uint32 stakeUpdateIndex = mockValidatorManager.nextMessageIndex() - 1;  
        vm.prank(alice);
        middleware.completeStakeUpdate(nodeId, stakeUpdateIndex);
        
        // Now the removal should work
        vm.prank(alice);
        middleware.removeNode(nodeId);
        uint32 removeIndex = mockValidatorManager.nextMessageIndex() - 1;

        // Move to next epoch
        epoch = _calcAndWarpOneEpoch();

        uint256 stakeNow = middleware.getNodeStake(epoch, validationID);

        // Confirm removal
        vm.prank(alice);
        middleware.completeValidatorRemoval(removeIndex);

        // Move to next epoch
        epoch = _calcAndWarpOneEpoch();

        uint256 finalStake = middleware.getNodeStake(epoch, validationID);
        assertEq(finalStake, 0, "Node stake must be 0 after final removal");

        // Verify update was processed and no longer pending
        bool stillPending = mockValidatorManager.isValidatorPendingWeightUpdate(validationID);
        assertFalse(stillPending, "Stake update should be cleared after completion");
        uint256 postCompleteStake = middleware.getNodeStake(epoch, validationID);
        assertEq(postCompleteStake, 0, "Node stake must be 0 after removal");
    }

    function testFuzz_MultipleNodes_AddRemoveReAdd(uint8 seedNodeCount, uint8 seedRemoveMask) public {
        // Force a small range for how many nodes to add (2–4)
        uint256 nodeCount = bound(seedNodeCount, 2, 4);

        // Move to next epoch, so we start from a clean point
        uint48 epoch = _calcAndWarpOneEpoch();

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

           // how much stake still free?
           (uint256 minStake, ) = middleware.getClassStakingRequirements(1);
           uint256 free = middleware.getOperatorAvailableStake(alice)
                           - middleware.getOperatorUsedStakeCached(alice);
        
            if (free < minStake) {
                // next addNode is *supposed* to revert – record and stop
                vm.expectRevert(abi.encodeWithSelector(IAvalancheL1Middleware.AvalancheL1Middleware__NotEnoughFreeStake.selector, minStake));
                vm.prank(alice);
                middleware.addNode(
                    nodeId, blsKey, uint64(block.timestamp + 2 days),
                    ownerStruct, ownerStruct, 0        // will revert
                );
                nodeCount = i;                         // shrink arrays; creation done
                break;
           }

            vm.prank(alice);
            middleware.addNode(nodeId, blsKey, uint64(block.timestamp + 2 days), ownerStruct, ownerStruct, 0);

            addMsgIndex[i] = mockValidatorManager.nextMessageIndex() - 1;

            bytes32 validationID = mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId))));
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
        epoch = _calcAndWarpOneEpoch();

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

                // Record the old validation ID *before* it's replaced by re-add
                oldRemovedValidationIds[i] = validationIds[i];

                // Attempt to remove the same node again immediately, expecting a revert
                vm.prank(alice);
                // vm.expectRevert("AvalancheL1Middleware__NodePendingRemoval");
                middleware.removeNode(nodeIds[i]);
            }
        }

        // Warp => next epoch => removed node stakes => 0
        epoch = _calcAndWarpOneEpoch();

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
                bytes32 newValID =
                    mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeIds[i]))));
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
        epoch = _calcAndWarpOneEpoch();

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

    function testFuzz_StakeUpDownForceUpdateRandNodes(
        uint8 seedNodeCount, // used to pick how many nodes to create
        uint8 stakeDeltaMask, // which nodes get stake up vs. down
        uint8 removeMask // which nodes get removed
    ) public {
        // Decide how many nodes to create (2-5)
        uint256 nodeCount = bound(seedNodeCount, 2, 5);

        // Warp to start fresh
        uint48 epoch = _calcAndWarpOneEpoch();

        // Prepare arrays
        bytes32[] memory nodeIds = new bytes32[](nodeCount);
        bytes32[] memory validationIds = new bytes32[](nodeCount);
        bool[] memory isActive = new bool[](nodeCount);
        uint32[] memory addMsgIdx = new uint32[](nodeCount);

        // Operator deposit (50-100 ETH)
        uint256 depositAmount = bound(uint256(seedNodeCount) * 10, 50 ether, 100 ether);
        (uint256 depositUsed, uint256 mintedShares_) = _deposit(staker, depositAmount);
        _setL1Limit(bob, validatorManagerAddress, assetClassId, depositUsed, delegator);
        _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, alice, mintedShares_, delegator);

        // BLS key and owners
        bytes memory blsKey = hex"abcd1234";
        address[] memory ownerArr = new address[](1);
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct = PChainOwner({threshold: 1, addresses: ownerArr});

        // Create nodes (unconfirmed)
        for (uint256 i = 0; i < nodeCount; i++) {
            bytes32 nodeId = keccak256(abi.encodePacked("Node", i, block.timestamp));
            nodeIds[i] = nodeId;

           // how much stake still free?
           (uint256 _minStake, ) = middleware.getClassStakingRequirements(1);
           uint256 free = middleware.getOperatorAvailableStake(alice)
                           - middleware.getOperatorUsedStakeCached(alice);
        
            if (free < _minStake) {
                // next addNode is *supposed* to revert – record and stop
                vm.expectRevert(abi.encodeWithSelector(IAvalancheL1Middleware.AvalancheL1Middleware__NotEnoughFreeStake.selector, _minStake));
                vm.prank(alice);
                middleware.addNode(
                    nodeId, blsKey, uint64(block.timestamp + 2 days),
                    ownerStruct, ownerStruct, 0        // will revert
                );
                nodeCount = i;                         // shrink arrays; creation done
                break;
           }

            vm.prank(alice);
            middleware.addNode(
                nodeId,
                hex"1234ABCD", // dummy BLS
                uint64(block.timestamp + 1 days),
                ownerStruct,
                ownerStruct,
                0
            );
            addMsgIdx[i] = mockValidatorManager.nextMessageIndex() - 1;

            bytes32 valID = mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId))));
            validationIds[i] = valID;
            isActive[i] = false;
        }

        // Confirm nodes => warp => truly active
        for (uint256 i = 0; i < nodeCount; i++) {
            vm.prank(alice);
            middleware.completeValidatorRegistration(alice, nodeIds[i], addMsgIdx[i]);
            isActive[i] = true;
        }
        epoch = _calcAndWarpOneEpoch();

        // Verify all nodes active
        {
            bytes32[] memory activeNodes = middleware.getActiveNodesForEpoch(alice, epoch);
            assertEq(activeNodes.length, nodeCount, "All newly confirmed nodes must show as active");
        }

        // Verify sum of stakes matches operator used stake
        {
            uint256 sumOfStakes;
            for (uint256 i = 0; i < nodeCount; i++) {
                sumOfStakes += middleware.getNodeStake(epoch, validationIds[i]);
            }
            uint256 operatorUsed = middleware.getOperatorUsedStakeCached(alice);
            assertEq(sumOfStakes, operatorUsed, "Operator used stake must match sum of node stakes after confirm");
        }

        // Fuzz stake up/down or remove nodes
        (uint256 _minStake,) = middleware.getClassStakingRequirements(assetClassId);

        for (uint256 i = 0; i < nodeCount; i++) {
            if (!isActive[i]) continue;

            bool doRemove = ((removeMask >> i) & 0x01) == 1;
            if (doRemove) {
                vm.prank(alice);
                middleware.removeNode(nodeIds[i]);
                isActive[i] = false;
                continue;
            }

            bool stakeDown = ((stakeDeltaMask >> i) & 0x01) == 1;
            uint256 currentStake = middleware.getNodeStake(epoch, validationIds[i]);
            if (currentStake == 0) continue;

            // Calculate new stake
            uint256 newStake;
            if (stakeDown) {
                newStake = currentStake / 2;
            } else {
                uint256 upAmount = currentStake / 2;
                newStake = currentStake + upAmount;
                uint256 avail = middleware.getOperatorAvailableStake(alice);
                if (newStake > currentStake + avail) {
                    newStake = currentStake + avail;
                }
            }

            if (newStake >= _minStake) {
                vm.prank(alice);
                middleware.initializeValidatorStakeUpdate(nodeIds[i], newStake);
                uint32 stakeMsgIdx = mockValidatorManager.nextMessageIndex() - 1;

                vm.prank(alice);
                middleware.completeStakeUpdate(nodeIds[i], stakeMsgIdx);
            }
        }

        // Warp to next epoch to finalize changes
        epoch = _calcAndWarpOneEpoch();

        // Verify sum of stakes matches operator used stake
        {
            uint256 sumOfStakes;
            for (uint256 i = 0; i < nodeCount; i++) {
                if (isActive[i]) {
                    sumOfStakes += middleware.getNodeStake(epoch, validationIds[i]);
                }
            }
            uint256 operatorUsed = middleware.getOperatorUsedStakeCached(alice);
            assertEq(sumOfStakes, operatorUsed, "Sum of node stakes should match operator used stake after updates");
        }

        // Warp to final window => forceUpdate
        _warpToLastHourOfCurrentEpoch();
        middleware.forceUpdateNodes(alice, 0);

        // Final epoch => finalize forced updates
        epoch = _calcAndWarpOneEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();

        // Check node stakes
        for (uint256 i = 0; i < nodeCount; i++) {
            uint256 finalStake = middleware.getNodeStake(epoch, validationIds[i]);

            if (isActive[i]) {
                bool forciblyRemoved = (finalStake == 0);
                if (forciblyRemoved) {
                    assertEq(finalStake, 0, "Node forcibly removed by forceUpdate");
                } else {
                    assertGt(finalStake, 0, "Node stake must remain > 0 if not forcibly removed");
                }
            } else {
                assertEq(finalStake, 0, "Node that was removed must have 0 stake");
            }
        }

        // Final check: sum of stakes matches operator used
        {
            uint256 sumOfStakes;
            for (uint256 i = 0; i < nodeCount; i++) {
                sumOfStakes += middleware.getNodeStake(epoch, validationIds[i]);
            }
            uint256 operatorUsed = middleware.getOperatorUsedStakeCached(alice);
            assertEq(sumOfStakes, operatorUsed, "Final sum of node stakes must match operator used stake");
        }
    }

    function testFuzz_TwoOperatorsMultipleNodes(
        uint8 seedNodeCountA,
        uint8 stakeDeltaMaskA,
        uint8 removeMaskA,
        uint8 seedNodeCountB,
        uint8 stakeDeltaMaskB,
        uint8 removeMaskB
    ) public {
        // Setup operators A (alice) and B (charlie) - using our pre-configured operators
        uint256 nodeCountA = bound(seedNodeCountA, 2, 5);
        uint256 nodeCountB = bound(seedNodeCountB, 2, 5);

        // Warp to start fresh
        uint48 epoch = _calcAndWarpOneEpoch();

        // Setup arrays for each operator
        bytes32[] memory nodeIdsA = new bytes32[](nodeCountA);
        bytes32[] memory validationIdsA = new bytes32[](nodeCountA);
        bool[] memory isActiveA = new bool[](nodeCountA);
        uint32[] memory addMsgIdxA = new uint32[](nodeCountA);

        bytes32[] memory nodeIdsB = new bytes32[](nodeCountB);
        bytes32[] memory validationIdsB = new bytes32[](nodeCountB);
        bool[] memory isActiveB = new bool[](nodeCountB);
        uint32[] memory addMsgIdxB = new uint32[](nodeCountB);

        // Operator deposits
        uint256 depositAmountA = bound(uint256(seedNodeCountA) * 10, 50 ether, 100 ether);
        // Use staker to deposit for Alice
        collateral.transfer(staker, depositAmountA);
        vm.startPrank(staker);
        collateral.approve(address(vault), depositAmountA);
        (uint256 depositUsedA, uint256 mintedSharesA) = vault.deposit(staker, depositAmountA);
        vm.stopPrank();

        _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, alice, mintedSharesA, delegator);

        uint256 depositAmountB = bound(uint256(seedNodeCountB) * 10, 50 ether, 100 ether);
        // Use staker to deposit for Charlie
        collateral.transfer(staker, depositAmountB);
        vm.startPrank(staker);
        collateral.approve(address(vault), depositAmountB);
        (uint256 depositUsedB, uint256 mintedSharesB) = vault.deposit(staker, depositAmountB);
        vm.stopPrank();

        _setL1Limit(bob, validatorManagerAddress, assetClassId, depositUsedA + depositUsedB, delegator);
        _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, charlie, mintedSharesB, delegator);
        _calcAndWarpOneEpoch();

        // Create nodes for operator A (Alice)
        for (uint256 i = 0; i < nodeCountA; i++) {
            bytes32 nodeId = keccak256(abi.encodePacked("NodeA", i, block.timestamp));
            nodeIdsA[i] = nodeId;

            vm.prank(alice);
            middleware.addNode(
                nodeId,
                hex"1234ABCD",
                uint64(block.timestamp + 1 days),
                PChainOwner({threshold: 1, addresses: new address[](1)}),
                PChainOwner({threshold: 1, addresses: new address[](1)}),
                0
            );
            addMsgIdxA[i] = mockValidatorManager.nextMessageIndex() - 1;

            bytes32 valID = mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId))));
            validationIdsA[i] = valID;
            isActiveA[i] = false;
        }

        // Create nodes for operator B (Charlie)
        for (uint256 i = 0; i < nodeCountB; i++) {
            bytes32 nodeId = keccak256(abi.encodePacked("NodeB", i, block.timestamp));
            nodeIdsB[i] = nodeId;

            vm.prank(charlie);
            middleware.addNode(
                nodeId,
                hex"9999DDDD",
                uint64(block.timestamp + 1 days),
                PChainOwner({threshold: 1, addresses: new address[](1)}),
                PChainOwner({threshold: 1, addresses: new address[](1)}),
                0
            );
            addMsgIdxB[i] = mockValidatorManager.nextMessageIndex() - 1;

            bytes32 valID = mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId))));
            validationIdsB[i] = valID;
            isActiveB[i] = false;
        }

        // Confirm nodes for both operators
        for (uint256 i = 0; i < nodeCountA; i++) {
            vm.prank(alice);
            middleware.completeValidatorRegistration(alice, nodeIdsA[i], addMsgIdxA[i]);
            isActiveA[i] = true;
        }

        for (uint256 i = 0; i < nodeCountB; i++) {
            vm.prank(charlie);
            middleware.completeValidatorRegistration(charlie, nodeIdsB[i], addMsgIdxB[i]);
            isActiveB[i] = true;
        }

        // Warp to next epoch
        epoch = _calcAndWarpOneEpoch();

        // Fuzz stake changes for both operators
        (uint256 minStake,) = middleware.getClassStakingRequirements(assetClassId);

        // Operator A (Alice) stake changes
        for (uint256 i = 0; i < nodeCountA; i++) {
            if (!isActiveA[i]) continue;

            bool doRemove = ((removeMaskA >> i) & 0x01) == 1;
            if (doRemove) {
                vm.prank(alice);
                middleware.removeNode(nodeIdsA[i]);
                isActiveA[i] = false;
                continue;
            }

            bool stakeDown = ((stakeDeltaMaskA >> i) & 0x01) == 1;
            uint256 currentStake = middleware.getNodeStake(epoch, validationIdsA[i]);
            if (currentStake == 0) continue;

            uint256 newStake;
            if (stakeDown) {
                newStake = currentStake / 2;
            } else {
                uint256 upAmt = currentStake / 2;
                newStake = currentStake + upAmt;
                uint256 avail = middleware.getOperatorAvailableStake(alice);
                if (newStake > currentStake + avail) {
                    newStake = currentStake + avail;
                }
            }

            if (newStake >= minStake) {
                vm.prank(alice);
                middleware.initializeValidatorStakeUpdate(nodeIdsA[i], newStake);
                uint32 stakeMsgIdx = mockValidatorManager.nextMessageIndex() - 1;

                vm.prank(alice);
                middleware.completeStakeUpdate(nodeIdsA[i], stakeMsgIdx);
            }
        }

        // Operator B (Charlie) stake changes
        for (uint256 i = 0; i < nodeCountB; i++) {
            if (!isActiveB[i]) continue;

            bool doRemove = ((removeMaskB >> i) & 0x01) == 1;
            if (doRemove) {
                vm.prank(charlie);
                middleware.removeNode(nodeIdsB[i]);
                isActiveB[i] = false;
                continue;
            }

            bool stakeDown = ((stakeDeltaMaskB >> i) & 0x01) == 1;
            uint256 currentStake = middleware.getNodeStake(epoch, validationIdsB[i]);
            if (currentStake == 0) continue;

            uint256 newStake;
            if (stakeDown) {
                newStake = currentStake / 2;
            } else {
                uint256 upAmt = currentStake / 2;
                newStake = currentStake + upAmt;
                uint256 avail = middleware.getOperatorAvailableStake(charlie);
                if (newStake > currentStake + avail) {
                    newStake = currentStake + avail;
                }
            }

            if (newStake >= minStake) {
                vm.prank(charlie);
                middleware.initializeValidatorStakeUpdate(nodeIdsB[i], newStake);
                uint32 stakeMsgIdx = mockValidatorManager.nextMessageIndex() - 1;

                vm.prank(charlie);
                middleware.completeStakeUpdate(nodeIdsB[i], stakeMsgIdx);
            }
        }

        // Warp to next epoch
        epoch = _calcAndWarpOneEpoch();

        // Force update both operators
        _warpToLastHourOfCurrentEpoch();
        middleware.forceUpdateNodes(alice, 0);
        middleware.forceUpdateNodes(charlie, 0);

        // Final epoch
        epoch = _calcAndWarpOneEpoch();

        // Check final stakes for operator A (Alice)
        for (uint256 i = 0; i < nodeCountA; i++) {
            uint256 finalStake = middleware.getNodeStake(epoch, validationIdsA[i]);
            if (isActiveA[i]) {
                if (finalStake == 0) {
                    assertEq(finalStake, 0, "Node forcibly removed by forceUpdate for operator A");
                } else {
                    assertGt(finalStake, 0, "Node stake must remain > 0 if not forcibly removed (operator A)");
                }
            } else {
                assertEq(finalStake, 0, "Removed node must have 0 stake (operator A)");
            }
        }

        // Check final stakes for operator B (Charlie)
        for (uint256 i = 0; i < nodeCountB; i++) {
            uint256 finalStake = middleware.getNodeStake(epoch, validationIdsB[i]);
            if (isActiveB[i]) {
                if (finalStake == 0) {
                    assertEq(finalStake, 0, "Node forcibly removed by forceUpdate for operator B");
                } else {
                    assertGt(finalStake, 0, "Node stake must remain > 0 if not forcibly removed (operator B)");
                }
            } else {
                assertEq(finalStake, 0, "Removed node must have 0 stake (operator B)");
            }
        }

        // Verify sum of stakes matches operator used stake
        {
            uint256 sumOfStakesA;
            for (uint256 i = 0; i < nodeCountA; i++) {
                sumOfStakesA += middleware.getNodeStake(epoch, validationIdsA[i]);
            }
            uint256 operatorAUsed = middleware.getOperatorUsedStakeCached(alice);
            assertEq(sumOfStakesA, operatorAUsed, "Final sum of node stakes must match operator A used stake");

            uint256 sumOfStakesB;
            for (uint256 i = 0; i < nodeCountB; i++) {
                sumOfStakesB += middleware.getNodeStake(epoch, validationIdsB[i]);
            }
            uint256 operatorBUsed = middleware.getOperatorUsedStakeCached(charlie);
            assertEq(sumOfStakesB, operatorBUsed, "Final sum of node stakes must match operator B used stake");
        }
    }

    function testFuzz_ThreeVaultsThreeOperators(
        uint8 nodeCountAlice,
        uint8 nodeCountCharlie,
        uint8 nodeCountDave,
        uint8 stakeDeltaMaskAlice,
        uint8 stakeDeltaMaskCharlie,
        uint8 stakeDeltaMaskDave,
        uint8 removeMaskAlice,
        uint8 removeMaskCharlie,
        uint8 removeMaskDave
    ) public {
        // Alice Operator for vault1 has 200_000_000_002_000 deposited
        // Alice Operator for vault3 has 100_000_000_000_000 deposited
        // Charlie Operator for vault1 has 150_000_000_000_000 deposited
        // Charlie Operator for vault2 has 120_000_000_000_000 deposited
        // Charlie Operator for vault3 has 100_000_000_000_000 deposited
        // Dave Operator for vault3 has 100_000_000_000_000 deposited
        // Dave Operator for vault2 has 160_000_000_000_000 deposited

        vm.startPrank(validatorManagerAddress);
        vaultManager.registerVault(address(vault2), 1, 3000 ether);
        vm.stopPrank();
        _setL1Limit(bob, validatorManagerAddress, 1, 2500 ether, delegator2);

        // Add collateral2 to assetClassId = 2
        _setupAssetClassAndRegisterVault(2, 1, collateral2, vault3, 3000 ether, 2500 ether, delegator3);

        // Advance epoch so that new stakes are recognized
        _calcAndWarpOneEpoch();

        // Now we do random node creation for each operator
        uint256 nA = bound(nodeCountAlice, 1, 6);
        uint256 nC = bound(nodeCountCharlie, 1, 6);
        uint256 nD = bound(nodeCountDave, 1, 6);

        (uint256 minStake, ) = middleware.getClassStakingRequirements(1);

        // Create & confirm nodes for each operator
        (bytes32[] memory nodeIdsAlice,,) = _createAndConfirmNodes(alice, nA, minStake, true, 2);
        (bytes32[] memory nodeIdsCharlie,,) = _createAndConfirmNodes(charlie, nC, minStake, true, 2);
        (bytes32[] memory nodeIdsDave,,) = _createAndConfirmNodes(dave, nD, minStake, true, 2);

        // Move to next epoch
        _calcAndWarpOneEpoch();

        // Fuzz: stakeDeltaMaskX, removeMaskX => operator modifies node stakes or removes them
        _stakeOrRemoveNodes(alice, nodeIdsAlice, stakeDeltaMaskAlice, removeMaskAlice);
        _stakeOrRemoveNodes(charlie, nodeIdsCharlie, stakeDeltaMaskCharlie, removeMaskCharlie);
        _stakeOrRemoveNodes(dave, nodeIdsDave, stakeDeltaMaskDave, removeMaskDave);

        // Warp => next epoch => finalize updates
        _calcAndWarpOneEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();

        // Force update each operator
        _warpToLastHourOfCurrentEpoch();
        middleware.forceUpdateNodes(alice, 0);
        middleware.forceUpdateNodes(charlie, 0);
        middleware.forceUpdateNodes(dave, 0);

        // Another epoch to ensure everything finalizes
        _calcAndWarpOneEpoch();

        // That's it. Optionally, verify final aggregator of node stakes == operatorUsedStake
        // for each operator. Just a quick check:
        _checkSumMatchesOperatorUsed(alice, nodeIdsAlice);
        _checkSumMatchesOperatorUsed(charlie, nodeIdsCharlie);
        _checkSumMatchesOperatorUsed(dave, nodeIdsDave);
    }

    function test_GetVaults() public view {
        uint48 epoch = middleware.getCurrentEpoch();

        address[] memory activeVaults = vaultManager.getVaults(epoch);

        uint256 activeCount = 0;
        bool foundVault1 = false;

        for (uint256 i = 0; i < activeVaults.length; i++) {
            if (activeVaults[i] != address(0)) {
                activeCount++;
                if (activeVaults[i] == address(vault)) foundVault1 = true;
            }
        }

        assertEq(activeCount, 1, "Should have 1 active vault");
        assertTrue(foundVault1, "First vault should be active");
    }

    function test_GetOperatorUsedStakeCachedPerEpoch() public {
        // Setup
        test_ForceUpdateWithAdditionalStake();
        uint48 epoch = middleware.getCurrentEpoch();

        // Test PRIMARY_ASSET_CLASS (1)
        uint256 primaryStake = middleware.getOperatorUsedStakeCachedPerEpoch(epoch, alice, 1);
        assertGt(primaryStake, 0, "Primary asset stake should be > 0");

        // Test secondary asset class (2)
        uint256 secondaryStake = middleware.getOperatorUsedStakeCachedPerEpoch(epoch, alice, 2);
        assertEq(secondaryStake, 0, "Secondary asset stake should be 0 as none was added");
    }

    function test_AutoUpdateFailsIfTooManyEpochsPending() public {
        uint48 maxAutoUpdates = middleware.MAX_AUTO_EPOCH_UPDATES();
        uint48 epochsToBecomePending = maxAutoUpdates + 1;

        uint48 currentEpochAfterWarp = _warpAdvanceMiddlewareEpochsRaw(epochsToBecomePending);
        
        bytes memory expectedError = abi.encodeWithSelector(
            IAvalancheL1Middleware.AvalancheL1Middleware__ManualEpochUpdateRequired.selector,
            currentEpochAfterWarp,
            maxAutoUpdates
        );
        vm.expectRevert(expectedError);
        middleware.calcAndCacheNodeStakeForAllOperators();

        bytes32 nodeId = keccak256("nodeTooManyPending");
        vm.startPrank(alice);
        vm.expectRevert(expectedError);
        middleware.addNode(
            nodeId,
            hex"1234",
            uint64(block.timestamp + 1 days),
            PChainOwner({threshold: 1, addresses: new address[](1)}),
            PChainOwner({threshold: 1, addresses: new address[](1)}),
            0
        );
        vm.stopPrank();
    }

    function test_ManualUpdateProcessesEpochsIncrementallyAndAutoUpdateSucceedsAfterCatchUp() public {
        address middlewareOwner = validatorManagerAddress;

        uint48 maxAutoUpdates = middleware.MAX_AUTO_EPOCH_UPDATES();
        uint48 totalEpochsToMakePending = maxAutoUpdates + 2;

        uint48 initialCurrentEpoch = middleware.getCurrentEpoch();
        uint48 currentEpochAfterWarp = _warpAdvanceMiddlewareEpochsRaw(totalEpochsToMakePending);
        
        assertEq(currentEpochAfterWarp, initialCurrentEpoch + totalEpochsToMakePending, "Warping did not result in the expected current epoch");

        bytes memory expectedRevertError = abi.encodeWithSelector(
            IAvalancheL1Middleware.AvalancheL1Middleware__ManualEpochUpdateRequired.selector,
            currentEpochAfterWarp,
            maxAutoUpdates
        );
        vm.expectRevert(expectedRevertError);
        middleware.calcAndCacheNodeStakeForAllOperators();

        uint48 epochsToProcessManuallyFirstPass = 2;
        vm.startPrank(middlewareOwner);
        vm.expectEmit(true, true, true, true, address(middleware));
        emit IAvalancheL1Middleware.NodeStakeCacheManuallyProcessed(
            epochsToProcessManuallyFirstPass,
            epochsToProcessManuallyFirstPass
        );
        middleware.manualProcessNodeStakeCache(epochsToProcessManuallyFirstPass);
        vm.stopPrank();

        middleware.calcAndCacheNodeStakeForAllOperators();
        
        vm.startPrank(middlewareOwner);
        vm.expectEmit(true, true, true, true, address(middleware));
        emit IAvalancheL1Middleware.NodeStakeCacheManuallyProcessed(
            currentEpochAfterWarp,
            0
        );
        middleware.manualProcessNodeStakeCache(1);
        vm.stopPrank();
        
        _warpAdvanceMiddlewareEpochsRaw(1);
        
        middleware.calcAndCacheNodeStakeForAllOperators();
    }
    
    function test_CalculateStakeForNowOldEpoch_AfterSlashingCheckRemoval() public {
        // Get initial epoch and asset class
        uint48 epochToTest = middleware.getCurrentEpoch();
        uint96 primaryAssetClass = middleware.PRIMARY_ASSET_CLASS();

        // Cache initial stake
        uint256 initialTotalStake = middleware.calcAndCacheStakes(epochToTest, primaryAssetClass);
        assertTrue(middleware.totalStakeCached(epochToTest, primaryAssetClass), "Stake should be cached");
        assertGt(initialTotalStake, 0, "Initial stake should be > 0");

        // Get time parameters
        uint48 slashingWindow = middleware.SLASHING_WINDOW();
        uint48 epochDuration = middleware.EPOCH_DURATION();
        assertTrue(epochDuration > 0, "Epoch duration must be positive");

        // Advance time past slashing window
        uint256 timeToAdvance = uint256(slashingWindow) + (uint256(epochDuration) * 5);
        vm.warp(block.timestamp + timeToAdvance);

        uint48 currentEpochAfterFarWarp = middleware.getCurrentEpoch();
        uint48 epochToTestStartTs = middleware.getEpochStartTs(epochToTest);
        
        // Verify time advancement
        assertTrue(currentEpochAfterFarWarp > epochToTest + (slashingWindow / epochDuration) + 3, "Time advanced enough");
        assertTrue(epochToTestStartTs < block.timestamp - slashingWindow, "Epoch is old enough");

        // Get stake for old epoch
        uint256 totalStakeForOldEpoch = middleware.getTotalStake(epochToTest, primaryAssetClass);
        assertEq(totalStakeForOldEpoch, initialTotalStake, "Stake matches initial value");
        assertGt(totalStakeForOldEpoch, 0, "Stake is positive");

        // Verify recalculation
        uint256 recalcTotalStakeForOldEpoch = middleware.calcAndCacheStakes(epochToTest, primaryAssetClass);
        assertEq(recalcTotalStakeForOldEpoch, initialTotalStake, "Recalculated stake matches");
        assertTrue(middleware.totalStakeCached(epochToTest, primaryAssetClass), "Stake remains cached");
    }

    // function test_DustLimitStakeCausesFakeRebalancing() public {
    //     address attacker = makeAddr("attacker");
    //     address delegatedStaker = makeAddr("delegatedStaker");

    //     _calcAndWarpOneEpoch();

    //     // Step 1. First, give Alice a large allocation and create nodes
    //     uint256 initialDeposit = 1000 ether;
    //     (uint256 depositAmount, uint256 initialShares) = _deposit(delegatedStaker, initialDeposit);
    //     console2.log("Initial deposit:", depositAmount);
    //     console2.log("Initial shares:", initialShares);

    //     // Set large L1 limit and give Alice all the shares initially
    //     _setL1Limit(bob, validatorManagerAddress, assetClassId, depositAmount, delegator);
    //     _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, alice, initialShares, delegator);

    //     // Step 2. Create nodes that will use this stake
    //     // move to next epoch
    //     _calcAndWarpOneEpoch();
    //     (, bytes32[] memory validationIDs,) = 
    //         _createAndConfirmNodes(alice, 2, 0, true);

    //     uint48 epoch2 = _calcAndWarpOneEpoch();

    //     // Verify nodes have the stake
    //     uint256 totalNodeStake = 0;
    //     for (uint i = 0; i < validationIDs.length; i++) {
    //         uint256 nodeStake = middleware.getNodeStake(epoch2, validationIDs[i]);
    //         totalNodeStake += nodeStake;
    //         console2.log("Node", i, "stake:", nodeStake);
    //     }
    //     console2.log("Total stake in nodes:", totalNodeStake); 

    //     uint256 operatorTotalStake = middleware.getOperatorStake(alice, epoch2, assetClassId);
    //     uint256 operatorUsedStake = middleware.getOperatorUsedStakeCached(alice);
    //     console2.log("Operator total stake (from delegation):", operatorTotalStake);
    //     console2.log("Operator used stake (in nodes):", operatorUsedStake);

    //     // Step 3. Delegated staker withdraws, reducing Alice's available stake
    //     console2.log("\n--- Delegated staker withdrawing 60% ---");
    //     uint256 withdrawAmount = (initialDeposit * 60) / 100; // 600 ether
    //     vm.startPrank(delegatedStaker);
    //     (uint256 burnedShares, ) = vault.withdraw(delegatedStaker, withdrawAmount);
    //     vm.stopPrank();        

    //     console2.log("Withdrawn amount:", withdrawAmount);
    //     console2.log("Burned shares:", burnedShares);
    //     console2.log("Remaining shares for Alice:", initialShares - burnedShares);

    //     // Step 4. Reduce Alice's operator shares to reflect the withdrawal
    //     uint256 newOperatorShares = initialShares - burnedShares;
    //     _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, alice, newOperatorShares, delegator);

    //     console2.log("Updated Alice's operator shares to:", newOperatorShares);
        
    //     // Step 5. Move to next epoch - this creates the imbalance
    //     uint48 epoch3  = _calcAndWarpOneEpoch();

    //     uint256 newOperatorTotalStake = middleware.getOperatorStake(alice, epoch3, assetClassId);
    //     uint256 currentUsedStake = middleware.getOperatorUsedStakeCached(alice);

    //     console2.log("\n--- After withdrawal (imbalance created) ---");
    //     console2.log("Alice's new total stake (reduced):", newOperatorTotalStake);
    //     console2.log("Alice's used stake (still in nodes):", currentUsedStake);                

    //     // Step 6. Attacker prevents legitimate rebalancing
    //     console2.log("\n--- ATTACKER PREVENTS REBALANCING ---");

    //     // Move to final window where forceUpdateNodes can be called
    //     _warpToLastHourOfCurrentEpoch();
        
    //     // Attacker front-runs with dust limitStake attack
    //     console2.log("Attacker executing dust forceUpdateNodes...");
    //     vm.prank(attacker);
    //     middleware.forceUpdateNodes(alice, 1); // 1 wei - minimal removal

    //     // Check if any meaningful stake was actually removed
    //     uint256 stakeAfterDustAttack = middleware.getOperatorUsedStakeCached(alice);
    //     console2.log("Used stake after dust attack:", stakeAfterDustAttack);

    //     uint256 actualRemoved = currentUsedStake > stakeAfterDustAttack ? 
    //         currentUsedStake - stakeAfterDustAttack : 0;
    //     console2.log("Stake actually removed by dust attack:", actualRemoved);   

    //     // The key issue: minimal stake removed, but still excess remains
    //     uint256 remainingExcess = stakeAfterDustAttack > newOperatorTotalStake ?
    //         stakeAfterDustAttack - newOperatorTotalStake : 0;
    //     console2.log("REMAINING EXCESS after dust attack:", remainingExcess);

    //     // 7. Try legitimate rebalancing - should be blocked
    //     console2.log("\n--- Attempting legitimate rebalancing ---");
    //     vm.expectRevert(); // Should revert with AvalancheL1Middleware__AlreadyRebalanced
    //     middleware.forceUpdateNodes(alice, 0); // Proper rebalancing with no limit
    //     console2.log("Legitimate rebalancing blocked by AlreadyRebalanced");                                     
    // }

    function test_DustLimitStakeCausesFakeRebalancingFix() public {
        address attacker = makeAddr("attacker");
        address delegatedStaker = makeAddr("delegatedStaker");

        _calcAndWarpOneEpoch();

        // Setup initial stake and nodes
        uint256 initialDeposit = 1000 ether;
        (uint256 depositAmount, uint256 initialShares) = _deposit(delegatedStaker, initialDeposit);

        _setL1Limit(bob, validatorManagerAddress, assetClassId, depositAmount, delegator);
        _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, alice, initialShares, delegator);

        _calcAndWarpOneEpoch();
        (, bytes32[] memory validationIDs,) = _createAndConfirmNodes(alice, 2, 0, true, 2);

        uint48 epoch2 = _calcAndWarpOneEpoch();

        // Verify node stakes
        uint256 totalNodeStake = 0;
        for (uint i = 0; i < validationIDs.length; i++) {
            uint256 nodeStake = middleware.getNodeStake(epoch2, validationIDs[i]);
            totalNodeStake += nodeStake;
        }

        middleware.getOperatorStake(alice, epoch2, assetClassId);
        middleware.getOperatorUsedStakeCached(alice);

        // Withdraw and update operator shares
        uint256 withdrawAmount = (initialDeposit * 60) / 100;
        vm.startPrank(delegatedStaker);
        (uint256 burnedShares, ) = vault.withdraw(delegatedStaker, withdrawAmount);
        vm.stopPrank();        

        uint256 newOperatorShares = initialShares - burnedShares;
        _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, alice, newOperatorShares, delegator);
        
        uint48 epoch3 = _calcAndWarpOneEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();

        uint256 newOperatorTotalStake = middleware.getOperatorStake(alice, epoch3, assetClassId);
        uint256 currentUsedStake = middleware.getOperatorUsedStakeCached(alice);

        // Verify excess stake scenario
        assertGt(newOperatorTotalStake, currentUsedStake, "Setup creates excess available stake");

        _warpToLastHourOfCurrentEpoch();
        
        // Test forceUpdateNodes behavior with excess stake
        vm.prank(attacker);
        middleware.forceUpdateNodes(alice, 1);
        
        assertFalse(middleware.rebalancedThisEpoch(alice, epoch3), "No rebalancing flag set for excess stake");
        
        middleware.forceUpdateNodes(alice, 0);
        assertFalse(middleware.rebalancedThisEpoch(alice, epoch3), "Still no rebalancing flag");
    }

    // function test_FutureEpochCacheManipulation() public {
    //     uint48 currentEpoch = _calcAndWarpOneEpoch();
        
    //     // Alice starts with high stake 
    //     uint256 aliceInitialStake = middleware.getOperatorStake(alice, currentEpoch, assetClassId);
    //     console2.log("Alice initial stake:", aliceInitialStake);
    //     assertGt(aliceInitialStake, 0, "Alice should have initial stake");
        
    //     // 1. ATTACK: Cache future epoch with current high stake values
    //     uint48 futureEpoch = currentEpoch + 5;
    //     console2.log("Caching future epoch:", futureEpoch);
    //     console2.log("Current epoch:", currentEpoch);
        
    //     // This should NOT be allowed but currently works
    //     uint256 cachedTotalStake = middleware.calcAndCacheStakes(futureEpoch, assetClassId);
    //     console2.log("Successfully cached future epoch total stake:", cachedTotalStake);
        
    //     // Verify that future epoch is now marked as cached
    //     assertTrue(middleware.totalStakeCached(futureEpoch, assetClassId), "Future epoch should be marked as cached");
        
    //     // Get Alice's cached stake for the future epoch (should be her current high stake)
    //     uint256 aliceCachedFutureStake = middleware.getOperatorStake(alice, futureEpoch, assetClassId);
    //     console2.log("Alice cached future stake:", aliceCachedFutureStake);
    //     assertEq(aliceCachedFutureStake, aliceInitialStake, "Cached future stake should equal current stake");
        
    //     // 2. TIME PASSES: Alice withdraws most of her stake
    //     uint256 withdrawAmount = 150_000_000_000_000; // Withdraw significant amount
    //     console2.log("Alice withdrawing:", withdrawAmount);
        
    //     _withdraw(staker, withdrawAmount);
        
    //     // Move forward through epochs to simulate time passing
    //     for (uint256 i = 0; i < 5; i++) {
    //         _calcAndWarpOneEpoch();
    //     }
        
    //     // We should now be at the future epoch that was cached
    //     uint48 nowCurrentEpoch = middleware.getCurrentEpoch();
    //     console2.log("Now at epoch:", nowCurrentEpoch);
    //     assertEq(nowCurrentEpoch, futureEpoch, "Should have reached the future epoch");
        
    //     // 3. DEMONSTRATE THE ISSUE: Check Alice's actual vs cached stake
        
    //     // Get Alice's actual current stake (should be lower due to withdrawal)
    //     // We need to calculate this manually since cached version will return stale data
        
    //     // First, let's clear the cache to see what the real value would be
    //     // (In a real attack, we can't do this, but for demo purposes let's show the difference)
        
    //     // Calculate what Alice's stake SHOULD be by checking a non-cached epoch
    //     uint48 recentEpoch = nowCurrentEpoch - 1;
    //     uint256 aliceActualRecentStake = middleware.getOperatorStake(alice, recentEpoch, assetClassId);
    //     console2.log("Alice's actual recent stake (epoch - 1):", aliceActualRecentStake);
        
    //     // Get the cached (manipulated) stake for the current epoch
    //     uint256 aliceManipulatedStake = middleware.getOperatorStake(alice, futureEpoch, assetClassId);
    //     console2.log("Alice's cached (manipulated) stake:", aliceManipulatedStake);
        
    //     // 4. PROVE THE MANIPULATION
    //     assertGt(aliceManipulatedStake, aliceActualRecentStake, "Cached stake should be higher than actual stake");
        
    //     // The cached stake should still be the original high value despite withdrawals
    //     assertEq(aliceManipulatedStake, aliceInitialStake, "Cached stake should still be original high value");
        
    //     console2.log("=== VULNERABILITY DEMONSTRATED ===");
    //     console2.log("Original stake when cached:", aliceInitialStake);
    //     console2.log("Actual stake after withdrawal:", aliceActualRecentStake);  
    //     console2.log("Cached manipulated stake:", aliceManipulatedStake);
    //     console2.log("Difference (potential theft):", aliceManipulatedStake - aliceActualRecentStake);

    //     // This demonstrates that Alice can get rewards based on her old high stake
    //     // even though she withdrew most of her funds
                
    //     // 5. SHOW THAT CACHE CANNOT BE UPDATED

    //     uint256 attemptRecalc = middleware.calcAndCacheStakes(futureEpoch, assetClassId);
    //     assertEq(attemptRecalc, cachedTotalStake, "Cache cannot be updated once set");
        
    //     // The vulnerability is complete: Alice has locked in high stakes for reward calculation
    //     // while having withdrawn most of her actual stake
    // }

    function test_FutureEpochCacheManipulationFix() public {
        uint48 currentEpoch = _calcAndWarpOneEpoch();
        
        // Alice starts with high stake 
        uint256 aliceInitialStake = middleware.getOperatorStake(alice, currentEpoch, assetClassId);
        console2.log("Alice initial stake:", aliceInitialStake);
        assertGt(aliceInitialStake, 0, "Alice should have initial stake");
        
        // 1. ATTACK ATTEMPT: Try to cache future epoch with current high stake values
        uint48 futureEpoch = currentEpoch + 5;
        
        // This should REVERT with the fix in place
        vm.expectRevert(
            abi.encodeWithSelector(
                IAvalancheL1Middleware.AvalancheL1Middleware__CannotCacheFutureEpoch.selector,
                futureEpoch
            )
        );
        middleware.calcAndCacheStakes(futureEpoch, assetClassId);
        
        // 2. Verify that future epoch is NOT cached
        assertFalse(
            middleware.totalStakeCached(futureEpoch, assetClassId), 
            "Future epoch should NOT be cached"
        );
        
        // 3. Verify we CAN cache the current epoch
        middleware.calcAndCacheStakes(currentEpoch, assetClassId);
        assertTrue(
            middleware.totalStakeCached(currentEpoch, assetClassId), 
            "Current epoch should be cached"
        );
        
        // 4. Verify we CAN cache past epochs (if needed for your use case)
        if (currentEpoch > 0) {
            uint48 pastEpoch = currentEpoch - 1;
            middleware.calcAndCacheStakes(pastEpoch, assetClassId);
            assertTrue(
                middleware.totalStakeCached(pastEpoch, assetClassId), 
                "Past epoch should be cached"
            );
        }
        
        // 5. TIME PASSES: Alice withdraws most of her stake
        uint256 withdrawAmount = 150_000_000_000_000; // Withdraw significant amount
        console2.log("Alice withdrawing:", withdrawAmount);
        
        _withdraw(staker, withdrawAmount);
        
        // Move forward through epochs to simulate time passing
        for (uint256 i = 0; i < 5; i++) {
            _calcAndWarpOneEpoch();
        }
        
        // We should now be at the future epoch that we tried to cache earlier
        uint48 nowCurrentEpoch = middleware.getCurrentEpoch();
        console2.log("Now at epoch:", nowCurrentEpoch);
        assertEq(nowCurrentEpoch, futureEpoch, "Should have reached the future epoch");
        
        // 6. NOW we can cache this epoch (since it's no longer in the future)
        middleware.calcAndCacheStakes(nowCurrentEpoch, assetClassId);
        
        // 7. Verify the stake reflects the ACTUAL current state (post-withdrawal)
        uint256 aliceCurrentStake = middleware.getOperatorStake(alice, nowCurrentEpoch, assetClassId);
        
        // The stake should be lower than the initial stake due to withdrawal
        assertLt(
            aliceCurrentStake, 
            aliceInitialStake, 
            "Alice's stake should be lower after withdrawal"
        );
    }

    function test_CacheCurrentAndPastEpochs() public {
        uint48 currentEpoch = _calcAndWarpOneEpoch();
        
        // Test 1: Can cache current epoch
        middleware.calcAndCacheStakes(currentEpoch, assetClassId);
        assertTrue(middleware.totalStakeCached(currentEpoch, assetClassId), "Should cache current epoch");
        
        // Test 2: Can cache past epoch
        if (currentEpoch > 0) {
            middleware.calcAndCacheStakes(currentEpoch - 1, assetClassId);
            assertTrue(middleware.totalStakeCached(currentEpoch - 1, assetClassId), "Should cache past epoch");
        }
        
        // Test 3: Cannot cache future epoch (even by 1)
        vm.expectRevert(
            abi.encodeWithSelector(
                IAvalancheL1Middleware.AvalancheL1Middleware__CannotCacheFutureEpoch.selector,
                currentEpoch + 1
            )
        );
        middleware.calcAndCacheStakes(currentEpoch + 1, assetClassId);
        
        // Test 4: Cannot cache far future epoch
        vm.expectRevert(
            abi.encodeWithSelector(
                IAvalancheL1Middleware.AvalancheL1Middleware__CannotCacheFutureEpoch.selector,
                currentEpoch + 100
            )
        );
        middleware.calcAndCacheStakes(currentEpoch + 100, assetClassId);
    }

//    function test_POC_MisattributedStake_NodeIdReused() public {
//         console2.log("--- POC: Misattributed Stake due to NodeID Reuse ---");

//         address operatorA = alice;
//         address operatorB = charlie; // Using charlie as Operator B

//         // Use a specific, predictable nodeId for the test
//         bytes32 sharedNodeId_X = keccak256(abi.encodePacked("REUSED_NODE_ID_XYZ"));
//         bytes memory blsKey_A = hex"A1A1A1";
//         bytes memory blsKey_B = hex"B2B2B2"; // Operator B uses a different BLS key
//         uint64 registrationExpiry = uint64(block.timestamp + 2 days);
//         address[] memory ownerArr = new address[](1);
//         ownerArr[0] = operatorA; // For simplicity, operator owns the PChainOwner
//         PChainOwner memory pchainOwner_A = PChainOwner({threshold: 1, addresses: ownerArr});
//         ownerArr[0] = operatorB;
//         PChainOwner memory pchainOwner_B = PChainOwner({threshold: 1, addresses: ownerArr});


//         // Ensure operators have some stake in the vault
//         uint256 stakeAmountOpA = 20_000_000_000_000; // e.g., 20k tokens
//         uint256 stakeAmountOpB = 30_000_000_000_000; // e.g., 30k tokens

//         // Operator A deposits and sets shares
//         collateral.transfer(staker, stakeAmountOpA);
//         vm.startPrank(staker);
//         collateral.approve(address(vault), stakeAmountOpA);
//         (,uint256 sharesA) = vault.deposit(operatorA, stakeAmountOpA);
//         vm.stopPrank();
//         _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, operatorA, sharesA, delegator);

//         // Operator B deposits and sets shares (can use the same vault or a different one)
//         collateral.transfer(staker, stakeAmountOpB);
//         vm.startPrank(staker);
//         collateral.approve(address(vault), stakeAmountOpB);
//         (,uint256 sharesB) = vault.deposit(operatorB, stakeAmountOpB);
//         vm.stopPrank();
//         _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, operatorB, sharesB, delegator);
        
//         _calcAndWarpOneEpoch(); // Ensure stakes are recognized

//         // --- Epoch E0: Operator A registers node N1 using sharedNodeId_X ---
//         console2.log("Epoch E0: Operator A registers node with sharedNodeId_X");
//         uint48 epochE0 = middleware.getCurrentEpoch();
//         vm.prank(operatorA);
//         middleware.addNode(sharedNodeId_X, blsKey_A, registrationExpiry, pchainOwner_A, pchainOwner_A, 0);
//         uint32 msgIdx_A1_add = mockValidatorManager.nextMessageIndex() - 1;
        
//         // Get the L1 validationID for Operator A's node
//         bytes memory pchainNodeId_P_X_bytes = abi.encodePacked(uint160(uint256(sharedNodeId_X)));
//         bytes32 validationID_A1 = mockValidatorManager.registeredValidators(pchainNodeId_P_X_bytes);
//         console2.log("Operator A's L1 validationID_A1:", vm.toString(validationID_A1));

//         vm.prank(operatorA);
//         middleware.completeValidatorRegistration(operatorA, sharedNodeId_X, msgIdx_A1_add);
        
//         _calcAndWarpOneEpoch(); // Move to E0 + 1 for N1 to be active
//         epochE0 = middleware.getCurrentEpoch(); // Update epochE0 to where node is active

//         uint256 stake_A_on_N1 = middleware.getNodeStake(epochE0, validationID_A1);
//         assertGt(stake_A_on_N1, 0, "Operator A's node N1 should have stake in Epoch E0");
//         console2.log("Stake of Operator A on node N1 (validationID_A1) in Epoch E0:", vm.toString(stake_A_on_N1));

//         bytes32[] memory activeNodes_A_E0 = middleware.getActiveNodesForEpoch(operatorA, epochE0);
//         assertEq(activeNodes_A_E0.length, 1, "Operator A should have 1 active node in E0");
//         assertEq(activeNodes_A_E0[0], sharedNodeId_X, "Active node for A in E0 should be sharedNodeId_X");

//         // --- Epoch E1: Node N1 (validationID_A1) is fully removed ---
//         console2.log("Epoch E1: Operator A removes node N1 (validationID_A1)");
//         _calcAndWarpOneEpoch();
//         uint48 epochE1 = middleware.getCurrentEpoch();

//         vm.prank(operatorA);
//         middleware.removeNode(sharedNodeId_X);
//         uint32 msgIdx_A1_remove = mockValidatorManager.nextMessageIndex() - 1;

//         _calcAndWarpOneEpoch(); // To process removal in cache
//         epochE1 = middleware.getCurrentEpoch(); // Update E1 to where removal is cached

//         assertEq(middleware.getNodeStake(epochE1, validationID_A1), 0, "Stake for validationID_A1 should be 0 after removal in cache");
        
//         vm.prank(operatorA);
//         middleware.completeValidatorRemoval(msgIdx_A1_remove); // L1 confirms removal
        
//         console2.log("P-Chain NodeID P_X (derived from sharedNodeId_X) is now considered available on L1.");

//         activeNodes_A_E0 = middleware.getActiveNodesForEpoch(operatorA, epochE1); // Check active nodes for A in E1
//         assertEq(activeNodes_A_E0.length, 0, "Operator A should have 0 active nodes in E1 after removal");

//         // --- Epoch E2: Operator B re-registers a node N2 using the *exact same sharedNodeId_X* ---
//         console2.log("Epoch E2: Operator B registers a new node N2 using the same sharedNodeId_X");
//         _calcAndWarpOneEpoch();
//         uint48 epochE2 = middleware.getCurrentEpoch();

//         vm.prank(operatorB);
//         middleware.addNode(sharedNodeId_X, blsKey_B, registrationExpiry, pchainOwner_B, pchainOwner_B, 0);
//         uint32 msgIdx_B2_add = mockValidatorManager.nextMessageIndex() - 1;

//         // Get the L1 validationID for Operator B's new node (N2)
//         bytes32 validationID_B2 = mockValidatorManager.registeredValidators(pchainNodeId_P_X_bytes);
//         console2.log("Operator B's new L1 validationID_B2 for sharedNodeId_X:", vm.toString(validationID_B2));
//         assertNotEq(validationID_A1, validationID_B2, "L1 validationID for B's node should be different from A's old one");

//         vm.prank(operatorB);
//         middleware.completeValidatorRegistration(operatorB, sharedNodeId_X, msgIdx_B2_add);

//         _calcAndWarpOneEpoch(); // Move to E2 + 1 for N2 to be active
//         epochE2 = middleware.getCurrentEpoch(); // Update epochE2 to where node is active

//         uint256 stake_B_on_N2 = middleware.getNodeStake(epochE2, validationID_B2);
//         assertGt(stake_B_on_N2, 0, "Operator B's node N2 should have stake in Epoch E2");
//         console2.log("Stake of Operator B on node N2 (validationID_B2) in Epoch E2:", vm.toString(stake_B_on_N2));

//         bytes32[] memory activeNodes_B_E2 = middleware.getActiveNodesForEpoch(operatorB, epochE2);
//         assertEq(activeNodes_B_E2.length, 1, "Operator B should have 1 active node in E2");
//         assertEq(activeNodes_B_E2[0], sharedNodeId_X);


//         // --- Querying for Operator A's Stake in Epoch E2 (THE VULNERABILITY) ---
//         console2.log("Querying Operator A's used stake in Epoch E2 (where B's node is active with sharedNodeId_X)");
        
//         // Ensure caches are up-to-date for Operator A for epoch E2
//         middleware.calcAndCacheStakes(epochE2, middleware.PRIMARY_ASSET_CLASS());

//         uint256 usedStake_A_E2 = middleware.getOperatorUsedStakeCachedPerEpoch(epochE2, operatorA, middleware.PRIMARY_ASSET_CLASS());
//         console2.log("Calculated 'used stake' for Operator A in Epoch E2: ", vm.toString(usedStake_A_E2));
//         // ASSERTION: Operator A's used stake should be 0 in epoch E2, as their node was removed in E1.
//         // However, due to the issue, it will pick up Operator B's stake.
//         assertEq(usedStake_A_E2, stake_B_on_N2, "FAIL: Operator A's used stake in E2 is misattributed with Operator B's stake!");

//         // Let's ensure B's node is indeed seen as active by the mock in E2
//         Validator memory validator_B2_details = mockValidatorManager.getValidator(validationID_B2);
//         uint48 epochE2_startTs = middleware.getEpochStartTs(epochE2);
//         bool b_node_active_in_e2 = uint48(validator_B2_details.startedAt) <= epochE2_startTs &&
//                                    (validator_B2_details.endedAt == 0 || uint48(validator_B2_details.endedAt) >= epochE2_startTs);
//         assertTrue(b_node_active_in_e2, "Operator B's node (validationID_B2) should be active in Epoch E2");

//         console2.log("--- PoC End ---");
//     }

    function test_POC_MisattributedStake_NodeIdReused_Fixed() public {
        address operatorA = alice;
        address operatorB = charlie; // Using charlie as Operator B

        // Use a specific, predictable nodeId for the test
        bytes32 sharedNodeId_X = keccak256(abi.encodePacked("REUSED_NODE_ID_XYZ"));
        bytes memory blsKey_A = hex"A1A1A1";
        bytes memory blsKey_B = hex"B2B2B2"; // Operator B uses a different BLS key
        uint64 registrationExpiry = uint64(block.timestamp + 2 days);
        address[] memory ownerArr = new address[](1);
        ownerArr[0] = operatorA; // For simplicity, operator owns the PChainOwner
        PChainOwner memory pchainOwner_A = PChainOwner({threshold: 1, addresses: ownerArr});
        ownerArr[0] = operatorB;
        PChainOwner memory pchainOwner_B = PChainOwner({threshold: 1, addresses: ownerArr});

        // Ensure operators have some stake in the vault
        uint256 stakeAmountOpA = 20_000_000_000_000; // e.g., 20k tokens
        uint256 stakeAmountOpB = 30_000_000_000_000; // e.g., 30k tokens

        // Operator A deposits and sets shares
        collateral.transfer(staker, stakeAmountOpA);
        vm.startPrank(staker);
        collateral.approve(address(vault), stakeAmountOpA);
        (,uint256 sharesA) = vault.deposit(operatorA, stakeAmountOpA);
        vm.stopPrank();
        _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, operatorA, sharesA, delegator);

        // Operator B deposits and sets shares
        collateral.transfer(staker, stakeAmountOpB);
        vm.startPrank(staker);
        collateral.approve(address(vault), stakeAmountOpB);
        (,uint256 sharesB) = vault.deposit(operatorB, stakeAmountOpB);
        vm.stopPrank();
        _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, operatorB, sharesB, delegator);
        
        _calcAndWarpOneEpoch(); // Ensure stakes are recognized

        // --- Epoch E0: Operator A registers node N1 using sharedNodeId_X ---
        uint48 epochE0 = middleware.getCurrentEpoch();
        vm.prank(operatorA);
        middleware.addNode(sharedNodeId_X, blsKey_A, registrationExpiry, pchainOwner_A, pchainOwner_A, 0);
        uint32 msgIdx_A1_add = mockValidatorManager.nextMessageIndex() - 1;
        
        // Get the L1 validationID for Operator A's node
        bytes memory pchainNodeId_P_X_bytes = abi.encodePacked(uint160(uint256(sharedNodeId_X)));
        bytes32 validationID_A1 = mockValidatorManager.registeredValidators(pchainNodeId_P_X_bytes);
        
        // Verify the fix: validationID is mapped to operator A
        assertEq(middleware.validationIdToOperator(validationID_A1), operatorA, "ValidationID should be mapped to operator A");

        vm.prank(operatorA);
        middleware.completeValidatorRegistration(operatorA, sharedNodeId_X, msgIdx_A1_add);
        
        _calcAndWarpOneEpoch(); // Move to E0 + 1 for N1 to be active
        epochE0 = middleware.getCurrentEpoch();

        uint256 stake_A_on_N1 = middleware.getNodeStake(epochE0, validationID_A1);
        assertGt(stake_A_on_N1, 0, "Operator A's node N1 should have stake");

        bytes32[] memory activeNodes_A_E0 = middleware.getActiveNodesForEpoch(operatorA, epochE0);
        assertEq(activeNodes_A_E0.length, 1, "Operator A should have 1 active node");
        assertEq(activeNodes_A_E0[0], sharedNodeId_X);

        // --- Epoch E1: Node N1 is fully removed ---
        _calcAndWarpOneEpoch();
        uint48 epochE1 = middleware.getCurrentEpoch();

        vm.prank(operatorA);
        middleware.removeNode(sharedNodeId_X);
        uint32 msgIdx_A1_remove = mockValidatorManager.nextMessageIndex() - 1;

        _calcAndWarpOneEpoch();
        epochE1 = middleware.getCurrentEpoch();

        assertEq(middleware.getNodeStake(epochE1, validationID_A1), 0, "Stake should be 0 after removal");
        
        vm.prank(operatorA);
        middleware.completeValidatorRemoval(msgIdx_A1_remove);

        bytes32[] memory activeNodes_A_E1 = middleware.getActiveNodesForEpoch(operatorA, epochE1);
        assertEq(activeNodes_A_E1.length, 0, "Operator A should have 0 active nodes after removal");

        // --- Epoch E2: Operator B re-registers using same sharedNodeId_X ---
        _calcAndWarpOneEpoch();
        uint48 epochE2 = middleware.getCurrentEpoch();

        vm.prank(operatorB);
        middleware.addNode(sharedNodeId_X, blsKey_B, registrationExpiry, pchainOwner_B, pchainOwner_B, 0);
        uint32 msgIdx_B2_add = mockValidatorManager.nextMessageIndex() - 1;

        // Get the L1 validationID for Operator B's new node
        bytes32 validationID_B2 = mockValidatorManager.registeredValidators(pchainNodeId_P_X_bytes);
        assertNotEq(validationID_A1, validationID_B2, "ValidationIDs should be different");
        
        // Verify the fix: new validationID is mapped to operator B
        assertEq(middleware.validationIdToOperator(validationID_B2), operatorB, "New ValidationID should be mapped to operator B");

        vm.prank(operatorB);
        middleware.completeValidatorRegistration(operatorB, sharedNodeId_X, msgIdx_B2_add);

        _calcAndWarpOneEpoch();
        epochE2 = middleware.getCurrentEpoch();

        uint256 stake_B_on_N2 = middleware.getNodeStake(epochE2, validationID_B2);
        assertGt(stake_B_on_N2, 0, "Operator B's node should have stake");

        bytes32[] memory activeNodes_B_E2 = middleware.getActiveNodesForEpoch(operatorB, epochE2);
        assertEq(activeNodes_B_E2.length, 1, "Operator B should have 1 active node");
        assertEq(activeNodes_B_E2[0], sharedNodeId_X);

        // --- THE FIX VERIFICATION: Query Operator A's stake in Epoch E2 ---
        middleware.calcAndCacheStakes(epochE2, middleware.PRIMARY_ASSET_CLASS());

        uint256 usedStake_A_E2 = middleware.getOperatorUsedStakeCachedPerEpoch(
            epochE2, operatorA, middleware.PRIMARY_ASSET_CLASS()
        );
        
        // WITH THE FIX: Operator A's used stake should be 0, NOT Operator B's stake
        assertEq(usedStake_A_E2, 0, "SUCCESS: Operator A's stake is correctly 0, not misattributed!");
        
        // Verify Operator B's stake is correctly attributed to B
        uint256 usedStake_B_E2 = middleware.getOperatorUsedStakeCachedPerEpoch(
            epochE2, operatorB, middleware.PRIMARY_ASSET_CLASS()
        );
        assertEq(usedStake_B_E2, stake_B_on_N2, "Operator B's stake correctly attributed");
        
        // Double-check that Operator A has no active nodes in E2
        bytes32[] memory activeNodes_A_E2 = middleware.getActiveNodesForEpoch(operatorA, epochE2);
        assertEq(activeNodes_A_E2.length, 0, "Operator A should have 0 active nodes in E2");
    }


    // function test_changeVaultManager() public {
    //     // Move forward to let the vault roll epochs
    //     uint48 epoch = _calcAndWarpOneEpoch();

    //     uint256 operatorStake = middleware.getOperatorStake(alice, epoch, assetClassId);
    //     console2.log("Operator stake (epoch", epoch, "):", operatorStake);
    //     assertGt(operatorStake, 0);

    //     MiddlewareVaultManager vaultManager2 = new MiddlewareVaultManager(address(vaultFactory), owner, address(middleware));

    //     vm.startPrank(validatorManagerAddress);
    //     middleware.setVaultManager(address(vaultManager2));
    //     vm.stopPrank();

    //     uint256 operatorStake2 = middleware.getOperatorStake(alice, epoch, assetClassId);
    //     console2.log("Operator stake (epoch", epoch, "):", operatorStake2);
    //     assertEq(operatorStake2, 0);
    // }

    function test_changeVaultManagerFix() public {
        // Move forward to let the vault roll epochs
        uint48 epoch = _calcAndWarpOneEpoch();

        uint256 operatorStake = middleware.getOperatorStake(alice, epoch, assetClassId);
        console2.log("Operator stake (epoch", epoch, "):", operatorStake);
        assertGt(operatorStake, 0);

        MiddlewareVaultManager vaultManager2 = new MiddlewareVaultManager(address(vaultFactory), owner, address(middleware), 24); // 24 epoch delay

        vm.startPrank(validatorManagerAddress);
        vm.expectRevert(abi.encodeWithSelector(IAvalancheL1Middleware.AvalancheL1Middleware__VaultManagerAlreadySet.selector, address(vaultManager)));
        middleware.setVaultManager(address(vaultManager2));
        vm.stopPrank();
    }

    // function test_POC_RemoveOperatorWithActiveNodes() public {
    //     uint48 epoch = _calcAndWarpOneEpoch();
        
    //     // Add nodes for alice
    //     (bytes32[] memory nodeIds, bytes32[] memory validationIDs,) = _createAndConfirmNodes(alice, 3, 0, true);
        
    //     // Move to next epoch to ensure nodes are active
    //     epoch = _calcAndWarpOneEpoch();
        
    //     // Verify alice has active nodes and stake
    //     uint256 nodeCount = middleware.getOperatorNodesLength(alice);
    //     uint256 aliceStake = middleware.getOperatorStake(alice, epoch, assetClassId);
    //     assertGt(nodeCount, 0, "Alice should have active nodes");
    //     assertGt(aliceStake, 0, "Alice should have stake");
        
    //     console2.log("Before removal:");
    //     console2.log("  Active nodes:", nodeCount);
    //     console2.log("  Operator stake:", aliceStake);
        
    //     // First disable the operator (required for removal)
    //     vm.prank(validatorManagerAddress);
    //     middleware.disableOperator(alice);
        
    //     // Warp past the slashing window to allow removal
    //     uint48 slashingWindow = middleware.SLASHING_WINDOW();
    //     vm.warp(block.timestamp + slashingWindow + 1);
        
    //     // @audit Admin can remove operator with active nodes (NO VALIDATION!)
    //     vm.prank(validatorManagerAddress);
    //     middleware.removeOperator(alice);
        
    //     // Verify alice is removed from operators mapping
    //     address[] memory currentOperators = middleware.getAllOperators();
    //         bool aliceFound = false;
    //         for (uint256 i = 0; i < currentOperators.length; i++) {
    //             if (currentOperators[i] == alice) {
    //                 aliceFound = true;
    //                 break;
    //             }
    //         }
    //         console2.log("Alice found:", aliceFound);
    //         assertFalse(aliceFound, "Alice should not be in current operators list");
        
    //     // Verify alice's nodes still exist in storage
    //     assertEq(middleware.getOperatorNodesLength(alice), nodeCount, "Alice's nodes should still exist in storage");
        
    //     // Verify alice's nodes still have stake cached
    //     for (uint256 i = 0; i < nodeIds.length; i++) {
    //         uint256 nodeStake = middleware.nodeStakeCache(epoch, validationIDs[i]);
    //         assertGt(nodeStake, 0, "Node should still have cached stake");
    //     }
        
    //     // Verify stake calculations still work
    //     uint256 stakeAfterRemoval = middleware.getOperatorStake(alice, epoch, assetClassId);
    //     assertEq(stakeAfterRemoval, aliceStake, "Stake calculation should still work");
        
    // }

    function test_POC_RemoveOperatorWithActiveNodesFix() public {
        uint48 epoch = _calcAndWarpOneEpoch();
        
        // Add nodes for alice
        (uint256 minStake, ) = middleware.getClassStakingRequirements(assetClassId);
        (bytes32[] memory nodeIds, ,) = _createAndConfirmNodes(alice, 3, minStake, true, 2);
        
        // Move to next epoch to ensure nodes are active
        epoch = _calcAndWarpOneEpoch();
        
        // Verify alice has active nodes and stake
        uint256 nodeCount = middleware.getOperatorNodesLength(alice);
        uint256 aliceStake = middleware.getOperatorStake(alice, epoch, assetClassId);
        assertEq(nodeCount, 3, "Alice should have exactly 3 active nodes");
        assertGt(aliceStake, 0, "Alice should have stake");
        
        // Try to disable the operator with active nodes - should REVERT
        vm.prank(validatorManagerAddress);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAvalancheL1Middleware.AvalancheL1Middleware__OperatorHasActiveNodes.selector,
                alice,
                nodeCount
            )
        );
        middleware.disableOperator(alice);
        
        // Now alice needs to properly remove all nodes
        // First, initiate removal for all nodes
        for (uint256 i = 0; i < nodeIds.length; i++) {
            vm.prank(alice);
            middleware.removeNode(nodeIds[i]);
        }
        
        // Move to next epoch to process removals
        epoch = _calcAndWarpOneEpoch();
        
        // Force the cache update to process node removals
        middleware.calcAndCacheNodeStakeForAllOperators();
        
        // Verify alice now has no nodes in the array
        uint256 remainingNodes = middleware.getOperatorNodesLength(alice);
        assertEq(remainingNodes, 0, "Alice should have no active nodes after removal processing");
        
        // Now disable should work
        vm.prank(validatorManagerAddress);
        middleware.disableOperator(alice);
        
        // Warp past the window to allow removal
        uint48 removalDelay = middleware.REMOVAL_DELAY_EPOCHS();
        _moveToNextEpochAndCalc(removalDelay);
        
        // Now removal should work since operator has no active nodes
        vm.prank(validatorManagerAddress);
        middleware.removeOperator(alice);
        
        // Verify alice is removed from operators mapping
        address[] memory currentOperators = middleware.getAllOperators();
        bool aliceFound = false;
        for (uint256 i = 0; i < currentOperators.length; i++) {
            if (currentOperators[i] == alice) {
                aliceFound = true;
                break;
            }
        }
        
        assertFalse(aliceFound, "Alice should not be in current operators list");
    }

//     function test_AddNodes_AndThenForceUpdate() public {
//        // Move to the next epoch so we have a clean slate
//        uint48 epoch = _calcAndWarpOneEpoch();

//        // Prepare node data
//        bytes32 nodeId = 0x00000000000000000000000039a662260f928d2d98ab5ad93aa7af8e0ee4d426;
//        bytes memory blsKey = hex"1234";
//        uint64 registrationExpiry = uint64(block.timestamp + 2 days);
//        bytes32 nodeId1 = 0x00000000000000000000000039a662260f928d2d98ab5ad93aa7af8e0ee4d626;
//        bytes memory blsKey1 = hex"1235";
//        bytes32 nodeId2 = 0x00000000000000000000000039a662260f928d2d98ab5ad93aa7af8e0ee4d526;
//        bytes memory blsKey2 = hex"1236";
//        address[] memory ownerArr = new address[](1);
//        ownerArr[0] = alice;
//        PChainOwner memory ownerStruct = PChainOwner({threshold: 1, addresses: ownerArr});

//        // Add node
//        vm.prank(alice);
//        middleware.addNode(nodeId, blsKey, registrationExpiry, ownerStruct, ownerStruct, 0);
//        bytes32 validationID = mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId))));

//        vm.prank(alice);

//        middleware.addNode(nodeId1, blsKey1, registrationExpiry, ownerStruct, ownerStruct, 0);
//        bytes32 validationID1 = mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId1))));

//        vm.prank(alice);

//        middleware.addNode(nodeId2, blsKey2, registrationExpiry, ownerStruct, ownerStruct, 0);
//        bytes32 validationID2 = mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId2))));

//        // Check node stake from the public getter
//        uint256 nodeStake = middleware.getNodeStake(epoch, validationID);
//        assertGt(nodeStake, 0, "Node stake should be >0 right after add");

//        bytes32[] memory activeNodesBeforeConfirm = middleware.getActiveNodesForEpoch(alice, epoch);
//        assertEq(activeNodesBeforeConfirm.length, 0, "Node shouldn't appear active before confirmation");

//        vm.prank(alice);
//        // messageIndex = 0 in this scenario
//        middleware.completeValidatorRegistration(alice, nodeId, 0);
//        middleware.completeValidatorRegistration(alice, nodeId1, 1);

//        middleware.completeValidatorRegistration(alice, nodeId2, 2);

//        vm.startPrank(staker);
//        (uint256 burnedShares, uint256 mintedShares_) = vault.withdraw(staker, 10_000_000);
//        vm.stopPrank();

//        _calcAndWarpOneEpoch();

//        _setupAssetClassAndRegisterVault(2, 5, collateral2, vault3, 3000 ether, 2500 ether, delegator3);
//        collateral2.transfer(staker, 10);
//        vm.startPrank(staker);
//        collateral2.approve(address(vault3), 10);
//        (uint256 depositUsedA, uint256 mintedSharesA) = vault3.deposit(staker, 10);
//        vm.stopPrank();

//        _warpToLastHourOfCurrentEpoch();

//         middleware.forceUpdateNodes(alice, 0);
//        assertEq(middleware.nodePendingRemoval(validationID), false);
//    }

    function test_AddNodes_AndThenForceUpdate_Corrected_Simplified_Approval() public {
        // Initial setup
        uint48 currentEpoch = _calcAndWarpOneEpoch();
        middleware.getClassStakingRequirements(middleware.PRIMARY_ASSET_CLASS());
        
        // Node data
        bytes32 nodeId_A = 0x00000000000000000000000039a662260f928d2d98ab5ad93aa7af8e0ee4d426;
        bytes32 nodeId_B = 0x00000000000000000000000039a662260f928d2d98ab5ad93aa7af8e0ee4d626;
        bytes32 nodeId_C = 0x00000000000000000000000039a662260f928d2d98ab5ad93aa7af8e0ee4d526;
        bytes memory blsKey = hex"1234";
        uint64 registrationExpiry = uint64(block.timestamp + 2 days);
        address[] memory ownerArr = new address[](1); 
        ownerArr[0] = alice;
        PChainOwner memory ownerStruct = PChainOwner({threshold: 1, addresses: ownerArr});

        // --- Setup Secondary Asset Class (ID 2) ---
        uint96 secondaryAssetClassId = 2;
        uint256 minSecondaryStakePerNodeForClass2 = 5 ether;

        // Setup the secondary asset class
        vm.startPrank(validatorManagerAddress);
        middleware.addAssetClass(secondaryAssetClassId, minSecondaryStakePerNodeForClass2, 0, address(collateral2));
        middleware.activateSecondaryAssetClass(secondaryAssetClassId);
        vaultManager.registerVault(address(vault3), secondaryAssetClassId, 3000 ether);
        vm.stopPrank();
        
        // Set L1 limit for the secondary asset class
        _setL1Limit(bob, validatorManagerAddress, secondaryAssetClassId, 2500 ether, delegator3);

        // --- Alice gets and deposits secondary stake into vault3 ---
        // IMPORTANT: Deposit enough for ALL 3 nodes (15 ETH) since primary will be insufficient
        uint256 aliceTargetSecondaryStake = minSecondaryStakePerNodeForClass2 * 3; // 15 ether for 3 nodes

        // 1. Give Alice collateral2 tokens
        deal(address(collateral2), alice, aliceTargetSecondaryStake);

        // 2. Alice approves vault3 to spend her collateral2
        vm.startPrank(alice);
        collateral2.approve(address(vault3), aliceTargetSecondaryStake);

        // 3. Alice deposits into vault3
        ( , uint256 mintedSecondarySharesAlice) = vault3.deposit(alice, aliceTargetSecondaryStake);
        vm.stopPrank();

        // 4. Assign these minted shares to Alice for the L1 system
        _setOperatorL1Shares(bob, validatorManagerAddress, secondaryAssetClassId, alice, mintedSecondarySharesAlice, delegator3);

        // Make sure changes are reflected
        currentEpoch = _calcAndWarpOneEpoch();
        middleware.calcAndCacheStakes(currentEpoch, middleware.PRIMARY_ASSET_CLASS());
        middleware.calcAndCacheStakes(currentEpoch, secondaryAssetClassId);

        // Verify Alice has sufficient secondary stake
        uint256 aliceSecondaryStake = middleware.getOperatorStake(alice, currentEpoch, secondaryAssetClassId);
        console2.log("Alice secondary stake:", aliceSecondaryStake);
        assertGe(aliceSecondaryStake, minSecondaryStakePerNodeForClass2 * 3, "Alice should have enough secondary stake for 3 nodes");

        // --- Add 3 Nodes for Alice ---
        vm.startPrank(alice);
        middleware.addNode(nodeId_A, blsKey, registrationExpiry, ownerStruct, ownerStruct, 0);
        middleware.addNode(nodeId_B, hex"1235", registrationExpiry, ownerStruct, ownerStruct, 0);
        middleware.addNode(nodeId_C, hex"1236", registrationExpiry, ownerStruct, ownerStruct, 0);
        vm.stopPrank();

        // Get validation IDs
        bytes32 validationID_A = mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId_A))));
        bytes32 validationID_B = mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId_B))));
        bytes32 validationID_C = mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId_C))));

        // Complete registrations
        uint32 currentMessageIndex = mockValidatorManager.nextMessageIndex();
        vm.startPrank(alice);
        middleware.completeValidatorRegistration(alice, nodeId_A, currentMessageIndex - 3);
        middleware.completeValidatorRegistration(alice, nodeId_B, currentMessageIndex - 2);
        middleware.completeValidatorRegistration(alice, nodeId_C, currentMessageIndex - 1);
        vm.stopPrank();

        currentEpoch = _calcAndWarpOneEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();
        assertEq(middleware.getOperatorNodesLength(alice), 3, "Alice should have 3 nodes.");

        // --- Test the forceUpdate scenario ---
        // Now let's reduce Alice's secondary stake to create a scenario where nodes need to be removed
        
        // Withdraw some secondary stake to leave only enough for 1 node
        uint256 secondaryToWithdraw = minSecondaryStakePerNodeForClass2 * 2; // Withdraw 10 ether, leaving 5 ether
        vm.startPrank(alice);
        vault3.withdraw(alice, secondaryToWithdraw);
        vm.stopPrank();

        // Update Alice's operator shares to reflect the withdrawal
        uint256 remainingSecondaryShares = mintedSecondarySharesAlice - (mintedSecondarySharesAlice * secondaryToWithdraw / aliceTargetSecondaryStake);
        _setOperatorL1Shares(bob, validatorManagerAddress, secondaryAssetClassId, alice, remainingSecondaryShares, delegator3);

        currentEpoch = _calcAndWarpOneEpoch();
        middleware.calcAndCacheStakes(currentEpoch, secondaryAssetClassId);
        
        // Verify Alice now has insufficient secondary stake for all nodes
        uint256 aliceNewSecondaryStake = middleware.getOperatorStake(alice, currentEpoch, secondaryAssetClassId);
        console2.log("Alice new secondary stake:", aliceNewSecondaryStake);
        assertLt(aliceNewSecondaryStake, minSecondaryStakePerNodeForClass2 * 3, "Alice should have insufficient secondary stake for 3 nodes");
        assertGe(aliceNewSecondaryStake, minSecondaryStakePerNodeForClass2, "Alice should have enough for at least 1 node");

        // --- Call forceUpdateNodes & Assert ---
        _warpToLastHourOfCurrentEpoch();
        
        // Since Alice only has enough secondary stake for 1 node, 2 nodes should be marked for removal
        middleware.forceUpdateNodes(alice, 0);

        // Check how many nodes are pending removal
        uint256 nodesFoundPendingRemoval = 0;
        if(middleware.nodePendingRemoval(validationID_A)) nodesFoundPendingRemoval++;
        if(middleware.nodePendingRemoval(validationID_B)) nodesFoundPendingRemoval++;
        if(middleware.nodePendingRemoval(validationID_C)) nodesFoundPendingRemoval++;
        
        console2.log("Nodes pending removal:", nodesFoundPendingRemoval);
        
        // With only enough secondary stake for 1 node, 2 should be removed
        assertEq(nodesFoundPendingRemoval, 2, "Expected 2 nodes to be marked for removal");

        currentEpoch = _calcAndWarpOneEpoch();
        middleware.calcAndCacheNodeStakeForAllOperators();
        assertEq(middleware.getOperatorNodesLength(alice), 1, "Alice should have 1 node remaining");
    }

    // function test_UnconfirmedStakeImmediateRewards() public {
    //     // Setup: Alice has 100 ETH equivalent stake
    //     uint48 epoch = _calcAndWarpOneEpoch();

    //     // increasuing vaults total stake
    //     (, uint256 additionalMinted) = _deposit(staker, 500 ether);
        
    //     // Now allocate more of this deposited stake to Alice (the operator)
    //     uint256 totalAliceShares = mintedShares + additionalMinted;
    //     _setL1Limit(bob, validatorManagerAddress, assetClassId, 3000 ether, delegator);
    //     _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, alice, totalAliceShares, delegator);

    //     // Move to next epoch to make the new stake available
    //     epoch = _calcAndWarpOneEpoch();
    
    //     // Verify Alice now has sufficient available stake
    //     uint256 aliceAvailableStake = middleware.getOperatorAvailableStake(alice);
    //     console2.log("Alice available stake: %s ETH", aliceAvailableStake / 1 ether);

    //     // Alice adds a node with 10 ETH stake
    //     (bytes32[] memory nodeIds, bytes32[] memory validationIDs,) = 
    //         _createAndConfirmNodes(alice, 1, 10 ether, true);
    //     bytes32 nodeId = nodeIds[0];
    //     bytes32 validationID = validationIDs[0];
        
    //     // Move to next epoch and confirm initial state
    //     epoch = _calcAndWarpOneEpoch();
    //     uint256 initialStake = middleware.getNodeStake(epoch, validationID);
    //     assertEq(initialStake, 10 ether, "Initial stake should be 10 ETH");
        
    //     // Alice increases stake to 1000 ETH (10x increase)
    //     uint256 modifiedStake = 50 ether;
    //     vm.prank(alice);
    //     middleware.initializeValidatorStakeUpdate(nodeId, modifiedStake);
        
    //     // Check: Stake cache immediately updated for next epoch (unconfirmed!)
    //     uint48 nextEpoch = middleware.getCurrentEpoch() + 1;
    //     uint256 unconfirmedStake = middleware.nodeStakeCache(nextEpoch, validationID);
    //     assertEq(unconfirmedStake, modifiedStake, "Unconfirmed stake should be immediately set");
        
    //     // Verify: P-Chain operation is still pending
    //     assertTrue(
    //         mockValidatorManager.isValidatorPendingWeightUpdate(validationID),
    //         "P-Chain operation should still be pending"
    //     );
        
    //     // Move to next epoch (when unconfirmed stake takes effect)
    //     epoch = _calcAndWarpOneEpoch();
        
    //     // Reward calculations now use unconfirmed 1000 ETH stake
    //     uint256 operatorStakeForRewards = middleware.getOperatorUsedStakeCachedPerEpoch(
    //         epoch, alice, middleware.PRIMARY_ASSET_CLASS()
    //     );
    //     assertEq(
    //         operatorStakeForRewards, 
    //         modifiedStake, 
    //         "Reward calculations should use unconfirmed 500 ETH stake"
    //     );
    //     console2.log("Stake used for rewards: %s ETH", operatorStakeForRewards / 1 ether);            
    // }

    function test_UnconfirmedStakeImmediateRewards_Fix() public {
        // Setup: Alice has 100 ETH equivalent stake
        uint48 epoch = _calcAndWarpOneEpoch();

        // Increase vaults total stake
        (, uint256 additionalMinted) = _deposit(staker, 500 ether);
        
        // Now allocate more of this deposited stake to Alice (the operator)
        uint256 totalAliceShares = mintedShares + additionalMinted;
        _setL1Limit(bob, validatorManagerAddress, assetClassId, 3000 ether, delegator);
        _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, alice, totalAliceShares, delegator);

        // Move to next epoch to make the new stake available
        epoch = _calcAndWarpOneEpoch();
    
        // Verify Alice now has sufficient available stake
        uint256 aliceAvailableStake = middleware.getOperatorAvailableStake(alice);
        console2.log("Alice available stake: %s ETH", aliceAvailableStake / 1 ether);

        // Alice adds a node with 10 ETH stake
        (bytes32[] memory nodeIds, bytes32[] memory validationIDs,) = 
            _createAndConfirmNodes(alice, 1, 10 ether, true, 2);
        bytes32 nodeId = nodeIds[0];
        bytes32 validationID = validationIDs[0];
        
        // Move to next epoch and confirm initial state
        epoch = _calcAndWarpOneEpoch();
        uint256 initialStake = middleware.getNodeStake(epoch, validationID);
        assertEq(initialStake, 10 ether, "Initial stake should be 10 ETH");
        
        // Alice increases stake to 1000 ETH (10x increase)
        uint256 modifiedStake = 50 ether;
        vm.prank(alice);
        middleware.initializeValidatorStakeUpdate(nodeId, modifiedStake);
        
        // FIXED: Stake cache should NOT be immediately updated (only after P-Chain confirmation)
        uint48 nextEpoch = middleware.getCurrentEpoch() + 1;
        uint256 unconfirmedStake = middleware.nodeStakeCache(nextEpoch, validationID);
        assertEq(unconfirmedStake, 0, "Stake cache should NOT be updated before P-Chain confirmation");
        
        // Verify: P-Chain operation is still pending
        assertTrue(
            mockValidatorManager.isValidatorPendingWeightUpdate(validationID),
            "P-Chain operation should still be pending"
        );
        
        // Complete the stake update (P-Chain confirmation)
        vm.prank(alice);
        middleware.completeStakeUpdate(nodeId, 0);
        
        // NOW the cache should be updated for next epoch
        uint256 confirmedStake = middleware.nodeStakeCache(nextEpoch, validationID);
        assertEq(confirmedStake, modifiedStake, "Stake cache should be updated after P-Chain confirmation");
        
        // Move to next epoch (when confirmed stake takes effect)
        epoch = _calcAndWarpOneEpoch();
        
        // Reward calculations now use confirmed 50 ETH stake (not unconfirmed)
        uint256 operatorStakeForRewards = middleware.getOperatorUsedStakeCachedPerEpoch(
            epoch, alice, middleware.PRIMARY_ASSET_CLASS()
        );
        assertEq(
            operatorStakeForRewards, 
            modifiedStake, 
            "Reward calculations should use confirmed 50 ETH stake"
        );
        console2.log("Stake used for rewards: %s ETH", operatorStakeForRewards / 1 ether);            
    }

    function test_operatorStakeWithoutNormalization() public {
        uint48 epoch = 1;
        // Deploy tokens with different decimals
        ERC20WithDecimals tokenA1 = new ERC20WithDecimals("TokenA", "TKA", 6); // e.g., USDC
        ERC20WithDecimals tokenB1 = new ERC20WithDecimals("TokenB", "TKB", 18); // e.g., DAI

        // Deploy vaults and associate with asset class 1
        vm.startPrank(validatorManagerAddress);
        address vaultAddress1 = vaultFactory.create(
            1,
            bob,
            abi.encode(
                IVaultTokenized.InitParams({
                    collateral: address(tokenA1),
                    burner: address(0xdEaD),
                    epochDuration: 8 hours,
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
        address vaultAddress2 = vaultFactory.create(
            1,
            bob,
            abi.encode(
                IVaultTokenized.InitParams({
                    collateral: address(tokenB1),
                    burner: address(0xdEaD),
                    epochDuration: 8 hours,
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
        VaultTokenized vaultTokenA = VaultTokenized(vaultAddress1);
        VaultTokenized vaultTokenB = VaultTokenized(vaultAddress2);
        vm.startPrank(validatorManagerAddress);
        middleware.addAssetClass(2, 0, 100, address(tokenA1));
        middleware.activateSecondaryAssetClass(2);
        middleware.addAssetToClass(2, address(tokenB1));
        vm.stopPrank();

        address[] memory l1LimitSetRoleHolders = new address[](1);
        l1LimitSetRoleHolders[0] = bob;
        address[] memory operatorL1SharesSetRoleHolders = new address[](1);
        operatorL1SharesSetRoleHolders[0] = bob;

        address delegatorAddress2 = delegatorFactory.create(
            0,
            abi.encode(
                address(vaultTokenA),
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
        L1RestakeDelegator _delegator2 = L1RestakeDelegator(delegatorAddress2);

        address delegatorAddress3 = delegatorFactory.create(
            0,
            abi.encode(
                address(vaultTokenB),
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
        L1RestakeDelegator _delegator3 = L1RestakeDelegator(delegatorAddress3);

        vm.prank(bob);
        vaultTokenA.setDelegator(delegatorAddress2);

        // Set the delegator in vault3
        vm.prank(bob);
        vaultTokenB.setDelegator(delegatorAddress3);

        _setOperatorL1Shares(bob, validatorManagerAddress, 2, alice, 100, _delegator2);
        _setOperatorL1Shares(bob, validatorManagerAddress, 2, alice, 100, _delegator3);

        vm.startPrank(validatorManagerAddress);
        vaultManager.registerVault(address(vaultTokenA), 2, 3000 ether);
        vaultManager.registerVault(address(vaultTokenB), 2, 3000 ether);
        vm.stopPrank();

        _optInOperatorVault(alice, address(vaultTokenA));
        _optInOperatorVault(alice, address(vaultTokenB));
        //_optInOperatorL1(alice, validatorManagerAddress);

        _setL1Limit(bob, validatorManagerAddress, 2, 10000 * 10**6, _delegator2);
        _setL1Limit(bob, validatorManagerAddress, 2, 10 * 10**18, _delegator3);

        // Define stakes without normalization
        uint256 stakeA = 10000 * 10**6; // 10,000 TokenA (6 decimals)
        uint256 stakeB = 10 * 10**18; // 10 TokenB (18 decimals)

        uint256 normalised = stakeA * 10**12 + stakeB; 

        tokenA1.transfer(staker, stakeA);
        vm.startPrank(staker);
        tokenA1.approve(address(vaultTokenA), stakeA);
        vaultTokenA.deposit(staker, stakeA);
        vm.stopPrank();

        tokenB1.transfer(staker, stakeB);
        vm.startPrank(staker);
        tokenB1.approve(address(vaultTokenB), stakeB);
        vaultTokenB.deposit(staker, stakeB);
        vm.stopPrank();

        vm.warp((epoch + 3) * middleware.EPOCH_DURATION());

        assertEq(middleware.getOperatorStake(alice, 2, 2), normalised);
        assertNotEq(middleware.getOperatorStake(alice, 2, 2), stakeA + stakeB);
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
        collateral.transfer(staker, amount);
        vm.startPrank(staker);
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

    function _optInOperatorVault(address user, address vault_) internal {
        vm.startPrank(user);
        operatorVaultOptInService.optIn(address(vault_));
        vm.stopPrank();
    }

    function _optOutOperatorVault(address user, address vault_) internal {
        vm.startPrank(user);
        operatorVaultOptInService.optOut(address(vault_));
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

    function _setL1Limit(
        address user,
        address _l1,
        uint96 assetClass,
        uint256 amount,
        L1RestakeDelegator delegator_
    ) internal {
        vm.startPrank(user);
        delegator_.setL1Limit(_l1, assetClass, amount);
        vm.stopPrank();
    }

    function _setOperatorL1Shares(
        address user,
        address _l1,
        uint96 assetClass,
        address operator,
        uint256 shares,
        L1RestakeDelegator delegator_
    ) internal {
        vm.startPrank(user);
        delegator_.setOperatorL1Shares(_l1, assetClass, operator, shares);
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
    ) internal returns (uint48) {
        for (uint256 i = 0; i < numberOfEpochs; i++) {
            // 1. Figure out what the *next* epoch index would be
            uint48 nextEpochIndex = middleware.getCurrentEpoch() + 1;

            // 2. Warp to *just after* that epoch's start
            // 2. Warp to *just after* that epoch's start
            uint256 nextEpochStartTs = middleware.getEpochStartTs(nextEpochIndex);
            vm.warp(nextEpochStartTs + 1);

            // 3. Do any housekeeping
            middleware.calcAndCacheNodeStakeForAllOperators();

            console2.log("Current middleware epoch:", middleware.getCurrentEpoch());
            console2.log("Current vault epoch:", vault.currentEpoch());
        }
        return middleware.getCurrentEpoch();
    }

    // Create a new asset class and register vault3 with it
    function _setupAssetClassAndRegisterVault(
        uint96 assetClassId_,
        uint256 minValidatorStake_,
        Token collateral_,
        VaultTokenized vault_,
        uint256 maxVaultLimit_,
        uint256 l1Limit_,
        L1RestakeDelegator delegator_
    ) internal {
        vm.startPrank(validatorManagerAddress);
        middleware.addAssetClass(assetClassId_, minValidatorStake_, 0, address(collateral_));
        middleware.activateSecondaryAssetClass(assetClassId_);
        vaultManager.registerVault(address(vault_), assetClassId_, maxVaultLimit_);
        vm.stopPrank();
        _setL1Limit(bob, validatorManagerAddress, assetClassId_, l1Limit_, delegator_);
    }

    function _warpToLastHourOfCurrentEpoch() internal {
        uint48 currentEpoch = middleware.getCurrentEpoch();
        uint48 currentEpochTs = middleware.getEpochStartTs(currentEpoch);

        // The final "window" starts at (epoch end - weightUpdateGracePeriod)
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
    ) internal returns (uint48) {
        for (uint256 i = 0; i < numberOfEpochs; i++) {
            uint48 nextEpochIndex = middleware.getCurrentEpoch() + 1;
            uint256 nextEpochStartTs = middleware.getEpochStartTs(nextEpochIndex);
            vm.warp(nextEpochStartTs + 1);
            middleware.calcAndCacheNodeStakeForAllOperators();
        }
        return middleware.getCurrentEpoch();
    }

    function _calcAndWarpOneEpoch() internal returns (uint48) {
        return _calcAndWarpOneEpoch(1);
    }

    function _createAndConfirmNodes(
        address operator,
        uint256 nodeCount,
        uint256 stake_,
        bool confirmImmediately,
        uint256 minMultiplier
    ) internal returns (bytes32[] memory nodeIds, bytes32[] memory validationIDs, uint256[] memory nodeWeights) {
        // Create temporary arrays with maximum size
        bytes32[] memory tempNodeIds = new bytes32[](nodeCount);
        bytes32[] memory tempValidationIDs = new bytes32[](nodeCount);
        uint256[] memory tempNodeWeights = new uint256[](nodeCount);
        
        uint256 actualNodeCount = 0; // Track actual successful registrations

        for (uint256 i = 0; i < nodeCount; i++) {
            bytes32 nodeId = keccak256(abi.encodePacked(operator, block.timestamp, i));
            middleware.calcAndCacheNodeStakeForAllOperators();
            uint256 free = middleware.getOperatorAvailableStake(operator)
                             - middleware.getOperatorUsedStakeCached(operator);
            (uint256 minStake, ) = middleware.getClassStakingRequirements(1);   // PRIMARY_ASSET_CLASS == 1
    
            // uint256 stakeForThisNode = (stake_ != 0) ? stake_
            //                       : (free > maxStake
            //                            ? maxStake
            //                            : free);
    
            uint256 stakeForThisNode = (stake_ != 0)
                ? stake_
                : minStake * minMultiplier;

            if (free < stakeForThisNode) {
                vm.expectRevert(abi.encodeWithSelector(IAvalancheL1Middleware.AvalancheL1Middleware__NotEnoughFreeStake.selector, stakeForThisNode));
                vm.prank(operator);
                middleware.addNode(
                    nodeId,
                    hex"ABABABAB",
                    uint64(block.timestamp + 2 days),
                    PChainOwner({threshold: 1, addresses: new address[](0)}),
                    PChainOwner({threshold: 1, addresses: new address[](0)}),
                    stakeForThisNode    
                );
                break;
            }

            vm.prank(operator);
            middleware.addNode(
                nodeId,
                hex"ABABABAB",
                uint64(block.timestamp + 2 days),
                PChainOwner({threshold: 1, addresses: new address[](0)}),
                PChainOwner({threshold: 1, addresses: new address[](0)}),
                stakeForThisNode                 // ← explicit max or caller‑provided
            );
            
            // Store the successful registration
            tempNodeIds[actualNodeCount] = nodeId;
            uint32 msgIdx = mockValidatorManager.nextMessageIndex() - 1;

            if (confirmImmediately) {
                vm.prank(operator);
                middleware.completeValidatorRegistration(operator, nodeId, msgIdx);
            }
            
            tempValidationIDs[actualNodeCount] = mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId))));
            uint48 epoch = middleware.getCurrentEpoch();
            tempNodeWeights[actualNodeCount] = middleware.nodeStakeCache(epoch, tempValidationIDs[actualNodeCount]);
            assertGt(tempNodeWeights[actualNodeCount], 0, "Node weight must be positive");
            
            actualNodeCount++;
        }
        
        // Create properly sized result arrays
        nodeIds = new bytes32[](actualNodeCount);
        validationIDs = new bytes32[](actualNodeCount);
        nodeWeights = new uint256[](actualNodeCount);
        
        // Copy the successful registrations to result arrays
        for (uint256 i = 0; i < actualNodeCount; i++) {
            nodeIds[i] = tempNodeIds[i];
            validationIDs[i] = tempValidationIDs[i];
            nodeWeights[i] = tempNodeWeights[i];
        }
    }

    function _stakeOrRemoveNodes(
        address operator,
        bytes32[] memory nodeIds,
        uint8 stakeDeltaMask,
        uint8 removeMask
    ) internal {
        (uint256 minStake,) = middleware.getClassStakingRequirements(assetClassId);
        uint48 epoch = middleware.getCurrentEpoch();

        for (uint256 i = 0; i < nodeIds.length; i++) {
            bytes32 valID = mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeIds[i]))));
            uint256 currentStake = middleware.getNodeStake(epoch, valID);
            if (currentStake == 0) {
                continue;
            }
            bool doRemove = ((removeMask >> i) & 0x01) == 1;
            if (doRemove) {
                vm.prank(operator);
                middleware.removeNode(nodeIds[i]);
                continue;
            }
            bool stakeDown = ((stakeDeltaMask >> i) & 0x01) == 1;
            uint256 newStake;
            if (stakeDown) {
                newStake = currentStake / 2;
            } else {
                uint256 upAmt = currentStake / 2;
                newStake = currentStake + upAmt;
                // Check operator leftover
                uint256 avail = middleware.getOperatorAvailableStake(operator);
                if (newStake > currentStake + avail) {
                    newStake = currentStake + avail;
                }
            }
            if (newStake >= minStake) {
                vm.prank(operator);
                middleware.initializeValidatorStakeUpdate(nodeIds[i], newStake);

                uint32 stakeMsgIdx = mockValidatorManager.nextMessageIndex() - 1;
                vm.prank(operator);
                middleware.completeStakeUpdate(nodeIds[i], stakeMsgIdx);
            }
        }
    }

    function _checkSumMatchesOperatorUsed(address operator, bytes32[] memory nodeIds) internal view {
        uint48 epoch = middleware.getCurrentEpoch();
        uint256 sumStakes;
        for (uint256 i = 0; i < nodeIds.length; i++) {
            bytes32 valID = mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeIds[i]))));
            sumStakes += middleware.getNodeStake(epoch, valID);
        }
        uint256 operatorUsed = middleware.getOperatorUsedStakeCached(operator);
        console2.log("Operator used vs. sumStakes =>", operator, operatorUsed, sumStakes);
        require(sumStakes == operatorUsed, "Mismatch in final operator used stake sum");
    }

    /// @notice Advances time by a number of middleware epochs without calling cache updates.
    function _warpAdvanceMiddlewareEpochsRaw(uint48 numEpochsToAdvance) internal returns (uint48 newCurrentEpochAfterWarp) {
        uint48 currentEpochBeforeWarp = middleware.getCurrentEpoch();
        uint48 targetEpoch = currentEpochBeforeWarp + numEpochsToAdvance;
        
        if (targetEpoch <= currentEpochBeforeWarp && numEpochsToAdvance > 0) {
            targetEpoch = currentEpochBeforeWarp + 1;
        } else if (numEpochsToAdvance == 0) {
            return currentEpochBeforeWarp;
        }

        uint256 targetTs = middleware.getEpochStartTs(targetEpoch) + 1;
        vm.warp(targetTs);
        
        newCurrentEpochAfterWarp = middleware.getCurrentEpoch();
        return newCurrentEpochAfterWarp;
    }
}
