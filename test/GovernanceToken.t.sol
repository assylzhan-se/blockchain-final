// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./BaseTest.sol";

contract GovernanceTokenTest is BaseTest {
    // ─── Initialization ───────────────────────────────────────────────────────

    function test_initialize_setsNameAndSymbol() public view {
        assertEq(govToken.name(), "Prediction Market Governance");
        assertEq(govToken.symbol(), "PMG");
    }

    function test_initialize_mintsInitialSupply() public view {
        assertEq(govToken.balanceOf(admin), INITIAL_SUPPLY - 150_000e18); // after transfers in setUp
    }

    function test_initialize_setsMaxSupply() public view {
        assertEq(govToken.maxSupply(), MAX_SUPPLY);
    }

    // ─── Mint ─────────────────────────────────────────────────────────────────

    function test_mint_ownerCanMint() public {
        vm.prank(admin);
        govToken.mint(alice, 1000e18);
        assertEq(govToken.balanceOf(alice), 101_000e18);
    }

    function test_mint_revert_nonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        govToken.mint(alice, 1000e18);
    }

    function test_mint_revert_exceedsMaxSupply() public {
        vm.prank(admin);
        vm.expectRevert("GovernanceToken: exceeds max supply");
        govToken.mint(alice, MAX_SUPPLY);
    }

    // ─── Voting ───────────────────────────────────────────────────────────────

    function test_delegate_updatesVotingPower() public {
        vm.prank(alice);
        govToken.delegate(alice);
        assertGt(govToken.getVotes(alice), 0);
    }

    function test_getPastVotes_afterTransfer() public {
        vm.roll(block.number + 1);
        uint256 pastVotes = govToken.getPastVotes(alice, block.number - 1);
        assertGt(pastVotes, 0);
    }

    function test_transfer_movesVotingPower() public {
        uint256 votesBefore = govToken.getVotes(alice);
        vm.prank(alice);
        assertTrue(govToken.transfer(bob, 10_000e18));
        // Bob hasn't delegated yet, so his votes = 0; alice's votes decreased
        assertLt(govToken.getVotes(alice), votesBefore);
    }

    // ─── Permit ───────────────────────────────────────────────────────────────

    function test_permit_valid() public {
        uint256 privateKey = 0xA11CE;
        address signer = vm.addr(privateKey);
        vm.prank(admin);
        govToken.mint(signer, 1000e18);

        uint256 nonce = govToken.nonces(signer);
        uint256 deadline = block.timestamp + 1 days;

        bytes32 domainSeparator = govToken.DOMAIN_SEPARATOR();
        bytes32 structHash = keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            signer,
            bob,
            500e18,
            nonce,
            deadline
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        govToken.permit(signer, bob, 500e18, deadline, v, r, s);
        assertEq(govToken.allowance(signer, bob), 500e18);
    }

    function test_permit_revert_expiredDeadline() public {
        vm.warp(1000);
        vm.expectRevert();
        govToken.permit(alice, bob, 100e18, 999, 0, bytes32(0), bytes32(0));
    }

    // ─── UUPS Upgrade ─────────────────────────────────────────────────────────

    function test_upgrade_V1toV2() public {
        GovernanceTokenV2 v2Impl = new GovernanceTokenV2();

        vm.prank(admin);
        govToken.upgradeToAndCall(address(v2Impl), "");

        GovernanceTokenV2 v2 = GovernanceTokenV2(address(govToken));
        assertEq(v2.version(), "2.0.0");

        // V2 has burn
        vm.prank(alice);
        v2.burn(1000e18);
        assertEq(v2.balanceOf(alice), 99_000e18);
    }

    function test_upgrade_revert_nonOwner() public {
        GovernanceTokenV2 v2Impl = new GovernanceTokenV2();
        vm.prank(alice);
        vm.expectRevert();
        govToken.upgradeToAndCall(address(v2Impl), "");
    }

    function test_upgrade_storageLayoutPreserved() public {
        uint256 balanceBefore = govToken.balanceOf(alice);
        uint256 supplyBefore  = govToken.totalSupply();

        GovernanceTokenV2 v2Impl = new GovernanceTokenV2();
        vm.prank(admin);
        govToken.upgradeToAndCall(address(v2Impl), "");

        assertEq(govToken.balanceOf(alice), balanceBefore);
        assertEq(govToken.totalSupply(), supplyBefore);
    }

    function test_v2_burnFrom_withAllowance() public {
        GovernanceTokenV2 v2Impl = new GovernanceTokenV2();
        vm.prank(admin);
        govToken.upgradeToAndCall(address(v2Impl), "");
        GovernanceTokenV2 v2 = GovernanceTokenV2(address(govToken));

        vm.prank(alice);
        v2.approve(bob, 5_000e18);

        uint256 balBefore = v2.balanceOf(alice);
        vm.prank(bob);
        v2.burnFrom(alice, 5_000e18);
        assertEq(v2.balanceOf(alice), balBefore - 5_000e18);
    }

    function test_v2_burnFrom_revert_insufficientAllowance() public {
        GovernanceTokenV2 v2Impl = new GovernanceTokenV2();
        vm.prank(admin);
        govToken.upgradeToAndCall(address(v2Impl), "");
        GovernanceTokenV2 v2 = GovernanceTokenV2(address(govToken));

        vm.prank(bob);
        vm.expectRevert();
        v2.burnFrom(alice, 1000e18); // no allowance
    }
}
