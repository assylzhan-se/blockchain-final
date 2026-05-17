// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FeeVault
/// @notice ERC-4626 compliant vault that accumulates trading fees and distributes yield to LPs.
///         LP providers deposit collateral tokens to receive vault shares.
///         Trading fees from MarketAMM are deposited here, increasing share value.
///
/// @dev ERC-4626 rounding invariants:
///      - convertToShares: rounds DOWN (protects vault from inflation attacks)
///      - convertToAssets: rounds DOWN (protects depositors on withdraw)
///      - previewMint / previewWithdraw: round UP (caller pays more, vault receives more)
contract FeeVault is ERC4626, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    bytes32 public constant FEE_DEPOSITOR_ROLE = keccak256("FEE_DEPOSITOR_ROLE");

    uint256 public totalFeesAccumulated;

    event FeeDeposited(address indexed from, uint256 amount);

    error ZeroShares();
    error ZeroAssets();

    constructor(IERC20 asset_, address admin) ERC4626(asset_) ERC20("PM Fee Vault Shares", "PMVS") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Called by MarketAMM to deposit collected fees into the vault.
    ///         Increases total assets → increases share value for all LPs.
    function depositFee(uint256 amount) external onlyRole(FEE_DEPOSITOR_ROLE) {
        require(amount > 0, "FeeVault: zero fee");
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        totalFeesAccumulated += amount;
        emit FeeDeposited(msg.sender, amount);
    }

    /// @notice ERC-4626 deposit with reentrancy guard
    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256 shares) {
        if (assets == 0) revert ZeroAssets();
        shares = super.deposit(assets, receiver);
        if (shares == 0) revert ZeroShares();
    }

    /// @notice ERC-4626 mint with reentrancy guard
    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256 assets) {
        if (shares == 0) revert ZeroShares();
        assets = super.mint(shares, receiver);
    }

    /// @notice ERC-4626 withdraw with reentrancy guard
    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAssets();
        shares = super.withdraw(assets, receiver, owner_);
    }

    /// @notice ERC-4626 redeem with reentrancy guard
    function redeem(uint256 shares, address receiver, address owner_)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        if (shares == 0) revert ZeroShares();
        assets = super.redeem(shares, receiver, owner_);
    }

    // ─── ERC-4626 rounding overrides ─────────────────────────────────────────

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 supply = totalSupply();
        return (assets == 0 || supply == 0)
            ? assets
            : assets.mulDiv(supply, totalAssets(), rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 supply = totalSupply();
        return (supply == 0) ? shares : shares.mulDiv(totalAssets(), supply, rounding);
    }
}
