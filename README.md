# Suzaku Core

Core smart contracts for the Suzaku Protocol - a restaking and validation orchestration platform for Avalanche L1s.

## Table of Contents

- [Overview](#overview)
- [Key Features](#key-features)
- [Architecture](#architecture)
  - [Core Components](#core-components)
  - [Suzaku Contracts Library Integration](#suzaku-contracts-library-integration)
- [Protocol Participants](#protocol-participants)
- [Protocol Flow](#protocol-flow)
- [Post-Audit Updates](#post-audit-updates)
- [Development](#development)
- [Documentation](#documentation)
- [Security](#security)
- [Inspiration & Acknowledgments](#inspiration--acknowledgments)
- [License](#license)
- [Links](#links)

## Overview

Suzaku enables Avalanche L1 builders to decentralize their networks by orchestrating relationships between operators, curators (delegators), and stakers. The protocol combines native token staking with restaking of high‑quality collateral assets (e.g. stablecoins, liquid staking tokens), allowing L1s to adopt flexible security models, such as:

- **Proof of Stake (PoS)**: Native L1 token staking
- **Liquid Staking & Restaking**: Enable liquid staking tokens for additional yield opportunities
- **Dual Staking Model**: Require both native tokens and whitelisted collateral, mitigating token volatility risks

**Suzaku Core is a fork of [Symbiotic Core](https://github.com/symbioticfi/core), adapted for Avalanche L1 validation.** While maintaining its delegation/vault patterns, Suzaku has been reworked to integrate Avalanche's ICM (Interchain Messaging) and validator management infrastructure, shifting from generic network security to L1‑centric validation orchestration.


## Key Features

- **Multi-Collateral Support**: L1s can accept multiple collateral classes (native tokens, stablecoins, liquid staking tokens)
- **Flexible Operator Model**: Operators opt into L1s and vaults, running validation infrastructure
- **Curator-Managed Delegation**: Curators select reliable operators and L1s, managing stake allocation for depositors
- **Epoch-Based Rewards**: Fair reward distribution based on uptime, stake, and collateral class weights
- **Security Modules**: Modular architecture supporting multiple validator management strategies via the BalancerValidatorManager
- **Role-Based Access Control**: Granular permissions for protocol administration

## Architecture

### Core Components

#### Registries
- **L1Registry** ([src/contracts/L1Registry.sol](./src/contracts/L1Registry.sol)): Registers Avalanche L1s with their middleware and validator manager references
- **OperatorRegistry** ([src/interfaces/IOperatorRegistry.sol](./src/interfaces/IOperatorRegistry.sol)): Tracks registered operators and their metadata
- **VaultFactory** ([src/interfaces/IVaultFactory.sol](./src/interfaces/IVaultFactory.sol)): Deploys and upgrades tokenized vaults via ERC1967 proxies

#### Vaults & Delegation
- **VaultTokenized**: Upgradeable "ERC4626‑style" vaults that support epoch‑based withdrawals and checkpointed balances
  - Withdrawals become claimable at `EPOCH+2` max (i.e. two epochs delay) for each deposit epoch
  - Role-based access control governs deposits, vault limits, and whitelisting
- **BaseDelegator** ([src/interfaces/delegator/IBaseDelegator.sol](./src/interfaces/delegator/IBaseDelegator.sol)): Tracks maximum stake allocation per `(L1, collateralClass)` pair
- **L1RestakeDelegator** ([src/interfaces/delegator/IL1RestakeDelegator.sol](./src/interfaces/delegator/IL1RestakeDelegator.sol)): Implements a shares‑based delegation model with historical checkpointing

#### Opt-In Services
- **OperatorL1OptInService**: Operators explicitly opt into L1s they will validate
- **OperatorVaultOptInService**: Operators opt into vaults they accept collateral from

#### Middleware Layer (L1-Owned)
- **AvalancheL1Middleware** ([src/contracts/middleware/](./src/contracts/middleware/)): Core orchestration contract per L1
  - Inherits from **CollateralClassRegistry** (formerly AssetClassRegistry) to manage multiple collateral types with min/max stake requirements
  - Controls operator and node lifecycle (registration, removal, weight updates)
  - Implements **ISecurityModule** interface for integration with BalancerValidatorManager
  - Manages node weight calculations and epoch transitions
  - Enforces stake locking during pending updates to prevent rewards manipulation
  - **Permissionless completion functions** (`completeValidatorRegistration`, `completeValidatorRemoval`, `completeValidatorWeightUpdate`) improve system liveness

#### Middleware Support (L1-Owned)
- **MiddlewareVaultManager** ([src/contracts/middleware/](./src/contracts/middleware/)): Registers vaults to L1s with stake limits per vault/collateral-class pair
- **CollateralClassRegistry** (formerly AssetClassRegistry): Groups ERC20 tokens by class with staking requirements
  - **Decimal validation**: All assets in a collateral class must have matching decimals
  - Role-based administration via `COLLATERAL_CLASS_MANAGER_ROLE`

#### Rewards System
- **Rewards** ([src/contracts/rewards/Rewards.sol](./src/contracts/rewards/Rewards.sol)): Epoch-based rewards distribution
  - **Funding**: Set rewards per epoch with protocol fee taken upfront
  - **Distribution**: Compute shares by collateral class, operator uptime, and vault stake routing
  - **Claims**: Process up to 64 epochs per call to prevent out-of-gas conditions
  - **Sweep**: Recover undistributed rewards after grace period
  - Time windows ensure proper funding and settlement
- **UptimeTracker** ([src/contracts/rewards/UptimeTracker.sol](./src/contracts/rewards/UptimeTracker.sol)): Tracks validator uptime across epochs
  - Validates against epochs before validator start
  - Sources data from middleware's balancer for validator manager access

### Suzaku Contracts Library Integration

The protocol integrates tightly with [suzaku-contracts-library](./lib/suzaku-contracts-library/), notably:

#### BalancerValidatorManager
Located at `lib/suzaku-contracts-library/src/contracts/ValidatorManager/`, the **BalancerValidatorManager** wraps the ICM ValidatorManager (v2.1.0) and enables multiple security modules to manage portions of the validator set.

**Key Features:**
- Multiple security modules operate independently with weight limits
- Each security module has a maximum weight allocation
- Tracks and enforces weight limits per module
- Supports wrapping existing ValidatorManagers with migration support
- Provides enhanced getters for validator state

**Architecture:**
```
┌─────────────────────────────┐
│ AvalancheL1Middleware       │ ← Security Module (implements ISecurityModule)
│ (Suzaku Core)               │
└──────────┬──────────────────┘
           │ initiates validator operations
           ▼
┌─────────────────────────────┐
│ BalancerValidatorManager    │ ← Manages multiple security modules
│ (Suzaku Library)            │    Enforces weight limits
└──────────┬──────────────────┘
           │ owns
           ▼
┌─────────────────────────────┐
│ ValidatorManager v2.1.0     │ ← ICM Validator Manager
│ (ICM Contracts)             │    Handles P-Chain communication
└─────────────────────────────┘
```

The middleware acts as a security module, initiating validator operations through the balancer, which enforces weight limits and coordinates with the underlying ICM ValidatorManager for P-Chain interactions.

**Security Modules:**
- **PoASecurityModule**: Proof of Authority implementation with owner-controlled validator management
- **AvalancheL1Middleware**: Restaking-based security module (this protocol)

See [lib/suzaku-contracts-library/src/contracts/ValidatorManager/README.md](./lib/suzaku-contracts-library/src/contracts/ValidatorManager/README.md) for detailed documentation.

## Protocol Participants

- **L1 Builders**: Define staking and slashing rules for their Avalanche L1s
- **Stakers**: Deposit collateral to secure networks and earn rewards
- **Operators**: Run validation infrastructure, must meet staking requirements
- **Curators**: Select operators and L1s, manage stake delegation for depositors

## Protocol Flow

### 1. L1 Onboarding
1. L1 owner registers the L1 in `L1Registry` with middleware and validator manager addresses
2. L1 owner registers vaults through `MiddlewareVaultManager`, setting stake limits per vault/collateral-class
3. L1 owner configures collateral classes (primary + secondary) with min/max stake requirements

### 2. Operator & Curator Setup
1. Operators register in `OperatorRegistry`
2. Operators opt into L1s via `OperatorL1OptInService`
3. Operators opt into vaults via `OperatorVaultOptInService`
4. Curators deploy vaults and set delegation shares for operators

### 3. Staking & Validation
1. Stakers deposit collateral into vaults
2. Vaults track active stake with epoch-based withdrawals (`EPOCH+2` delay)
3. Delegators assign operator shares within L1 limits
4. Operators add/remove/update validator nodes through middleware
5. Middleware calculates node weights and coordinates with BalancerValidatorManager
6. BalancerValidatorManager enforces weight limits and communicates with ICM ValidatorManager

### 4. Epoch Progression
1. Epoch transitions trigger node stake cache updates
2. Pending node updates are resolved (registrations, removals, weight changes)
3. Locked stake from mid-epoch changes is released
4. `UptimeTracker` records validator performance

### 5. Rewards Distribution
1. Distributor funds epochs with reward tokens (protocol fee taken upfront)
2. Distribution calculates shares based on:
   - Collateral class weights
   - Operator uptime (must meet minimum threshold)
   - Vault stake routing to each operator
3. Shares split between operators (fee), curators (fee), and stakers (remaining)
4. Participants claim rewards for completed epochs (max 64 epochs per call)
5. Undistributed rewards (rounding leftovers) can be swept after grace period

## Post-Audit Updates

The current implementation includes significant improvements from the Cyfrin audit baseline. See [post-audit-updates.md](./post-audit-updates.md) for complete details.

## Development

### Prerequisites
- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Solidity 0.8.25

### Installation
```bash
# Clone the repository
git clone https://github.com/suzaku-network/suzaku-core.git
cd suzaku-core

# Install dependencies
forge install

# Build contracts
forge build
```

### Testing
```bash
# Run all tests
forge test

# Run specific test file
forge test --match-path test/path/to/Test.t.sol

# Run with gas reports
forge test --gas-report

# Run with verbosity
forge test -vvv
```

### Deployment

Check on [Suzaku Deployer](https://github.com/suzaku/suzaku-deployer)** for information on how to deploy different contracts Suzaku Core contracts depending on the usecase.

## Documentation

- [Protocol Overview](./docs/overview.md): Detailed protocol explanation
- [Post-Audit Updates](./post-audit-updates.md): Changes from audit baseline to current implementation
- [Middleware README](./docs/middleware.md): Middleware-specific documentation
- [Rewards README](./docs/rewards.md): Rewards system deep dive
- [Balancer README](./lib/suzaku-contracts-library/src/contracts/ValidatorManager/README.md): BalancerValidatorManager and security modules

## Security

This codebase has undergone security audits:
- **Cyfrin Audit** (baseline commit `7381169`)
- Current implementation includes post-audit fixes and improvements

Audit reports can be found in the [audit/](./audit/) directory.

## Inspiration & Acknowledgments

**Suzaku Core is a fork of [Symbiotic Core](https://github.com/symbioticfi/core)**, adapted for the Avalanche ecosystem. The protocol inherits Symbiotic's vault architecture, delegation patterns, and operator registry concepts, while introducing significant modifications for Avalanche L1 validation.

Additional inspiration:
- [Eigenlayer](https://github.com/Layr-Labs/eigenlayer-contracts): Restaking concepts and security models

### Major Modifications from Symbiotic
- **L1-Specific**: Secures Avalanche `L1`s instead of generic `Network`s - each L1 must correspond to an existing Avalanche L1 converted via `ConvertSubnetTx`
- **Middleware Layer**: Introduces `AvalancheL1Middleware` as a security module implementing `ISecurityModule` for integration with `BalancerValidatorManager`
- **ICM Integration**: Deep integration with Avalanche's Interchain Messaging (ICM) and ValidatorManager v2.1.0 for P-Chain communication
- **Epoch-Based Rewards**: Custom rewards distribution system based on validator uptime tracking
- **Collateral Classes**: Multi-collateral support with decimal validation and weight-based distribution (notably modified in middleware and rewards)
- **No Common Contracts**: Doesn't use Symbiotic's `common` contracts standardization
- **Non-Migratable Vaults**: Vaults are upgradeable via proxy pattern but not migratable between implementations

## License

Dual-licensed under [MIT](./LICENSE-MIT) and [AGPL-3.0](./LICENSE).

## Links

- [Documentation](./docs/)
- [Suzaku Contracts Library](https://github.com/suzaku-network/suzaku-contracts-library)
- [Avalanche ICM Contracts](https://github.com/ava-labs/icm-contracts)
