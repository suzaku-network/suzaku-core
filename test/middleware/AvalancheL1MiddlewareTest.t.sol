// // SPDX-License-Identifier: MIT
// pragma solidity 0.8.25;

// import {Test, console2} from "forge-std/Test.sol";

// import {AvalancheL1Middleware, AvalancheL1MiddlewareSettings} from "../../src/contracts/middleware/AvalancheL1Middleware.sol";
// import {AssetClassManager} from "../../src/contracts/middleware/AssetClassManager.sol";

// // import {MockOperatorRegistry, MockRegistry, MockVault, MockDelegator, MockSlasher, MockVetoSlasher} from "../mocks/YourMockImports.sol";
// import {IBaseDelegator} from "../../src/interfaces/delegator/IBaseDelegator.sol";
// import {IOperatorRegistry} from "../../src/interfaces/IOperatorRegistry.sol";
// import {IVaultTokenized} from "../../src/interfaces/vault/IVaultTokenized.sol";
// import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";

// contract AvalancheL1MiddlewareTest is Test {
//     AvalancheL1Middleware middleware;

//     MockOperatorRegistry operatorRegistry;
//     MockRegistry vaultRegistry;
//     MockDelegator delegator;
//     MockSlasher slasherInstant;
//     MockVetoSlasher slasherVeto;
//     MockVault vaultInstant;
//     MockVault vaultVeto;

//     address owner = address(1000);
//     address operator = address(2000);

//     function setUp() public {
//         vm.startPrank(owner);

//         operatorRegistry = new MockOperatorRegistry();
//         vaultRegistry = new MockRegistry();
//         delegator = new MockDelegator();
//         slasherInstant = new MockSlasher();
//         slasherVeto = new MockVetoSlasher();

//         // Create 2 vault mocks with different slashers
//         vaultInstant = new MockVault(address(delegator), address(slasherInstant));
//         vaultVeto = new MockVault(address(delegator), address(slasherVeto));

//         // Make them recognized by "registry" so we can register them
//         vaultRegistry.setIsEntityReturn(true);

//         // Setup operator registry to always return "true" => is operator
//         operatorRegistry.setRegisteredReturn(true);

//         // Deploy the middleware
//         AvalancheL1MiddlewareSettings memory settings = AvalancheL1MiddlewareSettings({
//             l1ValidatorManager: address(0x1234),
//             operatorRegistry: address(operatorRegistry),
//             vaultRegistry: address(vaultRegistry),
//             operatorL1Optin: address(0x7777),
//             epochDuration: 3 hours,
//             slashingWindow: 4 hours
//         });

//         // Example constructor arguments for AssetClassManager:
//         uint256 maxStake = 1_000_000 ether;
//         uint256 primaryMinStake = 10_000 ether;
//         uint256 secondaryMinStake = 5_000 ether;

//         middleware = new AvalancheL1Middleware(
//             settings,
//             owner,
//             maxStake,
//             primaryMinStake,
//             secondaryMinStake
//         );

//         vm.stopPrank();
//     }

//     function testConstructorValues() public {
//         // Slashing window check
//         assertEq(middleware.SLASHING_WINDOW(), 4 hours);
//         // epochDuration
//         assertEq(middleware.EPOCH_DURATION(), 3 hours);

//         // Check start time (roughly block.timestamp within the same block)
//         uint256 blockTime = block.timestamp;
//         assertApproxEqAbs(middleware.START_TIME(), blockTime, 2);

//         // The rest are direct from the settings
//         assertEq(middleware.L1_VALIDATOR_MANAGER(), address(0x1234));
//     }

//     function testRegisterOperatorSuccess() public {
//         bytes32 pubkey = keccak256("myPubKey");

//         vm.startPrank(owner);
//         middleware.registerOperator(operator, pubkey);
//         vm.stopPrank();

//         // We can't query "operators" directly as it's private. 
//         // But we can verify no revert => success. 
//         // Ideally you'd expose a public method or event logs to confirm.
//         // For example, we might do an action that fails if operator not recognized...
//         // Here we just assume success if no revert.
//     }

//     function testRegisterOperatorRevertIfNotOperator() public {
//         // Make registry return false => not an operator
//         operatorRegistry.setRegisteredReturn(false);
//         bytes32 pubkey = keccak256("myPubKey");

//         vm.startPrank(owner);
//         vm.expectRevert(AvalancheL1Middleware.AvalancheL1Middleware__NotOperator.selector);
//         middleware.registerOperator(operator, pubkey);
//         vm.stopPrank();
//     }

//     function testRegisterVaultAndSetMaxL1Limit() public {
//         // registerVault calls `_setVaultMaxL1Limit`
//         // which calls delegator.setMaxL1Limit(OWNER, assetClassId, amount)
//         // so we can check it from delegator mock

