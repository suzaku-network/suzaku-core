// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {DataAggregator, L1Data, VaultData, OperatorData} from "../src/contracts/DataAggregator.sol";
import {IL1Registry} from "../src/interfaces/IL1Registry.sol";
import {IAvalancheL1Middleware} from "../src/interfaces/middleware/IAvalancheL1Middleware.sol";
import {IMiddlewareVaultManager} from "../src/interfaces/middleware/IMiddlewareVaultManager.sol";
import {IVaultTokenized} from "../src/interfaces/vault/IVaultTokenized.sol";
import {IL1RestakeDelegator} from "../src/interfaces/delegator/IL1RestakeDelegator.sol";
import {ICollateralClassRegistry} from "../src/interfaces/middleware/ICollateralClassRegistry.sol";

contract DataAggregatorTest is Test {
    DataAggregator public dataAggregator;

    address constant L1_REGISTRY = 0xbB2ab0Ae2DdbC302eF4947435E881d5A95E882FE;
    address constant L1_ADDRESS = 0x46a2C23826caA714d5E298aDF7E0eeEadc087d2d;
    address constant VAULT_ADDRESS = 0xc2BC5788A769F3BF4C37255eF301c08D641416D4;
    address constant OPERATOR_ADDRESS = 0x50cA76a4f5b0C9ac02E0a6E0C286C29D367aF650;

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
        emit log_named_uint("Current Epoch", l1Data.epochSettings.currentEpoch);
        emit log_named_uint("Number of Operators", l1Data.operators.length);
        for (uint256 i = 0; i < l1Data.operators.length; i++) {
            emit log_named_address("Operator", l1Data.operators[i]);
        }
        emit log_named_uint("Number of Vaults", l1Data.vaults.length);
        for (uint256 i = 0; i < l1Data.vaults.length; i++) {
            emit log_named_address("Vault", l1Data.vaults[i]);
        }
        emit log_named_uint("Number of Collateral Class Stakes", l1Data.collateralClassStakes.length);
        for (uint256 i = 0; i < l1Data.collateralClassStakes.length; i++) {
            emit log_named_uint("Collateral Class", l1Data.collateralClassStakes[i].collateralClass);
            emit log_named_uint("Number of Assets", l1Data.collateralClassStakes[i].assetsInClass.length);
            for (uint256 j = 0; j < l1Data.collateralClassStakes[i].assetsInClass.length; j++) {
                emit log_named_address("Asset", l1Data.collateralClassStakes[i].assetsInClass[j]);
            }
            emit log_named_uint("Stake", l1Data.collateralClassStakes[i].stake);
        }
        emit log_named_uint("Number of Validators", l1Data.validators);
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
        emit log_named_uint("Number of Collateral Class Stakes", operatorData.collateralClassStakeMap.length);
        for (uint256 i = 0; i < operatorData.collateralClassStakeMap.length; i++) {
            emit log_named_address("Middleware", operatorData.collateralClassStakeMap[i].middleware);
            emit log_named_uint(
                "Number of Collateral Class Stakes",
                operatorData.collateralClassStakeMap[i].collateralClassStakes.length
            );
            for (uint256 j = 0; j < operatorData.collateralClassStakeMap[i].collateralClassStakes.length; j++) {
                emit log_named_uint(
                    "Collateral Class", operatorData.collateralClassStakeMap[i].collateralClassStakes[j].collateralClass
                );
                emit log_named_uint(
                    "Number of Assets",
                    operatorData.collateralClassStakeMap[i].collateralClassStakes[j].assetsInClass.length
                );
                for (
                    uint256 k = 0;
                    k < operatorData.collateralClassStakeMap[i].collateralClassStakes[j].assetsInClass.length;
                    k++
                ) {
                    emit log_named_address(
                        "Asset", operatorData.collateralClassStakeMap[i].collateralClassStakes[j].assetsInClass[k]
                    );
                }
                emit log_named_uint("Stake", operatorData.collateralClassStakeMap[i].collateralClassStakes[j].stake);
            }
        }
    }
}
