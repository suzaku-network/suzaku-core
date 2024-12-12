// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {L1Registry} from "../src/contracts/L1Registry.sol";
import {IL1Registry} from "../src/interfaces/IL1Registry.sol";
import {MockACP99Manager} from "test/mocks/MockACP99Manager.sol";

contract L1RegistryTest is Test {
    address owner;
    address l1Middleware1;
    string l1Middleware1MetadataURL;
    address l1Middleware2;
    string l1Middleware2MetadataURL;
    address l1Middleware1SecurityModule;
    address l1Middleware2SecurityModule;

    IL1Registry registry;
    MockACP99Manager mockACP99Manager;

    function setUp() public {
        owner = address(this);
        l1Middleware1 = makeAddr("l1Middleware1");
        l1Middleware1MetadataURL = "https://l1.com";
        l1Middleware2 = makeAddr("l1Middleware2");
        l1Middleware2MetadataURL = "https://l2.com";
        l1Middleware1SecurityModule = makeAddr("l1Middleware1SecurityModule");
        l1Middleware2SecurityModule = makeAddr("l1Middleware2SecurityModule");

        mockACP99Manager = new MockACP99Manager();
        registry = new L1Registry();
    }

    function testCreate() public view {
        // No L1s should be registered
        assertEq(registry.totalL1s(), 0);
    }

    function testGetAllL1sWhenNoneRegistered() public view {
        // No L1s should be registered
        (address[] memory allL1s, address[] memory middlewares, string[] memory metadataURLs) = registry.getAllL1s();
        assertEq(allL1s.length, 0);
        assertEq(middlewares.length, 0);
        assertEq(metadataURLs.length, 0);
    }

    function testRegister() public {
        // l1Middleware1 registers as an L1
        vm.prank(l1Middleware1);
        registry.registerL1(address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL);

        assertEq(registry.isRegistered(address(mockACP99Manager)), true);
    }

    function testRegisterWithInvalidACP99Manager() public {
        // Invalid ACP99Manager address (just a random address or an invalid contract)
        address invalidACP99Manager = address(0x123);

        // l1Middleware1 tries to register with an invalid ACP99Manager and it should revert.
        // Currently fails because the check is not implemented
        vm.prank(l1Middleware1);
        vm.expectRevert(IL1Registry.L1Registry__InvalidValidatorManager.selector);
        registry.registerL1(invalidACP99Manager, l1Middleware1SecurityModule, l1Middleware1MetadataURL);
    }

    function testRegisterRevertAlreadyRegistered() public {
        // Register l1Middleware1
        vm.prank(l1Middleware1);
        registry.registerL1(address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL);

        // l1Middleware1 tries to register again and it should revert
        vm.prank(l1Middleware1);
        vm.expectRevert(IL1Registry.L1Registry__L1AlreadyRegistered.selector);
        registry.registerL1(address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL);
    }

    function testRegisterWithZeroAddress() public {
        // Try to register address(0), which should revert
        // Currently fails because the check is not implemented
        vm.prank(l1Middleware1);
        vm.expectRevert(IL1Registry.L1Registry__InvalidValidatorManager.selector);
        registry.registerL1(address(0), l1Middleware1SecurityModule, l1Middleware1MetadataURL);
    }

    function testRegisterMultipleL1s() public {
        // l1Middleware1 registers
        vm.prank(l1Middleware1);
        registry.registerL1(address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL);

        // Create a new mock manager for l1Middleware2
        MockACP99Manager l1Middleware2Manager = new MockACP99Manager();

        // l1Middleware2 registers
        vm.prank(l1Middleware2);
        registry.registerL1(address(l1Middleware2Manager), l1Middleware2SecurityModule, l1Middleware2MetadataURL);

        // Check that both managers are registered
        assertEq(registry.totalL1s(), 2);
        assertEq(registry.isRegistered(address(mockACP99Manager)), true);
        assertEq(registry.isRegistered(address(l1Middleware2Manager)), true);
    }

    function testGetL1s() public {
        // Register l1Middleware1 and l1Middleware2
        vm.prank(l1Middleware1);
        registry.registerL1(address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL);

        MockACP99Manager l1Middleware2Manager = new MockACP99Manager();
        vm.prank(l1Middleware2);
        registry.registerL1(address(l1Middleware2Manager), l1Middleware2SecurityModule, l1Middleware2MetadataURL);

        // Check that both managers are registered
        (address[] memory allL1s, address[] memory middlewares, string[] memory metadataURLs) = registry.getAllL1s();
        assertEq(allL1s.length, 2);
        assertEq(allL1s[0], address(mockACP99Manager));
        assertEq(allL1s[1], address(l1Middleware2Manager));
        assertEq(middlewares[0], l1Middleware1SecurityModule);
        assertEq(middlewares[1], l1Middleware2SecurityModule);
        assertEq(metadataURLs[0], l1Middleware1MetadataURL);
        assertEq(metadataURLs[1], l1Middleware2MetadataURL);
    }

    function testGetL1At() public {
        // Register l1Middleware1 and l1Middleware2
        vm.prank(l1Middleware1);
        registry.registerL1(address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL);

        MockACP99Manager l1Middleware2Manager = new MockACP99Manager();
        vm.prank(l1Middleware2);
        registry.registerL1(address(l1Middleware2Manager), l1Middleware2SecurityModule, l1Middleware2MetadataURL);

        // Check the addresses and metadata URLs at specific indexes
        (address l10, address middleware0, string memory metadataURL0) = registry.getL1At(0);
        assertEq(l10, address(mockACP99Manager));
        assertEq(middleware0, l1Middleware1SecurityModule);
        assertEq(metadataURL0, l1Middleware1MetadataURL);
        (address l11, address middleware1, string memory metadataURL1) = registry.getL1At(1);
        assertEq(l11, address(l1Middleware2Manager));
        assertEq(middleware1, l1Middleware2SecurityModule);
        assertEq(metadataURL1, l1Middleware2MetadataURL);
    }

    function testZeroTotalL1s() public view {
        // No L1s should be registered
        assertEq(registry.totalL1s(), 0);
    }

    function testRegisterL1EmitsEvents() public {
        // Expect the RegisterL1 event to be emitted
        vm.expectEmit(true, true, true, true);
        emit IL1Registry.RegisterL1(address(mockACP99Manager));

        // Expect the SetL1Middleware event to be emitted
        vm.expectEmit(true, true, true, true);
        emit IL1Registry.SetL1Middleware(address(mockACP99Manager), l1Middleware1SecurityModule);

        // Expect the SetMetadataURL event to be emitted
        vm.expectEmit(true, true, true, true);
        emit IL1Registry.SetMetadataURL(address(mockACP99Manager), l1Middleware1MetadataURL);

        // Register l1Middleware1
        vm.prank(l1Middleware1);
        registry.registerL1(address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL);
    }

    function testLargeNumberOfRegistrations() public {
        // Register 1000 L1s
        for (uint256 i = 0; i < 1000; i++) {
            address manager = address(new MockACP99Manager());
            address middleware = address(uint160(i + 10000)); // Offset to avoid collisions
            vm.prank(address(uint160(i)));
            registry.registerL1(manager, middleware, l1Middleware1MetadataURL);
        }

        // Check that all 1000 L1s are registered
        assertEq(registry.totalL1s(), 1000);
    }

    function testSetL1Middleware() public {
        // First register an L1
        vm.prank(l1Middleware1);
        registry.registerL1(address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL);

        // Set new middleware
        address newMiddleware = makeAddr("newMiddleware");
        registry.setL1Middleware(address(mockACP99Manager), newMiddleware);

        // Check that middleware was updated
        (, address middleware,) = registry.getL1At(0);
        assertEq(middleware, newMiddleware);
    }

    function testSetL1MiddlewareRevertNotRegistered() public {
        // Try to set middleware for unregistered L1
        vm.expectRevert(IL1Registry.L1Registry__L1NotRegistered.selector);
        registry.setL1Middleware(address(mockACP99Manager), l1Middleware1SecurityModule);
    }

    function testSetL1MiddlewareEmitsEvent() public {
        // Register L1 first
        vm.prank(l1Middleware1);
        registry.registerL1(address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL);

        // Expect SetL1Middleware event
        address newMiddleware = makeAddr("newMiddleware");
        vm.expectEmit(true, true, true, true);
        emit IL1Registry.SetL1Middleware(address(mockACP99Manager), newMiddleware);

        registry.setL1Middleware(address(mockACP99Manager), newMiddleware);
    }

    function testSetMetadataURL() public {
        // First register an L1
        vm.prank(l1Middleware1);
        registry.registerL1(address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL);

        // Set new metadata URL
        string memory newMetadataURL = "https://newmetadata.com";
        registry.setMetadataURL(address(mockACP99Manager), newMetadataURL);

        // Check that metadata URL was updated
        (,, string memory metadataURL) = registry.getL1At(0);
        assertEq(metadataURL, newMetadataURL);
    }

    function testSetMetadataURLRevertNotRegistered() public {
        // Try to set metadata URL for unregistered L1
        vm.expectRevert(IL1Registry.L1Registry__L1NotRegistered.selector);
        registry.setMetadataURL(address(mockACP99Manager), "https://newmetadata.com");
    }

    function testSetMetadataURLEmitsEvent() public {
        // Register L1 first
        vm.prank(l1Middleware1);
        registry.registerL1(address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL);

        // Expect SetMetadataURL event
        string memory newMetadataURL = "https://newmetadata.com";
        vm.expectEmit(true, true, true, true);
        emit IL1Registry.SetMetadataURL(address(mockACP99Manager), newMetadataURL);

        registry.setMetadataURL(address(mockACP99Manager), newMetadataURL);
    }

    function testRegisterSubnetwork() public {
        // Registering a new subnetwork for a registered L1 should succeed
        vm.prank(l1Middleware1);
        registry.registerL1(address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL);
        bytes32 subnetwork = registry.registerSubnetwork(address(mockACP99Manager), 1);
        assertEq(registry.isRegisteredSubnetwork(subnetwork), true);
    }

    function testRegisterSubnetworkRevertNotRegistered() public {
        // Registering a subnetwork for an unregistered L1 should revert
        vm.expectRevert(IL1Registry.L1Registry__L1NotRegistered.selector);
        registry.registerSubnetwork(address(mockACP99Manager), 1);
    }

    function testRegisterSubnetworkRevertAlreadyRegistered() public {
        // Registering an already registered subnetwork should revert
        vm.prank(l1Middleware1);
        registry.registerL1(address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL);
        bytes32 subnetwork = registry.registerSubnetwork(address(mockACP99Manager), 1);
        vm.expectRevert(abi.encodeWithSelector(IL1Registry.L1Registry__SubnetworkAlreadyRegistered.selector, subnetwork));
        registry.registerSubnetwork(address(mockACP99Manager), 1);
    }

    function testGetSubnetwork() public {
        // Getting an existing subnetwork's data should succeed
        vm.prank(l1Middleware1);
        registry.registerL1(address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL);
        bytes32 subnetwork = registry.registerSubnetwork(address(mockACP99Manager), 1);
        (address vManager, uint256 id) = registry.getSubnetwork(subnetwork);
        assertEq(vManager, address(mockACP99Manager));
        assertEq(id, 1);
    }

    function testGetSubnetworkRevertNotRegistered() public {
        // Getting a non-existent subnetwork should revert
        bytes32 unregistered = keccak256(abi.encodePacked(address(mockACP99Manager), uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(IL1Registry.L1Registry__SubnetworkNotRegistered.selector, unregistered));
        registry.getSubnetwork(unregistered);
    }

    function testGetSubnetworkByParams() public {
        // Getting a subnetwork by its parameters should succeed if registered
        vm.prank(l1Middleware1);
        registry.registerL1(address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL);
        bytes32 subnetwork = registry.registerSubnetwork(address(mockACP99Manager), 2);
        bytes32 fetched = registry.getSubnetworkByParams(address(mockACP99Manager), 2);
        assertEq(fetched, subnetwork);
    }

    function testGetSubnetworkByParamsRevert() public {
        // Getting a subnetwork by parameters for a non-existent one should revert
        bytes32 expectedSubnetwork = keccak256(abi.encodePacked(address(mockACP99Manager), uint256(2)));
        vm.expectRevert(abi.encodeWithSelector(IL1Registry.L1Registry__SubnetworkNotRegistered.selector, expectedSubnetwork));
        registry.getSubnetworkByParams(address(mockACP99Manager), 2);
    }

    function testGetAllSubnetworks() public {
        // Should return all registered subnetworks
        vm.prank(l1Middleware1);
        registry.registerL1(address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL);

        MockACP99Manager anotherManager = new MockACP99Manager();
        vm.prank(l1Middleware2);
        registry.registerL1(address(anotherManager), l1Middleware2SecurityModule, l1Middleware2MetadataURL);

        bytes32 s1 = registry.registerSubnetwork(address(mockACP99Manager), 1);
        bytes32 s2 = registry.registerSubnetwork(address(anotherManager), 10);
        bytes32 s3 = registry.registerSubnetwork(address(mockACP99Manager), 2);

        (bytes32[] memory subs, address[] memory managers, uint256[] memory ids) = registry.getAllSubnetworks();
        assertEq(subs.length, 3);
        assertEq(managers.length, 3);
        assertEq(ids.length, 3);

        assertEq(subs[0], s1);
        assertEq(managers[0], address(mockACP99Manager));
        assertEq(ids[0], 1);

        assertEq(subs[1], s2);
        assertEq(managers[1], address(anotherManager));
        assertEq(ids[1], 10);

        assertEq(subs[2], s3);
        assertEq(managers[2], address(mockACP99Manager));
        assertEq(ids[2], 2);
    }

    function testRemoveSubnetworkRevertWhenRegistered() public {
        // Trying to remove a subnetwork that is registered should revert
        vm.prank(l1Middleware1);
        registry.registerL1(address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL);
        bytes32 subnetwork = registry.registerSubnetwork(address(mockACP99Manager), 1);
        vm.expectRevert(abi.encodeWithSelector(IL1Registry.L1Registry__SubnetworkAlreadyRegistered.selector, subnetwork));
        registry.removeSubnetwork(subnetwork);
    }

    function testRemoveSubnetworkSuccessWhenNotRegistered() public {
        // Removing an unregistered subnetwork should not revert
        bytes32 subnetwork = keccak256(abi.encodePacked(address(mockACP99Manager), uint256(1)));
        registry.removeSubnetwork(subnetwork);
    }
}
