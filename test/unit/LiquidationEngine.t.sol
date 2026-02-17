// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/LiquidationEngine.sol";
import "../../src/core/Vault.sol";
import "../../src/core/LendingPool.sol";
import "../../src/oracle/PolymarketTWAPOracle.sol";
import "../../test/mocks/MockCTF.sol";
import "../../test/mocks/MockUSDC.sol";
import "../../src/libraries/Errors.sol";
import "../../src/libraries/PercentageMath.sol";

contract LiquidationEngineTest is Test {
    using PercentageMath for uint256;

    LiquidationEngine public engine;
    Vault public vault;
    LendingPool public pool;
    PolymarketTWAPOracle public oracle;
    MockCTF public ctf;
    MockUSDC public usdc;

    address public borrower = address(0x1);
    address public liquidator = address(0x2);
    address public polyLend = address(0x3);

    bytes32 constant MARKET_ID = keccak256("test-market");
    uint256 constant TOKEN_ID = 1;
    uint256 constant COLLATERAL_AMOUNT = 1000e18;
    uint256 constant BORROW_AMOUNT = 400e6; // 400 USDC

    function setUp() public {
        // Deploy contracts
        ctf = new MockCTF();
        usdc = new MockUSDC();
        vault = new Vault(address(ctf));
        pool = new LendingPool(address(usdc));
        oracle = new PolymarketTWAPOracle();
        engine = new LiquidationEngine();

        // Configure
        engine.setContracts(address(vault), address(pool), address(oracle), address(usdc));
        engine.setPolyLend(polyLend);
        vault.setPolyLend(polyLend);
        vault.setLiquidationEngine(address(engine));
        pool.setPolyLend(polyLend);

        // Setup oracle with price of 0.5 (50%)
        oracle.recordObservation(TOKEN_ID, 0.5e18);
        vm.warp(block.timestamp + 1 minutes);
        oracle.recordObservation(TOKEN_ID, 0.5e18);

        // Mint collateral to borrower and deposit
        ctf.mintWithId(borrower, TOKEN_ID, MARKET_ID, 0, COLLATERAL_AMOUNT);
        vm.prank(borrower);
        ctf.setApprovalForAll(address(vault), true);

        // Transfer to vault and update accounting
        vm.prank(borrower);
        ctf.safeTransferFrom(borrower, address(vault), TOKEN_ID, COLLATERAL_AMOUNT, "");
        vm.prank(polyLend);
        vault.depositCollateralFor(borrower, TOKEN_ID, COLLATERAL_AMOUNT, MARKET_ID);

        // Setup position in engine
        vm.prank(polyLend);
        engine.updatePositionCollateral(borrower, TOKEN_ID, COLLATERAL_AMOUNT, MARKET_ID);
        vm.prank(polyLend);
        engine.updatePositionDebt(borrower, TOKEN_ID, BORROW_AMOUNT, MARKET_ID);

        // Mint USDC to liquidator
        usdc.mint(liquidator, 10_000e6);
        vm.prank(liquidator);
        usdc.approve(address(engine), type(uint256).max);

        // Fund the lending pool for repayments
        usdc.mint(address(pool), 10_000e6);
    }

    function test_CalculateHealthFactor_Healthy() public view {
        // Collateral: 1000 tokens at 0.5 price = 500 USDC value
        // Debt: 400 USDC
        // HF = (500 * 0.75) / 400 = 0.9375 * 1e18

        uint256 collateralValue = 500e6; // 500 USDC
        uint256 hf = engine.calculateHealthFactor(collateralValue, BORROW_AMOUNT);

        // Should be below 1.0 (liquidatable)
        assertLt(hf, 1e18);
    }

    function test_CalculateHealthFactor_Unhealthy() public view {
        // If collateral value drops, position becomes unhealthy
        uint256 collateralValue = 300e6; // 300 USDC
        uint256 debt = 400e6;

        uint256 hf = engine.calculateHealthFactor(collateralValue, debt);

        // (300 * 7500 / 10000) / 400 = 225/400 = 0.5625
        assertLt(hf, 1e18);
    }

    function test_IsLiquidatable() public {
        // With current setup, position should be liquidatable
        // Collateral: 1000 tokens * 0.5 = 500 USDC value
        // Debt: 400 USDC
        // LTV = 400/500 = 80% > 75% threshold

        bool liquidatable = engine.isLiquidatable(borrower, TOKEN_ID);
        assertTrue(liquidatable);
    }

    function test_ExecuteLiquidation() public {
        // Verify position is liquidatable
        assertTrue(engine.isLiquidatable(borrower, TOKEN_ID));

        // Get max liquidation amounts
        (uint256 maxRepay, uint256 maxSeize) = engine.getMaxLiquidation(borrower, TOKEN_ID);
        assertGt(maxRepay, 0);
        assertGt(maxSeize, 0);

        // Execute liquidation as liquidator
        uint256 repayAmount = maxRepay / 2; // Repay half of max
        vm.prank(liquidator);
        uint256 seized = engine.executeLiquidation(borrower, TOKEN_ID, repayAmount);

        assertGt(seized, 0);

        // Verify position updated
        DataTypes.Position memory pos = engine.getPosition(borrower, TOKEN_ID);
        assertEq(pos.borrowedAmount, BORROW_AMOUNT - repayAmount);
        assertEq(pos.collateralAmount, COLLATERAL_AMOUNT - seized);
    }

    function test_CalculateSeizeAmount() public view {
        uint256 repayAmount = 100e6; // 100 USDC

        uint256 seizeAmount = engine.calculateSeizeAmount(TOKEN_ID, repayAmount);

        // With 10% bonus: 100 * 1.1 = 110 USDC worth of collateral
        // At price 0.5: 110 / 0.5 = 220 tokens
        assertGt(seizeAmount, 0);
    }

    function test_RevertNotLiquidatable() public {
        // Make position healthy by reducing debt
        vm.prank(polyLend);
        engine.updatePositionDebt(borrower, TOKEN_ID, 100e6, MARKET_ID); // Only 100 USDC debt

        assertFalse(engine.isLiquidatable(borrower, TOKEN_ID));

        vm.expectRevert();
        engine.executeLiquidation(borrower, TOKEN_ID, 50e6);
    }

    function test_RevertExceedsCloseFactor() public {
        // Close factor is 50%, so max repay is 200 USDC
        uint256 maxRepay = BORROW_AMOUNT.percentMul(5000); // 200 USDC

        vm.expectRevert(abi.encodeWithSelector(
            Errors.ExceedsCloseFactor.selector,
            maxRepay + 1,
            maxRepay
        ));
        engine.executeLiquidation(borrower, TOKEN_ID, maxRepay + 1);
    }

    function test_UpdateParameters() public {
        engine.updateParameters(8000, 1500, 6000);

        assertEq(engine.liquidationThreshold(), 8000);
        assertEq(engine.liquidationBonus(), 1500);
        assertEq(engine.closeFactor(), 6000);
    }

    function test_GetPosition() public view {
        DataTypes.Position memory pos = engine.getPosition(borrower, TOKEN_ID);

        assertEq(pos.tokenId, TOKEN_ID);
        assertEq(pos.collateralAmount, COLLATERAL_AMOUNT);
        assertEq(pos.borrowedAmount, BORROW_AMOUNT);
        assertEq(pos.marketId, MARKET_ID);
    }

    function test_GetPositionHealthFactor() public view {
        uint256 hf = engine.getPositionHealthFactor(borrower, TOKEN_ID);
        assertGt(hf, 0);
        assertLt(hf, 1e18); // Should be liquidatable
    }

    function test_NoDebtPosition() public view {
        address noDebtUser = address(0x999);

        // No position = max health factor
        uint256 hf = engine.getPositionHealthFactor(noDebtUser, TOKEN_ID);
        assertEq(hf, type(uint256).max);

        // Not liquidatable
        assertFalse(engine.isLiquidatable(noDebtUser, TOKEN_ID));
    }
}
