// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {OperatorRegistry} from "../src/contracts/OperatorRegistry.sol";
import {IOperatorRegistry} from "../src/interfaces/IOperatorRegistry.sol";

contract OperatorRegistryTest is Test {
    address owner;
    address alice;
    uint256 alicePrivateKey;
    address bob;
    uint256 bobPrivateKey;

    IOperatorRegistry registry;

    function setUp() public {
        owner = address(this);
        (alice, alicePrivateKey) = makeAddrAndKey("alice");
        (bob, bobPrivateKey) = makeAddrAndKey("bob");

        registry = new OperatorRegistry();
    }

    function test_Create() public view {        
        // No operators should be registered initially
        assertEq(registry.totalOperators(), 0);
    }

    function test_Register() public {
        // Register Alice
        vm.startPrank(alice);
        registry.registerOperator();
        vm.stopPrank();

        // Alice should be registered as an operator
        assertEq(registry.isRegistered(alice), true);
    }

    function test_RegisterRevertAlreadyRegistered() public {
        // Register Alice
        vm.startPrank(alice);
        registry.registerOperator();
        vm.stopPrank();

        // Alice tries to register again and it should revert
        vm.expectRevert(IOperatorRegistry.OperatorRegistry__OperatorAlreadyRegistered.selector);
        vm.startPrank(alice);
        registry.registerOperator();
        vm.stopPrank();
    }

    function test_GetAllOperatorsWhenNoneRegistered() public view {
        // No operators should be registered initially
        address[] memory allOperators = registry.getAllOperators();
        assertEq(allOperators.length, 0);
    }

    function test_RegisterMultipleOperators() public {
        // Alice registers
        vm.startPrank(alice);
        registry.registerOperator();
        vm.stopPrank();

        // Bob registers
        vm.startPrank(bob);
        registry.registerOperator();
        vm.stopPrank();

        // Check that both Alice and Bob are registered
        assertEq(registry.totalOperators(), 2);
        assertEq(registry.isRegistered(alice), true);
        assertEq(registry.isRegistered(bob), true);
    }

    function test_GetOperatorAt() public {
        // Register Alice and Bob
        vm.startPrank(alice);
        registry.registerOperator();
        vm.stopPrank();

        vm.startPrank(bob);
        registry.registerOperator();
        vm.stopPrank();

        // Check the operators at specific indexes
        assertEq(registry.getOperatorAt(0), alice);
        assertEq(registry.getOperatorAt(1), bob);
    }

    function test_EventEmissionOnRegister() public {
        // Expect the RegisterOperator event to be emitted
        vm.expectEmit(true, true, true, true);
        emit IOperatorRegistry.RegisterOperator(alice);

        // Register Alice
        vm.startPrank(alice);
        registry.registerOperator();
        vm.stopPrank();
    }

    function test_LargeNumberOfRegistrations() public {
        // Register 1000 operators
        for (uint256 i = 0; i < 1000; i++) {
            vm.startPrank(address(uint160(i)));
            registry.registerOperator();
            vm.stopPrank();
        }

        // Check that all 1000 operators are registered
        assertEq(registry.totalOperators(), 1000);
    }
}
