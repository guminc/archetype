// SPDX-License-Identifier: MIT
// Archetype v10.0
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
import "../IArchetypeBatch.sol";
import {MintFeeRegistry} from "../MintFeeRegistry.sol";
import {AffiliateSignerRegistry} from "../AffiliateSignerRegistry.sol";
import {
    MintConstraints,
    BurnConstraints,
    UnexpectedMintCurrency,
    InsufficientMintOutput,
    ExcessiveNativeValue,
    UnexpectedBurnCollection,
    UnexpectedBurnRecipient
} from "../MintConstraints.sol";
import "erc721a-upgradeable/contracts/ERC721AUpgradeable.sol";
import "erc721a-upgradeable/contracts/ERC721A__Initializable.sol";
import "erc721a-upgradeable/contracts/extensions/ERC721AQueryableUpgradeable.sol";
import "erc721a-upgradeable/contracts/ERC721A__InitializableStorage.sol";
import "./ERC721A__OwnableUpgradeable.sol";
import "solady/src/utils/LibString.sol";
import "openzeppelin-v4-upgradeable/token/common/ERC2981Upgradeable.sol";
import "../TransientReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract ArchetypeErc721a is
    ERC721A__Initializable,
    ERC721AUpgradeable,
    ERC721A__OwnableUpgradeable,
    ERC2981Upgradeable,
    TransientReentrancyGuard,
    ERC721AQueryableUpgradeable
{
    using SafeERC20 for IERC20;

    event Invited(bytes32 indexed key, bytes32 indexed cid);
    event BurnInvited(bytes32 indexed key, bytes32 indexed cid);
    event Referral(address indexed affiliate, address token, uint128 wad, uint256 numMints, uint256 paymentValue);

    address private immutable _platform;
    address private immutable _payouts;
    address private immutable _batch;
    MintFeeRegistry public immutable mintFeeRegistry;
    AffiliateSignerRegistry public immutable affiliateSignerRegistry;

    mapping(bytes32 => Invite) public invites;
    mapping(bytes32 => uint256) public packedBonusDiscounts;
    mapping(bytes32 => BurnInvite) public burnInvites;
    mapping(address => mapping(bytes32 => uint256)) private _minted;
    mapping(bytes32 => uint256) private _listSupply;

    Config public config;
    PayoutConfig public payoutConfig;
    Options public options;

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
        ERC721A__InitializableStorage.layout()._initialized = true;
    }

    function initialize(
        string memory name,
        string memory symbol,
        Config calldata config_,
        PayoutConfig calldata payoutConfig_,
        address _receiver
    ) external initializerERC721A {
        __ERC721A_init(name, symbol);
        // check max bps not reached and min platform fee.
        if (config_.affiliateFee > MAXBPS || config_.affiliateDiscount > MAXBPS || config_.maxBatchSize == 0) {
            revert InvalidConfig();
        }
        config = config_;
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

    function mint(
        Auth calldata auth,
        uint256 quantity,
        address affiliate,
        bytes calldata signature,
        MintConstraints memory constraints
    ) external payable {
        mintTo(auth, quantity, _msgSender(), affiliate, signature, constraints);
    }

    function batchMintTo(Auth calldata auth, Erc721BatchMint calldata mintArgs)
        external
        payable
        nonReentrant
        _onlyOwner
    {
        if (mintArgs.quantities.length != mintArgs.recipients.length) {
            revert InvalidConfig();
        }

        Invite storage invite = invites[auth.key];
        uint256 packedDiscount = packedBonusDiscounts[auth.key];
        uint256 curSupply = _totalMinted();

        (uint256 totalQuantity, uint256 totalBonusMints) =
            _batchMintTotals(mintArgs.quantities, invite.unitSize, packedDiscount);

        validateAndCreditMint(
            invite,
            auth,
            totalQuantity,
            totalBonusMints,
            curSupply,
            mintArgs.affiliate,
            mintArgs.affiliateAuthorization,
            mintArgs.constraints
        );

        _safeBatchMint(mintArgs.recipients, mintArgs.quantities, invite.unitSize, packedDiscount);
    }

    function _batchMintTotals(uint256[] calldata quantityList, uint32 unitSize, uint256 packedDiscount)
        internal
        view
        returns (uint256 totalQuantity, uint256 totalBonusMints)
    {
        uint256 unitMultiplier = unitSize > 1 ? unitSize : 1;
        for (uint256 i; i < quantityList.length; ++i) {
            uint256 quantity = quantityList[i] * unitMultiplier;
            totalQuantity += quantity;
            totalBonusMints += ArchetypeLogicErc721a.bonusMintsAwarded(quantity, packedDiscount);
        }
    }

    function _safeBatchMint(
        address[] calldata toList,
        uint256[] calldata quantityList,
        uint32 unitSize,
        uint256 packedDiscount
    ) internal {
        uint256 unitMultiplier = unitSize > 1 ? unitSize : 1;
        for (uint256 i; i < toList.length; ++i) {
            uint256 quantity = quantityList[i] * unitMultiplier;
            uint256 bonusMints = ArchetypeLogicErc721a.bonusMintsAwarded(quantity, packedDiscount);
            _safeMint(toList[i], quantity + bonusMints);
        }
    }

    function mintTo(
        Auth calldata auth,
        uint256 quantity,
        address to,
        address affiliate,
        bytes calldata signature,
        MintConstraints memory constraints
    ) public payable nonReentrant {
        Invite storage invite = invites[auth.key];
        uint256 packedDiscount = packedBonusDiscounts[auth.key];

        if (invite.unitSize > 1) {
            quantity = quantity * invite.unitSize;
        }

        uint256 curSupply = _totalMinted();

        uint256 numBonusMints = ArchetypeLogicErc721a.bonusMintsAwarded(quantity, packedDiscount);
        validateAndCreditMint(invite, auth, quantity, numBonusMints, curSupply, affiliate, signature, constraints);
        _safeMint(to, quantity + numBonusMints);
    }

    function validateAndCreditMint(
        Invite storage invite,
        Auth calldata auth,
        uint256 quantity,
        uint256 numBonusMints,
        uint256 curSupply,
        address affiliate,
        bytes calldata signature,
        MintConstraints memory constraints
    ) internal {
        uint256 totalQuantity = quantity + numBonusMints;
        if (invite.tokenAddress != constraints.currency) revert UnexpectedMintCurrency();
        if (totalQuantity < constraints.minTotalMints) revert InsufficientMintOutput();
        ValidationArgs memory args;
        {
            args = ValidationArgs({
                owner: owner(),
                sender: _msgSender(),
                affiliate: affiliate,
                quantity: totalQuantity,
                curSupply: curSupply,
                listSupply: _listSupply[auth.key]
            });
        }

        bool isPublic = ArchetypeLogicErc721a.isPublicInvite(invite, auth.key);
        MintPayment memory payment = ArchetypeLogicErc721a.computeMintPayment(
            invite,
            config,
            payoutConfig,
            auth.key,
            quantity,
            args.affiliate != address(0),
            isPublic ? mintFeeRegistry.nativeMinimumFee() : 0
        );
        if (payment.currencyCost > constraints.maxCurrencyCost) revert ExcessiveCurrencyCost();
        if (payment.nativeValue > constraints.maxNativeValue) revert ExcessiveNativeValue();

        ArchetypeAddresses memory addrs = archetypeAddresses();
        ArchetypeLogicErc721a.validateMint(
            addrs,
            invite,
            config,
            auth,
            _minted,
            signature,
            affiliateSignerRegistry,
            args,
            payment.currencyCost,
            payment.nativeValue
        );

        if (invite.limit < invite.maxSupply) {
            _minted[args.sender][auth.key] += totalQuantity;
        }
        if (invite.maxSupply < UINT32_MAX) {
            _listSupply[auth.key] = args.listSupply + totalQuantity;
        }

        ArchetypeLogicErc721a.updateBalances(
            addrs,
            invite.tokenAddress,
            config,
            payoutConfig,
            args.owner,
            args.sender,
            affiliate,
            quantity,
            payment.currencyCost,
            payment.platformSurcharge
        );

        if (msg.value > payment.nativeValue) {
            _refund(args.sender, msg.value - payment.nativeValue);
        }
    }

    function burnToMint(Auth calldata auth, uint256[] calldata tokenIds, BurnConstraints memory constraints)
        external
        payable
        nonReentrant
    {
        BurnInvite storage burnInvite = burnInvites[auth.key];

        uint128 cost = burnInvite.price;
        IERC721 burnCollection = burnInvite.burnErc721;
        address paymentToken = burnInvite.tokenAddress;
        uint16 ratio = burnInvite.ratio;
        bool reversed = burnInvite.reversed;
        uint256 quantity = reversed ? tokenIds.length * ratio : tokenIds.length / ratio;
        address burnRecipient = burnInvite.burnAddress != address(0)
            ? burnInvite.burnAddress
            : address(0x000000000000000000000000000000000000dEaD);
        if (address(burnCollection) != constraints.burnCollection) revert UnexpectedBurnCollection();
        if (burnRecipient != constraints.burnRecipient) revert UnexpectedBurnRecipient();
        if (paymentToken != constraints.mint.currency) revert UnexpectedMintCurrency();
        if (quantity < constraints.mint.minTotalMints) revert InsufficientMintOutput();
        if (cost > constraints.mint.maxCurrencyCost) revert ExcessiveCurrencyCost();
        ArchetypeLogicErc721a.validateBurnToMint(
            archetypeAddresses(), burnInvite, config, auth, tokenIds, _totalMinted(), _minted, cost
        );

        address msgSender = _msgSender();
        for (uint256 i; i < tokenIds.length;) {
            burnCollection.transferFrom(msgSender, burnRecipient, tokenIds[i]);
            unchecked {
                ++i;
            }
        }

        _safeMint(msgSender, quantity);

        if (burnInvite.limit < config.maxSupply) {
            _minted[msgSender][keccak256(abi.encodePacked("burn", auth.key))] += quantity;
        }

        ArchetypeLogicErc721a.updateBalances(
            archetypeAddresses(),
            paymentToken,
            config,
            payoutConfig,
            owner(),
            msgSender,
            address(0), // burn to mint does not support affiliates
            quantity,
            cost,
            0
        );

        if (msg.value > cost) {
            _refund(msgSender, msg.value - cost);
        }
    }

    function tokenURI(uint256 tokenId)
        public
        view
        virtual
        override(ERC721AUpgradeable, IERC721AUpgradeable)
        returns (string memory)
    {
        if (!_exists(tokenId)) revert URIQueryForNonexistentToken();

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

    function computePrice(bytes32 key, uint256 quantity, bool affiliateUsed) external view returns (uint256) {
        Invite storage i = invites[key];
        return ArchetypeLogicErc721a.computePrice(i, config.affiliateDiscount, quantity, affiliateUsed);
    }

    function computeMintPayment(bytes32 key, uint256 quantity, bool affiliateUsed)
        external
        view
        returns (uint256 currencyCost, uint256 nativeValue, address currency, uint256 totalMints)
    {
        Invite storage invite = invites[key];
        uint256 paidQuantity = invite.unitSize > 1 ? quantity * invite.unitSize : quantity;
        MintPayment memory payment = ArchetypeLogicErc721a.computeMintPayment(
            invite,
            config,
            payoutConfig,
            key,
            paidQuantity,
            affiliateUsed,
            ArchetypeLogicErc721a.isPublicInvite(invite, key) ? mintFeeRegistry.nativeMinimumFee() : 0
        );
        uint256 bonusMints = ArchetypeLogicErc721a.bonusMintsAwarded(paidQuantity, packedBonusDiscounts[key]);
        return (payment.currencyCost, payment.nativeValue, invite.tokenAddress, paidQuantity + bonusMints);
    }

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
    function setMaxSupply(uint32 maxSupply, string memory password) external nonReentrant _onlyOwner {
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
    function lockMaxSupply(string memory password) external nonReentrant _onlyOwner {
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

    function setBonusDiscounts(bytes32 _key, BonusDiscount[] calldata _bonusDiscounts) public _onlyOwner {
        if (_bonusDiscounts.length > 8) {
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
        Invite calldata _invite,
        BonusDiscount[] calldata _bonusDiscount
    ) external _onlyOwner {
        setBonusDiscounts(_key, _bonusDiscount);
        _setInvite(_key, _cid, _invite);
    }

    function setInvite(bytes32 _key, bytes32 _cid, Invite calldata _invite) external _onlyOwner {
        _setInvite(_key, _cid, _invite);
    }

    function _setInvite(bytes32 _key, bytes32 _cid, Invite memory invite) internal {
        // approve token for withdrawals if erc20 list
        if (invite.tokenAddress != address(0)) {
            IERC20(invite.tokenAddress).forceApprove(_payouts, type(uint256).max);
        }
        invites[_key] = invite;
        emit Invited(_key, _cid);
    }

    function setBurnInvite(bytes32 _key, bytes32 _cid, BurnInvite memory _burnInvite) external nonReentrant _onlyOwner {
        if (_burnInvite.tokenAddress != address(0)) {
            IERC20(_burnInvite.tokenAddress).forceApprove(_payouts, type(uint256).max);
        }
        burnInvites[_key] = _burnInvite;
        emit BurnInvited(_key, _cid);
    }

    function _startTokenId() internal view virtual override returns (uint256) {
        return 1;
    }

    function _msgSender() internal view returns (address) {
        if (msg.sender != _batch) return msg.sender;
        address caller = IArchetypeBatch(_batch).currentCaller();
        return caller == address(0) ? msg.sender : caller;
    }

    modifier _onlyPlatform() {
        if (_msgSender() != _platform) {
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
        override(IERC721AUpgradeable, ERC721AUpgradeable, ERC2981Upgradeable)
        returns (bool)
    {
        // Supports the following `interfaceId`s:
        // - IERC165: 0x01ffc9a7
        // - IERC721: 0x80ac58cd
        // - IERC721Metadata: 0x5b5e139f
        // - IERC2981: 0x2a55205a
        return ERC721AUpgradeable.supportsInterface(interfaceId) || ERC2981Upgradeable.supportsInterface(interfaceId);
    }

    function setDefaultRoyalty(address receiver, uint16 feeNumerator) public _onlyOwner {
        config.defaultRoyalty = feeNumerator;
        _setDefaultRoyalty(receiver, feeNumerator);
    }
}
