# Suzaku Collateral, Collateral Classes & Default Collateral

Suzaku Collateral enables flexible and capital-efficient staking by allowing multiple types of ERC-20 tokens to be used as collateral for securing L1s. The system is inspired by Symbiotic (for the concept and audits), but is adapted and extended for Suzaku's needs.

## What Are Collateral Classes?

In Suzaku, every collateral token (ERC-20) belongs to exactly one **collateral class**. Each class can contain one or more tokens that an L1 accepts for a specific staking requirement.

### Primary Collateral Class

- Each L1 must have at least one collateral class marked as "primary".
- Typically, this class includes the L1's own token and possibly derivatives (e.g., TOKEN and veTOKEN).
- Validators must stake a minimum amount from this class to meet the L1's primary requirement ("skin in the game").
- Primary classes enforce both `minValidatorStake` and `maxValidatorStake` per validator.

### Secondary Collateral Class(es)

- L1s can define additional (secondary) collateral classes for other tokens (e.g., stablecoins, LSTs, cross-chain assets).
- Secondary classes help diversify or stabilize collateral (e.g., "min. 100 native token + min. 200 stablecoin").
- Each secondary class can have multiple tokens and usually only enforces a minimum per validator.

## Collateral Tokens & Burners

- A Collateral in Suzaku is an ERC-20 token with extra features for normalization, points tracking, and (future) slashing.
- If principal slashing is supported, a Burner contract can be attached to burn or redeem the underlying asset.

## How It Works: L1 Staking Requirements

- **Primary Requirement:** L1 sets min/max rules for the primary class. All tokens in that class count toward the operator's primary stake.
- **Secondary Requirement:** L1 can require additional minimums from secondary classes. Operators must meet all requirements to validate.

## Vaults & Collateral Classes

- Each vault is deployed with a specific Collateral ERC-20 as its underlying token.
- That token belongs to one collateral class. If it's in the primary class, the vault's stake satisfies the primary requirement; if in a secondary class, it counts toward the secondary requirement.

## Registry & Enforcement

- Each L1's `AvalancheL1Middleware` contract consults `ICollateralClassRegistry` to check which tokens belong to which class and to enforce min/max staking rules.
- Operators must have delegations in all required collateral classes to become validators for an L1.

## Default Collateral

Default Collateral is a simple implementation of the Collateral interface for Suzaku. It enables instant debt repayment and supports only non-rebase underlying assets.

### Features

- **Instant Debt Repayment:** Repayments are processed immediately.
- **Non-Rebase Assets Only:** Only supports ERC-20 tokens that do not rebase.

### Implementation

The implementation can be found in this directory.

### Usage

#### Env

Create a `.env` file using a template:

```shell
RPC_URL=
```

To get the `RPC_URL`, you can use [Alchemy](https://www.alchemy.com/), [Infura](https://infura.io/), or any other Ethereum node provider.

#### Build

```shell
forge build
```

#### Test

```shell
forge test
```

#### Format

```shell
forge fmt
```

#### Gas Snapshots

```shell
forge snapshot
```

## References

- For more details, see the [Suzaku documentation](https://docs.suzaku.network/suzaku-protocol/for-builders/collateral-class).
- Concept inspired by [Symbiotic](https://symbiotic.fi) (see their [audits](https://github.com/symbioticfi/collateral/tree/main/audits)).
