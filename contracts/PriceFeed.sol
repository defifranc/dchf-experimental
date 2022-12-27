// SPDX-License-Identifier: MIT

pragma solidity 0.8.14;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./Interfaces/IPriceFeed.sol";

import "./Dependencies/CheckContract.sol";
import "./Dependencies/BaseMath.sol";
import "./Dependencies/DfrancMath.sol";

contract PriceFeed is Ownable, CheckContract, BaseMath, IPriceFeed {
    using SafeMath for uint256;

    string public constant NAME = "PriceFeed";

    // Use to convert a price answer to an 18-digit precision uint
    uint256 public constant TARGET_DIGITS = 18;

    uint256 public constant TIMEOUT = 4 hours;

    // Maximum deviation allowed between two consecutive Chainlink oracle prices. 18-digit precision.
    uint256 public constant MAX_PRICE_DEVIATION_FROM_PREVIOUS_ROUND = 5e17; // 50%
    uint256 public constant MAX_PRICE_DIFFERENCE_BETWEEN_ORACLES = 5e16; // 5%

    bool public isInitialized;

    address public adminContract;

    IPriceFeed.Status public status;
    mapping(address => RegisterOracle) public registeredOracles;
    mapping(address => uint256) public lastGoodPrice;
    mapping(address => uint256) public lastGoodForex;

    modifier isController() {
        require(msg.sender == owner() || msg.sender == adminContract, "Invalid Permission");
        _;
    }

    function setAddresses(address _adminContract) external onlyOwner {
        require(!isInitialized, "Already initialized");
        checkContract(_adminContract);
        isInitialized = true;

        adminContract = _adminContract;
        status = Status.chainlinkWorking;
    }

    function setAdminContract(address _admin) external onlyOwner {
        require(_admin != address(0), "Admin address is zero");
        checkContract(_admin);
        adminContract = _admin;
    }

    /**
     * @notice Returns the data for the latest round of this oracle
     * @param _token the address of the token to add
     * @param _oracle the address of the oracle giving the price of the token in USD
     * @param _chainlinkForexOracle the address of the Forex Chainlink Oracle to convert from USD
     */
    function addOracle(
        address _token,
        address _oracle,
        address _chainlinkForexOracle
    ) external override isController {
        IOracle priceOracle = IOracle(_oracle);
        AggregatorV3Interface forexOracle = AggregatorV3Interface(_chainlinkForexOracle);

        registeredOracles[_token] = RegisterOracle(priceOracle, forexOracle, true);

        (
            OracleResponse memory oracleResponse,
            ChainlinkResponse memory chainlinkForexResponse
        ) = _getOracleResponses(priceOracle, forexOracle);

        require(
            !_badChainlinkResponse(chainlinkForexResponse) && !_chainlinkIsFrozen(oracleResponse),
            "PriceFeed: Chainlink must be working and current"
        );

        _storeOraclePrice(_token, oracleResponse);
        _storeChainlinkForex(_token, chainlinkForexResponse);

        emit RegisteredNewOracle(_token, _oracle, _chainlinkForexOracle);
    }

    /**
     * @notice Returns the price of the given asset in CHF
     * @param _asset address of the asset to get the price of
     * @return _priceAssetInDCHF the price of the asset in CHF with the global precision
     */
    function getDirectPrice(address _asset) public view returns (uint256 _priceAssetInDCHF) {
        RegisterOracle memory oracle = registeredOracles[_asset];
        (
            OracleResponse memory oracleResponse,
            ChainlinkResponse memory chainlinkForexResponse
        ) = _getOracleResponses(oracle.oracle, oracle.chainLinkForex);

        uint256 scaledOraclePrice = _scaleChainlinkPriceByDigits(
            uint256(oracleResponse.answer),
            oracleResponse.decimals
        );

        uint256 scaledChainlinkForexPrice = _scaleChainlinkPriceByDigits(
            uint256(chainlinkForexResponse.answer),
            chainlinkForexResponse.decimals
        );

        _priceAssetInDCHF = scaledOraclePrice.mul(1 ether).div(scaledChainlinkForexPrice);
    }

    /**
     * @notice Returns the last good price of the given asset in CHF. If Chainlink is working it returns the current price and updates the last good prices
     * @param _token address of the asset to get and update the price of
     * @return the price of the asset in CHF with the global precision
     */
    function fetchPrice(address _token) external override returns (uint256) {
        RegisterOracle storage oracle = registeredOracles[_token];
        require(oracle.isRegistered, "Oracle is not registered!");

        (
            OracleResponse memory oracleResponse,
            ChainlinkResponse memory chainlinkForexResponse
        ) = _getOracleResponses(oracle.oracle, oracle.chainLinkForex);

        uint256 lastTokenGoodPrice = lastGoodPrice[_token];
        uint256 lastTokenGoodForex = lastGoodForex[_token];

        bool isChainlinkBroken = _badChainlinkResponse(chainlinkForexResponse) ||
            _chainlinkIsFrozen(oracleResponse);

        if (status == Status.chainlinkWorking) {
            if (isChainlinkBroken) {
                _changeStatus(Status.chainlinkUntrusted);
                return _getForexedPrice(lastTokenGoodPrice, lastTokenGoodForex);
            }

            // If Chainlink price has changed by > 50% between two consecutive rounds
            if (_chainlinkForexPriceChangeAboveMax(chainlinkForexResponse, lastTokenGoodForex)) {
                return _getForexedPrice(lastTokenGoodPrice, lastTokenGoodForex);
            }

            lastTokenGoodPrice = _storeOraclePrice(_token, oracleResponse);
            lastTokenGoodForex = _storeChainlinkForex(_token, chainlinkForexResponse);

            return _getForexedPrice(lastTokenGoodPrice, lastTokenGoodForex);
        }

        if (status == Status.chainlinkUntrusted) {
            if (!isChainlinkBroken) {
                _changeStatus(Status.chainlinkWorking);
                lastTokenGoodPrice = _storeOraclePrice(_token, oracleResponse);
                lastTokenGoodForex = _storeChainlinkForex(_token, chainlinkForexResponse);
            }

            return _getForexedPrice(lastTokenGoodPrice, lastTokenGoodForex);
        }

        return _getForexedPrice(lastTokenGoodPrice, lastTokenGoodForex);
    }

    /**
     * @notice Transforms the price from USD to a given foreign currency
     * @param _price address of the asset to get and update the price of
     * @param _forex the exchange rate to the foreign currency
     * @return the price converted to foreign currency
     */
    function _getForexedPrice(uint256 _price, uint256 _forex) internal pure returns (uint256) {
        return _price.mul(1 ether).div(_forex);
    }

    /**
     * @notice Queries both LP token and Chainlink oracles and get their responses
     * @param _oracle address of the LP token oracle
     * @param _chainLinkForexOracle address of Chainlink Forex Oracle
     */
    function _getOracleResponses(IOracle _oracle, AggregatorV3Interface _chainLinkForexOracle)
        internal
        view
        returns (OracleResponse memory currentOracle, ChainlinkResponse memory currentChainlinkForex)
    {
        currentOracle = _getCurrentOracleResponse(_oracle);

        if (address(_chainLinkForexOracle) != address(0)) {
            currentChainlinkForex = _getCurrentChainlinkResponse(_chainLinkForexOracle);
        } else {
            currentChainlinkForex = ChainlinkResponse(1, 1 ether, block.timestamp, true, 18);
        }

        return (currentOracle, currentChainlinkForex);
    }

    /**
     * @notice Checks is Chainlink is giving a bad response
     * @param _response struct containing all the data of a Chainlink response
     * @return a boolean indicating if the response is not valid (true)
     */
    function _badChainlinkResponse(ChainlinkResponse memory _response) internal view returns (bool) {
        if (!_response.success) {
            return true;
        }
        if (_response.roundId == 0) {
            return true;
        }
        if (_response.timestamp == 0 || _response.timestamp > block.timestamp) {
            return true;
        }
        if (_response.answer <= 0) {
            return true;
        }

        return false;
    }

    //@dev Checks if Chainlink response is current enough
    function _chainlinkIsFrozen(OracleResponse memory _response) internal view returns (bool) {
        return block.timestamp.sub(_response.timestamp) > TIMEOUT;
    }

    //@dev checks if Chainlink Forex Oracle is not giving a price that deviates too much from the last provided
    function _chainlinkForexPriceChangeAboveMax(
        ChainlinkResponse memory _currentResponse,
        uint256 _lastTokenGoodForex
    ) internal pure returns (bool) {
        uint256 currentScaledPrice = _scaleChainlinkPriceByDigits(
            uint256(_currentResponse.answer),
            _currentResponse.decimals
        );

        uint256 minPrice = DfrancMath._min(currentScaledPrice, _lastTokenGoodForex);
        uint256 maxPrice = DfrancMath._max(currentScaledPrice, _lastTokenGoodForex);

        /*
         * Use the larger price as the denominator:
         * - If price decreased, the percentage deviation is in relation to the the previous price.
         * - If price increased, the percentage deviation is in relation to the current price.
         */
        uint256 percentDeviation = maxPrice.sub(minPrice).mul(DECIMAL_PRECISION).div(maxPrice);

        // Return true if price has more than doubled, or more than halved.
        return percentDeviation > MAX_PRICE_DEVIATION_FROM_PREVIOUS_ROUND;
    }

    /**
     * @notice Util function to scale a given price to the Dfranc's target precision
     * @param _price is the price to scale
     * @param _answerDigits is the number of digits of _price
     * @return the price scaled Dfranc's target precision
     */
    function _scaleChainlinkPriceByDigits(uint256 _price, uint256 _answerDigits)
        internal
        pure
        returns (uint256)
    {
        uint256 price;
        if (_answerDigits >= TARGET_DIGITS) {
            // Scale the returned price value down to Dfranc's target precision
            price = _price.div(10**(_answerDigits - TARGET_DIGITS));
        } else if (_answerDigits < TARGET_DIGITS) {
            // Scale the returned price value up to Dfranc's target precision
            price = _price.mul(10**(TARGET_DIGITS - _answerDigits));
        }
        return price;
    }

    /**
     * @notice Changes the status of this PriceFeed contract
     * @param _status is the new status to mutate to
     */
    function _changeStatus(Status _status) internal {
        status = _status;
        emit PriceFeedStatusChanged(_status);
    }

    /**
     * @notice Stores the last Chainlink Forex response and returns its value
     * @param _token the address of the token to add the Forex response
     * @param _chainlinkForexResponse the response struct to store
     * @return the value of the Forex rate of the provided response scaled to Dfranc's precision
     */
    function _storeChainlinkForex(address _token, ChainlinkResponse memory _chainlinkForexResponse)
        internal
        returns (uint256)
    {
        uint256 scaledChainlinkForex = _scaleChainlinkPriceByDigits(
            uint256(_chainlinkForexResponse.answer),
            _chainlinkForexResponse.decimals
        );

        _storeForex(_token, scaledChainlinkForex);
        return scaledChainlinkForex;
    }

    /**
     * @notice Stores the last Oracle response and returns its value
     * @param _token the address of the token to add the Oracle response
     * @param _oracleResponse the response struct to store
     * @return the value of the token in USD in the provided response scaled to Dfranc's precision
     */
    function _storeOraclePrice(address _token, OracleResponse memory _oracleResponse)
        internal
        returns (uint256)
    {
        uint256 scaledChainlinkPrice = _scaleChainlinkPriceByDigits(
            uint256(_oracleResponse.answer),
            _oracleResponse.decimals
        );

        _storePrice(_token, scaledChainlinkPrice);
        return scaledChainlinkPrice;
    }

    /**
     * @notice Util function to update the current price of a given token
     * @param _token the address of the token to update
     * @param _currentPrice the new price to update to
     */
    function _storePrice(address _token, uint256 _currentPrice) internal {
        lastGoodPrice[_token] = _currentPrice;
        emit LastGoodPriceUpdated(_token, _currentPrice);
    }

    /**
     * @notice Util function to update the forex rate of a given token
     * @param _token the address of the token to update its Forex part
     * @param _currentForex the new forex rate to update to
     */
    function _storeForex(address _token, uint256 _currentForex) internal {
        lastGoodForex[_token] = _currentForex;
        emit LastGoodForexUpdated(_token, _currentForex);
    }

    // --- Oracle response wrapper functions ---

    /**
     * @notice Util function to get the current Chainlink response
     * @param _priceAggregator the interface of the Chainlink price feed
     * @return chainlinkResponse current Chainlink response struct
     */
    function _getCurrentChainlinkResponse(AggregatorV3Interface _priceAggregator)
        internal
        view
        returns (ChainlinkResponse memory chainlinkResponse)
    {
        try _priceAggregator.decimals() returns (uint8 decimals) {
            chainlinkResponse.decimals = decimals;
        } catch {
            return chainlinkResponse;
        }

        try _priceAggregator.latestRoundData() returns (
            uint80 roundId,
            int256 answer,
            uint256, /* startedAt */
            uint256 timestamp,
            uint80 /* answeredInRound */
        ) {
            chainlinkResponse.roundId = roundId;
            chainlinkResponse.answer = answer;
            chainlinkResponse.timestamp = timestamp;
            chainlinkResponse.success = true;
            return chainlinkResponse;
        } catch {
            return chainlinkResponse;
        }
    }

    /**
     * @notice Util function to get the current Oracle
     * @param _oracle the interface of the Oracle to query
     * @return oracleResponse current Oracle response struct
     */
    function _getCurrentOracleResponse(IOracle _oracle)
        internal
        view
        returns (OracleResponse memory oracleResponse)
    {
        try _oracle.decimals() returns (uint8 decimals) {
            oracleResponse.decimals = decimals;
        } catch {
            return oracleResponse;
        }

        try _oracle.latestAnswer() returns (int256 answer, uint256 timestamp) {
            oracleResponse.answer = answer;
            oracleResponse.timestamp = timestamp;
            oracleResponse.success = true;
            return oracleResponse;
        } catch {
            return oracleResponse;
        }
    }
}
