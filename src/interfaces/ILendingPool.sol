// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../libraries/DataTypes.sol";

/**
 * @title ILendingPool
 * @notice Interface for the USDC lending pool
 */
interface ILendingPool {
    /**
     * @notice Emitted when a lender deposits USDC
     * @param lender The depositor address
     * @param amount The USDC amount deposited
     * @param shares The shares minted to the lender
     */
    event Deposited(address indexed lender, uint256 amount, uint256 shares);

    /**
     * @notice Emitted when a lender withdraws USDC
     * @param lender The withdrawer address
     * @param amount The USDC amount withdrawn
     * @param shares The shares burned
     */
    event Withdrawn(address indexed lender, uint256 amount, uint256 shares);

    /**
     * @notice Emitted when a loan is disbursed
     * @param borrower The borrower address
     * @param amount The USDC amount lent
     */
    event LoanDisbursed(address indexed borrower, uint256 amount);

    /**
     * @notice Emitted when a loan repayment is received
     * @param borrower The borrower address
     * @param amount The USDC amount repaid
     */
    event LoanRepayment(address indexed borrower, uint256 amount);

    /**
     * @notice Deposit USDC to earn yield
     * @param amount The amount of USDC to deposit
     * @return shares The number of shares minted
     */
    function deposit(uint256 amount) external returns (uint256 shares);

    /**
     * @notice Withdraw USDC by burning shares
     * @param shares The number of shares to burn
     * @return amount The USDC amount withdrawn
     */
    function withdraw(uint256 shares) external returns (uint256 amount);

    /**
     * @notice Disburse a loan to a borrower (called by PolyLend)
     * @param borrower The borrower address
     * @param amount The amount to lend
     */
    function disburseLoan(address borrower, uint256 amount) external;

    /**
     * @notice Receive loan repayment (called by PolyLend)
     * @param borrower The borrower address
     * @param amount The amount being repaid
     */
    function receiveLoanRepayment(address borrower, uint256 amount) external;

    /**
     * @notice Get the current pool state
     * @return state The pool state struct
     */
    function getPoolState() external view returns (DataTypes.PoolState memory state);

    /**
     * @notice Get available liquidity for borrowing
     * @return The available USDC amount
     */
    function getAvailableLiquidity() external view returns (uint256);

    /**
     * @notice Get the current utilization rate
     * @return Utilization rate in basis points
     */
    function getUtilizationRate() external view returns (uint256);

    /**
     * @notice Get share balance of a lender
     * @param lender The lender address
     * @return The share balance
     */
    function sharesOf(address lender) external view returns (uint256);

    /**
     * @notice Convert shares to USDC amount
     * @param shares The number of shares
     * @return The equivalent USDC amount
     */
    function sharesToAmount(uint256 shares) external view returns (uint256);

    /**
     * @notice Convert USDC amount to shares
     * @param amount The USDC amount
     * @return The equivalent shares
     */
    function amountToShares(uint256 amount) external view returns (uint256);

    /**
     * @notice Get the USDC token address
     * @return The USDC contract address
     */
    function usdc() external view returns (address);
}
