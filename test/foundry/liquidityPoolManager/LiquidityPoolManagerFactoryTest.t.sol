// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.16;

import "../utils/BaseTest.sol";

import {LiquidityPoolManagerFactory, IProxy} from "../../../contracts/liquidityPoolManager/LiquidityPoolManagerFactory.sol";
import {UniswapV3LiquidityPoolManager, IUniswapV3LiquidityPoolManager} from "../../../contracts/liquidityPoolManager/UniswapV3LiquidityPoolManager.sol";

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TickMath} from "../../../contracts/libs/uniswap/TickMath.sol";
import {OracleLibrary} from "../../../contracts/libs/uniswap/OracleLibrary.sol";
import {FullMath, LiquidityAmounts} from "../../../contracts/libs/uniswap/LiquidityAmounts.sol";

contract LiquidityPoolManagerFactoryTest is BaseTest {
    using TickMath for int24;
    using FullMath for uint256;
    using Ints for int24;
    using Ints for int256;

    AddressHelper.TokenAddr public tokenAddr;
    AddressHelper.UniswapAddr public uniswapAddr;

    LiquidityPoolManagerFactory public factory;
    UniswapV3LiquidityPoolManager public template;
    IUniswapV3LiquidityPoolManager public liquidityPool;
    IUniswapV3Pool public pool;
    ISwapRouter public router;
    IERC20 public token0;
    IERC20 public token1;

    int24 public lowerTick = -205680;
    int24 public upperTick = -203760;
    int24 public currentTick;

    // currentTick = -204714;

    function setUp() public virtual {
        (tokenAddr, , uniswapAddr) = AddressHelper.addresses(block.chainid);

        pool = IUniswapV3Pool(uniswapAddr.wethUsdcPoolAddr500);
        token0 = IERC20(tokenAddr.wethAddr);
        token1 = IERC20(tokenAddr.usdcAddr);
        router = ISwapRouter(uniswapAddr.routerAddr);

        template = new UniswapV3LiquidityPoolManager();

        factory = new LiquidityPoolManagerFactory();
        factory.approveTemplate(IProxy(address(template)), true);

        //create proxy
        address[] memory _references = new address[](4);
        _references[0] = address(this);
        _references[1] = address(pool);
        _references[2] = address(token0);
        _references[3] = address(token1);
        liquidityPool = IUniswapV3LiquidityPoolManager(
            factory.create(IProxy(address(template)), new uint256[](0), _references)
        );

        //set Ticks for testing
        (, int24 _tick, , , , , ) = pool.slot0();
        currentTick = _tick;

        //deal
        deal(tokenAddr.wethAddr, address(this), 10_000 ether);
        deal(tokenAddr.usdcAddr, address(this), 10_000_000 * 1e6);
        deal(tokenAddr.wethAddr, carol, 10_000 ether);
        deal(tokenAddr.usdcAddr, carol, 10_000_000 * 1e6);

        //approve
        token0.approve(address(liquidityPool), type(uint256).max);
        token1.approve(address(liquidityPool), type(uint256).max);
        vm.startPrank(carol);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function test_mint_Success() public {
        _consoleBalance();

        //compute liquidity
        uint128 _liquidity = liquidityPool.getLiquidityForAmounts(lowerTick, upperTick, 1 ether, 1000 * 1e6);

        //mint
        IUniswapV3LiquidityPoolManager.MintParams memory _mintParams = IUniswapV3LiquidityPoolManager.MintParams(
            lowerTick,
            upperTick,
            _liquidity
        );
        (uint _amount0, uint _amount1) = liquidityPool.mint(_mintParams);
        console2.log(_amount0, _amount1);

        //assertion of mint
        (uint _amount0_, uint _amount1_) = liquidityPool.getAmountsForLiquidity(lowerTick, upperTick, _liquidity);
        assertEq(_amount0, _amount0_ + 1);
        assertEq(_amount1, _amount1_ + 1);

        uint128 _liquidity2 = liquidityPool.getCurrentLiquidity(lowerTick, upperTick);
        console2.log(_liquidity2, "liquidity2");
        assertEq(_liquidity, _liquidity2);
        _consoleBalance();

        // burn and collect
        IUniswapV3LiquidityPoolManager.BurnParams memory _paramsBurn = IUniswapV3LiquidityPoolManager.BurnParams(
            lowerTick,
            upperTick,
            _liquidity
        );
        (uint burn0_, uint burn1_) = liquidityPool.burn(_paramsBurn);
        assertEq(_amount0, burn0_ + 1);
        assertEq(_amount1, burn1_ + 1);
        _consoleBalance();

        IUniswapV3LiquidityPoolManager.CollectParams memory _collectParams = IUniswapV3LiquidityPoolManager
            .CollectParams(lowerTick, upperTick);
        (uint collect0, uint collect1) = liquidityPool.collect(_collectParams);
        console2.log(collect0, collect1);
        _consoleBalance();
    }

    function test_createByVault() public {
        //create vault
        address[] memory _references = new address[](3);
        _references[0] = address(pool);
        _references[1] = address(token0);
        _references[2] = address(token1);
        VaultMock _vault = new VaultMock(factory, IProxy(address(template)), new uint256[](0), _references);
        UniswapV3LiquidityPoolManager _liq = _vault.liquidityPool();
        assertEq(_liq.operator(), address(_vault));
    }

    /* ========== TEST functions ========== */
    function _consoleBalance() internal view {
        console2.log("balances: ");
        console2.log(
            token0.balanceOf(address(this)),
            token1.balanceOf(address(this)),
            token0.balanceOf(address(liquidityPool)),
            token1.balanceOf(address(liquidityPool))
        );
    }
}

contract VaultMock {
    UniswapV3LiquidityPoolManager public liquidityPool;

    //in construcor, create liquidity pool by factory
    constructor(
        LiquidityPoolManagerFactory _factory,
        IProxy _template,
        uint256[] memory _params,
        address[] memory _references
    ) {
        address[] memory referencesNew = new address[](4);
        referencesNew[0] = address(this);
        referencesNew[1] = _references[0];
        referencesNew[2] = _references[1];
        referencesNew[3] = _references[2];

        //create proxy
        liquidityPool = UniswapV3LiquidityPoolManager(
            _factory.create(IProxy(address(_template)), _params, referencesNew)
        );
    }
}
