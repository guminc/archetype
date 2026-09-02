// SPDX-License-Identifier: MIT
// ArchetypeLogic v10.0 - ERC1155
//
//        d8888                 888               888
//       d88888                 888               888
//      d88P888                 888               888
//     d88P 888 888d888 .d8888b 88888b.   .d88b.  888888 888  888 88888b.   .d88b.
//    d88P  888 888P"  d88P"    888 "88b d8P  Y8b 888    888  888 888 "88b d8P  Y8b
//   d88P   888 888    888      888  888 88888888 888    888  888 888  888 88888888
//  d8888888888 888    Y88b.    888  888 Y8b.     Y88b.  Y88b 888 888 d88P Y8b.
// d88P     888 888     "Y8888P 888  888  "Y8888   "Y888  "Y88888 88888P"   "Y8888
//                                                            888 888
//                                                       Y8b d88P 888
//                                                        "Y88P"  888

pragma solidity ^0.8.20;

import "../ArchetypePayouts.sol";
import "../IArchetypeBatch.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../AffiliateAuthorization.sol";
import {AffiliateSignerRegistry} from "../AffiliateSignerRegistry.sol";
import {MintConstraints} from "../MintConstraints.sol";
import "solady/src/utils/MerkleProofLib.sol";

error InvalidConfig();
error MintNotYetStarted();
error MintEnded();
error WalletUnauthorizedToMint();
error InsufficientEthSent();
error ExcessiveEthSent();
error Erc20BalanceTooLow();
error MaxSupplyExceeded();
error ListMaxSupplyExceeded();
error NumberOfMintsExceeded();
error MintingPaused();
error InvalidReferral();
error MaxBatchSizeExceeded();
error NotTokenOwner();
error NotPlatform();
error NotOwner();
error NotApprovedToTransfer();
error InvalidAmountOfTokens();
error WrongPassword();
error LockedForever();
error URIQueryForNonexistentToken();
error InvalidTokenId();
error MintToZeroAddress();
error NotSupported();
error MintCostOverflow();
error ExcessiveCurrencyCost();

struct Auth {
    bytes32 key;
    bytes32[] proof;
}

struct Config {
    string baseUri;
    uint32[] maxSupply; // max supply for each mintable tokenId
    uint16 maxBatchSize;
    uint16 affiliateFee; //BPS
    uint16 affiliateDiscount; //BPS
    uint16 defaultRoyalty; //BPS
}

struct PayoutConfig {
    uint16 ownerBps;
    uint16 platformBps;
    uint16 partnerBps;
    uint16 superAffiliateBps;
    address partner;
    address superAffiliate;
    address ownerAltPayout;
}

struct Options {
    bool uriLocked;
    bool maxSupplyLocked;
    bool affiliateFeeLocked;
    bool ownerAltPayoutLocked;
}

struct Invite {
    uint128 price;
    uint32 start;
    uint32 end;
    uint32 limit;
    uint32 maxSupply;
    uint32 unitSize; // mint 1 get x
    uint32[] tokenIds; // token ids mintable from this list
    address tokenAddress;
}

struct ValidationArgs {
    address owner;
    address sender;
    address affiliate;
    uint256[] quantities;
    uint256[] tokenIds;
    uint256 totalQuantity;
    uint256 listSupply;
}

struct ArchetypeAddresses {
    address platform;
    address payouts;
    address batch;
}

struct MintPayment {
    uint128 currencyCost;
    uint256 nativeValue;
    uint256 platformSurcharge;
}

struct Erc1155BatchMint {
    address[] recipients;
    uint256[] quantities;
    uint256[] tokenIds;
    address affiliate;
    bytes affiliateAuthorization;
    MintConstraints constraints;
}

uint16 constant MAXBPS = 5000; // max fee or discount is 50%
uint32 constant UINT32_MAX = 2 ** 32 - 1;

