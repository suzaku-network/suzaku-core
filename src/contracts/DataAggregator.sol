// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {IL1Registry} from "../interfaces/IL1Registry.sol";
import {AvalancheL1Middleware} from "../contracts/middleware/AvalancheL1Middleware.sol";
import {IMiddlewareVaultManager} from "../interfaces/middleware/IMiddlewareVaultManager.sol";
import {IVaultTokenized} from "../interfaces/vault/IVaultTokenized.sol";
import {IL1RestakeDelegator} from "../interfaces/delegator/IL1RestakeDelegator.sol";
import {ICollateralClassRegistry} from "../interfaces/middleware/ICollateralClassRegistry.sol";

struct CollateralClassStake {
    uint96 collateralClass;
    address[] assetsInClass;
    uint256 stake;
}

struct CollateralClassStakeMap {
    address middleware;
    CollateralClassStake[] collateralClassStakes;
}

struct EpochSettings {
    uint48 currentEpoch;
    uint48 epochDuration;
    uint48 currentEpochStartTs;
}

struct L1Data {
    address l1;
    address l1Middleware;
    address vaultManager;
    string l1Metadata;
    EpochSettings epochSettings;
    address[] operators;
    address[] vaults;
    CollateralClassStake[] collateralClassStakes;
    uint256 validators;
}

struct VaultData {
    address vault;
    address collateral;
    address delegator;
    uint256 totalStake;
    address[] delegatedL1s;
    address[] delegatedOperators;
}

struct OperatorData {
    address operator;
    address[] securedL1s;
    address[] trustedVaults;
    CollateralClassStakeMap[] collateralClassStakeMap;
}

