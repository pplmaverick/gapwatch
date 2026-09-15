// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {GapwatchRegistryV2} from "../src/GapwatchRegistryV2.sol";
import {ConsensusVerifierMock} from "../src/ConsensusVerifierMock.sol";

/// @notice Drives random but always-well-formed sequences of
///         record / challenge / resolve / reclaim / withdraw / time-warp
///         against the registry. Every consensus-gated call is signed with a
///         real 2-of-3 quorum, so the fuzzer explores the *state machine*
///         rather than bouncing off signature checks.
contract RegistryHandler is Test {
    GapwatchRegistryV2 public registry;

    uint256 internal node1Pk;
    uint256 internal node2Pk;
    uint256 internal node3Pk;

    address[] public actors;
    bytes32[] public eventHashes;
    mapping(bytes32 => address) public tokenOf;

    /// Total ETH ever sent into the registry by this handler, and total ever
    /// pulled back out via withdraw(). Ghost variables for the conservation
    /// check in the invariant contract.
    uint256 public ghost_deposited;
    uint256 public ghost_withdrawn;

    constructor(GapwatchRegistryV2 _registry, uint256 _pk1, uint256 _pk2, uint256 _pk3) {
        registry = _registry;
        node1Pk = _pk1;
        node2Pk = _pk2;
        node3Pk = _pk3;

        actors.push(makeAddr("inv_actor_0"));
        actors.push(makeAddr("inv_actor_1"));
        actors.push(makeAddr("inv_actor_2"));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function eventCount() external view returns (uint256) {
        return eventHashes.length;
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// Picks two of the three node keys, so different quorums get exercised.
    function _quorum(bytes32 digest, uint256 seed) internal view returns (bytes[] memory sigs) {
        sigs = new bytes[](2);
        uint256 pick = seed % 3;
        if (pick == 0) {
            sigs[0] = _sign(node1Pk, digest);
            sigs[1] = _sign(node2Pk, digest);
        } else if (pick == 1) {
            sigs[0] = _sign(node2Pk, digest);
            sigs[1] = _sign(node3Pk, digest);
        } else {
            sigs[0] = _sign(node1Pk, digest);
            sigs[1] = _sign(node3Pk, digest);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function record(uint256 seed, uint256 bondSeed) external {
        bytes32 eventHash = keccak256(abi.encode("inv-ev", seed));
        address token = address(uint160(uint256(keccak256(abi.encode("inv-tok", seed % 4))) | 1));
        uint256 bond = bound(bondSeed, registry.requiredBond(), registry.requiredBond() + 3 ether);
        address actor = _actor(seed);

        bytes32 digest = keccak256(
            abi.encode(eventHash, token, uint256(1e18), uint256(2e18), false, bytes32(0), address(registry), block.chainid)
        );
        bytes[] memory sigs = _quorum(digest, seed);

        vm.deal(actor, actor.balance + bond);
        vm.prank(actor);
        try registry.recordVerification{value: bond}(eventHash, token, 1e18, 2e18, false, bytes32(0), sigs) {
            eventHashes.push(eventHash);
            tokenOf[eventHash] = token;
            ghost_deposited += bond;
        } catch {}
    }

    function challenge(uint256 idxSeed, uint256 amountSeed, uint256 actorSeed) external {
        if (eventHashes.length == 0) return;
        bytes32 eventHash = eventHashes[idxSeed % eventHashes.length];
        GapwatchRegistryV2.Verification memory v = registry.getVerification(eventHash);
        if (v.bond == 0) return;

        uint256 amount = bound(amountSeed, v.bond, v.bond + 2 ether);
        address actor = _actor(actorSeed);

        vm.deal(actor, actor.balance + amount);
        vm.prank(actor);
        try registry.challenge{value: amount}(eventHash) {
            ghost_deposited += amount;
        } catch {}
    }

    function resolve(uint256 idxSeed, bool outcome, uint256 quorumSeed) external {
        if (eventHashes.length == 0) return;
        bytes32 eventHash = eventHashes[idxSeed % eventHashes.length];

        bytes32 digest = keccak256(abi.encode(eventHash, outcome, address(registry), block.chainid));
        bytes[] memory sigs = _quorum(digest, quorumSeed);

        try registry.resolveChallenge(eventHash, outcome, sigs) {} catch {}
    }

    function reclaim(uint256 idxSeed) external {
        if (eventHashes.length == 0) return;
        bytes32 eventHash = eventHashes[idxSeed % eventHashes.length];
        try registry.reclaimBond(eventHash) {} catch {}
    }

    function withdraw(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        uint256 before = actor.balance;
        vm.prank(actor);
        try registry.withdraw() {
            ghost_withdrawn += actor.balance - before;
        } catch {}
    }

    function warp(uint256 secondsAhead) external {
        vm.warp(block.timestamp + bound(secondsAhead, 1, 30 days));
    }

    /// Exercises the owner's ability to move the global window underneath
    /// records that already exist.
    function moveWindow(uint256 windowSeed) external {
        uint256 newWindow = bound(windowSeed, 0, registry.MAX_CHALLENGE_WINDOW());
        try registry.setChallengeWindow(newWindow) {} catch {}
    }
}

contract GapwatchRegistryV2InvariantTest is Test {
    GapwatchRegistryV2 registry;
    ConsensusVerifierMock verifier;
    RegistryHandler handler;

    function setUp() public {
        (address n1, uint256 pk1) = makeAddrAndKey("invnode1");
        (address n2, uint256 pk2) = makeAddrAndKey("invnode2");
        (address n3, uint256 pk3) = makeAddrAndKey("invnode3");

        verifier = new ConsensusVerifierMock();
        registry = new GapwatchRegistryV2([n1, n2, n3], address(verifier), 0.001 ether, 7 days);

        handler = new RegistryHandler(registry, pk1, pk2, pk3);
        // The handler needs to be the owner to exercise setChallengeWindow.
        registry.transferOwnership(address(handler));

        targetContract(address(handler));
    }

    /// Core solvency property: the registry must always hold at least enough
    /// ETH to honour every credited-but-unwithdrawn balance.
    function invariant_solvency() public view {
        uint256 owed;
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            owed += registry.pendingWithdrawals(handler.actors(i));
        }
        assertGe(address(registry).balance, owed, "registry cannot cover pendingWithdrawals");
    }

    /// Stronger conservation property: ETH in minus ETH out equals what the
    /// contract still holds -- no wei is created or destroyed by the state
    /// machine.
    function invariant_ethConservation() public view {
        assertEq(
            address(registry).balance,
            handler.ghost_deposited() - handler.ghost_withdrawn(),
            "deposited - withdrawn != balance"
        );
    }

    /// Non-vacuity probe: prints how deep the fuzzer actually got, so a
    /// green invariant run cannot be mistaken for "every call reverted early
    /// and nothing was ever exercised".
    function afterInvariant() public {
        emit log_named_uint("events recorded", handler.eventCount());
        emit log_named_uint("total ETH deposited (wei)", handler.ghost_deposited());
        emit log_named_uint("total ETH withdrawn (wei)", handler.ghost_withdrawn());
        emit log_named_uint("registry balance (wei)", address(registry).balance);
        uint256 owed;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            owed += registry.pendingWithdrawals(handler.actors(i));
        }
        emit log_named_uint("outstanding pendingWithdrawals (wei)", owed);
    }

    /// Every bond/challenge deposit is either still locked in an open record
    /// or credited to exactly one party -- checked here as: credited amounts
    /// never exceed everything ever deposited.
    function invariant_creditedNeverExceedsDeposited() public view {
        uint256 owed;
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            owed += registry.pendingWithdrawals(handler.actors(i));
        }
        assertLe(owed + handler.ghost_withdrawn(), handler.ghost_deposited(), "credited more than deposited");
    }
}
