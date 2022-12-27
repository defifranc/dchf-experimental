// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import {IERC20} from "./Library/IERC20.sol";

// Contract with no functionality, purely used to store and keep track of the burnt MON

contract BurnContract {
    IERC20 internal constant MON = IERC20(0x1EA48B9965bb5086F3b468E50ED93888a661fc17);

    function totalMONBurnt() external view returns (uint256 _totalMONBurnt) {
        _totalMONBurnt = MON.balanceOf(address(this));
    }
}
