// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.16;

import {IOrangeAlphaVault} from "../interfaces/IOrangeAlphaVault.sol";
import {IOrangeAlphaParameters} from "../interfaces/IOrangeAlphaParameters.sol";
import {IResolver} from "../vendor/gelato/IResolver.sol";
import {UniswapV3Twap, IUniswapV3Pool} from "../libs/UniswapV3Twap.sol";

// import "forge-std/console2.sol";
// import {Ints} from "../mocks/Ints.sol";

contract OrangeAlphaResolver is IResolver {
    using UniswapV3Twap for IUniswapV3Pool;

    /* ========== ERRORS ========== */
    string constant ERROR_CANNOT_STOPLOSS = "CANNOT_STOPLOSS";

    /* ========== PARAMETERS ========== */
    IOrangeAlphaVault public vault;
    IOrangeAlphaParameters public params;

    /* ========== CONSTRUCTOR ========== */
    constructor(address _vault, address _params) {
        vault = IOrangeAlphaVault(_vault);
        params = IOrangeAlphaParameters(_params);
    }

    // @inheritdoc IResolver
    function checker()
        external
        view
        override
        returns (bool canExec, bytes memory execPayload)
    {
        if (vault.hasPosition()) {
            IUniswapV3Pool _pool = vault.pool();
            (, int24 _currentTick, , , , , ) = _pool.slot0();
            int24 _twap = _pool.getTwap();
            int24 _stoplossLowerTick = vault.stoplossLowerTick();
            int24 _stoplossUpperTick = vault.stoplossUpperTick();
            if (
                _isOutOfRange(
                    _currentTick,
                    _stoplossLowerTick,
                    _stoplossUpperTick
                ) &&
                _isOutOfRange(_twap, _stoplossLowerTick, _stoplossUpperTick)
            ) {
                execPayload = abi.encodeWithSelector(
                    IOrangeAlphaVault.stoploss.selector,
                    _twap
                );
                return (true, execPayload);
            }
        }
        return (false, bytes(ERROR_CANNOT_STOPLOSS));
    }

    ///@notice Can stoploss when has position and out of range
    function _isOutOfRange(
        int24 _targetTick,
        int24 _lowerTick,
        int24 _upperTick
    ) internal pure returns (bool) {
        return (_targetTick > _upperTick || _targetTick < _lowerTick);
    }
}
