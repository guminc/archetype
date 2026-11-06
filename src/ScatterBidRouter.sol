// SPDX-License-Identifier: BUSL-1.1
// ScatterBidRouter v0.3.0
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {SeaportInterface} from "seaport-types/src/interfaces/SeaportInterface.sol";
import {ZoneInterface} from "seaport-types/src/interfaces/ZoneInterface.sol";
import {
    AdvancedOrder,
    CriteriaResolver,
    OfferItem,
    ConsiderationItem,
    OrderParameters,
    OrderComponents,
    ZoneParameters,
    Schema,
    SpentItem,
    ReceivedItem
} from "seaport-types/src/lib/ConsiderationStructs.sol";
import {ItemType, OrderType, Side} from "seaport-types/src/lib/ConsiderationEnums.sol";
import {ScatterCollectionRegistry} from "./ScatterCollectionRegistry.sol";
import {ScatterOfferer} from "./ScatterOfferer.sol";
import {ConduitConsumer} from "./ConduitConsumer.sol";
import {ConduitTransfer} from "seaport-types/src/conduit/lib/ConduitStructs.sol";
import {ConduitItemType} from "seaport-types/src/conduit/lib/ConduitEnums.sol";

error InvalidBidCurrency();
error InvalidOfferShape();
error InvalidConsiderationShape();
error InvalidOrderType();
error InvalidNftRecipient();
error InvalidQuantity();
error InvalidFraction();
error MissingCriteriaResolver();
error DuplicateCriteriaResolver();
error OrderStateChanged();
error SeaportCallFailed();
error NftNotTransferred();
error NoSellerProceeds();
error InsufficientSellerPayout();
error EmptyBatch();
error BatchTooLarge();
error LengthMismatch();
error CurrencyBalanceInvariant();
error InvalidFeeAuthorizer();
error InvalidFeeAuthorization();
error FeeAuthorizationExpired();
error InvalidScatterCollectionRegistry();
error InvalidFeeBps();
error InvalidFeeSplitBps();
error InvalidScatterOfferer();
error InvalidMinimumPayouts();
error OnlySeaport();
error InvalidSettlementOrder();
error SettlementNotAuthorized();

