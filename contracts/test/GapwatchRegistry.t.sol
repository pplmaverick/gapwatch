// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GapwatchRegistry} from "../src/GapwatchRegistry.sol";

contract GapwatchRegistryTest is Test {
    GapwatchRegistry registry;

    address owner = address(this);
    address relayer = makeAddr("relayer");
    address stranger = makeAddr("stranger");
    address token = makeAddr("token");

    bytes32 constant EVENT_HASH = keccak256("nvda-event-1");

    function setUp() public {
        registry = new GapwatchRegistry(relayer);
    }

    function test_recordVerification_happyPath() public {
        vm.prank(relayer);
        registry.recordVerification(
            EVENT_HASH, token, 1e18, 1000775159164630595, false, bytes32(uint256(0xabcd))
        );

        assertTrue(registry.isVerified(EVENT_HASH));

        GapwatchRegistry.Verification memory v = registry.getVerification(EVENT_HASH);
        assertEq(v.token, token);
        assertEq(v.oldMultiplier, 1e18);
        assertEq(v.newMultiplier, 1000775159164630595);
        assertEq(v.wasFiltered, false);
        assertEq(v.referenceModelHash, bytes32(uint256(0xabcd)));
        assertEq(v.recordedAt, block.timestamp);
    }

    function test_recordVerification_emitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit GapwatchRegistry.VerificationRecorded(EVENT_HASH, token, false);

        vm.prank(relayer);
        registry.recordVerification(EVENT_HASH, token, 1e18, 1e18, false, bytes32(0));
    }

    function test_recordVerification_revertsForNonRelayer() public {
        vm.prank(stranger);
        vm.expectRevert(GapwatchRegistry.NotRelayer.selector);
        registry.recordVerification(EVENT_HASH, token, 1e18, 1e18, false, bytes32(0));
    }

    function test_recordVerification_revertsOnDoubleRecord() public {
        vm.startPrank(relayer);
        registry.recordVerification(EVENT_HASH, token, 1e18, 1e18, false, bytes32(0));

        vm.expectRevert(
            abi.encodeWithSelector(GapwatchRegistry.AlreadyRecorded.selector, EVENT_HASH)
        );
        registry.recordVerification(EVENT_HASH, token, 1e18, 2e18, true, bytes32(uint256(1)));
        vm.stopPrank();
    }

    function test_setRelayer_ownerCanUpdate() public {
        address newRelayer = makeAddr("newRelayer");
        registry.setRelayer(newRelayer);
        assertEq(registry.relayer(), newRelayer);
    }

    function test_setRelayer_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        registry.setRelayer(makeAddr("newRelayer"));
    }

    function test_recordVerification_revertsOnZeroTokenAddress() public {
        vm.prank(relayer);
        vm.expectRevert(GapwatchRegistry.ZeroAddress.selector);
        registry.recordVerification(EVENT_HASH, address(0), 1e18, 1e18, false, bytes32(0));
    }

    function test_transferOwnership_ownerCanTransfer() public {
        address newOwner = makeAddr("newOwner");
        registry.transferOwnership(newOwner);
        assertEq(registry.owner(), newOwner);

        // new owner can now exercise onlyOwner functions; old owner cannot.
        vm.prank(newOwner);
        registry.setRelayer(makeAddr("newRelayer"));

        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this))
        );
        registry.setRelayer(makeAddr("anotherRelayer"));
    }

    function test_transferOwnership_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        registry.transferOwnership(makeAddr("newOwner"));
    }

    function test_constructor_revertsOnZeroRelayer() public {
        vm.expectRevert(GapwatchRegistry.ZeroAddress.selector);
        new GapwatchRegistry(address(0));
    }

    function test_setRelayer_revertsOnZeroAddress() public {
        vm.expectRevert(GapwatchRegistry.ZeroAddress.selector);
        registry.setRelayer(address(0));
    }

    function test_unknownEventHash_returnsFalseAndEmptyStruct_notRevert() public {
        bytes32 unknown = keccak256("never-recorded");

        assertFalse(registry.isVerified(unknown));

        GapwatchRegistry.Verification memory v = registry.getVerification(unknown);
        assertEq(v.token, address(0));
        assertEq(v.oldMultiplier, 0);
        assertEq(v.newMultiplier, 0);
        assertEq(v.wasFiltered, false);
        assertEq(v.referenceModelHash, bytes32(0));
        assertEq(v.recordedAt, 0);
    }
}
