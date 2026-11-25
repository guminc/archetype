// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IMintPricing {
    function getQuote(uint256 sold, uint256 quantity) external view returns (uint256 totalCost);
}
