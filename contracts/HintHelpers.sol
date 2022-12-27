// SPDX-License-Identifier: MIT

pragma solidity 0.8.14;

import "./Interfaces/ITroveManager.sol";
import "./Interfaces/ISortedTroves.sol";
import "./Dependencies/DfrancBase.sol";
import "./Dependencies/CheckContract.sol";

contract HintHelpers is DfrancBase, CheckContract {
    using SafeMath for uint256;
    string public constant NAME = "HintHelpers";

    struct LocalRedemptionVars {
        address _asset;
        uint256 _DCHFamount;
        uint256 _price;
        uint256 _maxIterations;
    }

    ISortedTroves public sortedTroves;
    ITroveManager public troveManager;

    bool public isInitialized;

    // --- Events --- //

    event SortedTrovesAddressChanged(address _sortedTrovesAddress);
    event TroveManagerAddressChanged(address _troveManagerAddress);

    // --- Dependency setters --- //

    function setAddresses(
        address _sortedTrovesAddress,
        address _troveManagerAddress,
        address _vaultParametersAddress
    ) external onlyOwner {
        require(!isInitialized, "Already initialized");
        checkContract(_sortedTrovesAddress);
        checkContract(_troveManagerAddress);
        checkContract(_vaultParametersAddress);

        isInitialized = true;

        sortedTroves = ISortedTroves(_sortedTrovesAddress);
        troveManager = ITroveManager(_troveManagerAddress);

        emit SortedTrovesAddressChanged(_sortedTrovesAddress);
        emit TroveManagerAddressChanged(_troveManagerAddress);

        setDfrancParameters(_vaultParametersAddress);
    }

    // --- Functions --- //

    /* getRedemptionHints() - Helper function for finding the right hints to pass to redeemCollateral().
     *
     * It simulates a redemption of `_DCHFamount` to figure out where the redemption sequence will start and what state the final Trove
     * of the sequence will end up in.
     *
     * Returns three hints:
     *  - `firstRedemptionHint` is the address of the first Trove with ICR >= MCR (i.e. the first Trove that will be redeemed).
     *  - `partialRedemptionHintNICR` is the final nominal ICR of the last Trove of the sequence after being hit by partial redemption,
     *     or zero in case of no partial redemption.
     *  - `truncatedDCHFamount` is the maximum amount that can be redeemed out of the the provided `_DCHFamount`. This can be lower than
     *    `_DCHFamount` when redeeming the full amount would leave the last Trove of the redemption sequence with less net debt than the
     *    minimum allowed value (i.e. dfrancParams.MIN_NET_DEBT()).
     *
     * The number of Troves to consider for redemption can be capped by passing a non-zero value as `_maxIterations`, while passing zero
     * will leave it uncapped.
     */

    function getRedemptionHints(
        address _asset,
        uint256 _DCHFamount,
        uint256 _price,
        uint256 _maxIterations
    )
        external
        view
        returns (
            address firstRedemptionHint,
            uint256 partialRedemptionHintNICR,
            uint256 truncatedDCHFamount
        )
    {
        ISortedTroves sortedTrovesCached = sortedTroves;

        LocalRedemptionVars memory vars = LocalRedemptionVars(_asset, _DCHFamount, _price, _maxIterations);

        uint256 remainingDCHF = _DCHFamount;
        address currentTroveUser = sortedTrovesCached.getLast(vars._asset);

        while (
            currentTroveUser != address(0) &&
            troveManager.getCurrentICR(vars._asset, currentTroveUser, _price) <
            dfrancParams.LIQ_MCR(vars._asset)
        ) {
            currentTroveUser = sortedTrovesCached.getPrev(vars._asset, currentTroveUser);
        }

        firstRedemptionHint = currentTroveUser;

        if (_maxIterations == 0) {
            _maxIterations = type(uint256).max;
        }

        while (currentTroveUser != address(0) && remainingDCHF > 0 && _maxIterations > 0) {
            _maxIterations--;
            uint256 netDCHFDebt = troveManager.getTroveDebt(vars._asset, currentTroveUser);

            if (netDCHFDebt > remainingDCHF) {
                if (netDCHFDebt > dfrancParams.MIN_NET_DEBT(vars._asset)) {
                    uint256 maxRedeemableDCHF = DfrancMath._min(
                        remainingDCHF,
                        netDCHFDebt.sub(dfrancParams.MIN_NET_DEBT(vars._asset))
                    );

                    uint256 ETH = troveManager.getTroveColl(vars._asset, currentTroveUser);

                    uint256 newColl = ETH.sub(maxRedeemableDCHF.mul(DECIMAL_PRECISION).div(_price));
                    uint256 newDebt = netDCHFDebt.sub(maxRedeemableDCHF);

                    partialRedemptionHintNICR = DfrancMath._computeNominalCR(newColl, newDebt);

                    remainingDCHF = remainingDCHF.sub(maxRedeemableDCHF);
                }
                break;
            } else {
                remainingDCHF = remainingDCHF.sub(netDCHFDebt);
            }

            currentTroveUser = sortedTrovesCached.getPrev(vars._asset, currentTroveUser);
        }

        truncatedDCHFamount = _DCHFamount.sub(remainingDCHF);
    }

    /* getApproxHint() - return address of a Trove that is, on average, (length / numTrials) positions away in the 
    sortedTroves list from the correct insert position of the Trove to be inserted. 
    
    Note: The output address is worst-case O(n) positions away from the correct insert position, however, the function 
    is probabilistic. Input can be tuned to guarantee results to a high degree of confidence, e.g:

    Submitting numTrials = k * sqrt(length), with k = 15 makes it very, very likely that the output address will 
    be <= sqrt(length) positions away from the correct insert position.
    */
    function getApproxHint(
        address _asset,
        uint256 _CR,
        uint256 _numTrials,
        uint256 _inputRandomSeed
    )
        external
        view
        returns (
            address hintAddress,
            uint256 diff,
            uint256 latestRandomSeed
        )
    {
        uint256 arrayLength = troveManager.getTroveOwnersCount(_asset);

        if (arrayLength == 0) {
            return (address(0), 0, _inputRandomSeed);
        }

        hintAddress = sortedTroves.getLast(_asset);
        diff = DfrancMath._getAbsoluteDifference(_CR, troveManager.getNominalICR(_asset, hintAddress));
        latestRandomSeed = _inputRandomSeed;

        uint256 i = 1;

        while (i < _numTrials) {
            latestRandomSeed = uint256(keccak256(abi.encodePacked(latestRandomSeed)));

            uint256 arrayIndex = latestRandomSeed % arrayLength;
            address currentAddress = troveManager.getTroveFromTroveOwnersArray(_asset, arrayIndex);
            uint256 currentNICR = troveManager.getNominalICR(_asset, currentAddress);

            // Check if abs(current - CR) > abs(closest - CR), and update closest if current is closer
            uint256 currentDiff = DfrancMath._getAbsoluteDifference(currentNICR, _CR);

            if (currentDiff < diff) {
                diff = currentDiff;
                hintAddress = currentAddress;
            }
            i++;
        }
    }

    function computeNominalCR(uint256 _coll, uint256 _debt) external pure returns (uint256) {
        return DfrancMath._computeNominalCR(_coll, _debt);
    }

    function computeCR(
        uint256 _coll,
        uint256 _debt,
        uint256 _price
    ) external pure returns (uint256) {
        return DfrancMath._computeCR(_coll, _debt, _price);
    }
}
