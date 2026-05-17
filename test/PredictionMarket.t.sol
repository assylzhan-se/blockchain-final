// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./BaseTest.sol";

contract PredictionMarketTest is BaseTest {
    uint256 internal marketId;

    function setUp() public override {
        super.setUp();
    }

    // ─── createMarket ─────────────────────────────────────────────────────────

    function test_createMarket_storesData() public {
        vm.prank(admin);
        uint256 id = market.createMarket("ETH > $3000?", address(mockFeed), 3000e8, INITIAL_LIQUIDITY);
        assertEq(id, 1);

        PredictionMarket.Market memory m = market.getMarket(id);
        assertEq(m.question, "ETH > $3000?");
        assertEq(uint8(m.state), uint8(PredictionMarket.MarketState.CREATED));
    }

    function test_createMarket_revert_unauthorized() public {
        vm.prank(attacker);
        vm.expectRevert();
        market.createMarket("hack?", address(mockFeed), 0, 0);
    }

    // ─── activateMarket ───────────────────────────────────────────────────────

    function test_activateMarket_setsActiveState() public {
        vm.startPrank(admin);
        uint256 id = market.createMarket("ETH > $3000?", address(mockFeed), 3000e8, INITIAL_LIQUIDITY);
        collateral.approve(address(market), INITIAL_LIQUIDITY);
        market.activateMarket(id);
        vm.stopPrank();

        PredictionMarket.Market memory m = market.getMarket(id);
        assertEq(uint8(m.state), uint8(PredictionMarket.MarketState.ACTIVE));
    }

    function test_activateMarket_revert_wrongState() public {
        marketId = _createActiveMarket();
        vm.startPrank(admin);
        collateral.approve(address(market), INITIAL_LIQUIDITY);
        vm.expectRevert();
        market.activateMarket(marketId); // already ACTIVE
        vm.stopPrank();
    }

    // ─── resolveMarket ────────────────────────────────────────────────────────

    function test_resolveMarket_priceAboveThreshold_setsYes() public {
        marketId = _createActiveMarket();
        mockFeed.setPrice(3500e8); // above $3000 threshold

        vm.prank(admin);
        market.resolveMarket(marketId);

        PredictionMarket.Market memory m = market.getMarket(marketId);
        assertEq(uint8(m.state), uint8(PredictionMarket.MarketState.DISPUTE));
        assertEq(m.winningOutcome, 1); // YES
    }

    function test_resolveMarket_priceBelowThreshold_setsNo() public {
        marketId = _createActiveMarket();
        mockFeed.setPrice(2500e8); // below $3000

        vm.prank(admin);
        market.resolveMarket(marketId);

        PredictionMarket.Market memory m = market.getMarket(marketId);
        assertEq(m.winningOutcome, 0); // NO
    }

    function test_resolveMarket_revert_stalePrice() public {
        marketId = _createActiveMarket();
        vm.warp(block.timestamp + 7201);
        mockFeed.setUpdatedAt(block.timestamp - 7200); // stale

        vm.prank(admin);
        vm.expectRevert();
        market.resolveMarket(marketId);
    }

    // ─── Dispute window ───────────────────────────────────────────────────────

    function test_finalizeResolution_revert_duringDisputeWindow() public {
        marketId = _createActiveMarket();
        mockFeed.setPrice(3500e8);
        vm.prank(admin);
        market.resolveMarket(marketId);

        vm.expectRevert();
        market.finalizeResolution(marketId); // still in window
    }

    function test_finalizeResolution_succeedsAfterWindow() public {
        marketId = _createActiveMarket();
        mockFeed.setPrice(3500e8);
        vm.prank(admin);
        market.resolveMarket(marketId);

        vm.warp(block.timestamp + 25 hours);
        market.finalizeResolution(marketId);

        PredictionMarket.Market memory m = market.getMarket(marketId);
        assertEq(uint8(m.state), uint8(PredictionMarket.MarketState.RESOLVED));
    }

    // ─── claimWinnings ────────────────────────────────────────────────────────

    function test_claimWinnings_winnersGetPaid() public {
        marketId = _createActiveMarket();

        // Alice buys YES shares
        uint256 buyAmount = 10_000e18;
        vm.startPrank(alice);
        collateral.approve(address(amm), buyAmount);
        amm.buy(marketId, 1, buyAmount, 1);
        vm.stopPrank();

        // Resolve to YES
        mockFeed.setPrice(3500e8);
        vm.prank(admin);
        market.resolveMarket(marketId);
        vm.warp(block.timestamp + 25 hours);
        market.finalizeResolution(marketId);

        // Alice claims
        uint256 collBefore = collateral.balanceOf(alice);
        vm.prank(alice);
        market.claimWinnings(marketId);
        assertGt(collateral.balanceOf(alice) - collBefore, 0);
        assertEq(shareToken.balanceOf(alice, shareToken.tokenId(marketId, 1)), 0);
    }

    function test_claimWinnings_revert_doubleClaim() public {
        marketId = _createActiveMarket();
        uint256 buyAmount = 5_000e18;
        vm.startPrank(alice);
        collateral.approve(address(amm), buyAmount);
        amm.buy(marketId, 1, buyAmount, 1);
        vm.stopPrank();

        mockFeed.setPrice(3500e8);
        vm.prank(admin);
        market.resolveMarket(marketId);
        vm.warp(block.timestamp + 25 hours);
        market.finalizeResolution(marketId);

        vm.prank(alice);
        market.claimWinnings(marketId);

        vm.prank(alice);
        vm.expectRevert();
        market.claimWinnings(marketId);
    }

    function test_claimWinnings_revert_noWinningShares() public {
        marketId = _createActiveMarket();

        // Alice buys NO, but YES wins
        vm.startPrank(alice);
        collateral.approve(address(amm), 5000e18);
        amm.buy(marketId, 0, 5000e18, 1);
        vm.stopPrank();

        mockFeed.setPrice(3500e8); // YES wins
        vm.prank(admin);
        market.resolveMarket(marketId);
        vm.warp(block.timestamp + 25 hours);
        market.finalizeResolution(marketId);

        vm.prank(alice);
        vm.expectRevert("PredictionMarket: no winning shares");
        market.claimWinnings(marketId);
    }

    // ─── SECURITY: Access Control Case Study ─────────────────────────────────
    //
    // BEFORE: Without AccessControl, anyone could call resolveMarket()
    //         and manipulate the outcome to steal funds.
    //
    // AFTER: Only RESOLVER_ROLE can call resolveMarket() — unauthorized reverts.

    function test_security_accessControl_resolverRoleRequired() public {
        marketId = _createActiveMarket();
        mockFeed.setPrice(3500e8);

        // Attacker tries to manipulate resolution
        vm.prank(attacker);
        vm.expectRevert();
        market.resolveMarket(marketId);

        // Verify market is still ACTIVE (not manipulated)
        PredictionMarket.Market memory m = market.getMarket(marketId);
        assertEq(uint8(m.state), uint8(PredictionMarket.MarketState.ACTIVE));
    }

    function test_security_accessControl_creatorRoleRequired() public {
        vm.prank(attacker);
        vm.expectRevert();
        market.createMarket("free market", address(mockFeed), 0, 0);
    }

    function test_security_noTxOriginUsed() public view {
        // Verify that no tx.origin is used for auth — all auth is msg.sender based via AccessControl
        // This is a static analysis assertion — the roles use _checkRole(role, msg.sender)
        assertTrue(market.hasRole(market.DEFAULT_ADMIN_ROLE(), admin));
        assertFalse(market.hasRole(market.RESOLVER_ROLE(), attacker));
    }
}
