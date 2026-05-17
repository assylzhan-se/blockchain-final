// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/GovernanceToken.sol";
import "../src/GovernanceTokenV2.sol";
import "../src/OutcomeShareToken.sol";
import "../src/ChainlinkAdapter.sol";
import "../src/FeeVault.sol";
import "../src/MarketAMM.sol";
import "../src/PredictionMarket.sol";
import "../src/MarketFactory.sol";
import "../src/PMGovernor.sol";

/// @dev Shared test base — deploys the full protocol stack
abstract contract BaseTest is Test {
    // Actors
    address internal admin    = makeAddr("admin");
    address internal alice    = makeAddr("alice");
    address internal bob      = makeAddr("bob");
    address internal carol    = makeAddr("carol");
    address internal attacker = makeAddr("attacker");

    // Protocol contracts
    GovernanceToken   internal govToken;
    OutcomeShareToken internal shareToken;
    MockAggregator    internal mockFeed;
    ChainlinkAdapter  internal oracle;
    FeeVault          internal vault;
    MarketAMM         internal amm;
    PredictionMarket  internal market;
    MarketFactory     internal factory;
    TimelockController internal timelock;
    PMGovernor        internal governor;

    // Mock collateral (use govToken as collateral for simplicity in tests,
    // in production this would be USDC)
    ERC20Mock internal collateral;

    uint256 internal constant INITIAL_SUPPLY   = 1_000_000e18;
    uint256 internal constant MAX_SUPPLY       = 10_000_000e18;
    uint256 internal constant INITIAL_LIQUIDITY = 100_000e18;

    function setUp() public virtual {
        vm.startPrank(admin);

        // 1. Collateral mock
        collateral = new ERC20Mock("USD Coin", "USDC", 6);
        collateral.mint(admin,  INITIAL_SUPPLY);
        collateral.mint(alice,  INITIAL_SUPPLY);
        collateral.mint(bob,    INITIAL_SUPPLY);
        collateral.mint(carol,  INITIAL_SUPPLY);

        // 2. Governance token (UUPS proxy)
        GovernanceToken govImpl = new GovernanceToken();
        bytes memory initData = abi.encodeCall(
            GovernanceToken.initialize, (admin, INITIAL_SUPPLY, MAX_SUPPLY)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(govImpl), initData);
        govToken = GovernanceToken(address(proxy));

        // 3. Timelock (2-day delay)
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = address(0); // set after governor deploy
        executors[0] = address(0); // anyone can execute
        timelock = new TimelockController(2 days, proposers, executors, admin);

        // 4. Outcome share tokens
        shareToken = new OutcomeShareToken(admin);

        // 5. Chainlink oracle
        mockFeed = new MockAggregator(2000e8, 8); // ETH/USD = $2000
        oracle = new ChainlinkAdapter(admin);

        // 6. FeeVault
        vault = new FeeVault(IERC20(address(collateral)), admin);

        // 7. MarketAMM
        amm = new MarketAMM(address(collateral), address(shareToken), address(vault), admin);

        // 8. PredictionMarket
        market = new PredictionMarket(
            address(collateral), address(shareToken), address(amm), address(oracle), admin
        );

        // 9. Factory
        factory = new MarketFactory(
            address(collateral), address(shareToken), address(amm), address(oracle), admin
        );

        // 10. Governor
        governor = new PMGovernor(IVotes(address(govToken)), timelock);

        // Grant roles
        shareToken.grantRole(shareToken.MINTER_ROLE(), address(amm));
        shareToken.grantRole(shareToken.BURNER_ROLE(), address(amm));
        shareToken.grantRole(shareToken.BURNER_ROLE(), address(market));
        vault.grantRole(vault.FEE_DEPOSITOR_ROLE(), address(amm));
        amm.grantRole(amm.MARKET_MANAGER_ROLE(), address(market));

        // Timelock: grant proposer role to governor
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));

        vm.stopPrank();

        // Distribute governance tokens and delegate
        vm.prank(admin);
        assertTrue(govToken.transfer(alice, 100_000e18));
        vm.prank(admin);
        assertTrue(govToken.transfer(bob, 50_000e18));

        vm.prank(alice);
        govToken.delegate(alice);
        vm.prank(bob);
        govToken.delegate(bob);
        vm.prank(admin);
        govToken.delegate(admin);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _createActiveMarket() internal returns (uint256 marketId) {
        vm.startPrank(admin);
        collateral.approve(address(market), INITIAL_LIQUIDITY);
        marketId = market.createMarket(
            "Will ETH be above $3000 on Dec 31?",
            address(mockFeed),
            3000e8,
            INITIAL_LIQUIDITY
        );
        market.activateMarket(marketId);
        vm.stopPrank();
    }
}

/// @dev Minimal ERC20 mock for tests
contract ERC20Mock is ERC20 {
    uint8 private _dec;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _dec = decimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }
}
