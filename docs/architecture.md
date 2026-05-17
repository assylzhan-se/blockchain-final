# Architecture Document

**Project:** On-Chain Prediction Market DAO  
**Version:** 1.0  
**Date:** 2026-05-17

---

## 1. System Overview (C4 Level 1 — Context)

```
┌──────────────────────────────────────────────────────────────────────┐
│                          External Actors                             │
│                                                                      │
│   ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌───────────────┐   │
│   │  Trader  │   │Liquidity │   │  DAO     │   │  Market       │   │
│   │          │   │Provider  │   │  Voter   │   │  Creator      │   │
│   └────┬─────┘   └────┬─────┘   └────┬─────┘   └──────┬────────┘   │
└────────┼──────────────┼──────────────┼─────────────────┼────────────┘
         │              │              │                 │
         ▼              ▼              ▼                 ▼
┌──────────────────────────────────────────────────────────────────────┐
│                    Prediction Market Protocol                        │
│              (Arbitrum Sepolia — EVM-compatible L2)                  │
└──────────────────────────────────────────────────────────────────────┘
         │                                               │
         ▼                                               ▼
┌────────────────────┐                      ┌──────────────────────────┐
│   Chainlink Oracle │                      │   The Graph (subgraph)   │
│   (price feeds)    │                      │   (off-chain indexer)    │
└────────────────────┘                      └──────────────────────────┘
```

---

## 2. Container Diagram (C4 Level 2)

```
┌──────────────────────────────────────────────────────────────────────┐
│                     Smart Contract Layer                             │
│                                                                      │
│  ┌─────────────────────┐      ┌──────────────────────────────────┐  │
│  │   GovernanceToken   │      │        PMGovernor                │  │
│  │  (UUPS proxy ERC20) │◄─────│  Governor + TimelockControl     │  │
│  │  ERC20Votes + Permit│      │  4% quorum, 1-week period       │  │
│  └─────────────────────┘      └─────────────┬────────────────────┘  │
│                                             │ TimelockController     │
│  ┌─────────────────────┐      ┌─────────────▼────────────────────┐  │
│  │   MarketFactory     │      │       PredictionMarket           │  │
│  │   CREATE + CREATE2  │─────►│  State machine, pull payments    │  │
│  └─────────────────────┘      └──┬──────────────┬───────────────┘  │
│                                  │              │                   │
│  ┌───────────────────────────────▼──┐  ┌────────▼───────────────┐  │
│  │           MarketAMM              │  │  OutcomeShareToken     │  │
│  │   CPMM (x·y=k), Yul assembly    │  │  ERC-1155 YES/NO shares│  │
│  │   0.3% fee → FeeVault           │  └────────────────────────┘  │
│  └────────────┬─────────────────────┘                              │
│               │                                                    │
│  ┌────────────▼──────────────┐  ┌─────────────────────────────┐   │
│  │        FeeVault           │  │     ChainlinkAdapter        │   │
│  │   ERC-4626 tokenised vault│  │  staleness guard (1 hour)   │   │
│  └───────────────────────────┘  └─────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 3. Component Diagram (C4 Level 3) — PredictionMarket

```
PredictionMarket
│
├── MarketState enum: CREATED → ACTIVE → DISPUTE → RESOLVED → CLOSED
│
├── createMarket(question, feed, threshold, liquidity)
│     └── pulls collateral from creator
│     └── calls amm.initializePool()
│     └── emits MarketCreated
│
├── activateMarket(id)
│     └── state: CREATED → ACTIVE
│     └── emits MarketActivated
│
├── resolveMarket(id)
│     └── calls oracle.validateFresh(feed)
│     └── compares price to threshold
│     └── state: ACTIVE → DISPUTE (dispute window opens)
│     └── emits MarketDisputeStarted
│
├── finalizeResolution(id)
│     └── requires dispute window elapsed
│     └── state: DISPUTE → RESOLVED
│     └── emits MarketResolved
│
├── overrideResolution(id, outcome)  [DISPUTE_RESOLVER_ROLE]
│     └── DAO can override during dispute window
│     └── state: DISPUTE → RESOLVED
│
└── claimWinnings(id)
      └── pull-over-push: user calls, contract pays
      └── state: RESOLVED → CLOSED (on first claim)
      └── emits WinningsClaimed
