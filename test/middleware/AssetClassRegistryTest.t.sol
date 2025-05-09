// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {AssetClassRegistry} from "../../src/contracts/middleware/AssetClassRegistry.sol";
import {IAssetClassRegistry} from "../../src/interfaces/middleware/IAssetClassRegistry.sol";
import {MockAssetClassRegistry} from "../mocks/MockAssetClassRegistry.sol";

contract AssetClassRegistryTest is Test {
    MockAssetClassRegistry assetClassRegistry;

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

        // Deploy the new child AssetClassRegistry
        assetClassRegistry = new MockAssetClassRegistry(owner);
        // Deploy the new AssetClassRegistry
        // The constructor automatically creates class "1" with:
        // - minValidatorStake = 50
        // - maxValidatorStake = 1000
        // assetClassRegistry = new AssetClassRegistry(1000, 50, tokenA);

        // Manually add a primary asset to class and primary asset with tokenA
        assetClassRegistry.addAssetClass(1, 50, 1000, tokenA);
        // declare primaryAsset from assetClassRegistry as tokenA
        assetClassRegistry.setPrimaryAsset(address(tokenA));

        // Add a "secondary" class #2
        assetClassRegistry.addAssetClass(2, 10, 0, tokenB);
    }

    function test_DefaultClass1Values() public view {
        // Class 1 is auto-created in the constructor
        (uint256 primaryAssetMinStake, uint256 primaryAssetMaxStake) = assetClassRegistry.getClassStakingRequirements(1);
        assertEq(primaryAssetMinStake, 50, "Expected primaryAssetMinStake = 50 for class 1");
        assertEq(primaryAssetMaxStake, 1000, "Expected primaryAssetMaxStake = 1000 for class 1");
    }

    function test_PrimaryAssetIsInClass1() public view {
        address[] memory assets = assetClassRegistry.getClassAssets(1);
        assertEq(assets.length, 1, "Expected exactly 1 default asset in class 1");
        assertEq(assets[0], tokenA, "Expected tokenA to be in class 1 as default asset");
    }

    // Should be moved to the AvalancheL1MiddlewareTest Test

    function test_RevertOnRemovePrimaryAssetFromClass1() public {
        // Trying to remove the default asset (tokenA) from class #1 must revert
        vm.expectRevert(
            abi.encodeWithSelector(IAssetClassRegistry.AssetClassRegistry__AssetIsPrimaryAssetClass.selector, 1)
        );
        assetClassRegistry.removeAssetFromClass(1, tokenA);
    }

    function test__addAssetToClass1() public {
        // Add something other than the default asset
        assetClassRegistry.addAssetToClass(1, tokenB);
        address[] memory assets = assetClassRegistry.getClassAssets(1);
        // Now we should have tokenA (default) + tokenB
        assertEq(assets.length, 2, "Expected 2 assets in class 1");
    }

    function test_MultipleAssetsInClass1() public {
        assetClassRegistry.addAssetToClass(1, tokenB);
        assetClassRegistry.addAssetToClass(1, tokenC);

        address[] memory assets = assetClassRegistry.getClassAssets(1);
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
        assetClassRegistry.addAssetToClass(2, tokenC);
        address[] memory assets = assetClassRegistry.getClassAssets(2);
        assertEq(assets.length, 2, "Expected 1 asset in class 2");
        assertEq(assets[0], tokenB, "Expected asset to match tokenB");
    }

    function test__removeAssetFromClass1() public {
        // Add an asset (alice) to class #1
        assetClassRegistry.addAssetToClass(1, tokenB);

        // Remove alice (allowed because she's not the default asset)
        assetClassRegistry.removeAssetFromClass(1, tokenB);

        // Check that tokenA (default) is still there
        address[] memory assets = assetClassRegistry.getClassAssets(1);
        assertEq(assets.length, 1, "Expected 1 asset (the default) left in class 1");
        assertEq(assets[0], tokenA, "Expected the default asset to remain in class 1");
    }

    function test_RevertOn_addAssetToInvalidClass() public {
        vm.expectRevert(IAssetClassRegistry.AssetClassRegistry__AssetClassNotFound.selector);
        assetClassRegistry.addAssetToClass(999, alice);
    }

    function test_RevertOnAddZeroAddress() public {
        vm.expectRevert(IAssetClassRegistry.AssetClassRegistry__InvalidAsset.selector);
        assetClassRegistry.addAssetToClass(1, address(0));
    }

    function test_MultipleAssetsInClass2() public {
        assetClassRegistry.addAssetToClass(2, tokenA);
        assetClassRegistry.addAssetToClass(2, tokenC);
        // tokenB already in class 2

        address[] memory assets = assetClassRegistry.getClassAssets(2);
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
        assetClassRegistry.addAssetToClass(2, tokenC);
        assetClassRegistry.removeAssetFromClass(2, tokenC);
        address[] memory assets = assetClassRegistry.getClassAssets(2);
        assertEq(assets.length, 1, "Expected no assets in class 2 after removal");
    }

    function test__addAssetClassAndCheckStakes() public {
        // Add new class #3
        assetClassRegistry.addAssetClass(3, 123, 456, address(tokenC));

        (uint256 primaryAssetMinStake, uint256 primaryAssetMaxStake) = assetClassRegistry.getClassStakingRequirements(3);
        assertEq(primaryAssetMinStake, 123, "Expected primaryAssetMinStake = 123 for class 3");
        assertEq(primaryAssetMaxStake, 456, "Expected primaryAssetMaxStake = 456 for class 3");
    }

    function test_RevertOnDuplicateAssetClass() public {
        vm.expectRevert(IAssetClassRegistry.AssetClassRegistry__AssetClassAlreadyExists.selector);
        // Class 1 and 2 already exist, so adding class 1 again reverts
        assetClassRegistry.addAssetClass(1, 123, 456, tokenA);
    }

    function test_RevertOnGetAssetsForNonexistentClass() public {
        vm.expectRevert(IAssetClassRegistry.AssetClassRegistry__AssetClassNotFound.selector);
        assetClassRegistry.getClassAssets(999);
    }

    function test_RevertOn_removeAssetFromInvalidClass() public {
        vm.expectRevert(IAssetClassRegistry.AssetClassRegistry__AssetClassNotFound.selector);
        assetClassRegistry.removeAssetFromClass(999, alice);
    }

    function test_RevertOnRemoveNonexistentAsset() public {
        assetClassRegistry.addAssetToClass(1, alice);
        // Try remove bob from class 1
        vm.expectRevert(IAssetClassRegistry.AssetClassRegistry__AssetNotFound.selector);
        assetClassRegistry.removeAssetFromClass(1, bob);
    }

    function test_RevertOnAddDuplicateAsset() public {
        assetClassRegistry.addAssetToClass(1, alice);
        vm.expectRevert(IAssetClassRegistry.AssetClassRegistry__AssetAlreadyRegistered.selector);
        assetClassRegistry.addAssetToClass(1, alice);
    }

    function test_RevertOnGetMinStakeForNonExistentClass() public {
        vm.expectRevert(IAssetClassRegistry.AssetClassRegistry__AssetClassNotFound.selector);
        assetClassRegistry.getClassStakingRequirements(999);
    }

    function test_GetAssetClassIds() public {
        // Add a new asset class #3
        assetClassRegistry.addAssetClass(3, 100, 1000, tokenC);

        // Get all asset class IDs
        uint96[] memory assetClassIds = assetClassRegistry.getAssetClassIds();

        // We should have 3 classes (1, 2, and 3)
        assertEq(assetClassIds.length, 3, "Expected 3 asset classes");

        // Check that all expected class IDs are present
        bool found1;
        bool found2;
        bool found3;

        for (uint256 i = 0; i < assetClassIds.length; i++) {
            if (assetClassIds[i] == 1) found1 = true;
            if (assetClassIds[i] == 2) found2 = true;
            if (assetClassIds[i] == 3) found3 = true;
        }

        assertTrue(found1, "Asset class 1 not found");
        assertTrue(found2, "Asset class 2 not found");
        assertTrue(found3, "Asset class 3 not found");
    }
}
