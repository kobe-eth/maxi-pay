// SPDX-License-Identifier: GPL 3.0
pragma solidity 0.8.20;

interface ILiquidityGauge {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function claimable_tokens(address user) external view returns (uint256);
    function claimable_reward(address user, address reward_token) external view returns (uint256);
    function claim_rewards(address user, address receiver) external;
    function transfer(address to, uint256 value) external returns (bool);
}
