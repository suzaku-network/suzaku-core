// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VaultTokenized} from "../../src/contracts/vault/VaultTokenized.sol";
import { IVaultTokenized } from "../../src/interfaces/vault/IVaultTokenized.sol";
import {Token} from "../mocks/MockToken.sol";
import {MockDelegatorFactory} from "../mocks/MockDelegatorFactory.sol";
import {MockSlasherFactory} from "../mocks/MockSlasherFactory.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import { MigratableEntityProxy } from "../../src/contracts/common/MigratableEntityProxy.sol";

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
        vaultImplementation = new VaultTokenized(address(this)); // Adjust if necessary


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
        uint64 initialVersion = 1; // Set to 1 for initial deployment
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
        // bytes memory initData = abi.encode(
        //     initialVersion,
        //     owner,
        //     abi.encode(params)
        // );

        // Deploy the proxy using MigratableEntityProxy
        proxy = new MigratableEntityProxy(address(vaultImplementation), initData);

        // Cast the proxy address to VaultTokenized
        vault = VaultTokenized(address(proxy));
    }

        // bytes memory data = abi.encode(params);

        // Initialize the vault with dummy addresses for unimplemented dependencies
        // vault.initialize(
        //     owner,
        //     data,
        //     address(delegatorFactory), // delegatorFactory (not implemented)
        //     address(slasherFactory)  // slasherFactory (not implemented)
        // );
    // }

    // Test initialization
    function testInitialization() public {
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
        assertEq(collateral.balanceOf(alice), transferAmount);

        // Alice approves vault to spend tokens
        vm.startPrank(alice);
        collateral.approve(address(vault), transferAmount);
        
        // Assert that the allowance is correctly set
        assertEq(collateral.allowance(alice, address(vault)), transferAmount);

        // Expect Deposit and Transfer events
        vm.expectEmit(true, true, false, true);
        emit IVaultTokenized.Deposit(alice, alice, transferAmount, transferAmount); // Ensure the event signature matches
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(address(0), alice, transferAmount);

        // Perform deposit
        (uint256 depositedAmount, uint256 mintedShares) = vault.deposit(alice, transferAmount);
        vm.stopPrank();

        // Assert deposited amount matches
        assertEq(depositedAmount, transferAmount);

        // Assert shares minted
        assertEq(mintedShares, transferAmount); // Assuming 1:1 share rate initially

        // Check balances
        assertEq(vault.balanceOf(alice), mintedShares);
        assertEq(collateral.balanceOf(address(vault)), depositedAmount);
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

        // Set deposit limit as Alice (DEPOSIT_LIMIT_SET_ROLE)
        vm.prank(alice);
        vault.setIsDepositLimit(true);
        vault.setDepositLimit(depositLimit);

        // Verify that deposit limit is set
        assertTrue(vault.isDepositLimit());
        assertEq(vault.depositLimit(), depositLimit);

        // Mint tokens to Alice
        collateral.transfer(alice, transferAmount);
        assertEq(collateral.balanceOf(alice), transferAmount);

        // Alice approves vault to spend tokens
        vm.prank(alice);
        collateral.approve(address(vault), transferAmount);
        assertEq(collateral.allowance(alice, address(vault)), transferAmount);

        // Attempt to deposit exceeding the limit
        vm.expectRevert(IVaultTokenized.Vault__DepositLimitReached.selector);
        vault.deposit(alice, transferAmount);
    }


}
