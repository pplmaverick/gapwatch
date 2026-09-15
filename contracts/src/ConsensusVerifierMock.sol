// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IConsensusVerifier} from "./IConsensusVerifier.sol";

/// @title ConsensusVerifierMock
/// @notice Solidity implementation of `IConsensusVerifier`, logically identical
///         to the Rust/Stylus `ConsensusVerifier` in `contracts-stylus/src/lib.rs`
///         (same malleability check, same v-normalization, same dedup, same
///         revert-vs-skip split). It exists for two reasons, not one:
///
///         1. `forge test` runs on the EVM (via revm) and cannot execute
///            Stylus/WASM bytecode, so `GapwatchRegistryV2`'s Foundry test
///            suite needs an ABI-compatible stand-in to call against.
///         2. It is also the "Solidity ecrecover-only" comparison point for
///            the gas benchmark requested alongside this contract -- there is
///            no separate throwaway benchmark contract, this mock IS that
///            benchmark.
///
///         This is a test/benchmark fixture, not a production fallback. The
///         production path is the Stylus contract; this file must not be
///         wired into any real deployment of GapwatchRegistryV2.
contract ConsensusVerifierMock is IConsensusVerifier {
    /// @dev secp256k1 curve order n, halved: `s` above this is the malleable
    ///      (high-s) representation of a valid low-s signature. Same constant
    ///      OpenZeppelin's ECDSA.sol uses.
    uint256 private constant SECP256K1N_HALF = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    error InvalidSignatureLength(uint256 index, uint256 length);
    error InvalidSignatureS(uint256 index);
    error InvalidSignatureV(uint256 index, uint8 v);

    /// @inheritdoc IConsensusVerifier
    function verifyConsensus(
        bytes32 msgHash,
        bytes[] calldata signatures,
        address[3] calldata expectedSigners,
        uint256 threshold
    ) external pure returns (bool passed, uint256 validCount, address[] memory signers) {
        address[] memory seen = new address[](signatures.length);
        uint256 count = 0;

        for (uint256 i = 0; i < signatures.length; i++) {
            address recovered = _recoverChecked(msgHash, signatures[i], i);
            if (recovered == address(0)) continue;

            if (
                recovered != expectedSigners[0] && recovered != expectedSigners[1] && recovered != expectedSigners[2]
            ) {
                continue;
            }

            if (!_contains(seen, count, recovered)) {
                seen[count] = recovered;
                count++;
            }
        }

        signers = new address[](count);
        for (uint256 k = 0; k < count; k++) {
            signers[k] = seen[k];
        }
        validCount = count;
        passed = count >= threshold;
    }

    /// @dev Format-checks and recovers one signature. Reverts on malformed
    ///      input (length, malleable `s`, invalid `v`); returns `address(0)`
    ///      (never reverts) when `ecrecover` itself fails to recover a signer.
    function _recoverChecked(bytes32 msgHash, bytes calldata sig, uint256 index) private pure returns (address) {
        if (sig.length != 65) revert InvalidSignatureLength(index, sig.length);

        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);

        // Malleability guard: reject high-s signatures outright rather than
        // silently normalizing them -- a format error must revert, not be
        // quietly "fixed" into something the original signer never signed.
        if (uint256(s) > SECP256K1N_HALF) revert InvalidSignatureS(index);

        if (v < 27) v += 27;
        if (v != 27 && v != 28) revert InvalidSignatureV(index, v);

        return ecrecover(msgHash, v, r, s);
    }

    function _contains(address[] memory arr, uint256 len, address needle) private pure returns (bool) {
        for (uint256 j = 0; j < len; j++) {
            if (arr[j] == needle) return true;
        }
        return false;
    }
}
