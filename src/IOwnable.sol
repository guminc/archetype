// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Interface for contracts that implement owner() function
interface IOwnable {
    function owner() external view returns (address);
}

