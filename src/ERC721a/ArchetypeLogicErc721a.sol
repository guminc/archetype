// SPDX-License-Identifier: MIT
// ArchetypeLogic v10.0
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
import "openzeppelin-v4/token/ERC721/IERC721.sol";
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
error BurnToMintDisabled();
error NotTokenOwner();
error NotPlatform();
error NotOwner();
error NotApprovedToTransfer();
error InvalidAmountOfTokens();
error WrongPassword();
error LockedForever();
error Blacklisted();
error MintCostOverflow();
error ExcessiveCurrencyCost();

struct Auth {
    bytes32 key;
    bytes32[] proof;
}

struct BonusDiscount {
    uint16 numMints;
    uint16 numBonusMints;
}

struct Config {
    string baseUri;
    uint32 maxSupply;
    uint32 maxBatchSize;
    uint16 affiliateFee; //BPS
    uint16 affiliateDiscount; //BPS
    uint16 defaultRoyalty; //BPS
}

// allocation splits for mint proceeds, must sum to 100%
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
    address tokenAddress;
    bool isBlacklist;
}

struct BurnInvite {
    IERC721 burnErc721;
    address burnAddress;
    address tokenAddress;
    uint128 price; // flat price - does not support discounts
    bool reversed; // side of the ratio (false=burn {ratio} get 1, true=burn 1 get {ratio})
    uint16 ratio;
    uint32 start;
    uint32 end;
    uint64 limit;
}

