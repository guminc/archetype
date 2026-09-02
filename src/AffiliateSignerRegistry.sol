// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

error InvalidAffiliateSigner();

contract AffiliateSignerRegistry is Ownable {
    address public affiliateSigner;

    event AffiliateSignerChanged(address indexed previousSigner, address indexed newSigner);

    constructor(address initialOwner, address initialSigner) Ownable(initialOwner) {
        _setAffiliateSigner(initialSigner);
    }

    function setAffiliateSigner(address newSigner) external onlyOwner {
        _setAffiliateSigner(newSigner);
    }

    function _setAffiliateSigner(address newSigner) internal {
        if (newSigner == address(0)) revert InvalidAffiliateSigner();
        address previousSigner = affiliateSigner;
        affiliateSigner = newSigner;
        emit AffiliateSignerChanged(previousSigner, newSigner);
    }
}
