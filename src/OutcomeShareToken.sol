// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title OutcomeShareToken
/// @notice ERC-1155 tokens representing binary outcome shares in prediction markets.
///         Token ID encoding: marketId * 2 + outcome (0=NO, 1=YES)
contract OutcomeShareToken is ERC1155, AccessControl, ReentrancyGuard {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /// @notice Emitted when outcome shares are minted
    event SharesMinted(uint256 indexed marketId, uint8 indexed outcome, address indexed to, uint256 amount);
    /// @notice Emitted when outcome shares are burned
    event SharesBurned(uint256 indexed marketId, uint8 indexed outcome, address indexed from, uint256 amount);

    constructor(address admin) ERC1155("https://api.predictionmarket.xyz/token/{id}.json") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Encode marketId + outcome into a single token ID
    function tokenId(uint256 marketId, uint8 outcome) public pure returns (uint256) {
        require(outcome <= 1, "OutcomeShareToken: outcome must be 0 or 1");
        return marketId * 2 + outcome;
    }

    /// @notice Mint outcome shares. Only callable by MINTER_ROLE (MarketAMM).
    function mint(address to, uint256 marketId, uint8 outcome, uint256 amount) external onlyRole(MINTER_ROLE) {
        uint256 id = tokenId(marketId, outcome);
        _mint(to, id, amount, "");
        emit SharesMinted(marketId, outcome, to, amount);
    }

    /// @notice Burn outcome shares after market resolution. Only BURNER_ROLE (PredictionMarket).
    function burn(address from, uint256 marketId, uint8 outcome, uint256 amount) external onlyRole(BURNER_ROLE) {
        uint256 id = tokenId(marketId, outcome);
        _burn(from, id, amount);
        emit SharesBurned(marketId, outcome, from, amount);
    }

    /// @notice Burn caller's own shares (for redemption)
    function burnSelf(uint256 marketId, uint8 outcome, uint256 amount) external nonReentrant {
        uint256 id = tokenId(marketId, outcome);
        _burn(msg.sender, id, amount);
        emit SharesBurned(marketId, outcome, msg.sender, amount);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC1155, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
