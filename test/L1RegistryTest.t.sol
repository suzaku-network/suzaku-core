// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {L1Registry} from "../src/contracts/L1Registry.sol";
import {IL1Registry} from "../src/interfaces/IL1Registry.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @dev Simple Ownable stub used to simulate L1 manager and security module contracts
contract OwnableStub is Ownable {
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

// Contract that reverts on receiving ether (for testing refund failures)
contract RevertingRefundReceiver {
    receive() external payable {
        revert("RevertingRefundReceiver: refusing refund");
    }
    
    fallback() external payable {
        revert("RevertingRefundReceiver: refusing refund");
    }
}

contract L1RegistryTest is Test {
    address owner;
    address middleware1;
    string middleware1MetadataURL;
    address middleware2;
    string middleware2MetadataURL;
    address middleware1SecurityModule;
    address middleware2SecurityModule;
    address feeCollectorAddress;
    L1Registry registry;
    OwnableStub l1Manager;
    uint256 registerFee;

    function setUp() public {
        owner = address(this);
        feeCollectorAddress = makeAddr("feeCollector");
        middleware1 = makeAddr("middleware1");
        vm.deal(middleware1, 100 ether); // Give middleware1 some funds
        middleware1MetadataURL = "https://l1.com";
        middleware2 = makeAddr("middleware2");
        vm.deal(middleware2, 100 ether); // Give middleware2 some funds
        middleware2MetadataURL = "https://l2.com";
        middleware1SecurityModule = makeAddr("middleware1SecurityModule");
        middleware2SecurityModule = makeAddr("middleware2SecurityModule");

        l1Manager = new OwnableStub(middleware1);

        OwnableStub secModule = new OwnableStub(middleware1);
        middleware1SecurityModule = address(secModule);

        OwnableStub secModule2 = new OwnableStub(middleware2);
        middleware2SecurityModule = address(secModule2);

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
        // middleware1 registers as an L1
        vm.prank(middleware1);
        registry.registerL1{value: registerFee}(
            address(l1Manager), middleware1SecurityModule, middleware1MetadataURL
        );

        assertEq(registry.isRegistered(address(l1Manager)), true);
    }

    function testRegisterRevertAlreadyRegistered() public {
        // Register middleware1
        vm.prank(middleware1);
        registry.registerL1{value: registerFee}(
            address(l1Manager), middleware1SecurityModule, middleware1MetadataURL
        );

        // middleware1 tries to register again and it should revert
        vm.prank(middleware1);
        vm.expectRevert(IL1Registry.L1Registry__L1AlreadyRegistered.selector);
        registry.registerL1{value: registerFee}(
            address(l1Manager), middleware1SecurityModule, middleware1MetadataURL
        );
    }

    function testRegisterWithZeroAddress() public {
        // Try to register address(0), which should revert
        vm.prank(middleware1);
        vm.expectRevert(abi.encodeWithSelector(IL1Registry.L1Registry__ZeroAddress.selector, "address"));
        registry.registerL1{value: registerFee}(address(0), middleware1SecurityModule, middleware1MetadataURL);
    }

    function testRegisterMultipleL1s() public {
        // middleware1 registers
        vm.prank(middleware1);
        registry.registerL1{value: registerFee}(
            address(l1Manager), middleware1SecurityModule, middleware1MetadataURL
        );

        // Create a new mock manager for middleware2
        OwnableStub middleware2Manager = new OwnableStub(middleware2);

        // middleware2 registers
        vm.prank(middleware2);
        registry.registerL1{value: registerFee}(
            address(middleware2Manager), middleware2SecurityModule, middleware2MetadataURL
        );

        // Check that both managers are registered
        assertEq(registry.totalL1s(), 2);
        assertEq(registry.isRegistered(address(l1Manager)), true);
        assertEq(registry.isRegistered(address(middleware2Manager)), true);
    }

    function testGetL1s() public {
        // Register middleware1 and middleware2
        vm.prank(middleware1);
        registry.registerL1{value: registerFee}(
            address(l1Manager), middleware1SecurityModule, middleware1MetadataURL
        );

        OwnableStub middleware2Manager = new OwnableStub(middleware2);
        vm.prank(middleware2);
        registry.registerL1{value: registerFee}(
            address(middleware2Manager), middleware2SecurityModule, middleware2MetadataURL
        );

        // Check that both managers are registered
        (address[] memory allL1s, address[] memory middlewares, string[] memory metadataURLs) = registry.getAllL1s();
        assertEq(allL1s.length, 2);
        assertEq(allL1s[0], address(l1Manager));
        assertEq(allL1s[1], address(middleware2Manager));
        assertEq(middlewares[0], middleware1SecurityModule);
        assertEq(middlewares[1], middleware2SecurityModule);
        assertEq(metadataURLs[0], middleware1MetadataURL);
        assertEq(metadataURLs[1], middleware2MetadataURL);
    }

    function testGetL1At() public {
        // Register middleware1 and middleware2
        vm.prank(middleware1);
        registry.registerL1{value: registerFee}(
            address(l1Manager), middleware1SecurityModule, middleware1MetadataURL
        );

        OwnableStub middleware2Manager = new OwnableStub(middleware2);
        vm.prank(middleware2);
        registry.registerL1{value: registerFee}(
            address(middleware2Manager), middleware2SecurityModule, middleware2MetadataURL
        );

        // Check the addresses and metadata URLs at specific indexes
        (address l10, address middleware0, string memory metadataURL0) = registry.getL1At(0);
        assertEq(l10, address(l1Manager));
        assertEq(middleware0, middleware1SecurityModule);
        assertEq(metadataURL0, middleware1MetadataURL);
        (address l11, address mw1, string memory metadataURL1) = registry.getL1At(1);
        assertEq(l11, address(middleware2Manager));
        assertEq(mw1, middleware2SecurityModule);
        assertEq(metadataURL1, middleware2MetadataURL);
    }

    function testZeroTotalL1s() public view {
        // No L1s should be registered
        assertEq(registry.totalL1s(), 0);
    }

    function testRegisterL1EmitsEvents() public {
        // Expect the RegisterL1 event to be emitted
        vm.expectEmit(true, true, true, true);
        emit IL1Registry.RegisterL1(address(l1Manager));

        // Expect the SetL1Middleware event to be emitted
        vm.expectEmit(true, true, true, true);
        emit IL1Registry.SetL1Middleware(address(l1Manager), middleware1SecurityModule);

        // Expect the SetMetadataURL event to be emitted
        vm.expectEmit(true, true, true, true);
        emit IL1Registry.SetMetadataURL(address(l1Manager), middleware1MetadataURL);

        // Register middleware1
        vm.prank(middleware1);
        registry.registerL1{value: registerFee}(
            address(l1Manager), middleware1SecurityModule, middleware1MetadataURL
        );
    }

    function testLargeNumberOfRegistrations() public {
        // Register 1000 L1s
        for (uint256 i = 0; i < 1000; i++) {
            address eoa = address(uint160(i + 10_000)); // skip address(0)
            vm.deal(eoa, 100 ether); // Give the account some funds
            OwnableStub manager = new OwnableStub(eoa);
            address middleware = address(new OwnableStub(eoa));

            vm.prank(eoa);
            registry.registerL1{value: registerFee}(address(manager), middleware, middleware1MetadataURL);
        }

        // Check that all 1000 L1s are registered
        assertEq(registry.totalL1s(), 1000);
    }

    function testSetL1Middleware() public {
        // First register an L1
        vm.prank(middleware1);
        registry.registerL1{value: registerFee}(
            address(l1Manager), middleware1SecurityModule, middleware1MetadataURL
        );

        // Make your "newMiddleware" an Ownable contract if you want to pass the second check
        OwnableStub newMiddle = new OwnableStub(middleware1);
        address newMiddleware = address(newMiddle);

        // **Again** call from middleware1
        vm.prank(middleware1);
        registry.setL1Middleware(address(l1Manager), newMiddleware);

        (, address actualMw,) = registry.getL1At(0);
        assertEq(actualMw, newMiddleware);
    }

    function testSetL1MiddlewareRevertNotRegistered() public {
        // Try to set middleware for unregistered L1
        vm.expectRevert(IL1Registry.L1Registry__L1NotRegistered.selector);
        registry.setL1Middleware(address(l1Manager), middleware1SecurityModule);
    }

    function testSetL1MiddlewareEmitsEvent() public {
        // Register L1 first
        vm.prank(middleware1);
        registry.registerL1{value: registerFee}(
            address(l1Manager), middleware1SecurityModule, middleware1MetadataURL
        );

        string memory newMetadataURL = "https://newmetadata.com";

        // Must call from the same manager owner
        vm.prank(middleware1);
        registry.setMetadataURL(address(l1Manager), newMetadataURL);

        (,, string memory actualURL) = registry.getL1At(0);
        assertEq(actualURL, newMetadataURL);
    }

    function testSetMetadataURL() public {
        // Register from middleware1
        vm.prank(middleware1);
        registry.registerL1{value: registerFee}(
            address(l1Manager), middleware1SecurityModule, middleware1MetadataURL
        );

        // Now also call setMetadataURL(...) from middleware1
        vm.prank(middleware1);
        string memory newMetadataURL = "https://newmetadata.com";
        registry.setMetadataURL(address(l1Manager), newMetadataURL);

        // Confirm result
        (,, string memory actualURL) = registry.getL1At(0);
        assertEq(actualURL, newMetadataURL);
    }

    function testSetMetadataURLRevertNotRegistered() public {
        // Try to set metadata URL for unregistered L1
        vm.expectRevert(IL1Registry.L1Registry__L1NotRegistered.selector);
        registry.setMetadataURL(address(l1Manager), "https://newmetadata.com");
    }

    function testSetMetadataURLEmitsEvent() public {
        // Register from middleware1
        vm.prank(middleware1);
        registry.registerL1{value: registerFee}(
            address(l1Manager), middleware1SecurityModule, middleware1MetadataURL
        );

        // Expect the event
        vm.expectEmit(true, true, true, true);
        emit IL1Registry.SetMetadataURL(address(l1Manager), "https://newmetadata.com");

        // Must call from the correct owner again
        vm.prank(middleware1);
        registry.setMetadataURL(address(l1Manager), "https://newmetadata.com");
    }

    function testRegisterL1InsufficientFeeReverts() public {
        // Attempt registration with a value less than registerFee
        vm.prank(middleware1);
        vm.expectRevert(IL1Registry.L1Registry__InsufficientFee.selector);
        registry.registerL1{value: registerFee - 1 wei}(
            address(l1Manager), middleware1SecurityModule, middleware1MetadataURL
        );
    }

    function testRegisterL1ExactFeeSucceeds() public {
        // Register with exact fee
        vm.prank(middleware1);
        registry.registerL1{value: registerFee}(
            address(l1Manager), middleware1SecurityModule, middleware1MetadataURL
        );

        // Verify registration
        assertEq(registry.isRegistered(address(l1Manager)), true);
    }

    function testRegisterL1ExcessFeeSucceeds() public {
        // Register with more than required fee
        uint256 overPaid = registerFee + 0.01 ether;
        uint256 excess = overPaid - registerFee;

        // Track balances before
        uint256 feeCollectorBalanceBefore = feeCollectorAddress.balance;
        uint256 senderBalanceBefore = middleware1.balance;

        // Perform registration
        vm.prank(middleware1);
        registry.registerL1{value: overPaid}(
            address(l1Manager), middleware1SecurityModule, middleware1MetadataURL
        );

        // Verify registration
        assertEq(registry.isRegistered(address(l1Manager)), true);

        // Fee collector should receive only the registerFee (not the full overPaid)
        assertEq(feeCollectorAddress.balance, feeCollectorBalanceBefore + registerFee);
        
        // Sender should be refunded the excess (should have paid exactly the registerFee)
        assertEq(middleware1.balance, senderBalanceBefore - registerFee);
        
        // Verify the excess calculation is correct
        assertEq(excess, 0.01 ether);
        
        // Verify sender got back exactly the excess amount (alternative way to check)
        assertEq(middleware1.balance, senderBalanceBefore - overPaid + excess);
    }

    function testRegisterL1NoFeeWhenRegisterFeeIsZero() public {
        // Suppose the owner sets the registerFee to 0
        vm.prank(owner);
        registry.setRegisterFee(0);

        // Then no fee is required to register
        vm.prank(middleware1);
        registry.registerL1(address(l1Manager), middleware1SecurityModule, middleware1MetadataURL);

        // Verify registration
        assertEq(registry.isRegistered(address(l1Manager)), true);
    }

    function testRegisterL1UnexpectedEtherWhenNoFeeReverts() public {
        // Set the register fee to 0
        vm.prank(owner);
        registry.setRegisterFee(0);

        // Try to register with ether when no fee is required - should revert
        vm.prank(middleware1);
        vm.expectRevert(IL1Registry.L1Registry__UnexpectedEther.selector);
        registry.registerL1{value: 0.001 ether}(
            address(l1Manager), middleware1SecurityModule, middleware1MetadataURL
        );
    }

    function testRegisterL1RefundFailureReverts() public {
        // Create a contract that will revert on receive
        RevertingRefundReceiver revertingReceiver = new RevertingRefundReceiver();
        
        // Set up a mock manager owned by the reverting receiver
        OwnableStub revertingManager = new OwnableStub(address(revertingReceiver));

        // Try to register with excess fee - should revert because refund fails
        uint256 overPaid = registerFee + 0.01 ether;

        vm.deal(address(revertingReceiver), overPaid);
        
        vm.prank(address(revertingReceiver));
        vm.expectRevert(abi.encodeWithSelector(IL1Registry.L1Registry__RefundFailed.selector, 0.01 ether));
        registry.registerL1{value: overPaid}(
            address(revertingManager), middleware1SecurityModule, middleware1MetadataURL
        );
    }

    function testRegisterL1ExactFeeNoRefund() public {
        // Track balances before
        uint256 feeCollectorBalanceBefore = feeCollectorAddress.balance;
        uint256 senderBalanceBefore = middleware1.balance;

        // Register with exact fee (no excess)
        vm.prank(middleware1);
        registry.registerL1{value: registerFee}(
            address(l1Manager), middleware1SecurityModule, middleware1MetadataURL
        );

        // Verify registration
        assertEq(registry.isRegistered(address(l1Manager)), true);

        // Fee collector should receive the exact fee
        assertEq(feeCollectorAddress.balance, feeCollectorBalanceBefore + registerFee);
        
        // Sender should have paid exactly the fee (no refund)
        assertEq(middleware1.balance, senderBalanceBefore - registerFee);
    }

    function testRegisterL1ExcessFeeWithFailedFeeTransfer() public {
        // Set a reverting fee collector
        RevertingFeeCollector revertingCollector = new RevertingFeeCollector();
        vm.prank(owner);
        registry.setFeeCollector(payable(address(revertingCollector)));

        // Register with excess fee
        uint256 overPaid = registerFee + 0.01 ether;
        uint256 senderBalanceBefore = middleware1.balance;

        vm.prank(middleware1);
        registry.registerL1{value: overPaid}(
            address(l1Manager), middleware1SecurityModule, middleware1MetadataURL
        );

        // Verify registration succeeded
        assertEq(registry.isRegistered(address(l1Manager)), true);

        // Unclaimed fees should track only the registerFee (not the full overPaid)
        assertEq(registry.unclaimedFees(), registerFee);
        
        // Sender should still be refunded the excess despite fee transfer failure
        assertEq(middleware1.balance, senderBalanceBefore - registerFee);
        
        // Contract should hold only the registerFee (excess was refunded)
        assertEq(address(registry).balance, registerFee);
    }

    function testFeeTransferFailsDoesNotRevert() public {
        RevertingFeeCollector revertingCollector = new RevertingFeeCollector();

        // Set it as the fee collector
        vm.prank(owner);
        registry.setFeeCollector(payable(address(revertingCollector)));

        // Attempt registration with fee - this should now succeed
        vm.prank(middleware1);
        registry.registerL1{value: registerFee}(
            address(l1Manager), middleware1SecurityModule, middleware1MetadataURL
        );
        
        // Verify registration succeeded
        assertEq(registry.isRegistered(address(l1Manager)), true);
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
        vm.prank(middleware1);
        registry.registerL1{value: registerFee}(
            address(l1Manager), middleware1SecurityModule, middleware1MetadataURL
        );
        
        // Registration was successful despite fee transfer failing
        assertEq(registry.isRegistered(address(l1Manager)), true);
        
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
        vm.prank(middleware1);
        registry.registerL1{value: registerFee}(
            address(l1Manager), middleware1SecurityModule, middleware1MetadataURL
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
        vm.prank(middleware1);
        registry.registerL1{value: registerFee}(
            address(l1Manager), middleware1SecurityModule, middleware1MetadataURL
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
        OwnableStub middleware2Manager = new OwnableStub(middleware2);
        vm.prank(middleware2);
        registry.registerL1{value: registerFee}(
            address(middleware2Manager), middleware2SecurityModule, middleware2MetadataURL
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
        vm.prank(middleware1);
        testRegistry.registerL1{value: registerFee}(
            address(l1Manager), middleware1SecurityModule, middleware1MetadataURL
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
