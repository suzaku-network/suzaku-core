// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {IEntity} from "../../interfaces/common/IEntity.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

abstract contract Entity is Initializable, ERC165, IEntity {
    /**
     * @inheritdoc IEntity
     */
    address public immutable override FACTORY;

    /**
     * @inheritdoc IEntity
     */
    uint64 public immutable override TYPE;

    constructor(address factory, uint64 type_) {
        _disableInitializers();
        if (factory == address(0)) {
            revert Entity__ZeroAddress("factory");
        }
        FACTORY = factory;
        TYPE = type_;
    }

    /**
     * @inheritdoc IERC165
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IEntity).interfaceId || super.supportsInterface(interfaceId);
    }

    /**
     * @inheritdoc IEntity
     */
    function initialize(
        bytes calldata data
    ) external virtual override initializer {
        _initialize(data);
    }

    function _initialize(
        bytes calldata data
    ) internal virtual;
}
