// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {OperatorRegistry} from "../src/contracts/OperatorRegistry.sol";
import {IOperatorRegistry} from "../src/interfaces/IOperatorRegistry.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract OperatorRegistryTest is Test {
    address owner;
    address operator1;
    string operator1MetadataURL = "https://operator1.com";
    address operator2;
    string operator2MetadataURL = "https://operator2.com";

    IOperatorRegistry registry;

    function setUp() public {
        owner = address(this);
        operator1 = makeAddr("operator1");
        operator2 = makeAddr("operator2");

        registry = new OperatorRegistry();
    }

    function testCreate() public view {
        // No operators should be registered initially
        assertEq(registry.totalOperators(), 0);
    }

    function testRegister() public {
        // Register operator1
        vm.prank(operator1);
        registry.registerOperator(operator1MetadataURL);

        // operator1 should be registered as an operator
        assertEq(registry.isRegistered(operator1), true);
    }

    function testRegisterRevertAlreadyRegistered() public {
        // Register operator1
        vm.prank(operator1);
        registry.registerOperator(operator1MetadataURL);

        // operator1 tries to register again and it should revert
        vm.expectRevert(IOperatorRegistry.OperatorRegistry__OperatorAlreadyRegistered.selector);
        vm.prank(operator1);
        registry.registerOperator(operator1MetadataURL);
    }

    function testGetAllOperatorsWhenNoneRegistered() public view {
        // No operators should be registered initially
        (address[] memory allOperators, string[] memory metadataURLs) = registry.getAllOperators();
        assertEq(allOperators.length, 0);
        assertEq(metadataURLs.length, 0);
    }

    function testRegisterMultipleOperators() public {
        // operator1 registers
        vm.prank(operator1);
        registry.registerOperator(operator1MetadataURL);

        // operator2 registers
        vm.prank(operator2);
        registry.registerOperator(operator2MetadataURL);

        // Check that both operator1 and operator2 are registered
        assertEq(registry.totalOperators(), 2);
        assertEq(registry.isRegistered(operator1), true);
        assertEq(registry.isRegistered(operator2), true);
    }

    function testGetOperator() public {
        // Register operator1 and operator2
        vm.prank(operator1);
        registry.registerOperator(operator1MetadataURL);

        vm.prank(operator2);
        registry.registerOperator(operator2MetadataURL);

        // Check the operators and metadata URLs at specific indexes
        (address operator, string memory metadataURL) = registry.getOperatorAt(0);
        assertEq(operator, operator1);
        assertEq(metadataURL, operator1MetadataURL);
        (operator, metadataURL) = registry.getOperatorAt(1);
        assertEq(operator, operator2);
        assertEq(metadataURL, operator2MetadataURL);
    }

    function testRegisterEmitsEvents() public {
        // Expect the RegisterOperator event to be emitted
        vm.expectEmit(true, true, true, true);
        emit IOperatorRegistry.RegisterOperator(operator1);

        // Expect the SetMetadataURL event to be emitted
        vm.expectEmit(true, true, true, true);
        emit IOperatorRegistry.SetMetadataURL(operator1, operator1MetadataURL);

        // Register operator1
        vm.prank(operator1);
        registry.registerOperator(operator1MetadataURL);
    }

    function testLargeNumberOfRegistrations() public {
        // Register 1000 operators
        for (uint256 i = 0; i < 1000; i++) {
            vm.prank(address(uint160(i)));
            registry.registerOperator(string.concat("https://operator", Strings.toString(i)));
        }

        // Check that all 1000 operators are registered
        assertEq(registry.totalOperators(), 1000);
    }

    function testSetMetadataURL() public {
        // First register an operator
        vm.prank(operator1);
        registry.registerOperator(operator1MetadataURL);

        // Set new metadata URL
        string memory newMetadataURL = "https://newmetadata.com";
        vm.prank(operator1);
        registry.setMetadataURL(newMetadataURL);

        // Check that metadata URL was updated
        (, string memory metadataURL) = registry.getOperatorAt(0);
        assertEq(metadataURL, newMetadataURL);
    }

    function testSetMetadataURLRevertNotRegistered() public {
        // Try to set metadata URL for unregistered operator
        vm.prank(operator1);
        vm.expectRevert(IOperatorRegistry.OperatorRegistry__OperatorNotRegistered.selector);
        registry.setMetadataURL("https://newmetadata.com");
    }

    function testSetMetadataURLEmitsEvent() public {
        // Register operator first
        vm.prank(operator1);
        registry.registerOperator(operator1MetadataURL);

        // Expect SetMetadataURL event
        string memory newMetadataURL = "https://newmetadata.com";
        vm.expectEmit(true, true, true, true);
        emit IOperatorRegistry.SetMetadataURL(operator1, newMetadataURL);

        vm.prank(operator1);
        registry.setMetadataURL(newMetadataURL);
    }
}
