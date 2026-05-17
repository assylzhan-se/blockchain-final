// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./PredictionMarket.sol";

/// @title MarketFactory
/// @notice Factory pattern for deploying PredictionMarket instances.
///         Uses both CREATE (standard deployment) and CREATE2 (deterministic deployment).
contract MarketFactory is Ownable {
    address public immutable collateral;
    address public immutable shareToken;
    address public immutable amm;
    address public immutable oracle;

    address[] public deployedMarkets;
    mapping(bytes32 => address) public saltToMarket;

    event MarketDeployed(address indexed market, uint256 indexed index, bool deterministic);

    constructor(
        address collateral_,
        address shareToken_,
        address amm_,
        address oracle_,
        address owner_
    ) Ownable(owner_) {
        collateral = collateral_;
        shareToken = shareToken_;
        amm = amm_;
        oracle = oracle_;
    }

    /// @notice Deploy a new PredictionMarket using standard CREATE
    function deployMarket() external onlyOwner returns (address market) {
        // CREATE — address depends on nonce, not deterministic
        market = address(new PredictionMarket(
            collateral,
            shareToken,
            amm,
            oracle,
            owner()
        ));

        deployedMarkets.push(market);
        emit MarketDeployed(market, deployedMarkets.length - 1, false);
    }

    /// @notice Deploy a new PredictionMarket at a deterministic address using CREATE2
    /// @param salt  Arbitrary salt — allows pre-computing the deployment address
    function deployMarketDeterministic(bytes32 salt) external onlyOwner returns (address market) {
        require(saltToMarket[salt] == address(0), "MarketFactory: salt already used");

        // CREATE2 — address = keccak256(0xff ++ deployer ++ salt ++ keccak256(initcode))
        market = address(new PredictionMarket{salt: salt}(
            collateral,
            shareToken,
            amm,
            oracle,
            owner()
        ));

        saltToMarket[salt] = market;
        deployedMarkets.push(market);
        emit MarketDeployed(market, deployedMarkets.length - 1, true);
    }

    /// @notice Pre-compute the CREATE2 address for a given salt
    function computeAddress(bytes32 salt) external view returns (address predicted) {
        bytes memory bytecode = abi.encodePacked(
            type(PredictionMarket).creationCode,
            abi.encode(collateral, shareToken, amm, oracle, owner())
        );
        bytes32 hash = keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            salt,
            keccak256(bytecode)
        ));
        predicted = address(uint160(uint256(hash)));
    }

    function deployedMarketsCount() external view returns (uint256) {
        return deployedMarkets.length;
    }
}
