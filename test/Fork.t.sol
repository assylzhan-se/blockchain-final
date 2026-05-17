// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/ChainlinkAdapter.sol";

/// @notice Fork tests that interact with real mainnet protocols.
///         Requires ETH_RPC_URL environment variable; skipped otherwise.
contract ForkTest is Test {
    // Ethereum mainnet Chainlink ETH/USD price feed
    address constant ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    // Ethereum mainnet USDC
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    ChainlinkAdapter oracle;

    function setUp() public {
        string memory rpcUrl = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpcUrl);
        oracle = new ChainlinkAdapter(address(this));
    }

    // ─── Fork test 1: Chainlink ETH/USD price is valid ───────────────────────

    /// @notice The mainnet ETH/USD Chainlink feed must return a positive, sane price.
    function test_fork_chainlinkEthUsd_priceIsValid() public {
        int256 price = oracle.validateFresh(ETH_USD_FEED);
        assertGt(price, 0, "ETH/USD price must be positive");
        // Sanity: ETH between $10 and $1 000 000
        assertGt(price, 10e8, "ETH price suspiciously low");
        assertLt(price, 1_000_000e8, "ETH price suspiciously high");
    }

    // ─── Fork test 2: getLatestPrice matches validateFresh ───────────────────

    /// @notice getLatestPrice and validateFresh must agree on the same feed.
    function test_fork_getLatestPrice_matchesValidateFresh() public {
        int256 validated = oracle.validateFresh(ETH_USD_FEED);
        (int256 latest,) = oracle.getLatestPrice(ETH_USD_FEED);
        assertEq(validated, latest, "getLatestPrice and validateFresh must agree");
    }

    // ─── Fork test 3: USDC decimals are 6 ────────────────────────────────────

    /// @notice Real USDC on mainnet must report 6 decimals (protocol ERC-20 assumption).
    function test_fork_usdc_hasCorrectDecimals() public {
        uint8 dec = IERC20Metadata(USDC).decimals();
        assertEq(dec, 6, "USDC must have 6 decimals");
    }
}

interface IERC20Metadata {
    function decimals() external view returns (uint8);
}
