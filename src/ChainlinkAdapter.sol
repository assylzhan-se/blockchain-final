// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title IOracle — Oracle adapter interface abstraction
interface IOracle {
    function getLatestPrice(address feed) external view returns (int256 price, uint256 updatedAt);
    function validateFresh(address feed) external view returns (int256 price);
}

/// @title ChainlinkAdapter
/// @notice Oracle adapter pattern wrapping Chainlink AggregatorV3Interface.
///         Reverts if price data is stale (older than MAX_STALENESS seconds).
contract ChainlinkAdapter is IOracle, Ownable {
    uint256 public constant MAX_STALENESS = 3600; // 1 hour

    /// @notice Override staleness per feed (0 = use default)
    mapping(address => uint256) public feedStaleness;

    event StalenessOverrideSet(address indexed feed, uint256 maxStaleness);

    error StalePrice(address feed, uint256 updatedAt, uint256 currentTime);
    error InvalidPrice(address feed, int256 price);
    error InvalidRound(address feed);

    constructor(address owner_) Ownable(owner_) {}

    function setStalenessOverride(address feed, uint256 maxStaleness) external onlyOwner {
        feedStaleness[feed] = maxStaleness;
        emit StalenessOverrideSet(feed, maxStaleness);
    }

    /// @notice Returns price and timestamp without staleness check
    function getLatestPrice(address feed) external view override returns (int256 price, uint256 updatedAt) {
        uint256 latestUpdatedAt;
        (, price,, latestUpdatedAt,) = AggregatorV3Interface(feed).latestRoundData();
        updatedAt = latestUpdatedAt;
    }

    /// @notice Returns price, reverts if stale or invalid
    function validateFresh(address feed) external view override returns (int256 price) {
        (uint80 roundId, int256 _price,, uint256 updatedAt, uint80 answeredInRound) =
            AggregatorV3Interface(feed).latestRoundData();

        if (answeredInRound < roundId) revert InvalidRound(feed);
        if (_price <= 0) revert InvalidPrice(feed, _price);

        uint256 maxStale = feedStaleness[feed] == 0 ? MAX_STALENESS : feedStaleness[feed];
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp - updatedAt > maxStale) {
            revert StalePrice(feed, updatedAt, block.timestamp);
        }

        price = _price;
    }

    /// @notice Convenience: get price with decimals
    function getPriceWithDecimals(address feed) external view returns (int256 price, uint8 decimals) {
        price = this.validateFresh(feed);
        decimals = AggregatorV3Interface(feed).decimals();
    }
}

/// @title MockAggregator — for tests only
contract MockAggregator is AggregatorV3Interface {
    int256 private _price;
    uint256 private _updatedAt;
    uint80 private _roundId;
    uint8 private _decimals;

    constructor(int256 initialPrice, uint8 decimals_) {
        _price = initialPrice;
        _updatedAt = block.timestamp;
        _roundId = 1;
        _decimals = decimals_;
    }

    function setPrice(int256 price_) external {
        _price = price_;
        _updatedAt = block.timestamp;
        _roundId++;
    }

    function setUpdatedAt(uint256 ts) external {
        _updatedAt = ts;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external pure override returns (string memory) {
        return "Mock/USD";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(uint80 _rid)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_rid, _price, _updatedAt, _updatedAt, _rid);
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _price, _updatedAt, _updatedAt, _roundId);
    }
}
