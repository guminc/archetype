// SPDX-License-Identifier: MIT
// Archetype v10.0 - ERC1155
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
import "../IArchetypeBatch.sol";
import {MintFeeRegistry} from "../MintFeeRegistry.sol";
import {AffiliateSignerRegistry} from "../AffiliateSignerRegistry.sol";
import {
    MintConstraints,
    UnexpectedMintCurrency,
    InsufficientMintOutput,
    ExcessiveNativeValue
} from "../MintConstraints.sol";
import "openzeppelin-v4-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "openzeppelin-v4-upgradeable/access/OwnableUpgradeable.sol";
import "openzeppelin-v4-upgradeable/proxy/utils/Initializable.sol";
import "openzeppelin-v4-upgradeable/token/common/ERC2981Upgradeable.sol";
import "../TransientReentrancyGuard.sol";
import "solady/src/utils/LibString.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract ArchetypeErc1155 is
    Initializable,
    ERC1155Upgradeable,
    OwnableUpgradeable,
    ERC2981Upgradeable,
    TransientReentrancyGuard
{
    using SafeERC20 for IERC20;

    event Invited(bytes32 indexed key, bytes32 indexed cid);
    event Referral(address indexed affiliate, address token, uint128 wad, uint256 numMints, uint256 paymentValue);

    mapping(bytes32 => Invite) public invites;
    mapping(address => mapping(bytes32 => uint256)) private _minted;
    mapping(bytes32 => uint256) private _listSupply;

    uint256[] private _tokenSupply;

    address private immutable _platform;
    address private immutable _payouts;
    address private immutable _batch;
    MintFeeRegistry public immutable mintFeeRegistry;
    AffiliateSignerRegistry public immutable affiliateSignerRegistry;

    Config public config;
    PayoutConfig public payoutConfig;
    Options public options;

    string public name;
    string public symbol;

    constructor(
        address platform,
        address payouts,
        address batch,
        MintFeeRegistry feeRegistry,
        AffiliateSignerRegistry signerRegistry
    ) {
        if (address(feeRegistry).code.length == 0) revert InvalidConfig();
        if (address(signerRegistry).code.length == 0) revert InvalidConfig();
        if (payouts.code.length == 0) revert InvalidPayouts();
        if (batch == address(0) || batch.code.length == 0) revert InvalidConfig();
        _platform = platform;
        _payouts = payouts;
        _batch = batch;
        mintFeeRegistry = feeRegistry;
        affiliateSignerRegistry = signerRegistry;
        _disableInitializers();
    }

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
        if (config_.affiliateFee > MAXBPS || config_.affiliateDiscount > MAXBPS || config_.maxBatchSize == 0) {
            revert InvalidConfig();
        }
        config = config_;
        _tokenSupply = new uint256[](config_.maxSupply.length);
        __Ownable_init();
        uint256 totalShares = payoutConfig_.ownerBps + payoutConfig_.platformBps + payoutConfig_.partnerBps
            + payoutConfig_.superAffiliateBps;

        if (
            payoutConfig_.platformBps < 500 || totalShares != 10000
                || (payoutConfig_.partnerBps > 0 && payoutConfig_.partner == address(0))
                || (payoutConfig_.superAffiliateBps > 0 && payoutConfig_.superAffiliate == address(0))
        ) {
            revert InvalidSplitShares();
        }
        payoutConfig = payoutConfig_;
        setDefaultRoyalty(_receiver, config.defaultRoyalty);
    }

    function mintToken(
        Auth calldata auth,
        uint256 quantity,
        uint256 tokenId,
        address affiliate,
        bytes calldata signature,
        MintConstraints memory constraints
    ) external payable {
        mintTo(auth, quantity, _msgSender(), tokenId, affiliate, signature, constraints);
    }

    function batchMintTo(Auth calldata auth, Erc1155BatchMint calldata mintArgs) external payable nonReentrant {
        if (
            mintArgs.quantities.length != mintArgs.recipients.length
                || mintArgs.quantities.length != mintArgs.tokenIds.length
        ) {
            revert InvalidConfig();
        }

        uint256 quantity;
        for (uint256 i = 0; i < mintArgs.quantities.length; i++) {
            quantity += mintArgs.quantities[i];
        }

        ValidationArgs memory args;
        {
            address sender = _msgSender();
            args = ValidationArgs({
                owner: owner(),
                sender: sender,
                affiliate: mintArgs.affiliate,
                quantities: mintArgs.quantities,
                tokenIds: mintArgs.tokenIds,
                totalQuantity: quantity,
                listSupply: _listSupply[auth.key]
            });
        }

        Invite storage invite = invites[auth.key];

        if (invite.unitSize > 1) {
            revert NotSupported();
        }

        validateAndCreditMint(
            invite, auth, args, mintArgs.affiliate, mintArgs.affiliateAuthorization, mintArgs.constraints
        );

        bytes memory _data;
        for (uint256 i = 0; i < mintArgs.recipients.length; i++) {
            _mint(mintArgs.recipients[i], mintArgs.tokenIds[i], mintArgs.quantities[i], _data);
        }
    }

    function mintTo(
        Auth calldata auth,
        uint256 quantity,
        address to,
        uint256 tokenId,
        address affiliate,
        bytes calldata signature,
        MintConstraints memory constraints
    ) public payable nonReentrant {
        if (to == address(0)) {
            revert MintToZeroAddress();
        }

        Invite storage invite = invites[auth.key];

        if (invite.unitSize > 1) {
            quantity = quantity * invite.unitSize;
        }

        ValidationArgs memory args;
        {
            address sender = _msgSender();
            uint256[] memory tokenIds = new uint256[](1);
            tokenIds[0] = tokenId;
            uint256[] memory quantities = new uint256[](1);
            quantities[0] = quantity;
            args = ValidationArgs({
                owner: owner(),
                sender: sender,
                affiliate: affiliate,
                quantities: quantities,
                tokenIds: tokenIds,
                totalQuantity: quantity,
                listSupply: _listSupply[auth.key]
            });
        }

        validateAndCreditMint(invite, auth, args, affiliate, signature, constraints);

        for (uint256 j = 0; j < args.tokenIds.length; j++) {
            bytes memory _data;
            _mint(to, args.tokenIds[j], args.quantities[j], _data);
        }
    }

    function validateAndCreditMint(
        Invite storage invite,
        Auth calldata auth,
        ValidationArgs memory args,
        address affiliate,
        bytes calldata signature,
        MintConstraints memory constraints
    ) internal {
        if (invite.tokenAddress != constraints.currency) {
            revert UnexpectedMintCurrency();
        }
        if (args.totalQuantity < constraints.minTotalMints) revert InsufficientMintOutput();
        bool isPublic = ArchetypeLogicErc1155.isPublicInvite(invite, auth.key);
        MintPayment memory payment = ArchetypeLogicErc1155.computeMintPayment(
            invite,
            config,
            payoutConfig,
            auth.key,
            args.totalQuantity,
            args.affiliate != address(0),
            isPublic ? mintFeeRegistry.nativeMinimumFee() : 0
        );
        if (payment.currencyCost > constraints.maxCurrencyCost) revert ExcessiveCurrencyCost();
        if (payment.nativeValue > constraints.maxNativeValue) revert ExcessiveNativeValue();

        ArchetypeAddresses memory addrs = archetypeAddresses();
        ArchetypeLogicErc1155.validateMint(
            addrs,
            invite,
            config,
            auth,
            _minted,
            _tokenSupply,
            signature,
            affiliateSignerRegistry,
            args,
            payment.currencyCost,
            payment.nativeValue
        );

        for (uint256 i = 0; i < args.tokenIds.length; i++) {
            _tokenSupply[args.tokenIds[i] - 1] += args.quantities[i];
        }

        if (invite.limit < invite.maxSupply) {
            _minted[args.sender][auth.key] += args.totalQuantity;
        }
        if (invite.maxSupply < 2 ** 32 - 1) {
            _listSupply[auth.key] = args.listSupply + args.totalQuantity;
        }

        ArchetypeLogicErc1155.updateBalances(
            addrs,
            invite,
            config,
            payoutConfig,
            args.owner,
            args.sender,
            affiliate,
            args.totalQuantity,
            payment.currencyCost,
            payment.platformSurcharge
        );

        if (msg.value > payment.nativeValue) {
            _refund(args.sender, msg.value - payment.nativeValue);
        }
    }

    function uri(uint256 tokenId) public view override returns (string memory) {
        return
            bytes(config.baseUri).length != 0
                ? string(abi.encodePacked(config.baseUri, LibString.toString(tokenId)))
                : "";
    }

    function minted(address minter, bytes32 key) external view returns (uint256) {
        return _minted[minter][key];
    }

    function listSupply(bytes32 key) external view returns (uint256) {
        return _listSupply[key];
    }

    function archetypeAddresses() public view returns (ArchetypeAddresses memory) {
        return ArchetypeAddresses({platform: _platform, payouts: _payouts, batch: _batch});
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

    function computePrice(bytes32 key, uint256 quantity, bool affiliateUsed) external view returns (uint256) {
        Invite storage i = invites[key];
        return ArchetypeLogicErc1155.computePrice(i, config.affiliateDiscount, quantity, affiliateUsed);
    }

    function computeMintPayment(bytes32 key, uint256 quantity, bool affiliateUsed)
        external
        view
        returns (uint256 currencyCost, uint256 nativeValue, address currency, uint256 totalMints)
    {
        Invite storage invite = invites[key];
        uint256 paidQuantity = invite.unitSize > 1 ? quantity * invite.unitSize : quantity;
        MintPayment memory payment = ArchetypeLogicErc1155.computeMintPayment(
            invite,
            config,
            payoutConfig,
            key,
            paidQuantity,
            affiliateUsed,
            ArchetypeLogicErc1155.isPublicInvite(invite, key) ? mintFeeRegistry.nativeMinimumFee() : 0
        );
        return (payment.currencyCost, payment.nativeValue, invite.tokenAddress, paidQuantity);
    }

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
    function setMaxSupply(uint32[] memory newMaxSupply, string memory password) external nonReentrant onlyOwner {
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
    function lockMaxSupply(string memory password) external nonReentrant _onlyOwner {
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

    function setInvite(bytes32 _key, bytes32 _cid, Invite calldata _invite) external _onlyOwner {
        Invite memory invite = _invite;
        // approve token for withdrawals if erc20 list
        if (invite.tokenAddress != address(0)) {
            IERC20(invite.tokenAddress).forceApprove(_payouts, type(uint256).max);
        }
        invites[_key] = invite;
        emit Invited(_key, _cid);
    }

    function _startTokenId() internal view virtual returns (uint256) {
        return 1;
    }

    function _exists(uint256 tokenId) internal view returns (bool) {
        return tokenId > 0 && tokenId <= _tokenSupply.length;
    }

    function _msgSender() internal view override returns (address) {
        if (msg.sender != _batch) return msg.sender;
        address caller = IArchetypeBatch(_batch).currentCaller();
        return caller == address(0) ? msg.sender : caller;
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
        if (_msgSender() != _platform) {
            revert NotPlatform();
        }
        _;
    }

    modifier _onlyOwner() {
        _isOwner();
        _;
    }

    function _refund(address to, uint256 refund) internal {
        (bool success,) = payable(to).call{value: refund}("");
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
        return ERC1155Upgradeable.supportsInterface(interfaceId) || ERC2981Upgradeable.supportsInterface(interfaceId);
    }

    function setDefaultRoyalty(address receiver, uint16 feeNumerator) public _onlyOwner {
        config.defaultRoyalty = feeNumerator;
        _setDefaultRoyalty(receiver, feeNumerator);
    }
}
