// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {RewardsNativeTokenIntegrationTestBase} from "../rewards/RewardsNativeTokenIntegrationTestBase.t.sol";
import {LSTWrapper} from "../../src/contracts/vault/LSTWrapper.sol";
import {LSTWrapperMerkl} from "../../src/contracts/vault/LSTWrapperMerkl.sol";
import {ILSTWrapper} from "../../src/interfaces/vault/ILSTWrapper.sol";
import {IVaultTokenized} from "../../src/interfaces/vault/IVaultTokenized.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {VaultHelper} from "../../src/contracts/VaultHelper.sol";
import {Token} from "../mocks/MockToken.sol";
import {MockCollateral} from "../mocks/MockCollateral.sol";
import {MockMerkleDistributor} from "../mocks/MockMerkleDistributor.sol";
import {VaultTokenized} from "../../src/contracts/vault/VaultTokenized.sol";
import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Upgrades} from "@openzeppelin/foundry-upgrades/Upgrades.sol";
import {DeployLSTWrapper} from "../../script/vault/LSTWrapperDeploy.s.sol";
import {LSTWrapperConfig} from "../../script/vault/LSTWrapperTypes.s.sol";

/**
 * @title LSTWrapperMerklTest
 * @notice Tests for LSTWrapperMerkl including upgrade from LSTWrapper
 * @dev Extends RewardsNativeTokenIntegrationTestBase to test Merkl integration
 */
