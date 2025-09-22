// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {LSTHelper, ClaimAmountsPerToken, PendingWithdraw} from "../src/contracts/LSTHelper.sol";
import {MockRewards} from "./mocks/MockRewards.sol";
import {Token} from "./mocks/MockToken.sol";
import {console} from "forge-std/console.sol";
import {IVaultTokenized} from "../src/interfaces/vault/IVaultTokenized.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LSTHelperTest is Test {
    LSTHelper public lstHelper;
    MockRewards public rewards;
    Token public rewardsToken;
    Token public rewardsToken2;
    Token public rewardsToken3;

    address constant UNDERLYING_ADDRESS = 0x36E3645354f4B19B5f2052f056E2cAC39f6C1172;
    address constant COLLATERAL_ADDRESS = 0x08d32A3e1B4B0a7ff6bAC233f40C9963AD45E58C;
    address constant VAULT_ADDRESS = 0xc2BC5788A769F3BF4C37255eF301c08D641416D4;
    address constant USER_ADDRESS = 0xf2afA31E62ce3809919DD92681fa9fB2E45B2657;
    address constant MIDDLEWARE_ADDRESS = 0xBE843C7d31e773acFf38575d7eC7A23358726d4e;
    address immutable ADMIN = makeAddr("Admin");
    // Fork Fuji testnet
    uint256 fuji;

    function setUp() public {
        fuji = vm.createFork("https://api.avax-test.network/ext/bc/C/rpc");
        vm.selectFork(fuji);
        vm.startPrank(ADMIN);
        lstHelper = new LSTHelper();
        rewards = new MockRewards(address(MIDDLEWARE_ADDRESS), address(VAULT_ADDRESS));
        rewardsToken = new Token("Rewards");
        rewardsToken2 = new Token("Rewards2");
        rewardsToken3 = new Token("Rewards3");
        vm.stopPrank();
    }

    function test_GetUserPendingWithdraws() public view {
        PendingWithdraw[] memory pendingWithdraws = lstHelper.getUserPendingWithdraws(VAULT_ADDRESS, USER_ADDRESS);
        assertEq(pendingWithdraws.length, 1);
    }

    function test_GetUserFuturePendingWithdraws() public view {
        PendingWithdraw[] memory pendingWithdraws = lstHelper.getUserFuturePendingWithdraws(VAULT_ADDRESS, USER_ADDRESS);
        assertEq(pendingWithdraws.length, 0);
    }

    function test_GetStakerClaimableRewards() public {
        // set rewards amount
        address[] memory tokens = new address[](3);
        tokens[0] = address(rewardsToken);
        tokens[1] = address(rewardsToken2);
        tokens[2] = address(rewardsToken3);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1_000_000_000_000_000;
        amounts[1] = 2_000_000_000_000_000;
        amounts[2] = 3_000_000_000_000_000;

        vm.startPrank(ADMIN);
        rewardsToken.approve(address(rewards), 100_000_000_000_000_000_000);
        rewardsToken2.approve(address(rewards), 100_000_000_000_000_000_000);
        rewardsToken3.approve(address(rewards), 100_000_000_000_000_000_000);
        rewards.setGlobalRewards(tokens, amounts);
        // set vault shares
        rewards.setVaultShares(VAULT_ADDRESS, 1000);
        // set last claimed epoch
        rewards.setLastEpochClaimed(USER_ADDRESS, 1050);
        vm.stopPrank();

        ClaimAmountsPerToken[] memory rewardsAmountsPerToken =
            lstHelper.getStakerClaimableRewards(USER_ADDRESS, address(rewards), VAULT_ADDRESS, tokens);

        assertEq(rewardsAmountsPerToken.length, 3);
        assertEq(rewardsAmountsPerToken[0].token, address(rewardsToken));
        assertEq(rewardsAmountsPerToken[1].token, address(rewardsToken2));
        assertEq(rewardsAmountsPerToken[2].token, address(rewardsToken3));
    }

    function test_StakeAssetInVault() public {
        uint256 assetBalanceBefore = IERC20(UNDERLYING_ADDRESS).balanceOf(USER_ADDRESS);
        uint256 vaultBalanceBefore = IVaultTokenized(VAULT_ADDRESS).activeSharesOf(USER_ADDRESS);
        vm.startPrank(USER_ADDRESS);
        IERC20(UNDERLYING_ADDRESS).approve(address(lstHelper), 10_000 ether);
        lstHelper.stakeAssetInVault(VAULT_ADDRESS, USER_ADDRESS, COLLATERAL_ADDRESS, UNDERLYING_ADDRESS, 10_000 ether);
        vm.stopPrank();

        uint256 assetBalanceAfter = IERC20(UNDERLYING_ADDRESS).balanceOf(USER_ADDRESS);
        uint256 vaultBalanceAfter = IVaultTokenized(VAULT_ADDRESS).activeSharesOf(USER_ADDRESS);
        assertEq(assetBalanceBefore - assetBalanceAfter, 10_000 ether);
        assertEq(vaultBalanceAfter - vaultBalanceBefore, 10_000 ether);
    }
}
