// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GapwatchRegistryV2} from "../src/GapwatchRegistryV2.sol";
import {ConsensusVerifierMock} from "../src/ConsensusVerifierMock.sol";
import {MockLendingPool} from "../src/MockLendingPool.sol";

/// @dev Re-enters `withdraw()` from inside its own receive callback, and also
///      acts as the recorder so it can accrue a real pendingWithdrawals
///      balance to withdraw. V2 counterpart of the V1-only ReentrantWithdrawer
///      in GapwatchRegistry.t.sol (which is left untouched).
contract ReentrantWithdrawerV2 {
    GapwatchRegistryV2 public registry;
    uint256 public reentryAttempts;
    bool public reentryReverted;

    constructor(GapwatchRegistryV2 _registry) {
        registry = _registry;
    }

    function record(
        bytes32 eventHash,
        address token,
        bytes[] calldata signatures,
        uint256 bond
    ) external {
        registry.recordVerification{value: bond}(eventHash, token, 1e18, 2e18, false, bytes32(0), signatures);
    }

    function attack() external {
        registry.withdraw();
    }

    receive() external payable {
        if (reentryAttempts == 0) {
            reentryAttempts++;
            try registry.withdraw() {
                // If this path is reached, the guard failed to stop reentry.
            } catch {
                reentryReverted = true;
            }
        }
    }
}

