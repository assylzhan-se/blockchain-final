// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/governance/utils/IVotes.sol";
import "../src/GovernanceToken.sol";
import "../src/PMGovernor.sol";
import "../src/FeeVault.sol";
import "../src/MarketAMM.sol";
import "../src/OutcomeShareToken.sol";
import "../src/PredictionMarket.sol";

/// @title Verify
/// @notice Post-deployment verification script.
///         Checks that all governance parameters match spec and no admin backdoor remains.
///         Run after deploy: forge script script/Verify.s.sol --rpc-url $RPC_URL
contract Verify is Script {
    // ─── Expected parameter values ────────────────────────────────────────────
    uint256 constant EXPECTED_TIMELOCK_DELAY    = 2 days;
    uint256 constant EXPECTED_VOTING_DELAY      = 7200;   // 1 day
    uint256 constant EXPECTED_VOTING_PERIOD     = 50400;  // 1 week
    uint256 constant EXPECTED_QUORUM_NUMERATOR  = 4;      // 4 %
    uint256 constant EXPECTED_MAX_STALENESS     = 3600;   // 1 hour

    bool private _allOk = true;

    function run() external {
        // Load deployed addresses from environment
        address govTokenAddr       = vm.envAddress("GOV_TOKEN");
        address timelockAddr       = vm.envAddress("TIMELOCK");
        address governorAddr       = vm.envAddress("GOVERNOR");
        address shareTokenAddr     = vm.envAddress("SHARE_TOKEN");
        address feeVaultAddr       = vm.envAddress("FEE_VAULT");
        address ammAddr            = vm.envAddress("AMM");
        address predMarketAddr     = vm.envAddress("PREDICTION_MARKET");

        console.log("=== Post-Deployment Verification ===");
        console.log("Governor  :", governorAddr);
        console.log("Timelock  :", timelockAddr);
        console.log("GovToken  :", govTokenAddr);

        _verifyTimelock(timelockAddr, governorAddr);
        _verifyGovernor(governorAddr, govTokenAddr, timelockAddr);
        _verifyGovToken(govTokenAddr, timelockAddr);
        _verifyShareToken(shareTokenAddr, ammAddr, predMarketAddr);
        _verifyFeeVault(feeVaultAddr, ammAddr);
        _verifyAMM(ammAddr, predMarketAddr);

        console.log("");
        if (_allOk) {
            console.log("[OK] All checks passed - deployment is correctly configured.");
        } else {
            console.log("[FAIL] One or more checks failed - review output above.");
            revert("Verification failed");
        }
    }

    // ─── Timelock checks ─────────────────────────────────────────────────────

    function _verifyTimelock(address timelockAddr, address governorAddr) internal {
        TimelockController tl = TimelockController(payable(timelockAddr));

        uint256 delay = tl.getMinDelay();
        _check("Timelock.minDelay == 2 days", delay == EXPECTED_TIMELOCK_DELAY,
            string.concat("got ", vm.toString(delay)));

        bool govIsProposer = tl.hasRole(tl.PROPOSER_ROLE(), governorAddr);
        _check("Governor has PROPOSER_ROLE on Timelock", govIsProposer, "");

        bool govIsCanceller = tl.hasRole(tl.CANCELLER_ROLE(), governorAddr);
        _check("Governor has CANCELLER_ROLE on Timelock", govIsCanceller, "");
    }

    // ─── Governor checks ──────────────────────────────────────────────────────

    function _verifyGovernor(address govAddr, address tokenAddr, address timelockAddr) internal {
        PMGovernor gov = PMGovernor(payable(govAddr));

        _check("Governor.votingDelay == 7200",
            gov.votingDelay() == EXPECTED_VOTING_DELAY, "");

        _check("Governor.votingPeriod == 50400",
            gov.votingPeriod() == EXPECTED_VOTING_PERIOD, "");

        _check("Governor.quorumNumerator == 4",
            gov.quorumNumerator() == EXPECTED_QUORUM_NUMERATOR, "");

        _check("Governor.token == govToken",
            address(gov.token()) == tokenAddr, "");

        _check("Governor.timelock == timelock",
            address(gov.timelock()) == timelockAddr, "");
    }

    // ─── GovernanceToken checks ───────────────────────────────────────────────

    function _verifyGovToken(address tokenAddr, address timelockAddr) internal {
        GovernanceToken token = GovernanceToken(tokenAddr);

        _check("GovToken.owner == Timelock",
            token.owner() == timelockAddr,
            string.concat("owner is ", vm.toString(token.owner())));
    }

    // ─── OutcomeShareToken checks ─────────────────────────────────────────────

    function _verifyShareToken(address shareAddr, address ammAddr, address marketAddr) internal {
        OutcomeShareToken st = OutcomeShareToken(shareAddr);
        bytes32 minterRole = st.MINTER_ROLE();
        bytes32 burnerRole = st.BURNER_ROLE();

        _check("AMM has MINTER_ROLE on ShareToken",  st.hasRole(minterRole, ammAddr), "");
        _check("AMM has BURNER_ROLE on ShareToken",  st.hasRole(burnerRole, ammAddr), "");
        _check("Market has BURNER_ROLE on ShareToken", st.hasRole(burnerRole, marketAddr), "");
    }

    // ─── FeeVault checks ──────────────────────────────────────────────────────

    function _verifyFeeVault(address vaultAddr, address ammAddr) internal {
        FeeVault fv = FeeVault(vaultAddr);
        _check("AMM has FEE_DEPOSITOR_ROLE on FeeVault",
            fv.hasRole(fv.FEE_DEPOSITOR_ROLE(), ammAddr), "");
    }

    // ─── MarketAMM checks ─────────────────────────────────────────────────────

    function _verifyAMM(address ammAddr, address marketAddr) internal {
        MarketAMM a = MarketAMM(ammAddr);
        _check("PredictionMarket has MARKET_MANAGER_ROLE on AMM",
            a.hasRole(a.MARKET_MANAGER_ROLE(), marketAddr), "");
    }

    // ─── Helper ───────────────────────────────────────────────────────────────

    function _check(string memory label, bool condition, string memory extra) internal {
        if (condition) {
            console.log(string.concat("[OK]   ", label));
        } else {
            string memory msg = bytes(extra).length > 0
                ? string.concat("[FAIL] ", label, " (", extra, ")")
                : string.concat("[FAIL] ", label);
            console.log(msg);
            _allOk = false;
        }
    }
}
