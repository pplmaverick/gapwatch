//! ConsensusVerifier -- Tier 3+4 M-of-N consensus verifier (Stylus / Rust).
//!
//! Solidity-equivalent interface (see `contracts/src/IConsensusVerifier.sol`,
//! which this contract implements from the caller's point of view):
//!
//! ```solidity
//! interface IConsensusVerifier {
//!     function verifyConsensus(
//!         bytes32 msgHash,
//!         bytes[] calldata signatures,
//!         address[3] calldata expectedSigners,
//!         uint256 threshold
//!     ) external view returns (bool passed, uint256 validCount, address[] memory signers);
//! }
//! ```
//!
//! Design notes:
//! - There is no host-accelerated `ecrecover` in stylus-sdk 0.10.9 (only
//!   `crypto::keccak` is accelerated -- see `stylus_sdk::crypto`). Signature
//!   recovery goes through the standard ECRECOVER precompile at `0x01`, called
//!   via `RawCall::new_static`, exactly as a Solidity contract's `ecrecover()`
//!   would resolve under the hood. This keeps the two implementations
//!   (this one, and `contracts/src/ConsensusVerifierMock.sol` used for Foundry
//!   testing) doing the *same* cryptographic operation, not two different ones.
//! - Malleability guard: `s` must be in the lower half of the secp256k1 curve
//!   order, same constant OpenZeppelin's `ECDSA.sol` uses. A high-`s`
//!   signature is a format error and reverts -- it is not silently
//!   renormalized into something the signer never actually signed.
//! - A signature that recovers cleanly but to an address outside
//!   `expected_signers` is *not* a format error: it is silently excluded from
//!   the vote count, and does not revert the call.
//! - Duplicate valid signers (the same address recovered from two different
//!   signature entries) count once.
//!
//! Not audited. Test-only Rust unit tests (`cargo test`) mock the ECRECOVER
//! precompile's response via `TestVM::mock_static_call` -- they verify this
//! contract's own dedup/threshold/format-check logic, not the correctness of
//! the ECRECOVER precompile itself (that runs on-chain, not in this test
//! harness). See `docs/tier4-stylus-verification.md` for the Tier 4
//! feasibility deployment this crate's scaffold came from.

#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
extern crate alloc;

use alloc::vec::Vec;
use stylus_sdk::{
    alloy_primitives::{Address, FixedBytes, U256},
    abi::Bytes,
    call::RawCall,
    prelude::*,
    stylus_core::host::Host,
};

/// The ECRECOVER precompile, at address `0x0000000000000000000000000000000000000001`.
const ECRECOVER: Address = Address::new([
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
]);

/// secp256k1 curve order `n`, halved (rounded down). Same constant
/// OpenZeppelin's `ECDSA.sol` uses to reject malleable (high-`s`) signatures:
/// `0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0`.
const SECP256K1N_HALF: [u8; 32] = [
    0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x5D, 0x57, 0x6E,
    0x73, 0x57, 0xA4, 0x50, 0x1D, 0xDF, 0xE9, 0x2F, 0x46, 0x68, 0x1B, 0x20, 0xA0,
];

/// Big-endian, fixed-length byte comparison is equivalent to numeric
/// comparison for unsigned integers -- avoids pulling in a full U256 compare
/// just for this one check.
fn s_is_low(s: &[u8]) -> bool {
    s <= SECP256K1N_HALF.as_slice()
}

/// Format-checks and recovers one signature via the ECRECOVER precompile.
///
/// Returns `Err` on a *format* error (wrong length, malleable `s`, invalid
/// `v`) -- these must revert the whole call, not be silently skipped. Returns
/// `Ok(Address::ZERO)` when the precompile itself fails to recover a signer
/// (e.g. an `r`/`s` pair with no valid point) -- that is not a format error,
/// and the caller treats it the same as "not an expected signer": skipped,
/// not reverted.
fn recover_checked<H: Host + ?Sized>(vm: &H, msg_hash: FixedBytes<32>, sig: &[u8]) -> Result<Address, Vec<u8>> {
    if sig.len() != 65 {
        return Err(b"InvalidSignatureLength".to_vec());
    }
    let r = &sig[0..32];
    let s = &sig[32..64];
    let mut v = sig[64];

    if !s_is_low(s) {
        return Err(b"InvalidSignatureS".to_vec());
    }
    if v < 27 {
        v += 27;
    }
    if v != 27 && v != 28 {
        return Err(b"InvalidSignatureV".to_vec());
    }

    // ECRECOVER precompile input: hash(32) || v(32, right-aligned) || r(32) || s(32).
    let mut input = [0u8; 128];
    input[0..32].copy_from_slice(msg_hash.as_slice());
    input[63] = v;
    input[64..96].copy_from_slice(r);
    input[96..128].copy_from_slice(s);

    let output = unsafe {
        RawCall::new_static(vm)
            .call(ECRECOVER, &input)
            .map_err(|_| b"EcrecoverCallReverted".to_vec())?
    };

    // Precompile returns 32 bytes (address right-aligned) on success, or an
    // empty/short result when it cannot recover a signer -- not a revert.
    if output.len() != 32 {
        return Ok(Address::ZERO);
    }
    Ok(Address::from_slice(&output[12..32]))
}

