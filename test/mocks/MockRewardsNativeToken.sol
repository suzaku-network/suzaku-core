// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {SafeERC20, IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAvalancheL1Middleware} from "../../src/interfaces/middleware/IAvalancheL1Middleware.sol";
import {IVaultTokenized} from "../../src/interfaces/vault/IVaultTokenized.sol";
import {Math} from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

/**
 * @title MockRewardsNativeToken
 * @dev Mock RewardsNativeToken contract for integration testing with real Vault + Middleware.
 * - Single native token rewards contract
 * - Global rewards distribution is the same across all epochs.
 * - Contract must be funded upfront for 100 epochs worth of rewards.
 * - Stakers can claim proportional shares based on vault shares and their active shares.
 */
contract MockRewardsNativeToken {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 constant BASIS_POINTS_DENOMINATOR = 10_000;

    /// @notice Middleware contract (real one in tests)
    address public immutable middleware;

    /// @notice Vault contract (real one in tests)
    address public immutable vault;

    /// @notice The single rewards token
    address public immutable rewardsToken;

    /// @notice Per-epoch reward amount
    uint256 public perEpochReward;

    /// @notice Mapping: vault -> shares (same for all epochs)
    mapping(uint48 => mapping(address => uint256)) public vaultShares;

    /// @notice Mapping: staker -> last claimed epoch
    mapping(address => uint48) public lastEpochClaimedStaker;

    /// @notice Mapping: epoch -> total rewards amount
    mapping(uint48 => uint256) public epochRewards;

    constructor(address _l1Middleware, address _vault, address _rewardsToken) {
        require(_l1Middleware != address(0), "Invalid middleware");
        require(_vault != address(0), "Invalid vault");
        require(_rewardsToken != address(0), "Invalid rewards token");
        middleware = _l1Middleware;
        vault = _vault;
        rewardsToken = _rewardsToken;
    }

    // -------------------------------
    // Config methods for testing
    // -------------------------------

    /**
     * @notice Sets the per-epoch rewards and funds the contract for 100 epochs.
     * @dev Caller must have approved this contract to pull `amount * 100`.
     * @param amount Per-epoch reward amount.
     */
    function setGlobalRewards(uint256 amount) external {
        perEpochReward = amount;

        // Pull in 100 epochs worth of rewards
        uint256 totalFund = amount * 10_000;
        IERC20(rewardsToken).safeTransferFrom(msg.sender, address(this), totalFund);
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
        lastEpochClaimedStaker[staker] = epoch;
    }

    /// @notice Sets epoch rewards (used by tests that expect specific epoch rewards)
    function setEpochRewards(uint48 epoch, uint256 amount) external {
        epochRewards[epoch] = amount;
    }

    // -------------------------------
    // Functions called by lens
    // -------------------------------

    function getEpochRewards(uint48 epoch) external view returns (uint256) {
        // If specific epoch rewards are set, use those; otherwise use perEpochReward
        uint256 specificReward = epochRewards[epoch];
        return specificReward > 0 ? specificReward : perEpochReward;
    }

    // -------------------------------
    // Claim logic
    // -------------------------------

    /**
     * @notice Claims all unclaimed rewards for the caller across all past epochs.
     * @dev Uses global rewards config + vault shares + vault.activeSharesOfAt.
     * @param recipient The recipient address.
     */
    function claimRewards(address recipient) external {
        uint48 currentEpoch = IAvalancheL1Middleware(middleware).getCurrentEpoch();
        uint48 lastClaimed = lastEpochClaimedStaker[msg.sender];

        require(currentEpoch > lastClaimed + 1, "Nothing to claim");

        uint256 totalRewards = 0;

        for (uint48 epoch = lastClaimed + 1; epoch < currentEpoch; epoch++) {
            uint48 epochTs = IAvalancheL1Middleware(middleware).getEpochStartTs(epoch);

            uint256 vaultRewardsShares = vaultShares[epoch][vault];
            if (vaultRewardsShares == 0) continue;

            uint256 stakerVaultShare = IVaultTokenized(vault).activeSharesOfAt(msg.sender, epochTs, "");
            if (stakerVaultShare == 0) continue;

            uint256 vaultTotalShares = IVaultTokenized(vault).activeSharesAt(epochTs, "");

            uint256 rewardsAmount = epochRewards[epoch] > 0 ? epochRewards[epoch] : perEpochReward;
            uint256 vaultRewardsAmount = Math.mulDiv(rewardsAmount, vaultRewardsShares, BASIS_POINTS_DENOMINATOR);

            uint256 stakerRewardsAmount = Math.mulDiv(vaultRewardsAmount, stakerVaultShare, vaultTotalShares);

            if (stakerRewardsAmount > 0) {
                totalRewards += stakerRewardsAmount;
            }
        }

        IERC20(rewardsToken).safeTransfer(recipient, totalRewards);
        lastEpochClaimedStaker[msg.sender] = currentEpoch - 1;
    }
}
