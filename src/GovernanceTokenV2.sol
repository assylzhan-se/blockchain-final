// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./GovernanceToken.sol";

/// @title GovernanceToken V2
/// @notice Upgrade from V1: adds burn capability for token holders.
///         Storage layout is strictly additive — no existing slots are changed.
///         Upgrade is triggered via DAO proposal → Timelock execute → upgradeToAndCall().
contract GovernanceTokenV2 is GovernanceToken {
    // No new storage variables needed for burn — uses inherited state.
    // If new storage is needed, MUST use ERC-7201 namespaced storage to avoid collisions.

    /// @notice Burn tokens from caller's balance
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @notice Burn tokens from another account (requires allowance)
    function burnFrom(address account, uint256 amount) external {
        _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
    }

    /// @notice Version identifier for upgrade verification
    function version() external pure returns (string memory) {
        return "2.0.0";
    }
}
