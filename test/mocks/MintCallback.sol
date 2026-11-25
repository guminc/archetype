// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ArchetypeErc721a} from "../../src/ERC721a/ArchetypeErc721a.sol";
import {IMintCallback} from "../../src/ERC721a/IMintCallback.sol";
import {IERC721Receiver} from "openzeppelin-v4/token/ERC721/IERC721Receiver.sol";

contract MintCallback is IMintCallback, IERC721Receiver {
    error CommitmentFailed();

    ArchetypeErc721a public immutable collection;
    uint256 public count;
    uint256 public received;
    uint256 public failAt;
    mapping(uint256 => address) public owners;
    bytes[] public attempts;
    bytes[] public failures;

    constructor(ArchetypeErc721a collection_) {
        collection = collection_;
    }

    function refreshMetadata(uint256 fromId, uint256 toId) external {
        collection.refreshMetadata(fromId, toId);
    }

    function setFailAt(uint256 tokenId) external {
        failAt = tokenId;
    }

    function addAttempt(bytes calldata data) external {
        attempts.push(data);
    }

    function tokenMinted(uint256 tokenId) external {
        require(msg.sender == address(collection));
        if (tokenId == failAt) revert CommitmentFailed();
        require(owners[tokenId] == address(0));
        owners[tokenId] = collection.ownerOf(tokenId);
        ++count;
        if (tokenId == 1) {
            for (uint256 i; i < attempts.length; ++i) {
                (bool success, bytes memory result) = address(collection).call(attempts[i]);
                require(!success);
                failures.push(result);
            }
        }
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        require(msg.sender == address(collection));
        require(owners[tokenId] == address(this));
        require(count == collection.totalSupply());
        ++received;
        return IERC721Receiver.onERC721Received.selector;
    }
}