contract DataAggregator {
    address public immutable L1_REGISTRY;

    constructor(
        address l1Registry
    ) {
        L1_REGISTRY = l1Registry;
    }

    function getL1Data(
        address l1
    ) external view returns (L1Data memory) {
        (address[] memory l1s,,) = IL1Registry(L1_REGISTRY).getAllL1s();

        uint256 l1Index;
        bool found;
        for (uint256 i = 0; i < l1s.length; i++) {
            if (l1s[i] == l1) {
                l1Index = i;
                found = true;
                break;
            }
        }

        if (!found) {
            return L1Data({
                l1: l1,
                l1Middleware: address(0),
                vaultManager: address(0),
                l1Metadata: "",
                epochSettings: EpochSettings({currentEpoch: 0, epochDuration: 0, currentEpochStartTs: 0}),
                operators: new address[](0),
                vaults: new address[](0),
                collateralClassStakes: new CollateralClassStake[](0),
                validators: 0
            });
        }

        (address l1Address, address l1MiddlewareAddress, string memory l1Metadata) =
            IL1Registry(L1_REGISTRY).getL1At(l1Index);

        address vaultManager;
        try AvalancheL1Middleware(payable(l1MiddlewareAddress)).getVaultManager() returns (address _vaultManager) {
            vaultManager = _vaultManager;
        } catch {
            return L1Data({
                l1: l1Address,
                l1Middleware: l1MiddlewareAddress,
                vaultManager: address(0),
                l1Metadata: l1Metadata,
                epochSettings: EpochSettings({currentEpoch: 0, epochDuration: 0, currentEpochStartTs: 0}),
                operators: new address[](0),
                vaults: new address[](0),
                collateralClassStakes: new CollateralClassStake[](0),
                validators: 0
            });
        }

        uint48 currentEpoch;
        try AvalancheL1Middleware(payable(l1MiddlewareAddress)).getCurrentEpoch() returns (uint48 _currentEpoch) {
            currentEpoch = _currentEpoch;
        } catch {
            return L1Data({
                l1: l1Address,
                l1Middleware: l1MiddlewareAddress,
                vaultManager: vaultManager,
                l1Metadata: l1Metadata,
                epochSettings: EpochSettings({currentEpoch: 0, epochDuration: 0, currentEpochStartTs: 0}),
                operators: new address[](0),
                vaults: new address[](0),
                collateralClassStakes: new CollateralClassStake[](0),
                validators: 0
            });
        }

        uint48 epochDuration;
        try AvalancheL1Middleware(payable(l1MiddlewareAddress)).EPOCH_DURATION() returns (uint48 _epochDuration) {
            epochDuration = _epochDuration;
        } catch {
            return L1Data({
                l1: l1Address,
                l1Middleware: l1MiddlewareAddress,
                vaultManager: vaultManager,
                l1Metadata: l1Metadata,
                epochSettings: EpochSettings({currentEpoch: currentEpoch, epochDuration: 0, currentEpochStartTs: 0}),
                operators: new address[](0),
                vaults: new address[](0),
                collateralClassStakes: new CollateralClassStake[](0),
                validators: 0
            });
        }

        uint48 currentEpochStartTs;
        try AvalancheL1Middleware(payable(l1MiddlewareAddress)).getEpochStartTs(currentEpoch) returns (
            uint48 _currentEpochStartTs
        ) {
            currentEpochStartTs = _currentEpochStartTs;
        } catch {
            return L1Data({
                l1: l1Address,
                l1Middleware: l1MiddlewareAddress,
                vaultManager: vaultManager,
                l1Metadata: l1Metadata,
                epochSettings: EpochSettings({
                    currentEpoch: currentEpoch,
                    epochDuration: epochDuration,
                    currentEpochStartTs: 0
                }),
                operators: new address[](0),
                vaults: new address[](0),
                collateralClassStakes: new CollateralClassStake[](0),
                validators: 0
            });
        }

        address[] memory allOperators;
        uint256 validators;
        try AvalancheL1Middleware(payable(l1MiddlewareAddress)).getAllOperators() returns (address[] memory _operators)
        {
            allOperators = _operators;
            for (uint256 i = 0; i < allOperators.length; i++) {
                try AvalancheL1Middleware(payable(l1MiddlewareAddress)).getActiveNodesForEpoch(
                    allOperators[i], currentEpoch
                ) returns (bytes32[] memory _activeNodeIds) {
                    validators += _activeNodeIds.length;
                } catch {
                    continue;
                }
            }
        } catch {
            allOperators = new address[](0);
            validators = 0;
        }

        address[] memory allVaults;
        try IMiddlewareVaultManager(payable(vaultManager)).getVaults(currentEpoch) returns (address[] memory _vaults) {
            allVaults = _vaults;
        } catch {
            allVaults = new address[](0);
        }

        uint256 primaryCollateralClass;
        uint256[] memory secondaryCollateralClasses;
        try AvalancheL1Middleware(payable(l1MiddlewareAddress)).getActiveCollateralClasses() returns (
            uint256 _primaryCollateralClass, uint256[] memory _secondaryCollateralClasses
        ) {
            primaryCollateralClass = _primaryCollateralClass;
            secondaryCollateralClasses = _secondaryCollateralClasses;
        } catch {
            return L1Data({
                l1: l1Address,
                l1Middleware: l1MiddlewareAddress,
                vaultManager: vaultManager,
                l1Metadata: l1Metadata,
                epochSettings: EpochSettings({
                    currentEpoch: currentEpoch,
                    epochDuration: epochDuration,
                    currentEpochStartTs: currentEpochStartTs
                }),
                operators: allOperators,
                vaults: allVaults,
                collateralClassStakes: new CollateralClassStake[](0),
                validators: 0
            });
        }

        CollateralClassStake[] memory collateralClassStakes =
            new CollateralClassStake[](secondaryCollateralClasses.length + 1);

        // Fetch tokens in the primary collateral class and its stake
        address[] memory primaryAssets;
        uint256 primaryStake;
        try AvalancheL1Middleware(payable(l1MiddlewareAddress)).getClassAssets(primaryCollateralClass) returns (
            address[] memory _assets
        ) {
            primaryAssets = _assets;
        } catch {
            primaryAssets = new address[](0);
        }
        try AvalancheL1Middleware(payable(l1MiddlewareAddress)).getTotalStake(
            currentEpoch, uint96(primaryCollateralClass)
        ) returns (uint256 stake) {
            primaryStake = stake;
        } catch {
            primaryStake = 0;
        }
        collateralClassStakes[0] = CollateralClassStake({
            collateralClass: uint96(primaryCollateralClass),
            assetsInClass: primaryAssets,
            stake: primaryStake
        });

        // Fetch tokens and stake for each secondary collateral class
        for (uint256 i = 0; i < secondaryCollateralClasses.length; i++) {
            address[] memory assetsInClass;
            uint256 stakeInClass;
            try AvalancheL1Middleware(payable(l1MiddlewareAddress)).getClassAssets(secondaryCollateralClasses[i])
            returns (address[] memory _assets) {
                assetsInClass = _assets;
            } catch {
                assetsInClass = new address[](0);
            }
            try AvalancheL1Middleware(payable(l1MiddlewareAddress)).getTotalStake(
                currentEpoch, uint96(secondaryCollateralClasses[i])
            ) returns (uint256 stake) {
                stakeInClass = stake;
            } catch {
                stakeInClass = 0;
            }
            collateralClassStakes[i + 1] = CollateralClassStake({
                collateralClass: uint96(secondaryCollateralClasses[i]),
                assetsInClass: assetsInClass,
                stake: stakeInClass
            });
        }

        return L1Data({
            l1: l1Address,
            l1Middleware: l1MiddlewareAddress,
            vaultManager: vaultManager,
            l1Metadata: l1Metadata,
            epochSettings: EpochSettings({
                currentEpoch: currentEpoch,
                epochDuration: epochDuration,
                currentEpochStartTs: currentEpochStartTs
            }),
            operators: allOperators,
            vaults: allVaults,
            collateralClassStakes: collateralClassStakes,
            validators: validators
        });
    }

    // Helper struct to pass data between functions
    struct VaultContext {
        address vault;
        address delegator;
        address[] l1s;
        address[] l1Middlewares;
    }

    // Helper function to check if a vault is delegated to an L1
    function _isVaultDelegatedToL1(
        address vault,
        address l1Middleware,
        uint48 currentEpoch
    ) private view returns (bool) {
        try AvalancheL1Middleware(payable(l1Middleware)).getVaultManager() returns (address l1VaultManager) {
            try IMiddlewareVaultManager(l1VaultManager).getVaults(currentEpoch) returns (address[] memory vaults) {
                for (uint256 i = 0; i < vaults.length; i++) {
                    if (vaults[i] == vault) {
                        return true;
                    }
                }
            } catch {
                // If getVaults reverts, consider this L1 as not having the vault
                return false;
            }
        } catch {
            // If getVaultManager reverts, consider this L1 as not having the vault
            return false;
        }
        return false;
    }

    // Helper function to check if a vault is delegating to an operator
    function _isDelegatedOperator(
        VaultContext memory context,
        address l1,
        address l1Middleware
    ) private view returns (uint256) {
        (uint256 primaryCollateralClass, uint256[] memory secondaryCollateralClasses) =
            AvalancheL1Middleware(payable(l1Middleware)).getActiveCollateralClasses();

        address[] memory operators = AvalancheL1Middleware(payable(l1Middleware)).getAllOperators();

        for (uint256 i = 0; i < operators.length; i++) {
            // Check primary asset class
            if (
                IL1RestakeDelegator(context.delegator).operatorL1Shares(
                    l1, uint96(primaryCollateralClass), operators[i]
                ) > 0
            ) {
                return 1;
            }

            // Check secondary asset classes
            for (uint256 j = 0; j < secondaryCollateralClasses.length; j++) {
                if (
                    IL1RestakeDelegator(context.delegator).operatorL1Shares(
                        l1, uint96(secondaryCollateralClasses[j]), operators[i]
                    ) > 0
                ) {
                    return 1;
                }
            }
        }
        return 0;
    }

    // Helper function to get delegated operators for an L1
    function _getDelegatedOperator(
        VaultContext memory context,
        address l1,
        address l1Middleware
    ) private view returns (address) {
        (uint256 primaryCollateralClass, uint256[] memory secondaryCollateralClasses) =
            AvalancheL1Middleware(payable(l1Middleware)).getActiveCollateralClasses();

        address[] memory operators = AvalancheL1Middleware(payable(l1Middleware)).getAllOperators();

        for (uint256 i = 0; i < operators.length; i++) {
            // Check primary asset class
            if (
                IL1RestakeDelegator(context.delegator).operatorL1Shares(
                    l1, uint96(primaryCollateralClass), operators[i]
                ) > 0
            ) {
                return operators[i];
            }

            // Check secondary asset classes
            for (uint256 j = 0; j < secondaryCollateralClasses.length; j++) {
                if (
                    IL1RestakeDelegator(context.delegator).operatorL1Shares(
                        l1, uint96(secondaryCollateralClasses[j]), operators[i]
                    ) > 0
                ) {
                    return operators[i];
                }
            }
        }
        return address(0);
    }

    function getVaultData(
        address vault
    ) external view returns (VaultData memory) {
        address collateral = IVaultTokenized(vault).collateral();
        address delegator = IVaultTokenized(vault).delegator();
        uint256 totalStake = IVaultTokenized(vault).activeStake();

        (address[] memory l1s, address[] memory l1Middlewares,) = IL1Registry(L1_REGISTRY).getAllL1s();

        VaultContext memory context =
            VaultContext({vault: vault, delegator: delegator, l1s: l1s, l1Middlewares: l1Middlewares});

        // Count delegated L1s and operators
        uint256 delegatedL1Count = 0;
        uint256 delegatedOperatorCount = 0;

        for (uint256 i = 0; i < l1Middlewares.length; i++) {
            try AvalancheL1Middleware(payable(l1Middlewares[i])).getCurrentEpoch() returns (uint48 currentEpoch) {
                if (_isVaultDelegatedToL1(vault, l1Middlewares[i], currentEpoch)) {
                    delegatedL1Count++;
                    delegatedOperatorCount += _isDelegatedOperator(context, l1s[i], l1Middlewares[i]);
                }
            } catch {
                // If getCurrentEpoch reverts, consider this L1 as not having the vault
                continue;
            }
        }

        // Initialize arrays with correct sizes
        address[] memory delegatedL1s = new address[](delegatedL1Count);
        address[] memory delegatedOperators = new address[](delegatedOperatorCount);
        uint256 l1Index = 0;
        uint256 operatorIndex = 0;

        // Fill arrays with actual data
        for (uint256 i = 0; i < l1Middlewares.length; i++) {
            try AvalancheL1Middleware(payable(l1Middlewares[i])).getCurrentEpoch() returns (uint48 currentEpoch) {
                if (_isVaultDelegatedToL1(vault, l1Middlewares[i], currentEpoch)) {
                    delegatedL1s[l1Index++] = l1s[i];

                    address operator = _getDelegatedOperator(context, l1s[i], l1Middlewares[i]);
                    if (operator != address(0)) {
                        delegatedOperators[operatorIndex++] = operator;
                    }
                }
            } catch {
                // If getCurrentEpoch reverts, consider this L1 as not having the vault
                continue;
            }
        }

        return VaultData({
            vault: vault,
            collateral: collateral,
            delegator: delegator,
            totalStake: totalStake,
            delegatedL1s: delegatedL1s,
            delegatedOperators: delegatedOperators
        });
    }

    // Helper struct to pass data between functions
    struct OperatorContext {
        address operator;
        address[] l1s;
        address[] l1Middlewares;
    }

    // Helper function to check if an operator secures an L1
    function _isOperatorSecuringL1(address operator, address l1Middleware) private view returns (bool) {
        try AvalancheL1Middleware(payable(l1Middleware)).getAllOperators() returns (address[] memory operators) {
            for (uint256 i = 0; i < operators.length; i++) {
                if (operators[i] == operator) {
                    return true;
                }
            }
        } catch {
            return false;
        }
        return false;
    }

    // Helper function to check if an operator has stake in an L1
    function _getOperatorStakeInL1(
        address operator,
        address l1Middleware,
        uint48 currentEpoch,
        uint96 primaryCollateralClass
    ) private view returns (uint256) {
        try AvalancheL1Middleware(payable(l1Middleware)).getOperatorUsedStakeCachedPerEpoch(
            currentEpoch, operator, primaryCollateralClass
        ) returns (uint256 stake) {
            return stake;
        } catch {
            return 0;
        }
    }

    // Helper function to check if an operator is trusted by a vault
    function _isOperatorTrustedByVault(
        OperatorContext memory context,
        address l1,
        address vault,
        uint96 vaultCollateralClass
    ) private view returns (bool) {
        try IL1RestakeDelegator(IVaultTokenized(vault).delegator()).operatorL1Shares(
            l1, vaultCollateralClass, context.operator
        ) returns (uint256 shares) {
            return shares > 0;
        } catch {
            return false;
        }
    }

    function getOperatorData(
        address operator
    ) external view returns (OperatorData memory) {
        (address[] memory l1s, address[] memory l1Middlewares,) = IL1Registry(L1_REGISTRY).getAllL1s();

        OperatorContext memory context = OperatorContext({operator: operator, l1s: l1s, l1Middlewares: l1Middlewares});

        // First pass: count everything
        uint256 securedL1Count = 0;
        uint256 trustedVaultCount = 0;
        uint256[] memory collateralClassStakesCountPerMiddleware = new uint256[](l1Middlewares.length);
        CollateralClassStakeMap[] memory collateralClassStakeMap = new CollateralClassStakeMap[](l1Middlewares.length);

        for (uint256 i = 0; i < l1Middlewares.length; i++) {
            try AvalancheL1Middleware(payable(l1Middlewares[i])).getCurrentEpoch() returns (uint48 currentEpoch) {
                try AvalancheL1Middleware(payable(l1Middlewares[i])).getVaultManager() returns (address vaultManager) {
                    try AvalancheL1Middleware(payable(l1Middlewares[i])).getActiveCollateralClasses() returns (
                        uint256 primaryCollateralClass, uint256[] memory secondaryCollateralClasses
                    ) {
                        // Check if operator secures this L1
                        if (_isOperatorSecuringL1(operator, l1Middlewares[i])) {
                            securedL1Count++;
                        }

                        // Check operator stake
                        uint256 operatorStake = _getOperatorStakeInL1(
                            operator, l1Middlewares[i], currentEpoch, uint96(primaryCollateralClass)
                        );
                        if (operatorStake > 0) {
                            collateralClassStakesCountPerMiddleware[i]++;
                        }
                        for (uint256 j = 0; j < secondaryCollateralClasses.length; j++) {
                            operatorStake = 0;
                            operatorStake += _getOperatorStakeInL1(
                                operator, l1Middlewares[i], currentEpoch, uint96(secondaryCollateralClasses[j])
                            );
                            if (operatorStake > 0) {
                                collateralClassStakesCountPerMiddleware[i]++;
                            }
                        }

                        // Check trusted vaults
                        try IMiddlewareVaultManager(vaultManager).getVaults(currentEpoch) returns (
                            address[] memory vaults
                        ) {
                            for (uint256 j = 0; j < vaults.length; j++) {
                                try IMiddlewareVaultManager(vaultManager).getVaultCollateralClass(vaults[j]) returns (
                                    uint96 vaultCollateralClass
                                ) {
                                    if (_isOperatorTrustedByVault(context, l1s[i], vaults[j], vaultCollateralClass)) {
                                        trustedVaultCount++;
                                        break;
                                    }
                                } catch {
                                    continue;
                                }
                            }
                        } catch {
                            continue;
                        }
                    } catch {
                        continue;
                    }
                } catch {
                    continue;
                }
            } catch {
                continue;
            }
        }

        // Initialize arrays with correct sizes
        address[] memory securedL1s = new address[](securedL1Count);
        address[] memory trustedVaults = new address[](trustedVaultCount);
        uint256 securedL1sIndex = 0;
        uint256 trustedVaultsIndex = 0;
        uint256 collateralClassStakesIndex = 0;

        // Second pass: fill arrays
        for (uint256 i = 0; i < l1Middlewares.length; i++) {
            try AvalancheL1Middleware(payable(l1Middlewares[i])).getCurrentEpoch() returns (uint48 currentEpoch) {
                CollateralClassStake[] memory collateralClassStakes =
                    new CollateralClassStake[](collateralClassStakesCountPerMiddleware[i]);
                try AvalancheL1Middleware(payable(l1Middlewares[i])).getVaultManager() returns (address vaultManager) {
                    try AvalancheL1Middleware(payable(l1Middlewares[i])).getActiveCollateralClasses() returns (
                        uint256 primaryCollateralClass, uint256[] memory secondaryCollateralClasses
                    ) {
                        // Add secured L1s
                        if (_isOperatorSecuringL1(operator, l1Middlewares[i])) {
                            securedL1s[securedL1sIndex++] = l1s[i];
                        }

                        // Add asset stakes
                        uint256 operatorStake = _getOperatorStakeInL1(
                            operator, l1Middlewares[i], currentEpoch, uint96(primaryCollateralClass)
                        );
                        if (operatorStake > 0) {
                            try AvalancheL1Middleware(payable(l1Middlewares[i])).getClassAssets(
                                uint96(primaryCollateralClass)
                            ) returns (address[] memory assets) {
                                collateralClassStakes[collateralClassStakesIndex++] = CollateralClassStake({
                                    collateralClass: uint96(primaryCollateralClass),
                                    assetsInClass: assets,
                                    stake: operatorStake
                                });
                            } catch {
                                continue;
                            }
                        }

                        for (uint256 j = 0; j < secondaryCollateralClasses.length; j++) {
                            uint256 operatorSecondaryStake = _getOperatorStakeInL1(
                                operator, l1Middlewares[i], currentEpoch, uint96(secondaryCollateralClasses[j])
                            );
                            if (operatorSecondaryStake > 0) {
                                try AvalancheL1Middleware(payable(l1Middlewares[i])).getClassAssets(
                                    uint96(secondaryCollateralClasses[j])
                                ) returns (address[] memory assets) {
                                    collateralClassStakes[collateralClassStakesIndex++] = CollateralClassStake({
                                        collateralClass: uint96(secondaryCollateralClasses[j]),
                                        assetsInClass: assets,
                                        stake: operatorSecondaryStake
                                    });
                                } catch {
                                    continue;
                                }
                            }
                        }

                        collateralClassStakeMap[i] = CollateralClassStakeMap({
                            middleware: l1Middlewares[i],
                            collateralClassStakes: collateralClassStakes
                        });

                        // Add trusted vaults
                        try IMiddlewareVaultManager(vaultManager).getVaults(currentEpoch) returns (
                            address[] memory vaults
                        ) {
                            for (uint256 j = 0; j < vaults.length; j++) {
                                try IMiddlewareVaultManager(payable(vaultManager)).getVaultCollateralClass(vaults[j])
                                returns (uint96 vaultCollateralClass) {
                                    if (
                                        _isOperatorTrustedByVault(
                                            context, l1s[i], vaults[j], uint96(vaultCollateralClass)
                                        )
                                    ) {
                                        trustedVaults[trustedVaultsIndex++] = vaults[j];
                                        break;
                                    }
                                } catch {
                                    continue;
                                }
                            }
                        } catch {
                            continue;
                        }
                    } catch {
                        continue;
                    }
                } catch {
                    continue;
                }
            } catch {
                continue;
            }
        }

        return OperatorData({
            operator: operator,
            securedL1s: securedL1s,
            trustedVaults: trustedVaults,
            collateralClassStakeMap: collateralClassStakeMap
        });
    }
}
