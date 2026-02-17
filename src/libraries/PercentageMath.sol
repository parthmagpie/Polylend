// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title PercentageMath
 * @notice Math utilities for percentage and basis point calculations
 * @dev All percentages are expressed in basis points (1 bp = 0.01% = 1/10000)
 */
library PercentageMath {
    /// @notice Basis points denominator (100% = 10000 bp)
    uint256 internal constant BPS = 10_000;

    /// @notice Half basis points for rounding
    uint256 internal constant HALF_BPS = 5_000;

    /// @notice Precision for price calculations (18 decimals)
    uint256 internal constant PRICE_PRECISION = 1e18;

    /// @notice Half precision for rounding
    uint256 internal constant HALF_PRECISION = 5e17;

    /// @notice USDC has 6 decimals
    uint256 internal constant USDC_DECIMALS = 6;

    /// @notice Scaling factor from USDC to 18 decimals
    uint256 internal constant USDC_SCALE = 1e12;

    /**
     * @notice Calculate percentage of a value in basis points
     * @param value The base value
     * @param bps The percentage in basis points
     * @return The calculated percentage, rounded down
     */
    function percentMul(uint256 value, uint256 bps) internal pure returns (uint256) {
        if (value == 0 || bps == 0) {
            return 0;
        }
        return (value * bps) / BPS;
    }

    /**
     * @notice Calculate percentage of a value in basis points, rounded up
     * @param value The base value
     * @param bps The percentage in basis points
     * @return The calculated percentage, rounded up
     */
    function percentMulUp(uint256 value, uint256 bps) internal pure returns (uint256) {
        if (value == 0 || bps == 0) {
            return 0;
        }
        return (value * bps + BPS - 1) / BPS;
    }

    /**
     * @notice Divide a value by a percentage in basis points
     * @param value The dividend
     * @param bps The divisor percentage in basis points
     * @return The quotient, rounded down
     */
    function percentDiv(uint256 value, uint256 bps) internal pure returns (uint256) {
        require(bps != 0, "Division by zero");
        return (value * BPS) / bps;
    }

    /**
     * @notice Divide a value by a percentage in basis points, rounded up
     * @param value The dividend
     * @param bps The divisor percentage in basis points
     * @return The quotient, rounded up
     */
    function percentDivUp(uint256 value, uint256 bps) internal pure returns (uint256) {
        require(bps != 0, "Division by zero");
        return (value * BPS + bps - 1) / bps;
    }

    /**
     * @notice Calculate LTV ratio in basis points
     * @param debt The debt amount
     * @param collateralValue The collateral value (in same units as debt)
     * @return The LTV ratio in basis points
     */
    function calculateLTV(uint256 debt, uint256 collateralValue) internal pure returns (uint256) {
        if (collateralValue == 0) {
            return type(uint256).max;
        }
        return (debt * BPS) / collateralValue;
    }

    /**
     * @notice Calculate health factor with precision
     * @param collateralValue Total collateral value
     * @param liquidationThreshold Liquidation threshold in basis points
     * @param debt Total debt
     * @return Health factor with 18 decimal precision (1e18 = healthy threshold)
     */
    function calculateHealthFactor(
        uint256 collateralValue,
        uint256 liquidationThreshold,
        uint256 debt
    ) internal pure returns (uint256) {
        if (debt == 0) {
            return type(uint256).max;
        }
        return (collateralValue * liquidationThreshold * PRICE_PRECISION) / (debt * BPS);
    }

    /**
     * @notice Scale USDC amount (6 decimals) to 18 decimals
     * @param amount Amount in USDC decimals
     * @return Scaled amount in 18 decimals
     */
    function scaleUSDCTo18(uint256 amount) internal pure returns (uint256) {
        return amount * USDC_SCALE;
    }

    /**
     * @notice Scale amount from 18 decimals to USDC (6 decimals)
     * @param amount Amount in 18 decimals
     * @return Scaled amount in USDC decimals
     */
    function scaleToUSDC(uint256 amount) internal pure returns (uint256) {
        return amount / USDC_SCALE;
    }

    /**
     * @notice Calculate the maximum borrowable amount given collateral and LTV
     * @param collateralValue The collateral value
     * @param maxLTV The maximum LTV in basis points
     * @return The maximum borrowable amount
     */
    function maxBorrowAmount(uint256 collateralValue, uint256 maxLTV) internal pure returns (uint256) {
        return percentMul(collateralValue, maxLTV);
    }

    /**
     * @notice Calculate the minimum collateral required for a given debt
     * @param debt The debt amount
     * @param maxLTV The maximum LTV in basis points
     * @return The minimum collateral required
     */
    function minCollateralRequired(uint256 debt, uint256 maxLTV) internal pure returns (uint256) {
        if (maxLTV == 0) {
            return type(uint256).max;
        }
        return percentDivUp(debt, maxLTV);
    }

    /**
     * @notice Check if a value is within a certain percentage of a reference
     * @param value The value to check
     * @param refValue The reference value
     * @param toleranceBps The tolerance in basis points
     * @return True if value is within tolerance of reference
     */
    function isWithinTolerance(
        uint256 value,
        uint256 refValue,
        uint256 toleranceBps
    ) internal pure returns (bool) {
        if (refValue == 0) {
            return value == 0;
        }
        uint256 diff = value > refValue ? value - refValue : refValue - value;
        return (diff * BPS) <= (refValue * toleranceBps);
    }

    /**
     * @notice Calculate percentage deviation between two values
     * @param value The current value
     * @param refValue The reference value
     * @return Deviation in basis points
     */
    function calculateDeviation(uint256 value, uint256 refValue) internal pure returns (uint256) {
        if (refValue == 0) {
            return value == 0 ? 0 : type(uint256).max;
        }
        uint256 diff = value > refValue ? value - refValue : refValue - value;
        return (diff * BPS) / refValue;
    }

    /**
     * @notice Get minimum of two values
     * @param a First value
     * @param b Second value
     * @return The minimum value
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /**
     * @notice Get maximum of two values
     * @param a First value
     * @param b Second value
     * @return The maximum value
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
}
