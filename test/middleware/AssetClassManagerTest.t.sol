// // SPDX-License-Identifier: MIT
// pragma solidity 0.8.25;

// import {Test, console2} from "forge-std/Test.sol";
// import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

// import {AssetClassRegistry} from "../../src/contracts/middleware/AssetClassRegistry.sol";
// import {IAssetClassRegistry} from "../../src/interfaces/middleware/IAssetClassRegistry.sol";

// contract AssetClassRegistryTest is Test {
//     AssetClassRegistry assetClassRegistry;

//     address owner;
//     address alice;
//     address bob;
//     address tokenA;
//     address tokenB;
//     address tokenC;

//     function setUp() public {
//         owner = address(this);
//         alice = makeAddr("alice");
//         bob   = makeAddr("bob");
//         tokenA = makeAddr("tokenA");
//         tokenB = makeAddr("tokenB");
//         tokenC = makeAddr("tokenC");

//         // Deploy the new AssetClassRegistry
//         // The constructor automatically creates class "1" with:
//         // - minValidatorStake = 50
//         // - maxValidatorStake = 1000
//         assetClassRegistry = new AssetClassRegistry(1000, 50, tokenA);

//         // For a "secondary" class, add class ID #2
//         // with min = 10, max = 0
//         assetClassRegistry._addAssetClass(2, 10, 0);
//     }

//     function test_DefaultClass1Values() public view {
//         // Class 1 is auto-created in the constructor
//         uint256 minStake = assetClassRegistry.getMinValidatorStake(1);
//         uint256 maxStake = assetClassRegistry.getMaxValidatorStake(1);
//         assertEq(minStake, 50,  "Expected minStake = 50 for class 1");
//         assertEq(maxStake, 1000, "Expected maxStake = 1000 for class 1");
//     }

//     function test_DefaultAssetIsInClass1() public view {
//         address[] memory assets = assetClassRegistry.getClassAssets(1);
//         assertEq(assets.length, 1, "Expected exactly 1 default asset in class 1");
//         assertEq(assets[0], tokenA, "Expected tokenA to be in class 1 as default asset");
//     }

//     function test_RevertOnRemoveDefaultAssetFromClass1() public {
//         // Trying to remove the default asset (tokenA) from class #1 must revert
//         vm.expectRevert(IAssetClassRegistry.AssetClassRegistry__AssetIsDefaultAsset.selector);
//         assetClassRegistry._removeAssetFromClass(1, tokenA);
//     }

//     function test__addAssetToClass1() public {
//         // Add something other than the default asset
//         assetClassRegistry._addAssetToClass(1, tokenB);
//         address[] memory assets = assetClassRegistry.getClassAssets(1);
//         // Now we should have tokenA (default) + tokenB
//         assertEq(assets.length, 2, "Expected 2 assets in class 1");
//     }

//     function test_MultipleAssetsInClass1() public {
//         assetClassRegistry._addAssetToClass(1, tokenB);
//         assetClassRegistry._addAssetToClass(1, tokenC);

//         address[] memory assets = assetClassRegistry.getClassAssets(1);
//         // We now have: tokenA (default), tokenB, tokenC
//         assertEq(assets.length, 3, "Expected 3 assets in class 1");

//         bool foundTokenA;
//         bool foundTokenB;
//         bool foundTokenC;
//         for (uint256 i = 0; i < assets.length; i++) {
//             if (assets[i] == tokenA)  foundTokenA = true;
//             if (assets[i] == tokenB)   foundTokenB  = true;
//             if (assets[i] == tokenC)     foundTokenC    = true;
//         }
//         assertTrue(foundTokenA, "tokenA (default) not found in class 1");
//         assertTrue(foundTokenB,  "tokenB not found in class 1");
//         assertTrue(foundTokenC,    "tokenC not found in class 1");
//     }

//     function test__addAssetToClass2() public {
//         assetClassRegistry._addAssetToClass(2, tokenB);
//         address[] memory assets = assetClassRegistry.getClassAssets(2);
//         assertEq(assets.length, 1, "Expected 1 asset in class 2");
//         assertEq(assets[0], tokenB, "Expected asset to match tokenB");
//     }

//     function test__removeAssetFromClass1() public {
//         // Add an asset (alice) to class #1
//         assetClassRegistry._addAssetToClass(1, tokenB);

//         // Remove alice (allowed because she's not the default asset)
//         assetClassRegistry._removeAssetFromClass(1, tokenB);

