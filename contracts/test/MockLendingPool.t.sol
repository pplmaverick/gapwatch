// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {GapwatchRegistry} from "../src/GapwatchRegistry.sol";
import {MockLendingPool} from "../src/MockLendingPool.sol";

contract MockLendingPoolTest is Test {
    GapwatchRegistry registry;
    MockLendingPool pool;

    address relayer = makeAddr("relayer");
    address user = makeAddr("user");
    address token = makeAddr("token");
    address stranger = makeAddr("stranger");

    bytes32 constant EVENT_HASH = keccak256("nvda-event-1");
    uint256 constant BOND = 0.001 ether;

    function setUp() public {
        registry = new GapwatchRegistry(relayer, BOND, 1 days);
        pool = new MockLendingPool(address(registry));

        vm.deal(relayer, 1 ether);
        vm.prank(relayer);
        registry.recordVerification{value: BOND}(EVENT_HASH, token, 1e18, 1e18, false, bytes32(0));
    }

    function test_openPosition_recordsData() public {
        vm.prank(user);
        pool.openPosition(token, 100);

        (address posToken, uint256 amount) = pool.positions(user);
        assertEq(posToken, token);
        assertEq(amount, 100);
    }

    function test_checkLiquidatable_normalConditions() public {
        vm.prank(user);
        pool.openPosition(token, 100);

        assertTrue(pool.checkLiquidatable(user));
    }

    function test_checkLiquidatable_falseForEmptyPosition() public view {
        assertFalse(pool.checkLiquidatable(user));
    }

    function test_pauseLiquidation_revertsWithoutDiscrepancy() public {
        vm.expectRevert(
            abi.encodeWithSelector(MockLendingPool.NoDiscrepancyFlagged.selector, EVENT_HASH)
        );
        pool.pauseLiquidation(token);
    }

    function test_pauseLiquidation_revertsForTokenNeverVerified() public {
        address unverifiedToken = makeAddr("unverifiedToken");
        vm.expectRevert(
            abi.encodeWithSelector(MockLendingPool.NoVerificationForToken.selector, unverifiedToken)
        );
        pool.pauseLiquidation(unverifiedToken);
    }

    function test_pauseLiquidation_succeedsAfterDiscrepancyReported() public {
        vm.prank(user);
        pool.openPosition(token, 100);
        assertTrue(pool.checkLiquidatable(user));

        vm.prank(relayer);
        registry.reportDiscrepancy(EVENT_HASH, "reference model mismatch");

        // Anyone can call pauseLiquidation -- the gate is the registry data, not
        // the caller's identity.
        vm.prank(stranger);
        pool.pauseLiquidation(token);

        assertTrue(pool.tokenLiquidationPaused(token));
        assertFalse(pool.checkLiquidatable(user));
    }

    function test_reportDiscrepancy_revertsForNonRelayerNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(GapwatchRegistry.NotAuthorized.selector);
        registry.reportDiscrepancy(EVENT_HASH, "not my place to say");
    }

    function test_reportDiscrepancy_ownerCanAlsoReport() public {
        // owner is address(this) in this test contract (the deployer of registry)
        registry.reportDiscrepancy(EVENT_HASH, "owner flagged it");
        assertTrue(registry.hasDiscrepancy(EVENT_HASH));
    }
}
