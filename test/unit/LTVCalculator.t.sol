// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/risk/LTVCalculator.sol";
import "../../src/risk/MarketRegistry.sol";
import "../../src/libraries/DataTypes.sol";

contract LTVCalculatorTest is Test {
    LTVCalculator public calculator;
    MarketRegistry public registry;

    bytes32 constant MARKET_ID = keccak256("test-market");
    uint256 constant TOKEN_ID = 1;

    function setUp() public {
        registry = new MarketRegistry();
        calculator = new LTVCalculator(address(registry));

        // Register a test market with 30 days until resolution
        uint256 resolutionTime = block.timestamp + 30 days;
        registry.registerMarket(MARKET_ID, resolutionTime, 2);
        registry.mapTokenToMarket(TOKEN_ID, MARKET_ID);
    }

    function test_NormalTier_MoreThan7Days() public view {
        // Market is 30 days out, should be NORMAL tier
        DataTypes.LTVTier tier = calculator.getLTVTier(MARKET_ID);
        assertEq(uint256(tier), uint256(DataTypes.LTVTier.NORMAL));

        uint256 maxLTV = calculator.getMaxLTV(MARKET_ID);
        assertEq(maxLTV, 5000); // 50%
    }

    function test_MediumRiskTier_2To7Days() public {
        // Fast forward to 5 days before resolution
        vm.warp(block.timestamp + 25 days);

        DataTypes.LTVTier tier = calculator.getLTVTier(MARKET_ID);
        assertEq(uint256(tier), uint256(DataTypes.LTVTier.MEDIUM_RISK));

        uint256 maxLTV = calculator.getMaxLTV(MARKET_ID);
        assertEq(maxLTV, 3500); // 35%
    }

    function test_HighRiskTier_24To48Hours() public {
        // Fast forward to 36 hours before resolution
        vm.warp(block.timestamp + 30 days - 36 hours);

        DataTypes.LTVTier tier = calculator.getLTVTier(MARKET_ID);
        assertEq(uint256(tier), uint256(DataTypes.LTVTier.HIGH_RISK));

        uint256 maxLTV = calculator.getMaxLTV(MARKET_ID);
        assertEq(maxLTV, 2000); // 20%
    }

    function test_FrozenTier_LessThan24Hours() public {
        // Fast forward to 12 hours before resolution
        vm.warp(block.timestamp + 30 days - 12 hours);

        DataTypes.LTVTier tier = calculator.getLTVTier(MARKET_ID);
        assertEq(uint256(tier), uint256(DataTypes.LTVTier.FROZEN));

        uint256 maxLTV = calculator.getMaxLTV(MARKET_ID);
        assertEq(maxLTV, 0); // 0%
    }

    function test_FrozenTier_MarketManuallyFrozen() public {
        // Freeze the market manually
        registry.freezeMarket(MARKET_ID);

        DataTypes.LTVTier tier = calculator.getLTVTier(MARKET_ID);
        assertEq(uint256(tier), uint256(DataTypes.LTVTier.FROZEN));

        uint256 maxLTV = calculator.getMaxLTV(MARKET_ID);
        assertEq(maxLTV, 0);
    }

    function test_CalculateMaxBorrow() public view {
        uint256 collateralValue = 1000e6; // 1000 USDC

        uint256 maxBorrow = calculator.calculateMaxBorrow(MARKET_ID, collateralValue);
        assertEq(maxBorrow, 500e6); // 50% of 1000 = 500 USDC
    }

    function test_IsBorrowingAllowed() public {
        // Normal tier - borrowing allowed
        assertTrue(calculator.isBorrowingAllowed(MARKET_ID));

        // Frozen tier - borrowing not allowed
        vm.warp(block.timestamp + 30 days - 12 hours);
        assertFalse(calculator.isBorrowingAllowed(MARKET_ID));
    }

    function test_UpdateLTVTiers() public {
        calculator.updateLTVTiers(6000, 4000, 2500);

        (uint256 normalLTV, uint256 mediumLTV, uint256 highLTV,) = calculator.getAllLTVTiers();
        assertEq(normalLTV, 6000);
        assertEq(mediumLTV, 4000);
        assertEq(highLTV, 2500);
    }

    function test_UpdateLTVTiers_RevertIfInvalid() public {
        // Normal LTV too high
        vm.expectRevert("Normal LTV too high");
        calculator.updateLTVTiers(11000, 4000, 2500);

        // Medium must be <= Normal
        vm.expectRevert("Medium must be <= Normal");
        calculator.updateLTVTiers(5000, 6000, 2500);

        // High must be <= Medium
        vm.expectRevert("High must be <= Medium");
        calculator.updateLTVTiers(5000, 3000, 4000);
    }

    function test_RevertForUnregisteredMarket() public {
        bytes32 unknownMarket = keccak256("unknown");

        vm.expectRevert(abi.encodeWithSelector(
            Errors.MarketNotRegistered.selector,
            unknownMarket
        ));
        calculator.getLTVTier(unknownMarket);
    }

    function test_GetLTVInfo() public view {
        (
            DataTypes.LTVTier tier,
            uint256 maxLTV,
            uint256 timeToResolution,
            bool isFrozen
        ) = calculator.getLTVInfo(MARKET_ID);

        assertEq(uint256(tier), uint256(DataTypes.LTVTier.NORMAL));
        assertEq(maxLTV, 5000);
        assertGt(timeToResolution, 29 days);
        assertFalse(isFrozen);
    }
}