sol_storage! {
    #[entrypoint]
    pub struct ConsensusVerifier {}
}

#[public]
impl ConsensusVerifier {
    /// See the module-level doc for the full contract and the equivalent
    /// Solidity interface this implements.
    pub fn verify_consensus(
        &self,
        msg_hash: FixedBytes<32>,
        signatures: Vec<Bytes>,
        expected_signers: [Address; 3],
        threshold: U256,
    ) -> Result<(bool, U256, Vec<Address>), Vec<u8>> {
        let mut seen: Vec<Address> = Vec::new();

        for sig in signatures.iter() {
            let recovered = recover_checked(self.vm(), msg_hash, sig.as_ref())?;

            if recovered == Address::ZERO {
                continue;
            }
            if !expected_signers.contains(&recovered) {
                continue;
            }
            if !seen.contains(&recovered) {
                seen.push(recovered);
            }
        }

        let valid_count = U256::from(seen.len() as u64);
        let passed = valid_count >= threshold;
        Ok((passed, valid_count, seen))
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use stylus_sdk::testing::*;

    const NODE_A: Address = Address::new([0xAA; 20]);
    const NODE_B: Address = Address::new([0xBB; 20]);
    const NODE_C: Address = Address::new([0xCC; 20]);
    const OUTSIDER: Address = Address::new([0xDD; 20]);

    /// Builds a syntactically valid (correct length, low-s, v in {27,28})
    /// signature. The actual r/s bytes are arbitrary fixed test bytes -- what
    /// they recover to is controlled entirely by `mock_static_call` below,
    /// not by real secp256k1 math. This is intentional: `TestVM` does not run
    /// a real EVM, so there is no real ECRECOVER precompile to call in this
    /// harness. These tests verify ConsensusVerifier's own dedup/threshold/
    /// format-check logic against a *mocked* precompile response, not the
    /// cryptographic correctness of recovery itself.
    ///
    /// KNOWN `stylus-test` 0.10.9 LIMITATION (verified at the source level,
    /// not assumed): `TestVM::mock_static_call(to, data, result)` keys its
    /// lookup HashMap correctly by `(to, data)`, and `perform_mocked_static_call`
    /// does find the right entry per call -- but `RawCall::call`'s actual
    /// return bytes come from a *second*, separate step,
    /// `host.read_return_data(offset, size)`, which reads a single global
    /// `state.return_data` buffer that `mock_static_call` overwrites on
    /// *registration*, not on lookup (see `stylus-test-0.10.9/src/vm.rs`,
    /// `mock_static_call` and `read_return_data`). So when a single
    /// `verify_consensus` call makes two `RawCall`s to the same target
    /// (ECRECOVER) with two *different* mocked responses registered earlier,
    /// both calls actually read back whichever response was registered
    /// *last* -- not the one matching their own calldata. A test that mocks
    /// two signatures to two *different* recovered addresses and expects both
    /// to come back correctly within one `verify_consensus` invocation will
    /// silently get the wrong address for the earlier-registered one.
    ///
    /// Tests below that only ever need ONE distinct mocked address in play
    /// (even across multiple signature slots) are unaffected and reliable.
    /// Tests that genuinely need two different valid signers recovered within
    /// one call are marked `#[ignore]` with this same note, rather than left
    /// silently green on a false premise. That exact scenario (real,
    /// non-mocked `ecrecover` recovering two different signers to reach
    /// 2-of-3) is verified for real by `ConsensusVerifierMockGasTest` /
    /// `GapwatchRegistryV2Test` in `contracts/test/` (Solidity, same
    /// semantics, real EVM `ecrecover` -- no such mocking limitation there).
    /// Final confidence for this Rust contract's own multi-signer path still
    /// needs an on-chain or local Stylus dev-node call, which was out of
    /// scope for this round (no deployment was performed here).
    fn make_sig(tag: u8) -> Vec<u8> {
        let mut sig = alloc::vec![0u8; 65];
        sig[31] = tag; // vary r so distinct "signatures" have distinct calldata to mock against
        sig[64] = 27;
        sig
    }

    fn ecrecover_calldata(msg_hash: FixedBytes<32>, sig: &[u8]) -> Vec<u8> {
        let mut input = alloc::vec![0u8; 128];
        input[0..32].copy_from_slice(msg_hash.as_slice());
        input[63] = sig[64];
        input[64..96].copy_from_slice(&sig[0..32]);
        input[96..128].copy_from_slice(&sig[32..64]);
        input
    }

    fn mock_recovers_to(vm: &TestVM, msg_hash: FixedBytes<32>, sig: &[u8], addr: Address) {
        let calldata = ecrecover_calldata(msg_hash, sig);
        let mut output = alloc::vec![0u8; 32];
        output[12..32].copy_from_slice(addr.as_slice());
        vm.mock_static_call(ECRECOVER, calldata, Ok(output));
    }

    #[test]
    #[ignore = "stylus-test 0.10.9 TestVM only returns the most-recently-registered \
                mock_static_call response, not the one matching each call's own \
                calldata, when two DIFFERENT responses are mocked for the same \
                target within one execution -- see the doc comment above. Real \
                2-of-3-distinct-signers coverage lives in \
                contracts/test/GapwatchRegistryV2.t.sol (real ecrecover)."]
    fn two_of_three_passes() {
        let vm = TestVM::new();
        let hash = FixedBytes::<32>::from([1u8; 32]);
        let sig_a = make_sig(1);
        let sig_b = make_sig(2);
        mock_recovers_to(&vm, hash, &sig_a, NODE_A);
        mock_recovers_to(&vm, hash, &sig_b, NODE_B);

        let contract = ConsensusVerifier::from(&vm);
        let (passed, valid_count, signers) = contract
            .verify_consensus(hash, alloc::vec![sig_a.into(), sig_b.into()], [NODE_A, NODE_B, NODE_C], U256::from(2))
            .unwrap();

        assert!(passed);
        assert_eq!(valid_count, U256::from(2));
        assert_eq!(signers.len(), 2);
    }

    #[test]
    fn one_signature_fails_threshold() {
        let vm = TestVM::new();
        let hash = FixedBytes::<32>::from([2u8; 32]);
        let sig_a = make_sig(1);
        mock_recovers_to(&vm, hash, &sig_a, NODE_A);

        let contract = ConsensusVerifier::from(&vm);
        let (passed, valid_count, _) = contract
            .verify_consensus(hash, alloc::vec![sig_a.into()], [NODE_A, NODE_B, NODE_C], U256::from(2))
            .unwrap();

        assert!(!passed);
        assert_eq!(valid_count, U256::from(1));
    }

    #[test]
    fn same_signer_twice_counts_once() {
        let vm = TestVM::new();
        let hash = FixedBytes::<32>::from([3u8; 32]);
        let sig_a1 = make_sig(1);
        let sig_a2 = make_sig(2); // different signature bytes, same recovered signer
        mock_recovers_to(&vm, hash, &sig_a1, NODE_A);
        mock_recovers_to(&vm, hash, &sig_a2, NODE_A);

        let contract = ConsensusVerifier::from(&vm);
        let (passed, valid_count, signers) = contract
            .verify_consensus(hash, alloc::vec![sig_a1.into(), sig_a2.into()], [NODE_A, NODE_B, NODE_C], U256::from(2))
            .unwrap();

        assert!(!passed);
        assert_eq!(valid_count, U256::from(1));
        assert_eq!(signers.len(), 1);
    }

    #[test]
    #[ignore = "same TestVM limitation as two_of_three_passes -- this test needs two \
                DIFFERENT mocked recovered addresses (NODE_A, OUTSIDER) resolved \
                within one verify_consensus call. Real coverage: \
                GapwatchRegistryV2Test.test_recordVerification_nonNodeSigner_notCounted."]
    fn non_node_signer_not_counted() {
        let vm = TestVM::new();
        let hash = FixedBytes::<32>::from([4u8; 32]);
        let sig_a = make_sig(1);
        let sig_outsider = make_sig(2);
        mock_recovers_to(&vm, hash, &sig_a, NODE_A);
        mock_recovers_to(&vm, hash, &sig_outsider, OUTSIDER);

        let contract = ConsensusVerifier::from(&vm);
        let (passed, valid_count, _) = contract
            .verify_consensus(
                hash,
                alloc::vec![sig_a.into(), sig_outsider.into()],
                [NODE_A, NODE_B, NODE_C],
                U256::from(2),
            )
            .unwrap();

        assert!(!passed);
        assert_eq!(valid_count, U256::from(1));
    }

    #[test]
    #[ignore = "same TestVM limitation as two_of_three_passes -- the exact-threshold-2 \
                half of this test needs two DIFFERENT mocked recovered addresses \
                (NODE_B, NODE_C) resolved within one verify_consensus call. Real \
                coverage: GapwatchRegistryV2Test.test_recordVerification_thresholdBoundary_exactlyTwo_passes."]
    fn threshold_boundary_exact_pass_and_one_short() {
        let vm = TestVM::new();
        let hash = FixedBytes::<32>::from([5u8; 32]);
        let sig_b = make_sig(1);
        let sig_c = make_sig(2);
        mock_recovers_to(&vm, hash, &sig_b, NODE_B);
        mock_recovers_to(&vm, hash, &sig_c, NODE_C);

        let contract = ConsensusVerifier::from(&vm);
        let (passed_exact, count_exact, _) = contract
            .verify_consensus(hash, alloc::vec![sig_b.clone().into(), sig_c.into()], [NODE_A, NODE_B, NODE_C], U256::from(2))
            .unwrap();
        assert!(passed_exact);
        assert_eq!(count_exact, U256::from(2));

        let (passed_short, count_short, _) = contract
            .verify_consensus(hash, alloc::vec![sig_b.into()], [NODE_A, NODE_B, NODE_C], U256::from(2))
            .unwrap();
        assert!(!passed_short);
        assert_eq!(count_short, U256::from(1));
    }

    /// Threshold boundary using only ONE distinct mocked address throughout --
    /// reliable under the TestVM limitation documented above. Complements
    /// (does not replace) the ignored 2-distinct-signer version above.
    #[test]
    fn threshold_boundary_single_signer_exact_and_short() {
        let vm = TestVM::new();
        let hash = FixedBytes::<32>::from([9u8; 32]);
        let sig_a = make_sig(1);
        mock_recovers_to(&vm, hash, &sig_a, NODE_A);

        let contract = ConsensusVerifier::from(&vm);

        // threshold == validCount (1) -> passes.
        let (passed_exact, count_exact, _) = contract
            .verify_consensus(hash, alloc::vec![sig_a.clone().into()], [NODE_A, NODE_B, NODE_C], U256::from(1))
            .unwrap();
        assert!(passed_exact);
        assert_eq!(count_exact, U256::from(1));

        // threshold == validCount + 1 (2) -> fails.
        let (passed_short, count_short, _) = contract
            .verify_consensus(hash, alloc::vec![sig_a.into()], [NODE_A, NODE_B, NODE_C], U256::from(2))
            .unwrap();
        assert!(!passed_short);
        assert_eq!(count_short, U256::from(1));
    }

    #[test]
    fn wrong_signature_length_reverts() {
        let vm = TestVM::new();
        let hash = FixedBytes::<32>::from([6u8; 32]);
        let bad_sig: Vec<u8> = alloc::vec![0u8; 64]; // one byte short

        let contract = ConsensusVerifier::from(&vm);
        let result = contract.verify_consensus(hash, alloc::vec![bad_sig.into()], [NODE_A, NODE_B, NODE_C], U256::from(2));
        assert!(result.is_err());
    }

    #[test]
    fn malleable_high_s_reverts() {
        let vm = TestVM::new();
        let hash = FixedBytes::<32>::from([7u8; 32]);
        let mut bad_sig = make_sig(1);
        bad_sig[32] = 0xFF; // forces s above SECP256K1N_HALF

        let contract = ConsensusVerifier::from(&vm);
        let result = contract.verify_consensus(hash, alloc::vec![bad_sig.into()], [NODE_A, NODE_B, NODE_C], U256::from(2));
        assert!(result.is_err());
    }

    /// Deep-audit: 150 malformed (wrong-length) signatures. Establishes
    /// whether the loop aborts on the FIRST format error or skips bad entries
    /// and keeps iterating. Uses one repeated malformed value, so no
    /// multi-mock TestVM limitation applies.
    #[test]
    fn bulk_malformed_signatures_revert_whole_call() {
        let vm = TestVM::new();
        let hash = FixedBytes::<32>::from([10u8; 32]);

        let mut sigs: Vec<Bytes> = Vec::new();
        for _ in 0..150 {
            let bad: Vec<u8> = alloc::vec![0u8; 64]; // one byte short
            sigs.push(bad.into());
        }

        let contract = ConsensusVerifier::from(&vm);
        let result = contract.verify_consensus(hash, sigs, [NODE_A, NODE_B, NODE_C], U256::from(2));
        assert!(result.is_err(), "150 malformed sigs must revert, not be skipped");
        assert_eq!(result.unwrap_err(), b"InvalidSignatureLength".to_vec());
    }

    /// The abort happens at the FIRST bad entry even when a good entry
    /// precedes it -- i.e. a malformed signature is never silently dropped in
    /// favour of continuing to tally the well-formed ones.
    #[test]
    fn malformed_after_valid_still_reverts_whole_call() {
        let vm = TestVM::new();
        let hash = FixedBytes::<32>::from([11u8; 32]);
        let good = make_sig(1);
        mock_recovers_to(&vm, hash, &good, NODE_A);

        let mut sigs: Vec<Bytes> = Vec::new();
        sigs.push(good.into());
        sigs.push(alloc::vec![0u8; 10].into()); // malformed
        sigs.push(make_sig(2).into());

        let contract = ConsensusVerifier::from(&vm);
        let result = contract.verify_consensus(hash, sigs, [NODE_A, NODE_B, NODE_C], U256::from(2));
        assert!(result.is_err());
        assert_eq!(result.unwrap_err(), b"InvalidSignatureLength".to_vec());
    }

    /// Control case for the two above: 150 WELL-FORMED signatures all
    /// recovering to the same signer run the loop to completion (no revert)
    /// and dedup down to a single vote. Confirms the revert in the malformed
    /// cases comes from the format check, not from the array length.
    #[test]
    fn bulk_wellformed_duplicate_signatures_complete_and_dedup() {
        let vm = TestVM::new();
        let hash = FixedBytes::<32>::from([12u8; 32]);
        let good = make_sig(1);
        mock_recovers_to(&vm, hash, &good, NODE_A);

        let mut sigs: Vec<Bytes> = Vec::new();
        for _ in 0..150 {
            sigs.push(good.clone().into());
        }

        let contract = ConsensusVerifier::from(&vm);
        let (passed, valid_count, signers) = contract
            .verify_consensus(hash, sigs, [NODE_A, NODE_B, NODE_C], U256::from(2))
            .unwrap();

        assert!(!passed);
        assert_eq!(valid_count, U256::from(1));
        assert_eq!(signers.len(), 1);
    }

    /// Deep-audit: a zero `s` passes the low-s malleability test (0 <= n/2) and
    /// is therefore NOT treated as a format error; it is handed to the
    /// precompile, which fails to recover, and the entry is skipped rather
    /// than reverting. Documents the boundary between "format error ->
    /// revert" and "recovery failure -> skip". Mocked precompile returns
    /// empty output, matching the real precompile's failure representation.
    #[test]
    fn zero_s_is_skipped_not_reverted() {
        let vm = TestVM::new();
        let hash = FixedBytes::<32>::from([13u8; 32]);

        let mut sig = alloc::vec![0u8; 65];
        sig[31] = 7; // some r
        // s stays all-zero
        sig[64] = 27;

        // Real ECRECOVER returns EMPTY output (not a revert) when it cannot
        // recover; mock that shape explicitly.
        let calldata = ecrecover_calldata(hash, &sig);
        vm.mock_static_call(ECRECOVER, calldata, Ok(alloc::vec![]));

        let contract = ConsensusVerifier::from(&vm);
        let (passed, valid_count, signers) = contract
            .verify_consensus(hash, alloc::vec![sig.into()], [NODE_A, NODE_B, NODE_C], U256::from(2))
            .unwrap();

        assert!(!passed);
        assert_eq!(valid_count, U256::from(0));
        assert_eq!(signers.len(), 0);
    }

    #[test]
    fn invalid_v_reverts() {
        let vm = TestVM::new();
        let hash = FixedBytes::<32>::from([8u8; 32]);
        let mut bad_sig = make_sig(1);
        bad_sig[64] = 5; // not 27/28, and not < 27 either after normalization branch (5 -> +27 = 32)

        let contract = ConsensusVerifier::from(&vm);
        let result = contract.verify_consensus(hash, alloc::vec![bad_sig.into()], [NODE_A, NODE_B, NODE_C], U256::from(2));
        assert!(result.is_err());
    }
}
