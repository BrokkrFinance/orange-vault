// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.16;

import "../utils/BaseTest.sol";
import "./IOrangeAlphaVaultEvent.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IAaveV3Pool} from "../../../contracts/interfaces/IAaveV3Pool.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Errors} from "../../../contracts/libs/Errors.sol";
import {OrangeAlphaVaultMock} from "../../../contracts/mocks/OrangeAlphaVaultMock.sol";
import {IOrangeAlphaVault} from "../../../contracts/interfaces/IOrangeAlphaVault.sol";
import {IOpsProxyFactory} from "../../../contracts/vendor/gelato/GelatoOps.sol";
import {TickMath} from "../../../contracts/vendor/uniswap/TickMath.sol";
import {OracleLibrary} from "../../../contracts/vendor/uniswap/OracleLibrary.sol";
import {FullMath, LiquidityAmounts} from "../../../contracts/vendor/uniswap/LiquidityAmounts.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

contract OrangeAlphaVaultTest is BaseTest, IOrangeAlphaVaultEvent {
    using SafeERC20 for IERC20;
    using TickMath for int24;
    using FullMath for uint256;
    using Ints for int24;
    using Ints for int256;

    uint256 MAGIC_SCALE_1E8 = 1e8; //for computing ltv
    uint16 MAGIC_SCALE_1E4 = 10000; //for slippage

    AddressHelper.TokenAddr public tokenAddr;
    AddressHelper.AaveAddr aaveAddr;
    AddressHelper.UniswapAddr uniswapAddr;
    ISwapRouter router;

    OrangeAlphaVaultMock vault;
    IUniswapV3Pool pool;
    IAaveV3Pool aave;
    IERC20 weth;
    IERC20 usdc;
    IERC20 debtToken0; //weth
    IERC20 aToken1; //usdc
    IOrangeAlphaVault.Ticks _ticks;

    int24 lowerTick = -205680;
    int24 upperTick = -203760;

    //parameters
    uint256 constant DEPOSIT_CAP = 1_000_000 * 1e6;
    uint256 constant TOTAL_DEPOSIT_CAP = 1_000_000 * 1e6;
    uint16 constant SLIPPAGE_BPS = 500;
    uint24 constant SLIPPAGE_TICK_BPS = 10;
    uint32 constant MAX_LTV = 70000000;
    uint32 constant LOCKUP_PERIOD = 7 days;

    function setUp() public {
        (tokenAddr, aaveAddr, uniswapAddr) = AddressHelper.addresses(
            block.chainid
        );

        router = ISwapRouter(uniswapAddr.routerAddr); //for test
        pool = IUniswapV3Pool(uniswapAddr.wethUsdcPoolAddr);
        weth = IERC20(tokenAddr.wethAddr);
        usdc = IERC20(tokenAddr.usdcAddr);
        aave = IAaveV3Pool(aaveAddr.poolAddr);
        debtToken0 = IERC20(aaveAddr.vDebtWethAddr);
        aToken1 = IERC20(aaveAddr.ausdcAddr);

        vault = new OrangeAlphaVaultMock(
            "OrangeAlphaVault",
            "ORANGE_ALPHA_VAULT",
            6,
            address(pool),
            address(weth),
            address(usdc),
            address(aave),
            address(debtToken0),
            address(aToken1),
            lowerTick,
            upperTick
        );
        vault.setDepositCap(DEPOSIT_CAP, TOTAL_DEPOSIT_CAP);
        vault.setSlippage(SLIPPAGE_BPS, SLIPPAGE_TICK_BPS);
        vault.setMaxLtv(MAX_LTV);
        vault.setLockupPeriod(LOCKUP_PERIOD);

        //set Ticks for testing
        (uint160 _sqrtRatioX96, int24 _tick, , , , , ) = pool.slot0();
        _ticks = IOrangeAlphaVault.Ticks(
            _sqrtRatioX96,
            _tick,
            lowerTick,
            upperTick
        );

        //deal
        deal(tokenAddr.wethAddr, address(this), 10_000 ether);
        deal(tokenAddr.usdcAddr, address(this), 10_000_000 * 1e6);
        deal(tokenAddr.usdcAddr, alice, 10_000_000 * 1e6);
        deal(tokenAddr.wethAddr, carol, 10_000 ether);
        deal(tokenAddr.usdcAddr, carol, 10_000_000 * 1e6);

        //approve
        usdc.approve(address(vault), type(uint256).max);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(carol);
        weth.approve(address(router), type(uint256).max);
        usdc.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    /* ========== MODIFIER ========== */
    function test_onlyOwner() public {
        vm.startPrank(alice);
        //test removeAllPosition
        vm.expectRevert("Ownable");
        vault.removeAllPosition(0);
        //test setDepositCap
        vm.expectRevert("Ownable");
        vault.setDepositCap(0, 0);
        //test setSlippage
        vm.expectRevert("Ownable");
        vault.setSlippage(0, 0);
        //test setMaxLtv
        vm.expectRevert("Ownable");
        vault.setMaxLtv(0);
        //test setLockupPeriod
        vm.expectRevert("Ownable");
        vault.setLockupPeriod(0);
    }

    function test_onlyDedicatedMsgSender() public {
        vm.expectRevert("Only dedicated msg.sender");
        vault.stoploss(0);
    }

    /* ========== CONSTRUCTOR ========== */
    function test_constructor_Success() public {
        assertEq(address(vault.pool()), address(pool));
        assertEq(address(vault.token0()), address(weth));
        assertEq(address(vault.token1()), address(usdc));
        assertEq(
            weth.allowance(address(vault), address(pool)),
            type(uint256).max
        );
        assertEq(
            usdc.allowance(address(vault), address(pool)),
            type(uint256).max
        );
        assertEq(address(vault.aave()), address(aave));
        assertEq(
            weth.allowance(address(vault), address(aave)),
            type(uint256).max
        );
        assertEq(
            usdc.allowance(address(vault), address(aave)),
            type(uint256).max
        );
        assertEq(address(vault.debtToken0()), address(debtToken0));
        assertEq(address(vault.aToken1()), address(aToken1));
        assertEq(vault.decimals(), IERC20Decimals(address(usdc)).decimals());

        assertEq(vault.depositCap(address(0)), DEPOSIT_CAP);
        assertEq(vault.totalDepositCap(), TOTAL_DEPOSIT_CAP);
        assertEq(vault.slippageBPS(), SLIPPAGE_BPS);
        assertEq(vault.tickSlippageBPS(), SLIPPAGE_TICK_BPS);
        assertEq(vault.maxLtv(), MAX_LTV);

        assertEq(vault.lowerTick(), lowerTick);
        assertEq(vault.upperTick(), upperTick);
    }

    function test_constructor_RevertTickSpacing() public {
        vm.expectRevert(bytes(Errors.TICKS));
        new OrangeAlphaVaultMock(
            "OrangeAlphaVault",
            "ORANGE_ALPHA_VAULT",
            6,
            address(pool),
            address(weth),
            address(usdc),
            address(aave),
            address(debtToken0),
            address(aToken1),
            101,
            upperTick
        );
    }

    /* ========== VIEW FUNCTIONS ========== */
    function test_totalAssets_Success() public {
        assertEq(vault.totalAssets(), 0); //zero

        vault.deposit(10_000 * 1e6, address(this), 9_900 * 1e6);
        // console2.log(vault.totalAssets(), "totalAssets");
        assertApproxEqRel(vault.totalAssets(), 10_000 * 1e6, 1e16);
    }

    function test_convertToShares_Success() public {
        assertEq(vault.convertToShares(0), 0); //zero

        vault.deposit(10_000 * 1e6, address(this), 9_900 * 1e6);
        uint256 _assets = 7500 * 1e6;
        // console2.log(vault.convertToShares(_assets), "convertToShares");
        assertEq(
            vault.convertToShares(_assets),
            _assets.mulDiv(vault.totalSupply(), vault.totalAssets() - _assets)
        );
    }

    function test_convertToAssets_Success() public {
        assertEq(vault.convertToAssets(0), 0); //zero

        vault.deposit(10_000 * 1e6, address(this), 9_900 * 1e6);
        uint256 _shares = 2500 * 1e6;
        // console2.log(vault.convertToAssets(_assets), "convertToAssets");
        assertEq(
            vault.convertToAssets(_shares),
            _shares.mulDiv(vault.totalAssets(), vault.totalSupply())
        );
    }

    function test_alignTotalAsset_Success0() public {
        //amount0Current == amount0Debt
        uint256 totalAlignedAssets = vault.alignTotalAsset(
            10 ether,
            10000 * 1e6,
            10 ether,
            14000 * 1e6
        );
        // console2.log(totalAlignedAssets, "totalAlignedAssets");
        assertEq(totalAlignedAssets, 10000 * 1e6 + 14000 * 1e6);
    }

    function test_alignTotalAsset_Success1() public {
        //amount0Current < amount0Debt
        uint256 totalAlignedAssets = vault.alignTotalAsset(
            10 ether,
            10000 * 1e6,
            11 ether,
            14000 * 1e6
        );
        // console2.log(totalAlignedAssets, "totalAlignedAssets");

        uint256 amount0deducted = 11 ether - 10 ether;
        amount0deducted = OracleLibrary.getQuoteAtTick(
            _ticks.currentTick,
            uint128(amount0deducted),
            address(weth),
            address(usdc)
        );
        assertEq(
            totalAlignedAssets,
            10000 * 1e6 + 14000 * 1e6 - amount0deducted
        );
    }

    function test_alignTotalAsset_Success2() public {
        //amount0Current > amount0Debt
        uint256 totalAlignedAssets = vault.alignTotalAsset(
            12 ether,
            10000 * 1e6,
            10 ether,
            14000 * 1e6
        );
        // console2.log(totalAlignedAssets, "totalAlignedAssets");

        uint256 amount0Added = 12 ether - 10 ether;
        amount0Added = OracleLibrary.getQuoteAtTick(
            _ticks.currentTick,
            uint128(amount0Added),
            address(weth),
            address(usdc)
        );
        assertEq(totalAlignedAssets, 10000 * 1e6 + 14000 * 1e6 + amount0Added);
    }

    function test_getUnderlyingBalances_Success0() public {
        //zero
        IOrangeAlphaVault.UnderlyingAssets memory _underlyingAssets = vault
            .getUnderlyingBalances();
        assertEq(_underlyingAssets.amount0Current, 0);
        assertEq(_underlyingAssets.amount1Current, 0);
        assertEq(_underlyingAssets.accruedFees0, 0);
        assertEq(_underlyingAssets.accruedFees1, 0);
        assertEq(_underlyingAssets.amount0Balance, 0);
        assertEq(_underlyingAssets.amount1Balance, 0);
    }

    function test_getUnderlyingBalances_Success1() public {
        vault.deposit(10_000 * 1e6, address(this), 9_900 * 1e6);
        IOrangeAlphaVault.UnderlyingAssets memory _underlyingAssets = vault
            .getUnderlyingBalances();
        //Greater than 0
        assertGt(_underlyingAssets.amount0Current, 0);
        assertGt(_underlyingAssets.amount1Current, 0);
        //zero
        assertEq(_underlyingAssets.accruedFees0, 0);
        assertEq(_underlyingAssets.accruedFees1, 0);
        //Greater than 0
        assertGt(_underlyingAssets.amount0Balance, 0);
        assertGt(_underlyingAssets.amount1Balance, 0);
    }

    function test_getUnderlyingBalances_Success2() public {
        vault.deposit(10_000 * 1e6, address(this), 9_900 * 1e6);
        multiSwapByCarol(); //swapped
        IOrangeAlphaVault.UnderlyingAssets memory _underlyingAssets = vault
            .getUnderlyingBalances();
        //Greater than 0
        assertGt(_underlyingAssets.amount0Current, 0);
        assertGt(_underlyingAssets.amount1Current, 0);
        //Greater than 0
        assertGt(_underlyingAssets.accruedFees0, 0);
        assertGt(_underlyingAssets.accruedFees1, 0);
        //Greater than 0
        assertGt(_underlyingAssets.amount0Balance, 0);
        assertGt(_underlyingAssets.amount1Balance, 0);
    }

    function assert_computeFeesEarned() internal {
        (
            uint128 liquidity,
            uint256 feeGrowthInside0Last,
            uint256 feeGrowthInside1Last,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = pool.positions(vault.getPositionID());

        uint256 accruedFees0 = vault.computeFeesEarned(
            true,
            feeGrowthInside0Last,
            liquidity
        ) + uint256(tokensOwed0);
        uint256 accruedFees1 = vault.computeFeesEarned(
            false,
            feeGrowthInside1Last,
            liquidity
        ) + uint256(tokensOwed1);
        console2.log(accruedFees0, "accruedFees0");
        console2.log(accruedFees1, "accruedFees1");

        // assert to fees collected acutually
        IOrangeAlphaVault.Ticks memory __ticks = vault.getTicksByStorage();
        (, , uint256 fee0_, uint256 fee1_, , ) = vault.burnAndCollectFees(
            __ticks.lowerTick,
            __ticks.upperTick,
            liquidity
        );
        console2.log(fee0_, "fee0_");
        console2.log(fee1_, "fee1_");
        assertEq(accruedFees0, fee0_);
        assertEq(accruedFees1, fee1_);
    }

    function test_computeFeesEarned_Success1() public {
        //current tick is in range
        vault.deposit(10_000 * 1e6, address(this), 9_900 * 1e6);
        multiSwapByCarol(); //swapped

        (, int24 _tick, , , , , ) = pool.slot0();
        console2.log(_tick.toString(), "currentTick");
        assert_computeFeesEarned();
    }

    function test_computeFeesEarned_Success2UnderRange() public {
        vault.deposit(10_000 * 1e6, address(this), 9_900 * 1e6);
        multiSwapByCarol(); //swapped

        swapByCarol(true, 1000 ether); //current price under lowerPrice
        // (, int24 __tick, , , , , ) = pool.slot0();
        // console2.log(__tick.toString(), "currentTick");
        assert_computeFeesEarned();
    }

    function test_computeFeesEarned_Success3OverRange() public {
        vault.deposit(10_000 * 1e6, address(this), 9_900 * 1e6);
        multiSwapByCarol(); //swapped

        swapByCarol(false, 1_000_000 * 1e6); //current price over upperPrice
        // (, int24 __tick, , , , , ) = pool.slot0();
        // console2.log(__tick.toString(), "currentTick");
        assert_computeFeesEarned();
    }

    function test_computeSupplyAndBorrow_Success() public {
        uint256 supply_;
        uint256 borrow_;
        //zero
        (supply_, borrow_) = vault.computeSupplyAndBorrow(0);
        assertEq(supply_, 0);
        assertEq(borrow_, 0);

        //assert ltv
        (supply_, borrow_) = vault.computeSupplyAndBorrow(10000 * 1e6);
        // console2.log(supply_, borrow_);

        uint256 _borrowUsdc = OracleLibrary.getQuoteAtTick(
            _ticks.currentTick,
            uint128(borrow_),
            address(weth),
            address(usdc)
        );
        uint256 _ltv = MAGIC_SCALE_1E8.mulDiv(_borrowUsdc, supply_);
        assertApproxEqAbs(_ltv, vault.getLtvByRange(), 1);
    }

    function test_getLtvByRange_Success1() public {
        uint256 _currentPrice = vault.quoteEthPriceByTick(_ticks.currentTick);
        // uint256 _lowerPrice = vault.quoteEthPriceByTick(_ticks.lowerTick);
        uint256 _upperPrice = vault.quoteEthPriceByTick(_ticks.upperTick);
        uint256 ltv_ = uint256(MAX_LTV).mulDiv(_currentPrice, _upperPrice);
        assertEq(ltv_, vault.getLtvByRange());
    }

    function test_getLtvByRange_Success2() public {
        swapByCarol(true, 1000 ether); //current price under lowerPrice
        // (, int24 _tick, , , , , ) = pool.slot0();
        // uint256 _currentPrice = vault.quoteEthPriceByTick(_tick);
        uint256 _lowerPrice = vault.quoteEthPriceByTick(_ticks.lowerTick);
        uint256 _upperPrice = vault.quoteEthPriceByTick(_ticks.upperTick);
        // console2.log(_currentPrice, "_currentPrice");
        console2.log(_lowerPrice, "_lowerPrice");
        console2.log(_upperPrice, "_upperPrice");
        uint256 ltv_ = uint256(MAX_LTV).mulDiv(_lowerPrice, _upperPrice);
        assertEq(ltv_, vault.getLtvByRange());
    }

    function test_getLtvByRange_Success3() public {
        swapByCarol(false, 1_000_000 * 1e6); //current price over upperPrice
        // (, int24 _tick, , , , , ) = pool.slot0();
        // uint256 _currentPrice = vault.quoteEthPriceByTick(_tick);
        // uint256 _upperPrice = vault.quoteEthPriceByTick(_ticks.upperTick);
        // console2.log(_currentPrice, "_currentPrice");
        // console2.log(_upperPrice, "_upperPrice");
        assertEq(MAX_LTV, vault.getLtvByRange());
    }

    function test_computeSwapAmount_Success0() public {
        //zero
        (bool _zeroForOne, int256 _swapAmount) = vault.computeSwapAmount(0, 0);
        assertEq(_zeroForOne, false);
        assertEq(_swapAmount, 0);
    }

    function assert_computeSwapAmount(uint256 _amount0, uint256 _amount1)
        private
    {
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            _ticks.sqrtRatioX96,
            _ticks.lowerTick.getSqrtRatioAtTick(),
            _ticks.upperTick.getSqrtRatioAtTick(),
            _amount0,
            _amount1
        );
        (uint256 amount0, uint256 amount1) = LiquidityAmounts
            .getAmountsForLiquidity(
                _ticks.sqrtRatioX96,
                _ticks.lowerTick.getSqrtRatioAtTick(),
                _ticks.upperTick.getSqrtRatioAtTick(),
                liquidity
            );
        console2.log(_amount0, "_amount0");
        console2.log(_amount1, "_amount1");
        console2.log(amount0, "amount0");
        console2.log(amount1, "amount1");
        assertApproxEqRel(_amount0, amount0, 1e24);
        assertApproxEqRel(_amount1, amount1, 1e24);
    }

    function test_computeSwapAmount_Success1() public {
        (bool _zeroForOne, int256 _swapAmount) = vault.computeSwapAmount(
            10 ether,
            0
        );
        assertEq(_zeroForOne, true);
        console2.log(_swapAmount.toString(), "_swapAmount");
        uint256 _amount0 = 10 ether - uint256(_swapAmount);
        uint256 _amount1 = OracleLibrary.getQuoteAtTick(
            _ticks.currentTick,
            uint128(uint256(_swapAmount)),
            address(weth),
            address(usdc)
        );
        assert_computeSwapAmount(_amount0, _amount1);
    }

    function test_computeSwapAmount_Success2() public {
        (bool _zeroForOne, int256 _swapAmount) = vault.computeSwapAmount(
            0,
            10000 * 1e6
        );
        assertEq(_zeroForOne, false);
        console2.log(_swapAmount.toString(), "_swapAmount");
        uint256 _amount1 = 10000 * 1e6 - uint256(_swapAmount);
        uint256 _amount0 = OracleLibrary.getQuoteAtTick(
            _ticks.currentTick,
            uint128(uint256(_swapAmount)),
            address(usdc),
            address(weth)
        );
        assert_computeSwapAmount(_amount0, _amount1);
    }

    function test_computeSwapAmount_Success3() public {
        //ether a little more then usdc
        (bool _zeroForOne, int256 _swapAmount) = vault.computeSwapAmount(
            8 ether,
            10000 * 1e6
        );
        console2.log(_zeroForOne, "_zeroForOne");
        assertEq(_zeroForOne, true);
        console2.log(_swapAmount.toString(), "_swapAmount");
        uint256 _amount0 = 8 ether - uint256(_swapAmount);
        uint256 _amount1 = 10000 *
            1e6 +
            OracleLibrary.getQuoteAtTick(
                _ticks.currentTick,
                uint128(uint256(_swapAmount)),
                address(weth),
                address(usdc)
            );
        assert_computeSwapAmount(_amount0, _amount1);
    }

    function test_depositCap_Success() public {
        assertEq(vault.depositCap(alice), DEPOSIT_CAP);
    }

    function test_canStoploss_Success1() public {
        assertEq(vault.canStoploss(), false);
        swapByCarol(true, 1000 ether); //current price under lowerPrice
        // console2.log(vault.getTwap().toString(), "twap");
        assertEq(vault.canStoploss(), false);
        // (, int24 _tick, , , , , ) = pool.slot0();
        // console2.log(_tick.toString(), "_tick");
        vault.setAvgTick(-206587);
        // console2.log(vault.getTwap().toString(), "twap");
        assertEq(vault.canStoploss(), true);
        vault.setStoplossed(true); //stoploss
        assertEq(vault.canStoploss(), false);
    }

    function test_isOutOfRange_Success1() public {
        assertEq(vault.isOutOfRange(0, 1, 2), true);
        assertEq(vault.isOutOfRange(0, -1, -2), true);
        assertEq(vault.isOutOfRange(0, -1, 1), false);
    }

    function test_checker_Success() public {
        bool canExec;
        bytes memory execPayload;
        (canExec, execPayload) = vault.checker();
        assertEq(canExec, false);
        assertEq(execPayload, bytes("can not stoploss"));
        swapByCarol(true, 1000 ether); //current price under lowerPrice
        vault.setAvgTick(-206587);
        (, int24 __tick, , , , , ) = pool.slot0();
        (canExec, execPayload) = vault.checker();
        assertEq(canExec, true);
        assertEq(
            execPayload,
            abi.encodeWithSelector(IOrangeAlphaVault.stoploss.selector, __tick)
        );
    }

    function test_getTicksByStorage_Success() public {
        IOrangeAlphaVault.Ticks memory __ticks = vault.getTicksByStorage();
        assertEq(__ticks.sqrtRatioX96, _ticks.sqrtRatioX96);
        assertEq(__ticks.currentTick, _ticks.currentTick);
        assertEq(__ticks.lowerTick, _ticks.lowerTick);
        assertEq(__ticks.upperTick, _ticks.upperTick);
    }

    function test_decimals_Success() public {
        assertEq(vault.decimals(), IERC20Decimals(address(usdc)).decimals());
    }

    /* ========== VIEW FUNCTIONS(INTERNAL) ========== */
    function test_validateTicks_Success() public {
        vault.validateTicks(60, 120);
        vm.expectRevert(bytes(Errors.TICKS));
        vault.validateTicks(120, 60);
        vm.expectRevert(bytes(Errors.TICKS));
        vault.validateTicks(61, 120);
        vm.expectRevert(bytes(Errors.TICKS));
        vault.validateTicks(60, 121);
    }

    function test_checkSlippage_Success1() public {
        assertEq(
            vault.checkSlippage(10000, true),
            uint160(FullMath.mulDiv(10000, SLIPPAGE_BPS, MAGIC_SCALE_1E4))
        );
        assertEq(
            vault.checkSlippage(10000, false),
            uint160(
                FullMath.mulDiv(
                    10000,
                    SLIPPAGE_BPS + MAGIC_SCALE_1E4,
                    MAGIC_SCALE_1E4
                )
            )
        );
    }

    function test_checkTickSlippage_Success1() public {
        vault.checkTickSlippage(0, 0);
        vm.expectRevert(bytes(Errors.HIGH_SLIPPAGE));
        vault.checkTickSlippage(10, 21);
    }

    function test_computePercentageFromUpperRange_Success1() public {
        uint256 _currentPrice = vault.quoteEthPriceByTick(_ticks.currentTick);
        uint256 _lowerPrice = vault.quoteEthPriceByTick(_ticks.lowerTick);
        uint256 _upperPrice = vault.quoteEthPriceByTick(_ticks.upperTick);

        uint256 _maxPriceRange = _upperPrice - _lowerPrice;
        uint256 _currentPriceFromUpper = _upperPrice - _currentPrice;
        uint256 parcentageFromUpper_ = (MAGIC_SCALE_1E8 *
            _currentPriceFromUpper) / _maxPriceRange;
        assertEq(
            vault.computePercentageFromUpperRange(_ticks),
            parcentageFromUpper_
        );
    }

    function test_computePercentageFromUpperRange_Success2UnderRange() public {
        swapByCarol(true, 1000 ether); //current price under lowerPrice
        (uint160 __sqrtRatioX96, int24 __tick, , , , , ) = pool.slot0();
        _ticks = IOrangeAlphaVault.Ticks(
            __sqrtRatioX96,
            __tick,
            lowerTick,
            upperTick
        );
        assertEq(
            vault.computePercentageFromUpperRange(_ticks),
            MAGIC_SCALE_1E8
        );
    }

    function test_computePercentageFromUpperRange_Success3OverRange() public {
        swapByCarol(false, 1_000_000 * 1e6); //current price over upperPrice
        (uint160 __sqrtRatioX96, int24 __tick, , , , , ) = pool.slot0();
        _ticks = IOrangeAlphaVault.Ticks(
            __sqrtRatioX96,
            __tick,
            lowerTick,
            upperTick
        );
        assertEq(vault.computePercentageFromUpperRange(_ticks), 0);
    }

    /* ========== EXTERNAL FUNCTIONS ========== */
    function test_deposit_Revert1() public {
        vm.expectRevert(bytes(Errors.DEPOSIT_RECEIVER));
        vault.deposit(10_000 * 1e6, alice, 9_900 * 1e6);
        vm.expectRevert(bytes(Errors.ZERO));
        vault.deposit(0, address(this), 9_900 * 1e6);
        vm.expectRevert(bytes(Errors.CAPOVER));
        vault.deposit(1_000_001 * 1e6, address(this), 9_900 * 1e6);
        vm.expectRevert(bytes(Errors.LESS));
        vault.deposit(10_000 * 1e6, address(this), 11_000 * 1e6);

        //revert with total deposit cap
        vm.prank(alice);
        vault.deposit(1_000_000 * 1e6, alice, 9_900 * 1e6);
        vm.expectRevert(bytes(Errors.CAPOVER));
        vault.deposit(10_000 * 1e6, address(this), 9_900 * 1e6);
    }

    function test_deposit_Success0() public {
        //initial depositing
        vault.deposit(10_000 * 1e6, address(this), 10_000 * 1e6);
        assertEq(vault.balanceOf(address(this)), 10_000 * 1e6);
    }

    function test_deposit_Success1() public {
        vault.deposit(10_000 * 1e6, address(this), 9_900 * 1e6);
        IOrangeAlphaVault.UnderlyingAssets memory _underlyingAssets = vault
            .getUnderlyingBalances();
        consoleUnderlyingAssets(_underlyingAssets);
        assertEq(vault.balanceOf(address(this)), 10_000 * 1e6);
        assertEq(usdc.balanceOf(address(this)), (10_000_000 - 10_000) * 1e6);
        (uint256 _deposit, ) = vault.deposits(address(this));
        assertEq(_deposit, 10_000 * 1e6);
        assertEq(vault.totalDeposits(), 10_000 * 1e6);
        // assert ltv
        uint256 _debtToken0 = debtToken0.balanceOf(address(vault));
        uint256 _aToken1 = aToken1.balanceOf(address(vault));
        // console2.log(_debtToken0, "_debtToken0");
        // console2.log(_aToken1, "aToken1");
        (, int24 _tick, , , , , ) = pool.slot0();
        uint256 _debtUsdc = OracleLibrary.getQuoteAtTick(
            _tick,
            uint128(_debtToken0),
            address(weth),
            address(usdc)
        );
        assertApproxEqRel(
            MAGIC_SCALE_1E8.mulDiv(_debtUsdc, _aToken1),
            vault.getLtvByRange(),
            1e16
        );
        // assert debt token0 amount nearly equals adding token0
        assertApproxEqRel(_debtToken0, _underlyingAssets.amount0Current, 1e16);
        console2.log(vault.totalAssets(), "totalAssets");
    }

    function test_deposit_Success2() public {
        //stoplossed
        vault.setStoplossed(true);
        vault.deposit(10_000 * 1e6, address(this), 9_900 * 1e6);
        assertEq(vault.balanceOf(address(this)), 10_000 * 1e6);
        assertEq(usdc.balanceOf(address(this)), (10_000_000 - 10_000) * 1e6);
        (uint256 _deposit, ) = vault.deposits(address(this));
        assertEq(_deposit, 10_000 * 1e6);
        assertEq(vault.totalDeposits(), 10_000 * 1e6);
        assertEq(debtToken0.balanceOf(address(vault)), 0);
        assertEq(aToken1.balanceOf(address(vault)), 0);
    }

    function test_redeem_Revert1() public {
        vm.expectRevert(bytes(Errors.ZERO));
        vault.redeem(0, address(this), address(0), 9_900 * 1e6);

        vault.deposit(10_000 * 1e6, address(this), 9_900 * 1e6);
        skip(1);
        vm.expectRevert(bytes(Errors.LOCKUP));
        vault.redeem(10_000 * 1e6, address(this), address(0), 9_900 * 1e6);

        vault.deposit(10_000 * 1e6, address(this), 0);
        // skip(8 days);
        // vm.expectRevert(bytes(Errors.LESS));
        // vault.redeem(10_000 * 1e6, address(this), address(0), 11_000 * 1e6);
        console2.log(vault.balanceOf(address(this)), "balanceOf");
    }

    function test_redeem_Success1Max() public {
        vault.deposit(10_000 * 1e6, address(this), 9_900 * 1e6);
        skip(8 days);
        vault.redeem(10_000 * 1e6, address(this), address(0), 9_900 * 1e6);
        //assertion
        assertEq(vault.balanceOf(address(this)), 0);
        (uint128 _liquidity, , , , ) = pool.positions(vault.getPositionID());
        assertEq(_liquidity, 0);
        assertEq(debtToken0.balanceOf(address(vault)), 0);
        assertEq(aToken1.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(weth.balanceOf(address(vault)), 0);
        assertApproxEqRel(
            usdc.balanceOf(address(this)),
            10_000_000 * 1e6,
            1e18
        );
    }

    function test_redeem_Success2Quater() public {
        vault.deposit(10_000 * 1e6, address(this), 9_900 * 1e6);
        skip(8 days);
        // prepare for assetion
        (uint128 _liquidity0, , , , ) = pool.positions(vault.getPositionID());
        uint256 _debtToken0 = debtToken0.balanceOf(address(vault));
        uint256 _aToken1 = aToken1.balanceOf(address(vault));

        //execute
        vault.redeem(7_500 * 1e6, address(this), address(0), 7_400 * 1e6);
        //assertion
        assertEq(vault.balanceOf(address(this)), 2_500 * 1e6);
        (uint128 _liquidity, , , , ) = pool.positions(vault.getPositionID());
        assertApproxEqAbs(_liquidity, _liquidity0 / 4, 1);
        assertApproxEqAbs(
            debtToken0.balanceOf(address(vault)),
            _debtToken0 / 4,
            1
        );
        assertApproxEqAbs(aToken1.balanceOf(address(vault)), _aToken1 / 4, 1);
        assertApproxEqRel(usdc.balanceOf(address(this)), 9_997_500 * 1e6, 1e18);
    }

    function test_redeem_Success3OverDeposit() public {
        vault.deposit(10_000 * 1e6, address(this), 9_900 * 1e6);
        skip(8 days);
        //reduce deposit log
        vault.setDeposits(address(this), 100);
        vault.setTotalDeposits(100);

        vault.redeem(10_000 * 1e6, address(this), address(0), 9_900 * 1e6);
        //assertion
        assertEq(vault.balanceOf(address(this)), 0);
        (uint128 _liquidity, , , , ) = pool.positions(vault.getPositionID());
        assertEq(_liquidity, 0);
        assertEq(debtToken0.balanceOf(address(vault)), 0);
        assertEq(aToken1.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(weth.balanceOf(address(vault)), 0);
        assertApproxEqRel(
            usdc.balanceOf(address(this)),
            10_000_000 * 1e6,
            1e18
        );
    }

    function test_emitAction_Success() public {
        //test in events section
    }

    function test_stoploss_Success() public {
        swapByCarol(true, 1000 ether); //current price under lowerPrice
        vault.setAvgTick(-206587);
        (, int24 __tick, , , , , ) = pool.slot0();
        vm.prank(vault.dedicatedMsgSender());
        vault.stoploss(__tick);
        assertEq(vault.stoplossed(), true);
    }

    function test_stoploss_Revert() public {
        vm.prank(vault.dedicatedMsgSender());
        vm.expectRevert(bytes(Errors.WHEN_CAN_STOPLOSS));
        vault.stoploss(1);
    }

    /* ========== OWNERS FUNCTIONS ========== */
    function test_rebalance_RevertRebalancer() public {
        //test rebalance
        vm.prank(alice);
        vm.expectRevert("Rebalancer");
        vault.rebalance(0, 0, 0);
    }

    function test_rebalance_RevertTickSpacing() public {
        int24 _newLowerTick = -1;
        int24 _newUpperTick = -205680;
        vm.expectRevert(bytes(Errors.TICKS));
        vault.rebalance(_newLowerTick, _newUpperTick, 1);
    }

    function test_rebalance_RevertNewLiquidity() public {
        //prepare
        vault.deposit(10_000 * 1e6, address(this), 9_900 * 1e6);
        skip(1);
        swapByCarol(true, 1000 ether); //current price under lowerPrice
        skip(1 days);
        uint256 _debtToken0 = debtToken0.balanceOf(address(vault));
        uint256 _aToken1 = aToken1.balanceOf(address(vault));
        (uint128 _liquidity, , , , ) = pool.positions(vault.getPositionID());
        //rebalance
        int24 _newLowerTick = -207540;
        int24 _newUpperTick = -205680;
        (, int24 __tick, , , , , ) = pool.slot0();
        vm.expectRevert(bytes(Errors.LESS));
        vault.rebalance(_newLowerTick, _newUpperTick, 2359131680723999);
    }

    function test_rebalance_Success0() public {
        //totalSupply is zero
        int24 _newLowerTick = -207540;
        int24 _newUpperTick = -205680;
        (, int24 __tick, , , , , ) = pool.slot0();
        vault.rebalance(_newLowerTick, _newUpperTick, 2359131680000000);
        assertEq(vault.lowerTick(), _newLowerTick);
        assertEq(vault.upperTick(), _newUpperTick);
        assertEq(vault.stoplossed(), false);
    }

    function test_rebalance_Success1UnderRange() public {
        //prepare
        vault.deposit(10_000 * 1e6, address(this), 9_900 * 1e6);
        skip(1);
        swapByCarol(true, 1000 ether); //current price under lowerPrice
        skip(1 days);
        uint256 _debtToken0 = debtToken0.balanceOf(address(vault));
        uint256 _aToken1 = aToken1.balanceOf(address(vault));
        (uint128 _liquidity, , , , ) = pool.positions(vault.getPositionID());
        //rebalance
        int24 _newLowerTick = -207540;
        int24 _newUpperTick = -205680;
        (, int24 __tick, , , , , ) = pool.slot0();
        vault.rebalance(_newLowerTick, _newUpperTick, 2359131680000000);
        assertEq(vault.lowerTick(), _newLowerTick);
        assertEq(vault.upperTick(), _newUpperTick);

        assertGt(debtToken0.balanceOf(address(vault)), _debtToken0); //more borrowing than before
        assertEq(aToken1.balanceOf(address(vault)), _aToken1);
        (uint128 _newLiquidity, , , , ) = pool.positions(vault.getPositionID());
        // console2.log(_newLiquidity, "_newLiquidity");
        assertApproxEqRel(_liquidity, _newLiquidity, 1e17);
    }

    function test_rebalance_Success2OverRange() public {
        //prepare
        vault.deposit(10_000 * 1e6, address(this), 9_900 * 1e6);
        skip(1);
        swapByCarol(false, 1_000_000 * 1e6); //current price over upperPrice
        (, int24 __tick, , , , , ) = pool.slot0();
        console2.log(__tick.toString(), "__tick");
        skip(1 days);
        uint256 _debtToken0 = debtToken0.balanceOf(address(vault));
        uint256 _aToken1 = aToken1.balanceOf(address(vault));
        (uint128 _liquidity, , , , ) = pool.positions(vault.getPositionID());
        //rebalance
        int24 _newLowerTick = -204600;
        int24 _newUpperTick = -202500;
        vault.rebalance(_newLowerTick, _newUpperTick, 1617216894672500);
        assertEq(vault.lowerTick(), _newLowerTick);
        assertEq(vault.upperTick(), _newUpperTick);
        assertLt(debtToken0.balanceOf(address(vault)), _debtToken0); //less borrowing than before
        assertEq(aToken1.balanceOf(address(vault)), _aToken1);
        (uint128 _newLiquidity, , , , ) = pool.positions(vault.getPositionID());
        console2.log(_newLiquidity, "_newLiquidity");
        assertApproxEqRel(_liquidity, _newLiquidity, 5e17);
    }

    function test_rebalance_Success3InRange() public {
        //prepare
        vault.deposit(10_000 * 1e6, address(this), 9_900 * 1e6);
        skip(1);
        (, int24 __tick, , , , , ) = pool.slot0();
        console2.log(__tick.toString(), "__tick");
        skip(1 days);
        uint256 _debtToken0 = debtToken0.balanceOf(address(vault));
        uint256 _aToken1 = aToken1.balanceOf(address(vault));
        (uint128 _liquidity, , , , ) = pool.positions(vault.getPositionID());
        //rebalance
        int24 _newLowerTick = -205620;
        int24 _newUpperTick = -203820;
        vault.rebalance(_newLowerTick, _newUpperTick, 2359131680000000);
        assertEq(vault.lowerTick(), _newLowerTick);
        assertEq(vault.upperTick(), _newUpperTick);
        assertApproxEqRel(
            debtToken0.balanceOf(address(vault)),
            _debtToken0,
            1e17
        );
        assertEq(aToken1.balanceOf(address(vault)), _aToken1);
        (uint128 _newLiquidity, , , , ) = pool.positions(vault.getPositionID());
        assertApproxEqRel(_liquidity, _newLiquidity, 1e17);
    }

    function test_removeAllPosition_Success0() public {
        (, int24 _tick, , , , , ) = pool.slot0();
        vault.removeAllPosition(_tick);
        IOrangeAlphaVault.Ticks memory __ticks = vault.getTicksByStorage();
        assertEq(__ticks.sqrtRatioX96, _ticks.sqrtRatioX96);
        assertEq(__ticks.currentTick, _ticks.currentTick);
        assertEq(__ticks.lowerTick, _ticks.lowerTick);
        assertEq(__ticks.upperTick, _ticks.upperTick);
    }

    function test_removeAllPosition_Success1() public {
        vault.deposit(10_000 * 1e6, address(this), 9_900 * 1e6);
        skip(1);
        (, int24 _tick, , , , , ) = pool.slot0();
        vault.removeAllPosition(_tick);
        //assertion
        (uint128 _liquidity, , , , ) = pool.positions(vault.getPositionID());
        assertEq(_liquidity, 0);
        assertEq(debtToken0.balanceOf(address(vault)), 0);
        assertEq(aToken1.balanceOf(address(vault)), 0);
        assertApproxEqRel(
            usdc.balanceOf(address(vault)),
            10_000_000 * 1e6,
            1e18
        );
        assertEq(weth.balanceOf(address(vault)), 0);
    }

    function test_removeAllPosition_Success2() public {
        //removeAllPosition when vault has no position
        vault.deposit(10_000 * 1e6, address(this), 9_900 * 1e6);
        skip(1);
        (, int24 _tick, , , , , ) = pool.slot0();
        vault.removeAllPosition(_tick);
        skip(1);
        vault.removeAllPosition(_tick);
        //assertion
        (uint128 _liquidity, , , , ) = pool.positions(vault.getPositionID());
        assertEq(_liquidity, 0);
        assertEq(debtToken0.balanceOf(address(vault)), 0);
        assertEq(aToken1.balanceOf(address(vault)), 0);
        assertApproxEqRel(
            usdc.balanceOf(address(vault)),
            10_000_000 * 1e6,
            1e18
        );
        assertEq(weth.balanceOf(address(vault)), 0);
    }

    function test_setDepositCap_Success() public {
        vm.expectRevert(bytes(Errors.PARAMS));
        vault.setDepositCap(DEPOSIT_CAP + 1, TOTAL_DEPOSIT_CAP);
        vault.setDepositCap(DEPOSIT_CAP, TOTAL_DEPOSIT_CAP);
        assertEq(vault.depositCap(address(0)), DEPOSIT_CAP);
        assertEq(vault.totalDepositCap(), TOTAL_DEPOSIT_CAP);
    }

    function test_setSlippage_Success() public {
        vm.expectRevert(bytes(Errors.PARAMS));
        vault.setSlippage(10001, SLIPPAGE_TICK_BPS);

        vault.setSlippage(SLIPPAGE_BPS, SLIPPAGE_TICK_BPS);
        assertEq(vault.slippageBPS(), SLIPPAGE_BPS);
        assertEq(vault.tickSlippageBPS(), SLIPPAGE_TICK_BPS);
    }

    function test_setMaxLtv_Success() public {
        vm.expectRevert(bytes(Errors.PARAMS));
        vault.setMaxLtv(100000001);
        vault.setMaxLtv(MAX_LTV);
        assertEq(vault.maxLtv(), MAX_LTV);
    }

    function test_setLockupPeriod_Success() public {
        vault.setLockupPeriod(1);
        assertEq(vault.lockupPeriod(), 1);
    }

    /* ========== WRITE FUNCTIONS(INTERNAL) ========== */
    function test_swapAndAddLiquidity_Revert1() public {
        vm.expectRevert(bytes(Errors.ADD_LIQUIDITY_AMOUNTS));
        vault.swapAndAddLiquidity(0, 0, _ticks);
    }

    function test_swapAndAddLiquidity_Success1() public {
        usdc.safeTransfer(address(vault), 10000 * 1e6);
        (
            uint128 liquidity_,
            uint256 amountDeposited0_,
            uint256 amountDeposited1_
        ) = vault.swapAndAddLiquidity(0, 10000 * 1e6, _ticks);
        console2.log(liquidity_, "liquidity_");
        console2.log(amountDeposited0_, "amountDeposited0_");
        console2.log(amountDeposited1_, "amountDeposited1_");
    }

    function test_swapAndAddLiquidity_Success2() public {
        uint256 amount0 = 8 ether;
        uint256 amount1 = 10000 * 1e6;
        weth.safeTransfer(address(vault), amount0);
        usdc.safeTransfer(address(vault), amount1);
        (
            uint128 liquidity_,
            uint256 amountDeposited0_,
            uint256 amountDeposited1_
        ) = vault.swapAndAddLiquidity(amount0, amount1, _ticks);
        console2.log(liquidity_, "liquidity_");
        console2.log(amountDeposited0_, "amountDeposited0_");
        console2.log(amountDeposited1_, "amountDeposited1_");
    }

    function test_swapAndAddLiquidity_Success3() public {
        // cannot do testing these cases
        // if (_swapAmount != 0) {
        // if (liquidity_ > 0) {
    }

    function test_burnShare_Success1() public {
        vault.deposit(10_000 * 1e6, address(this), 9_900 * 1e6);
        skip(1);
        IOrangeAlphaVault.UnderlyingAssets memory _underlyingAssets = vault
            .getUnderlyingBalances();

        (uint256 burnAndFees0_, uint256 burnAndFees1_, ) = vault.burnShare(
            10_000 * 1e6,
            10_000 * 1e6,
            vault.getTicksByStorage()
        );
        assertApproxEqRel(
            _underlyingAssets.amount0Current +
                _underlyingAssets.accruedFees0 +
                _underlyingAssets.amount0Balance,
            burnAndFees0_,
            1e16
        );
        assertApproxEqRel(
            _underlyingAssets.amount1Current +
                _underlyingAssets.accruedFees1 +
                _underlyingAssets.amount1Balance,
            burnAndFees1_,
            1e16
        );
    }

    function test_burnAndCollectFees_Success1() public {
        vault.deposit(10_000 * 1e6, address(this), 9_900 * 1e6);
        skip(1);
        (uint128 _liquidity, , , , ) = pool.positions(vault.getPositionID());
        IOrangeAlphaVault.UnderlyingAssets memory _underlyingAssets = vault
            .getUnderlyingBalances();
        (
            uint256 burn0_,
            uint256 burn1_,
            uint256 fee0_,
            uint256 fee1_,
            uint256 preBalance0_,
            uint256 preBalance1_
        ) = vault.burnAndCollectFees(
                _ticks.lowerTick,
                _ticks.upperTick,
                _liquidity
            );
        assertApproxEqRel(_underlyingAssets.amount0Current, burn0_, 1e16);
        assertApproxEqRel(_underlyingAssets.amount1Current, burn1_, 1e16);
        assertApproxEqRel(_underlyingAssets.accruedFees0, fee0_, 1e16);
        assertApproxEqRel(_underlyingAssets.accruedFees1, fee1_, 1e16);
        assertApproxEqRel(_underlyingAssets.amount0Balance, preBalance0_, 1e16);
        assertApproxEqRel(_underlyingAssets.amount1Balance, preBalance1_, 1e16);
    }

    /* ========== CALLBACK FUNCTIONS ========== */
    function test_uniswapV3MintCallback_Revert() public {
        vm.expectRevert(bytes(Errors.CALLBACK_CALLER));
        vault.uniswapV3MintCallback(0, 0, "");
    }

    function test_uniswapV3MintCallback_Success() public {
        vm.prank(address(pool));
        vault.uniswapV3MintCallback(0, 0, "");
        assertEq(weth.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);

        deal(address(weth), address(vault), 10 ether);
        deal(address(usdc), address(vault), 10_000 * 1e6);
        vm.prank(address(pool));
        vault.uniswapV3MintCallback(1 ether, 1_000 * 1e6, "");
        assertEq(weth.balanceOf(address(vault)), 9 ether);
        assertEq(usdc.balanceOf(address(vault)), 9_000 * 1e6);
    }

    function testuniswapV3SwapCallback_Revert() public {
        vm.expectRevert(bytes(Errors.CALLBACK_CALLER));
        vault.uniswapV3SwapCallback(0, 0, "");
    }

    function testuniswapV3SwapCallback_Success1() public {
        vm.prank(address(pool));
        vault.uniswapV3SwapCallback(0, 0, "");
        assertEq(weth.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);

        deal(address(weth), address(vault), 10 ether);
        deal(address(usdc), address(vault), 10_000 * 1e6);

        //amount0
        vm.prank(address(pool));
        vault.uniswapV3SwapCallback(1 ether, 0, "");
        assertEq(weth.balanceOf(address(vault)), 9 ether);
        assertEq(usdc.balanceOf(address(vault)), 10_000 * 1e6);
        //amount1
        vm.prank(address(pool));
        vault.uniswapV3SwapCallback(0, 1_000 * 1e6, "");
        assertEq(weth.balanceOf(address(vault)), 9 ether);
        assertEq(usdc.balanceOf(address(vault)), 9_000 * 1e6);
    }

    /* ========== EVENTS ========== */
    function test_eventRebalance_Success() public {
        vault.deposit(10_000 * 1e6, address(this), 9_900 * 1e6);
        skip(1);
        swapByCarol(true, 1000 ether); //current price under lowerPrice
        skip(1 days);
        //rebalance
        int24 _newLowerTick = -207540;
        int24 _newUpperTick = -205680;
        (, int24 _tick, , , , , ) = pool.slot0();
        vm.expectEmit(false, false, false, false);
        emit Rebalance(0, 0, 0, 0);
        vault.rebalance(_newLowerTick, _newUpperTick, 2359131680000000);
    }

    function test_eventRemoveAllPosition_Success() public {
        vault.deposit(10_000 * 1e6, address(this), 9_900 * 1e6);
        skip(1);
        (, int24 _tick, , , , , ) = pool.slot0();
        vm.expectEmit(false, false, false, false);
        emit RemoveAllPosition(0, 0, 0);
        vault.removeAllPosition(_tick);
    }

    function test_eventUpdateDepositCap_Success() public {
        vm.expectEmit(false, false, false, false);
        emit UpdateDepositCap(1_000_000, 1_000_000);
        vault.setDepositCap(1_000_000, 1_000_000);
    }

    function test_eventUpdateSlippage_Success() public {
        vm.expectEmit(false, false, false, false);
        emit UpdateSlippage(SLIPPAGE_BPS, SLIPPAGE_TICK_BPS);
        vault.setSlippage(SLIPPAGE_BPS, SLIPPAGE_TICK_BPS);
    }

    function test_eventUpdateMaxLtv_Success() public {
        vm.expectEmit(false, false, false, false);
        emit UpdateMaxLtv(0);
        vault.setMaxLtv(MAX_LTV);
    }

    function test_eventSwapAndAddLiquidity_Success() public {
        usdc.safeTransfer(address(vault), 10000 * 1e6);
        vm.expectEmit(false, false, false, false);
        emit SwapAndAddLiquidity(false, 0, 0, 0, 0, 0);
        vault.swapAndAddLiquidity(0, 10000 * 1e6, _ticks);
    }

    function test_eventBurnAndCollectFees_Success() public {
        vault.deposit(10_000 * 1e6, address(this), 9_900 * 1e6);
        skip(1);
        (uint128 _liquidity, , , , ) = pool.positions(vault.getPositionID());
        emit BurnAndCollectFees(0, 0, 0, 0);
        vault.burnAndCollectFees(
            _ticks.lowerTick,
            _ticks.upperTick,
            _liquidity
        );
    }

    function test_eventAction_Success() public {
        IOrangeAlphaVault.UnderlyingAssets memory _underlyingAssets = vault
            .getUnderlyingBalances();
        vm.expectEmit(false, false, false, false);
        emit Action(
            0,
            address(this),
            0,
            0,
            _underlyingAssets,
            0,
            0,
            _ticks.lowerTick.getSqrtRatioAtTick(),
            _ticks.upperTick.getSqrtRatioAtTick(),
            _ticks.sqrtRatioX96
        );
        vault.emitAction();
    }

    /* ========== TEST functions ========== */
    function swapByCarol(bool _zeroForOne, uint256 _amountIn)
        private
        returns (uint256 amountOut_)
    {
        ISwapRouter.ExactInputSingleParams memory params;
        if (_zeroForOne) {
            params = ISwapRouter.ExactInputSingleParams({
                tokenIn: address(weth),
                tokenOut: address(usdc),
                fee: 3000,
                recipient: msg.sender,
                deadline: block.timestamp,
                amountIn: _amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
        } else {
            params = ISwapRouter.ExactInputSingleParams({
                tokenIn: address(usdc),
                tokenOut: address(weth),
                fee: 3000,
                recipient: msg.sender,
                deadline: block.timestamp,
                amountIn: _amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
        }
        vm.prank(carol);
        amountOut_ = router.exactInputSingle(params);
    }

    function multiSwapByCarol() private {
        swapByCarol(true, 1 ether);
        swapByCarol(false, 2000 * 1e6);
        swapByCarol(true, 1 ether);
    }

    function consoleUnderlyingAssets(
        IOrangeAlphaVault.UnderlyingAssets memory _underlyingAssets
    ) private view {
        console2.log("++++++++++++++++consoleUnderlyingAssets++++++++++++++++");
        console2.log(_underlyingAssets.amount0Current, "amount0Current");
        console2.log(_underlyingAssets.amount1Current, "amount1Current");
        console2.log(_underlyingAssets.accruedFees0, "accruedFees0");
        console2.log(_underlyingAssets.accruedFees1, "accruedFees1");
        console2.log(_underlyingAssets.amount0Balance, "amount0Balance");
        console2.log(_underlyingAssets.amount1Balance, "amount1Balance");
        console2.log("++++++++++++++++consoleUnderlyingAssets++++++++++++++++");
    }
}

import {DataTypes} from "../../../contracts/vendor/aave/DataTypes.sol";

contract AaveMock {
    function getReserveData(address)
        external
        pure
        returns (DataTypes.ReserveData memory reserveData_)
    {
        DataTypes.ReserveConfigurationMap memory configuration;
        reserveData_ = DataTypes.ReserveData(
            configuration,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            address(0),
            address(0),
            address(0),
            address(0),
            0,
            0,
            0
        );
    }
}
