# SuzVault Deployment Guide

Follow the steps below to deploy the SuzVault along with the required collateral token and associated contracts.

## 1. Create the `Collateral` Token

After deploying anvil and before deploying SuzVault, you need to create the `collateral` token. 

- **Repository:** Use the [suzaku-deployments repository](https://github.com/suzaku-network/suzaku-deployments).
- **Path:** Navigate to the `/suzaku-restaking/docs/local-anvil/collateral.md` section for detailed instructions on creating the collateral token.

## 2. Set Up Environment Variables

Create a `.env.anvil` file in your project root directory and populate it with the following variables:

```env
CHAIN_ID=31337
OWNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
INITIAL_VAULT_VERSION=1
DEFAULT_INCLUDE_SLASHER=false
COLLATERAL_TOKEN_ADDRESS= # Replace with your collateral token address 
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
INCLUDE_SLASHER=false
```

**Important:**
- Ensure you replace the placeholder comments (e.g., `# Replace with your collateral token address`) with actual deployed contract addresses.
- The owner and private key are the first anvil created address.

## 3. Deploy Factories and Registries

Deploy the necessary factories and registries using the following commands:

```bash
# Export all variables from .env.anvil
set -a
source .env.anvil

# Deploy Factory and Registry contracts
forge script ./script/deploy/FactoryAndRegistry.s.sol:FactoryAndRegistryScript \
  --broadcast \
  --rpc-url http://127.0.0.1:8545 \
  --private-key $DEPLOYER_PRIV_KEY \
  --via-ir
```

## 4. Update Environment Variables with Deployed Addresses

```env
export DELEGATOR_FACTORY=$(jq -r '.DelegatorFactory' deployments/deploymentDetails.json)
export VAULT_FACTORY=$(jq -r '.VaultFactory' deployments/deploymentDetails.json)
export SLASHER_FACTORY=$(jq -r '.SlasherFactory' deployments/deploymentDetails.json)
export L1_REGISTRY=$(jq -r '.L1Registry' deployments/deploymentDetails.json)
export OPERATOR_REGISTRY=$(jq -r '.OperatorRegistry' deployments/deploymentDetails.json)
```

## 5. Deploy Core Contracts

```bash
# Deploy Core contracts
forge script ./script/deploy/Core.s.sol:CoreScript \
  --broadcast \
  --rpc-url http://127.0.0.1:8545 \
  --private-key $DEPLOYER_PRIV_KEY \
  --via-ir
```

## 6. Verification and Final Steps

- **Verify Deployments:** Check the `deployments` folder to ensure all contracts have been deployed successfully.

