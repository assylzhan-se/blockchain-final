import {
  BigInt,
  Bytes,
  Address,
  log,
} from "@graphprotocol/graph-ts";

import {
  MarketCreated,
  MarketActivated,
  MarketDisputeStarted,
  MarketResolved,
  WinningsClaimed,
} from "../generated/PredictionMarket/PredictionMarket";

import {
  SharesBought,
  SharesSold,
  LiquidityAdded,
  LiquidityRemoved,
  FeeCollected,
} from "../generated/MarketAMM/MarketAMM";

import {
  ProposalCreated,
  VoteCast,
  ProposalQueued,
  ProposalExecuted,
  ProposalCanceled,
} from "../generated/PMGovernor/PMGovernor";

import {
  Market,
  Trade,
  LiquidityPosition,
  GovernanceProposal,
  ProposalVote,
  ProtocolStats,
} from "../generated/schema";

// ─── Helpers ─────────────────────────────────────────────────────────────────

function loadOrCreateProtocolStats(): ProtocolStats {
  let stats = ProtocolStats.load("global");
  if (stats == null) {
    stats = new ProtocolStats("global");
    stats.totalMarketsCreated = BigInt.fromI32(0);
    stats.totalTradeVolume = BigInt.fromI32(0);
    stats.totalFeesCollected = BigInt.fromI32(0);
    stats.totalLiquidityProvided = BigInt.fromI32(0);
    stats.lastUpdated = BigInt.fromI32(0);
  }
  return stats as ProtocolStats;
}

// ─── PredictionMarket handlers ────────────────────────────────────────────────

export function handleMarketCreated(event: MarketCreated): void {
  let marketId = event.params.marketId.toString();
  let market = new Market(marketId);

  market.question = event.params.question;
  market.resolutionFeed = event.params.feed;
  market.resolutionThreshold = event.params.threshold;
  market.state = "CREATED";
  market.winningOutcome = null;
  market.initialLiquidity = BigInt.fromI32(0);
  market.createdAt = event.block.timestamp;
  market.resolvedAt = null;

  market.save();

  let stats = loadOrCreateProtocolStats();
  stats.totalMarketsCreated = stats.totalMarketsCreated.plus(BigInt.fromI32(1));
  stats.lastUpdated = event.block.timestamp;
  stats.save();
}

export function handleMarketActivated(event: MarketActivated): void {
  let market = Market.load(event.params.marketId.toString());
  if (market == null) {
    log.warning("handleMarketActivated: market {} not found", [
      event.params.marketId.toString(),
    ]);
    return;
  }
  market.state = "ACTIVE";
  market.save();
}

export function handleMarketDisputeStarted(
  event: MarketDisputeStarted
): void {
  let market = Market.load(event.params.marketId.toString());
  if (market == null) {
    log.warning("handleMarketDisputeStarted: market {} not found", [
      event.params.marketId.toString(),
    ]);
    return;
  }
  market.state = "DISPUTE";
  market.save();
}

export function handleMarketResolved(event: MarketResolved): void {
  let market = Market.load(event.params.marketId.toString());
  if (market == null) {
    log.warning("handleMarketResolved: market {} not found", [
      event.params.marketId.toString(),
    ]);
    return;
  }
  market.state = "RESOLVED";
  market.winningOutcome = event.params.winningOutcome as i32;
  market.resolvedAt = event.block.timestamp;
  market.save();
}

export function handleWinningsClaimed(event: WinningsClaimed): void {
  let market = Market.load(event.params.marketId.toString());
  if (market == null) {
    log.warning("handleWinningsClaimed: market {} not found", [
      event.params.marketId.toString(),
    ]);
    return;
  }
  // Update market state to CLOSED once the first claim is processed.
  // The contract emits WinningsClaimed for each individual claimant.
  if (market.state == "RESOLVED") {
    market.state = "CLOSED";
    market.save();
  }
}

// ─── MarketAMM handlers ───────────────────────────────────────────────────────

export function handleSharesBought(event: SharesBought): void {
  let id =
    event.transaction.hash.toHexString() +
    "-" +
    event.logIndex.toString();

  let trade = new Trade(id);
  trade.market = event.params.marketId.toString();
  trade.trader = event.params.buyer;
  trade.outcome = event.params.outcome as i32;
  trade.amountIn = event.params.amountIn;
  trade.amountOut = event.params.amountOut;
  trade.isBuy = true;
  trade.timestamp = event.block.timestamp;
  trade.blockNumber = event.block.number;
  trade.save();

  let stats = loadOrCreateProtocolStats();
  stats.totalTradeVolume = stats.totalTradeVolume.plus(event.params.amountIn);
  stats.lastUpdated = event.block.timestamp;
  stats.save();
}

export function handleSharesSold(event: SharesSold): void {
  let id =
    event.transaction.hash.toHexString() +
    "-" +
    event.logIndex.toString();

  let trade = new Trade(id);
  trade.market = event.params.marketId.toString();
  trade.trader = event.params.seller;
  trade.outcome = event.params.outcome as i32;
  trade.amountIn = event.params.amountIn;
  trade.amountOut = event.params.amountOut;
  trade.isBuy = false;
  trade.timestamp = event.block.timestamp;
  trade.blockNumber = event.block.number;
  trade.save();

  let stats = loadOrCreateProtocolStats();
  stats.totalTradeVolume = stats.totalTradeVolume.plus(event.params.amountOut);
  stats.lastUpdated = event.block.timestamp;
  stats.save();
}

