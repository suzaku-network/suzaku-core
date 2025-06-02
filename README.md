# Suzaku Core

Core contracts of the Suzaku protocol.

## Architecture

Suzaku Core contracts are inspired by [Symbiotic Core contracts](https://github.com/symbioticfi/core).

### Major divergences between Suzaku and Symbiotic

- Suzaku doesn't use the Symbiotics [`common` contracts](https://github.com/symbioticfi/core/tree/main/src/contracts/common) standardization.
- Suzaku secures `L1`s instead of `Network`s. Each `L1` has to correspond to an existing Avalanche L1 that has been converted using `ConvertSubnetTx`.
- Suzaku `Vault`s are not migratable.

**Note:** The compatibility with Symbiotic interfaces could be increased in the future if needed for some integrations.

### Contracts and Symbiotics counterparts

| Suzaku                                                     | Symbiotic                                                                                            |
| ---------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| [L1Registry](./src/contracts/L1Registry.sol)               | [NetworkRegistry](https://github.com/symbioticfi/core/blob/main/src/contracts/NetworkRegistry.sol)   |
| [OperatorRegistry](./src/interfaces/IOperatorRegistry.sol) | [OperatorRegistry](https://github.com/symbioticfi/core/blob/main/src/contracts/OperatorRegistry.sol) |

### Collateral

**Collateral** is a concept introduced by [Symbiotic](https://symbiotic.fi) that brings capital efficiency and scale by enabling assets used to secure networks to be held outside of the restaking protocol itself - e.g. in DeFi positions on networks other than Ethereum itself.

The Collateral interface can be found [here](./src/interfaces/ICollateral.sol).

## Default Collateral

Default Collateral is a simple version of Collateral that has an instant debt repayment, which supports only non-rebase underlying assets.

The implementation can be found [here](./src/contracts/defaultCollateral).

## Security

Security audits can be found in the [symbioticfi/collateral](https://github.com/symbioticfi/collateral/tree/main/audits) repository.

## Usage

### Env

Create `.env` file using a template:

```
ETH_RPC_URL=
```

To get the `ETH_RPC_URL`, you can use [Alchemy](https://www.alchemy.com/), [Infura](https://infura.io/), or any other Ethereum node provider.

### Build

```shell
forge build
```

### Test

```shell
forge test
```

### Format

```shell
forge fmt
```

### Gas Snapshots

```shell
forge snapshot
```
