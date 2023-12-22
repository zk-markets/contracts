// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract Base {
    address public owner = address(0);  // Default

    modifier onlyOwnerOrSelf() virtual {
        require(msg.sender == owner || msg.sender == address(this), "Not authorized");
        _;
    }
}