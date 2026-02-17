// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IPolymarketOracle
 * @notice Interface for the Polymarket TWAP Oracle
 */
interface IPolymarketOracle {
    /**
     * @notice Record a new price observation
     * @param tokenId The conditional token ID
     * @param price The observed price (18 decimals, 0 to 1e18)
     */
    function recordObservation(uint256 tokenId, uint256 price) external;

    /**
     * @notice Get the TWAP price for a token
     * @param tokenId The conditional token ID
     * @return price The TWAP price (18 decimals)
     * @return timestamp The timestamp of the latest observation
     */
    function getTWAP(uint256 tokenId) external view returns (uint256 price, uint256 timestamp);

    /**
     * @notice Get the latest spot price for a token
     * @param tokenId The conditional token ID
     * @return price The latest price (18 decimals)
     * @return timestamp The timestamp of the observation
     */
    function getLatestPrice(uint256 tokenId) external view returns (uint256 price, uint256 timestamp);

    /**
     * @notice Check if price data is stale
     * @param tokenId The conditional token ID
     * @return True if the price data is stale
     */
    function isPriceStale(uint256 tokenId) external view returns (bool);

    /**
     * @notice Check if circuit breaker is triggered for a token
     * @param tokenId The conditional token ID
     * @return True if circuit breaker is active
     */
    function isCircuitBreakerTriggered(uint256 tokenId) external view returns (bool);

    /**
     * @notice Get the TWAP window duration
     * @return Duration in seconds
     */
    function twapWindow() external view returns (uint256);

    /**
     * @notice Get the staleness threshold
     * @return Duration in seconds
     */
    function stalenessThreshold() external view returns (uint256);

    /**
     * @notice Get the circuit breaker deviation threshold
     * @return Deviation in basis points
     */
    function circuitBreakerThreshold() external view returns (uint256);
}
