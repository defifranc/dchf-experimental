// SPDX-License-Identifier: MIT
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "./IOracle.sol";

pragma solidity ^0.8.14;

interface IPriceFeed {
    struct ChainlinkResponse {
        uint80 roundId;
        int256 answer;
        uint256 timestamp;
        bool success;
        uint8 decimals;
    }

    struct OracleResponse {
        int256 answer;
        uint256 timestamp;
        bool success;
        uint8 decimals;
    }

    struct RegisterOracle {
        IOracle oracle;
        AggregatorV3Interface chainLinkForex;
        bool isRegistered;
    }

    enum Status {
        chainlinkWorking,
        chainlinkUntrusted
    }

    // --- Events ---
    event PriceFeedStatusChanged(Status newStatus);
    event LastGoodPriceUpdated(address indexed token, uint256 _lastGoodPrice);
    event LastGoodForexUpdated(address indexed token, uint256 _lastGoodIndex);
    event RegisteredNewOracle(address token, address oracle, address chianLinkIndex);

    // --- Function ---
    function addOracle(
        address _token,
        address _oracle,
        address _chainlinkForexOracle
    ) external;

    function fetchPrice(address _token) external returns (uint256);

    function getDirectPrice(address _asset) external returns (uint256);
}
