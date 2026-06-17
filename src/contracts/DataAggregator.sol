// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {IL1Registry} from "../interfaces/IL1Registry.sol";
import {AvalancheL1Middleware} from "../contracts/middleware/AvalancheL1Middleware.sol";
import {IMiddlewareVaultManager} from "../interfaces/middleware/IMiddlewareVaultManager.sol";
import {IVaultTokenized} from "../interfaces/vault/IVaultTokenized.sol";
import {IL1RestakeDelegator} from "../interfaces/delegator/IL1RestakeDelegator.sol";
import {ICollateralClassRegistry} from "../interfaces/middleware/ICollateralClassRegistry.sol";

/* ─────────────────────────────────────────────────────
   DOMAIN STRUCTS
   ───────────────────────────────────────────────────── */
/// @notice Epoch timing snapshot for an L1
struct EpochSettings {
    uint48 currentEpoch;
    uint48 epochDuration;
    uint48 currentEpochStartTs;
}

/// @notice Assets that belong to a collateral class
struct CollateralClassAssets {
    uint256 classId;
    address[] assets;
}

/// @notice Total stake for a collateral class (L1 scoped)
struct CollateralClassStake {
    uint256 classId;
    uint256 stake;
}

/// @notice Collateral-related data for an L1
struct CollateralData {
    uint256[] classIds; // ordered [primary, ...secondary]
    CollateralClassAssets[] assetsByClass; // one entry per classId
    CollateralClassStake[] stakesByClass; // one entry per classId
}

/// @notice Operator stake split by collateral class for a single L1
struct OperatorStakeByClass {
    uint256 classId; // collateral class id
    uint256 stakeOnL1; // operator stake in that class on the L1
    uint256 stake; // total stake in that class (L1-wide)
    uint256 usedStake; // used stake for the epoch (getOperatorUsedStakeCachedPerEpoch)
}

/// @notice Operator stakes for a single L1
struct OperatorStakeByL1 {
    address l1;
    OperatorStakeByClass[] stakesByClass;
}

/// @notice Operator stake coming from a vault (delegated)
struct OperatorStakeByVault {
    address vault;
    address collateralAsset;
    uint256 stake;
}

/// @notice Public operator-centric view returned by getOperatorData(...)
struct OperatorData {
    address operator;
    OperatorStakeByL1[] stakesByL1; // per-L1 breakdown
    OperatorStakeByVault[] stakesByVault; // cross-L1 per-vault entries
}

/// @notice Vault stake for a single L1 (class + total delegated stake)
struct VaultStakeByL1 {
    address l1;
    uint256 classId;
    uint256 stake;
}

/// @notice Per-operator stake for a vault (aggregated across L1s)
struct VaultStakeByOperator {
    address operator;
    uint256 stake;
}

/// @notice Public vault-centric view returned by getVaultData(...)
struct VaultData {
    address vault;
    address collateral; // vault.collateral()
    address delegator; // vault.delegator()
    uint256 totalStake; // vault.totalStake()
    VaultStakeByL1[] stakesByL1; // per L1 totals for this vault
    VaultStakeByOperator[] stakesByOperator; // aggregated per-operator stakes
}

/// @notice L1 stake delegated to an operator
struct L1StakeByOperator {
    address operator;
    OperatorStakeByClass[] stakesByClass;
}

/// @notice L1 stake delegated to a vault
struct L1StakeByVault {
    address vault;
    uint256 classId;
    uint256 stake;
}

/// @notice Public L1-level data returned by getL1Data(...)
struct L1Data {
    address l1;
    address middleware;
    address vaultManager;
    EpochSettings epoch;
    CollateralData collateral;
    L1StakeByOperator[] operatorSet;
    L1StakeByVault[] vaultSet;
    uint256 validatorsCount;
}

/* ─────────────────────────────────────────────────────
   MAIN VIEW CONTRACT — PUBLIC ENTRYPOINTS
   ───────────────────────────────────────────────────── */

/**
 * @title DataAggregator
 * @notice Read-only lens contract that aggregates on-chain data from L1 middleware and vault manager
 * @dev This contract is intentionally read-only and defensive: reverts in external contracts are treated
 *      as empty responses so UI consumers can display partial results rather than fail.
 */
