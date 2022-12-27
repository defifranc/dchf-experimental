// SPDX-License-Identifier: MIT

pragma solidity 0.8.14;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./Dependencies/DfrancBase.sol";
import "./Dependencies/CheckContract.sol";

import "./Interfaces/ITroveManager.sol";

/*
 * In this leverage version there is no CollGasCompensation and no DCHFGasCompensation.
 * Besides, there is a protocol fee on the total Collateral liquidated.
 * No redistribution as it happens when the DCHF of the Stability Pool is not enough for the liquidation
 * and the rest of the debt and coll gets redistributed between the users.
 * No interactions with Default Pool.
 * Ownable is inherited from DfrancBase.
 */

contract TroveManager is DfrancBase, CheckContract, ITroveManager {
    using SafeERC20 for IERC20;

    string public constant NAME = "TroveManager";

    // --- Connected contract declarations --- //

    address public borrowerOperationsAddress;
    address public feeContractAddress;

    ICollSurplusPool collSurplusPool;

    IDCHFToken public override dchfToken;

    // A doubly linked list of Troves sorted by their sorted by their collateral ratios
    ISortedTroves public sortedTroves;

    // --- Data structures --- //

    // Store the necessary data for a trove
    struct Trove {
        address asset;
        uint256 debt;
        uint256 coll;
        Status status;
        uint128 arrayIndex;
    }

    bool public isInitialized;

    uint256 public constant SECONDS_IN_ONE_MINUTE = 60;
    /*
     * Half-life of 12h. 12h = 720 min
     * (1/2) = d^720 => d = (1/2)^(1/720)
     */
    uint256 public constant MINUTE_DECAY_FACTOR = 999037758833783000;

    /*
     * BETA: 18 digit decimal. Parameter by which to divide the redeemed fraction, in order to calc the new base rate from a redemption.
     * Corresponds to (1 / ALPHA) in the white paper.
     */
    uint256 public constant BETA = 2;

    mapping(address => uint256) public baseRate;

    // The timestamp of the latest fee operation (redemption or new DCHF issuance)
    mapping(address => uint256) public lastFeeOperationTime;

    mapping(address => mapping(address => Trove)) public Troves;

    // Array of all active trove addresses - used to to compute an approximate hint off-chain, for the sorted list insertion
    mapping(address => address[]) public TroveOwners;

    mapping(address => bool) public redemptionWhitelist;
    bool public isRedemptionWhitelisted;

    mapping(address => bool) public liquidationWhitelist;
    bool public isLiquidationWhitelisted;

    uint256 public protocolFee; // In bps 1% = 100, 10% = 1000, 100% = 10000

    modifier troveIsActive(address _asset, address _borrower) {
        require(isTroveActive(_asset, _borrower), "TroveManager: Trove does not exist or is closed");
        _;
    }

    function _onlyBorrowerOperations() private view {
        require(msg.sender == borrowerOperationsAddress, "TroveManager: Caller is not BorrowerOperations");
    }

    modifier onlyBorrowerOperations() {
        _onlyBorrowerOperations();
        _;
    }

    // --- Dependency setter --- //

    function setAddresses(
        address _collSurplusPoolAddress,
        address _dchfTokenAddress,
        address _sortedTrovesAddress,
        address _feeContractAddress,
        address _dfrancParamsAddress,
        address _borrowerOperationsAddress
    ) external override onlyOwner {
        require(!isInitialized, "Already initialized");
        checkContract(_collSurplusPoolAddress);
        checkContract(_dchfTokenAddress);
        checkContract(_sortedTrovesAddress);
        checkContract(_feeContractAddress);
        checkContract(_dfrancParamsAddress);
        checkContract(_borrowerOperationsAddress);

        isInitialized = true;

        collSurplusPool = ICollSurplusPool(_collSurplusPoolAddress);
        dchfToken = IDCHFToken(_dchfTokenAddress);
        sortedTroves = ISortedTroves(_sortedTrovesAddress);

        borrowerOperationsAddress = _borrowerOperationsAddress;
        feeContractAddress = _feeContractAddress;

        setDfrancParameters(_dfrancParamsAddress);
    }

    // --- Setter onlyOwner --- //

    function setFeeContractAddress(address _newFeeAddress) external onlyOwner {
        require(_newFeeAddress != address(0), "BorrowerOps: Not valid address");
        feeContractAddress = _newFeeAddress;
        emit FeeContractAddressChanged(feeContractAddress);
    }

    // --- Trove Getter functions --- //

    function isContractTroveManager() public pure returns (bool) {
        return true;
    }

    // --- Trove Liquidation functions --- //

    // Single liquidation function. Closes the trove if its ICR is lower than the minimum collateral ratio.
    function liquidate(address _asset, address _borrower) external override troveIsActive(_asset, _borrower) {
        address[] memory borrowers = new address[](1);
        borrowers[0] = _borrower;
        batchLiquidateTroves(_asset, borrowers);
    }

    // --- Inner single liquidation functions --- //

    // Liquidate one trove, in Normal Mode. Trove debt is DCHF amount + DCHF borrowing fee.
    function _liquidateNormalMode(address _asset, address _borrower)
        internal
        returns (LiquidationValues memory singleLiquidation)
    {
        (
            singleLiquidation.entireTroveColl, // coll
            singleLiquidation.entireTroveDebt // debt
        ) = _getCurrentTroveAmounts(_asset, _borrower); // Troves[_borrower][_asset]

        _closeTrove(_asset, _borrower, Status.closedByLiquidation); // Troves[_borrower][_asset] = 0;

        emit TroveLiquidated(
            _asset,
            _borrower,
            singleLiquidation.entireTroveDebt,
            singleLiquidation.entireTroveColl,
            TroveManagerOperation.liquidateInNormalMode
        );
        emit TroveUpdated(_asset, _borrower, 0, 0, TroveManagerOperation.liquidateInNormalMode);
    }

    /*
     * Liquidate a sequence of troves. Closes a maximum number of n under-collateralized Troves,
     * starting from the one with the lowest collateral ratio in the system, and moving upwards.
     */
    function liquidateTroves(address _asset, uint256 _n) external override {
        if (isLiquidationWhitelisted) {
            require(liquidationWhitelist[msg.sender], "TroveManager: Not in whitelist");
        }

        LocalVariables_OuterLiquidationFunction memory vars;
        LiquidationTotals memory totals;

        vars.price = dfrancParams.priceFeed().fetchPrice(_asset);

        totals = _getTotalsFromLiquidateTrovesSequence_NormalMode(_asset, vars.price, _n, msg.sender);

        require(totals.totalDebtInSequence > 0, "TroveManager: Nothing to liquidate");

        // Burn the DCHF debt amount from liquidator and compensate with the trove collateral, minus fees
        uint256 protocolCompensation = _executeLiq(
            _asset,
            totals.totalCollInSequence,
            totals.totalDebtInSequence,
            msg.sender
        );

        emit Liquidation(
            _asset,
            totals.totalDebtInSequence,
            totals.totalCollInSequence,
            protocolCompensation
        );
    }

    function _getTotalsFromLiquidateTrovesSequence_NormalMode(
        address _asset,
        uint256 _price,
        uint256 _n,
        address _liquidator
    ) internal returns (LiquidationTotals memory totals) {
        LocalVariables_LiquidationSequence memory vars;
        LiquidationValues memory singleLiquidation;
        ISortedTroves sortedTrovesCached = sortedTroves;

        vars.remainingDCHFInLiquidator = dchfToken.balanceOf(_liquidator);

        for (vars.i = 0; vars.i < _n; vars.i++) {
            vars.user = sortedTrovesCached.getLast(_asset);
            vars.ICR = getCurrentICR(_asset, vars.user, _price);

            if (vars.ICR < dfrancParams.LIQ_MCR(_asset)) {
                singleLiquidation = _liquidateNormalMode(_asset, vars.user);

                require(
                    singleLiquidation.entireTroveDebt <= vars.remainingDCHFInLiquidator,
                    "Not enough funds to liquidate n Troves"
                );
                vars.remainingDCHFInLiquidator =
                    vars.remainingDCHFInLiquidator -
                    singleLiquidation.entireTroveDebt;

                // Add liquidation values to their respective running totals
                totals = _addLiquidationValuesToTotals(totals, singleLiquidation);
            } else break; // Break if the loop reaches a Trove with ICR >= MCR
        }
    }

    /*
     * Attempt to liquidate a custom list of troves provided by the caller.
     */
    function batchLiquidateTroves(address _asset, address[] memory _troveArray) public override {
        if (isLiquidationWhitelisted) {
            require(liquidationWhitelist[msg.sender], "TroveManager: Not in whitelist");
        }

        require(_troveArray.length != 0, "TroveManager: Calldata address array must not be empty");

        LocalVariables_OuterLiquidationFunction memory vars;
        LiquidationTotals memory totals;

        vars.price = dfrancParams.priceFeed().fetchPrice(_asset);

        totals = _getTotalsFromBatchLiquidate_NormalMode(_asset, vars.price, _troveArray, msg.sender);

        require(totals.totalDebtInSequence > 0, "TroveManager: Nothing to liquidate");

        // Burn the DCHF debt amount from liquidator and compensate with the trove collateral, minus fees
        uint256 protocolCompensation = _executeLiq(
            _asset,
            totals.totalCollInSequence,
            totals.totalDebtInSequence,
            msg.sender
        );

        emit Liquidation(
            _asset,
            totals.totalDebtInSequence,
            totals.totalCollInSequence,
            protocolCompensation
        );
    }

    function _getTotalsFromBatchLiquidate_NormalMode(
        address _asset,
        uint256 _price,
        address[] memory _troveArray,
        address _liquidator
    ) internal returns (LiquidationTotals memory totals) {
        LocalVariables_LiquidationSequence memory vars;
        LiquidationValues memory singleLiquidation;

        vars.remainingDCHFInLiquidator = dchfToken.balanceOf(_liquidator);

        for (vars.i = 0; vars.i < _troveArray.length; vars.i++) {
            vars.user = _troveArray[vars.i];
            vars.ICR = getCurrentICR(_asset, vars.user, _price);

            if (vars.ICR < dfrancParams.LIQ_MCR(_asset)) {
                singleLiquidation = _liquidateNormalMode(_asset, vars.user);

                require(
                    singleLiquidation.entireTroveDebt <= vars.remainingDCHFInLiquidator,
                    "Not enough funds to liquidate n Troves"
                );
                vars.remainingDCHFInLiquidator =
                    vars.remainingDCHFInLiquidator -
                    singleLiquidation.entireTroveDebt;

                // Add liquidation values to their respective running totals (totals start in 0)
                totals = _addLiquidationValuesToTotals(totals, singleLiquidation);
            }
        }
    }

    // --- Liquidation helper functions --- //

    // Tally all the values with their respective running totals
    function _addLiquidationValuesToTotals(
        LiquidationTotals memory oldTotals,
        LiquidationValues memory singleLiquidation
    ) internal pure returns (LiquidationTotals memory newTotals) {
        newTotals.totalDebtInSequence = oldTotals.totalDebtInSequence + singleLiquidation.entireTroveDebt;
        newTotals.totalCollInSequence = oldTotals.totalCollInSequence + singleLiquidation.entireTroveColl;
    }

    function _executeLiq(
        address _asset,
        uint256 _collToRelease,
        uint256 _debtToOffset,
        address _liquidator
    ) internal returns (uint256) {
        IActivePool activePoolCached = dfrancParams.activePool();

        require(dchfToken.balanceOf(_liquidator) >= _debtToOffset, "TroveManager: Not enough balance");

        activePoolCached.decreaseDCHFDebt(_asset, _debtToOffset); // cancel the liquidated DCHF debt

        dchfToken.burn(_liquidator, _debtToOffset); // burn the DCHF debt amount form the liquidator

        uint256 protocolGain = (_collToRelease * protocolFee) / 10000;
        uint256 collToLiquidator = _collToRelease - protocolGain;

        activePoolCached.sendAsset(_asset, feeContractAddress, protocolGain);
        activePoolCached.sendAsset(_asset, _liquidator, collToLiquidator);

        return protocolGain;
    }

    function setFee(uint256 _fee) external onlyOwner {
        require(_fee >= 0 && _fee < 1000, "TroveManager: Invalid fee value"); // Between 0 and 10% of the total collateral
        uint256 prevFee = protocolFee;
        protocolFee = _fee;
        emit SetFees(protocolFee, prevFee);
    }

    function setLiquidationWhitelistStatus(bool _status) external onlyOwner {
        isLiquidationWhitelisted = _status;
    }

    function addUserToWhitelistLiquidation(address _user) external onlyOwner {
        liquidationWhitelist[_user] = true;
    }

    function removeUserFromWhitelistLiquidation(address _user) external onlyOwner {
        delete liquidationWhitelist[_user];
    }

    // --- Redemption functions --- //

    // Redeem as much collateral as possible from _borrower's Trove in exchange for DCHF up to _maxDCHFamount
    function _redeemCollateralFromTrove(
        address _asset,
        ContractsCache memory _contractsCache,
        address _borrower,
        uint256 _maxDCHFamount,
        uint256 _price,
        address _upperPartialRedemptionHint,
        address _lowerPartialRedemptionHint,
        uint256 _partialRedemptionHintNICR
    ) internal returns (SingleRedemptionValues memory singleRedemption) {
        LocalVariables_AssetBorrowerPrice memory vars = LocalVariables_AssetBorrowerPrice(
            _asset,
            _borrower,
            _price
        );

        // Determine the remaining amount (lot) to be redeemed, capped by the entire debt of the Trove minus the liquidation reserve
        singleRedemption.DCHFLot = DfrancMath._min(_maxDCHFamount, getTroveDebt(vars._asset, vars._borrower));

        // Get the ETHLot of equivalent value in USD (ETH value of the DCHF amount to redeem)
        singleRedemption.ETHLot = (singleRedemption.DCHFLot * DECIMAL_PRECISION) / _price;

        // Decrease the debt and collateral of the current Trove according to the DCHF lot and corresponding ETH to send
        uint256 newDebt = (getTroveDebt(vars._asset, vars._borrower)) - singleRedemption.DCHFLot;
        uint256 newColl = (getTroveColl(vars._asset, vars._borrower)) - singleRedemption.ETHLot; // newColl is the collSurplus that remains for the borrower (TotalColl - ETHLot)

        if (newDebt == 0) {
            // No debt left in the Trove (except for the liquidation reserve), therefore the trove gets closed
            _closeTrove(vars._asset, vars._borrower, Status.closedByRedemption);

            _redeemCloseTrove(vars._asset, _contractsCache, vars._borrower, newColl);

            emit TroveUpdated(vars._asset, vars._borrower, 0, 0, TroveManagerOperation.redeemCollateral);
        } else {
            uint256 newNICR = DfrancMath._computeNominalCR(newColl, newDebt);

            /*
             * If the provided hint is out of date, we bail since trying to reinsert without a good hint will almost
             * certainly result in running out of gas.
             *
             * If the resultant net debt of the partial is less than the minimum, net debt we bail.
             */
            if (newNICR != _partialRedemptionHintNICR || newDebt < dfrancParams.MIN_NET_DEBT(vars._asset)) {
                singleRedemption.cancelledPartial = true;
                return singleRedemption;
            }

            _contractsCache.sortedTroves.reInsert(
                vars._asset,
                vars._borrower,
                newNICR,
                _upperPartialRedemptionHint,
                _lowerPartialRedemptionHint
            );

            _setTroveDebtAndColl(vars._asset, vars._borrower, newDebt, newColl);

            emit TroveUpdated(
                vars._asset,
                vars._borrower,
                newDebt,
                newColl,
                TroveManagerOperation.redeemCollateral
            );
        }

        return singleRedemption;
    }

    /*
     * Called when a full redemption occurs, and closes the trove.
     * The redeemer swaps (debt) DCHF for (debt) worth of ETH, as here there is no DCHF liquidation reserve.
     * In this case, there is no need to burn the DCHF liquidation reserve, and remove the corresponding debt from the active pool.
     * The debt recorded on the trove's struct is zero'd elsewhere, in _closeTrove.
     * Any surplus ETH left in the trove, is sent to the Coll surplus pool, and can be later claimed by the borrower.
     */
    function _redeemCloseTrove(
        address _asset,
        ContractsCache memory _contractsCache,
        address _borrower,
        uint256 _ETH
    ) internal {
        // Send ETH from Active Pool to the CollSurplusPool -> the borrower can reclaim it later
        _contractsCache.collSurplusPool.accountSurplus(_asset, _borrower, _ETH);
        _contractsCache.activePool.sendAsset(_asset, address(_contractsCache.collSurplusPool), _ETH);
    }

    function _isValidFirstRedemptionHint(
        address _asset,
        ISortedTroves _sortedTroves,
        address _firstRedemptionHint,
        uint256 _price
    ) internal view returns (bool) {
        if (
            _firstRedemptionHint == address(0) ||
            !_sortedTroves.contains(_asset, _firstRedemptionHint) ||
            getCurrentICR(_asset, _firstRedemptionHint, _price) < dfrancParams.LIQ_MCR(_asset)
        ) {
            return false;
        }

        address nextTrove = _sortedTroves.getNext(_asset, _firstRedemptionHint);
        return
            nextTrove == address(0) ||
            getCurrentICR(_asset, nextTrove, _price) < dfrancParams.LIQ_MCR(_asset);
    }

    function setRedemptionWhitelistStatus(bool _status) external onlyOwner {
        isRedemptionWhitelisted = _status;
    }

    function addUserToWhitelistRedemption(address _user) external onlyOwner {
        redemptionWhitelist[_user] = true;
    }

    function removeUserFromWhitelistRedemption(address _user) external onlyOwner {
        delete redemptionWhitelist[_user];
    }

    /* Send _DCHFamount DCHF to the system and redeem the corresponding amount of collateral from as many Troves as are needed to fill the redemption
     * request. Applies pending rewards to a Trove before reducing its debt and coll.
     *
     * Note that if _amount is very large, this function can run out of gas, specially if traversed troves are small. This can be easily avoided by
     * splitting the total _amount in appropriate chunks and calling the function multiple times.
     *
     * Param `_maxIterations` can also be provided, so the loop through Troves is capped (if it’s zero, it will be ignored).This makes it easier to
     * avoid OOG for the frontend, as only knowing approximately the average cost of an iteration is enough, without needing to know the “topology”
     * of the trove list. It also avoids the need to set the cap in stone in the contract, nor doing gas calculations, as both gas price and opcode
     * costs can vary.
     *
     * All Troves that are redeemed from -- with the likely exception of the last one -- will end up with no debt left, therefore they will be closed.
     * If the last Trove does have some remaining debt, it has a finite ICR, and the reinsertion could be anywhere in the list, therefore it requires a hint.
     * A frontend should use getRedemptionHints() to calculate what the ICR of this Trove will be after redemption, and pass a hint for its position
     * in the sortedTroves list along with the ICR value that the hint was found for.
     *
     * If another transaction modifies the list between calling getRedemptionHints() and passing the hints to redeemCollateral(), it
     * is very likely that the last (partially) redeemed Trove would end up with a different ICR than what the hint is for. In this case the
     * redemption will stop after the last completely redeemed Trove and the sender will keep the remaining DCHF amount, which they can attempt
     * to redeem later.
     *
     * A redemption sequence of n steps will fully redeem from up to n-1 Troves, and, and partially redeems from up to 1 Trove, which is always the last
     * Trove in the redemption sequence.
     */
    function redeemCollateral(
        address _asset,
        uint256 _DCHFamount,
        address _firstRedemptionHint, // hints at the position of the first Trove that will be redeemed from
        address _upperPartialRedemptionHint, // hints at the prevId neighbor of the last redeemed Trove upon reinsertion, if it's partially redeemed
        address _lowerPartialRedemptionHint, // hints at the nextId neighbor of the last redeemed Trove upon reinsertion, if it's partially redeemed
        uint256 _partialRedemptionHintNICR, // ensures that the transaction won't run out of gas if neither
        uint256 _maxIterations,
        uint256 _maxFeePercentage
    ) external override {
        if (isRedemptionWhitelisted) {
            require(redemptionWhitelist[msg.sender], "TroveManager: Not in whitelist");
        }

        // Redemptions are disabled during the first 14 days of operation to protect the system
        require(
            block.timestamp >= dfrancParams.redemptionBlock(_asset),
            "TroveManager: Redemption is blocked"
        );

        ContractsCache memory contractsCache = ContractsCache(
            dfrancParams.activePool(),
            dchfToken,
            sortedTroves,
            collSurplusPool
        );

        RedemptionTotals memory totals;

        totals.price = dfrancParams.priceFeed().fetchPrice(_asset);

        _requireValidMaxFeePercentage(_asset, _maxFeePercentage);
        _requireTCRoverMCR(_asset, totals.price);
        _requireAmountGreaterThanZero(_DCHFamount);
        _requireDCHFBalanceCoversRedemption(contractsCache.dchfToken, msg.sender, _DCHFamount);

        totals.totalDCHFSupplyAtStart = getEntireSystemDebt(_asset); // activePool
        totals.remainingDCHF = _DCHFamount;
        address currentBorrower;

        if (
            _isValidFirstRedemptionHint(
                _asset,
                contractsCache.sortedTroves,
                _firstRedemptionHint,
                totals.price
            )
        ) {
            currentBorrower = _firstRedemptionHint;
        } else {
            currentBorrower = contractsCache.sortedTroves.getLast(_asset);
            // Find the first trove with ICR >= MCR -> will only redeem from Troves that have an ICR >= MCR
            // Troves are redeemed from in ascending order of their collateralization ratio
            while (
                currentBorrower != address(0) &&
                getCurrentICR(_asset, currentBorrower, totals.price) < dfrancParams.LIQ_MCR(_asset)
            ) {
                currentBorrower = contractsCache.sortedTroves.getPrev(_asset, currentBorrower);
            }
        }

        // Loop through the Troves starting from the one with lowest collateral ratio until _amount of DCHF is exchanged for collateral
        if (_maxIterations == 0) {
            _maxIterations = type(uint256).max;
        }
        while (currentBorrower != address(0) && totals.remainingDCHF > 0 && _maxIterations > 0) {
            _maxIterations--;
            // Save the address of the Trove preceding the current one, before potentially modifying the list
            address nextUserToCheck = contractsCache.sortedTroves.getPrev(_asset, currentBorrower);

            SingleRedemptionValues memory singleRedemption = _redeemCollateralFromTrove(
                _asset,
                contractsCache,
                currentBorrower,
                totals.remainingDCHF,
                totals.price,
                _upperPartialRedemptionHint,
                _lowerPartialRedemptionHint,
                _partialRedemptionHintNICR
            );

            if (singleRedemption.cancelledPartial) break; // Partial redemption was cancelled (out-of-date hint, or new net debt < minimum), therefore we could not redeem from the last Trove

            totals.totalDCHFToRedeem = totals.totalDCHFToRedeem + singleRedemption.DCHFLot;
            totals.totalAssetDrawn = totals.totalAssetDrawn + singleRedemption.ETHLot;

            totals.remainingDCHF = totals.remainingDCHF - singleRedemption.DCHFLot;
            currentBorrower = nextUserToCheck;
        }
        require(totals.totalAssetDrawn > 0, "TroveManager: Unable to redeem any amount");

        // Decay the baseRate due to time passed, and then increase it according to the size of this redemption.
        // The baseRate increases with each redemption, and decays according to time passed since the last fee event.
        // Use the saved total DCHF supply value, from before it was reduced by the redemption.
        _updateBaseRateFromRedemption(
            _asset,
            totals.totalAssetDrawn,
            totals.price,
            totals.totalDCHFSupplyAtStart
        );

        // Calculate the ETH fee
        totals.ETHFee = _getRedemptionFee(_asset, totals.totalAssetDrawn);

        _requireUserAcceptsFee(totals.ETHFee, totals.totalAssetDrawn, _maxFeePercentage);

        // Send the ETH fee to the feeContract
        contractsCache.activePool.sendAsset(_asset, feeContractAddress, totals.ETHFee);

        totals.ETHToSendToRedeemer = totals.totalAssetDrawn - totals.ETHFee;

        emit Redemption(_asset, _DCHFamount, totals.totalDCHFToRedeem, totals.totalAssetDrawn, totals.ETHFee);

        // Burn the total DCHF that is cancelled with debt, and send the redeemed Asset (ETH) to msg.sender
        contractsCache.dchfToken.burn(msg.sender, totals.totalDCHFToRedeem);

        // Update Active Pool DCHF, and send ETH to account
        contractsCache.activePool.decreaseDCHFDebt(_asset, totals.totalDCHFToRedeem);
        contractsCache.activePool.sendAsset(_asset, msg.sender, totals.ETHToSendToRedeemer);
    }

    // --- Helper functions --- //

    // Return the nominal collateral ratio (ICR) of a given Trove, without the price. Takes a trove's pending coll and debt rewards from redistributions into account.
    function getNominalICR(address _asset, address _borrower) public view override returns (uint256) {
        (uint256 currentAsset, uint256 currentDCHFDebt) = _getCurrentTroveAmounts(_asset, _borrower);
        uint256 NICR = DfrancMath._computeNominalCR(currentAsset, currentDCHFDebt);
        return NICR;
    }

    // Return the current collateral ratio (ICR) of a given Trove. Takes a trove's pending coll and debt rewards from redistributions into account.
    function getCurrentICR(
        address _asset,
        address _borrower,
        uint256 _price
    ) public view override returns (uint256) {
        (uint256 currentAsset, uint256 currentDCHFDebt) = _getCurrentTroveAmounts(_asset, _borrower);
        uint256 ICR = DfrancMath._computeCR(currentAsset, currentDCHFDebt, _price);
        return ICR;
    }

    function _getCurrentTroveAmounts(address _asset, address _borrower)
        internal
        view
        returns (uint256, uint256)
    {
        uint256 currentAsset = Troves[_borrower][_asset].coll;
        uint256 currentDCHFDebt = Troves[_borrower][_asset].debt;

        return (currentAsset, currentDCHFDebt);
    }

    function closeTrove(address _asset, address _borrower) external override onlyBorrowerOperations {
        _closeTrove(_asset, _borrower, Status.closedByOwner);
    }

    function _closeTrove(
        address _asset,
        address _borrower,
        Status closedStatus
    ) internal {
        assert(closedStatus != Status.nonExistent && closedStatus != Status.active);

        uint256 TroveOwnersArrayLength = TroveOwners[_asset].length;
        _requireMoreThanOneTroveInSystem(_asset, TroveOwnersArrayLength);

        Troves[_borrower][_asset].status = closedStatus;
        Troves[_borrower][_asset].coll = 0;
        Troves[_borrower][_asset].debt = 0;

        _removeTroveOwner(_asset, _borrower, TroveOwnersArrayLength);
        sortedTroves.remove(_asset, _borrower);
    }

    function addTroveOwnerToArray(address _asset, address _borrower)
        external
        override
        onlyBorrowerOperations
        returns (uint256)
    {
        return _addTroveOwnerToArray(_asset, _borrower);
    }

    function _addTroveOwnerToArray(address _asset, address _borrower) internal returns (uint128 index) {
        TroveOwners[_asset].push(_borrower);

        index = uint128(TroveOwners[_asset].length - 1);
        Troves[_borrower][_asset].arrayIndex = index;
    }

    function _removeTroveOwner(
        address _asset,
        address _borrower,
        uint256 troveOwnersArrayLength
    ) internal {
        Status troveStatus = Troves[_borrower][_asset].status;
        assert(troveStatus != Status.nonExistent && troveStatus != Status.active);

        uint128 index = Troves[_borrower][_asset].arrayIndex;
        uint256 length = troveOwnersArrayLength;
        uint256 idxLast = length - 1;

        assert(index <= idxLast);

        address addressToMove = TroveOwners[_asset][idxLast];

        TroveOwners[_asset][index] = addressToMove;
        Troves[addressToMove][_asset].arrayIndex = index;
        emit TroveIndexUpdated(_asset, addressToMove, index);

        TroveOwners[_asset].pop();
    }

    function getTCR(address _asset, uint256 _price) external view override returns (uint256) {
        return _getTCR(_asset, _price);
    }

    function _updateBaseRateFromRedemption(
        address _asset,
        uint256 _ETHDrawn,
        uint256 _price,
        uint256 _totalDCHFSupply
    ) internal returns (uint256) {
        uint256 decayedBaseRate = _calcDecayedBaseRate(_asset);

        uint256 redeemedDCHFFraction = (_ETHDrawn * _price) / _totalDCHFSupply;

        uint256 newBaseRate = decayedBaseRate + (redeemedDCHFFraction / BETA);
        newBaseRate = DfrancMath._min(newBaseRate, DECIMAL_PRECISION);
        assert(newBaseRate > 0);

        baseRate[_asset] = newBaseRate;
        emit BaseRateUpdated(_asset, newBaseRate);

        _updateLastFeeOpTime(_asset);

        return newBaseRate;
    }

    function getRedemptionRate(address _asset) public view override returns (uint256) {
        return _calcRedemptionRate(_asset, baseRate[_asset]);
    }

    function getRedemptionRateWithDecay(address _asset) public view override returns (uint256) {
        return _calcRedemptionRate(_asset, _calcDecayedBaseRate(_asset));
    }

    function _calcRedemptionRate(address _asset, uint256 _baseRate) internal view returns (uint256) {
        return DfrancMath._min(dfrancParams.REDEMPTION_FEE_FLOOR(_asset) + _baseRate, DECIMAL_PRECISION);
    }

    function _getRedemptionFee(address _asset, uint256 _assetDraw) internal view returns (uint256) {
        return _calcRedemptionFee(getRedemptionRate(_asset), _assetDraw);
    }

    function getRedemptionFeeWithDecay(address _asset, uint256 _assetDraw)
        external
        view
        override
        returns (uint256)
    {
        return _calcRedemptionFee(getRedemptionRateWithDecay(_asset), _assetDraw);
    }

    function _calcRedemptionFee(uint256 _redemptionRate, uint256 _assetDraw) internal pure returns (uint256) {
        uint256 redemptionFee = (_redemptionRate * _assetDraw) / DECIMAL_PRECISION;
        require(redemptionFee < _assetDraw, "TroveManager: Fee would eat up all returned collateral");
        return redemptionFee;
    }

    function getBorrowingRate(address _asset) public view override returns (uint256) {
        return _calcBorrowingRate(_asset, baseRate[_asset]);
    }

    function getBorrowingRateWithDecay(address _asset) public view override returns (uint256) {
        return _calcBorrowingRate(_asset, _calcDecayedBaseRate(_asset));
    }

    function _calcBorrowingRate(address _asset, uint256 _baseRate) internal view returns (uint256) {
        return
            DfrancMath._min(
                dfrancParams.BORROWING_FEE_FLOOR(_asset) + _baseRate,
                dfrancParams.MAX_BORROWING_FEE(_asset)
            );
    }

    function getBorrowingFee(address _asset, uint256 _DCHFDebt) external view override returns (uint256) {
        return _calcBorrowingFee(getBorrowingRate(_asset), _DCHFDebt);
    }

    function getBorrowingFeeWithDecay(address _asset, uint256 _DCHFDebt) external view returns (uint256) {
        return _calcBorrowingFee(getBorrowingRateWithDecay(_asset), _DCHFDebt);
    }

    function _calcBorrowingFee(uint256 _borrowingRate, uint256 _DCHFDebt) internal pure returns (uint256) {
        return (_borrowingRate * _DCHFDebt) / DECIMAL_PRECISION;
    }

    function decayBaseRateFromBorrowing(address _asset) external override onlyBorrowerOperations {
        uint256 decayedBaseRate = _calcDecayedBaseRate(_asset);
        assert(decayedBaseRate <= DECIMAL_PRECISION);

        baseRate[_asset] = decayedBaseRate;
        emit BaseRateUpdated(_asset, decayedBaseRate);

        _updateLastFeeOpTime(_asset);
    }

    // Update the last fee operation time only if time passed >= decay interval. This prevents base rate griefing.
    function _updateLastFeeOpTime(address _asset) internal {
        uint256 timePassed = block.timestamp - lastFeeOperationTime[_asset];

        if (timePassed >= SECONDS_IN_ONE_MINUTE) {
            lastFeeOperationTime[_asset] = block.timestamp;
            emit LastFeeOpTimeUpdated(_asset, block.timestamp);
        }
    }

    function _calcDecayedBaseRate(address _asset) internal view returns (uint256) {
        uint256 minutesPassed = _minutesPassedSinceLastFeeOp(_asset);
        uint256 decayFactor = DfrancMath._decPow(MINUTE_DECAY_FACTOR, minutesPassed);

        return (baseRate[_asset] * decayFactor) / DECIMAL_PRECISION;
    }

    function _minutesPassedSinceLastFeeOp(address _asset) internal view returns (uint256) {
        return (block.timestamp - lastFeeOperationTime[_asset]) / SECONDS_IN_ONE_MINUTE;
    }

    function _requireDCHFBalanceCoversRedemption(
        IDCHFToken _dchfToken,
        address _redeemer,
        uint256 _amount
    ) internal view {
        require(
            _dchfToken.balanceOf(_redeemer) >= _amount,
            "TroveManager: Requested redemption amount must be <= user's DCHF token balance"
        );
    }

    function _requireMoreThanOneTroveInSystem(address _asset, uint256 TroveOwnersArrayLength) internal view {
        require(
            TroveOwnersArrayLength > 1 && sortedTroves.getSize(_asset) > 1,
            "TroveManager: Only one trove in the system"
        );
    }

    function _requireAmountGreaterThanZero(uint256 _amount) internal pure {
        require(_amount > 0, "TroveManager: Amount must be greater than zero");
    }

    function _requireTCRoverMCR(address _asset, uint256 _price) internal view {
        require(
            _getTCR(_asset, _price) >= dfrancParams.LIQ_MCR(_asset),
            "TroveManager: Cannot redeem when TCR < MCR"
        );
    }

    function _requireValidMaxFeePercentage(address _asset, uint256 _maxFeePercentage) internal view {
        require(
            _maxFeePercentage >= dfrancParams.REDEMPTION_FEE_FLOOR(_asset) &&
                _maxFeePercentage <= DECIMAL_PRECISION,
            "Max fee percentage must be between 0.5% and 100%"
        );
    }

    function isTroveActive(address _asset, address _borrower) public view override returns (bool) {
        return getTroveStatus(_asset, _borrower) == uint256(Status.active);
    }

    // --- Trove owners getters --- //

    function getTroveOwnersCount(address _asset) external view override returns (uint256) {
        return TroveOwners[_asset].length;
    }

    function getTroveFromTroveOwnersArray(address _asset, uint256 _index)
        external
        view
        override
        returns (address)
    {
        return TroveOwners[_asset][_index];
    }

    // --- Trove property getters --- //

    function getTrove(address _asset, address _borrower)
        external
        view
        override
        returns (
            address,
            uint256,
            uint256,
            Status,
            uint128
        )
    {
        Trove memory _trove = Troves[_borrower][_asset];
        return (_trove.asset, _trove.debt, _trove.coll, _trove.status, _trove.arrayIndex);
    }

    function getTroveStatus(address _asset, address _borrower) public view override returns (uint256) {
        return uint256(Troves[_borrower][_asset].status);
    }

    function getTroveDebt(address _asset, address _borrower) public view override returns (uint256) {
        return Troves[_borrower][_asset].debt;
    }

    function getTroveColl(address _asset, address _borrower) public view override returns (uint256) {
        return Troves[_borrower][_asset].coll;
    }

    function getEntireDebtAndColl(address _asset, address _borrower)
        public
        view
        override
        returns (uint256 debt, uint256 coll)
    {
        debt = Troves[_borrower][_asset].debt;
        coll = Troves[_borrower][_asset].coll;
    }

    // --- Trove property setters, internal --- //

    function _setTroveDebtAndColl(
        address _asset,
        address _borrower,
        uint256 _debt,
        uint256 _coll
    ) internal {
        Troves[_borrower][_asset].debt = _debt;
        Troves[_borrower][_asset].coll = _coll;
    }

    // --- Trove property setters, called by BorrowerOperations --- //

    function setTroveStatus(
        address _asset,
        address _borrower,
        uint256 _num
    ) external override onlyBorrowerOperations {
        Troves[_borrower][_asset].asset = _asset;
        Troves[_borrower][_asset].status = Status(_num);
    }

    function decreaseTroveColl(
        address _asset,
        address _borrower,
        uint256 _collDecrease
    ) external override onlyBorrowerOperations returns (uint256) {
        uint256 newColl = Troves[_borrower][_asset].coll - _collDecrease;
        Troves[_borrower][_asset].coll = newColl;
        return newColl;
    }

    function increaseTroveDebt(
        address _asset,
        address _borrower,
        uint256 _debtIncrease
    ) external override onlyBorrowerOperations returns (uint256) {
        uint256 newDebt = Troves[_borrower][_asset].debt + _debtIncrease;
        Troves[_borrower][_asset].debt = newDebt;
        return newDebt;
    }

    function decreaseTroveDebt(
        address _asset,
        address _borrower,
        uint256 _debtDecrease
    ) external override onlyBorrowerOperations returns (uint256) {
        uint256 newDebt = Troves[_borrower][_asset].debt - _debtDecrease;
        Troves[_borrower][_asset].debt = newDebt;
        return newDebt;
    }

    function increaseTroveColl(
        address _asset,
        address _borrower,
        uint256 _collIncrease
    ) external override onlyBorrowerOperations returns (uint256) {
        uint256 newColl = Troves[_borrower][_asset].coll + _collIncrease;
        Troves[_borrower][_asset].coll = newColl;
        return newColl;
    }
}
