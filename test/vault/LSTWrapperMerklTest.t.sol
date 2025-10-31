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
        
        // Deploy LSTWrapper implementation (original)
        lstWrapperImplementation = new LSTWrapper();
        
        // Deploy proxy with LSTWrapper initialization
        bytes memory initData = abi.encodeWithSelector(
            LSTWrapper.initialize.selector,
            lstAdmin,
            address(vault),
            address(rewards), // Use original rewards for initial setup
            address(vaultHelper),
            "LST Wrapped VaultTokenized",
            "lstVT"
        );
        
        // Use TransparentUpgradeableProxy - it creates its own ProxyAdmin internally
        // Pass lstAdmin as initialOwner so the internal ProxyAdmin is owned by lstAdmin
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(lstWrapperImplementation),
            lstAdmin, // initialOwner - ProxyAdmin will be created internally and owned by lstAdmin
            initData
        );
        
        lstWrapper = LSTWrapper(address(proxy));
        
        // Get the internal ProxyAdmin that was created by the proxy
        // The admin slot is at keccak256("eip1967.proxy.admin") - 1 = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103
        bytes32 adminSlot = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        address internalProxyAdminAddr = address(uint160(uint256(vm.load(address(proxy), adminSlot))));
        proxyAdmin = ProxyAdmin(internalProxyAdminAddr);
        
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
     * @dev Uses ProxyAdmin to upgrade the TransparentUpgradeableProxy
     */
    function _upgradeToMerkl() internal {
        // Deploy new LSTWrapperMerkl implementation
        lstWrapperMerklImplementation = new LSTWrapperMerkl();
        
        // Upgrade the proxy using ProxyAdmin
        // In production, ProxyAdmin would be owned by a multisig/governance
        vm.prank(lstAdmin); // ProxyAdmin owner calls upgrade
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(payable(address(lstWrapper))),
            address(lstWrapperMerklImplementation),
            "" // Empty bytes - no function call during upgrade
        );
        
        // Cast to LSTWrapperMerkl (storage is compatible)
        lstWrapperMerkl = LSTWrapperMerkl(address(lstWrapper));
        
        // After upgrade, rewards() still returns old address (storage preserved)
        // merkleDistributor() is an alias that calls rewards()
        // For testing, we'll update the storage slot directly to point to MockMerkleDistributor
        // In production, you'd need a migration function
        _updateRewardsAddressInStorage(address(merkleDistributor));
    }
    
    /**
     * @notice Update rewards address in storage (simulates migration)
     * @dev Directly updates storage slot - in production use a proper migration function
     */
    function _updateRewardsAddressInStorage(address newRewards) internal {
        // Storage slot for rewards is at offset 1 in LSTWrapperStorageStruct
        // bytes32 slot = _LSTWRAPPER_STORAGE_SLOT = 0x799f344bf9d1b9145d63579fefcda32172d8d3c9b295fe5dc25c088a9f94f700
        bytes32 storageSlot = 0x799f344bf9d1b9145d63579fefcda32172d8d3c9b295fe5dc25c088a9f94f700;
        bytes32 rewardsSlot = bytes32(uint256(storageSlot) + 1); // rewards is 2nd field (after vault)
        
        // Update storage directly
        vm.store(address(lstWrapperMerkl), rewardsSlot, bytes32(uint256(uint160(newRewards))));
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
    
    function test_OldHarvestReverts() public {
        // Old harvest() signature should revert with helpful message
        vm.expectRevert("Use harvest(address token, uint256 amount, bytes32[] calldata proof) - Merkl requires Merkle proofs");
        lstWrapperMerkl.harvest();
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
            nativeToken,
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
    
    function test_HarvestWithInvalidToken() public {
        address wrongToken = makeAddr("wrongToken");
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = bytes32(0);
        
        vm.expectRevert(ILSTWrapper.LSTWrapper__InvalidRewardsToken.selector);
        lstWrapperMerkl.harvest(wrongToken, HARVEST_AMOUNT, proof);
    }
    
    function test_HarvestWithZeroAmount() public {
        address nativeToken = address(MockCollateral(vault.collateral()).asset());
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = bytes32(0);
        
        // Should succeed but claim 0
        (uint256 claimedNative, uint256 mintedVaultShares) = lstWrapperMerkl.harvest(
            nativeToken,
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
        
        vm.prank(lstAdmin);
        lstWrapperMerkl.setVaultHelper(address(newHelper));
        
        assertEq(lstWrapperMerkl.vaultHelper(), address(newHelper), "Vault helper should be updated");
    }
    
    function test_SetDepositsPaused() public {
        vm.prank(lstAdmin);
        lstWrapperMerkl.setDepositsPaused(true);
        
        // Try to deposit - should revert
        vm.startPrank(lstUser1);
        vault.approve(address(lstWrapperMerkl), 100 ether);
        vm.expectRevert(ILSTWrapper.LSTWrapper__DepositsPaused.selector);
        lstWrapperMerkl.deposit(100 ether, lstUser1);
        vm.stopPrank();
        
        // Unpause
        vm.prank(lstAdmin);
        lstWrapperMerkl.setDepositsPaused(false);
        
        // Now deposit should work
        vm.startPrank(lstUser1);
        lstWrapperMerkl.deposit(100 ether, lstUser1);
        vm.stopPrank();
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
        (uint256 claimed1,) = lstWrapperMerkl.harvest(nativeToken, HARVEST_AMOUNT, proof1);
        assertGt(claimed1, 0, "First harvest should succeed");
        assertEq(claimed1, HARVEST_AMOUNT, "First harvest should claim exactly HARVEST_AMOUNT");
        
        // Second harvest - claim remaining (amount parameter is still total claimable, mock calculates incremental)
        bytes32[] memory proof2 = new bytes32[](1);
        proof2[0] = keccak256(abi.encodePacked(address(lstWrapperMerkl), nativeToken, totalClaimable));
        (uint256 claimed2,) = lstWrapperMerkl.harvest(nativeToken, totalClaimable, proof2);
        assertGt(claimed2, 0, "Second harvest should succeed");
        assertEq(claimed2, HARVEST_AMOUNT, "Second harvest should claim remaining HARVEST_AMOUNT");
    }
}

