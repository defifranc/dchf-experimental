// SPDX-License-Identifier: MIT

pragma solidity 0.8.14;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import "../Interfaces/IOracle.sol";

interface IGrizzlyVault {
    function pricePerShare() external view returns (uint256);

    function decimals() external view returns (uint8);
}

interface ICurvePool {
    function get_virtual_price() external view returns (uint256 price);

    function decimals() external view returns (uint256);
}

contract GVFrax3CrvOracle is IOracle {
    IGrizzlyVault public constant GVFrax3Crv = IGrizzlyVault(0xF437C8cEa5Bb0d8C10Bb9c012fb4a765663942f1);
    ICurvePool public constant Frax3Crv = ICurvePool(0xd632f22692FaC7611d2AA1C0D552930D43CAEd3B);
    /**
     * Network: Mainnet
     * Aggregators: DAI/USD, USDC/USD, USDT/USD, FRAX/USD
     */
    AggregatorV3Interface public constant DAI =
        AggregatorV3Interface(0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9);
    AggregatorV3Interface public constant USDC =
        AggregatorV3Interface(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6);
    AggregatorV3Interface public constant USDT =
        AggregatorV3Interface(0x3E7d1eAB13ad0104d2750B8863b489D65364e32D);
    AggregatorV3Interface public constant FRAX =
        AggregatorV3Interface(0xB9E1E3A9feFf48998E45Fa90847ed4D467E8BcfD);

    int256 public DECIMAL_ADJUSTMENT;

    constructor() {
        DECIMAL_ADJUSTMENT = int(10**(GVFrax3Crv.decimals() + Frax3Crv.decimals() + FRAX.decimals() - 18)); // 10 ** 18
    }

    /**
     * @notice Returns the smallest of two numbers.
     */
    function min(int256 a, int256 b) internal pure returns (int256) {
        return a < b ? a : b;
    }

    function decimals() external view override returns (uint8) {
        return 18;
    }

    function description() external view override returns (string memory) {
        return "Grizzly Vault Frax3Crv Oracle";
    }

    function version() external view override returns (uint256) {
        return 1;
    }

    /**
     * @notice Returns the data for the latest round of this oracle
     * @return answer the value of the data fetched by this oracle
     * @return updatedAt the timestamp of the answer
     */
    function latestAnswer() public view override returns (int256 answer, uint256 updatedAt) {
        (
            ,
            ,
            ,
            /* roundId */
            /* answer */
            /* startedAt */
            updatedAt,
            /* answeredInRound */

        ) = FRAX.latestRoundData(); // We use the data of the single asset feed
        answer = _getLatestLPTokenPrice();
    }

    /**
     * @dev Returns a fair lower bound for the latest LPToken Price
     * @return LPPrice the price for the LP token in USD normalized to 1e18
     */
    function _getLatestLPTokenPrice() internal view returns (int256 LPPrice) {
        int256 minStablePrice = min(
            min(_getLatestPrice(FRAX), _getLatestPrice(DAI)),
            min(_getLatestPrice(USDC), _getLatestPrice(USDT))
        );
        int256 price = int(GVFrax3Crv.pricePerShare() * Frax3Crv.get_virtual_price()) * minStablePrice;

        LPPrice = price / DECIMAL_ADJUSTMENT;
    }

    /**
     * @dev Returns the latest price of the given Chainlink price feed in USD
     * @param _priceFeed Interface of the used price feed
     */
    function _getLatestPrice(AggregatorV3Interface _priceFeed) internal view returns (int256 latestPrice) {
        (
            ,
            /*uint80 roundID*/
            latestPrice,
            /*uint startedAt*/
            /*uint timeStamp*/
            /*uint80 answeredInRound*/
            ,
            ,

        ) = _priceFeed.latestRoundData();
    }
}
