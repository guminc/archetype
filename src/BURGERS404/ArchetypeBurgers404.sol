// SPDX-License-Identifier: MIT
// Archetype v0.8.0 - BURGERS404
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

import "./ArchetypeLogicBurgers404.sol";
import "dn404/src/DN420.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "solady/src/utils/LibString.sol";
import "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol";

contract ArchetypeBurgers404 is DN420, Initializable, OwnableUpgradeable, ERC2981Upgradeable {
  //
  // EVENTS
  //
  event Invited(bytes32 indexed key, bytes32 indexed cid);
  event Referral(address indexed affiliate, address token, uint128 wad, uint256 numMints);
  event Withdrawal(address indexed src, address token, uint128 wad);

  //
  // VARIABLES
  //
  mapping(bytes32 => AdvancedInvite) public invites;
  mapping(bytes32 => uint256) public packedBonusDiscounts;
  mapping(address => mapping(bytes32 => uint256)) private _minted;
  mapping(bytes32 => uint256) private _listSupply;
  mapping(address => uint128) private _ownerBalance;
  mapping(address => mapping(address => uint128)) private _affiliateBalance;
  mapping(bytes32 => bytes32) public pairedListKeys; 

  string private _name;
  string private _symbol;
  uint256 private totalErc20Mints;
  Config public config;
  PayoutConfig public payoutConfig;
  uint256 public flags;
  // bit 0: uriLocked
  // bit 1: maxSupplyLocked 
  // bit 2: ownerAltPayoutLocked

  //
  // METHODS
  //
  function initialize(
    string memory name_,
    string memory symbol_,
    Config calldata config_,
    PayoutConfig calldata payoutConfig_,
    address _receiver
  ) external initializer {
    _name = name_;
    _symbol = symbol_;
    config = config_;

    _initializeDN420(0, address(0));

    // check max bps not reached and min platform fee.
    if (
      config_.affiliateFee > MAXBPS ||
      config_.affiliateDiscount > MAXBPS ||
      config_.affiliateSigner == address(0) ||
      config_.maxBatchSize == 0
    ) {
      revert InvalidConfig();
    }
    __Ownable_init();

    uint256 totalShares = payoutConfig_.ownerBps +
      payoutConfig_.platformBps +
      payoutConfig_.partnerBps +
      payoutConfig_.superAffiliateBps;

    if (payoutConfig_.platformBps < 250 || totalShares != 10000) {
      revert InvalidSplitShares();
    }
    payoutConfig = payoutConfig_;
    setDefaultRoyalty(_receiver, config.defaultRoyalty);
  }

  //
  // PUBLIC
  //
  function mint(
    Auth calldata auth,
    uint256 quantity,
    address affiliate,
    bytes calldata signature
  ) external payable {
    mintTo(auth, quantity, _msgSender(), affiliate, signature);
  }

  function batchMintTo(
    Auth calldata auth,
    address[] calldata toList,
    uint256[] calldata quantityList,
    address affiliate,
    bytes calldata signature
  ) external payable {
    if (quantityList.length != toList.length) {
      revert InvalidConfig();
    }

    AdvancedInvite storage invite = invites[auth.key];
    uint256 packedDiscount = packedBonusDiscounts[auth.key];

    uint256 totalQuantity;
    uint256 totalBonusMints;

    for (uint256 i; i < toList.length; ) {
      uint256 quantityToAdd;
      if (invite.unitSize > 1) {
        quantityToAdd = quantityList[i] * invite.unitSize;
      } else {
        quantityToAdd = quantityList[i];
      }

      uint256 numBonusMints = ArchetypeLogicBurgers404.bonusMintsAwarded(quantityToAdd / config.erc20Ratio, packedDiscount) * config.erc20Ratio;
      _mintNext(toList[i], (quantityToAdd + numBonusMints) * ERC20_UNIT, "");

      totalQuantity += quantityToAdd;
      totalBonusMints += numBonusMints;

      unchecked {
        ++i;
      }
    }

    validateAndCreditMint(invite, auth, totalQuantity, totalBonusMints, totalErc20Mints, affiliate, signature);
  }

  function mintTo(
    Auth calldata auth,
    uint256 quantity,
    address to,
    address affiliate,
    bytes calldata signature
  ) public payable {
    AdvancedInvite storage invite = invites[auth.key];
    uint256 packedDiscount = packedBonusDiscounts[auth.key];

    if (invite.unitSize > 1) {
      quantity = quantity * invite.unitSize;
    }

    uint256 numBonusMints = ArchetypeLogicBurgers404.bonusMintsAwarded(quantity / config.erc20Ratio, packedDiscount) * config.erc20Ratio;
    _mintNext(to, (quantity + numBonusMints) * ERC20_UNIT, "");

    validateAndCreditMint(invite, auth, quantity, numBonusMints, totalErc20Mints, affiliate, signature);
  }

  function validateAndCreditMint(
    AdvancedInvite storage invite,
    Auth calldata auth,
    uint256 quantity,
    uint256 numBonusMints,
    uint256 curSupply,
    address affiliate,
    bytes calldata signature
  ) internal {
    uint256 totalQuantity = quantity + numBonusMints;
    ValidationArgs memory args;
    {
      bytes32 pairedKey = pairedListKeys[auth.key];
      uint256 pairedSupply = pairedKey != 0 ? _listSupply[bytes32(uint256(pairedKey) - 1)]: 0;
      args = ValidationArgs({
        owner: owner(),
        affiliate: affiliate,
        quantity: totalQuantity,
        curSupply: curSupply,
        listSupply: _listSupply[auth.key],
        pairedSupply: pairedSupply
      });
    }

    uint128 cost = uint128(
      ArchetypeLogicBurgers404.computePrice(
        invite,
        config.affiliateDiscount,
        quantity,
        args.listSupply,
        args.affiliate != address(0)
      )
    );

    ArchetypeLogicBurgers404.validateMint(invite, config, auth, _minted, signature, args, cost);

    if (invite.limit < invite.maxSupply) {
      _minted[_msgSender()][auth.key] += totalQuantity;
    }
    if (invite.maxSupply < UINT32_MAX) {
      _listSupply[auth.key] += totalQuantity;
    }
    totalErc20Mints += totalQuantity;

    ArchetypeLogicBurgers404.updateBalances(
      invite,
      config,
      _ownerBalance,
      _affiliateBalance,
      affiliate,
      quantity,
      cost
    );

    if (msg.value > cost) {
      _refund(_msgSender(), msg.value - cost);
    }
  }

  function burnToRemint(uint256[] calldata tokenIds) public {
    if(config.remintPremium == 0) {
      revert burnToRemintDisabled();
    }

    if(tokenIds.length < 1) {
      revert invalidTokenIdLength();
    }

    address msgSender = _msgSender();
    uint256 mintQuantity = 1 * _unit();
    uint256 burnQuantity =  mintQuantity * config.remintPremium / 10000;
    uint256 msgSenderBalance = balanceOf(msgSender);
    uint256 change = 0;

    // transfer nft 1
    safeTransferNFT(msgSender, 0x000000000000000000000000000000000000dEaD, tokenIds[0], "");

    // if premium will make minter lose an nft, transfer nft 2 and give back change, otherwise just transfer erc20
    if(msgSenderBalance % _unit() < burnQuantity) {
      if(tokenIds.length < 2) {
        revert invalidTokenIdLength();
      }
      _safeTransferNFT(msgSender, msgSender, 0x000000000000000000000000000000000000dEaD, tokenIds[1], "");
      change += _unit() - burnQuantity;
    } else {
      _transfer(msgSender, 0x000000000000000000000000000000000000dEaD, burnQuantity, "");
    }

    // remint
    _mintNext(msgSender, mintQuantity + change, "");
  }

  function withdraw() external {
    address[] memory tokens = new address[](1);
    tokens[0] = address(0);
    withdrawTokens(tokens);
  }

  function withdrawTokens(address[] memory tokens) public {
    ArchetypeLogicBurgers404.withdrawTokens(payoutConfig, _ownerBalance, owner(), tokens);
  }

  function withdrawAffiliate() external {
    address[] memory tokens = new address[](1);
    tokens[0] = address(0);
    withdrawTokensAffiliate(tokens);
  }

  function withdrawTokensAffiliate(address[] memory tokens) public {
    ArchetypeLogicBurgers404.withdrawTokensAffiliate(_affiliateBalance, tokens);
  }

  function ownerBalance() external view returns (uint128) {
    return _ownerBalance[address(0)];
  }

  function ownerBalanceToken(address token) external view returns (uint128) {
    return _ownerBalance[token];
  }

  function affiliateBalance(address affiliate) external view returns (uint128) {
    return _affiliateBalance[affiliate][address(0)];
  }

  function affiliateBalanceToken(address affiliate, address token) external view returns (uint128) {
    return _affiliateBalance[affiliate][token];
  }

  function minted(address minter, bytes32 key) external view returns (uint256) {
    return _minted[minter][key];
  }

  function listSupply(bytes32 key) external view returns (uint256) {
    return _listSupply[key];
  }

  function numErc20Minted() public view returns (uint256) {
    return totalErc20Mints;
  }

  function numNftsMinted() public view returns (uint256) {
    return totalErc20Mints / config.erc20Ratio;
  }

  function balanceOfNFT(address owner) public view returns (uint256) {
    return _balanceOfNFT(owner);
  }

  function exists(uint256 id) external view returns (bool) {
    return _exists(id);
  }

  function platform() external pure returns (address) {
    return PLATFORM;
  }

  function computePrice(
    bytes32 key,
    uint256 quantity,
    bool affiliateUsed
  ) external view returns (uint256) {
    AdvancedInvite storage i = invites[key];
    uint256 listSupply_ = _listSupply[key];
    return ArchetypeLogicBurgers404.computePrice(i, config.affiliateDiscount, quantity, listSupply_, affiliateUsed);
  }

  //
  // Overides
  //

  function name() public view override returns (string memory) {
    return _name;
  }

  function symbol() public view override returns (string memory) {
    return _symbol;
  }

  function uri(uint256 tokenId) public view override returns (string memory) {
    if (!_exists(tokenId)) revert URIQueryForNonexistentToken();

    return
      bytes(config.baseUri).length != 0
        ? string(abi.encodePacked(config.baseUri, LibString.toString(tokenId)))
        : "";
  }

  //
  // OWNER ONLY
  //

  function setBaseURI(string memory baseUri) external _onlyOwner {
    if (_getFlag(0)) {
      revert LockedForever();
    }

    config.baseUri = baseUri;
  }

  /// @notice the password is "forever"
  function lockURI(string calldata password) external _onlyOwner {
    _checkPassword(password);
    _setFlag(0);
  }

  // max supply cannot subceed total supply. Be careful changing.
  function setMaxSupply(uint32 maxSupply) external _onlyOwner {
    if (_getFlag(1)) {
      revert LockedForever();
    }

    if (maxSupply < numErc20Minted()) {
      revert MaxSupplyExceeded();
    }

    config.maxSupply = maxSupply;
  }

  /// @notice the password is "forever"
  function lockMaxSupply(string calldata password) external _onlyOwner {
    _checkPassword(password);
    _setFlag(1);
  }

  function setAffiliateFee(uint16 affiliateFee) external _onlyOwner {
    if (affiliateFee > MAXBPS) {
      revert InvalidConfig();
    }

    config.affiliateFee = affiliateFee;
  }

  function setAffiliateDiscount(uint16 affiliateDiscount) external _onlyOwner {
    if (affiliateDiscount > MAXBPS) {
      revert InvalidConfig();
    }

    config.affiliateDiscount = affiliateDiscount;
  }

  function setOwnerAltPayout(address ownerAltPayout) external _onlyOwner {
    if (_getFlag(2)) {
      revert LockedForever();
    }

    payoutConfig.ownerAltPayout = ownerAltPayout;
  }

  /// @notice the password is "forever"
  function lockOwnerAltPayout(string calldata password) external _onlyOwner {
    _checkPassword(password);
    _setFlag(2);
  }

  function setMaxBatchSize(uint32 maxBatchSize) external _onlyOwner {
    config.maxBatchSize = maxBatchSize;
  }

  function setRemintPremium(uint16 remintPremium) external _onlyOwner {
    config.remintPremium = remintPremium;
  }

  // Up to 8 discount tiers: [discount7][discount6][discount5][discount4][discount3][discount2][discount1][discount0]
  function setBonusDiscounts(bytes32 _key, BonusDiscount[] calldata _bonusDiscounts) public onlyOwner {
      if(_bonusDiscounts.length > 8) {
        revert InvalidConfig();
      }
      
      uint256 packed;
      for (uint8 i = 0; i < _bonusDiscounts.length; i++) {
          if (i > 0 && _bonusDiscounts[i].numMints >= _bonusDiscounts[i - 1].numMints) {
              revert InvalidConfig();
          }
          uint32 discount = (uint32(_bonusDiscounts[i].numMints) << 16) | uint32(_bonusDiscounts[i].numBonusMints);
          packed |= uint256(discount) << (32 * i);
      }
      packedBonusDiscounts[_key] = packed;
  }

  function setBonusInvite(
    bytes32 _key,
    bytes32 _cid,
    AdvancedInvite calldata _advancedInvite,
    BonusDiscount[] calldata _bonusDiscount
  ) external _onlyOwner {
    setBonusDiscounts(_key, _bonusDiscount);
    setAdvancedInvite(_key, _cid, _advancedInvite);
  }

  function setInvite(
    bytes32 _key,
    bytes32 _cid,
    Invite calldata _invite
  ) external _onlyOwner {
    setAdvancedInvite(_key, _cid, AdvancedInvite({
      price: _invite.price,
      reservePrice: _invite.price,
      delta: 0,
      start: _invite.start,
      end: _invite.end,
      limit: _invite.limit,
      maxSupply: _invite.maxSupply,
      interval: 0,
      unitSize: _invite.unitSize,
      tokenAddress: _invite.tokenAddress,
      isBlacklist: _invite.isBlacklist
    }));
  }

  function setAdvancedInvite(
    bytes32 _key,
    bytes32 _cid,
    AdvancedInvite memory _AdvancedInvite
  ) public _onlyOwner {
    // approve token for withdrawals if erc20 list
    if (_AdvancedInvite.tokenAddress != address(0)) {
      bool success = IERC20(_AdvancedInvite.tokenAddress).approve(PAYOUTS, 2**256 - 1);
      if (!success) {
        revert NotApprovedToTransfer();
      }
    }
    if (_AdvancedInvite.start < block.timestamp) {
      _AdvancedInvite.start = uint32(block.timestamp);
    }
    invites[_key] = _AdvancedInvite;
    emit Invited(_key, _cid);
  }

  // method will pair the supplies of two invite lists
  function setPairedInvite(bytes32 key1, bytes32 key2) external _onlyOwner {
    if(invites[key1].maxSupply != invites[key2].maxSupply) {
      revert InvalidConfig();
    }
    pairedListKeys[key1] = bytes32(uint256(key2) + 1);
    pairedListKeys[key2] = bytes32(uint256(key1) + 1);
  }

  //
  // INTERNAL
  //

  function _unit() internal view override returns (uint256) {
    return ERC20_UNIT * uint256(config.erc20Ratio);
  }

  function _msgSender() internal view override returns (address) {
    return msg.sender == BATCH ? tx.origin : msg.sender;
  }

  modifier _onlyOwner() {
    if (_msgSender() != owner()) {
      revert NotOwner();
    }
    _;
  }

  function _refund(address to, uint256 refund) internal {
    (bool success, ) = payable(to).call{ value: refund }("");
    if (!success) {
      revert TransferFailed();
    }
  }

  function _checkPassword(string calldata password) internal pure {
    if (keccak256(abi.encodePacked(password)) != keccak256(abi.encodePacked("forever"))) {
      revert WrongPassword();
    }
  }

  function _setFlag(uint256 flag) internal {
    flags |= 1 << flag;
  }

  function _getFlag(uint256 flag) internal view returns (bool) {
    return (flags & (1 << flag)) != 0;
  }

  //ERC2981 ROYALTY
  function supportsInterface(bytes4 interfaceId)
    public
    view
    virtual
    override(DN420, ERC2981Upgradeable)
    returns (bool)
  {
    // Supports the following `interfaceId`s:
    // - IERC165: 0x01ffc9a7
    // - ERC1155: 0xd9b67a26
    // - ERC1155MetadataURI: 0x0e89341c
    // - IERC2981: 0x2a55205a
    return
      DN420.supportsInterface(interfaceId) || ERC2981Upgradeable.supportsInterface(interfaceId);
  }

  function setDefaultRoyalty(address receiver, uint16 feeNumerator) public _onlyOwner {
    config.defaultRoyalty = feeNumerator;
    _setDefaultRoyalty(receiver, feeNumerator);
  }
}
