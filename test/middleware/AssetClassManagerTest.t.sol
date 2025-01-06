// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {AssetClassManager} from "../../src/contracts/middleware/AssetClassManager.sol";
import {IAssetClassManager} from "../../src/interfaces/middleware/IAssetClassManager.sol";

contract AssetClassManagerTest is Test {
    AssetClassManager assetClassManager;

    address owner;
    address alice;
    address bob;

    function setUp() public {
        owner = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        assetClassManager = new AssetClassManager(
            1000, // _maxStake
            50,   // _primaryMinStake
            10    // _secondaryMinStake
        );
    }

    function test_ConstructorInitialValues() public view {
        address[] memory initialPrimaryTokens = assetClassManager.getPrimaryTokens();
        address[] memory initialSecondaryTokens = assetClassManager.getSecondaryTokens();
        
        assertEq(initialPrimaryTokens.length, 0, "Expected no primary tokens at start");
        assertEq(initialSecondaryTokens.length, 0, "Expected no secondary tokens at start");
    }

    function test_AddPrimaryToken() public {
        assetClassManager.addPrimaryToken(alice);

        address[] memory primaryTokens = assetClassManager.getPrimaryTokens();
        assertEq(primaryTokens.length, 1, "Expected 1 primary token after adding");
        assertEq(primaryTokens[0], alice, "Expected token to match 'alice' address");
    }

    function test_AddPrimaryTokenRevertIfInvalid() public {
        vm.expectRevert(IAssetClassManager.AssetClassManager__InvalidToken.selector);
        assetClassManager.addPrimaryToken(address(0));
    }

    function test_RemovePrimaryToken() public {
        assetClassManager.addPrimaryToken(alice);
        assetClassManager.removePrimaryToken(alice);

        address[] memory primaryTokens = assetClassManager.getPrimaryTokens();
        assertEq(primaryTokens.length, 0, "Expected no primary tokens after removing");
    }

    function test_AddSecondaryToken() public {
        assetClassManager.addSecondaryToken(bob);

        address[] memory secondaryTokens = assetClassManager.getSecondaryTokens();
        assertEq(secondaryTokens.length, 1, "Expected 1 secondary token after adding");
        assertEq(secondaryTokens[0], bob, "Expected token to match 'bob' address");
    }

    function test_AddSecondaryTokenRevertIfInvalid() public {
        vm.expectRevert(IAssetClassManager.AssetClassManager__InvalidToken.selector);
        assetClassManager.addSecondaryToken(address(0));
    }

    function test_RemoveSecondaryToken() public {
        assetClassManager.addSecondaryToken(bob);

        assetClassManager.removeSecondaryToken(bob);

        address[] memory secondaryTokens = assetClassManager.getSecondaryTokens();
        assertEq(secondaryTokens.length, 0, "Expected no secondary tokens after removing");
    }

    function test_GetPrimaryTokensMultiple() public {
        address token1 = makeAddr("token1");
        address token2 = makeAddr("token2");
        address token3 = makeAddr("token3");

        assetClassManager.addPrimaryToken(token1);
        assetClassManager.addPrimaryToken(token2);
        assetClassManager.addPrimaryToken(token3);

        address[] memory primaryTokens = assetClassManager.getPrimaryTokens();
        assertEq(primaryTokens.length, 3, "Expected 3 primary tokens after adding");

        bool foundToken1;
        bool foundToken2;
        bool foundToken3;
        for (uint256 i = 0; i < primaryTokens.length; i++) {
            if (primaryTokens[i] == token1) foundToken1 = true;
            if (primaryTokens[i] == token2) foundToken2 = true;
            if (primaryTokens[i] == token3) foundToken3 = true;
        }
        assertTrue(foundToken1, "token1 not found in primary tokens");
        assertTrue(foundToken2, "token2 not found in primary tokens");
        assertTrue(foundToken3, "token3 not found in primary tokens");
    }

    function test_GetSecondaryTokensMultiple() public {
        address tokenA = makeAddr("tokenA");
        address tokenB = makeAddr("tokenB");
        address tokenC = makeAddr("tokenC");

        assetClassManager.addSecondaryToken(tokenA);
        assetClassManager.addSecondaryToken(tokenB);
        assetClassManager.addSecondaryToken(tokenC);

        address[] memory secondaryTokens = assetClassManager.getSecondaryTokens();
        assertEq(secondaryTokens.length, 3, "Expected 3 secondary tokens after adding");

        bool foundTokenA;
        bool foundTokenB;
        bool foundTokenC;
        for (uint256 i = 0; i < secondaryTokens.length; i++) {
            if (secondaryTokens[i] == tokenA) foundTokenA = true;
            if (secondaryTokens[i] == tokenB) foundTokenB = true;
            if (secondaryTokens[i] == tokenC) foundTokenC = true;
        }
        assertTrue(foundTokenA, "tokenA not found in secondary tokens");
        assertTrue(foundTokenB, "tokenB not found in secondary tokens");
        assertTrue(foundTokenC, "tokenC not found in secondary tokens");
    }
}
