// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Timelock} from "../src/Timelock.sol";

contract Box {
    uint256 public number;

    function store(uint256 n) external {
        number = n;
    }

    function fail() external pure {
        revert("nope");
    }
}

contract ReentrantPayee {
    Timelock public immutable timelock;
    bytes32 public immutable salt;

    constructor(Timelock timelock_, bytes32 salt_) {
        timelock = timelock_;
        salt = salt_;
    }

    receive() external payable {
        if (address(timelock).balance >= 1 ether) {
            timelock.execute(address(this), 1 ether, "", salt);
        }
    }
}

contract TimelockTest is Test {
    uint256 constant DELAY = 2 days;
    bytes32 constant SALT = bytes32(uint256(1));

    address admin = makeAddr("admin");
    address guardian = makeAddr("guardian");
    address stranger = makeAddr("stranger");
    bytes data = abi.encodeCall(Box.store, (42));

    Timelock timelock;
    Box box;

    function setUp() public {
        timelock = new Timelock(admin, guardian, DELAY);
        box = new Box();
    }

    function _queue() internal returns (bytes32) {
        vm.prank(admin);
        return timelock.queue(address(box), 0, data, SALT);
    }

    function test_QueueStoresReadyTimeAndEmits() public {
        bytes32 expectedId = timelock.getId(address(box), 0, data, SALT);
        uint256 expectedReadyTime = block.timestamp + DELAY;

        vm.expectEmit(address(timelock));
        emit Timelock.Queued(expectedId, address(box), 0, data, SALT, expectedReadyTime);
        bytes32 id = _queue();

        assertEq(id, expectedId);
        assertEq(timelock.readyAt(id), expectedReadyTime);
    }

    function test_RevertWhen_StrangerQueues() public {
        vm.prank(stranger);
        vm.expectRevert(Timelock.NotAdmin.selector);
        timelock.queue(address(box), 0, data, SALT);
    }

    function test_RevertWhen_GuardianQueues() public {
        vm.prank(guardian);
        vm.expectRevert(Timelock.NotAdmin.selector);
        timelock.queue(address(box), 0, data, SALT);
    }

    function test_RevertWhen_QueuedTwice() public {
        bytes32 id = _queue();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Timelock.AlreadyQueued.selector, id));
        timelock.queue(address(box), 0, data, SALT);
    }

    function test_SameActionWithNewSaltIsSeparate() public {
        bytes32 first = _queue();

        vm.prank(admin);
        bytes32 second = timelock.queue(address(box), 0, data, bytes32(uint256(2)));

        assertNotEq(first, second);
    }

    function test_RevertWhen_ExecutedOneSecondEarly() public {
        bytes32 id = _queue();
        uint256 readyTime = timelock.readyAt(id);

        vm.warp(readyTime - 1);
        vm.expectRevert(abi.encodeWithSelector(Timelock.NotReady.selector, id, readyTime));
        timelock.execute(address(box), 0, data, SALT);
    }

    function test_ExecutesExactlyAtReadyTime() public {
        bytes32 id = _queue();
        uint256 readyTime = timelock.readyAt(id);

        vm.warp(readyTime);
        vm.prank(stranger);
        timelock.execute(address(box), 0, data, SALT);

        assertEq(box.number(), 42);
        assertEq(timelock.readyAt(id), 0);
    }

    function test_ExecutesOnLastSecondOfGracePeriod() public {
        bytes32 id = _queue();
        uint256 deadline = timelock.readyAt(id) + timelock.GRACE_PERIOD();

        vm.warp(deadline);
        timelock.execute(address(box), 0, data, SALT);

        assertEq(box.number(), 42);
    }

    function test_RevertWhen_ExecutedAfterGracePeriod() public {
        bytes32 id = _queue();
        uint256 deadline = timelock.readyAt(id) + timelock.GRACE_PERIOD();

        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(Timelock.Expired.selector, id, deadline));
        timelock.execute(address(box), 0, data, SALT);
    }

    function test_RevertWhen_NeverQueued() public {
        bytes32 id = timelock.getId(address(box), 0, data, SALT);

        vm.expectRevert(abi.encodeWithSelector(Timelock.NotQueued.selector, id));
        timelock.execute(address(box), 0, data, SALT);
    }

    function test_RevertWhen_ExecutedTwice() public {
        bytes32 id = _queue();

        vm.warp(timelock.readyAt(id));
        timelock.execute(address(box), 0, data, SALT);

        vm.expectRevert(abi.encodeWithSelector(Timelock.NotQueued.selector, id));
        timelock.execute(address(box), 0, data, SALT);
    }

    function test_RevertWhen_DataDiffersFromQueued() public {
        bytes32 queuedId = _queue();
        bytes memory swapped = abi.encodeCall(Box.store, (9999));
        bytes32 swappedId = timelock.getId(address(box), 0, swapped, SALT);

        vm.warp(timelock.readyAt(queuedId));
        vm.expectRevert(abi.encodeWithSelector(Timelock.NotQueued.selector, swappedId));
        timelock.execute(address(box), 0, swapped, SALT);
    }

    function test_RevertWhen_ValueDiffersFromQueued() public {
        bytes32 queuedId = _queue();
        vm.deal(address(timelock), 1 ether);
        bytes32 changedId = timelock.getId(address(box), 1 ether, data, SALT);

        vm.warp(timelock.readyAt(queuedId));
        vm.expectRevert(abi.encodeWithSelector(Timelock.NotQueued.selector, changedId));
        timelock.execute(address(box), 1 ether, data, SALT);
    }

    function test_RevertWhen_TargetDiffersFromQueued() public {
        bytes32 queuedId = _queue();
        Box otherBox = new Box();
        bytes32 changedId = timelock.getId(address(otherBox), 0, data, SALT);

        vm.warp(timelock.readyAt(queuedId));
        vm.expectRevert(abi.encodeWithSelector(Timelock.NotQueued.selector, changedId));
        timelock.execute(address(otherBox), 0, data, SALT);
    }

    function test_RevertWhen_SaltDiffersFromQueued() public {
        bytes32 queuedId = _queue();
        bytes32 otherSalt = bytes32(uint256(2));
        bytes32 changedId = timelock.getId(address(box), 0, data, otherSalt);

        vm.warp(timelock.readyAt(queuedId));
        vm.expectRevert(abi.encodeWithSelector(Timelock.NotQueued.selector, changedId));
        timelock.execute(address(box), 0, data, otherSalt);
    }

    function test_RevertWhen_SelectorDiffersFromQueued() public {
        bytes32 queuedId = _queue();
        // Same length as the queued call, but it calls a different function.
        bytes memory swapped = abi.encodePacked(Box.fail.selector, uint256(42));
        bytes32 swappedId = timelock.getId(address(box), 0, swapped, SALT);

        vm.warp(timelock.readyAt(queuedId));
        vm.expectRevert(abi.encodeWithSelector(Timelock.NotQueued.selector, swappedId));
        timelock.execute(address(box), 0, swapped, SALT);
    }

    function test_MismatchedExecuteLeavesQueuedActionIntact() public {
        bytes32 queuedId = _queue();
        uint256 readyTime = timelock.readyAt(queuedId);
        bytes memory swapped = abi.encodeCall(Box.store, (9999));
        bytes32 swappedId = timelock.getId(address(box), 0, swapped, SALT);

        vm.warp(readyTime);
        vm.expectRevert(abi.encodeWithSelector(Timelock.NotQueued.selector, swappedId));
        timelock.execute(address(box), 0, swapped, SALT);

        assertEq(box.number(), 0);
        assertEq(timelock.readyAt(queuedId), readyTime);

        timelock.execute(address(box), 0, data, SALT);
        assertEq(box.number(), 42);
    }

    function test_FailedCallStaysQueuedAndRetryable() public {
        bytes memory failData = abi.encodeCall(Box.fail, ());

        vm.prank(admin);
        bytes32 id = timelock.queue(address(box), 0, failData, SALT);
        uint256 readyTime = timelock.readyAt(id);

        vm.warp(readyTime);
        vm.expectRevert(Timelock.ExecutionFailed.selector);
        timelock.execute(address(box), 0, failData, SALT);

        assertEq(timelock.readyAt(id), readyTime);
    }

    function test_GuardianCancels() public {
        bytes32 id = _queue();

        vm.prank(guardian);
        timelock.cancel(id);

        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(abi.encodeWithSelector(Timelock.NotQueued.selector, id));
        timelock.execute(address(box), 0, data, SALT);
    }

    function test_AdminCancels() public {
        bytes32 id = _queue();

        vm.prank(admin);
        timelock.cancel(id);

        assertEq(timelock.readyAt(id), 0);
    }

    function test_RevertWhen_StrangerCancels() public {
        bytes32 id = _queue();

        vm.prank(stranger);
        vm.expectRevert(Timelock.NotAdminOrGuardian.selector);
        timelock.cancel(id);
    }

    function test_RevertWhen_SetDelayCalledDirectly() public {
        vm.prank(admin);
        vm.expectRevert(Timelock.NotSelf.selector);
        timelock.setDelay(3 days);
    }

    function test_SetDelayGoesThroughTheQueue() public {
        bytes memory setDelayData = abi.encodeCall(Timelock.setDelay, (3 days));

        vm.prank(admin);
        bytes32 id = timelock.queue(address(timelock), 0, setDelayData, SALT);

        vm.warp(timelock.readyAt(id));
        timelock.execute(address(timelock), 0, setDelayData, SALT);

        assertEq(timelock.delay(), 3 days);
    }

    function test_RevertWhen_NewDelayOutOfRange() public {
        bytes memory setDelayData = abi.encodeCall(Timelock.setDelay, (1 minutes));

        vm.prank(admin);
        bytes32 id = timelock.queue(address(timelock), 0, setDelayData, SALT);

        vm.warp(timelock.readyAt(id));
        vm.expectRevert(Timelock.ExecutionFailed.selector);
        timelock.execute(address(timelock), 0, setDelayData, SALT);
    }

    function test_RevertWhen_ConstructorDelayOutOfRange() public {
        vm.expectRevert(abi.encodeWithSelector(Timelock.DelayOutOfRange.selector, 1 minutes));
        new Timelock(admin, guardian, 1 minutes);
    }

    function test_ReentrantPayeeCannotDrain() public {
        vm.deal(address(timelock), 5 ether);
        ReentrantPayee payee = new ReentrantPayee(timelock, SALT);

        vm.prank(admin);
        bytes32 id = timelock.queue(address(payee), 1 ether, "", SALT);

        vm.warp(timelock.readyAt(id));
        try timelock.execute(address(payee), 1 ether, "", SALT) {} catch {}

        assertEq(address(payee).balance + address(timelock).balance, 5 ether);
        assertGe(address(timelock).balance, 4 ether, "timelock drained");
    }

    function testFuzz_RevertWhen_StoredNumberDiffersFromQueued(uint256 n) public {
        vm.assume(n != 42);
        bytes32 queuedId = _queue();
        bytes memory swapped = abi.encodeCall(Box.store, (n));
        bytes32 swappedId = timelock.getId(address(box), 0, swapped, SALT);

        vm.warp(timelock.readyAt(queuedId));
        vm.expectRevert(abi.encodeWithSelector(Timelock.NotQueued.selector, swappedId));
        timelock.execute(address(box), 0, swapped, SALT);
    }

    function testFuzz_NeverExecutesBeforeReadyTime(uint256 wait) public {
        wait = bound(wait, 0, DELAY - 1);
        bytes32 id = _queue();
        uint256 readyTime = timelock.readyAt(id);

        vm.warp(block.timestamp + wait);
        vm.expectRevert(abi.encodeWithSelector(Timelock.NotReady.selector, id, readyTime));
        timelock.execute(address(box), 0, data, SALT);
    }
}
