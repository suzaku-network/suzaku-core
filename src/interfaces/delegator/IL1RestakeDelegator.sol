// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IBaseDelegator} from "./IBaseDelegator.sol";

interface IL1RestakeDelegator is IBaseDelegator {
    error L1RestakeDelegator__DuplicateRoleHolder();
    error L1RestakeDelegator__ExceedsMaxL1Limit();
    error L1RestakeDelegator__MaxL1LimitNotSet();
    error L1RestakeDelegator__MissingRoleHolders();
    error L1RestakeDelegator__ZeroAddressRoleHolder();

    /**
     * @notice Hints for a stake.
     * @param baseHints base hints
     * @param activeStakeHint hint for the active stake checkpoint
     * @param l1LimitHint hint for the subnetwork limit checkpoint
     * @param totalOperatorL1SharesHint hint for the total operator-l1-shares checkpoint
     * @param operatorL1SharesHint hint for the operator-l1-shares checkpoint
     */
    struct StakeHints {
        bytes baseHints;
        bytes activeStakeHint;
        bytes l1LimitHint;
        bytes totalOperatorL1SharesHint;
        bytes operatorL1SharesHint;
    }

    /**
     * @notice Initial parameters needed for a full restaking delegator deployment.
     * @param baseParams base parameters for the delegator's deployment
     * @param l1LimitSetRoleHolders array of addresses of the initial L1_LIMIT_SET_ROLE holders
     * @param operatorL1SharesSetRoleHolders array of addresses of the initial OPERATOR_L1_SHARES_SET_ROLE holders
     */
    struct InitParams {
        IBaseDelegator.BaseParams baseParams;
        address[] l1LimitSetRoleHolders;
        address[] operatorL1SharesSetRoleHolders;
    }

    /**
     * @notice Emitted when a subnetwork's limit is set.
     * @param l1 address of the L1
     * @param assetClass uint96 identifier of the stakable asset
     * @param amount new subnetwork's limit
     */
    event SetL1Limit(address indexed l1, uint96 indexed assetClass, uint256 amount);

    /**
     * @notice Emitted when an operator's shares inside a subnetwork are set.
     * @param l1 address of the L1
     * @param assetClass uint96 identifier of the stakable asset
     * @param operator address of the operator
     * @param shares new operator's shares
     */
    event SetOperatorL1Shares(address indexed l1, uint96 indexed assetClass, address indexed operator, uint256 shares);

    /**
     * @notice Get a subnetwork limit setter's role.
     * @return identifier of the subnetwork limit setter role
     */
    function L1_LIMIT_SET_ROLE() external view returns (bytes32);

    /**
     * @notice Get an operator-l1-shares setter's role.
     * @return identifier of the operator-l1-shares setter role
     */
    function OPERATOR_L1_SHARES_SET_ROLE() external view returns (bytes32);

    /**
     * @notice Get a subnetwork's limit at a given timestamp using a hint.
     * @param l1 address of the L1
     * @param assetClass uint96 identifier of the stakable asset
     * @param timestamp time point to get the subnetwork limit at
     * @param hint hint for checkpoint index
     * @return limit of the subnetwork at the given timestamp
     */
    function l1LimitAt(
        address l1,
        uint96 assetClass,
        uint48 timestamp,
        bytes memory hint
    ) external view returns (uint256);

    /**
     * @notice Get a subnetwork's limit.
     * @param l1 address of the L1
     * @param assetClass uint96 identifier of the stakable asset
     * @return limit of the subnetwork
     */
    function l1Limit(address l1, uint96 assetClass) external view returns (uint256);

    /**
     * @notice Get total operators' shares for a subnetwork at a given timestamp using a hint.
     * @param l1 address of the L1
     * @param assetClass uint96 identifier of the stakable asset
     * @param timestamp time point to get the total operators' shares at
     * @param hint hint for checkpoint index
     * @return total shares of the operators for the subnetwork at the given timestamp
     */
    function totalOperatorL1SharesAt(
        address l1,
        uint96 assetClass,
        uint48 timestamp,
        bytes memory hint
    ) external view returns (uint256);

    /**
     * @notice Get total operators' shares for a subnetwork.
     * @param l1 address of the L1
     * @param assetClass uint96 identifier of the stakable asset
     * @return total shares of the operators for the subnetwork
     */
    function totalOperatorL1Shares(address l1, uint96 assetClass) external view returns (uint256);

    /**
     * @notice Get an operator's shares for a subnetwork at a given timestamp using a hint.
     * @param l1 address of the L1
     * @param assetClass uint96 identifier of the stakable asset
     * @param operator address of the operator
     * @param timestamp time point to get the operator's shares at
     * @param hint hint for checkpoint index
     * @return shares of the operator for the subnetwork at the given timestamp
     */
    function operatorL1SharesAt(
        address l1,
        uint96 assetClass,
        address operator,
        uint48 timestamp,
        bytes memory hint
    ) external view returns (uint256);

    /**
     * @notice Get an operator's shares for a subnetwork.
     * @param l1 address of the L1
     * @param assetClass uint96 identifier of the stakable asset
     * @param operator address of the operator
     * @return shares of the operator for the subnetwork
     */
    function operatorL1Shares(address l1, uint96 assetClass, address operator) external view returns (uint256);

    /**
     * @notice Set a subnetwork's limit.
     * @param l1 address of the L1
     * @param assetClass uint96 identifier of the stakable asset
     * @param amount new limit of the subnetwork
     * @dev Only a L1_LIMIT_SET_ROLE holder can call this function.
     */
    function setL1Limit(address l1, uint96 assetClass, uint256 amount) external;

    /**
     * @notice Set an operator's shares for a subnetwork.
     * @param l1 address of the L1
     * @param assetClass uint96 identifier of the stakable asset
     * @param operator address of the operator
     * @param shares new shares of the operator for the subnetwork
     * @dev Only an OPERATOR_L1_SHARES_SET_ROLE holder can call this function.
     */
    function setOperatorL1Shares(address l1, uint96 assetClass, address operator, uint256 shares) external;
}
