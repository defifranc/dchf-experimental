// SPDX-License-Identifier: MIT

pragma solidity ^0.8.14;

interface IOracle {
    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function version() external view returns (uint256);

    function latestAnswer() external view returns (int256 answer, uint256 updatedAt);
}
