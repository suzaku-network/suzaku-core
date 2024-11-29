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
import {ERC4626Math} from "../../src/contracts/libraries/ERC4626Math.sol";

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

    // Helper functions to simulate deposit and withdrawal
    /**
     * @dev Helper function to simulate a deposit by a user.
     */
    function _deposit(address user, uint256 amount) internal {
        // Mint tokens to the user
        collateral.transfer(user, amount);
        assertEq(collateral.balanceOf(user), amount, "User should have received the transfer amount");

        // User approves vault to spend tokens
        vm.prank(user);
        collateral.approve(address(vault), amount);
        assertEq(collateral.allowance(user, address(vault)), amount, "User's allowance mismatch");

        // Perform deposit
        vm.prank(user);
        (uint256 depositedAmount, uint256 mintedShares) = vault.deposit(user, amount);

        // Assertions
        assertEq(depositedAmount, amount, "Deposited amount mismatch");
        assertEq(mintedShares, amount, "Minted shares mismatch"); // Assuming 1:1 share rate initially
        assertEq(vault.balanceOf(user), mintedShares, "User's share balance mismatch");
    }

    /**
     * @dev Helper function to simulate a withdrawal by a user.
     */
    function _withdraw(address user, uint256 amount) internal {
        // Calculate shares to burn
        uint256 burnedShares = ERC4626Math.previewWithdraw(amount, vault.activeShares(), vault.activeStake());
        require(burnedShares <= vault.balanceOf(user), "User does not have enough shares to withdraw");

        // Capture user's balance before withdrawal
        uint256 userBalanceBefore = vault.balanceOf(user);

        // Perform withdrawal
        vm.prank(user);
        (uint256 actualBurnedShares, uint256 mintedWithdrawalShares) = vault.withdraw(user, amount);

        // Assertions
        assertEq(actualBurnedShares, burnedShares, "Burned shares mismatch");
        assertEq(mintedWithdrawalShares, amount, "Minted withdrawal shares mismatch"); // Assuming 1:1 share rate initially

        // Correctly compare the user's balance after withdrawal
        assertEq(vault.balanceOf(user), userBalanceBefore - actualBurnedShares, "User's share balance after withdrawal mismatch");
    }

    /**
     * @dev Enhanced helper function to simulate a deposit by a user and record the timestamp.
     */
    function _depositWithTimestamp(address user, uint256 amount) internal returns (uint256 timestamp) {
        _deposit(user, amount);
        timestamp = block.timestamp;
    }

    /**
     * @dev Enhanced helper function to simulate a withdrawal by a user and record the timestamp.
     */
    function _withdrawWithTimestamp(address user, uint256 amount) internal returns (uint256 timestamp) {
        _withdraw(user, amount);
        timestamp = block.timestamp;
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
        (uint256 burnedShares, uint256 mintedWithdrawalShares) = vault.withdraw(alice, withdrawAmount);
        assertEq(burnedShares, withdrawAmount, "Burned shares mismatch");
        assertEq(mintedWithdrawalShares, withdrawAmount, "Minted withdrawal shares mismatch"); // Assuming 1:1 share rate initially

        // Need to stop impersonating Alice for epoch advancement
        vm.stopPrank();

        // Warp to two epoch durations to make withdrawal claimable
        uint256 epochDuration = vault.epochDuration();
        vm.warp(vault.nextEpochStart() + epochDuration); // Warp to currentEpoch() = 2

        // Alice claims her withdrawal from epoch=1 in epoch=2 or more
        vm.startPrank(alice);

        uint256 withdrawalEpoch = 1; // The withdrawal was recorded for epoch=1

        // Expect Claim event
        vm.expectEmit(true, true, false, true);
        emit IVaultTokenized.Claim(alice, alice, withdrawalEpoch, withdrawAmount);

        // Perform the claim
        uint256 claimedAmount = vault.claim(alice, withdrawalEpoch);
        assertEq(claimedAmount, withdrawAmount, "Claimed amount mismatch");

        vm.stopPrank();

        // Check balances
        assertEq(collateral.balanceOf(alice), withdrawAmount, "Alice's collateral balance mismatch");
        assertEq(collateral.balanceOf(address(vault)), depositAmount - withdrawAmount, "Vault's collateral balance mismatch");
    }


    /**
     * @notice Test claiming with a zero recipient address.
     * @dev Expects the transaction to revert with Vault__InvalidRecipient().
     */
    function testClaimWithZeroRecipient() public {
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
        (uint256 burnedShares, uint256 mintedWithdrawalShares) = vault.withdraw(alice, withdrawAmount);
        assertEq(burnedShares, withdrawAmount, "Burned shares mismatch");
        assertEq(mintedWithdrawalShares, withdrawAmount, "Minted withdrawal shares mismatch"); // Assuming 1:1 share rate initially

        vm.stopPrank();

        // Warp to two epoch durations to make withdrawal claimable
        uint256 epochDuration = vault.epochDuration();
        vm.warp(vault.nextEpochStart() + epochDuration); // Warp to currentEpoch() = 2

        // Attempt to claim with zero recipient
        vm.startPrank(alice);

        uint256 withdrawalEpoch = 1; // The withdrawal was recorded for epoch=1

        // Expect the transaction to revert with Vault__InvalidRecipient()
        vm.expectRevert(IVaultTokenized.Vault__InvalidRecipient.selector);
        vault.claim(address(0), withdrawalEpoch);

        vm.stopPrank();
    }

    /**
     * @notice Test claiming the same epoch twice.
     * @dev The first claim should succeed, and the second should revert with Vault__AlreadyClaimed().
     */
    function testDoubleClaimSameEpoch() public {
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
        (uint256 burnedShares, uint256 mintedWithdrawalShares) = vault.withdraw(alice, withdrawAmount);
        assertEq(burnedShares, withdrawAmount, "Burned shares mismatch");
        assertEq(mintedWithdrawalShares, withdrawAmount, "Minted withdrawal shares mismatch"); // Assuming 1:1 share rate initially

        vm.stopPrank();

        // Warp to two epoch durations to make withdrawal claimable
        uint256 epochDuration = vault.epochDuration();
        vm.warp(vault.nextEpochStart() + epochDuration); // Warp to currentEpoch() = 2

        // First claim attempt (should succeed)
        vm.startPrank(alice);

        uint256 withdrawalEpoch = 1; // The withdrawal was recorded for epoch=1

        // Expect Claim event
        vm.expectEmit(true, true, false, true);
        emit IVaultTokenized.Claim(alice, alice, withdrawalEpoch, withdrawAmount);

        // Perform the first claim
        uint256 claimedAmount = vault.claim(alice, withdrawalEpoch);
        assertEq(claimedAmount, withdrawAmount, "Claimed amount mismatch");

        // Second claim attempt (should fail with Vault__AlreadyClaimed())
        vm.expectRevert(IVaultTokenized.Vault__AlreadyClaimed.selector);
        vault.claim(alice, withdrawalEpoch);

        vm.stopPrank();
    }

    /**
     * @dev Test the redeem functionality along with the claim process.
     */
    function testRedeem() public {
        uint256 depositAmount = 1000 * 10**collateral.decimals();
        uint256 redeemAmount = 500 * 10**collateral.decimals();

        // Alice deposits tokens into the vault
        _deposit(alice, depositAmount);

        // Expect Transfer event: alice -> address(0) (burned shares)
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(alice, address(0), redeemAmount); // Burning shares

        // Perform redeem as Alice
        vm.prank(alice);
        (uint256 withdrawnAssets, uint256 mintedShares) = vault.redeem(alice, redeemAmount);

        // Assertions post redeem
        assertEq(withdrawnAssets, redeemAmount, "Withdrawn assets mismatch");
        assertEq(mintedShares, redeemAmount, "Minted shares mismatch"); // Assuming 1:1 share rate initially
        assertEq(vault.balanceOf(alice), depositAmount - redeemAmount, "Alice's share balance after redemption mismatch");
        
        // After redeem, the vault's collateral should still be depositAmount
        assertEq(collateral.balanceOf(address(vault)), depositAmount, "Vault's collateral balance mismatch after redemption");

        // Warp to the next epoch to make the withdrawal claimable
        uint256 epochDuration = vault.epochDuration();
        uint256 nextEpochStart = vault.nextEpochStart();
        vm.warp(nextEpochStart + epochDuration); // Warp to currentEpoch() =2

        // Define withdrawal epoch (assuming redeem registers for currentEpoch()+1)
        uint256 withdrawalEpoch = 1; // Withdrawal was registered for epoch=1

        // Expect Claim event
        vm.expectEmit(true, true, false, true);
        emit IVaultTokenized.Claim(alice, alice, withdrawalEpoch, redeemAmount);

        // Perform the claim
        vm.prank(alice);
        uint256 claimedAmount = vault.claim(alice, withdrawalEpoch);

        // Assertions post claim
        assertEq(claimedAmount, redeemAmount, "Claimed amount mismatch");
        assertEq(collateral.balanceOf(address(vault)), depositAmount - redeemAmount, "Vault's collateral balance mismatch after claim");
        assertEq(collateral.balanceOf(alice), redeemAmount, "Alice's collateral balance after claim mismatch");

        // Attempt to redeem more shares than Alice possesses
        uint256 excessiveRedeem = depositAmount; // Alice only has (depositAmount - redeemAmount) shares
        vm.prank(alice);
        vm.expectRevert(IVaultTokenized.Vault__TooMuchRedeem.selector);
        vault.redeem(alice, excessiveRedeem);

        // Attempt to redeem zero shares
        vm.prank(alice);
        vm.expectRevert(IVaultTokenized.Vault__InsufficientRedemption.selector);
        vault.redeem(alice, 0);
    }

    function testClaimBatch() public {
        uint256 depositAmount = 2000 * 10**collateral.decimals();
        uint256 withdrawAmount1 = 500 * 10**collateral.decimals();
        uint256 withdrawAmount2 = 700 * 10**collateral.decimals();

        // Alice deposits tokens into the vault
        _deposit(alice, depositAmount);

        // Alice withdraws first amount
        vm.prank(alice);
        _withdraw(alice, withdrawAmount1);

        // Warp to next epoch to make first withdrawal claimable
        vm.warp(vault.nextEpochStart());

        // Alice withdraws second amount in the next epoch
        vm.prank(alice);
        _withdraw(alice, withdrawAmount2);

        // Warp to the epoch after the second withdrawal to make both withdrawals claimable
        uint256 epochDuration = vault.epochDuration();
        vm.warp(vault.nextEpochStart() + epochDuration); // Warp to currentEpoch() = 2

        // Define epochs to claim (epoch 1 and epoch 2)
        uint256 currentEpoch = vault.currentEpoch(); // Should be 2
        uint256 claimEpoch1 = 1; // First withdrawal was in epoch 1
        uint256 claimEpoch2 = 2; // Second withdrawal was in epoch 2

        // Prepare expected total claim amount
        uint256 expectedTotalClaim = withdrawAmount1 + withdrawAmount2;

        // Define the epochs array with correct declaration and initialization
        uint256[] memory epochsToClaim = new uint256[](2);
        epochsToClaim[0] = claimEpoch1;
        epochsToClaim[1] = claimEpoch2;

        // Expect ClaimBatch event
        vm.expectEmit(true, true, false, true);
        emit IVaultTokenized.ClaimBatch(alice, alice, epochsToClaim, expectedTotalClaim);

        // Perform batch claim
        vm.prank(alice);
        uint256 claimedAmount = vault.claimBatch(alice, epochsToClaim);

        // Assertions
        assertEq(claimedAmount, expectedTotalClaim, "Total claimed amount mismatch");
        assertEq(
            collateral.balanceOf(address(vault)),
            depositAmount - expectedTotalClaim,
            "Vault's collateral balance mismatch after claims"
        );
        assertEq(collateral.balanceOf(alice), expectedTotalClaim, "Alice's collateral balance after claims mismatch");

        // Attempt to claim the same epochs again
        vm.prank(alice);
        vm.expectRevert(IVaultTokenized.Vault__AlreadyClaimed.selector);
        vault.claimBatch(alice, epochsToClaim);


        // Attempt to claim an invalid epoch (future epoch)
        vm.prank(alice);
        uint256 futureEpoch = currentEpoch + 1;
        uint256[] memory futureEpochs = new uint256[](1);
        futureEpochs[0] = futureEpoch;
        vm.expectRevert(IVaultTokenized.Vault__InvalidEpoch.selector);
        vault.claimBatch(alice, futureEpochs);

    }

    /**
     * @notice Simplified test covering activeSharesAt, activeShares, activeStakeAt, activeStake, activeSharesOfAt, and activeSharesOf.
     */
    function testActiveFunctions() public {
        // Define deposit and withdrawal amounts
        uint256 aliceDeposit = 1000 * 10**collateral.decimals();
        uint256 bobDeposit = 2000 * 10**collateral.decimals();
        uint256 aliceWithdraw = 500 * 10**collateral.decimals();
        uint256 bobWithdraw = 800 * 10**collateral.decimals();

        // Alice deposits at T1
        _deposit(alice, aliceDeposit);
        uint48 T1 = uint48(block.timestamp);

        // Bob deposits at T2 (after half an epoch)
        vm.warp(T1 + vault.epochDuration() / 2);
        _deposit(bob, bobDeposit);
        uint48 T2 = uint48(block.timestamp);

        // Alice withdraws at T3 (after the epoch ends)
        vm.warp(T1 + vault.epochDuration());
        _withdraw(alice, aliceWithdraw);
        uint48 T3 = uint48(block.timestamp);

        // Bob withdraws at T4 (after another half epoch)
        vm.warp(T3 + vault.epochDuration() / 2);
        _withdraw(bob, bobWithdraw);
        uint48 T4 = uint48(block.timestamp);

        // Move forward to the end of the next epoch
        vm.warp(T1 + 2 * vault.epochDuration());

        // =======================
        // Assertions for activeSharesAt and activeStakeAt
        // =======================

        // activeSharesAt Assertions
        assertEq(vault.activeSharesAt(T1, ""), aliceDeposit, "activeSharesAt T1 mismatch");
        assertEq(vault.activeSharesAt(T2, ""), aliceDeposit + bobDeposit, "activeSharesAt T2 mismatch");
        assertEq(vault.activeSharesAt(T3, ""), aliceDeposit - aliceWithdraw + bobDeposit, "activeSharesAt T3 mismatch");
        assertEq(vault.activeSharesAt(T4, ""), aliceDeposit - aliceWithdraw + bobDeposit - bobWithdraw, "activeSharesAt T4 mismatch");

        // activeStakeAt Assertions (assuming activeStake mirrors activeShares)
        assertEq(vault.activeStakeAt(T1, ""), aliceDeposit, "activeStakeAt T1 mismatch");
        assertEq(vault.activeStakeAt(T2, ""), aliceDeposit + bobDeposit, "activeStakeAt T2 mismatch");
        assertEq(vault.activeStakeAt(T3, ""), aliceDeposit - aliceWithdraw + bobDeposit, "activeStakeAt T3 mismatch");
        assertEq(vault.activeStakeAt(T4, ""), aliceDeposit - aliceWithdraw + bobDeposit - bobWithdraw, "activeStakeAt T4 mismatch");

        // =======================
        // Assertions for activeShares and activeStake
        // =======================

        // Current activeShares and activeStake
        uint256 expectedActive = aliceDeposit - aliceWithdraw + bobDeposit - bobWithdraw;
        assertEq(vault.activeShares(), expectedActive, "activeShares current mismatch");
        assertEq(vault.activeStake(), expectedActive, "activeStake current mismatch");

        // =======================
        // Assertions for activeSharesOfAt
        // =======================

        // Alice's activeSharesOfAt
        assertEq(vault.activeSharesOfAt(alice, T1, ""), aliceDeposit, "Alice's activeSharesOfAt T1 mismatch");
        assertEq(vault.activeSharesOfAt(alice, T3, ""), aliceDeposit - aliceWithdraw, "Alice's activeSharesOfAt T3 mismatch");

        // Bob's activeSharesOfAt
        assertEq(vault.activeSharesOfAt(bob, T2, ""), bobDeposit, "Bob's activeSharesOfAt T2 mismatch");
        assertEq(vault.activeSharesOfAt(bob, T4, ""), bobDeposit - bobWithdraw, "Bob's activeSharesOfAt T4 mismatch");

        // =======================
        // Assertions for activeSharesOf
        // =======================

        // Alice's activeSharesOf
        assertEq(vault.activeSharesOf(alice), aliceDeposit - aliceWithdraw, "Alice's activeSharesOf current mismatch");

        // Bob's activeSharesOf
        assertEq(vault.activeSharesOf(bob), bobDeposit - bobWithdraw, "Bob's activeSharesOf current mismatch");
    }



}
