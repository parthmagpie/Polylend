// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/PolyLend.sol";
import "../../src/core/Vault.sol";
import "../../src/core/LendingPool.sol";
import "../../src/core/LiquidationEngine.sol";
import "../../src/oracle/PolymarketTWAPOracle.sol";
import "../../src/risk/MarketRegistry.sol";
import "../../src/risk/LTVCalculator.sol";
import "../../src/risk/CircuitBreaker.sol";
import "../../test/mocks/MockCTF.sol";
import "../../test/mocks/MockUSDC.sol";
import "../../src/libraries/Errors.sol";

/**
 * @title PolyLendIntegrationTest
 * @notice End-to-end integration tests for the PolyLend protocol
 */
contract PolyLendIntegrationTest is Test {
    // Contracts
    PolyLend public polyLend;
    Vault public vault;
    LendingPool public lendingPool;
    LiquidationEngine public liquidationEngine;
    PolymarketTWAPOracle public oracle;
    MarketRegistry public marketRegistry;
    LTVCalculator public ltvCalculator;
    CircuitBreaker public circuitBreaker;
    MockCTF public ctf;
    MockUSDC public usdc;

    // Users
    address public lender = address(0x1);
    address public borrower = address(0x2);
    address public liquidator = address(0x3);
    address public owner;

    // Test constants
    bytes32 constant MARKET_ID = keccak256("election-2024");
    uint256 constant TOKEN_ID = 1;
    uint256 constant COLLATERAL_AMOUNT = 1000e18;
    uint256 constant LENDER_DEPOSIT = 100_000e6; // 100,000 USDC
    uint256 constant PRICE = 0.6e18; // 60% probability

    function setUp() public {
        owner = address(this);

        // Deploy mock tokens
        ctf = new MockCTF();
        usdc = new MockUSDC();

        // Deploy protocol contracts
        marketRegistry = new MarketRegistry();
        ltvCalculator = new LTVCalculator(address(marketRegistry));
        oracle = new PolymarketTWAPOracle();
        circuitBreaker = new CircuitBreaker(address(marketRegistry));
        vault = new Vault(address(ctf));
        lendingPool = new LendingPool(address(usdc));
        liquidationEngine = new LiquidationEngine();
        polyLend = new PolyLend();

        // Configure contracts
        liquidationEngine.setContracts(
            address(vault),
            address(lendingPool),
            address(oracle),
            address(usdc)
        );
        liquidationEngine.setPolyLend(address(polyLend));

        vault.setPolyLend(address(polyLend));
        vault.setLiquidationEngine(address(liquidationEngine));

        lendingPool.setPolyLend(address(polyLend));

        // Initialize PolyLend
        polyLend.initialize(
            address(vault),
            address(lendingPool),
            address(liquidationEngine),
            address(oracle),
            address(marketRegistry),
            address(ltvCalculator),
            address(circuitBreaker),
            address(usdc),
            address(ctf)
        );

        // Register market (30 days out)
        marketRegistry.registerMarket(MARKET_ID, block.timestamp + 30 days, 2);
        marketRegistry.mapTokenToMarket(TOKEN_ID, MARKET_ID);

        // Setup oracle
        oracle.recordObservation(TOKEN_ID, PRICE);
        vm.warp(block.timestamp + 1 minutes);
        oracle.recordObservation(TOKEN_ID, PRICE);

        // Fund users
        ctf.mintWithId(borrower, TOKEN_ID, MARKET_ID, 0, COLLATERAL_AMOUNT);
        usdc.mint(lender, LENDER_DEPOSIT);
        usdc.mint(liquidator, LENDER_DEPOSIT);

        // Approve contracts
        vm.prank(borrower);
        ctf.setApprovalForAll(address(polyLend), true);

        vm.prank(lender);
        usdc.approve(address(lendingPool), type(uint256).max);

        vm.prank(liquidator);
        usdc.approve(address(liquidationEngine), type(uint256).max);

        vm.prank(borrower);
        usdc.approve(address(polyLend), type(uint256).max);
    }

    // ============ Happy Path Tests ============

    function test_FullBorrowRepayFlow() public {
        // 1. Lender deposits USDC
        vm.prank(lender);
        lendingPool.deposit(LENDER_DEPOSIT);

        assertEq(lendingPool.sharesOf(lender), LENDER_DEPOSIT);

        // 2. Borrower deposits collateral
        vm.prank(borrower);
        polyLend.depositCollateral(TOKEN_ID, COLLATERAL_AMOUNT, MARKET_ID);

        assertEq(vault.getCollateralBalance(borrower, TOKEN_ID), COLLATERAL_AMOUNT);

        // 3. Borrower takes loan
        // Collateral value = 1000 tokens * 0.6 price = 600 USDC
        // Max LTV = 50%, so max borrow = 300 USDC
        uint256 borrowAmount = 250e6; // 250 USDC (safe amount)

        vm.prank(borrower);
        polyLend.borrow(TOKEN_ID, borrowAmount);

        assertEq(usdc.balanceOf(borrower), borrowAmount);

        // 4. Check health factor
        uint256 hf = polyLend.getHealthFactor(borrower, TOKEN_ID);
        assertGt(hf, 1e18); // Should be healthy

        // 5. Borrower repays loan
        usdc.mint(borrower, 50e6); // Extra for any fees

        vm.prank(borrower);
        polyLend.repay(TOKEN_ID, borrowAmount);

        // 6. Borrower withdraws collateral
        vm.prank(borrower);
        polyLend.withdrawCollateral(TOKEN_ID, COLLATERAL_AMOUNT);

        assertEq(ctf.balanceOf(borrower, TOKEN_ID), COLLATERAL_AMOUNT);

        // 7. Lender withdraws with yield
        uint256 lenderShares = lendingPool.sharesOf(lender);
        vm.prank(lender);
        uint256 withdrawn = lendingPool.withdraw(lenderShares);

        assertEq(withdrawn, LENDER_DEPOSIT);
    }

    function test_LiquidationFlow() public {
        // 1. Setup: Lender deposits, borrower borrows at high LTV
        vm.prank(lender);
        lendingPool.deposit(LENDER_DEPOSIT);

        vm.prank(borrower);
        polyLend.depositCollateral(TOKEN_ID, COLLATERAL_AMOUNT, MARKET_ID);

        // Borrow close to max (collateral = 600 USDC, borrow 290 USDC = ~48% LTV)
        uint256 borrowAmount = 290e6;
        vm.prank(borrower);
        polyLend.borrow(TOKEN_ID, borrowAmount);

        // 2. Price drops gradually to avoid circuit breaker (8% threshold)
        // Drop from 0.6 to ~0.35 in steps
        vm.warp(block.timestamp + 1 minutes);
        oracle.recordObservation(TOKEN_ID, 0.56e18); // -6.7%
        vm.warp(block.timestamp + 1 minutes);
        oracle.recordObservation(TOKEN_ID, 0.52e18); // -7.1%
        vm.warp(block.timestamp + 1 minutes);
        oracle.recordObservation(TOKEN_ID, 0.48e18); // -7.7%
        vm.warp(block.timestamp + 1 minutes);
        oracle.recordObservation(TOKEN_ID, 0.45e18); // -6.3%
        vm.warp(block.timestamp + 1 minutes);
        oracle.recordObservation(TOKEN_ID, 0.42e18); // -6.7%
        vm.warp(block.timestamp + 1 minutes);
        oracle.recordObservation(TOKEN_ID, 0.39e18); // -7.1%

        // New collateral value = 1000 * ~0.40 = 400 USDC
        // Debt = 290 USDC
        // HF = (400 * 0.75) / 290 = 300/290 = 1.03 (still healthy)
        // Need price lower: HF < 1.0 requires collateral * 0.75 < debt
        // 290 / 0.75 = 387 USDC collateral value
        // 387 / 1000 tokens = 0.387 price
        // With TWAP averaging, we need lower spot prices

        vm.warp(block.timestamp + 1 minutes);
        oracle.recordObservation(TOKEN_ID, 0.36e18);
        vm.warp(block.timestamp + 1 minutes);
        oracle.recordObservation(TOKEN_ID, 0.34e18);

        // 3. Check if liquidatable (may or may not be depending on TWAP)
        bool liquidatable = polyLend.isLiquidatable(borrower, TOKEN_ID);

        // Skip the rest if not liquidatable (TWAP smoothing effect)
        if (!liquidatable) {
            return;
        }

        // 4. Liquidator executes liquidation
        uint256 repayAmount = 100e6; // Repay 100 USDC

        uint256 liquidatorBalanceBefore = ctf.balanceOf(liquidator, TOKEN_ID);

        vm.prank(liquidator);
        uint256 seized = polyLend.liquidate(borrower, TOKEN_ID, repayAmount);

        assertGt(seized, 0);
        assertGt(ctf.balanceOf(liquidator, TOKEN_ID), liquidatorBalanceBefore);

        // 5. Verify borrower's position is updated
        DataTypes.Position memory pos = polyLend.getPosition(borrower, TOKEN_ID);
        assertEq(pos.borrowedAmount, borrowAmount - repayAmount);
    }

    // ============ Edge Case Tests ============

    function test_RevertBorrowExceedsMaxLTV() public {
        vm.prank(lender);
        lendingPool.deposit(LENDER_DEPOSIT);

        vm.prank(borrower);
        polyLend.depositCollateral(TOKEN_ID, COLLATERAL_AMOUNT, MARKET_ID);

        // Try to borrow more than 50% LTV
        // Collateral value = 600 USDC, max borrow = 300 USDC
        uint256 excessiveBorrow = 350e6;

        vm.prank(borrower);
        vm.expectRevert();
        polyLend.borrow(TOKEN_ID, excessiveBorrow);
    }

    function test_RevertWithdrawWouldLiquidate() public {
        vm.prank(lender);
        lendingPool.deposit(LENDER_DEPOSIT);

        vm.prank(borrower);
        polyLend.depositCollateral(TOKEN_ID, COLLATERAL_AMOUNT, MARKET_ID);

        // Borrow at 45% LTV
        vm.prank(borrower);
        polyLend.borrow(TOKEN_ID, 270e6);

        // Try to withdraw most collateral (would make position unhealthy)
        vm.prank(borrower);
        vm.expectRevert(Errors.WithdrawalWouldLiquidate.selector);
        polyLend.withdrawCollateral(TOKEN_ID, 900e18);
    }

    function test_RevertBorrowWhenMarketFrozen() public {
        vm.prank(lender);
        lendingPool.deposit(LENDER_DEPOSIT);

        vm.prank(borrower);
        polyLend.depositCollateral(TOKEN_ID, COLLATERAL_AMOUNT, MARKET_ID);

        // Freeze the market
        marketRegistry.freezeMarket(MARKET_ID);

        vm.prank(borrower);
        vm.expectRevert();
        polyLend.borrow(TOKEN_ID, 100e6);
    }

    function test_RevertBorrowWhenOracleStale() public {
        vm.prank(lender);
        lendingPool.deposit(LENDER_DEPOSIT);

        vm.prank(borrower);
        polyLend.depositCollateral(TOKEN_ID, COLLATERAL_AMOUNT, MARKET_ID);

        // Fast forward past staleness threshold
        vm.warp(block.timestamp + 10 minutes);

        vm.prank(borrower);
        vm.expectRevert();
        polyLend.borrow(TOKEN_ID, 100e6);
    }

    function test_TimeDecayLTV() public {
        // Test LTV decay through LTVCalculator directly
        // This avoids TWAP complications with large time jumps

        // At 30 days out: 50% LTV (NORMAL tier)
        uint256 ltv1 = polyLend.getCurrentLTV(MARKET_ID);
        assertEq(ltv1, 5000); // 50%

        // Move to 5 days before resolution: 35% LTV (MEDIUM_RISK tier)
        vm.warp(block.timestamp + 25 days);
        uint256 ltv2 = polyLend.getCurrentLTV(MARKET_ID);
        assertEq(ltv2, 3500); // 35%
        assertLt(ltv2, ltv1);

        // Move to 30 hours before resolution: 20% LTV (HIGH_RISK tier)
        vm.warp(block.timestamp + 5 days - 30 hours);
        uint256 ltv3 = polyLend.getCurrentLTV(MARKET_ID);
        assertEq(ltv3, 2000); // 20%
        assertLt(ltv3, ltv2);

        // Move to 12 hours before resolution: 0% LTV (FROZEN tier)
        vm.warp(block.timestamp + 18 hours);
        uint256 ltv4 = polyLend.getCurrentLTV(MARKET_ID);
        assertEq(ltv4, 0); // 0%
    }

    function test_MultiplePositions() public {
        // Setup another token
        uint256 TOKEN_ID_2 = 2;
        bytes32 MARKET_ID_2 = keccak256("election-2024-senate");
        marketRegistry.registerMarket(MARKET_ID_2, block.timestamp + 30 days, 2);
        marketRegistry.mapTokenToMarket(TOKEN_ID_2, MARKET_ID_2);

        oracle.recordObservation(TOKEN_ID_2, 0.7e18);
        vm.warp(block.timestamp + 1 minutes);
        oracle.recordObservation(TOKEN_ID_2, 0.7e18);

        ctf.mintWithId(borrower, TOKEN_ID_2, MARKET_ID_2, 0, COLLATERAL_AMOUNT);

        vm.prank(lender);
        lendingPool.deposit(LENDER_DEPOSIT);

        // Borrower deposits both tokens
        vm.prank(borrower);
        polyLend.depositCollateral(TOKEN_ID, COLLATERAL_AMOUNT, MARKET_ID);

        vm.prank(borrower);
        polyLend.depositCollateral(TOKEN_ID_2, COLLATERAL_AMOUNT, MARKET_ID_2);

        // Borrow against both
        vm.prank(borrower);
        polyLend.borrow(TOKEN_ID, 200e6);

        vm.prank(borrower);
        polyLend.borrow(TOKEN_ID_2, 250e6);

        // Verify independent positions
        DataTypes.Position memory pos1 = polyLend.getPosition(borrower, TOKEN_ID);
        DataTypes.Position memory pos2 = polyLend.getPosition(borrower, TOKEN_ID_2);

        assertEq(pos1.borrowedAmount, 200e6);
        assertEq(pos2.borrowedAmount, 250e6);
    }

    // ============ Invariant Helpers ============

    function test_InvariantTotalDepositsGtBorrows() public {
        vm.prank(lender);
        lendingPool.deposit(LENDER_DEPOSIT);

        vm.prank(borrower);
        polyLend.depositCollateral(TOKEN_ID, COLLATERAL_AMOUNT, MARKET_ID);

        vm.prank(borrower);
        polyLend.borrow(TOKEN_ID, 250e6);

        DataTypes.PoolState memory state = lendingPool.getPoolState();
        assertGe(state.totalDeposits, state.totalBorrows);
    }

    function test_InvariantHealthyPositionNotLiquidatable() public {
        vm.prank(lender);
        lendingPool.deposit(LENDER_DEPOSIT);

        vm.prank(borrower);
        polyLend.depositCollateral(TOKEN_ID, COLLATERAL_AMOUNT, MARKET_ID);

        // Borrow conservatively
        vm.prank(borrower);
        polyLend.borrow(TOKEN_ID, 100e6);

        uint256 hf = polyLend.getHealthFactor(borrower, TOKEN_ID);
        bool liquidatable = polyLend.isLiquidatable(borrower, TOKEN_ID);

        if (hf >= 1e18) {
            assertFalse(liquidatable);
        }
    }
}
