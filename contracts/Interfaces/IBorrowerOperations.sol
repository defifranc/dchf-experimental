// SPDX-License-Identifier: MIT

pragma solidity 0.8.14;

// Common interface for the Trove Manager.
interface IBorrowerOperations {
    // --- Events --- //

    event TroveManagerAddressChanged(address _newTroveManagerAddress);
    event CollSurplusPoolAddressChanged(address _collSurplusPoolAddress);
    event SortedTrovesAddressChanged(address _sortedTrovesAddress);
    event DCHFTokenAddressChanged(address _dchfTokenAddress);
    event FeeContractAddressChanged(address _feeContractAddress);

    event TroveCreated(address indexed _asset, address indexed _borrower, uint256 arrayIndex);
    event TroveUpdated(
        address indexed _asset,
        address indexed _borrower,
        uint256 _debt,
        uint256 _coll,
        uint8 operation
    );
    event DCHFBorrowingFeePaid(address indexed _asset, address indexed _borrower, uint256 _DCHFFee);

    // --- Functions --- //

    function setAddresses(
        address _troveManagerAddress,
        address _collSurplusPoolAddress,
        address _sortedTrovesAddress,
        address _dchfTokenAddress,
        address _dfrancParamsAddress,
        address _feeContractAddress
    ) external;

    function openTrove(
        address _asset,
        uint256 _tokenAmount,
        uint256 _maxFee,
        uint256 _DCHFamount,
        address _upperHint,
        address _lowerHint
    ) external payable;

    function addColl(
        address _asset,
        uint256 _assetSent,
        address _upperHint,
        address _lowerHint
    ) external payable;

    function withdrawColl(
        address _asset,
        uint256 _amount,
        address _upperHint,
        address _lowerHint
    ) external;

    function withdrawDCHF(
        address _asset,
        uint256 _maxFee,
        uint256 _amount,
        address _upperHint,
        address _lowerHint
    ) external;

    function repayDCHF(
        address _asset,
        uint256 _amount,
        address _upperHint,
        address _lowerHint
    ) external;

    function closeTrove(address _asset) external;

    function adjustTrove(
        address _asset,
        uint256 _assetSent,
        uint256 _maxFee,
        uint256 _collWithdrawal,
        uint256 _debtChange,
        bool isDebtIncrease,
        address _upperHint,
        address _lowerHint
    ) external payable;

    function claimCollateral(address _asset) external;

    function isContractBorrowerOps() external pure returns (bool);
}
