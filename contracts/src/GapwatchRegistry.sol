// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title GapwatchRegistry
/// @notice On-chain, append-only record of Gapwatch's off-chain verification pipeline
///         (modules 1-5): for each candidate corporate-action event, whether it was
///         compliance-filtered, its old/new UI multiplier, and a hash sealing the
///         independent Reference Model's recomputation.
/// @dev V1 TRUST MODEL -- READ BEFORE INTEGRATING OR AUDITING:
///      Writes are gated by a single `relayer` address, controlled by a single
///      `owner`. This is a deliberate simplification, not an oversight: V1's job is
///      to prove the on-chain recording primitive works (immutable-once-written,
///      queryable, event-logged), not to solve decentralized trust yet. Anyone
///      who does not trust the relayer operator must not treat data in this
///      contract as independently attested -- it is only as trustworthy as
///      whoever controls the relayer key today.
///
///      The planned fix is Tier 3: replacing the single relayer with M-of-N
///      multi-party verification (multiple independent relayers whose reports
///      must agree before a record is accepted). `Discrepancy` is pre-declared
///      below for that future use; it is unused in V1.
contract GapwatchRegistry is Ownable {
    struct Verification {
        address token;
        uint256 oldMultiplier;
        uint256 newMultiplier;
        bool wasFiltered;
        bytes32 referenceModelHash;
        uint256 recordedAt;
    }

    /// @notice Keyed by the candidate event's tx hash, matching `event_store.tx_hash`
    ///         off-chain so the API layer can look records up directly.
    mapping(bytes32 => Verification) public verifications;

    address public relayer;

    event VerificationRecorded(bytes32 indexed eventHash, address indexed token, bool wasFiltered);
    event RelayerUpdated(address indexed oldRelayer, address indexed newRelayer);

    /// @notice Reserved for Tier 2.5 downstream consumer contracts to flag a
    ///         disagreement they observe (e.g. against their own reference model).
    ///         Declared now for interface stability; no code in V1 emits it.
    event Discrepancy(bytes32 indexed eventHash, string reason);

    error NotRelayer();
    error ZeroAddress();
    error AlreadyRecorded(bytes32 eventHash);

    modifier onlyRelayer() {
        if (msg.sender != relayer) revert NotRelayer();
        _;
    }

    /// @dev `owner` (and `transferOwnership()` / `renounceOwnership()`) come from
    ///      OpenZeppelin's Ownable, deployer set as the initial owner.
    constructor(address initialRelayer) Ownable(msg.sender) {
        if (initialRelayer == address(0)) revert ZeroAddress();
        relayer = initialRelayer;
    }

    /// @notice Record one verified event. Reverts if `eventHash` was already
    ///         recorded -- records are immutable once written by design: this is
    ///         the core trust guarantee of the registry. A relayer that made a
    ///         mistake cannot quietly overwrite it; the wrong record stays visible
    ///         forever, which is the honest outcome for an audit trail.
    function recordVerification(
        bytes32 eventHash,
        address token,
        uint256 oldMultiplier,
        uint256 newMultiplier,
        bool wasFiltered,
        bytes32 referenceModelHash
    ) external onlyRelayer {
        if (token == address(0)) revert ZeroAddress();
        if (verifications[eventHash].recordedAt != 0) revert AlreadyRecorded(eventHash);

        verifications[eventHash] = Verification({
            token: token,
            oldMultiplier: oldMultiplier,
            newMultiplier: newMultiplier,
            wasFiltered: wasFiltered,
            referenceModelHash: referenceModelHash,
            recordedAt: block.timestamp
        });

        emit VerificationRecorded(eventHash, token, wasFiltered);
    }

    function isVerified(bytes32 eventHash) external view returns (bool) {
        return verifications[eventHash].recordedAt != 0;
    }

    function getVerification(bytes32 eventHash) external view returns (Verification memory) {
        return verifications[eventHash];
    }

    function setRelayer(address newRelayer) external onlyOwner {
        if (newRelayer == address(0)) revert ZeroAddress();
        address old = relayer;
        relayer = newRelayer;
        emit RelayerUpdated(old, newRelayer);
    }
}
