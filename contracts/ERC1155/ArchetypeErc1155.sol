// SPDX-License-Identifier: MIT
// Archetype v0.8.0 - ERC1155
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

import "./ArchetypeLogicErc1155.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol";
import "solady/src/utils/LibString.sol";

contract ArchetypeErc1155 is Initializable, ERC1155Upgradeable, OwnableUpgradeable, ERC2981Upgradeable {
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

  uint256[] private _tokenSupply;

  Config public config;
  PayoutConfig public payoutConfig;
  Options public options;

  string public name;
  string public symbol;

  //
  // METHODS
  //
  function initialize(
    string memory _name,
    string memory _symbol,
    Config calldata config_,
    PayoutConfig calldata payoutConfig_,
    address _receiver
  ) external initializer {
    name = _name;
    symbol = _symbol;
    __ERC1155_init("");

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
    _tokenSupply = new uint256[](config_.maxSupply.length);
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

  function mintToken(
    Auth calldata auth,
    uint256 quantity,
    uint256 tokenId,
    address affiliate,
    bytes calldata signature
  ) external payable {
    mintTo(auth, quantity, msg.sender, tokenId, affiliate, signature);
  }

  function batchMintTo(
    Auth calldata auth,
    address[] calldata toList,
    uint256[] calldata quantityList,
    uint256[] calldata tokenIdList,
    address affiliate,
    bytes calldata signature
  ) external payable {
    if (quantityList.length != toList.length || quantityList.length != tokenIdList.length) {
      revert InvalidConfig();
    }

    uint256 quantity;
    for (uint256 i = 0; i < quantityList.length; i++) {
      quantity += quantityList[i];
    }

    ValidationArgs memory args;
    {
      args = ValidationArgs({
        owner: owner(),
        affiliate: affiliate,
        quantities: quantityList,
        tokenIds: tokenIdList,
        totalQuantity: quantity,
        listSupply: _listSupply[auth.key]
      });
    }

    AdvancedInvite storage invite = invites[auth.key];

    if (invite.unitSize > 1) {
      revert NotSupported();
    }

    validateAndCreditMint(invite, auth, args, affiliate, signature);

    for (uint256 i = 0; i < toList.length; i++) {
      bytes memory _data;
      _mint(toList[i], tokenIdList[i], quantityList[i], _data);
      _tokenSupply[tokenIdList[i] - 1] += quantityList[i];
    }
  }

  function mintTo(
    Auth calldata auth,
    uint256 quantity,
    address to,
    uint256 tokenId,
    address affiliate,
    bytes calldata signature
  ) public payable {

    if (to == address(0)) {
      revert MintToZeroAddress();
    }

    AdvancedInvite storage invite = invites[auth.key];

    if (invite.unitSize > 1) {
      quantity = quantity * invite.unitSize;
    }

    ValidationArgs memory args;
    {
      uint256[] memory tokenIds = new uint256[](1);
      tokenIds[0] = tokenId;
      uint256[] memory quantities = new uint256[](1);
      quantities[0] = quantity;
      args = ValidationArgs({
        owner: owner(),
        affiliate: affiliate,
        quantities: quantities,
        tokenIds: tokenIds,
        totalQuantity: quantity,
        listSupply: _listSupply[auth.key]
      });
    }

    validateAndCreditMint(invite, auth, args, affiliate, signature);

    for (uint256 j = 0; j < args.tokenIds.length; j++) {
      bytes memory _data;
      _mint(to, args.tokenIds[j], args.quantities[j], _data);
      _tokenSupply[args.tokenIds[j] - 1] += args.quantities[j];
    }
  }

  function validateAndCreditMint(
      AdvancedInvite storage invite,
      Auth calldata auth,
      ValidationArgs memory args,
      address affiliate,
      bytes calldata signature
    ) internal {

     uint128 cost = uint128(
      ArchetypeLogicErc1155.computePrice(
        invite,
        config.affiliateDiscount,
        args.totalQuantity,
        args.listSupply,
        args.affiliate != address(0)
      )
    );
    
    ArchetypeLogicErc1155.validateMint(
      invite,
      config,
      auth,
      _minted,
      _tokenSupply,
      signature,
      args,
      cost
    );

    if (invite.limit < invite.maxSupply) {
      _minted[msg.sender][auth.key] += args.totalQuantity;
    }
    if (invite.maxSupply < 2**32 - 1) {
      _listSupply[auth.key] += args.totalQuantity;
    }

    ArchetypeLogicErc1155.updateBalances(
      invite,
      config,
      _ownerBalance,
      _affiliateBalance,
      affiliate,
      args.totalQuantity,
      cost
    );

    if (msg.value > cost) {
      _refund(_msgSender(), msg.value - cost);
    }
  }

  function uri(uint256 tokenId) public view override returns (string memory) {
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
    ArchetypeLogicErc1155.withdrawTokens(payoutConfig, _ownerBalance, owner(), tokens);
  }

  function withdrawAffiliate() external {
    address[] memory tokens = new address[](1);
    tokens[0] = address(0);
    withdrawTokensAffiliate(tokens);
  }

  function withdrawTokensAffiliate(address[] memory tokens) public {
    ArchetypeLogicErc1155.withdrawTokensAffiliate(_affiliateBalance, tokens);
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

  function tokenSupply(uint256 tokenId) external view returns (uint256) {
    if (!_exists(tokenId)) revert URIQueryForNonexistentToken();
    return _tokenSupply[tokenId - 1];
  }

  function totalSupply() external view returns (uint256) {
    uint256 supply = 0;
    for (uint256 i = 0; i < _tokenSupply.length; i++) {
      supply += _tokenSupply[i];
    }
    return supply;
  }

  function maxSupply() external view returns (uint32[] memory) {
    return config.maxSupply;
  }

  function computePrice(
    bytes32 key,
    uint256 quantity,
    bool affiliateUsed
  ) external view returns (uint256) {
    AdvancedInvite storage i = invites[key];
    uint256 listSupply_ = _listSupply[key];
    return ArchetypeLogicErc1155.computePrice(i, config.affiliateDiscount, quantity, listSupply_, affiliateUsed);
  }

  //
  // OWNER ONLY
  //

  function setBaseURI(string memory baseUri) external onlyOwner {
    if (options.uriLocked) {
      revert LockedForever();
    }

    config.baseUri = baseUri;
  }

  /// @notice the password is "forever"
  function lockURI(string memory password) external _onlyOwner {
    _checkPassword(password);
    options.uriLocked = true;
  }

  /// @notice the password is "forever"
  // max supply cannot subceed total supply. Be careful changing.
  function setMaxSupply(uint32[] memory newMaxSupply, string memory password) external onlyOwner {
    if (keccak256(abi.encodePacked(password)) != keccak256(abi.encodePacked("forever"))) {
      revert WrongPassword();
    }

    if (options.maxSupplyLocked) {
      revert LockedForever();
    }

    for (uint256 i = 0; i < _tokenSupply.length; i++) {
      if (newMaxSupply[i] < _tokenSupply[i]) {
        revert MaxSupplyExceeded();
      }
    }

    // increase size of token supply array to match new max supply
    for (uint256 i = _tokenSupply.length; i < newMaxSupply.length; i++) {
      _tokenSupply.push(0);
    }
    config.maxSupply = newMaxSupply;
  }

  /// @notice the password is "forever"
  function lockMaxSupply(string memory password) external _onlyOwner {
    _checkPassword(password);
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
    _checkPassword(password);
    options.affiliateFeeLocked = true;
  }

  function setOwnerAltPayout(address ownerAltPayout) external _onlyOwner {
    if (options.ownerAltPayoutLocked) {
      revert LockedForever();
    }

    payoutConfig.ownerAltPayout = ownerAltPayout;
  }

  /// @notice the password is "forever"
  function lockOwnerAltPayout(string memory password) external _onlyOwner {
    _checkPassword(password);
    options.ownerAltPayoutLocked = true;
  }

  function setMaxBatchSize(uint16 maxBatchSize) external _onlyOwner {
    config.maxBatchSize = maxBatchSize;
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
      tokenIds: _invite.tokenIds,
      tokenAddress: _invite.tokenAddress
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

  //
  // INTERNAL
  //
  function _startTokenId() internal view virtual returns (uint256) {
    return 1;
  }

  function _exists(uint256 tokenId) internal view returns (bool) {
    return tokenId > 0 && tokenId <= _tokenSupply.length;
  }

  function _msgSender() internal view override returns (address) {
    return msg.sender == BATCH ? tx.origin : msg.sender;
  }

  function _checkPassword(string memory password) internal pure {
    if (keccak256(abi.encodePacked(password)) != keccak256(abi.encodePacked("forever"))) {
      revert WrongPassword();
    }
  }

  function _isOwner() internal view {
    if (_msgSender() != owner()) {
      revert NotOwner();
    }
  }

  modifier _onlyPlatform() {
    if (_msgSender() != PLATFORM) {
      revert NotPlatform();
    }
    _;
  }

  modifier _onlyOwner() {
    _isOwner();
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
    override(ERC1155Upgradeable, ERC2981Upgradeable)
    returns (bool)
  {
    // Supports the following `interfaceId`s:
    // - IERC165: 0x01ffc9a7
    // - IERC721: 0x80ac58cd
    // - IERC721Metadata: 0x5b5e139f
    // - IERC2981: 0x2a55205a
    return
      ERC1155Upgradeable.supportsInterface(interfaceId) ||
      ERC2981Upgradeable.supportsInterface(interfaceId);
  }

  function setDefaultRoyalty(address receiver, uint16 feeNumerator) public _onlyOwner {
    config.defaultRoyalty = feeNumerator;
    _setDefaultRoyalty(receiver, feeNumerator);
  }
}
