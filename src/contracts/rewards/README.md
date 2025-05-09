# Rewards System

The rewards system manages the distribution of staking rewards to operators, stakers, curators, and protocol owners based on validator performance and stake amounts.

## Overview

The system tracks and distributes rewards for each epoch, taking into account:

- Operator uptime and performance
- Staked amounts across different asset classes
- Fee structures for different participants

## Key Components

### Roles

- **Admin**: Can configure fees, rewards amounts, and claim undistributed rewards
- **Protocol Owner**: Receives protocol fees
- **Operators**: Run validators and receive operator fees
- **Curators**: Vault owners who receive curator fees
- **Stakers**: Users who stake tokens in vaults

### Fee Structure

- Protocol Fee
- Operator Fee
- Curator Fee

All fees are configured in basis points (1/10000)

## Typical Epoch Workflow

1. **Uptime Tracking**

   - Validator uptime is recorded throughout the epoch
   - Operator uptime is computed as average of their validators
   - Minimum required uptime threshold must be met

2. **Rewards Distribution**

   - Admin sets rewards amount for epochs using setRewardsAmountForEpochs()
   - Distribution happens in batches via distributeRewards()
   - System calculates shares for:
     - Operators based on stake and uptime
     - Vaults based on delegated stake
     - Curators based on vault ownership

3. **Claims Process**

   - Stakers: claimRewards()
   - Operators: claimOperatorFee()
   - Curators: claimCuratorFee()
   - Protocol Owner: claimProtocolFee()

4. **Undistributed Rewards**

   - After 2 epochs, admin can claim undistributed rewards
   - Uses claimUndistributedRewards()

## Share Calculation

1. **Operator Shares**

   - Based on total stake across asset classes
   - Weighted by uptime performance
   - Adjusted by operator fee percentage

2. **Vault Shares**

   - Proportional to stake delegated to operators
   - Weighted by asset class rewards share
   - Reduced by curator fee

3. **Curator Shares**
   - Percentage of vault shares based on curator fee
   - Tracked per vault owner

## Important Notes

- Claims can only be made for completed epochs
- Uptime must be above minimum threshold for rewards
- Fees cannot exceed 100% in total
- Undistributed rewards have 2 epoch waiting period
- Each participant can only claim once per epoch

## Error Handling

The system includes comprehensive error checking for:

- Invalid recipients
- Double claims
- Incomplete distributions
- Zero rewards scenarios
- Invalid fee configurations
- Missing uptime data

This rewards system provides a flexible and secure way to distribute staking rewards while ensuring proper incentive alignment between all participants.
