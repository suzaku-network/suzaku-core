// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ValidatorManager, ValidatorManagerSettings} from "@avalabs/icm-contracts/validator-manager/ValidatorManager.sol";
import {PoAManager} from "@avalabs/icm-contracts/validator-manager/PoAManager.sol";
import {IValidatorManagerExternalOwnable} from "@avalabs/icm-contracts/validator-manager/interfaces/IValidatorManagerExternalOwnable.sol";
import {UnsafeUpgrades} from "@openzeppelin/foundry-upgrades/Upgrades.sol";
import {ICMInitializable} from "@avalabs/icm-contracts/utilities/ICMInitializable.sol";
import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";

import {
    AvalancheL1Middleware,
    AvalancheL1MiddlewareSettings
} from "../../src/contracts/middleware/AvalancheL1Middleware.sol";
import {MiddlewareVaultManager} from "../../src/contracts/middleware/MiddlewareVaultManager.sol";
import {CollateralClassRegistry} from "../../src/contracts/middleware/CollateralClassRegistry.sol";
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
import {MockWarpMessenger} from "../mocks/MockWarpMessenger.sol";
import {DeployBalancerValidatorManager} from "lib/suzaku-contracts-library/script/ValidatorManager/DeployBalancerValidatorManager.s.sol";

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
    ValidatorStatus
} from "@avalabs/icm-contracts/validator-manager/interfaces/IACP99Manager.sol";
import {ValidatorMessages} from "@avalabs/icm-contracts/validator-manager/ValidatorMessages.sol";
import {IWarpMessenger, WarpMessage} from "@avalabs/subnet-evm-contracts@1.2.0/contracts/interfaces/IWarpMessenger.sol";

import {Token} from "../mocks/MockToken.sol";
import {ERC20WithDecimals} from "../mocks/MockERC20WithDecimals.sol";

import {IBaseDelegator} from "../../src/interfaces/delegator/IBaseDelegator.sol";
import {IOperatorRegistry} from "../../src/interfaces/IOperatorRegistry.sol";
import {IVaultTokenized} from "../../src/interfaces/vault/IVaultTokenized.sol";
import {IL1RestakeDelegator} from "../../src/interfaces/delegator/IL1RestakeDelegator.sol";
import {IAvalancheL1Middleware} from "../../src/interfaces/middleware/IAvalancheL1Middleware.sol";
import {StakeConversion} from "../../src/contracts/middleware/libraries/StakeConversion.sol";
import {IMiddlewareVaultManager} from "../../src/interfaces/middleware/IMiddlewareVaultManager.sol";