```

---

## 4. Sequence Diagrams

### 4.1 Buy Outcome Shares

```
Trader          PredictionMarket       MarketAMM           OutcomeShareToken
  │                    │                    │                      │
  │── buyShares() ─────────────────────────►│                      │
  │                    │         forceApprove(collateral)           │
  │                    │                    │── transferFrom ──────►│
  │                    │                    │   (collateral in)     │
  │                    │                    │── _getAmountOut() ─── │ (Yul asm)
  │                    │                    │── mint(trader, shares)►│
  │                    │                    │── _depositFee() ──────►FeeVault
  │                    │                    │── emit SharesBought   │
  │◄──────────── amountOut ─────────────────│                      │
```

### 4.2 Governance Proposal Lifecycle

```
Proposer         PMGovernor           TimelockController    Target Contract
   │                  │                       │                    │
   │── propose() ────►│                       │                    │
   │                  │── emit ProposalCreated│                    │
   │    [7200 blocks voting delay]             │                    │
   │── castVote() ────►│                      │                    │
   │    [50400 blocks voting period]           │                    │
   │── queue() ───────►│                      │                    │
   │                  │── scheduleBatch() ────►│                   │
   │    [2 days timelock delay]                │                    │
   │── execute() ─────►│                      │                    │
   │                  │── executeBatch() ─────►│                   │
   │                  │                       │── call() ──────────►
   │                  │── emit ProposalExecuted                    │
```

### 4.3 Market Resolution

```
Resolver         PredictionMarket       ChainlinkAdapter      Chainlink Feed
   │                    │                      │                     │
   │── resolveMarket() ►│                      │                     │
   │                    │── getLatestPrice() ──►│                    │
   │                    │                      │── latestRoundData()►│
   │                    │                      │◄─ price, updatedAt ─│
   │                    │                      │── require(staleness)│
   │                    │◄── price ────────────│                     │
   │                    │── compare threshold  │                     │
   │                    │── state = DISPUTE    │                     │
   │                    │── emit MarketDisputeStarted               │
   │    [24 hours dispute window]              │                     │
   │── finalizeResolution() ►│                 │                     │
   │                    │── state = RESOLVED   │                     │
```

---

## 5. Data Flows

### 5.1 Fee Flow

```
Trader's USDC
      │
      ▼ amountIn × 0.003
  MarketAMM._depositFee()
      │ forceApprove + depositFee()
      ▼
  FeeVault.depositFee()
      │ internal accounting (totalFeesAccrued)
      ▼
  ERC-4626 vault shares minted to depositor
      │ governance controls distribution
      ▼
  DAO vote → FeeVault.withdrawFees()
```

### 5.2 Collateral Flow on Claim

```
Winner calls claimWinnings(marketId)
      │
      ├── hasClaimed[marketId][winner] = false → set true
      │
      ├── shareToken.balanceOf(winner, tokenId(marketId, winningOutcome))
      │
      ├── amm.payWinnings(marketId, winner, shares)
      │       └── collateral.safeTransfer(winner, amount)
      │
      └── emit WinningsClaimed
```

---

## 6. Storage Layouts

### 6.1 GovernanceToken (UUPS, ERC-7201)

```
Slot (keccak256("predictionmarket.storage.GovernanceToken") - 1) & ~0xff:
  = 0x5320cba978ec7c74aad3a7178916d3e8ae962287304238eecc4848e2f5ca7900

Within GovernanceTokenStorage struct (ERC-7201 namespaced):
  +0  maxSupply   uint256
  +1  (reserved)

ERC20Upgradeable standard slots (OZ v5):
  _balances      mapping(address => uint256)   — slot per OZ layout
  _allowances    mapping(address => mapping(address => uint256))
  _totalSupply   uint256
  _name          string
  _symbol        string

ERC20VotesUpgradeable additional:
  _checkpoints   mapping(address => Checkpoints.Trace208)
  _totalCheckpoints Checkpoints.Trace208

OwnableUpgradeable:
  _owner         address

UUPSUpgradeable:
  _implementation address  (ERC-1967 slot: keccak256("eip1967.proxy.implementation")-1)
