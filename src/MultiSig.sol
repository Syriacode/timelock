// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MultiSig {
    struct Transaction {
        address to;
        uint256 value;
        bytes data;
        bool executed;
    }

    uint256 public constant THRESHOLD = 2;

    address[3] public owners;
    mapping(address => bool) public isOwner;
    Transaction[] private transactions;
    mapping(uint256 => mapping(address => bool)) public hasApproved;

    event Deposited(address indexed sender, uint256 amount);
    event Submitted(uint256 indexed txId, address indexed owner, address indexed to, uint256 value);
    event Approved(uint256 indexed txId, address indexed owner);
    event Revoked(uint256 indexed txId, address indexed owner);
    event Executed(uint256 indexed txId);
    event OwnerReplaced(address indexed oldOwner, address indexed newOwner);

    error NotSelf();
    error NotOwner();
    error ZeroAddress();
    error DuplicateOwner(address owner);
    error TxNotFound(uint256 txId);
    error AlreadyExecuted(uint256 txId);
    error AlreadyApproved(uint256 txId);
    error NotApproved(uint256 txId);
    error NotEnoughApprovals(uint256 have, uint256 need);
    error ExecutionFailed();

    modifier onlyOwner() {
        if (!isOwner[msg.sender]) revert NotOwner();
        _;
    }

    modifier txExists(uint256 txId) {
        if (txId >= transactions.length) revert TxNotFound(txId);
        _;
    }

    modifier notExecuted(uint256 txId) {
        if (transactions[txId].executed) revert AlreadyExecuted(txId);
        _;
    }

    constructor(address[3] memory initialOwners) {
        for (uint256 i = 0; i < 3; i++) {
            address owner = initialOwners[i];
            if (owner == address(0)) revert ZeroAddress();
            if (isOwner[owner]) revert DuplicateOwner(owner);
            isOwner[owner] = true;
            owners[i] = owner;
        }
    }

    receive() external payable {
        emit Deposited(msg.sender, msg.value);
    }

    function submit(address to, uint256 value, bytes calldata data) external onlyOwner returns (uint256 txId) {
        if (to == address(0)) revert ZeroAddress();
        txId = transactions.length;
        transactions.push(Transaction({to: to, value: value, data: data, executed: false}));
        emit Submitted(txId, msg.sender, to, value);
    }

    function approve(uint256 txId) external onlyOwner txExists(txId) notExecuted(txId) {
        if (hasApproved[txId][msg.sender]) revert AlreadyApproved(txId);
        hasApproved[txId][msg.sender] = true;
        emit Approved(txId, msg.sender);
    }

    function revoke(uint256 txId) external onlyOwner txExists(txId) notExecuted(txId) {
        if (!hasApproved[txId][msg.sender]) revert NotApproved(txId);
        hasApproved[txId][msg.sender] = false;
        emit Revoked(txId, msg.sender);
    }

    function replaceOwner(address oldOwner, address newOwner) external {
        if (msg.sender != address(this)) revert NotSelf();
        if (newOwner == address(0)) revert ZeroAddress();
        if (!isOwner[oldOwner]) revert NotOwner();
        if (isOwner[newOwner]) revert DuplicateOwner(newOwner);

        for (uint256 i = 0; i < 3; i++) {
            if (owners[i] == oldOwner) {
                owners[i] = newOwner;
                break;
            }
        }
        isOwner[oldOwner] = false;
        isOwner[newOwner] = true;
        emit OwnerReplaced(oldOwner, newOwner);
    }

    function execute(uint256 txId) external onlyOwner txExists(txId) notExecuted(txId) {
        Transaction storage t = transactions[txId];

        // Checks
        uint256 have = approvalCount(txId);
        if (have < THRESHOLD) revert NotEnoughApprovals(have, THRESHOLD);

        // Effects
        t.executed = true;
        emit Executed(txId);

        // Interactions
        (bool ok,) = t.to.call{value: t.value}(t.data);
        if (!ok) revert ExecutionFailed();
    }

    function approvalCount(uint256 txId) public view returns (uint256 count) {
        // Count only current owners, so a removed owner's old approval no longer counts.
        for (uint256 i = 0; i < 3; i++) {
            if (hasApproved[txId][owners[i]]) count++;
        }
    }

    function getTransaction(uint256 txId) external view returns (Transaction memory) {
        return transactions[txId];
    }

    function transactionCount() external view returns (uint256) {
        return transactions.length;
    }
}
