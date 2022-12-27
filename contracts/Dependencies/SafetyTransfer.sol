import "./ERC20Decimals.sol";

library SafetyTransfer {
    // _amount is in Ether (1e18) and we want to convert it to the token decimal
    function decimalsCorrection(address _token, uint256 _amount) internal view returns (uint256) {
        if (_token == address(0)) return _amount;
        if (_amount == 0) return 0;

        uint8 decimals = ERC20Decimals(_token).decimals();
        if (decimals < 18) {
            return _amount / (10**(18 - decimals));
        } else {
            return _amount * (10**(decimals - 18));
        }
    }
}