contract ScatterBidRouter is
    Ownable2Step,
    Pausable,
    ReentrancyGuard,
    ERC721Holder,
    ERC1155Holder,
    EIP712,
    ConduitConsumer,
    ZoneInterface
{
    using SafeERC20 for IERC20;

    address public immutable SEAPORT =
        block.chainid == 4326 ? 0x00000000006687982678b03100B9bDC8be440814 : 0x0000000000000068F116a894984e2DB1123eB395;
    address public constant PLATFORM = 0x8952caF7E5bf1fe63ebe94148ca802F3eF127C98;

    uint256 public constant DEFAULT_FEE_BPS = 500;
    uint256 public constant MAX_FEE_BPS = 5000;
    uint256 public constant DEFAULT_FEE_SPLIT_BPS = 5000;
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant MAX_BATCH = 50;
    uint256 public constant MAX_AUTHORIZATION_WINDOW = 7 days;

    address public immutable SCATTER_OFFERER;
    ScatterCollectionRegistry public immutable scatterCollectionRegistry;
    address public activeRoutedFulfiller;

    /// Server-held signer for affiliate fee authorizations. The owner may rotate it.
    address public feeAuthorizer;
    uint256 public feeBps = DEFAULT_FEE_BPS;
    uint256 public feeSplitBps = DEFAULT_FEE_SPLIT_BPS;

    /// Currencies whose offers `sellIntoBids` settles. The owner tracks the
    /// marketplace's supported currency list; an offer in anything else reverts.
    mapping(address currency => bool) public allowedCurrencies;

    bytes32 public constant FEE_AUTHORIZATION_TYPEHASH =
        keccak256("FeeAuthorization(address seller,address affiliate,bytes32 fillsHash,uint256 deadline)");
    bytes32 public constant MATCHED_FEE_AUTHORIZATION_TYPEHASH = keccak256(
        "MatchedFeeAuthorization(address seller,address affiliate,bytes32 orderHash,bytes32 sourceOrderHash,uint256 deadline)"
    );

    struct MatchedBidContext {
        OrderComponents sourceOrder;
        bytes32[] criteriaProof;
        address affiliate;
        uint256 minimumSellerPayout;
        uint256 feeAuthorizationDeadline;
        bytes feeAuthorizationSignature;
    }

    struct MatchedSettlement {
        address seller;
        address currency;
        address collection;
        uint256 tokenId;
        uint256 quantity;
        uint256 proceeds;
        bytes32 sourceOrderHash;
        Fees fees;
    }

    struct MatchedSource {
        uint256 filledNumerator;
        uint256 filledDenominator;
        uint256 orderQuantity;
        uint256 quantity;
        uint256 settlements;
    }

    struct MatchedCurrency {
        uint256 balanceBefore;
        uint256 proceeds;
    }

    mapping(bytes32 => MatchedSettlement) private matchedSettlements;
    mapping(bytes32 => MatchedSource) private matchedSources;
    mapping(address => MatchedCurrency) private matchedCurrencies;
    uint256 private matchedSettlementCount;
    bool private matchedOrdersValidated;

    struct MinimumPayout {
        address currency;
        uint256 amount;
    }

    struct Fees {
        uint256 totalAmount;
        uint256 platformAmount;
        uint256 rewardsAmount;
        uint256 affiliateAmount;
        address rewardsRecipient;
        address affiliate;
    }

    struct BidDetails {
        bytes32 orderHash;
        address currency;
        address collection;
        uint256 tokenId;
        uint256 quantity;
        address bidder;
        bool isErc721;
        uint256 currencyConsideration;
    }

    event FeeAuthorizerUpdated(address indexed oldFeeAuthorizer, address indexed newFeeAuthorizer);
    event FeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event FeeSplitBpsUpdated(uint256 oldFeeSplitBps, uint256 newFeeSplitBps);
    event AllowedCurrencyUpdated(address indexed currency, bool allowed);
    event ExternalBidFilled(
        address indexed seller,
        address indexed currency,
        bytes32 indexed orderHash,
        address collection,
        uint256 tokenId,
        uint256 quantity,
        address bidder,
        uint256 proceeds,
        uint256 scatterFee,
        uint256 sellerPayout,
        address affiliate,
        address rewardsRecipient,
        uint256 platformAmount,
        uint256 rewardsAmount,
        uint256 affiliateAmount
    );

    event BidProceedsPaid(
        address indexed seller,
        address indexed currency,
        bytes32 indexed orderHash,
        address collection,
        uint256 tokenId,
        uint256 quantity,
        uint256 proceeds,
        uint256 scatterFee,
        uint256 sellerPayout,
        address affiliate,
        address rewardsRecipient,
        uint256 platformAmount,
        uint256 rewardsAmount,
        uint256 affiliateAmount
    );

    constructor(
        address initialOwner,
        address initialFeeAuthorizer,
        ScatterCollectionRegistry scatterCollectionRegistry_,
        address scatterOfferer,
        bytes32 conduitKey
    ) Ownable(initialOwner) EIP712("ScatterBidRouter", "1") ConduitConsumer(conduitKey) {
        if (scatterOfferer.code.length == 0) revert InvalidScatterOfferer();
        if (initialFeeAuthorizer == address(0)) revert InvalidFeeAuthorizer();
        if (address(scatterCollectionRegistry_).code.length == 0) revert InvalidScatterCollectionRegistry();
        SCATTER_OFFERER = scatterOfferer;
        feeAuthorizer = initialFeeAuthorizer;
        scatterCollectionRegistry = scatterCollectionRegistry_;
    }

    function authorizeOrder(ZoneParameters calldata parameters)
        external
        override
        nonReentrant
        whenNotPaused
        returns (bytes4)
    {
        if (msg.sender != SEAPORT) revert OnlySeaport();
        if (parameters.offerer != parameters.fulfiller || parameters.offerer == address(this)) {
            revert InvalidSettlementOrder();
        }
        if (parameters.offer.length != 1 || parameters.consideration.length != 1) revert InvalidSettlementOrder();
        if (matchedSettlements[parameters.orderHash].seller != address(0)) revert InvalidSettlementOrder();
        if (matchedSettlementCount == MAX_BATCH) revert BatchTooLarge();

        SpentItem calldata nft = parameters.offer[0];
        ReceivedItem calldata payment = parameters.consideration[0];
        if (nft.itemType != ItemType.ERC721 && nft.itemType != ItemType.ERC1155) revert InvalidSettlementOrder();
        if (nft.amount == 0 || (nft.itemType == ItemType.ERC721 && nft.amount != 1)) revert InvalidQuantity();
        if (payment.itemType != ItemType.ERC20 || payment.identifier != 0 || payment.recipient != address(this)) {
            revert InvalidSettlementOrder();
        }
        if (!allowedCurrencies[payment.token] || payment.token == nft.token) revert InvalidBidCurrency();

        MatchedBidContext memory context = abi.decode(parameters.extraData, (MatchedBidContext));
        uint256 orderQuantity = _validateMatchedProceeds(nft, payment, parameters.offerer, context);
        bytes32 sourceOrderHash = SeaportInterface(SEAPORT).getOrderHash(context.sourceOrder);
        _validateMatchedFeeAuthorization(parameters, sourceOrderHash, context);
        Fees memory fees = _calculateBidFees(
            payment.amount,
            feeBps,
            feeSplitBps,
            context.affiliate,
            scatterCollectionRegistry.rewardsRecipient(nft.token)
        );
        if (payment.amount - fees.totalAmount < context.minimumSellerPayout) revert InsufficientSellerPayout();

        MatchedSource storage source = matchedSources[sourceOrderHash];
        if (source.settlements == 0) {
            for (uint256 i; i < parameters.orderHashes.length; ++i) {
                if (parameters.orderHashes[i] == sourceOrderHash) revert InvalidSettlementOrder();
            }
            (,, source.filledNumerator, source.filledDenominator) =
                SeaportInterface(SEAPORT).getOrderStatus(sourceOrderHash);
            if (source.filledDenominator == 0) source.filledDenominator = 1;
            source.orderQuantity = orderQuantity;
        }
        source.quantity += nft.amount;
        ++source.settlements;

        MatchedCurrency storage currency = matchedCurrencies[payment.token];
        if (currency.proceeds == 0) currency.balanceBefore = IERC20(payment.token).balanceOf(address(this));
        currency.proceeds += payment.amount;
        matchedSettlements[parameters.orderHash] = MatchedSettlement({
            seller: parameters.offerer,
            currency: payment.token,
            collection: nft.token,
            tokenId: nft.identifier,
            quantity: nft.amount,
            proceeds: payment.amount,
            sourceOrderHash: sourceOrderHash,
            fees: fees
        });
        ++matchedSettlementCount;
        return ZoneInterface.authorizeOrder.selector;
    }

    function validateOrder(ZoneParameters calldata parameters)
        external
        override
        nonReentrant
        whenNotPaused
        returns (bytes4)
    {
        if (msg.sender != SEAPORT) revert OnlySeaport();
        MatchedSettlement memory settlement = matchedSettlements[parameters.orderHash];
        if (settlement.seller == address(0)) revert SettlementNotAuthorized();
        if (!matchedOrdersValidated) {
            for (uint256 i; i < parameters.orderHashes.length; ++i) {
                bytes32 orderHash = parameters.orderHashes[i];
                if (matchedSettlements[orderHash].seller == address(0) && matchedSources[orderHash].settlements == 0) {
                    revert InvalidSettlementOrder();
                }
            }
            matchedOrdersValidated = true;
        }

        MatchedSource storage source = matchedSources[settlement.sourceOrderHash];
        (,, uint256 filled, uint256 size) = SeaportInterface(SEAPORT).getOrderStatus(settlement.sourceOrderHash);
        uint256 denominator = size * source.filledDenominator;
        if (denominator == 0) revert InvalidSettlementOrder();
        uint256 numerator = filled * source.filledDenominator - source.filledNumerator * size;
        if (_scaleMatchedAmount(source.orderQuantity, numerator, denominator) != source.quantity) {
            revert InvalidSettlementOrder();
        }

        IERC20 token = IERC20(settlement.currency);
        MatchedCurrency storage currency = matchedCurrencies[settlement.currency];
        uint256 balanceBefore = token.balanceOf(address(this));
        if (balanceBefore < currency.balanceBefore + currency.proceeds) revert CurrencyBalanceInvariant();
        currency.proceeds -= settlement.proceeds;
        if (currency.proceeds == 0) delete matchedCurrencies[settlement.currency];
        if (--source.settlements == 0) delete matchedSources[settlement.sourceOrderHash];
        delete matchedSettlements[parameters.orderHash];
        if (--matchedSettlementCount == 0) matchedOrdersValidated = false;

        uint256 sellerPayout = settlement.proceeds - settlement.fees.totalAmount;
        _distributeFeesErc20(token, settlement.fees);
        _paySellerErc20(token, settlement.seller, sellerPayout);
        if (token.balanceOf(address(this)) != balanceBefore - settlement.proceeds) revert CurrencyBalanceInvariant();
        emit BidProceedsPaid(
            settlement.seller,
            settlement.currency,
            parameters.orderHash,
            settlement.collection,
            settlement.tokenId,
            settlement.quantity,
            settlement.proceeds,
            settlement.fees.totalAmount,
            sellerPayout,
            settlement.fees.affiliate,
            settlement.fees.rewardsRecipient,
            settlement.fees.platformAmount,
            settlement.fees.rewardsAmount,
            settlement.fees.affiliateAmount
        );
        return ZoneInterface.validateOrder.selector;
    }

    function getSeaportMetadata() external pure override returns (string memory name, Schema[] memory schemas) {
        return ("ScatterBidRouter", new Schema[](0));
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC1155Holder, ZoneInterface) returns (bool) {
        return interfaceId == type(ZoneInterface).interfaceId || super.supportsInterface(interfaceId);
    }

    function _validateMatchedProceeds(
        SpentItem calldata nft,
        ReceivedItem calldata payment,
        address seller,
        MatchedBidContext memory context
    ) internal view returns (uint256 orderQuantity) {
        OrderComponents memory source = context.sourceOrder;
        if (source.orderType == OrderType.CONTRACT) revert InvalidOrderType();
        if (source.offer.length != 1) revert InvalidOfferShape();
        OfferItem memory offer = source.offer[0];
        if (offer.itemType != ItemType.ERC20 || offer.token != payment.token || offer.identifierOrCriteria != 0) {
            revert InvalidOfferShape();
        }
        if (offer.startAmount == 0 || offer.startAmount != offer.endAmount) revert InvalidOfferShape();
        for (uint256 i; i < source.consideration.length; ++i) {
            ConsiderationItem memory item = source.consideration[i];
            if (item.startAmount != item.endAmount) revert InvalidConsiderationShape();
            if (_isNftItemType(item.itemType)) {
                if (orderQuantity != 0 || item.startAmount == 0) revert InvalidConsiderationShape();
                if (item.token != nft.token || item.recipient == address(0) || item.recipient == address(this)) {
                    revert InvalidSettlementOrder();
                }
                bool criteria =
                    item.itemType == ItemType.ERC721_WITH_CRITERIA || item.itemType == ItemType.ERC1155_WITH_CRITERIA;
                if (uint8(item.itemType) != uint8(nft.itemType) + (criteria ? 2 : 0)) revert InvalidSettlementOrder();
                if (criteria) {
                    if (
                        item.identifierOrCriteria != 0
                            && !MerkleProof.verify(
                                context.criteriaProof,
                                bytes32(item.identifierOrCriteria),
                                keccak256(abi.encode(nft.identifier))
                            )
                    ) revert InvalidSettlementOrder();
                } else if (item.identifierOrCriteria != nft.identifier) {
                    revert InvalidSettlementOrder();
                }
                orderQuantity = item.startAmount;
            } else {
                if (item.itemType != ItemType.ERC20 || item.token != payment.token || item.identifierOrCriteria != 0) {
                    revert InvalidConsiderationShape();
                }
                if (item.recipient == seller || item.recipient == address(this)) revert InvalidConsiderationShape();
            }
        }
        if (orderQuantity == 0 || nft.amount > orderQuantity) revert InvalidQuantity();
        uint256 gross = _scaleMatchedAmount(offer.startAmount, nft.amount, orderQuantity);
        uint256 externalFees;
        for (uint256 i; i < source.consideration.length; ++i) {
            if (source.consideration[i].itemType == ItemType.ERC20) {
                externalFees += _scaleMatchedAmount(source.consideration[i].startAmount, nft.amount, orderQuantity);
            }
        }
        if (gross <= externalFees) revert NoSellerProceeds();
        if (payment.amount != gross - externalFees) revert InvalidSettlementOrder();
    }

    function _scaleMatchedAmount(uint256 amount, uint256 numerator, uint256 denominator)
        internal
        pure
        returns (uint256)
    {
        if (mulmod(amount, numerator, denominator) != 0) revert InvalidFraction();
        return Math.mulDiv(amount, numerator, denominator);
    }

    function _validateMatchedFeeAuthorization(
        ZoneParameters calldata parameters,
        bytes32 sourceOrderHash,
        MatchedBidContext memory context
    ) internal view {
        if (context.affiliate == address(0)) {
            if (context.feeAuthorizationSignature.length != 0) revert InvalidFeeAuthorization();
            return;
        }
        uint256 deadline = context.feeAuthorizationDeadline;
        if (block.timestamp > deadline) revert FeeAuthorizationExpired();
        if (deadline > block.timestamp + MAX_AUTHORIZATION_WINDOW) revert InvalidFeeAuthorization();
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    MATCHED_FEE_AUTHORIZATION_TYPEHASH,
                    parameters.offerer,
                    context.affiliate,
                    parameters.orderHash,
                    sourceOrderHash,
                    deadline
                )
            )
        );
        (address signer, ECDSA.RecoverError error,) = ECDSA.tryRecover(digest, context.feeAuthorizationSignature);
        if (error != ECDSA.RecoverError.NoError || signer != feeAuthorizer) {
            revert InvalidFeeAuthorization();
        }
    }

    function sellIntoBids(
        AdvancedOrder[] calldata orders,
        CriteriaResolver[][] calldata resolvers,
        address affiliate,
        MinimumPayout[] calldata minimumPayouts,
        uint256 feeAuthorizationDeadline,
        bytes calldata feeAuthorizationSignature
    ) external nonReentrant whenNotPaused {
        uint256 appliedFeeBps = feeBps;
        uint256 appliedFeeSplitBps = feeSplitBps;
        if (orders.length == 0) revert EmptyBatch();
        if (orders.length > MAX_BATCH) revert BatchTooLarge();
        if (orders.length != resolvers.length) revert LengthMismatch();

        _validateFeeAuthorization(
            affiliate, keccak256(abi.encode(orders, resolvers)), feeAuthorizationDeadline, feeAuthorizationSignature
        );
        if (minimumPayouts.length == 0 || minimumPayouts.length > orders.length) revert InvalidMinimumPayouts();
        for (uint256 i; i < minimumPayouts.length; ++i) {
            for (uint256 j; j < i; ++j) {
                if (minimumPayouts[i].currency == minimumPayouts[j].currency) revert InvalidMinimumPayouts();
            }
        }
        uint256[] memory payouts = new uint256[](minimumPayouts.length);
        bool[] memory usedCurrencies = new bool[](minimumPayouts.length);
        for (uint256 i = 0; i < orders.length; i++) {
            bool nativeBid = orders[i].parameters.orderType == OrderType.CONTRACT;
            BidDetails memory bid = nativeBid
                ? _calculateNativeBidDetails(orders[i], resolvers[i], affiliate)
                : _calculateBidDetails(orders[i], resolvers[i]);
            uint256 currencyIndex;
            while (currencyIndex < minimumPayouts.length && minimumPayouts[currencyIndex].currency != bid.currency) {
                ++currencyIndex;
            }
            if (currencyIndex == minimumPayouts.length) revert InvalidMinimumPayouts();
            usedCurrencies[currencyIndex] = true;
            payouts[
                currencyIndex
            ] += _sellIntoBid(orders[i], resolvers[i], bid, affiliate, appliedFeeBps, appliedFeeSplitBps, nativeBid);
        }
        for (uint256 i; i < minimumPayouts.length; ++i) {
            if (!usedCurrencies[i]) revert InvalidMinimumPayouts();
            if (payouts[i] < minimumPayouts[i].amount) revert InsufficientSellerPayout();
        }
    }

    function _validateFeeAuthorization(address affiliate, bytes32 fillsHash, uint256 deadline, bytes calldata signature)
        internal
        view
    {
        if (affiliate == address(0)) {
            if (signature.length != 0) revert InvalidFeeAuthorization();
            return;
        }
        if (block.timestamp > deadline) revert FeeAuthorizationExpired();
        if (deadline > block.timestamp + MAX_AUTHORIZATION_WINDOW) revert InvalidFeeAuthorization();
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(FEE_AUTHORIZATION_TYPEHASH, msg.sender, affiliate, fillsHash, deadline))
        );
        if (ECDSA.recover(digest, signature) != feeAuthorizer) revert InvalidFeeAuthorization();
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

    function setAllowedCurrency(address currency, bool allowed) external onlyOwner {
        if (currency == address(0)) revert InvalidBidCurrency();
        emit AllowedCurrencyUpdated(currency, allowed);
        allowedCurrencies[currency] = allowed;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _sellIntoBid(
        AdvancedOrder calldata order,
        CriteriaResolver[] calldata resolvers,
        BidDetails memory bid,
        address affiliate,
        uint256 appliedFeeBps,
        uint256 appliedFeeSplitBps,
        bool nativeBid
    ) internal returns (uint256 sellerPayout) {
        IERC20 token = IERC20(bid.currency);

        uint256 nftBalanceBefore = _pullNft(bid);
        uint256 balanceBefore = token.balanceOf(address(this));
        _approveNftForSeaport(bid);
        if (!nativeBid) _verifyOrderHasntChangedDuringNftOperations(order, bid);
        _approveErc20Consideration(token, bid.currencyConsideration);
        if (nativeBid) activeRoutedFulfiller = msg.sender;
        bool fulfilled = _fulfillAdvancedOrder(order, resolvers);
        if (nativeBid) activeRoutedFulfiller = address(0);
        _disapproveErc20Consideration(token, bid.currencyConsideration);
        _disapproveNftForSeaport(bid);
        if (!fulfilled) revert SeaportCallFailed();
        _verifyNftLeftRouter(bid, nftBalanceBefore);
        uint256 balanceAfter = token.balanceOf(address(this));

        uint256 proceeds = balanceAfter - balanceBefore;
        if (proceeds == 0) revert NoSellerProceeds();

        if (nativeBid) {
            _paySellerErc20(token, msg.sender, proceeds);
            _verifyErc20LeftRouter(token, balanceBefore);
            return proceeds;
        }

        address rewardsRecipient = scatterCollectionRegistry.rewardsRecipient(bid.collection);
        Fees memory fees = _calculateBidFees(proceeds, appliedFeeBps, appliedFeeSplitBps, affiliate, rewardsRecipient);
        sellerPayout = proceeds - fees.totalAmount;

        _distributeFeesErc20(token, fees);
        _paySellerErc20(token, msg.sender, sellerPayout);
        _verifyErc20LeftRouter(token, balanceBefore);

        emit ExternalBidFilled(
            msg.sender,
            address(token),
            bid.orderHash,
            bid.collection,
            bid.tokenId,
            bid.quantity,
            bid.bidder,
            proceeds,
            fees.totalAmount,
            sellerPayout,
            fees.affiliate,
            fees.rewardsRecipient,
            fees.platformAmount,
            fees.rewardsAmount,
            fees.affiliateAmount
        );
    }

    function _calculateNativeBidDetails(
        AdvancedOrder calldata order,
        CriteriaResolver[] calldata resolvers,
        address affiliate
    ) internal view returns (BidDetails memory bid) {
        OrderParameters calldata params = order.parameters;
        if (params.offerer != SCATTER_OFFERER) revert InvalidScatterOfferer();
        if (!ScatterOfferer(SCATTER_OFFERER).trustedRouters(address(this))) revert InvalidScatterOfferer();
        if (order.numerator != 1 || order.denominator != 1) revert InvalidFraction();
        if (resolvers.length != 0 || params.conduitKey != bytes32(0)) revert InvalidConsiderationShape();
        (
            ScatterOfferer.ScatterSubmission memory submission,,
            address nativeAffiliate,
            ScatterOfferer.ScatterFill[] memory fills,,,
        ) = abi.decode(
            order.extraData,
            (
                ScatterOfferer.ScatterSubmission,
                bytes,
                address,
                ScatterOfferer.ScatterFill[],
                bytes32[][],
                uint256,
                bytes
            )
        );
        if (submission.role != ScatterOfferer.Role.Bid) revert InvalidOrderType();
        if (nativeAffiliate != affiliate) revert InvalidFeeAuthorization();
        if (fills.length != 1 || fills[0].itemIndex >= submission.listings.length) revert InvalidConsiderationShape();
        ScatterOfferer.ScatterListing memory listing = submission.listings[fills[0].itemIndex];
        bid.currency = _validateOfferCurrency(order);
        if (listing.currency != bid.currency) revert InvalidBidCurrency();
        if (params.consideration.length != 1 || params.totalOriginalConsiderationItems != 1) {
            revert InvalidConsiderationShape();
        }
        ConsiderationItem calldata item = params.consideration[0];
        bid.isErc721 = listing.assetType == ScatterOfferer.AssetType.ERC721;
        if (
            item.itemType != (bid.isErc721 ? ItemType.ERC721 : ItemType.ERC1155) || item.token != listing.collection
                || item.identifierOrCriteria != fills[0].tokenId || item.startAmount != fills[0].quantity
                || item.endAmount != fills[0].quantity
        ) revert InvalidConsiderationShape();
        if (fills[0].quantity == 0 || (bid.isErc721 && fills[0].quantity != 1)) revert InvalidQuantity();
        bid.collection = listing.collection;
        bid.tokenId = fills[0].tokenId;
        bid.quantity = fills[0].quantity;
    }

    function _calculateBidDetails(AdvancedOrder calldata order, CriteriaResolver[] calldata resolvers)
        internal
        view
        returns (BidDetails memory bid)
    {
        OrderParameters calldata params = order.parameters;

        if (order.numerator == 0 || order.denominator == 0 || order.numerator > order.denominator) {
            revert InvalidFraction();
        }
        if (
            params.orderType != OrderType.FULL_OPEN && params.orderType != OrderType.PARTIAL_OPEN
                && params.orderType != OrderType.FULL_RESTRICTED && params.orderType != OrderType.PARTIAL_RESTRICTED
        ) {
            revert InvalidOrderType();
        }
        if (
            order.numerator < order.denominator
                && (params.orderType == OrderType.FULL_OPEN || params.orderType == OrderType.FULL_RESTRICTED)
        ) {
            revert InvalidFraction();
        }

        bid.currency = _validateOfferCurrency(order);
        if (params.consideration.length == 0) revert InvalidConsiderationShape();
        if (params.consideration.length != params.totalOriginalConsiderationItems) revert InvalidConsiderationShape();

        bid.orderHash = _calculateOrderHash(params);
        (uint256 fillNumerator, uint256 fillDenominator) =
            _calculateActualFillFraction(bid.orderHash, order.numerator, order.denominator);

        bool nftSeen;
        for (uint256 i = 0; i < params.consideration.length; i++) {
            ConsiderationItem calldata item = params.consideration[i];
            if (_isNftItemType(item.itemType)) {
                if (nftSeen) revert InvalidConsiderationShape();
                nftSeen = true;
                if (item.token == bid.currency) revert InvalidConsiderationShape();
                if (item.recipient == address(0) || item.recipient == address(this)) revert InvalidNftRecipient();
                if (item.startAmount != item.endAmount) revert InvalidConsiderationShape();

                (uint256 tokenId, uint256 quantity, bool isErc721) =
                    _calculateNftDetails(item, resolvers, i, fillNumerator, fillDenominator);
                bid.collection = item.token;
                bid.tokenId = tokenId;
                bid.quantity = quantity;
                bid.isErc721 = isErc721;
            } else {
                if (item.itemType != ItemType.ERC20) revert InvalidConsiderationShape();
                if (item.token != bid.currency) revert InvalidBidCurrency();
                if (item.recipient == msg.sender) revert InvalidConsiderationShape();
                if (item.startAmount != item.endAmount) revert InvalidConsiderationShape();
                if (mulmod(item.startAmount, fillNumerator, fillDenominator) != 0) revert InvalidFraction();
                bid.currencyConsideration += Math.mulDiv(item.startAmount, fillNumerator, fillDenominator);
            }
        }

        if (!nftSeen) revert InvalidConsiderationShape();
        bid.bidder = params.offerer;
    }

    function _pullNft(BidDetails memory bid) internal returns (uint256 nftBalanceBefore) {
        if (!bid.isErc721) {
            nftBalanceBefore = IERC1155(bid.collection).balanceOf(address(this), bid.tokenId);
        }
        ConduitTransfer[] memory transfers = new ConduitTransfer[](1);
        transfers[0] = ConduitTransfer(
            bid.isErc721 ? ConduitItemType.ERC721 : ConduitItemType.ERC1155,
            bid.collection,
            msg.sender,
            address(this),
            bid.tokenId,
            bid.quantity
        );
        _executeConduit(transfers);
    }

    function _approveNftForSeaport(BidDetails memory bid) internal {
        if (bid.isErc721) {
            IERC721(bid.collection).approve(SEAPORT, bid.tokenId);
        } else {
            IERC1155(bid.collection).setApprovalForAll(SEAPORT, true);
        }
    }

    function _verifyOrderHasntChangedDuringNftOperations(AdvancedOrder calldata order, BidDetails memory bid)
        internal
        view
    {
        if (_calculateOrderHash(order.parameters) != bid.orderHash) revert OrderStateChanged();
    }

    function _approveErc20Consideration(IERC20 token, uint256 amount) internal {
        if (amount == 0) return;
        token.forceApprove(SEAPORT, amount);
    }

    function _fulfillAdvancedOrder(AdvancedOrder calldata order, CriteriaResolver[] calldata resolvers)
        internal
        returns (bool)
    {
        return SeaportInterface(SEAPORT).fulfillAdvancedOrder(order, resolvers, bytes32(0), address(this));
    }

    function _disapproveErc20Consideration(IERC20 token, uint256 amount) internal {
        if (amount == 0) return;
        token.forceApprove(SEAPORT, 0);
    }

    function _disapproveNftForSeaport(BidDetails memory bid) internal {
        if (bid.isErc721) return;
        IERC1155(bid.collection).setApprovalForAll(SEAPORT, false);
    }

    function _verifyNftLeftRouter(BidDetails memory bid, uint256 nftBalanceBefore) internal view {
        if (bid.isErc721) {
            try IERC721(bid.collection).ownerOf(bid.tokenId) returns (address owner) {
                if (owner == address(this)) revert NftNotTransferred();
            } catch {}
            return;
        }

        if (IERC1155(bid.collection).balanceOf(address(this), bid.tokenId) != nftBalanceBefore) {
            revert NftNotTransferred();
        }
    }

    function _calculateBidFees(
        uint256 proceeds,
        uint256 appliedFeeBps,
        uint256 appliedFeeSplitBps,
        address affiliate,
        address rewardsRecipient
    ) internal pure returns (Fees memory fees) {
        fees.totalAmount = Math.mulDiv(proceeds, appliedFeeBps, BPS_DENOMINATOR);
        if (affiliate != address(0)) {
            fees.platformAmount = Math.mulDiv(fees.totalAmount, appliedFeeSplitBps, BPS_DENOMINATOR);
            fees.affiliateAmount = fees.totalAmount - fees.platformAmount;
            fees.affiliate = fees.affiliateAmount > 0 ? affiliate : address(0);
            return fees;
        }
        if (rewardsRecipient != address(0)) {
            fees.platformAmount = Math.mulDiv(fees.totalAmount, appliedFeeSplitBps, BPS_DENOMINATOR);
            fees.rewardsAmount = fees.totalAmount - fees.platformAmount;
            fees.rewardsRecipient = fees.rewardsAmount > 0 ? rewardsRecipient : address(0);
            return fees;
        }
        fees.platformAmount = fees.totalAmount;
    }

    function _distributeFeesErc20(IERC20 token, Fees memory fees) internal {
        if (fees.platformAmount > 0) token.safeTransfer(PLATFORM, fees.platformAmount);
        if (fees.rewardsAmount > 0) token.safeTransfer(fees.rewardsRecipient, fees.rewardsAmount);
        if (fees.affiliateAmount > 0) token.safeTransfer(fees.affiliate, fees.affiliateAmount);
    }

    function _paySellerErc20(IERC20 token, address seller, uint256 amount) internal {
        uint256 balanceBefore = token.balanceOf(seller);
        token.safeTransfer(seller, amount);
        if (token.balanceOf(seller) != balanceBefore + amount) revert CurrencyBalanceInvariant();
    }

    function _verifyErc20LeftRouter(IERC20 token, uint256 balanceBefore) internal view {
        if (token.balanceOf(address(this)) != balanceBefore) revert CurrencyBalanceInvariant();
    }

    function _calculateNftDetails(
        ConsiderationItem calldata item,
        CriteriaResolver[] calldata resolvers,
        uint256 itemIndex,
        uint256 fillNumerator,
        uint256 fillDenominator
    ) internal pure returns (uint256 tokenId, uint256 quantity, bool isErc721) {
        ItemType itemType = item.itemType;
        bool identifierIsMerkleRoot =
            itemType == ItemType.ERC721_WITH_CRITERIA || itemType == ItemType.ERC1155_WITH_CRITERIA;

        tokenId =
            identifierIsMerkleRoot ? _calculateNftCriteriaIdentifier(resolvers, itemIndex) : item.identifierOrCriteria;
        if (mulmod(item.startAmount, fillNumerator, fillDenominator) != 0) revert InvalidFraction();

        quantity = Math.mulDiv(item.startAmount, fillNumerator, fillDenominator);
        if (quantity == 0) revert InvalidQuantity();

        isErc721 = itemType == ItemType.ERC721 || itemType == ItemType.ERC721_WITH_CRITERIA;
        if (isErc721 && quantity != 1) revert InvalidQuantity();
    }

    function _calculateActualFillFraction(bytes32 orderHash, uint120 requestedNumerator, uint120 requestedDenominator)
        internal
        view
        returns (uint256, uint256)
    {
        (,, uint256 filledNumerator, uint256 filledDenominator) = SeaportInterface(SEAPORT).getOrderStatus(orderHash);
        if (filledDenominator == 0) return (requestedNumerator, requestedDenominator);

        uint256 remaining = filledDenominator - filledNumerator;
        if (requestedDenominator == 1) return (remaining, filledDenominator);
        if (requestedDenominator == filledDenominator) {
            return (Math.min(requestedNumerator, remaining), filledDenominator);
        }

        uint256 totalPieces = uint256(requestedDenominator) * filledDenominator;
        uint256 filledPieces = filledNumerator * requestedDenominator;
        uint256 requestedPieces = uint256(requestedNumerator) * filledDenominator;
        uint256 availablePieces = totalPieces - filledPieces;
        return (Math.min(requestedPieces, availablePieces), totalPieces);
    }

    function _calculateNftCriteriaIdentifier(CriteriaResolver[] calldata resolvers, uint256 itemIndex)
        internal
        pure
        returns (uint256 identifier)
    {
        uint256 matchCount;
        for (uint256 i = 0; i < resolvers.length; i++) {
            CriteriaResolver calldata resolver = resolvers[i];
            if (resolver.side != Side.CONSIDERATION) continue;
            if (resolver.index != itemIndex) continue;
            matchCount++;
            identifier = resolver.identifier;
        }
        if (matchCount == 0) revert MissingCriteriaResolver();
        if (matchCount > 1) revert DuplicateCriteriaResolver();
    }

    // Callers choose the token and its minimum; balance checks do not establish token honesty.
    // Only owner-allowed currencies settle.
    function _validateOfferCurrency(AdvancedOrder calldata order) internal view returns (address currency) {
        if (order.parameters.offer.length != 1) revert InvalidOfferShape();
        OfferItem calldata offer = order.parameters.offer[0];
        if (offer.itemType != ItemType.ERC20) revert InvalidOfferShape();
        if (!allowedCurrencies[offer.token]) revert InvalidBidCurrency();
        if (offer.identifierOrCriteria != 0) revert InvalidOfferShape();
        if (offer.startAmount == 0) revert InvalidOfferShape();
        if (offer.startAmount != offer.endAmount) revert InvalidOfferShape();
        return offer.token;
    }

    function _calculateOrderHash(OrderParameters calldata params) internal view returns (bytes32) {
        uint256 counter = SeaportInterface(SEAPORT).getCounter(params.offerer);
        OrderComponents memory components = OrderComponents({
            offerer: params.offerer,
            zone: params.zone,
            offer: params.offer,
            consideration: params.consideration,
            orderType: params.orderType,
            startTime: params.startTime,
            endTime: params.endTime,
            zoneHash: params.zoneHash,
            salt: params.salt,
            conduitKey: params.conduitKey,
            counter: counter
        });
        return SeaportInterface(SEAPORT).getOrderHash(components);
    }

    function _isNftItemType(ItemType itemType) internal pure returns (bool) {
        return itemType == ItemType.ERC721 || itemType == ItemType.ERC721_WITH_CRITERIA || itemType == ItemType.ERC1155
            || itemType == ItemType.ERC1155_WITH_CRITERIA;
    }
}
