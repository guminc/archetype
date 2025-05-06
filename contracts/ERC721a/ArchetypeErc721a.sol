// SPDX-License-Identifier: MIT
// Archetype v0.8.1
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

import "./ArchetypeLogicErc721a.sol";
import "erc721a-upgradeable/contracts/ERC721AUpgradeable.sol";
import "erc721a-upgradeable/contracts/ERC721A__Initializable.sol";
import "erc721a-upgradeable/contracts/extensions/ERC721AQueryableUpgradeable.sol";
import "./ERC721A__OwnableUpgradeable.sol";
import "solady/src/utils/LibString.sol";
import "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol";

contract ArchetypeErc721a is
  ERC721A__Initializable,
  ERC721AUpgradeable,
  ERC721A__OwnableUpgradeable,
  ERC2981Upgradeable,
  ERC721AQueryableUpgradeable
{
  //
  // EVENTS
  //
  event Invited(bytes32 indexed key, bytes32 indexed cid);
  event BurnInvited(bytes32 indexed key, bytes32 indexed cid);
  event Referral(address indexed affiliate, address token, uint128 wad, uint256 numMints);
  event Withdrawal(address indexed src, address token, uint128 wad);

  //
  // VARIABLES
  //
  mapping(bytes32 => AdvancedInvite) public invites;
  mapping(bytes32 => uint256) public packedBonusDiscounts;
  mapping(bytes32 => BurnInvite) public burnInvites;
  mapping(address => mapping(bytes32 => uint256)) private _minted;
  mapping(bytes32 => uint256) private _listSupply;
  mapping(address => uint128) private _ownerBalance;
  mapping(address => mapping(address => uint128)) private _affiliateBalance;

  Config public config;
  PayoutConfig public payoutConfig;
  Options public options;

  //
  // METHODS
  //
  function initialize(
    string memory name,
    string memory symbol,
    Config calldata config_,
    PayoutConfig calldata payoutConfig_,
    address _receiver
  ) external initializerERC721A {
    __ERC721A_init(name, symbol);
    // check max bps not reached and min platform fee.
    if (
      config_.affiliateFee > MAXBPS ||
      config_.affiliateDiscount > MAXBPS ||
      config_.affiliateSigner == address(0) ||
      config_.maxBatchSize == 0
    ) {
      revert InvalidConfig();
    }
    config = config_;
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
    uint256 curSupply = _totalMinted();
    
    uint256 totalQuantity;
    uint256 totalBonusMints;

    for (uint256 i; i < toList.length; ) {
      uint256 quantityToAdd;
      if (invite.unitSize > 1) {
        quantityToAdd = quantityList[i] * invite.unitSize;
      } else {
        quantityToAdd = quantityList[i];
      }

      uint256 numBonusMints = ArchetypeLogicErc721a.bonusMintsAwarded(quantityToAdd, packedDiscount);
      _mint(toList[i], quantityToAdd + numBonusMints);

      totalQuantity += quantityToAdd;
      totalBonusMints += numBonusMints;

      unchecked {
        ++i;
      }
    }

    validateAndCreditMint(invite, auth, totalQuantity, totalBonusMints, curSupply, affiliate, signature);
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

    uint256 curSupply = _totalMinted();

    uint256 numBonusMints = ArchetypeLogicErc721a.bonusMintsAwarded(quantity, packedDiscount);
    _mint(to, quantity + numBonusMints);

    validateAndCreditMint(invite, auth, quantity, numBonusMints, curSupply, affiliate, signature);
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
      args = ValidationArgs({
        owner: owner(),
        affiliate: affiliate,
        quantity: totalQuantity,
        curSupply: curSupply,
        listSupply: _listSupply[auth.key]
      });
    }

    uint128 cost = uint128(
      ArchetypeLogicErc721a.computePrice(
        invite,
        config.affiliateDiscount,
        quantity,
        args.listSupply,
        args.affiliate != address(0)
      )
    );

    ArchetypeLogicErc721a.validateMint(invite, config, auth, _minted, signature, args, cost);

    if (invite.limit < invite.maxSupply) {
      _minted[_msgSender()][auth.key] += totalQuantity;
    }
    if (invite.maxSupply < UINT32_MAX) {
      _listSupply[auth.key] += totalQuantity;
    }

    ArchetypeLogicErc721a.updateBalances(
      invite.tokenAddress,
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

  function burnToMint(Auth calldata auth, uint256[] calldata tokenIds) external payable {
    BurnInvite storage burnInvite = burnInvites[auth.key];

    uint256 curSupply = _totalMinted();
    uint128 cost = burnInvite.price;
    ArchetypeLogicErc721a.validateBurnToMint(burnInvite, config, auth, tokenIds, curSupply, _minted, cost);

    address msgSender = _msgSender();
    for (uint256 i; i < tokenIds.length; ) {
      address burnAddress = burnInvite.burnAddress != address(0)
        ? burnInvite.burnAddress
        : address(0x000000000000000000000000000000000000dEaD);
      burnInvite.burnErc721.transferFrom(msgSender, burnAddress, tokenIds[i]);
      unchecked {
        ++i;
      }
    }

    uint256 quantity = burnInvite.reversed
      ? tokenIds.length * burnInvite.ratio
      : tokenIds.length / burnInvite.ratio;
    _mint(msgSender, quantity);

    if (burnInvite.limit < config.maxSupply) {
      _minted[msgSender][keccak256(abi.encodePacked("burn", auth.key))] += quantity;
    }

    ArchetypeLogicErc721a.updateBalances(
      burnInvite.tokenAddress,
      config,
      _ownerBalance,
      _affiliateBalance,
      address(0), // burn to mint does not support affiliates
      quantity,
      cost
    );

    if (msg.value > cost) {
      _refund(_msgSender(), msg.value - cost);
    }
  }

  function tokenURI(uint256 tokenId) public view virtual override(ERC721AUpgradeable, IERC721AUpgradeable) returns (string memory) {
    if (!_exists(tokenId)) revert URIQueryForNonexistentToken();

    return
      bytes(config.baseUri).length != 0
        ? string(abi.encodePacked(config.baseUri, LibString.toString(tokenId)))
        : "";
  }

  function withdraw() external {
    address[] memory tokens = new address[](1);
    tokens[0] = address(0);
    withdrawTokens(tokens);
  }

  function withdrawTokens(address[] memory tokens) public {
    ArchetypeLogicErc721a.withdrawTokens(payoutConfig, _ownerBalance, owner(), tokens);
  }

  function withdrawAffiliate() external {
    address[] memory tokens = new address[](1);
    tokens[0] = address(0);
    withdrawTokensAffiliate(tokens);
  }

  function withdrawTokensAffiliate(address[] memory tokens) public {
    ArchetypeLogicErc721a.withdrawTokensAffiliate(_affiliateBalance, tokens);
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
    return ArchetypeLogicErc721a.computePrice(i, config.affiliateDiscount, quantity, listSupply_, affiliateUsed);
  }

  //
  // OWNER ONLY
  //

  function setBaseURI(string memory baseUri) external _onlyOwner {
    if (options.uriLocked) {
      revert LockedForever();
    }

    config.baseUri = baseUri;
  }

  /// @notice the password is "forever"
  function lockURI(string memory password) external _onlyOwner {
    if (keccak256(abi.encodePacked(password)) != keccak256(abi.encodePacked("forever"))) {
      revert WrongPassword();
    }

    options.uriLocked = true;
  }

  /// @notice the password is "forever"
  // max supply cannot subceed total supply. Be careful changing.
  function setMaxSupply(uint32 maxSupply, string memory password) external _onlyOwner {
    if (keccak256(abi.encodePacked(password)) != keccak256(abi.encodePacked("forever"))) {
      revert WrongPassword();
    }

    if (options.maxSupplyLocked) {
      revert LockedForever();
    }

    if (maxSupply < _totalMinted()) {
      revert MaxSupplyExceeded();
    }

    config.maxSupply = maxSupply;
  }

  /// @notice the password is "forever"
  function lockMaxSupply(string memory password) external _onlyOwner {
    if (keccak256(abi.encodePacked(password)) != keccak256(abi.encodePacked("forever"))) {
      revert WrongPassword();
    }

    options.maxSupplyLocked = true;
  }

  function setAffiliateFee(uint16 affiliateFee) external _onlyOwner {
    if (options.affiliateFeeLocked) {
      revert LockedForever();
    }
    if (affiliateFee > MAXBPS) {
      revert InvalidConfig();
    }

    config.affiliateFee = affiliateFee;
  }

  function setAffiliateDiscount(uint16 affiliateDiscount) external _onlyOwner {
    if (options.affiliateFeeLocked) {
      revert LockedForever();
    }
    if (affiliateDiscount > MAXBPS) {
      revert InvalidConfig();
    }

    config.affiliateDiscount = affiliateDiscount;
  }

  /// @notice the password is "forever"
  function lockAffiliateFee(string memory password) external _onlyOwner {
    if (keccak256(abi.encodePacked(password)) != keccak256(abi.encodePacked("forever"))) {
      revert WrongPassword();
    }

    options.affiliateFeeLocked = true;
  }

  function setOwnerAltPayout(address ownerAltPayout) external _onlyOwner {
    if (options.ownerAltPayoutLocked) {
      revert LockedForever();
    }

    payoutConfig.ownerAltPayout = ownerAltPayout;
  }

  function lockOwnerAltPayout() external _onlyOwner {
    options.ownerAltPayoutLocked = true;
  }

  function setMaxBatchSize(uint32 maxBatchSize) external _onlyOwner {
    config.maxBatchSize = maxBatchSize;
  }

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

  function setBurnInvite(
    bytes32 _key,
    bytes32 _cid,
    BurnInvite memory _burnInvite
  ) external _onlyOwner {
    if (_burnInvite.start < block.timestamp) {
      _burnInvite.start = uint32(block.timestamp);
    }
    burnInvites[_key] = _burnInvite;
    emit BurnInvited(_key, _cid);
  }

  //
  // INTERNAL
  //
  function _startTokenId() internal view virtual override returns (uint256) {
    return 1;
  }

  function _msgSender() internal view returns (address) {
    return msg.sender == BATCH ? tx.origin : msg.sender;
  }

  modifier _onlyPlatform() {
    if (_msgSender() != PLATFORM) {
      revert NotPlatform();
    }
    _;
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

  //ERC2981 ROYALTY
  function supportsInterface(bytes4 interfaceId)
    public
    view
    virtual
    override(IERC721AUpgradeable, ERC721AUpgradeable, ERC2981Upgradeable)
    returns (bool)
  {
    // Supports the following `interfaceId`s:
    // - IERC165: 0x01ffc9a7
    // - IERC721: 0x80ac58cd
    // - IERC721Metadata: 0x5b5e139f
    // - IERC2981: 0x2a55205a
    return
      ERC721AUpgradeable.supportsInterface(interfaceId) ||
      ERC2981Upgradeable.supportsInterface(interfaceId);
  }

  function setDefaultRoyalty(address receiver, uint16 feeNumerator) public _onlyOwner {
    config.defaultRoyalty = feeNumerator;
    _setDefaultRoyalty(receiver, feeNumerator);
  }
}