export function handleLiquidityAdded(event: LiquidityAdded): void {
  let posId =
    event.params.marketId.toString() +
    "-" +
    event.params.provider.toHexString();

  let pos = LiquidityPosition.load(posId);
  if (pos == null) {
    pos = new LiquidityPosition(posId);
    pos.market = event.params.marketId.toString();
    pos.provider = event.params.provider;
    pos.liquidity = BigInt.fromI32(0);
  }
  pos.liquidity = pos.liquidity.plus(event.params.liquidity);
  pos.lastUpdated = event.block.timestamp;
  pos.save();

  let stats = loadOrCreateProtocolStats();
  stats.totalLiquidityProvided = stats.totalLiquidityProvided.plus(
    event.params.liquidity
  );
  stats.lastUpdated = event.block.timestamp;
  stats.save();
}

export function handleLiquidityRemoved(event: LiquidityRemoved): void {
  let posId =
    event.params.marketId.toString() +
    "-" +
    event.params.provider.toHexString();

  let pos = LiquidityPosition.load(posId);
  if (pos == null) {
    log.warning("handleLiquidityRemoved: position {} not found", [posId]);
    return;
  }
  pos.liquidity = pos.liquidity.minus(event.params.liquidity);
  if (pos.liquidity.lt(BigInt.fromI32(0))) {
    pos.liquidity = BigInt.fromI32(0);
  }
  pos.lastUpdated = event.block.timestamp;
  pos.save();
}

export function handleFeeCollected(event: FeeCollected): void {
  let stats = loadOrCreateProtocolStats();
  stats.totalFeesCollected = stats.totalFeesCollected.plus(
    event.params.feeAmount
  );
  stats.lastUpdated = event.block.timestamp;
  stats.save();
}

// ─── PMGovernor handlers ──────────────────────────────────────────────────────

export function handleProposalCreated(event: ProposalCreated): void {
  let proposal = new GovernanceProposal(
    event.params.proposalId.toString()
  );
  proposal.proposer = event.params.proposer;
  proposal.description = event.params.description;
  proposal.state = "Pending";
  proposal.forVotes = BigInt.fromI32(0);
  proposal.againstVotes = BigInt.fromI32(0);
  proposal.abstainVotes = BigInt.fromI32(0);
  proposal.startBlock = event.params.voteStart;
  proposal.endBlock = event.params.voteEnd;
  proposal.executedAt = null;
  proposal.save();
}

export function handleVoteCast(event: VoteCast): void {
  let voteId =
    event.params.proposalId.toString() +
    "-" +
    event.params.voter.toHexString();

  let vote = new ProposalVote(voteId);
  vote.proposal = event.params.proposalId.toString();
  vote.voter = event.params.voter;
  vote.support = event.params.support as i32;
  vote.weight = event.params.weight;
  vote.reason = event.params.reason;
  vote.timestamp = event.block.timestamp;
  vote.save();

  let proposal = GovernanceProposal.load(
    event.params.proposalId.toString()
  );
  if (proposal == null) {
    log.warning("handleVoteCast: proposal {} not found", [
      event.params.proposalId.toString(),
    ]);
    return;
  }

  // 0=Against 1=For 2=Abstain
  if (event.params.support == 0) {
    proposal.againstVotes = proposal.againstVotes.plus(event.params.weight);
  } else if (event.params.support == 1) {
    proposal.forVotes = proposal.forVotes.plus(event.params.weight);
    proposal.state = "Active";
  } else {
    proposal.abstainVotes = proposal.abstainVotes.plus(event.params.weight);
  }
  proposal.save();
}

export function handleProposalQueued(event: ProposalQueued): void {
  let proposal = GovernanceProposal.load(
    event.params.proposalId.toString()
  );
  if (proposal == null) {
    log.warning("handleProposalQueued: proposal {} not found", [
      event.params.proposalId.toString(),
    ]);
    return;
  }
  proposal.state = "Queued";
  proposal.save();
}

export function handleProposalExecuted(event: ProposalExecuted): void {
  let proposal = GovernanceProposal.load(
    event.params.proposalId.toString()
  );
  if (proposal == null) {
    log.warning("handleProposalExecuted: proposal {} not found", [
      event.params.proposalId.toString(),
    ]);
    return;
  }
  proposal.state = "Executed";
  proposal.executedAt = event.block.timestamp;
  proposal.save();
}

export function handleProposalCanceled(event: ProposalCanceled): void {
  let proposal = GovernanceProposal.load(
    event.params.proposalId.toString()
  );
  if (proposal == null) {
    log.warning("handleProposalCanceled: proposal {} not found", [
      event.params.proposalId.toString(),
    ]);
    return;
  }
  proposal.state = "Canceled";
  proposal.save();
}
