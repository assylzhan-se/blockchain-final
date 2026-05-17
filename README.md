# On-Chain Prediction Market DAO

**Blockchain Technologies 2 — Final Project — Option D**

A fully on-chain, governance-controlled prediction market protocol deployed on **Arbitrum Sepolia**. Users bet on binary (YES/NO) outcomes powered by Chainlink price feeds; a CPMM AMM provides on-demand liquidity; protocol revenue flows to an ERC-4626 fee vault; and all parameter changes go through a Governor + TimelockController DAO.

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────┐
│                  Frontend dApp                        │
│            (frontend/index.html + ethers.js)          │
└────────────────────┬─────────────────────────────────┘
                     │ RPC / events
        ┌────────────▼──────────────┐
        │    PredictionMarket.sol   │  state machine (CREATED→ACTIVE→DISPUTE→RESOLVED→CLOSED)
        │    MarketFactory.sol      │  CREATE + CREATE2 factory
        └──┬──────────┬────────────┘
           │          │
    ┌──────▼──┐  ┌────▼──────────┐
    │MarketAMM│  │OutcomeShare   │  ERC-1155 YES/NO share tokens
    │  CPMM   │  │Token.sol      │
    │ Yul asm │  └───────────────┘
    └──┬──────┘
       │ fees
  ┌────▼──────┐     ┌─────────────────┐
  │ FeeVault  │     │ ChainlinkAdapter │  staleness-guarded oracle
  │ ERC-4626  │     └─────────────────┘
  └───────────┘
        │
  ┌─────▼──────────────────────────────┐
  │  PMGovernor + TimelockController   │  OpenZeppelin Governor stack
  │  GovernanceToken (UUPS proxy)      │  ERC20Votes + ERC20Permit
  └─────────────────────────────────────┘
```

---

## Smart Contracts

| Contract | Description |
|---|---|
| `GovernanceToken.sol` | UUPS-upgradeable ERC20Votes + ERC20Permit governance token (PMG). Max supply 10M. |
| `GovernanceTokenV2.sol` | V2 implementation adding `burn` / `burnFrom`. |
| `PMGovernor.sol` | OpenZeppelin Governor: 1-day voting delay, 1-week period, 4% quorum, 2-day timelock. |
| `PredictionMarket.sol` | Core market lifecycle. State machine. Pull-over-push claims. |
| `MarketFactory.sol` | CREATE + CREATE2 factory for `PredictionMarket` instances. |
| `MarketAMM.sol` | Constant-product AMM with 0.3% fee. Yul assembly optimisation in `_getAmountOutAssembly`. |
| `OutcomeShareToken.sol` | ERC-1155 YES/NO outcome shares. |
| `FeeVault.sol` | ERC-4626 tokenised vault accumulating protocol fees. |
| `ChainlinkAdapter.sol` | Chainlink AggregatorV3 wrapper with configurable staleness guard. |

---

## Prerequisites

- [Foundry](https://book.getfoundry.sh/) (`forge`, `cast`, `anvil`)
- Node.js 20+ (for subgraph + frontend)
- Git with submodules

```bash
git clone --recursive <repo>
cd "Final blockchain"
forge build
```

---

## Build & Test

```bash
# Compile
forge build --sizes

# Run all tests (136 tests, 1 skip)
forge test -v

# Run with fork tests (requires Arbitrum Sepolia RPC)
ETH_RPC_URL=https://arb-sepolia.... forge test -v

# Coverage report
forge coverage --no-match-test "invariant_" --report summary

# Format check
forge fmt --check

