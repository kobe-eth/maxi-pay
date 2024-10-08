// SPDX-License-Identifier: GPL 3.0
pragma solidity 0.8.20;

interface IDelegate {
    function setDelegate(bytes32 space, address delegatee) external;
}
