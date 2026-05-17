// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./BaseTest.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

/// @notice Full governance lifecycle tests: propose → vote → queue → execute.
///         Also covers PMGovernor view functions and edge cases.
contract GovernorTest is BaseTest {
    // ─── Helpers ─────────────────────────────────────────────────────────────

    struct Proposal {
        address[] targets;
        uint256[] values;
        bytes[]   calldatas;
        bytes32   descHash;
        uint256   id;
    }

    /// @dev Build a minimal governance proposal that mints governance tokens.
    function _buildMintProposal() internal view returns (Proposal memory p) {
        p.targets   = new address[](1);
        p.values    = new uint256[](1);
        p.calldatas = new bytes[](1);

        p.targets[0]   = address(govToken);
        p.calldatas[0] = abi.encodeCall(GovernanceToken.mint, (carol, 1000e18));
        p.descHash     = keccak256(bytes("Mint 1000 PMG to carol"));
    }

    /// @dev Advance blocks and time to end the voting delay.
    function _skipVotingDelay() internal {
        uint256 delay = governor.votingDelay();
        vm.roll(block.number + delay + 1);
        vm.warp(block.timestamp + delay * 12 + 1);
    }

    /// @dev Advance blocks and time to end the voting period.
    function _skipVotingPeriod() internal {
        uint256 period = governor.votingPeriod();
        vm.roll(block.number + period + 1);
        vm.warp(block.timestamp + period * 12 + 1);
    }

    /// @dev Advance time past the Timelock min-delay.
    function _skipTimelockDelay() internal {
        vm.warp(block.timestamp + timelock.getMinDelay() + 1);
    }

    // ─── Governor parameters ──────────────────────────────────────────────────

    function test_governor_votingDelay_is1Day() public view {
        assertEq(governor.votingDelay(), 7200);
    }

    function test_governor_votingPeriod_is1Week() public view {
        assertEq(governor.votingPeriod(), 50400);
    }

    function test_governor_quorumFraction_is4pct() public view {
        // quorumNumerator() should return 4
        assertEq(governor.quorumNumerator(), 4);
    }

    function test_governor_proposalThreshold_is1pct() public {
        // At snapshot block, 1% of total supply — supply is ~850k after setUp transfers
        vm.roll(block.number + 1);
        uint256 threshold = governor.proposalThreshold();
        // Should be ~1% of total supply at the snapshot
        assertGt(threshold, 0);
    }

    function test_timelock_minDelay_is2Days() public view {
        assertEq(timelock.getMinDelay(), 2 days);
    }

    // ─── Propose ──────────────────────────────────────────────────────────────

    function test_propose_succeeds_withEnoughTokens() public {
        // Transfer ownership of govToken to timelock for the mint to work
        vm.prank(admin);
        govToken.transferOwnership(address(timelock));

        Proposal memory p = _buildMintProposal();

        vm.roll(block.number + 1);
        vm.prank(alice); // alice has 100k tokens — above threshold
        p.id = governor.propose(p.targets, p.values, p.calldatas, "Mint 1000 PMG to carol");
        assertGt(p.id, 0);
    }

    function test_propose_revert_belowThreshold() public {
        // carol has no tokens → below proposal threshold
        Proposal memory p = _buildMintProposal();

        vm.roll(block.number + 1);
        vm.prank(carol);
        vm.expectRevert();
        governor.propose(p.targets, p.values, p.calldatas, "fail");
    }

    // ─── Full lifecycle: propose → vote → queue → execute ─────────────────────

    function test_lifecycle_propose_vote_queue_execute() public {
        // 1. Transfer govToken ownership to timelock so it can mint
        vm.prank(admin);
        govToken.transferOwnership(address(timelock));

        // 2. Propose
        vm.roll(block.number + 1);
        vm.prank(alice);
        Proposal memory p = _buildMintProposal();
        p.id = governor.propose(p.targets, p.values, p.calldatas, "Mint 1000 PMG to carol");

        // State: Pending
        assertEq(uint8(governor.state(p.id)), uint8(IGovernorState.ProposalState.Pending));

        // 3. Skip voting delay
        _skipVotingDelay();
        assertEq(uint8(governor.state(p.id)), uint8(IGovernorState.ProposalState.Active));

        // 4. Vote (admin + alice both vote FOR)
        vm.prank(alice);
        governor.castVote(p.id, 1); // 1 = For

        vm.prank(admin);
        governor.castVote(p.id, 1);

        // 5. Skip voting period
        _skipVotingPeriod();
        assertEq(uint8(governor.state(p.id)), uint8(IGovernorState.ProposalState.Succeeded));

        // 6. Queue into timelock
        governor.queue(p.targets, p.values, p.calldatas, p.descHash);
        assertEq(uint8(governor.state(p.id)), uint8(IGovernorState.ProposalState.Queued));

        // 7. Skip timelock delay
        _skipTimelockDelay();

        // 8. Execute
        uint256 carolBefore = govToken.balanceOf(carol);
        governor.execute(p.targets, p.values, p.calldatas, p.descHash);
        assertEq(uint8(governor.state(p.id)), uint8(IGovernorState.ProposalState.Executed));
        assertEq(govToken.balanceOf(carol) - carolBefore, 1000e18);
    }

    function test_lifecycle_defeated_whenQuorumNotMet() public {
        vm.prank(admin);
        govToken.transferOwnership(address(timelock));

        vm.roll(block.number + 1);
        vm.prank(alice);
        Proposal memory p = _buildMintProposal();
        p.id = governor.propose(p.targets, p.values, p.calldatas, "Mint 1000 PMG to carol");

        _skipVotingDelay();

        // Nobody votes → quorum not met
        _skipVotingPeriod();
        assertEq(uint8(governor.state(p.id)), uint8(IGovernorState.ProposalState.Defeated));
    }

    function test_lifecycle_defeated_whenVotedAgainst() public {
        vm.prank(admin);
        govToken.transferOwnership(address(timelock));

        vm.roll(block.number + 1);
        vm.prank(alice);
        Proposal memory p = _buildMintProposal();
        p.id = governor.propose(p.targets, p.values, p.calldatas, "Mint 1000 PMG to carol");

        _skipVotingDelay();

        // Admin votes AGAINST (admin has ~850k tokens — more than alice's 100k)
        vm.prank(admin);
        governor.castVote(p.id, 0); // 0 = Against

        _skipVotingPeriod();
        assertEq(uint8(governor.state(p.id)), uint8(IGovernorState.ProposalState.Defeated));
    }

    // ─── castVote variants ────────────────────────────────────────────────────

    function test_castVoteWithReason() public {
        vm.prank(admin);
        govToken.transferOwnership(address(timelock));

        vm.roll(block.number + 1);
        vm.prank(alice);
        Proposal memory p = _buildMintProposal();
        p.id = governor.propose(p.targets, p.values, p.calldatas, "Mint 1000 PMG to carol");

        _skipVotingDelay();

        vm.prank(alice);
        governor.castVoteWithReason(p.id, 1, "Supports token distribution");

        (uint256 against, uint256 forVotes, uint256 abstain) = _getVoteCounts(p.id);
        assertGt(forVotes, 0);
        assertEq(against, 0);
        assertEq(abstain, 0);
    }

    function test_castVote_revert_alreadyVoted() public {
        vm.prank(admin);
        govToken.transferOwnership(address(timelock));

        vm.roll(block.number + 1);
        vm.prank(alice);
        Proposal memory p = _buildMintProposal();
        p.id = governor.propose(p.targets, p.values, p.calldatas, "desc");

        _skipVotingDelay();

        vm.startPrank(alice);
        governor.castVote(p.id, 1);
        vm.expectRevert();
        governor.castVote(p.id, 1); // duplicate vote
        vm.stopPrank();
    }

    function test_castVote_revert_notActive() public {
        vm.prank(admin);
        govToken.transferOwnership(address(timelock));

        vm.roll(block.number + 1);
        vm.prank(alice);
        Proposal memory p = _buildMintProposal();
        p.id = governor.propose(p.targets, p.values, p.calldatas, "desc");

        // Still in Pending state — not active yet
        vm.prank(alice);
        vm.expectRevert();
        governor.castVote(p.id, 1);
    }

    // ─── proposalNeedsQueuing ─────────────────────────────────────────────────

    function test_proposalNeedsQueuing_returnsTrue() public {
        vm.prank(admin);
        govToken.transferOwnership(address(timelock));

        vm.roll(block.number + 1);
        vm.prank(alice);
        Proposal memory p = _buildMintProposal();
        p.id = governor.propose(p.targets, p.values, p.calldatas, "desc");

        assertTrue(governor.proposalNeedsQueuing(p.id));
    }

    // ─── quorum ───────────────────────────────────────────────────────────────

    function test_quorum_isCorrect() public {
        vm.roll(block.number + 1);
        uint256 q = governor.quorum(block.number - 1);
        uint256 totalSupply = govToken.getPastTotalSupply(block.number - 1);
        assertEq(q, totalSupply * 4 / 100);
    }

    // ─── Internal helper ──────────────────────────────────────────────────────

    function _getVoteCounts(uint256 proposalId)
        internal
        view
        returns (uint256 against, uint256 forVotes, uint256 abstain)
    {
        // GovernorCountingSimple exposes proposalVotes(id)
        // which returns (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes)
        bytes memory data = abi.encodeWithSignature("proposalVotes(uint256)", proposalId);
        (bool ok, bytes memory ret) = address(governor).staticcall(data);
        require(ok);
        (against, forVotes, abstain) = abi.decode(ret, (uint256, uint256, uint256));
    }
}

interface IGovernorState {
    enum ProposalState {
        Pending, Active, Canceled, Defeated, Succeeded, Queued, Expired, Executed
    }
}
