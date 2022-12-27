// SPDX-License-Identifier: MIT

pragma solidity 0.8.14;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

import "../Dependencies/CheckContract.sol";

interface IVault is IERC20 {
    function name() external view returns (string calldata);

    function symbol() external view returns (string calldata);

    function decimals() external view returns (uint256);

    function deposit(uint256 amount) external returns (uint256);

    function withdraw(uint256 maxShares) external returns (uint256);

    function token() external view returns (address);

    function pricePerShare() external view returns (uint256);
}

interface ITroveManager {
    function liquidate(address _asset, address borrower) external;

    function liquidateTroves(address _asset, uint256 _n) external;
}

interface ICurveSwap {
    function remove_liquidity_one_coin(
        uint256 _token_amount,
        int128 i,
        uint256 min_amount
    ) external;

    function exchange(
        uint256 from,
        uint256 to,
        uint256 from_amount,
        uint256 min_to_amount
    ) external payable;

    function price_oracle() external view returns (uint256);
}

contract LiquidatorDCHF is IERC3156FlashBorrower, Ownable {
    using SafeERC20 for IERC20;

    IERC20 internal constant DCHF = IERC20(0x045da4bFe02B320f4403674B3b7d121737727A36);

    address internal constant curvePoolDCHF = 0xDcb11E81C8B8a1e06BF4b50d4F6f3bb31f7478C3;
    address internal constant crvToken = 0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490;
    address internal constant ETHAddress = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    IERC3156FlashLender public immutable lender;

    ITroveManager public troveManager;

    uint256 public slippageMax;

    uint256 internal constant MAX = type(uint256).max;
    uint256 internal constant DENOMINATOR = 10000;

    struct Params {
        uint256 liqAction; // (0 = SINGLE) (1 = MULTI)
        address vaultAddress; // IERC20 Vault token address
        address borrower; // Borrower to liquidate
        uint256 n; // Number of Troves to Liquidate
    }

    event LiquidationProfit(uint256 amount);
    event Sweep(address indexed token, uint256 amount);

    constructor(IERC3156FlashLender _lender, address _troveManager) {
        CheckContract(address(_lender));
        lender = _lender;

        CheckContract(_troveManager);
        troveManager = ITroveManager(_troveManager);

        slippageMax = 9500; // 5% diff from the oracle twap price

        _approveToken(address(DCHF), _troveManager);
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

        Params memory params = abi.decode(data, (Params));

        // Perform the liquidation according the type
        if (params.liqAction == 0) {
            troveManager.liquidate(params.vaultAddress, params.borrower);
        } else if (params.liqAction == 1) {
            troveManager.liquidateTroves(params.vaultAddress, params.n);
        }

        // Withdraw the Curve LpTokens from the Vault
        IVault(params.vaultAddress).withdraw(_tokenBalance(params.vaultAddress));

        _removeLiquidity(params.vaultAddress);

        _swapToDCHF();

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    function liquidateSingle(
        address _asset,
        address _borrower,
        uint256 _amount
    ) external {
        bytes memory data = abi.encode(
            Params({liqAction: 0, vaultAddress: _asset, borrower: _borrower, n: 0})
        );

        lender.flashLoan(this, address(DCHF), _amount, data);

        _transferGains();
    }

    function liquidateMulti(
        address _asset,
        uint256 _n,
        uint256 _amount
    ) external {
        bytes memory data = abi.encode(
            Params({liqAction: 1, vaultAddress: _asset, borrower: address(0), n: _n})
        );

        lender.flashLoan(this, address(DCHF), _amount, data);

        _transferGains();
    }

    function _removeLiquidity(address _vaultAddress) internal {
        address underlyingToken = IVault(_vaultAddress).token(); // LpToken address
        uint256 underlyingTokenBal = _tokenBalance(underlyingToken);

        // Remove liquidity in 3Crv (index = 1) Metapool
        ICurveSwap(underlyingToken).remove_liquidity_one_coin(underlyingTokenBal, 1, 0);
    }

    function _swapToDCHF() internal {
        uint256 crvPriceInDCHF = ICurveSwap(curvePoolDCHF).price_oracle(); // 1e18 precision (i.e 0,95 * 10^18)
        uint256 intermediateTokenBal = _tokenBalance(crvToken); // 3Crv
        uint256 _amountOut = (intermediateTokenBal * crvPriceInDCHF * slippageMax) / DENOMINATOR / 1e18;

        _approveToken(crvToken, curvePoolDCHF);

        // Swap 3Crv to DCHF
        ICurveSwap(curvePoolDCHF).exchange(1, 0, intermediateTokenBal, _amountOut);
    }

    function _transferGains() internal {
        uint256 balanceOfDCHF = _tokenBalance(address(DCHF));
        DCHF.safeTransfer(msg.sender, balanceOfDCHF);
        emit LiquidationProfit(balanceOfDCHF);
    }

    function _approveToken(address token, address spender) internal {
        IERC20 _token = IERC20(token);
        if (_token.allowance(address(this), spender) > 0) return;
        else {
            _token.safeApprove(spender, type(uint256).max);
        }
    }

    function _tokenBalance(address _token) internal view returns (uint256) {
        return IERC20(_token).balanceOf(address(this));
    }

    /// @notice Sweep tokens or ETH in case they get stuck in the contract
    function sweep(address[] memory _tokens, bool _ETH) external onlyOwner {
        if (_ETH) {
            uint256 balance = address(this).balance;
            (bool success, ) = msg.sender.call{value: address(this).balance}("");
            require(success, "LiquidatorDCHF: Sending ETH failed");
            emit Sweep(ETHAddress, balance);
        }
        for (uint256 i = 0; i < _tokens.length; i++) {
            uint256 amount = _tokenBalance(_tokens[i]);
            IERC20(_tokens[i]).safeTransfer(owner(), amount);
            emit Sweep(_tokens[i], amount);
        }
    }

    /// @notice Set the slippage parameter for making swaps
    function setSlippage(uint256 _slippageMax) external onlyOwner {
        require(_slippageMax < 10001, "LiquidatorDCHF: Not valid slippage");
        slippageMax = _slippageMax;
    }
}
