// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;
pragma experimental ABIEncoderV2;

import {IERC20} from "./Library/IERC20.sol";
import {SafeERC20} from "./Library/SafeERC20.sol";
import {SafeMath} from "./Library/SafeMath.sol";
import {Ownable} from "./Library/Ownable.sol";

import "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";

interface IUniV3 {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

interface IOracle {
    function latestAnswer() external view returns (uint256);
}

interface ICurveFi {
    function get_dy(
        address pool,
        uint256 from,
        uint256 to,
        uint256 _from_amount
    ) external view returns (uint256);

    function exchange(
        address pool,
        uint256 from,
        uint256 to,
        uint256 from_amount,
        uint256 min_to_amount
    ) external payable;
}

interface IBurnContract {
    function totalMONBurnt() external view returns (uint256 _totalMONBurnt);
}

contract FeeContract is Ownable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    IERC20 internal constant DCHF = IERC20(0x045da4bFe02B320f4403674B3b7d121737727A36);
    IERC20 internal constant MON = IERC20(0x1EA48B9965bb5086F3b468E50ED93888a661fc17);

    ICurveFi internal constant curveHelper = ICurveFi(0x97aDC08FA1D849D2C48C5dcC1DaB568B169b0267);

    address internal constant uniRouter = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address internal constant uniPool = 0x21f396Dd37a26D7754C513fD916D07F66Aa6B81E;
    address internal constant curvePool = 0xDcb11E81C8B8a1e06BF4b50d4F6f3bb31f7478C3;

    IERC20 internal constant usdt = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IERC20 internal constant usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 internal constant dai = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 internal constant weth = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    address public targetStable;
    uint256 public optimal;
    uint24 public uniStableFee;
    uint24 public MONFee;
    uint256 public slippageMax;

    address public burnContract;

    uint256 internal constant MAX = type(uint256).max;
    uint256 internal constant DENOMINATOR = 10000;

    event Sweep(address indexed token, uint256 amount);
    event BuybackMON(uint256 timestamp, uint256 amount);

    constructor() {
        targetStable = address(usdc);
        optimal = 2; // USDC
        uniStableFee = 500;
        MONFee = 3000;

        slippageMax = 9700; // 3% diff from the oracle price

        DCHF.safeApprove(address(curveHelper), 0);
        DCHF.safeApprove(address(curveHelper), MAX);

        usdc.safeApprove(uniRouter, 0);
        usdc.safeApprove(uniRouter, MAX);
    }

    /// @notice BurnContract is just a contract with no functionality
    function setBurnContractAddress(address _burnContract) external onlyOwner {
        burnContract = _burnContract;
    }

    function executePurchaseMON() external onlyOwner {
        uint256 _optimal = optimal;

        _curveSwapToWant(_optimal);
        _uniV3SwapToMON(_optimal);
        _burnMON();
    }

    /// @notice See how much USDC we would get for our DCHF on Curve
    function valueOfDCHF(uint256 _optimal) public view returns (uint256) {
        uint256 currentDCHF = DCHF.balanceOf(address(this));
        if (currentDCHF > 0) {
            return curveHelper.get_dy(curvePool, 0, _optimal, currentDCHF);
        } else {
            return 0;
        }
    }

    /// @notice Get actual price from UniV3 Pool
    function getCurrentUniV3Price() public view returns (uint256 price) {
        IOracle ethOracle = IOracle(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
        uint256 ethPrice = ethOracle.latestAnswer(); // 1e8 precision

        (uint160 sqrtRatioX96, , , , , , ) = IUniV3(uniPool).slot0();
        uint256 priceInETH = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, uint256(2**192) / 1e18);

        price = (priceInETH * ethPrice) / 1e8;
    }

    function _curveSwapToWant(uint256 _optimal) internal {
        IOracle chfOracle = IOracle(0x449d117117838fFA61263B61dA6301AA2a88B13A);
        uint256 chfPrice = chfOracle.latestAnswer(); // 1e8 precision

        uint256 _amountInDCHF = DCHF.balanceOf(address(this));
        uint256 _amountOut;

        if (_optimal == 2 || _optimal == 3) {
            // Use our slippage tolerance, convert between CHF (1e18) -> USDC / USDT (1e6)
            _amountOut = (_amountInDCHF.mul(chfPrice).mul(slippageMax)).div(DENOMINATOR).div(1e20);
        } else {
            // Use our slippage tolerance, convert between CHF (1e18) -> DAI (1e18)
            _amountOut = (_amountInDCHF.mul(chfPrice).mul(slippageMax)).div(DENOMINATOR).div(1e8);
        }

        // DAI is 1, USDC is 2, USDT is 3, DCHF is 0
        curveHelper.exchange(curvePool, 0, _optimal, _amountInDCHF, _amountOut);
    }

