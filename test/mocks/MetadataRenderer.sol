// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ArchetypeErc721a} from "../../src/ERC721a/ArchetypeErc721a.sol";
import {IMetadataRenderer} from "../../src/ERC721a/IMetadataRenderer.sol";
import {LibString} from "solady/src/utils/LibString.sol";

contract MetadataRenderer is IMetadataRenderer {
    error RenderingFailed();

    bool public revealed;
    bool public failing;

    function reveal() external {
        revealed = true;
    }

    function revealAndRefresh(ArchetypeErc721a collection, uint256 fromId, uint256 toId) external {
        revealed = true;
        collection.refreshMetadata(fromId, toId);
    }

    function fail() external {
        failing = true;
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        if (failing) revert RenderingFailed();
        return string.concat(revealed ? "revealed/" : "hidden/", LibString.toString(tokenId));
    }
}

contract MalformedMetadataRenderer {
    function tokenURI(uint256) external pure returns (uint256) {
        return 1;
    }
}
