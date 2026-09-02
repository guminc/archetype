// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

error UnexpectedMintCurrency();
error InsufficientMintOutput();
error ExcessiveNativeValue();
error UnexpectedBurnCollection();
error UnexpectedBurnRecipient();

struct MintConstraints {
    address currency;
    uint128 maxCurrencyCost;
    uint256 maxNativeValue;
    uint256 minTotalMints;
}

struct BurnConstraints {
    MintConstraints mint;
    address burnCollection;
    address burnRecipient;
}