//         // Let’s pick a random assetClassId
//         uint96 assetClassId = 42;

//         vm.startPrank(owner);
//         // We expect it to pass successfully
//         middleware.registerVault(address(vaultInstant), assetClassId);

//         // Confirm the delegator got setMaxL1Limit() with the chosen assetClassId + maxValidatorStake
//         // Because the contract sets `_setVaultMaxL1Limit(vault, assetClassId, maxValidatorStake)`
//         // in registerVault
//         // (We store maxValidatorStake in the parent AssetClassManager.)
//         // 
//         // In this example, the new contract has 
//         //   `uint32 private minValidatorStake;`
//         //   `uint32 private maxValidatorStake;`
//         //
//         // If you need to expose them, you can do so in the AssetClassManager or in tests
//         // we can only verify from the mock delegator:

//         uint256 storedLimit = delegator.maxL1Limit(owner, assetClassId);
//         // By default, in your code, `maxValidatorStake` is uninitialized or 0 
//         // unless you set it inside the AssetClassManager logic.
//         // If you want to test a known value, you might store it in your contract 
//         // or retrieve it from a public getter.

//         // If your contract sets something like this in the constructor:
//         //    maxValidatorStake = uint32(_MaxStake);
//         // Then:
//         // storedLimit should equal _MaxStake passed in the constructor, i.e. 1_000_000 ether in setUp.

//         assertEq(storedLimit, 1_000_000 ether);

//         vm.stopPrank();
//     }

//     function testGetOperatorStakeAndCaching() public {
//         // We'll set up a scenario where operator has some stake in vaultInstant
//         // We'll call getOperatorStake first => expect it to read from delegator
//         // Then call again => verify it's cached?

//         // Prepare mock stake
//         // subnetwork 0 => 100 tokens, subnetwork 1 => 200 tokens => total 300
//         // (In your code these are "asset classes", but we call them subnetwork = 0 / 1)
//         delegator.setStakeAt(address(middleware.L1_VALIDATOR_MANAGER()), 0, operator, uint48(block.timestamp), 100);
//         delegator.setStakeAt(address(middleware.L1_VALIDATOR_MANAGER()), 1, operator, uint48(block.timestamp), 200);

//         vm.startPrank(owner);
//         // Need to register the vault, so it’s recognized
//         middleware.registerVault(address(vaultInstant), 0);
//         vm.stopPrank();

//         uint48 epoch = middleware.getCurrentEpoch();
//         uint256 stake = middleware.getOperatorStake(operator, epoch);
//         assertEq(stake, 300);

//         // Check that getOperatorStake is cached now
//         (bool cachedBefore,) = middleware.totalStakeCached(epoch);
//         assertFalse(cachedBefore); 
//         // Because the caching actually occurs in `calcAndCacheStakes` or `submission`. 
//         // Right now it's only triggered by the `updateStakeCache` modifier or direct call.

//         // Force a direct caching call
//         vm.prank(owner);
//         middleware.calcAndCacheStakes(epoch);
//         (bool cachedAfter,) = middleware.totalStakeCached(epoch);
//         assertTrue(cachedAfter);

//         // Now, if we change the underlying stake in delegator, it won't reflect unless we reset the cache or move epoch
//         delegator.setStakeAt(address(middleware.L1_VALIDATOR_MANAGER()), 0, operator, uint48(block.timestamp), 999);
//         uint256 stake2 = middleware.getOperatorStake(operator, epoch);
//         // We expect the old cached value => 300
//         assertEq(stake2, 300);
//     }

//     function testSlashBasic() public {
//         // We test the slash flow to ensure no reverts
//         // In reality you’d test amounts being pro-rated, events, etc.
//         // Let’s register vaultInstant as if it had stake
//         vm.startPrank(owner);
//         middleware.registerVault(address(vaultInstant), 0);
//         vm.stopPrank();

//         // Place some stake in subnetwork 0/1 for the operator
//         // Then slash => confirm no revert
//         delegator.setStakeAt(address(middleware.L1_VALIDATOR_MANAGER()), 0, operator, uint48(block.timestamp), 600);
//         delegator.setStakeAt(address(middleware.L1_VALIDATOR_MANAGER()), 1, operator, uint48(block.timestamp), 400);

//         uint48 epoch = middleware.getCurrentEpoch();
//         uint256 totalStake = middleware.getOperatorStake(operator, epoch);
//         assertEq(totalStake, 1000);

//         // Perform slash
//         vm.startPrank(owner);
//         middleware.slash(epoch, operator, 100);
//         vm.stopPrank();
//         // Confirm no revert => success. 
//         // In an advanced test, you’d check calls to slasher(s).
//     }
// }
