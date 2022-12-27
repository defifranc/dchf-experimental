// SPDX-License-Identifier: MIT

pragma solidity ^0.8.14;
import "../Interfaces/IOracle.sol";

contract MockOracle is IOracle {
    // storage variables to hold the mock data
    uint8 private decimalsVal = 8;
    int256 private price;
    uint256 private updateTime;

    bool latestRevert;
    bool decimalsRevert;

    // --- Functions ---

    function setDecimals(uint8 _decimals) external {
        decimalsVal = _decimals;
    }

    function setPrice(int256 _price) external {
        price = _price;
    }

    function setUpdateTime(uint256 _updateTime) external {
        updateTime = _updateTime;
    }

    function setLatestRevert() external {
        latestRevert = !latestRevert;
    }

    function setDecimalsRevert() external {
        decimalsRevert = !decimalsRevert;
    }

    // --- Getters that adhere to the AggregatorV3 interface ---

    function decimals() external view override returns (uint8) {
        if (decimalsRevert) {
            require(1 == 0, "decimals reverted");
        }

        return decimalsVal;
    }

    function latestAnswer() external view override returns (int256 answer, uint256 updatedAt) {
        if (latestRevert) {
            require(1 == 0, "latestAnswer reverted");
        }

        return (price, updateTime);
    }

    function description() external pure override returns (string memory) {
        return "";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }
}
