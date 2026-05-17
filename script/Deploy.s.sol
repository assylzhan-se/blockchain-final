// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/governance/utils/IVotes.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/ChainlinkAdapter.sol";
import "../src/FeeVault.sol";
import "../src/GovernanceToken.sol";
import "../src/MarketAMM.sol";
import "../src/OutcomeShareToken.sol";
import "../src/PMGovernor.sol";
import "../src/PredictionMarket.sol";

contract Deploy is Script {
    struct DeployedContracts {
        GovernanceToken governanceToken;
        TimelockController timelock;
        PMGovernor governor;
        OutcomeShareToken shareToken;
        ChainlinkAdapter oracle;
        FeeVault vault;
        MarketAMM amm;
        PredictionMarket predictionMarket;
    }

    uint256 internal constant DEFAULT_INITIAL_SUPPLY = 1_000_000e18;
    uint256 internal constant DEFAULT_MAX_SUPPLY = 10_000_000e18;
    uint256 internal constant DEFAULT_TIMELOCK_DELAY = 2 days;

    function run() external returns (DeployedContracts memory deployed) {
        address admin = vm.envOr("ADMIN", msg.sender);
        address collateral = vm.envAddress("COLLATERAL_TOKEN");
        uint256 initialSupply = vm.envOr("GOV_INITIAL_SUPPLY", DEFAULT_INITIAL_SUPPLY);
        uint256 maxSupply = vm.envOr("GOV_MAX_SUPPLY", DEFAULT_MAX_SUPPLY);
        uint256 timelockDelay = vm.envOr("TIMELOCK_DELAY", DEFAULT_TIMELOCK_DELAY);

        vm.startBroadcast();

        GovernanceToken govImpl = new GovernanceToken();
        bytes memory initData = abi.encodeCall(GovernanceToken.initialize, (admin, initialSupply, maxSupply));
        ERC1967Proxy govProxy = new ERC1967Proxy(address(govImpl), initData);
        deployed.governanceToken = GovernanceToken(address(govProxy));

        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = admin;
        executors[0] = address(0);
        deployed.timelock = new TimelockController(timelockDelay, proposers, executors, admin);

        deployed.governor = new PMGovernor(IVotes(address(deployed.governanceToken)), deployed.timelock);
        deployed.shareToken = new OutcomeShareToken(admin);
        deployed.oracle = new ChainlinkAdapter(admin);
        deployed.vault = new FeeVault(IERC20(collateral), admin);
        deployed.amm = new MarketAMM(collateral, address(deployed.shareToken), address(deployed.vault), admin);
        deployed.predictionMarket = new PredictionMarket(
            collateral, address(deployed.shareToken), address(deployed.amm), address(deployed.oracle), admin
        );

        deployed.shareToken.grantRole(deployed.shareToken.MINTER_ROLE(), address(deployed.amm));
        deployed.shareToken.grantRole(deployed.shareToken.BURNER_ROLE(), address(deployed.amm));
        deployed.shareToken.grantRole(deployed.shareToken.BURNER_ROLE(), address(deployed.predictionMarket));
        deployed.vault.grantRole(deployed.vault.FEE_DEPOSITOR_ROLE(), address(deployed.amm));
        deployed.amm.grantRole(deployed.amm.MARKET_MANAGER_ROLE(), address(deployed.predictionMarket));

        deployed.timelock.grantRole(deployed.timelock.PROPOSER_ROLE(), address(deployed.governor));
        deployed.timelock.grantRole(deployed.timelock.CANCELLER_ROLE(), address(deployed.governor));

        vm.stopBroadcast();
    }
}
