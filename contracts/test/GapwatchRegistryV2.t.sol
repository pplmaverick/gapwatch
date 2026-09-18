// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {GapwatchRegistryV2} from "../src/GapwatchRegistryV2.sol";
import {ConsensusVerifierMock} from "../src/ConsensusVerifierMock.sol";

/// @notice Foundry cannot execute the production Tier 4 Stylus contract
///         (contracts-stylus/) -- forge test runs on the EVM via revm, not
///         WASM. `ConsensusVerifierMock` is a Solidity re-implementation of
///         the exact same `verifyConsensus` semantics (see its NatSpec), used
///         here as the `IConsensusVerifier` GapwatchRegistryV2 is deployed
///         against. Everything below tests GapwatchRegistryV2's own logic
///         (msgHash binding, threshold gating, revert-vs-skip handling of the
///         verifier's result) -- it is not a test of the Rust contract itself.
contract GapwatchRegistryV2Test is Test {
    address constant FILTER_PRECOMPILE = 0x0000000000000000000000000000000000000074;
    bytes4 constant IS_FILTERED_SELECTOR = 0x85c733a4;
    bytes4 constant UI_MULTIPLIER_SELECTOR = 0xa60bf13d;

    GapwatchRegistryV2 registry;
    ConsensusVerifierMock verifier;

    uint256 node1Pk;
    uint256 node2Pk;
    uint256 node3Pk;
    address node1;
    address node2;
    address node3;

    address stranger = makeAddr("stranger");
    address token = makeAddr("token");
    address challenger = makeAddr("challenger");
    address recorder = makeAddr("recorder");

    bytes32 constant EVENT_HASH = keccak256("nvda-event-1");
    bytes32 constant EVENT_HASH_2 = keccak256("nvda-event-2");

    uint256 constant BOND = 0.001 ether;
    uint256 constant WINDOW = 1 days;

    // secp256k1 order, for constructing an out-of-range (high-s) signature.
    uint256 constant SECP256K1N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    function setUp() public {
        // Ephemeral, test-only signer keys derived deterministically from a
        // label (forge-std's makeAddrAndKey) -- intentionally NOT the same
        // addresses as the real node1/node2/node3 keystores generated for
        // eventual testnet/demo use (~/gapwatch/.keystores/, gitignored).
        // Real node private keys must never be hardcoded into a versioned
        // test file; that would let anyone who can read this repo forge
        // consensus signatures for the real deployment.
        (node1, node1Pk) = makeAddrAndKey("node1");
        (node2, node2Pk) = makeAddrAndKey("node2");
        (node3, node3Pk) = makeAddrAndKey("node3");

        verifier = new ConsensusVerifierMock();
        registry = new GapwatchRegistryV2([node1, node2, node3], address(verifier), BOND, WINDOW);

        vm.deal(recorder, 10 ether);
        vm.deal(stranger, 10 ether);
        vm.deal(challenger, 10 ether);
    }

    // -------------------------------------------------------------------- //
    // helpers
    // -------------------------------------------------------------------- //

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev `claimedFiltered=false`/`claimedMultiplier=1e18` throughout this
    ///      file's happy-path helpers -- matches `_record`'s mocked "actual"
    ///      values below, so every existing call site's intended behavior
    ///      (unfiltered, 1e18 multiplier) is preserved after the filter-check
    ///      + multiplier cross-validation upgrade, not changed.
    function _recordMsgHash(bytes32 eventHash, address registryAddr) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                eventHash, token, uint256(1e18), uint256(1e18), false, uint256(1e18), bytes32(0), registryAddr, block.chainid
            )
        );
    }

    /// @dev Stubs the two staticcalls `recordVerification` now makes, so
    ///      `token` (a plain `makeAddr()` address with no code) and an
    ///      arbitrary `eventHash` behave as "not filtered, uiMultiplier() ==
    ///      1e18" -- the same values every existing test in this file was
    ///      already implicitly assuming before the cross-validation upgrade.
    function _mockActualState(bytes32 eventHash) internal {
        vm.mockCall(
            FILTER_PRECOMPILE, abi.encodeWithSelector(IS_FILTERED_SELECTOR, eventHash), abi.encode(false)
        );
        vm.mockCall(token, abi.encodeWithSelector(UI_MULTIPLIER_SELECTOR), abi.encode(uint256(1e18)));
    }

    function _challengeMsgHash(bytes32 eventHash, bool outcome, address registryAddr) internal view returns (bytes32) {
        return keccak256(abi.encode(eventHash, outcome, registryAddr, block.chainid));
    }

    function _discrepancyMsgHash(bytes32 eventHash, string memory reason, address registryAddr)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(registry.REPORT_DISCREPANCY_TAG(), eventHash, reason, registryAddr, block.chainid)
        );
    }

    function _sigs2(bytes memory a, bytes memory b) internal pure returns (bytes[] memory arr) {
        arr = new bytes[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _sigs1(bytes memory a) internal pure returns (bytes[] memory arr) {
        arr = new bytes[](1);
        arr[0] = a;
    }

    function _record(bytes32 eventHash, bytes[] memory signatures) internal {
        _mockActualState(eventHash);
        vm.prank(recorder);
        registry.recordVerification{value: BOND}(eventHash, token, false, 1e18, 1e18, 1e18, bytes32(0), signatures);
    }

    /// @dev Signs the canonical recordVerification digest for `eventHash`
    ///      against `registry` with node1 and node2 -- the "happy path" 2-of-3 set.
    function _node1and2Sigs(bytes32 eventHash, address registryAddr) internal view returns (bytes[] memory) {
        bytes32 digest = _recordMsgHash(eventHash, registryAddr);
        return _sigs2(_sign(node1Pk, digest), _sign(node2Pk, digest));
    }

    // -------------------------------------------------------------------- //
    // recordVerification: consensus gating
    // -------------------------------------------------------------------- //

    /// 2-of-3 signatures (node1 + node2) -> succeeds.
    function test_recordVerification_twoOfThree_succeeds() public {
        _record(EVENT_HASH, _node1and2Sigs(EVENT_HASH, address(registry)));
        assertTrue(registry.isVerified(EVENT_HASH));
    }

    /// Only 1 valid signature -> reverts, does not write.
    function test_recordVerification_oneSignature_reverts() public {
        bytes32 digest = _recordMsgHash(EVENT_HASH, address(registry));
        bytes[] memory sigs = _sigs1(_sign(node1Pk, digest));

        vm.expectRevert(abi.encodeWithSelector(GapwatchRegistryV2.ConsensusNotReached.selector, 1, 2));
        _record(EVENT_HASH, sigs);
        assertFalse(registry.isVerified(EVENT_HASH));
    }

    /// Same node signing twice counts as ONE valid vote, not two -- cannot
    /// reach the 2-of-3 threshold this way.
    function test_recordVerification_sameNodeTwice_countsOnce_reverts() public {
        bytes32 digest = _recordMsgHash(EVENT_HASH, address(registry));
        bytes memory sig = _sign(node1Pk, digest);
        bytes[] memory sigs = _sigs2(sig, sig);

        vm.expectRevert(abi.encodeWithSelector(GapwatchRegistryV2.ConsensusNotReached.selector, 1, 2));
        _record(EVENT_HASH, sigs);
        assertFalse(registry.isVerified(EVENT_HASH));
    }

    /// A signature from a non-node address is not counted as a valid vote
    /// (and does not itself cause a revert -- it's silently excluded); paired
    /// with only one real node signature this still falls short of 2-of-3.
    function test_recordVerification_nonNodeSigner_notCounted() public {
        (, uint256 outsiderPk) = makeAddrAndKey("outsider");
        bytes32 digest = _recordMsgHash(EVENT_HASH, address(registry));
        bytes[] memory sigs = _sigs2(_sign(node1Pk, digest), _sign(outsiderPk, digest));

        vm.expectRevert(abi.encodeWithSelector(GapwatchRegistryV2.ConsensusNotReached.selector, 1, 2));
        _record(EVENT_HASH, sigs);
        assertFalse(registry.isVerified(EVENT_HASH));
    }

    /// Signature replay across events: signatures over EVENT_HASH's digest
    /// must not authorize EVENT_HASH_2, because eventHash is baked into the
    /// signed digest.
    function test_recordVerification_replayAcrossEvents_reverts() public {
        bytes[] memory sigsForEvent1 = _node1and2Sigs(EVENT_HASH, address(registry));

        // Using EVENT_HASH's signatures to record EVENT_HASH_2's payload must fail:
        // the digest recomputed inside recordVerification for EVENT_HASH_2 does not
        // match what was actually signed, so ecrecover yields the wrong (or a
        // random) address and consensus is not reached.
        _mockActualState(EVENT_HASH_2);
        vm.prank(recorder);
        vm.expectRevert(); // ConsensusNotReached, with an unpredictable validCount
        registry.recordVerification{value: BOND}(EVENT_HASH_2, token, false, 1e18, 1e18, 1e18, bytes32(0), sigsForEvent1);
        assertFalse(registry.isVerified(EVENT_HASH_2));
    }

    /// Signature replay across contracts: signatures over registry A's digest
    /// must not authorize the identical call on registry B, because
    /// address(this) is baked into the signed digest.
    function test_recordVerification_replayAcrossContracts_reverts() public {
        GapwatchRegistryV2 registryB = new GapwatchRegistryV2([node1, node2, node3], address(verifier), BOND, WINDOW);

        bytes[] memory sigsForRegistry = _node1and2Sigs(EVENT_HASH, address(registry));

        _mockActualState(EVENT_HASH);
        vm.deal(recorder, 10 ether);
        vm.prank(recorder);
        vm.expectRevert(abi.encodeWithSelector(GapwatchRegistryV2.ConsensusNotReached.selector, 0, 2));
        registryB.recordVerification{value: BOND}(EVENT_HASH, token, false, 1e18, 1e18, 1e18, bytes32(0), sigsForRegistry);
        assertFalse(registryB.isVerified(EVENT_HASH));
    }

    /// Threshold boundary: exactly 2 valid signers passes.
    function test_recordVerification_thresholdBoundary_exactlyTwo_passes() public {
        bytes32 digest = _recordMsgHash(EVENT_HASH, address(registry));
        bytes[] memory sigs = _sigs2(_sign(node2Pk, digest), _sign(node3Pk, digest));
        _record(EVENT_HASH, sigs);
        assertTrue(registry.isVerified(EVENT_HASH));
    }

    /// Threshold boundary: 1 (threshold - 1) valid signer always fails.
    function test_recordVerification_thresholdBoundary_oneLessThanTwo_reverts() public {
        bytes32 digest = _recordMsgHash(EVENT_HASH, address(registry));
        bytes[] memory sigs = _sigs1(_sign(node3Pk, digest));
        vm.expectRevert(abi.encodeWithSelector(GapwatchRegistryV2.ConsensusNotReached.selector, 1, 2));
        _record(EVENT_HASH, sigs);
        assertFalse(registry.isVerified(EVENT_HASH));
    }

    /// The account posting the bond need not be one of the 3 nodes.
    function test_recordVerification_bondPoster_neverNeedsToBeANode() public {
        assertFalse(recorder == node1 || recorder == node2 || recorder == node3);
        _record(EVENT_HASH, _node1and2Sigs(EVENT_HASH, address(registry)));
        GapwatchRegistryV2.Verification memory v = registry.getVerification(EVENT_HASH);
        assertEq(v.recordedBy, recorder);
    }

    // -------------------------------------------------------------------- //
    // resolveChallenge: consensus gating
    // -------------------------------------------------------------------- //

    function _setUpActiveChallenge() internal {
        _record(EVENT_HASH, _node1and2Sigs(EVENT_HASH, address(registry)));
        vm.prank(challenger);
        registry.challenge{value: BOND}(EVENT_HASH);
    }

    function test_resolveChallenge_twoOfThree_passes() public {
        _setUpActiveChallenge();
        bytes32 digest = _challengeMsgHash(EVENT_HASH, true, address(registry));
        bytes[] memory sigs = _sigs2(_sign(node1Pk, digest), _sign(node3Pk, digest));

        registry.resolveChallenge(EVENT_HASH, true, sigs);

        GapwatchRegistryV2.Challenge memory c = registry.getChallenge(EVENT_HASH);
        assertTrue(c.resolved);
        assertEq(registry.pendingWithdrawals(challenger), BOND * 2);
    }

    function test_resolveChallenge_oneSignature_reverts() public {
        _setUpActiveChallenge();
        bytes32 digest = _challengeMsgHash(EVENT_HASH, true, address(registry));
        bytes[] memory sigs = _sigs1(_sign(node1Pk, digest));

        vm.expectRevert(abi.encodeWithSelector(GapwatchRegistryV2.ConsensusNotReached.selector, 1, 2));
        registry.resolveChallenge(EVENT_HASH, true, sigs);

        GapwatchRegistryV2.Challenge memory c = registry.getChallenge(EVENT_HASH);
        assertFalse(c.resolved);
    }

    function test_resolveChallenge_sameNodeTwice_countsOnce_reverts() public {
        _setUpActiveChallenge();
        bytes32 digest = _challengeMsgHash(EVENT_HASH, false, address(registry));
        bytes memory sig = _sign(node2Pk, digest);
        bytes[] memory sigs = _sigs2(sig, sig);

        vm.expectRevert(abi.encodeWithSelector(GapwatchRegistryV2.ConsensusNotReached.selector, 1, 2));
        registry.resolveChallenge(EVENT_HASH, false, sigs);
    }

    /// A signature set signed for `challengerWins = true` must not authorize
    /// resolving with `challengerWins = false` -- the outcome bool is baked
    /// into the digest.
    function test_resolveChallenge_wrongOutcomeSignature_reverts() public {
        _setUpActiveChallenge();
        bytes32 digestForTrue = _challengeMsgHash(EVENT_HASH, true, address(registry));
        bytes[] memory sigs = _sigs2(_sign(node1Pk, digestForTrue), _sign(node2Pk, digestForTrue));

        vm.expectRevert(abi.encodeWithSelector(GapwatchRegistryV2.ConsensusNotReached.selector, 0, 2));
        registry.resolveChallenge(EVENT_HASH, false, sigs);
    }

    // -------------------------------------------------------------------- //
    // reportDiscrepancy: consensus gating
    // -------------------------------------------------------------------- //

    string constant REASON = "reference model mismatch";

    function test_reportDiscrepancy_twoOfThree_succeeds() public {
        _record(EVENT_HASH, _node1and2Sigs(EVENT_HASH, address(registry)));

        bytes32 digest = _discrepancyMsgHash(EVENT_HASH, REASON, address(registry));
        bytes[] memory sigs = _sigs2(_sign(node1Pk, digest), _sign(node3Pk, digest));

        registry.reportDiscrepancy(EVENT_HASH, REASON, sigs);
        assertTrue(registry.hasDiscrepancy(EVENT_HASH));
    }

    function test_reportDiscrepancy_oneSignature_reverts() public {
        _record(EVENT_HASH, _node1and2Sigs(EVENT_HASH, address(registry)));

        bytes32 digest = _discrepancyMsgHash(EVENT_HASH, REASON, address(registry));
        bytes[] memory sigs = _sigs1(_sign(node1Pk, digest));

        vm.expectRevert(abi.encodeWithSelector(GapwatchRegistryV2.ConsensusNotReached.selector, 1, 2));
        registry.reportDiscrepancy(EVENT_HASH, REASON, sigs);
        assertFalse(registry.hasDiscrepancy(EVENT_HASH));
    }

    function test_reportDiscrepancy_sameNodeTwice_countsOnce_reverts() public {
        _record(EVENT_HASH, _node1and2Sigs(EVENT_HASH, address(registry)));

        bytes32 digest = _discrepancyMsgHash(EVENT_HASH, REASON, address(registry));
        bytes memory sig = _sign(node2Pk, digest);
        bytes[] memory sigs = _sigs2(sig, sig);

        vm.expectRevert(abi.encodeWithSelector(GapwatchRegistryV2.ConsensusNotReached.selector, 1, 2));
        registry.reportDiscrepancy(EVENT_HASH, REASON, sigs);
        assertFalse(registry.hasDiscrepancy(EVENT_HASH));
    }

    /// The whole point of `REPORT_DISCREPANCY_TAG`: a legitimate 2-of-3
    /// signature set produced for `recordVerification` (or `resolveChallenge`)
    /// must NOT authorize `reportDiscrepancy`, even though both take an
    /// `eventHash`-shaped first argument. Without the domain tag, an attacker
    /// who intercepts a valid recordVerification signature set could replay it
    /// here; with it, the digest recomputed inside reportDiscrepancy never
    /// matches what was actually signed, so consensus is not reached.
    function test_reportDiscrepancy_crossFunctionReplay_reverts() public {
        bytes[] memory recordSigs = _node1and2Sigs(EVENT_HASH, address(registry));
        _record(EVENT_HASH, recordSigs);

        vm.expectRevert(abi.encodeWithSelector(GapwatchRegistryV2.ConsensusNotReached.selector, 0, 2));
        registry.reportDiscrepancy(EVENT_HASH, REASON, recordSigs);
        assertFalse(registry.hasDiscrepancy(EVENT_HASH));

        // Same check against a resolveChallenge signature set.
        vm.prank(challenger);
        registry.challenge{value: BOND}(EVENT_HASH);
        bytes32 challengeDigest = _challengeMsgHash(EVENT_HASH, true, address(registry));
        bytes[] memory resolveSigs = _sigs2(_sign(node1Pk, challengeDigest), _sign(node2Pk, challengeDigest));

        vm.expectRevert(abi.encodeWithSelector(GapwatchRegistryV2.ConsensusNotReached.selector, 0, 2));
        registry.reportDiscrepancy(EVENT_HASH, REASON, resolveSigs);
        assertFalse(registry.hasDiscrepancy(EVENT_HASH));
    }

    // -------------------------------------------------------------------- //
    // signature format checks (ConsensusVerifierMock -- revert, not skip)
    // -------------------------------------------------------------------- //

    function test_recordVerification_malformedSignatureLength_reverts() public {
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(node1Pk, _recordMsgHash(EVENT_HASH, address(registry)));
        sigs[1] = hex"deadbeef"; // 4 bytes, not 65 -- a format error, must revert

        vm.expectRevert(); // ConsensusVerifierMock.InvalidSignatureLength(1, 4)
        _record(EVENT_HASH, sigs);
    }

    function test_recordVerification_malleableHighS_reverts() public {
        bytes32 digest = _recordMsgHash(EVENT_HASH, address(registry));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(node1Pk, digest);

        // Flip to the malleable high-s counterpart of a valid low-s signature
        // and the complementary v, exactly as an attacker resubmitting a
        // mutated-but-still-"valid" signature would.
        bytes32 highS = bytes32(SECP256K1N - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;
        bytes memory malleableSig = abi.encodePacked(r, highS, flippedV);

        bytes[] memory sigs = _sigs2(malleableSig, _sign(node2Pk, digest));
        vm.expectRevert(); // ConsensusVerifierMock.InvalidSignatureS(0)
        _record(EVENT_HASH, sigs);
    }
}
