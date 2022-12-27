// SPDX-License-Identifier: MIT

pragma solidity 0.8.14;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./BaseMath.sol";
import "./DfrancMath.sol";

import "../Interfaces/IActivePool.sol";
import "../Interfaces/IPriceFeed.sol";
import "../Interfaces/IDfrancBase.sol";

/*
 * Base contract for TroveManager & BorrowerOperations. Contains global system constants and common functions.
 */
contract DfrancBase is BaseMath, IDfrancBase, Ownable {
    address public constant ETH_REF_ADDRESS = address(0);

    IDfrancParameters public override dfrancParams;

    function setDfrancParameters(address _vaultParams) public onlyOwner {
        dfrancParams = IDfrancParameters(_vaultParams);
        emit VaultParametersBaseChanged(_vaultParams);
    }

    function getEntireSystemColl(address _asset) public view returns (uint256 entireSystemColl) {
        entireSystemColl = dfrancParams.activePool().getAssetBalance(_asset); // activeColl
    }

    function getEntireSystemDebt(address _asset) public view returns (uint256 entireSystemDebt) {
        entireSystemDebt = dfrancParams.activePool().getDCHFDebt(_asset); // activeDebt
    }

    function _getTCR(address _asset, uint256 _price) internal view returns (uint256 TCR) {
        uint256 entireSystemColl = getEntireSystemColl(_asset);
        uint256 entireSystemDebt = getEntireSystemDebt(_asset);

        TCR = DfrancMath._computeCR(entireSystemColl, entireSystemDebt, _price);
    }

    function _requireUserAcceptsFee(
        uint256 _fee,
        uint256 _amount,
        uint256 _maxFeePercentage
    ) internal view {
        uint256 feePercentage = (_fee * dfrancParams.DECIMAL_PRECISION()) / _amount;
        require(feePercentage <= _maxFeePercentage, "Fee needs to be below max");
    }
}
