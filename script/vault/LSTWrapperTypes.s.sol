// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

struct LSTWrapperConfig {
    string implementation;  // "LSTWrapper" or "LSTWrapperMerkl"
    address admin;
    address vault;
    address rewards;
    address helper;
    string name;
    string symbol;
}

