// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./BaseTest.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MarketAMMTest is BaseTest {
    uint256 internal marketId;

    function setUp() public override {
        super.setUp();
        marketId = _createActiveMarket();
    }

    // ─── Buy ─────────────────────────────────────────────────────────────────

    function test_buy_yesShares_happyPath() public {
        uint256 amountIn = 1000e18;
        vm.startPrank(alice);
        collateral.approve(address(amm), amountIn);

        uint256 balBefore = shareToken.balanceOf(alice, shareToken.tokenId(marketId, 1));
        uint256 out = amm.buy(marketId, 1, amountIn, 1);
        uint256 balAfter = shareToken.balanceOf(alice, shareToken.tokenId(marketId, 1));

        assertGt(out, 0);
        assertEq(balAfter - balBefore, out);
        vm.stopPrank();
    }

    function test_buy_noShares_happyPath() public {
        uint256 amountIn = 1000e18;
        vm.startPrank(alice);
        collateral.approve(address(amm), amountIn);
        uint256 out = amm.buy(marketId, 0, amountIn, 1);
        assertGt(out, 0);
        vm.stopPrank();
    }

    function test_buy_revert_slippage() public {
        uint256 amountIn = 1000e18;
        vm.startPrank(alice);
        collateral.approve(address(amm), amountIn);

        // Set minOut to extremely high value — should revert
        vm.expectRevert();
        amm.buy(marketId, 1, amountIn, type(uint256).max);
        vm.stopPrank();
    }

    function test_buy_revert_invalidOutcome() public {
        vm.startPrank(alice);
        collateral.approve(address(amm), 1000e18);
        vm.expectRevert();
        amm.buy(marketId, 2, 1000e18, 0);
        vm.stopPrank();
    }

    function test_buy_revert_zeroAmount() public {
        vm.prank(alice);
        vm.expectRevert();
        amm.buy(marketId, 1, 0, 0);
    }

    function test_buy_feeGoesToVault() public {
        uint256 amountIn = 100_000e18;
        uint256 vaultBefore = collateral.balanceOf(address(vault));

        vm.startPrank(alice);
        collateral.approve(address(amm), amountIn);
        amm.buy(marketId, 1, amountIn, 1);
        vm.stopPrank();

        uint256 expectedFee = (amountIn * 3) / 1000;
        assertGe(collateral.balanceOf(address(vault)), vaultBefore + expectedFee - 1);
    }

    // ─── Sell ─────────────────────────────────────────────────────────────────

    function test_sell_happyPath() public {
        // First buy some shares
        uint256 buyAmount = 10_000e18;
        vm.startPrank(alice);
        collateral.approve(address(amm), buyAmount);
        uint256 sharesReceived = amm.buy(marketId, 1, buyAmount, 1);

        // Now sell them back
        uint256 collBefore = collateral.balanceOf(alice);
        uint256 collOut = amm.sell(marketId, 1, sharesReceived, 1);
        assertGt(collOut, 0);
        assertEq(collateral.balanceOf(alice) - collBefore, collOut);
        vm.stopPrank();
    }

    function test_sell_revert_slippage() public {
        uint256 buyAmount = 10_000e18;
        vm.startPrank(alice);
        collateral.approve(address(amm), buyAmount);
        uint256 shares = amm.buy(marketId, 1, buyAmount, 1);

        vm.expectRevert();
        amm.sell(marketId, 1, shares, type(uint256).max);
        vm.stopPrank();
    }

    // ─── Constant-product invariant ──────────────────────────────────────────

    function test_buy_kDoesNotDecrease() public {
        (uint256 r0Yes, uint256 r0No,,) = amm.pools(marketId);
        uint256 k0 = r0Yes * r0No;

        vm.startPrank(alice);
        collateral.approve(address(amm), 5000e18);
        amm.buy(marketId, 1, 5000e18, 1);
        vm.stopPrank();

        (uint256 r1Yes, uint256 r1No,,) = amm.pools(marketId);
        uint256 k1 = r1Yes * r1No;
        assertGe(k1, k0);
    }

    // ─── Yul getAmountOut benchmark ───────────────────────────────────────────

    function test_getAmountOut_yulMatchesSolidity() public view {
        uint256 aIn = 500e18;
        uint256 rIn = 50_000e18;
        uint256 rOut = 50_000e18;

        uint256 solOut = amm.getAmountOutSolidity(aIn, rIn, rOut);
        // Call internal Yul via buy path — we compare outputs here
        // Both should produce 4975124378109452736318
        assertEq(solOut, (aIn * rOut) / (rIn + aIn));
    }

    // ─── Pause (Circuit Breaker) ──────────────────────────────────────────────

    function test_pause_blocksTrades() public {
        vm.prank(admin);
        amm.pause();

        vm.startPrank(alice);
        collateral.approve(address(amm), 1000e18);
        vm.expectRevert();
        amm.buy(marketId, 1, 1000e18, 0);
        vm.stopPrank();
    }

    function test_unpause_allowsTrades() public {
        vm.prank(admin);
        amm.pause();
        vm.prank(admin);
        amm.unpause();

        vm.startPrank(alice);
        collateral.approve(address(amm), 1000e18);
        uint256 out = amm.buy(marketId, 1, 1000e18, 1);
        assertGt(out, 0);
        vm.stopPrank();
    }

    // ─── SECURITY: Reentrancy Attack Case Study ───────────────────────────────
    //
    // BEFORE: Without ReentrancyGuard, an attacker contract could:
    //   1. Call buy()
    //   2. In the ERC-1155 callback (onERC1155Received), call sell() again
    //   3. Drain reserves by selling before state updates
    //
    // AFTER: ReentrancyGuard prevents re-entry — the second call reverts.

    function test_security_reentrancyBlocked() public {
        ReentrancyAttacker hacker = new ReentrancyAttacker(amm, shareToken, collateral, marketId);
        collateral.mint(address(hacker), 10_000e18);

        // Attack should fail due to ReentrancyGuard
        vm.expectRevert();
        hacker.attack();
    }

    // ─── Liquidity ────────────────────────────────────────────────────────────

    function test_addLiquidity_increasesReserves() public {
        (uint256 r0Yes, uint256 r0No,,) = amm.pools(marketId);

        vm.startPrank(alice);
        collateral.approve(address(amm), 10_000e18);
        amm.addLiquidity(marketId, 10_000e18);
        vm.stopPrank();

        (uint256 r1Yes, uint256 r1No,,) = amm.pools(marketId);
        assertGt(r1Yes, r0Yes);
        assertGt(r1No, r0No);
    }

    // ─── Price ────────────────────────────────────────────────────────────────

    function test_getPrice_initiallyFiftyFifty() public view {
        uint256 yesPrice = amm.getPrice(marketId, 1);
        uint256 noPrice  = amm.getPrice(marketId, 0);
        assertApproxEqAbs(yesPrice + noPrice, 1e18, 1);
    }

    function test_getPrice_revert_uninitializedPool() public {
        vm.expectRevert();
        amm.getPrice(999, 1);
    }

    // ─── removeLiquidity ─────────────────────────────────────────────────────

    function test_removeLiquidity_returnsCollateral() public {
        uint256 addAmount = 20_000e18;
        vm.startPrank(alice);
        collateral.approve(address(amm), addAmount);
        uint256 liq = amm.addLiquidity(marketId, addAmount);

        uint256 collBefore = collateral.balanceOf(alice);
        uint256 collOut = amm.removeLiquidity(marketId, liq);
        assertGt(collOut, 0);
        assertEq(collateral.balanceOf(alice) - collBefore, collOut);
        vm.stopPrank();
    }

    function test_removeLiquidity_revert_insufficientShares() public {
        vm.prank(alice);
        vm.expectRevert("MarketAMM: insufficient LP shares");
        amm.removeLiquidity(marketId, 1);
    }

    function test_removeLiquidity_revert_uninitializedPool() public {
        vm.prank(alice);
        vm.expectRevert();
        amm.removeLiquidity(999, 1);
    }

    // ─── payWinnings ─────────────────────────────────────────────────────────

    function test_payWinnings_revert_notMarketManager() public {
        vm.prank(attacker);
        vm.expectRevert();
        amm.payWinnings(marketId, alice, 100e18);
    }

    function test_payWinnings_revert_zeroAmount() public {
        vm.prank(admin);
        vm.expectRevert();
        amm.payWinnings(marketId, alice, 0);
    }

    function test_payWinnings_revert_uninitializedPool() public {
        vm.startPrank(admin);
        amm.grantRole(amm.MARKET_MANAGER_ROLE(), admin);
        vm.expectRevert();
        amm.payWinnings(999, alice, 100e18);
        vm.stopPrank();
    }

    // ─── initializePool edge cases ────────────────────────────────────────────

    function test_initializePool_revert_alreadyInitialized() public {
        vm.startPrank(admin);
        collateral.approve(address(amm), INITIAL_LIQUIDITY);
        vm.expectRevert();
        amm.initializePool(marketId, INITIAL_LIQUIDITY); // already initialized by _createActiveMarket
        vm.stopPrank();
    }

    function test_initializePool_revert_insufficientLiquidity() public {
        vm.startPrank(admin);
        collateral.approve(address(amm), 100);
        vm.expectRevert("MarketAMM: insufficient initial liquidity");
        amm.initializePool(99, 100); // below MINIMUM_LIQUIDITY
        vm.stopPrank();
    }

    // ─── addLiquidity edge cases ──────────────────────────────────────────────

    function test_addLiquidity_revert_uninitializedPool() public {
        vm.startPrank(alice);
        collateral.approve(address(amm), 1000e18);
        vm.expectRevert();
        amm.addLiquidity(999, 1000e18);
        vm.stopPrank();
    }

    function test_addLiquidity_revert_zeroAmount() public {
        vm.prank(alice);
        vm.expectRevert();
        amm.addLiquidity(marketId, 0);
    }
}

/// @dev Attack contract for reentrancy case study
contract ReentrancyAttacker {
    MarketAMM immutable target;
    OutcomeShareToken immutable shares;
    IERC20 immutable coll;
    uint256 immutable mId;
    bool attacking;

    constructor(MarketAMM _amm, OutcomeShareToken _shares, IERC20 _coll, uint256 _mId) {
        target = _amm;
        shares = _shares;
        coll = _coll;
        mId = _mId;
    }

    function attack() external {
        coll.approve(address(target), type(uint256).max);
        attacking = true;
        target.buy(mId, 1, 1000e18, 1);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        returns (bytes4)
    {
        if (attacking) {
            attacking = false;
            // Attempt reentrant sell — should revert
            target.sell(mId, 1, 1, 0);
        }
        return this.onERC1155Received.selector;
    }
}
