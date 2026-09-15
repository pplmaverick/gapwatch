// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IConsensusVerifier
/// @notice Interface for the Tier 3+4 M-of-N consensus verifier. The production
///         implementation is a Stylus (Rust) contract in `contracts-stylus/`;
///         this same interface is implemented in Solidity by
///         `ConsensusVerifierMock.sol`, used for Foundry testing and gas
///         benchmarking since `forge test` runs on the EVM and cannot execute
///         Stylus/WASM bytecode.
interface IConsensusVerifier {
    /// @notice Recovers the signer of each entry in `signatures` over `msgHash`,
    ///         counts how many distinct recovered addresses appear in
    ///         `expectedSigners`, and reports whether that count meets
    ///         `threshold`.
    /// @dev Two distinct classes of bad input, with DIFFERENT handling -- do not
    ///      conflate them:
    ///
    ///      (1) REVERTS the whole call. Exactly three checks, all performed by
    ///          the verifier itself before touching the precompile:
    ///            - length != 65 bytes
    ///            - malleable (high) `s`, i.e. `s > secp256k1n/2`. The cutoff is
    ///              inclusive of `n/2`: `s == n/2` passes, `s == n/2 + 1` reverts.
    ///            - `v` outside {27, 28} after normalising `v < 27` by adding 27
    ///
    ///      (2) SILENTLY SKIPPED -- not counted toward `validCount`, does NOT
    ///          revert:
    ///            - `r == 0`, `s == 0`, or `r >= secp256k1n`. These are
    ///              structurally invalid encodings, but the verifier does not
    ///              pre-check them; they reach the ECRECOVER precompile, which
    ///              signals failure by returning EMPTY output rather than
    ///              reverting, and the entry is then dropped.
    ///            - any signature that recovers cleanly to an address not in
    ///              `expectedSigners`.
    ///
    ///      So "malformed input always reverts" is NOT true as a blanket rule:
    ///      only the three checks in (1) revert. The cases in (2) are silently
    ///      dropped. This split is implementation behaviour verified on-chain,
    ///      not an aspiration -- do not restate it more strongly than this.
    ///
    ///      Deduplication is by RECOVERED ADDRESS, not by position in
    ///      `expectedSigners`: the same valid signer appearing more than once
    ///      counts as one vote, and a duplicated entry inside `expectedSigners`
    ///      cannot let a single signer satisfy a threshold of 2.
    /// @param msgHash The digest that was signed (caller is responsible for
    ///        binding it to whatever context -- event, contract, chain --
    ///        needs replay protection; this function does not inspect
    ///        `msgHash`'s contents).
    /// @param signatures Each entry must be exactly 65 bytes: `r` (32) ||
    ///        `s` (32) || `v` (1), `v` in `{0,1,27,28}`.
    /// @param expectedSigners The fixed 3-address node set to recover against.
    /// @param threshold Minimum distinct valid-signer count for `passed`.
    function verifyConsensus(
        bytes32 msgHash,
        bytes[] calldata signatures,
        address[3] calldata expectedSigners,
        uint256 threshold
    ) external view returns (bool passed, uint256 validCount, address[] memory signers);
}
