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

## Collateral

Suzaku Collateral enables flexible and capital-efficient staking by allowing multiple types of ERC-20 tokens to be used as collateral for securing L1s. See [src/contracts/defaultCollateral/README.md](./src/contracts/defaultCollateral/README.md) for details.
