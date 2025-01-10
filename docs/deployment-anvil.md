# SuzVault Deployment Guide 

This guide outlines how to deploy the collateral token, the suzaku factories, registeries and rest of contracts on a local Anvil network using a single deployment script.

## Prerequisites

- **Anvil**: A local EVM testnet
- **Foundry**: For `forge` commands (see [Foundry Book](https://book.getfoundry.sh/) for installation instructions)
- **Node.js + jq**: For processing JSON outputs

## Steps

1. **Start Anvil**

   In a new terminal:
   ```bash
   anvil
   ```

   This starts a local Ethereum test network at `http://127.0.0.1:8545`.

2. **Run the Centralized Deployment Script**

   In another terminal, navigate to your project directory and run:
   ```bash
   forge script script/deploy/anvil/FullLocalDeploymentScript.s.sol:FullLocalDeploymentScript \
       --broadcast \
       --rpc-url http://127.0.0.1:8545 \
       --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
       --via-ir
   ```

   **What this does:**
   - Deploys a mock collateral token (with an initial supply allocated to the deployer).
   - Deploys all required factories and registries.
   - Whitelists the Vault and Delegator implementations.
   - Creates a fully functioning vault and delegator setup in one go.
   - Generates a `fullLocalDeployment.json` file in the `./deployments/` directory containing addresses of all deployed contracts.

3. **Review the Deployment**

   Check the output in the terminal and the `fullLocalDeployment.json` file in the `./deployments/` folder for the deployed contract addresses. These addresses can now be used directly in your tests or further scripts.

## Optional Steps for Customization

If you wish to adjust configurations (e.g., deposit limits, epoch duration, token names), modify the `HelperConfig.s.sol` file. The `FullLocalDeploymentScript` reads these static configurations directly. No `.env.anvil` file or environment variable sourcing is required.
