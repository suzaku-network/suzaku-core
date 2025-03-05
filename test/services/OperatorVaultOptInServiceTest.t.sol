// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";

import {OperatorRegistry} from "../../src/contracts/OperatorRegistry.sol";
import {VaultFactory} from "../../src/contracts/VaultFactory.sol";
import {OperatorVaultOptInService} from "../../src/contracts/service/OperatorVaultOptInService.sol";
import {IOptInService} from "../../src/interfaces/service/IOptInService.sol";
import {VaultTokenized} from "../../src/contracts/vault/VaultTokenized.sol";
import {DelegatorFactory} from "../../src/contracts/DelegatorFactory.sol";
import {SlasherFactory} from "../../src/contracts/SlasherFactory.sol";
import {Token} from "../mocks/MockToken.sol";
import {MockFeeOnTransferToken} from "../mocks/MockFeeOnTransferToken.sol";

import {IVaultTokenized} from "../../src/interfaces/vault/IVaultTokenized.sol";

import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";

contract OperatorVaultOptInServiceTest is Test {
    address owner;
    address alice;
    uint256 alicePrivateKey;
    address bob;
    uint256 bobPrivateKey;

    OperatorRegistry operatorRegistry;
    VaultFactory vaultFactory;
    DelegatorFactory delegatorFactory;
    SlasherFactory slasherFactory;

    Token collateral;
    MockFeeOnTransferToken feeOnTransferCollateral;

    IOptInService service;

    function setUp() public {
        owner = address(this);
        (alice, alicePrivateKey) = makeAddrAndKey("alice");
        (bob, bobPrivateKey) = makeAddrAndKey("bob");

        operatorRegistry = new OperatorRegistry();
        vaultFactory = new VaultFactory(owner);
        delegatorFactory = new DelegatorFactory(owner);
        slasherFactory = new SlasherFactory(owner);

        collateral = new Token("Token");
        feeOnTransferCollateral = new MockFeeOnTransferToken("FeeOnTransferToken");

        address vaultImpl = address(new VaultTokenized(address(vaultFactory)));
        vaultFactory.whitelist(vaultImpl);

        // Deploy service for Operator-Vault optin
        service =
            new OperatorVaultOptInService(address(operatorRegistry), address(vaultFactory), "OperatorVaultOptInService");
    }

    function _createVaultEntity() internal returns (address vaultEntity) {
        uint64 lastVersion = vaultFactory.lastVersion();
        vaultEntity = vaultFactory.create(
            lastVersion,
            owner,
            abi.encode(
                IVaultTokenized.InitParams({
                    collateral: address(collateral),
                    burner: address(0xdEaD),
                    epochDuration: 7 days,
                    depositWhitelist: false,
                    isDepositLimit: false,
                    depositLimit: 0,
                    defaultAdminRoleHolder: alice,
                    depositWhitelistSetRoleHolder: alice,
                    depositorWhitelistRoleHolder: alice,
                    isDepositLimitSetRoleHolder: alice,
                    depositLimitSetRoleHolder: alice,
                    name: "TestVault",
                    symbol: "TVT"
                })
            ),
            address(delegatorFactory),
            address(slasherFactory)
        );
    }

    function test_Create() public {
        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        assertEq(service.isOptedInAt(alice, alice, 0, ""), false);
        assertEq(service.isOptedIn(alice, alice), false);
        assertEq(service.nonces(alice, alice), 0);

        // Register operator
        address operator = alice;
        vm.startPrank(operator);
        operatorRegistry.registerOperator("operatorMetadata");
        vm.stopPrank();

        // Create a valid vault entity
        address where = _createVaultEntity();

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
        // where is a valid entity so we must create one
        address where = _createVaultEntity();

        // Not registering operator to test NotWho revert
        vm.startPrank(operator);
        vm.expectRevert(IOptInService.OptInService__NotWho.selector);
        service.optIn(where);
        vm.stopPrank();
    }

    function test_OptInRevertNotWhereEntity() public {
        address operator = alice;
        vm.startPrank(operator);
        operatorRegistry.registerOperator("operatorMetadata");
        vm.stopPrank();

        // 'where' = bob is not created by vaultFactory, so not an entity
        address where = bob;

        vm.startPrank(operator);
        vm.expectRevert(IOptInService.OptInService__NotWhereEntity.selector);
        service.optIn(where);
        vm.stopPrank();
    }

    function test_OptInRevertAlreadyOptedIn() public {
        address operator = alice;
        address where = _createVaultEntity();

        vm.startPrank(operator);
        operatorRegistry.registerOperator("operatorMetadata");
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
        address where = _createVaultEntity();

        vm.startPrank(operator);
        operatorRegistry.registerOperator("operatorMetadata");
        vm.stopPrank();

        // Not calling optIn before optOut
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
        address where = _createVaultEntity();

        vm.startPrank(operator);
        operatorRegistry.registerOperator("operatorMetadata");
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
        address where = _createVaultEntity();

        vm.startPrank(operator);
        operatorRegistry.registerOperator("operatorMetadata");
        vm.stopPrank();

        uint48 deadline = uint48(blockTimestamp);
        bytes32 digest = computeOptInDigest(operator, where, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPrivateKey, digest); // invalid signer
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(IOptInService.OptInService__InvalidSignature.selector);
        service.optIn(operator, where, deadline, signature);
    }

    function test_OptInWithExpiredDeadline() public {
        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        address operator = alice;
        address where = _createVaultEntity();

        vm.startPrank(operator);
        operatorRegistry.registerOperator("operatorMetadata");
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
        address where = _createVaultEntity();

        vm.startPrank(operator);
        operatorRegistry.registerOperator("operatorMetadata");
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
        // Can't use old signature since nonce changed
        service.optIn(operator, where, deadline, signature);
    }

    function test_OptOutWithSignature() public {
        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        address operator = alice;
        address where = _createVaultEntity();

        vm.startPrank(operator);
        operatorRegistry.registerOperator("operatorMetadata");
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
        address where = _createVaultEntity();

        vm.startPrank(operator);
        operatorRegistry.registerOperator("operatorMetadata");
        vm.stopPrank();

        vm.startPrank(operator);
        service.optIn(where);
        vm.stopPrank();

        blockTimestamp += 1;
        vm.warp(blockTimestamp);

        uint48 deadline = uint48(blockTimestamp);
        bytes32 digest = computeOptOutDigest(operator, where, 1, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPrivateKey, digest); // invalid signer
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(IOptInService.OptInService__InvalidSignature.selector);
        service.optOut(operator, where, deadline, signature);
    }

    function test_OptOutWithExpiredDeadline() public {
        uint256 blockTimestamp = block.timestamp * block.timestamp / block.timestamp * block.timestamp / block.timestamp;
        blockTimestamp = blockTimestamp + 1_720_700_948;
        vm.warp(blockTimestamp);

        address operator = alice;
        address where = _createVaultEntity();

        vm.startPrank(operator);
        operatorRegistry.registerOperator("operatorMetadata");
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