contract LSTWrapperMerklTest is RewardsNativeTokenIntegrationTestBase {

    LSTWrapper public lstWrapper;
    LSTWrapper public lstWrapperImplementation;
    LSTWrapperMerkl public lstWrapperMerkl;
    LSTWrapperMerkl public lstWrapperMerklImplementation;
    MockMerkleDistributor public merkleDistributor;
    VaultHelper public vaultHelper;
    ProxyAdmin public proxyAdmin; // For managing upgrades
    
    address public lstAdmin;
    address public lstUser1;
    address public lstUser2;
    
    uint256 constant INITIAL_DEPOSIT = 100 ether;
    uint256 constant HARVEST_AMOUNT = 10 ether;
    
    function setUp() public override {
        super.setUp();
        
        // Setup test accounts
        lstAdmin = makeAddr("lstAdmin");
        lstUser1 = makeAddr("lstUser1");
        lstUser2 = makeAddr("lstUser2");
        
        // Deploy VaultHelper
        vaultHelper = new VaultHelper(address(vaultFactory));
        
        // Deploy Mock Merkl Distributor
        merkleDistributor = new MockMerkleDistributor();
        
        // Deploy LSTWrapper using the deployment script
        DeployLSTWrapper deployer = new DeployLSTWrapper();
        LSTWrapperConfig memory config = LSTWrapperConfig({
            implementation: "LSTWrapper",
            admin: lstAdmin,
            vault: address(vault),
            rewards: address(rewards), // Use original rewards for initial setup
            helper: address(vaultHelper),
            name: "LST Wrapped VaultTokenized",
            symbol: "lstVT"
        });
        
        // Don't use prank since deployment script handles broadcast
        (address proxyAddr, address implAddr, address proxyAdminAddr) = deployer.executeLSTWrapperDeployment(config);
        
        lstWrapper = LSTWrapper(proxyAddr);
        lstWrapperImplementation = LSTWrapper(implAddr);
        proxyAdmin = ProxyAdmin(proxyAdminAddr);
        
        // Setup initial deposits to vault for testing
        _setupInitialVaultDeposits();
        
        // Give users some vault shares for testing
        _distributeVaultShares();
        
        // Initialize wrapper for testing (handles first mint protection)
        _initializeWrapperForTesting(lstWrapper, vault, lstAdmin);
        
        // NOW UPGRADE TO LSTWrapperMerkl
        _upgradeToMerkl();
        
        // Setup Merkl rewards for testing
        _setupMerklRewards();
    }
    
    /**
     * @notice Upgrade LSTWrapper proxy to LSTWrapperMerkl implementation
     * @dev Uses ProxyAdmin to upgrade the TransparentUpgradeableProxy and calls setRewards
     */
    function _upgradeToMerkl() internal {
        // Deploy new LSTWrapperMerkl implementation
        lstWrapperMerklImplementation = new LSTWrapperMerkl();
        
        // Upgrade and set distributor via setRewards
        bytes memory callData =
            abi.encodeWithSelector(ILSTWrapper.setRewards.selector, address(merkleDistributor));
        vm.prank(lstAdmin);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(payable(address(lstWrapper))),
            address(lstWrapperMerklImplementation),
            callData
        );
        lstWrapperMerkl = LSTWrapperMerkl(address(lstWrapper));
        
        // Note: In production, use the UpgradeLSTWrapper script instead of direct upgrade
    }
    
    /**
     * @notice Setup Merkl rewards for testing
     */
    function _setupMerklRewards() internal {
        // Fund Merkl Distributor with native tokens
        address nativeToken = address(MockCollateral(vault.collateral()).asset());
        uint256 fundAmount = 1000 ether;
        
        // Mint tokens to this contract
        Token(nativeToken).mint(address(this), fundAmount);
        IERC20(nativeToken).approve(address(merkleDistributor), fundAmount);
        merkleDistributor.fund(nativeToken, fundAmount);
        
        // Set claimable amounts for the wrapper
        merkleDistributor.setClaimableAmount(address(lstWrapperMerkl), nativeToken, HARVEST_AMOUNT);
    }
    
    function _setupInitialVaultDeposits() internal {
        // Add more liquidity to vault
        uint256 additionalDeposit = 1000 ether;
        collateral.transfer(staker, additionalDeposit);
        vm.startPrank(staker);
        collateral.approve(address(vault), additionalDeposit);
        vault.deposit(staker, additionalDeposit);
        vm.stopPrank();
    }
    
    function _distributeVaultShares() internal {
        // Transfer some vault shares to test users
        uint256 shares = vault.balanceOf(staker) / 4;
        vm.startPrank(staker);
        vault.transfer(lstUser1, shares);
        vault.transfer(lstUser2, shares);
        vm.stopPrank();
    }
    
    /// @dev Helper to initialize wrapper for testing by doing owner first mint and unpause
    function _initializeWrapperForTesting(LSTWrapper wrapper, IERC20 vaultToken, address owner) internal {
        // Owner performs seed deposit (required for first mint protection)
        uint256 initialSeed = 1000; // Reasonable seed to unlock first mint
        
        // For real vault, transfer from staker
        vm.startPrank(staker);
        vaultToken.transfer(owner, initialSeed);
        vm.stopPrank();
        
        vm.startPrank(owner);
        vaultToken.approve(address(wrapper), initialSeed);
        wrapper.deposit(initialSeed, owner); // Owner can deposit even while paused
        // Now unpause for regular testing
        wrapper.setDepositsPaused(false);
        vm.stopPrank();
    }
    
    // ========== Upgrade Tests ==========
    
    function test_UpgradeToMerkl() public view {
        // Verify upgrade succeeded
        assertEq(address(lstWrapperMerkl), address(lstWrapper), "Should be same proxy address");
        assertEq(lstWrapperMerkl.vault(), address(vault), "Vault should be preserved");
        assertEq(lstWrapperMerkl.collateral(), vault.collateral(), "Collateral should be preserved");
        assertEq(lstWrapperMerkl.nativeToken(), MockCollateral(vault.collateral()).asset(), "Native token should be preserved");
        assertEq(lstWrapperMerkl.vaultHelper(), address(vaultHelper), "Vault helper should be preserved");
        assertEq(lstWrapperMerkl.owner(), lstAdmin, "Owner should be preserved");
    }
    
    function test_UpgradePreservesStorage() public view {
        // Verify all storage is preserved after upgrade
        assertEq(lstWrapperMerkl.totalSupply(), lstWrapper.totalSupply(), "Total supply should be preserved");
        assertEq(lstWrapperMerkl.totalAssets(), lstWrapper.totalAssets(), "Total assets should be preserved");
    }
    
    function test_HarvestRequiresParams() public {
        // Unified harvest requires amount and proof parameters (function signature enforces this)
        // This test verifies the function signature accepts the required params
        bytes32[] memory proof = new bytes32[](0);
        (uint256 claimedNative, uint256 mintedVaultShares) = lstWrapperMerkl.harvest(0, proof);
        // Should succeed with zero amount (no revert expected)
        assertEq(claimedNative, 0);
        assertEq(mintedVaultShares, 0);
    }
    
    // ========== Merkl Harvest Tests ==========
    
    function test_HarvestWithMerklProof() public {
        address nativeToken = address(MockCollateral(vault.collateral()).asset());
        uint256 harvestAmount = HARVEST_AMOUNT;
        
        // Get balance before harvest
        uint256 balanceBefore = IERC20(nativeToken).balanceOf(address(lstWrapperMerkl));
        uint256 vaultSharesBefore = lstWrapperMerkl.totalAssets();
        
        // Create a simple proof (mock doesn't strictly validate, but we need the format)
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = keccak256(abi.encodePacked(address(lstWrapperMerkl), nativeToken, harvestAmount));
        
        // Harvest with Merkle proof
        (uint256 claimedNative, uint256 mintedVaultShares) = lstWrapperMerkl.harvest(
            harvestAmount,
            proof
        );
        
        // Verify harvest succeeded
        assertGt(claimedNative, 0, "Should have claimed native tokens");
        assertGt(mintedVaultShares, 0, "Should have minted vault shares");
        
        // Verify balances updated
        uint256 balanceAfter = IERC20(nativeToken).balanceOf(address(lstWrapperMerkl));
        assertEq(balanceAfter, balanceBefore, "Native tokens should be reinvested (balance should be same)");
        
        uint256 vaultSharesAfter = lstWrapperMerkl.totalAssets();
        assertGt(vaultSharesAfter, vaultSharesBefore, "Vault shares should increase");
    }
    
    function test_HarvestWithZeroAmount() public {
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = bytes32(0);
        
        // Should succeed but claim 0
        (uint256 claimedNative, uint256 mintedVaultShares) = lstWrapperMerkl.harvest(
            0,
            proof
        );
        
        assertEq(claimedNative, 0, "Should claim 0");
        assertEq(mintedVaultShares, 0, "Should mint 0 shares");
    }
    
    // ========== Reuse Tests from LSTWrapperTest ==========
    
    function test_Deposit() public {
        uint256 depositAmount = 100 ether;
        
        vm.startPrank(lstUser1);
        vault.approve(address(lstWrapperMerkl), depositAmount);
        uint256 shares = lstWrapperMerkl.deposit(depositAmount, lstUser1);
        vm.stopPrank();
        
        assertGt(shares, 0, "Should receive shares");
        assertEq(lstWrapperMerkl.balanceOf(lstUser1), shares, "Balance should match");
    }
    
    function test_Withdraw() public {
        // First deposit
        uint256 depositAmount = 100 ether;
        vm.startPrank(lstUser1);
        vault.approve(address(lstWrapperMerkl), depositAmount);
        uint256 shares = lstWrapperMerkl.deposit(depositAmount, lstUser1);
        
        // Then withdraw
        uint256 assets = lstWrapperMerkl.withdraw(depositAmount, lstUser1, lstUser1);
        vm.stopPrank();
        
        assertEq(assets, shares, "Should burn correct shares");
        assertEq(lstWrapperMerkl.balanceOf(lstUser1), 0, "Balance should be zero");
    }
    
    function test_Redeem() public {
        // Deposit first
        uint256 depositAmount = 100 ether;
        vm.startPrank(lstUser1);
        vault.approve(address(lstWrapperMerkl), depositAmount);
        uint256 shares = lstWrapperMerkl.deposit(depositAmount, lstUser1);
        
        // Then redeem
        uint256 assets = lstWrapperMerkl.redeem(shares, lstUser1, lstUser1);
        vm.stopPrank();
        
        assertEq(assets, depositAmount, "Should receive correct assets");
        assertEq(lstWrapperMerkl.balanceOf(lstUser1), 0, "Balance should be zero");
    }
    
    function test_DepositWithMinShares() public {
        uint256 depositAmount = 100 ether;
        uint256 minShares = 90 ether; // Reasonable minimum
        
        vm.startPrank(lstUser1);
        vault.approve(address(lstWrapperMerkl), depositAmount);
        uint256 shares = lstWrapperMerkl.depositWithMinShares(depositAmount, minShares, lstUser1);
        vm.stopPrank();
        
        assertGe(shares, minShares, "Should receive at least min shares");
    }
    
    function test_DepositWithMinShares_Revert() public {
        uint256 depositAmount = 100 ether;
        uint256 minShares = 200 ether; // Unreasonable minimum
        
        vm.startPrank(lstUser1);
        vault.approve(address(lstWrapperMerkl), depositAmount);
        vm.expectRevert(ILSTWrapper.LSTWrapper__SlippageProtection.selector);
        lstWrapperMerkl.depositWithMinShares(depositAmount, minShares, lstUser1);
        vm.stopPrank();
    }
    
    function test_TotalAssets() public view {
        uint256 totalAssets = lstWrapperMerkl.totalAssets();
        assertEq(totalAssets, IERC20(lstWrapperMerkl.asset()).balanceOf(address(lstWrapperMerkl)), "Total assets should match balance");
    }
    
    function test_ConvertToShares() public view {
        uint256 assets = 100 ether;
        uint256 shares = lstWrapperMerkl.convertToShares(assets);
        assertGt(shares, 0, "Should convert to shares");
    }
    
    function test_ConvertToAssets() public view {
        uint256 shares = 100 ether;
        uint256 assets = lstWrapperMerkl.convertToAssets(shares);
        assertGt(assets, 0, "Should convert to assets");
    }
    
    function test_Sweep() public {
        // Deploy a random token and send it to wrapper
        Token randomToken = new Token("Random");
        randomToken.mint(address(lstWrapperMerkl), 100 ether);
        
        uint256 balanceBefore = randomToken.balanceOf(lstAdmin);
        
        vm.prank(lstAdmin);
        lstWrapperMerkl.sweep(address(randomToken), lstAdmin, 100 ether);
        
        assertEq(randomToken.balanceOf(lstAdmin), balanceBefore + 100 ether, "Admin should receive tokens");
    }
    
    function test_Sweep_RevertAsset() public {
        vm.prank(lstAdmin);
        vm.expectRevert(ILSTWrapper.LSTWrapper__CannotSweepAsset.selector);
        lstWrapperMerkl.sweep(address(vault), lstAdmin, 100 ether);
    }
    
    function test_Sweep_RevertCollateral() public {
        vm.prank(lstAdmin);
        vm.expectRevert(ILSTWrapper.LSTWrapper__CannotSweepCollateral.selector);
        lstWrapperMerkl.sweep(address(collateral), lstAdmin, 100 ether);
    }
    
    function test_SetVaultHelper() public {
        VaultHelper newHelper = new VaultHelper(address(vaultFactory));
        
        // Call setVaultHelper via ProxyAdmin's upgradeAndCall
        vm.prank(lstAdmin);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(payable(address(lstWrapperMerkl))),
            address(lstWrapperMerklImplementation), // same implementation
            abi.encodeWithSelector(ILSTWrapper.setVaultHelper.selector, address(newHelper))
        );
        
        assertEq(lstWrapperMerkl.vaultHelper(), address(newHelper), "Vault helper should be updated");
    }
    
    function test_SetDepositsPaused() public {
        vm.prank(lstAdmin);
        lstWrapperMerkl.setDepositsPaused(true);
        assertEq(lstWrapperMerkl.maxDeposit(lstUser1), 0);
        assertEq(lstWrapperMerkl.maxMint(lstUser1), 0);
        
        // Try to deposit - should revert
        vm.startPrank(lstUser1);
        vault.approve(address(lstWrapperMerkl), 100 ether);
        vm.expectRevert(ILSTWrapper.LSTWrapper__DepositsPaused.selector);
        lstWrapperMerkl.deposit(100 ether, lstUser1);
        vm.stopPrank();
        
        // Unpause
        vm.prank(lstAdmin);
        lstWrapperMerkl.setDepositsPaused(false);
        assertEq(lstWrapperMerkl.maxDeposit(lstUser1), type(uint256).max);
        assertEq(lstWrapperMerkl.maxMint(lstUser1), type(uint256).max);
    }
    
    function test_MaxDeposit_SeedPhaseIsZero() public {
        // Deploy a fresh wrapper to test seed phase
        LSTWrapper freshImpl = new LSTWrapper();
        bytes memory initData = abi.encodeWithSelector(
            LSTWrapper.initialize.selector,
            lstAdmin,
            address(vault),
            address(rewards),
            address(vaultHelper),
            "Test Wrapper",
            "TEST"
        );
        TransparentUpgradeableProxy freshProxy = new TransparentUpgradeableProxy(
            address(freshImpl),
            lstAdmin,
            initData
        );
        LSTWrapper freshWrapper = LSTWrapper(address(freshProxy));
        
        // Verify seed phase introspection
        assertEq(freshWrapper.totalSupply(), 0, "Should be in seed phase");
        assertEq(freshWrapper.maxDeposit(address(this)), 0, "maxDeposit should return 0 in seed phase");
        assertEq(freshWrapper.maxMint(address(this)), 0, "maxMint should return 0 in seed phase");
    }
    
    // ========== Merkl-Specific Tests ==========
    
    function test_MerkleDistributorAddress() public view {
        // After upgrade and storage update, merkleDistributor() should return MockMerkleDistributor
        address distributor = lstWrapperMerkl.merkleDistributor();
        assertEq(distributor, address(merkleDistributor), "Should return Merkl Distributor address");
    }
    
    function test_RewardsAddressAfterUpgrade() public view {
        // After upgrade, rewards() should return the updated address (MockMerkleDistributor)
        address rewardsAddr = lstWrapperMerkl.rewards();
        assertEq(rewardsAddr, address(merkleDistributor), "Rewards address should be updated");
    }
    
    function test_MultipleHarvests() public {
        address nativeToken = address(MockCollateral(vault.collateral()).asset());
        
        // Set up total claimable amount
        uint256 totalClaimable = HARVEST_AMOUNT * 2;
        merkleDistributor.setClaimableAmount(address(lstWrapperMerkl), nativeToken, totalClaimable);
        
        // Fund distributor
        Token(nativeToken).mint(address(this), totalClaimable);
        IERC20(nativeToken).approve(address(merkleDistributor), totalClaimable);
        merkleDistributor.fund(nativeToken, totalClaimable);
        
        // First harvest - claim first portion (amount parameter is total claimable)
        bytes32[] memory proof1 = new bytes32[](1);
        proof1[0] = keccak256(abi.encodePacked(address(lstWrapperMerkl), nativeToken, totalClaimable));
        (uint256 claimed1,) = lstWrapperMerkl.harvest(HARVEST_AMOUNT, proof1);
        assertGt(claimed1, 0, "First harvest should succeed");
        assertEq(claimed1, HARVEST_AMOUNT, "First harvest should claim exactly HARVEST_AMOUNT");
        
        // Second harvest - claim remaining (amount parameter is still total claimable, mock calculates incremental)
        bytes32[] memory proof2 = new bytes32[](1);
        proof2[0] = keccak256(abi.encodePacked(address(lstWrapperMerkl), nativeToken, totalClaimable));
        (uint256 claimed2,) = lstWrapperMerkl.harvest(totalClaimable, proof2);
        assertGt(claimed2, 0, "Second harvest should succeed");
        assertEq(claimed2, HARVEST_AMOUNT, "Second harvest should claim remaining HARVEST_AMOUNT");
    }
    
    // ========================== ERC20Votes TESTS ==========================
    
    function test_VotesAfterUpgrade_InitializeVotes() public {
        // After upgrade, voting functionality needs to be initialized
        vm.prank(lstAdmin);
        lstWrapperMerkl.initializeVotes();
        
        // Now voting should work
        uint256 shares = _depositToWrapper(lstUser1, 50 ether);
        
        // Without delegation, no votes
        assertEq(lstWrapperMerkl.getVotes(lstUser1), 0);
        
        // Self-delegate
        vm.prank(lstUser1);
        lstWrapperMerkl.delegate(lstUser1);
        
        assertEq(lstWrapperMerkl.getVotes(lstUser1), shares);
    }
    
    function test_VotesAfterUpgrade_DoubleInitializeFails() public {
        vm.prank(lstAdmin);
        lstWrapperMerkl.initializeVotes();
        
        // Try to initialize again - should fail
        vm.expectRevert();
        vm.prank(lstAdmin);
        lstWrapperMerkl.initializeVotes();
    }
    
    function test_Permit_WorksWithMerkl() public {
        uint256 ownerPk = 0xBEEF;
        address owner = vm.addr(ownerPk);
        address spender = lstUser2;
        
        uint256 shares = _depositToWrapper(owner, 25 ether);
        uint256 permitAmount = shares / 2;
        uint256 deadline = block.timestamp + 1 days;
        uint256 nonce = lstWrapperMerkl.nonces(owner);
        
        bytes32 domainSeparator = lstWrapperMerkl.DOMAIN_SEPARATOR();
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                permitAmount,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);
        
        lstWrapperMerkl.permit(owner, spender, permitAmount, deadline, v, r, s);
        
        // Verify permit worked
        assertEq(lstWrapperMerkl.allowance(owner, spender), permitAmount);
        assertEq(lstWrapperMerkl.nonces(owner), nonce + 1);
    }
    
    function test_Votes_DelegationWithMerkl() public {
        // Initialize voting
        vm.prank(lstAdmin);
        lstWrapperMerkl.initializeVotes();
        
        uint256 user1Shares = _depositToWrapper(lstUser1, 100 ether);
        uint256 user2Shares = _depositToWrapper(lstUser2, 50 ether);
        
        // User1 delegates to User2
        vm.prank(lstUser1);
        lstWrapperMerkl.delegate(lstUser2);
        
        // User2 self-delegates
        vm.prank(lstUser2);
        lstWrapperMerkl.delegate(lstUser2);
        
        // Check voting power
        assertEq(lstWrapperMerkl.getVotes(lstUser1), 0);
        assertEq(lstWrapperMerkl.getVotes(lstUser2), user1Shares + user2Shares);
    }
    
    function test_Votes_HistoricalTracking() public {
        // Initialize voting
        vm.prank(lstAdmin);
        lstWrapperMerkl.initializeVotes();
        
        uint256 shares = _depositToWrapper(lstUser1, 100 ether);
        
        // Block 100: Self-delegate
        vm.roll(100);
        vm.prank(lstUser1);
        lstWrapperMerkl.delegate(lstUser1);
        uint256 block100 = vm.getBlockNumber();
        
        // Block 110: Transfer half
        vm.roll(110);
        vm.prank(lstUser1);
        lstWrapperMerkl.transfer(lstUser2, shares / 2);
        
        // Block 120: Check historical
        vm.roll(120);
        
        assertEq(lstWrapperMerkl.getPastVotes(lstUser1, block100), shares);
        assertEq(lstWrapperMerkl.getPastTotalSupply(block100), 1000 + shares); // Include seed
    }
    
    // ---- Helper functions ----
    
    function _depositToWrapper(address user, uint256 amount) internal returns (uint256) {
        vm.prank(staker);
        vault.transfer(user, amount);
        
        vm.startPrank(user);
        vault.approve(address(lstWrapperMerkl), amount);
        uint256 shares = lstWrapperMerkl.deposit(amount, user);
        vm.stopPrank();
        
        return shares;
    }
}