library ArchetypeLogicErc1155 {
    using SafeERC20 for IERC20;

    event Invited(bytes32 indexed key, bytes32 indexed cid);
    event Referral(address indexed affiliate, address token, uint128 wad, uint256 numMints, uint256 paymentValue);

    // calculate price based on affiliate usage and mint discounts
    function computePrice(Invite storage invite, uint16 affiliateDiscount, uint256 numTokens, bool affiliateUsed)
        public
        view
        returns (uint128)
    {
        uint256 cost = uint256(invite.price) * numTokens;

        if (affiliateUsed) {
            cost = cost - ((cost * affiliateDiscount) / 10000);
        }

        if (cost > type(uint128).max) revert MintCostOverflow();
        return uint128(cost);
    }

    function computeMintPayment(
        Invite storage invite,
        Config storage config,
        PayoutConfig storage payoutConfig,
        bytes32 key,
        uint256 paidQuantity,
        bool affiliateUsed,
        uint256 nativeMinimumFee
    ) public view returns (MintPayment memory payment) {
        payment.currencyCost = computePrice(invite, config.affiliateDiscount, paidQuantity, affiliateUsed);

        bool isPublic = isPublicInvite(invite, key);
        if (!isPublic) {
            if (invite.tokenAddress == address(0)) payment.nativeValue = payment.currencyCost;
            return payment;
        }

        uint256 minimumFee = nativeMinimumFee * paidQuantity;
        if (invite.tokenAddress != address(0)) {
            payment.nativeValue = minimumFee;
            payment.platformSurcharge = minimumFee;
            return payment;
        }

        uint256 affiliateWad = affiliateUsed ? (payment.currencyCost * config.affiliateFee) / 10000 : 0;
        uint256 platformFee = ((payment.currencyCost - affiliateWad) * payoutConfig.platformBps) / 10000;
        if (minimumFee > platformFee) payment.platformSurcharge = minimumFee - platformFee;
        payment.nativeValue = payment.currencyCost + payment.platformSurcharge;
    }

    function validateMint(
        ArchetypeAddresses memory addrs,
        Invite storage i,
        Config storage config,
        Auth calldata auth,
        mapping(address => mapping(bytes32 => uint256)) storage minted,
        uint256[] storage tokenSupply,
        bytes calldata affiliateAuthorization,
        AffiliateSignerRegistry affiliateSignerRegistry,
        ValidationArgs memory args,
        uint256 cost,
        uint256 nativeValue
    ) public view {
        address msgSender = args.sender;
        if (args.affiliate != address(0)) {
            if (args.affiliate == addrs.platform || args.affiliate == args.owner || args.affiliate == msgSender) {
                revert InvalidReferral();
            }
            AffiliateAuthorization.validate(
                args.affiliate, msgSender, affiliateAuthorization, affiliateSignerRegistry.affiliateSigner()
            );
        } else if (affiliateAuthorization.length != 0) {
            revert InvalidAffiliateAuthorization();
        }

        if (i.limit == 0) {
            revert MintingPaused();
        }

        if (!verify(auth, i.tokenAddress, msgSender)) {
            revert WalletUnauthorizedToMint();
        }

        if (block.timestamp < i.start) {
            revert MintNotYetStarted();
        }

        if (i.end > i.start && block.timestamp > i.end) {
            revert MintEnded();
        }

        uint256 totalQuantity = args.totalQuantity;

        {
            uint256 totalAfterMint;
            if (i.limit < i.maxSupply) {
                totalAfterMint = minted[msgSender][auth.key] + totalQuantity;

                if (totalAfterMint > i.limit) {
                    revert NumberOfMintsExceeded();
                }
            }

            if (i.maxSupply < UINT32_MAX) {
                totalAfterMint = args.listSupply + totalQuantity;
                if (totalAfterMint > i.maxSupply) {
                    revert ListMaxSupplyExceeded();
                }
            }
        }

        if (args.tokenIds.length == 1) {
            uint256 tokenId = args.tokenIds[0];
            if (i.tokenIds.length != 0) {
                bool isValid = false;
                for (uint256 k = 0; k < i.tokenIds.length; k++) {
                    if (tokenId == i.tokenIds[k]) {
                        isValid = true;
                        break;
                    }
                }
                if (!isValid) {
                    revert InvalidTokenId();
                }
            }

            if (tokenSupply[tokenId - 1] + args.quantities[0] > config.maxSupply[tokenId - 1]) {
                revert MaxSupplyExceeded();
            }
        } else {
            uint256[] memory checked = new uint256[](tokenSupply.length);
            for (uint256 j = 0; j < args.tokenIds.length; j++) {
                uint256 tokenId = args.tokenIds[j];
                if (i.tokenIds.length != 0) {
                    bool isValid = false;
                    for (uint256 k = 0; k < i.tokenIds.length; k++) {
                        if (tokenId == i.tokenIds[k]) {
                            isValid = true;
                            break;
                        }
                    }
                    if (!isValid) {
                        revert InvalidTokenId();
                    }
                }

                if (
                    (tokenSupply[tokenId - 1] + checked[tokenId - 1] + args.quantities[j])
                        > config.maxSupply[tokenId - 1]
                ) {
                    revert MaxSupplyExceeded();
                }
                checked[tokenId - 1] += args.quantities[j];
            }
        }

        if (totalQuantity > config.maxBatchSize) {
            revert MaxBatchSizeExceeded();
        }

        if (i.tokenAddress != address(0)) {
            IERC20 erc20Token = IERC20(i.tokenAddress);
            if (erc20Token.allowance(msgSender, address(this)) < cost) {
                revert NotApprovedToTransfer();
            }

            if (erc20Token.balanceOf(msgSender) < cost) {
                revert Erc20BalanceTooLow();
            }

            if (nativeValue == 0 && msg.value != 0) {
                revert ExcessiveEthSent();
            }
        }

        if (msg.value < nativeValue) {
            revert InsufficientEthSent();
        }
    }

    function isPublicInvite(Invite storage invite, bytes32 key) internal view returns (bool) {
        return uint256(key) <= 0xff || key == keccak256(abi.encodePacked(invite.tokenAddress));
    }

    function creditPlatformSurcharge(ArchetypeAddresses memory addrs, uint256 surcharge) public {
        if (surcharge == 0) return;

        address[] memory recipients = new address[](1);
        recipients[0] = addrs.platform;
        uint16[] memory splits = new uint16[](1);
        splits[0] = 10000;
        ArchetypePayouts(addrs.payouts).updateBalances{value: surcharge}(surcharge, address(0), recipients, splits);
    }

    function updateBalances(
        ArchetypeAddresses memory addrs,
        Invite storage i,
        Config storage config,
        PayoutConfig storage payoutConfig,
        address owner,
        address sender,
        address affiliate,
        uint256 quantity,
        uint128 value,
        uint256 platformSurcharge
    ) public {
        address tokenAddress = i.tokenAddress;

        uint128 affiliateWad;
        if (affiliate != address(0)) {
            affiliateWad = (value * config.affiliateFee) / 10000;
        }

        if (tokenAddress != address(0)) {
            IERC20 erc20Token = IERC20(tokenAddress);
            uint256 balanceBefore = erc20Token.balanceOf(address(this));
            erc20Token.safeTransferFrom(sender, address(this), value);
            if (erc20Token.balanceOf(address(this)) != balanceBefore + value) {
                revert UnexpectedTokenBalanceChange();
            }
        }

        uint128 payoutWad = value - affiliateWad;
        if (tokenAddress == address(0) && value == 0 && platformSurcharge == 0) {
            if (affiliate != address(0)) emit Referral(affiliate, tokenAddress, 0, quantity, 0);
            return;
        }

        address[] memory recipients;
        uint16[] memory splits;
        if (payoutWad > 0) {
            address ownerRecipient = payoutConfig.ownerAltPayout;
            if (ownerRecipient == address(0)) ownerRecipient = owner == address(0) ? addrs.platform : owner;

            uint256 recipientCount = 2;
            if (payoutConfig.partnerBps > 0) ++recipientCount;
            if (payoutConfig.superAffiliateBps > 0) ++recipientCount;

            recipients = new address[](recipientCount);
            recipients[0] = ownerRecipient;
            recipients[1] = addrs.platform;

            splits = new uint16[](recipientCount);
            splits[0] = payoutConfig.ownerBps;
            splits[1] = payoutConfig.platformBps;

            uint256 recipientIndex = 2;
            if (payoutConfig.partnerBps > 0) {
                recipients[recipientIndex] = payoutConfig.partner;
                splits[recipientIndex++] = payoutConfig.partnerBps;
            }
            if (payoutConfig.superAffiliateBps > 0) {
                recipients[recipientIndex] = payoutConfig.superAffiliate;
                splits[recipientIndex] = payoutConfig.superAffiliateBps;
            }

            if (tokenAddress != address(0)) {
                ArchetypePayouts(addrs.payouts).updateBalances(payoutWad, tokenAddress, recipients, splits);
            }
        }

        if (tokenAddress == address(0)) {
            if (affiliate == address(0) && platformSurcharge == 0) {
                ArchetypePayouts(addrs.payouts).updateBalances{value: payoutWad}(
                    payoutWad, tokenAddress, recipients, splits
                );
            } else {
                NativeMintCredit memory credit = NativeMintCredit({
                    payoutAmount: payoutWad,
                    affiliateAmount: affiliateWad,
                    platformSurcharge: platformSurcharge,
                    affiliate: affiliate,
                    platform: addrs.platform
                });
                ArchetypePayouts(addrs.payouts).creditMint{value: uint256(value) + platformSurcharge}(
                    credit, recipients, splits
                );
            }
            if (affiliate != address(0)) {
                emit Referral(affiliate, tokenAddress, affiliateWad, quantity, uint256(value) + platformSurcharge);
            }
            return;
        }

        if (affiliate != address(0)) {
            if (affiliateWad > 0) {
                address[] memory affiliateRecipients = new address[](1);
                affiliateRecipients[0] = affiliate;
                uint16[] memory affiliateSplits = new uint16[](1);
                affiliateSplits[0] = 10000;
                ArchetypePayouts(addrs.payouts)
                    .updateBalances(affiliateWad, tokenAddress, affiliateRecipients, affiliateSplits);
            }
            emit Referral(affiliate, tokenAddress, affiliateWad, quantity, value);
        }
        if (platformSurcharge > 0) creditPlatformSurcharge(addrs, platformSurcharge);
    }

    function verify(Auth calldata auth, address tokenAddress, address account) public pure returns (bool) {
        // keys 0-255 and tokenAddress are public
        if (uint256(auth.key) <= 0xff || auth.key == keccak256(abi.encodePacked(tokenAddress))) {
            return true;
        }

        return MerkleProofLib.verify(auth.proof, auth.key, keccak256(abi.encodePacked(account)));
    }

    function _msgSender(ArchetypeAddresses memory addrs) internal view returns (address) {
        if (msg.sender != addrs.batch) return msg.sender;
        address caller = IArchetypeBatch(addrs.batch).currentCaller();
        return caller == address(0) ? msg.sender : caller;
    }
}
