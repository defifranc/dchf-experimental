// SPDX-License-Identifier: MIT

pragma solidity 0.8.14;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./Interfaces/IBorrowerOperations.sol";
import "./Interfaces/ITroveManager.sol";
import "./Interfaces/IDCHFToken.sol";
import "./Interfaces/ICollSurplusPool.sol";
import "./Interfaces/ISortedTroves.sol";

import "./Dependencies/DfrancBase.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/SafetyTransfer.sol";

contract BorrowerOperations is DfrancBase, CheckContract, IBorrowerOperations {
    using SafeERC20 for IERC20;

    string public constant NAME = "BorrowerOperations";

    address public feeContractAddress;

    // --- Connected Contract declarations --- //

    ITroveManager public troveManager;

    ICollSurplusPool collSurplusPool;

    IDCHFToken public DCHFToken;

    // A doubly linked list of Troves, sorted by their collateral ratios
    ISortedTroves public sortedTroves;

    bool public isInitialized;

    // --- Variable container structs  --- //

    /* 
    Used to hold, return and assign variables inside a function, in order to avoid the error:
    "CompilerError: Stack too deep". */

    struct LocalVariables_adjustTrove {
        address asset;
        uint256 price;
        uint256 collChange;
        uint256 netDebtChange;
        bool isCollIncrease;
        uint256 debt;
        uint256 coll;
        uint256 newICR;
        uint256 newTCR;
        uint256 DCHFFee;
        uint256 newDebt;
        uint256 newColl;
    }

    struct LocalVariables_openTrove {
        address asset;
        uint256 price;
        uint256 DCHFFee;
        uint256 netDebt;
        uint256 ICR;
        uint256 NICR;
        uint256 arrayIndex;
    }

    struct ContractsCache {
        ITroveManager troveManager;
        IActivePool activePool;
        IDCHFToken DCHFToken;
    }

    enum BorrowerOperation {
        openTrove,
        closeTrove,
        adjustTrove
    }

    event TroveUpdated(
        address indexed _asset,
        address indexed _borrower,
        uint256 _debt,
        uint256 _coll,
        BorrowerOperation operation
    );

    // --- Dependency setters --- //

    function setAddresses(
        address _troveManagerAddress,
        address _collSurplusPoolAddress,
        address _sortedTrovesAddress,
        address _dchfTokenAddress,
        address _dfrancParamsAddress,
        address _feeContractAddress
    ) external override onlyOwner {
        require(!isInitialized, "Already initialized");
        checkContract(_troveManagerAddress);
        checkContract(_collSurplusPoolAddress);
        checkContract(_sortedTrovesAddress);
        checkContract(_dchfTokenAddress);
        checkContract(_dfrancParamsAddress);
        checkContract(_feeContractAddress);

        isInitialized = true;

        troveManager = ITroveManager(_troveManagerAddress);
        collSurplusPool = ICollSurplusPool(_collSurplusPoolAddress);
        sortedTroves = ISortedTroves(_sortedTrovesAddress);
        DCHFToken = IDCHFToken(_dchfTokenAddress);

        feeContractAddress = _feeContractAddress;

        setDfrancParameters(_dfrancParamsAddress);

        emit TroveManagerAddressChanged(_troveManagerAddress);
        emit CollSurplusPoolAddressChanged(_collSurplusPoolAddress);
        emit SortedTrovesAddressChanged(_sortedTrovesAddress);
        emit DCHFTokenAddressChanged(_dchfTokenAddress);
        emit FeeContractAddressChanged(_feeContractAddress);
    }

    // --- Setter onlyOwner --- //

    function setFeeContractAddress(address _newFeeAddress) external onlyOwner {
        require(_newFeeAddress != address(0), "BorrowerOps: Not valid address");
        feeContractAddress = _newFeeAddress;
        emit FeeContractAddressChanged(feeContractAddress);
    }

    // --- Borrower Trove Operations Getter functions --- //

    function isContractBorrowerOps() public pure returns (bool) {
        return true;
    }

    // --- Borrower Trove Operations --- //

    function openTrove(
        address _asset,
        uint256 _tokenAmount,
        uint256 _maxFeePercentage,
        uint256 _DCHFamount,
        address _upperHint,
        address _lowerHint
    ) external payable override {
        require(dfrancParams.sanitizeParameters(_asset), "Params are not configured for the asset");

        ContractsCache memory contractsCache = ContractsCache(
            troveManager,
            dfrancParams.activePool(),
            DCHFToken
        );
        LocalVariables_openTrove memory vars;
        vars.asset = _asset;

        _tokenAmount = getMethodValue(vars.asset, _tokenAmount, false);
        vars.price = dfrancParams.priceFeed().fetchPrice(vars.asset);

        _requireValidMaxFeePercentage(vars.asset, _maxFeePercentage);
        _requireTroveisNotActive(vars.asset, contractsCache.troveManager, msg.sender);

        vars.DCHFFee = _triggerBorrowingFee(
            vars.asset,
            contractsCache.troveManager,
            contractsCache.DCHFToken,
            _DCHFamount,
            _maxFeePercentage
        ); // mints the fee to the feeContract

        // netDebt = compositeDebt (there is no DCHF_GAS_COMPENSATION)
        vars.netDebt = _DCHFamount + vars.DCHFFee;

        _requireAtLeastMinNetDebt(vars.asset, vars.netDebt);

        assert(vars.netDebt > 0);

        // ICR is based on the composite debt, i.e. the requested DCHF amount + DCHF borrowing fee.
        vars.ICR = DfrancMath._computeCR(_tokenAmount, vars.netDebt, vars.price);
        vars.NICR = DfrancMath._computeNominalCR(_tokenAmount, vars.netDebt);

        _requireICRisAboveMCR(vars.asset, vars.ICR);

        uint256 newTCR = _getNewTCRFromTroveChange(
            vars.asset,
            _tokenAmount,
            true,
            vars.netDebt,
            true,
            vars.price
        ); // bools: coll increase, debt increase

        if (newTCR < dfrancParams.LIMIT_CR(_asset)) {
            require(
                vars.ICR >= dfrancParams.LIMIT_CR(_asset),
                "BorrowerOps: Can not open a trove with ICR below Limit if TCR is below Limit"
            );
        }

        _requireBorrowTVLBelowCap(contractsCache.activePool, vars.asset, _DCHFamount);

        // Set the trove struct's properties
        contractsCache.troveManager.setTroveStatus(vars.asset, msg.sender, 1); // Active
        contractsCache.troveManager.increaseTroveColl(vars.asset, msg.sender, _tokenAmount);
        contractsCache.troveManager.increaseTroveDebt(vars.asset, msg.sender, vars.netDebt);

        sortedTroves.insert(vars.asset, msg.sender, vars.NICR, _upperHint, _lowerHint);
        vars.arrayIndex = contractsCache.troveManager.addTroveOwnerToArray(vars.asset, msg.sender);
        emit TroveCreated(vars.asset, msg.sender, vars.arrayIndex);

        // Move the ETH to the Active Pool, and mint the DCHFAmount to the borrower
        _activePoolAddColl(vars.asset, contractsCache.activePool, _tokenAmount);
        _withdrawDCHF(
            vars.asset,
            contractsCache.activePool,
            contractsCache.DCHFToken,
            msg.sender,
            _DCHFamount,
            vars.netDebt
        );

        emit TroveUpdated(vars.asset, msg.sender, vars.netDebt, _tokenAmount, BorrowerOperation.openTrove);
        emit DCHFBorrowingFeePaid(vars.asset, msg.sender, vars.DCHFFee);
    }

    // Send ETH as collateral to a trove
    function addColl(
        address _asset,
        uint256 _assetSent,
        address _upperHint,
        address _lowerHint
    ) external payable override {
        _adjustTrove(
            _asset,
            getMethodValue(_asset, _assetSent, false),
            msg.sender,
            0,
            0,
            false,
            _upperHint,
            _lowerHint,
            0
        );
    }

    // Withdraw ETH collateral from a trove
    function withdrawColl(
        address _asset,
        uint256 _collWithdrawal,
        address _upperHint,
        address _lowerHint
    ) external override {
        _adjustTrove(_asset, 0, msg.sender, _collWithdrawal, 0, false, _upperHint, _lowerHint, 0);
    }

    // Withdraw DCHF tokens from a trove: mint new DCHF tokens to the owner, and increase the trove's debt accordingly
    function withdrawDCHF(
        address _asset,
        uint256 _maxFeePercentage,
        uint256 _DCHFamount,
        address _upperHint,
        address _lowerHint
    ) external override {
        _adjustTrove(_asset, 0, msg.sender, 0, _DCHFamount, true, _upperHint, _lowerHint, _maxFeePercentage);
    }

    // Repay DCHF tokens to a Trove: burn the repaid DCHF tokens, and reduce the trove's debt accordingly
    function repayDCHF(
        address _asset,
        uint256 _DCHFamount,
        address _upperHint,
        address _lowerHint
    ) external override {
        _adjustTrove(_asset, 0, msg.sender, 0, _DCHFamount, false, _upperHint, _lowerHint, 0);
    }

    function adjustTrove(
        address _asset,
        uint256 _assetSent,
        uint256 _maxFeePercentage,
        uint256 _collWithdrawal,
        uint256 _DCHFChange,
        bool _isDebtIncrease,
        address _upperHint,
        address _lowerHint
    ) external payable override {
        _adjustTrove(
            _asset,
            getMethodValue(_asset, _assetSent, true),
            msg.sender,
            _collWithdrawal,
            _DCHFChange,
            _isDebtIncrease,
            _upperHint,
            _lowerHint,
            _maxFeePercentage
        );
    }

    /*
     * _adjustTrove(): Alongside a debt change, this function can perform either a collateral top-up or a collateral withdrawal.
     * It therefore expects either a positive msg.value, or a positive _collWithdrawal argument.
     * If both are positive, it will revert.
     */
    function _adjustTrove(
        address _asset,
        uint256 _assetSent,
        address _borrower,
        uint256 _collWithdrawal,
        uint256 _DCHFChange,
        bool _isDebtIncrease,
        address _upperHint,
        address _lowerHint,
        uint256 _maxFeePercentage
    ) internal {
        ContractsCache memory contractsCache = ContractsCache(
            troveManager,
            dfrancParams.activePool(),
            DCHFToken
        );
        LocalVariables_adjustTrove memory vars;
        vars.asset = _asset;

        require(
            msg.value == 0 || msg.value == _assetSent,
            "BorrowerOps: _assetSent and msg.value aren't the same!"
        );

        vars.price = dfrancParams.priceFeed().fetchPrice(vars.asset);

        if (_isDebtIncrease) {
            _requireValidMaxFeePercentage(vars.asset, _maxFeePercentage);
            _requireNonZeroDebtChange(_DCHFChange);
            _requireBorrowTVLBelowCap(contractsCache.activePool, vars.asset, _DCHFChange);
        }
        _requireSingularCollChange(_collWithdrawal, _assetSent);
        _requireNonZeroAdjustment(_collWithdrawal, _DCHFChange, _assetSent);
        _requireTroveisActive(vars.asset, contractsCache.troveManager, _borrower);

        // Get the collChange based on whether or not ETH was sent in the transaction
        (vars.collChange, vars.isCollIncrease) = _getCollChange(_assetSent, _collWithdrawal);

        vars.netDebtChange = _DCHFChange;

        // If the adjustment incorporates a debt increase and system is in Normal Mode, then trigger a borrowing fee
        if (_isDebtIncrease) {
            vars.DCHFFee = _triggerBorrowingFee(
                vars.asset,
                contractsCache.troveManager,
                contractsCache.DCHFToken,
                _DCHFChange,
                _maxFeePercentage
            );
            vars.netDebtChange = vars.netDebtChange + vars.DCHFFee; // The raw debt change includes the fee
        }

        vars.coll = contractsCache.troveManager.getTroveColl(vars.asset, _borrower);
        vars.debt = contractsCache.troveManager.getTroveDebt(vars.asset, _borrower);

        // Get the trove's new ICR after the adjustment
        vars.newICR = _getNewICRFromTroveChange(
            vars.coll,
            vars.debt,
            vars.collChange,
            vars.isCollIncrease,
            vars.netDebtChange,
            _isDebtIncrease,
            vars.price
        );
        require(_collWithdrawal <= vars.coll, "BorrowerOps: Trying to remove more than the trove holds");

        // Check the adjustment satisfies all conditions for the current system mode
        _requireValidAdjustment(vars.asset, _isDebtIncrease, _collWithdrawal, vars);

        // When the adjustment is a debt repayment, check it's a valid amount and that the caller has enough DCHF
        if (!_isDebtIncrease && _DCHFChange > 0) {
            _requireAtLeastMinNetDebt(vars.asset, vars.debt - vars.netDebtChange);
            _requireValidDCHFRepayment(vars.debt, vars.netDebtChange);
            _requireSufficientDCHFBalance(contractsCache.DCHFToken, _borrower, vars.netDebtChange);
        }

        (vars.newColl, vars.newDebt) = _updateTroveFromAdjustment(
            vars.asset,
            contractsCache.troveManager,
            _borrower,
            vars.collChange,
            vars.isCollIncrease,
            vars.netDebtChange,
            _isDebtIncrease
        );

        // Re-insert trove in to the sorted list
        uint256 newNICR = DfrancMath._computeNominalCR(vars.newColl, vars.newDebt);
        sortedTroves.reInsert(vars.asset, _borrower, newNICR, _upperHint, _lowerHint);

        emit TroveUpdated(vars.asset, _borrower, vars.newDebt, vars.newColl, BorrowerOperation.adjustTrove);
        emit DCHFBorrowingFeePaid(vars.asset, msg.sender, vars.DCHFFee);

        // Use the unmodified _DCHFChange here, as we don't send the fee to the user
        _moveTokensAndETHfromAdjustment(
            vars.asset,
            contractsCache.activePool,
            contractsCache.DCHFToken,
            msg.sender,
            vars.collChange,
            vars.isCollIncrease,
            _DCHFChange,
            _isDebtIncrease,
            vars.netDebtChange
        );
    }

    function closeTrove(address _asset) external override {
        ITroveManager troveManagerCached = troveManager;
        IActivePool activePoolCached = dfrancParams.activePool();
        IDCHFToken DCHFTokenCached = DCHFToken;

        _requireTroveisActive(_asset, troveManagerCached, msg.sender);
        uint256 price = dfrancParams.priceFeed().fetchPrice(_asset);

        uint256 coll = troveManagerCached.getTroveColl(_asset, msg.sender);
        uint256 debt = troveManagerCached.getTroveDebt(_asset, msg.sender);

        _requireSufficientDCHFBalance(DCHFTokenCached, msg.sender, debt);

        uint256 newTCR = _getNewTCRFromTroveChange(_asset, coll, false, debt, false, price);
        _requireNewTCRisAboveLimit(_asset, newTCR);

        troveManagerCached.closeTrove(_asset, msg.sender);

        emit TroveUpdated(_asset, msg.sender, 0, 0, BorrowerOperation.closeTrove);

        // Burn the repaid DCHF from the user's balance
        _repayDCHF(_asset, activePoolCached, DCHFTokenCached, msg.sender, debt);

        // Send the collateral back to the user
        activePoolCached.sendAsset(_asset, msg.sender, coll);
    }

    // Claim remaining collateral from a redemption.
    function claimCollateral(address _asset) external override {
        collSurplusPool.claimColl(_asset, msg.sender); // Send ETH from CollSurplus Pool to owner
    }

    // --- Helper functions --- //

    function _triggerBorrowingFee(
        address _asset,
        ITroveManager _troveManager,
        IDCHFToken _DCHFToken,
        uint256 _DCHFamount,
        uint256 _maxFeePercentage
    ) internal returns (uint256) {
        _troveManager.decayBaseRateFromBorrowing(_asset); // decay the baseRate state variable
        uint256 DCHFFee = _troveManager.getBorrowingFee(_asset, _DCHFamount);

        _requireUserAcceptsFee(DCHFFee, _DCHFamount, _maxFeePercentage);

        // Send fee to feeContract
        _DCHFToken.mint(_asset, feeContractAddress, DCHFFee);

        return DCHFFee;
    }

    function _getCollChange(uint256 _collReceived, uint256 _requestedCollWithdrawal)
        internal
        pure
        returns (uint256 collChange, bool isCollIncrease)
    {
        if (_collReceived != 0) {
            collChange = _collReceived;
            isCollIncrease = true;
        } else {
            collChange = _requestedCollWithdrawal;
        }
    }

    // Update trove's coll and debt based on whether they increase or decrease
    function _updateTroveFromAdjustment(
        address _asset,
        ITroveManager _troveManager,
        address _borrower,
        uint256 _collChange,
        bool _isCollIncrease,
        uint256 _debtChange,
        bool _isDebtIncrease
    ) internal returns (uint256, uint256) {
        uint256 newColl = (_isCollIncrease)
            ? _troveManager.increaseTroveColl(_asset, _borrower, _collChange)
            : _troveManager.decreaseTroveColl(_asset, _borrower, _collChange);
        uint256 newDebt = (_isDebtIncrease)
            ? _troveManager.increaseTroveDebt(_asset, _borrower, _debtChange)
            : _troveManager.decreaseTroveDebt(_asset, _borrower, _debtChange);

        return (newColl, newDebt);
    }

    function _moveTokensAndETHfromAdjustment(
        address _asset,
        IActivePool _activePool,
        IDCHFToken _DCHFToken,
        address _borrower,
        uint256 _collChange,
        bool _isCollIncrease,
        uint256 _DCHFChange,
        bool _isDebtIncrease,
        uint256 _netDebtChange
    ) internal {
        if (_isDebtIncrease) {
            _withdrawDCHF(_asset, _activePool, _DCHFToken, _borrower, _DCHFChange, _netDebtChange);
        } else {
            _repayDCHF(_asset, _activePool, _DCHFToken, _borrower, _DCHFChange);
        }

        if (_isCollIncrease) {
            _activePoolAddColl(_asset, _activePool, _collChange);
        } else {
            _activePool.sendAsset(_asset, _borrower, _collChange);
        }
    }

    // Send ETH to Active Pool and increase its recorded ETH balance
    function _activePoolAddColl(
        address _asset,
        IActivePool _activePool,
        uint256 _amount
    ) internal {
        if (_asset == ETH_REF_ADDRESS) {
            (bool success, ) = address(_activePool).call{value: _amount}("");
            require(success, "BorrowerOps: Sending ETH to ActivePool failed");
        } else {
            IERC20(_asset).safeTransferFrom(
                msg.sender,
                address(_activePool),
                SafetyTransfer.decimalsCorrection(_asset, _amount)
            );

            _activePool.receivedERC20(_asset, _amount);
        }
    }

    // Issue the specified amount of DCHF to _account and increases the total active debt (_netDebtIncrease potentially includes a DCHFFee)
    function _withdrawDCHF(
        address _asset,
        IActivePool _activePool,
        IDCHFToken _DCHFToken,
        address _account,
        uint256 _DCHFamount,
        uint256 _netDebtIncrease
    ) internal {
        _activePool.increaseDCHFDebt(_asset, _netDebtIncrease);
        _DCHFToken.mint(_asset, _account, _DCHFamount);
    }

    // Burn the specified amount of DCHF from _account and decreases the total active debt
    function _repayDCHF(
        address _asset,
        IActivePool _activePool,
        IDCHFToken _DCHFToken,
        address _account,
        uint256 _DCHF
    ) internal {
        _activePool.decreaseDCHFDebt(_asset, _DCHF);
        _DCHFToken.burn(_account, _DCHF);
    }

    // --- 'Require' wrapper functions --- //

    function _requireSingularCollChange(uint256 _collWithdrawal, uint256 _amountSent) internal pure {
        require(_collWithdrawal == 0 || _amountSent == 0, "BorrowerOps: Cannot withdraw and add coll");
    }

    function _requireNonZeroAdjustment(
        uint256 _collWithdrawal,
        uint256 _DCHFChange,
        uint256 _assetSent
    ) internal view {
        require(
            msg.value != 0 || _collWithdrawal != 0 || _DCHFChange != 0 || _assetSent != 0,
            "BorrowerOps: There must be either a collateral change or a debt change"
        );
    }

    function _requireTroveisActive(
        address _asset,
        ITroveManager _troveManager,
        address _borrower
    ) internal view {
        uint256 status = _troveManager.getTroveStatus(_asset, _borrower);
        require(status == 1, "BorrowerOps: Trove does not exist or is closed");
    }

    function _requireTroveisNotActive(
        address _asset,
        ITroveManager _troveManager,
        address _borrower
    ) internal view {
        uint256 status = _troveManager.getTroveStatus(_asset, _borrower);
        require(status != 1, "BorrowerOps: Trove is active");
    }

    function _requireNonZeroDebtChange(uint256 _DCHFChange) internal pure {
        require(_DCHFChange > 0, "BorrowerOps: Debt increase requires non-zero debtChange");
    }

    function _requireValidAdjustment(
        address _asset,
        bool _isDebtIncrease,
        uint256 _collWithdrawal,
        LocalVariables_adjustTrove memory _vars
    ) internal view {
        // In Normal Mode, ensure the new ICR is above MCR and the TCR is above the LIMIT_CR
        _requireICRisAboveMCR(_asset, _vars.newICR);

        // If the TCR is below Limit only prevent debt increases or coll withdrawals
        if (_isDebtIncrease || _collWithdrawal > 0) {
            _vars.newTCR = _getNewTCRFromTroveChange(
                _asset,
                _vars.collChange,
                _vars.isCollIncrease,
                _vars.netDebtChange,
                _isDebtIncrease,
                _vars.price
            );
            _requireNewTCRisAboveLimit(_asset, _vars.newTCR);
        }
    }

    function _requireICRisAboveMCR(address _asset, uint256 _newICR) internal view {
        require(
            _newICR >= dfrancParams.BORROW_MCR(_asset),
            "BorrowerOps: An operation that would result in ICR < MCR is not permitted"
        );
    }

    function _requireNewTCRisAboveLimit(address _asset, uint256 _newTCR) internal view {
        require(
            _newTCR >= dfrancParams.LIMIT_CR(_asset),
            "BorrowerOps: An operation that would result in TCR < LIMIT_CR is not permitted"
        );
    }

    function _requireAtLeastMinNetDebt(address _asset, uint256 _netDebt) internal view {
        require(
            _netDebt >= dfrancParams.MIN_NET_DEBT(_asset),
            "BorrowerOps: Trove's net debt must be greater than minimum"
        );
    }

    function _requireBorrowTVLBelowCap(
        IActivePool _activePool,
        address _asset,
        uint256 _DCHFamount
    ) internal view {
        require(
            _activePool.getDCHFDebt(_asset) + _DCHFamount <= dfrancParams.TVL_CAP(_asset),
            "BorrowerOps: Borrow Cap reached"
        );
    }

    function _requireValidDCHFRepayment(uint256 _currentDebt, uint256 _debtRepayment) internal pure {
        require(_debtRepayment <= _currentDebt, "BorrowerOps: Amount repaid is larger than Trove's debt");
    }

    function _requireSufficientDCHFBalance(
        IDCHFToken _DCHFToken,
        address _borrower,
        uint256 _debtRepayment
    ) internal view {
        require(
            _DCHFToken.balanceOf(_borrower) >= _debtRepayment,
            "BorrowerOps: Caller doesnt have enough DCHF to make repayment"
        );
    }

    function _requireValidMaxFeePercentage(address _asset, uint256 _maxFeePercentage) internal view {
        require(
            _maxFeePercentage >= dfrancParams.BORROWING_FEE_FLOOR(_asset) &&
                _maxFeePercentage <= dfrancParams.DECIMAL_PRECISION(),
            "Max fee percentage must be between 0.5% and 100%"
        );
    }

    // --- ICR and TCR getters --- //

    // Compute the new collateral ratio, considering the change in coll and debt. Assumes 0 pending rewards.
    function _getNewICRFromTroveChange(
        uint256 _coll,
        uint256 _debt,
        uint256 _collChange,
        bool _isCollIncrease,
        uint256 _debtChange,
        bool _isDebtIncrease,
        uint256 _price
    ) internal pure returns (uint256) {
        (uint256 newColl, uint256 newDebt) = _getNewTroveAmounts(
            _coll,
            _debt,
            _collChange,
            _isCollIncrease,
            _debtChange,
            _isDebtIncrease
        );

        uint256 newICR = DfrancMath._computeCR(newColl, newDebt, _price);
        return newICR;
    }

    function _getNewTroveAmounts(
        uint256 _coll,
        uint256 _debt,
        uint256 _collChange,
        bool _isCollIncrease,
        uint256 _debtChange,
        bool _isDebtIncrease
    ) internal pure returns (uint256, uint256) {
        uint256 newColl = _coll;
        uint256 newDebt = _debt;

        newColl = _isCollIncrease ? _coll + _collChange : _coll - _collChange;
        newDebt = _isDebtIncrease ? _debt + _debtChange : _debt - _debtChange;

        return (newColl, newDebt);
    }

    function _getNewTCRFromTroveChange(
        address _asset,
        uint256 _collChange,
        bool _isCollIncrease,
        uint256 _debtChange,
        bool _isDebtIncrease,
        uint256 _price
    ) internal view returns (uint256) {
        uint256 totalColl = getEntireSystemColl(_asset);
        uint256 totalDebt = getEntireSystemDebt(_asset);

        totalColl = _isCollIncrease ? totalColl + _collChange : totalColl - _collChange;
        totalDebt = _isDebtIncrease ? totalDebt + _debtChange : totalDebt - _debtChange;

        uint256 newTCR = DfrancMath._computeCR(totalColl, totalDebt, _price);
        return newTCR;
    }

    function getMethodValue(
        address _asset,
        uint256 _amount,
        bool canBeZero
    ) private view returns (uint256) {
        bool isEth = _asset == address(0);

        require(
            (canBeZero || (isEth && msg.value != 0)) || (!isEth && msg.value == 0),
            "BorrowerOp: Invalid Input. Override msg.value only if using ETH asset, otherwise use _tokenAmount"
        );

        if (_asset == address(0)) {
            _amount = msg.value;
        }

        return _amount;
    }
}
