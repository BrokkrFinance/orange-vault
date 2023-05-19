// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.16;

import {Ownable} from "../libs/Ownable.sol";
import {Errors} from "../libs/Errors.sol";
import {IOrangeV1Parameters} from "../interfaces/IOrangeV1Parameters.sol";

contract OrangeV1Parameters is IOrangeV1Parameters, Ownable {
    /* ========== CONSTANTS ========== */
    uint256 constant MAGIC_SCALE_1E8 = 1e8; //for computing ltv
    uint16 constant MAGIC_SCALE_1E4 = 10000; //for slippage

    /* ========== PARAMETERS ========== */
    uint256 public depositCap;
    uint256 public totalDepositCap;
    uint256 public minDepositAmount;
    uint16 public slippageBPS;
    uint24 public tickSlippageBPS;
    uint32 public twapSlippageInterval;
    uint32 public maxLtv;
    mapping(address => bool) public strategists;
    bool public allowlistEnabled;
    bytes32 public merkleRoot;
    uint24 public routerFee;
    address public router;
    address public balancer;
    address public strategyImpl;

    /* ========== CONSTRUCTOR ========== */
    constructor() {
        // these variables can be udpated by the manager
        depositCap = 100_000 * 1e6;
        totalDepositCap = 100_000 * 1e6;
        minDepositAmount = 100 * 1e6;
        slippageBPS = 500; // default: 5% slippage
        tickSlippageBPS = 10;
        twapSlippageInterval = 5 minutes;
        maxLtv = 80000000; //80%
        strategists[msg.sender] = true;
        allowlistEnabled = true;
        routerFee = 500; // 5% uniswap routers fee
    }

    /**
     * @notice Set parameters of depositCap
     * @param _depositCap Deposit cap of each accounts
     * @param _totalDepositCap Total deposit cap
     */
    function setDepositCap(uint256 _depositCap, uint256 _totalDepositCap) external onlyOwner {
        if (_depositCap > _totalDepositCap) {
            revert(Errors.INVALID_PARAM);
        }
        depositCap = _depositCap;
        totalDepositCap = _totalDepositCap;
    }

    /**
     * @notice Set parameters of minDepositAmount
     * @param _minDepositAmount Min deposit amount
     */
    function setMinDepositAmount(uint256 _minDepositAmount) external onlyOwner {
        minDepositAmount = _minDepositAmount;
    }

    /**
     * @notice Set parameters of slippage
     * @param _slippageBPS Slippage BPS
     * @param _tickSlippageBPS Check ticks BPS
     */
    function setSlippage(uint16 _slippageBPS, uint24 _tickSlippageBPS) external onlyOwner {
        if (_slippageBPS > MAGIC_SCALE_1E4) {
            revert(Errors.INVALID_PARAM);
        }
        slippageBPS = _slippageBPS;
        tickSlippageBPS = _tickSlippageBPS;
    }

    /**
     * @notice Set parameters of twap slippage
     * @param _twapSlippageInterval TWAP slippage interval
     */
    function setTwapSlippageInterval(uint32 _twapSlippageInterval) external onlyOwner {
        twapSlippageInterval = _twapSlippageInterval;
    }

    /**
     * @notice Set parameters of max LTV
     * @param _maxLtv Max LTV
     */
    function setMaxLtv(uint32 _maxLtv) external onlyOwner {
        if (_maxLtv > MAGIC_SCALE_1E8) {
            revert(Errors.INVALID_PARAM);
        }
        maxLtv = _maxLtv;
    }

    /**
     * @notice Set parameters of Rebalancer
     * @param _strategist Strategist
     * @param _is true or false
     */
    function setStrategist(address _strategist, bool _is) external onlyOwner {
        strategists[_strategist] = _is;
    }

    /**
     * @notice Set parameters of allowlist
     * @param _allowlistEnabled true or false
     */
    function setAllowlistEnabled(bool _allowlistEnabled) external onlyOwner {
        allowlistEnabled = _allowlistEnabled;
    }

    /**
     * @notice Set parameters of merkle root
     * @param _merkleRoot Merkle root
     */
    function setMerkleRoot(bytes32 _merkleRoot) external onlyOwner {
        merkleRoot = _merkleRoot;
    }

    /**
     * @notice Set parameters of router fee
     * @param _routerFee router fee
     */
    function setRouterFee(uint24 _routerFee) external onlyOwner {
        routerFee = _routerFee;
    }

    /**
     * @notice Set parameters of router
     * @param _router router
     */
    function setRouter(address _router) external onlyOwner {
        router = _router;
    }

    /**
     * @notice Set parameters of balancer
     * @param _balancer balancer
     */
    function setBalancer(address _balancer) external onlyOwner {
        balancer = _balancer;
    }

    /**
     * @notice Set parameters of strategyImpl
     * @param _strategyImpl strategyImpl
     */
    function setStrategyImpl(address _strategyImpl) external onlyOwner {
        strategyImpl = _strategyImpl;
    }
}
