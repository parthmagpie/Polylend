// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../libraries/DataTypes.sol";
import "../libraries/Errors.sol";
import "../libraries/PercentageMath.sol";
import "./MarketRegistry.sol";

/**
 * @title LTVCalculator
 * @notice Calculates time-decay LTV based on market resolution proximity
 * @dev LTV decreases as markets approach resolution to reduce risk
 *
 * Time-Decay Schedule:
 * - > 7 days:      50% LTV (NORMAL)
 * - 2-7 days:      35% LTV (MEDIUM_RISK)
 * - 24-48 hours:   20% LTV (HIGH_RISK)
 * - < 24 hours:    0% LTV (FROZEN - no new borrows)
 */
contract LTVCalculator is Ownable {
    using PercentageMath for uint256;

    // ============ Constants ============

    /// @notice 7 days in seconds
    uint256 public constant NORMAL_THRESHOLD = 7 days;

    /// @notice 2 days in seconds
    uint256 public constant MEDIUM_RISK_THRESHOLD = 2 days;

    /// @notice 48 hours in seconds
    uint256 public constant HIGH_RISK_THRESHOLD = 48 hours;

    /// @notice 24 hours in seconds (pre-resolution freeze)
    uint256 public constant FREEZE_THRESHOLD = 24 hours;

    // ============ Storage ============

    /// @notice Reference to market registry
    MarketRegistry public immutable marketRegistry;

    /// @notice LTV for normal tier (> 7 days) in basis points
    uint256 public normalLTV = 5000; // 50%

    /// @notice LTV for medium risk tier (2-7 days) in basis points
    uint256 public mediumRiskLTV = 3500; // 35%

    /// @notice LTV for high risk tier (24-48 hours) in basis points
    uint256 public highRiskLTV = 2000; // 20%

    /// @notice LTV for frozen tier (< 24 hours) in basis points
    uint256 public frozenLTV = 0; // 0%

    // ============ Events ============

    event LTVTiersUpdated(
        uint256 normalLTV,
        uint256 mediumRiskLTV,
        uint256 highRiskLTV
    );

    // ============ Constructor ============

    constructor(address _marketRegistry) Ownable(msg.sender) {
        if (_marketRegistry == address(0)) {
            revert Errors.ZeroAddress();
        }
        marketRegistry = MarketRegistry(_marketRegistry);
    }

    // ============ Admin Functions ============

    /**
     * @notice Update LTV tiers
     * @param _normalLTV New normal tier LTV (basis points)
     * @param _mediumRiskLTV New medium risk tier LTV (basis points)
     * @param _highRiskLTV New high risk tier LTV (basis points)
     */
    function updateLTVTiers(
        uint256 _normalLTV,
        uint256 _mediumRiskLTV,
        uint256 _highRiskLTV
    ) external onlyOwner {
        require(_normalLTV <= PercentageMath.BPS, "Normal LTV too high");
        require(_mediumRiskLTV <= _normalLTV, "Medium must be <= Normal");
        require(_highRiskLTV <= _mediumRiskLTV, "High must be <= Medium");

        normalLTV = _normalLTV;
        mediumRiskLTV = _mediumRiskLTV;
        highRiskLTV = _highRiskLTV;

        emit LTVTiersUpdated(_normalLTV, _mediumRiskLTV, _highRiskLTV);
    }

    // ============ View Functions ============

    /**
     * @notice Get the current LTV tier for a market
     * @param marketId The market condition ID
     * @return tier The current LTV tier
     */
    function getLTVTier(bytes32 marketId) public view returns (DataTypes.LTVTier tier) {
        DataTypes.Market memory market = marketRegistry.getMarket(marketId);

        if (!market.isRegistered) {
            revert Errors.MarketNotRegistered(marketId);
        }

        // If manually frozen, return FROZEN tier
        if (market.isFrozen) {
            return DataTypes.LTVTier.FROZEN;
        }

        uint256 timeToResolution = _getTimeToResolution(market.resolutionTime);

        if (timeToResolution < FREEZE_THRESHOLD) {
            return DataTypes.LTVTier.FROZEN;
        } else if (timeToResolution < HIGH_RISK_THRESHOLD) {
            return DataTypes.LTVTier.HIGH_RISK;
        } else if (timeToResolution < NORMAL_THRESHOLD) {
            return DataTypes.LTVTier.MEDIUM_RISK;
        } else {
            return DataTypes.LTVTier.NORMAL;
        }
    }

    /**
     * @notice Get the current max LTV for a market
     * @param marketId The market condition ID
     * @return The max LTV in basis points
     */
    function getMaxLTV(bytes32 marketId) external view returns (uint256) {
        DataTypes.LTVTier tier = getLTVTier(marketId);
        return _getLTVForTier(tier);
    }

    /**
     * @notice Get the current max LTV for a token
     * @param tokenId The ERC-1155 token ID
     * @return The max LTV in basis points
     */
    function getMaxLTVForToken(uint256 tokenId) external view returns (uint256) {
        DataTypes.Market memory market = marketRegistry.getMarketForToken(tokenId);
        if (!market.isRegistered) {
            revert Errors.MarketNotRegistered(bytes32(0));
        }
        DataTypes.LTVTier tier = getLTVTier(market.conditionId);
        return _getLTVForTier(tier);
    }

    /**
     * @notice Calculate the maximum borrowable amount given collateral
     * @param marketId The market condition ID
     * @param collateralValue The collateral value in USDC terms
     * @return The maximum borrowable amount
     */
    function calculateMaxBorrow(
        bytes32 marketId,
        uint256 collateralValue
    ) external view returns (uint256) {
        DataTypes.LTVTier tier = getLTVTier(marketId);
        uint256 maxLTV = _getLTVForTier(tier);
        return collateralValue.percentMul(maxLTV);
    }

    /**
     * @notice Check if borrowing is allowed for a market
     * @param marketId The market condition ID
     * @return True if borrowing is allowed
     */
    function isBorrowingAllowed(bytes32 marketId) external view returns (bool) {
        DataTypes.LTVTier tier = getLTVTier(marketId);
        return tier != DataTypes.LTVTier.FROZEN;
    }

    /**
     * @notice Get detailed LTV info for a market
     * @param marketId The market condition ID
     * @return tier The current tier
     * @return maxLTV The current max LTV
     * @return timeToResolution Time until resolution
     * @return isFrozen Whether the market is frozen
     */
    function getLTVInfo(bytes32 marketId) external view returns (
        DataTypes.LTVTier tier,
        uint256 maxLTV,
        uint256 timeToResolution,
        bool isFrozen
    ) {
        DataTypes.Market memory market = marketRegistry.getMarket(marketId);

        if (!market.isRegistered) {
            revert Errors.MarketNotRegistered(marketId);
        }

        tier = getLTVTier(marketId);
        maxLTV = _getLTVForTier(tier);
        timeToResolution = _getTimeToResolution(market.resolutionTime);
        isFrozen = tier == DataTypes.LTVTier.FROZEN;
    }

    /**
     * @notice Get all LTV tier values
     * @return _normalLTV Normal tier LTV
     * @return _mediumRiskLTV Medium risk tier LTV
     * @return _highRiskLTV High risk tier LTV
     * @return _frozenLTV Frozen tier LTV (always 0)
     */
    function getAllLTVTiers() external view returns (
        uint256 _normalLTV,
        uint256 _mediumRiskLTV,
        uint256 _highRiskLTV,
        uint256 _frozenLTV
    ) {
        return (normalLTV, mediumRiskLTV, highRiskLTV, frozenLTV);
    }

    // ============ Internal Functions ============

    /**
     * @notice Get time remaining until resolution
     * @param resolutionTime The resolution timestamp
     * @return Time in seconds (0 if already passed)
     */
    function _getTimeToResolution(uint256 resolutionTime) internal view returns (uint256) {
        if (block.timestamp >= resolutionTime) {
            return 0;
        }
        return resolutionTime - block.timestamp;
    }

    /**
     * @notice Get the LTV for a specific tier
     * @param tier The LTV tier
     * @return The LTV in basis points
     */
    function _getLTVForTier(DataTypes.LTVTier tier) internal view returns (uint256) {
        if (tier == DataTypes.LTVTier.NORMAL) {
            return normalLTV;
        } else if (tier == DataTypes.LTVTier.MEDIUM_RISK) {
            return mediumRiskLTV;
        } else if (tier == DataTypes.LTVTier.HIGH_RISK) {
            return highRiskLTV;
        } else {
            return frozenLTV;
        }
    }
}
