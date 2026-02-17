// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Errors
 * @notice Custom errors for the PolyLend protocol
 * @dev Using custom errors for gas efficiency over require strings
 */
library Errors {
    // ============ General Errors ============

    /// @notice Thrown when caller is not authorized
    error Unauthorized();

    /// @notice Thrown when zero address is provided
    error ZeroAddress();

    /// @notice Thrown when zero amount is provided
    error ZeroAmount();

    /// @notice Thrown when array lengths don't match
    error ArrayLengthMismatch();

    /// @notice Thrown when contract is paused
    error ContractPaused();

    // ============ Market Errors ============

    /// @notice Thrown when market is not registered
    error MarketNotRegistered(bytes32 marketId);

    /// @notice Thrown when market is already registered
    error MarketAlreadyRegistered(bytes32 marketId);

    /// @notice Thrown when market is frozen
    error MarketFrozen(bytes32 marketId);

    /// @notice Thrown when market has already resolved
    error MarketResolved(bytes32 marketId);

    /// @notice Thrown when resolution time is invalid
    error InvalidResolutionTime();

    // ============ Position Errors ============

    /// @notice Thrown when position doesn't exist
    error PositionNotFound(address user, uint256 positionId);

    /// @notice Thrown when position is healthy and cannot be liquidated
    error PositionHealthy(uint256 healthFactor);

    /// @notice Thrown when withdrawal would make position unhealthy
    error WithdrawalWouldLiquidate();

    /// @notice Thrown when borrow would exceed max LTV
    error ExceedsMaxLTV(uint256 requestedLTV, uint256 maxLTV);

    /// @notice Thrown when position has outstanding debt
    error OutstandingDebt(uint256 debt);

    // ============ Lending Pool Errors ============

    /// @notice Thrown when insufficient liquidity for borrow
    error InsufficientLiquidity(uint256 available, uint256 requested);

    /// @notice Thrown when insufficient shares for withdrawal
    error InsufficientShares(uint256 available, uint256 requested);

    /// @notice Thrown when repayment exceeds debt
    error ExcessiveRepayment(uint256 debt, uint256 repayment);

    /// @notice Thrown when utilization rate is too high
    error UtilizationTooHigh(uint256 utilization);

    // ============ Vault Errors ============

    /// @notice Thrown when collateral transfer fails
    error CollateralTransferFailed();

    /// @notice Thrown when insufficient collateral
    error InsufficientCollateral(uint256 available, uint256 requested);

    /// @notice Thrown when collateral doesn't belong to user
    error NotCollateralOwner();

    // ============ Oracle Errors ============

    /// @notice Thrown when price data is stale
    error StalePrice(uint256 lastUpdate, uint256 stalenessThreshold);

    /// @notice Thrown when price deviation exceeds threshold
    error PriceDeviationTooHigh(uint256 deviation, uint256 maxDeviation);

    /// @notice Thrown when insufficient observations for TWAP
    error InsufficientObservations(uint256 count, uint256 required);

    /// @notice Thrown when price is invalid (zero or negative)
    error InvalidPrice();

    // ============ Liquidation Errors ============

    /// @notice Thrown when liquidation amount exceeds close factor
    error ExceedsCloseFactor(uint256 amount, uint256 maxClose);

    /// @notice Thrown when liquidator receives insufficient collateral
    error InsufficientLiquidationReward();

    /// @notice Thrown when health factor is above liquidation threshold
    error NotLiquidatable(uint256 healthFactor);

    // ============ Circuit Breaker Errors ============

    /// @notice Thrown when emergency pause is already active
    error AlreadyPaused();

    /// @notice Thrown when trying to unpause when not paused
    error NotPaused();

    /// @notice Thrown when market is in pre-resolution freeze period
    error PreResolutionFreeze(bytes32 marketId, uint256 timeToResolution);

    /// @notice Thrown when circuit breaker is tripped
    error CircuitBreakerTripped();

    // ============ Access Control Errors ============

    /// @notice Thrown when caller is not the owner
    error NotOwner();

    /// @notice Thrown when caller is not a guardian
    error NotGuardian();

    /// @notice Thrown when caller is not an authorized updater
    error NotAuthorizedUpdater();

    /// @notice Thrown when caller is not the lending pool
    error NotLendingPool();

    /// @notice Thrown when caller is not the liquidation engine
    error NotLiquidationEngine();
}
