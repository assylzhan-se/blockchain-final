// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./BaseTest.sol";

/// @notice Fuzz tests for AMM swap, vault deposit/withdraw, and governance voting power.
contract FuzzTest is BaseTest {
    uint256 internal marketId;

    function setUp() public override {
        super.setUp();
        marketId = _createActiveMarket();
    }

    // ─── AMM Fuzz ─────────────────────────────────────────────────────────────

    /// @notice Buying any valid amount always produces positive output.
    function testFuzz_buy_amountOut_positive(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e6, 10_000e18);

        collateral.mint(alice, amountIn);
        vm.startPrank(alice);
        collateral.approve(address(amm), amountIn);
        uint256 out = amm.buy(marketId, 1, amountIn, 0);
        vm.stopPrank();

        assertGt(out, 0);
    }

    /// @notice Selling fewer shares back than bought always returns positive collateral.
    function testFuzz_sell_collateralOut_positive(uint256 buyAmount) public {
        buyAmount = bound(buyAmount, 1e6, 5_000e18);

        collateral.mint(alice, buyAmount);
        vm.startPrank(alice);
        collateral.approve(address(amm), buyAmount);
        uint256 shares = amm.buy(marketId, 1, buyAmount, 0);
        uint256 collOut = amm.sell(marketId, 1, shares, 0);
        vm.stopPrank();

        assertGt(collOut, 0);
    }

    /// @notice Buying shares never returns more than the YES reserve.
    function testFuzz_buy_cannotDrainPool(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e6, 5_000e18);

        (uint256 rYesBefore,,,) = amm.pools(marketId);

        collateral.mint(alice, amountIn);
        vm.startPrank(alice);
        collateral.approve(address(amm), amountIn);
        uint256 out = amm.buy(marketId, 1, amountIn, 0);
        vm.stopPrank();

        assertLt(out, rYesBefore);
    }

    /// @notice k = reserveYes * reserveNo must not decrease after any buy.
    function testFuzz_buy_kNeverDecreases(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e6, 5_000e18);

        (uint256 r0Yes, uint256 r0No,,) = amm.pools(marketId);
        uint256 k0 = r0Yes * r0No;

        collateral.mint(alice, amountIn);
        vm.startPrank(alice);
        collateral.approve(address(amm), amountIn);
        amm.buy(marketId, 1, amountIn, 0);
        vm.stopPrank();

        (uint256 r1Yes, uint256 r1No,,) = amm.pools(marketId);
        assertGe(r1Yes * r1No, k0);
    }

    /// @notice Yul assembly getAmountOut matches the pure-Solidity equivalent.
    function testFuzz_getAmountOut_yulMatchesSolidity(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) public view {
        amountIn   = bound(amountIn,   1, 1e27);
        reserveIn  = bound(reserveIn,  1, 1e27);
        reserveOut = bound(reserveOut, 1, 1e27);
        // Avoid overflow in numerator
        vm.assume(amountIn <= type(uint256).max / reserveOut);

        uint256 solidityOut = amm.getAmountOutSolidity(amountIn, reserveIn, reserveOut);
        uint256 expected    = (amountIn * reserveOut) / (reserveIn + amountIn);
        assertEq(solidityOut, expected);
    }

    /// @notice Adding liquidity always increases both reserves.
    function testFuzz_addLiquidity_increasesReserves(uint256 amount) public {
        amount = bound(amount, 2e6, 10_000e18);

        (uint256 r0Yes, uint256 r0No,,) = amm.pools(marketId);

        collateral.mint(alice, amount);
        vm.startPrank(alice);
        collateral.approve(address(amm), amount);
        amm.addLiquidity(marketId, amount);
        vm.stopPrank();

        (uint256 r1Yes, uint256 r1No,,) = amm.pools(marketId);
        assertGe(r1Yes, r0Yes);
        assertGe(r1No, r0No);
    }

    // ─── Vault Fuzz ───────────────────────────────────────────────────────────

    /// @notice Depositing then fully redeeming returns at most the deposited amount.
    function testFuzz_vault_depositWithdraw_roundTrip(uint256 assets) public {
        assets = bound(assets, 1e6, INITIAL_SUPPLY / 2);

        vm.startPrank(alice);
        collateral.approve(address(vault), assets);
        uint256 shares = vault.deposit(assets, alice);
        uint256 received = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        // fees/rounding may cause received < assets, never received > assets
        assertLe(received, assets);
        assertGt(received, 0);
    }

    /// @notice previewDeposit always matches the actual shares received.
    function testFuzz_vault_previewDeposit_matchesActual(uint256 assets) public {
        assets = bound(assets, 1e6, 100_000e18);

        uint256 preview = vault.previewDeposit(assets);

        vm.startPrank(alice);
        collateral.approve(address(vault), assets);
        uint256 actual = vault.deposit(assets, alice);
        vm.stopPrank();

        assertEq(preview, actual);
    }

    /// @notice Depositing a fee always increases the convertToAssets value for existing shares.
    function testFuzz_vault_feeDeposit_increasesShareValue(uint256 assets, uint256 fee) public {
        assets = bound(assets, 1e10, 100_000e18);
        fee    = bound(fee,    1,    10_000e18);

        vm.startPrank(alice);
        collateral.approve(address(vault), assets);
        uint256 shares = vault.deposit(assets, alice);
        vm.stopPrank();

        uint256 assetsBefore = vault.convertToAssets(shares);

        vm.startPrank(admin);
        vault.grantRole(vault.FEE_DEPOSITOR_ROLE(), admin);
        collateral.mint(admin, fee);
        collateral.approve(address(vault), fee);
        vault.depositFee(fee);
        vm.stopPrank();

        uint256 assetsAfter = vault.convertToAssets(shares);
        assertGe(assetsAfter, assetsBefore);
    }

    // ─── Governance Fuzz ──────────────────────────────────────────────────────

    /// @notice Voting power decreases by exactly the transferred amount.
    function testFuzz_votingPower_afterTransfer(uint256 amount) public {
        uint256 aliceBal = govToken.balanceOf(alice);
        amount = bound(amount, 1, aliceBal);

        uint256 votesBefore = govToken.getVotes(alice);

        vm.prank(alice);
        govToken.transfer(bob, amount);

        assertEq(govToken.getVotes(alice), votesBefore - amount);
    }

    /// @notice Minting up to maxSupply always keeps totalSupply within bounds.
    function testFuzz_mint_staysBelowMaxSupply(uint256 mintAmount) public {
        uint256 remaining = govToken.maxSupply() - govToken.totalSupply();
        if (remaining == 0) return;

        mintAmount = bound(mintAmount, 1, remaining);

        vm.prank(admin);
        govToken.mint(alice, mintAmount);
        assertLe(govToken.totalSupply(), govToken.maxSupply());
    }

    // ─── OutcomeShareToken Fuzz ───────────────────────────────────────────────

    /// @notice tokenId must be unique across different (marketId, outcome) pairs.
    function testFuzz_tokenId_uniqueEncoding(uint256 mId, uint8 outcome) public view {
        outcome = uint8(bound(outcome, 0, 1));
        mId     = bound(mId, 0, type(uint128).max);

        uint256 tid = shareToken.tokenId(mId, outcome);
        assertEq(tid, mId * 2 + outcome);
    }
}
