// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../libraries/DataTypes.sol";

/**
 * @title IVault
 * @notice Interface for the collateral vault that holds ERC-1155 conditional tokens
 */
interface IVault {
    /**
     * @notice Emitted when collateral is deposited
     * @param user The depositor address
     * @param tokenId The ERC-1155 token ID
     * @param amount The amount deposited
     * @param marketId The associated market condition ID
     */
    event CollateralDeposited(
        address indexed user,
        uint256 indexed tokenId,
        uint256 amount,
        bytes32 indexed marketId
    );

    /**
     * @notice Emitted when collateral is withdrawn
     * @param user The withdrawer address
     * @param tokenId The ERC-1155 token ID
     * @param amount The amount withdrawn
     */
    event CollateralWithdrawn(
        address indexed user,
        uint256 indexed tokenId,
        uint256 amount
    );

    /**
     * @notice Emitted when collateral is transferred to liquidator
     * @param from The original owner
     * @param to The liquidator
     * @param tokenId The ERC-1155 token ID
     * @param amount The amount transferred
     */
    event CollateralSeized(
        address indexed from,
        address indexed to,
        uint256 indexed tokenId,
        uint256 amount
    );

    /**
     * @notice Deposit ERC-1155 collateral
     * @param tokenId The token ID to deposit
     * @param amount The amount to deposit
     * @param marketId The associated market condition ID
     */
    function depositCollateral(
        uint256 tokenId,
        uint256 amount,
        bytes32 marketId
    ) external;

    /**
     * @notice Withdraw ERC-1155 collateral
     * @param tokenId The token ID to withdraw
     * @param amount The amount to withdraw
     */
    function withdrawCollateral(uint256 tokenId, uint256 amount) external;

    /**
     * @notice Transfer collateral from borrower to liquidator during liquidation
     * @param from The borrower being liquidated
     * @param to The liquidator receiving collateral
     * @param tokenId The token ID to transfer
     * @param amount The amount to transfer
     */
    function transferCollateralToLiquidator(
        address from,
        address to,
        uint256 tokenId,
        uint256 amount
    ) external;

    /**
     * @notice Get collateral balance for a user and token
     * @param user The user address
     * @param tokenId The token ID
     * @return The collateral amount
     */
    function getCollateralBalance(address user, uint256 tokenId) external view returns (uint256);

    /**
     * @notice Get full collateral info for a user and token
     * @param user The user address
     * @param tokenId The token ID
     * @return The collateral information
     */
    function getCollateralInfo(
        address user,
        uint256 tokenId
    ) external view returns (DataTypes.CollateralInfo memory);

    /**
     * @notice Get total collateral held in vault for a token
     * @param tokenId The token ID
     * @return The total amount held
     */
    function getTotalCollateral(uint256 tokenId) external view returns (uint256);

    /**
     * @notice Get the CTF contract address
     * @return The conditional token framework contract address
     */
    function ctf() external view returns (address);
}
