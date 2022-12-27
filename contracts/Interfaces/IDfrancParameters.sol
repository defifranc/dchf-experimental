// SPDX-License-Identifier: MIT

pragma solidity 0.8.14;

import "./IActivePool.sol";
import "./IPriceFeed.sol";
import "./IDfrancBase.sol";

interface IDfrancParameters {
    error SafeCheckError(string parameter, uint256 valueEntered, uint256 minValue, uint256 maxValue);

    event BORROW_MCRChanged(uint256 oldBorrowMCR, uint256 newBorrowMCR);
    event LIQ_MCRChanged(uint256 oldLiqMCR, uint256 newLiqMCR);
    event LIMIT_CRChanged(uint256 oldLIMIT_CR, uint256 newLIMIT_CR);
    event TVL_CAPChanged(uint256 oldTVL_CAP, uint256 newTVL_CAP);
    event MinNetDebtChanged(uint256 oldMinNet, uint256 newMinNet);
    event PercentDivisorChanged(uint256 oldPercentDiv, uint256 newPercentDiv);
    event BorrowingFeeFloorChanged(uint256 oldBorrowingFloorFee, uint256 newBorrowingFloorFee);
    event MaxBorrowingFeeChanged(uint256 oldMaxBorrowingFee, uint256 newMaxBorrowingFee);
    event RedemptionFeeFloorChanged(uint256 oldRedemptionFeeFloor, uint256 newRedemptionFeeFloor);
    event RedemptionBlockRemoved(address _asset);
    event PriceFeedChanged(address indexed addr);

    function DECIMAL_PRECISION() external view returns (uint256);

    function _100pct() external view returns (uint256);

    function BORROW_MCR(address _collateral) external view returns (uint256);

    function LIQ_MCR(address _collateral) external view returns (uint256);

    function LIMIT_CR(address _collateral) external view returns (uint256);

    function TVL_CAP(address _collateral) external view returns (uint256);

    function MIN_NET_DEBT(address _collateral) external view returns (uint256);

    function PERCENT_DIVISOR(address _collateral) external view returns (uint256);

    function BORROWING_FEE_FLOOR(address _collateral) external view returns (uint256);

    function REDEMPTION_FEE_FLOOR(address _collateral) external view returns (uint256);

    function MAX_BORROWING_FEE(address _collateral) external view returns (uint256);

    function redemptionBlock(address _collateral) external view returns (uint256);

    function activePool() external view returns (IActivePool);

    function priceFeed() external view returns (IPriceFeed);

    function setAddresses(
        address _activePool,
        address _priceFeed,
        address _adminContract
    ) external;

    function setPriceFeed(address _priceFeed) external;

    function setBORROW_MCR(address _asset, uint256 newBorrowMCR) external;

    function setLIQ_MCR(address _asset, uint256 newLiqMCR) external;

    function setLIMIT_CR(address _asset, uint256 newLIMIT_CR) external;

    function setTVL_CAP(address _asset, uint256 newTVL_CAP) external;

    function sanitizeParameters(address _asset) external returns (bool);

    function setAsDefault(address _asset) external;

    function setAsDefaultWithRedemptionBlock(address _asset, uint256 blockInDays) external;

    function setMinNetDebt(address _asset, uint256 minNetDebt) external;

    function setPercentDivisor(address _asset, uint256 percentDivisor) external;

    function setBorrowingFeeFloor(address _asset, uint256 borrowingFeeFloor) external;

    function setMaxBorrowingFee(address _asset, uint256 maxBorrowingFee) external;

    function setRedemptionFeeFloor(address _asset, uint256 redemptionFeeFloor) external;

    function removeRedemptionBlock(address _asset) external;
}
