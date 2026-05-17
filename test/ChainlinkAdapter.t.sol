// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./BaseTest.sol";

contract ChainlinkAdapterTest is BaseTest {
    // Advance to a large timestamp so staleness subtractions don't underflow,
    // then refresh the mock feed so it isn't immediately considered stale.
    function setUp() public override {
        super.setUp();
        vm.warp(100_000);
        mockFeed.setPrice(2000e8); // resets _updatedAt to the new block.timestamp
    }

    // ─── validateFresh ────────────────────────────────────────────────────────

    function test_validateFresh_returnsCurrentPrice() public view {
        int256 price = oracle.validateFresh(address(mockFeed));
        assertEq(price, 2000e8);
    }

    function test_validateFresh_revert_stalePrice() public {
        // Make updatedAt older than MAX_STALENESS
        mockFeed.setUpdatedAt(block.timestamp - (oracle.MAX_STALENESS() + 1));
        vm.expectRevert();
        oracle.validateFresh(address(mockFeed));
    }

    function test_validateFresh_revert_negativePrice() public {
        mockFeed.setPrice(-1);
        vm.expectRevert();
        oracle.validateFresh(address(mockFeed));
    }

    function test_validateFresh_revert_zeroPrice() public {
        mockFeed.setPrice(0);
        vm.expectRevert();
        oracle.validateFresh(address(mockFeed));
    }

    function test_validateFresh_passesAtExactStalenessEdge() public {
        // updatedAt == block.timestamp - MAX_STALENESS: should NOT revert
        mockFeed.setUpdatedAt(block.timestamp - oracle.MAX_STALENESS());
        int256 price = oracle.validateFresh(address(mockFeed));
        assertGt(price, 0);
    }

    // ─── getLatestPrice (no staleness check) ─────────────────────────────────

    function test_getLatestPrice_noStalenessCheck() public {
        // Very stale — getLatestPrice should still succeed (no staleness guard)
        uint256 staleAt = block.timestamp - 10_000;
        mockFeed.setUpdatedAt(staleAt);
        (int256 price, uint256 updatedAt) = oracle.getLatestPrice(address(mockFeed));
        assertEq(price, 2000e8);
        assertEq(updatedAt, staleAt);
    }

    // ─── setStalenessOverride ─────────────────────────────────────────────────

    function test_setStalenessOverride_ownerCanSet() public {
        vm.prank(admin);
        oracle.setStalenessOverride(address(mockFeed), 100);
        assertEq(oracle.feedStaleness(address(mockFeed)), 100);
    }

    function test_setStalenessOverride_revert_nonOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        oracle.setStalenessOverride(address(mockFeed), 100);
    }

    function test_customStaleness_revertsWhenExceeded() public {
        vm.prank(admin);
        oracle.setStalenessOverride(address(mockFeed), 60);

        mockFeed.setUpdatedAt(block.timestamp - 61);
        vm.expectRevert();
        oracle.validateFresh(address(mockFeed));
    }

    function test_customStaleness_passesWithinWindow() public {
        vm.prank(admin);
        oracle.setStalenessOverride(address(mockFeed), 7200);

        mockFeed.setUpdatedAt(block.timestamp - 3600);
        int256 price = oracle.validateFresh(address(mockFeed));
        assertGt(price, 0);
    }

    // ─── Price updates ────────────────────────────────────────────────────────

    function test_priceUpdate_reflectsNewValue() public {
        mockFeed.setPrice(3500e8);
        int256 price = oracle.validateFresh(address(mockFeed));
        assertEq(price, 3500e8);
    }

    function test_defaultMaxStaleness_isOneHour() public view {
        assertEq(oracle.MAX_STALENESS(), 3600);
    }
}
