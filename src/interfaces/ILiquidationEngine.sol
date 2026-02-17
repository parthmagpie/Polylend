// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../libraries/DataTypes.sol";

/**
 * @title ILiquidationEngine
 * @notice Interface for the liquidation engine
 */
interface ILiquidationEngine {
    /**
     * @notice Emitted when a position is liquidated
     * @param liquidator The liquidator address
     * @param borrower The borrower being liquidated
     * @param tokenId The collateral token ID
     * @param debtRepaid The amount of debt repaid
     * @param collateralSeized The amount of collateral seized
     */
    event Liquidation(
        address indexed liquidator,
        address indexed borrower,
        uint256 indexed tokenId,
        uint256 debtRepaid,
        uint256 collateralSeized
    );

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
    ) external returns (uint256 collateralSeized);

    /**
     * @notice Calculate the health factor for a position
     * @param collateralValue The collateral value in USDC terms
     * @param debt The outstanding debt
     * @return healthFactor The health factor (1e18 = 1.0)
     */
    function calculateHealthFactor(
        uint256 collateralValue,
        uint256 debt
    ) external view returns (uint256 healthFactor);

    /**
     * @notice Check if a position can be liquidated
     * @param borrower The borrower address
     * @param tokenId The collateral token ID
     * @return True if the position is liquidatable
     */
    function isLiquidatable(address borrower, uint256 tokenId) external view returns (bool);

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
    ) external view returns (uint256 maxRepay, uint256 maxSeize);

    /**
     * @notice Calculate collateral to seize for a given repay amount
     * @param tokenId The collateral token ID
     * @param repayAmount The amount being repaid
     * @return The collateral amount to seize (including bonus)
     */
    function calculateSeizeAmount(
        uint256 tokenId,
        uint256 repayAmount
    ) external view returns (uint256);

    /**
     * @notice Get the liquidation threshold
     * @return Threshold in basis points
     */
    function liquidationThreshold() external view returns (uint256);

    /**
     * @notice Get the liquidation bonus
     * @return Bonus in basis points
     */
    function liquidationBonus() external view returns (uint256);

    /**
     * @notice Get the close factor
     * @return Close factor in basis points
     */
    function closeFactor() external view returns (uint256);
}