# Lint
npx solhint 'src/**/*.sol'
```

### Test Categories

| Suite | File | Tests | Type |
|---|---|---|---|
| GovernanceToken | `test/GovernanceToken.t.sol` | 16 | Unit |
| MarketAMM | `test/MarketAmm.t.sol` | 22 | Unit |
| PredictionMarket | `test/PredictionMarket.t.sol` | 18 | Unit |
| OutcomeShareToken | `test/OutcomeShareToken.t.sol` | 14 | Unit |
| ChainlinkAdapter | `test/ChainlinkAdapter.t.sol` | 12 | Unit |
| MarketFactory | `test/MarketFactory.t.sol` | 12 | Unit |
| FeeVault | `test/FeeVault.t.sol` | 10 | Unit |
| Governor lifecycle | `test/Governor.t.sol` | 15 | Unit |
| Fuzz | `test/Fuzz.t.sol` | 12 | Fuzz |
| Invariant | `test/Invariant.t.sol` | 5 | Invariant |
| Fork | `test/Fork.t.sol` | 3 | Fork |
| **Total** | | **139** | |

---

## Deployment (Optimism Sepolia)

| Contract | Address |
|---|---|
| GovernanceToken (proxy) | [0x4e5823966488747a6a6BB5160896cadC7bd8337e](https://sepolia-optimism.etherscan.io/address/0x4e5823966488747a6a6bb5160896cadc7bd8337e) |
| TimelockController | [0x9Ba01c6580eF81892b9e37798B5eb3Efab2E926E](https://sepolia-optimism.etherscan.io/address/0x9ba01c6580ef81892b9e37798b5eb3efab2e926e) |
| PMGovernor | [0xf171ba61C5c819E4107b1a38d20af2c2dF2e9BB2](https://sepolia-optimism.etherscan.io/address/0xf171ba61c5c819e4107b1a38d20af2c2df2e9bb2) |
| OutcomeShareToken | [0x554FD096F3Fcf4f0645a7aD939a829c70ad658AD](https://sepolia-optimism.etherscan.io/address/0x554fd096f3fcf4f0645a7ad939a829c70ad658ad) |
| ChainlinkAdapter | [0x9054A39BaaD90D9845e088604Ab93F5a58444911](https://sepolia-optimism.etherscan.io/address/0x9054a39baad90d9845e088604ab93f5a58444911) |
| FeeVault | [0x52574b3FeF0271e9013e7e1aE87Ec674d950BA83](https://sepolia-optimism.etherscan.io/address/0x52574b3fef0271e9013e7e1ae87ec674d950ba83) |
| MarketAMM | [0x8bE8A2E7FEf800AE88558a4228D80B54e5d9ea5e](https://sepolia-optimism.etherscan.io/address/0x8be8a2e7fef800ae88558a4228d80b54e5d9ea5e) |
| PredictionMarket | [0xc6d169F69951831A2da5490b09780F42544fc405](https://sepolia-optimism.etherscan.io/address/0xc6d169f69951831a2da5490b09780f42544fc405) |

Network: Optimism Sepolia (Chain ID: 11155420)

## Subgraph

```bash
cd subgraph
npm install

# Generate types from ABI
graph codegen

# Build WASM
graph build

# Deploy to The Graph Studio
graph deploy --studio prediction-market
```

Indexes: `Market`, `Trade`, `LiquidityPosition`, `GovernanceProposal`, `ProposalVote`, `ProtocolStats`.

---

## Frontend

Open `frontend/index.html` in a browser with MetaMask installed and connected to Arbitrum Sepolia.

Update `ADDRESSES` in the script block with deployed contract addresses and update `GRAPH_URL` with your subgraph endpoint before use.

---

## CI/CD

GitHub Actions pipeline (`.github/workflows/ci.yml`):

1. `forge build --sizes` — compile and report contract sizes
2. `forge fmt --check` — formatting gate
3. `forge test -v` — full test suite
4. `forge coverage --report lcov` — coverage report uploaded as artifact
5. `crytic/slither-action` — static analysis (non-blocking)
6. `solhint 'src/**/*.sol'` — Solidity linting

---

## Documentation

| Document | Description |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | C4 diagrams, data flows, storage layouts, trust model |
| [`docs/security-audit.md`](docs/security-audit.md) | Audit findings, mitigations, Slither output |
| [`docs/gas-optimization.md`](docs/gas-optimization.md) | Yul vs Solidity benchmarks, storage packing analysis |

---

## Security Properties

- **UUPS proxy** with `onlyOwner` upgrade guard; owner transferred to Timelock post-deploy.
- **ReentrancyGuard** on all state-changing AMM and market functions.
- **Checks-Effects-Interactions** pattern throughout.
- **SafeERC20** (`forceApprove`) for all ERC-20 interactions.
- **Pull-over-push** payments in `claimWinnings`.
- **Chainlink staleness guard** (1-hour max age) prevents stale oracle resolution.
- **2-day Timelock** on all governance actions.
- **Pausable** AMM as circuit breaker.

---

## License

MIT
