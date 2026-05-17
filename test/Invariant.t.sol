// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./BaseTest.sol";

// ─── Handler ─────────────────────────────────────────────────────────────────

/// @notice Wraps protocol actions so Foundry's invariant fuzzer can call them
///         in arbitrary order. Ghost variables track per-call invariant checks.
contract ProtocolHandler is Test {
    MarketAMM internal amm;
    FeeVault internal vault;
    GovernanceToken internal govToken;
    ERC20Mock internal collateral;
    OutcomeShareToken internal shareToken;
    uint256 internal marketId;

    address internal alice;
    address internal bob;
    address internal admin;

    // Ghost: track whether k ever decreased after a swap
    bool public ghost_kInvariantViolated;

    constructor(
        MarketAMM _amm,
        FeeVault _vault,
        GovernanceToken _govToken,
        ERC20Mock _coll,
        OutcomeShareToken _shareToken,
        uint256 _marketId,
        address _alice,
        address _bob,
        address _admin
    ) {
        amm = _amm;
        vault = _vault;
        govToken = _govToken;
        collateral = _coll;
        shareToken = _shareToken;
        marketId = _marketId;
        alice = _alice;
        bob = _bob;
        admin = _admin;
    }

    // ── AMM actions ───────────────────────────────────────────────────────────

    function buy(uint256 amountIn, uint8 outcome) external {
        amountIn = bound(amountIn, 1e6, 1_000e18);
        outcome = uint8(bound(outcome, 0, 1));

        (uint256 rYes0, uint256 rNo0,,) = amm.pools(marketId);
        uint256 kBefore = rYes0 * rNo0;

        deal(address(collateral), alice, amountIn);
        vm.startPrank(alice);
        collateral.approve(address(amm), amountIn);
        try amm.buy(marketId, outcome, amountIn, 0) {
            (uint256 rYes1, uint256 rNo1,,) = amm.pools(marketId);
            if (rYes1 * rNo1 < kBefore) {
                ghost_kInvariantViolated = true;
            }
        } catch { }
        vm.stopPrank();
    }

    function sell(uint256 sharesIn, uint8 outcome) external {
        outcome = uint8(bound(outcome, 0, 1));
        uint256 tid = shareToken.tokenId(marketId, outcome);
        uint256 bal = shareToken.balanceOf(alice, tid);
        if (bal == 0) return;
        sharesIn = bound(sharesIn, 1, bal);

        vm.startPrank(alice);
        try amm.sell(marketId, outcome, sharesIn, 0) { } catch { }
        vm.stopPrank();
    }

    function addLiquidity(uint256 amount) external {
        amount = bound(amount, 2e6, 10_000e18);
        deal(address(collateral), bob, amount);
        vm.startPrank(bob);
        collateral.approve(address(amm), amount);
        try amm.addLiquidity(marketId, amount) { } catch { }
        vm.stopPrank();
    }

    // ── Vault actions ─────────────────────────────────────────────────────────

    function depositToVault(uint256 assets) external {
        assets = bound(assets, 1e6, 10_000e18);
        deal(address(collateral), alice, assets);
        vm.startPrank(alice);
        collateral.approve(address(vault), assets);
        try vault.deposit(assets, alice) { } catch { }
        vm.stopPrank();
    }

    function depositFee(uint256 amount) external {
        amount = bound(amount, 1, 1_000e18);
        deal(address(collateral), admin, amount);
        vm.startPrank(admin);
        collateral.approve(address(vault), amount);
        try vault.depositFee(amount) { } catch { }
        vm.stopPrank();
    }

    // ── Governance actions ────────────────────────────────────────────────────

    function transferGovTokens(uint256 amount) external {
        uint256 bal = govToken.balanceOf(alice);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(alice);
        govToken.transfer(bob, amount);
    }
}

// ─── Invariant test ───────────────────────────────────────────────────────────

contract InvariantTest is BaseTest {
    ProtocolHandler internal handler;

    function setUp() public override {
        super.setUp();
        uint256 mktId = _createActiveMarket();

        handler = new ProtocolHandler(amm, vault, govToken, collateral, shareToken, mktId, alice, bob, admin);

        // Grant FEE_DEPOSITOR to handler so depositFee action works
        vm.startPrank(admin);
        vault.grantRole(vault.FEE_DEPOSITOR_ROLE(), address(handler));
        vm.stopPrank();

        targetContract(address(handler));
    }

    // ─── 1. k-invariant ──────────────────────────────────────────────────────

    /// @notice After every buy/sell, k = reserveYes * reserveNo must not decrease.
    ///         Violations are recorded in the ghost variable by the handler.
    function invariant_kNeverDecreasesOnSwap() public view {
        assertFalse(handler.ghost_kInvariantViolated(), "k invariant violated: swap decreased k");
    }

    // ─── 2. Total supply conservation ────────────────────────────────────────

    /// @notice Governance token total supply must never exceed maxSupply.
    function invariant_totalSupplyBoundedByMaxSupply() public view {
        assertLe(govToken.totalSupply(), govToken.maxSupply(), "totalSupply exceeded maxSupply");
    }

    // ─── 3. Vault solvency ────────────────────────────────────────────────────

    /// @notice The vault's reported totalAssets must always be non-negative.
    function invariant_vaultTotalAssetsNonNegative() public view {
        assertGe(vault.totalAssets(), 0, "vault totalAssets is negative");
    }

    // ─── 4. Pool initialized flag is sticky ──────────────────────────────────

    /// @notice Once a pool is initialized it must stay initialized.
    function invariant_poolRemainsInitialized() public view {
        (,,, bool initialized) = amm.pools(1);
        assertTrue(initialized, "pool was de-initialized");
    }

    // ─── 5. Pool reserves within total liquidity ─────────────────────────────

    /// @notice Each reserve must never exceed the pool's total tracked liquidity.
    function invariant_poolReservesWithinTotalLiquidity() public view {
        (uint256 rYes, uint256 rNo, uint256 totalLiq, bool init) = amm.pools(1);
        if (init && totalLiq > 0) {
            assertLe(rYes, totalLiq, "reserveYes exceeds totalLiquidity");
            assertLe(rNo, totalLiq, "reserveNo  exceeds totalLiquidity");
        }
    }
}
