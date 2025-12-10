// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {MiddlewareTestBase} from "./middleware/MiddlewareTestBase.t.sol";
import {VaultHelper, PendingWithdraw, ClaimAmountsPerToken} from "../src/contracts/VaultHelper.sol";
import {LSTWrapperFactory} from "../src/contracts/vault/LSTWrapperFactory.sol";
import {MockFeeOnTransferToken} from "./mocks/MockFeeOnTransferToken.sol";
import {IVaultTokenized} from "../src/interfaces/vault/IVaultTokenized.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Token} from "./mocks/MockToken.sol";
import {MockRewardsNativeToken} from "./mocks/MockRewardsNativeToken.sol";
import {RewardsNativeToken} from "../src/contracts/rewards/RewardsNativeToken.sol";
import {DefaultCollateralFactory} from "../src/contracts/defaultCollateral/DefaultCollateralFactory.sol";
import {IDefaultCollateral} from "../src/interfaces/defaultCollateral/IDefaultCollateral.sol";
import {VaultTokenized} from "../src/contracts/vault/VaultTokenized.sol";
import {LSTWrapper} from "../src/contracts/vault/LSTWrapper.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract VaultHelperTest is MiddlewareTestBase {
    VaultHelper public vaultHelper;
    LSTWrapperFactory public lstWrapperFactory;
    MockRewardsNativeToken public rewards;
    Token public rewardsToken;
    Token public rewardsToken2;
    address public lstAdmin;
    address public factoryOwner;

    // DefaultCollateral setup
    DefaultCollateralFactory public defaultCollateralFactory;
    address public defaultCollateral1;
    address public defaultCollateral2;
    Token public underlyingToken1;
    Token public underlyingToken2;

    // Vaults that use DefaultCollateral
    VaultTokenized public vaultWithDC1;
    VaultTokenized public vaultWithDC2;

    // LST Wrapper contracts that wrap vaults
    LSTWrapper public lstWrapper1;
    LSTWrapper public lstWrapper1Implementation;
    LSTWrapper public lstWrapper2;
    LSTWrapper public lstWrapper2Implementation;

    function setUp() public override {
        super.setUp();

        lstAdmin = makeAddr("lstAdmin");
        factoryOwner = makeAddr("factoryOwner");

        // Deploy LSTWrapperFactory and whitelist implementation
        lstWrapperFactory = new LSTWrapperFactory(factoryOwner);
        
        LSTWrapper wrapperImpl = new LSTWrapper();
        vm.prank(factoryOwner);
        lstWrapperFactory.whitelist(address(wrapperImpl));

        // Deploy VaultHelper with both factories
        vaultHelper = new VaultHelper(address(vaultFactory), address(lstWrapperFactory));

        // Deploy DefaultCollateralFactory
        defaultCollateralFactory = new DefaultCollateralFactory();

        // Create underlying tokens for DefaultCollateral
        underlyingToken1 = new Token("Underlying Token 1");
        underlyingToken2 = new Token("Underlying Token 2");

        // Create DefaultCollateral instances through factory
        defaultCollateral1 = defaultCollateralFactory.create(
            address(underlyingToken1),
            type(uint256).max, // no limit
            address(0) // no limit increaser
        );

        defaultCollateral2 = defaultCollateralFactory.create(
            address(underlyingToken2),
            type(uint256).max, // no limit
            address(0) // no limit increaser
        );

        // Create vaults that use DefaultCollateral as their collateral
        uint48 epochDuration = 8 hours;
        uint64 lastVersion = vaultFactory.lastVersion();

        address vaultAddress1 = vaultFactory.create(
            lastVersion,
            curatorOwner1,
            abi.encode(
                IVaultTokenized.InitParams({
                    collateral: defaultCollateral1,
                    burner: address(0xdEaD),
                    epochDuration: epochDuration,
                    depositWhitelist: false,
                    isDepositLimit: false,
                    depositLimit: 0,
                    defaultAdminRoleHolder: curatorOwner1,
                    depositWhitelistSetRoleHolder: curatorOwner1,
                    depositorWhitelistRoleHolder: curatorOwner1,
                    isDepositLimitSetRoleHolder: curatorOwner1,
                    depositLimitSetRoleHolder: curatorOwner1,
                    name: "VaultWithDC1",
                    symbol: "VDC1"
                })
            ),
            address(delegatorFactory),
            address(slasherFactory)
        );
        vaultWithDC1 = VaultTokenized(vaultAddress1);

        address vaultAddress2 = vaultFactory.create(
            lastVersion,
            curatorOwner2,
            abi.encode(
                IVaultTokenized.InitParams({
                    collateral: defaultCollateral2,
                    burner: address(0xdEaD),
                    epochDuration: epochDuration,
                    depositWhitelist: false,
                    isDepositLimit: false,
                    depositLimit: 0,
                    defaultAdminRoleHolder: curatorOwner2,
                    depositWhitelistSetRoleHolder: curatorOwner2,
                    depositorWhitelistRoleHolder: curatorOwner2,
                    isDepositLimitSetRoleHolder: curatorOwner2,
                    depositLimitSetRoleHolder: curatorOwner2,
                    name: "VaultWithDC2",
                    symbol: "VDC2"
                })
            ),
            address(delegatorFactory),
            address(slasherFactory)
        );
        vaultWithDC2 = VaultTokenized(vaultAddress2);

        // Deploy mock rewards for the rewards tests
        rewardsToken = new Token("Rewards");
        rewardsToken2 = new Token("Rewards2");
        rewards = new MockRewardsNativeToken(address(middleware), address(vault), address(rewardsToken));

        // Deploy wrappers through factory (permissionless - anyone can call)
        lstWrapper1 = LSTWrapper(
            lstWrapperFactory.create(
                1, // version
                lstAdmin,
                address(vaultWithDC1),
                address(rewards),
                "LST Wrapped VaultWithDC1",
                "lstVDC1"
            )
        );

        lstWrapper2 = LSTWrapper(
            lstWrapperFactory.create(
                1, // version
                lstAdmin,
                address(vaultWithDC2),
                address(rewards),
                "LST Wrapped VaultWithDC2",
                "lstVDC2"
            )
        );

        // Wrappers are automatically registered by factory.create()

        // Give staker some underlying tokens to work with
        underlyingToken1.transfer(staker, 100_000 ether);
        underlyingToken2.transfer(staker, 100_000 ether);

        // Initialize wrappers for testing
        _initializeWrapperForTesting(
            lstWrapper1, address(underlyingToken1), defaultCollateral1, address(vaultWithDC1), lstAdmin
        );
        _initializeWrapperForTesting(
            lstWrapper2, address(underlyingToken2), defaultCollateral2, address(vaultWithDC2), lstAdmin
        );
    }

    function _initializeWrapperForTesting(
        LSTWrapper wrapper,
        address underlyingToken,
        address collateral,
        address vaultToken,
        address owner
    ) internal {
        // Owner performs seed deposit (required for first mint protection)
        uint256 initialSeed = 1000; // Reasonable seed to unlock first mint

        IERC20(underlyingToken).approve(address(vaultHelper), initialSeed);
        vaultHelper.stakeAssetInVault(
            address(vaultToken), address(this), collateral, address(underlyingToken), initialSeed
        );
        IERC20(vaultToken).transfer(owner, initialSeed);

        vm.startPrank(owner);
        IERC20(vaultToken).approve(address(wrapper), initialSeed);
        wrapper.deposit(initialSeed, owner); // Owner can deposit even while paused
        // Now unpause for regular testing
        wrapper.setDepositsPaused(false);
        vm.stopPrank();

        // Note: We keep the seed to prevent totalSupply from going back to 0
        // Tests need to account for this seed in their assertions
    }

    function test_StakeAssetInVault() public {
        uint256 amount = 10_000 ether;

        // Check initial balances
        uint256 stakerBalanceBefore = underlyingToken1.balanceOf(staker);
        uint256 vaultSharesBefore = vaultWithDC1.activeSharesOf(staker);

        // Approve and stake
        vm.startPrank(staker);
        underlyingToken1.approve(address(vaultHelper), amount);
        vaultHelper.stakeAssetInVault(
            address(vaultWithDC1), staker, defaultCollateral1, address(underlyingToken1), amount
        );
        vm.stopPrank();

        // Verify results
        uint256 stakerBalanceAfter = underlyingToken1.balanceOf(staker);
        uint256 vaultSharesAfter = vaultWithDC1.activeSharesOf(staker);

        assertEq(stakerBalanceBefore - stakerBalanceAfter, amount, "Staker should have spent the exact amount");
        assertEq(vaultSharesAfter - vaultSharesBefore, amount, "Vault shares should equal deposit amount");
    }

    function test_InvalidLSTWrapper_Reverts() public {
        uint256 amount = 10_000 ether;
        address invalidLSTWrapper = address(0);

        vm.startPrank(staker);
        // Test zero address
        vm.expectRevert(abi.encodeWithSelector(VaultHelper.VaultHelper__ZeroAddress.selector, "lstWrapper"));
        vaultHelper.stakeAssetInWrappedVault(staker, invalidLSTWrapper, amount);

        // Test EOA (address with no code)
        invalidLSTWrapper = makeAddr("InvalidLSTWrapper");
        vm.expectRevert(abi.encodeWithSelector(VaultHelper.VaultHelper__LSTWrapperMismatch.selector, invalidLSTWrapper));
        vaultHelper.stakeAssetInWrappedVault(staker, invalidLSTWrapper, amount);

        // Test contract that returns invalid addresses - will revert when trying to use address(0)
        invalidLSTWrapper = address(new MockLSTWrapper());
        vm.expectRevert(); // Will revert when trying to call methods on address(0) returned by mock
        vaultHelper.stakeAssetInWrappedVault(staker, invalidLSTWrapper, amount);
        vm.stopPrank();
    }

    function test_StakeAssetInWrappedVault() public {
        uint256 amount = 10_000 ether;

        // Check initial balances
        uint256 stakerBalanceBefore = underlyingToken1.balanceOf(staker);
        uint256 lstSharesBefore = lstWrapper1.balanceOf(staker);

        // Approve and stake
        vm.startPrank(staker);
        underlyingToken1.approve(address(vaultHelper), amount);
        vaultHelper.stakeAssetInWrappedVault(staker, address(lstWrapper1), amount);
        vm.stopPrank();

        // Verify results
        uint256 stakerBalanceAfter = underlyingToken1.balanceOf(staker);
        uint256 lstSharesAfter = lstWrapper1.balanceOf(staker);

        assertEq(stakerBalanceBefore - stakerBalanceAfter, amount, "Staker should have spent the exact amount");
        assertEq(lstSharesAfter - lstSharesBefore, amount, "LST shares should equal deposit amount");
    }

    function test_StakeAssetInVault_FeeOnTransferToken() public {
        // Deploy fee-on-transfer token
        MockFeeOnTransferToken feeToken = new MockFeeOnTransferToken("FeeToken");

        // Deploy DefaultCollateral for fee token through factory
        address feeTokenCollateral = defaultCollateralFactory.create(address(feeToken), type(uint256).max, address(0));

        // Create a vault that uses this fee token collateral
        uint48 epochDuration = 8 hours;
        uint64 lastVersion = vaultFactory.lastVersion();
        address feeTokenVaultAddr = vaultFactory.create(
            lastVersion,
            curatorOwner3,
            abi.encode(
                IVaultTokenized.InitParams({
                    collateral: feeTokenCollateral,
                    burner: address(0xdEaD),
                    epochDuration: epochDuration,
                    depositWhitelist: false,
                    isDepositLimit: false,
                    depositLimit: 0,
                    defaultAdminRoleHolder: curatorOwner3,
                    depositWhitelistSetRoleHolder: curatorOwner3,
                    depositorWhitelistRoleHolder: curatorOwner3,
                    isDepositLimitSetRoleHolder: curatorOwner3,
                    depositLimitSetRoleHolder: curatorOwner3,
                    name: "FeeTokenVault",
                    symbol: "FTV"
                })
            ),
            address(delegatorFactory),
            address(slasherFactory)
        );
        VaultTokenized feeTokenVault = VaultTokenized(feeTokenVaultAddr);

        // Give staker some fee tokens
        feeToken.transfer(staker, 10_000 ether);

        uint256 depositAmount = 1000 ether;
        // Fee token deducts 1 token on each transfer:
        // 1. From staker to VaultHelper: 1000 - 1 = 999
        // 2. From VaultHelper to DefaultCollateral: 999 - 1 = 998
        uint256 expectedReceived = depositAmount - 2;

        // Record initial state
        uint256 stakerBalanceBefore = feeToken.balanceOf(staker);
        uint256 vaultSharesBefore = feeTokenVault.activeSharesOf(staker);

        // Approve and stake
        vm.startPrank(staker);
        feeToken.approve(address(vaultHelper), depositAmount);
        vaultHelper.stakeAssetInVault(
            address(feeTokenVault), staker, feeTokenCollateral, address(feeToken), depositAmount
        );
        vm.stopPrank();

        // Verify results
        uint256 stakerBalanceAfter = feeToken.balanceOf(staker);
        uint256 vaultSharesAfter = feeTokenVault.activeSharesOf(staker);

        // User should have paid exactly depositAmount
        assertEq(stakerBalanceBefore - stakerBalanceAfter, depositAmount, "User paid full amount");

        // Vault should have received shares based on actualAmount (depositAmount - 1)
        assertEq(vaultSharesAfter - vaultSharesBefore, expectedReceived, "Vault shares match actual received");
    }

    function test_StakeAssetInVault_StandardToken_StillWorks() public {
        // This test ensures our fix doesn't break normal token functionality
        uint256 amount = 1000 ether;

        // Record initial state
        uint256 stakerBalanceBefore = underlyingToken2.balanceOf(staker);
        uint256 vaultSharesBefore = vaultWithDC2.activeSharesOf(staker);

        // Approve and stake
        vm.startPrank(staker);
        underlyingToken2.approve(address(vaultHelper), amount);
        vaultHelper.stakeAssetInVault(
            address(vaultWithDC2), staker, defaultCollateral2, address(underlyingToken2), amount
        );
        vm.stopPrank();

        // Verify standard tokens work as expected
        uint256 stakerBalanceAfter = underlyingToken2.balanceOf(staker);
        uint256 vaultSharesAfter = vaultWithDC2.activeSharesOf(staker);

        assertEq(stakerBalanceBefore - stakerBalanceAfter, amount, "Exact amount transferred");
        assertEq(vaultSharesAfter - vaultSharesBefore, amount, "Vault shares equal deposit");
    }

    function test_StakeAssetInVault_RelayerPaysForUser() public {
        // Test that a relayer can pay tokens on behalf of a user
        address relayer = makeAddr("relayer");
        underlyingToken1.transfer(relayer, 5000 ether);

        uint256 amount = 1000 ether;

        // Record initial states
        uint256 relayerBalanceBefore = underlyingToken1.balanceOf(relayer);
        uint256 userBalanceBefore = underlyingToken1.balanceOf(alice);
        uint256 relayerSharesBefore = vaultWithDC1.activeSharesOf(relayer);
        uint256 userSharesBefore = vaultWithDC1.activeSharesOf(alice);

        // Relayer approves and stakes for alice
        vm.startPrank(relayer);
        underlyingToken1.approve(address(vaultHelper), amount);
        vaultHelper.stakeAssetInVault(
            address(vaultWithDC1), alice, defaultCollateral1, address(underlyingToken1), amount
        );
        vm.stopPrank();

        // Verify results
        uint256 relayerBalanceAfter = underlyingToken1.balanceOf(relayer);
        uint256 userBalanceAfter = underlyingToken1.balanceOf(alice);
        uint256 relayerSharesAfter = vaultWithDC1.activeSharesOf(relayer);
        uint256 userSharesAfter = vaultWithDC1.activeSharesOf(alice);

        // Relayer paid the tokens
        assertEq(relayerBalanceBefore - relayerBalanceAfter, amount, "Relayer paid");
        // User didn't pay anything
        assertEq(userBalanceBefore, userBalanceAfter, "User balance unchanged");
        // User got the shares
        assertEq(userSharesAfter - userSharesBefore, amount, "User got shares");
        // Relayer got no shares
        assertEq(relayerSharesAfter, relayerSharesBefore, "Relayer shares unchanged");
    }

    function test_StakeAssetInVault_InvalidVault_Reverts() public {
        address fakeVault = makeAddr("FakeVault");

        vm.startPrank(staker);
        underlyingToken1.approve(address(vaultHelper), 1000 ether);

        vm.expectRevert(abi.encodeWithSelector(VaultHelper.VaultHelper__InvalidVault.selector, fakeVault));
        vaultHelper.stakeAssetInVault(fakeVault, staker, defaultCollateral1, address(underlyingToken1), 1000 ether);
        vm.stopPrank();
    }

    function test_StakeAssetInVault_ZeroAddress_Reverts() public {
        vm.startPrank(staker);
        underlyingToken1.approve(address(vaultHelper), 1000 ether);

        // Test zero vault address
        vm.expectRevert(abi.encodeWithSelector(VaultHelper.VaultHelper__ZeroAddress.selector, "vault"));
        vaultHelper.stakeAssetInVault(address(0), staker, defaultCollateral1, address(underlyingToken1), 1000 ether);

        // Test zero collateral address
        vm.expectRevert(abi.encodeWithSelector(VaultHelper.VaultHelper__ZeroAddress.selector, "collateral"));
        vaultHelper.stakeAssetInVault(address(vaultWithDC1), staker, address(0), address(underlyingToken1), 1000 ether);

        // Test zero underlying address
        vm.expectRevert(abi.encodeWithSelector(VaultHelper.VaultHelper__ZeroAddress.selector, "underlying"));
        vaultHelper.stakeAssetInVault(address(vaultWithDC1), staker, defaultCollateral1, address(0), 1000 ether);

        // Test zero user address
        vm.expectRevert(abi.encodeWithSelector(VaultHelper.VaultHelper__InvalidUser.selector, address(0)));
        vaultHelper.stakeAssetInVault(
            address(vaultWithDC1), address(0), defaultCollateral1, address(underlyingToken1), 1000 ether
        );

        vm.stopPrank();
    }

    function test_GetUserPendingWithdraws() public {
        // Use base vault from parent for this test
        // Setup: Make a withdrawal request
        collateral.transfer(alice, 100_000 ether);
        vm.startPrank(alice);
        collateral.approve(address(vault), 100_000 ether);
        vault.deposit(alice, 100_000 ether);

        // Move to next block to allow withdrawal
        vm.warp(block.timestamp + 1);

        // Request withdrawal - this creates withdrawal shares for the NEXT epoch
        vault.withdraw(alice, 50_000 ether);
        vm.stopPrank();

        // Record the epoch where withdrawal will be recorded (next epoch)
        uint256 withdrawalEpoch = vault.currentEpoch() + 1;

        // Move forward to advance past the withdrawal epoch
        // Need to advance at least 2 epochs so withdrawalEpoch becomes a past epoch
        vm.warp(block.timestamp + vault.epochDuration() * 2 + 1);

        // Check pending withdrawals
        PendingWithdraw[] memory pendingWithdraws = vaultHelper.getUserPendingWithdraws(address(vault), alice);

        // Should have one pending withdrawal
        assertEq(pendingWithdraws.length, 1, "Should have 1 pending withdrawal");
        assertEq(pendingWithdraws[0].amount, 50_000 ether, "Withdrawal amount should match");
        assertEq(pendingWithdraws[0].epoch, withdrawalEpoch, "Should be from the epoch when withdrawal was recorded");
    }

    function test_GetUserFuturePendingWithdraws() public {
        // Use base vault from parent for this test
        // Setup: Make deposits and withdrawal requests across epochs
        collateral.transfer(alice, 200_000 ether);
        vm.startPrank(alice);
        collateral.approve(address(vault), 200_000 ether);
        vault.deposit(alice, 100_000 ether);

        // Request withdrawal for current epoch
        vault.withdraw(alice, 50_000 ether);
        vm.stopPrank();

        // Check future pending withdrawals
        PendingWithdraw[] memory futureWithdraws = vaultHelper.getUserFuturePendingWithdraws(address(vault), alice);

        // Should include the withdrawal from current epoch
        assertGt(futureWithdraws.length, 0, "Should have future withdrawals");
    }

    function test_GetUserPendingWithdrawsInRange() public {
        // Move forward to ensure toEpoch is in the valid future (advance to at least epoch 10)
        uint256 epochsNeeded = 10 - vault.currentEpoch();
        if (epochsNeeded > 0) {
            vm.warp(block.timestamp + vault.epochDuration() * epochsNeeded + 1);
        }

        uint256 fromEpoch = 0;
        uint256 toEpoch = 10;

        PendingWithdraw[] memory pendingWithdraws =
            vaultHelper.getUserPendingWithdrawsInRange(address(vault), alice, fromEpoch, toEpoch);

        // Should return withdrawals within range (may be empty if no withdrawals)
        assertTrue(pendingWithdraws.length <= toEpoch - fromEpoch, "Should not exceed range");
    }

    function test_GetUserPendingWithdrawsInRange_InvalidRange_Reverts() public {
        // Test fromEpoch >= toEpoch
        vm.expectRevert(VaultHelper.VaultHelper__InvalidRange.selector);
        vaultHelper.getUserPendingWithdrawsInRange(address(vault), alice, 10, 10);

        vm.expectRevert(VaultHelper.VaultHelper__InvalidRange.selector);
        vaultHelper.getUserPendingWithdrawsInRange(address(vault), alice, 10, 5);
    }

    function test_GetUserPendingWithdrawsInRange_ZeroAddress_Reverts() public {
        // Test zero vault address
        vm.expectRevert(abi.encodeWithSelector(VaultHelper.VaultHelper__ZeroAddress.selector, "vault"));
        vaultHelper.getUserPendingWithdrawsInRange(address(0), alice, 0, 10);

        // Test zero user address
        vm.expectRevert(abi.encodeWithSelector(VaultHelper.VaultHelper__InvalidUser.selector, address(0)));
        vaultHelper.getUserPendingWithdrawsInRange(address(vault), address(0), 0, 10);
    }

    // Rewards tests - properly set up to avoid arithmetic overflow
    function test_GetStakerClaimableRewards() public {
        // Since getStakerClaimableRewards expects an array of vaults and returns aggregated amounts,
        // we'll test the simpler getStakerClaimableReward first and then test the array version

        // Test with real contracts setup
        address rewardToken = address(collateral);
        uint48 currentEpoch = 100;
        uint48 lastClaimedEpoch = 95; // 5 epochs unclaimed

        // Create a mock rewards contract
        address mockRewards = makeAddr("mockRewards");

        // Mock the middleware getter on rewards contract
        vm.mockCall(mockRewards, abi.encodeWithSignature("middleware()"), abi.encode(address(middleware)));

        // Mock middleware getCurrentEpoch
        vm.mockCall(
            address(middleware), abi.encodeWithSelector(middleware.getCurrentEpoch.selector), abi.encode(currentEpoch)
        );

        // Mock lastEpochClaimedStaker on rewards
        vm.mockCall(
            mockRewards, abi.encodeWithSignature("lastEpochClaimedStaker(address)", alice), abi.encode(lastClaimedEpoch)
        );

        // For each epoch from 96 to 99, mock the necessary data
        for (uint48 epoch = 96; epoch < 100; epoch++) {
            uint48 epochTs = epoch * 1000; // Simple timestamp calculation for test

            // Mock getEpochStartTs
            vm.mockCall(
                address(middleware),
                abi.encodeWithSelector(middleware.getEpochStartTs.selector, epoch),
                abi.encode(epochTs)
            );

            // Mock rewards amount for this epoch (1000 tokens per epoch)
            vm.mockCall(mockRewards, abi.encodeWithSignature("getEpochRewards(uint48)", epoch), abi.encode(1000 ether));

            // Mock vault share (50% = 5000 basis points)
            vm.mockCall(
                mockRewards,
                abi.encodeWithSignature("vaultShares(uint48,address)", epoch, address(vault)),
                abi.encode(5000)
            );

            // Mock staker's active shares in vault at epochTs (25% of vault)
            vm.mockCall(
                address(vault),
                abi.encodeWithSelector(IVaultTokenized.activeSharesOfAt.selector, alice, epochTs, ""),
                abi.encode(250 ether)
            );

            // Mock total vault shares at epochTs
            vm.mockCall(
                address(vault),
                abi.encodeWithSelector(IVaultTokenized.activeSharesAt.selector, epochTs, ""),
                abi.encode(1000 ether)
            );
        }

        // Mock rewardsToken() getter
        vm.mockCall(mockRewards, abi.encodeWithSignature("rewardsToken()"), abi.encode(rewardToken));

        // Test single vault reward calculation
        ClaimAmountsPerToken memory claimAmount =
            vaultHelper.getStakerClaimableReward(alice, mockRewards, address(vault), rewardToken);

        // Expected: 4 epochs * (1000 ether * 50% * 25%) = 4 * 125 ether = 500 ether
        assertEq(claimAmount.token, rewardToken, "Token address mismatch");
        assertEq(claimAmount.amount, 500 ether, "Claim amount incorrect");

        // Now test the array version
        address[] memory tokens = new address[](1);
        tokens[0] = rewardToken;

        ClaimAmountsPerToken[] memory claimAmounts =
            vaultHelper.getStakerClaimableRewards(alice, mockRewards, address(vault), tokens);

        assertEq(claimAmounts.length, 1, "Should return one claim amount");
        assertEq(claimAmounts[0].token, rewardToken, "Token address mismatch in array");
        assertEq(claimAmounts[0].amount, 500 ether, "Claim amount incorrect in array");
    }

    function test_GetStakerClaimableReward() public {
        // This test is already covered in test_GetStakerClaimableRewards above
        // The getStakerClaimableReward function is tested there with proper mocking
    }

    function test_GetStakerClaimableRewardInRange() public {
        // Test rewards calculation within specific epoch range
        address staker = alice;
        address rewardToken = address(collateral);
        uint48 fromEpoch = 10;
        uint48 toEpoch = 15; // 5 epochs in range

        // Create a mock rewards contract
        address mockRewards = makeAddr("mockRewards");

        // Mock the middleware getter on rewards contract
        vm.mockCall(mockRewards, abi.encodeWithSignature("middleware()"), abi.encode(address(middleware)));

        // Ensure helper's currentEpoch cap does not truncate [fromEpoch, toEpoch)
        vm.mockCall(
            address(middleware),
            abi.encodeWithSelector(middleware.getCurrentEpoch.selector),
            abi.encode(uint48(toEpoch)) // any value >= toEpoch is fine
        );

        // For each epoch in range, mock the necessary data
        for (uint48 epoch = fromEpoch; epoch < toEpoch; epoch++) {
            uint48 epochTs = epoch * 1000; // Simple timestamp calculation for test

            // Mock getEpochStartTs
            vm.mockCall(
                address(middleware),
                abi.encodeWithSelector(middleware.getEpochStartTs.selector, epoch),
                abi.encode(epochTs)
            );

            // Mock rewards amount for this epoch (200 tokens per epoch)
            vm.mockCall(mockRewards, abi.encodeWithSignature("getEpochRewards(uint48)", epoch), abi.encode(200 ether));

            // Mock vault share (25% = 2500 basis points)
            vm.mockCall(
                mockRewards,
                abi.encodeWithSignature("vaultShares(uint48,address)", epoch, address(vault)),
                abi.encode(2500)
            );

            // Mock staker's active shares in vault at epochTs (50% of vault)
            vm.mockCall(
                address(vault),
                abi.encodeWithSelector(IVaultTokenized.activeSharesOfAt.selector, staker, epochTs, ""),
                abi.encode(500 ether)
            );

            // Mock total vault shares at epochTs
            vm.mockCall(
                address(vault),
                abi.encodeWithSelector(IVaultTokenized.activeSharesAt.selector, epochTs, ""),
                abi.encode(1000 ether)
            );
        }

        // Mock rewardsToken() getter
        vm.mockCall(mockRewards, abi.encodeWithSignature("rewardsToken()"), abi.encode(rewardToken));

        // Get claimable reward in range
        ClaimAmountsPerToken memory claimAmount = vaultHelper.getStakerClaimableRewardInRange(
            staker, mockRewards, address(vault), rewardToken, fromEpoch, toEpoch
        );

        // Expected: 5 epochs * (200 ether * 25% * 50%) = 5 * 25 ether = 125 ether
        assertEq(claimAmount.token, rewardToken, "Token address mismatch");
        assertEq(claimAmount.amount, 125 ether, "Range reward incorrect");
    }

    function test_GetStakerClaimableRewardInRange_InvalidRange_Reverts() public {
        // Test fromEpoch >= toEpoch
        vm.expectRevert(VaultHelper.VaultHelper__InvalidRange.selector);
        vaultHelper.getStakerClaimableRewardInRange(
            alice, address(rewards), address(vault), address(rewardsToken), 1055, 1055
        );

        vm.expectRevert(VaultHelper.VaultHelper__InvalidRange.selector);
        vaultHelper.getStakerClaimableRewardInRange(
            alice, address(rewards), address(vault), address(rewardsToken), 1055, 1050
        );
    }

    function test_MultipleVaults_DifferentUnderlying() public {
        // Test staking in vaultWithDC1 with underlyingToken1
        uint256 amount1 = 5000 ether;
        vm.startPrank(staker);
        underlyingToken1.approve(address(vaultHelper), amount1);
        vaultHelper.stakeAssetInVault(
            address(vaultWithDC1), staker, defaultCollateral1, address(underlyingToken1), amount1
        );
        vm.stopPrank();

        assertEq(vaultWithDC1.activeSharesOf(staker), amount1, "Should have shares in vault1");

        // Test staking in vaultWithDC2 with underlyingToken2
        uint256 amount2 = 3000 ether;
        vm.startPrank(staker);
        underlyingToken2.approve(address(vaultHelper), amount2);
        vaultHelper.stakeAssetInVault(
            address(vaultWithDC2), staker, defaultCollateral2, address(underlyingToken2), amount2
        );
        vm.stopPrank();

        assertEq(vaultWithDC2.activeSharesOf(staker), amount2, "Should have shares in vault2");
    }

    function test_ZeroAmount_Reverts() public {
        vm.startPrank(staker);
        underlyingToken1.approve(address(vaultHelper), 1000 ether);

        vm.expectRevert(abi.encodeWithSelector(VaultHelper.VaultHelper__InvalidAmount.selector, 0));
        vaultHelper.stakeAssetInVault(address(vaultWithDC1), staker, defaultCollateral1, address(underlyingToken1), 0);
        vm.stopPrank();
    }

    function test_WithdrawFromWrappedVault() public {
        uint256 amountDeposit = 10_000 ether;

        // Approve and stake
        vm.startPrank(staker);
        underlyingToken1.approve(address(vaultHelper), amountDeposit);
        vaultHelper.stakeAssetInWrappedVault(staker, address(lstWrapper1), amountDeposit);
        vm.stopPrank();

        // Check balance after deposit
        assertEq(lstWrapper1.balanceOf(staker), amountDeposit, "Should have shares in lstWrapper after deposit");

        // Withdraw half
        uint256 amountWithdraw = amountDeposit / 2;
        vm.startPrank(staker);
        lstWrapper1.approve(address(vaultHelper), amountWithdraw);
        vaultHelper.withdrawFromWrappedVault(address(lstWrapper1), amountWithdraw);
        vm.stopPrank();

        // Check balance after withdrawal
        assertEq(
            lstWrapper1.balanceOf(staker),
            amountDeposit - amountWithdraw,
            "Should have half less shares in lstWrapper after withdrawal"
        );

        // Check future pending withdrawals from vault
        PendingWithdraw[] memory futureWithdraws =
            vaultHelper.getUserFuturePendingWithdraws(address(vaultWithDC1), staker);
        assertEq(futureWithdraws.length, 1, "Should have 1 future pending withdrawal");
        assertEq(futureWithdraws[0].amount, amountWithdraw, "Withdrawal amount should match");
        assertEq(futureWithdraws[0].epoch, vaultWithDC1.currentEpoch() + 1, "Should be from the next epoch");
    }

    function test_WithdrawFromWrappedVault_YieldLossBug() public {
        uint256 depositAmount = 10_000 ether;

        // 1. Setup: User stakes 10,000
        vm.startPrank(staker);
        underlyingToken1.approve(address(vaultHelper), depositAmount);
        vaultHelper.stakeAssetInWrappedVault(staker, address(lstWrapper1), depositAmount);
        vm.stopPrank();

        // 2. Simulate Yield (Auto-Compounding)
        // We simulate this by donating Vault Shares directly to the LSTWrapper.
        // This makes the LSTWrapper hold MORE vault shares than it minted LST shares.
        // Scenario: 10% yield.
        uint256 yieldAmount = 1000 ether;

        // Mint vault shares to this test contract then transfer to wrapper to simulate yield
        vm.startPrank(staker);
        // (Staker has plenty of underlying from setUp)
        underlyingToken1.approve(address(vaultHelper), yieldAmount);
        vaultHelper.stakeAssetInVault(
            address(vaultWithDC1), staker, defaultCollateral1, address(underlyingToken1), yieldAmount
        );
        // Transfer the resulting vault shares to the wrapper (Donation/Yield)
        vaultWithDC1.transfer(address(lstWrapper1), yieldAmount);
        vm.stopPrank();

        // CHECKPOINT: PPS should now be > 1
        // Total Assets (Vault Shares) = 11,000
        // Total Supply (LST Shares) = 10,000 + (seed)
        // Exchange rate is approx 1.1
        uint256 assetsPerShare = lstWrapper1.convertToAssets(1 ether);
        assertGt(assetsPerShare, 1 ether, "PPS should be > 1");

        // 3. User withdraws their FULL balance
        uint256 lstBalance = lstWrapper1.balanceOf(staker);

        // Calculate what the user SHOULD get in Vault Shares
        uint256 expectedVaultShares = lstWrapper1.convertToAssets(lstBalance);

        vm.startPrank(staker);
        lstWrapper1.approve(address(vaultHelper), lstBalance);

        // --- PERFORM WITHDRAWAL ---
        vaultHelper.withdrawFromWrappedVault(address(lstWrapper1), lstBalance);
        vm.stopPrank();

        // 4. DETECT THE BUG
        // The Helper redeemed 'lstBalance' (10,000) from the Vault,
        // instead of 'expectedVaultShares' (11,000).
        // The difference (1,000) is left stuck in the VaultHelper contract.

        uint256 stuckFunds = vaultWithDC1.balanceOf(address(vaultHelper));

        console2.log("Stuck Funds in Helper:", stuckFunds);
        console2.log("Expected Vault Shares:", expectedVaultShares);
        console2.log("LST Burned:", lstBalance);

        // If the bug is present, this assertion is TRUE:
        // assertEq(stuckFunds, expectedVaultShares - lstBalance, "CRITICAL: Yield was left stuck in the helper!");

        // If you fix the bug, you should change the assertion to:
        assertEq(stuckFunds, 0, "Helper should be empty");
    }

    /// @notice Test that attacker cannot redeem victim's shares (uses msg.sender now)
    function test_WithdrawFromWrappedVault_AttackerCannotRedeemVictimShares() public {
        uint256 depositAmount = 10_000 ether;
        address attacker = makeAddr("attacker");

        // 1. Victim stakes via VaultHelper
        vm.startPrank(staker);
        underlyingToken1.approve(address(vaultHelper), depositAmount);
        vaultHelper.stakeAssetInWrappedVault(staker, address(lstWrapper1), depositAmount);
        lstWrapper1.approve(address(vaultHelper), type(uint256).max);
        vm.stopPrank();

        uint256 victimLstBalance = lstWrapper1.balanceOf(staker);

        // 2. Attacker tries to withdraw - but msg.sender is attacker, who has no shares
        vm.startPrank(attacker);
        lstWrapper1.approve(address(vaultHelper), type(uint256).max);
        vm.expectRevert(); // Will revert due to insufficient balance
        vaultHelper.withdrawFromWrappedVault(address(lstWrapper1), victimLstBalance);
        vm.stopPrank();

        // 3. Victim's shares are untouched
        assertEq(lstWrapper1.balanceOf(staker), victimLstBalance, "Victim shares unchanged");
    }

    /// @notice Test that authorized withdrawals still work
    function test_WithdrawFromWrappedVault_AuthorizedRedemption_Succeeds() public {
        uint256 depositAmount = 10_000 ether;

        vm.startPrank(staker);
        underlyingToken1.approve(address(vaultHelper), depositAmount);
        vaultHelper.stakeAssetInWrappedVault(staker, address(lstWrapper1), depositAmount);

        uint256 lstBalance = lstWrapper1.balanceOf(staker);
        lstWrapper1.approve(address(vaultHelper), lstBalance);

        // User withdraws their own position - should succeed
        vaultHelper.withdrawFromWrappedVault(address(lstWrapper1), lstBalance);
        vm.stopPrank();

        assertEq(lstWrapper1.balanceOf(staker), 0, "User should have withdrawn their shares");
    }

    // ============================================
    // Malicious Wrapper Validation Tests
    // ============================================

    /// @notice Test that a malicious wrapper with an invalid vault (not in factory) is rejected
    function test_MaliciousWrapper_InvalidVault_Reverts() public {
        address fakeVault = makeAddr("fakeVault");
        
        // Deploy malicious wrapper that returns the correct vaultHelper but a fake vault
        MaliciousLSTWrapper maliciousWrapper = new MaliciousLSTWrapper(
            address(vaultHelper),
            fakeVault,
            defaultCollateral1,
            address(underlyingToken1)
        );

        vm.startPrank(staker);
        underlyingToken1.approve(address(vaultHelper), 1000 ether);

        // Should revert because the vault is not in the factory registry
        vm.expectRevert(abi.encodeWithSelector(VaultHelper.VaultHelper__InvalidVault.selector, fakeVault));
        vaultHelper.stakeAssetInWrappedVault(staker, address(maliciousWrapper), 1000 ether);
        vm.stopPrank();
    }

    /// @notice Test that a malicious wrapper with mismatched collateral is rejected
    function test_MaliciousWrapper_CollateralMismatch_Reverts() public {
        // Deploy malicious wrapper that returns:
        // - correct vaultHelper
        // - valid vault (vaultWithDC1 which uses defaultCollateral1)
        // - WRONG collateral (defaultCollateral2)
        // - nativeToken matching the wrong collateral (underlyingToken2)
        MaliciousLSTWrapper maliciousWrapper = new MaliciousLSTWrapper(
            address(vaultHelper),
            address(vaultWithDC1),    // Valid vault in factory
            defaultCollateral2,        // WRONG collateral (vault uses defaultCollateral1)
            address(underlyingToken2)  // Asset of wrong collateral
        );

        vm.startPrank(staker);
        underlyingToken2.approve(address(vaultHelper), 1000 ether);

        // Should revert because collateral doesn't match vault's collateral
        vm.expectRevert(
            abi.encodeWithSelector(
                VaultHelper.VaultHelper__CollateralMismatch.selector,
                defaultCollateral2,      // provided by wrapper
                defaultCollateral1       // expected by vault
            )
        );
        vaultHelper.stakeAssetInWrappedVault(staker, address(maliciousWrapper), 1000 ether);
        vm.stopPrank();
    }

    /// @notice Test that a malicious wrapper with mismatched nativeToken is rejected
    function test_MaliciousWrapper_AssetMismatch_Reverts() public {
        // Deploy malicious wrapper that returns:
        // - correct vaultHelper
        // - valid vault (vaultWithDC1 which uses defaultCollateral1)
        // - correct collateral (defaultCollateral1 which uses underlyingToken1)
        // - WRONG nativeToken (underlyingToken2)
        MaliciousLSTWrapper maliciousWrapper = new MaliciousLSTWrapper(
            address(vaultHelper),
            address(vaultWithDC1),      // Valid vault
            defaultCollateral1,          // Correct collateral
            address(underlyingToken2)    // WRONG native token (should be underlyingToken1)
        );

        vm.startPrank(staker);
        underlyingToken2.approve(address(vaultHelper), 1000 ether);

        // Should revert because nativeToken doesn't match collateral's asset
        vm.expectRevert(
            abi.encodeWithSelector(
                VaultHelper.VaultHelper__AssetMismatch.selector,
                address(underlyingToken2),  // provided by wrapper
                address(underlyingToken1)   // expected by collateral
            )
        );
        vaultHelper.stakeAssetInWrappedVault(staker, address(maliciousWrapper), 1000 ether);
        vm.stopPrank();
    }

    /// @notice Test that withdrawFromWrappedVault also validates the vault
    function test_WithdrawFromWrappedVault_InvalidVault_Reverts() public {
        address fakeVault = makeAddr("fakeVault");
        
        MaliciousLSTWrapper maliciousWrapper = new MaliciousLSTWrapper(
            address(vaultHelper),
            fakeVault,
            defaultCollateral1,
            address(underlyingToken1)
        );

        vm.startPrank(staker);
        // Should revert because vault is not in factory
        vm.expectRevert(abi.encodeWithSelector(VaultHelper.VaultHelper__InvalidVault.selector, fakeVault));
        vaultHelper.withdrawFromWrappedVault(address(maliciousWrapper), 1000 ether);
        vm.stopPrank();
    }
}

contract MockLSTWrapper {
    function nativeToken() external pure returns (address) {
        return address(0);
    }
    
    function collateral() external pure returns (address) {
        return address(0);
    }
    
    function vault() external pure returns (address) {
        return address(0);
    }
}

/// @notice Malicious wrapper that can return arbitrary addresses for vault, collateral, and nativeToken
contract MaliciousLSTWrapper {
    address public vaultHelper;
    address public vault;
    address public collateral;
    address public nativeToken;

    constructor(
        address _vaultHelper,
        address _vault,
        address _collateral,
        address _nativeToken
    ) {
        vaultHelper = _vaultHelper;
        vault = _vault;
        collateral = _collateral;
        nativeToken = _nativeToken;
    }

    // Minimal ILSTWrapper interface to pass the checks
    function deposit(uint256, address) external pure returns (uint256) {
        return 0;
    }

    function redeem(uint256, address, address) external pure returns (uint256) {
        return 0;
    }
}
