// forge-lint: disable-start(asm-keccak256, block-timestamp)

// SPDX-License-Identifier: BUSL-1.1
// ScatterOfferer v0.3.0
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

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ContractOffererInterface} from "seaport-types/src/interfaces/ContractOffererInterface.sol";
import {ItemType, ReceivedItem, Schema, SpentItem} from "seaport-types/src/lib/ConsiderationStructs.sol";
import {ScatterCollectionRegistry} from "./ScatterCollectionRegistry.sol";
import {ConduitConsumer} from "./ConduitConsumer.sol";
import {ConduitTransfer} from "seaport-types/src/conduit/lib/ConduitStructs.sol";
import {ConduitItemType} from "seaport-types/src/conduit/lib/ConduitEnums.sol";

error OnlySeaport();
error OrderExpired();
error OrderCancelled();
error InvalidSignature();
error NonceMismatch();
error CurrencyMismatch();
error QuantityExceeded();
error InvalidCriteriaProof();
error TokenIdNotZeroForCriteria();
error InvalidRole();
error InvalidAssetType();
error EmptySpec();
error InvalidRouter();
error InvalidFill();
error DuplicateListingItem();
error InvalidScatterCollectionRegistry();
error InvalidFeeAuthorizer();
error InvalidFeeAuthorization();
error FeeAuthorizationExpired();
error InvalidRoutedFulfiller();
error InvalidFeeBps();
error InvalidFeeSplitBps();
error FeeBpsExceedsLimit(uint256 currentFeeBps, uint256 maximumFeeBps);

