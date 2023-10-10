// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.16;

import {PoolManagerDeployer} from "@src/operation/factory/poolManagerDeployer/PoolManagerDeployer.sol";
import {IPoolManager} from "@src/operation/factory/poolManagerDeployer/IPoolManager.sol";
import {CamelotV3LiquidityPoolManager} from "@src/poolManager/CamelotV3LiquidityPoolManager.sol";

/**
 * @title CamelotV3LiquidityPoolManagerDeployer
 * @author Orange Finance
 * @notice Deploys CamelotV3LiquidityPoolManager contracts in a way of OrangeVaultFactory
 */
contract CamelotV3LiquidityPoolManagerDeployer is PoolManagerDeployer {
    /// @inheritdoc PoolManagerDeployer
    function deployPoolManager(
        address _token0,
        address _token1,
        address _liquidityPool,
        bytes calldata
    ) external override returns (IPoolManager) {
        CamelotV3LiquidityPoolManager poolManager = new CamelotV3LiquidityPoolManager({
            _token0: _token0,
            _token1: _token1,
            _pool: _liquidityPool
        });

        emit PoolManagerDeployed(address(poolManager), _liquidityPool);

        return IPoolManager(address(poolManager));
    }
}
