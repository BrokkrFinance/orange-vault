// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.16;

interface IUniswapV3TickSpacing {
    function tickSpacing() external view returns (int24);
}
