// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {L1Registry} from "../src/contracts/L1Registry.sol";
import {IL1Registry} from "../src/interfaces/IL1Registry.sol";
import {MockACP99Manager} from "test/mocks/MockACP99Manager.sol";

contract L1RegistryTest is Test {
    address owner;
    address alice;
    uint256 alicePrivateKey;
    address bob;
    uint256 bobPrivateKey;

    IL1Registry registry;
    MockACP99Manager mockACP99Manager;

    function setUp() public {
        owner = address(this);
        (alice, alicePrivateKey) = makeAddrAndKey("alice");
        (bob, bobPrivateKey) = makeAddrAndKey("bob");

        mockACP99Manager = new MockACP99Manager();
        registry = new L1Registry(); // Moved here to ensure fresh contract before each test
    }

    function testCreate() public view {
        // No L1s should be registered
        assertEq(registry.totalL1s(), 0);
    }

    function testGetAllL1sWhenNoneRegistered() public view {
        // No L1s should be registered
        address[] memory allL1s = registry.getAllL1s();
        assertEq(allL1s.length, 0);
    }

    function testRegister() public {
        // Alice registers herself as an L1
        vm.startPrank(alice);
        registry.registerL1(address(mockACP99Manager));
        vm.stopPrank();

        assertEq(registry.isRegistered(alice), true);
    }

    function testRegisterWithInvalidACP99Manager() public {
        // Invalid ACP99Manager address (just a random address or an invalid contract)
        address invalidACP99Manager = address(0x123);

        // Alice tries to register with an invalid ACP99Manager and it should revert.
        // Currently fails because the check is not implemented 
        vm.startPrank(alice);
        vm.expectRevert(IL1Registry.L1Registry__InvalidACP99Manager.selector);
        registry.registerL1(invalidACP99Manager);
        vm.stopPrank();
    }   

    function testRegisterRevertAlreadyRegistered() public {
        // Register Alice
        vm.startPrank(alice);
        registry.registerL1(address(mockACP99Manager));
        vm.stopPrank();

        // Alice tries to register again and it should revert
        vm.startPrank(alice);
        vm.expectRevert(IL1Registry.L1Registry__L1AlreadyRegistered.selector);
        registry.registerL1(address(mockACP99Manager));
        vm.stopPrank();
    }

    function testRegisterWithZeroAddress() public {
        // Try to register address(0), which should revert
        // Currently fails because the check is not implemented
        vm.startPrank(alice);
        vm.expectRevert(IL1Registry.L1Registry__InvalidACP99Manager.selector);
        registry.registerL1(address(0));
        vm.stopPrank();
    }

    function testRegisterMultipleL1s() public {
        // Alice registers
        vm.startPrank(alice);
        registry.registerL1(address(mockACP99Manager));
        vm.stopPrank();

        // Bob registers
        vm.startPrank(bob);
        registry.registerL1(address(mockACP99Manager));
        vm.stopPrank();

        // Check that both Alice and Bob are registered
        assertEq(registry.totalL1s(), 2);
        assertEq(registry.isRegistered(alice), true);
        assertEq(registry.isRegistered(bob), true);
    }

    function testGetL1s() public {
        // Register Alice and Bob
        vm.startPrank(alice);
        registry.registerL1(address(mockACP99Manager));
        vm.stopPrank();

        vm.startPrank(bob);
        registry.registerL1(address(mockACP99Manager));
        vm.stopPrank();

        // Check that both Alice and Bob are registered
        address[] memory allL1s = registry.getAllL1s();
        assertEq(allL1s.length, 2);
        assertEq(allL1s[0], alice);
        assertEq(allL1s[1], bob);
    }

    function testGetL1At() public {
        // Register Alice and Bob
        vm.startPrank(alice);
        registry.registerL1(address(mockACP99Manager));
        vm.stopPrank();

        vm.startPrank(bob);
        registry.registerL1(address(mockACP99Manager));
        vm.stopPrank();

        // Check the addresses at specific indexes
        assertEq(registry.getL1At(0), alice);
        assertEq(registry.getL1At(1), bob);
    }

    function testZeroTotalL1s() public view {
        // No L1s should be registered
        assertEq(registry.totalL1s(), 0);
    }

    function testEventEmissionOnRegister() public {
        // Expect the RegisterL1 event to be emitted
        vm.expectEmit(true, true, true, true);
        emit IL1Registry.RegisterL1(alice);

        // Register Alice
        vm.startPrank(alice);
        registry.registerL1(address(mockACP99Manager));
        vm.stopPrank();
    }

    function testLargeNumberOfRegistrations() public {
        // Register 1000 L1s
        for (uint256 i = 0; i < 1000; i++) {
            vm.startPrank(address(uint160(i)));
            registry.registerL1(address(mockACP99Manager));
            vm.stopPrank();
        }

        // Check that all 1000 L1s are registered
        assertEq(registry.totalL1s(), 1000);
    }
}
