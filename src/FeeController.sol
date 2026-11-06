// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract FeeController {
    address public immutable admin;
    uint256 public feeBps;

    error NotAdmin();

    event FeeChanged(uint256 newFeeBps);

    constructor(address admin_) {
        admin = admin_;
    }

    function setFee(uint256 newFeeBps) external {
        if (msg.sender != admin) revert NotAdmin();
        feeBps = newFeeBps;
        emit FeeChanged(newFeeBps);
    }
}
