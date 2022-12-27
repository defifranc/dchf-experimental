// SPDX-License-Identifier: MIT

pragma solidity ^0.8.14;
import "../PriceFeed.sol";

contract PriceFeedTesterSet is PriceFeed {
    function setLastGoodPrice(uint256 _lastGoodPrice) external {
        lastGoodPrice[address(0)] = _lastGoodPrice;
    }

    function setLastGoodForex(uint256 _lastGoodForex) external {
        lastGoodForex[address(0)] = _lastGoodForex;
    }

    function setStatus(Status _status) external {
        status = _status;
    }
}
