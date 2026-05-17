// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./OutcomeShareToken.sol";
import "./MarketAMM.sol";
import "./ChainlinkAdapter.sol";

/// @title PredictionMarket
/// @notice Core prediction market contract managing market lifecycle.
///
/// State machine:
///   CREATED → ACTIVE (after funding)
///   ACTIVE  → DISPUTE (after oracle resolution, during dispute window)
///   DISPUTE → RESOLVED (after dispute window expires or DAO override)
///   RESOLVED → CLOSED (after all claims processed)
///
/// Pull-over-push payment pattern: winners call claimWinnings() themselves.
contract PredictionMarket is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");
    bytes32 public constant MARKET_CREATOR_ROLE = keccak256("MARKET_CREATOR_ROLE");
    bytes32 public constant DISPUTE_RESOLVER_ROLE = keccak256("DISPUTE_RESOLVER_ROLE");

    uint256 public constant DISPUTE_WINDOW = 24 hours;

    IERC20 public immutable collateral;
    OutcomeShareToken public immutable shareToken;
    MarketAMM public immutable amm;
    ChainlinkAdapter public immutable oracle;

    enum MarketState { CREATED, ACTIVE, DISPUTE, RESOLVED, CLOSED }

    struct Market {
        string question;
        address resolutionFeed;    // Chainlink feed for resolution
        int256 resolutionThreshold; // price threshold for YES outcome
        uint256 createdAt;
        uint256 resolvedAt;
        uint256 initialLiquidity;
        MarketState state;
        uint8 winningOutcome;      // 0=NO, 1=YES (only valid when RESOLVED)
        bool outcomeSet;
    }

    mapping(uint256 => Market) public markets;
    uint256 public marketCount;

    // Pull-over-push: track claims
    mapping(uint256 => mapping(address => bool)) public hasClaimed;

    event MarketCreated(uint256 indexed marketId, string question, address feed, int256 threshold);
    event MarketActivated(uint256 indexed marketId);
    event MarketDisputeStarted(uint256 indexed marketId, uint8 proposedOutcome, uint256 disputeDeadline);
    event MarketResolved(uint256 indexed marketId, uint8 winningOutcome);
    event WinningsClaimed(uint256 indexed marketId, address indexed claimer, uint256 amount);

    error InvalidState(MarketState current, MarketState required);
    error DisputeWindowActive(uint256 deadline);
    error AlreadyClaimed();

    constructor(
        address collateral_,
        address shareToken_,
        address amm_,
        address oracle_,
        address admin
    ) {
        collateral = IERC20(collateral_);
        shareToken = OutcomeShareToken(shareToken_);
        amm = MarketAMM(amm_);
        oracle = ChainlinkAdapter(oracle_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MARKET_CREATOR_ROLE, admin);
        _grantRole(RESOLVER_ROLE, admin);
        _grantRole(DISPUTE_RESOLVER_ROLE, admin);
    }

    // ─── State Machine Transitions ────────────────────────────────────────────

    /// @notice Create a new prediction market (CREATED state)
    function createMarket(
        string calldata question,
        address resolutionFeed,
        int256 resolutionThreshold,
        uint256 initialLiquidity
    ) external onlyRole(MARKET_CREATOR_ROLE) returns (uint256 marketId) {
        marketId = ++marketCount;

        markets[marketId] = Market({
            question: question,
            resolutionFeed: resolutionFeed,
            resolutionThreshold: resolutionThreshold,
            createdAt: block.timestamp,
            resolvedAt: 0,
            initialLiquidity: initialLiquidity,
            state: MarketState.CREATED,
            winningOutcome: 0,
            outcomeSet: false
        });

        emit MarketCreated(marketId, question, resolutionFeed, resolutionThreshold);
    }

    /// @notice Fund the market and activate it (CREATED → ACTIVE)
    function activateMarket(uint256 marketId) external onlyRole(MARKET_CREATOR_ROLE) nonReentrant {
        Market storage market = markets[marketId];
        _requireState(market.state, MarketState.CREATED);

        market.state = MarketState.ACTIVE;

        // Interactions — fund the AMM pool
        collateral.safeTransferFrom(msg.sender, address(this), market.initialLiquidity);
        collateral.forceApprove(address(amm), market.initialLiquidity);
        amm.initializePool(marketId, market.initialLiquidity);

        emit MarketActivated(marketId);
    }

    /// @notice Resolve market using Chainlink oracle (ACTIVE → DISPUTE)
    ///         Starts dispute window — final resolution after 24h.
    function resolveMarket(uint256 marketId) external onlyRole(RESOLVER_ROLE) {
        Market storage market = markets[marketId];
        _requireState(market.state, MarketState.ACTIVE);

        int256 price = oracle.validateFresh(market.resolutionFeed);
        uint8 outcome = price >= market.resolutionThreshold ? 1 : 0;

        market.state = MarketState.DISPUTE;
        market.resolvedAt = block.timestamp;
        market.winningOutcome = outcome;
        market.outcomeSet = true;

        emit MarketDisputeStarted(marketId, outcome, block.timestamp + DISPUTE_WINDOW);
    }

    /// @notice Override resolution during dispute window (DAO governance via Timelock)
    function overrideResolution(uint256 marketId, uint8 forcedOutcome)
        external
        onlyRole(DISPUTE_RESOLVER_ROLE)
    {
        Market storage market = markets[marketId];
        require(
            market.state == MarketState.DISPUTE,
            "PredictionMarket: not in dispute"
        );
        require(forcedOutcome <= 1, "PredictionMarket: invalid outcome");

        market.winningOutcome = forcedOutcome;
        emit MarketDisputeStarted(marketId, forcedOutcome, block.timestamp + DISPUTE_WINDOW);
    }

    /// @notice Finalize resolution after dispute window (DISPUTE → RESOLVED)
    function finalizeResolution(uint256 marketId) external {
        Market storage market = markets[marketId];
        _requireState(market.state, MarketState.DISPUTE);

        uint256 deadline = market.resolvedAt + DISPUTE_WINDOW;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < deadline) revert DisputeWindowActive(deadline);

        market.state = MarketState.RESOLVED;
        emit MarketResolved(marketId, market.winningOutcome);
    }

    /// @notice Claim winnings after resolution (Pull-over-push pattern)
    function claimWinnings(uint256 marketId) external nonReentrant {
        Market storage market = markets[marketId];
        require(
            market.state == MarketState.RESOLVED || market.state == MarketState.CLOSED,
            "PredictionMarket: market not resolved"
        );
        if (hasClaimed[marketId][msg.sender]) revert AlreadyClaimed();

        // Checks
        uint256 tokenId = shareToken.tokenId(marketId, market.winningOutcome);
        uint256 shares = shareToken.balanceOf(msg.sender, tokenId);
        require(shares > 0, "PredictionMarket: no winning shares");

        // Effects
        hasClaimed[marketId][msg.sender] = true;

        // Interactions — burn shares, pay out collateral 1:1
        shareToken.burn(msg.sender, marketId, market.winningOutcome, shares);
        amm.payWinnings(marketId, msg.sender, shares);

        emit WinningsClaimed(marketId, msg.sender, shares);
    }

    // ─── View ─────────────────────────────────────────────────────────────────

    function getMarket(uint256 marketId) external view returns (Market memory) {
        return markets[marketId];
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _requireState(MarketState current, MarketState required) internal pure {
        if (current != required) revert InvalidState(current, required);
    }
}
