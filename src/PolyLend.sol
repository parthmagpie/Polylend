// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./libraries/DataTypes.sol";
import "./libraries/Errors.sol";
import "./libraries/PercentageMath.sol";
import "./interfaces/IPolyLend.sol";
import "./interfaces/IVault.sol";
import "./interfaces/ILendingPool.sol";
import "./interfaces/ILiquidationEngine.sol";
import "./interfaces/IPolymarketOracle.sol";
import "./risk/MarketRegistry.sol";
import "./risk/LTVCalculator.sol";
import "./risk/CircuitBreaker.sol";
import "./core/Vault.sol";
import "./core/LendingPool.sol";
import "./core/LiquidationEngine.sol";
import "./oracle/PolymarketTWAPOracle.sol";

/**
 * @title PolyLend
 * @notice Main entry point for the PolyLend decentralized lending protocol
 * @dev Orchestrates all protocol modules: Vault, LendingPool, LiquidationEngine, Oracle, and Risk
 *
 * PolyLend enables Polymarket traders to borrow USDC against their conditional token positions.
 *
 * Key Features:
 * - Deposit ERC-1155 conditional tokens as collateral
 * - Borrow USDC against collateral value
 * - Time-decay LTV based on market resolution proximity
 * - TWAP oracle with circuit breaker protection
 * - Liquidation system with bonus incentives
 */
