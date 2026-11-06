// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FeeController} from "../src/FeeController.sol";
import {MultiSig} from "../src/MultiSig.sol";
import {Timelock} from "../src/Timelock.sol";

contract StackTest is Test {
    bytes32 constant SALT = bytes32(uint256(1));

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address guardian = makeAddr("guardian");
    address stranger = makeAddr("stranger");

    MultiSig multisig;
    Timelock timelock;
    FeeController fee;

    function setUp() public {
        multisig = new MultiSig([alice, bob, carol]);
        timelock = new Timelock(address(multisig), guardian, 2 days);
        fee = new FeeController(address(timelock));
    }

    function _viaMultisig(address to, bytes memory data, address first, address second) internal {
        vm.prank(first);
        uint256 txId = multisig.submit(to, 0, data);
        vm.prank(first);
        multisig.approve(txId);
        vm.prank(second);
        multisig.approve(txId);
        vm.prank(first);
        multisig.execute(txId);
    }

    function _queueFee(uint256 newFee, address first, address second)
        internal
        returns (bytes32 id, bytes memory feeData)
    {
        feeData = abi.encodeCall(FeeController.setFee, (newFee));
        _viaMultisig(address(timelock), abi.encodeCall(Timelock.queue, (address(fee), 0, feeData, SALT)), first, second);
        // MultiSig.execute discards the id that queue returns, so compute it here.
        id = timelock.getId(address(fee), 0, feeData, SALT);
    }

    function test_FeeChangesAfterDelay() public {
        (, bytes memory feeData) = _queueFee(100, alice, bob);

        vm.warp(block.timestamp + 2 days);
        vm.prank(stranger);
        timelock.execute(address(fee), 0, feeData, SALT);

        assertEq(fee.feeBps(), 100);
    }

    function test_TwoStolenKeysStoppedByGuardian() public {
        (bytes32 id, bytes memory feeData) = _queueFee(9999, bob, carol);
        uint256 readyTime = timelock.readyAt(id);

        vm.expectRevert(abi.encodeWithSelector(Timelock.NotReady.selector, id, readyTime));
        timelock.execute(address(fee), 0, feeData, SALT);

        vm.prank(guardian);
        timelock.cancel(id);

        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(abi.encodeWithSelector(Timelock.NotQueued.selector, id));
        timelock.execute(address(fee), 0, feeData, SALT);

        assertEq(fee.feeBps(), 0);
    }

    function test_MultisigCannotSkipTheTimelock() public {
        vm.prank(alice);
        uint256 txId = multisig.submit(address(fee), 0, abi.encodeCall(FeeController.setFee, (100)));
        vm.prank(alice);
        multisig.approve(txId);
        vm.prank(bob);
        multisig.approve(txId);

        vm.prank(alice);
        vm.expectRevert(MultiSig.ExecutionFailed.selector);
        multisig.execute(txId);

        assertEq(fee.feeBps(), 0);
    }
}
