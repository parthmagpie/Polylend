// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../libraries/DataTypes.sol";
import "../libraries/Errors.sol";
import "../libraries/PercentageMath.sol";
import "../interfaces/ILiquidationEngine.sol";
import "../interfaces/IVault.sol";
import "../interfaces/ILendingPool.sol";
import "../interfaces/IPolymarketOracle.sol";

/**
 * @title LiquidationEngine
 * @notice Handles health factor calculation and liquidation execution
 * @dev Implements liquidation with configurable threshold, bonus, and close factor
 *
 * Parameters:
 * - Liquidation Threshold: 75% - Position becomes liquidatable when LTV exceeds this
 * - Liquidation Bonus: 10% - Extra collateral given to liquidators as incentive
 * - Close Factor: 50% - Maximum portion of debt that can be repaid per liquidation
 */
contract LiquidationEngine is ILiquidationEngine, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    using PercentageMath for uint256;

    // ============ Constants ============

    /// @notice Health factor threshold (1e18 = 1.0, below this is liquidatable)
    uint256 public constant HEALTH_FACTOR_THRESHOLD = 1e18;

    // ============ Storage ============

    /// @notice Liquidation threshold in basis points (75% = 7500)
    uint256 public override liquidationThreshold = 7500;

    /// @notice Liquidation bonus in basis points (10% = 1000)
    uint256 public override liquidationBonus = 1000;

    /// @notice Close factor in basis points (50% = 5000)
    uint256 public override closeFactor = 5000;

    /// @notice The vault contract
    IVault public vault;

    /// @notice The lending pool contract
    ILendingPool public lendingPool;

    /// @notice The price oracle
    IPolymarketOracle public oracle;

    /// @notice The USDC token
    address public usdc;

    /// @notice The main PolyLend contract
    address public polyLend;

    /// @notice User positions: user => tokenId => Position
    mapping(address => mapping(uint256 => DataTypes.Position)) public positions;

    // ============ Events ============

    event ParametersUpdated(
        uint256 liquidationThreshold,
        uint256 liquidationBonus,
        uint256 closeFactor
    );

    event ContractsSet(
        address vault,
        address lendingPool,
        address oracle,
        address usdc
    );

    event PolyLendSet(address indexed polyLend);

    // ============ Modifiers ============

    modifier onlyPolyLend() {
        if (msg.sender != polyLend) {
            revert Errors.Unauthorized();
        }
        _;
    }

    // ============ Constructor ============

    constructor() Ownable(msg.sender) {}

    // ============ Admin Functions ============

    /**
     * @notice Set contract references
     * @param _vault The vault contract
     * @param _lendingPool The lending pool contract
     * @param _oracle The oracle contract
     * @param _usdc The USDC token address
     */
    function setContracts(
        address _vault,
        address _lendingPool,
        address _oracle,
        address _usdc
    ) external onlyOwner {
        if (_vault == address(0) || _lendingPool == address(0) ||
            _oracle == address(0) || _usdc == address(0)) {
            revert Errors.ZeroAddress();
        }

        vault = IVault(_vault);
        lendingPool = ILendingPool(_lendingPool);
        oracle = IPolymarketOracle(_oracle);
        usdc = _usdc;

        emit ContractsSet(_vault, _lendingPool, _oracle, _usdc);
    }

    /**
     * @notice Set the PolyLend contract
     * @param _polyLend The PolyLend contract address
     */
    function setPolyLend(address _polyLend) external onlyOwner {
        if (_polyLend == address(0)) {
            revert Errors.ZeroAddress();
        }
        polyLend = _polyLend;
        emit PolyLendSet(_polyLend);
    }

    /**
     * @notice Update liquidation parameters
     * @param _liquidationThreshold New threshold in basis points
     * @param _liquidationBonus New bonus in basis points
     * @param _closeFactor New close factor in basis points
     */
    function updateParameters(
        uint256 _liquidationThreshold,
        uint256 _liquidationBonus,
        uint256 _closeFactor
    ) external onlyOwner {
        require(_liquidationThreshold <= PercentageMath.BPS, "Threshold too high");
        require(_liquidationBonus <= 5000, "Bonus too high"); // Max 50%
        require(_closeFactor <= PercentageMath.BPS, "Close factor too high");

        liquidationThreshold = _liquidationThreshold;
        liquidationBonus = _liquidationBonus;
        closeFactor = _closeFactor;

        emit ParametersUpdated(_liquidationThreshold, _liquidationBonus, _closeFactor);
    }

    // ============ Position Management (called by PolyLend) ============

    /**
     * @notice Update a position's debt
     * @param user The user address
     * @param tokenId The collateral token ID
     * @param newDebt The new debt amount
     * @param marketId The market condition ID
     */
    function updatePositionDebt(
        address user,
        uint256 tokenId,
        uint256 newDebt,
        bytes32 marketId
    ) external onlyPolyLend {
        DataTypes.Position storage position = positions[user][tokenId];

        if (position.collateralAmount == 0) {
            // Initialize new position
            position.tokenId = tokenId;
            position.marketId = marketId;
        }

        position.borrowedAmount = newDebt;
        position.lastUpdateTimestamp = block.timestamp;
    }

    /**
     * @notice Update a position's collateral
     * @param user The user address
     * @param tokenId The collateral token ID
     * @param newCollateral The new collateral amount
     * @param marketId The market condition ID
     */
    function updatePositionCollateral(
        address user,
        uint256 tokenId,
        uint256 newCollateral,
        bytes32 marketId
    ) external onlyPolyLend {
        DataTypes.Position storage position = positions[user][tokenId];

        if (position.tokenId == 0) {
            position.tokenId = tokenId;
            position.marketId = marketId;
        }

        position.collateralAmount = newCollateral;
        position.lastUpdateTimestamp = block.timestamp;
    }

    // ============ Liquidation Functions ============

    /**
     * @notice Execute liquidation of an unhealthy position
     * @param borrower The borrower to liquidate
     * @param tokenId The collateral token ID
     * @param repayAmount The amount of debt to repay
     * @return collateralSeized The amount of collateral transferred to liquidator
     */
    function executeLiquidation(
        address borrower,
        uint256 tokenId,
        uint256 repayAmount
    ) external override nonReentrant returns (uint256 collateralSeized) {
        if (repayAmount == 0) {
            revert Errors.ZeroAmount();
        }

        DataTypes.Position storage position = positions[borrower][tokenId];

        // Check position is liquidatable
        uint256 collateralValue = _getCollateralValue(tokenId, position.collateralAmount);
        uint256 healthFactor = calculateHealthFactor(collateralValue, position.borrowedAmount);

        if (healthFactor >= HEALTH_FACTOR_THRESHOLD) {
            revert Errors.NotLiquidatable(healthFactor);
        }

        // Check close factor limit
        uint256 maxRepay = position.borrowedAmount.percentMul(closeFactor);
        if (repayAmount > maxRepay) {
            revert Errors.ExceedsCloseFactor(repayAmount, maxRepay);
        }

        // Calculate collateral to seize (including bonus)
        collateralSeized = calculateSeizeAmount(tokenId, repayAmount);

        // Ensure enough collateral exists
        if (collateralSeized > position.collateralAmount) {
            collateralSeized = position.collateralAmount;
        }

        // Transfer USDC from liquidator to lending pool
        IERC20(usdc).safeTransferFrom(msg.sender, address(lendingPool), repayAmount);

        // Update position
        position.borrowedAmount -= repayAmount;
        position.collateralAmount -= collateralSeized;
        position.lastUpdateTimestamp = block.timestamp;

        // Transfer collateral from vault to liquidator
        vault.transferCollateralToLiquidator(borrower, msg.sender, tokenId, collateralSeized);

        emit Liquidation(msg.sender, borrower, tokenId, repayAmount, collateralSeized);
    }

    // ============ View Functions ============

    /**
     * @notice Calculate the health factor for given values
     * @param collateralValue The collateral value in USDC terms
     * @param debt The outstanding debt
     * @return healthFactor The health factor (1e18 = 1.0)
     */
    function calculateHealthFactor(
        uint256 collateralValue,
        uint256 debt
    ) public view override returns (uint256 healthFactor) {
        return PercentageMath.calculateHealthFactor(collateralValue, liquidationThreshold, debt);
    }

    /**
     * @notice Check if a position can be liquidated
     * @param borrower The borrower address
     * @param tokenId The collateral token ID
     * @return True if the position is liquidatable
     */
    function isLiquidatable(address borrower, uint256 tokenId) external view override returns (bool) {
        DataTypes.Position memory position = positions[borrower][tokenId];

        if (position.borrowedAmount == 0) {
            return false;
        }

        uint256 collateralValue = _getCollateralValue(tokenId, position.collateralAmount);
        uint256 healthFactor = calculateHealthFactor(collateralValue, position.borrowedAmount);

        return healthFactor < HEALTH_FACTOR_THRESHOLD;
    }

    /**
     * @notice Get the maximum amount that can be liquidated
     * @param borrower The borrower address
     * @param tokenId The collateral token ID
     * @return maxRepay The maximum repayable amount
     * @return maxSeize The maximum collateral that can be seized
     */
    function getMaxLiquidation(
        address borrower,
        uint256 tokenId
    ) external view override returns (uint256 maxRepay, uint256 maxSeize) {
        DataTypes.Position memory position = positions[borrower][tokenId];

        if (position.borrowedAmount == 0) {
            return (0, 0);
        }

        maxRepay = position.borrowedAmount.percentMul(closeFactor);
        maxSeize = calculateSeizeAmount(tokenId, maxRepay);

        // Cap at available collateral
        if (maxSeize > position.collateralAmount) {
            maxSeize = position.collateralAmount;
            // Reverse calculate repay amount
            maxRepay = _calculateRepayForSeize(tokenId, maxSeize);
        }
    }

    /**
     * @notice Calculate collateral to seize for a given repay amount
     * @param tokenId The collateral token ID
     * @param repayAmount The amount being repaid
     * @return The collateral amount to seize (including bonus)
     */
    function calculateSeizeAmount(
        uint256 tokenId,
        uint256 repayAmount
    ) public view override returns (uint256) {
        // Get collateral price
        (uint256 price,) = oracle.getTWAP(tokenId);

        if (price == 0) {
            return 0;
        }

        // repayAmount is in USDC (6 decimals)
        // price is in 18 decimals (0 to 1e18 representing 0% to 100%)
        // collateral amount should be in token units

        // Value of repayment in collateral terms, with bonus
        // collateralValue = repayAmount * (1 + bonus) / price
        uint256 repayWithBonus = repayAmount.percentMul(PercentageMath.BPS + liquidationBonus);

        // Scale repay amount to 18 decimals then divide by price
        uint256 repayScaled = PercentageMath.scaleUSDCTo18(repayWithBonus);

        return (repayScaled * PercentageMath.PRICE_PRECISION) / price;
    }

    /**
     * @notice Get a user's position
     * @param user The user address
     * @param tokenId The token ID
     * @return The position struct
     */
    function getPosition(
        address user,
        uint256 tokenId
    ) external view returns (DataTypes.Position memory) {
        return positions[user][tokenId];
    }

    /**
     * @notice Get the health factor for a position
     * @param user The user address
     * @param tokenId The token ID
     * @return The health factor
     */
    function getPositionHealthFactor(
        address user,
        uint256 tokenId
    ) external view returns (uint256) {
        DataTypes.Position memory position = positions[user][tokenId];

        if (position.borrowedAmount == 0) {
            return type(uint256).max;
        }

        uint256 collateralValue = _getCollateralValue(tokenId, position.collateralAmount);
        return calculateHealthFactor(collateralValue, position.borrowedAmount);
    }

    // ============ Internal Functions ============

    /**
     * @notice Get collateral value in USDC terms
     * @param tokenId The token ID
     * @param amount The collateral amount
     * @return The value in USDC (6 decimals)
     */
    function _getCollateralValue(uint256 tokenId, uint256 amount) internal view returns (uint256) {
        if (amount == 0) {
            return 0;
        }

        (uint256 price,) = oracle.getTWAP(tokenId);

        // price is 0 to 1e18 representing probability
        // collateral value = amount * price
        // Scale down from 18 decimals to 6 decimals for USDC
        return PercentageMath.scaleToUSDC((amount * price) / PercentageMath.PRICE_PRECISION);
    }

    /**
     * @notice Calculate repay amount for a given seize amount (reverse calculation)
     * @param tokenId The token ID
     * @param seizeAmount The collateral to seize
     * @return The repay amount needed
     */
    function _calculateRepayForSeize(uint256 tokenId, uint256 seizeAmount) internal view returns (uint256) {
        (uint256 price,) = oracle.getTWAP(tokenId);

        if (price == 0) {
            return 0;
        }

        // seizeAmount * price = repayValue * (1 + bonus)
        // repayAmount = (seizeAmount * price) / (1 + bonus)
        uint256 seizeValue = (seizeAmount * price) / PercentageMath.PRICE_PRECISION;
        uint256 seizeValueUSDC = PercentageMath.scaleToUSDC(seizeValue);

        return seizeValueUSDC.percentDiv(PercentageMath.BPS + liquidationBonus);
    }
}
