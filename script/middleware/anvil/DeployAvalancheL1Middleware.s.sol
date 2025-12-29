// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {MiddlewareHelperConfig} from "./MiddlewareHelperConfig.s.sol";
import {Script} from "forge-std/Script.sol";
import {DeployBalancerValidatorManager} from "../../../lib/suzaku-contracts-library/script/ValidatorManager/DeployBalancerValidatorManager.s.sol";
import {OperatorRegistry} from "../../../src/contracts/OperatorRegistry.sol";
import {VaultFactory} from "../../../src/contracts/VaultFactory.sol";
import {OperatorL1OptInService} from "../../../src/contracts/service/OperatorL1OptInService.sol";
import {L1Registry} from "../../../src/contracts/L1Registry.sol";
import {
    AvalancheL1Middleware,
    AvalancheL1MiddlewareSettings
} from "../../../src/contracts/middleware/AvalancheL1Middleware.sol";
import {MiddlewareVaultManager} from "../../../src/contracts/middleware/MiddlewareVaultManager.sol";

/**
 * @dev Deploy a test Avalanche L1 Middleware
 * @dev DO NOT USE THIS IN PRODUCTION
 */
contract DeployTestAvalancheL1Middleware is Script {
    // Storage variables to reduce stack depth
    uint256 internal s_protocolOwnerKey;
    address internal s_protocolOwnerAddress;
    address internal s_balancerAddress;
    address internal s_primaryCollateral;
    uint256 internal s_primaryCollateralMaxStake;
    uint256 internal s_primaryCollateralMinStake;
    uint256 internal s_primaryCollateralWeightScaleFactor;

    function run() external returns (address) {
        // Revert if not on Anvil
        if (block.chainid != 31_337) {
            revert("Not on Anvil");
        }

        _loadConfig();
        _deployValidatorManager();
        return _deployMiddlewareStack();
    }

    function _loadConfig() internal {
        MiddlewareHelperConfig helperConfig = new MiddlewareHelperConfig();
        (
            ,
            uint256 protocolOwnerKey,
            ,
            ,
            ,
            address primaryCollateral,
            uint256 primaryCollateralMaxStake,
            uint256 primaryCollateralMinStake,
            uint256 primaryCollateralWeightScaleFactor
        ) = helperConfig.activeNetworkConfig();

        s_protocolOwnerKey = protocolOwnerKey;
        s_protocolOwnerAddress = vm.addr(protocolOwnerKey);
        s_primaryCollateral = primaryCollateral;
        s_primaryCollateralMaxStake = primaryCollateralMaxStake;
        s_primaryCollateralMinStake = primaryCollateralMinStake;
        s_primaryCollateralWeightScaleFactor = primaryCollateralWeightScaleFactor;
    }

    function _deployValidatorManager() internal {
        DeployBalancerValidatorManager deployScript = new DeployBalancerValidatorManager();
        (address balancerAddress, , ) = deployScript.run(
            address(0),
            1000,
            new bytes[](0)
        );
        s_balancerAddress = balancerAddress;
    }

    function _deployMiddlewareStack() internal returns (address) {
        L1Registry l1Registry = new L1Registry(
            payable(s_protocolOwnerAddress),
            0.01 ether,
            1 ether,
            s_protocolOwnerAddress
        );
        OperatorRegistry operatorRegistry = new OperatorRegistry();
        VaultFactory vaultFactory = new VaultFactory(s_protocolOwnerAddress);
        OperatorL1OptInService operatorL1OptIn =
            new OperatorL1OptInService(address(operatorRegistry), address(l1Registry), "Suzaku Operator -> L1 Opt-In");

        AvalancheL1Middleware avalancheL1Middleware = _deployMiddleware(
            address(operatorRegistry),
            address(vaultFactory),
            address(operatorL1OptIn)
        );

        MiddlewareVaultManager vaultManager =
            new MiddlewareVaultManager(address(vaultFactory), s_protocolOwnerAddress, address(avalancheL1Middleware), 24);

        vm.startBroadcast(s_protocolOwnerKey);
        avalancheL1Middleware.setVaultManager(address(vaultManager));
        vm.stopBroadcast();

        return address(avalancheL1Middleware);
    }

    function _deployMiddleware(
        address operatorRegistry,
        address vaultFactory,
        address operatorL1OptIn
    ) internal returns (AvalancheL1Middleware) {
        return new AvalancheL1Middleware(
            AvalancheL1MiddlewareSettings({
                balancer: s_balancerAddress,
                operatorRegistry: operatorRegistry,
                vaultRegistry: vaultFactory,
                operatorL1Optin: operatorL1OptIn,
                epochDuration: 4 hours,
                slashingWindow: 5 hours,
                stakeUpdateWindow: 3 hours
            }),
            s_protocolOwnerAddress,
            s_primaryCollateral,
            s_primaryCollateralMaxStake,
            s_primaryCollateralMinStake,
            s_primaryCollateralWeightScaleFactor
        );
    }
}