//         // Check that tokenA (default) is still there
//         address[] memory assets = assetClassRegistry.getClassAssets(1);
//         assertEq(assets.length, 1, "Expected 1 asset (the default) left in class 1");
//         assertEq(assets[0], tokenA, "Expected the default asset to remain in class 1");
//     }    

//     function test_RevertOn_addAssetToInvalidClass() public {
//         vm.expectRevert(IAssetClassRegistry.AssetClassRegistry__AssetClassNotFound.selector);
//         assetClassRegistry._addAssetToClass(999, alice);
//     }

//     function test_RevertOnAddZeroAddress() public {
//         vm.expectRevert(IAssetClassRegistry.AssetClassRegistry__InvalidAsset.selector);
//         assetClassRegistry._addAssetToClass(1, address(0));
//     }

//     function test_MultipleAssetsInClass2() public {
//         assetClassRegistry._addAssetToClass(2, tokenA);
//         assetClassRegistry._addAssetToClass(2, tokenB);
//         assetClassRegistry._addAssetToClass(2, tokenC);

//         address[] memory assets = assetClassRegistry.getClassAssets(2);
//         assertEq(assets.length, 3, "Expected 3 assets in class 2");

//         bool foundTokenA;
//         bool foundTokenB;
//         bool foundTokenC;
//         for (uint256 i = 0; i < assets.length; i++) {
//             if (assets[i] == tokenA) foundTokenA = true;
//             if (assets[i] == tokenB) foundTokenB = true;
//             if (assets[i] == tokenC) foundTokenC = true;
//         }
//         assertTrue(foundTokenA, "tokenA not found in class 2");
//         assertTrue(foundTokenB, "tokenB not found in class 2");
//         assertTrue(foundTokenC, "tokenC not found in class 2");
//     }

//     function test__removeAssetFromClass2() public {
//         assetClassRegistry._addAssetToClass(2, tokenB);
//         assetClassRegistry._removeAssetFromClass(2, tokenB);
//         address[] memory assets = assetClassRegistry.getClassAssets(2);
//         assertEq(assets.length, 0, "Expected no assets in class 2 after removal");
//     }

//     function test__addAssetClassAndCheckStakes() public {
//         // Add new class #3
//         assetClassRegistry._addAssetClass(3, 123, 456);
//         uint256 minStake = assetClassRegistry.getMinValidatorStake(3);
//         uint256 maxStake = assetClassRegistry.getMaxValidatorStake(3);
//         assertEq(minStake, 123, "Expected minStake = 123 for class 3");
//         assertEq(maxStake, 456, "Expected maxStake = 456 for class 3");
//     }

//     function test_RevertOnDuplicateAssetClass() public {
//         vm.expectRevert(IAssetClassRegistry.AssetClassRegistry__AssetClassAlreadyExists.selector);
//         // Class 1 and 2 already exist, so adding class 1 again reverts
//         assetClassRegistry._addAssetClass(1, 123, 456);
//     }

//     function test_RevertOnGetAssetsForNonexistentClass() public {
//         vm.expectRevert(IAssetClassRegistry.AssetClassRegistry__AssetClassNotFound.selector);
//         assetClassRegistry.getClassAssets(999);
//     }

//     function test_RevertOn_removeAssetFromInvalidClass() public {
//         vm.expectRevert(IAssetClassRegistry.AssetClassRegistry__AssetClassNotFound.selector);
//         assetClassRegistry._removeAssetFromClass(999, alice);
//     }

//     function test_RevertOnRemoveNonexistentAsset() public {
//         assetClassRegistry._addAssetToClass(1, alice);
//         // Try remove bob from class 1
//         vm.expectRevert(IAssetClassRegistry.AssetClassRegistry__AssetNotFound.selector);
//         assetClassRegistry._removeAssetFromClass(1, bob);
//     }

//     function test_RevertOnAddDuplicateAsset() public {
//         assetClassRegistry._addAssetToClass(1, alice);
//         vm.expectRevert(IAssetClassRegistry.AssetClassRegistry__AssetAlreadyRegistered.selector);
//         assetClassRegistry._addAssetToClass(1, alice);
//     }

//     function test_RevertOnGetMinStakeForNonExistentClass() public {
//         vm.expectRevert(IAssetClassRegistry.AssetClassRegistry__AssetClassNotFound.selector);
//         assetClassRegistry.getMinValidatorStake(999);
//     }

//     function test_RevertOnGetMaxStakeForNonExistentClass() public {
//         vm.expectRevert(IAssetClassRegistry.AssetClassRegistry__AssetClassNotFound.selector);
//         assetClassRegistry.getMaxValidatorStake(999);
//     }

// }
