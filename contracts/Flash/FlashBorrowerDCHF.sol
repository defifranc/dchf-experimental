// SPDX-License-Identifier: MIT

pragma solidity 0.8.14;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

import "../Dependencies/CheckContract.sol";

interface IDCHF is IERC20 {
    function mint(
        address _asset,
        address _account,
        uint256 _amount
    ) external;

    function burn(address _account, uint256 _amount) external;
}

contract FlashBorrowerDCHF is IERC3156FlashBorrower, Ownable {
    enum Action {
        NONE,
        LEVERAGE,
        DELEVERAGE
    }

    IERC3156FlashLender lender;

    constructor(IERC3156FlashLender _lender) {
        CheckContract(address(_lender));
        lender = _lender;
    }

    /// @dev ERC-3156 Flash loan callback
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        require(msg.sender == address(lender), "FlashBorrowerDCHF: Untrusted lender");
        require(initiator == address(this), "FlashBorrowerDCHF: Untrusted initiator");

        Action action = abi.decode(data, (Action));

        if (action == Action.LEVERAGE) {
            // do one thing
        } else if (action == Action.DELEVERAGE) {
            // do another
        }

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    /// @dev Initiate a flash loan
    function flashBorrow(
        address token,
        uint256 amount,
        Action action
    ) public {
        bytes memory data = abi.encode(action);

        lender.flashLoan(this, token, amount, data);
    }
}
