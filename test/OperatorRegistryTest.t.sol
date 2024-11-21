// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {OperatorRegistry} from "../src/contracts/OperatorRegistry.sol";
import {IOperatorRegistry} from "../src/interfaces/IOperatorRegistry.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract OperatorRegistryTest is Test {
    address owner;
    address alice;
    string aliceMetadataURL = "https://alice.com";
    uint256 alicePrivateKey;
    address bob;
    string bobMetadataURL = "https://bob.com";
    uint256 bobPrivateKey;

    IOperatorRegistry registry;

    function setUp() public {
        owner = address(this);
        (alice, alicePrivateKey) = makeAddrAndKey("alice");
        (bob, bobPrivateKey) = makeAddrAndKey("bob");

        registry = new OperatorRegistry();
    }

    function testCreate() public view {
        // No operators should be registered initially
        assertEq(registry.totalOperators(), 0);
    }

    function testRegister() public {
        // Register Alice
        vm.prank(alice);
        registry.registerOperator(aliceMetadataURL);

        // Alice should be registered as an operator
        assertEq(registry.isRegistered(alice), true);
    }

    function testRegisterRevertAlreadyRegistered() public {
        // Register Alice
        vm.prank(alice);
        registry.registerOperator(aliceMetadataURL);

        // Alice tries to register again and it should revert
        vm.expectRevert(
            IOperatorRegistry
                .OperatorRegistry__OperatorAlreadyRegistered
                .selector
        );
        vm.prank(alice);
        registry.registerOperator(aliceMetadataURL);
    }

    function testGetAllOperatorsWhenNoneRegistered() public view {
        // No operators should be registered initially
        (address[] memory allOperators, string[] memory metadataURLs) = registry
            .getAllOperators();
        assertEq(allOperators.length, 0);
        assertEq(metadataURLs.length, 0);
    }

    function testRegisterMultipleOperators() public {
        // Alice registers
        vm.prank(alice);
        registry.registerOperator(aliceMetadataURL);

        // Bob registers
        vm.prank(bob);
        registry.registerOperator(bobMetadataURL);

        // Check that both Alice and Bob are registered
        assertEq(registry.totalOperators(), 2);
        assertEq(registry.isRegistered(alice), true);
        assertEq(registry.isRegistered(bob), true);
    }

    function testGetOperator() public {
        // Register Alice and Bob
        vm.prank(alice);
        registry.registerOperator(aliceMetadataURL);

        vm.prank(bob);
        registry.registerOperator(bobMetadataURL);

        // Check the operators and metadata URLs at specific indexes
        (address operator, string memory metadataURL) = registry.getOperatorAt(
            0
        );
        assertEq(operator, alice);
        assertEq(metadataURL, aliceMetadataURL);
        (operator, metadataURL) = registry.getOperatorAt(1);
        assertEq(operator, bob);
        assertEq(metadataURL, bobMetadataURL);
    }

    function testEventEmissionOnRegister() public {
        // Expect the RegisterOperator event to be emitted
        vm.expectEmit(true, true, true, true);
        emit IOperatorRegistry.RegisterOperator(alice, aliceMetadataURL);

        // Register Alice
        vm.prank(alice);
        registry.registerOperator(aliceMetadataURL);
    }

    function testLargeNumberOfRegistrations() public {
        // Register 1000 operators
        for (uint256 i = 0; i < 1000; i++) {
            vm.prank(address(uint160(i)));
            registry.registerOperator(
                string.concat("https://operator", Strings.toString(i))
            );
        }

        // Check that all 1000 operators are registered
        assertEq(registry.totalOperators(), 1000);
    }
}
