// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./BaseTest.sol";

contract OutcomeShareTokenTest is BaseTest {
    uint256 constant MKT_ID = 42;

    // ─── tokenId encoding ────────────────────────────────────────────────────

    function test_tokenId_encodesCorrectly() public view {
        assertEq(shareToken.tokenId(1, 0), 2); // 1*2+0
        assertEq(shareToken.tokenId(1, 1), 3); // 1*2+1
        assertEq(shareToken.tokenId(5, 0), 10);
        assertEq(shareToken.tokenId(5, 1), 11);
        assertEq(shareToken.tokenId(0, 0), 0);
    }

    function test_tokenId_revert_invalidOutcome() public {
        vm.expectRevert("OutcomeShareToken: outcome must be 0 or 1");
        shareToken.tokenId(1, 2);
    }

    function test_tokenId_revert_invalidOutcome_255() public {
        vm.expectRevert("OutcomeShareToken: outcome must be 0 or 1");
        shareToken.tokenId(1, 255);
    }

    // ─── Mint ─────────────────────────────────────────────────────────────────
    // Note: use startPrank/stopPrank so the role-getter call doesn't consume the prank.

    function test_mint_minterRoleCanMint() public {
        vm.startPrank(admin);
        shareToken.grantRole(shareToken.MINTER_ROLE(), admin);
        shareToken.mint(alice, MKT_ID, 1, 100e18);
        vm.stopPrank();

        assertEq(shareToken.balanceOf(alice, shareToken.tokenId(MKT_ID, 1)), 100e18);
    }

    function test_mint_revert_unauthorized() public {
        vm.prank(attacker);
        vm.expectRevert();
        shareToken.mint(attacker, MKT_ID, 1, 100e18);
    }

    function test_mint_emitsSharesMinted() public {
        vm.startPrank(admin);
        shareToken.grantRole(shareToken.MINTER_ROLE(), admin);

        vm.expectEmit(true, true, true, true);
        emit OutcomeShareToken.SharesMinted(MKT_ID, 1, alice, 50e18);
        shareToken.mint(alice, MKT_ID, 1, 50e18);
        vm.stopPrank();
    }

    // ─── Burn (role-gated) ────────────────────────────────────────────────────

    function test_burn_burnerRoleCanBurn() public {
        vm.startPrank(admin);
        shareToken.grantRole(shareToken.MINTER_ROLE(), admin);
        shareToken.grantRole(shareToken.BURNER_ROLE(), admin);
        shareToken.mint(alice, MKT_ID, 0, 200e18);
        shareToken.burn(alice, MKT_ID, 0, 100e18);
        vm.stopPrank();

        assertEq(shareToken.balanceOf(alice, shareToken.tokenId(MKT_ID, 0)), 100e18);
    }

    function test_burn_revert_unauthorized() public {
        vm.prank(attacker);
        vm.expectRevert();
        shareToken.burn(alice, MKT_ID, 0, 100e18);
    }

    // ─── burnSelf ─────────────────────────────────────────────────────────────

    function test_burnSelf_holderCanBurn() public {
        vm.startPrank(admin);
        shareToken.grantRole(shareToken.MINTER_ROLE(), admin);
        shareToken.mint(alice, MKT_ID, 1, 500e18);
        vm.stopPrank();

        uint256 tid = shareToken.tokenId(MKT_ID, 1);
        vm.prank(alice);
        shareToken.burnSelf(MKT_ID, 1, 200e18);

        assertEq(shareToken.balanceOf(alice, tid), 300e18);
    }

    function test_burnSelf_revert_insufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert();
        shareToken.burnSelf(MKT_ID, 1, 1);
    }

    // ─── supportsInterface ────────────────────────────────────────────────────

    function test_supportsInterface_erc1155() public view {
        assertTrue(shareToken.supportsInterface(0xd9b67a26));
    }

    function test_supportsInterface_accessControl() public view {
        assertTrue(shareToken.supportsInterface(0x7965db0b));
    }

    // ─── Role management ──────────────────────────────────────────────────────

    function test_adminCanGrantRoles() public {
        vm.startPrank(admin);
        shareToken.grantRole(shareToken.MINTER_ROLE(), bob);
        vm.stopPrank();

        assertTrue(shareToken.hasRole(shareToken.MINTER_ROLE(), bob));
    }

    function test_revokedMinterRole_cannotMint() public {
        vm.startPrank(admin);
        shareToken.grantRole(shareToken.MINTER_ROLE(), bob);
        shareToken.revokeRole(shareToken.MINTER_ROLE(), bob);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert();
        shareToken.mint(alice, MKT_ID, 0, 100e18);
    }
}
