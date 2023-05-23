// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.16;

import "forge-std/console2.sol";
import {IERC20} from "../libs/BalancerFlashloan.sol";
import {IOrangeParametersV1} from "../interfaces/IOrangeParametersV1.sol";
import {IOrangeBaseV1} from "../interfaces/IOrangeBaseV1.sol";
import {OrangeERC20} from "./OrangeERC20.sol";

abstract contract OrangeBaseV1 is IOrangeBaseV1, OrangeERC20 {
    struct DepositType {
        uint256 assets;
        uint40 timestamp;
    }

    //OrangeVault
    int24 public lowerTick;
    int24 public upperTick;
    bool public hasPosition;
    bytes32 public flashloanHash; //cache flashloan hash to check validity

    //Checker
    mapping(address => DepositType) public deposits;
    uint256 public totalDeposits;

    /* ========== PARAMETERS ========== */
    address public liquidityPool;
    address public lendingPool;
    IERC20 public token0; //collateral and deposited currency by users
    IERC20 public token1; //debt and hedge target token
    IOrangeParametersV1 public params;
}
