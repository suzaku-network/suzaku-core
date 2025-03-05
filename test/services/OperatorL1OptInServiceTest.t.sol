// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";

import {OperatorRegistry} from "../../src/contracts/OperatorRegistry.sol";
import {L1Registry} from "../../src/contracts/L1Registry.sol";
import {OperatorL1OptInService} from "../../src/contracts/service/OperatorL1OptInService.sol";
import {IOptInService} from "../../src/interfaces/service/IOptInService.sol";

import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";

contract OperatorL1OptInServiceTest is Test {
    address owner;
    address alice;
    uint256 alicePrivateKey;
    address bob;
    uint256 bobPrivateKey;

    OperatorRegistry operatorRegistry;
    L1Registry l1Registry;

    IOptInService service;

    function setUp() public {
        owner = address(this);
        (alice, alicePrivateKey) = makeAddrAndKey("alice");
        (bob, bobPrivateKey) = makeAddrAndKey("bob");

        operatorRegistry = new OperatorRegistry();
        l1Registry = new L1Registry();

        // Deploy service for Operator-L1 optin
        service = new OperatorL1OptInService(address(operatorRegistry), address(l1Registry), "OperatorL1OptInService");
    }

    function test_Create() public {
        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        assertEq(service.isOptedInAt(alice, alice, 0, ""), false);
        assertEq(service.isOptedIn(alice, alice), false);
        assertEq(service.nonces(alice, alice), 0);

        address operator = alice;
        address where = bob;

        // Register operator and L1
        vm.startPrank(operator);
        operatorRegistry.registerOperator("operatorMetadata");
        vm.stopPrank();

        vm.startPrank(where);
        l1Registry.registerL1(where, where, "metadataURL");
        vm.stopPrank();

        vm.startPrank(operator);
        service.optIn(where);
        vm.stopPrank();

        assertEq(service.isOptedIn(operator, where), true);

        // Advance time and test opt-out
        blockTimestamp += 1;
        vm.warp(blockTimestamp);

        vm.startPrank(operator);
        service.optOut(where);
        vm.stopPrank();

        assertEq(service.isOptedIn(operator, where), false);

        // Opt-in again
        blockTimestamp += 1;
        vm.warp(blockTimestamp);

        vm.startPrank(operator);
        service.optIn(where);
        vm.stopPrank();

        assertEq(service.isOptedIn(operator, where), true);

        vm.startPrank(operator);
        vm.expectRevert(IOptInService.OptInService__OptOutCooldown.selector);
        service.optOut(where);
        vm.stopPrank();

        // Wait another block
        blockTimestamp += 1;
        vm.warp(blockTimestamp);

        vm.startPrank(operator);
        service.optOut(where);
        vm.stopPrank();

        assertEq(service.isOptedIn(operator, where), false);
    }

    function test_OptInRevertNotWho() public {
        address operator = alice;
        address where = bob;

        // L1 registered, operator not
        vm.startPrank(where);
        l1Registry.registerL1(where, where, "metadataURL");
        vm.stopPrank();

        vm.startPrank(operator);
        vm.expectRevert(IOptInService.OptInService__NotWho.selector);
        service.optIn(where);
        vm.stopPrank();
    }

    function test_OptInRevertNotWhereRegistered() public {
        address operator = alice;
        address where = bob;

        // Operator registered, L1 not
        vm.startPrank(operator);
        operatorRegistry.registerOperator("operatorMetadata");
        vm.stopPrank();

        vm.startPrank(operator);
        vm.expectRevert(IOptInService.OptInService__NotWhereRegistered.selector);
        service.optIn(where);
        vm.stopPrank();
    }

    function test_OptInRevertAlreadyOptedIn() public {
        address operator = alice;
        address where = bob;

        vm.startPrank(operator);
        operatorRegistry.registerOperator("operatorMetadata");
        vm.stopPrank();

        vm.startPrank(where);
        l1Registry.registerL1(where, where, "metadataURL");
        vm.stopPrank();

        vm.startPrank(operator);
        service.optIn(where);
        vm.stopPrank();

        vm.startPrank(operator);
        vm.expectRevert(IOptInService.OptInService__AlreadyOptedIn.selector);
        service.optIn(where);
        vm.stopPrank();
    }

    function test_OptOutRevertNotOptedIn() public {
        address operator = alice;
        address where = bob;

        vm.startPrank(operator);
        operatorRegistry.registerOperator("operatorMetadata");
        vm.stopPrank();

        vm.startPrank(where);
        l1Registry.registerL1(where, where, "metadataURL");
        vm.stopPrank();

        vm.startPrank(operator);
        vm.expectRevert(IOptInService.OptInService__NotOptedIn.selector);
        service.optOut(where);
        vm.stopPrank();
    }

    function test_OptInWithSignature() public {
        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        address operator = alice;
        address where = bob;
        vm.startPrank(operator);
        operatorRegistry.registerOperator("operatorMetadata");
        vm.stopPrank();

        vm.startPrank(where);
        l1Registry.registerL1(where, where, "metadataURL");
        vm.stopPrank();

        uint48 deadline = uint48(blockTimestamp);
        bytes32 digest = computeOptInDigest(operator, where, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        service.optIn(operator, where, deadline, signature);

        assertEq(service.isOptedIn(operator, where), true);
        assertEq(service.nonces(operator, where), 1);
    }

    function test_OptInWithInvalidSignature() public {
        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        address operator = alice;
        address where = bob;
        vm.startPrank(operator);
        operatorRegistry.registerOperator("operatorMetadata");
        vm.stopPrank();

        vm.startPrank(where);
        l1Registry.registerL1(where, where, "metadataURL");
        vm.stopPrank();

        uint48 deadline = uint48(blockTimestamp);
        bytes32 digest = computeOptInDigest(operator, where, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPrivateKey, digest); // Signed by bob, should fail
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(IOptInService.OptInService__InvalidSignature.selector);
        service.optIn(operator, where, deadline, signature);
    }

    function test_OptInWithExpiredDeadline() public {
        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        address operator = alice;
        address where = bob;
        vm.startPrank(operator);
        operatorRegistry.registerOperator("operatorMetadata");
        vm.stopPrank();

        vm.startPrank(where);
        l1Registry.registerL1(where, where, "metadataURL");
        vm.stopPrank();

        uint48 deadline = uint48(blockTimestamp - 1);
        bytes32 digest = computeOptInDigest(operator, where, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(IOptInService.OptInService__ExpiredSignature.selector);
        service.optIn(operator, where, deadline, signature);
    }

    function test_IncreaseNonce() public {
        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        address operator = alice;
        address where = bob;
        vm.startPrank(operator);
        operatorRegistry.registerOperator("operatorMetadata");
        vm.stopPrank();

        vm.startPrank(where);
        l1Registry.registerL1(where, where, "metadataURL");
        vm.stopPrank();

        uint48 deadline = uint48(blockTimestamp);
        bytes32 digest = computeOptInDigest(operator, where, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.startPrank(operator);
        service.increaseNonce(where);
        vm.stopPrank();

        assertEq(service.nonces(operator, where), 1);

        vm.expectRevert();
        service.optIn(operator, where, deadline, signature);
    }

    function test_OptOutWithSignature() public {
        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        address operator = alice;
        address where = bob;

        vm.startPrank(operator);
        operatorRegistry.registerOperator("operatorMetadata");
        vm.stopPrank();

        vm.startPrank(where);
        l1Registry.registerL1(where, where, "metadataURL");
        vm.stopPrank();

        vm.startPrank(operator);
        service.optIn(where);
        vm.stopPrank();

        blockTimestamp += 1;
        vm.warp(blockTimestamp);

        uint48 deadline = uint48(blockTimestamp);
        bytes32 digest = computeOptOutDigest(operator, where, 1, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        service.optOut(operator, where, deadline, signature);

        assertEq(service.isOptedIn(operator, where), false);
        assertEq(service.nonces(operator, where), 2);
    }

    function test_OptOutWithInvalidSignature() public {
        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        address operator = alice;
        address where = bob;

        vm.startPrank(operator);
        operatorRegistry.registerOperator("operatorMetadata");
        vm.stopPrank();

        vm.startPrank(where);
        l1Registry.registerL1(where, where, "metadataURL");
        vm.stopPrank();

        vm.startPrank(operator);
        service.optIn(where);
        vm.stopPrank();

        blockTimestamp += 1;
        vm.warp(blockTimestamp);

        uint48 deadline = uint48(blockTimestamp);
        bytes32 digest = computeOptOutDigest(operator, where, 1, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPrivateKey, digest); // Invalid signer
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(IOptInService.OptInService__InvalidSignature.selector);
        service.optOut(operator, where, deadline, signature);
    }

    function test_OptOutWithExpiredDeadline() public {
        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        address operator = alice;
        address where = bob;

        vm.startPrank(operator);
        operatorRegistry.registerOperator("operatorMetadata");
        vm.stopPrank();

        vm.startPrank(where);
        l1Registry.registerL1(where, where, "metadataURL");
        vm.stopPrank();

        vm.startPrank(operator);
        service.optIn(where);
        vm.stopPrank();

        blockTimestamp += 1;
        vm.warp(blockTimestamp);

        uint48 deadline = uint48(blockTimestamp - 1);
        bytes32 digest = computeOptOutDigest(operator, where, 1, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(IOptInService.OptInService__ExpiredSignature.selector);
        service.optOut(operator, where, deadline, signature);
    }

    function computeOptInDigest(
        address who,
        address where,
        uint256 nonce,
        uint48 deadline
    ) internal view returns (bytes32) {
        bytes32 OPT_IN_TYPEHASH = keccak256("OptIn(address who,address where,uint256 nonce,uint48 deadline)");
        bytes32 structHash = keccak256(abi.encode(OPT_IN_TYPEHASH, who, where, nonce, deadline));

        bytes32 domainSeparator = _computeDomainSeparator(address(service));

        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function computeOptOutDigest(
        address who,
        address where,
        uint256 nonce,
        uint48 deadline
    ) internal view returns (bytes32) {
        bytes32 OPT_OUT_TYPEHASH = keccak256("OptOut(address who,address where,uint256 nonce,uint48 deadline)");
        bytes32 structHash = keccak256(abi.encode(OPT_OUT_TYPEHASH, who, where, nonce, deadline));

        bytes32 domainSeparator = _computeDomainSeparator(address(service));

        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _computeDomainSeparator(
        address _service
    ) internal view returns (bytes32) {
        bytes32 DOMAIN_TYPEHASH =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

        (, string memory name, string memory version,,,,) = IERC5267(_service).eip712Domain();
        bytes32 NAME_HASH = keccak256(bytes(name));
        bytes32 VERSION_HASH = keccak256(bytes(version));
        uint256 chainId = block.chainid;

        return keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, chainId, _service));
    }
}
