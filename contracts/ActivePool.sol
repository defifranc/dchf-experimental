// SPDX-License-Identifier: MIT

pragma solidity 0.8.14;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./Interfaces/IActivePool.sol";
import "./Interfaces/ICollSurplusPool.sol";
import "./Interfaces/IDeposit.sol";

import "./Dependencies/CheckContract.sol";
import "./Dependencies/SafetyTransfer.sol";

/*
 * The Active Pool holds the collaterals and DCHF debt (but not DCHF tokens) for all active Troves.
 */
contract ActivePool is Ownable, ReentrancyGuard, CheckContract, IActivePool {
    using SafeERC20 for IERC20;

    string public constant NAME = "ActivePool";
    address constant ETH_REF_ADDRESS = address(0);

    address public borrowerOperationsAddress;
    address public troveManagerAddress;

    ICollSurplusPool public collSurplusPool;

    bool public isInitialized;

    mapping(address => uint256) internal assetsBalance;
    mapping(address => uint256) internal DCHFDebts;

    // --- Contract setters --- //

    function setAddresses(
        address _borrowerOperationsAddress,
        address _troveManagerAddress,
        address _collSurplusPoolAddress
    ) external onlyOwner {
        require(!isInitialized, "Already initialized");
        checkContract(_borrowerOperationsAddress);
        checkContract(_troveManagerAddress);
        checkContract(_collSurplusPoolAddress);

        isInitialized = true;

        borrowerOperationsAddress = _borrowerOperationsAddress;
        troveManagerAddress = _troveManagerAddress;
        collSurplusPool = ICollSurplusPool(_collSurplusPoolAddress);

        emit BorrowerOperationsAddressChanged(_borrowerOperationsAddress);
        emit TroveManagerAddressChanged(_troveManagerAddress);

        renounceOwnership();
    }

    // --- Getters for public variables. Required by IPool interface --- //

    /*
     * Returns the ETH state variable.
     *
     * Not necessarily equal to the the contract's raw ETH balance - ether can be forcibly sent to contracts.
     */
    function getAssetBalance(address _asset) external view override returns (uint256) {
        return assetsBalance[_asset];
    }

    function getDCHFDebt(address _asset) external view override returns (uint256) {
        return DCHFDebts[_asset];
    }

    // --- Pool functionality --- //

    function sendAsset(
        address _asset,
        address _account,
        uint256 _amount
    ) external override nonReentrant callerIsBorrowerOperationsOrTroveManager {
        uint256 safetyTransferAmount = SafetyTransfer.decimalsCorrection(_asset, _amount);
        if (safetyTransferAmount == 0) return;

        assetsBalance[_asset] = assetsBalance[_asset] - _amount;

        if (_asset != ETH_REF_ADDRESS) {
            IERC20(_asset).safeTransfer(_account, safetyTransferAmount);

            if (isERC20DepositContract(_account)) {
                IDeposit(_account).receivedERC20(_asset, _amount);
            }
        } else {
            (bool success, ) = _account.call{value: _amount}("");
            require(success, "ActivePool: sending ETH failed");
        }

        emit ActivePoolAssetBalanceUpdated(_asset, assetsBalance[_asset]);
        emit AssetSent(_account, _asset, safetyTransferAmount);
    }

    function isERC20DepositContract(address _account) private view returns (bool) {
        return (_account == address(collSurplusPool));
    }

    function increaseDCHFDebt(address _asset, uint256 _amount)
        external
        override
        callerIsBorrowerOperationsOrTroveManager
    {
        DCHFDebts[_asset] = DCHFDebts[_asset] + _amount;
        emit ActivePoolDCHFDebtUpdated(_asset, DCHFDebts[_asset]);
    }

    function decreaseDCHFDebt(address _asset, uint256 _amount)
        external
        override
        callerIsBorrowerOperationsOrTroveManager
    {
        DCHFDebts[_asset] = DCHFDebts[_asset] - _amount;
        emit ActivePoolDCHFDebtUpdated(_asset, DCHFDebts[_asset]);
    }

    // --- 'require' functions --- //

    modifier callerIsBorrowerOperations() {
        require(msg.sender == borrowerOperationsAddress, "ActivePool: Caller is not BorrowerOperations");
        _;
    }

    modifier callerIsBorrowerOperationsOrTroveManager() {
        require(
            msg.sender == borrowerOperationsAddress || msg.sender == troveManagerAddress,
            "ActivePool: Caller is neither BorrowerOperations nor TroveManager"
        );
        _;
    }

    function receivedERC20(address _asset, uint256 _amount) external override callerIsBorrowerOperations {
        assetsBalance[_asset] = assetsBalance[_asset] + _amount;
        emit ActivePoolAssetBalanceUpdated(_asset, assetsBalance[_asset]);
    }

    // --- Fallback function --- //

    receive() external payable callerIsBorrowerOperations {
        assetsBalance[ETH_REF_ADDRESS] = assetsBalance[ETH_REF_ADDRESS] + msg.value;
        emit ActivePoolAssetBalanceUpdated(ETH_REF_ADDRESS, assetsBalance[ETH_REF_ADDRESS]);
    }
}
