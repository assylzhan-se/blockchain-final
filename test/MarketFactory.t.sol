// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./BaseTest.sol";

contract MarketFactoryTest is BaseTest {
    // ─── deployMarket (CREATE) ─────────────────────────────────────────────────

    function test_deployMarket_ownerCanDeploy() public {
        vm.prank(admin);
        address deployed = factory.deployMarket();
        assertFalse(deployed == address(0));
        assertEq(factory.deployedMarketsCount(), 1);
    }

    function test_deployMarket_revert_nonOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        factory.deployMarket();
    }

    function test_deployMarket_tracksMultiple() public {
        vm.startPrank(admin);
        factory.deployMarket();
        factory.deployMarket();
        factory.deployMarket();
        vm.stopPrank();
        assertEq(factory.deployedMarketsCount(), 3);
    }

    function test_deployMarket_storesInArray() public {
        vm.prank(admin);
        address deployed = factory.deployMarket();
        assertEq(factory.deployedMarkets(0), deployed);
    }

    function test_deployMarket_differentAddressEachTime() public {
        vm.startPrank(admin);
        address a = factory.deployMarket();
        address b = factory.deployMarket();
        vm.stopPrank();
        assertFalse(a == b);
    }

    // ─── deployMarketDeterministic (CREATE2) ──────────────────────────────────

    function test_deployMarketDeterministic_matchesPredictedAddress() public {
        bytes32 salt = keccak256("test-salt");
        address predicted = factory.computeAddress(salt);

        vm.prank(admin);
        address deployed = factory.deployMarketDeterministic(salt);
        assertEq(deployed, predicted);
    }

    function test_deployMarketDeterministic_revert_saltReused() public {
        bytes32 salt = keccak256("used-salt");
        vm.prank(admin);
        factory.deployMarketDeterministic(salt);

        vm.prank(admin);
        vm.expectRevert("MarketFactory: salt already used");
        factory.deployMarketDeterministic(salt);
    }

    function test_deployMarketDeterministic_differentSalts_differentAddresses() public {
        vm.startPrank(admin);
        address a = factory.deployMarketDeterministic(keccak256("salt-a"));
        address b = factory.deployMarketDeterministic(keccak256("salt-b"));
        vm.stopPrank();
        assertFalse(a == b);
    }

    function test_saltToMarket_mappingUpdated() public {
        bytes32 salt = keccak256("mapping-salt");
        vm.prank(admin);
        address deployed = factory.deployMarketDeterministic(salt);
        assertEq(factory.saltToMarket(salt), deployed);
    }

    function test_deployMarketDeterministic_revert_nonOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        factory.deployMarketDeterministic(keccak256("hack"));
    }

    // ─── computeAddress ───────────────────────────────────────────────────────

    function test_computeAddress_deterministicBeforeDeploy() public view {
        bytes32 salt = keccak256("future");
        address predicted = factory.computeAddress(salt);
        assertFalse(predicted == address(0));
    }

    function test_deployedMarketsCount_startsAtZero() public view {
        assertEq(factory.deployedMarketsCount(), 0);
    }
}