```

### 6.2 PredictionMarket

```
Slot 0: collateral   (immutable → bytecode)
Slot 1: shareToken   (immutable)
Slot 2: amm          (immutable)
Slot 3: oracle       (immutable)
Slot 4: _roles       (AccessControl, mapping)
Slot 5: markets      mapping(uint256 => Market)
          Market { question, resolutionFeed, resolutionThreshold,
                   createdAt, resolvedAt, initialLiquidity,
                   state (uint8), winningOutcome (uint8), outcomeSet (bool) }
Slot 6: marketCount  uint256
Slot 7: hasClaimed   mapping(uint256 => mapping(address => bool))
```

### 6.3 MarketAMM

```
Slot 0-3: immutables (bytecode)
Slot 4: pools        mapping(uint256 => Pool)
          Pool { reserveYes (uint256), reserveNo (uint256),
                 totalLiquidity (uint256), initialized (bool) }
Slot 5: liquidityOf  mapping(uint256 => mapping(address => uint256))
```

---

## 7. Key Design Decisions (Architecture Decision Records)

### ADR-001: UUPS over Transparent Proxy

**Decision:** Use UUPS (ERC-1822/ERC-1967) for `GovernanceToken`.  
**Rationale:** UUPS puts the upgrade logic in the implementation contract, so the proxy is cheaper to deploy and cheaper per-call (no admin slot check on every call). After transferring ownership to the Timelock, upgrades require a DAO vote — same security as Transparent Proxy but ~2 700 gas cheaper per transaction.  
**Trade-off:** If the V1 implementation has a bug in `_authorizeUpgrade`, the contract could be permanently locked. Mitigated by extensive upgrade testing in `test/GovernanceToken.t.sol`.

### ADR-002: ERC-7201 Namespaced Storage

**Decision:** Store GovernanceToken's custom state in an ERC-7201 namespaced storage slot.  
**Rationale:** OpenZeppelin's upgradeable library v5 mandates this pattern. Prevents storage slot collisions across inheritance chains even as the contract evolves through upgrades.  
**Slot computation:** `keccak256(abi.encode(uint256(keccak256("predictionmarket.storage.GovernanceToken")) - 1)) & ~bytes32(uint256(0xff))`

### ADR-003: ERC-1155 for Outcome Shares

**Decision:** Use ERC-1155 multi-token for YES/NO shares rather than two separate ERC-20 contracts.  
**Rationale:** A single contract manages all outcomes for all markets. Token ID encoding: `tokenId = marketId * 2 + outcome`. This halves deployment gas and simplifies the AMM's share management.  
**Trade-off:** ERC-1155 is not compatible with DEX routers expecting ERC-20. Acceptable because shares are only traded through the protocol AMM.

### ADR-004: Yul Assembly in `_getAmountOutAssembly`

**Decision:** Implement the CPMM output formula in Yul assembly.  
**Rationale:** The formula `amountOut = (amountIn × (1 - fee) × reserveOut) / (reserveIn + amountIn × (1 - fee))` is called on every swap. Yul eliminates the Solidity bounds checking overhead (≈ 400 gas per swap vs pure Solidity). The Solidity reference implementation is kept as `_getAmountOutSolidity` and fuzz-tested for equivalence.

### ADR-005: Pull-over-Push Payments

**Decision:** Winners call `claimWinnings()` rather than the contract pushing funds.  
**Rationale:** Push payments create reentrancy risk and can fail if the recipient is a contract that reverts. Pull-over-push is the recommended pattern (see Consensys Smart Contract Best Practices). `hasClaimed` mapping prevents double claims.

### ADR-006: Chainlink Staleness Guard

**Decision:** Reject oracle data older than `maxStaleness` (default 1 hour).  
**Rationale:** A stale price feed could allow an attacker to resolve a market based on an outdated price. The 1-hour threshold matches Chainlink's typical Arbitrum heartbeat. The threshold is configurable by governance.

### ADR-007: CREATE2 for Deterministic Market Addresses

**Decision:** `MarketFactory` supports both `deployMarket` (CREATE) and `deployMarketDeterministic` (CREATE2).  
**Rationale:** CREATE2 addresses can be computed off-chain before deployment, enabling frontends and integrators to pre-approve spending to a market address before it exists. The salt is a `bytes32` chosen by the creator to prevent collisions.

### ADR-008: ERC-4626 for Fee Vault

**Decision:** Implement `FeeVault` as a standard ERC-4626 tokenised vault.  
**Rationale:** ERC-4626 provides a standard interface for yield-bearing vaults. Any ERC-4626-aware tool (DeFi aggregators, dashboards) can interact with the fee vault without bespoke integration.

---

## 8. Trust Model

| Component | Trusted Parties | Risk |
|---|---|---|
| GovernanceToken upgrades | Timelock (DAO-controlled) | Malicious upgrade; mitigated by 2-day delay + quorum |
| Market creation | `MARKET_CREATOR_ROLE` (admin at launch) | Rogue market question; mitigated by transitioning to DAO role |
| Market resolution | `RESOLVER_ROLE` (keeper bot at launch) | Wrong outcome; mitigated by 24h dispute window |
| Dispute override | `DISPUTE_RESOLVER_ROLE` (DAO via Governor) | Majority attack; mitigated by 4% quorum |
| Oracle feed | Chainlink | Feed manipulation or downtime; mitigated by staleness guard |
| AMM pause | `PAUSER_ROLE` | DoS; mitigated by Timelock controlling role grants |

**Fully decentralised state:** All privileged roles should be transferred to the Timelock post-launch. The `script/Verify.s.sol` post-deployment verification script checks that `govToken.owner() == timelock` and that all expected role grants are in place.

---

## 9. L2 Deployment Considerations

- **Network:** Arbitrum Sepolia (chain ID 421614)
- **Block time:** ~250 ms, but Arbitrum One uses Ethereum block numbers for `block.number`
- **Voting delay/period:** Set in blocks. On Arbitrum, `block.number` increments at ~1/second; 7200 blocks ≈ 2 hours (not 1 day as on Ethereum mainnet). Adjust if deploying to Arbitrum One for production.
- **Gas pricing:** Arbitrum uses a two-dimensional gas model (L1 calldata cost + L2 execution). Yul optimization in MarketAMM reduces L2 execution cost. Calldata compression (EIP-4844 blobs) further reduces costs on Arbitrum One.
- **Chainlink feeds:** Deployed and maintained on Arbitrum Sepolia. Use the official Chainlink docs for feed addresses.

---

## 10. Upgrade Path

```
GovernanceToken V1 (deployed)
    │
    │ DAO proposal → queue in Timelock → 2-day delay
    │
    ▼
