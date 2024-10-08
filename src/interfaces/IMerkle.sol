// SPDX-License-Identifier: GPL 3.0
pragma solidity 0.8.20;

interface IMerkle {
    function claim(address token,  uint256 index, address account, uint256 amount, bytes32[] calldata proof) external;
}
