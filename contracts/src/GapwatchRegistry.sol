// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title GapwatchRegistry
/// @notice On-chain, append-only record of Gapwatch's off-chain verification pipeline
///         (modules 1-5): for each candidate corporate-action event, whether it was
///         compliance-filtered, its old/new UI multiplier, and a hash sealing the
///         independent Reference Model's recomputation. Tier 2 adds an economic
///         challenge mechanism: the relayer posts a bond with every record, and
///         anyone can challenge it within a time window by matching that bond.
/// @dev V1 TRUST MODEL -- READ BEFORE INTEGRATING OR AUDITING:
///      Writes are gated by a single `relayer` address, controlled by a single
///      `owner`. This is a deliberate simplification, not an oversight: V1's job is
///      to prove the on-chain recording primitive works (immutable-once-written,
///      queryable, event-logged), not to solve decentralized trust yet. Anyone
///      who does not trust the relayer operator must not treat data in this
///      contract as independently attested -- it is only as trustworthy as
///      whoever controls the relayer key today.
///
///      Tier 2 does NOT decentralize dispute resolution either: `resolveChallenge`
///      is decided by `owner` alone, by human judgment, off-chain. There is no
///      on-chain arbitration logic -- owner simply picks a winner. A compromised
///      or dishonest owner can drain every posted relayer bond by acting as (or
///      colluding with) the challenger on every record and always ruling in the
///      challenger's favor; owner cannot redirect funds to an arbitrary address
///      it does not already control as relayer or challenger, but self-dealing via
///      collusion is entirely possible and this contract does nothing to prevent
///      it. Do not treat V1 as trust-minimized. The planned fix is Tier 3:
///      replacing both the single relayer and the single-owner arbitration with
///      M-of-N multi-party verification. `Discrepancy` is pre-declared below for
///      that future use; it is unused in V1.
contract GapwatchRegistry is Ownable, ReentrancyGuard {
    struct Verification {
        address token;
        uint256 oldMultiplier;
        uint256 newMultiplier;
        bool wasFiltered;
        bytes32 referenceModelHash;
        uint256 recordedAt;
        /// @dev Bond posted by `recordedBy` when this record was written. Zeroed
        ///      out the moment it is paid out via `resolveChallenge` or reclaimed
        ///      via `reclaimBond` -- doubles as a single-spend guard so neither
        ///      path can pay out the same bond twice.
        uint256 bond;
        /// @dev Whoever called `recordVerification` and posted `bond`. Captured
        ///      separately from the mutable `relayer` pointer: if `setRelayer`
        ///      rotates the role afterwards, the bond must still return to
        ///      whoever actually posted it, not to whoever holds the role now.
        address recordedBy;
    }

    struct Challenge {
        address challenger;
        uint256 amount;
        bool resolved;
    }

    /// @notice Keyed by the candidate event's tx hash, matching `event_store.tx_hash`
    ///         off-chain so the API layer can look records up directly.
    mapping(bytes32 => Verification) public verifications;
    mapping(bytes32 => Challenge) public challenges;
    mapping(address => uint256) public pendingWithdrawals;

    address public relayer;

    /// @notice Minimum ETH (wei) the relayer must post with each `recordVerification`
    ///         call. Owner-adjustable.
    uint256 public requiredBond;

    /// @notice How long after `recordedAt` a record can still be challenged.
    ///         Owner-adjustable, capped at `MAX_CHALLENGE_WINDOW`.
    uint256 public challengeWindow;

    /// @dev Hard ceiling on `challengeWindow`. Without this, `recordedAt +
    ///      challengeWindow` (computed in `challenge`/`reclaimBond`) can overflow
    ///      uint256 for a large enough window and revert every single time --
    ///      permanently stranding every future bond with no way to challenge OR
    ///      reclaim it. A generous but finite cap closes that off entirely rather
    ///      than relying on owner never making this mistake.
    uint256 public constant MAX_CHALLENGE_WINDOW = 365 days;

    event VerificationRecorded(bytes32 indexed eventHash, address indexed token, bool wasFiltered);
    event RelayerUpdated(address indexed oldRelayer, address indexed newRelayer);
    event RequiredBondUpdated(uint256 oldBond, uint256 newBond);
    event ChallengeWindowUpdated(uint256 oldWindow, uint256 newWindow);
    event Challenged(bytes32 indexed eventHash, address indexed challenger, uint256 amount);
    event ChallengeResolved(bytes32 indexed eventHash, bool challengerWon);
    event BondReclaimed(bytes32 indexed eventHash, address indexed relayer, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);

    /// @notice Reserved for Tier 2.5 downstream consumer contracts to flag a
    ///         disagreement they observe (e.g. against their own reference model).
    ///         Declared now for interface stability; no code in V1 emits it.
    event Discrepancy(bytes32 indexed eventHash, string reason);

    error NotRelayer();
    error ZeroAddress();
    error AlreadyRecorded(bytes32 eventHash);
    error InsufficientBond(uint256 required, uint256 sent);
    error NotVerified(bytes32 eventHash);
    error ChallengeWindowExpired();
    error ChallengeWindowNotExpired();
    error ChallengeAlreadyActive();
    error NoActiveChallenge();
    error NothingToReclaim();
    error WithdrawFailed();
    error ChallengeWindowTooLong(uint256 requested, uint256 max);

    modifier onlyRelayer() {
        if (msg.sender != relayer) revert NotRelayer();
        _;
    }

    /// @dev `owner` (and `transferOwnership()` / `renounceOwnership()`) come from
    ///      OpenZeppelin's Ownable, deployer set as the initial owner.
    constructor(address initialRelayer, uint256 initialRequiredBond, uint256 initialChallengeWindow)
        Ownable(msg.sender)
    {
        if (initialRelayer == address(0)) revert ZeroAddress();
        if (initialChallengeWindow > MAX_CHALLENGE_WINDOW) {
            revert ChallengeWindowTooLong(initialChallengeWindow, MAX_CHALLENGE_WINDOW);
        }
        relayer = initialRelayer;
        requiredBond = initialRequiredBond;
        challengeWindow = initialChallengeWindow;
    }

    /// @notice Record one verified event, posting `msg.value` as its bond. Reverts
    ///         if `eventHash` was already recorded -- records are immutable once
    ///         written by design: this is the core trust guarantee of the registry.
    ///         A relayer that made a mistake cannot quietly overwrite it; the wrong
    ///         record stays visible forever, which is the honest outcome for an
    ///         audit trail (it can still be challenged and its bond slashed).
    function recordVerification(
        bytes32 eventHash,
        address token,
        uint256 oldMultiplier,
        uint256 newMultiplier,
        bool wasFiltered,
        bytes32 referenceModelHash
    ) external payable onlyRelayer {
        if (token == address(0)) revert ZeroAddress();
        if (verifications[eventHash].recordedAt != 0) revert AlreadyRecorded(eventHash);
        if (msg.value < requiredBond) revert InsufficientBond(requiredBond, msg.value);

        verifications[eventHash] = Verification({
            token: token,
            oldMultiplier: oldMultiplier,
            newMultiplier: newMultiplier,
            wasFiltered: wasFiltered,
            referenceModelHash: referenceModelHash,
            recordedAt: block.timestamp,
            bond: msg.value,
            recordedBy: msg.sender
        });

        emit VerificationRecorded(eventHash, token, wasFiltered);
    }

    /// @notice Challenge a record within its challenge window by matching its bond.
    ///         Only one unresolved challenge may be outstanding per record at a
    ///         time; a new one may be filed once the previous is resolved, but in
    ///         practice every resolution path zeroes `bond`, so a record can only
    ///         ever be challenged productively once -- there is nothing left to
    ///         seize on a second attempt, and this function reverts rather than
    ///         accept a challenge with no stake behind it.
    function challenge(bytes32 eventHash) external payable {
        Verification storage v = verifications[eventHash];
        if (v.recordedAt == 0) revert NotVerified(eventHash);
        if (v.bond == 0) revert NothingToReclaim();
        if (block.timestamp > v.recordedAt + challengeWindow) revert ChallengeWindowExpired();

        Challenge storage c = challenges[eventHash];
        if (c.challenger != address(0) && !c.resolved) revert ChallengeAlreadyActive();
        if (msg.value < v.bond) revert InsufficientBond(v.bond, msg.value);

        challenges[eventHash] = Challenge({challenger: msg.sender, amount: msg.value, resolved: false});
        emit Challenged(eventHash, msg.sender, msg.value);
    }

    /// @notice Decide an outstanding challenge. V1 CENTRALIZATION WARNING: this is
    ///         plain human judgment by `owner`, not on-chain arbitration -- see the
    ///         contract-level NatSpec for the blast radius of a compromised owner.
    ///         `challengerWins = true` sends the relayer's bond plus the
    ///         challenger's own bond to the challenger (the relayer's bond is
    ///         slashed). `challengerWins = false` sends the relayer's bond plus
    ///         the challenger's forfeited bond to the relayer instead (the
    ///         challenger's bond is slashed as the cost of a rejected challenge).
    ///         Either way, both bonds are always accounted for and credited to
    ///         exactly one party via `pendingWithdrawals` -- pull payment, not a
    ///         direct transfer, so this function itself makes no external call.
    function resolveChallenge(bytes32 eventHash, bool challengerWins) external onlyOwner {
        Challenge storage c = challenges[eventHash];
        if (c.challenger == address(0) || c.resolved) revert NoActiveChallenge();

        Verification storage v = verifications[eventHash];
        uint256 relayerBond = v.bond;
        uint256 challengerBond = c.amount;
        v.bond = 0;
        c.resolved = true;

        if (challengerWins) {
            pendingWithdrawals[c.challenger] += relayerBond + challengerBond;
        } else {
            pendingWithdrawals[v.recordedBy] += relayerBond + challengerBond;
        }

        emit ChallengeResolved(eventHash, challengerWins);
    }

    /// @notice Let the relayer who posted a record's bond reclaim it once the
    ///         challenge window has passed with no challenge ever filed (or the
    ///         only one filed already resolved). Without this, every unchallenged
    ///         bond -- the overwhelmingly common case -- would be permanently
    ///         stuck in the contract with no way out.
    function reclaimBond(bytes32 eventHash) external {
        Verification storage v = verifications[eventHash];
        if (v.recordedAt == 0) revert NotVerified(eventHash);
        if (v.bond == 0) revert NothingToReclaim();
        if (block.timestamp <= v.recordedAt + challengeWindow) revert ChallengeWindowNotExpired();

        Challenge storage c = challenges[eventHash];
        if (c.challenger != address(0) && !c.resolved) revert ChallengeAlreadyActive();

        uint256 amount = v.bond;
        v.bond = 0;
        pendingWithdrawals[v.recordedBy] += amount;

        emit BondReclaimed(eventHash, v.recordedBy, amount);
    }

    /// @notice Pull payment: withdraw whatever `pendingWithdrawals` has accrued for
    ///         the caller. A zero balance is a safe no-op, not a revert. Balance is
    ///         zeroed before the external call (checks-effects-interactions) and
    ///         the function is also `nonReentrant` as defense in depth.
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) return;

        pendingWithdrawals[msg.sender] = 0;

        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) revert WithdrawFailed();

        emit Withdrawn(msg.sender, amount);
    }

    function isVerified(bytes32 eventHash) external view returns (bool) {
        return verifications[eventHash].recordedAt != 0;
    }

    function getVerification(bytes32 eventHash) external view returns (Verification memory) {
        return verifications[eventHash];
    }

    function getChallenge(bytes32 eventHash) external view returns (Challenge memory) {
        return challenges[eventHash];
    }

    function setRelayer(address newRelayer) external onlyOwner {
        if (newRelayer == address(0)) revert ZeroAddress();
        address old = relayer;
        relayer = newRelayer;
        emit RelayerUpdated(old, newRelayer);
    }

    function setRequiredBond(uint256 newBond) external onlyOwner {
        uint256 old = requiredBond;
        requiredBond = newBond;
        emit RequiredBondUpdated(old, newBond);
    }

    function setChallengeWindow(uint256 newWindow) external onlyOwner {
        if (newWindow > MAX_CHALLENGE_WINDOW) {
            revert ChallengeWindowTooLong(newWindow, MAX_CHALLENGE_WINDOW);
        }
        uint256 old = challengeWindow;
        challengeWindow = newWindow;
        emit ChallengeWindowUpdated(old, newWindow);
    }
}