abstract contract MiddlewareTestBase is Test {
    // Constants
    address constant WARP = 0x0200000000000000000000000000000000000005;
    
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
    uint96 internal collateralClassId;
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
    // Real ValidatorManager stack addresses
    address internal balancer;      // BalancerValidatorManager proxy
    address internal validatorManager;  // ValidatorManager proxy  
    address internal secModule;     // PoASecurityModule
    


    function setUp() public virtual {
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
            address primaryCollateral,
            uint256 primaryCollateralMaxStake,
            uint256 primaryCollateralMinStake,
            uint256 primaryCollateralWeightScaleFactor
        ) = helperConfig.activeNetworkConfig();

        // Deploy real ValidatorManager + Balancer + SecurityModule
        DeployBalancerValidatorManager deployScript = new DeployBalancerValidatorManager();
        // Balancer requires at least one migrated validator – use two known 20-byte NodeIDs
        bytes[] memory migrated = new bytes[](2);
        migrated[0] = hex"2345678123456781234567812345678123456781";
        migrated[1] = hex"3456781234567812345678123456781234567812";
        (balancer, secModule, validatorManager) = 
            deployScript.run(address(0), /* initialSecModMaxWeight */ uint64(18 ether), migrated);

        // AFTER deploy script finishes (it installs its own test messenger internally),
        // override the canonical warp messenger with our push-style test messenger:
        {
            MockWarpMessenger messenger = new MockWarpMessenger();
            address WARP_MESSENGER_ADDR = WARP;
            vm.etch(WARP_MESSENGER_ADDR, address(messenger).code);
        }
        
        // The "L1 address" the rest of this test suite uses
        validatorManagerAddress = balancer;

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
        primaryCollateral = address(collateral);

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
            primaryCollateral,
            primaryCollateralMaxStake,
            primaryCollateralMinStake,
            primaryCollateralWeightScaleFactor
        );

        vaultManager = new MiddlewareVaultManager(address(vaultFactory), owner, address(middleware), 24); // 24 epoch delay
        // middleware.addCollateralClass(2, primaryCollateralMinStake, primaryCollateralMaxStake);
        // middleware.activateSecondaryCollateralClass(0);

        // Set the vault manager in the middleware
        middleware.setVaultManager(address(vaultManager));

        middleware.transferOwnership(validatorManagerAddress);
        vaultManager.transferOwnership(validatorManagerAddress);

        // Setup middleware as a security module on the Balancer
        // Note: The deployment script sets up an initial security module, but we need to add middleware
        {
            address balOwner = BalancerValidatorManager(balancer).owner();
            uint64 maxWeight = uint64(1_000_000_000); // 1e9 weight cap (>> enough for tests)
            vm.prank(balOwner);
            BalancerValidatorManager(balancer).setUpSecurityModule(address(middleware), maxWeight);
        }

        // The real stack handles ownership during deployment

        // Give validatorManager some ETH to pay the registration fee
        vm.deal(validatorManagerAddress, 1 ether);

        _registerL1(validatorManagerAddress, address(middleware));
        collateralClassId = 1;
        maxVaultL1Limit = 3000 ether;

        vm.startPrank(validatorManagerAddress);
        vaultManager.registerVault(address(vault), collateralClassId, maxVaultL1Limit);
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

        _setL1Limit(bob, validatorManagerAddress, collateralClassId, l1Limit, delegator);
        _setOperatorL1Shares(bob, validatorManagerAddress, collateralClassId, alice, mintedShares, delegator);

        // Setup Charlie as operator for both vault1 and vault2
        // First deposit to vault1
        uint256 charlieVault1DepositAmount = 250_000_000_000_000;
        collateral.transfer(staker, charlieVault1DepositAmount);
        vm.startPrank(staker);
        collateral.approve(address(vault), charlieVault1DepositAmount);
        (, uint256 charlieVault1Shares) = vault.deposit(staker, charlieVault1DepositAmount);
        vm.stopPrank();

        // Add Charlie's shares from vault1 (existing limit is already set)
        _setOperatorL1Shares(bob, validatorManagerAddress, collateralClassId, charlie, charlieVault1Shares, delegator);

        // Then deposit to vault2
        uint256 charlieVault2DepositAmount = 220_000_000_000_000;
        collateral.transfer(staker, charlieVault2DepositAmount);
        vm.startPrank(staker);
        collateral.approve(address(vault2), charlieVault2DepositAmount);
        (, uint256 charlieVault2Shares) = vault2.deposit(staker, charlieVault2DepositAmount);
        vm.stopPrank();

        // Set L1 shares for Charlie from vault2
        _setOperatorL1Shares(bob, validatorManagerAddress, collateralClassId, charlie, charlieVault2Shares, delegator2);

        // Setup Dave as operator for vault2
        uint256 daveVault2DepositAmount = 200_000_000_000_000;
        collateral.transfer(staker, daveVault2DepositAmount);
        vm.startPrank(staker);
        collateral.approve(address(vault2), daveVault2DepositAmount);
        (, uint256 daveVault2Shares) = vault2.deposit(staker, daveVault2DepositAmount);
        vm.stopPrank();

        // Set L1 shares for Dave from vault2
        _setOperatorL1Shares(bob, validatorManagerAddress, collateralClassId, dave, daveVault2Shares, delegator2);

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

    
    /* ---------------------------- tiny helpers ---------------------------- */
    function _nodeBytes(bytes32 nodeId) internal pure returns (bytes memory) {
        return abi.encodePacked(uint160(uint256(nodeId))); // 20-byte NodeID encoding
    }

    function _pOwner1(address who) internal pure returns (PChainOwner memory o) {
        address[] memory a = new address[](1);
        a[0] = who;
        o = PChainOwner({threshold: 1, addresses: a});
    }

    function _pOwnerEmpty() internal pure returns (PChainOwner memory o) {
        address[] memory a = new address[](0);
        o = PChainOwner({threshold: 0, addresses: a});
    }

    ///////////////////////////////
    // INTERNAL HELPERS
    ///////////////////////////////

    function _pushRegistrationAck(bytes32 validationID, bool accepted) internal returns (uint32 idx) {
        bytes memory payload = abi.encodePacked(
            ValidatorMessages.CODEC_ID,
            ValidatorMessages.L1_VALIDATOR_REGISTRATION_MESSAGE_TYPE_ID,
            validationID,
            accepted
        );
        WarpMessage memory m = WarpMessage({
            sourceChainID: bytes32(0),            // ok for tests
            originSenderAddress: address(0),      // ok for tests
            payload: payload
        });
        MockWarpMessenger(WARP).push(m);
        return 0; // always pass 0 to complete* calls
    }

    function _pushWeight(bytes32 validationID, uint64 nonce, uint64 weight)
        internal
        returns (uint32 idx)
    {
        bytes memory payload = abi.encodePacked(
            ValidatorMessages.CODEC_ID,
            ValidatorMessages.L1_VALIDATOR_WEIGHT_MESSAGE_TYPE_ID,
            validationID,
            nonce,
            weight
        );
        WarpMessage memory m = WarpMessage({
            sourceChainID: bytes32(0),
            originSenderAddress: address(0),
            payload: payload
        });
        MockWarpMessenger(WARP).push(m);
        return 0;
    }

    function _pushRemovalAck(bytes32 validationID)
        internal
        returns (uint32 idx)
    {
        // completeValidatorRemoval expects a L1ValidatorRegistrationMessage with registered=false
        bytes memory payload = abi.encodePacked(
            ValidatorMessages.CODEC_ID,
            ValidatorMessages.L1_VALIDATOR_REGISTRATION_MESSAGE_TYPE_ID,
            validationID,
            bytes1(0x00) // registered=false for removal
        );
        WarpMessage memory m = WarpMessage({
            sourceChainID: bytes32(0),
            originSenderAddress: address(0),
            payload: payload
        });
        MockWarpMessenger(WARP).push(m);
        return 0;
    }

    function _registerOperator(address user, string memory metadataURL) internal {
        vm.startPrank(user);
        operatorRegistry.registerOperator(metadataURL);
        vm.stopPrank();
    }

    function _registerL1(address _l1, address _middleware) internal {
        // L1Registry expects the call to come from the owner of the validator manager
        address l1Owner = Ownable(_l1).owner();
        vm.deal(l1Owner, 1 ether); // Ensure the owner has ETH for registration fee
        vm.prank(l1Owner);
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
        uint96 collateralClass,
        uint256 amount,
        L1RestakeDelegator delegator_
    ) internal {
        vm.startPrank(user);
        delegator_.setL1Limit(_l1, collateralClass, amount);
        vm.stopPrank();
    }

    function _setOperatorL1Shares(
        address user,
        address _l1,
        uint96 collateralClass,
        address operator,
        uint256 shares,
        L1RestakeDelegator delegator_
    ) internal {
        vm.startPrank(user);
        delegator_.setOperatorL1Shares(_l1, collateralClass, operator, shares);
        vm.stopPrank();
    }



    function _moveToNextEpochAndCalc(
        uint256 numberOfEpochs
    ) internal returns (uint48) {
        for (uint256 i = 0; i < numberOfEpochs; i++) {
            // 1. Figure out what the *next* epoch index would be
            uint48 nextEpochIndex = middleware.getCurrentEpoch() + 1;

            // 2. Warp to *just after* that epoch's start
            _warpToEpoch(nextEpochIndex);
            _syncStakeCache(nextEpochIndex);

            // 3. Do any housekeeping
            middleware.calcAndCacheNodeStakeForAllOperators();

            console2.log("Current middleware epoch:", middleware.getCurrentEpoch());
            console2.log("Current vault epoch:", vault.currentEpoch());
        }
        return middleware.getCurrentEpoch();
    }

    /// warp safely to the _first second_ of `epoch`
    function _warpToEpoch(uint48 epoch) internal {
        vm.warp(middleware.getEpochStartTs(epoch) + 1);
    }

    /// bring the node‑stake cache forward _up to_ `epoch`
    function _syncStakeCache(uint48 epoch) internal {
        uint48 cachedEpoch = middleware.lastGlobalNodeStakeUpdateEpoch();
        if (cachedEpoch < epoch) {
            vm.prank(validatorManagerAddress);
            middleware.manualProcessNodeStakeCache(epoch - cachedEpoch);
        }
    }

    // Create a new asset class and register vault3 with it
    function _setupCollateralClassAndRegisterVault(
        uint96 collateralClassId_,
        uint256 minValidatorStake_,
        Token collateral_,
        VaultTokenized vault_,
        uint256 maxVaultLimit_,
        uint256 l1Limit_,
        L1RestakeDelegator delegator_
    ) internal {
        vm.startPrank(validatorManagerAddress);
        middleware.addCollateralClass(collateralClassId_, minValidatorStake_, 0, address(collateral_));
        middleware.activateSecondaryCollateralClass(collateralClassId_);
        vaultManager.registerVault(address(vault_), collateralClassId_, maxVaultLimit_);
        vm.stopPrank();
        _setL1Limit(bob, validatorManagerAddress, collateralClassId_, l1Limit_, delegator_);
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

    // Storage arrays to avoid stack depth issues
    bytes32[] private _tempNodeIds;
    bytes32[] private _tempValidationIDs;
    uint256[] private _tempNodeWeights;

    function _createAndConfirmNodes(
        address operator,
        uint256 nodeCount,
        uint256 stake_,
        bool confirmImmediately,
        uint256 minMultiplier
    ) internal returns (bytes32[] memory nodeIds, bytes32[] memory validationIDs, uint256[] memory nodeWeights) {
        // Clear storage arrays from any previous use
        delete _tempNodeIds;
        delete _tempValidationIDs;
        delete _tempNodeWeights;
        
        uint256 actualNodeCount = _registerNodes(operator, nodeCount, stake_, confirmImmediately, minMultiplier);
        
        // Copy from storage to memory for return
        nodeIds = new bytes32[](actualNodeCount);
        validationIDs = new bytes32[](actualNodeCount);
        nodeWeights = new uint256[](actualNodeCount);
        
        for (uint256 i = 0; i < actualNodeCount; i++) {
            nodeIds[i] = _tempNodeIds[i];
            validationIDs[i] = _tempValidationIDs[i];
            nodeWeights[i] = _tempNodeWeights[i];
        }
        
        // Clear storage arrays to save gas
        delete _tempNodeIds;
        delete _tempValidationIDs;
        delete _tempNodeWeights;
    }
    
    function _registerNodes(
        address operator,
        uint256 nodeCount,
        uint256 stake_,
        bool confirmImmediately,
        uint256 minMultiplier
    ) private returns (uint256 actualNodeCount) {
        for (uint256 i = 0; i < nodeCount; i++) {
            bytes32 nodeId = keccak256(abi.encodePacked(operator, block.timestamp, i));
            uint256 stakeAmount = _calculateStakeAmount(stake_, minMultiplier);
            
            if (!_tryRegisterNode(operator, nodeId, stakeAmount)) {
                break;
            }
            
            _tempNodeIds.push(nodeId);
            
            bytes32 validationID = IBalancerValidatorManager(balancer).getNodeValidationID(_nodeBytes(nodeId));
            _tempValidationIDs.push(validationID);
            
            if (confirmImmediately) {
                _completeNodeRegistration(validationID, actualNodeCount, nodeCount);
            }
            
            uint256 weight = middleware.nodeStakeCache(middleware.getCurrentEpoch(), validationID);
            assertGt(weight, 0, "Node weight must be positive");
            _tempNodeWeights.push(weight);
            
            actualNodeCount++;
        }
    }
    
    function _calculateStakeAmount(
        uint256 stake_,
        uint256 minMultiplier
    ) internal returns (uint256) {
        middleware.calcAndCacheNodeStakeForAllOperators();
        (uint256 minStake, ) = middleware.getClassStakingRequirements(1); // PRIMARY_ASSET_CLASS == 1
        
        return (stake_ != 0) ? stake_ : minStake * minMultiplier;
    }
    
    function _tryRegisterNode(
        address operator,
        bytes32 nodeId,
        uint256 stakeAmount
    ) internal returns (bool success) {
        uint256 free = middleware.getOperatorAvailableStake(operator);
        
        if (free < stakeAmount) {
            // accept *any* stake‑deficiency revert
            vm.expectRevert(); // removed selector filter
            vm.prank(operator);
            middleware.addNode(
                nodeId,
                new bytes(48), // 48-byte BLS
                _pOwner1(operator),
                _pOwner1(operator),
                stakeAmount
            );
            return false;
        }
        
        vm.prank(operator);
        middleware.addNode(
            nodeId,
            new bytes(48), // 48-byte BLS
            _pOwner1(operator),
            _pOwner1(operator),
            stakeAmount
        );
        return true;
    }
    
    function _completeNodeRegistration(
        bytes32 validationID,
        uint256 currentCount,
        uint256 totalCount
    ) internal {
        uint32 msgIdx = _pushRegistrationAck(validationID, true);
        middleware.completeValidatorRegistration(msgIdx); // permissionless
        if (currentCount + 1 < totalCount) _calcAndWarpOneEpoch();
    }

    function _stakeOrRemoveNodes(
        address operator,
        bytes32[] memory nodeIds,
        uint8 stakeDeltaMask,
        uint8 removeMask
    ) internal {
        (uint256 minStake,) = middleware.getClassStakingRequirements(collateralClassId);
        uint48 epoch = middleware.getCurrentEpoch();

        for (uint256 i = 0; i < nodeIds.length; i++) {
            bytes32 valID = IBalancerValidatorManager(balancer).getNodeValidationID(_nodeBytes(nodeIds[i]));
            uint256 currentStake = middleware.getNodeStake(epoch, valID);
            if (currentStake == 0) {
                continue;
            }
            bool doRemove = ((removeMask >> i) & 0x01) == 1;
            if (doRemove) {
                vm.prank(operator);
                middleware.removeNode(nodeIds[i]);

                // finalize removal with a proper removal-ack message
                uint32 rmIdx = _pushRemovalAck(valID);      // our messenger always returns last msg on index 0
                middleware.completeValidatorRemoval(rmIdx);  // rmIdx == 0 with our messenger
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

                // Get validation ID and compute the scaled weight
                bytes32 validationIdForUpdate = IBalancerValidatorManager(balancer).getNodeValidationID(
                    abi.encodePacked(uint160(uint256(nodeIds[i])))
                );
                uint64 scaledWeight = StakeConversion.stakeToWeight(newStake, middleware.WEIGHT_SCALE_FACTOR());
                
                // Get current nonce from validator
                Validator memory v = IBalancerValidatorManager(balancer).getValidator(validationIdForUpdate);
                uint64 nextNonce = uint64(v.sentNonce);
                
                // Push weight update in the warp messenger
                uint32 stakeMsgIdx = _pushWeight(validationIdForUpdate, nextNonce, scaledWeight);
                middleware.completeStakeUpdate(stakeMsgIdx); // permissionless
            }
        }
    }

    function _checkSumMatchesOperatorUsed(address operator, bytes32[] memory nodeIds) internal view {
        uint48 epoch = middleware.getCurrentEpoch();
        uint256 sumStakes;
        for (uint256 i = 0; i < nodeIds.length; i++) {
            bytes32 valID = IBalancerValidatorManager(balancer).getNodeValidationID(_nodeBytes(nodeIds[i]));
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

    /// Return the (primary‑asset‑class) min‑stake once – it never changes.
    function _primaryMinStake() internal view returns (uint256 s) {
        (s,) = middleware.getClassStakingRequirements(1);
    }

    function _ensureFreeStake(address operator) internal {
        uint256 need = _primaryMinStake();
        uint256 free = middleware.getOperatorAvailableStake(operator);
        if (free >= need) return;

        uint256 topUp = need - free;
        collateral.transfer(operator, topUp);
        vm.startPrank(operator);
        collateral.approve(address(vault), topUp);
        vault.deposit(operator, topUp);
        vm.stopPrank();
    }
}
