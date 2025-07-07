// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {
    DataAggregator,
    L1Data,
    VaultData,
    OperatorData,
    AssetClassStake,
    AssetsStake
} from "../src/contracts/DataAggregator.sol";
import {IL1Registry} from "../src/interfaces/IL1Registry.sol";
import {IAvalancheL1Middleware} from "../src/interfaces/middleware/IAvalancheL1Middleware.sol";
import {IMiddlewareVaultManager} from "../src/interfaces/middleware/IMiddlewareVaultManager.sol";
import {IVaultTokenized} from "../src/interfaces/vault/IVaultTokenized.sol";
import {IL1RestakeDelegator} from "../src/interfaces/delegator/IL1RestakeDelegator.sol";
import {IAssetClassRegistry} from "../src/interfaces/middleware/IAssetClassRegistry.sol";

contract DataAggregatorTest is Test {
    DataAggregator public dataAggregator;

    address constant L1_REGISTRY = 0xB9826Bbf0deB10cC3924449B93F418db6b16be36;
    address constant L1_ADDRESS = 0x84F2B4D4cF8DA889701fBe83d127896880c04325;
    address constant VAULT_ADDRESS = 0x85F212C69f0C567011E1eCFf956dCc0014754A2c;
    address constant OPERATOR_ADDRESS = 0xfFF4224c953682C0866cb45643512D8Eee6eB608;

    // Fork Fuji testnet
    uint256 fuji;

    function setUp() public {
        // Create a fork of Avalanche Fuji testnet
        fuji = vm.createFork("https://api.avax-test.network/ext/bc/C/rpc");
        vm.selectFork(fuji);

        // Deploy DataAggregator
        dataAggregator = new DataAggregator(L1_REGISTRY);
    }

    function test_GetL1Data() public {
        L1Data memory l1Data = dataAggregator.getL1Data(L1_ADDRESS);

        // Log the data for manual verification
        emit log_named_address("L1 Address", l1Data.l1);
        emit log_named_address("L1 Middleware", l1Data.l1Middleware);
        emit log_named_address("Vault Manager", l1Data.vaultManager);
        emit log_named_string("L1 Metadata", l1Data.l1Metadata);
        emit log_named_uint("Current Epoch", l1Data.currentEpoch);
        emit log_named_uint("Number of Operators", l1Data.operators.length);
        for (uint256 i = 0; i < l1Data.operators.length; i++) {
            emit log_named_address("Operator", l1Data.operators[i]);
        }
        emit log_named_uint("Number of Vaults", l1Data.vaults.length);
        for (uint256 i = 0; i < l1Data.vaults.length; i++) {
            emit log_named_address("Vault", l1Data.vaults[i]);
        }
        emit log_named_uint("Number of Asset Class Stakes", l1Data.assetClassStakes.length);
        for (uint256 i = 0; i < l1Data.assetClassStakes.length; i++) {
            emit log_named_uint("Asset Class", l1Data.assetClassStakes[i].assetClass);
            emit log_named_uint("Stake", l1Data.assetClassStakes[i].stake);
        }
    }

    function test_GetVaultData() public {
        VaultData memory vaultData = dataAggregator.getVaultData(VAULT_ADDRESS);

        // Log the data for manual verification
        emit log_named_address("Vault Address", vaultData.vault);
        emit log_named_address("Collateral", vaultData.collateral);
        emit log_named_address("Delegator", vaultData.delegator);
        emit log_named_uint("Total Stake", vaultData.totalStake);
        emit log_named_uint("Number of Delegated L1s", vaultData.delegatedL1s.length);
        for (uint256 i = 0; i < vaultData.delegatedL1s.length; i++) {
            emit log_named_address("Delegated L1", vaultData.delegatedL1s[i]);
        }
        emit log_named_uint("Number of Delegated Operators", vaultData.delegatedOperators.length);
        for (uint256 i = 0; i < vaultData.delegatedOperators.length; i++) {
            emit log_named_address("Delegated Operator", vaultData.delegatedOperators[i]);
        }
    }

    function test_GetOperatorData() public {
        OperatorData memory operatorData = dataAggregator.getOperatorData(OPERATOR_ADDRESS);

        // Log the data for manual verification
        emit log_named_address("Operator Address", operatorData.operator);
        emit log_named_uint("Number of Secured L1s", operatorData.securedL1s.length);
        for (uint256 i = 0; i < operatorData.securedL1s.length; i++) {
            emit log_named_address("Secured L1", operatorData.securedL1s[i]);
        }
        emit log_named_uint("Number of Trusted Vaults", operatorData.trustedVaults.length);
        for (uint256 i = 0; i < operatorData.trustedVaults.length; i++) {
            emit log_named_address("Trusted Vault", operatorData.trustedVaults[i]);
        }
        emit log_named_uint("Number of Assets Stakes", operatorData.assetsStakes.length);
        for (uint256 i = 0; i < operatorData.assetsStakes.length; i++) {
            emit log_named_uint("Number of Assets", operatorData.assetsStakes[i].assets.length);
            for (uint256 j = 0; j < operatorData.assetsStakes[i].assets.length; j++) {
                emit log_named_address("Asset", operatorData.assetsStakes[i].assets[j]);
            }
            emit log_named_uint("Stake", operatorData.assetsStakes[i].stake);
        }
    }
}
