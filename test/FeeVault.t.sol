// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./BaseTest.sol";

contract FeeVaultTest is BaseTest {
    // ─── Deposit / Withdraw ───────────────────────────────────────────────────

    function test_deposit_receivesShares() public {
        uint256 assets = 10_000e18;
        vm.startPrank(alice);
        collateral.approve(address(vault), assets);
        uint256 shares = vault.deposit(assets, alice);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);
        vm.stopPrank();
    }

    function test_withdraw_returnsAssets() public {
        uint256 assets = 10_000e18;
        vm.startPrank(alice);
        collateral.approve(address(vault), assets);
        vault.deposit(assets, alice);

        uint256 collBefore = collateral.balanceOf(alice);
        vault.withdraw(assets, alice, alice);
        assertEq(collateral.balanceOf(alice) - collBefore, assets);
        vm.stopPrank();
    }

    function test_redeem_returnsCorrectAssets() public {
        uint256 assets = 50_000e18;
        vm.startPrank(alice);
        collateral.approve(address(vault), assets);
        uint256 shares = vault.deposit(assets, alice);

        vault.redeem(shares, alice, alice);
        assertEq(vault.balanceOf(alice), 0);
        vm.stopPrank();
    }

    function test_mint_receivesCorrectShares() public {
        uint256 shares = 100e18;
        vm.startPrank(alice);
        collateral.approve(address(vault), type(uint256).max);
        uint256 paid = vault.mint(shares, alice);
        assertGt(paid, 0);
        assertEq(vault.balanceOf(alice), shares);
        vm.stopPrank();
    }

    // ─── Fee deposit increases share value ────────────────────────────────────

    function test_depositFee_increasesShareValue() public {
        uint256 assets = 10_000e18;
        vm.startPrank(alice);
        collateral.approve(address(vault), assets);
        uint256 sharesBefore = vault.deposit(assets, alice);
        vm.stopPrank();

        uint256 assetsBefore = vault.convertToAssets(sharesBefore);

        // Simulate fee from AMM
        vm.startPrank(admin);
        vault.grantRole(vault.FEE_DEPOSITOR_ROLE(), admin);
        collateral.approve(address(vault), 1000e18);
        vault.depositFee(1000e18);
        vm.stopPrank();

        uint256 assetsAfter = vault.convertToAssets(sharesBefore);
        assertGt(assetsAfter, assetsBefore);
    }

    // ─── ERC-4626 Rounding Invariants ────────────────────────────────────────

    function test_convertToShares_roundsDown() public view {
        // convertToShares should round down (protect vault)
        uint256 shares = vault.convertToShares(1);
        assertLe(shares, 1);
    }

    function test_convertToAssets_roundsDown() public {
        vm.startPrank(alice);
        collateral.approve(address(vault), 10_000e18);
        vault.deposit(10_000e18, alice);
        vm.stopPrank();

        uint256 assets = vault.convertToAssets(1);
        // 1 share → assets, should be <= actual assets per share
        assertGe(vault.totalAssets(), assets);
    }

    function test_previewDeposit_matchesActual() public {
        uint256 assets = 5_000e18;
        uint256 previewShares = vault.previewDeposit(assets);

        vm.startPrank(alice);
        collateral.approve(address(vault), assets);
        uint256 actualShares = vault.deposit(assets, alice);
        vm.stopPrank();

        assertEq(previewShares, actualShares);
    }

    function test_previewWithdraw_matchesActual() public {
        vm.startPrank(alice);
        collateral.approve(address(vault), 10_000e18);
        vault.deposit(10_000e18, alice);

        uint256 wantOut = 5_000e18;
        uint256 previewShares = vault.previewWithdraw(wantOut);
        uint256 actualShares  = vault.withdraw(wantOut, alice, alice);
        assertEq(previewShares, actualShares);
        vm.stopPrank();
    }

    // ─── Zero amount reverts ──────────────────────────────────────────────────

    function test_deposit_revert_zeroAssets() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(0, alice);
    }

    function test_redeem_revert_zeroShares() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(0, alice, alice);
    }

    // ─── Access control ───────────────────────────────────────────────────────

    function test_depositFee_revert_unauthorized() public {
        vm.prank(attacker);
        collateral.approve(address(vault), 1000e18);
        vm.expectRevert();
        vault.depositFee(1000e18);
    }

    // ─── maxDeposit / maxWithdraw ─────────────────────────────────────────────

    function test_maxDeposit_returnsMaxUint() public view {
        assertEq(vault.maxDeposit(alice), type(uint256).max);
    }

    function test_maxWithdraw_returnsZeroForNoShares() public view {
        assertEq(vault.maxWithdraw(attacker), 0);
    }
}
