// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {IL1Registry} from "../interfaces/IL1Registry.sol";
import {IAvalancheL1Middleware} from "../interfaces/middleware/IAvalancheL1Middleware.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract L1Registry is IL1Registry, Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet private l1s;

    /// @notice The l1Middleware for each L1
    mapping(address => address) public l1Middleware;

    /// @notice The metadata URL for each L1
    mapping(address => string) public l1MetadataURL;

    /// @notice The fee collector address (can be changed later).
    address payable public feeCollector;

    /// @notice The adjustable fee (in wei) for registerL1.
    uint256 public registerFee;

    /// @notice MAX_FEE is the maximum fee that can be set by the owner.
    uint256 immutable MAX_FEE;

    /// @notice Tracks the total unclaimed fees in the contract
    uint256 public unclaimedFees;

    modifier onlyValidatorManagerOwner(
        address l1
    ) {
        // Ensure caller owns the validator manager
        address vmOwner = Ownable(l1).owner();
        if (vmOwner != msg.sender) {
            revert L1Registry__NotValidatorManagerOwner(msg.sender, vmOwner);
        }
        _;
    }

    modifier isRegisteredL1(
        address l1
    ) {
        if (!isRegistered(l1)) {
            revert L1Registry__L1NotRegistered();
        }
        _;
    }

    modifier notZeroAddress(
        address l1
    ) {
        if (l1 == address(0)) {
            revert L1Registry__InvalidValidatorManager(l1);
        }
        _;
    }

    constructor(address payable feeCollector_, uint256 registerFee_, uint256 MAX_FEE_, address owner) Ownable(owner) {
        if (feeCollector_ == address(0)) {
            revert L1Registry__ZeroAddress("feeCollector");
        }
        feeCollector = feeCollector_;
        registerFee = registerFee_;
        MAX_FEE = MAX_FEE_;
    }

    /// @inheritdoc IL1Registry
    function registerL1(
        address l1,
        address l1Middleware_,
        string calldata metadataURL
    ) external payable notZeroAddress(l1) onlyValidatorManagerOwner(l1) {
        if (registerFee == 0) {
            if (msg.value > 0) revert L1Registry__UnexpectedEther();
        } else {
            if (msg.value < registerFee) revert L1Registry__InsufficientFee();

            uint256 excess = msg.value - registerFee;

            // refund excess first – ensures balance is available
            if (excess > 0) {
                (bool refundOk, ) = payable(msg.sender).call{value: excess}("");
                if (!refundOk) revert L1Registry__RefundFailed(excess);
            }

            // forward exact fee
            (bool success, ) = feeCollector.call{value: registerFee}("");
            if (!success) unclaimedFees += registerFee;
        }

        bool registered = l1s.add(l1);
        if (!registered) {
            revert L1Registry__L1AlreadyRegistered();
        }
        l1Middleware[l1] = l1Middleware_;
        l1MetadataURL[l1] = metadataURL;

        emit RegisterL1(l1);
        emit SetL1Middleware(l1, l1Middleware_);
        emit SetMetadataURL(l1, metadataURL);
    }

    /// @inheritdoc IL1Registry
    function setL1Middleware(
        address l1,
        address l1Middleware_
    ) external notZeroAddress(l1Middleware_) isRegisteredL1(l1) onlyValidatorManagerOwner(l1) {
        l1Middleware[l1] = l1Middleware_;

        emit SetL1Middleware(l1, l1Middleware_);
    }

    /// @inheritdoc IL1Registry
    function setMetadataURL(
        address l1,
        string calldata metadataURL
    ) external isRegisteredL1(l1) onlyValidatorManagerOwner(l1) {
        // TODO: check that msg.sender is a SecurityModule of the ValidatorManager

        l1MetadataURL[l1] = metadataURL;

        emit SetMetadataURL(l1, metadataURL);
    }

    /// @inheritdoc IL1Registry
    function isRegistered(
        address l1
    ) public view returns (bool) {
        return l1s.contains(l1);
    }

    // @inheritdoc IL1Registry
    function isRegisteredWithMiddleware(address l1, address vaultManager_) external view returns (bool) {
        if (!isRegistered(l1)) {
            return false;
        }

        address middleware = l1Middleware[l1];
        if (middleware == address(0)) {
            return false;
        }

        address actualVaultManager = IAvalancheL1Middleware(middleware).getVaultManager();

        if (actualVaultManager != vaultManager_) {
            revert L1Registry__InvalidL1Middleware();
        }

        return true;
    }

    /// @inheritdoc IL1Registry
    function getL1At(
        uint256 index
    ) public view returns (address, address, string memory) {
        address l1 = l1s.at(index);
        return (l1, l1Middleware[l1], l1MetadataURL[l1]);
    }

    /// @inheritdoc IL1Registry
    function totalL1s() public view returns (uint256) {
        return l1s.length();
    }

    /// @inheritdoc IL1Registry
    function getAllL1s() public view returns (address[] memory, address[] memory, string[] memory) {
        address[] memory l1sList = l1s.values();
        address[] memory l1Middlewares = new address[](l1sList.length);
        string[] memory metadataURLs = new string[](l1sList.length);
        for (uint256 i = 0; i < l1sList.length; i++) {
            l1Middlewares[i] = l1Middleware[l1sList[i]];
            metadataURLs[i] = l1MetadataURL[l1sList[i]];
        }
        return (l1sList, l1Middlewares, metadataURLs);
    }

    /// @notice Adjust fee collector. Only owner can change it.
    /// @param newFeeCollector The new fee collector address
    function setFeeCollector(
        address payable newFeeCollector
    ) external onlyOwner {
        if (newFeeCollector == address(0)) {
            revert L1Registry__ZeroAddress("feeCollector");
        }
        
        // Try to disburse any accumulated fees to the new collector
        uint256 feesToSend = unclaimedFees;
        if (feesToSend > 0) {
            // Reset unclaimed fees before transfer to prevent reentrancy issues
            unclaimedFees = 0;
            
            (bool success,) = newFeeCollector.call{value: feesToSend}("");
            if (!success) {
                // If transfer fails, restore the unclaimed fees amount
                // but continue execution so that feeCollector is still updated
                unclaimedFees = feesToSend;
            }
        }
        
        feeCollector = newFeeCollector;
    }

    /// @notice Adjust fee. Only owner can change it.
    function setRegisterFee(
        uint256 newFee
    ) external onlyOwner {
        if (newFee > MAX_FEE) {
            revert L1Registry__FeeExceedsMaximum(newFee, MAX_FEE);
        }
        registerFee = newFee;
    }

    /// @notice Allows the fee collector to withdraw accumulated fees
    function withdrawFees() external {
        if (msg.sender != feeCollector) {
            revert L1Registry__NotFeeCollector(msg.sender);
        }
        
        uint256 feesToSend = unclaimedFees;
        if (feesToSend == 0) {
            revert L1Registry__NoFeesToWithdraw();
        }
        
        // Reset unclaimed fees before transfer to prevent reentrancy issues
        unclaimedFees = 0;
        
        (bool success,) = feeCollector.call{value: feesToSend}("");
        if (!success) {
            // If transfer fails, restore the unclaimed fees amount
            unclaimedFees = feesToSend;
            revert L1Registry__FeeTransferFailed();
        }
    }

    receive() external payable {}
}