contract GapwatchRegistryV2Audit2Test is Test {
    GapwatchRegistryV2 registry;
    ConsensusVerifierMock verifier;
    MockLendingPool pool;

    uint256 node1Pk;
    uint256 node2Pk;
    uint256 node3Pk;
    address node1;
    address node2;
    address node3;

    address recorder = makeAddr("r2_recorder");
    address challenger = makeAddr("r2_challenger");
    address stranger = makeAddr("r2_stranger");
    address token = makeAddr("r2_token");
    address user = makeAddr("r2_user");

    bytes32 constant EVENT_HASH = keccak256("r2-event-1");
    uint256 constant BOND = 0.001 ether;
    uint256 constant WINDOW = 7 days;

    function setUp() public {
        (node1, node1Pk) = makeAddrAndKey("r2node1");
        (node2, node2Pk) = makeAddrAndKey("r2node2");
        (node3, node3Pk) = makeAddrAndKey("r2node3");

        verifier = new ConsensusVerifierMock();
        registry = new GapwatchRegistryV2([node1, node2, node3], address(verifier), BOND, WINDOW);
        pool = new MockLendingPool(address(registry));

        vm.deal(recorder, 100 ether);
        vm.deal(challenger, 100 ether);
        vm.deal(stranger, 100 ether);
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

    function _recordDigest(bytes32 eventHash, address tok, uint256 chainId) internal view returns (bytes32) {
        return keccak256(
            abi.encode(eventHash, tok, uint256(1e18), uint256(2e18), false, bytes32(0), address(registry), chainId)
        );
    }

    function _recordSigs(bytes32 eventHash, address tok) internal view returns (bytes[] memory) {
        bytes32 d = _recordDigest(eventHash, tok, block.chainid);
        return _pair(_sign(node1Pk, d), _sign(node2Pk, d));
    }

    function _record(bytes32 eventHash, address tok) internal {
        vm.prank(recorder);
        registry.recordVerification{value: BOND}(eventHash, tok, 1e18, 2e18, false, bytes32(0), _recordSigs(eventHash, tok));
    }

    function _discrepancySigs(bytes32 eventHash, string memory reason) internal view returns (bytes[] memory) {
        bytes32 d = keccak256(
            abi.encode(registry.REPORT_DISCREPANCY_TAG(), eventHash, reason, address(registry), block.chainid)
        );
        return _pair(_sign(node1Pk, d), _sign(node2Pk, d));
    }

    function _resolveSigs(bytes32 eventHash, bool outcome) internal view returns (bytes[] memory) {
        bytes32 d = keccak256(abi.encode(eventHash, outcome, address(registry), block.chainid));
        return _pair(_sign(node1Pk, d), _sign(node2Pk, d));
    }

    // ================================================================== //
    // Item 1 -- V2 x MockLendingPool integration
    // ================================================================== //

    /// Full downstream flow against V2 (previously only ever exercised
    /// against V1): record -> pause refused -> consensus flags discrepancy ->
    /// pause accepted -> liquidation check flips.
    function test_integration_v2_fullDiscrepancyFlow() public {
        vm.prank(user);
        pool.openPosition(token, 1 ether);
        assertTrue(pool.checkLiquidatable(user), "position should start liquidatable");

        _record(EVENT_HASH, token);

        // No discrepancy yet -> pause must be refused.
        vm.expectRevert(abi.encodeWithSelector(MockLendingPool.NoDiscrepancyFlagged.selector, EVENT_HASH));
        pool.pauseLiquidation(token);
        assertTrue(pool.checkLiquidatable(user));

        // 2-of-3 consensus flags the discrepancy on V2.
        registry.reportDiscrepancy(EVENT_HASH, "reference model mismatch", _discrepancySigs(EVENT_HASH, "reference model mismatch"));

        // Now the downstream pool accepts the pause, and liquidation flips off.
        pool.pauseLiquidation(token);
        assertTrue(pool.tokenLiquidationPaused(token));
        assertFalse(pool.checkLiquidatable(user), "liquidation must be paused after discrepancy");
    }

    /// The pool's gate is the registry's data, not the caller's identity:
    /// an arbitrary stranger can trigger the pause once V2 has the flag.
    function test_integration_v2_pauseIsDataGatedNotCallerGated() public {
        _record(EVENT_HASH, token);
        registry.reportDiscrepancy(EVENT_HASH, "x", _discrepancySigs(EVENT_HASH, "x"));

        vm.prank(stranger);
        pool.pauseLiquidation(token);
        assertTrue(pool.tokenLiquidationPaused(token));
    }

    /// Token the registry has never recorded -> pool refuses outright.
    function test_integration_v2_unknownTokenRefused() public {
        address unknown = makeAddr("r2_unknown_token");
        vm.expectRevert(abi.encodeWithSelector(MockLendingPool.NoVerificationForToken.selector, unknown));
        pool.pauseLiquidation(unknown);
    }

    /// Behavioural detail of the V2 integration worth pinning down: the pool
    /// reads `latestVerificationForToken`, so once a NEWER event is recorded
    /// for the same token, a discrepancy flagged on the OLDER event no longer
    /// satisfies the pool -- the pause window effectively closes when the
    /// token gets a fresh record.
    function test_integration_v2_newerRecordSupersedesOlderDiscrepancy() public {
        bytes32 older = keccak256("r2-event-older");
        bytes32 newer = keccak256("r2-event-newer");

        _record(older, token);
        registry.reportDiscrepancy(older, "bad", _discrepancySigs(older, "bad"));
        assertTrue(registry.hasDiscrepancy(older));

        // A newer verification for the same token moves the pointer.
        _record(newer, token);
        assertEq(registry.latestVerificationForToken(token), newer);

        // The older discrepancy is still on record...
        assertTrue(registry.hasDiscrepancy(older));
        // ...but the pool now looks at `newer`, which has no discrepancy.
        vm.expectRevert(abi.encodeWithSelector(MockLendingPool.NoDiscrepancyFlagged.selector, newer));
        pool.pauseLiquidation(token);
        assertFalse(pool.tokenLiquidationPaused(token));
    }

    /// Once the pause flag is set in the pool, it is never cleared by
    /// anything happening in the registry afterwards (the pool has no unpause
    /// path at all).
    function test_integration_v2_pauseIsIrreversibleInPool() public {
        bytes32 older = keccak256("r2-event-older2");
        _record(older, token);
        registry.reportDiscrepancy(older, "bad", _discrepancySigs(older, "bad"));
        pool.pauseLiquidation(token);
        assertTrue(pool.tokenLiquidationPaused(token));

        // Newer clean record for the same token does not un-pause the pool.
        bytes32 newer = keccak256("r2-event-newer2");
        _record(newer, token);
        assertFalse(registry.hasDiscrepancy(newer));
        assertTrue(pool.tokenLiquidationPaused(token), "pool has no unpause path");

        vm.prank(user);
        pool.openPosition(token, 1 ether);
        assertFalse(pool.checkLiquidatable(user));
    }

    // ================================================================== //
    // Item 3 -- withdraw() reentrancy on V2
    // ================================================================== //

    function test_withdraw_reentrancyGuardBlocksReentry_v2() public {
        ReentrantWithdrawerV2 attacker = new ReentrantWithdrawerV2(registry);
        vm.deal(address(attacker), 10 ether);

        bytes32 evt = keccak256("r2-reentrancy");
        attacker.record(evt, token, _recordSigs(evt, token), BOND);

        // Window passes with no challenge; the attacker's bond is credited.
        vm.warp(block.timestamp + WINDOW + 1);
        registry.reclaimBond(evt);
        assertEq(registry.pendingWithdrawals(address(attacker)), BOND);

        uint256 registryBalanceBefore = address(registry).balance;

        attacker.attack();

        assertEq(attacker.reentryAttempts(), 1, "receive hook did not fire");
        assertTrue(attacker.reentryReverted(), "reentrant withdraw() was not blocked");
        // Paid exactly once.
        assertEq(registry.pendingWithdrawals(address(attacker)), 0);
        assertEq(address(registry).balance, registryBalanceBefore - BOND);
    }

    /// A second withdraw() with a zero balance is a no-op, not a revert, and
    /// does not pay anything out again.
    function test_withdraw_secondCallIsNoOp_v2() public {
        _record(EVENT_HASH, token);
        vm.warp(block.timestamp + WINDOW + 1);
        registry.reclaimBond(EVENT_HASH);

        uint256 before = recorder.balance;
        vm.prank(recorder);
        registry.withdraw();
        assertEq(recorder.balance, before + BOND);

        vm.prank(recorder);
        registry.withdraw(); // no revert, no second payout
        assertEq(recorder.balance, before + BOND);
    }

    // ================================================================== //
    // Item 4 -- duplicate entries in expectedSigners (verifier directly)
    // ================================================================== //

    /// Calls the verifier directly with a node set containing the SAME
    /// address twice, supplying only ONE signature from that address.
    /// If dedup were done by expectedSigners index position rather than by
    /// recovered address, a single signer could reach threshold 2.
    function test_verifier_duplicateExpectedSigners_singleSignerCannotReachTwo() public view {
        bytes32 digest = keccak256("dup-signer-test");
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(node1Pk, digest);

        (bool passed, uint256 validCount, address[] memory signers) =
            verifier.verifyConsensus(digest, sigs, [node1, node1, node2], 2);

        assertFalse(passed, "one signer must not reach threshold via a duplicated node slot");
        assertEq(validCount, 1);
        assertEq(signers.length, 1);
        assertEq(signers[0], node1);
    }

    /// Same node set, but the one signer's signature supplied TWICE -- the
    /// other way a naive implementation might double-count.
    function test_verifier_duplicateExpectedSigners_repeatedSignatureStillOneVote() public view {
        bytes32 digest = keccak256("dup-signer-test-2");
        bytes memory sig = _sign(node1Pk, digest);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = sig;
        sigs[1] = sig;

        (bool passed, uint256 validCount,) = verifier.verifyConsensus(digest, sigs, [node1, node1, node2], 2);

        assertFalse(passed);
        assertEq(validCount, 1);
    }

    /// Control: with the duplicated set, two DISTINCT valid signers still
    /// reach threshold normally.
    function test_verifier_duplicateExpectedSigners_twoDistinctStillPasses() public view {
        bytes32 digest = keccak256("dup-signer-test-3");
        bytes[] memory sigs = _pair(_sign(node1Pk, digest), _sign(node2Pk, digest));

        (bool passed, uint256 validCount,) = verifier.verifyConsensus(digest, sigs, [node1, node1, node2], 2);

        assertTrue(passed);
        assertEq(validCount, 2);
    }

    // ================================================================== //
    // Item 5 -- transferOwnership / renounceOwnership on V2
    // ================================================================== //

    function test_ownership_transferMovesConfigRights() public {
        address newOwner = makeAddr("r2_newOwner");
        registry.transferOwnership(newOwner);
        assertEq(registry.owner(), newOwner);

        // Old owner (this test contract) can no longer touch the knobs.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        registry.setRequiredBond(1 ether);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        registry.setChallengeWindow(1 days);

        // New owner can.
        vm.prank(newOwner);
        registry.setRequiredBond(2 ether);
        assertEq(registry.requiredBond(), 2 ether);

        vm.prank(newOwner);
        registry.setChallengeWindow(3 days);
        assertEq(registry.challengeWindow(), 3 days);
    }

    function test_ownership_renounceLocksConfigForever() public {
        registry.renounceOwnership();
        assertEq(registry.owner(), address(0));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        registry.setRequiredBond(1 ether);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        registry.setChallengeWindow(1 days);

        // Nobody else can either -- address(0) cannot be impersonated into a
        // successful call path that OZ would accept.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        registry.setRequiredBond(1 ether);
    }

    /// After renouncing, the three consensus-gated functions keep working --
    /// they never depended on owner in the first place.
    function test_ownership_renounceDoesNotBreakConsensusFunctions() public {
        registry.renounceOwnership();
        assertEq(registry.owner(), address(0));

        _record(EVENT_HASH, token);
        assertTrue(registry.isVerified(EVENT_HASH));

        registry.reportDiscrepancy(EVENT_HASH, "still works", _discrepancySigs(EVENT_HASH, "still works"));
        assertTrue(registry.hasDiscrepancy(EVENT_HASH));

        vm.prank(challenger);
        registry.challenge{value: BOND}(EVENT_HASH);
        registry.resolveChallenge(EVENT_HASH, true, _resolveSigs(EVENT_HASH, true));
        assertEq(registry.pendingWithdrawals(challenger), BOND * 2);

        vm.prank(challenger);
        registry.withdraw();
    }

    // ================================================================== //
    // Item 7 -- chainid replay
    // ================================================================== //

    /// Signatures produced under the deployment chain id must not authorise
    /// the same call once the chain id changes (fork / replay scenario).
    function test_chainIdReplay_signaturesFromOriginalChainFailOnFork() public {
        bytes[] memory sigs = _recordSigs(EVENT_HASH, token);

        uint256 forkChainId = block.chainid + 12345;
        vm.chainId(forkChainId);

        vm.prank(recorder);
        vm.expectRevert(abi.encodeWithSelector(GapwatchRegistryV2.ConsensusNotReached.selector, 0, 2));
        registry.recordVerification{value: BOND}(EVENT_HASH, token, 1e18, 2e18, false, bytes32(0), sigs);
        assertFalse(registry.isVerified(EVENT_HASH));
    }

    /// Reverse direction: signatures produced for a DIFFERENT chain id must
    /// not authorise the call on the real chain.
    function test_chainIdReplay_signaturesForOtherChainFailHere() public {
        uint256 fakeChainId = block.chainid + 999;
        bytes32 foreignDigest = _recordDigest(EVENT_HASH, token, fakeChainId);
        bytes[] memory sigs = _pair(_sign(node1Pk, foreignDigest), _sign(node2Pk, foreignDigest));

        vm.prank(recorder);
        vm.expectRevert(abi.encodeWithSelector(GapwatchRegistryV2.ConsensusNotReached.selector, 0, 2));
        registry.recordVerification{value: BOND}(EVENT_HASH, token, 1e18, 2e18, false, bytes32(0), sigs);
        assertFalse(registry.isVerified(EVENT_HASH));
    }

    /// The same binding protects resolveChallenge.
    function test_chainIdReplay_resolveChallengeAlsoBound() public {
        _record(EVENT_HASH, token);
        vm.prank(challenger);
        registry.challenge{value: BOND}(EVENT_HASH);

        bytes[] memory sigs = _resolveSigs(EVENT_HASH, true);
        vm.chainId(block.chainid + 7);

        vm.expectRevert(abi.encodeWithSelector(GapwatchRegistryV2.ConsensusNotReached.selector, 0, 2));
        registry.resolveChallenge(EVENT_HASH, true, sigs);
    }

    // ================================================================== //
    // Item 8 -- requiredBond retroactivity
    // ================================================================== //

    /// A record stores the ETH actually posted (`v.bond`), so a later change
    /// to the global `requiredBond` must not move the goalposts for that
    /// record's challenge/resolve/reclaim amounts.
    function test_requiredBond_changeIsNotRetroactiveForExistingRecords() public {
        registry.setRequiredBond(1 ether);

        bytes32 evt = keccak256("r2-bond-retro");
        vm.prank(recorder);
        registry.recordVerification{value: 1 ether}(evt, token, 1e18, 2e18, false, bytes32(0), _recordSigs(evt, token));
        assertEq(registry.getVerification(evt).bond, 1 ether);

        // Owner raises the global minimum fivefold AFTER the fact.
        registry.setRequiredBond(5 ether);
        assertEq(registry.requiredBond(), 5 ether);
        // The stored per-record bond is untouched.
        assertEq(registry.getVerification(evt).bond, 1 ether);

        // Challenging still only has to match the ORIGINAL stored bond,
        // not the new global minimum.
        vm.prank(challenger);
        registry.challenge{value: 1 ether}(evt);
        assertEq(registry.getChallenge(evt).amount, 1 ether);

        // Payout is computed from the stored amounts.
        registry.resolveChallenge(evt, true, _resolveSigs(evt, true));
        assertEq(registry.pendingWithdrawals(challenger), 2 ether);
    }

    /// Lowering requiredBond afterwards likewise does not shrink an existing
    /// record's bond or let a challenger underpay against it.
    function test_requiredBond_loweringDoesNotShrinkExistingBond() public {
        registry.setRequiredBond(1 ether);

        bytes32 evt = keccak256("r2-bond-retro-2");
        vm.prank(recorder);
        registry.recordVerification{value: 1 ether}(evt, token, 1e18, 2e18, false, bytes32(0), _recordSigs(evt, token));

        registry.setRequiredBond(0.0001 ether);

        // Challenger still has to match the record's own 1 ETH bond.
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(GapwatchRegistryV2.InsufficientBond.selector, 1 ether, 0.0001 ether));
        registry.challenge{value: 0.0001 ether}(evt);

        // Reclaim returns the full original bond.
        vm.warp(block.timestamp + WINDOW + 1);
        registry.reclaimBond(evt);
        assertEq(registry.pendingWithdrawals(recorder), 1 ether);
    }

    /// Overpaying above requiredBond is stored as-is, and that larger amount
    /// is what a challenger must match.
    function test_requiredBond_overpaymentBecomesTheBarForChallengers() public {
        bytes32 evt = keccak256("r2-bond-overpay");
        vm.prank(recorder);
        registry.recordVerification{value: 3 ether}(evt, token, 1e18, 2e18, false, bytes32(0), _recordSigs(evt, token));
        assertEq(registry.getVerification(evt).bond, 3 ether);

        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(GapwatchRegistryV2.InsufficientBond.selector, 3 ether, BOND));
        registry.challenge{value: BOND}(evt);

        vm.prank(challenger);
        registry.challenge{value: 3 ether}(evt);
        assertEq(registry.getChallenge(evt).amount, 3 ether);
    }
}
