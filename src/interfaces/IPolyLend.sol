// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../libraries/DataTypes.sol";

/**
 * @title IPolyLend
 * @notice Main interface for the PolyLend protocol
 */
interface IPolyLend {
    // ============ Events ============

    /**
     * @notice Emitted when collateral is deposited
     */
    event CollateralDeposited(
        address indexed user,
        uint256 indexed tokenId,
        uint256 amount,
        bytes32 indexed marketId
    );

    /**
     * @notice Emitted when collateral is withdrawn
     */
    event CollateralWithdrawn(
        address indexed user,
        uint256 indexed tokenId,
        uint256 amount
    );

    /**
     * @notice Emitted when a user borrows USDC
     */
    event Borrowed(
        address indexed borrower,
        uint256 indexed tokenId,
        uint256 amount
    );

    /**
     * @notice Emitted when a user repays their loan
     */
    event Repaid(
        address indexed borrower,
        uint256 indexed tokenId,
        uint256 amount
    );

    /**
     * @notice Emitted when a position is liquidated
     */
    event Liquidated(
        address indexed liquidator,
        address indexed borrower,
        uint256 indexed tokenId,
        uint256 debtRepaid,
        uint256 collateralSeized
    );

    // ============ Borrower Functions ============

    /**
     * @notice Deposit ERC-1155 conditional tokens as collateral
     * @param tokenId The ERC-1155 token ID
     * @param amount The amount to deposit
     * @param marketId The Polymarket condition ID
     */
    function depositCollateral(
        uint256 tokenId,
        uint256 amount,
        bytes32 marketId
    ) external;

    /**
     * @notice Withdraw collateral (if health factor allows)
     * @param tokenId The ERC-1155 token ID
     * @param amount The amount to withdraw
     */
    function withdrawCollateral(uint256 tokenId, uint256 amount) external;

    /**
     * @notice Borrow USDC against deposited collateral
     * @param tokenId The collateral token ID
     * @param amount The amount of USDC to borrow
     */
    function borrow(uint256 tokenId, uint256 amount) external;

    /**
     * @notice Repay borrowed USDC
     * @param tokenId The collateral token ID
     * @param amount The amount to repay
     */
    function repay(uint256 tokenId, uint256 amount) external;

    // ============ Liquidator Functions ============

    /**
     * @notice Liquidate an unhealthy position
     * @param borrower The borrower to liquidate
     * @param tokenId The collateral token ID
     * @param repayAmount The amount of debt to repay
     * @return collateralSeized The amount of collateral received
     */
    function liquidate(
        address borrower,
        uint256 tokenId,
        uint256 repayAmount
    ) external returns (uint256 collateralSeized);

    // ============ Lender Functions ============

    /**
     * @notice Deposit USDC to earn yield
     * @param amount The amount of USDC to deposit
     * @return shares The number of shares received
     */
    function deposit(uint256 amount) external returns (uint256 shares);

    /**
     * @notice Withdraw USDC by burning shares
     * @param shares The number of shares to burn
     * @return amount The USDC amount withdrawn
     */
    function withdraw(uint256 shares) external returns (uint256 amount);

    // ============ View Functions ============

    /**
     * @notice Get a user's position for a specific collateral
     * @param user The user address
     * @param tokenId The collateral token ID
     * @return The position struct
     */
    function getPosition(
        address user,
        uint256 tokenId
    ) external view returns (DataTypes.Position memory);

    /**
     * @notice Get the health factor of a position
     * @param user The user address
     * @param tokenId The collateral token ID
     * @return The health factor (1e18 = 1.0)
     */
    function getHealthFactor(address user, uint256 tokenId) external view returns (uint256);

    /**
     * @notice Get the maximum borrowable amount for a position
     * @param user The user address
     * @param tokenId The collateral token ID
     * @return The maximum additional USDC that can be borrowed
     */
    function getMaxBorrowAmount(address user, uint256 tokenId) external view returns (uint256);

    /**
     * @notice Check if a position can be liquidated
     * @param user The user address
     * @param tokenId The collateral token ID
     * @return True if the position is liquidatable
     */
    function isLiquidatable(address user, uint256 tokenId) external view returns (bool);

    /**
     * @notice Get the current LTV for a market
     * @param marketId The market condition ID
     * @return The current max LTV in basis points
     */
    function getCurrentLTV(bytes32 marketId) external view returns (uint256);
}
