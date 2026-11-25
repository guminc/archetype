// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IMintCallback {
    function tokenMinted(uint256 tokenId) external;
}
