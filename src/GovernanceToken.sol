// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";

/// @title GovernanceToken V1
/// @notice ERC20Votes + ERC20Permit governance token with UUPS upgradeability.
///         V1 → V2 upgrade path: V2 adds burn capability (see GovernanceTokenV2.sol).
contract GovernanceToken is
    Initializable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    ERC20VotesUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    /// @custom:storage-location erc7201:predictionmarket.storage.GovernanceToken
    struct GovernanceTokenStorage {
        uint256 maxSupply;
    }

    // keccak256(abi.encode(uint256(keccak256("predictionmarket.storage.GovernanceToken")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant GOVERNANCE_TOKEN_STORAGE_LOCATION =
        0x5320cba978ec7c74aad3a7178916d3e8ae962287304238eecc4848e2f5ca7900;

    function _getStorage() private pure returns (GovernanceTokenStorage storage $) {
        assembly {
            $.slot := GOVERNANCE_TOKEN_STORAGE_LOCATION
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, uint256 initialSupply, uint256 maxSupply_) public initializer {
        __ERC20_init("Prediction Market Governance", "PMG");
        __ERC20Permit_init("Prediction Market Governance");
        __ERC20Votes_init();
        __Ownable_init(initialOwner);

        GovernanceTokenStorage storage $ = _getStorage();
        $.maxSupply = maxSupply_;

        _mint(initialOwner, initialSupply);
    }

    /// @notice Mint new tokens. Only callable by owner (Timelock after governance transfer).
    function mint(address to, uint256 amount) external onlyOwner {
        GovernanceTokenStorage storage $ = _getStorage();
        require(totalSupply() + amount <= $.maxSupply, "GovernanceToken: exceeds max supply");
        _mint(to, amount);
    }

    function maxSupply() external view returns (uint256) {
        return _getStorage().maxSupply;
    }

    /// @dev Required by UUPS — only owner (Timelock) can upgrade
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ─── Required overrides ───────────────────────────────────────────────────

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20VotesUpgradeable)
    {
        super._update(from, to, value);
    }

    function nonces(address owner)
        public
        view
        override(ERC20PermitUpgradeable, NoncesUpgradeable)
        returns (uint256)
    {
        return super.nonces(owner);
    }
}
