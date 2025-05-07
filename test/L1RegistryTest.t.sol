// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {L1Registry} from "../src/contracts/L1Registry.sol";
import {IL1Registry} from "../src/interfaces/IL1Registry.sol";
import {MockACP99Manager} from "test/mocks/MockACP99Manager.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract DummySecurityModule is Ownable {
    constructor(
        address initialOwner
    ) Ownable(initialOwner) {}
}

// A simple contract to demonstrate a reverting fallback
contract RevertingFeeCollector {
    receive() external payable {
        revert("RevertingFeeCollector: fallback revert");
    }
}

contract L1RegistryTest is Test {
    address owner;
    address l1Middleware1;
    string l1Middleware1MetadataURL;
    address l1Middleware2;
    string l1Middleware2MetadataURL;
    address l1Middleware1SecurityModule;
    address l1Middleware2SecurityModule;
    address feeCollectorAddress;
    L1Registry registry;
    MockACP99Manager mockACP99Manager;
    uint256 registerFee;

    function setUp() public {
        owner = address(this);
        feeCollectorAddress = makeAddr("feeCollector");
        l1Middleware1 = makeAddr("l1Middleware1");
        vm.deal(l1Middleware1, 100 ether); // Give l1Middleware1 some funds
        l1Middleware1MetadataURL = "https://l1.com";
        l1Middleware2 = makeAddr("l1Middleware2");
        vm.deal(l1Middleware2, 100 ether); // Give l1Middleware2 some funds
        l1Middleware2MetadataURL = "https://l2.com";
        l1Middleware1SecurityModule = makeAddr("l1Middleware1SecurityModule");
        l1Middleware2SecurityModule = makeAddr("l1Middleware2SecurityModule");

        mockACP99Manager = new MockACP99Manager(l1Middleware1);

        DummySecurityModule secModule = new DummySecurityModule(l1Middleware1);
        l1Middleware1SecurityModule = address(secModule);

        DummySecurityModule secModule2 = new DummySecurityModule(l1Middleware2);
        l1Middleware2SecurityModule = address(secModule2);

        address payable feeCollector = payable(feeCollectorAddress);
        registerFee = 0.01 ether; // Set fee for tests
        uint256 MAX_FEE = 1 ether; // Max fee of 1 ether for tests
        registry = new L1Registry(feeCollector, registerFee, MAX_FEE, owner);
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
        registry.registerL1{value: registerFee}(
            address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL
        );

        assertEq(registry.isRegistered(address(mockACP99Manager)), true);
    }

    function testRegisterRevertAlreadyRegistered() public {
        // Register l1Middleware1
        vm.prank(l1Middleware1);
        registry.registerL1{value: registerFee}(
            address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL
        );

        // l1Middleware1 tries to register again and it should revert
        vm.prank(l1Middleware1);
        vm.expectRevert(IL1Registry.L1Registry__L1AlreadyRegistered.selector);
        registry.registerL1{value: registerFee}(
            address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL
        );
    }

    function testRegisterWithZeroAddress() public {
        // Try to register address(0), which should revert
        // Currently fails because the check is not implemented
        vm.prank(l1Middleware1);
        vm.expectRevert(abi.encodeWithSelector(IL1Registry.L1Registry__InvalidValidatorManager.selector, address(0)));
        registry.registerL1{value: registerFee}(address(0), l1Middleware1SecurityModule, l1Middleware1MetadataURL);
    }

    function testRegisterMultipleL1s() public {
        // l1Middleware1 registers
        vm.prank(l1Middleware1);
        registry.registerL1{value: registerFee}(
            address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL
        );

        // Create a new mock manager for l1Middleware2
        MockACP99Manager l1Middleware2Manager = new MockACP99Manager(l1Middleware2);

        // l1Middleware2 registers
        vm.prank(l1Middleware2);
        registry.registerL1{value: registerFee}(
            address(l1Middleware2Manager), l1Middleware2SecurityModule, l1Middleware2MetadataURL
        );

        // Check that both managers are registered
        assertEq(registry.totalL1s(), 2);
        assertEq(registry.isRegistered(address(mockACP99Manager)), true);
        assertEq(registry.isRegistered(address(l1Middleware2Manager)), true);
    }

    function testGetL1s() public {
        // Register l1Middleware1 and l1Middleware2
        vm.prank(l1Middleware1);
        registry.registerL1{value: registerFee}(
            address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL
        );

        MockACP99Manager l1Middleware2Manager = new MockACP99Manager(l1Middleware2);
        vm.prank(l1Middleware2);
        registry.registerL1{value: registerFee}(
            address(l1Middleware2Manager), l1Middleware2SecurityModule, l1Middleware2MetadataURL
        );

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
        registry.registerL1{value: registerFee}(
            address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL
        );

        MockACP99Manager l1Middleware2Manager = new MockACP99Manager(l1Middleware2);
        vm.prank(l1Middleware2);
        registry.registerL1{value: registerFee}(
            address(l1Middleware2Manager), l1Middleware2SecurityModule, l1Middleware2MetadataURL
        );

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
        registry.registerL1{value: registerFee}(
            address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL
        );
    }

    function testLargeNumberOfRegistrations() public {
        // Register 1000 L1s
        for (uint256 i = 0; i < 1000; i++) {
            address eoa = address(uint160(i + 10_000)); // skip address(0)
            vm.deal(eoa, 100 ether); // Give the account some funds
            MockACP99Manager manager = new MockACP99Manager(eoa);
            address middleware = address(new DummySecurityModule(eoa));

            vm.prank(eoa);
            registry.registerL1{value: registerFee}(address(manager), middleware, l1Middleware1MetadataURL);
        }

        // Check that all 1000 L1s are registered
        assertEq(registry.totalL1s(), 1000);
    }

    function testSetL1Middleware() public {
        // First register an L1
        vm.prank(l1Middleware1);
        registry.registerL1{value: registerFee}(
            address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL
        );

        // Make your "newMiddleware" an Ownable contract if you want to pass the second check
        DummySecurityModule newMiddle = new DummySecurityModule(l1Middleware1);
        address newMiddleware = address(newMiddle);

        // **Again** call from l1Middleware1
        vm.prank(l1Middleware1);
        registry.setL1Middleware(address(mockACP99Manager), newMiddleware);

        (, address actualMw,) = registry.getL1At(0);
        assertEq(actualMw, newMiddleware);
    }

    function testSetL1MiddlewareRevertNotRegistered() public {
        // Try to set middleware for unregistered L1
        vm.expectRevert(IL1Registry.L1Registry__L1NotRegistered.selector);
        registry.setL1Middleware(address(mockACP99Manager), l1Middleware1SecurityModule);
    }

    function testSetL1MiddlewareEmitsEvent() public {
        // Register L1 first
        vm.prank(l1Middleware1);
        registry.registerL1{value: registerFee}(
            address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL
        );

        string memory newMetadataURL = "https://newmetadata.com";

        // Must call from the same manager owner
        vm.prank(l1Middleware1);
        registry.setMetadataURL(address(mockACP99Manager), newMetadataURL);

        (,, string memory actualURL) = registry.getL1At(0);
        assertEq(actualURL, newMetadataURL);
    }

    function testSetMetadataURL() public {
        // Register from l1Middleware1
        vm.prank(l1Middleware1);
        registry.registerL1{value: registerFee}(
            address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL
        );

        // Now also call setMetadataURL(...) from l1Middleware1
        vm.prank(l1Middleware1);
        string memory newMetadataURL = "https://newmetadata.com";
        registry.setMetadataURL(address(mockACP99Manager), newMetadataURL);

        // Confirm result
        (,, string memory actualURL) = registry.getL1At(0);
        assertEq(actualURL, newMetadataURL);
    }

    function testSetMetadataURLRevertNotRegistered() public {
        // Try to set metadata URL for unregistered L1
        vm.expectRevert(IL1Registry.L1Registry__L1NotRegistered.selector);
        registry.setMetadataURL(address(mockACP99Manager), "https://newmetadata.com");
    }

    function testSetMetadataURLEmitsEvent() public {
        // Register from l1Middleware1
        vm.prank(l1Middleware1);
        registry.registerL1{value: registerFee}(
            address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL
        );

        // Expect the event
        vm.expectEmit(true, true, true, true);
        emit IL1Registry.SetMetadataURL(address(mockACP99Manager), "https://newmetadata.com");

        // Must call from the correct owner again
        vm.prank(l1Middleware1);
        registry.setMetadataURL(address(mockACP99Manager), "https://newmetadata.com");
    }

    function testRegisterL1InsufficientFeeReverts() public {
        // Attempt registration with a value less than registerFee
        vm.prank(l1Middleware1);
        vm.expectRevert(IL1Registry.L1Registry__InsufficientFee.selector);
        registry.registerL1{value: registerFee - 1 wei}(
            address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL
        );
    }

    function testRegisterL1ExactFeeSucceeds() public {
        // Register with exact fee
        vm.prank(l1Middleware1);
        registry.registerL1{value: registerFee}(
            address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL
        );

        // Verify registration
        assertEq(registry.isRegistered(address(mockACP99Manager)), true);
    }

    function testRegisterL1ExcessFeeSucceeds() public {
        // Register with more than required fee
        uint256 overPaid = registerFee + 0.01 ether;

        // Track fee collector's balance before
        uint256 feeCollectorBalanceBefore = feeCollectorAddress.balance;

        // Perform registration
        vm.prank(l1Middleware1);
        registry.registerL1{value: overPaid}(
            address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL
        );

        // Verify registration
        assertEq(registry.isRegistered(address(mockACP99Manager)), true);

        // Fee collector should receive the full `overPaid`
        assertEq(feeCollectorAddress.balance, feeCollectorBalanceBefore + overPaid);
    }

    function testRegisterL1NoFeeWhenRegisterFeeIsZero() public {
        // Suppose the owner sets the registerFee to 0
        vm.prank(owner);
        registry.setRegisterFee(0);

        // Then no fee is required to register
        vm.prank(l1Middleware1);
        registry.registerL1(address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL);

        // Verify registration
        assertEq(registry.isRegistered(address(mockACP99Manager)), true);
    }

    function testFeeTransferFailsDoesNotRevert() public {
        RevertingFeeCollector revertingCollector = new RevertingFeeCollector();

        // Set it as the fee collector
        vm.prank(owner);
        registry.setFeeCollector(payable(address(revertingCollector)));

        // Attempt registration with fee - this should now succeed
        vm.prank(l1Middleware1);
        registry.registerL1{value: registerFee}(
            address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL
        );
        
        // Verify registration succeeded
        assertEq(registry.isRegistered(address(mockACP99Manager)), true);
    }

    function testSetFeeCollectorToZeroAddressReverts() public {
        // Attempt to set the fee collector to address(0), which should revert
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IL1Registry.L1Registry__ZeroAddress.selector, "feeCollector"));
        registry.setFeeCollector(payable(address(0)));
    }

    function testConstructorWithZeroFeeCollectorReverts() public {
        // Attempt to create a registry with address(0) as fee collector, which should revert
        vm.expectRevert(abi.encodeWithSelector(IL1Registry.L1Registry__ZeroAddress.selector, "feeCollector"));
        new L1Registry(payable(address(0)), registerFee, 1 ether, owner);
    }

    function testFeeTransferFailsButRegistrationSucceeds() public {
        RevertingFeeCollector revertingCollector = new RevertingFeeCollector();

        // Set it as the fee collector
        vm.prank(owner);
        registry.setFeeCollector(payable(address(revertingCollector)));

        // Initially there should be no unclaimed fees
        assertEq(registry.unclaimedFees(), 0);

        // Attempt registration with fee - now this should succeed unlike before
        vm.prank(l1Middleware1);
        registry.registerL1{value: registerFee}(
            address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL
        );
        
        // Registration was successful despite fee transfer failing
        assertEq(registry.isRegistered(address(mockACP99Manager)), true);
        
        // Unclaimed fees should now be tracked
        assertEq(registry.unclaimedFees(), registerFee);
        
        // Total contract balance should include these fees
        assertEq(address(registry).balance, registerFee);
    }
    
    function testWithdrawFees() public {
        // First setup the scenario with trapped fees
        RevertingFeeCollector revertingCollector = new RevertingFeeCollector();
        vm.prank(owner);
        registry.setFeeCollector(payable(address(revertingCollector)));
        
        // Register and trap the fees
        vm.prank(l1Middleware1);
        registry.registerL1{value: registerFee}(
            address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL
        );
        
        // Change to a working fee collector
        address payable newCollector = payable(makeAddr("newCollector"));
        uint256 newCollectorBalanceBefore = newCollector.balance;
        
        vm.prank(owner);
        registry.setFeeCollector(newCollector);
        
        // Fees should have been automatically transferred during setFeeCollector
        assertEq(registry.unclaimedFees(), 0);
        assertEq(newCollector.balance, newCollectorBalanceBefore + registerFee);
    }
    
    function testWithdrawFeesDirectly() public {
        // First setup the scenario with trapped fees
        RevertingFeeCollector revertingCollector = new RevertingFeeCollector();
        vm.prank(owner);
        registry.setFeeCollector(payable(address(revertingCollector)));
        
        // Register and trap the fees
        vm.prank(l1Middleware1);
        registry.registerL1{value: registerFee}(
            address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL
        );
        
        // At this point unclaimedFees should be registerFee
        assertEq(registry.unclaimedFees(), registerFee);
        
        // Change to a controllable fee collector
        address payable newCollector = payable(makeAddr("newCollector"));
        uint256 newCollectorBalanceBefore = newCollector.balance;
        
        vm.prank(owner);
        registry.setFeeCollector(newCollector);
        
        // Fees should be transferred during setFeeCollector
        assertEq(registry.unclaimedFees(), 0);
        assertEq(newCollector.balance, newCollectorBalanceBefore + registerFee);
        
        // Try to withdraw fees - should fail since there are none left
        vm.expectRevert(IL1Registry.L1Registry__NoFeesToWithdraw.selector);
        vm.prank(newCollector);
        registry.withdrawFees();
        
        // Set the collector back to the reverting one to trap fees again
        vm.prank(owner);
        registry.setFeeCollector(payable(address(revertingCollector)));
        
        // Now register another L1 to accumulate more fees
        MockACP99Manager l1Middleware2Manager = new MockACP99Manager(l1Middleware2);
        vm.prank(l1Middleware2);
        registry.registerL1{value: registerFee}(
            address(l1Middleware2Manager), l1Middleware2SecurityModule, l1Middleware2MetadataURL
        );
        
        // Fees should be available to withdraw
        assertEq(registry.unclaimedFees(), registerFee);
        
        // Set back the collector to the good one
        vm.prank(owner);
        registry.setFeeCollector(newCollector);
        
        // Non-fee collector cannot withdraw
        vm.expectRevert(abi.encodeWithSelector(IL1Registry.L1Registry__NotFeeCollector.selector, address(this)));
        registry.withdrawFees();
        
        // Fees already transferred during setFeeCollector, so withdrawFees should fail
        vm.expectRevert(IL1Registry.L1Registry__NoFeesToWithdraw.selector);
        vm.prank(newCollector);
        registry.withdrawFees();
        
        // Check fees were transferred
        assertEq(registry.unclaimedFees(), 0);
        assertEq(newCollector.balance, newCollectorBalanceBefore + registerFee * 2);
    }
    
    function testWithdrawFeesSuccessfully() public {
        // Create a new registry with a working fee collector
        address payable collector = payable(makeAddr("collector"));
        L1Registry testRegistry = new L1Registry(collector, registerFee, 1 ether, owner);
        
        // Set a reverting fee collector to trap fees
        RevertingFeeCollector revertingCollector = new RevertingFeeCollector();
        vm.prank(owner);
        testRegistry.setFeeCollector(payable(address(revertingCollector)));
        
        // Register an L1 (fees will be trapped)
        vm.prank(l1Middleware1);
        testRegistry.registerL1{value: registerFee}(
            address(mockACP99Manager), l1Middleware1SecurityModule, l1Middleware1MetadataURL
        );
        
        // Create a controllable mock fee collector
        PartialRevertingFeeCollector partialRevertingCollector = new PartialRevertingFeeCollector();
        
        // Set it as the fee collector (this will revert the transfer in setFeeCollector)
        vm.prank(owner);
        testRegistry.setFeeCollector(payable(address(partialRevertingCollector)));
        
        // Unclaimed fees should still be tracked because the transfer in setFeeCollector failed
        assertEq(testRegistry.unclaimedFees(), registerFee);
        
        // Configure the collector to accept the next transfer
        partialRevertingCollector.acceptNextTransfer();
        
        // Now withdraw the fees 
        vm.prank(address(partialRevertingCollector));
        testRegistry.withdrawFees();
        
        // Fees should now be withdrawn
        assertEq(testRegistry.unclaimedFees(), 0);
    }
}

// Contract that reverts only on setFeeCollector transfers but accepts withdrawFees
contract PartialRevertingFeeCollector {
    bool public shouldRevert = true;
    
    receive() external payable {
        if (shouldRevert) {
            revert("PartialRevertingFeeCollector: reverting on setFeeCollector");
        }
        // Accept funds on withdrawFees
        shouldRevert = true; // Reset for next call
    }
    
    function acceptNextTransfer() external {
        shouldRevert = false;
    }
}
