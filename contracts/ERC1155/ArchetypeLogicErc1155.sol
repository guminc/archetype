// SPDX-License-Identifier: MIT
// ArchetypeLogic v0.8.0 - ERC1155-random
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
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "solady/src/utils/MerkleProofLib.sol";
import "solady/src/utils/ECDSA.sol";

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
error InvalidSignature();
error MaxBatchSizeExceeded();
error NotTokenOwner();
error NotPlatform();
error NotOwner();
error NotShareholder();
error NotApprovedToTransfer();
error InvalidAmountOfTokens();
error WrongPassword();
error LockedForever();
error URIQueryForNonexistentToken();
error InvalidTokenId();
error MintToZeroAddress();
error NotSupported();

//
// STRUCTS
//
struct Auth {
  bytes32 key;
  bytes32[] proof;
}

struct Config {
  string baseUri;
  address affiliateSigner;
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

struct AdvancedInvite {
  uint128 price;
  uint128 reservePrice;
  uint128 delta;
  uint32 start;
  uint32 end;
  uint32 limit;
  uint32 maxSupply;
  uint32 interval;
  uint32 unitSize; // mint 1 get x
  uint32[] tokenIds; // token ids mintable from this list
  address tokenAddress;
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
  address affiliate;
  uint256[] quantities;
  uint256[] tokenIds;
  uint256 totalQuantity;
  uint256 listSupply;
}

// UPDATE CONSTANTS BEFORE DEPLOY
address constant PLATFORM = 0x8952caF7E5bf1fe63ebe94148ca802F3eF127C98;
address constant BATCH = 0xEa49e7bE310716dA66725c84a5127d2F6A202eAf;
address constant PAYOUTS = 0xaAfdfA4a935d8511bF285af11A0544ce7e4a1199;
uint16 constant MAXBPS = 5000; // max fee or discount is 50%
uint32 constant UINT32_MAX = 2**32 - 1;

library ArchetypeLogicErc1155 {
  //
  // EVENTS
  //
  event Invited(bytes32 indexed key, bytes32 indexed cid);
  event Referral(address indexed affiliate, address token, uint128 wad, uint256 numMints);
  event Withdrawal(address indexed src, address token, uint128 wad);

  // calculate price based on affiliate usage and mint discounts
  function computePrice(
    AdvancedInvite storage invite,
    uint16 affiliateDiscount,
    uint256 numTokens,
    uint256 listSupply,
    bool affiliateUsed
  ) public view returns (uint256) {
    uint256 price = invite.price;
    uint256 cost;
    if (invite.interval > 0 && invite.delta > 0) {
      // Apply dutch pricing
      uint256 diff = (((block.timestamp - invite.start) / invite.interval) * invite.delta);
      if (price > invite.reservePrice) {
        if (diff > price - invite.reservePrice) {
          price = invite.reservePrice;
        } else {
          price = price - diff;
        }
      } else if (price < invite.reservePrice) {
        if (diff > invite.reservePrice - price) {
          price = invite.reservePrice;
        } else {
          price = price + diff;
        }
      }
      cost = price * numTokens;
    } else if (invite.interval == 0 && invite.delta > 0) {
      // Apply linear curve
      uint256 lastPrice = price + invite.delta * listSupply;
      cost = lastPrice * numTokens + (invite.delta * numTokens * (numTokens - 1)) / 2;
    } else {
      cost = price * numTokens;
    }

    if (affiliateUsed) {
      cost = cost - ((cost * affiliateDiscount) / 10000);
    }

    return cost;
  }

  function validateMint(
    AdvancedInvite storage i,
    Config storage config,
    Auth calldata auth,
    mapping(address => mapping(bytes32 => uint256)) storage minted,
    uint256[] storage tokenSupply,
    bytes calldata signature,
    ValidationArgs memory args,
    uint256 cost
  ) public view {
    address msgSender = _msgSender();
    if (args.affiliate != address(0)) {
      if (
        args.affiliate == PLATFORM || args.affiliate == args.owner || args.affiliate == msgSender
      ) {
        revert InvalidReferral();
      }
      validateAffiliate(args.affiliate, signature, config.affiliateSigner);
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

    uint256 totalQuantity = 0;
    for (uint256 j = 0; j < args.quantities.length; j++) {
      totalQuantity += args.quantities[j];
    }

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
        (tokenSupply[tokenId - 1] + checked[tokenId - 1] + args.quantities[j]) >
        config.maxSupply[tokenId - 1]
      ) {
        revert MaxSupplyExceeded();
      }
      checked[tokenId - 1] += args.quantities[j];
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
    AdvancedInvite storage i,
    Config storage config,
    mapping(address => uint128) storage _ownerBalance,
    mapping(address => mapping(address => uint128)) storage _affiliateBalance,
    address affiliate,
    uint256 quantity,
    uint128 value
  ) public {
    address tokenAddress = i.tokenAddress;

    uint128 affiliateWad;
    if (affiliate != address(0)) {
      affiliateWad = (value * config.affiliateFee) / 10000;
      _affiliateBalance[affiliate][tokenAddress] += affiliateWad;
      emit Referral(affiliate, tokenAddress, affiliateWad, quantity);
    }

    uint128 balance = _ownerBalance[tokenAddress];
    uint128 ownerWad = value - affiliateWad;
    _ownerBalance[tokenAddress] = balance + ownerWad;

    if (tokenAddress != address(0)) {
      IERC20 erc20Token = IERC20(tokenAddress);
      bool success = erc20Token.transferFrom(_msgSender(), address(this), value);
      if (!success) {
        revert TransferFailed();
      }
    }
  }

  function withdrawTokensAffiliate(
    mapping(address => mapping(address => uint128)) storage _affiliateBalance,
    address[] calldata tokens
  ) public {
    address msgSender = _msgSender();

    for (uint256 i; i < tokens.length; i++) {
      address tokenAddress = tokens[i];
      uint128 wad = _affiliateBalance[msgSender][tokenAddress];
      _affiliateBalance[msgSender][tokenAddress] = 0;

      if (wad == 0) {
        revert BalanceEmpty();
      }

      if (tokenAddress == address(0)) {
        bool success = false;
        (success, ) = msgSender.call{ value: wad }("");
        if (!success) {
          revert TransferFailed();
        }
      } else {
        IERC20 erc20Token = IERC20(tokenAddress);
        bool success = erc20Token.transfer(msgSender, wad);
        if (!success) {
          revert TransferFailed();
        }
      }

      emit Withdrawal(msgSender, tokenAddress, wad);
    }
  }

  function withdrawTokens(
    PayoutConfig storage payoutConfig,
    mapping(address => uint128) storage _ownerBalance,
    address owner,
    address[] calldata tokens
  ) public {
    address msgSender = _msgSender();
    for (uint256 i; i < tokens.length; i++) {
      address tokenAddress = tokens[i];
      uint128 wad;

      if (
        msgSender == owner ||
        msgSender == PLATFORM ||
        msgSender == payoutConfig.partner ||
        msgSender == payoutConfig.superAffiliate ||
        msgSender == payoutConfig.ownerAltPayout
      ) {
        wad = _ownerBalance[tokenAddress];
        _ownerBalance[tokenAddress] = 0;
      } else {
        revert NotShareholder();
      }

      if (wad == 0) {
        revert BalanceEmpty();
      }

      if (payoutConfig.ownerAltPayout == address(0)) {
        address[] memory recipients = new address[](4);
        recipients[0] = owner;
        recipients[1] = PLATFORM;
        recipients[2] = payoutConfig.partner;
        recipients[3] = payoutConfig.superAffiliate;

        uint16[] memory splits = new uint16[](4);
        splits[0] = payoutConfig.ownerBps;
        splits[1] = payoutConfig.platformBps;
        splits[2] = payoutConfig.partnerBps;
        splits[3] = payoutConfig.superAffiliateBps;

        if (tokenAddress == address(0)) {
          ArchetypePayouts(PAYOUTS).updateBalances{ value: wad }(
            wad,
            tokenAddress,
            recipients,
            splits
          );
        } else {
          ArchetypePayouts(PAYOUTS).updateBalances(wad, tokenAddress, recipients, splits);
        }
      } else {
        uint256 ownerShare = (uint256(wad) * payoutConfig.ownerBps) / 10000;
        uint256 remainingShare = wad - ownerShare;

        if (tokenAddress == address(0)) {
          (bool success, ) = payable(payoutConfig.ownerAltPayout).call{ value: ownerShare }("");
          if (!success) revert TransferFailed();
        } else {
          IERC20(tokenAddress).transfer(payoutConfig.ownerAltPayout, ownerShare);
        }

        address[] memory recipients = new address[](3);
        recipients[0] = PLATFORM;
        recipients[1] = payoutConfig.partner;
        recipients[2] = payoutConfig.superAffiliate;

        uint16[] memory splits = new uint16[](3);
        uint16 remainingBps = 10000 - payoutConfig.ownerBps;
        splits[1] = uint16((uint256(payoutConfig.partnerBps) * 10000) / remainingBps);
        splits[2] = uint16((uint256(payoutConfig.superAffiliateBps) * 10000) / remainingBps);
        splits[0] = 10000 - splits[1] - splits[2];

        if (tokenAddress == address(0)) {
          ArchetypePayouts(PAYOUTS).updateBalances{ value: remainingShare }(
            remainingShare,
            tokenAddress,
            recipients,
            splits
          );
        } else {
          ArchetypePayouts(PAYOUTS).updateBalances(
            remainingShare,
            tokenAddress,
            recipients,
            splits
          );
        }
      }
      emit Withdrawal(msgSender, tokenAddress, wad);
    }
  }

  function validateAffiliate(
    address affiliate,
    bytes calldata signature,
    address affiliateSigner
  ) public view {
    bytes32 signedMessagehash = ECDSA.toEthSignedMessageHash(
      keccak256(abi.encodePacked(affiliate))
    );
    address signer = ECDSA.recover(signedMessagehash, signature);

    if (signer != affiliateSigner) {
      revert InvalidSignature();
    }
  }

  function verify(
    Auth calldata auth,
    address tokenAddress,
    address account
  ) public pure returns (bool) {
    // keys 0-255 and tokenAddress are public
    if (uint256(auth.key) <= 0xff || auth.key == keccak256(abi.encodePacked(tokenAddress))) {
      return true;
    }

    return MerkleProofLib.verify(auth.proof, auth.key, keccak256(abi.encodePacked(account)));
  }


  function _msgSender() internal view returns (address) {
    return msg.sender == BATCH ? tx.origin : msg.sender;
  }
}
