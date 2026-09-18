// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IConsensusVerifier} from "./IConsensusVerifier.sol";

/// @title GapwatchRegistryV2
/// @notice Tier 3 revision of `GapwatchRegistry` (V1, left deployed and unmodified
///         at its existing address -- see `deployment.json`): replaces the single
///         `relayer` address and single-`owner` arbitration with a fixed 3-node,
///         2-of-3 ECDSA multi-signature consensus, verified by an external
///         `IConsensusVerifier` (the Tier 4 Stylus contract in `contracts-stylus/`
///         in production; `ConsensusVerifierMock.sol` in tests -- see that file's
///         NatSpec for why the split exists).
/// @dev V2 TRUST MODEL -- READ BEFORE INTEGRATING OR AUDITING:
///      The 3-address node set (`node1`/`node2`/`node3`) is fixed at construction
///      and genuinely immutable: there is no setter, and the underlying variables
///      use Solidity's `immutable` keyword. (Solidity does not allow `immutable`
///      on array types, which is why the set is three separate `immutable`
///      addresses rather than an `address[3] immutable` -- `nodeSet()` below
///      reassembles them into the array shape `IConsensusVerifier` expects.)
///      `recordVerification`, `resolveChallenge`, and `reportDiscrepancy` all
///      require 2-of-3 valid, distinct ECDSA signatures over a digest bound to
///      this contract's address, the current chain id, and the specific
///      record/challenge/discrepancy being acted on -- each with its own
///      leading domain-separation tag (`REPORT_DISCREPANCY_TAG` for the last
///      one) so a valid signature set for one function can never be replayed
///      against another, even where argument shapes might otherwise coincide.
///      This closes V1's two centralization risks (single relayer key, single
///      owner arbitration) but introduces a new one this contract does nothing
///      to solve: if 2 of the 3 node keys are compromised or collude, they have
///      exactly the same power V1's relayer+owner had -- forge records, resolve
///      challenges, and flag/suppress discrepancies in their own favor. This is
///      a smaller trust anchor than V1 (3 independent keys vs. 1), not a
///      trustless one. A production deployment should treat node key
///      management (HSMs, separate operators, key rotation via a full
///      redeploy) as seriously as the contract logic itself. `owner` retains
///      no path to bypass consensus on any of these three functions.
contract GapwatchRegistryV2 is Ownable, ReentrancyGuard {
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
        /// @dev Whoever called `recordVerification` and posted `bond`. Not
        ///      required to be one of the 3 consensus nodes -- consensus
        ///      authorizes *what* gets written, not *who* pays for it.
        address recordedBy;
    }

    struct Challenge {
        address challenger;
        uint256 amount;
        bool resolved;
    }

    /// @notice Keyed by the candidate event's tx hash, matching `event_store.tx_hash`
    ///         off-chain so the API layer can look records up directly. Also
    ///         doubles as the "challenge id" referenced in this contract's
    ///         signed messages -- there is no separate challenge-id type, a
    ///         challenge is identified by the eventHash it challenges.
    mapping(bytes32 => Verification) public verifications;
    mapping(bytes32 => Challenge) public challenges;
    mapping(address => uint256) public pendingWithdrawals;

    /// @notice Most recent eventHash recorded for a given token, so a downstream
    ///         consumer (Tier 2.5) can find "the latest verification for this
    ///         token" without indexing events off-chain.
    mapping(address => bytes32) public latestVerificationForToken;

    /// @notice Set once `reportDiscrepancy` has been called for an eventHash.
    ///         Never cleared -- a flagged discrepancy is permanent history, same
    ///         as everything else in this registry.
    mapping(bytes32 => bool) public hasDiscrepancy;

    /// @notice The fixed 3-node consensus set. See contract-level NatSpec for
    ///         why these are three separate `immutable`s instead of one array.
    address public immutable node1;
    address public immutable node2;
    address public immutable node3;

    /// @notice The `IConsensusVerifier` implementation this registry defers to.
    ///         Production: the Tier 4 Stylus contract. Tests: `ConsensusVerifierMock`.
    address public immutable consensusVerifier;

    /// @notice Fixed at 2-of-3 for this revision. Not owner-adjustable: changing
    ///         the security threshold is a governance decision Tier 3 does not
    ///         attempt to make configurable post-deployment.
    uint256 public constant CONSENSUS_THRESHOLD = 2;

    /// @notice Domain-separation tags mixed into each function's signed digest
    ///         as the first `abi.encode` field. `recordVerification` and
    ///         `resolveChallenge` are already domain-separated from each other
    ///         by their differing argument shapes, but `reportDiscrepancy`
    ///         accepts only `(bytes32, string)` -- not distinguishable from a
    ///         truncated/coincidental encoding of another function's args by
    ///         shape alone. Do not rely on "the arguments happen to differ";
    ///         these tags make cross-function signature replay impossible by
    ///         construction, not by accident of the current parameter lists.
    bytes32 public constant REPORT_DISCREPANCY_TAG = keccak256("GapwatchRegistryV2.reportDiscrepancy");

    /// @notice Minimum ETH (wei) the caller must post with each `recordVerification`
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
    event RequiredBondUpdated(uint256 oldBond, uint256 newBond);
    event ChallengeWindowUpdated(uint256 oldWindow, uint256 newWindow);
    event Challenged(bytes32 indexed eventHash, address indexed challenger, uint256 amount);
    event ChallengeResolved(bytes32 indexed eventHash, bool challengerWon);
    event BondReclaimed(bytes32 indexed eventHash, address indexed relayer, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);

    /// @notice Emitted by `reportDiscrepancy` when 2-of-3 node consensus flags a
    ///         recorded event as disputed (e.g. the off-chain Reference Model no
    ///         longer agrees with what's on-chain). Tier 2.5 downstream consumers
    ///         (e.g. MockLendingPool) watch for this via `hasDiscrepancy`.
    event Discrepancy(bytes32 indexed eventHash, string reason);

    error ZeroAddress();
    error DuplicateNode();
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
    /// @notice `verifyConsensus` reported `validCount < CONSENSUS_THRESHOLD`.
    error ConsensusNotReached(uint256 validCount, uint256 threshold);
    /// @notice `tokenAddress.staticcall(uiMultiplier())` did not come back
    ///         with a clean 32-byte return -- either it reverted, or it has
    ///         no code / isn't ERC-8056-shaped at that selector.
    error NotERC8056Token(address token);
    /// @notice The relayer's `claimedFiltered` does not match what
    ///         `isTransactionFiltered(txHash)` reports on-chain right now.
    error FilterCheckMismatch(bytes32 txHash, bool claimedFiltered, bool actualFiltered);
    /// @notice The relayer's `claimedMultiplier` does not match
    ///         `tokenAddress.uiMultiplier()`'s current on-chain value.
    error MultiplierMismatch(address tokenAddress, uint256 claimedMultiplier, uint256 actualMultiplier);

    /// @notice ArbOS's ArbFilteredTransactionsManager precompile, and the
    ///         ERC-8056 `uiMultiplier()` selector. Verified against live RPC
    ///         (see docs/recordVerification-checklist.md and the audit
    ///         history for this cross-validation logic).
    address public constant FILTER_PRECOMPILE = 0x0000000000000000000000000000000000000074;
    bytes4 public constant IS_FILTERED_SELECTOR = 0x85c733a4;
    bytes4 public constant UI_MULTIPLIER_SELECTOR = 0xa60bf13d;

    /// @dev `owner` (and `transferOwnership()` / `renounceOwnership()`) come from
    ///      OpenZeppelin's Ownable, deployer set as the initial owner. Owner
    ///      retains only the config knobs below (`requiredBond`, `challengeWindow`)
    ///      -- it has no path to bypass consensus on `recordVerification`,
    ///      `resolveChallenge`, or `reportDiscrepancy`.
    constructor(
        address[3] memory _nodeSet,
        address _consensusVerifier,
        uint256 initialRequiredBond,
        uint256 initialChallengeWindow
    ) Ownable(msg.sender) {
        if (_nodeSet[0] == address(0) || _nodeSet[1] == address(0) || _nodeSet[2] == address(0)) {
            revert ZeroAddress();
        }
        if (_consensusVerifier == address(0)) revert ZeroAddress();
        if (_nodeSet[0] == _nodeSet[1] || _nodeSet[0] == _nodeSet[2] || _nodeSet[1] == _nodeSet[2]) {
            revert DuplicateNode();
        }
        if (initialChallengeWindow > MAX_CHALLENGE_WINDOW) {
            revert ChallengeWindowTooLong(initialChallengeWindow, MAX_CHALLENGE_WINDOW);
        }

        node1 = _nodeSet[0];
        node2 = _nodeSet[1];
        node3 = _nodeSet[2];
        consensusVerifier = _consensusVerifier;
        requiredBond = initialRequiredBond;
        challengeWindow = initialChallengeWindow;
    }

    /// @notice The fixed node set as the `address[3]` shape `IConsensusVerifier`
    ///         expects. Pure reassembly of the three immutables above -- there is
    ///         no separate storage slot for this.
    function nodeSet() public view returns (address[3] memory) {
        return [node1, node2, node3];
    }

    /// @dev Packs the two on-chain-read "actual" values so `recordVerification`
    ///      only needs one local for them (avoids "stack too deep" without
    ///      `--via-ir`, which this project does not build with).
    struct ActualState {
        bool filtered;
        uint256 multiplier;
    }

    /// @dev Split into two functions (filter-only, then multiplier-only) so
    ///      `recordVerification` can revert on the filter mismatch BEFORE
    ///      ever touching `tokenAddress` -- filter-check runs first, always.
    function _readActualStateFilterOnly(bytes32 txHash) internal returns (ActualState memory s) {
        (bool okFilter, bytes memory retFilter) =
            FILTER_PRECOMPILE.staticcall(abi.encodeWithSelector(IS_FILTERED_SELECTOR, txHash));
        require(okFilter && retFilter.length == 32, "FilterPrecompileCallFailed");
        s.filtered = abi.decode(retFilter, (bool));
    }

    /// @dev See `_readActualStateFilterOnly`.
    function _readActualMultiplier(address tokenAddress) internal returns (uint256 multiplier) {
        (bool okMult, bytes memory retMult) = tokenAddress.staticcall(abi.encodeWithSelector(UI_MULTIPLIER_SELECTOR));
        if (!okMult || retMult.length != 32) revert NotERC8056Token(tokenAddress);
        multiplier = abi.decode(retMult, (uint256));
    }

    /// @notice Record one verified event, posting `msg.value` as its bond, gated
    ///         by 2-of-3 node consensus instead of V1's single relayer. Reverts
    ///         if `eventHash` was already recorded -- records are immutable once
    ///         written by design: this is the core trust guarantee of the registry.
    ///         Also cross-validates the relayer's claims against what the chain
    ///         itself reports RIGHT NOW: `claimedFiltered` against
    ///         `isTransactionFiltered(txHash)` on the ArbOS precompile (checked
    ///         first), then `claimedMultiplier` against `tokenAddress.uiMultiplier()`
    ///         (checked second) -- a mismatch on either reverts
    ///         (`FilterCheckMismatch`/`MultiplierMismatch`) before any state is
    ///         touched, and what gets written to `verifications[txHash]` is the
    ///         on-chain `actual*` values this function itself just read, never
    ///         the relayer-submitted `claimed*` ones. See
    ///         docs/recordVerification-checklist.md for the operational
    ///         implication: claimed values must be freshly re-queried
    ///         immediately before submission, not reused from an earlier
    ///         off-chain snapshot.
    /// @param signatures 2-of-3 ECDSA signatures (order does not matter, extra
    ///        signatures beyond 3 are wasted gas but not an error) over
    ///        `keccak256(abi.encode(txHash, tokenAddress, oldMultiplier, newMultiplier,
    ///        claimedFiltered, claimedMultiplier, referenceModelHash, address(this),
    ///        block.chainid))`.
    function recordVerification(
        bytes32 txHash,
        address tokenAddress,
        bool claimedFiltered,
        uint256 claimedMultiplier,
        uint256 oldMultiplier,
        uint256 newMultiplier,
        bytes32 referenceModelHash,
        bytes[] calldata signatures
    ) external payable {
        // --- filter-check: claimed vs actual, checked first --------------- //
        ActualState memory actual = _readActualStateFilterOnly(txHash);
        if (actual.filtered != claimedFiltered) {
            revert FilterCheckMismatch(txHash, claimedFiltered, actual.filtered);
        }

        // --- multiplier cross-check: claimed vs actual --------------------- //
        actual.multiplier = _readActualMultiplier(tokenAddress);
        if (actual.multiplier != claimedMultiplier) {
            revert MultiplierMismatch(tokenAddress, claimedMultiplier, actual.multiplier);
        }

        if (tokenAddress == address(0)) revert ZeroAddress();
        if (verifications[txHash].recordedAt != 0) revert AlreadyRecorded(txHash);
        if (msg.value < requiredBond) revert InsufficientBond(requiredBond, msg.value);

        bytes32 msgHash = keccak256(
            abi.encode(
                txHash,
                tokenAddress,
                oldMultiplier,
                newMultiplier,
                claimedFiltered,
                claimedMultiplier,
                referenceModelHash,
                address(this),
                block.chainid
            )
        );
        (bool passed, uint256 validCount,) =
            IConsensusVerifier(consensusVerifier).verifyConsensus(msgHash, signatures, nodeSet(), CONSENSUS_THRESHOLD);
        if (!passed) revert ConsensusNotReached(validCount, CONSENSUS_THRESHOLD);

        verifications[txHash] = Verification({
            token: tokenAddress,
            oldMultiplier: oldMultiplier,
            newMultiplier: actual.multiplier,
            wasFiltered: actual.filtered,
            referenceModelHash: referenceModelHash,
            recordedAt: block.timestamp,
            bond: msg.value,
            recordedBy: msg.sender
        });
        latestVerificationForToken[tokenAddress] = txHash;

        emit VerificationRecorded(txHash, tokenAddress, actual.filtered);
    }

    /// @notice Flag a recorded event as disputed -- e.g. the off-chain Reference
    ///         Model (module 5) no longer agrees with what's on-chain. Gated by
    ///         the same 2-of-3 node consensus as `recordVerification` and
    ///         `resolveChallenge` (previously `onlyOwner`; V1's `relayer` half
    ///         of `onlyRelayerOrOwner` no longer exists). Permanent once set,
    ///         same as every other record in this registry.
    /// @param signatures 2-of-3 ECDSA signatures over
    ///        `keccak256(abi.encode(REPORT_DISCREPANCY_TAG, eventHash, reason, address(this), block.chainid))`.
    ///        `REPORT_DISCREPANCY_TAG` is required specifically because this
    ///        function's argument shape is not otherwise distinguishable from
    ///        a coincidental re-encoding under another function's digest.
    function reportDiscrepancy(bytes32 eventHash, string calldata reason, bytes[] calldata signatures) external {
        if (verifications[eventHash].recordedAt == 0) revert NotVerified(eventHash);

        bytes32 msgHash = keccak256(abi.encode(REPORT_DISCREPANCY_TAG, eventHash, reason, address(this), block.chainid));
        (bool passed, uint256 validCount,) =
            IConsensusVerifier(consensusVerifier).verifyConsensus(msgHash, signatures, nodeSet(), CONSENSUS_THRESHOLD);
        if (!passed) revert ConsensusNotReached(validCount, CONSENSUS_THRESHOLD);

        hasDiscrepancy[eventHash] = true;
        emit Discrepancy(eventHash, reason);
    }

    /// @notice Challenge a record within its challenge window by matching its bond.
    ///         Unchanged from V1: anyone may challenge, not just consensus nodes.
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

    /// @notice Decide an outstanding challenge, gated by 2-of-3 node consensus
    ///         instead of V1's single-owner human judgment. `challengerWins = true`
    ///         sends the relayer's bond plus the challenger's own bond to the
    ///         challenger (the recorder's bond is slashed). `challengerWins = false`
    ///         sends the recorder's bond plus the challenger's forfeited bond to
    ///         the recorder instead. Either way, both bonds are always accounted
    ///         for and credited to exactly one party via `pendingWithdrawals` --
    ///         pull payment, not a direct transfer, so this function itself makes
    ///         no external call.
    /// @param signatures 2-of-3 ECDSA signatures over
    ///        `keccak256(abi.encode(eventHash, challengerWins, address(this), block.chainid))`.
    ///        `eventHash` doubles as this challenge's id (see the `challenges`
    ///        mapping NatSpec above).
    function resolveChallenge(bytes32 eventHash, bool challengerWins, bytes[] calldata signatures) external {
        Challenge storage c = challenges[eventHash];
        if (c.challenger == address(0) || c.resolved) revert NoActiveChallenge();

        bytes32 msgHash = keccak256(abi.encode(eventHash, challengerWins, address(this), block.chainid));
        (bool passed, uint256 validCount,) =
            IConsensusVerifier(consensusVerifier).verifyConsensus(msgHash, signatures, nodeSet(), CONSENSUS_THRESHOLD);
        if (!passed) revert ConsensusNotReached(validCount, CONSENSUS_THRESHOLD);

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

    /// @notice Let whoever posted a record's bond reclaim it once the challenge
    ///         window has passed with no challenge ever filed (or the only one
    ///         filed already resolved). Without this, every unchallenged bond --
    ///         the overwhelmingly common case -- would be permanently stuck in
    ///         the contract with no way out. Unchanged from V1: no consensus
    ///         needed, this only ever returns funds to whoever already posted them.
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
