Create .env.anvil with following variables:

```
CHAIN_ID=31337
OWNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
INITIAL_VAULT_VERSION=1
DEFAULT_INCLUDE_SLASHER=false
COLLATERAL_TOKEN_ADDRESS=0x9f1ac54bef0dd2f6f3462ea0fa94fc62300d3a8e
EPOCH_DURATION=3600
DEPOSIT_WHITELIST=true
DEPOSIT_LIMIT=1000000
DELEGATOR_INDEX=0
SLASHER_INDEX=0
VETO_DURATION=3600
OPERATOR=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
RESOLVER_EPOCHS_DELAY=10
NAME="SuzVault"
SYMBOL="Suz"
DEPLOYER_PRIV_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
VAULT_FACTORY=
DELEGATOR_FACTORY=
SLASHER_FACTORY=
L1_REGISTRY=
OPERATOR_REGISTRY=
INCLUDE_SLASHER=false
```

Launch the factories and registries

```
set -a
source .env.sepolia
forge script ./script/deploy/FactoryAndRegistry.s.sol:FactoryAndRegistryScript --broadcast --rpc-url http://127.0.0.1:8545 --private-key $DEPLOYER_PRIV_KEY --via-ir
```

Replace factories and registries in `.env.anvil` with the deployed adddresses. They can be found in `deployments` folder. 



set -a
source .env.sepolia
forge script ./script/deploy/Core.s.sol:CoreScript --broadcast --rpc-url http://127.0.0.1:8545 --private-key $DEPLOYER_PRIV_KEY --via-ir
