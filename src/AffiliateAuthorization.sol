// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ECDSA} from "solady/src/utils/ECDSA.sol";

error InvalidAffiliateAuthorization();
error ExpiredAffiliateAuthorization();

library AffiliateAuthorization {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 internal constant AUTHORIZATION_TYPEHASH =
        keccak256("AffiliateAuthorization(address affiliate,address minter,uint256 deadline)");

    function validate(address affiliate, address minter, bytes calldata authorization, address affiliateSigner)
        internal
        view
    {
        if (authorization.length != 97) revert InvalidAffiliateAuthorization();

        uint256 deadline = uint256(bytes32(authorization[:32]));
        if (block.timestamp > deadline) revert ExpiredAffiliateAuthorization();

        bytes32 domainSeparator = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("Archetype"), keccak256("1"), block.chainid, address(this))
        );
        bytes32 structHash = keccak256(abi.encode(AUTHORIZATION_TYPEHASH, affiliate, minter, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        if (ECDSA.recoverCalldata(digest, authorization[32:]) != affiliateSigner) {
            revert InvalidAffiliateAuthorization();
        }
    }
}
