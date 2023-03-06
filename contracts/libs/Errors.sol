// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.16;

library Errors {
    //access control
    string public constant ONLY_PERIPHERY = "1";
    string public constant ONLY_DEDICATED_MSG_SENDER = "2";
    string public constant ONLY_ADMINISTRATOR = "3";
    string public constant ONLY_CALLBACK_CALLER = "4";
    //condition
    string public constant CANNOT_STOPLOSS = "11";
    //validation
    string public constant INVALID_TICKS = "21";
    string public constant INVALID_AMOUNT = "22";
    string public constant INVALID_DEPOSIT_AMOUNT = "23";
    //logic
    string public constant SURPLUS_ZERO = "31";
    string public constant AAVE_MISMATCH = "32";
    string public constant LESS_AMOUNT = "33";
    string public constant LESS_LIQUIDITY = "34";
    string public constant HIGH_SLIPPAGE = "35";
}
