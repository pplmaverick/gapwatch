// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GapwatchRegistry} from "../src/GapwatchRegistry.sol";

/// @dev Attempts to re-enter `withdraw()` from within its own receive callback.
contract ReentrantWithdrawer {
    GapwatchRegistry public registry;
    uint256 public reentryAttempts;
    bool public reentryReverted;

    constructor(GapwatchRegistry _registry) {
        registry = _registry;
    }

    function attack() external {
        registry.withdraw();
    }

    receive() external payable {
        if (reentryAttempts == 0) {
            reentryAttempts++;
            try registry.withdraw() {
                // If this succeeds, ReentrancyGuard failed to do its job.
            } catch {
                reentryReverted = true;
            }
        }
    }
}

contract GapwatchRegistryTest is Test {
    GapwatchRegistry registry;

    address relayer = makeAddr("relayer");
    address stranger = makeAddr("stranger");
    address token = makeAddr("token");
    address challenger = makeAddr("challenger");

    bytes32 constant EVENT_HASH = keccak256("nvda-event-1");

    uint256 constant BOND = 0.001 ether;
    uint256 constant WINDOW = 1 days;

    function setUp() public {
        registry = new GapwatchRegistry(relayer, BOND, WINDOW);
        vm.deal(relayer, 10 ether);
        vm.deal(stranger, 10 ether);
        vm.deal(challenger, 10 ether);
    }

    function _record() internal {
        vm.prank(relayer);
        registry.recordVerification{value: BOND}(EVENT_HASH, token, 1e18, 1e18, false, bytes32(0));
    }

    // -------------------------------------------------------------------- //
    // recordVerification / bonding
    // -------------------------------------------------------------------- //

    function test_recordVerification_happyPath() public {
        _record();
        assertTrue(registry.isVerified(EVENT_HASH));

        GapwatchRegistry.Verification memory v = registry.getVerification(EVENT_HASH);
        assertEq(v.token, token);
        assertEq(v.bond, BOND);
        assertEq(v.recordedBy, relayer);
        assertEq(address(registry).balance, BOND);
    }

    function test_recordVerification_revertsOnInsufficientBond() public {
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(GapwatchRegistry.InsufficientBond.selector, BOND, BOND - 1)
        );
        registry.recordVerification{value: BOND - 1}(EVENT_HASH, token, 1e18, 1e18, false, bytes32(0));
    }

    function test_recordVerification_revertsForNonRelayer() public {
        vm.prank(stranger);
        vm.expectRevert(GapwatchRegistry.NotRelayer.selector);
        registry.recordVerification{value: BOND}(EVENT_HASH, token, 1e18, 1e18, false, bytes32(0));
    }

    function test_recordVerification_revertsOnDoubleRecord() public {
        _record();
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(GapwatchRegistry.AlreadyRecorded.selector, EVENT_HASH)
        );
        registry.recordVerification{value: BOND}(EVENT_HASH, token, 1e18, 2e18, true, bytes32(uint256(1)));
    }

    function test_recordVerification_revertsOnZeroTokenAddress() public {
        vm.prank(relayer);
        vm.expectRevert(GapwatchRegistry.ZeroAddress.selector);
        registry.recordVerification{value: BOND}(EVENT_HASH, address(0), 1e18, 1e18, false, bytes32(0));
    }

    // -------------------------------------------------------------------- //
    // challenge
    // -------------------------------------------------------------------- //

    function test_challenge_happyPath() public {
        _record();
        vm.prank(challenger);
        registry.challenge{value: BOND}(EVENT_HASH);

        GapwatchRegistry.Challenge memory c = registry.getChallenge(EVENT_HASH);
        assertEq(c.challenger, challenger);
        assertEq(c.amount, BOND);
        assertFalse(c.resolved);
        assertEq(address(registry).balance, BOND * 2);
    }

    function test_challenge_revertsOnInsufficientBond() public {
        _record();
        vm.prank(challenger);
        vm.expectRevert(
            abi.encodeWithSelector(GapwatchRegistry.InsufficientBond.selector, BOND, BOND - 1)
        );
        registry.challenge{value: BOND - 1}(EVENT_HASH);
    }

    function test_challenge_revertsAfterWindowExpires() public {
        _record();
        vm.warp(block.timestamp + WINDOW + 1);

        vm.prank(challenger);
        vm.expectRevert(GapwatchRegistry.ChallengeWindowExpired.selector);
        registry.challenge{value: BOND}(EVENT_HASH);
    }

    function test_challenge_revertsWhileAnotherChallengeIsActive() public {
        _record();
        vm.prank(challenger);
        registry.challenge{value: BOND}(EVENT_HASH);

        address secondChallenger = makeAddr("secondChallenger");
        vm.deal(secondChallenger, 1 ether);
        vm.prank(secondChallenger);
        vm.expectRevert(GapwatchRegistry.ChallengeAlreadyActive.selector);
        registry.challenge{value: BOND}(EVENT_HASH);
    }

    function test_challenge_revertsOnSecondAttemptAfterResolution() public {
        _record();
        vm.prank(challenger);
        registry.challenge{value: BOND}(EVENT_HASH);
        registry.resolveChallenge(EVENT_HASH, false);

        // Bond was zeroed out by the resolution; a second challenge has nothing
        // left to seize and must be rejected, not silently accepted.
        address secondChallenger = makeAddr("secondChallenger");
        vm.deal(secondChallenger, 1 ether);
        vm.prank(secondChallenger);
        vm.expectRevert(GapwatchRegistry.NothingToReclaim.selector);
        registry.challenge{value: BOND}(EVENT_HASH);
    }

    function test_challenge_revertsOnUnrecordedEvent() public {
        vm.prank(challenger);
        vm.expectRevert(
            abi.encodeWithSelector(GapwatchRegistry.NotVerified.selector, EVENT_HASH)
        );
        registry.challenge{value: BOND}(EVENT_HASH);
    }

    // -------------------------------------------------------------------- //
    // resolveChallenge
    // -------------------------------------------------------------------- //

    function test_resolveChallenge_challengerWins_paysOutCorrectly() public {
        _record();
        vm.prank(challenger);
        registry.challenge{value: BOND}(EVENT_HASH);

        registry.resolveChallenge(EVENT_HASH, true);

        assertEq(registry.pendingWithdrawals(challenger), BOND * 2);
        assertEq(registry.pendingWithdrawals(relayer), 0);

        vm.prank(challenger);
        registry.withdraw();
        assertEq(challenger.balance, 10 ether - BOND + BOND * 2);

        vm.prank(relayer);
        registry.withdraw(); // no-op, nothing pending
        assertEq(relayer.balance, 10 ether - BOND);
    }

    function test_resolveChallenge_relayerWins_paysOutCorrectly() public {
        _record();
        vm.prank(challenger);
        registry.challenge{value: BOND}(EVENT_HASH);

        registry.resolveChallenge(EVENT_HASH, false);

        assertEq(registry.pendingWithdrawals(relayer), BOND * 2);
        assertEq(registry.pendingWithdrawals(challenger), 0);

        vm.prank(relayer);
        registry.withdraw();
        assertEq(relayer.balance, 10 ether - BOND + BOND * 2);

        vm.prank(challenger);
        registry.withdraw(); // no-op, nothing pending
        assertEq(challenger.balance, 10 ether - BOND);
    }

    function test_resolveChallenge_revertsForNonOwner() public {
        _record();
        vm.prank(challenger);
        registry.challenge{value: BOND}(EVENT_HASH);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        registry.resolveChallenge(EVENT_HASH, true);
    }

    function test_resolveChallenge_revertsWithNoActiveChallenge() public {
        _record();
        vm.expectRevert(GapwatchRegistry.NoActiveChallenge.selector);
        registry.resolveChallenge(EVENT_HASH, true);
    }

    function test_resolveChallenge_revertsIfAlreadyResolved() public {
        _record();
        vm.prank(challenger);
        registry.challenge{value: BOND}(EVENT_HASH);
        registry.resolveChallenge(EVENT_HASH, true);

        vm.expectRevert(GapwatchRegistry.NoActiveChallenge.selector);
        registry.resolveChallenge(EVENT_HASH, false);
    }

    /// @dev Every wei that ever entered the contract for this event (both bonds)
    ///      ends up credited to exactly one pendingWithdrawals slot -- nothing
    ///      stuck, nothing double-counted.
    function test_resolveChallenge_conservesAllFunds() public {
        _record();
        vm.prank(challenger);
        registry.challenge{value: BOND}(EVENT_HASH);

        uint256 contractBalanceBefore = address(registry).balance;
        registry.resolveChallenge(EVENT_HASH, true);

        uint256 totalCredited = registry.pendingWithdrawals(challenger) + registry.pendingWithdrawals(relayer);
        assertEq(totalCredited, contractBalanceBefore);
        assertEq(totalCredited, BOND * 2);
    }

    // -------------------------------------------------------------------- //
    // reclaimBond
    // -------------------------------------------------------------------- //

    function test_reclaimBond_afterWindowExpiresWithNoChallenge() public {
        _record();
        vm.warp(block.timestamp + WINDOW + 1);

        registry.reclaimBond(EVENT_HASH);
        assertEq(registry.pendingWithdrawals(relayer), BOND);

        vm.prank(relayer);
        registry.withdraw();
        assertEq(relayer.balance, 10 ether);
    }

    function test_reclaimBond_revertsBeforeWindowExpires() public {
        _record();
        vm.expectRevert(GapwatchRegistry.ChallengeWindowNotExpired.selector);
        registry.reclaimBond(EVENT_HASH);
    }

    function test_reclaimBond_revertsIfAlreadyResolvedByChallenge() public {
        _record();
        vm.prank(challenger);
        registry.challenge{value: BOND}(EVENT_HASH);
        registry.resolveChallenge(EVENT_HASH, false);

        vm.warp(block.timestamp + WINDOW + 1);
        vm.expectRevert(GapwatchRegistry.NothingToReclaim.selector);
        registry.reclaimBond(EVENT_HASH);
    }

    function test_reclaimBond_revertsWhileChallengeStillActive() public {
        _record();
        vm.prank(challenger);
        registry.challenge{value: BOND}(EVENT_HASH);

        vm.warp(block.timestamp + WINDOW + 1);
        vm.expectRevert(GapwatchRegistry.ChallengeAlreadyActive.selector);
        registry.reclaimBond(EVENT_HASH);
    }

    // -------------------------------------------------------------------- //
    // withdraw / reentrancy
    // -------------------------------------------------------------------- //

    function test_withdraw_zeroBalanceIsSafeNoOp() public {
        vm.prank(stranger);
        registry.withdraw(); // must not revert
        assertEq(stranger.balance, 10 ether);
    }

    function test_withdraw_reentrancyGuardBlocksReentry() public {
        ReentrantWithdrawer attacker = new ReentrantWithdrawer(registry);

        // Get the attacker contract some pendingWithdrawals via a resolved challenge
        // where it plays the challenger.
        vm.deal(address(attacker), BOND);
        _record();
        vm.prank(address(attacker));
        registry.challenge{value: BOND}(EVENT_HASH);
        registry.resolveChallenge(EVENT_HASH, true);

        assertEq(registry.pendingWithdrawals(address(attacker)), BOND * 2);

        attacker.attack();

        // The reentrant call inside receive() must have reverted...
        assertTrue(attacker.reentryReverted());
        // ...but the outer withdraw() must still have succeeded and paid out once.
        assertEq(address(attacker).balance, BOND * 2);
        assertEq(registry.pendingWithdrawals(address(attacker)), 0);
    }

    // -------------------------------------------------------------------- //
    // unknown event hash
    // -------------------------------------------------------------------- //

    function test_unknownEventHash_returnsFalseAndEmptyStruct_notRevert() public view {
        bytes32 unknown = keccak256("never-recorded");

        assertFalse(registry.isVerified(unknown));

        GapwatchRegistry.Verification memory v = registry.getVerification(unknown);
        assertEq(v.token, address(0));
        assertEq(v.oldMultiplier, 0);
        assertEq(v.newMultiplier, 0);
        assertEq(v.wasFiltered, false);
        assertEq(v.referenceModelHash, bytes32(0));
        assertEq(v.recordedAt, 0);
        assertEq(v.bond, 0);
        assertEq(v.recordedBy, address(0));
    }

    // -------------------------------------------------------------------- //
    // access control (unchanged from Tier 1)
    // -------------------------------------------------------------------- //

    function test_setRelayer_ownerCanUpdate() public {
        address newRelayer = makeAddr("newRelayer");
        registry.setRelayer(newRelayer);
        assertEq(registry.relayer(), newRelayer);
    }

    function test_setRelayer_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        registry.setRelayer(makeAddr("newRelayer"));
    }

    function test_constructor_revertsOnZeroRelayer() public {
        vm.expectRevert(GapwatchRegistry.ZeroAddress.selector);
        new GapwatchRegistry(address(0), BOND, WINDOW);
    }

    function test_setRelayer_revertsOnZeroAddress() public {
        vm.expectRevert(GapwatchRegistry.ZeroAddress.selector);
        registry.setRelayer(address(0));
    }

    /// @dev Proves the overflow-lock finding from the self-audit is actually
    ///      fixed: an excessive window is rejected up front with a clear error,
    ///      not allowed through to silently brick every future bond.
    function test_constructor_revertsOnExcessiveChallengeWindow() public {
        uint256 tooLong = registry.MAX_CHALLENGE_WINDOW() + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                GapwatchRegistry.ChallengeWindowTooLong.selector, tooLong, registry.MAX_CHALLENGE_WINDOW()
            )
        );
        new GapwatchRegistry(relayer, BOND, tooLong);
    }

    function test_setChallengeWindow_revertsOnExcessiveWindow() public {
        uint256 tooLong = type(uint256).max;
        vm.expectRevert(
            abi.encodeWithSelector(
                GapwatchRegistry.ChallengeWindowTooLong.selector, tooLong, registry.MAX_CHALLENGE_WINDOW()
            )
        );
        registry.setChallengeWindow(tooLong);
    }

    function test_setChallengeWindow_ownerCanSetWithinCap() public {
        registry.setChallengeWindow(30 days);
        assertEq(registry.challengeWindow(), 30 days);
    }

    function test_transferOwnership_ownerCanTransfer() public {
        address newOwner = makeAddr("newOwner");
        registry.transferOwnership(newOwner);
        assertEq(registry.owner(), newOwner);

        vm.prank(newOwner);
        registry.setRelayer(makeAddr("newRelayer"));

        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this))
        );
        registry.setRelayer(makeAddr("anotherRelayer"));
    }

    function test_transferOwnership_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        registry.transferOwnership(makeAddr("newOwner"));
    }

    /// @dev Relayer rotation must not let the new relayer reclaim a bond posted
    ///      by the old one -- bonds are tied to `recordedBy`, not the mutable
    ///      `relayer` pointer.
    function test_reclaimBond_afterRelayerRotation_stillPaysOriginalPoster() public {
        _record(); // posted by `relayer`
        address newRelayer = makeAddr("newRelayer");
        registry.setRelayer(newRelayer);

        vm.warp(block.timestamp + WINDOW + 1);
        registry.reclaimBond(EVENT_HASH);

        assertEq(registry.pendingWithdrawals(relayer), BOND);
        assertEq(registry.pendingWithdrawals(newRelayer), 0);
    }
}
