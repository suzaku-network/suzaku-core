// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {VaultTokenized} from "../../src/contracts/vault/VaultTokenized.sol";
import { IVaultTokenized } from "../../src/interfaces/vault/IVaultTokenized.sol";
import { MigratableEntityProxy } from "../../src/contracts/common/MigratableEntityProxy.sol";

import {Token} from "../mocks/MockToken.sol";
import {MockDelegatorFactory} from "../mocks/MockDelegatorFactory.sol";
import {MockSlasherFactory} from "../mocks/MockSlasherFactory.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Test, console2} from "forge-std/Test.sol";

contract VaultTokenizedTest is Test {
    using Math for uint256;

    address owner;
    address alice;
    uint256 alicePrivateKey;
    address bob;
    uint256 bobPrivateKey;

    // VaultTokenized vault;
    // Token collateral;
    // MockDelegatorFactory delegatorFactory;
    // MockSlasherFactory slasherFactory;
    // Contracts
    VaultTokenized vaultImplementation;
    MigratableEntityProxy proxy;
    VaultTokenized vault;
    Token collateral;
    MockDelegatorFactory delegatorFactory;
    MockSlasherFactory slasherFactory;

    function setUp() public {
        owner = address(this);
        (alice, alicePrivateKey) = makeAddrAndKey("alice");
        (bob, bobPrivateKey) = makeAddrAndKey("bob");

        // Deploy mock factories
        delegatorFactory = new MockDelegatorFactory();
        slasherFactory = new MockSlasherFactory();

        // Deploy the collateral token
        collateral = new Token("Token");

        // Instantiate VaultTokenized contract directly
        // vault = new VaultTokenized(address(this)); // Passing address(this) as the vaultFactory

        // Deploy the VaultTokenized implementation contract
        vaultImplementation = new VaultTokenized(address(this));


        // Prepare initialization data
        VaultTokenized.InitParams memory params = IVaultTokenized.InitParams({
            collateral: address(collateral),
            burner: address(0xdead),
            epochDuration: 1 weeks,
            depositWhitelist: false,
            isDepositLimit: false,
            depositLimit: 0,
            defaultAdminRoleHolder: alice,
            depositWhitelistSetRoleHolder: alice,
            depositorWhitelistRoleHolder: alice,
            isDepositLimitSetRoleHolder: alice,
            depositLimitSetRoleHolder: alice,
            name: "TestToken",
            symbol: "TEST"
        });

        // Encode the initialization data
        uint64 initialVersion = 1;
        // Prepare initialization data with function selector
        bytes memory initData = abi.encodeCall(
            IVaultTokenized.initialize,
            (
                initialVersion,
                owner,
                abi.encode(params),
                address(delegatorFactory),
                address(slasherFactory)
            )
        );

        // Deploy the proxy using MigratableEntityProxy
        proxy = new MigratableEntityProxy(address(vaultImplementation), initData);

        // Cast the proxy address to VaultTokenized
        vault = VaultTokenized(address(proxy));
    }

    // Test initialization
    function testInitialization() public view {
        // Check ERC20 properties
        assertEq(vault.name(), "TestToken");
        assertEq(vault.symbol(), "TEST");
        assertEq(vault.decimals(), collateral.decimals());

        // Check collateral and burner
        assertEq(vault.collateral(), address(collateral));
        assertEq(vault.burner(), address(0xDEAD));

        // Check epoch settings
        assertEq(vault.epochDuration(), 1 weeks);
        assertEq(vault.epochDurationInit(), block.timestamp);

        // Check deposit settings
        assertEq(vault.depositWhitelist(), false);
        assertEq(vault.isDepositLimit(), false);
        assertEq(vault.depositLimit(), 0);

        // Check roles
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), alice));
        assertTrue(vault.hasRole(vault.DEPOSIT_WHITELIST_SET_ROLE(), alice));
        assertTrue(vault.hasRole(vault.DEPOSITOR_WHITELIST_ROLE(), alice));
        assertTrue(vault.hasRole(vault.IS_DEPOSIT_LIMIT_SET_ROLE(), alice));
        assertTrue(vault.hasRole(vault.DEPOSIT_LIMIT_SET_ROLE(), alice));

        // Check factory addresses
        assertEq(vault.DELEGATOR_FACTORY(), address(delegatorFactory));
        assertEq(vault.SLASHER_FACTORY(), address(slasherFactory));

        // Check initialization flags
        assertTrue(vault.isInitialized());
        assertTrue(vault.isDelegatorInitialized());
        assertTrue(vault.isSlasherInitialized());
    }

    function testDeposit() public {
        uint256 transferAmount = 1000 * 10**collateral.decimals();

        // Mint tokens to Alice
        collateral.transfer(alice, transferAmount);
        assertEq(collateral.balanceOf(alice), transferAmount, "Alice should have received the transfer amount");

        // Alice approves vault to spend tokens
        vm.prank(alice);
        collateral.approve(address(vault), transferAmount);

        // Assert that the allowance is correctly set
        assertEq(collateral.allowance(alice, address(vault)), transferAmount, "Alice's allowance mismatch");

        // Expect Deposit event
        vm.expectEmit(true, true, false, true);
        emit IVaultTokenized.Deposit(alice, alice, transferAmount, transferAmount);

        // Expect Transfer event: address(0) -> alice (minted shares)
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(address(0), alice, transferAmount); // Vault's ERC20 Transfer event for shares

        // Perform deposit as Alice
        vm.prank(alice);
        (uint256 depositedAmount, uint256 mintedShares) = vault.deposit(alice, transferAmount);

        // Assert deposited amount matches
        assertEq(depositedAmount, transferAmount, "Deposited amount mismatch");

        // Assert shares minted
        assertEq(mintedShares, transferAmount, "Minted shares mismatch"); // Assuming 1:1 share rate initially

        // Check balances
        assertEq(vault.balanceOf(alice), mintedShares, "Alice's share balance mismatch");
        assertEq(collateral.balanceOf(address(vault)), depositedAmount, "Vault's collateral balance mismatch");
    }


    function testDepositWithWhitelisting() public {
        uint256 transferAmount = 1000 * 10**collateral.decimals();

        // Enable deposit whitelist
        vm.prank(alice); // Alice has the DEPOSIT_WHITELIST_SET_ROLE
        vault.setDepositWhitelist(true);

        // Mint tokens to Bob
        collateral.transfer(bob, transferAmount);
        assertEq(collateral.balanceOf(bob), transferAmount);

        // Bob approves vault to spend tokens
        vm.prank(bob);
        collateral.approve(address(vault), transferAmount);

        // Attempt deposit as non-whitelisted depositor
        vm.prank(bob);
        vm.expectRevert(IVaultTokenized.Vault__NotWhitelistedDepositor.selector);
        vault.deposit(bob, transferAmount);

        // Whitelist Bob as Alice
        vm.prank(alice);
        vault.setDepositorWhitelistStatus(bob, true);

        // Attempt deposit again as Bob
        vm.prank(bob);
        (uint256 depositedAmount, uint256 mintedShares) = vault.deposit(bob, transferAmount);

        // Assert deposited amount and shares
        assertEq(depositedAmount, transferAmount);
        assertEq(mintedShares, depositedAmount); // Assuming 1:1 share rate initially

        // Check balances
        assertEq(vault.balanceOf(bob), mintedShares);
        assertEq(collateral.balanceOf(address(vault)), depositedAmount);
    }

    function testDepositExceedingLimit() public {
        uint256 depositLimit = 1000 * 10**collateral.decimals();
        uint256 transferAmount = 2000 * 10**collateral.decimals();

        // Doesn't work if I use prank instead of startPrank
        vm.startPrank(alice);
        
        // Set deposit limit
        vault.setIsDepositLimit(true);
        vault.setDepositLimit(depositLimit);
        
        vm.stopPrank();

        // Verify that deposit limit is set
        assertTrue(vault.isDepositLimit(), "Deposit limit should be enabled");
        assertEq(vault.depositLimit(), depositLimit, "Deposit limit mismatch");

        // Mint tokens to Alice
        collateral.transfer(alice, transferAmount);
        assertEq(collateral.balanceOf(alice), transferAmount, "Alice should have received the transfer amount");

        // Alice approves vault to spend tokens
        vm.prank(alice);
        collateral.approve(address(vault), transferAmount);
        assertEq(collateral.allowance(alice, address(vault)), transferAmount, "Alice's allowance mismatch");

        // Attempt to deposit exceeding the limit
        vm.prank(alice);
        vm.expectRevert(IVaultTokenized.Vault__DepositLimitReached.selector);
        vault.deposit(alice, transferAmount);
    }

    // Won't work, need to build logic around operators first.
    function testClaim() public {
        uint256 depositAmount = 1000 * 10**collateral.decimals();
        uint256 withdrawAmount = 500 * 10**collateral.decimals();

        // Mint tokens to Alice
        collateral.transfer(alice, depositAmount);
        assertEq(collateral.balanceOf(alice), depositAmount, "Alice should have received the transfer amount");

        // Start impersonating Alice for multiple actions
        vm.startPrank(alice);

        // Alice approves the vault to spend tokens
        collateral.approve(address(vault), depositAmount);
        assertEq(collateral.allowance(alice, address(vault)), depositAmount, "Alice's allowance mismatch");

        // Alice deposits tokens into the vault
        (uint256 depositedAmount, uint256 mintedShares) = vault.deposit(alice, depositAmount);
        assertEq(depositedAmount, depositAmount, "Deposited amount mismatch");
        assertEq(mintedShares, depositAmount, "Minted shares mismatch"); // Assuming 1:1 share rate initially

        // Alice withdraws half of her deposit
        vault.withdraw(alice, withdrawAmount);
        vm.stopPrank();

        // Warp to the **next epoch's start time** to make withdrawal claimable
        vm.warp(vault.nextEpochStart());

        // Alice claims her withdrawal
        vm.startPrank(alice);
        // Expect Claim event
        uint256 currentEpoch = vault.currentEpoch() - 1;
        // vm.expectEmit(true, true, false, true);
        emit IVaultTokenized.Claim(alice, alice, currentEpoch, withdrawAmount);
        uint256 claimedAmount = vault.claim(alice, currentEpoch);
        assertEq(claimedAmount, withdrawAmount, "Claimed amount mismatch");

        // Stop impersonating Alice
        vm.stopPrank();

        // Check balances
        assertEq(collateral.balanceOf(alice), withdrawAmount, "Alice's collateral balance mismatch");
        assertEq(collateral.balanceOf(address(vault)), depositAmount - withdrawAmount, "Vault's collateral balance mismatch");
    }



}
