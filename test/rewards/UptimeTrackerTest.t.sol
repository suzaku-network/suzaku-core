// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {
    UptimeTracker, ValidatorUptimeInfos, LastUptimeCheckpoint
} from "../../src/contracts/rewards/UptimeTracker.sol";
import {
    AvalancheL1MiddlewareSettings,
    AvalancheL1Middleware
} from "../../src/contracts/middleware/AvalancheL1Middleware.sol";

contract UptimeTrackerTest is Test {
    string constant VALIDATION_ID = "5SzUABX7Pv61TNy3F7w8qRoF5weeDZkyUMQDYuZCjft6E6hhs";
    UptimeTracker rewardCalculator;
    AvalancheL1Middleware middleware;

    function setUp() public {
        uint48 epochDuration = 4 hours;
        address owner = makeAddr("owner");
        address primaryAsset = makeAddr("primaryAsset");

        AvalancheL1MiddlewareSettings memory middlewareSettings = AvalancheL1MiddlewareSettings({
            l1ValidatorManager: address(0),
            operatorRegistry: address(0),
            vaultRegistry: address(0),
            operatorL1Optin: address(0),
            epochDuration: epochDuration,
            slashingWindow: 4 hours
        });

        middleware = new AvalancheL1Middleware(
            middlewareSettings, owner, primaryAsset, 1_000_000_000_000_000_000_000, 100_000_000_000_000_000
        );

        rewardCalculator = new UptimeTracker(address(middleware));
    }

    modifier initializeValidator() {
        ValidatorUptimeInfos memory validatorInfos = ValidatorUptimeInfos({
            validationID: VALIDATION_ID,
            nodeID: "",
            weight: 100,
            startTimestamp: 1000,
            isActive: true,
            isL1Validator: false,
            isConnected: true,
            uptimePercentage: 0,
            uptimeSeconds: 0
        });
        rewardCalculator.setInitialCheckpoint(validatorInfos);
        _;
    }

    function test_CalculateUptimeCoverage() public initializeValidator {
        LastUptimeCheckpoint memory initialUptimeCheckpoint = rewardCalculator.getLastUptimeCheckpoint(VALIDATION_ID);

        console2.log("INITIAL VALUES:");
        console2.log("TIMESTAMP:", initialUptimeCheckpoint.timestamp);
        console2.log("UPTIME:", initialUptimeCheckpoint.uptime);
        console2.log("REMAINING UPTIME:", initialUptimeCheckpoint.remainingUptime);
        console2.log("UPTIME EPOCH:", middleware.getEpochAtTs(uint48(initialUptimeCheckpoint.timestamp)));
        console2.log(
            "UPTIME EPOCH START TIMESTAMP:",
            middleware.getEpochStartTs(middleware.getEpochAtTs(uint48(initialUptimeCheckpoint.timestamp)))
        );

        ValidatorUptimeInfos memory validatorInfos = ValidatorUptimeInfos({
            validationID: VALIDATION_ID,
            nodeID: "",
            weight: 100,
            startTimestamp: 1000,
            isActive: true,
            isL1Validator: false,
            isConnected: true,
            uptimePercentage: 50,
            uptimeSeconds: 3 hours
        });

        console2.log("---- FIRST UPTIME PROOF SUBMIT ----");
        console2.log("INPUT VALUES:");
        console2.log("TIMESTAMP:", uint256(14_401));
        console2.log("UPTIME:", validatorInfos.uptimeSeconds);

        console2.log("---- COMPUTE ----");
        console2.log("COMPUTED VALUES:");
        console2.log("CURRENT EPOCH:", middleware.getEpochAtTs(uint48(14_401)));
        console2.log(
            "UPTIME EPOCH START TIMESTAMP:", middleware.getEpochStartTs(middleware.getEpochAtTs(uint48(14_401)))
        );
        console2.log(
            "TOTAL UPTIME:",
            initialUptimeCheckpoint.remainingUptime + (validatorInfos.uptimeSeconds - initialUptimeCheckpoint.uptime)
        );
        console2.log(
            "TIME BETWEEN UPTIME:",
            middleware.getEpochStartTs(middleware.getEpochAtTs(uint48(14_401)))
                - middleware.getEpochStartTs(middleware.getEpochAtTs(uint48(initialUptimeCheckpoint.timestamp)))
        );

        rewardCalculator.calculateValidatorUptimeCoverage(validatorInfos, 14_401);
        console2.log("---- CALCULATE VALIDATOR UPTIME COVERAGE CALLED ----");
        LastUptimeCheckpoint memory firstUptimeCheckpoint =
            rewardCalculator.getLastUptimeCheckpoint(validatorInfos.validationID);

        console2.log("FIRST UPTIME CHECKPOINT VALUES:");
        console2.log("TIMESTAMP:", firstUptimeCheckpoint.timestamp);
        console2.log("UPTIME:", firstUptimeCheckpoint.uptime);
        console2.log("REMAINING UPTIME:", firstUptimeCheckpoint.remainingUptime);
        console2.log("UPTIME EPOCH:", middleware.getEpochAtTs(uint48(firstUptimeCheckpoint.timestamp)));
        console2.log(
            "UPTIME EPOCH START TIMESTAMP:",
            middleware.getEpochStartTs(middleware.getEpochAtTs(uint48(firstUptimeCheckpoint.timestamp)))
        );

        ValidatorUptimeInfos memory validatorInfos2 = ValidatorUptimeInfos({
            validationID: VALIDATION_ID,
            nodeID: "",
            weight: 100,
            startTimestamp: 1000,
            isActive: true,
            isL1Validator: false,
            isConnected: true,
            uptimePercentage: 50,
            uptimeSeconds: 7 hours
        });

        console2.log("---- SECOND UPTIME PROOF SUBMIT ----");
        console2.log("INPUT VALUES:");
        console2.log("TIMESTAMP:", uint256(43_201));
        console2.log("UPTIME:", validatorInfos2.uptimeSeconds);

        console2.log("---- COMPUTE ----");
        console2.log("COMPUTED VALUES:");
        console2.log("CURRENT EPOCH:", middleware.getEpochAtTs(uint48(43_201)));
        console2.log(
            "UPTIME EPOCH START TIMESTAMP:", middleware.getEpochStartTs(middleware.getEpochAtTs(uint48(43_201)))
        );
        console2.log(
            "TOTAL UPTIME:",
            firstUptimeCheckpoint.remainingUptime + (validatorInfos2.uptimeSeconds - firstUptimeCheckpoint.uptime)
        );
        console2.log(
            "TIME BETWEEN UPTIME:",
            middleware.getEpochStartTs(middleware.getEpochAtTs(uint48(43_201)))
                - middleware.getEpochStartTs(middleware.getEpochAtTs(uint48(firstUptimeCheckpoint.timestamp)))
        );

        rewardCalculator.calculateValidatorUptimeCoverage(validatorInfos2, 43_201);
        console2.log("---- CALCULATE VALIDATOR UPTIME COVERAGE CALLED ----");
        LastUptimeCheckpoint memory secondUptimeCheckpoint =
            rewardCalculator.getLastUptimeCheckpoint(validatorInfos2.validationID);

        console2.log("SECOND UPTIME CHECKPOINT VALUES:");
        console2.log("TIMESTAMP:", secondUptimeCheckpoint.timestamp);
        console2.log("UPTIME:", secondUptimeCheckpoint.uptime);
        console2.log("REMAINING UPTIME:", secondUptimeCheckpoint.remainingUptime);
        console2.log("UPTIME EPOCH:", middleware.getEpochAtTs(uint48(secondUptimeCheckpoint.timestamp)));
        console2.log(
            "UPTIME EPOCH START TIMESTAMP:",
            middleware.getEpochStartTs(middleware.getEpochAtTs(uint48(secondUptimeCheckpoint.timestamp)))
        );

        _printUptimePerEpoch();
    }

    function _printUptimePerEpoch() internal view {
        string memory validationID = "5SzUABX7Pv61TNy3F7w8qRoF5weeDZkyUMQDYuZCjft6E6hhs";
        for (uint48 i = 0; i < 5; i++) {
            uint256 uptime = rewardCalculator.getValidatorUptimeAt(validationID, i);
            console2.log("UPTIME AT EPOCH", i, ":", uptime);
        }
    }
}
