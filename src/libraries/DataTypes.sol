// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title DataTypes
 * @notice Core data structures used across the PolyLend protocol
 */
library DataTypes {
    /**
     * @notice LTV tier based on time to market resolution
     * @param NORMAL > 7 days to resolution, 50% max LTV
     * @param MEDIUM_RISK 2-7 days to resolution, 35% max LTV
     * @param HIGH_RISK < 48 hours to resolution, 20% max LTV
     * @param FROZEN < 24 hours to resolution, no borrowing allowed
     */
    enum LTVTier {
        NORMAL,
        MEDIUM_RISK,
        HIGH_RISK,
        FROZEN
    }

    /**
     * @notice Represents a borrower's loan position
     * @param tokenId ERC-1155 conditional token ID used as collateral
     * @param collateralAmount Amount of conditional tokens deposited
     * @param borrowedAmount Amount of USDC borrowed
     * @param lastUpdateTimestamp Last time the position was modified
     * @param marketId The Polymarket condition ID this position is tied to
     */
    struct Position {
        uint256 tokenId;
        uint256 collateralAmount;
        uint256 borrowedAmount;
        uint256 lastUpdateTimestamp;
        bytes32 marketId;
    }

    /**
     * @notice Configuration for a Polymarket market
     * @param conditionId Unique identifier for the market condition
     * @param resolutionTime Expected timestamp when market resolves
     * @param isFrozen Whether new borrows are blocked for this market
     * @param isRegistered Whether this market is recognized by the protocol
     * @param outcomeCount Number of possible outcomes (typically 2)
     */
    struct Market {
        bytes32 conditionId;
        uint256 resolutionTime;
        bool isFrozen;
        bool isRegistered;
        uint8 outcomeCount;
    }

    /**
     * @notice Risk parameters for loan terms
     * @param maxLTV Maximum loan-to-value ratio in basis points (e.g., 5000 = 50%)
     * @param liquidationThreshold Threshold at which position becomes liquidatable (basis points)
     * @param liquidationBonus Bonus given to liquidators (basis points)
     * @param closeFactor Maximum percentage of debt that can be liquidated at once (basis points)
     */
    struct LoanTerms {
        uint256 maxLTV;
        uint256 liquidationThreshold;
        uint256 liquidationBonus;
        uint256 closeFactor;
    }

    /**
     * @notice TWAP observation point for price oracle
     * @param timestamp Time of the observation
     * @param price Price at observation time (18 decimals)
     * @param cumulativePrice Cumulative price for TWAP calculation
     */
    struct PriceObservation {
        uint256 timestamp;
        uint256 price;
        uint256 cumulativePrice;
    }

    /**
     * @notice Lending pool state
     * @param totalDeposits Total USDC deposited by lenders
     * @param totalBorrows Total USDC borrowed by borrowers
     * @param totalShares Total shares issued to lenders
     * @param lastUpdateTimestamp Last time pool state was updated
     */
    struct PoolState {
        uint256 totalDeposits;
        uint256 totalBorrows;
        uint256 totalShares;
        uint256 lastUpdateTimestamp;
    }

    /**
     * @notice Collateral information stored in vault
     * @param owner Address that deposited the collateral
     * @param tokenId ERC-1155 token ID
     * @param amount Amount of tokens
     * @param marketId Associated market condition ID
     * @param depositTimestamp When collateral was deposited
     */
    struct CollateralInfo {
        address owner;
        uint256 tokenId;
        uint256 amount;
        bytes32 marketId;
        uint256 depositTimestamp;
    }
}
