// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/oracle/PolymarketTWAPOracle.sol";
import "../../src/libraries/Errors.sol";

contract PolymarketTWAPOracleTest is Test {
    PolymarketTWAPOracle public oracle;

    uint256 constant TOKEN_ID = 1;
    uint256 constant INITIAL_PRICE = 0.5e18; // 50%

    function setUp() public {
        oracle = new PolymarketTWAPOracle();
    }

    function test_RecordObservation() public {
        oracle.recordObservation(TOKEN_ID, INITIAL_PRICE);

        (uint256 price, uint256 timestamp) = oracle.getLatestPrice(TOKEN_ID);
        assertEq(price, INITIAL_PRICE);
        assertEq(timestamp, block.timestamp);
    }

    function test_TWAPCalculation() public {
        // Record first observation
        oracle.recordObservation(TOKEN_ID, 0.5e18);

        // Advance time and record another
        vm.warp(block.timestamp + 10 minutes);
        oracle.recordObservation(TOKEN_ID, 0.6e18);

        (uint256 twap,) = oracle.getTWAP(TOKEN_ID);

        // TWAP should be between the two prices
        assertGe(twap, 0.5e18);
        assertLe(twap, 0.6e18);
    }

    function test_CircuitBreaker_TriggeredOnLargeDeviation() public {
        // Record initial observations
        oracle.recordObservation(TOKEN_ID, 0.5e18);
        vm.warp(block.timestamp + 1 minutes);
        oracle.recordObservation(TOKEN_ID, 0.5e18);

        // Try to record a price with >8% deviation
        vm.warp(block.timestamp + 1 minutes);
        oracle.recordObservation(TOKEN_ID, 0.6e18); // 20% deviation

        // Circuit breaker should be triggered
        assertTrue(oracle.isCircuitBreakerTriggered(TOKEN_ID));
    }

    function test_CircuitBreaker_NotTriggeredOnSmallDeviation() public {
        // Record initial observations
        oracle.recordObservation(TOKEN_ID, 0.5e18);
        vm.warp(block.timestamp + 1 minutes);
        oracle.recordObservation(TOKEN_ID, 0.5e18);

        // Record a price with <8% deviation
        vm.warp(block.timestamp + 1 minutes);
        oracle.recordObservation(TOKEN_ID, 0.52e18); // 4% deviation

        // Circuit breaker should NOT be triggered
        assertFalse(oracle.isCircuitBreakerTriggered(TOKEN_ID));
    }

    function test_PriceStaleness() public {
        // No observations - should be stale
        assertTrue(oracle.isPriceStale(TOKEN_ID));

        // Record observation
        oracle.recordObservation(TOKEN_ID, INITIAL_PRICE);
        assertFalse(oracle.isPriceStale(TOKEN_ID));

        // Advance past staleness threshold (5 minutes)
        vm.warp(block.timestamp + 6 minutes);
        assertTrue(oracle.isPriceStale(TOKEN_ID));
    }

    function test_InsufficientObservations() public {
        // Only one observation
        oracle.recordObservation(TOKEN_ID, INITIAL_PRICE);

        vm.expectRevert(abi.encodeWithSelector(
            Errors.InsufficientObservations.selector,
            1,
            2
        ));
        oracle.getTWAP(TOKEN_ID);
    }

    function test_InvalidPrice() public {
        // Price > 1e18 is invalid
        vm.expectRevert(Errors.InvalidPrice.selector);
        oracle.recordObservation(TOKEN_ID, 1.1e18);
    }

    function test_AuthorizedUpdater() public {
        address updater = address(0x123);

        // Unauthorized updater should fail
        vm.prank(updater);
        vm.expectRevert(Errors.NotAuthorizedUpdater.selector);
        oracle.recordObservation(TOKEN_ID, INITIAL_PRICE);

        // Authorize and retry
        oracle.authorizeUpdater(updater);

        vm.prank(updater);
        oracle.recordObservation(TOKEN_ID, INITIAL_PRICE);

        (uint256 price,) = oracle.getLatestPrice(TOKEN_ID);
        assertEq(price, INITIAL_PRICE);
    }

    function test_RevokeUpdater() public {
        address updater = address(0x123);
        oracle.authorizeUpdater(updater);

        // Should work
        vm.prank(updater);
        oracle.recordObservation(TOKEN_ID, INITIAL_PRICE);

        // Revoke
        oracle.revokeUpdater(updater);

        // Should fail now
        vm.prank(updater);
        vm.expectRevert(Errors.NotAuthorizedUpdater.selector);
        oracle.recordObservation(TOKEN_ID, 0.6e18);
    }

    function test_ResetCircuitBreaker() public {
        // Trigger circuit breaker
        oracle.recordObservation(TOKEN_ID, 0.5e18);
        vm.warp(block.timestamp + 1 minutes);
        oracle.recordObservation(TOKEN_ID, 0.5e18);
        vm.warp(block.timestamp + 1 minutes);
        oracle.recordObservation(TOKEN_ID, 0.8e18); // Large deviation

        assertTrue(oracle.isCircuitBreakerTriggered(TOKEN_ID));

        // Reset
        oracle.resetCircuitBreaker(TOKEN_ID);
        assertFalse(oracle.isCircuitBreakerTriggered(TOKEN_ID));
    }

    function test_BatchRecordObservations() public {
        uint256[] memory tokenIds = new uint256[](3);
        uint256[] memory prices = new uint256[](3);

        tokenIds[0] = 1;
        tokenIds[1] = 2;
        tokenIds[2] = 3;
        prices[0] = 0.5e18;
        prices[1] = 0.6e18;
        prices[2] = 0.7e18;

        oracle.batchRecordObservations(tokenIds, prices);

        (uint256 price1,) = oracle.getLatestPrice(1);
        (uint256 price2,) = oracle.getLatestPrice(2);
        (uint256 price3,) = oracle.getLatestPrice(3);

        assertEq(price1, 0.5e18);
        assertEq(price2, 0.6e18);
        assertEq(price3, 0.7e18);
    }

    function test_RingBufferOverflow() public {
        // Fill up the ring buffer (60 observations)
        for (uint256 i = 0; i < 65; i++) {
            vm.warp(block.timestamp + 30 seconds);
            uint256 price = 0.5e18 + (i * 0.001e18); // Slowly increasing price
            if (price > 1e18) price = 1e18;
            oracle.recordObservation(TOKEN_ID, price);
        }

        // Should still work and have 60 observations
        assertEq(oracle.getObservationCount(TOKEN_ID), 60);

        // TWAP should still be calculable
        (uint256 twap,) = oracle.getTWAP(TOKEN_ID);
        assertGt(twap, 0);
    }
}