struct ValidationArgs {
    address owner;
    address sender;
    address affiliate;
    uint256 quantity;
    uint256 curSupply;
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

struct Erc721BatchMint {
    address[] recipients;
    uint256[] quantities;
    address affiliate;
    bytes affiliateAuthorization;
    MintConstraints constraints;
}

uint16 constant MAXBPS = 5000; // max fee or discount is 50%
uint32 constant UINT32_MAX = 2 ** 32 - 1;

library ArchetypeLogicErc721a {
    using SafeERC20 for IERC20;

    event Invited(bytes32 indexed key, bytes32 indexed cid);
    event BurnInvited(bytes32 indexed key, bytes32 indexed cid);
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

    function bonusMintsAwarded(uint256 numNfts, uint256 packedDiscount) internal pure returns (uint256) {
        for (uint8 i = 0; i < 8; i++) {
            uint32 discount = uint32((packedDiscount >> (32 * i)) & 0xFFFFFFFF);
            uint16 tierNumMints = uint16(discount >> 16);
            uint16 tierBonusMints = uint16(discount);

            if (tierNumMints == 0) {
                break; // End of valid discounts
            }

            if (numNfts >= tierNumMints) {
                return (numNfts / tierNumMints) * tierBonusMints;
            }
        }
        return 0;
    }

    function isPublicInvite(Invite storage invite, bytes32 key) internal view returns (bool) {
        return invite.isBlacklist || uint256(key) <= 0xff || key == keccak256(abi.encodePacked(invite.tokenAddress));
    }

    function validateMint(
        ArchetypeAddresses memory addrs,
        Invite storage i,
        Config storage config,
        Auth calldata auth,
        mapping(address => mapping(bytes32 => uint256)) storage minted,
        bytes calldata affiliateAuthorization,
        AffiliateSignerRegistry affiliateSignerRegistry,
        ValidationArgs memory args,
        uint128 cost,
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

        if (!i.isBlacklist) {
            if (!verify(auth, i.tokenAddress, msgSender)) {
                revert WalletUnauthorizedToMint();
            }
        } else {
            if (verify(auth, i.tokenAddress, msgSender)) {
                revert Blacklisted();
            }
        }

        if (block.timestamp < i.start) {
            revert MintNotYetStarted();
        }

        if (i.end > i.start && block.timestamp > i.end) {
            revert MintEnded();
        }

        if (i.limit < i.maxSupply) {
            uint256 totalAfterMint = minted[msgSender][auth.key] + args.quantity;

            if (totalAfterMint > i.limit) {
                revert NumberOfMintsExceeded();
            }
        }

        if (i.maxSupply < config.maxSupply) {
            uint256 totalAfterMint = args.listSupply + args.quantity;
            if (totalAfterMint > i.maxSupply) {
                revert ListMaxSupplyExceeded();
            }
        }

        if (args.quantity > config.maxBatchSize) {
            revert MaxBatchSizeExceeded();
        }

        if ((args.curSupply + args.quantity) > config.maxSupply) {
            revert MaxSupplyExceeded();
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

    function creditPlatformSurcharge(ArchetypeAddresses memory addrs, uint256 surcharge) public {
        if (surcharge == 0) return;

        address[] memory recipients = new address[](1);
        recipients[0] = addrs.platform;
        uint16[] memory splits = new uint16[](1);
        splits[0] = 10000;
        ArchetypePayouts(addrs.payouts).updateBalances{value: surcharge}(surcharge, address(0), recipients, splits);
    }

    function validateBurnToMint(
        ArchetypeAddresses memory addrs,
        BurnInvite storage burnInvite,
        Config storage config,
        Auth calldata auth,
        uint256[] calldata tokenIds,
        uint256 curSupply,
        mapping(address => mapping(bytes32 => uint256)) storage minted,
        uint128 cost
    ) public view {
        if (burnInvite.limit == 0) {
            revert MintingPaused();
        }

        if (block.timestamp < burnInvite.start) {
            revert MintNotYetStarted();
        }

        if (burnInvite.end > burnInvite.start && block.timestamp > burnInvite.end) {
            revert MintEnded();
        }

        // check if msgSender owns tokens and has correct approvals
        address msgSender = _msgSender(addrs);
        for (uint256 i; i < tokenIds.length;) {
            if (burnInvite.burnErc721.ownerOf(tokenIds[i]) != msgSender) {
                revert NotTokenOwner();
            }
            unchecked {
                ++i;
            }
        }

        if (!verify(auth, burnInvite.tokenAddress, msgSender)) {
            revert WalletUnauthorizedToMint();
        }

        if (!burnInvite.burnErc721.isApprovedForAll(msgSender, address(this))) {
            revert NotApprovedToTransfer();
        }

        uint256 quantity;
        if (burnInvite.reversed) {
            quantity = tokenIds.length * burnInvite.ratio;
        } else {
            if (tokenIds.length % burnInvite.ratio != 0) {
                revert InvalidAmountOfTokens();
            }
            quantity = tokenIds.length / burnInvite.ratio;
        }

        if (quantity > config.maxBatchSize) {
            revert MaxBatchSizeExceeded();
        }

        if (burnInvite.limit < config.maxSupply) {
            uint256 totalAfterMint = minted[msgSender][keccak256(abi.encodePacked("burn", auth.key))] + quantity;

            if (totalAfterMint > burnInvite.limit) {
                revert NumberOfMintsExceeded();
            }
        }

        if ((curSupply + quantity) > config.maxSupply) {
            revert MaxSupplyExceeded();
        }

        if (burnInvite.tokenAddress != address(0)) {
            IERC20 erc20Token = IERC20(burnInvite.tokenAddress);
            if (erc20Token.allowance(msgSender, address(this)) < cost) {
                revert NotApprovedToTransfer();
            }

            if (erc20Token.balanceOf(msgSender) < cost) {
                revert Erc20BalanceTooLow();
            }

            if (msg.value != 0) {
                revert ExcessiveEthSent();
            }
        } else {
            if (msg.value < cost) {
                revert InsufficientEthSent();
            }
        }
    }

    function updateBalances(
        ArchetypeAddresses memory addrs,
        address tokenAddress,
        Config storage config,
        PayoutConfig storage payoutConfig,
        address owner,
        address sender,
        address affiliate,
        uint256 quantity,
        uint128 value,
        uint256 platformSurcharge
    ) public {
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