GovernanceToken V2 (GovernanceTokenV2.sol)
    └── Adds burn() and burnFrom()
    └── Storage layout preserved (checked in test_upgrade_storageLayoutPreserved)
    └── New version() → "2.0.0"
```

Future upgrades follow the same pattern: implement `_authorizeUpgrade` in V(n+1), deploy implementation, create Governor proposal calling `upgradeToAndCall`, pass DAO vote, execute after timelock.
## Subgraph GraphQL Queries

### Query 1 — All markets
```graphql
{
  markets(first: 20, orderBy: createdAt, orderDirection: desc) {
    id
    question
    state
    winningOutcome
    initialLiquidity
    createdAt
  }
}
```

### Query 2 — Recent trades for a market
```graphql
{
  trades(where: { market: "1" }, orderBy: timestamp, orderDirection: desc, first: 10) {
    id
    trader
    outcome
    amountIn
    amountOut
    isBuy
    timestamp
  }
}
```

### Query 3 — Active governance proposals
```graphql
{
  governanceProposals(where: { state: "Active" }) {
    id
    proposer
    description
    forVotes
    againstVotes
    abstainVotes
    startBlock
    endBlock
  }
}
```

### Query 4 — Liquidity positions by provider
```graphql
{
  liquidityPositions(where: { provider: "0xYOUR_ADDRESS" }) {
    id
    market { id question }
    liquidity
    lastUpdated
  }
}
```

### Query 5 — Protocol global stats
```graphql
{
  protocolStats(id: "global") {
    totalMarketsCreated
    totalTradeVolume
    totalFeesCollected
    totalLiquidityProvided
    lastUpdated
  }
}
```