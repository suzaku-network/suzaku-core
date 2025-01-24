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

    function setUp() public {
        owner = address(this);
        (alice, alicePrivateKey) = makeAddrAndKey("alice");
        (bob, bobPrivateKey) = makeAddrAndKey("bob");
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

        validatorManagerAddress =
            _deployValidatorManager(validatorSettings, proxyAdminOwnerAddress, protocolOwnerAddress);

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

        // Deploy vaultTokenized
        uint48 epochDuration = 1 days;
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

        vault = VaultTokenized(vaultAddress);

        // Deploy delegator
        address[] memory l1LimitSetRoleHolders = new address[](1);
        l1LimitSetRoleHolders[0] = alice;
        address[] memory operatorL1SharesSetRoleHolders = new address[](1);
        operatorL1SharesSetRoleHolders[0] = alice;

        address delegatorAddress = delegatorFactory.create(
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
        );

        delegator = L1RestakeDelegator(delegatorAddress);

        // Set the delegator in the vault
        vault.setDelegator(delegatorAddress);

        // Deploy the middleware
        AvalancheL1MiddlewareSettings memory middlewareSettings = AvalancheL1MiddlewareSettings({
            l1ValidatorManager: address(validatorManagerAddress),
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

        middleware.transferOwnership(address(validatorManagerAddress));
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

        _registerL1(address(validatorManagerAddress), address(middleware));

        vm.startPrank(address(validatorManagerAddress)); // Check if this should change
        middleware.registerVault(address(vault), assetClassId, maxVaultL1Limit);
        vm.stopPrank();
    }

    function test_RegisterOperator() public {
        _registerL1(address(validatorManagerAddress), address(middleware));
        _registerOperator(alice, "metadata");
        _optInOperatorL1(alice, validatorManagerAddress);

        uint256 maxNodeStake = 900_000_000_000_000_000_000;
        uint256 minNodeStake = 110_000_000_000_000;

        vm.startPrank(address(validatorManagerAddress));

        middleware.registerOperator(alice, keccak256("myPubKey"), maxNodeStake, minNodeStake);
        vm.stopPrank();
    }

    function test_DepositAndGetOperatorStake() public {
        uint96 assetClassId = 1;
        uint256 maxVaultL1Limit = 2000 ether;
        // middleware.addAssetToClass(1, address(collateral));

        _registerL1(address(validatorManagerAddress), address(middleware));

        vm.startPrank(address(validatorManagerAddress));
        middleware.registerVault(address(vault), assetClassId, maxVaultL1Limit);
        vm.stopPrank();

        _grantDepositorWhitelistRole(alice, alice);
        (uint256 depositedAmount, uint256 mintedShares) = _deposit(alice, 500 ether);

        _setL1Limit(alice, middleware.L1_VALIDATOR_MANAGER(), assetClassId, depositedAmount);

        _registerOperator(bob, "bob metadata");
        _optInOperatorVault(bob);
        _optInOperatorL1(bob, validatorManagerAddress);

        vm.startPrank(alice);
        delegator.setOperatorL1Shares(middleware.L1_VALIDATOR_MANAGER(), assetClassId, bob, mintedShares);
        vm.stopPrank();

        uint48 epoch = middleware.getCurrentEpoch();
        uint256 stakeBob = middleware.getOperatorStake(bob, epoch, assetClassId);
        console2.log("Bob stake:", stakeBob);
        assertGt(stakeBob, 0, "Bob's stake should be > 0 now");
    }

    // Internal helpers
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
