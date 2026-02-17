// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/Vault.sol";
import "../../test/mocks/MockCTF.sol";
import "../../src/libraries/Errors.sol";

contract VaultTest is Test {
    Vault public vault;
    MockCTF public ctf;

    address public user = address(0x1);
    address public polyLend = address(0x2);
    address public liquidationEngine = address(0x3);

    bytes32 constant MARKET_ID = keccak256("test-market");
    uint256 constant TOKEN_ID = 1;
    uint256 constant DEPOSIT_AMOUNT = 1000e18;

    function setUp() public {
        ctf = new MockCTF();
        vault = new Vault(address(ctf));

        vault.setPolyLend(polyLend);
        vault.setLiquidationEngine(liquidationEngine);

        // Mint tokens to user
        ctf.mintWithId(user, TOKEN_ID, MARKET_ID, 0, DEPOSIT_AMOUNT);

        // User approves vault
        vm.prank(user);
        ctf.setApprovalForAll(address(vault), true);
    }

    function test_DepositCollateral() public {
        vm.prank(user);
        vault.depositCollateral(TOKEN_ID, DEPOSIT_AMOUNT, MARKET_ID);

        assertEq(vault.getCollateralBalance(user, TOKEN_ID), DEPOSIT_AMOUNT);
        assertEq(vault.getTotalCollateral(TOKEN_ID), DEPOSIT_AMOUNT);
        assertEq(ctf.balanceOf(address(vault), TOKEN_ID), DEPOSIT_AMOUNT);
    }

    function test_DepositCollateralFor() public {
        // Transfer tokens to vault first
        vm.prank(user);
        ctf.safeTransferFrom(user, address(vault), TOKEN_ID, DEPOSIT_AMOUNT, "");

        // PolyLend updates accounting
        vm.prank(polyLend);
        vault.depositCollateralFor(user, TOKEN_ID, DEPOSIT_AMOUNT, MARKET_ID);

        assertEq(vault.getCollateralBalance(user, TOKEN_ID), DEPOSIT_AMOUNT);
    }

    function test_WithdrawCollateral() public {
        // Deposit first
        vm.prank(user);
        vault.depositCollateral(TOKEN_ID, DEPOSIT_AMOUNT, MARKET_ID);

        // Withdraw half
        vm.prank(user);
        vault.withdrawCollateral(TOKEN_ID, DEPOSIT_AMOUNT / 2);

        assertEq(vault.getCollateralBalance(user, TOKEN_ID), DEPOSIT_AMOUNT / 2);
        assertEq(ctf.balanceOf(user, TOKEN_ID), DEPOSIT_AMOUNT / 2);
    }

    function test_WithdrawCollateralFor() public {
        // Deposit first
        vm.prank(user);
        vault.depositCollateral(TOKEN_ID, DEPOSIT_AMOUNT, MARKET_ID);

        // PolyLend withdraws on behalf of user
        vm.prank(polyLend);
        vault.withdrawCollateralFor(user, TOKEN_ID, DEPOSIT_AMOUNT);

        assertEq(vault.getCollateralBalance(user, TOKEN_ID), 0);
        assertEq(ctf.balanceOf(user, TOKEN_ID), DEPOSIT_AMOUNT);
    }

    function test_TransferCollateralToLiquidator() public {
        address liquidator = address(0x4);

        // Deposit first
        vm.prank(user);
        vault.depositCollateral(TOKEN_ID, DEPOSIT_AMOUNT, MARKET_ID);

        // Liquidation engine transfers to liquidator
        vm.prank(liquidationEngine);
        vault.transferCollateralToLiquidator(user, liquidator, TOKEN_ID, DEPOSIT_AMOUNT / 2);

        assertEq(vault.getCollateralBalance(user, TOKEN_ID), DEPOSIT_AMOUNT / 2);
        assertEq(ctf.balanceOf(liquidator, TOKEN_ID), DEPOSIT_AMOUNT / 2);
    }

    function test_RevertZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(Errors.ZeroAmount.selector);
        vault.depositCollateral(TOKEN_ID, 0, MARKET_ID);
    }

    function test_RevertInsufficientCollateral() public {
        vm.prank(user);
        vault.depositCollateral(TOKEN_ID, DEPOSIT_AMOUNT, MARKET_ID);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(
            Errors.InsufficientCollateral.selector,
            DEPOSIT_AMOUNT,
            DEPOSIT_AMOUNT + 1
        ));
        vault.withdrawCollateral(TOKEN_ID, DEPOSIT_AMOUNT + 1);
    }

    function test_RevertUnauthorizedLiquidation() public {
        vm.prank(user);
        vault.depositCollateral(TOKEN_ID, DEPOSIT_AMOUNT, MARKET_ID);

        address attacker = address(0x999);
        vm.prank(attacker);
        vm.expectRevert(Errors.NotLiquidationEngine.selector);
        vault.transferCollateralToLiquidator(user, attacker, TOKEN_ID, DEPOSIT_AMOUNT);
    }

    function test_GetCollateralInfo() public {
        vm.prank(user);
        vault.depositCollateral(TOKEN_ID, DEPOSIT_AMOUNT, MARKET_ID);

        DataTypes.CollateralInfo memory info = vault.getCollateralInfo(user, TOKEN_ID);

        assertEq(info.owner, user);
        assertEq(info.tokenId, TOKEN_ID);
        assertEq(info.amount, DEPOSIT_AMOUNT);
        assertEq(info.marketId, MARKET_ID);
        assertEq(info.depositTimestamp, block.timestamp);
    }

    function test_HasCollateral() public {
        assertFalse(vault.hasCollateral(user, TOKEN_ID));

        vm.prank(user);
        vault.depositCollateral(TOKEN_ID, DEPOSIT_AMOUNT, MARKET_ID);

        assertTrue(vault.hasCollateral(user, TOKEN_ID));
    }
}
