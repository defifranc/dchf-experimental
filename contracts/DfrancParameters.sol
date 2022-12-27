// SPDX-License-Identifier: MIT

pragma solidity 0.8.14;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./Dependencies/CheckContract.sol";

import "./Interfaces/IDfrancParameters.sol";

contract DfrancParameters is IDfrancParameters, Ownable, CheckContract {
    string public constant NAME = "DfrancParameters";

    uint256 public constant override DECIMAL_PRECISION = 1 ether;
    uint256 public constant override _100pct = 1 ether; // 1e18 == 100%

    uint256 public constant REDEMPTION_BLOCK_DAY = 14;

    uint256 public constant BORROW_MCR_DEFAULT = 1500000000000000000; // 150%
    uint256 public constant LIQ_MCR_DEFAULT = 1100000000000000000; // 110%
    uint256 public constant LIMIT_CR_DEFAULT = 1250000000000000000; // 125%
    uint256 public constant PERCENT_DIVISOR_DEFAULT = 100; // dividing by 100 yields 0.5%

    uint256 public constant BORROWING_FEE_FLOOR_DEFAULT = (DECIMAL_PRECISION / 1000) * 5; // 0.5%
    uint256 public constant MAX_BORROWING_FEE_DEFAULT = (DECIMAL_PRECISION / 100) * 5; // 5%

    uint256 public constant MIN_NET_DEBT_DEFAULT = 2000 ether;
    uint256 public constant REDEMPTION_FEE_FLOOR_DEFAULT = (DECIMAL_PRECISION / 1000) * 5; // 0.5%

    uint256 public constant TVL_CAP_DEFAULT = 1e25; // 10M

    // Minimum borrow collateral ratio for individual troves.
    mapping(address => uint256) public override BORROW_MCR;
    // Minimum liquidation collateral ratio for individual troves.
    mapping(address => uint256) public override LIQ_MCR;
    // Limit system collateral ratio. If the system's total collateral ratio (TCR) falls below the LIMIT_CR, some functions can not be invoked.
    mapping(address => uint256) public override LIMIT_CR;
    // Borrow Cap for each asset, limit of DCHF that can be borrowed globally for a specific market.
    mapping(address => uint256) public override TVL_CAP;

    mapping(address => uint256) public override MIN_NET_DEBT; // Minimum amount of net DCHF debt a trove must have
    mapping(address => uint256) public override PERCENT_DIVISOR; // dividing by 200 yields 0.5%
    mapping(address => uint256) public override BORROWING_FEE_FLOOR;
    mapping(address => uint256) public override REDEMPTION_FEE_FLOOR;
    mapping(address => uint256) public override MAX_BORROWING_FEE;
    mapping(address => uint256) public override redemptionBlock;

    mapping(address => bool) internal hasCollateralConfigured;

    IActivePool public override activePool;
    IPriceFeed public override priceFeed;

    address public adminContract;

    bool public isInitialized;

    modifier isController() {
        require(msg.sender == owner() || msg.sender == adminContract, "Invalid Permissions");
        _;
    }

    function setAddresses(
        address _activePool,
        address _priceFeed,
        address _adminContract
    ) external override onlyOwner {
        require(!isInitialized, "Already initialized");
        checkContract(_activePool);
        checkContract(_priceFeed);
        checkContract(_adminContract);

        isInitialized = true;

        adminContract = _adminContract;
        activePool = IActivePool(_activePool);
        priceFeed = IPriceFeed(_priceFeed);
    }

    function setAdminContract(address _admin) external onlyOwner {
        require(_admin != address(0), "Admin address is zero");
        checkContract(_admin);
        adminContract = _admin;
    }

    function setPriceFeed(address _priceFeed) external override onlyOwner {
        checkContract(_priceFeed);
        priceFeed = IPriceFeed(_priceFeed);

        emit PriceFeedChanged(_priceFeed);
    }

    function sanitizeParameters(address _asset) external view returns (bool params) {
        params = hasCollateralConfigured[_asset] ? true : false;
    }

    function setAsDefault(address _asset) external onlyOwner {
        _setAsDefault(_asset);
    }

    function setAsDefaultWithRedemptionBlock(address _asset, uint256 blockInDays) external isController {
        if (blockInDays > 14) {
            blockInDays = REDEMPTION_BLOCK_DAY;
        }

        if (redemptionBlock[_asset] == 0) {
            redemptionBlock[_asset] = block.timestamp + (blockInDays * 1 days);
        }

        _setAsDefault(_asset);
    }

    function _setAsDefault(address _asset) private {
        hasCollateralConfigured[_asset] = true;

        BORROW_MCR[_asset] = BORROW_MCR_DEFAULT;
        LIQ_MCR[_asset] = LIQ_MCR_DEFAULT;
        LIMIT_CR[_asset] = LIMIT_CR_DEFAULT;
        TVL_CAP[_asset] = TVL_CAP_DEFAULT;
        MIN_NET_DEBT[_asset] = MIN_NET_DEBT_DEFAULT;
        PERCENT_DIVISOR[_asset] = PERCENT_DIVISOR_DEFAULT;
        BORROWING_FEE_FLOOR[_asset] = BORROWING_FEE_FLOOR_DEFAULT;
        MAX_BORROWING_FEE[_asset] = MAX_BORROWING_FEE_DEFAULT;
        REDEMPTION_FEE_FLOOR[_asset] = REDEMPTION_FEE_FLOOR_DEFAULT;
    }

    function setCollateralParameters(
        address _asset,
        uint256 borrowMCR,
        uint256 liqMCR,
        uint256 limitCR,
        uint256 tvlCap,
        uint256 minNetDebt,
        uint256 percentDivisor,
        uint256 borrowingFeeFloor,
        uint256 maxBorrowingFee,
        uint256 redemptionFeeFloor
    ) external onlyOwner {
        hasCollateralConfigured[_asset] = true;

        setBORROW_MCR(_asset, borrowMCR);
        setLIQ_MCR(_asset, liqMCR);
        setLIMIT_CR(_asset, limitCR);
        setTVL_CAP(_asset, tvlCap);
        setMinNetDebt(_asset, minNetDebt);
        setPercentDivisor(_asset, percentDivisor);
        setMaxBorrowingFee(_asset, maxBorrowingFee);
        setBorrowingFeeFloor(_asset, borrowingFeeFloor);
        setRedemptionFeeFloor(_asset, redemptionFeeFloor);
    }

    function setBORROW_MCR(address _asset, uint256 newBorrowMCR)
        public
        override
        onlyOwner
        safeCheck("borrowMCR", _asset, newBorrowMCR, 1010000000000000000, 10000000000000000000) /// 101% - 1000%
    {
        uint256 oldBorrowMCR = BORROW_MCR[_asset];
        BORROW_MCR[_asset] = newBorrowMCR;

        emit BORROW_MCRChanged(oldBorrowMCR, newBorrowMCR);
    }

    function setLIQ_MCR(address _asset, uint256 newLiqMCR)
        public
        override
        onlyOwner
        safeCheck("liqMCR", _asset, newLiqMCR, 1010000000000000000, 10000000000000000000) /// 101% - 1000%
    {
        uint256 oldLiqMCR = LIQ_MCR[_asset];
        LIQ_MCR[_asset] = newLiqMCR;

        emit LIQ_MCRChanged(oldLiqMCR, newLiqMCR);
    }

    function setLIMIT_CR(address _asset, uint256 newLIMIT_CR)
        public
        override
        onlyOwner
        safeCheck("LIMIT_CR", _asset, newLIMIT_CR, 1010000000000000000, 10000000000000000000) /// 101% - 1000%
    {
        uint256 oldLIMIT_CR = LIMIT_CR[_asset];
        LIMIT_CR[_asset] = newLIMIT_CR;

        emit LIMIT_CRChanged(oldLIMIT_CR, newLIMIT_CR);
    }

    function setTVL_CAP(address _asset, uint256 newTVL_CAP)
        public
        override
        onlyOwner
        safeCheck("TVL_CAP", _asset, newTVL_CAP, 1e22, 1e27) /// 10000 - 1000M
    {
        uint256 oldTVL_CAP = TVL_CAP[_asset];
        TVL_CAP[_asset] = newTVL_CAP;

        emit TVL_CAPChanged(oldTVL_CAP, newTVL_CAP);
    }

    function setPercentDivisor(address _asset, uint256 percentDivisor)
        public
        override
        onlyOwner
        safeCheck("Percent Divisor", _asset, percentDivisor, 2, 200)
    {
        uint256 oldPercent = PERCENT_DIVISOR[_asset];
        PERCENT_DIVISOR[_asset] = percentDivisor;

        emit PercentDivisorChanged(oldPercent, percentDivisor);
    }

    function setBorrowingFeeFloor(address _asset, uint256 borrowingFeeFloor)
        public
        override
        onlyOwner
        safeCheck("Borrowing Fee Floor", _asset, borrowingFeeFloor, 0, 1000) /// 0% - 10%
    {
        uint256 oldBorrowing = BORROWING_FEE_FLOOR[_asset];
        uint256 newBorrowingFee = (DECIMAL_PRECISION / 10000) * borrowingFeeFloor;

        BORROWING_FEE_FLOOR[_asset] = newBorrowingFee;
        require(MAX_BORROWING_FEE[_asset] > BORROWING_FEE_FLOOR[_asset], "Wrong inputs setBorrowingFeeFloor");

        emit BorrowingFeeFloorChanged(oldBorrowing, newBorrowingFee);
    }

    function setMaxBorrowingFee(address _asset, uint256 maxBorrowingFee)
        public
        override
        onlyOwner
        safeCheck("Max Borrowing Fee", _asset, maxBorrowingFee, 0, 1000) /// 0% - 10%
    {
        uint256 oldMaxBorrowingFee = MAX_BORROWING_FEE[_asset];
        uint256 newMaxBorrowingFee = (DECIMAL_PRECISION / 10000) * maxBorrowingFee;

        MAX_BORROWING_FEE[_asset] = newMaxBorrowingFee;
        require(MAX_BORROWING_FEE[_asset] > BORROWING_FEE_FLOOR[_asset], "Wrong inputs setMaxBorrowingFee");

        emit MaxBorrowingFeeChanged(oldMaxBorrowingFee, newMaxBorrowingFee);
    }

    function setMinNetDebt(address _asset, uint256 minNetDebt)
        public
        override
        onlyOwner
        safeCheck("Min Net Debt", _asset, minNetDebt, 0, 10000 ether)
    {
        uint256 oldMinNet = MIN_NET_DEBT[_asset];
        MIN_NET_DEBT[_asset] = minNetDebt;

        emit MinNetDebtChanged(oldMinNet, minNetDebt);
    }

    function setRedemptionFeeFloor(address _asset, uint256 redemptionFeeFloor)
        public
        override
        onlyOwner
        safeCheck("Redemption Fee Floor", _asset, redemptionFeeFloor, 10, 1000) /// 0.10% - 10%
    {
        uint256 oldRedemptionFeeFloor = REDEMPTION_FEE_FLOOR[_asset];
        uint256 newRedemptionFeeFloor = (DECIMAL_PRECISION / 10000) * redemptionFeeFloor;

        REDEMPTION_FEE_FLOOR[_asset] = newRedemptionFeeFloor;
        emit RedemptionFeeFloorChanged(oldRedemptionFeeFloor, newRedemptionFeeFloor);
    }

    function removeRedemptionBlock(address _asset) external override onlyOwner {
        redemptionBlock[_asset] = block.timestamp;

        emit RedemptionBlockRemoved(_asset);
    }

    modifier safeCheck(
        string memory parameter,
        address _asset,
        uint256 enteredValue,
        uint256 min,
        uint256 max
    ) {
        require(
            hasCollateralConfigured[_asset],
            "Collateral is not configured, use setAsDefault or setCollateralParameters"
        );

        if (enteredValue < min || enteredValue > max) {
            revert SafeCheckError(parameter, enteredValue, min, max);
        }
        _;
    }
}
