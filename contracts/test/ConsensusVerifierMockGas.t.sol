// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ConsensusVerifierMock} from "../src/ConsensusVerifierMock.sol";

/// @notice Isolated gas measurement for the Solidity ecrecover-only
///         `verifyConsensus` path, requested as a stand-in estimate for the
///         Rust/Stylus `ConsensusVerifier`'s order of magnitude (calling the
///         ECRECOVER precompile from Stylus costs roughly the same ~3000 gas
///         per call as calling it from Solidity -- the precompile itself is
///         the same EVM-level operation either way; what differs is
///         surrounding interpreter/host-call overhead, which this Solidity
///         number does not capture). Not a substitute for a real Stylus
///         benchmark once the contract is deployed.
contract ConsensusVerifierMockGasTest is Test {
    ConsensusVerifierMock verifier;
    uint256 node1Pk;
    uint256 node2Pk;
    uint256 node3Pk;
    address node1;
    address node2;
    address node3;

    function setUp() public {
        (node1, node1Pk) = makeAddrAndKey("gasnode1");
        (node2, node2Pk) = makeAddrAndKey("gasnode2");
        (node3, node3Pk) = makeAddrAndKey("gasnode3");
        verifier = new ConsensusVerifierMock();
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// 2 signatures, 2 valid (the realistic 2-of-3 happy path).
    function test_gas_twoSignatures_twoValid() public {
        bytes32 digest = keccak256("gas-bench-2of3");
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(node1Pk, digest);
        sigs[1] = _sign(node2Pk, digest);
        address[3] memory expected = [node1, node2, node3];

        uint256 gasBefore = gasleft();
        verifier.verifyConsensus(digest, sigs, expected, 2);
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("gas: verifyConsensus(2 sigs, 2 valid, threshold 2)", used);
    }

    /// 3 signatures, all 3 valid (upper bound for a 3-node set).
    function test_gas_threeSignatures_threeValid() public {
        bytes32 digest = keccak256("gas-bench-3of3");
        bytes[] memory sigs = new bytes[](3);
        sigs[0] = _sign(node1Pk, digest);
        sigs[1] = _sign(node2Pk, digest);
        sigs[2] = _sign(node3Pk, digest);
        address[3] memory expected = [node1, node2, node3];

        uint256 gasBefore = gasleft();
        verifier.verifyConsensus(digest, sigs, expected, 2);
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("gas: verifyConsensus(3 sigs, 3 valid, threshold 2)", used);
    }
}
