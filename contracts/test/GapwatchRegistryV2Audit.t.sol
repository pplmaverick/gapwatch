// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {GapwatchRegistryV2} from "../src/GapwatchRegistryV2.sol";
import {ConsensusVerifierMock} from "../src/ConsensusVerifierMock.sol";

/// @notice Deep-audit scenario tests for the bond state machine and for the
///         retroactivity of the global `challengeWindow`. Separate file from
///         GapwatchRegistryV2.t.sol so no existing test is touched.
///         Uses ConsensusVerifierMock as the IConsensusVerifier (forge cannot
///         execute the Stylus/WASM production verifier).
contract GapwatchRegistryV2AuditTest is Test {
    GapwatchRegistryV2 registry;
    ConsensusVerifierMock verifier;

    uint256 node1Pk;
    uint256 node2Pk;
    uint256 node3Pk;
    address node1;
    address node2;
    address node3;

    address recorder = makeAddr("recorder");
    address challengerA = makeAddr("challengerA");
    address challengerB = makeAddr("challengerB");
    address token = makeAddr("token");

    bytes32 constant EVENT_HASH = keccak256("audit-event-1");
    uint256 constant BOND = 0.001 ether;
    uint256 constant WINDOW = 7 days;

    function setUp() public {
        (node1, node1Pk) = makeAddrAndKey("auditnode1");
        (node2, node2Pk) = makeAddrAndKey("auditnode2");
        (node3, node3Pk) = makeAddrAndKey("auditnode3");

        verifier = new ConsensusVerifierMock();
        registry = new GapwatchRegistryV2([node1, node2, node3], address(verifier), BOND, WINDOW);

        vm.deal(recorder, 100 ether);
        vm.deal(challengerA, 100 ether);
        vm.deal(challengerB, 100 ether);
    }

    // ------------------------------------------------------------------ //
    // helpers
    // ------------------------------------------------------------------ //

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _pair(bytes memory a, bytes memory b) internal pure returns (bytes[] memory arr) {
        arr = new bytes[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _recordDigest(bytes32 eventHash) internal view returns (bytes32) {
        return keccak256(
            abi.encode(eventHash, token, uint256(1e18), uint256(2e18), false, bytes32(0), address(registry), block.chainid)
        );
    }

    function _resolveDigest(bytes32 eventHash, bool outcome) internal view returns (bytes32) {
        return keccak256(abi.encode(eventHash, outcome, address(registry), block.chainid));
    }

    function _record(bytes32 eventHash) internal {
        bytes32 d = _recordDigest(eventHash);
        bytes[] memory sigs = _pair(_sign(node1Pk, d), _sign(node2Pk, d));
        vm.prank(recorder);
        registry.recordVerification{value: BOND}(eventHash, token, 1e18, 2e18, false, bytes32(0), sigs);
    }

    // ------------------------------------------------------------------ //
    // Goal 1.1 -- challenge() on the same eventHash twice
    // ------------------------------------------------------------------ //

    /// Second challenge while the first is unresolved must revert, otherwise
    /// challenger A's ETH would be orphaned (challenges[eventHash] overwritten
    /// with no record of A's deposit and no path for A to ever recover it).
    function test_challenge_sameEventTwice() public {
        _record(EVENT_HASH);

        vm.prank(challengerA);
        registry.challenge{value: BOND}(EVENT_HASH);

        uint256 balanceBefore = address(registry).balance;

        vm.prank(challengerB);
        vm.expectRevert(GapwatchRegistryV2.ChallengeAlreadyActive.selector);
        registry.challenge{value: BOND}(EVENT_HASH);

        // Challenger A's record is intact and no second deposit was absorbed.
        GapwatchRegistryV2.Challenge memory c = registry.getChallenge(EVENT_HASH);
        assertEq(c.challenger, challengerA);
        assertEq(c.amount, BOND);
        assertEq(address(registry).balance, balanceBefore);
    }

    /// A challenge filed by the same account twice is likewise rejected -- the
    /// guard is on the challenge slot, not on the identity of the challenger.
    function test_challenge_sameChallengerTwice() public {
        _record(EVENT_HASH);

        vm.prank(challengerA);
        registry.challenge{value: BOND}(EVENT_HASH);

        vm.prank(challengerA);
        vm.expectRevert(GapwatchRegistryV2.ChallengeAlreadyActive.selector);
        registry.challenge{value: BOND}(EVENT_HASH);
    }

    /// After a challenge is resolved, the record's bond is zero, so a second
    /// challenge cannot be filed against it at all (different revert reason
    /// than the unresolved case: NothingToReclaim, hit before the
    /// ChallengeAlreadyActive guard).
    function test_challenge_afterResolution_reverts() public {
        _record(EVENT_HASH);

        vm.prank(challengerA);
        registry.challenge{value: BOND}(EVENT_HASH);

        bytes32 d = _resolveDigest(EVENT_HASH, true);
        registry.resolveChallenge(EVENT_HASH, true, _pair(_sign(node1Pk, d), _sign(node2Pk, d)));

        vm.prank(challengerB);
        vm.expectRevert(GapwatchRegistryV2.NothingToReclaim.selector);
        registry.challenge{value: BOND}(EVENT_HASH);
    }

    // ------------------------------------------------------------------ //
    // Goal 1.2 -- resolveChallenge() on the same eventHash twice
    // ------------------------------------------------------------------ //

    /// Second resolution with a DIFFERENT but equally valid 2-of-3 signature
    /// set must revert -- consensus authorising the action is not enough, the
    /// challenge slot itself must still be open, or bonds would be paid twice.
    function test_resolveChallenge_sameEventTwice() public {
        _record(EVENT_HASH);

        vm.prank(challengerA);
        registry.challenge{value: BOND}(EVENT_HASH);

        bytes32 dTrue = _resolveDigest(EVENT_HASH, true);
        // First resolution: node1 + node2.
        registry.resolveChallenge(EVENT_HASH, true, _pair(_sign(node1Pk, dTrue), _sign(node2Pk, dTrue)));

        uint256 creditedOnce = registry.pendingWithdrawals(challengerA);
        assertEq(creditedOnce, BOND * 2);

        // Second attempt, same outcome, different valid quorum: node2 + node3.
        vm.expectRevert(GapwatchRegistryV2.NoActiveChallenge.selector);
        registry.resolveChallenge(EVENT_HASH, true, _pair(_sign(node2Pk, dTrue), _sign(node3Pk, dTrue)));

        // Third attempt, opposite outcome, fresh valid quorum.
        bytes32 dFalse = _resolveDigest(EVENT_HASH, false);
        vm.expectRevert(GapwatchRegistryV2.NoActiveChallenge.selector);
        registry.resolveChallenge(EVENT_HASH, false, _pair(_sign(node1Pk, dFalse), _sign(node3Pk, dFalse)));

        // Nobody was paid twice, and the loser was never credited.
        assertEq(registry.pendingWithdrawals(challengerA), creditedOnce);
        assertEq(registry.pendingWithdrawals(recorder), 0);
    }

    // ------------------------------------------------------------------ //
    // Goal 1.4 -- reclaimBond() vs resolveChallenge() mutual exclusion
    // ------------------------------------------------------------------ //

    /// Window expiring while an unresolved challenge is outstanding: the two
    /// payout paths must be mutually exclusive, in both possible orderings.
    function test_reclaimBond_vs_resolveChallenge_race() public {
        _record(EVENT_HASH);
        uint256 recordedAt = block.timestamp;

        // Challenge filed inside the window.
        vm.warp(recordedAt + 1 days);
        vm.prank(challengerA);
        registry.challenge{value: BOND}(EVENT_HASH);

        // Move to the first instant at which reclaimBond's window test passes.
        vm.warp(recordedAt + WINDOW + 1);

        // Ordering A: reclaim attempted first -- blocked by the open challenge.
        vm.expectRevert(GapwatchRegistryV2.ChallengeAlreadyActive.selector);
        registry.reclaimBond(EVENT_HASH);

        // Resolution still works after window expiry (resolveChallenge has no
        // window check at all) and pays out exactly once.
        bytes32 d = _resolveDigest(EVENT_HASH, false);
        registry.resolveChallenge(EVENT_HASH, false, _pair(_sign(node1Pk, d), _sign(node2Pk, d)));
        assertEq(registry.pendingWithdrawals(recorder), BOND * 2);

        // And now reclaim is permanently closed off: bond already zeroed.
        vm.expectRevert(GapwatchRegistryV2.NothingToReclaim.selector);
        registry.reclaimBond(EVENT_HASH);

        // Total credited never exceeds what was actually deposited (2 x BOND).
        assertEq(
            registry.pendingWithdrawals(recorder) + registry.pendingWithdrawals(challengerA),
            BOND * 2
        );
    }

    /// Reverse ordering: resolution first, then reclaim.
    function test_reclaimBond_afterResolution_reverts() public {
        _record(EVENT_HASH);
        uint256 recordedAt = block.timestamp;

        vm.prank(challengerA);
        registry.challenge{value: BOND}(EVENT_HASH);

        bytes32 d = _resolveDigest(EVENT_HASH, true);
        registry.resolveChallenge(EVENT_HASH, true, _pair(_sign(node1Pk, d), _sign(node2Pk, d)));

        vm.warp(recordedAt + WINDOW + 1);
        vm.expectRevert(GapwatchRegistryV2.NothingToReclaim.selector);
        registry.reclaimBond(EVENT_HASH);

        assertEq(registry.pendingWithdrawals(challengerA), BOND * 2);
        assertEq(registry.pendingWithdrawals(recorder), 0);
    }

    /// Boundary: at exactly `recordedAt + challengeWindow`, challenge() is
    /// still open (strict `>`), and reclaimBond() is still closed (`<=`).
    /// Documents that there is no timestamp at which both are simultaneously
    /// permitted.
    function test_windowBoundary_exactExpiryInstant() public {
        _record(EVENT_HASH);
        uint256 recordedAt = block.timestamp;

        vm.warp(recordedAt + WINDOW);

        vm.expectRevert(GapwatchRegistryV2.ChallengeWindowNotExpired.selector);
        registry.reclaimBond(EVENT_HASH);

        vm.prank(challengerA);
        registry.challenge{value: BOND}(EVENT_HASH);
        assertEq(registry.getChallenge(EVENT_HASH).challenger, challengerA);
    }

    /// One second later, challenge() has closed.
    function test_windowBoundary_oneSecondAfterExpiry() public {
        _record(EVENT_HASH);
        uint256 recordedAt = block.timestamp;

        vm.warp(recordedAt + WINDOW + 1);

        vm.prank(challengerA);
        vm.expectRevert(GapwatchRegistryV2.ChallengeWindowExpired.selector);
        registry.challenge{value: BOND}(EVENT_HASH);

        registry.reclaimBond(EVENT_HASH);
        assertEq(registry.pendingWithdrawals(recorder), BOND);
    }

    // ------------------------------------------------------------------ //
    // Goal 3 -- retroactivity of the global challengeWindow
    // ------------------------------------------------------------------ //

    /// Event recorded under a 7-day window; 5 days later the owner shortens
    /// the window to 1 day. Does the already-recorded event's reclaim
    /// eligibility move?
    function test_challengeWindow_shortenedAfterRecord_isRetroactive() public {
        _record(EVENT_HASH);
        uint256 recordedAt = block.timestamp;

        // Day 5 of the original 7-day window: not reclaimable yet.
        vm.warp(recordedAt + 5 days);
        vm.expectRevert(GapwatchRegistryV2.ChallengeWindowNotExpired.selector);
        registry.reclaimBond(EVENT_HASH);

        // Owner shortens the global window to 1 day.
        registry.setChallengeWindow(1 days);

        // The already-recorded event is now immediately reclaimable, 2 days
        // earlier than the window in force when it was recorded.
        registry.reclaimBond(EVENT_HASH);
        assertEq(registry.pendingWithdrawals(recorder), BOND);
    }

    /// Same shortening also retroactively closes the challenge path for an
    /// already-recorded event.
    function test_challengeWindow_shortened_closesChallengeEarly() public {
        _record(EVENT_HASH);
        uint256 recordedAt = block.timestamp;

        vm.warp(recordedAt + 5 days);

        // Before the change, a challenge at day 5 is still accepted...
        uint256 snap = vm.snapshotState();
        vm.prank(challengerA);
        registry.challenge{value: BOND}(EVENT_HASH);
        assertEq(registry.getChallenge(EVENT_HASH).challenger, challengerA);
        vm.revertToState(snap);

        // ...after shortening to 1 day, the same challenge at day 5 reverts.
        registry.setChallengeWindow(1 days);
        vm.prank(challengerA);
        vm.expectRevert(GapwatchRegistryV2.ChallengeWindowExpired.selector);
        registry.challenge{value: BOND}(EVENT_HASH);
    }

    /// Lengthening the window retroactively re-locks a bond that had already
    /// become reclaimable, and re-opens challenges against it.
    function test_challengeWindow_lengthenedAfterRecord_relocksBond() public {
        _record(EVENT_HASH);
        uint256 recordedAt = block.timestamp;

        vm.warp(recordedAt + WINDOW + 1);

        // Reclaimable at this point...
        uint256 snap = vm.snapshotState();
        registry.reclaimBond(EVENT_HASH);
        assertEq(registry.pendingWithdrawals(recorder), BOND);
        vm.revertToState(snap);

        // ...but after the owner lengthens the window, it is locked again.
        registry.setChallengeWindow(365 days);
        vm.expectRevert(GapwatchRegistryV2.ChallengeWindowNotExpired.selector);
        registry.reclaimBond(EVENT_HASH);

        // And the challenge path re-opens for this historical record.
        vm.prank(challengerA);
        registry.challenge{value: BOND}(EVENT_HASH);
        assertEq(registry.getChallenge(EVENT_HASH).challenger, challengerA);
    }

    /// Scope check: does the retroactive effect reach records whose bond has
    /// already been settled (reclaimed or resolved)?
    function test_challengeWindow_change_doesNotAffectSettledRecords() public {
        bytes32 settled = keccak256("audit-event-settled");
        _record(settled);
        uint256 recordedAt = block.timestamp;

        vm.warp(recordedAt + WINDOW + 1);
        registry.reclaimBond(settled);
        assertEq(registry.pendingWithdrawals(recorder), BOND);

        // Lengthening the window cannot un-settle it: bond is already zero,
        // so both paths revert on NothingToReclaim before the window test.
        registry.setChallengeWindow(365 days);

        vm.expectRevert(GapwatchRegistryV2.NothingToReclaim.selector);
        registry.reclaimBond(settled);

        vm.prank(challengerA);
        vm.expectRevert(GapwatchRegistryV2.NothingToReclaim.selector);
        registry.challenge{value: BOND}(settled);
    }
}
