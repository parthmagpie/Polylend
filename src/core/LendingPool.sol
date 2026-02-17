// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../libraries/DataTypes.sol";
import "../libraries/Errors.sol";
import "../libraries/PercentageMath.sol";
import "../interfaces/ILendingPool.sol";

/**
 * @title LendingPool
 * @notice Manages USDC liquidity from lenders
 * @dev Implements a share-based system for tracking lender deposits
 *
 * Lenders deposit USDC and receive shares proportional to the pool value.
 * As borrowers pay interest, the share value increases.
 */
contract LendingPool is ILendingPool, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    using PercentageMath for uint256;

    // ============ Constants ============

    /// @notice Initial share ratio (1:1 with USDC)
    uint256 public constant INITIAL_SHARE_RATIO = 1e6;

    /// @notice Minimum deposit amount (1 USDC)
    uint256 public constant MIN_DEPOSIT = 1e6;

    // ============ Storage ============

    /// @notice The USDC token contract
    address public immutable override usdc;

    /// @notice The main PolyLend contract (authorized to disburse loans)
    address public polyLend;

    /// @notice Pool state
    DataTypes.PoolState public poolState;

    /// @notice Share balances per lender
    mapping(address => uint256) public shares;

    // ============ Events ============

    event PolyLendSet(address indexed polyLend);

    // ============ Modifiers ============

    modifier onlyPolyLend() {
        if (msg.sender != polyLend) {
            revert Errors.NotLendingPool();
        }
        _;
    }

    // ============ Constructor ============

    /**
     * @notice Initialize the lending pool with USDC address
     * @param _usdc The USDC token contract address
     */
    constructor(address _usdc) Ownable(msg.sender) {
        if (_usdc == address(0)) {
            revert Errors.ZeroAddress();
        }
        usdc = _usdc;

        poolState = DataTypes.PoolState({
            totalDeposits: 0,
            totalBorrows: 0,
            totalShares: 0,
            lastUpdateTimestamp: block.timestamp
        });
    }

    // ============ Admin Functions ============

    /**
     * @notice Set the PolyLend contract address
     * @param _polyLend The PolyLend contract address
     */
    function setPolyLend(address _polyLend) external onlyOwner {
        if (_polyLend == address(0)) {
            revert Errors.ZeroAddress();
        }
        polyLend = _polyLend;
        emit PolyLendSet(_polyLend);
    }

    // ============ Lender Functions ============

    /**
     * @notice Deposit USDC to earn yield
     * @param amount The amount of USDC to deposit
     * @return mintedShares The number of shares minted
     */
    function deposit(uint256 amount) external override nonReentrant returns (uint256 mintedShares) {
        if (amount < MIN_DEPOSIT) {
            revert Errors.ZeroAmount();
        }

        // Calculate shares to mint
        mintedShares = amountToShares(amount);
        if (mintedShares == 0) {
            revert Errors.ZeroAmount();
        }

        // Transfer USDC from lender
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), amount);

        // Update state
        shares[msg.sender] += mintedShares;
        poolState.totalShares += mintedShares;
        poolState.totalDeposits += amount;
        poolState.lastUpdateTimestamp = block.timestamp;

        emit Deposited(msg.sender, amount, mintedShares);
    }

    /**
     * @notice Withdraw USDC by burning shares
     * @param shareAmount The number of shares to burn
     * @return amount The USDC amount withdrawn
     */
    function withdraw(uint256 shareAmount) external override nonReentrant returns (uint256 amount) {
        if (shareAmount == 0) {
            revert Errors.ZeroAmount();
        }

        if (shares[msg.sender] < shareAmount) {
            revert Errors.InsufficientShares(shares[msg.sender], shareAmount);
        }

        // Calculate USDC amount
        amount = sharesToAmount(shareAmount);

        // Check liquidity
        uint256 available = getAvailableLiquidity();
        if (amount > available) {
            revert Errors.InsufficientLiquidity(available, amount);
        }

        // Update state
        shares[msg.sender] -= shareAmount;
        poolState.totalShares -= shareAmount;
        poolState.totalDeposits -= amount;
        poolState.lastUpdateTimestamp = block.timestamp;

        // Transfer USDC to lender
        IERC20(usdc).safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount, shareAmount);
    }

    // ============ Loan Functions (called by PolyLend) ============

    /**
     * @notice Disburse a loan to a borrower
     * @param borrower The borrower address
     * @param amount The amount to lend
     */
    function disburseLoan(address borrower, uint256 amount) external override nonReentrant onlyPolyLend {
        if (amount == 0) {
            revert Errors.ZeroAmount();
        }
        if (borrower == address(0)) {
            revert Errors.ZeroAddress();
        }

        uint256 available = getAvailableLiquidity();
        if (amount > available) {
            revert Errors.InsufficientLiquidity(available, amount);
        }

        // Update state
        poolState.totalBorrows += amount;
        poolState.lastUpdateTimestamp = block.timestamp;

        // Transfer USDC to borrower
        IERC20(usdc).safeTransfer(borrower, amount);

        emit LoanDisbursed(borrower, amount);
    }

    /**
     * @notice Receive loan repayment
     * @param borrower The borrower address
     * @param amount The amount being repaid
     */
    function receiveLoanRepayment(
        address borrower,
        uint256 amount
    ) external override nonReentrant onlyPolyLend {
        if (amount == 0) {
            revert Errors.ZeroAmount();
        }

        // Transfer USDC from PolyLend (which collected it from borrower)
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), amount);

        // Update state - handle overpayment edge case
        if (amount > poolState.totalBorrows) {
            // Interest payment increases deposits
            uint256 interest = amount - poolState.totalBorrows;
            poolState.totalDeposits += interest;
            poolState.totalBorrows = 0;
        } else {
            poolState.totalBorrows -= amount;
        }
        poolState.lastUpdateTimestamp = block.timestamp;

        emit LoanRepayment(borrower, amount);
    }

    /**
     * @notice Direct repayment function for simple cases
     * @param amount The amount being repaid
     */
    function receiveRepayment(uint256 amount) external nonReentrant {
        if (amount == 0) {
            revert Errors.ZeroAmount();
        }

        // Transfer USDC from sender
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), amount);

        // Update state
        if (amount > poolState.totalBorrows) {
            uint256 interest = amount - poolState.totalBorrows;
            poolState.totalDeposits += interest;
            poolState.totalBorrows = 0;
        } else {
            poolState.totalBorrows -= amount;
        }
        poolState.lastUpdateTimestamp = block.timestamp;

        emit LoanRepayment(msg.sender, amount);
    }

    // ============ View Functions ============

    /**
     * @notice Get the current pool state
     * @return state The pool state struct
     */
    function getPoolState() external view override returns (DataTypes.PoolState memory state) {
        return poolState;
    }

    /**
     * @notice Get available liquidity for borrowing
     * @return The available USDC amount
     */
    function getAvailableLiquidity() public view override returns (uint256) {
        return IERC20(usdc).balanceOf(address(this));
    }

    /**
     * @notice Get the current utilization rate
     * @return Utilization rate in basis points
     */
    function getUtilizationRate() external view override returns (uint256) {
        if (poolState.totalDeposits == 0) {
            return 0;
        }
        return (poolState.totalBorrows * PercentageMath.BPS) / poolState.totalDeposits;
    }

    /**
     * @notice Get share balance of a lender
     * @param lender The lender address
     * @return The share balance
     */
    function sharesOf(address lender) external view override returns (uint256) {
        return shares[lender];
    }

    /**
     * @notice Convert shares to USDC amount
     * @param shareAmount The number of shares
     * @return The equivalent USDC amount
     */
    function sharesToAmount(uint256 shareAmount) public view override returns (uint256) {
        if (poolState.totalShares == 0) {
            return shareAmount;
        }
        // Total pool value = deposits (including earned interest)
        uint256 totalValue = poolState.totalDeposits;
        return (shareAmount * totalValue) / poolState.totalShares;
    }

    /**
     * @notice Convert USDC amount to shares
     * @param amount The USDC amount
     * @return The equivalent shares
     */
    function amountToShares(uint256 amount) public view override returns (uint256) {
        if (poolState.totalShares == 0 || poolState.totalDeposits == 0) {
            // Initial deposit: 1:1 ratio
            return amount;
        }
        return (amount * poolState.totalShares) / poolState.totalDeposits;
    }

    /**
     * @notice Get the current share price (USDC per share, scaled by 1e6)
     * @return The share price
     */
    function getSharePrice() external view returns (uint256) {
        if (poolState.totalShares == 0) {
            return INITIAL_SHARE_RATIO;
        }
        return (poolState.totalDeposits * 1e6) / poolState.totalShares;
    }

    /**
     * @notice Get total value locked in the pool
     * @return The total USDC value
     */
    function getTotalValueLocked() external view returns (uint256) {
        return poolState.totalDeposits;
    }
}
