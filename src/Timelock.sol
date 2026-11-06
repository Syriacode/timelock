// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Timelock {
    uint256 public constant MIN_DELAY = 1 hours;
    uint256 public constant MAX_DELAY = 30 days;
    uint256 public constant GRACE_PERIOD = 14 days;

    address public immutable admin;
    address public immutable guardian;
    uint256 public delay;

    // The time an action can run, by action ID. 0 means not queued.
    mapping(bytes32 id => uint256 time) public readyAt;

    event Queued(
        bytes32 indexed id, address indexed target, uint256 value, bytes data, bytes32 salt, uint256 readyTime
    );
    event Executed(bytes32 indexed id, address indexed target, uint256 value, bytes data);
    event Cancelled(bytes32 indexed id, address indexed by);
    event DelayChanged(uint256 oldDelay, uint256 newDelay);
    event Received(address indexed sender, uint256 amount);

    error NotAdmin();
    error NotAdminOrGuardian();
    error NotSelf();
    error ZeroAddress();
    error DelayOutOfRange(uint256 delay);
    error AlreadyQueued(bytes32 id);
    error NotQueued(bytes32 id);
    error NotReady(bytes32 id, uint256 readyTime);
    error Expired(bytes32 id, uint256 deadline);
    error ExecutionFailed();

    constructor(address admin_, address guardian_, uint256 delay_) {
        if (admin_ == address(0) || guardian_ == address(0)) revert ZeroAddress();
        if (delay_ < MIN_DELAY || delay_ > MAX_DELAY) revert DelayOutOfRange(delay_);
        admin = admin_;
        guardian = guardian_;
        delay = delay_;
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    function getId(address target, uint256 value, bytes calldata data, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(target, value, data, salt));
    }

    function queue(address target, uint256 value, bytes calldata data, bytes32 salt) external returns (bytes32 id) {
        if (msg.sender != admin) revert NotAdmin();
        if (target == address(0)) revert ZeroAddress();

        id = getId(target, value, data, salt);
        if (readyAt[id] != 0) revert AlreadyQueued(id);

        uint256 readyTime = block.timestamp + delay;
        readyAt[id] = readyTime;
        emit Queued(id, target, value, data, salt, readyTime);
    }

    function execute(address target, uint256 value, bytes calldata data, bytes32 salt) external {
        bytes32 id = getId(target, value, data, salt);
        uint256 readyTime = readyAt[id];

        // Checks
        if (readyTime == 0) revert NotQueued(id);
        if (block.timestamp < readyTime) revert NotReady(id, readyTime);
        if (block.timestamp > readyTime + GRACE_PERIOD) revert Expired(id, readyTime + GRACE_PERIOD);

        // Effects
        delete readyAt[id];
        emit Executed(id, target, value, data);

        // Interactions
        (bool ok,) = target.call{value: value}(data);
        if (!ok) revert ExecutionFailed();
    }

    function cancel(bytes32 id) external {
        if (msg.sender != admin && msg.sender != guardian) revert NotAdminOrGuardian();
        if (readyAt[id] == 0) revert NotQueued(id);

        delete readyAt[id];
        emit Cancelled(id, msg.sender);
    }

    function setDelay(uint256 newDelay) external {
        if (msg.sender != address(this)) revert NotSelf();
        if (newDelay < MIN_DELAY || newDelay > MAX_DELAY) revert DelayOutOfRange(newDelay);

        emit DelayChanged(delay, newDelay);
        delay = newDelay;
    }
}
