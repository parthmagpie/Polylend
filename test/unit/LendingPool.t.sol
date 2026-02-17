// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/LendingPool.sol";
import "../../test/mocks/MockUSDC.sol";
import "../../src/libraries/Errors.sol";

contract LendingPoolTest is Test {
    LendingPool public pool;
    MockUSDC public usdc;

    address public lender = address(0x1);
    address public borrower = address(0x2);
    address public polyLend = address(0x3);

    uint256 constant DEPOSIT_AMOUNT = 10_000e6; // 10,000 USDC
    uint256 constant BORROW_AMOUNT = 5_000e6;   // 5,000 USDC

    function setUp() public {
        usdc = new MockUSDC();
        pool = new LendingPool(address(usdc));
        pool.setPolyLend(polyLend);

        // Mint USDC to lender
        usdc.mint(lender, DEPOSIT_AMOUNT * 2);

        // Lender approves pool
        vm.prank(lender);
        usdc.approve(address(pool), type(uint256).max);
    }

    function test_Deposit() public {
        vm.prank(lender);
        uint256 shares = pool.deposit(DEPOSIT_AMOUNT);

        assertEq(shares, DEPOSIT_AMOUNT); // 1:1 for first deposit
        assertEq(pool.sharesOf(lender), DEPOSIT_AMOUNT);
        assertEq(pool.getAvailableLiquidity(), DEPOSIT_AMOUNT);
    }

    function test_Withdraw() public {
        // Deposit first
        vm.prank(lender);
        pool.deposit(DEPOSIT_AMOUNT);

        // Withdraw half
        vm.prank(lender);
        uint256 amount = pool.withdraw(DEPOSIT_AMOUNT / 2);

        assertEq(amount, DEPOSIT_AMOUNT / 2);
        assertEq(pool.sharesOf(lender), DEPOSIT_AMOUNT / 2);
        assertEq(usdc.balanceOf(lender), DEPOSIT_AMOUNT + DEPOSIT_AMOUNT / 2);
    }

    function test_DisburseLoan() public {
        // Deposit liquidity
        vm.prank(lender);
        pool.deposit(DEPOSIT_AMOUNT);

        // PolyLend disburses loan
        vm.prank(polyLend);
        pool.disburseLoan(borrower, BORROW_AMOUNT);

        assertEq(usdc.balanceOf(borrower), BORROW_AMOUNT);
        assertEq(pool.getAvailableLiquidity(), DEPOSIT_AMOUNT - BORROW_AMOUNT);

        DataTypes.PoolState memory state = pool.getPoolState();
        assertEq(state.totalBorrows, BORROW_AMOUNT);
    }

    function test_ReceiveLoanRepayment() public {
        // Setup: deposit and borrow
        vm.prank(lender);
        pool.deposit(DEPOSIT_AMOUNT);

        vm.prank(polyLend);
        pool.disburseLoan(borrower, BORROW_AMOUNT);

        // Borrower repays through PolyLend
        usdc.mint(polyLend, BORROW_AMOUNT);
        vm.prank(polyLend);
        usdc.approve(address(pool), BORROW_AMOUNT);

        vm.prank(polyLend);
        pool.receiveLoanRepayment(borrower, BORROW_AMOUNT);

        DataTypes.PoolState memory state = pool.getPoolState();
        assertEq(state.totalBorrows, 0);
        assertEq(pool.getAvailableLiquidity(), DEPOSIT_AMOUNT);
    }

    function test_UtilizationRate() public {
        vm.prank(lender);
        pool.deposit(DEPOSIT_AMOUNT);

        // No borrows = 0% utilization
        assertEq(pool.getUtilizationRate(), 0);

        vm.prank(polyLend);
        pool.disburseLoan(borrower, BORROW_AMOUNT);

        // 50% utilization
        assertEq(pool.getUtilizationRate(), 5000);
    }

    function test_SharePrice() public {
        vm.prank(lender);
        pool.deposit(DEPOSIT_AMOUNT);

        // Initial share price should be 1:1
        assertEq(pool.getSharePrice(), 1e6);
    }

    function test_SharesConversion() public {
        vm.prank(lender);
        pool.deposit(DEPOSIT_AMOUNT);

        uint256 shares = pool.amountToShares(1000e6);
        uint256 amount = pool.sharesToAmount(shares);

        assertEq(amount, 1000e6);
    }

    function test_RevertInsufficientLiquidity() public {
        vm.prank(lender);
        pool.deposit(DEPOSIT_AMOUNT);

        vm.prank(polyLend);
        vm.expectRevert(abi.encodeWithSelector(
            Errors.InsufficientLiquidity.selector,
            DEPOSIT_AMOUNT,
            DEPOSIT_AMOUNT + 1
        ));
        pool.disburseLoan(borrower, DEPOSIT_AMOUNT + 1);
    }

    function test_RevertInsufficientShares() public {
        vm.prank(lender);
        pool.deposit(DEPOSIT_AMOUNT);

        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(
            Errors.InsufficientShares.selector,
            DEPOSIT_AMOUNT,
            DEPOSIT_AMOUNT + 1
        ));
        pool.withdraw(DEPOSIT_AMOUNT + 1);
    }

    function test_RevertUnauthorizedDisbursement() public {
        vm.prank(lender);
        pool.deposit(DEPOSIT_AMOUNT);

        address attacker = address(0x999);
        vm.prank(attacker);
        vm.expectRevert(Errors.NotLendingPool.selector);
        pool.disburseLoan(borrower, BORROW_AMOUNT);
    }

    function test_MinimumDeposit() public {
        vm.prank(lender);
        vm.expectRevert(Errors.ZeroAmount.selector);
        pool.deposit(0);
    }

    function test_MultipleDepositors() public {
        address lender2 = address(0x4);
        usdc.mint(lender2, DEPOSIT_AMOUNT);

        vm.prank(lender2);
        usdc.approve(address(pool), type(uint256).max);

        // First lender deposits
        vm.prank(lender);
        pool.deposit(DEPOSIT_AMOUNT);

        // Second lender deposits
        vm.prank(lender2);
        uint256 shares2 = pool.deposit(DEPOSIT_AMOUNT);

        // Both should have equal shares (same deposit amount, 1:1 ratio)
        assertEq(pool.sharesOf(lender), pool.sharesOf(lender2));
        assertEq(shares2, DEPOSIT_AMOUNT);
    }
}
