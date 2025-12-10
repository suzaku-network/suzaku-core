// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";

import {AvalancheL1Middleware, AvalancheL1MiddlewareSettings} from
    "../../src/contracts/middleware/AvalancheL1Middleware.sol";
import {IAvalancheL1Middleware} from "../../src/interfaces/middleware/IAvalancheL1Middleware.sol";
import {MiddlewareVaultManager} from "../../src/contracts/middleware/MiddlewareVaultManager.sol";
import {VaultTokenized} from "../../src/contracts/vault/VaultTokenized.sol";
import {L1RestakeDelegator} from "../../src/contracts/delegator/L1RestakeDelegator.sol";
import {IVaultTokenized} from "../../src/interfaces/vault/IVaultTokenized.sol";
import {IBaseDelegator} from "../../src/interfaces/delegator/IBaseDelegator.sol";
import {IL1RestakeDelegator} from "../../src/interfaces/delegator/IL1RestakeDelegator.sol";
import {IBalancerValidatorManager} from
    "@suzaku/contracts-library/interfaces/ValidatorManager/IBalancerValidatorManager.sol";
import {BalancerValidatorManager} from
    "@suzaku/contracts-library/contracts/ValidatorManager/BalancerValidatorManager.sol";

import {ERC20WithDecimals} from "../mocks/MockERC20WithDecimals.sol";
import {ICollateralClassRegistry} from "../../src/interfaces/middleware/ICollateralClassRegistry.sol";
import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";

// Additional imports needed for standalone test
import {VaultFactory} from "../../src/contracts/VaultFactory.sol";
import {DelegatorFactory} from "../../src/contracts/DelegatorFactory.sol";
import {SlasherFactory} from "../../src/contracts/SlasherFactory.sol";
import {L1Registry} from "../../src/contracts/L1Registry.sol";
import {OperatorRegistry} from "../../src/contracts/OperatorRegistry.sol";
import {OperatorVaultOptInService} from "../../src/contracts/service/OperatorVaultOptInService.sol";
import {OperatorL1OptInService} from "../../src/contracts/service/OperatorL1OptInService.sol";
import {DeployBalancerValidatorManager} from "lib/suzaku-contracts-library/script/ValidatorManager/DeployBalancerValidatorManager.s.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PChainOwner} from "@avalabs/icm-contracts/validator-manager/interfaces/IACP99Manager.sol";
import {MockWarpMessenger} from "../mocks/MockWarpMessenger.sol";
import {Token} from "../mocks/Token.sol";

