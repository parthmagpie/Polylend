// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../libraries/DataTypes.sol";
import "../libraries/Errors.sol";
import "../libraries/PercentageMath.sol";
import "../interfaces/IPolymarketOracle.sol";

/**
 * @title PolymarketTWAPOracle
 * @notice Time-Weighted Average Price oracle for Polymarket conditional tokens
 * @dev Implements a 30-minute TWAP with circuit breaker and staleness checks
 *
 * Features:
 * - 30-minute TWAP window
 * - 8% deviation circuit breaker
 * - 5-minute staleness threshold
 * - Ring buffer for gas-efficient observation storage (60 slots)
 */
contract PolymarketTWAPOracle is IPolymarketOracle, Ownable {
    using PercentageMath for uint256;

    // ============ Constants ============

    /// @notice Number of observation slots in ring buffer
    uint256 public constant OBSERVATION_CARDINALITY = 60;

    /// @notice TWAP window duration (30 minutes)
    uint256 public constant TWAP_WINDOW = 30 minutes;

    /// @notice Staleness threshold (5 minutes)
    uint256 public constant STALENESS_THRESHOLD = 5 minutes;

    /// @notice Circuit breaker threshold (8% = 800 basis points)
    uint256 public constant CIRCUIT_BREAKER_THRESHOLD = 800;

    /// @notice Minimum observations required for valid TWAP
    uint256 public constant MIN_OBSERVATIONS = 2;

    /// @notice Price precision (18 decimals)
    uint256 public constant PRICE_PRECISION = 1e18;

    // ============ Storage ============

    /// @notice Authorized price updaters
    mapping(address => bool) public authorizedUpdaters;

    /// @notice Ring buffer observations per token
    mapping(uint256 => DataTypes.PriceObservation[OBSERVATION_CARDINALITY]) public observations;

    /// @notice Current index in ring buffer per token
    mapping(uint256 => uint256) public observationIndex;

    /// @notice Number of observations recorded per token
    mapping(uint256 => uint256) public observationCount;

    /// @notice Circuit breaker status per token
    mapping(uint256 => bool) public circuitBreakerTriggered;

    /// @notice Last recorded TWAP per token (for circuit breaker comparison)
    mapping(uint256 => uint256) public lastTWAP;

    // ============ Events ============

    event ObservationRecorded(
        uint256 indexed tokenId,
        uint256 price,
        uint256 timestamp,
        uint256 cumulativePrice
    );

    event CircuitBreakerTriggered(
        uint256 indexed tokenId,
        uint256 newPrice,
        uint256 previousTWAP,
        uint256 deviation
    );

    event CircuitBreakerReset(uint256 indexed tokenId);

    event UpdaterAuthorized(address indexed updater);

    event UpdaterRevoked(address indexed updater);

    // ============ Modifiers ============

    modifier onlyAuthorizedUpdater() {
        if (!authorizedUpdaters[msg.sender] && msg.sender != owner()) {
            revert Errors.NotAuthorizedUpdater();
        }
        _;
    }

    // ============ Constructor ============

    constructor() Ownable(msg.sender) {
        // Owner is automatically an authorized updater
        authorizedUpdaters[msg.sender] = true;
    }

    // ============ Admin Functions ============

    /**
     * @notice Authorize an address to update prices
     * @param updater The address to authorize
     */
    function authorizeUpdater(address updater) external onlyOwner {
        if (updater == address(0)) {
            revert Errors.ZeroAddress();
        }
        authorizedUpdaters[updater] = true;
        emit UpdaterAuthorized(updater);
    }

    /**
     * @notice Revoke update authorization
     * @param updater The address to revoke
     */
    function revokeUpdater(address updater) external onlyOwner {
        authorizedUpdaters[updater] = false;
        emit UpdaterRevoked(updater);
    }

    /**
     * @notice Manually reset circuit breaker for a token
     * @param tokenId The token ID
     */
    function resetCircuitBreaker(uint256 tokenId) external onlyOwner {
        circuitBreakerTriggered[tokenId] = false;
        emit CircuitBreakerReset(tokenId);
    }

    // ============ Price Update Functions ============

    /**
     * @notice Record a new price observation
     * @param tokenId The conditional token ID
     * @param price The observed price (18 decimals, between 0 and 1e18)
     */
    function recordObservation(uint256 tokenId, uint256 price) external onlyAuthorizedUpdater {
        if (price > PRICE_PRECISION) {
            revert Errors.InvalidPrice();
        }

        // Get current observation data
        uint256 currentIndex = observationIndex[tokenId];
        uint256 count = observationCount[tokenId];

        // Calculate cumulative price
        uint256 cumulativePrice;
        if (count > 0) {
            uint256 prevIndex = currentIndex == 0 ? OBSERVATION_CARDINALITY - 1 : currentIndex - 1;
            DataTypes.PriceObservation storage prevObs = observations[tokenId][prevIndex];
            uint256 timeDelta = block.timestamp - prevObs.timestamp;
            cumulativePrice = prevObs.cumulativePrice + (prevObs.price * timeDelta);
        }

        // Check circuit breaker before recording
        if (count >= MIN_OBSERVATIONS && !circuitBreakerTriggered[tokenId]) {
            uint256 currentTWAP = _calculateTWAP(tokenId);
            if (currentTWAP > 0) {
                uint256 deviation = PercentageMath.calculateDeviation(price, currentTWAP);
                if (deviation > CIRCUIT_BREAKER_THRESHOLD) {
                    circuitBreakerTriggered[tokenId] = true;
                    emit CircuitBreakerTriggered(tokenId, price, currentTWAP, deviation);
                    return; // Don't record the observation
                }
            }
        }

        // Record new observation
        observations[tokenId][currentIndex] = DataTypes.PriceObservation({
            timestamp: block.timestamp,
            price: price,
            cumulativePrice: cumulativePrice
        });

        // Update index and count
        observationIndex[tokenId] = (currentIndex + 1) % OBSERVATION_CARDINALITY;
        if (count < OBSERVATION_CARDINALITY) {
            observationCount[tokenId] = count + 1;
        }

        // Update last TWAP if we have enough observations
        if (observationCount[tokenId] >= MIN_OBSERVATIONS) {
            lastTWAP[tokenId] = _calculateTWAP(tokenId);
        }

        emit ObservationRecorded(tokenId, price, block.timestamp, cumulativePrice);
    }

    /**
     * @notice Batch record observations for multiple tokens
     * @param tokenIds Array of token IDs
     * @param prices Array of prices
     */
    function batchRecordObservations(
        uint256[] calldata tokenIds,
        uint256[] calldata prices
    ) external onlyAuthorizedUpdater {
        if (tokenIds.length != prices.length) {
            revert Errors.ArrayLengthMismatch();
        }

        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (prices[i] <= PRICE_PRECISION) {
                // Skip invalid prices silently in batch
                _recordObservationInternal(tokenIds[i], prices[i]);
            }
        }
    }

    // ============ View Functions ============

    /**
     * @notice Get the TWAP price for a token
     * @param tokenId The conditional token ID
     * @return price The TWAP price (18 decimals)
     * @return timestamp The timestamp of the latest observation
     */
    function getTWAP(uint256 tokenId) external view returns (uint256 price, uint256 timestamp) {
        uint256 count = observationCount[tokenId];
        if (count < MIN_OBSERVATIONS) {
            revert Errors.InsufficientObservations(count, MIN_OBSERVATIONS);
        }

        price = _calculateTWAP(tokenId);
        timestamp = _getLatestObservation(tokenId).timestamp;
    }

    /**
     * @notice Get the latest spot price for a token
     * @param tokenId The conditional token ID
     * @return price The latest price (18 decimals)
     * @return timestamp The timestamp of the observation
     */
    function getLatestPrice(uint256 tokenId) external view returns (uint256 price, uint256 timestamp) {
        if (observationCount[tokenId] == 0) {
            revert Errors.InsufficientObservations(0, 1);
        }

        DataTypes.PriceObservation memory obs = _getLatestObservation(tokenId);
        return (obs.price, obs.timestamp);
    }

    /**
     * @notice Check if price data is stale
     * @param tokenId The conditional token ID
     * @return True if the price data is stale
     */
    function isPriceStale(uint256 tokenId) external view returns (bool) {
        if (observationCount[tokenId] == 0) {
            return true;
        }

        DataTypes.PriceObservation memory latest = _getLatestObservation(tokenId);
        return block.timestamp - latest.timestamp > STALENESS_THRESHOLD;
    }

    /**
     * @notice Check if circuit breaker is triggered for a token
     * @param tokenId The conditional token ID
     * @return True if circuit breaker is active
     */
    function isCircuitBreakerTriggered(uint256 tokenId) external view returns (bool) {
        return circuitBreakerTriggered[tokenId];
    }

    /**
     * @notice Get the TWAP window duration
     * @return Duration in seconds
     */
    function twapWindow() external pure returns (uint256) {
        return TWAP_WINDOW;
    }

    /**
     * @notice Get the staleness threshold
     * @return Duration in seconds
     */
    function stalenessThreshold() external pure returns (uint256) {
        return STALENESS_THRESHOLD;
    }

    /**
     * @notice Get the circuit breaker deviation threshold
     * @return Deviation in basis points
     */
    function circuitBreakerThreshold() external pure returns (uint256) {
        return CIRCUIT_BREAKER_THRESHOLD;
    }

    /**
     * @notice Get observation details for a token at a specific index
     * @param tokenId The token ID
     * @param index The observation index
     * @return The observation data
     */
    function getObservation(
        uint256 tokenId,
        uint256 index
    ) external view returns (DataTypes.PriceObservation memory) {
        require(index < OBSERVATION_CARDINALITY, "Index out of bounds");
        return observations[tokenId][index];
    }

    /**
     * @notice Get the number of valid observations for a token
     * @param tokenId The token ID
     * @return The observation count
     */
    function getObservationCount(uint256 tokenId) external view returns (uint256) {
        return observationCount[tokenId];
    }

    // ============ Internal Functions ============

    /**
     * @notice Internal function to record observation (used in batch)
     */
    function _recordObservationInternal(uint256 tokenId, uint256 price) internal {
        uint256 currentIndex = observationIndex[tokenId];
        uint256 count = observationCount[tokenId];

        uint256 cumulativePrice;
        if (count > 0) {
            uint256 prevIndex = currentIndex == 0 ? OBSERVATION_CARDINALITY - 1 : currentIndex - 1;
            DataTypes.PriceObservation storage prevObs = observations[tokenId][prevIndex];
            uint256 timeDelta = block.timestamp - prevObs.timestamp;
            cumulativePrice = prevObs.cumulativePrice + (prevObs.price * timeDelta);
        }

        // Check circuit breaker
        if (count >= MIN_OBSERVATIONS && !circuitBreakerTriggered[tokenId]) {
            uint256 currentTWAP = _calculateTWAP(tokenId);
            if (currentTWAP > 0) {
                uint256 deviation = PercentageMath.calculateDeviation(price, currentTWAP);
                if (deviation > CIRCUIT_BREAKER_THRESHOLD) {
                    circuitBreakerTriggered[tokenId] = true;
                    emit CircuitBreakerTriggered(tokenId, price, currentTWAP, deviation);
                    return;
                }
            }
        }

        observations[tokenId][currentIndex] = DataTypes.PriceObservation({
            timestamp: block.timestamp,
            price: price,
            cumulativePrice: cumulativePrice
        });

        observationIndex[tokenId] = (currentIndex + 1) % OBSERVATION_CARDINALITY;
        if (count < OBSERVATION_CARDINALITY) {
            observationCount[tokenId] = count + 1;
        }

        if (observationCount[tokenId] >= MIN_OBSERVATIONS) {
            lastTWAP[tokenId] = _calculateTWAP(tokenId);
        }

        emit ObservationRecorded(tokenId, price, block.timestamp, cumulativePrice);
    }

    /**
     * @notice Calculate TWAP from observations
     * @param tokenId The token ID
     * @return The TWAP price
     */
    function _calculateTWAP(uint256 tokenId) internal view returns (uint256) {
        uint256 count = observationCount[tokenId];
        if (count < MIN_OBSERVATIONS) {
            return 0;
        }

        // Get latest observation
        DataTypes.PriceObservation memory latest = _getLatestObservation(tokenId);

        // Find the oldest observation within TWAP window
        uint256 targetTime = latest.timestamp > TWAP_WINDOW ? latest.timestamp - TWAP_WINDOW : 0;
        DataTypes.PriceObservation memory oldest = _findOldestObservationInWindow(tokenId, targetTime);

        uint256 timeDelta = latest.timestamp - oldest.timestamp;
        if (timeDelta == 0) {
            return latest.price;
        }

        // Calculate TWAP
        uint256 priceDelta = latest.cumulativePrice +
            (latest.price * (block.timestamp - latest.timestamp)) -
            oldest.cumulativePrice;

        return priceDelta / timeDelta;
    }

    /**
     * @notice Get the latest observation for a token
     * @param tokenId The token ID
     * @return The latest observation
     */
    function _getLatestObservation(uint256 tokenId) internal view returns (DataTypes.PriceObservation memory) {
        uint256 currentIndex = observationIndex[tokenId];
        uint256 latestIndex = currentIndex == 0 ? observationCount[tokenId] - 1 : currentIndex - 1;
        return observations[tokenId][latestIndex];
    }

    /**
     * @notice Find the oldest observation within the TWAP window
     * @param tokenId The token ID
     * @param targetTime The target timestamp
     * @return The oldest relevant observation
     */
    function _findOldestObservationInWindow(
        uint256 tokenId,
        uint256 targetTime
    ) internal view returns (DataTypes.PriceObservation memory) {
        uint256 count = observationCount[tokenId];
        uint256 currentIndex = observationIndex[tokenId];

        // Start from the oldest observation
        uint256 oldestIndex;
        if (count < OBSERVATION_CARDINALITY) {
            oldestIndex = 0;
        } else {
            oldestIndex = currentIndex;
        }

        DataTypes.PriceObservation memory oldest = observations[tokenId][oldestIndex];

        // If oldest is already newer than target, return it
        if (oldest.timestamp >= targetTime) {
            return oldest;
        }

        // Search for the observation closest to target time
        for (uint256 i = 0; i < count; i++) {
            uint256 idx = (oldestIndex + i) % OBSERVATION_CARDINALITY;
            if (observations[tokenId][idx].timestamp >= targetTime) {
                return observations[tokenId][idx];
            }
        }

        return oldest;
    }
}
