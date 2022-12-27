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

contract FlashMinterDCHF is IERC3156FlashLender, Ownable {
    bytes32 public constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    uint256 public fee; // in bps -> 1 == 0.01%

    address[] public validContracts;
    mapping(address => bool) validContract;
    bool public isFlashMinterWhitelisted;

    IDCHF public immutable DCHF = IDCHF(address(0x045da4bFe02B320f4403674B3b7d121737727A36));

    event FlashLoan(address indexed receiver, address token, uint256 amount, uint256 fee);
    event UpdateValidContracts(address[] validContracts, uint256 n);
    event SetFee(uint256 newFee, uint256 oldFee);

    constructor() {
        fee = 0;
    }

    /**
     * @dev The amount of currency available to be lent.
     * @param token The loan currency.
     * @return The amount of `token` that can be borrowed.
     */
    function maxFlashLoan(address token) public view override returns (uint256) {
        return type(uint256).max - DCHF.totalSupply();
    }

    /**
     * @dev Loan `amount` tokens to `receiver`, and takes it back plus a `flashFee` after the ERC3156 callback.
     * @param receiver The contract receiving the tokens, needs to implement the `onFlashLoan(address user, uint256 amount, uint256 fee, bytes calldata)` interface.
     * @param token The loan currency. Must match the address of this contract.
     * @param amount The amount of tokens lent.
     * @param data A data parameter to be passed on to the `receiver` for any custom use.
     */
    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external override returns (bool) {
        require(token == address(DCHF), "FlashMinterDCHF: Unsupported currency");
        require(amount <= maxFlashLoan(token), "FlashMinterDCHF: Ceiling exceeded");

        if (isFlashMinterWhitelisted) {
            require(validContract[msg.sender], "FlashMinterDCHF: Not allowed");
        }

        uint256 _fee = _flashFee(token, amount);

        // address(0) is the address of ETH as an asset, can be paused in emergencyStopMintingCollateral[_asset]
        DCHF.mint(address(0), address(receiver), amount);

        emit FlashLoan(address(receiver), token, amount, 0);

        require(
            receiver.onFlashLoan(msg.sender, token, amount, _fee, data) == CALLBACK_SUCCESS,
            "FlashMinterDCHF: Callback failed"
        );

        DCHF.burn(address(receiver), amount + _fee);

        return true;
    }

    /**
     * @dev The fee to be charged for a given loan.
     * @param token The loan currency. Must match the address of this contract.
     * @param amount The amount of tokens lent.
     * @return The amount of `token` to be charged for the loan, on top of the returned principal.
     */
    function flashFee(address token, uint256 amount) external view override returns (uint256) {
        require(token == address(DCHF), "FlashMinterDCHF: Unsupported currency");
        return _flashFee(token, amount);
    }

    /**
     * @dev The fee to be charged for a given loan. Internal function with no checks.
     */
    function _flashFee(address token, uint256 amount) internal view returns (uint256) {
        return (amount * fee) / 10000;
    }

    /**
     * @param _fee The percentage of the loan `amount` that needs to be repaid, in addition to `amount`.
     */
    function setFee(uint256 _fee) external onlyOwner {
        require(_fee >= 0 && _fee < 10000, "FlashMinterDCHF: Invalid Range");
        uint256 oldFee = fee;
        fee = _fee;
        emit SetFee(_fee, oldFee);
    }

    /**
     * @param _validContract whitelisted address able to flashMint from this contract.
     */
    function addValidContract(address _validContract) external onlyOwner {
        CheckContract(_validContract);
        require(!validContract[_validContract], "FlashMinter: Already Exists");
        validContract[_validContract] = true;
        validContracts.push(_validContract);
        emit UpdateValidContracts(validContracts, validContracts.length);
    }

    /**
     * @dev Toggle to enable or disable the whitelist for minting.
     */
    function toggleWhitelist() external onlyOwner {
        isFlashMinterWhitelisted = !isFlashMinterWhitelisted;
    }

    /**
     * @dev Function to enable the minting of DCHF by this contract.
     * @return True.
     */
    function isContractBorrowerOps() external pure returns (bool) {
        return true;
    }
}