contract PolyLend is IPolyLend, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    using PercentageMath for uint256;

    // ============ Storage ============

    /// @notice The vault contract for collateral custody
    Vault public vault;

    /// @notice The lending pool for USDC management
    LendingPool public lendingPool;

    /// @notice The liquidation engine
    LiquidationEngine public liquidationEngine;

    /// @notice The TWAP oracle
    PolymarketTWAPOracle public oracle;

    /// @notice The market registry
    MarketRegistry public marketRegistry;

    /// @notice The LTV calculator
    LTVCalculator public ltvCalculator;

    /// @notice The circuit breaker
    CircuitBreaker public circuitBreaker;

    /// @notice The USDC token
    IERC20 public usdc;

    /// @notice The Conditional Token Framework
    IERC1155 public ctf;

    /// @notice Whether the protocol is initialized
    bool public initialized;

    // ============ Events ============

    event ProtocolInitialized(
        address vault,
        address lendingPool,
        address liquidationEngine,
        address oracle,
        address marketRegistry,
        address ltvCalculator,
        address circuitBreaker
    );

    // ============ Constructor ============

    constructor() Ownable(msg.sender) {}

    // ============ Initialization ============

    /**
     * @notice Initialize the protocol with all component addresses
     * @param _vault The vault contract
     * @param _lendingPool The lending pool contract
     * @param _liquidationEngine The liquidation engine contract
     * @param _oracle The oracle contract
     * @param _marketRegistry The market registry contract
     * @param _ltvCalculator The LTV calculator contract
     * @param _circuitBreaker The circuit breaker contract
     * @param _usdc The USDC token address
     * @param _ctf The CTF contract address
     */
    function initialize(
        address _vault,
        address _lendingPool,
        address _liquidationEngine,
        address _oracle,
        address _marketRegistry,
        address _ltvCalculator,
        address _circuitBreaker,
        address _usdc,
        address _ctf
    ) external onlyOwner {
        require(!initialized, "Already initialized");

        vault = Vault(_vault);
        lendingPool = LendingPool(_lendingPool);
        liquidationEngine = LiquidationEngine(_liquidationEngine);
        oracle = PolymarketTWAPOracle(_oracle);
        marketRegistry = MarketRegistry(_marketRegistry);
        ltvCalculator = LTVCalculator(_ltvCalculator);
        circuitBreaker = CircuitBreaker(_circuitBreaker);
        usdc = IERC20(_usdc);
        ctf = IERC1155(_ctf);

        initialized = true;

        emit ProtocolInitialized(
            _vault,
            _lendingPool,
            _liquidationEngine,
            _oracle,
            _marketRegistry,
            _ltvCalculator,
            _circuitBreaker
        );
    }

    // ============ Modifiers ============

    modifier whenInitialized() {
        require(initialized, "Not initialized");
        _;
    }

    modifier whenNotFrozen(bytes32 marketId) {
        (bool allowed, uint8 reason) = circuitBreaker.canBorrow(marketId);
        if (!allowed) {
            if (reason == 1) revert Errors.ContractPaused();
            if (reason == 2) revert Errors.CircuitBreakerTripped();
            if (reason == 3) revert Errors.CircuitBreakerTripped();
            if (reason == 4) revert Errors.PreResolutionFreeze(marketId, 0);
            if (reason == 5) revert Errors.MarketFrozen(marketId);
        }
        _;
    }

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
    ) external override nonReentrant whenInitialized {
        if (amount == 0) {
            revert Errors.ZeroAmount();
        }

        // Verify market is registered
        if (!marketRegistry.isMarketRegistered(marketId)) {
            revert Errors.MarketNotRegistered(marketId);
        }

        // Transfer tokens from user to vault
        ctf.safeTransferFrom(msg.sender, address(vault), tokenId, amount, "");

        // Update vault accounting
        vault.depositCollateralFor(msg.sender, tokenId, amount, marketId);

        // Update liquidation engine position
        DataTypes.Position memory currentPos = liquidationEngine.getPosition(msg.sender, tokenId);
        liquidationEngine.updatePositionCollateral(
            msg.sender,
            tokenId,
            currentPos.collateralAmount + amount,
            marketId
        );

        emit CollateralDeposited(msg.sender, tokenId, amount, marketId);
    }

    /**
     * @notice Withdraw collateral (if health factor allows)
     * @param tokenId The ERC-1155 token ID
     * @param amount The amount to withdraw
     */
    function withdrawCollateral(
        uint256 tokenId,
        uint256 amount
    ) external override nonReentrant whenInitialized {
        if (amount == 0) {
            revert Errors.ZeroAmount();
        }

        // Check circuit breaker allows withdrawals
        if (!circuitBreaker.canWithdraw()) {
            revert Errors.ContractPaused();
        }

        DataTypes.Position memory position = liquidationEngine.getPosition(msg.sender, tokenId);

        if (position.collateralAmount < amount) {
            revert Errors.InsufficientCollateral(position.collateralAmount, amount);
        }

        // If there's debt, check health factor after withdrawal
        if (position.borrowedAmount > 0) {
            uint256 newCollateral = position.collateralAmount - amount;
            uint256 newCollateralValue = _getCollateralValue(tokenId, newCollateral);
            uint256 newHealthFactor = liquidationEngine.calculateHealthFactor(
                newCollateralValue,
                position.borrowedAmount
            );

            if (newHealthFactor < PercentageMath.PRICE_PRECISION) {
                revert Errors.WithdrawalWouldLiquidate();
            }
        }

        // Update position
        liquidationEngine.updatePositionCollateral(
            msg.sender,
            tokenId,
            position.collateralAmount - amount,
            position.marketId
        );

        // Withdraw from vault
        vault.withdrawCollateralFor(msg.sender, tokenId, amount);

        emit CollateralWithdrawn(msg.sender, tokenId, amount);
    }

    /**
     * @notice Borrow USDC against deposited collateral
     * @param tokenId The collateral token ID
     * @param amount The amount of USDC to borrow
     */
    function borrow(
        uint256 tokenId,
        uint256 amount
    ) external override nonReentrant whenInitialized {
        if (amount == 0) {
            revert Errors.ZeroAmount();
        }

        DataTypes.Position memory position = liquidationEngine.getPosition(msg.sender, tokenId);

        if (position.collateralAmount == 0) {
            revert Errors.InsufficientCollateral(0, 1);
        }

        // Check market isn't frozen
        bytes32 marketId = position.marketId;
        (bool allowed,) = circuitBreaker.canBorrow(marketId);
        if (!allowed) {
            revert Errors.MarketFrozen(marketId);
        }

        // Check oracle isn't stale or circuit-broken
        if (oracle.isPriceStale(tokenId)) {
            revert Errors.StalePrice(0, oracle.stalenessThreshold());
        }
        if (oracle.isCircuitBreakerTriggered(tokenId)) {
            revert Errors.CircuitBreakerTripped();
        }

        // Calculate max borrow amount
        uint256 collateralValue = _getCollateralValue(tokenId, position.collateralAmount);
        uint256 maxLTV = ltvCalculator.getMaxLTVForToken(tokenId);

        if (maxLTV == 0) {
            revert Errors.MarketFrozen(marketId);
        }

        uint256 maxBorrow = collateralValue.percentMul(maxLTV);
        uint256 newTotalDebt = position.borrowedAmount + amount;

        if (newTotalDebt > maxBorrow) {
            uint256 currentLTV = (newTotalDebt * PercentageMath.BPS) / collateralValue;
            revert Errors.ExceedsMaxLTV(currentLTV, maxLTV);
        }

        // Update position debt
        liquidationEngine.updatePositionDebt(msg.sender, tokenId, newTotalDebt, marketId);

        // Disburse loan
        lendingPool.disburseLoan(msg.sender, amount);

        emit Borrowed(msg.sender, tokenId, amount);
    }

    /**
     * @notice Repay borrowed USDC
     * @param tokenId The collateral token ID
     * @param amount The amount to repay
     */
    function repay(
        uint256 tokenId,
        uint256 amount
    ) external override nonReentrant whenInitialized {
        if (amount == 0) {
            revert Errors.ZeroAmount();
        }

        DataTypes.Position memory position = liquidationEngine.getPosition(msg.sender, tokenId);

        if (position.borrowedAmount == 0) {
            revert Errors.ZeroAmount();
        }

        // Cap repayment at outstanding debt
        uint256 repayAmount = amount > position.borrowedAmount ? position.borrowedAmount : amount;

        // Transfer USDC from borrower
        usdc.safeTransferFrom(msg.sender, address(this), repayAmount);

        // Approve lending pool to pull funds
        usdc.approve(address(lendingPool), repayAmount);

        // Send to lending pool
        lendingPool.receiveLoanRepayment(msg.sender, repayAmount);

        // Update position
        liquidationEngine.updatePositionDebt(
            msg.sender,
            tokenId,
            position.borrowedAmount - repayAmount,
            position.marketId
        );

        emit Repaid(msg.sender, tokenId, repayAmount);
    }

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
    ) external override nonReentrant whenInitialized returns (uint256 collateralSeized) {
        // Check liquidations are allowed
        DataTypes.Position memory position = liquidationEngine.getPosition(borrower, tokenId);
        if (!circuitBreaker.canLiquidate(position.marketId)) {
            revert Errors.ContractPaused();
        }

        // Execute liquidation through liquidation engine
        collateralSeized = liquidationEngine.executeLiquidation(borrower, tokenId, repayAmount);

        emit Liquidated(msg.sender, borrower, tokenId, repayAmount, collateralSeized);
    }

    // ============ Lender Functions ============

    /**
     * @notice Deposit USDC to earn yield
     * @param amount The amount of USDC to deposit
     * @return shares The number of shares received
     */
    function deposit(uint256 amount) external override nonReentrant whenInitialized returns (uint256 shares) {
        if (amount == 0) {
            revert Errors.ZeroAmount();
        }

        // Transfer USDC from lender
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        // Approve lending pool
        usdc.approve(address(lendingPool), amount);

        // Forward to lending pool and get shares
        // Note: We need to handle this differently since lendingPool.deposit expects direct call
        // Transfer to lending pool directly
        usdc.safeTransfer(address(lendingPool), amount);

        // For MVP, shares are minted directly to caller through lending pool
        // This requires lending pool to accept transfers and credit the sender
        shares = lendingPool.amountToShares(amount);

        return shares;
    }

    /**
     * @notice Withdraw USDC by burning shares
     * @param shares The number of shares to burn
     * @return amount The USDC amount withdrawn
     */
    function withdraw(uint256 shares) external override nonReentrant whenInitialized returns (uint256 amount) {
        if (shares == 0) {
            revert Errors.ZeroAmount();
        }

        // Check withdrawals are allowed
        if (!circuitBreaker.canWithdraw()) {
            revert Errors.ContractPaused();
        }

        // Withdraw through lending pool
        amount = lendingPool.withdraw(shares);

        return amount;
    }

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
    ) external view override returns (DataTypes.Position memory) {
        return liquidationEngine.getPosition(user, tokenId);
    }

    /**
     * @notice Get the health factor of a position
     * @param user The user address
     * @param tokenId The collateral token ID
     * @return The health factor (1e18 = 1.0)
     */
    function getHealthFactor(
        address user,
        uint256 tokenId
    ) external view override returns (uint256) {
        return liquidationEngine.getPositionHealthFactor(user, tokenId);
    }

    /**
     * @notice Get the maximum borrowable amount for a position
     * @param user The user address
     * @param tokenId The collateral token ID
     * @return The maximum additional USDC that can be borrowed
     */
    function getMaxBorrowAmount(
        address user,
        uint256 tokenId
    ) external view override returns (uint256) {
        DataTypes.Position memory position = liquidationEngine.getPosition(user, tokenId);

        if (position.collateralAmount == 0) {
            return 0;
        }

        uint256 collateralValue = _getCollateralValue(tokenId, position.collateralAmount);
        uint256 maxLTV = ltvCalculator.getMaxLTVForToken(tokenId);
        uint256 maxBorrow = collateralValue.percentMul(maxLTV);

        if (maxBorrow <= position.borrowedAmount) {
            return 0;
        }

        return maxBorrow - position.borrowedAmount;
    }

    /**
     * @notice Check if a position can be liquidated
     * @param user The user address
     * @param tokenId The collateral token ID
     * @return True if the position is liquidatable
     */
    function isLiquidatable(
        address user,
        uint256 tokenId
    ) external view override returns (bool) {
        return liquidationEngine.isLiquidatable(user, tokenId);
    }

    /**
     * @notice Get the current LTV for a market
     * @param marketId The market condition ID
     * @return The current max LTV in basis points
     */
    function getCurrentLTV(bytes32 marketId) external view override returns (uint256) {
        return ltvCalculator.getMaxLTV(marketId);
    }

    /**
     * @notice Get collateral value in USDC
     * @param tokenId The token ID
     * @param amount The collateral amount
     * @return The value in USDC (6 decimals)
     */
    function getCollateralValue(uint256 tokenId, uint256 amount) external view returns (uint256) {
        return _getCollateralValue(tokenId, amount);
    }

    /**
     * @notice Get protocol component addresses
     */
    function getProtocolAddresses() external view returns (
        address _vault,
        address _lendingPool,
        address _liquidationEngine,
        address _oracle,
        address _marketRegistry,
        address _ltvCalculator,
        address _circuitBreaker
    ) {
        return (
            address(vault),
            address(lendingPool),
            address(liquidationEngine),
            address(oracle),
            address(marketRegistry),
            address(ltvCalculator),
            address(circuitBreaker)
        );
    }

    // ============ Internal Functions ============

    /**
     * @notice Get collateral value in USDC terms
     * @param tokenId The token ID
     * @param amount The collateral amount
     * @return The value in USDC (6 decimals)
     */
    function _getCollateralValue(uint256 tokenId, uint256 amount) internal view returns (uint256) {
        if (amount == 0) {
            return 0;
        }

        (uint256 price,) = oracle.getTWAP(tokenId);

        // price is 0 to 1e18 representing probability
        // collateral value = amount * price
        // Scale down from 18 decimals to 6 decimals for USDC
        return PercentageMath.scaleToUSDC((amount * price) / PercentageMath.PRICE_PRECISION);
    }

    // ============ ERC1155 Receiver ============

    /**
     * @notice Handle receipt of ERC1155 tokens
     */
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes memory
    ) public pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    /**
     * @notice Handle batch receipt of ERC1155 tokens
     */
    function onERC1155BatchReceived(
        address,
        address,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) public pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    /**
     * @notice ERC165 interface support
     */
    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return interfaceId == 0x01ffc9a7 || // ERC165
               interfaceId == 0x4e2312e0;   // ERC1155Receiver
    }
}