contract DataAggregator {
    /* ─────────────────────────────────────────────────────
    INTERNAL DOMAIN STRUCTS
    ───────────────────────────────────────────────────── */

    /// @dev Lightweight L1 config used inside loaders
    struct L1Config {
        address l1;
        address middleware;
        address vaultManager;
        string metadata; // optional, only if you read it
    }

    /// @dev Raw L1 tuple as returned from registry (index-based)
    struct L1ConfigRaw {
        address l1;
        address mw;
        address vm;
    }

    /// @dev For vault → L1 registration (vault exists on this L1)
    struct VaultL1Registration {
        address l1;
        address middleware;
        address vaultManager;
        uint96 collateralClassId;
    }

    /// @dev Operator stake for a single collateral class
    struct OperatorCollateralClassStake {
        uint256 classId;
        uint256 stake;
        uint256 usedStake;
    }

    /// @dev Compact operator summary for L1-level lists
    struct OperatorL1Summary {
        address operator;
        OperatorCollateralClassStake stake;
    }

    /// @dev Vault stake for a single L1
    struct VaultL1Stake {
        address l1;
        uint96 collateralClassId;
        uint256 stake;
    }

    /// @dev Vault stake for a single operator
    struct VaultOperatorStake {
        address operator;
        uint256 stake;
    }

    /// @dev Vault summary for L1-level lists
    struct VaultSummary {
        address vault;
        address asset;
        uint96 collateralClassId;
        uint256 stake;
    }

    /// @dev Internal packing helpers used by builders (temporary)
    struct BufferPointer {
        uint256 length;
        uint256 capacity;
    }

    address public immutable L1_REGISTRY;

    /**
     * @dev Initialize with L1 registry address used to lookup L1 entry metadata.
     * @param l1Registry The registry contract address
     */
    constructor(
        address l1Registry
    ) {
        L1_REGISTRY = l1Registry;
    }

    function getOperatorData(
        address operator
    ) external view returns (OperatorData memory out) {
        (address[] memory l1s, address[] memory mws) = _loadOperatorL1s(operator);

        OperatorStakeByL1[] memory perL1 = new OperatorStakeByL1[](l1s.length);
        OperatorStakeByVault[] memory perVault; // built once at end

        // Aggregate operator-L1 data
        for (uint256 i = 0; i < l1s.length; i++) {
            address mw = mws[i];
            if (mw == address(0)) {
                perL1[i] = OperatorStakeByL1({l1: l1s[i], stakesByClass: new OperatorStakeByClass[](0)});
                continue;
            }

            uint48 epoch = _loadEpochSafely(mw);

            (uint256 p, uint256[] memory sec) = _loadCollateralClasses(mw);
            uint256 n = 1 + sec.length;

            uint256[] memory classes = new uint256[](n);
            classes[0] = p;
            for (uint256 j = 0; j < sec.length; j++) {
                classes[j + 1] = sec[j];
            }

            OperatorStakeByClass[] memory perClass = _buildOperatorPerClassStakes(mw, epoch, operator, classes);

            perL1[i] = OperatorStakeByL1({l1: l1s[i], stakesByClass: perClass});
        }

        OperatorStakeByVault[] memory vaultStakes = _buildOperatorVaultStakes(operator);

        perVault = new OperatorStakeByVault[](vaultStakes.length);
        for (uint256 i = 0; i < vaultStakes.length; i++) {
            perVault[i] = OperatorStakeByVault({
                vault: vaultStakes[i].vault,
                collateralAsset: vaultStakes[i].collateralAsset,
                stake: vaultStakes[i].stake
            });
        }

        out = OperatorData({operator: operator, stakesByL1: perL1, stakesByVault: perVault});
    }

    function getVaultData(
        address vault
    ) external view returns (VaultData memory out) {
        return _buildVaultData(vault);
    }

    function getL1Data(
        address l1
    ) external view returns (L1Data memory out) {
        L1ConfigRaw memory cfg = _loadL1Config(l1);
        if (cfg.mw == address(0)) {
            return L1Data({
                l1: l1,
                middleware: address(0),
                vaultManager: address(0),
                epoch: EpochSettings({currentEpoch: 0, epochDuration: 0, currentEpochStartTs: 0}),
                collateral: CollateralData({
                    classIds: new uint256[](0),
                    assetsByClass: new CollateralClassAssets[](0),
                    stakesByClass: new CollateralClassStake[](0)
                }),
                operatorSet: new L1StakeByOperator[](0),
                vaultSet: new L1StakeByVault[](0),
                validatorsCount: 0
            });
        }

        EpochSettings memory epoch = _loadEpochSettings(cfg.mw);

        CollateralData memory cdata = _buildCollateralClassData(cfg.mw, epoch.currentEpoch);

        CollateralData memory collateral = CollateralData({
            classIds: cdata.classIds,
            assetsByClass: cdata.assetsByClass,
            stakesByClass: cdata.stakesByClass
        });

        address[] memory ops = _loadOperatorList(cfg.mw);
        L1StakeByOperator[] memory opSummary = new L1StakeByOperator[](ops.length);

        for (uint256 i = 0; i < ops.length; i++) {
            OperatorStakeByClass[] memory stakesByClass =
                _buildOperatorPerClassStakes(cfg.mw, epoch.currentEpoch, ops[i], collateral.classIds);
            opSummary[i] = L1StakeByOperator({operator: ops[i], stakesByClass: stakesByClass});
        }

        L1StakeByVault[] memory vSummary = _buildL1Vaults(cfg.vm, epoch.currentEpoch, l1);

        uint256 validatorsCount = _loadValidatorCount(cfg.mw, epoch.currentEpoch);

        out = L1Data({
            l1: l1,
            middleware: cfg.mw,
            vaultManager: cfg.vm,
            epoch: epoch,
            collateral: collateral,
            operatorSet: opSummary,
            vaultSet: vSummary,
            validatorsCount: validatorsCount
        });
    }

    /* ─────────────────────────────────────────────────────
       L1 REGISTRY LOADERS
       ───────────────────────────────────────────────────── */

    function _loadAllL1s() internal view returns (address[] memory l1s, address[] memory mws, address[] memory vms) {
        (l1s, mws,) = IL1Registry(L1_REGISTRY).getAllL1s();
        // per L1, get the vault manager
        vms = new address[](l1s.length);
        for (uint256 i = 0; i < l1s.length; i++) {
            vms[i] = AvalancheL1Middleware(payable(mws[i])).getVaultManager();
        }
    }

    function _loadL1Config(
        address targetL1
    ) internal view returns (L1ConfigRaw memory cfg) {
        (address[] memory l1s, address[] memory mws, address[] memory vms) = _loadAllL1s();
        for (uint256 i = 0; i < l1s.length; i++) {
            if (l1s[i] == targetL1) {
                return L1ConfigRaw({l1: l1s[i], mw: mws[i], vm: vms[i]});
            }
        }
        return L1ConfigRaw({l1: targetL1, mw: address(0), vm: address(0)});
    }

    /* ─────────────────────────────────────────────────────
       EPOCH LOADERS
       ───────────────────────────────────────────────────── */

    function _loadEpochSafely(
        address mw
    ) internal view returns (uint48) {
        try AvalancheL1Middleware(payable(mw)).getCurrentEpoch() returns (uint48 e) {
            return e;
        } catch {
            return 0;
        }
    }

    function _loadEpochSettings(
        address mw
    ) internal view returns (EpochSettings memory) {
        uint48 currentEpoch = _loadEpochSafely(mw);
        uint48 epochDuration = AvalancheL1Middleware(payable(mw)).EPOCH_DURATION();
        uint48 currentEpochStartTs = AvalancheL1Middleware(payable(mw)).getEpochStartTs(currentEpoch);
        return EpochSettings({
            currentEpoch: currentEpoch,
            epochDuration: epochDuration,
            currentEpochStartTs: currentEpochStartTs
        });
    }

    /* ─────────────────────────────────────────────────────
       COLLATERAL LOADERS
       ───────────────────────────────────────────────────── */

    function _loadCollateralClasses(
        address mw
    ) internal view returns (uint256 primary, uint256[] memory secondary) {
        try AvalancheL1Middleware(payable(mw)).getActiveCollateralClasses() returns (uint256 p, uint256[] memory s) {
            return (p, s);
        } catch {
            return (0, new uint256[](0));
        }
    }

    function _loadClassAssets(address mw, uint96 classId) internal view returns (address[] memory assets) {
        try AvalancheL1Middleware(payable(mw)).getClassAssets(classId) returns (address[] memory a) {
            return a;
        } catch {
            return new address[](0);
        }
    }

    function _loadClassTotalStake(address mw, uint48 epoch, uint96 classId) internal view returns (uint256) {
        try AvalancheL1Middleware(payable(mw)).getTotalStake(epoch, classId) returns (uint256 s) {
            return s;
        } catch {
            return 0;
        }
    }

    /* ─────────────────────────────────────────────────────
       OPERATOR LOADERS
       ───────────────────────────────────────────────────── */

    function _loadOperatorList(
        address mw
    ) internal view returns (address[] memory) {
        try AvalancheL1Middleware(payable(mw)).getAllOperators() returns (address[] memory ops) {
            return ops;
        } catch {
            return new address[](0);
        }
    }

    function _loadOperatorStake(
        address mw,
        uint48 epoch,
        address operator,
        uint96 classId
    ) internal view returns (uint256) {
        try AvalancheL1Middleware(payable(mw)).getOperatorStake(operator, epoch, classId) returns (uint256 s) {
            return s;
        } catch {
            return 0;
        }
    }

    function _loadOperatorUsedStake(
        address mw,
        uint48 epoch,
        address operator,
        uint96 classId
    ) internal view returns (uint256) {
        try AvalancheL1Middleware(payable(mw)).getOperatorUsedStakeCachedPerEpoch(epoch, operator, classId) returns (
            uint256 s
        ) {
            return s;
        } catch {
            return 0;
        }
    }

    function _loadValidatorCount(address mw, uint48 epoch) internal view returns (uint256 count) {
        // get all operators on the L1
        address[] memory ops = _loadOperatorList(mw);
        // for each operator, get the number of validators
        for (uint256 i = 0; i < ops.length; i++) {
            try AvalancheL1Middleware(payable(mw)).getActiveNodesForEpoch(ops[i], epoch) returns (
                bytes32[] memory validators
            ) {
                count += validators.length;
            } catch {
                continue;
            }
        }
    }

    function _loadOperatorL1s(
        address operator
    ) internal view returns (address[] memory operatorL1s, address[] memory operatorMws) {
        (address[] memory l1s, address[] memory mws,) = _loadAllL1s();
        uint256 count = 0;
        // First, count how many L1s the operator is present on
        for (uint256 i = 0; i < l1s.length; i++) {
            address mw = mws[i];
            if (mw == address(0)) {
                continue;
            }
            address[] memory ops = _loadOperatorList(mw);
            for (uint256 j = 0; j < ops.length; j++) {
                if (ops[j] == operator) {
                    count++;
                    break;
                }
            }
        }
        // Allocate result array
        operatorL1s = new address[](count);
        operatorMws = new address[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < l1s.length; i++) {
            address mw = mws[i];
            if (mw == address(0)) {
                continue;
            }
            address[] memory ops = _loadOperatorList(mw);
            for (uint256 j = 0; j < ops.length; j++) {
                if (ops[j] == operator) {
                    operatorL1s[idx] = l1s[i];
                    operatorMws[idx] = mw;
                    idx++;
                    break;
                }
            }
        }
        return (operatorL1s, operatorMws);
    }

    /* ─────────────────────────────────────────────────────
       VAULT LOADERS
       ───────────────────────────────────────────────────── */

    function _loadVaults(address vm, uint48 epoch) internal view returns (address[] memory) {
        try IMiddlewareVaultManager(vm).getVaults(epoch) returns (address[] memory v) {
            return v;
        } catch {
            return new address[](0);
        }
    }

    function _loadVaultCollateralClass(address vm, address vault) internal view returns (uint96, bool) {
        try IMiddlewareVaultManager(vm).getVaultCollateralClass(vault) returns (uint96 classId) {
            return (classId, true);
        } catch {
            return (0, false);
        }
    }

    function _loadVaultDelegator(
        address vault
    ) internal view returns (address) {
        try IVaultTokenized(vault).delegator() returns (address d) {
            return d;
        } catch {
            return address(0);
        }
    }

    function _loadVaultCollateralToken(
        address vault
    ) internal view returns (address) {
        try IVaultTokenized(vault).collateral() returns (address a) {
            return a;
        } catch {
            return address(0);
        }
    }

    function _loadVaultTotalStake(
        address vault
    ) internal view returns (uint256) {
        try IVaultTokenized(vault).totalStake() returns (uint256 s) {
            return s;
        } catch {
            return 0;
        }
    }

    function _loadVaultL1Operators(address vault, address l1) internal view returns (address[] memory) {
        // Resolve L1 config (middleware + vault manager)
        L1ConfigRaw memory cfg = _loadL1Config(l1);
        if (cfg.mw == address(0) || cfg.vm == address(0)) {
            return new address[](0);
        }
        // Determine the vault's collateral class on this L1
        (uint96 classId, bool ok) = _loadVaultCollateralClass(cfg.vm, vault);
        if (!ok) {
            return new address[](0);
        }
        // Fetch the vault's delegator
        address delegator = _loadVaultDelegator(vault);
        if (delegator == address(0)) {
            return new address[](0);
        }
        // Load all operators on this L1, then filter by those the vault delegates to
        address[] memory ops = _loadOperatorList(cfg.mw);
        // First pass: collect matching operators into a temporary buffer
        address[] memory buf = new address[](ops.length);
        uint256 count = 0;
        for (uint256 i = 0; i < ops.length; i++) {
            if (_loadDelegatorStake(delegator, l1, classId, ops[i]) > 0) {
                buf[count++] = ops[i];
            }
        }
        // Shrink to exact size
        address[] memory filtered = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            filtered[i] = buf[i];
        }
        return filtered;
    }

    /* ─────────────────────────────────────────────────────
       DELEGATOR LOADERS
       ───────────────────────────────────────────────────── */

    function _loadDelegatorStake(
        address delegator,
        address l1,
        uint96 classId,
        address operator
    ) internal view returns (uint256) {
        try IL1RestakeDelegator(delegator).stake(l1, classId, operator) returns (uint256 s) {
            return s;
        } catch {
            return 0;
        }
    }

    /* ─────────────────────────────────────────────────────
       L1 BUILDERS
       ───────────────────────────────────────────────────── */

    function _buildL1Vaults(address vm, uint48 epoch, address l1) internal view returns (L1StakeByVault[] memory out) {
        address[] memory vaults = _loadVaults(vm, epoch);
        out = new L1StakeByVault[](vaults.length);

        for (uint256 i = 0; i < vaults.length; i++) {
            (uint96 classId, bool ok) = _loadVaultCollateralClass(vm, vaults[i]);
            address[] memory ops = _loadVaultL1Operators(vaults[i], l1);

            uint256 total = 0;
            if (ok) {
                address delegator = _loadVaultDelegator(vaults[i]);
                if (delegator != address(0)) {
                    address[] memory _ops = ops;
                    for (uint256 j = 0; j < _ops.length; j++) {
                        total += _loadDelegatorStake(delegator, l1, classId, _ops[j]);
                    }
                }
            }

            out[i] = L1StakeByVault({vault: vaults[i], classId: classId, stake: total});
        }
    }

    /* ─────────────────────────────────────────────────────
       OPERATOR BUILDERS
       ───────────────────────────────────────────────────── */

    function _buildOperatorPerClassStakes(
        address mw,
        uint48 epoch,
        address operator,
        uint256[] memory classes
    ) internal view returns (OperatorStakeByClass[] memory out) {
        // Prepare a temp array to collect valid entries
        OperatorStakeByClass[] memory temp = new OperatorStakeByClass[](classes.length);
        uint256 count = 0;

        for (uint256 i = 0; i < classes.length; i++) {
            uint96 c = uint96(classes[i]);

            uint256 l1Stake = _loadClassTotalStake(mw, epoch, c);
            uint256 totalStake = _loadOperatorStake(mw, epoch, operator, c);
            uint256 usedStake = _loadOperatorUsedStake(mw, epoch, operator, c);

            // Include only if totalStake or usedStake is nonzero
            if (totalStake != 0 || usedStake != 0) {
                temp[count++] = OperatorStakeByClass({
                    classId: classes[i],
                    stakeOnL1: l1Stake,
                    stake: totalStake,
                    usedStake: usedStake
                });
            }
        }

        // Copy to output array of correct length
        out = new OperatorStakeByClass[](count);
        for (uint256 j = 0; j < count; j++) {
            out[j] = temp[j];
        }
    }

    function _buildOperatorVaultStakes(
        address operator
    ) internal view returns (OperatorStakeByVault[] memory out) {
        (address[] memory l1s, address[] memory mws, address[] memory vms) = _loadAllL1s();

        // 1) compute upper bound of possible vault matches
        uint256 upper = 0;
        for (uint256 i = 0; i < vms.length; i++) {
            address vm = vms[i];
            if (vm == address(0)) continue;

            uint48 epoch = _loadEpochSafely(mws[i]);
            address[] memory vaults = _loadVaults(vm, epoch);
            upper += vaults.length;
        }

        // Merge buffer
        out = new OperatorStakeByVault[](upper);
        uint256 count = 0;

        // 2) iterate L1s → vaults → delegator → stake(operator)
        for (uint256 i = 0; i < vms.length; i++) {
            address vm = vms[i];
            address mw = mws[i];
            if (vm == address(0)) continue;

            uint48 epoch = _loadEpochSafely(mw);
            address[] memory vaults = _loadVaults(vm, epoch);

            for (uint256 j = 0; j < vaults.length; j++) {
                address vault = vaults[j];
                address delegator = _loadVaultDelegator(vault);

                if (delegator == address(0)) continue;

                // load class
                (uint96 c, bool ok) = _loadVaultCollateralClass(vm, vault);
                if (!ok) continue;

                uint256 stake = _loadDelegatorStake(delegator, l1s[i], c, operator);
                if (stake == 0) continue;

                out[count++] = OperatorStakeByVault({
                    vault: vault,
                    collateralAsset: _loadVaultCollateralToken(vault),
                    stake: stake
                });
            }
        }
        // Trim to the exact number of matches
        OperatorStakeByVault[] memory trimmed = new OperatorStakeByVault[](count);
        for (uint256 k = 0; k < count; k++) {
            trimmed[k] = out[k];
        }
        return trimmed;
    }

    /* ─────────────────────────────────────────────────────
       COLLATERAL BUILDERS
       ───────────────────────────────────────────────────── */

    function _buildCollateralClassAssets(
        address mw,
        uint256[] memory classes
    ) internal view returns (CollateralClassAssets[] memory out) {
        out = new CollateralClassAssets[](classes.length);

        for (uint256 i = 0; i < classes.length; i++) {
            uint96 cid = uint96(classes[i]);
            address[] memory assets = _loadClassAssets(mw, cid);

            out[i] = CollateralClassAssets({classId: classes[i], assets: assets});
        }
    }

    function _buildCollateralClassStakes(
        address mw,
        uint48 epoch,
        uint256[] memory classes
    ) internal view returns (CollateralClassStake[] memory out) {
        out = new CollateralClassStake[](classes.length);
        for (uint256 i = 0; i < classes.length; i++) {
            uint96 cid = uint96(classes[i]);
            uint256 s = _loadClassTotalStake(mw, epoch, cid);
            out[i] = CollateralClassStake({classId: classes[i], stake: s});
        }
    }

    function _buildCollateralClassData(address mw, uint48 epoch) internal view returns (CollateralData memory out) {
        (uint256 p, uint256[] memory sec) = _loadCollateralClasses(mw);
        uint256 n = 1 + sec.length;

        uint256[] memory classes = new uint256[](n);
        classes[0] = p;
        for (uint256 i = 0; i < sec.length; i++) {
            classes[i + 1] = sec[i];
        }

        CollateralClassAssets[] memory assets = _buildCollateralClassAssets(mw, classes);
        CollateralClassStake[] memory stakes = _buildCollateralClassStakes(mw, epoch, classes);

        out = CollateralData({classIds: classes, assetsByClass: assets, stakesByClass: stakes});
    }

    /* ─────────────────────────────────────────────────────
       VAULT BUILDERS
       ───────────────────────────────────────────────────── */

    function _buildVaultData(
        address vault
    ) internal view returns (VaultData memory out) {
        address collateral = _loadVaultCollateralToken(vault);
        address delegator = _loadVaultDelegator(vault);
        uint256 totalStake = _loadVaultTotalStake(vault);

        VaultStakeByL1[] memory perL1 = _buildVaultL1Stakes(vault, delegator);
        VaultStakeByOperator[] memory perOp = _buildVaultOperatorStakes(vault, delegator);

        out = VaultData({
            vault: vault,
            collateral: collateral,
            delegator: delegator,
            totalStake: totalStake,
            stakesByL1: perL1,
            stakesByOperator: perOp
        });
    }

    function _buildVaultL1Stakes(
        address vault,
        address delegator
    ) internal view returns (VaultStakeByL1[] memory out) {
        if (delegator == address(0)) return new VaultStakeByL1[](0);

        (address[] memory l1s, address[] memory mws, address[] memory vms) = _loadAllL1s();
        uint256 n = l1s.length;

        // Use a temporary buffer for results
        VaultStakeByL1[] memory temp = new VaultStakeByL1[](n);
        uint256 count = 0;

        for (uint256 i = 0; i < n; i++) {
            address vm = vms[i];
            if (vm == address(0)) {
                continue;
            }

            (uint96 classId, bool ok) = _loadVaultCollateralClass(vm, vault);
            if (!ok) {
                continue;
            }

            // sum operator stakes on this L1
            uint256 total;
            address[] memory ops = _loadOperatorList(mws[i]);
            for (uint256 j = 0; j < ops.length; j++) {
                total += _loadDelegatorStake(delegator, l1s[i], classId, ops[j]);
            }

            if (total > 0) {
                temp[count] = VaultStakeByL1({l1: l1s[i], classId: classId, stake: total});
                count++;
            }
        }

        // Allocate output array with only nonzero stakes
        out = new VaultStakeByL1[](count);
        for (uint256 i = 0; i < count; i++) {
            out[i] = temp[i];
        }
    }

    function _buildVaultOperatorStakes(
        address vault,
        address delegator
    ) internal view returns (VaultStakeByOperator[] memory out) {
        if (delegator == address(0)) return new VaultStakeByOperator[](0);

        (address[] memory l1s, address[] memory mws, address[] memory vms) = _loadAllL1s();

        // temporary buffers
        uint256 maxOps = 0;
        for (uint256 i = 0; i < mws.length; i++) {
            maxOps += _loadOperatorList(mws[i]).length;
        }

        address[] memory opsBuf = new address[](maxOps);
        uint256[] memory stakeBuf = new uint256[](maxOps);
        uint256 count = 0;

        for (uint256 i = 0; i < l1s.length; i++) {
            address mw = mws[i];
            address vm = vms[i];
            if (vm == address(0)) continue;

            (uint96 classId, bool ok) = _loadVaultCollateralClass(vm, vault);
            if (!ok) continue;

            address[] memory ops = _loadOperatorList(mw);
            for (uint256 j = 0; j < ops.length; j++) {
                uint256 s = _loadDelegatorStake(delegator, l1s[i], classId, ops[j]);
                if (s == 0) continue;

                // merge
                bool found = false;
                for (uint256 k = 0; k < count; k++) {
                    if (opsBuf[k] == ops[j]) {
                        stakeBuf[k] += s;
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    opsBuf[count] = ops[j];
                    stakeBuf[count] = s;
                    count++;
                }
            }
        }

        out = new VaultStakeByOperator[](count);
        for (uint256 i = 0; i < count; i++) {
            out[i] = VaultStakeByOperator({operator: opsBuf[i], stake: stakeBuf[i]});
        }
    }
}
