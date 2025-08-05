// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {CollateralClassRegistry} from "../../src/contracts/middleware/CollateralClassRegistry.sol";
import {ICollateralClassRegistry} from "../../src/interfaces/middleware/ICollateralClassRegistry.sol";
import {MockCollateralClassRegistry} from "../mocks/MockCollateralClassRegistry.sol";

contract CollateralClassRegistryTest is Test {
    MockCollateralClassRegistry collateralClassRegistry;

    address owner;
    address alice;
    address bob;
    address tokenA;
    address tokenB;
    address tokenC;

    function setUp() public {
        owner = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        tokenA = makeAddr("tokenA");
        tokenB = makeAddr("tokenB");
        tokenC = makeAddr("tokenC");

        // Deploy the new child CollateralClassRegistry
        collateralClassRegistry = new MockCollateralClassRegistry(owner);
        // Deploy the new CollateralClassRegistry
        // The constructor automatically creates class "1" with:
        // - minValidatorStake = 50
        // - maxValidatorStake = 1000
        // collateralClassRegistry = new CollateralClassRegistry(1000, 50, tokenA);

        // Manually add a primary collateral to class and primary collateral with tokenA
        collateralClassRegistry.addCollateralClass(1, 50, 1000, tokenA);
        // declare primaryCollateral from collateralClassRegistry as tokenA
        collateralClassRegistry.setPrimaryCollateral(address(tokenA));

        // Add a "secondary" class #2
        collateralClassRegistry.addCollateralClass(2, 10, 0, tokenB);
    }

    function test_DefaultClass1Values() public view {
        // Class 1 is auto-created in the constructor
        (uint256 primaryCollateralMinStake, uint256 primaryCollateralMaxStake) = collateralClassRegistry.getClassStakingRequirements(1);
        assertEq(primaryCollateralMinStake, 50, "Expected primaryCollateralMinStake = 50 for class 1");
        assertEq(primaryCollateralMaxStake, 1000, "Expected primaryCollateralMaxStake = 1000 for class 1");
    }

    function test_PrimaryCollateralIsInClass1() public view {
        address[] memory assets = collateralClassRegistry.getClassAssets(1);
        assertEq(assets.length, 1, "Expected exactly 1 default asset in class 1");
        assertEq(assets[0], tokenA, "Expected tokenA to be in class 1 as default asset");
    }

    // Should be moved to the AvalancheL1MiddlewareTest Test

    function test_RevertOnRemovePrimaryCollateralFromClass1() public {
        // Trying to remove the default asset (tokenA) from class #1 must revert
        vm.expectRevert(
            abi.encodeWithSelector(ICollateralClassRegistry.CollateralClassRegistry__AssetIsPrimaryCollateralClass.selector, 1)
        );
        collateralClassRegistry.removeAssetFromClass(1, tokenA);
    }

    function test__addAssetToClass1() public {
        // Add something other than the default asset
        collateralClassRegistry.addAssetToClass(1, tokenB);
        address[] memory assets = collateralClassRegistry.getClassAssets(1);
        // Now we should have tokenA (default) + tokenB
        assertEq(assets.length, 2, "Expected 2 assets in class 1");
    }

    function test_MultipleAssetsInClass1() public {
        collateralClassRegistry.addAssetToClass(1, tokenB);
        collateralClassRegistry.addAssetToClass(1, tokenC);

        address[] memory assets = collateralClassRegistry.getClassAssets(1);
        // We now have: tokenA (default), tokenB, tokenC
        assertEq(assets.length, 3, "Expected 3 assets in class 1");

        bool foundTokenA;
        bool foundTokenB;
        bool foundTokenC;
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i] == tokenA) foundTokenA = true;
            if (assets[i] == tokenB) foundTokenB = true;
            if (assets[i] == tokenC) foundTokenC = true;
        }
        assertTrue(foundTokenA, "tokenA (default) not found in class 1");
        assertTrue(foundTokenB, "tokenB not found in class 1");
        assertTrue(foundTokenC, "tokenC not found in class 1");
    }

    function test__addAssetToClass2() public {
        collateralClassRegistry.addAssetToClass(2, tokenC);
        address[] memory assets = collateralClassRegistry.getClassAssets(2);
        assertEq(assets.length, 2, "Expected 1 asset in class 2");
        assertEq(assets[0], tokenB, "Expected asset to match tokenB");
    }

    function test__removeAssetFromClass1() public {
        // Add an asset (alice) to class #1
        collateralClassRegistry.addAssetToClass(1, tokenB);

        // Remove alice (allowed because she's not the default asset)
        collateralClassRegistry.removeAssetFromClass(1, tokenB);

        // Check that tokenA (default) is still there
        address[] memory assets = collateralClassRegistry.getClassAssets(1);
        assertEq(assets.length, 1, "Expected 1 asset (the default) left in class 1");
        assertEq(assets[0], tokenA, "Expected the default asset to remain in class 1");
    }

    function test_RevertOn_addAssetToInvalidClass() public {
        vm.expectRevert(ICollateralClassRegistry.CollateralClassRegistry__CollateralClassNotFound.selector);
        collateralClassRegistry.addAssetToClass(999, alice);
    }

    function test_RevertOnAddZeroAddress() public {
        vm.expectRevert(ICollateralClassRegistry.CollateralClassRegistry__InvalidAsset.selector);
        collateralClassRegistry.addAssetToClass(1, address(0));
    }

    function test_MultipleAssetsInClass2() public {
        collateralClassRegistry.addAssetToClass(2, tokenA);
        collateralClassRegistry.addAssetToClass(2, tokenC);
        // tokenB already in class 2

        address[] memory assets = collateralClassRegistry.getClassAssets(2);
        assertEq(assets.length, 3, "Expected 3 assets in class 2");

        bool foundTokenA;
        bool foundTokenB;
        bool foundTokenC;
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i] == tokenA) foundTokenA = true;
            if (assets[i] == tokenB) foundTokenB = true;
            if (assets[i] == tokenC) foundTokenC = true;
        }
        assertTrue(foundTokenA, "tokenA not found in class 2");
        assertTrue(foundTokenB, "tokenB not found in class 2");
        assertTrue(foundTokenC, "tokenC not found in class 2");
    }

    function test__removeAssetFromClass2() public {
        collateralClassRegistry.addAssetToClass(2, tokenC);
        collateralClassRegistry.removeAssetFromClass(2, tokenC);
        address[] memory assets = collateralClassRegistry.getClassAssets(2);
        assertEq(assets.length, 1, "Expected no assets in class 2 after removal");
    }

    function test__addCollateralClassAndCheckStakes() public {
        // Add new class #3
        collateralClassRegistry.addCollateralClass(3, 123, 456, address(tokenC));

        (uint256 primaryCollateralMinStake, uint256 primaryCollateralMaxStake) = collateralClassRegistry.getClassStakingRequirements(3);
        assertEq(primaryCollateralMinStake, 123, "Expected primaryCollateralMinStake = 123 for class 3");
        assertEq(primaryCollateralMaxStake, 456, "Expected primaryCollateralMaxStake = 456 for class 3");
    }

    function test_RevertOnDuplicateCollateralClass() public {
        vm.expectRevert(ICollateralClassRegistry.CollateralClassRegistry__CollateralClassAlreadyExists.selector);
        // Class 1 and 2 already exist, so adding class 1 again reverts
        collateralClassRegistry.addCollateralClass(1, 123, 456, tokenA);
    }

    function test_RevertOnGetAssetsForNonexistentClass() public {
        vm.expectRevert(ICollateralClassRegistry.CollateralClassRegistry__CollateralClassNotFound.selector);
        collateralClassRegistry.getClassAssets(999);
    }

    function test_RevertOn_removeAssetFromInvalidClass() public {
        vm.expectRevert(ICollateralClassRegistry.CollateralClassRegistry__CollateralClassNotFound.selector);
        collateralClassRegistry.removeAssetFromClass(999, alice);
    }

    function test_RevertOnRemoveNonexistentAsset() public {
        collateralClassRegistry.addAssetToClass(1, alice);
        // Try remove bob from class 1
        vm.expectRevert(ICollateralClassRegistry.CollateralClassRegistry__AssetNotFound.selector);
        collateralClassRegistry.removeAssetFromClass(1, bob);
    }

    function test_RevertOnAddDuplicateAsset() public {
        collateralClassRegistry.addAssetToClass(1, alice);
        vm.expectRevert(ICollateralClassRegistry.CollateralClassRegistry__AssetAlreadyRegistered.selector);
        collateralClassRegistry.addAssetToClass(1, alice);
    }

    function test_RevertOnGetMinStakeForNonExistentClass() public {
        vm.expectRevert(ICollateralClassRegistry.CollateralClassRegistry__CollateralClassNotFound.selector);
        collateralClassRegistry.getClassStakingRequirements(999);
    }

    function test_GetCollateralClassIds() public {
        // Add a new asset class #3
        collateralClassRegistry.addCollateralClass(3, 100, 1000, tokenC);

        // Get all asset class IDs
        uint96[] memory collateralClassIds = collateralClassRegistry.getCollateralClassIds();

        // We should have 3 classes (1, 2, and 3)
        assertEq(collateralClassIds.length, 3, "Expected 3 asset classes");

        // Check that all expected class IDs are present
        bool found1;
        bool found2;
        bool found3;

        for (uint256 i = 0; i < collateralClassIds.length; i++) {
            if (collateralClassIds[i] == 1) found1 = true;
            if (collateralClassIds[i] == 2) found2 = true;
            if (collateralClassIds[i] == 3) found3 = true;
        }

        assertTrue(found1, "Asset class 1 not found");
        assertTrue(found2, "Asset class 2 not found");
        assertTrue(found3, "Asset class 3 not found");
    }
}
