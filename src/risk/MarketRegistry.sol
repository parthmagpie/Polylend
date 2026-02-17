// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../libraries/DataTypes.sol";
import "../libraries/Errors.sol";

/**
 * @title MarketRegistry
 * @notice Registry for Polymarket markets and their metadata
 * @dev Tracks market configuration, resolution times, and freeze status
 */
contract MarketRegistry is Ownable {
    // ============ Storage ============

    /// @notice Mapping from condition ID to market configuration
    mapping(bytes32 => DataTypes.Market) public markets;

    /// @notice Mapping from token ID to market condition ID
    mapping(uint256 => bytes32) public tokenToMarket;

    /// @notice List of all registered market IDs
    bytes32[] public marketIds;

    /// @notice Guardians who can freeze markets
    mapping(address => bool) public guardians;

    // ============ Events ============

    event MarketRegistered(
        bytes32 indexed conditionId,
        uint256 resolutionTime,
        uint8 outcomeCount
    );

    event MarketUpdated(bytes32 indexed conditionId, uint256 newResolutionTime);

    event MarketFrozen(bytes32 indexed conditionId, address indexed guardian);

    event MarketUnfrozen(bytes32 indexed conditionId, address indexed guardian);

    event TokenMapped(uint256 indexed tokenId, bytes32 indexed conditionId);

    event GuardianAdded(address indexed guardian);

    event GuardianRemoved(address indexed guardian);

    // ============ Modifiers ============

    modifier onlyGuardian() {
        if (!guardians[msg.sender] && msg.sender != owner()) {
            revert Errors.NotGuardian();
        }
        _;
    }

    // ============ Constructor ============

    constructor() Ownable(msg.sender) {}

    // ============ Admin Functions ============

    /**
     * @notice Register a new Polymarket market
     * @param conditionId The unique condition identifier
     * @param resolutionTime Expected resolution timestamp
     * @param outcomeCount Number of outcomes (typically 2)
     */
    function registerMarket(
        bytes32 conditionId,
        uint256 resolutionTime,
        uint8 outcomeCount
    ) external onlyOwner {
        if (markets[conditionId].isRegistered) {
            revert Errors.MarketAlreadyRegistered(conditionId);
        }
        if (resolutionTime <= block.timestamp) {
            revert Errors.InvalidResolutionTime();
        }
        if (outcomeCount < 2) {
            revert Errors.InvalidResolutionTime(); // Reusing error for invalid config
        }

        markets[conditionId] = DataTypes.Market({
            conditionId: conditionId,
            resolutionTime: resolutionTime,
            isFrozen: false,
            isRegistered: true,
            outcomeCount: outcomeCount
        });

        marketIds.push(conditionId);

        emit MarketRegistered(conditionId, resolutionTime, outcomeCount);
    }

    /**
     * @notice Update the resolution time for a market
     * @param conditionId The market condition ID
     * @param newResolutionTime The new resolution timestamp
     */
    function updateResolutionTime(
        bytes32 conditionId,
        uint256 newResolutionTime
    ) external onlyOwner {
        if (!markets[conditionId].isRegistered) {
            revert Errors.MarketNotRegistered(conditionId);
        }
        if (newResolutionTime <= block.timestamp) {
            revert Errors.InvalidResolutionTime();
        }

        markets[conditionId].resolutionTime = newResolutionTime;

        emit MarketUpdated(conditionId, newResolutionTime);
    }

    /**
     * @notice Map a token ID to a market condition
     * @param tokenId The ERC-1155 token ID
     * @param conditionId The market condition ID
     */
    function mapTokenToMarket(uint256 tokenId, bytes32 conditionId) external onlyOwner {
        if (!markets[conditionId].isRegistered) {
            revert Errors.MarketNotRegistered(conditionId);
        }

        tokenToMarket[tokenId] = conditionId;

        emit TokenMapped(tokenId, conditionId);
    }

    /**
     * @notice Batch map multiple tokens to markets
     * @param tokenIds Array of token IDs
     * @param conditionIds Array of corresponding condition IDs
     */
    function batchMapTokens(
        uint256[] calldata tokenIds,
        bytes32[] calldata conditionIds
    ) external onlyOwner {
        if (tokenIds.length != conditionIds.length) {
            revert Errors.ArrayLengthMismatch();
        }

        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (!markets[conditionIds[i]].isRegistered) {
                revert Errors.MarketNotRegistered(conditionIds[i]);
            }
            tokenToMarket[tokenIds[i]] = conditionIds[i];
            emit TokenMapped(tokenIds[i], conditionIds[i]);
        }
    }

    /**
     * @notice Add a guardian
     * @param guardian The address to add as guardian
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

    // ============ Guardian Functions ============

    /**
     * @notice Freeze a market (blocks new borrows)
     * @param conditionId The market to freeze
     */
    function freezeMarket(bytes32 conditionId) external onlyGuardian {
        if (!markets[conditionId].isRegistered) {
            revert Errors.MarketNotRegistered(conditionId);
        }

        markets[conditionId].isFrozen = true;

        emit MarketFrozen(conditionId, msg.sender);
    }

    /**
     * @notice Unfreeze a market
     * @param conditionId The market to unfreeze
     */
    function unfreezeMarket(bytes32 conditionId) external onlyGuardian {
        if (!markets[conditionId].isRegistered) {
            revert Errors.MarketNotRegistered(conditionId);
        }

        markets[conditionId].isFrozen = false;

        emit MarketUnfrozen(conditionId, msg.sender);
    }

    // ============ View Functions ============

    /**
     * @notice Get market configuration
     * @param conditionId The market condition ID
     * @return The market struct
     */
    function getMarket(bytes32 conditionId) external view returns (DataTypes.Market memory) {
        return markets[conditionId];
    }

    /**
     * @notice Get the market for a token ID
     * @param tokenId The ERC-1155 token ID
     * @return The market struct
     */
    function getMarketForToken(uint256 tokenId) external view returns (DataTypes.Market memory) {
        bytes32 conditionId = tokenToMarket[tokenId];
        return markets[conditionId];
    }

    /**
     * @notice Check if a market is registered
     * @param conditionId The market condition ID
     * @return True if registered
     */
    function isMarketRegistered(bytes32 conditionId) external view returns (bool) {
        return markets[conditionId].isRegistered;
    }

    /**
     * @notice Check if a market is frozen
     * @param conditionId The market condition ID
     * @return True if frozen
     */
    function isMarketFrozen(bytes32 conditionId) external view returns (bool) {
        return markets[conditionId].isFrozen;
    }

    /**
     * @notice Get time remaining until resolution
     * @param conditionId The market condition ID
     * @return Time in seconds (0 if already resolved)
     */
    function getTimeToResolution(bytes32 conditionId) external view returns (uint256) {
        uint256 resolutionTime = markets[conditionId].resolutionTime;
        if (block.timestamp >= resolutionTime) {
            return 0;
        }
        return resolutionTime - block.timestamp;
    }

    /**
     * @notice Get the total number of registered markets
     * @return The count
     */
    function getMarketCount() external view returns (uint256) {
        return marketIds.length;
    }

    /**
     * @notice Check if an address is a guardian
     * @param account The address to check
     * @return True if guardian
     */
    function isGuardian(address account) external view returns (bool) {
        return guardians[account];
    }
}
