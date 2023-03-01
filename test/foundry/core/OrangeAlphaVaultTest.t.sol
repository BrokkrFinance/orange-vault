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
import {OrangeAlphaParameters} from "../../../contracts/core/OrangeAlphaParameters.sol";
import {IOpsProxyFactory} from "../../../contracts/libs/GelatoOps.sol";
import {TickMath} from "../../../contracts/vendor/uniswap/TickMath.sol";
import {OracleLibrary} from "../../../contracts/vendor/uniswap/OracleLibrary.sol";
import {FullMath, LiquidityAmounts} from "../../../contracts/vendor/uniswap/LiquidityAmounts.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

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
    OrangeAlphaParameters params;
    IUniswapV3Pool pool;
    IAaveV3Pool aave;
    IERC20 weth;
    IERC20 usdc;
    IERC20 debtToken0; //weth
    IERC20 aToken1; //usdc
    IOrangeAlphaVault.Ticks _ticks;

    int24 lowerTick = -205680;
    int24 upperTick = -203760;
    int24 stoplossLowerTick = -206280;
    int24 stoplossUpperTick = -203160;
    // currentTick = -204714;

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

        params = new OrangeAlphaParameters();
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
            address(params)
        );

        //set parameters
        params.setSlippage(SLIPPAGE_BPS, SLIPPAGE_TICK_BPS);
        params.setMaxLtv(MAX_LTV);
        params.setLockupPeriod(LOCKUP_PERIOD);
        params.setPeriphery(address(this));

        //set Ticks for testing
        (, int24 _tick, , , , , ) = pool.slot0();
        // console2.log(_tick.toString(), "tick");
        _ticks = IOrangeAlphaVault.Ticks(_tick, lowerTick, upperTick);
        //rebalance (set ticks)
        vault.rebalance(
            lowerTick,
            upperTick,
            stoplossLowerTick,
            stoplossUpperTick,
            0
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
    function test_onlyPeriphery_Revert() public {
        vm.startPrank(alice);
        vm.expectRevert(bytes(Errors.ONLY_PERIPHERY));
        vault.deposit(0, address(this), 0);
        vm.expectRevert(bytes(Errors.ONLY_PERIPHERY));
        vault.redeem(0, address(this), address(0), 0);
    }

    function test_onlyAdministrators_Revert() public {
        vm.startPrank(alice);
        vm.expectRevert(bytes(Errors.ONLY_ADMINISTRATOR));
        vault.removeAllPosition(0);
        vm.expectRevert(bytes(Errors.ONLY_ADMINISTRATOR));
        vault.rebalance(0, 0, 0, 0, 0);
    }

    /* ========== CONSTRUCTOR ========== */
    function test_constructor_Success() public {
        assertEq(vault.decimals(), IERC20Decimals(address(usdc)).decimals());
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
        // assertEq(address(vault.debtToken0()), address(debtToken0));
        // assertEq(address(vault.aToken1()), address(aToken1));
        assertEq(
            weth.allowance(address(vault), address(aave)),
            type(uint256).max
        );
        assertEq(
            usdc.allowance(address(vault), address(aave)),
            type(uint256).max
        );
        assertEq(address(vault.params()), address(params));
    }

    /* ========== VIEW FUNCTIONS ========== */
    function test_totalAssets_Success() public {
        assertEq(vault.totalAssets(), 0); //zero
        uint256 _shares = (vault.convertToShares(10_000 * 1e6) * 9900) /
            MAGIC_SCALE_1E4;

        vault.deposit(10_000 * 1e6, address(this), _shares);
        console2.log(vault.totalAssets(), "totalAssets");
        assertApproxEqRel(vault.totalAssets(), 10_000 * 1e6, 1e16);
    }

    function test_convertToShares_Success0() public {
        assertEq(vault.convertToShares(0), 0); //zero
    }

    function test_convertToShares_Success1() public {
        //assert shares after deposit
        uint256 _shares = vault.convertToShares(10_000 * 1e6);
        console2.log(_shares, "_shares");

        vault.deposit(11_000 * 1e6, address(this), _shares);

        uint256 _shares2 = vault.convertToShares(10_000 * 1e6);
        console2.log(_shares2, "_shares2");
        assertApproxEqRel(_shares2, _shares, 1e16);
    }

    function test_convertToShares_Success2() public {
        // stoplossed
        vault.setStoplossed(true);
        assertEq(vault.convertToShares(10_000 * 1e6), 0); //zero
    }

    function test_convertToShares_Success3() public {
        // stoplossed and after deposit
        uint256 _shares = (vault.convertToShares(10_000 * 1e6) * 9900) /
            MAGIC_SCALE_1E4;

        vault.deposit(10_000 * 1e6, address(this), _shares);
        // stoplossed
        vault.setStoplossed(true);
        skip(1);
        vault.removeAllPosition(_ticks.currentTick);
        uint256 _shares2 = vault.convertToShares(10_000 * 1e6);
        uint256 _bal = usdc.balanceOf(address(vault));
        uint256 _shares3 = _shares.mulDiv(10_000 * 1e6, _bal);
        assertApproxEqRel(_shares2, _shares3, 2e16);
    }

    function test_convertToShares_Success4() public {
        // _zeroForOne = false
        swapByCarol(true, 200 ether); // reduce price
        uint256 _shares = vault.convertToShares(10_000 * 1e6);
        console2.log(_shares, "_shares");
        //nothing to assert
    }

    function test_convertToAssets_Success() public {
        assertEq(vault.convertToAssets(0), 0); //zero

        //
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
        uint256 _shares = (vault.convertToShares(10_000 * 1e6) * 9900) /
            MAGIC_SCALE_1E4;

        vault.deposit(10_000 * 1e6, address(this), _shares);
        IOrangeAlphaVault.UnderlyingAssets memory _underlyingAssets = vault
            .getUnderlyingBalances();
        //zero
        assertGt(_underlyingAssets.amount0Current, 0);
        assertGt(_underlyingAssets.amount1Current, 0);
        //Greater than 0
        assertGt(_underlyingAssets.amount0Balance, 0);
        assertGt(_underlyingAssets.amount1Balance, 0);
    }

    function test_getUnderlyingBalances_Success2() public {
        uint256 _shares = (vault.convertToShares(10_000 * 1e6) * 9900) /
            MAGIC_SCALE_1E4;

        vault.deposit(10_000 * 1e6, address(this), _shares);
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

    function test_getRebalancedLiquidity_Success() public {
        vault.deposit(10_000 * 1e6, address(this), 9_900 * 1e6);
        uint128 _liquidity = vault.getRebalancedLiquidity(
            lowerTick,
            upperTick,
            stoplossLowerTick,
            stoplossUpperTick
        );

        (uint256 _supply, uint256 _borrow) = vault.computeSupplyAndBorrow(
            10_000 * 1e6,
            _ticks.currentTick,
            lowerTick,
            upperTick,
            stoplossLowerTick,
            stoplossUpperTick
        );
        uint256 remainingAmount = 10_000 * 1e6 - _supply;
        //compute liquidity
        uint128 _liquidity2 = LiquidityAmounts.getLiquidityForAmounts(
            _ticks.currentTick.getSqrtRatioAtTick(),
            lowerTick.getSqrtRatioAtTick(),
            upperTick.getSqrtRatioAtTick(),
            _borrow,
            remainingAmount
        );
        assertEq(_liquidity, _liquidity2);
    }

    //TODO assert more parameters
    function test_computeSupplyAndBorrow_Success() public {
        uint256 supply_;
        uint256 borrow_;
        //zero
        (supply_, borrow_) = vault.computeSupplyAndBorrow(
            0,
            _ticks.currentTick,
            lowerTick,
            upperTick,
            stoplossLowerTick,
            stoplossUpperTick
        );
        assertEq(supply_, 0);
        assertEq(borrow_, 0);

        //assert ltv
        (supply_, borrow_) = vault.computeSupplyAndBorrow(
            10000 * 1e6,
            _ticks.currentTick,
            lowerTick,
            upperTick,
            stoplossLowerTick,
            stoplossUpperTick
        );
        // console2.log(supply_, borrow_);

        uint256 _borrowUsdc = OracleLibrary.getQuoteAtTick(
            _ticks.currentTick,
            uint128(borrow_),
            address(weth),
            address(usdc)
        );
        uint256 _ltv = MAGIC_SCALE_1E8.mulDiv(_borrowUsdc, supply_);
        assertApproxEqAbs(
            _ltv,
            vault.getLtvByRange(_ticks.currentTick, stoplossUpperTick),
            1
        );
    }

    function test_getLtvByRange_Success1() public {
        uint256 _currentPrice = vault.quoteEthPriceByTick(_ticks.currentTick);
        uint256 _upperPrice = vault.quoteEthPriceByTick(stoplossUpperTick);
        uint256 ltv_ = uint256(MAX_LTV).mulDiv(_currentPrice, _upperPrice);
        assertEq(
            ltv_,
            vault.getLtvByRange(_ticks.currentTick, stoplossUpperTick)
        );
    }

    function test_getLtvByRange_Success2() public {
        swapByCarol(true, 1000 ether); //current price under lowerPrice
        (, int24 _tick, , , , , ) = pool.slot0();
        uint256 _currentPrice = vault.quoteEthPriceByTick(_tick);
        uint256 _upperPrice = vault.quoteEthPriceByTick(stoplossUpperTick);
        // console2.log(_currentPrice, "_currentPrice");
        console2.log(_upperPrice, "_upperPrice");
        uint256 ltv_ = uint256(MAX_LTV).mulDiv(_currentPrice, _upperPrice);
        assertEq(ltv_, vault.getLtvByRange(_tick, stoplossUpperTick));
    }

    function test_getLtvByRange_Success3() public {
        swapByCarol(false, 1_000_000 * 1e6); //current price over upperPrice
        (, int24 _tick, , , , , ) = pool.slot0();
        console2.log(_tick.toString(), "_tick");
        assertEq(MAX_LTV, vault.getLtvByRange(_tick, -203500));
    }

    function test_canStoploss_Success1() public {
        // int24 lowerTick = -205680;
        // int24 upperTick = -203760;
        // int24 stoplossLowerTick = -206280;
        // int24 stoplossUpperTick = -203160;
        // currentTick = -204714;
        assertEq(
            vault.canStoploss(
                _ticks.currentTick,
                stoplossLowerTick,
                stoplossUpperTick
            ),
            false
        );
        assertEq(
            vault.canStoploss(-300000, stoplossLowerTick, stoplossUpperTick),
            true
        );
        assertEq(
            vault.canStoploss(0, stoplossLowerTick, stoplossUpperTick),
            true
        );
        vault.setStoplossed(true); //stoploss
        assertEq(
            vault.canStoploss(
                _ticks.currentTick,
                stoplossLowerTick,
                stoplossUpperTick
            ),
            false
        );
    }

    /* ========== EXTERNAL FUNCTIONS ========== */
    function test_deposit_Revert1() public {
        vm.expectRevert(bytes(Errors.INVALID_AMOUNT));
        vault.deposit(0, address(this), 9_900 * 1e6);
        vm.expectRevert(bytes(Errors.INVALID_AMOUNT));
        vault.deposit(1000, address(this), 0);
    }

    // function test_deposit_Revert2() public {
    //     //reverts when stoplossed
    //     uint256 _shares = (vault.convertToShares(10_000 * 1e6) * 9900) /
    //         MAGIC_SCALE_1E4;
    //     vault.setStoplossed(true);
    //     vm.expectRevert(bytes(Errors.DEPOSIT_STOPLOSSED));

    //     vault.deposit(10_000 * 1e6, address(this), _shares);

    //     vault.setStoplossed(false);
    //     vault.deposit(10_000 * 1e6, address(this), _shares);
    //     skip(1);
    //     vault.removeAllPosition(_ticks.currentTick);
    //     vault.setStoplossed(true);
    //     vm.expectRevert(bytes(Errors.LESS));
    //     vault.deposit(1_000 * 1e6, address(this), _shares);
    // }

    //TODO deposit when stoplossed

    function test_deposit_Success0() public {
        //initial depositing
        uint256 _initialBalance = usdc.balanceOf(address(this));
        vault.deposit(10_000 * 1e6, address(this), 9_900 * 1e6);
        //assertion
        assertEq(vault.balanceOf(address(this)), 10_000 * 1e6);
        uint256 _realAssets = _initialBalance - usdc.balanceOf(address(this));
        assertEq(_realAssets, 10_000 * 1e6);
        assertEq(usdc.balanceOf(address(vault)), 10_000 * 1e6);
    }

    //TODO
    function test_deposit_Success1() public {
        // second depositing without liquidity
        vault.deposit(10_000 * 1e6, address(this), 9_900 * 1e6);
        uint256 _shares = (vault.convertToShares(10_000 * 1e6) * 9900) /
            MAGIC_SCALE_1E4;
        vault.deposit(10_000 * 1e6, address(this), _shares);
        //assertion
        assertEq(vault.balanceOf(address(this)), 19_900 * 1e6);
        assertEq(usdc.balanceOf(address(vault)), 19_900 * 1e6);
    }

    function test_deposit_Success2() public {
        // second depositing with liquidity
        vault.deposit(10_000 * 1e6, address(this), 9_900 * 1e6);
        vault.rebalance(
            lowerTick,
            upperTick,
            stoplossLowerTick,
            stoplossUpperTick,
            0
        );
        consoleUnderlyingAssets(vault.getUnderlyingBalances());

        uint256 _shares = (vault.convertToShares(10_000 * 1e6) * 9900) /
            MAGIC_SCALE_1E4;
        vault.deposit(10_000 * 1e6, address(this), _shares);
        //assertion
        uint256 _vaultShare = vault.balanceOf(address(this));
        console2.log(_vaultShare, "_vaultShare");
        consoleUnderlyingAssets(vault.getUnderlyingBalances());
        // assertEq(vault.balanceOf(address(this)), 19_900 * 1e6);
        // assertEq(usdc.balanceOf(address(vault)), 20_000 * 1e6);
    }

    //here

    function test_deposit_Success3() public {
        //stoplossed
        uint256 _shares = (vault.convertToShares(10_000 * 1e6) * 9900) /
            MAGIC_SCALE_1E4;

        vault.deposit(10_000 * 1e6, address(this), _shares);

        vault.setStoplossed(true);
        skip(1);
        vault.removeAllPosition(_ticks.currentTick);
        uint256 _shares2 = (vault.convertToShares(10_000 * 1e6) * 9900) /
            MAGIC_SCALE_1E4;
        vault.deposit(10_000 * 1e6, address(this), _shares2);
    }

    function test_redeem_Revert1() public {
        vm.expectRevert(bytes(Errors.INVALID_AMOUNT));
        vault.redeem(0, address(this), address(0), 9_900 * 1e6);

        uint256 _shares = (vault.convertToShares(10_000 * 1e6) * 9900) /
            MAGIC_SCALE_1E4;

        // vault.deposit(10_000 * 1e6, address(this), _shares);
        // skip(1);
        // vm.expectRevert(bytes(Errors.LOCKUP));
        // vault.redeem(10_000 * 1e6, address(this), address(0), 9_900 * 1e6);

        skip(8 days);
        vm.expectRevert(bytes(Errors.LESS_AMOUNT));
        vault.redeem(_shares, address(this), address(0), 100_900 * 1e6);
    }

    function test_redeem_Success1Max() public {
        uint256 _shares = (vault.convertToShares(10_000 * 1e6) * 9900) /
            MAGIC_SCALE_1E4;

        uint256 _realShares = vault.deposit(
            10_000 * 1e6,
            address(this),
            _shares
        );
        skip(8 days);

        uint256 _assets = (vault.convertToAssets(_realShares) * 9900) /
            MAGIC_SCALE_1E4;
        // console2.log(_assets, "assets");
        uint256 _realAssets = vault.redeem(
            _realShares,
            address(this),
            address(0),
            _assets
        );
        // console2.log(_realAssets, "realAssets");
        //assertion
        assertApproxEqRel(_assets, _realAssets, 1e16);
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
        uint256 _shares = (vault.convertToShares(10_000 * 1e6) * 9900) /
            MAGIC_SCALE_1E4;

        uint256 _realShares = vault.deposit(
            10_000 * 1e6,
            address(this),
            _shares
        );
        skip(8 days);
        // prepare for assetion
        (uint128 _liquidity0, , , , ) = pool.positions(vault.getPositionID());
        uint256 _debtToken0 = debtToken0.balanceOf(address(vault));
        uint256 _aToken1 = aToken1.balanceOf(address(vault));

        //execute
        uint256 _assets = (vault.convertToAssets(_realShares) * 9900) /
            MAGIC_SCALE_1E4;
        _assets = (_assets * 3) / 4;
        vault.redeem((_realShares * 3) / 4, address(this), address(0), _assets);
        // assertion
        assertApproxEqAbs(vault.balanceOf(address(this)), _realShares / 4, 1);
        (uint128 _liquidity, , , , ) = pool.positions(vault.getPositionID());
        assertApproxEqAbs(_liquidity, _liquidity0 / 4, 1);
        assertApproxEqRel(
            debtToken0.balanceOf(address(vault)),
            _debtToken0 / 4,
            1e12
        );
        assertApproxEqAbs(aToken1.balanceOf(address(vault)), _aToken1 / 4, 1);
        assertApproxEqRel(usdc.balanceOf(address(this)), 9_997_500 * 1e6, 1e18);
    }

    function test_redeem_Success3OverDeposit() public {
        uint256 _shares = (vault.convertToShares(10_000 * 1e6) * 9900) /
            MAGIC_SCALE_1E4;

        uint256 _realShares = vault.deposit(
            10_000 * 1e6,
            address(this),
            _shares
        );
        skip(8 days);
        //reduce deposit log
        // vault.setDeposits(address(this), 100);
        // vault.setTotalDeposits(100);

        uint256 _assets = (vault.convertToAssets(_realShares) * 9900) /
            MAGIC_SCALE_1E4;
        vault.redeem(_realShares, address(this), address(0), _assets);
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
        vm.prank(params.dedicatedMsgSender());
        vault.stoploss(__tick);
        assertEq(vault.stoplossed(), true);
    }

    function test_stoploss_Revert() public {
        vm.prank(params.dedicatedMsgSender());
        vm.expectRevert(bytes(Errors.CANNOT_STOPLOSS));
        vault.stoploss(1);
    }

    /* ========== OWNERS FUNCTIONS ========== */
    function test_rebalance_RevertTickSpacing() public {
        int24 _newLowerTick = -1;
        int24 _newUpperTick = -205680;
        vm.expectRevert(bytes(Errors.INVALID_TICKS));
        vault.rebalance(
            _newLowerTick,
            _newUpperTick,
            stoplossLowerTick,
            stoplossUpperTick,
            1
        );
    }

    function test_rebalance_RevertNewLiquidity() public {
        //prepare
        uint256 _shares = (vault.convertToShares(10_000 * 1e6) * 9900) /
            MAGIC_SCALE_1E4;

        vault.deposit(10_000 * 1e6, address(this), _shares);
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
        vm.expectRevert(bytes(Errors.LESS_LIQUIDITY));
        vault.rebalance(
            _newLowerTick,
            _newUpperTick,
            _newLowerTick,
            _newUpperTick,
            2359131680723999
        );
    }

    function test_rebalance_Success0() public {
        //totalSupply is zero
        int24 _newLowerTick = -207540;
        int24 _newUpperTick = -205680;
        int24 _newStoplossLowerTick = -208740;
        int24 _newStoplossUpperTick = -204480;
        vault.rebalance(
            _newLowerTick,
            _newUpperTick,
            _newStoplossLowerTick,
            _newStoplossUpperTick,
            0
        );
        assertEq(vault.lowerTick(), _newLowerTick);
        assertEq(vault.upperTick(), _newUpperTick);
        assertEq(vault.stoplossLowerTick(), _newStoplossLowerTick);
        assertEq(vault.stoplossUpperTick(), _newStoplossUpperTick);
        assertEq(vault.stoplossed(), false);
    }

    function test_rebalance_Success1() public {
        vault.deposit(10_000 * 1e6, address(this), 10_000 * 1e6);
        vault.rebalance(
            lowerTick,
            upperTick,
            stoplossLowerTick,
            stoplossUpperTick,
            0
        );
        consoleUnderlyingAssets(vault.getUnderlyingBalances());
    }

    // function test_rebalance_Success1UnderRange() public {
    //     //prepare
    //     uint256 _shares = (vault.convertToShares(10_000 * 1e6) * 9900) /
    //         MAGIC_SCALE_1E4;

    //     vault.deposit(10_000 * 1e6, address(this), _shares);
    //     skip(1);
    //     swapByCarol(true, 1000 ether); //current price under lowerPrice
    //     skip(1 days);
    //     uint256 _debtToken0 = debtToken0.balanceOf(address(vault));
    //     uint256 _aToken1 = aToken1.balanceOf(address(vault));
    //     (uint128 _liquidity, , , , ) = pool.positions(vault.getPositionID());
    //     //rebalance
    //     int24 _newLowerTick = -207540;
    //     int24 _newUpperTick = -205680;
    //     (, int24 __tick, , , , , ) = pool.slot0();
    //     vault.rebalance(
    //         _newLowerTick,
    //         _newUpperTick,
    //         _newLowerTick,
    //         _newUpperTick,
    //         _liquidity
    //     );
    //     // assertEq(vault.lowerTick(), _newLowerTick);
    //     // assertEq(vault.upperTick(), _newUpperTick);

    //     assertGt(debtToken0.balanceOf(address(vault)), _debtToken0); //more borrowing than before
    //     assertEq(aToken1.balanceOf(address(vault)), _aToken1);
    //     (uint128 _newLiquidity, , , , ) = pool.positions(vault.getPositionID());
    //     // console2.log(_newLiquidity, "_newLiquidity");
    //     assertApproxEqRel(_liquidity, _newLiquidity, 1e17);
    // }

    // function test_rebalance_Success2OverRange() public {
    //     //prepare
    //     uint256 _shares = (vault.convertToShares(10_000 * 1e6) * 9900) /
    //         MAGIC_SCALE_1E4;

    //     vault.deposit(10_000 * 1e6, address(this), _shares);
    //     skip(1);
    //     swapByCarol(false, 1_000_000 * 1e6); //current price over upperPrice
    //     (, int24 __tick, , , , , ) = pool.slot0();
    //     // console2.log(__tick.toString(), "__tick");
    //     skip(1 days);
    //     uint256 _debtToken0 = debtToken0.balanceOf(address(vault));
    //     uint256 _aToken1 = aToken1.balanceOf(address(vault));
    //     (uint128 _liquidity, , , , ) = pool.positions(vault.getPositionID());
    //     //rebalance
    //     int24 _newLowerTick = -204600;
    //     int24 _newUpperTick = -202500;
    //     uint128 _estimatedNewLiquidity = vault.computeNewLiquidity(
    //         _newLowerTick,
    //         _newUpperTick,
    //         stoplossLowerTick,
    //         stoplossUpperTick
    //     );
    //     // console2.log(_estimatedNewLiquidity, "_estimatedNewLiquidity");
    //     vault.rebalance(
    //         _newLowerTick,
    //         _newUpperTick,
    //         stoplossLowerTick,
    //         stoplossUpperTick,
    //         (_estimatedNewLiquidity * 8000) / MAGIC_SCALE_1E4
    //     );
    //     // assertEq(vault.lowerTick(), _newLowerTick);
    //     // assertEq(vault.upperTick(), _newUpperTick);
    //     // console2.log(vault.totalAssets(), "totalAssets");
    //     assertLt(debtToken0.balanceOf(address(vault)), _debtToken0); //less borrowing than before
    //     assertEq(aToken1.balanceOf(address(vault)), _aToken1);
    //     (uint128 _newLiquidity, , , , ) = pool.positions(vault.getPositionID());
    //     // console2.log(_newLiquidity, "_newLiquidity");
    //     assertApproxEqRel(_liquidity, _newLiquidity, 5e17);
    // }

    // function test_rebalance_Success3InRange() public {
    //     //prepare
    //     uint256 _shares = (vault.convertToShares(10_000 * 1e6) * 9900) /
    //         MAGIC_SCALE_1E4;

    //     vault.deposit(10_000 * 1e6, address(this), _shares);
    //     skip(1);
    //     (, int24 __tick, , , , , ) = pool.slot0();
    //     console2.log(__tick.toString(), "__tick");
    //     skip(1 days);
    //     uint256 _debtToken0 = debtToken0.balanceOf(address(vault));
    //     uint256 _aToken1 = aToken1.balanceOf(address(vault));
    //     (uint128 _liquidity, , , , ) = pool.positions(vault.getPositionID());
    //     //rebalance
    //     int24 _newLowerTick = -205620;
    //     int24 _newUpperTick = -203820;
    //     vault.rebalance(
    //         _newLowerTick,
    //         _newUpperTick,
    //         stoplossLowerTick,
    //         stoplossUpperTick,
    //         _liquidity
    //     );
    //     // assertEq(vault.lowerTick(), _newLowerTick);
    //     // assertEq(vault.upperTick(), _newUpperTick);
    //     assertApproxEqRel(
    //         debtToken0.balanceOf(address(vault)),
    //         _debtToken0,
    //         1e17
    //     );
    //     assertEq(aToken1.balanceOf(address(vault)), _aToken1);
    //     (uint128 _newLiquidity, , , , ) = pool.positions(vault.getPositionID());
    //     assertApproxEqRel(_liquidity, _newLiquidity, 1e17);
    // }

    function test_removeAllPosition_Success0() public {
        (, int24 _tick, , , , , ) = pool.slot0();
        vault.removeAllPosition(_tick);
        IOrangeAlphaVault.Ticks memory __ticks = vault.getTicksByStorage();
        assertEq(
            __ticks.currentTick.getSqrtRatioAtTick(),
            _ticks.currentTick.getSqrtRatioAtTick()
        );
        assertEq(__ticks.currentTick, _ticks.currentTick);
        assertEq(__ticks.lowerTick, _ticks.lowerTick);
        assertEq(__ticks.upperTick, _ticks.upperTick);
    }

    function test_removeAllPosition_Success1() public {
        uint256 _shares = (vault.convertToShares(10_000 * 1e6) * 9900) /
            MAGIC_SCALE_1E4;

        vault.deposit(10_000 * 1e6, address(this), _shares);
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
        uint256 _shares = (vault.convertToShares(10_000 * 1e6) * 9900) /
            MAGIC_SCALE_1E4;

        vault.deposit(10_000 * 1e6, address(this), _shares);
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

    function test_setTicks_RevertTickSpacing() public {
        vm.expectRevert(bytes(Errors.INVALID_TICKS));
        vault.rebalance(
            101,
            upperTick,
            stoplossLowerTick,
            stoplossUpperTick,
            1
        );
    }

    function test_burnShare_Success1() public {
        uint256 _shares = (vault.convertToShares(10_000 * 1e6) * 9900) /
            MAGIC_SCALE_1E4;

        vault.deposit(10_000 * 1e6, address(this), _shares);
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
        uint256 _shares = (vault.convertToShares(10_000 * 1e6) * 9900) /
            MAGIC_SCALE_1E4;

        vault.deposit(10_000 * 1e6, address(this), _shares);
        skip(1);
        (uint128 _liquidity, , , , ) = pool.positions(vault.getPositionID());
        IOrangeAlphaVault.UnderlyingAssets memory _underlyingAssets = vault
            .getUnderlyingBalances();
        (uint256 burn0_, uint256 burn1_, uint256 fee0_, uint256 fee1_) = vault
            .burnAndCollectFees(_ticks.lowerTick, _ticks.upperTick, _liquidity);
        assertApproxEqRel(_underlyingAssets.amount0Current, burn0_, 1e16);
        assertApproxEqRel(_underlyingAssets.amount1Current, burn1_, 1e16);
        assertApproxEqRel(_underlyingAssets.accruedFees0, fee0_, 1e16);
        assertApproxEqRel(_underlyingAssets.accruedFees1, fee1_, 1e16);
    }

    /* ========== VIEW FUNCTIONS(INTERNAL) ========== */
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
        (, , uint256 fee0_, uint256 fee1_) = vault.burnAndCollectFees(
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

    function test_getTicksByStorage_Success() public {
        IOrangeAlphaVault.Ticks memory __ticks = vault.getTicksByStorage();
        assertEq(
            __ticks.currentTick.getSqrtRatioAtTick(),
            _ticks.currentTick.getSqrtRatioAtTick()
        );
        assertEq(__ticks.currentTick, _ticks.currentTick);
        assertEq(__ticks.lowerTick, _ticks.lowerTick);
        assertEq(__ticks.upperTick, _ticks.upperTick);
    }

    function test_validateTicks_Success() public {
        vault.validateTicks(60, 120);
        vm.expectRevert(bytes(Errors.INVALID_TICKS));
        vault.validateTicks(120, 60);
        vm.expectRevert(bytes(Errors.INVALID_TICKS));
        vault.validateTicks(61, 120);
        vm.expectRevert(bytes(Errors.INVALID_TICKS));
        vault.validateTicks(60, 121);
    }

    function test_setSlippage_Success1() public {
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

    /* ========== CALLBACK FUNCTIONS ========== */
    function test_uniswapV3Callback_Revert() public {
        vm.expectRevert(bytes(Errors.ONLY_CALLBACK_CALLER));
        vault.uniswapV3MintCallback(0, 0, "");
        vm.expectRevert(bytes(Errors.ONLY_CALLBACK_CALLER));
        vault.uniswapV3SwapCallback(0, 0, "");
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
    function test_eventAction_Success() public {
        IOrangeAlphaVault.UnderlyingAssets memory _underlyingAssets = vault
            .getUnderlyingBalances();
        vm.expectEmit(false, false, false, false);
        emit Action(0, address(this), 0, 0);
        vault.emitAction();
    }

    /* ========== TEST functions ========== */
    function swapByCarol(bool _zeroForOne, uint256 _amountIn)
        private
        returns (uint256 amountOut_)
    {
        ISwapRouter.ExactInputSingleParams memory inputParams;
        if (_zeroForOne) {
            inputParams = ISwapRouter.ExactInputSingleParams({
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
            inputParams = ISwapRouter.ExactInputSingleParams({
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
        amountOut_ = router.exactInputSingle(inputParams);
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
