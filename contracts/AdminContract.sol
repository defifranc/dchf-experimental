// SPDX-License-Identifier: MIT

pragma solidity 0.8.14;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./Dependencies/CheckContract.sol";

import "./Interfaces/IDfrancParameters.sol";

contract AdminContract is Ownable {
    string public constant NAME = "AdminContract";

    bool public isInitialized;

    IDfrancParameters private dfrancParameters;

    address borrowerOperationsAddress;
    address troveManagerAddress;
    address dchfTokenAddress;
    address sortedTrovesAddress;

    function setAddresses(
        address _parameters,
        address _borrowerOperationsAddress,
        address _troveManagerAddress,
        address _dchfTokenAddress,
        address _sortedTrovesAddress
    ) external onlyOwner {
        require(!isInitialized, "Already initialized");
        CheckContract(_parameters);
        CheckContract(_borrowerOperationsAddress);
        CheckContract(_troveManagerAddress);
        CheckContract(_dchfTokenAddress);
        CheckContract(_sortedTrovesAddress);

        isInitialized = true;

        borrowerOperationsAddress = _borrowerOperationsAddress;
        troveManagerAddress = _troveManagerAddress;
        dchfTokenAddress = _dchfTokenAddress;
        sortedTrovesAddress = _sortedTrovesAddress;

        dfrancParameters = IDfrancParameters(_parameters);
    }

    function addNewCollateral(
        address _asset,
        address _oracle,
        address _chainlinkIndex,
        uint256 redemptionLockInDay
    ) external onlyOwner {
        dfrancParameters.priceFeed().addOracle(_asset, _oracle, _chainlinkIndex);
        dfrancParameters.setAsDefaultWithRedemptionBlock(_asset, redemptionLockInDay);
    }
}