contract ScatterOfferer is ContractOffererInterface, EIP712, Ownable2Step, Pausable, ReentrancyGuard, ConduitConsumer {
    using SafeERC20 for IERC20;

    address public immutable SEAPORT =
        block.chainid == 4326 ? 0x00000000006687982678b03100B9bDC8be440814 : 0x0000000000000068F116a894984e2DB1123eB395;
    address public constant PLATFORM = 0x8952caF7E5bf1fe63ebe94148ca802F3eF127C98;

    uint256 public constant DEFAULT_FEE_BPS = 500; // 5%
    uint256 public constant MAX_FEE_BPS = 5000; // 50%
    uint256 public constant DEFAULT_FEE_SPLIT_BPS = 5000;
    uint256 public constant BPS_DENOMINATOR = 10000; // 100%

    bytes4 private constant RATIFY_ORDER_MAGIC_VALUE = ContractOffererInterface.ratifyOrder.selector;

    bytes32 public constant SCATTER_LISTING_TYPEHASH = keccak256(
        "ScatterListing(uint8 assetType,address collection,uint256 tokenId,uint256 quantity,address currency,uint256 priceWei)"
    );
    bytes32 public constant SCATTER_SUBMISSION_TYPEHASH = keccak256(
        "ScatterSubmission(uint8 role,ScatterListing[] listings,bytes32 criteriaRoot,uint256 maxFeeBps,uint256 startTime,uint256 endTime,uint256 nonce,bytes32 salt)ScatterListing(uint8 assetType,address collection,uint256 tokenId,uint256 quantity,address currency,uint256 priceWei)"
    );

    enum Role {
        Listing, // the signer is a seller offering an NFT for sale.
        Bid // the signer is a buyer offering to purchase an NFT.
    }

    enum AssetType {
        ERC721,
        ERC1155
    }

    struct ScatterListing {
        AssetType assetType;
        address collection;
        uint256 tokenId;
        uint256 quantity;
        address currency;
        uint256 priceWei;
    }

    struct ScatterSubmission {
        Role role;
        ScatterListing[] listings;
        bytes32 criteriaRoot; // Bids only. Merkle root of accepted token IDs
        uint256 maxFeeBps;
        uint256 startTime;
        uint256 endTime;
        uint256 nonce;
        bytes32 salt;
    }

    struct ScatterFill {
        uint256 itemIndex;
        uint256 tokenId;
        uint256 quantity;
    }

    struct SeaportFillInput {
        ScatterSubmission submission;
        bytes submissionSig;
        address affiliate;
        ScatterFill[] fills;
        bytes32[][] criteriaProofs;
        uint256 feeAuthorizationDeadline;
        bytes feeAuthorizationSignature;
    }

    struct ValidatedFillData {
        bytes32 submissionHash;
        address signer;
        uint256 totalFillPrice;
    }

    struct FillFeeData {
        uint256 totalPrice;
        address rewardsRecipient;
        Fees fees;
    }

    struct SeaportOrderContext {
        SeaportFillInput input;
        ValidatedFillData fillData;
        ScatterSubmission submission; // precalculated for convenience
        Role role; // precalculated for convenience
        FillFeeData[] fillFees; // precalculated for convenience
        Fees totalFees; // precalculated for convenience
        address currency; // selected fills must share one currency in v1
    }

    struct Fees {
        uint256 sellerAmount;
        uint256 platformAmount;
        uint256 rewardsAmount;
        uint256 affiliateAmount;
    }

    //
    // STATE
    //
    mapping(address signer => uint256 counter) public counter;
    mapping(address signer => mapping(bytes32 submissionHash => mapping(uint256 itemIndex => bool cancelled))) public
        cancelledListings;
    mapping(address signer => mapping(bytes32 submissionHash => mapping(uint256 itemIndex => uint256 filled))) public
        filledListingQuantity;
    mapping(address router => bool trusted) public trustedRouters;
    ScatterCollectionRegistry public immutable scatterCollectionRegistry;

    /// Server-held signer for affiliate fee authorizations. The owner may rotate it.
    address public feeAuthorizer;
    uint256 public feeBps = DEFAULT_FEE_BPS;
    uint256 public feeSplitBps = DEFAULT_FEE_SPLIT_BPS;

    bytes32 public constant FEE_AUTHORIZATION_TYPEHASH = keccak256(
        "FeeAuthorization(address fulfiller,address affiliate,bytes32 submissionHash,bytes32 fillsHash,uint256 deadline)"
    );
    uint256 public constant MAX_AUTHORIZATION_WINDOW = 7 days;

    event ListingCancelled(bytes32 indexed submissionHash, address indexed signer, uint256 itemIndex);
    event CounterIncremented(address indexed signer, uint256 newCounter);
    event TrustedRouterUpdated(address indexed router, bool trusted);
    event FeeAuthorizerUpdated(address indexed oldFeeAuthorizer, address indexed newFeeAuthorizer);
    event FeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event FeeSplitBpsUpdated(uint256 oldFeeSplitBps, uint256 newFeeSplitBps);
    event ScatterSale(
        bytes32 indexed submissionHash,
        uint8 role,
        address indexed seller,
        address indexed buyer,
        address collection,
        uint256 itemIndex,
        uint256 tokenId,
        uint256 quantity,
        address currency,
        uint256 totalPrice,
        address affiliate,
        address rewardsRecipient,
        uint256 sellerAmount,
        uint256 platformAmount,
        uint256 rewardsAmount,
        uint256 affiliateAmount
    );

    constructor(
        address initialOwner,
        ScatterCollectionRegistry scatterCollectionRegistry_,
        address initialFeeAuthorizer,
        bytes32 conduitKey
    ) EIP712("Scatter Marketplace", "1") Ownable(initialOwner) ConduitConsumer(conduitKey) {
        if (address(scatterCollectionRegistry_).code.length == 0) {
            revert InvalidScatterCollectionRegistry();
        }
        if (initialFeeAuthorizer == address(0)) revert InvalidFeeAuthorizer();
        scatterCollectionRegistry = scatterCollectionRegistry_;
        feeAuthorizer = initialFeeAuthorizer;
    }

    function hashSubmission(ScatterSubmission calldata submission) external view returns (bytes32) {
        return _hashSubmission(submission);
    }

    function listingStatus(address signer, ScatterSubmission calldata submission, uint256 itemIndex)
        external
        view
        returns (bytes32 submissionHash, bool isCancelled, uint256 filled, uint256 remaining)
    {
        if (itemIndex >= submission.listings.length) revert InvalidFill();
        submissionHash = _hashSubmission(submission);
        isCancelled = cancelledListings[signer][submissionHash][itemIndex];
        filled = filledListingQuantity[signer][submissionHash][itemIndex];
        uint256 quantity = submission.listings[itemIndex].quantity;
        if (filled >= quantity) {
            remaining = 0;
        } else {
            remaining = quantity - filled;
        }
    }

    //
    // Cancellation
    //
    struct CancelListingItem {
        bytes32 submissionHash;
        uint256 itemIndex;
    }

    function cancelListings(CancelListingItem[] calldata items) external {
        for (uint256 i = 0; i < items.length; i++) {
            cancelledListings[msg.sender][items[i].submissionHash][items[i].itemIndex] = true;
            emit ListingCancelled(items[i].submissionHash, msg.sender, items[i].itemIndex);
        }
    }

    function incrementCounter() external {
        counter[msg.sender] += 1;
        emit CounterIncremented(msg.sender, counter[msg.sender]);
    }

    //
    // ContractOffererInterface
    //
    function generateOrder(
        address requester,
        SpentItem[] calldata, // minimumReceived
        SpentItem[] calldata, // maximumSpent
        bytes calldata seaportFillInputContextCalldata
    )
        external
        _onlySeaport
        nonReentrant
        whenNotPaused
        returns (SpentItem[] memory seaportOffer, ReceivedItem[] memory seaportConsideration)
    {
        SeaportOrderContext memory context = _decodeAndBuildContext(seaportFillInputContextCalldata);
        _validateFeeAuthorization(
            _resolveFulfiller(requester),
            context.input.affiliate,
            context.fillData.submissionHash,
            keccak256(abi.encode(context.input.fills)),
            context.input.feeAuthorizationDeadline,
            context.input.feeAuthorizationSignature
        );

        for (uint256 i = 0; i < context.input.fills.length; i++) {
            ScatterFill memory fill = context.input.fills[i];
            filledListingQuantity[
                context.fillData.signer
            ][context.fillData.submissionHash][fill.itemIndex] += fill.quantity;
        }
        if (context.role == Role.Listing) {
            (seaportOffer, seaportConsideration) = _buildSeaportArraysListing(context);
            _pullAndApproveNft(context);
            // Seaport sends listing fees directly to their recipients.
        } else {
            (seaportOffer, seaportConsideration) = _buildSeaportArraysBid(context);
            _pullAndApproveErc20(context);
            _distributeFeesErc20(context);
        }
        _emitScatterSale(context, requester);
    }

    function ratifyOrder(
        SpentItem[] calldata, // offer
        ReceivedItem[] calldata, // consideration
        bytes calldata, // context
        bytes32[] calldata, // orderHashes
        uint256 // contractNonce
    )
        external
        view
        _onlySeaport
        returns (bytes4)
    {
        return RATIFY_ORDER_MAGIC_VALUE;
    }

    function previewOrder(
        address, // caller
        address, // fulfiller
        SpentItem[] calldata, // minimumReceived
        SpentItem[] calldata, // maximumSpent
        bytes calldata seaportFillInputContextCalldata
    ) external view returns (SpentItem[] memory seaportOffer, ReceivedItem[] memory seaportConsideration) {
        SeaportOrderContext memory context = _decodeAndBuildContext(seaportFillInputContextCalldata);
        if (context.role == Role.Listing) {
            (seaportOffer, seaportConsideration) = _buildSeaportArraysListing(context);
        } else {
            (seaportOffer, seaportConsideration) = _buildSeaportArraysBid(context);
        }
    }

    function getSeaportMetadata() external pure returns (string memory name, Schema[] memory schemas) {
        name = "Scatter Marketplace";
        schemas = new Schema[](0);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        // The receiver ids matter: tokens are transferred INTO this contract
        // before Seaport routes them, and token contracts that ERC165-check
        // receivers reject the transfer when the id isn't advertised.
        return interfaceId == type(ContractOffererInterface).interfaceId // Seaport ContractOfferer
            || interfaceId == 0x150b7a02 // ERC721TokenReceiver
            || interfaceId == 0x4e2312e0 // ERC1155TokenReceiver
            || interfaceId == 0x01ffc9a7; // ERC165
    }

    //
    // ADMIN
    //
    function setTrustedRouter(address router, bool trusted) external onlyOwner {
        if (router == address(0)) revert InvalidRouter();
        trustedRouters[router] = trusted;
        emit TrustedRouterUpdated(router, trusted);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setFeeAuthorizer(address newFeeAuthorizer) external onlyOwner {
        if (newFeeAuthorizer == address(0)) revert InvalidFeeAuthorizer();
        emit FeeAuthorizerUpdated(feeAuthorizer, newFeeAuthorizer);
        feeAuthorizer = newFeeAuthorizer;
    }

    function setFeeBps(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert InvalidFeeBps();
        emit FeeBpsUpdated(feeBps, newFeeBps);
        feeBps = newFeeBps;
    }

    function setFeeSplitBps(uint256 newFeeSplitBps) external onlyOwner {
        if (newFeeSplitBps > BPS_DENOMINATOR) revert InvalidFeeSplitBps();
        emit FeeSplitBpsUpdated(feeSplitBps, newFeeSplitBps);
        feeSplitBps = newFeeSplitBps;
    }

    /// For routed fills, Seaport reports the router as fulfiller. Read the caller
    /// from the trusted router because a direct `sweepMixed` caller can forge
    /// `extraData`. Revert if the router cannot return the caller. Using the router
    /// would bind every fee authorization to the same address.
    function _resolveFulfiller(address requester) internal view returns (address fulfiller) {
        if (!trustedRouters[requester]) return requester;

        (bool ok, bytes memory data) = requester.staticcall(abi.encodeWithSignature("activeRoutedFulfiller()"));
        if (!ok || data.length != 32) revert InvalidRoutedFulfiller();
        fulfiller = abi.decode(data, (address));
        if (fulfiller == address(0)) revert InvalidRoutedFulfiller();
    }

    /// Bind the authorization to Seaport's `requester`. For routed fills,
    /// `_resolveFulfiller` replaces the router with its caller. `msg.sender` is
    /// always Seaport here.
    function _validateFeeAuthorization(
        address fulfiller,
        address affiliate,
        bytes32 submissionHash,
        bytes32 fillsHash,
        uint256 deadline,
        bytes memory signature
    ) internal view {
        if (affiliate == address(0)) {
            if (signature.length != 0) revert InvalidFeeAuthorization();
            return;
        }
        if (block.timestamp > deadline) revert FeeAuthorizationExpired();
        if (deadline > block.timestamp + MAX_AUTHORIZATION_WINDOW) revert InvalidFeeAuthorization();

        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(FEE_AUTHORIZATION_TYPEHASH, fulfiller, affiliate, submissionHash, fillsHash, deadline))
        );
        if (ECDSA.recover(digest, signature) != feeAuthorizer) revert InvalidFeeAuthorization();
    }

    function _decodeAndBuildContext(bytes calldata seaportFillInputContextCalldata)
        internal
        view
        returns (SeaportOrderContext memory context)
    {
        (
            context.input.submission,
            context.input.submissionSig,
            context.input.affiliate,
            context.input.fills,
            context.input.criteriaProofs,
            context.input.feeAuthorizationDeadline,
            context.input.feeAuthorizationSignature
        ) =
            abi.decode(
                seaportFillInputContextCalldata,
                (ScatterSubmission, bytes, address, ScatterFill[], bytes32[][], uint256, bytes)
            );
        context.submission = context.input.submission;
        context.role = context.submission.role;
        context.fillData = _computeFillData(context.input);
        context.currency = context.submission.listings[context.input.fills[0].itemIndex].currency;

        context.fillFees = new FillFeeData[](context.input.fills.length);
        for (uint256 i = 0; i < context.input.fills.length; i++) {
            ScatterListing memory item = context.submission.listings[context.input.fills[i].itemIndex];
            uint256 totalPrice =
                item.assetType == AssetType.ERC1155 ? item.priceWei * context.input.fills[i].quantity : item.priceWei;
            address rewardsRecipient = scatterCollectionRegistry.rewardsRecipient(item.collection);
            Fees memory fillFees = _computeListingFee(totalPrice, context.input.affiliate, rewardsRecipient);
            context.fillFees[i] =
                FillFeeData({totalPrice: totalPrice, rewardsRecipient: rewardsRecipient, fees: fillFees});
            context.totalFees.sellerAmount += fillFees.sellerAmount;
            context.totalFees.platformAmount += fillFees.platformAmount;
            context.totalFees.affiliateAmount += fillFees.affiliateAmount;
        }
    }

    function _buildSeaportArraysListing(SeaportOrderContext memory context)
        internal
        pure
        returns (SpentItem[] memory offer, ReceivedItem[] memory consideration)
    {
        SeaportFillInput memory input = context.input;
        ScatterSubmission memory submission = context.submission;

        offer = new SpentItem[](input.fills.length);
        for (uint256 i = 0; i < input.fills.length; i++) {
            offer[i] = SpentItem({
                itemType: submission.listings[input.fills[i].itemIndex].assetType == AssetType.ERC1155
                    ? ItemType.ERC1155
                    : ItemType.ERC721,
                token: submission.listings[input.fills[i].itemIndex].collection,
                identifier: input.fills[i].tokenId,
                amount: input.fills[i].quantity
            });
        }
        consideration = _buildConsiderationArrayListing(context);
    }

    function _buildSeaportArraysBid(SeaportOrderContext memory context)
        internal
        pure
        returns (SpentItem[] memory offer, ReceivedItem[] memory consideration)
    {
        Fees memory fees = context.totalFees;

        offer = new SpentItem[](1);
        offer[0] = SpentItem({
            itemType: context.currency == address(0) ? ItemType.NATIVE : ItemType.ERC20,
            token: context.currency,
            identifier: 0,
            amount: fees.sellerAmount
        });
        consideration = _buildConsiderationArrayBid(context);
    }

    function _buildConsiderationArrayListing(SeaportOrderContext memory context)
        internal
        pure
        returns (ReceivedItem[] memory consideration)
    {
        SeaportFillInput memory input = context.input;
        Fees memory fees = context.totalFees;

        ItemType currencyItemType = context.currency == address(0) ? ItemType.NATIVE : ItemType.ERC20;

        // ReceivedItem[] payment order:
        // | flow                       | layout                                                     |
        // | -------------------------- | ---------------------------------------------------------- |
        // | listing, sellerAmount > 0  | [seller, platform?, reward1?, reward2?, ..., affiliate?]    |
        // | listing, sellerAmount == 0 | [platform?, reward1?, reward2?, ..., affiliate?]            |
        // ? = included only for a positive amount; each fill can add its own rewards payment.
        // Rewards follow fill order, even when recipients repeat. Affiliate fees take precedence over rewards.
        uint256 itemCount = fees.sellerAmount > 0 ? 1 : 0;
        if (fees.platformAmount > 0) itemCount++;
        for (uint256 j = 0; j < context.fillFees.length; j++) {
            if (context.fillFees[j].fees.rewardsAmount > 0) itemCount++;
        }
        if (fees.affiliateAmount > 0) itemCount++;

        consideration = new ReceivedItem[](itemCount);

        uint256 i = 0;
        if (fees.sellerAmount > 0) {
            consideration[i++] = ReceivedItem({
                itemType: currencyItemType,
                token: context.currency,
                identifier: 0,
                amount: fees.sellerAmount,
                recipient: payable(context.fillData.signer)
            });
        }

        if (fees.platformAmount > 0) {
            consideration[i++] = ReceivedItem({
                itemType: currencyItemType,
                token: context.currency,
                identifier: 0,
                amount: fees.platformAmount,
                recipient: payable(PLATFORM)
            });
        }

        for (uint256 j = 0; j < context.fillFees.length; j++) {
            FillFeeData memory fillFee = context.fillFees[j];
            if (fillFee.fees.rewardsAmount > 0) {
                consideration[i++] = ReceivedItem({
                    itemType: currencyItemType,
                    token: context.currency,
                    identifier: 0,
                    amount: fillFee.fees.rewardsAmount,
                    recipient: payable(fillFee.rewardsRecipient)
                });
            }
        }

        if (fees.affiliateAmount > 0) {
            consideration[i++] = ReceivedItem({
                itemType: currencyItemType,
                token: context.currency,
                identifier: 0,
                amount: fees.affiliateAmount,
                recipient: payable(input.affiliate)
            });
        }
    }

    function _buildConsiderationArrayBid(SeaportOrderContext memory context)
        internal
        pure
        returns (ReceivedItem[] memory consideration)
    {
        SeaportFillInput memory input = context.input;
        ValidatedFillData memory fillData = context.fillData;
        ScatterSubmission memory submission = context.submission;

        consideration = new ReceivedItem[](input.fills.length);
        for (uint256 i = 0; i < input.fills.length; i++) {
            consideration[i] = ReceivedItem({
                itemType: submission.listings[input.fills[i].itemIndex].assetType == AssetType.ERC1155
                    ? ItemType.ERC1155
                    : ItemType.ERC721,
                token: submission.listings[input.fills[i].itemIndex].collection,
                identifier: input.fills[i].tokenId,
                amount: input.fills[i].quantity,
                recipient: payable(fillData.signer)
            });
        }
    }

    function _pullAndApproveNft(SeaportOrderContext memory context) internal {
        SeaportFillInput memory input = context.input;
        ScatterSubmission memory submission = context.submission;
        ConduitTransfer[] memory transfers = new ConduitTransfer[](input.fills.length);
        for (uint256 i; i < input.fills.length; ++i) {
            transfers[i] = ConduitTransfer({
                itemType: submission.listings[input.fills[i].itemIndex].assetType == AssetType.ERC721
                    ? ConduitItemType.ERC721
                    : ConduitItemType.ERC1155,
                token: submission.listings[input.fills[i].itemIndex].collection,
                from: context.fillData.signer,
                to: address(this),
                identifier: input.fills[i].tokenId,
                amount: input.fills[i].quantity
            });
        }

        _executeConduit(transfers);

        for (uint256 i = 0; i < input.fills.length; i++) {
            address collection = transfers[i].token;
            if (transfers[i].itemType == ConduitItemType.ERC721) {
                if (!IERC721(collection).isApprovedForAll(address(this), SEAPORT)) {
                    IERC721(collection).setApprovalForAll(SEAPORT, true);
                }
            } else {
                if (!IERC1155(collection).isApprovedForAll(address(this), SEAPORT)) {
                    IERC1155(collection).setApprovalForAll(SEAPORT, true);
                }
            }
        }
    }

    function _pullAndApproveErc20(SeaportOrderContext memory context) internal {
        IERC20 token = IERC20(context.currency);
        ConduitTransfer[] memory transfers = new ConduitTransfer[](1);
        transfers[0] = ConduitTransfer(
            ConduitItemType.ERC20,
            context.currency,
            context.fillData.signer,
            address(this),
            0,
            context.fillData.totalFillPrice
        );
        _executeConduit(transfers);
        token.forceApprove(SEAPORT, token.allowance(address(this), SEAPORT) + context.totalFees.sellerAmount);
    }

    function _distributeFeesErc20(SeaportOrderContext memory context) internal {
        SeaportFillInput memory input = context.input;
        Fees memory fees = context.totalFees;

        if (fees.platformAmount > 0) {
            IERC20(context.currency).safeTransfer(PLATFORM, fees.platformAmount);
        }

        for (uint256 i = 0; i < context.fillFees.length; i++) {
            FillFeeData memory fillFee = context.fillFees[i];
            if (fillFee.fees.rewardsAmount > 0) {
                IERC20(context.currency).safeTransfer(fillFee.rewardsRecipient, fillFee.fees.rewardsAmount);
            }
        }

        if (fees.affiliateAmount > 0) {
            IERC20(context.currency).safeTransfer(input.affiliate, fees.affiliateAmount);
        }
    }

    function _emitScatterSale(SeaportOrderContext memory context, address requester) internal {
        SeaportFillInput memory input = context.input;
        ValidatedFillData memory fillData = context.fillData;
        ScatterSubmission memory submission = context.submission;
        address signer = fillData.signer;

        address fulfiller = _resolveFulfiller(requester);
        (address seller, address buyer) = context.role == Role.Listing ? (signer, fulfiller) : (fulfiller, signer);

        for (uint256 i = 0; i < input.fills.length; i++) {
            ScatterFill memory fill = input.fills[i];
            FillFeeData memory fillFee = context.fillFees[i];
            ScatterListing memory item = submission.listings[fill.itemIndex];
            emit ScatterSale({
                submissionHash: fillData.submissionHash,
                role: uint8(submission.role),
                seller: seller,
                buyer: buyer,
                collection: item.collection,
                itemIndex: fill.itemIndex,
                tokenId: fill.tokenId,
                quantity: fill.quantity,
                currency: item.currency,
                totalPrice: fillFee.totalPrice,
                affiliate: fillFee.fees.affiliateAmount > 0 ? input.affiliate : address(0),
                rewardsRecipient: fillFee.fees.rewardsAmount > 0 ? fillFee.rewardsRecipient : address(0),
                sellerAmount: fillFee.fees.sellerAmount,
                platformAmount: fillFee.fees.platformAmount,
                rewardsAmount: fillFee.fees.rewardsAmount,
                affiliateAmount: fillFee.fees.affiliateAmount
            });
        }
    }

    function _computeListingFee(uint256 listingPrice, address affiliate, address rewardsRecipient)
        internal
        view
        returns (Fees memory fees)
    {
        uint256 totalFee = Math.mulDiv(listingPrice, feeBps, BPS_DENOMINATOR);
        fees.sellerAmount = listingPrice - totalFee;

        if (affiliate != address(0)) {
            fees.platformAmount = Math.mulDiv(totalFee, feeSplitBps, BPS_DENOMINATOR);
            fees.affiliateAmount = totalFee - fees.platformAmount;
            return fees;
        }

        if (rewardsRecipient != address(0)) {
            fees.platformAmount = Math.mulDiv(totalFee, feeSplitBps, BPS_DENOMINATOR);
            fees.rewardsAmount = totalFee - fees.platformAmount;
            return fees;
        }

        fees.platformAmount = totalFee;
        return fees;
    }

    function _hashListingItem(ScatterListing memory listing) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                SCATTER_LISTING_TYPEHASH,
                listing.assetType,
                listing.collection,
                listing.tokenId,
                listing.quantity,
                listing.currency,
                listing.priceWei
            )
        );
    }

    function _hashSubmission(ScatterSubmission memory submission) internal view returns (bytes32) {
        bytes32[] memory listingHashes = new bytes32[](submission.listings.length);
        for (uint256 i = 0; i < submission.listings.length; i++) {
            listingHashes[i] = _hashListingItem(submission.listings[i]);
        }
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    SCATTER_SUBMISSION_TYPEHASH,
                    submission.role,
                    keccak256(abi.encodePacked(listingHashes)),
                    submission.criteriaRoot,
                    submission.maxFeeBps,
                    submission.startTime,
                    submission.endTime,
                    submission.nonce,
                    submission.salt
                )
            )
        );
    }

    function _computeFillData(SeaportFillInput memory input) internal view returns (ValidatedFillData memory fillData) {
        ScatterSubmission memory submission = input.submission;
        if (feeBps > submission.maxFeeBps) revert FeeBpsExceedsLimit(feeBps, submission.maxFeeBps);

        // Validate role
        if (submission.role != Role.Listing && submission.role != Role.Bid) revert InvalidRole();

        // Validate lisitng/fills existance
        if (submission.listings.length == 0 || input.fills.length == 0) revert EmptySpec();

        // Validate criteria proofs
        bool needsCriteriaProofs = submission.role == Role.Bid && submission.criteriaRoot != bytes32(0);
        if (needsCriteriaProofs && input.criteriaProofs.length != input.fills.length) revert InvalidCriteriaProof();

        _validateNoDuplicateTokenIds(submission);
        _validateNoDuplicateItemIndexes(input.fills);

        // determinate currency for all listings
        // (we need to check if input.fills[0].itemIndex is valid key for submission.listings)
        if (input.fills[0].itemIndex >= submission.listings.length) revert InvalidFill();
        address fillCurrency = submission.listings[input.fills[0].itemIndex].currency;

        for (uint256 i = 0; i < input.fills.length; i++) {
            ScatterFill memory fill = input.fills[i];

            _validateFill(submission, fill, fillCurrency);
            ScatterListing memory item = submission.listings[fill.itemIndex];
            fillData.totalFillPrice += item.assetType == AssetType.ERC1155
                ? item.priceWei * fill.quantity
                : item.priceWei;
        }

        // Validate time window
        if (block.timestamp < submission.startTime || block.timestamp >= submission.endTime) revert OrderExpired();

        // Compute submissionHash and signer
        fillData.submissionHash = _hashSubmission(submission);
        fillData.signer = ECDSA.recover(fillData.submissionHash, input.submissionSig);

        // Validate nonce
        if (fillData.signer == address(0)) revert InvalidSignature();
        if (submission.nonce != counter[fillData.signer]) revert NonceMismatch();

        // Validate cancellation
        for (uint256 i = 0; i < input.fills.length; i++) {
            if (cancelledListings[fillData.signer][fillData.submissionHash][input.fills[i].itemIndex]) {
                revert OrderCancelled();
            }
        }

        for (uint256 i = 0; i < input.fills.length; i++) {
            ScatterFill memory fill = input.fills[i];
            ScatterListing memory item = submission.listings[fill.itemIndex];
            if (
                filledListingQuantity[fillData.signer][fillData.submissionHash][fill.itemIndex] + fill.quantity
                    > item.quantity
            ) {
                revert QuantityExceeded();
            }

            // Validate criteriaRoot
            if (needsCriteriaProofs) {
                bytes32 leaf = keccak256(abi.encode(fill.tokenId));
                if (!MerkleProof.verify(input.criteriaProofs[i], submission.criteriaRoot, leaf)) {
                    revert InvalidCriteriaProof();
                }
            }
        }
    }

    function _validateNoDuplicateTokenIds(ScatterSubmission memory submission) internal pure {
        for (uint256 i = 0; i < submission.listings.length; i++) {
            uint256 tokenId = submission.listings[i].tokenId;
            if (tokenId == 0 && submission.role == Role.Bid) continue;
            for (uint256 j = i + 1; j < submission.listings.length; j++) {
                bool sameCollection = submission.listings[j].collection == submission.listings[i].collection;
                bool sameTokenId = submission.listings[j].tokenId == tokenId;
                if (sameCollection && sameTokenId) revert DuplicateListingItem();
            }
        }
    }

    function _validateNoDuplicateItemIndexes(ScatterFill[] memory fills) internal pure {
        for (uint256 i = 0; i < fills.length; i++) {
            for (uint256 j = i + 1; j < fills.length; j++) {
                if (fills[j].itemIndex == fills[i].itemIndex) revert DuplicateListingItem();
            }
        }
    }

    function _validateFill(ScatterSubmission memory submission, ScatterFill memory fill, address fillCurrency)
        internal
        pure
    {
        if (fill.itemIndex >= submission.listings.length) revert InvalidFill();
        if (fill.quantity == 0) revert EmptySpec();

        ScatterListing memory item = submission.listings[fill.itemIndex];

        if (item.assetType != AssetType.ERC721 && item.assetType != AssetType.ERC1155) revert InvalidAssetType();
        if (item.currency != fillCurrency) revert CurrencyMismatch();
        if (submission.role == Role.Bid && item.currency == address(0)) revert CurrencyMismatch();

        if (submission.role == Role.Listing && fill.tokenId != item.tokenId) revert TokenIdNotZeroForCriteria();
        if (submission.role == Role.Bid && item.tokenId != 0 && fill.tokenId != item.tokenId) {
            revert TokenIdNotZeroForCriteria();
        }

        if (item.assetType == AssetType.ERC721) {
            if (fill.quantity != 1) revert QuantityExceeded();
            if (submission.role == Role.Listing && item.quantity != 1) revert QuantityExceeded();
            if (submission.role == Role.Bid && item.tokenId != 0 && item.quantity != 1) revert QuantityExceeded();
        }
    }

    //
    // ERC721/1155 RECEIVER HOOKS
    //
    function onERC721Received(
        address, // operator
        address, // from
        uint256, // tokenId
        bytes calldata // data
    )
        external
        pure
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }

    function onERC1155Received(
        address, // operator
        address, // from
        uint256, // id
        uint256, // value
        bytes calldata // data
    )
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address, // operator
        address, // from
        uint256[] calldata, // ids
        uint256[] calldata, // values
        bytes calldata // data
    )
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    modifier _onlySeaport() {
        if (msg.sender != SEAPORT) revert OnlySeaport();
        _;
    }
}
