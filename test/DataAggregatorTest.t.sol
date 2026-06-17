// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {DataAggregator, L1Data, OperatorData, VaultData} from "../src/contracts/DataAggregator.sol";
import {IL1Registry} from "../src/interfaces/IL1Registry.sol";
import {IAvalancheL1Middleware} from "../src/interfaces/middleware/IAvalancheL1Middleware.sol";
import {IMiddlewareVaultManager} from "../src/interfaces/middleware/IMiddlewareVaultManager.sol";
import {IVaultTokenized} from "../src/interfaces/vault/IVaultTokenized.sol";
import {IL1RestakeDelegator} from "../src/interfaces/delegator/IL1RestakeDelegator.sol";
import {ICollateralClassRegistry} from "../src/interfaces/middleware/ICollateralClassRegistry.sol";

contract DataAggregatorTest is Test {
    DataAggregator public dataAggregator;

    address constant L1_REGISTRY = 0xaA59b19A7636bf6d821aA124A14eEE6C92746110;
    address constant L1_ADDRESS = 0x5D8aBF189f5e167aD5b089d93828Dc091dD85690;
    address constant VAULT_ADDRESS = 0xFEafE001E6080Be907A63C7492748c100541C48B;
    address constant OPERATOR_ADDRESS = 0x5f3722fdE8a7014464CA1507af0EFE1566684856;

    // Fork Mainnet
    uint256 mainnet;

    function setUp() public {
        // Create a fork of Avalanche Mainnet
        mainnet = vm.createFork("https://avax.meowrpc.com");
        vm.selectFork(mainnet);

        // Deploy DataAggregator
        dataAggregator = new DataAggregator(L1_REGISTRY);
    }

    function test_GetL1Data() public {
        L1Data memory l1Data = dataAggregator.getL1Data(L1_ADDRESS);

        // Log the data for manual verification
        emit log_named_address("L1 Address", l1Data.l1);
        emit log_named_address("L1 Middleware", l1Data.middleware);
        emit log_named_address("Vault Manager", l1Data.vaultManager);
        emit log_named_uint("Current Epoch", l1Data.epoch.currentEpoch);
        emit log_named_uint("Epoch Duration", l1Data.epoch.epochDuration);
        emit log_named_uint("Current Epoch Start Timestamp", l1Data.epoch.currentEpochStartTs);

        // Collaterals
        emit log_named_uint("Number of Collateral Classes", l1Data.collateral.classIds.length);
        for (uint256 i = 0; i < l1Data.collateral.classIds.length; i++) {
            emit log_named_uint("Collateral Class ID", l1Data.collateral.classIds[i]);
            emit log_named_uint("Number of Assets", l1Data.collateral.assetsByClass[i].assets.length);
            for (uint256 j = 0; j < l1Data.collateral.assetsByClass[i].assets.length; j++) {
                emit log_named_address("Asset", l1Data.collateral.assetsByClass[i].assets[j]);
            }
            emit log_named_uint("Total Stake", l1Data.collateral.stakesByClass[i].stake);
        }

        // Operators
        emit log_named_uint("Number of Operators", l1Data.operatorSet.length);
        for (uint256 i = 0; i < l1Data.operatorSet.length; i++) {
            emit log_named_address("Operator", l1Data.operatorSet[i].operator);
            emit log_named_uint("Number of Collateral Classes", l1Data.operatorSet[i].stakesByClass.length);
            for (uint256 j = 0; j < l1Data.operatorSet[i].stakesByClass.length; j++) {
                emit log_named_uint("Collateral Class ID", l1Data.operatorSet[i].stakesByClass[j].classId);
                emit log_named_uint("L1 Total Stake", l1Data.operatorSet[i].stakesByClass[j].stakeOnL1);
                emit log_named_uint("Operator Stake", l1Data.operatorSet[i].stakesByClass[j].stake);
                emit log_named_uint("Operator Used Stake", l1Data.operatorSet[i].stakesByClass[j].usedStake);
            }
        }
        emit log_named_uint("Number of Validators", l1Data.validatorsCount);

        // Vaults
        emit log_named_uint("Number of Vaults", l1Data.vaultSet.length);
        for (uint256 i = 0; i < l1Data.vaultSet.length; i++) {
            emit log_named_address("Vault", l1Data.vaultSet[i].vault);
            emit log_named_uint("Collateral Class ID", l1Data.vaultSet[i].classId);
            emit log_named_uint("Stake", l1Data.vaultSet[i].stake);
        }
    }

    function test_GetOperatorData() public {
        OperatorData memory operatorData = dataAggregator.getOperatorData(OPERATOR_ADDRESS);

        emit log_named_address("Operator Address", operatorData.operator);

        // L1s
        emit log_named_uint("Number of L1s", operatorData.stakesByL1.length);
        for (uint256 i = 0; i < operatorData.stakesByL1.length; i++) {
            emit log_named_address("L1 Address", operatorData.stakesByL1[i].l1);
            emit log_named_uint("Number of Collateral Classes", operatorData.stakesByL1[i].stakesByClass.length);
            for (uint256 j = 0; j < operatorData.stakesByL1[i].stakesByClass.length; j++) {
                emit log_named_uint("Collateral Class ID", operatorData.stakesByL1[i].stakesByClass[j].classId);
                emit log_named_uint("L1 Stake", operatorData.stakesByL1[i].stakesByClass[j].stakeOnL1);
                emit log_named_uint("Operator Stake", operatorData.stakesByL1[i].stakesByClass[j].stake);
                emit log_named_uint("Operator Used Stake", operatorData.stakesByL1[i].stakesByClass[j].usedStake);
            }
        }

        // Vaults
        emit log_named_uint("Number of Vaults", operatorData.stakesByVault.length);
        for (uint256 i = 0; i < operatorData.stakesByVault.length; i++) {
            emit log_named_address("Vault Address", operatorData.stakesByVault[i].vault);
            emit log_named_address("Collateral Asset", operatorData.stakesByVault[i].collateralAsset);
            emit log_named_uint("Stake", operatorData.stakesByVault[i].stake);
        }
    }

    function test_GetVaultData() public {
        VaultData memory vaultData = dataAggregator.getVaultData(VAULT_ADDRESS);

        emit log_named_address("Vault Address", vaultData.vault);
        emit log_named_address("Collateral", vaultData.collateral);
        emit log_named_address("Delegator", vaultData.delegator);
        emit log_named_uint("Total Stake", vaultData.totalStake);

        // L1s
        emit log_named_uint("Number of Delegated L1s", vaultData.stakesByL1.length);
        for (uint256 i = 0; i < vaultData.stakesByL1.length; i++) {
            emit log_named_address("Delegated L1", vaultData.stakesByL1[i].l1);
            emit log_named_uint("Corresponding Collateral Class ID", vaultData.stakesByL1[i].classId);
            emit log_named_uint("Stake", vaultData.stakesByL1[i].stake);
        }

        // Operators
        emit log_named_uint("Number of Delegated Operators", vaultData.stakesByOperator.length);
        for (uint256 i = 0; i < vaultData.stakesByOperator.length; i++) {
            emit log_named_address("Delegated Operator", vaultData.stakesByOperator[i].operator);
            emit log_named_uint("Stake", vaultData.stakesByOperator[i].stake);
        }
    }
}
