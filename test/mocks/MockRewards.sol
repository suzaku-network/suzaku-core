// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAvalancheL1Middleware} from "../../src/interfaces/middleware/IAvalancheL1Middleware.sol";
import {IVaultTokenized} from "../../src/interfaces/vault/IVaultTokenized.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title MockRewards
 * @dev Mock Rewards contract for integration testing with real Vault + Middleware.
 * - Global rewards distribution is the same across all epochs.
 * - Contract must be funded upfront for 100 epochs worth of rewards.
 * - Stakers can claim proportional shares based on vault shares and their active shares.
 */
contract MockRewards {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 constant BASIS_POINTS_DENOMINATOR = 10_000;

    /// @notice Struct to represent rewards per token
    struct RewardsConfig {
        address[] tokens;
        uint256[] amounts; // per-epoch reward amount
    }

    /// @notice Middleware contract (real one in tests)
    address public immutable middleware;

    /// @notice Vault contract (real one in tests)
    address public immutable vault;

    /// @notice Global rewards config applied to all epochs
    RewardsConfig private globalRewards;

    /// @notice Mapping: vault -> shares (same for all epochs)
    mapping(uint48 => mapping(address => uint256)) public vaultShares;

    /// @notice Mapping: staker -> rewards token -> last claimed epoch
    mapping(address => mapping(address => uint48)) public lastEpochClaimedStaker;

    constructor(address _l1Middleware, address _vault) {
        require(_l1Middleware != address(0), "Invalid middleware");
        middleware = _l1Middleware;
        vault = _vault;
    }

    // -------------------------------
    // Config methods for testing
    // -------------------------------

    /**
     * @notice Sets the global rewards distribution and funds the contract for 100 epochs.
     * @dev Caller must have approved this contract to pull `amounts[i] * 100` for each token.
     * @param tokens List of ERC20 tokens to distribute.
     * @param amounts Per-epoch reward amounts corresponding to each token.
     */
    function setGlobalRewards(address[] calldata tokens, uint256[] calldata amounts) external {
        require(tokens.length == amounts.length, "Length mismatch");

        // Store config
        globalRewards = RewardsConfig(tokens, amounts);

        // Pull in 100 epochs worth of rewards for each token
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 totalFund = amounts[i] * 10_000;
            IERC20(tokens[i]).safeTransferFrom(msg.sender, address(this), totalFund);
        }
    }

    /// @notice Sets vault shares (same for all epochs).
    function setVaultShares(address, uint256 shares) external {
        uint48 currentEpoch = IAvalancheL1Middleware(middleware).getCurrentEpoch();
        for (uint48 epoch = currentEpoch - 100; epoch < currentEpoch + 500; epoch++) {
            vaultShares[epoch][vault] = shares;
        }
    }

    /// @notice Sets the last claimed epoch for a staker.
    function setLastEpochClaimed(address staker, uint48 epoch) external {
        address[] memory rewardsTokens = globalRewards.tokens;
        for (uint256 i = 0; i < rewardsTokens.length; i++) {
            lastEpochClaimedStaker[staker][rewardsTokens[i]] = epoch;
        }
    }

    // -------------------------------
    // Functions called by lens
    // -------------------------------

    function getRewardsAmountPerTokenFromEpoch(
        uint48
    ) external view returns (address[] memory tokens, uint256[] memory amounts) {
        return (globalRewards.tokens, globalRewards.amounts);
    }

    function getRewardsAmountPerTokenFromEpoch(uint48, address token) external view returns (uint256 amount) {
        for (uint256 i = 0; i < globalRewards.tokens.length; i++) {
            if (globalRewards.tokens[i] == token) {
                return globalRewards.amounts[i];
            }
        }
    }

    // -------------------------------
    // Claim logic
    // -------------------------------

    /**
     * @notice Claims all unclaimed rewards for the caller across all past epochs.
     * @dev Uses global rewards config + vault shares + vault.activeSharesOfAt.
     * @param rewardsToken The rewards token address.
     * @param recipient The recipient address.
     */
    function claimRewards(address rewardsToken, address recipient) external {
        uint48 currentEpoch = IAvalancheL1Middleware(middleware).getCurrentEpoch();
        uint48 lastClaimed = lastEpochClaimedStaker[msg.sender][rewardsToken];

        require(currentEpoch > lastClaimed + 1, "Nothing to claim");

        uint256 totalRewards = 0;

        uint256 rewardsAmount = 0;
        for (uint256 i = 0; i < globalRewards.tokens.length; i++) {
            if (globalRewards.tokens[i] == rewardsToken) {
                rewardsAmount = globalRewards.amounts[i];
                break;
            }
        }

        for (uint48 epoch = lastClaimed + 1; epoch < currentEpoch; epoch++) {
            uint48 epochTs = IAvalancheL1Middleware(middleware).getEpochStartTs(epoch);

            uint256 vaultRewardsShares = vaultShares[epoch][vault];
            if (vaultRewardsShares == 0) continue;

            uint256 stakerVaultShare = IVaultTokenized(vault).activeSharesOfAt(msg.sender, epochTs, "");
            if (stakerVaultShare == 0) continue;

            uint256 vaultTotalShares = IVaultTokenized(vault).activeSharesAt(epochTs, "");

            uint256 vaultRewardsAmount = Math.mulDiv(rewardsAmount, vaultRewardsShares, BASIS_POINTS_DENOMINATOR);

            uint256 stakerRewardsAmount = Math.mulDiv(vaultRewardsAmount, stakerVaultShare, vaultTotalShares);

            if (stakerRewardsAmount > 0) {
                totalRewards += stakerRewardsAmount;
            }
        }

        IERC20(rewardsToken).safeTransfer(recipient, totalRewards);
        lastEpochClaimedStaker[msg.sender][rewardsToken] = currentEpoch - 1;
    }
}
