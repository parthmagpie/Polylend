// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockCTF
 * @notice Mock Conditional Token Framework for testing
 * @dev Simulates Polymarket's ERC-1155 conditional tokens
 */
contract MockCTF is ERC1155, Ownable {
    /// @notice Mapping from condition ID to whether it has been resolved
    mapping(bytes32 => bool) public isConditionResolved;

    /// @notice Mapping from condition ID to payout numerators
    mapping(bytes32 => uint256[]) public payoutNumerators;

    /// @notice Mapping from condition ID to payout denominator
    mapping(bytes32 => uint256) public payoutDenominator;

    /// @notice Next token ID to mint
    uint256 public nextTokenId;

    /// @notice Mapping from token ID to condition ID
    mapping(uint256 => bytes32) public tokenConditions;

    /// @notice Mapping from token ID to outcome index
    mapping(uint256 => uint256) public tokenOutcomes;

    constructor() ERC1155("https://polymarket.com/token/{id}") Ownable(msg.sender) {}

    /**
     * @notice Prepare a condition for conditional tokens
     * @param conditionId The unique condition identifier
     * @param outcomeSlotCount Number of outcome slots
     */
    function prepareCondition(bytes32 conditionId, uint256 outcomeSlotCount) external {
        require(outcomeSlotCount >= 2, "Need at least 2 outcomes");
        payoutNumerators[conditionId] = new uint256[](outcomeSlotCount);
        payoutDenominator[conditionId] = 1;
    }

    /**
     * @notice Mint conditional tokens for testing
     * @param to Recipient address
     * @param conditionId The condition these tokens are tied to
     * @param outcomeIndex The outcome index (0 for YES, 1 for NO typically)
     * @param amount Amount to mint
     * @return tokenId The ID of the minted tokens
     */
    function mintConditionalTokens(
        address to,
        bytes32 conditionId,
        uint256 outcomeIndex,
        uint256 amount
    ) external returns (uint256 tokenId) {
        tokenId = nextTokenId++;
        tokenConditions[tokenId] = conditionId;
        tokenOutcomes[tokenId] = outcomeIndex;
        _mint(to, tokenId, amount, "");
    }

    /**
     * @notice Mint tokens with a specific ID (for deterministic testing)
     * @param to Recipient address
     * @param tokenId The specific token ID to mint
     * @param conditionId The condition these tokens are tied to
     * @param outcomeIndex The outcome index
     * @param amount Amount to mint
     */
    function mintWithId(
        address to,
        uint256 tokenId,
        bytes32 conditionId,
        uint256 outcomeIndex,
        uint256 amount
    ) external {
        tokenConditions[tokenId] = conditionId;
        tokenOutcomes[tokenId] = outcomeIndex;
        _mint(to, tokenId, amount, "");
    }

    /**
     * @notice Resolve a condition (simulate market resolution)
     * @param conditionId The condition to resolve
     * @param payouts Array of payout weights for each outcome
     */
    function resolveCondition(bytes32 conditionId, uint256[] calldata payouts) external onlyOwner {
        require(!isConditionResolved[conditionId], "Already resolved");
        require(payouts.length == payoutNumerators[conditionId].length, "Invalid payouts length");

        uint256 totalPayout;
        for (uint256 i = 0; i < payouts.length; i++) {
            totalPayout += payouts[i];
        }
        require(totalPayout > 0, "Invalid payouts");

        payoutNumerators[conditionId] = payouts;
        payoutDenominator[conditionId] = totalPayout;
        isConditionResolved[conditionId] = true;
    }

    /**
     * @notice Get the condition ID for a token
     * @param tokenId The token ID
     * @return The associated condition ID
     */
    function getConditionId(uint256 tokenId) external view returns (bytes32) {
        return tokenConditions[tokenId];
    }

    /**
     * @notice Get the outcome index for a token
     * @param tokenId The token ID
     * @return The outcome index
     */
    function getOutcomeIndex(uint256 tokenId) external view returns (uint256) {
        return tokenOutcomes[tokenId];
    }

    /**
     * @notice Check if a condition has been resolved
     * @param conditionId The condition ID to check
     * @return True if resolved
     */
    function isResolved(bytes32 conditionId) external view returns (bool) {
        return isConditionResolved[conditionId];
    }

    /**
     * @notice Get the payout for a specific outcome after resolution
     * @param conditionId The condition ID
     * @param outcomeIndex The outcome index
     * @return numerator The payout numerator
     * @return denominator The payout denominator
     */
    function getPayoutForOutcome(
        bytes32 conditionId,
        uint256 outcomeIndex
    ) external view returns (uint256 numerator, uint256 denominator) {
        require(isConditionResolved[conditionId], "Not resolved");
        require(outcomeIndex < payoutNumerators[conditionId].length, "Invalid outcome");
        return (payoutNumerators[conditionId][outcomeIndex], payoutDenominator[conditionId]);
    }

    /**
     * @notice Burn tokens (simulate redemption)
     * @param from Address to burn from
     * @param tokenId Token ID to burn
     * @param amount Amount to burn
     */
    function burn(address from, uint256 tokenId, uint256 amount) external {
        require(
            from == msg.sender || isApprovedForAll(from, msg.sender),
            "Not authorized"
        );
        _burn(from, tokenId, amount);
    }
}
