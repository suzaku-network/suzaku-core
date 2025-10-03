# Post-Audit Updates

Analysis of changes from Cyfrin Audit to current implementation in `src/` (excluding defaultCollateral subfolder).

**Commit Range:**
- **From:** [`7381169`](https://github.com/suzaku-network/suzaku-core/commit/7381169) (Cyfrin Audit baseline)
- **To:** [`837da30`](https://github.com/suzaku-network/suzaku-core/commit/837da30) (Current implementation)
- **View Full Diff:** [`7381169...837da30`](https://github.com/suzaku-network/suzaku-core/compare/7381169...837da30)

## Index

1. [Key & Breaking Changes](#key--breaking-changes)
2. [AvalancheL1Middleware.sol Changes](#avalanchel1middlewaresol-changes)
3. [CollateralClassRegistry.sol Changes (was AssetClassRegistry.sol)](#collateralclassregistrysol-changes-was-assetclassregistrysol)
4. [MiddlewareVaultManager.sol Changes](#middlewarevaultmanagersol-changes)
5. [New Contracts](#new-contracts)
6. [Rewards.sol Changes](#rewardssol-changes)
7. [UptimeTracker.sol Changes](#uptimetrackersol-changes)
8. [L1Registry.sol Changes](#l1registrysol-changes)
9. [Test Architecture Refactor](#test-architecture-refactor)
10. [Rename Map](#rename-map-old--new)

## Key & Breaking Changes

1. **Version alignment** - Middleware targets `BalancerValidatorManager` v2 upgraded to support [Validator Manager v2.1.0](https://github.com/ava-labs/icm-contracts/tree/validator-manager-v2.1.0) and introducing [ISecurityModule](https://github.com/suzaku-network/suzaku-contracts-library/blob/main/src/interfaces/ValidatorManager/ISecurityModule.sol) interface adoption
2. **Asset → Collateral naming** - All external calls must update references
3. **Role-based access control** - Replaced `onlyOwner` with AccessControl roles (must grant before use)
4. **Validator API changes** - New `initiate*` methods
5. **`complete*` functions are now permissionless** - Anyone can call them (returns validation IDs)
6. **Validator registration API changed** - Direct parameters instead of struct input
7. **Node ID → Validation ID** - Lookup via `getNodeValidationID` instead of `registeredValidators`
8. **ERC20 decimals validation** - All assets in a collateral class must have the same number of decimals
9. **Vault share calculation** - Now based on actual delegations not cached stakes
10. **Rewards distribution** - New safeguards: underflow protection, funding checks, middleware epoch sources
11. **Registry changes** - L1Registry tracks `BalancerValidatorManager`s (not raw `ValidatorManager`s)
12. **Private mappings** - `validationIdToOperator` and `operatorStakeCache` are now private
13. **Test architecture** - Real deployments replace mocks with a multi-actors / roles model

## AvalancheL1Middleware.sol Changes

**Architecture & Interface Changes:**
- Middleware now targets BalancerValidatorManager v0.1.0 upgraded to support Validator Manager v2.1.0. Updates include the `initiate*/complete*` API set, `getNodeValidationID(...)`, and `Validator.{startTime,endTime}`.
- Now implements `ISecurityModule` interface and adds ERC-165 `supportsInterface` override.
- Complete functions (`completeValidatorRegistration`, `completeValidatorRemoval`, `completeValidatorWeightUpdate`) are permissionless and return values per `ISecurityModule`.
- Added `AccessControl` inheritance (via `CollateralClassRegistry`).
- New roles: `DEFAULT_ADMIN_ROLE`, `OPERATORS_MANAGER_ROLE`, `COLLATERAL_CLASS_MANAGER_ROLE`.
- All admin functions now use role-based permissions instead of owner-only:
  - `setVaultManager` → `onlyRole(DEFAULT_ADMIN_ROLE)` (emits previous and new addresses).
  - Operator admin (`register/enable/disable/removeOperator`) → `onlyRole(OPERATORS_MANAGER_ROLE)` and require opt-in to `BALANCER`.
  - Collateral class admin (activate/deactivate/remove, add/remove assets) → `onlyRole(COLLATERAL_CLASS_MANAGER_ROLE)`.

**API & Function Changes:**
- **Validator Registration**: Old: `initializeValidatorRegistration(ValidatorRegistrationInput struct, weight)` → New: `initiateValidatorRegistration(nodeKey, blsKey, remainingBalanceOwner, disableOwner, weight)` (no expiry param).
- **Complete Functions**: 
  - `completeValidatorRegistration` and `completeValidatorRemoval` return `validationID`.
  - `completeValidatorWeightUpdate` returns `(vid, nonce)`, updates caches and unlocks stake deltas.
- **Operator Management**: 
  - Enable operator now validates operator exists in registry before enabling.
  - Checks operator opt-in status to balancer.
  - Management functions require operators to be opted into the balancer.
- `setVaultManager` now emits both previous and new addresses.
- `getActiveNodesForEpoch` visibility widened to `public`.

**Gas Optimizations & Code Improvements:**
- **Modifier → Function Pattern**: All modifiers converted to private functions to reduce bytecode size and gas costs.
- **Error Consolidation**: 
- Added node stake caching system with `lastGlobalNodeStakeUpdateEpoch` tracking and manual epoch update capabilities via `manualProcessNodeStakeCache`. This serves for potential gas issues when updating cache.
- Internal functions added: `_initializeEndValidationAndFlag`, `_calcAndCacheNodeStakeForOperatorAtEpoch`, `_processSingleEpochNodeStakeCacheUpdate`.
  - Simplified error messages by removing parameter details.
  - Grouped similar errors into common types.
- Added `unchecked` blocks in loops for gas optimization.
- Added helper functions: `_vid(nodeId)`, `_nodeKey(nodeId)` for cleaner code.
- `validationIdToOperator` mapping made private.
- `operatorStakeCache` mapping made private.
- Stake decimals normalization removed from operator stake calculation (now handled at collateral class level).

## CollateralClassRegistry.sol Changes (ex AssetClassRegistry.sol)

**Structure Changes:**
- Added `AccessControl` inheritance
- New role: `COLLATERAL_CLASS_MANAGER_ROLE`
- Added `unitDecimals` field to CollateralClass struct

**ERC20 Decimals Normalization (NEW):**
- Stores decimals for each collateral class in `unitDecimals` field
- Validates all assets in a class have same decimals:
  ```solidity
  uint8 dec = IERC20Metadata(asset).decimals();
  if (cls.assets.length() == 0) {
      cls.unitDecimals = dec;
  } else if (dec != cls.unitDecimals) {
      revert CollateralClassRegistry__AssetDecimalsMismatch(cls.unitDecimals, dec);
  }
  ```
- New error `CollateralClassRegistry__AssetDecimalsMismatch` prevents mixing assets with different decimals

**Access Control:**
- All functions use `onlyRole(COLLATERAL_CLASS_MANAGER_ROLE)` instead of `onlyOwner`

## MiddlewareVaultManager.sol Changes

**Access Control:**
- Added `AccessControl` inheritance
- New role: `VAULTS_MANAGER_ROLE`
- All functions: `onlyOwner` → `onlyRole(VAULTS_MANAGER_ROLE)`
- Constructor grants `DEFAULT_ADMIN_ROLE` and `VAULTS_MANAGER_ROLE` to the owner

**Function Changes:**
- Internal `_setVaultMaxL1Limit` no longer has `onlyOwner` modifier (already protected by external functions)
- All vault management functions (`registerVault`, `updateVaultMaxL1Limit`, `removeVault`) now use role-based access
- Vault validation uses middleware's collateral class checks

## New Contracts
- `Factory.sol` - Factory pattern
- `DefaultCollateral.sol` - Default collateral implementation
- `DefaultCollateralFactory.sol` - Factory for default collateral
- `Permit2Lib.sol` - Permit2 integration

## Rewards.sol Changes

**Vault Share Calculation Fix:**
- Added `_totalDelegatedToOperator()` helper to calculate actual delegated amounts from all vaults
- Previous calculation used cached operator stakes which could be incorrect
- New approach sums vault delegations directly for accurate share distribution

**Distribution Safety Improvements:**
- **Underflow Protection**: Clamps total shares to 100% to prevent underflow in undistributed rewards calculation
```solidity
uint256 usedShares = totalDistributedShares > BASIS_POINTS_DENOMINATOR
    ? BASIS_POINTS_DENOMINATOR
    : totalDistributedShares;
```
- **Sweep Optimization**: Mark `_undistributedClaimed` before transfer to prevent reentrancy
- **Funding Guard**: Distribution reverts if epoch not funded while operators exist

**Epoch Sources:**
- All epoch/time calculations now sourced from middleware for consistency
- Removes dependency on separate epoch tracking

**Out-of-Gas Protection:**
- Added `MAX_EPOCHS_PER_CLAIM` constant (64) to prevent out-of-gas on long histories
- Claim functions (`claimRewards`, `claimOperatorFee`, `claimCuratorFee`) now process at most 64 epochs per call
- Users with long backlogs can call claim functions multiple times to process all epochs

## UptimeTracker.sol Changes

**Epoch Validation (NEW):**
- Added validation to prevent processing uptime for epochs before validator start
```solidity
if (currentEpoch < lastUptimeEpoch) {
    revert UptimeBeforeStart(validationID, lastUptimeEpoch, currentEpoch);
}
```

**Integration Updates:**
- Uses middleware's balancer for validator manager access
- Updated to use new validator manager API for node to validation ID lookups  
- Imports validator types from new interface location

## L1Registry.sol Changes

**Conceptual Changes:**
- Now tracks balancers (not raw validator managers)
- Updated comments and documentation to reflect balancer-centric architecture

**Gas Optimizations:**
- Caches `registerFee` in local variable to avoid multiple SLOADs
- Improved fee handling: refunds excess before forwarding exact fee amount
- Tracks failed fee transfers in `unclaimedFees` for later recovery

**Code Quality:**
- Fixed variable shadowing in `validateL1Middleware()` by using local `_middleware`
- Maintains consistency with balancer terminology throughout

## Test Architecture Refactor

Major refactor to move from mock-heavy unit tests to realistic integration tests using the real ValidatorManager/Balancer stack and shared test bases.

- **Scale**: 34 files changed; ~+6.9k insertions / -3.1k deletions (net +3.8k).

- **Architecture**:
  - Middleware tests now use a real Balancer/ValidatorManager via `DeployBalancerValidatorManager` from `suzaku-contracts-library`.
  - Introduced shared bases for different tests:
    - `MiddlewareTestBase`: provisions real middleware, vault manager, roles.
    - `UptimeTrackerTestBase`: extends Middleware base and wires `UptimeTracker` with real middleware.
  - Role-based actors replace single-owner tests: `protocolOwner`, `l1Owner`, curator owners, multiple operator accounts.

- **Key integrations**:
  - Imports migrated `@avalabs/teleporter` → `@avalabs/icm-contracts` with real interfaces (`IACP99Manager`, etc.).
  - New end-to-end suites:
    - `RewardsIntegrationTest.t.sol` (~2.4k LOC): multi-collateral, delegation, distribution.
    - `MiddlewareCollateralDecimalsTest.t.sol` (~1.0k LOC): complete system bring-up using production scripts, testing collateral decimals handling scenarios.
  - Audit-specific test suites (addressing identified vulnerabilities):
    - `AvalancheL1MiddlewareStakeLockingTest.t.sol`: tests stake-locking mechanisms in `addNode()` to prevent rewards manipulation.
    - `AvalancheL1MiddlewareNodeRemovalTest.t.sol`: tests proper node removal to prevent phantom/irremovable nodes.
    - `RewardsSharesOverflowTest.t.sol`: tests correct sum-of-shares calculation to prevent overflow issues.
  - Deployment scripts provision Balancer/Validator Manager v2.1.0 to match middleware APIs.

- **Mocks cleanup**:
  - Removed: `MockAssetClassRegistry`, most `MockBalancerValidatorManager` usage.
  - Enhanced: `MockWarpMessenger` (push-style), `MockUptimeTracker` for rewards, new token mocks (`DAILikeToken`, fee-on-transfer, permit).

- **Terminology updates** (tests):
  - `assetClassId` → `collateralClassId`; `AssetClassRegistry` → `CollateralClassRegistry`.
  - `l1ValidatorManager` → `balancer` across setup and assertions.

- **Benefits**:
  - Tests exercise close to real validator lifecycle (registration, weight update, removal) and cross-chain message patterns.
  - Validates production deployment scripts and ownership transfer flows.
  - Shared infrastructure improves consistency and reuse across suites.

- **Migration impact for tests**:
  - Move setups from mocks to real deployments provided by library scripts.
  - Adopt multi-role actor model; update permissions/role grants in fixtures.
  - Update names and APIs per main codebase renames (collateral classes, BALANCER, initiate/complete patterns).
  - Expect longer setup; ensure isolation by fresh deployments per test or suite.

## Rename Map (old → new)
**Middleware**:
- `L1_VALIDATOR_MANAGER` → `BALANCER`
- `L1_VALIDATOR_MANAGER()` → `BALANCER()`
- `getActiveAssetClasses` → `getActiveCollateralClasses`
- `isActiveAssetClass` → `isActiveCollateralClass`
- `activateSecondaryAssetClass` → `activateSecondaryCollateralClass`
- `deactivateSecondaryAssetClass` → `deactivateSecondaryCollateralClass`
- `removeAssetClass` → `removeCollateralClass`
 - `secondaryAssetClasses` → `secondaryCollateralClasses`
 - `AvalancheL1MiddlewareSettings.l1ValidatorManager` → `AvalancheL1MiddlewareSettings.balancer`
 - `BalancerValidatorManager` (type) → `IBalancerValidatorManager`
 - `IValidatorManager` (import) → `IACP99Manager` (import)
 - `updateStakeCache` (modifier) → `_updateStakeCache()`
 - `onlyDuringFinalWindowOfEpoch` (modifier) → `_onlyDuringFinalWindowOfEpoch()`
 - `onlyRegisteredOperatorNode` (modifier) → `_onlyRegisteredOperatorNode()`
 - `updateGlobalNodeStakeOncePerEpoch` (modifier) → `_updateGlobalNodeStakeOncePerEpoch()`
 - `completeStakeUpdate(bytes32 nodeId, uint32 messageIndex)` → `completeValidatorWeightUpdate(uint32 messageIndex)`
 - `completeValidatorRegistration(address operator, bytes32 nodeId, uint32 messageIndex)` → `completeValidatorRegistration(uint32 messageIndex)`
 - `AvalancheL1Middleware__ActiveSecondaryAssetClass` → `AvalancheL1Middleware__ActiveSecondaryCollateralClass`
 - `AvalancheL1Middleware__InvalidUpdateWindow` → `AvalancheL1Middleware__InvalidWindow`
 - `AvalancheL1Middleware__SlashingWindowTooShort` → `AvalancheL1Middleware__InvalidWindow`
 - `AvalancheL1Middleware__StakeTooLow` / `AvalancheL1Middleware__StakeTooHigh` → `AvalancheL1Middleware__InvalidStakeAmount`
 - `AvalancheL1Middleware__NotEnoughFreeStake` → `AvalancheL1Middleware__InsufficientStake`
 - `AvalancheL1Middleware__NodePendingRemoval` / `AvalancheL1Middleware__NodePendingUpdate` → `AvalancheL1Middleware__NodePending`
 - `AvalancheL1Middleware__NoMeaningfulUpdatesAvailable` → `AvalancheL1Middleware__RebalanceNotRequired`
 - `AvalancheL1Middleware__LimitStakeTooLow` → `AvalancheL1Middleware__InvalidStakeAmount`
 - `AvalancheL1Middleware__ZeroAddress(string)` → `AvalancheL1Middleware__ZeroAddress()`
- `_isActiveAssetClass` → `_isActiveCollateralClass`
- `_isUsedAssetClass` → `_isUsedCollateralClass`
- `_isUsedAsset` → `_isUsedAsset` (parameter change only)
- `_requireMinSecondaryAssetClasses` → `_requireMinSecondaryCollateralClasses`
- `AvalancheL1Middleware__InvalidScaleFactor` → removed
- `AvalancheL1Middleware__AlreadyRebalanced` → removed (consolidated to RebalanceNotRequired)
- `AvalancheL1Middleware__ManualEpochUpdateRequired(epochsPending, MAX)` → `AvalancheL1Middleware__ManualEpochUpdateRequired(epochsPending)`
- `primaryAsset*` parameters → `primaryCollateral*`
- `primaryAssetWeightScaleFactor` → `primaryCollateralWeightScaleFactor`
- `operatorStakeCache` visibility → private
- `lastGlobalNodeStakeUpdateEpoch` → tracked for node stake updates

**Registry**:
- `l1Middleware` (mapping/var) → `middleware`
- `l1Middleware_` (parameter in `registerL1` and `setL1Middleware`) → `middleware_`
- `vmOwner` (local variable) → `balancerOwner`
- `l1Middlewares` (local array in `getAllL1s`) → `middlewares`

**General**:
- `l1Middleware` (fields/params across contracts like Rewards/UptimeTracker) → `middleware`

**Classes Registry**:
- `AssetClassRegistry` → `CollateralClassRegistry`
- `IAssetClassRegistry` → `ICollateralClassRegistry`
- `AssetClass` (struct) → `CollateralClass`
- `assetClassIds` → `collateralClassIds`
- `assetClasses` → `collateralClasses`
- `assetClassId` (parameter) → `collateralClassId`
- `assetClassIDs` (local array) → `collateralClassIDs`
- `addAssetClass` → `addCollateralClass`
- `_addAssetClass` → `_addCollateralClass`
- `removeAssetClass` → `removeCollateralClass`
- `_removeAssetClass` → `_removeCollateralClass`
- `getAssetClassIds` → `getCollateralClassIds`
- `isActiveAssetClass` → `isActiveCollateralClass`
- `activateSecondaryAssetClass` → `activateSecondaryCollateralClass`
- `deactivateSecondaryAssetClass` → `deactivateSecondaryCollateralClass`
- `AssetClassAdded` (event) → `CollateralClassAdded`
- `AssetClassRemoved` (event) → `CollateralClassRemoved`
- `AssetClassRegistry__AssetClassNotFound` → `CollateralClassRegistry__CollateralClassNotFound`
- `AssetClassRegistry__AssetClassAlreadyExists` → `CollateralClassRegistry__CollateralClassAlreadyExists`
- `AssetClassRegistry__AssetIsPrimaryAssetClass` → `CollateralClassRegistry__AssetIsPrimaryCollateralClass`
- `AssetClassRegistry__AssetsStillExist` → `CollateralClassRegistry__AssetsStillExist`
- `AssetClassRegistry__InvalidStakingRequirements` → `CollateralClassRegistry__InvalidStakingRequirements`
- `AssetClassRegistry__InvalidAsset` → `CollateralClassRegistry__InvalidAsset`
- `AssetClassRegistry__AssetAlreadyRegistered` → `CollateralClassRegistry__AssetAlreadyRegistered`
- `AssetClassRegistry__AssetNotFound` → `CollateralClassRegistry__AssetNotFound`
- `CollateralClassRegistry__AssetDecimalsMismatch` → new error added
- `onlyOwner` (modifier) → `onlyRole(COLLATERAL_CLASS_MANAGER_ROLE)`
- `addAssetToClass` → keeps same name but changes access control
- `removeAssetFromClass` → keeps same name but changes access control
- `getClassAssets` → keeps same name
- `getClassStakingRequirements` → keeps same name
- `isAssetInClass` → keeps same name
- `_addAssetToClass` → keeps same name but adds decimals validation
- `_removeAssetFromClass` → keeps same name

**Rewards**:
- `l1Middleware` → `middleware`
- `l1Middleware_` (parameter) → `middleware_`
- `rewardsSharePerAssetClass` → `rewardsSharePerCollateralClass`
- `setRewardsShareForAssetClass` → `setRewardsShareForCollateralClass`
- `operatorBeneficiariesSharesPerAssetClass` → `operatorBeneficiariesSharesPerCollateralClass`
- `_totalAssetClassShares` → `_totalCollateralClassShares`
- `AssetClassSharesExceed100` (error) → `CollateralClassSharesExceed100`
- `assetClass` (parameters/variables) → `collateralClass`
- `assetClasses` → `collateralClasses`
- `assetClassShare` → `collateralClassShare`
- `vaultAssetClass` → `vaultCollateralClass`
- `operatorAssetClassShare` → `operatorCollateralClassShare`
- `L1_VALIDATOR_MANAGER()` → `BALANCER()`

**Vault manager**:
- `vaultToAssetClass` → `vaultToCollateralClass`
- `getVaultAssetClass` → `getVaultCollateralClass`
- `assetClassId` (parameter) → `collateralClassId`
- `onlyOwner` → `onlyRole(VAULTS_MANAGER_ROLE)`
- `MiddlewareVaultManager__WrongVaultAssetClass` → `MiddlewareVaultManager__WrongVaultCollateralClass`
- `isActiveAssetClass` → `isActiveCollateralClass`
- `IAvalancheL1Middleware.AvalancheL1Middleware__AssetClassNotActive` → `IAvalancheL1Middleware.AvalancheL1Middleware__CollateralClassNotActive`
- `IAvalancheL1Middleware.AvalancheL1Middleware__CollateralNotInAssetClass` → `IAvalancheL1Middleware.AvalancheL1Middleware__CollateralNotInCollateralClass`
- `L1_VALIDATOR_MANAGER()` → `BALANCER()`

**Uptime**:
- `l1Middleware` → `middleware`
- `l1Middleware_` (parameter) → `middleware_`
- `l1ChainID` → `uptimeBlockchainID`
- `l1ChainID_` (parameter) → `uptimeBlockchainID_`
- `validator.startedAt` → `validator.startTime`
- `validator.endedAt` → `validator.endTime`
- `L1_VALIDATOR_MANAGER()` → `BALANCER()`

**Validator manager API**:
- `initializeValidatorRegistration` → `initiateValidatorRegistration`
- `initializeValidatorWeightUpdate` → `initiateValidatorWeightUpdate`
- `initializeEndValidation` → `initiateValidatorRemoval`
- `completeEndValidation` → `completeValidatorRemoval`
- `registeredValidators(nodeKey)` → `getNodeValidationID(nodeKey)`
- `registeredValidators(nodeKey)` → `getNodeValidationID(nodeKey)`
- `Validator` type import from `@avalabs/teleporter/validator-manager/interfaces/IValidatorManager.sol` → `@avalabs/icm-contracts/validator-manager/interfaces/IACP99Manager.sol`