    function _uniV3SwapToMON(uint256 _optimal) internal {
        address _targetStable = targetStable;

        IOracle ethOracle = IOracle(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
        uint256 ethPrice = ethOracle.latestAnswer(); // 1e8 precision

        uint256 targetStableBalance = IERC20(_targetStable).balanceOf(address(this));
        uint256 ethExpected;

        if (_optimal == 2 || _optimal == 3) {
            // Use our slippage tolerance, convert between USDC / USDT (1e6) -> ETH (1e18)
            ethExpected = (((targetStableBalance.mul(1e20)).div(ethPrice)).mul(slippageMax)).div(DENOMINATOR);
        } else {
            // Use our slippage tolerance, convert between DAI (1e18) -> ETH (1e18)
            ethExpected = (((targetStableBalance.mul(1e8)).div(ethPrice)).mul(slippageMax)).div(DENOMINATOR);
        }

        uint256 amountOutMON = _getUniswapTwapAmount(address(weth), address(MON), uint128(ethExpected), 120);

        IUniV3(uniRouter).exactInput(
            IUniV3.ExactInputParams({
                path: abi.encodePacked(_targetStable, uniStableFee, address(weth), MONFee, address(MON)),
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: targetStableBalance,
                amountOutMinimum: amountOutMON
            })
        );
    }

    function _getUniswapTwapAmount(
        address tokenIn,
        address tokenOut,
        uint128 amountIn,
        uint32 interval
    ) internal view returns (uint256 amountOut) {
        uint32[] memory secondsAgo = new uint32[](2);
        secondsAgo[0] = interval; // 300 -> 5 min;
        secondsAgo[1] = 0;

        // Returns the cumulative tick values and liquidity as of each timestamp secondsAgo from current block timestamp
        (int56[] memory tickCumulatives, ) = IUniV3(uniPool).observe(secondsAgo);

        int24 avgTick = int24((tickCumulatives[1] - tickCumulatives[0]) / int56(uint56(interval)));

        amountOut = OracleLibrary.getQuoteAtTick(avgTick, amountIn, tokenIn, tokenOut);
    }

    /// @notice Burn MON by transferring to the Burn Contract as the supply is fixed and is not "burnable"
    function _burnMON() internal {
        uint256 balanceMON = MON.balanceOf(address(this));
        MON.safeTransfer(burnContract, balanceMON);
        emit BuybackMON(block.timestamp, balanceMON); // Event to track repurchases
    }

    /// @notice Set the optimal token to sell the DCHF on Curve
    function setOptimal(uint256 _optimal) external onlyOwner {
        if (_optimal == 1) {
            targetStable = address(dai);
        } else if (_optimal == 2) {
            targetStable = address(usdc);
        } else if (_optimal == 3) {
            targetStable = address(usdt);
        } else {
            revert("Incorrect token");
        }

        optimal = _optimal;

        IERC20(targetStable).safeApprove(uniRouter, 0);
        IERC20(targetStable).safeApprove(uniRouter, MAX);
    }

    /// @notice Set the fee pool we'd like to swap through on UniV3 (1% = 10_000)
    function setUniFees(uint24 _stableFee) external onlyOwner {
        require(_stableFee == 100 || _stableFee == 500 || _stableFee == 3000, "FeeContract: Not valid fee");
        uniStableFee = _stableFee;
    }

    /// @notice Set the fee pool we'd like to swap ETH-MON on UniV3 (1% = 10_000)
    function setUniMONFee(uint24 _MONFee) external onlyOwner {
        require(_MONFee == 3000 || _MONFee == 10000, "FeeContract: Not valid Fee");
        MONFee = _MONFee;
    }

    /// @notice Set the slippage parameter for making swaps
    function setSlippage(uint256 _slippageMax) external onlyOwner {
        require(_slippageMax < 10001, "FeeContract: Not valid slippage");
        slippageMax = _slippageMax;
    }

    /// @notice Sweep tokens different than DCHF (hs-Tokens)
    function sweep(address[] memory _tokens) external onlyOwner {
        for (uint256 i = 0; i < _tokens.length; i++) {
            uint256 amount = IERC20(_tokens[i]).balanceOf(address(this));
            IERC20(_tokens[i]).safeTransfer(owner(), amount);
            emit Sweep(_tokens[i], amount);
        }
    }

    /// @notice Getter to track the amount of MON burnt to date
    function totalMONBurnt() external view returns (uint256 _totalMONBurnt) {
        _totalMONBurnt = IBurnContract(burnContract).totalMONBurnt();
    }

    receive() external payable {
        require(msg.sender != tx.origin, "FeeContract: Do not send ETH directly");
    }
}
