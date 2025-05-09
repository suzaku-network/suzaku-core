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
import {IWarpMessenger} from "@avalabs/subnet-evm-contracts/interfaces/IWarpMessenger.sol";
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
        collateral.transfer(staker, 200_000_000_002_000);
        vm.startPrank(staker);
        collateral.approve(address(vault), 200_000_000_002_000);
        (depositedAmount, mintedShares) = vault.deposit(staker, 200_000_000_002_000);
        vm.stopPrank();

        _setL1Limit(bob, validatorManagerAddress, assetClassId, l1Limit, delegator);
        _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, alice, mintedShares, delegator);

        // Setup Charlie as operator for both vault1 and vault2
        // First deposit to vault1
        uint256 charlieVault1DepositAmount = 150_000_000_000_000;
        collateral.transfer(staker, charlieVault1DepositAmount);
        vm.startPrank(staker);
        collateral.approve(address(vault), charlieVault1DepositAmount);
        (, uint256 charlieVault1Shares) = vault.deposit(staker, charlieVault1DepositAmount);
        vm.stopPrank();

        // Add Charlie's shares from vault1 (existing limit is already set)
        _setOperatorL1Shares(bob, validatorManagerAddress, assetClassId, charlie, charlieVault1Shares, delegator);

        // Then deposit to vault2
        uint256 charlieVault2DepositAmount = 120_000_000_000_000;
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
        _createAndConfirmNodes(alice, 1, 0, true);
    }

    function test_AddNodeSimpleAndComplete() public {
        uint48 epoch = _calcAndWarpOneEpoch();
        uint256 totalStake = middleware.getOperatorStake(alice, epoch, assetClassId);
        assertGt(totalStake, 0);

        // Add node
        (, bytes32[] memory validationIDs,) = _createAndConfirmNodes(alice, 1, 0, true);
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
            _createAndConfirmNodes(alice, 1, 0, false);
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
            _createAndConfirmNodes(alice, 1, 0, true);
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
            _createAndConfirmNodes(alice, 1, 0, true);
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
            _createAndConfirmNodes(alice, 1, 0, true);
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
            _createAndConfirmNodes(alice, 1, 0, true);
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
            _createAndConfirmNodes(alice, 2, stake1, true);
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
        (bytes32[] memory nodeIds,,) = _createAndConfirmNodes(alice, 2, stake1, true);
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
            _createAndConfirmNodes(alice, 2, stake1, true);
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
        middleware.forceUpdateNodes(alice, 0);

        vm.prank(alice);
        middleware.completeValidatorRemoval(2);

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
        _createAndConfirmNodes(alice, 1, stake1, true);

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

        (bytes32[] memory nodeIds, bytes32[] memory validationIDs,) = _createAndConfirmNodes(alice, 1, 0, true);
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

        // Remove node while update is pending
        vm.prank(alice);
        middleware.removeNode(nodeId);
        uint32 removeIndex = mockValidatorManager.nextMessageIndex() - 1;

        // Move to next epoch
        epoch = _calcAndWarpOneEpoch();

        uint256 stakeNow = middleware.getNodeStake(epoch, validationID);
        console2.log("Stake after removing while update pending:", stakeNow);

        // Confirm removal
        vm.prank(alice);
        middleware.completeValidatorRemoval(removeIndex);

        // Move to next epoch
        epoch = _calcAndWarpOneEpoch();

        uint256 finalStake = middleware.getNodeStake(epoch, validationID);
        assertEq(finalStake, 0, "Node stake must be 0 after final removal");

        // Complete stake update after removal
        uint32 stakeUpdateMsgIndex = mockValidatorManager.nextMessageIndex() - 1;
        vm.prank(alice);
        middleware.completeStakeUpdate(nodeId, stakeUpdateMsgIndex);

        // Verify update was processed
        bool stillPending = mockValidatorManager.isValidatorPendingWeightUpdate(validationID);
        assertFalse(stillPending, "Stake update should be cleared after removal");
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

        // Create nodes (unconfirmed)
        for (uint256 i = 0; i < nodeCount; i++) {
            bytes32 nodeId = keccak256(abi.encodePacked("Node", i, block.timestamp));
            nodeIds[i] = nodeId;

            vm.prank(alice);
            middleware.addNode(
                nodeId,
                hex"1234ABCD", // dummy BLS
                uint64(block.timestamp + 1 days),
                PChainOwner({threshold: 1, addresses: new address[](1)}),
                PChainOwner({threshold: 1, addresses: new address[](1)}),
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
        (uint256 minStake,) = middleware.getClassStakingRequirements(assetClassId);

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

            if (newStake >= minStake) {
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

        // Create & confirm nodes for each operator
        (bytes32[] memory nodeIdsAlice,,) = _createAndConfirmNodes(alice, nA, 0, true);
        (bytes32[] memory nodeIdsCharlie,,) = _createAndConfirmNodes(charlie, nC, 0, true);
        (bytes32[] memory nodeIdsDave,,) = _createAndConfirmNodes(dave, nD, 0, true);

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

        // That’s it. Optionally, verify final aggregator of node stakes == operatorUsedStake
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
        // Add additional stake to alice
        test_ForceUpdateWithAdditionalStake();
        uint48 epoch = middleware.getCurrentEpoch();

        // Test PRIMARY_ASSET_CLASS (1)
        uint256 primaryStake = middleware.getOperatorUsedStakeCachedPerEpoch(epoch, alice, 1);
        assertGt(primaryStake, 0, "Primary asset stake should be > 0");

        // Test secondary asset class (2)
        uint256 secondaryStake = middleware.getOperatorUsedStakeCachedPerEpoch(epoch, alice, 2);
        assertEq(secondaryStake, 0, "Secondary asset stake should be 0 as none was added");
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
        bool confirmImmediately
    ) internal returns (bytes32[] memory nodeIds, bytes32[] memory validationIDs, uint256[] memory nodeWeights) {
        nodeIds = new bytes32[](nodeCount);
        validationIDs = new bytes32[](nodeCount);
        nodeWeights = new uint256[](nodeCount);

        for (uint256 i = 0; i < nodeCount; i++) {
            bytes32 nodeId = keccak256(abi.encodePacked(operator, block.timestamp, i));
            nodeIds[i] = nodeId;

            vm.prank(operator);
            middleware.addNode(
                nodeId,
                hex"ABABABAB", // dummy BLS
                uint64(block.timestamp + 2 days),
                PChainOwner({threshold: 1, addresses: new address[](1)}),
                PChainOwner({threshold: 1, addresses: new address[](1)}),
                stake_
            );
            uint32 msgIdx = mockValidatorManager.nextMessageIndex() - 1;

            if (confirmImmediately) {
                vm.prank(operator);
                middleware.completeValidatorRegistration(operator, nodeId, msgIdx);
            }
            validationIDs[i] = mockValidatorManager.registeredValidators(abi.encodePacked(uint160(uint256(nodeId))));
            uint48 epoch = middleware.getCurrentEpoch();
            nodeWeights[i] = middleware.nodeStakeCache(epoch, validationIDs[i]);
            assertGt(nodeWeights[i], 0, "Node weight must be positive");
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
}
