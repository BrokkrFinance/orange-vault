// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.16;

import "@test/foundry/utils/BaseTest.sol";

import {CamelotV3LiquidityPoolManager} from "../../../contracts/poolManager/CamelotV3LiquidityPoolManager.sol";

import {IAlgebraPool} from "../../../contracts/vendor/algebra/IAlgebraPool.sol";
import {IDataStorageOperator} from "../../../contracts/vendor/algebra/IDataStorageOperator.sol";
import {IAlgebraSwapCallback} from "../../../contracts/vendor/algebra/callback/IAlgebraSwapCallback.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TickMath} from "../../../contracts/libs/uniswap/TickMath.sol";
import {FullMath} from "../../../contracts/libs/uniswap/LiquidityAmounts.sol";
import {ARB_FORK_BLOCK_CAMELOT} from "../Config.sol";

contract CamelotV3LiquidityPoolManagerTest is BaseTest, IAlgebraSwapCallback {
    using SafeERC20 for IERC20;
    using TickMath for int24;
    using FullMath for uint256;
    using Ints for int24;
    using Ints for int256;

    AddressHelper.TokenAddr public tokenAddr;
    AddressHelper.UniswapAddr public uniswapAddr;
    AddressHelperV2.CamelotAddr camelotAddr;

    CamelotV3LiquidityPoolManager public liquidityPool;
    IAlgebraPool public pool;
    IDataStorageOperator public dataStorage;
    ISwapRouter public router;
    IERC20 public token0;
    IERC20 public token1;

    int24 public lowerTick = -202440;
    int24 public upperTick = -200040;
    int24 public currentTick;

    function setUp() public virtual {
        vm.createSelectFork("arb", ARB_FORK_BLOCK_CAMELOT);

        (tokenAddr, , uniswapAddr) = AddressHelper.addresses(block.chainid);
        (, camelotAddr) = AddressHelperV2.addresses(block.chainid);

        pool = IAlgebraPool(camelotAddr.wethUsdcePoolAddr);
        token0 = IERC20(tokenAddr.wethAddr);
        token1 = IERC20(tokenAddr.usdcAddr);
        router = ISwapRouter(uniswapAddr.routerAddr);

        liquidityPool = new CamelotV3LiquidityPoolManager(address(token0), address(token1), address(pool));
        liquidityPool.setVault(address(this));

        //set Ticks for testing
        (, int24 _tick, , , , , , ) = pool.globalState();
        currentTick = _tick;
        console2.log("currentTick", currentTick.toString());
        int24 spac = pool.tickSpacing();
        console2.log(spac.toString(), "tickSpacing");

        //deal
        deal(tokenAddr.wethAddr, address(this), 10_000 ether);
        deal(tokenAddr.usdcAddr, address(this), 10_000_000 * 1e6);
        // deal(tokenAddr.wethAddr, carol, 10_000 ether);
        // deal(tokenAddr.usdcAddr, carol, 10_000_000 * 1e6);

        //approve
        token0.approve(address(liquidityPool), type(uint256).max);
        token1.approve(address(liquidityPool), type(uint256).max);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
    }

    function test_onlyOperator_Revert() public {
        vm.expectRevert(bytes("ONLY_VAULT"));
        vm.prank(alice);
        liquidityPool.mint(lowerTick, upperTick, 0);

        vm.expectRevert(bytes("ONLY_VAULT"));
        vm.prank(alice);
        liquidityPool.burnAndCollect(lowerTick, upperTick, 0);

        vm.expectRevert(bytes("ONLY_CALLBACK_CALLER"));
        vm.prank(alice);
        liquidityPool.algebraMintCallback(0, 0, bytes(""));
    }

    function test_onlyOwner_Revert() public {
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        vm.prank(alice);
        liquidityPool.setPerfFeeRecipient(address(0));

        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        vm.prank(alice);
        liquidityPool.setPerfFeeDivisor(0);
    }

    function test_constructor_Success() public {
        assertEq(liquidityPool.reversed(), false);
        liquidityPool = new CamelotV3LiquidityPoolManager(address(token1), address(token0), address(pool));
        liquidityPool.setVault(address(this));
        assertEq(liquidityPool.reversed(), true);
    }

    function test_setVault() public {
        vm.expectRevert(bytes("ALREADY_SET"));
        liquidityPool.setVault(address(this));
    }

    function test_getTwap_Success() public {
        int24 _twap = liquidityPool.getTwap(5 minutes);
        uint32[] memory secondsAgo = new uint32[](2);
        secondsAgo[0] = 5 minutes;
        secondsAgo[1] = 0;
        (int56[] memory tickCumulatives, , , ) = pool.getTimepoints(secondsAgo);
        int24 avgTick = int24((tickCumulatives[1] - tickCumulatives[0]) / int56(uint56(5 minutes)));
        assertEq(avgTick, _twap);
    }

    function test_validateTicks_Revert() public {
        vm.expectRevert(bytes("INVALID_TICKS"));
        liquidityPool.validateTicks(1, upperTick);
        vm.expectRevert(bytes("INVALID_TICKS"));
        liquidityPool.validateTicks(lowerTick, 1);
        vm.expectRevert(bytes("INVALID_TICKS"));
        liquidityPool.validateTicks(upperTick, lowerTick);
    }

    function test_burnAndCollect_ReturnsZero() public {
        liquidityPool.setPerfFeeRecipient(david);
        liquidityPool.setPerfFeeDivisor(20); // 5%

        (uint256 _burned0, uint256 _burned1) = liquidityPool.burnAndCollect(lowerTick, upperTick, 0);

        assertEq(_burned0, 0);
        assertEq(_burned1, 0);
    }

    function test_all_Success() public {
        // _consoleBalance();

        //compute liquidity
        uint128 _liquidity = liquidityPool.getLiquidityForAmounts(lowerTick, upperTick, 1 ether, 2000 * 1e6);

        //mint
        (uint _amount0, uint _amount1) = liquidityPool.mint(lowerTick, upperTick, _liquidity);
        console2.log(_amount0, _amount1);

        //assertion of mint
        (uint _amount0_, uint _amount1_) = liquidityPool.getAmountsForLiquidity(lowerTick, upperTick, _liquidity);
        assertEq(_amount0, _amount0_ + 1);
        assertEq(_amount1, _amount1_ + 1);

        uint128 _liquidity2 = liquidityPool.getCurrentLiquidity(lowerTick, upperTick);
        console2.log(_liquidity2, "liquidity2");
        // assertEq(_liquidity, _liquidity2);
        // _consoleBalance();

        //swap
        multiSwapByCarol();

        //compute current fee and position
        (uint256 fee0, uint256 fee1) = liquidityPool.getFeesEarned(lowerTick, upperTick);
        console2.log(fee0, fee1);
        (_amount0, _amount1) = liquidityPool.getAmountsForLiquidity(lowerTick, upperTick, _liquidity);
        uint _balance0 = token0.balanceOf(address(this));
        uint _balance1 = token1.balanceOf(address(this));

        // burn and collect
        (uint burn0_, uint burn1_) = liquidityPool.burnAndCollect(lowerTick, upperTick, _liquidity);
        assertEq(_amount0, burn0_);
        assertEq(_amount1, burn1_);
        _consoleBalance();

        assertEq(_balance0 + fee0 + burn0_, token0.balanceOf(address(this)));
        assertEq(_balance1 + fee1 + burn1_, token1.balanceOf(address(this)));
        _consoleBalance();
    }

    function test_allWithPerfFee_Success() public {
        liquidityPool.setPerfFeeRecipient(david);
        liquidityPool.setPerfFeeDivisor(20); // 5%

        //compute liquidity
        uint128 _liquidity = liquidityPool.getLiquidityForAmounts(lowerTick, upperTick, 1 ether, 1000 * 1e6);

        //mint
        (uint _amount0, uint _amount1) = liquidityPool.mint(lowerTick, upperTick, _liquidity);

        //assertion of mint
        (uint _amount0_, uint _amount1_) = liquidityPool.getAmountsForLiquidity(lowerTick, upperTick, _liquidity);
        assertEq(_amount0, _amount0_ + 1);
        assertEq(_amount1, _amount1_ + 1);

        uint128 _liquidity2 = liquidityPool.getCurrentLiquidity(lowerTick, upperTick);
        assertEq(_liquidity, _liquidity2);

        //swap
        multiSwapByCarol();

        //compute current fee and position
        (uint256 fee0, uint256 fee1) = liquidityPool.getFeesEarned(lowerTick, upperTick);
        (_amount0, _amount1) = liquidityPool.getAmountsForLiquidity(lowerTick, upperTick, _liquidity);
        uint _balance0 = token0.balanceOf(address(this));
        uint _balance1 = token1.balanceOf(address(this));

        // burn and collect
        (uint burn0_, uint burn1_) = liquidityPool.burnAndCollect(lowerTick, upperTick, _liquidity);
        assertEq(_amount0, burn0_);
        assertEq(_amount1, burn1_);

        // 5% of fee
        (uint _perfFee0, uint _perfFee1) = (fee0 / 20, fee1 / 20);

        assertEq(token0.balanceOf(david), _perfFee0);
        assertEq(token1.balanceOf(david), _perfFee1);
        assertEq(token0.balanceOf(address(this)), _balance0 + fee0 - _perfFee0 + burn0_);
        assertEq(token1.balanceOf(address(this)), _balance1 + fee1 - _perfFee1 + burn1_);
    }

    function test_allWithZeroFee_Success() public {
        liquidityPool.setPerfFeeRecipient(david);
        liquidityPool.setPerfFeeDivisor(0); // no performance fee

        //compute liquidity
        uint128 _liquidity = liquidityPool.getLiquidityForAmounts(lowerTick, upperTick, 1 ether, 1000 * 1e6);

        //mint
        (uint _amount0, uint _amount1) = liquidityPool.mint(lowerTick, upperTick, _liquidity);

        //assertion of mint
        (uint _amount0_, uint _amount1_) = liquidityPool.getAmountsForLiquidity(lowerTick, upperTick, _liquidity);
        assertEq(_amount0, _amount0_ + 1);
        assertEq(_amount1, _amount1_ + 1);

        uint128 _liquidity2 = liquidityPool.getCurrentLiquidity(lowerTick, upperTick);
        assertEq(_liquidity, _liquidity2);

        //swap
        multiSwapByCarol();

        //compute current fee and position
        (uint256 fee0, uint256 fee1) = liquidityPool.getFeesEarned(lowerTick, upperTick);
        (_amount0, _amount1) = liquidityPool.getAmountsForLiquidity(lowerTick, upperTick, _liquidity);
        uint _balance0 = token0.balanceOf(address(this));
        uint _balance1 = token1.balanceOf(address(this));

        // burn and collect
        (uint burn0_, uint burn1_) = liquidityPool.burnAndCollect(lowerTick, upperTick, _liquidity);
        assertEq(_amount0, burn0_);
        assertEq(_amount1, burn1_);

        assertEq(token0.balanceOf(david), 0);
        assertEq(token1.balanceOf(david), 0);
        assertEq(token0.balanceOf(address(this)), _balance0 + fee0 + burn0_);
        assertEq(token1.balanceOf(address(this)), _balance1 + fee1 + burn1_);
    }

    function test_allReverse_Success() public {
        //re-deploy contract
        liquidityPool = new CamelotV3LiquidityPoolManager(address(token1), address(token0), address(pool));
        liquidityPool.setVault(address(this));
        token0.approve(address(liquidityPool), type(uint256).max);
        token1.approve(address(liquidityPool), type(uint256).max);

        // _consoleBalance();

        //compute liquidity
        uint128 _liquidity = liquidityPool.getLiquidityForAmounts(lowerTick, upperTick, 1000 * 1e6, 1 ether);

        //mint
        (uint _amount0, uint _amount1) = liquidityPool.mint(lowerTick, upperTick, _liquidity);
        console2.log(_amount0, _amount1);

        //assertion of mint
        (uint _amount0_, uint _amount1_) = liquidityPool.getAmountsForLiquidity(lowerTick, upperTick, _liquidity);
        assertEq(_amount0, _amount0_ + 1);
        assertEq(_amount1, _amount1_ + 1);

        uint128 _liquidity2 = liquidityPool.getCurrentLiquidity(lowerTick, upperTick);
        console2.log(_liquidity2, "liquidity2");
        assertEq(_liquidity, _liquidity2);
        // _consoleBalance();

        //swap
        multiSwapByCarol();

        //compute current fee and position
        (uint256 fee0, uint256 fee1) = liquidityPool.getFeesEarned(lowerTick, upperTick);
        console2.log(fee0, fee1);
        (_amount0, _amount1) = liquidityPool.getAmountsForLiquidity(lowerTick, upperTick, _liquidity);
        uint _balance0 = token1.balanceOf(address(this));
        uint _balance1 = token0.balanceOf(address(this));

        // burn and collect
        (uint burn0_, uint burn1_) = liquidityPool.burnAndCollect(lowerTick, upperTick, _liquidity);
        assertEq(_amount0, burn0_);
        assertEq(_amount1, burn1_);

        assertEq(_balance0 + fee0 + burn0_, token1.balanceOf(address(this)));
        assertEq(_balance1 + fee1 + burn1_, token0.balanceOf(address(this)));
        // _consoleBalance();
    }

    /* ========== TEST functions ========== */
    function swapByCarol(bool _zeroForOne, uint256 _amountIn) internal {
        int256 _swapAmount = int256(_amountIn);
        (, int24 _tick, , , , , , ) = pool.globalState();
        if (_zeroForOne) {
            _tick = _tick - 60;
        } else {
            _tick = _tick + 60;
        }
        uint160 swapThresholdPrice = TickMath.getSqrtRatioAtTick(_tick);

        pool.swap(
            address(this),
            _zeroForOne,
            _swapAmount,
            swapThresholdPrice,
            "" //data
        );
    }

    function multiSwapByCarol() internal {
        swapByCarol(true, 1 ether);
        swapByCarol(false, 2000 * 1e6);
        swapByCarol(true, 1 ether);
    }

    function _consoleBalance() internal view {
        console2.log("balances: ");
        console2.log(
            token0.balanceOf(address(this)),
            token1.balanceOf(address(this)),
            token0.balanceOf(address(liquidityPool)),
            token1.balanceOf(address(liquidityPool))
        );
    }

    /// @notice Uniswap v3 callback fn, called back on pool.swap
    function algebraSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata /*data*/) external override {
        // console2.log("algebraSwapCallback");
        // console2.log(uint256(amount0Delta), uint256(amount1Delta));
        require(msg.sender == address(pool), "callback caller");
        if (amount0Delta > 0) token0.safeTransfer(msg.sender, uint256(amount0Delta));
        else if (amount1Delta > 0) token1.safeTransfer(msg.sender, uint256(amount1Delta));
    }
}
