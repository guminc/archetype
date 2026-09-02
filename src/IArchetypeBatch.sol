// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IArchetypeBatch {
    function currentCaller() external view returns (address);
}