contract MiddlewareCollateralDecimalsTest is Test {
    // Constants
    address constant WARP = 0x0200000000000000000000000000000000000005;
    
    // State variables
    VaultFactory vaultFactory;
    DelegatorFactory delegatorFactory;
    SlasherFactory slasherFactory;
    L1Registry l1Registry;
    OperatorRegistry operatorRegistry;
    OperatorVaultOptInService operatorVaultOptInService;
    OperatorL1OptInService operatorL1OptInService;
    AvalancheL1Middleware middleware;
    MiddlewareVaultManager vaultManager;
    
    address alice;
    address bob;
    address staker;
    address l1Owner;
    address protocolOwner;
    address balancer;
    
    function setUp() public {
        // Setup addresses
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        staker = makeAddr("staker");
        l1Owner = makeAddr("l1Owner");
        protocolOwner = makeAddr("protocolOwner");
        
        // Deploy factories
        vaultFactory = new VaultFactory(protocolOwner);
        delegatorFactory = new DelegatorFactory(protocolOwner);
        slasherFactory = new SlasherFactory(protocolOwner);
        
        // Whitelist VaultTokenized implementation
        address vaultImpl = address(new VaultTokenized(address(vaultFactory)));
        vm.prank(protocolOwner);
        vaultFactory.whitelist(vaultImpl);
        
        // Deploy registries
        l1Registry = new L1Registry(payable(protocolOwner), 0.01 ether, 0.1 ether, protocolOwner);
        operatorRegistry = new OperatorRegistry();
        
        // Deploy opt-in services
        operatorVaultOptInService = new OperatorVaultOptInService(
            address(operatorRegistry),
            address(vaultFactory),
            "OperatorVaultOptInService"
        );
        
        operatorL1OptInService = new OperatorL1OptInService(
            address(operatorRegistry),
            address(l1Registry),
            "OperatorL1OptInService"
        );
        
        // Whitelist L1RestakeDelegator implementation
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
        vm.prank(protocolOwner);
        delegatorFactory.whitelist(l1RestakeDelegatorImpl);
        
        // Deploy balancer
        DeployBalancerValidatorManager deployScript = new DeployBalancerValidatorManager();
        bytes[] memory migrated = new bytes[](2);
        migrated[0] = hex"2345678123456781234567812345678123456781";
        migrated[1] = hex"3456781234567812345678123456781234567812";
        (balancer,,) = deployScript.run(address(0), uint64(18 ether), migrated);
        
        // Transfer balancer ownership to l1Owner
        address currentOwner = BalancerValidatorManager(balancer).owner();
        vm.prank(currentOwner);
        BalancerValidatorManager(balancer).transferOwnership(l1Owner);
        
        // Register alice as operator
        vm.prank(alice);
        operatorRegistry.registerOperator("alice-metadata");
        
        // Fund test accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(staker, 100 ether);
        vm.deal(l1Owner, 100 ether);
        
        // AFTER deploy script finishes, override the canonical warp messenger with our push-style test messenger
        {
            MockWarpMessenger messenger = new MockWarpMessenger();
            vm.etch(WARP, address(messenger).code);
        }
        
        // Deploy the middleware with a standard 18-decimal token as primary
        uint256 scaleFactor = 10 ** 18;
        uint256 maxStakeAmount = 1_000 * scaleFactor;
        uint256 minStakeAmount = 1 * scaleFactor;
        
        AvalancheL1MiddlewareSettings memory middlewareSettings = AvalancheL1MiddlewareSettings({
            balancer: balancer,
            operatorRegistry: address(operatorRegistry),
            vaultRegistry: address(vaultFactory),
            operatorL1Optin: address(operatorL1OptInService),
            epochDuration: 4 hours,
            slashingWindow: 5 hours,
            stakeUpdateWindow: 3 hours
        });
        
        middleware = new AvalancheL1Middleware(
            middlewareSettings,
            l1Owner,
            address(new Token("PrimaryToken")), // dummy primary collateral
            maxStakeAmount,
            minStakeAmount,
            scaleFactor
        );
        
        // Deploy vaultManager
        vaultManager = new MiddlewareVaultManager(
            address(vaultFactory), 
            l1Owner, 
            address(middleware), 
            24
        );
        
        // Set the vault manager in the middleware
        vm.prank(l1Owner);
        middleware.setVaultManager(address(vaultManager));
        
        // Setup middleware as a security module on the Balancer
        vm.prank(l1Owner);
        BalancerValidatorManager(balancer).setUpSecurityModule(address(middleware), uint64(1000));
        
        // Register L1
        _registerL1(balancer, address(middleware));
        
        // Now alice can opt into the L1 after it's registered
        vm.prank(alice);
        operatorL1OptInService.optIn(balancer);
        
        // Register operator alice in middleware
        vm.prank(l1Owner);
        middleware.registerOperator(alice);
    }
    
    // Helper functions
    function _optInOperatorVault(address operator, address vault) internal {
        vm.prank(operator);
        operatorVaultOptInService.optIn(vault);
    }
    
    function _registerL1(address _l1, address _middleware) internal {
        address balancerOwner = Ownable(_l1).owner();
        vm.deal(balancerOwner, 1 ether);
        vm.prank(balancerOwner);
        l1Registry.registerL1{value: 0.01 ether}(_l1, _middleware, "metadataURL");
    }
    
    function _pOwner1(address owner) internal pure returns (PChainOwner memory) {
        address[] memory addresses = new address[](1);
        addresses[0] = owner;
        return PChainOwner({
            threshold: 1,
            addresses: addresses
        });
    }
    
    function _ensureFreeStake(address operator) internal view {
        // Helper function to ensure operator has free stake
        // In these tests, we don't need to do anything as operators start with free stake
    }
    /// POC 1: available stake inflation when primary collateral has 6 decimals.
    function test_POC_AvailableStakeInflated_Primary6Decimals() public {
        // --- 6-dec primary token and vault ---
        ERC20WithDecimals usdc6Dec = new ERC20WithDecimals("USDC6", "USDC6", 6);

        uint48 epochDuration = 8 hours;
        address vImplOwner = bob;
        address vault6DecAddress = vaultFactory.create(
            vaultFactory.lastVersion(),
            vImplOwner,
            abi.encode(
                IVaultTokenized.InitParams({
                    collateral: address(usdc6Dec),
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
                    name: "USDC6 Vault",
                    symbol: "USDC6V"
                })
            ),
            address(delegatorFactory),
            address(slasherFactory)
        );
        VaultTokenized vault6Dec = VaultTokenized(vault6DecAddress);

        // Delegator for vault6
        address[] memory l1LimitSetRoleHolders = new address[](1);
        l1LimitSetRoleHolders[0] = bob;
        address[] memory operatorL1SharesSetRoleHolders = new address[](1);
        operatorL1SharesSetRoleHolders[0] = bob;

        address delegator6DecAddress = delegatorFactory.create(
            0,
            abi.encode(
                vault6DecAddress,
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
        L1RestakeDelegator delegator6Dec = L1RestakeDelegator(delegator6DecAddress);

        vm.prank(bob);
        vault6Dec.setDelegator(delegator6DecAddress);

        // Operator opt-ins for this new vault
        _optInOperatorVault(alice, vault6DecAddress);

        // Deposit 1,000 units (U = 6 decimals)
        uint256 depositAmount = 1_000 * 10**6;
        usdc6Dec.transfer(staker, depositAmount);
        vm.startPrank(staker);
        usdc6Dec.approve(vault6DecAddress, depositAmount);
        (uint256 depositUsed, uint256 mintedShares) = vault6Dec.deposit(staker, depositAmount);
        vm.stopPrank();
        assertEq(depositUsed, depositAmount);

        // L1 limit ≥ deposit
        // _setL1Limit(bob, balancer, 1, 5_000 * 10**6, delegator6Dec);
        // _setOperatorL1Shares(bob, balancer, 1, alice, mintedShares, delegator6Dec);
        // NOTE: don't set L1 limit yet (maxL1Limit must be set by middleware via registerVault)

        // --- New middleware with 6-dec primary ---
        AvalancheL1MiddlewareSettings memory middlewareSettings = AvalancheL1MiddlewareSettings({
            balancer: balancer,
            operatorRegistry: address(operatorRegistry),
            vaultRegistry: address(vaultFactory),
            operatorL1Optin: address(operatorL1OptInService),
            epochDuration: 4 hours,
            slashingWindow: 5 hours,
            stakeUpdateWindow: 3 hours
        });

        // scaleFactor in U; require scaleFactor ≤ minStake in constructor
        uint256 minStakeAmount = 1_000_000; // 1 token
        uint256 maxStakeAmount = 1_000_000_000_000_000; // large
        uint256 scaleFactor = 1_000_000; // 1e6

        AvalancheL1Middleware middleware6Dec = new AvalancheL1Middleware(
            middlewareSettings,
            l1Owner,  // l1Owner owns middleware
            address(usdc6Dec),
            maxStakeAmount,
            minStakeAmount,
            scaleFactor
        );

        // Vault manager for middleware6Dec
        MiddlewareVaultManager vaultManager6Dec = new MiddlewareVaultManager(address(vaultFactory), l1Owner, address(middleware6Dec), 24);
        vm.prank(l1Owner);
        middleware6Dec.setVaultManager(address(vaultManager6Dec));

        // Keep middleware and vaultManager owned by the l1Owner
        // Do NOT transfer ownership to anyone else as per the new architecture

        // Register middleware6Dec as a security module with **maxWeight = 2000** → capU = 2000 * scaleFactor = 2,000e6
        {
            vm.prank(l1Owner);
            BalancerValidatorManager(balancer).setUpSecurityModule(address(middleware6Dec), uint64(2000));
        }

        // Update the L1's middleware association to the new middleware6Dec
        vm.prank(l1Owner);
        l1Registry.setL1Middleware(balancer, address(middleware6Dec));

        // Register vault6Dec for class 1 in middleware6Dec
        vm.startPrank(l1Owner);  // vaultManager6Dec is owned by the l1Owner
        vaultManager6Dec.registerVault(vault6DecAddress, 1, 10_000 * 10**6);
        vm.stopPrank();

        // Register operator in middleware6Dec
        vm.startPrank(l1Owner);  // middleware6Dec is owned by the l1Owner
        middleware6Dec.registerOperator(alice);
        vm.stopPrank();

        // Now that maxL1Limit is set by registerVault, set per‑L1 limit & shares on delegator
        // bob is the delegator owner (defaultAdminRoleHolder), so he can set limits
        vm.startPrank(bob);
        delegator6Dec.setL1Limit(balancer, 1, 5_000 * 10**6);
        delegator6Dec.setOperatorL1Shares(balancer, 1, alice, mintedShares);
        vm.stopPrank();
        // Move to next middleware6Dec epoch so vault/operator are active for stake accounting
        uint48 nextMw6Epoch = middleware6Dec.getCurrentEpoch() + 1;
        vm.warp(middleware6Dec.getEpochStartTs(nextMw6Epoch) + 1);
        middleware6Dec.calcAndCacheNodeStakeForAllOperators();

        // After normalization fix there is no inflation: available == actual stake (1,000e6)
        uint256 availableStake = middleware6Dec.getOperatorAvailableStake(alice);
        assertEq(availableStake, 1_000 * 10**6, "no inflation; equals actual stake");

        // Adding 1,500e6 must now fail (insufficient free stake)
        bytes32 nodeId = bytes32(uint256(uint160(uint256(keccak256("inflation-node")))));
        vm.expectRevert(IAvalancheL1Middleware.AvalancheL1Middleware__InsufficientStake.selector);
        vm.prank(alice);
        middleware6Dec.addNode(
            nodeId,
            new bytes(48),
            _pOwner1(alice),
            _pOwner1(alice),
            1_500 * 10**6
        );
        // Revert proves that over-allocation is prevented.
    }

    /// POC 2: secondary min per-node bypass when secondary collateral has 6 decimals.
    function test_POC_MinSecondaryBypass_6Decimals() public {
        // First, set up primary collateral (18-dec) so alice has enough primary stake
        // Use the same primary token that the middleware was initialized with
        address primaryToken = middleware.PRIMARY_ASSET();
        
        // Create primary vault
        address primaryVaultAddress = vaultFactory.create(
            vaultFactory.lastVersion(),
            bob,
            abi.encode(
                IVaultTokenized.InitParams({
                    collateral: primaryToken,
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
                    name: "Primary Vault",
                    symbol: "PRIMV"
                })
            ),
            address(delegatorFactory),
            address(slasherFactory)
        );
        VaultTokenized primaryVault = VaultTokenized(primaryVaultAddress);
        
        // Create delegator for primary vault
        address[] memory primaryL1LimitSetRoleHolders = new address[](1);
        primaryL1LimitSetRoleHolders[0] = bob;
        address[] memory primaryOperatorL1SharesSetRoleHolders = new address[](1);
        primaryOperatorL1SharesSetRoleHolders[0] = bob;
        
        address primaryDelegatorAddress = delegatorFactory.create(
            0,
            abi.encode(
                primaryVaultAddress,
                abi.encode(
                    IL1RestakeDelegator.InitParams({
                        baseParams: IBaseDelegator.BaseParams({
                            defaultAdminRoleHolder: bob,
                            hook: address(0),
                            hookSetRoleHolder: bob
                        }),
                        l1LimitSetRoleHolders: primaryL1LimitSetRoleHolders,
                        operatorL1SharesSetRoleHolders: primaryOperatorL1SharesSetRoleHolders
                    })
                )
            )
        );
        L1RestakeDelegator primaryDelegator = L1RestakeDelegator(primaryDelegatorAddress);
        
        vm.prank(bob);
        primaryVault.setDelegator(primaryDelegatorAddress);
        
        // Alice opts into primary vault
        _optInOperatorVault(alice, primaryVaultAddress);
        
        // Register primary vault with vaultManager
        vm.prank(l1Owner);
        vaultManager.registerVault(primaryVaultAddress, 1, 1000 ether);
        
        // Deposit primary tokens and assign to alice
        Token(primaryToken).transfer(staker, 2 ether);
        vm.startPrank(staker);
        Token(primaryToken).approve(primaryVaultAddress, 2 ether);
        (, uint256 primaryMintedShares) = primaryVault.deposit(staker, 2 ether);
        vm.stopPrank();
        
        vm.startPrank(bob);
        primaryDelegator.setL1Limit(balancer, 1, 1000 ether);
        primaryDelegator.setOperatorL1Shares(balancer, 1, alice, primaryMintedShares);
        vm.stopPrank();
        
        // Now set up secondary token with 6 decimals
        ERC20WithDecimals usdc6Dec = new ERC20WithDecimals("USDC6", "USDC6", 6);

        // Create vault for secondary class
        address vaultUSDCAddress = vaultFactory.create(
            vaultFactory.lastVersion(),
            bob,
            abi.encode(
                IVaultTokenized.InitParams({
                    collateral: address(usdc6Dec),
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
                    name: "USDC6 Sec",
                    symbol: "USDC6S"
                })
            ),
            address(delegatorFactory),
            address(slasherFactory)
        );
        VaultTokenized vaultUSDC6Dec = VaultTokenized(vaultUSDCAddress);

        // Delegator for secondary vault
        address[] memory l1LimitSetRoleHolders = new address[](1);
        l1LimitSetRoleHolders[0] = bob;
        address[] memory operatorL1SharesSetRoleHolders = new address[](1);
        operatorL1SharesSetRoleHolders[0] = bob;

        address delegatorUSDCAddress = delegatorFactory.create(
            0,
            abi.encode(
                vaultUSDCAddress,
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
        L1RestakeDelegator delegatorUSDC = L1RestakeDelegator(delegatorUSDCAddress);

        vm.prank(bob);
        vaultUSDC6Dec.setDelegator(delegatorUSDCAddress);

        // Add secondary class with min per-node = 100 USDC (U = 100e6)
        uint96 secClass = 42;
        vm.startPrank(l1Owner);
        middleware.addCollateralClass(secClass, 100 * 10**6, 0, address(usdc6Dec));
        middleware.activateSecondaryCollateralClass(secClass);
        // Register the vault in that class
        vaultManager.registerVault(vaultUSDCAddress, secClass, 10_000 * 10**6);
        vm.stopPrank();

        // Opt-in operator to this vault
        _optInOperatorVault(alice, vaultUSDCAddress);

        // Give Alice only 50 USDC (insufficient) but bug will pass
        uint256 depositAmount = 50 * 10**6;
        usdc6Dec.transfer(staker, depositAmount);
        vm.startPrank(staker);
        usdc6Dec.approve(vaultUSDCAddress, depositAmount);
        (uint256 depositUsed, uint256 shares) = vaultUSDC6Dec.deposit(staker, depositAmount);
        vm.stopPrank();
        assertEq(depositUsed, depositAmount);

        // bob is the delegator owner (defaultAdminRoleHolder), so he can set limits
        vm.startPrank(bob);
        delegatorUSDC.setL1Limit(balancer, secClass, 1_000 * 10**6);
        delegatorUSDC.setOperatorL1Shares(balancer, secClass, alice, shares);
        vm.stopPrank();

        // Advance one epoch so the newly registered vaults count this epoch
        {
            uint48 nextEpoch = middleware.getCurrentEpoch() + 1;
            vm.warp(middleware.getEpochStartTs(nextEpoch) + 1);
        }
        middleware.calcAndCacheNodeStakeForAllOperators();

        // Sanity assertions to clearly show the stake situation
        uint48 e = middleware.getCurrentEpoch();
        // Stakes for class 42 are reported in its canonical unit (USDC6 => 6 decimals)
        assertEq(middleware.getOperatorStake(alice, e, 42), 50 * 10**6, "Alice has only 50 USDC");
        assertGe(middleware.getOperatorStake(alice, e, 1), 1 ether, "Alice has enough primary stake");

        // Try to add a node with minimum primary stake (1 ether)
        // Alice has 2 ether primary stake (sufficient) 
        // But only 50 USDC secondary stake (insufficient - needs 100 USDC minimum)
        // With only 50 USDC (min=100), this must now revert
        bytes32 nodeId = bytes32(uint256(uint160(uint256(keccak256("secondary-bypass-node")))));
        vm.expectRevert(IAvalancheL1Middleware.AvalancheL1Middleware__InsufficientStake.selector);
        vm.prank(alice);
        middleware.addNode(
            nodeId,
            new bytes(48),
            _pOwner1(alice),
            _pOwner1(alice),
            1 ether // use minimum primary stake
        );
        // Revert proves min-secondary is now properly enforced.
    }

    /// Primary = 18d (from setUp). Adding a 6d asset to primary class must revert.
    function test_Primary18_AddSecondAsset6Decimals_Revert() public {
        ERC20WithDecimals six = new ERC20WithDecimals("SIX", "SIX", 6);

        vm.expectRevert(
            abi.encodeWithSelector(
                ICollateralClassRegistry.CollateralClassRegistry__AssetDecimalsMismatch.selector,
                uint8(18),
                uint8(6)
            )
        );
        vm.prank(l1Owner);
        middleware.addAssetToClass(1, address(six));
    }

    /// Spin up a new middleware with 6d primary; same‑dec asset is allowed, different‑dec (8d) must revert.
    function test_Primary6_AddSecondAsset8Decimals_Revert_SameDecPass() public {
        ERC20WithDecimals token6 = new ERC20WithDecimals("USDC6", "U6", 6);
        AvalancheL1MiddlewareSettings memory settings = AvalancheL1MiddlewareSettings({
            balancer: balancer,
            operatorRegistry: address(operatorRegistry),
            vaultRegistry: address(vaultFactory),
            operatorL1Optin: address(operatorL1OptInService),
            epochDuration: 4 hours,
            slashingWindow: 5 hours,
            stakeUpdateWindow: 3 hours
        });
        uint256 minStake = 1_000_000; // 1e6
        uint256 maxStake = 1_000_000_000_000_000;
        uint256 scale    = 1_000_000;

        AvalancheL1Middleware mw6 = new AvalancheL1Middleware(
            settings, l1Owner, address(token6), maxStake, minStake, scale
        );
        MiddlewareVaultManager vm6 = new MiddlewareVaultManager(address(vaultFactory), l1Owner, address(mw6), 24);
        vm.prank(l1Owner);
        mw6.setVaultManager(address(vm6));

        // same‑dec (6) → ok
        ERC20WithDecimals another6 = new ERC20WithDecimals("MOCK6", "M6", 6);
        vm.prank(l1Owner);
        mw6.addAssetToClass(1, address(another6));

        // different‑dec (8) → revert
        ERC20WithDecimals tok8 = new ERC20WithDecimals("TOK8","T8",8);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICollateralClassRegistry.CollateralClassRegistry__AssetDecimalsMismatch.selector,
                uint8(6),
                uint8(8)
            )
        );
        vm.prank(l1Owner);
        mw6.addAssetToClass(1, address(tok8));
    }

    /// Secondary class with 8 decimals: adding another 8d asset is OK; adding 6d must revert.
    function test_Secondary8_AddSameDecPass_DiffDecRevert() public {
        ERC20WithDecimals a8 = new ERC20WithDecimals("A8","A8",8);
        ERC20WithDecimals b8 = new ERC20WithDecimals("B8","B8",8);
        ERC20WithDecimals c6 = new ERC20WithDecimals("C6","C6",6);
        uint96 sec = 88;

        vm.startPrank(l1Owner);
        middleware.addCollateralClass(sec, 0, 0, address(a8));
        middleware.activateSecondaryCollateralClass(sec);

        // same dec ok
        middleware.addAssetToClass(sec, address(b8));

        // different dec revert
        vm.expectRevert(
            abi.encodeWithSelector(
                ICollateralClassRegistry.CollateralClassRegistry__AssetDecimalsMismatch.selector,
                uint8(8),
                uint8(6)
            )
        );
        middleware.addAssetToClass(sec, address(c6));
        vm.stopPrank();
    }

    /// Secondary in-use protections: cannot deactivate class or remove asset while a vault uses it.
    function test_Secondary8_InUse_DeactivateOrRemove_Revert() public {
        ERC20WithDecimals t8 = new ERC20WithDecimals("T8","T8",8);
        uint96 sec = 77;

        // create class + activate
        vm.startPrank(l1Owner);
        middleware.addCollateralClass(sec, 0, 0, address(t8));
        middleware.activateSecondaryCollateralClass(sec);
        vm.stopPrank();

        // register a vault for that class
        address vAddr = vaultFactory.create(
            vaultFactory.lastVersion(),
            bob,
            abi.encode(
                IVaultTokenized.InitParams({
                    collateral: address(t8),
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
                    name: "SEC8",
                    symbol: "S8"
                })
            ),
            address(delegatorFactory),
            address(slasherFactory)
        );
        VaultTokenized v = VaultTokenized(vAddr);

        address dAddr = delegatorFactory.create(
            0,
            abi.encode(
                vAddr,
                abi.encode(
                    IL1RestakeDelegator.InitParams({
                        baseParams: IBaseDelegator.BaseParams({
                            defaultAdminRoleHolder: bob,
                            hook: address(0),
                            hookSetRoleHolder: bob
                        }),
                        l1LimitSetRoleHolders: _one(bob),
                        operatorL1SharesSetRoleHolders: _one(bob)
                    })
                )
            )
        );
        vm.prank(bob);
        v.setDelegator(dAddr);

        vm.prank(l1Owner);
        vaultManager.registerVault(vAddr, sec, 1_000 * 10**8);

        // cannot deactivate while in use
        vm.expectRevert(
            abi.encodeWithSelector(IAvalancheL1Middleware.AvalancheL1Middleware__AssetStillInUse.selector, sec)
        );
        vm.prank(l1Owner);
        middleware.deactivateSecondaryCollateralClass(sec);

        // cannot remove the only asset while in use
        vm.expectRevert(
            abi.encodeWithSelector(IAvalancheL1Middleware.AvalancheL1Middleware__AssetStillInUse.selector, sec)
        );
        vm.prank(l1Owner);
        middleware.removeAssetFromClass(sec, address(t8));
    }

    /// Helper for delegator role arrays
    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    /// POC variant: secondary = 8 decimals. Min per-node enforced during addNode.
    function test_POC_MinSecondaryBypass_8Decimals() public {
        // Ensure primary stake for alice (same as POC_6d but with current middleware/primary 18d)
        address primaryToken = middleware.PRIMARY_ASSET();

        // primary vault + delegator + deposit 2e18 assigned to alice
        address pVaultAddr = vaultFactory.create(
            vaultFactory.lastVersion(),
            bob,
            abi.encode(
                IVaultTokenized.InitParams({
                    collateral: primaryToken,
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
                    name: "PRIM",
                    symbol: "P"
                })
            ),
            address(delegatorFactory),
            address(slasherFactory)
        );
        VaultTokenized pVault = VaultTokenized(pVaultAddr);

        address pDelAddr = delegatorFactory.create(
            0,
            abi.encode(
                pVaultAddr,
                abi.encode(
                    IL1RestakeDelegator.InitParams({
                        baseParams: IBaseDelegator.BaseParams({
                            defaultAdminRoleHolder: bob,
                            hook: address(0),
                            hookSetRoleHolder: bob
                        }),
                        l1LimitSetRoleHolders: _one(bob),
                        operatorL1SharesSetRoleHolders: _one(bob)
                    })
                )
            )
        );
        L1RestakeDelegator pDel = L1RestakeDelegator(pDelAddr);
        vm.prank(bob);
        pVault.setDelegator(pDelAddr);

        _optInOperatorVault(alice, pVaultAddr);
        vm.prank(l1Owner);
        vaultManager.registerVault(pVaultAddr, 1, 1_000 ether);

        Token(primaryToken).transfer(staker, 2 ether);
        vm.startPrank(staker);
        Token(primaryToken).approve(pVaultAddr, 2 ether);
        ( , uint256 pShares) = pVault.deposit(staker, 2 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        pDel.setL1Limit(balancer, 1, 1_000 ether);
        pDel.setOperatorL1Shares(balancer, 1, alice, pShares);
        vm.stopPrank();

        // secondary 8d
        ERC20WithDecimals t8 = new ERC20WithDecimals("USDT8", "U8", 8);
        uint96 sec = 66;

        // class with min per-node = 100e8
        vm.startPrank(l1Owner);
        middleware.addCollateralClass(sec, 100 * 10**8, 0, address(t8));
        middleware.activateSecondaryCollateralClass(sec);
        vm.stopPrank();

        // vault + delegator for secondary
        address sVaultAddr = vaultFactory.create(
            vaultFactory.lastVersion(),
            bob,
            abi.encode(
                IVaultTokenized.InitParams({
                    collateral: address(t8),
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
                    name: "SEC8",
                    symbol: "S8"
                })
            ),
            address(delegatorFactory),
            address(slasherFactory)
        );
        VaultTokenized sVault = VaultTokenized(sVaultAddr);

        address sDelAddr = delegatorFactory.create(
            0,
            abi.encode(
                sVaultAddr,
                abi.encode(
                    IL1RestakeDelegator.InitParams({
                        baseParams: IBaseDelegator.BaseParams({
                            defaultAdminRoleHolder: bob,
                            hook: address(0),
                            hookSetRoleHolder: bob
                        }),
                        l1LimitSetRoleHolders: _one(bob),
                        operatorL1SharesSetRoleHolders: _one(bob)
                    })
                )
            )
        );
        L1RestakeDelegator sDel = L1RestakeDelegator(sDelAddr);
        vm.prank(bob);
        sVault.setDelegator(sDelAddr);

        _optInOperatorVault(alice, sVaultAddr);
        vm.prank(l1Owner);
        vaultManager.registerVault(sVaultAddr, sec, 10_000 * 10**8);

        // Give only 50e8 (insufficient vs 100e8/node)
        uint256 dep = 50 * 10**8;
        t8.transfer(staker, dep);
        vm.startPrank(staker);
        t8.approve(sVaultAddr, dep);
        ( , uint256 sShares) = sVault.deposit(staker, dep);
        vm.stopPrank();

        vm.startPrank(bob);
        sDel.setL1Limit(balancer, sec, 1_000 * 10**8);
        sDel.setOperatorL1Shares(balancer, sec, alice, sShares);
        vm.stopPrank();

        // Advance to next epoch for accounting
        {
            uint48 nextEpoch = middleware.getCurrentEpoch() + 1;
            vm.warp(middleware.getEpochStartTs(nextEpoch) + 1);
        }
        middleware.calcAndCacheNodeStakeForAllOperators();

        // Sanity checks
        uint48 e = middleware.getCurrentEpoch();
        assertEq(middleware.getOperatorStake(alice, e, sec), 50 * 10**8, "secondary stake is 50e8");
        assertGe(middleware.getOperatorStake(alice, e, 1), 1 ether, "primary enough");

        // Adding a node should fail due to min secondary per-node
        bytes32 nodeId = bytes32(uint256(uint160(uint256(keccak256("sec8-bypass")))));
        vm.expectRevert(IAvalancheL1Middleware.AvalancheL1Middleware__InsufficientStake.selector);
        vm.prank(alice);
        middleware.addNode(
            nodeId,
            new bytes(48),
            _pOwner1(alice),
            _pOwner1(alice),
            1 ether
        );
    }

    /// Aggregation across two 8‑dec secondary vaults (same class): sums exactly in class unit.
    function test_Secondary8_TwoVaults_Aggregation() public {
        ERC20WithDecimals a8 = new ERC20WithDecimals("A8","A8",8);
        ERC20WithDecimals b8 = new ERC20WithDecimals("B8","B8",8);
        uint96 sec = 99;

        vm.startPrank(l1Owner);
        middleware.addCollateralClass(sec, 0, 0, address(a8));
        middleware.activateSecondaryCollateralClass(sec);
        middleware.addAssetToClass(sec, address(b8));
        vm.stopPrank();

        // Vault A
        address vA = vaultFactory.create(
            vaultFactory.lastVersion(),
            bob,
            abi.encode(
                IVaultTokenized.InitParams({
                    collateral: address(a8),
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
                    name: "A8V",
                    symbol: "A8V"
                })
            ),
            address(delegatorFactory),
            address(slasherFactory)
        );
        VaultTokenized VA = VaultTokenized(vA);
        address dA = delegatorFactory.create(
            0,
            abi.encode(
                vA,
                abi.encode(
                    IL1RestakeDelegator.InitParams({
                        baseParams: IBaseDelegator.BaseParams({
                            defaultAdminRoleHolder: bob,
                            hook: address(0),
                            hookSetRoleHolder: bob
                        }),
                        l1LimitSetRoleHolders: _one(bob),
                        operatorL1SharesSetRoleHolders: _one(bob)
                    })
                )
            )
        );
        vm.prank(bob); VA.setDelegator(dA);
        _optInOperatorVault(alice, vA);
        vm.prank(l1Owner); vaultManager.registerVault(vA, sec, 10_000 * 10**8);

        // Vault B
        address vB = vaultFactory.create(
            vaultFactory.lastVersion(),
            bob,
            abi.encode(
                IVaultTokenized.InitParams({
                    collateral: address(b8),
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
                    name: "B8V",
                    symbol: "B8V"
                })
            ),
            address(delegatorFactory),
            address(slasherFactory)
        );
        VaultTokenized VB = VaultTokenized(vB);
        address dB = delegatorFactory.create(
            0,
            abi.encode(
                vB,
                abi.encode(
                    IL1RestakeDelegator.InitParams({
                        baseParams: IBaseDelegator.BaseParams({
                            defaultAdminRoleHolder: bob,
                            hook: address(0),
                            hookSetRoleHolder: bob
                        }),
                        l1LimitSetRoleHolders: _one(bob),
                        operatorL1SharesSetRoleHolders: _one(bob)
                    })
                )
            )
        );
        vm.prank(bob); VB.setDelegator(dB);
        _optInOperatorVault(alice, vB);
        vm.prank(l1Owner); vaultManager.registerVault(vB, sec, 10_000 * 10**8);

        // Deposits: 60e8 + 40e8
        uint256 depA = 60 * 10**8;
        uint256 depB = 40 * 10**8;

        a8.transfer(staker, depA);
        vm.startPrank(staker);
        a8.approve(vA, depA);
        ( , uint256 shA) = VA.deposit(staker, depA);
        vm.stopPrank();

        b8.transfer(staker, depB);
        vm.startPrank(staker);
        b8.approve(vB, depB);
        ( , uint256 shB) = VB.deposit(staker, depB);
        vm.stopPrank();

        vm.startPrank(bob);
        L1RestakeDelegator(dA).setL1Limit(balancer, sec, 10_000 * 10**8);
        L1RestakeDelegator(dA).setOperatorL1Shares(balancer, sec, alice, shA);
        L1RestakeDelegator(dB).setL1Limit(balancer, sec, 10_000 * 10**8);
        L1RestakeDelegator(dB).setOperatorL1Shares(balancer, sec, alice, shB);
        vm.stopPrank();

        // next epoch + cache
        {
            uint48 nextEpoch = middleware.getCurrentEpoch() + 1;
            vm.warp(middleware.getEpochStartTs(nextEpoch) + 1);
        }
        middleware.calcAndCacheNodeStakeForAllOperators();

        uint48 e = middleware.getCurrentEpoch();
        assertEq(middleware.getOperatorStake(alice, e, sec), (depA + depB), "sum in class unit (8d)");
    }
}
