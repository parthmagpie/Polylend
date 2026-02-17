// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../libraries/Errors.sol";
import "./MarketRegistry.sol";

/**
 * @title CircuitBreaker
 * @notice Emergency controls for the PolyLend protocol
 * @dev Manages pre-resolution freeze, manual freezes, and global pause
 */
contract CircuitBreaker is Ownable, Pausable {
    // ============ Constants ============

    /// @notice Pre-resolution freeze period (24 hours)
    uint256 public constant PRE_RESOLUTION_FREEZE = 24 hours;

    // ============ Storage ============

    /// @notice Reference to market registry
    MarketRegistry public immutable marketRegistry;

    /// @notice Guardians who can trigger emergency actions
    mapping(address => bool) public guardians;

    /// @notice Timestamp when circuit breaker was tripped for a market
    mapping(bytes32 => uint256) public circuitBreakerTrippedAt;

    /// @notice Whether protocol-wide circuit breaker is active
    bool public globalCircuitBreakerActive;

    /// @notice Cooldown period after circuit breaker trips
    uint256 public circuitBreakerCooldown = 1 hours;

    // ============ Events ============

    event GlobalPause(address indexed guardian);
    event GlobalUnpause(address indexed guardian);
    event MarketCircuitBreakerTripped(bytes32 indexed marketId, address indexed triggeredBy);
    event MarketCircuitBreakerReset(bytes32 indexed marketId, address indexed resetBy);
    event GlobalCircuitBreakerTripped(address indexed triggeredBy);
    event GlobalCircuitBreakerReset(address indexed resetBy);
    event GuardianAdded(address indexed guardian);
    event GuardianRemoved(address indexed guardian);
    event CooldownUpdated(uint256 newCooldown);

    // ============ Modifiers ============

    modifier onlyGuardian() {
        if (!guardians[msg.sender] && msg.sender != owner()) {
            revert Errors.NotGuardian();
        }
        _;
    }

    // ============ Constructor ============

    constructor(address _marketRegistry) Ownable(msg.sender) {
        if (_marketRegistry == address(0)) {
            revert Errors.ZeroAddress();
        }
        marketRegistry = MarketRegistry(_marketRegistry);
    }

    // ============ Admin Functions ============

    /**
     * @notice Add a guardian
     * @param guardian The address to add
     */
    function addGuardian(address guardian) external onlyOwner {
        if (guardian == address(0)) {
            revert Errors.ZeroAddress();
        }
        guardians[guardian] = true;
        emit GuardianAdded(guardian);
    }

    /**
     * @notice Remove a guardian
     * @param guardian The address to remove
     */
    function removeGuardian(address guardian) external onlyOwner {
        guardians[guardian] = false;
        emit GuardianRemoved(guardian);
    }

    /**
     * @notice Update circuit breaker cooldown period
     * @param newCooldown New cooldown in seconds
     */
    function updateCooldown(uint256 newCooldown) external onlyOwner {
        circuitBreakerCooldown = newCooldown;
        emit CooldownUpdated(newCooldown);
    }

    // ============ Guardian Functions ============

    /**
     * @notice Pause all protocol operations
     */
    function pauseProtocol() external onlyGuardian {
        _pause();
        emit GlobalPause(msg.sender);
    }

    /**
     * @notice Unpause protocol operations
     */
    function unpauseProtocol() external onlyGuardian {
        _unpause();
        emit GlobalUnpause(msg.sender);
    }

    /**
     * @notice Trip the circuit breaker for a specific market
     * @param marketId The market to trip
     */
    function tripMarketCircuitBreaker(bytes32 marketId) external onlyGuardian {
        circuitBreakerTrippedAt[marketId] = block.timestamp;
        emit MarketCircuitBreakerTripped(marketId, msg.sender);
    }

    /**
     * @notice Reset the circuit breaker for a specific market
     * @param marketId The market to reset
     */
    function resetMarketCircuitBreaker(bytes32 marketId) external onlyGuardian {
        circuitBreakerTrippedAt[marketId] = 0;
        emit MarketCircuitBreakerReset(marketId, msg.sender);
    }

    /**
     * @notice Trip the global circuit breaker
     */
    function tripGlobalCircuitBreaker() external onlyGuardian {
        globalCircuitBreakerActive = true;
        emit GlobalCircuitBreakerTripped(msg.sender);
    }

    /**
     * @notice Reset the global circuit breaker
     */
    function resetGlobalCircuitBreaker() external onlyGuardian {
        globalCircuitBreakerActive = false;
        emit GlobalCircuitBreakerReset(msg.sender);
    }

    // ============ Check Functions ============

    /**
     * @notice Check if operations are allowed (not paused, no global circuit breaker)
     * @dev Reverts if operations should be blocked
     */
    function checkGlobalState() external view {
        if (paused()) {
            revert Errors.ContractPaused();
        }
        if (globalCircuitBreakerActive) {
            revert Errors.CircuitBreakerTripped();
        }
    }

    /**
     * @notice Check if a market is in pre-resolution freeze
     * @param marketId The market to check
     * @return True if in freeze period
     */
    function isInPreResolutionFreeze(bytes32 marketId) public view returns (bool) {
        DataTypes.Market memory market = marketRegistry.getMarket(marketId);

        if (!market.isRegistered) {
            return false;
        }

        if (block.timestamp >= market.resolutionTime) {
            return true; // Market has resolved
        }

        uint256 timeToResolution = market.resolutionTime - block.timestamp;
        return timeToResolution < PRE_RESOLUTION_FREEZE;
    }

    /**
     * @notice Check if market circuit breaker is active
     * @param marketId The market to check
     * @return True if circuit breaker is tripped and cooldown hasn't passed
     */
    function isMarketCircuitBreakerActive(bytes32 marketId) public view returns (bool) {
        uint256 trippedAt = circuitBreakerTrippedAt[marketId];
        if (trippedAt == 0) {
            return false;
        }
        return block.timestamp < trippedAt + circuitBreakerCooldown;
    }

    /**
     * @notice Check if borrowing is allowed for a market
     * @param marketId The market to check
     * @return allowed True if borrowing is allowed
     * @return reason Reason code if not allowed (0=allowed, 1=paused, 2=global_cb, 3=market_cb, 4=pre_resolution, 5=frozen)
     */
    function canBorrow(bytes32 marketId) external view returns (bool allowed, uint8 reason) {
        if (paused()) {
            return (false, 1);
        }
        if (globalCircuitBreakerActive) {
            return (false, 2);
        }
        if (isMarketCircuitBreakerActive(marketId)) {
            return (false, 3);
        }
        if (isInPreResolutionFreeze(marketId)) {
            return (false, 4);
        }

        DataTypes.Market memory market = marketRegistry.getMarket(marketId);
        if (market.isFrozen) {
            return (false, 5);
        }

        return (true, 0);
    }

    /**
     * @notice Check if liquidations are allowed for a market
     * @param marketId The market to check
     * @return True if liquidations are allowed
     */
    function canLiquidate(bytes32 marketId) external view returns (bool) {
        // Liquidations are always allowed unless globally paused
        // Even in pre-resolution freeze, liquidations should proceed
        return !paused();
    }

    /**
     * @notice Check if withdrawals are allowed
     * @return True if withdrawals are allowed
     */
    function canWithdraw() external view returns (bool) {
        return !paused();
    }

    /**
     * @notice Check if repayments are allowed
     * @return True if repayments are allowed
     */
    function canRepay() external view returns (bool) {
        // Repayments should always be allowed, even when paused
        return true;
    }

    // ============ View Functions ============

    /**
     * @notice Check if an address is a guardian
     * @param account The address to check
     * @return True if guardian
     */
    function isGuardian(address account) external view returns (bool) {
        return guardians[account];
    }

    /**
     * @notice Get the status of all circuit breakers
     * @return _paused Whether protocol is paused
     * @return _globalCB Whether global circuit breaker is active
     */
    function getGlobalStatus() external view returns (bool _paused, bool _globalCB) {
        return (paused(), globalCircuitBreakerActive);
    }

    /**
     * @notice Get detailed market status
     * @param marketId The market to check
     * @return isPreResolutionFreeze Whether in pre-resolution freeze
     * @return isCircuitBreakerActive Whether market circuit breaker is active
     * @return circuitBreakerTripped Timestamp when circuit breaker was tripped
     * @return timeToResolution Time until market resolution
     */
    function getMarketStatus(bytes32 marketId) external view returns (
        bool isPreResolutionFreeze,
        bool isCircuitBreakerActive,
        uint256 circuitBreakerTripped,
        uint256 timeToResolution
    ) {
        isPreResolutionFreeze = isInPreResolutionFreeze(marketId);
        isCircuitBreakerActive = isMarketCircuitBreakerActive(marketId);
        circuitBreakerTripped = circuitBreakerTrippedAt[marketId];

        DataTypes.Market memory market = marketRegistry.getMarket(marketId);
        if (market.isRegistered && block.timestamp < market.resolutionTime) {
            timeToResolution = market.resolutionTime - block.timestamp;
        }
    }
}
