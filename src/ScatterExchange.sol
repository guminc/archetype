// forge-lint: disable-start(asm-keccak256, block-timestamp)

// SPDX-License-Identifier: BUSL-1.1
// ScatterExchange v0.1.0
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
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ScatterCollectionRegistry} from "./ScatterCollectionRegistry.sol";

/// Settles Scatter listings and bids without Seaport or a conduit. This
/// contract is the only caller of every NFT transfer it settles, and it moves
/// an NFT only inside a fill that pays Scatter's fee on the signed price. A
/// collection whose transfers are limited to whitelisted operators can
/// therefore whitelist this address alone.
///
/// Assets move directly between the two parties and the fee recipients. The
/// contract holds none, so sellers approve it for their NFTs and payers approve
/// it for their ERC20.
contract ScatterExchange is EIP712, Ownable2Step, Pausable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    error OrderExpired();
    error OrderCancelled();
    error NonceMismatch();
    error CurrencyMismatch();
    error QuantityExceeded();
    error InvalidCriteriaProof();
    error TokenIdMismatch();
    error InvalidRole();
    error EmptySpec();
    error InvalidFill();
    error InvalidRecipient();
    error InvalidRouter();
    error InvalidRoutedFulfiller();
    error DuplicateListingItem();
    error InvalidScatterCollectionRegistry();
    error InvalidFeeAuthorizer();
    error InvalidFeeAuthorization();
    error FeeAuthorizationExpired();
    error InvalidFeeBps();
    error InvalidFeeSplitBps();
    error FeeBpsExceedsLimit(uint256 currentFeeBps, uint256 maximumFeeBps);
    error InvalidNativeValue(uint256 sent, uint256 required);
    error NativeTransferFailed(address recipient, bytes reason);

    address public constant PLATFORM = 0x8952caF7E5bf1fe63ebe94148ca802F3eF127C98;

    uint256 public constant MAX_FEE_BPS = 5000; // 50%
    uint256 public constant BPS_DENOMINATOR = 10000; // 100%
    uint256 public constant MAX_AUTHORIZATION_WINDOW = 7 days;

    bytes32 public constant SCATTER_LISTING_TYPEHASH = keccak256(
        "ScatterListing(uint8 assetType,address collection,uint256 tokenId,uint256 quantity,address currency,uint256 priceWei)"
    );
    bytes32 public constant SCATTER_SUBMISSION_TYPEHASH = keccak256(
        "ScatterSubmission(uint8 role,ScatterListing[] listings,bytes32 criteriaRoot,uint256 maxFeeBps,uint256 startTime,uint256 endTime,uint256 nonce,bytes32 salt)ScatterListing(uint8 assetType,address collection,uint256 tokenId,uint256 quantity,address currency,uint256 priceWei)"
    );
    bytes32 public constant FEE_AUTHORIZATION_TYPEHASH =
        keccak256("FeeAuthorization(address fulfiller,address affiliate,bytes32 fillsHash,uint256 deadline)");

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

    struct FillInput {
        ScatterSubmission submission;
        bytes submissionSig;
        ScatterFill[] fills;
        bytes32[][] criteriaProofs;
    }

    struct CancelListingItem {
        bytes32 submissionHash;
        uint256 itemIndex;
    }

    struct Fees {
        uint256 sellerAmount;
        uint256 platformAmount;
        uint256 rewardsAmount;
        uint256 affiliateAmount;
    }

    mapping(address signer => uint256 counter) public counter;
    mapping(address signer => mapping(bytes32 submissionHash => mapping(uint256 itemIndex => bool cancelled))) public
        cancelledListings;
    mapping(address signer => mapping(bytes32 submissionHash => mapping(uint256 itemIndex => uint256 filled))) public
        filledListingQuantity;
    mapping(address router => bool trusted) public trustedRouters;
    ScatterCollectionRegistry public immutable scatterCollectionRegistry;

    /// Server-held signer for affiliate fee authorizations. The owner may rotate it.
    address public feeAuthorizer;
    uint16 private _feeBps = 500;
    uint16 private _feeSplitBps = 5000;

    function feeBps() external view returns (uint256) {
        return _feeBps;
    }

    function feeSplitBps() external view returns (uint256) {
        return _feeSplitBps;
    }

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
        address initialFeeAuthorizer
    ) EIP712("Scatter Exchange", "1") Ownable(initialOwner) {
        if (address(scatterCollectionRegistry_).code.length == 0) {
            revert InvalidScatterCollectionRegistry();
        }
        if (initialFeeAuthorizer == address(0)) revert InvalidFeeAuthorizer();
        scatterCollectionRegistry = scatterCollectionRegistry_;
        feeAuthorizer = initialFeeAuthorizer;
    }

    /// Buys from listing submissions. The caller pays each listing's signed
    /// price: native listings from `msg.value`, which must equal their sum, and
    /// ERC20 listings from the caller's allowance. Every NFT goes to `recipient`.
    function buyListings(
        FillInput[] calldata inputs,
        address recipient,
        address affiliate,
        uint256 feeAuthorizationDeadline,
        bytes calldata feeAuthorizationSignature
    ) external payable nonReentrant whenNotPaused {
        if (recipient == address(0) || recipient == address(this)) {
            revert InvalidRecipient();
        }
        uint256 appliedFeeBps = _feeBps;
        uint256 appliedFeeSplitBps = _feeSplitBps;
        address fulfiller = _resolveFulfiller(msg.sender);
        _validateFeeAuthorization(fulfiller, inputs, affiliate, feeAuthorizationDeadline, feeAuthorizationSignature);

        uint256 nativeSpent;
        for (uint256 i = 0; i < inputs.length; i++) {
            nativeSpent += _settle(
                inputs[i],
                Role.Listing,
                fulfiller,
                recipient,
                affiliate,
                appliedFeeBps,
                appliedFeeSplitBps,
                msg.value - nativeSpent
            );
        }
        if (nativeSpent != msg.value) revert InvalidNativeValue(msg.value, nativeSpent);
    }

    /// Sells the caller's NFTs into bid submissions. Each bidder pays from their
    /// ERC20 allowance and receives the NFT. `maximumFeeBps` bounds the fee taken
    /// from the caller's proceeds.
    function sellIntoBids(
        FillInput[] calldata inputs,
        uint256 maximumFeeBps,
        address affiliate,
        uint256 feeAuthorizationDeadline,
        bytes calldata feeAuthorizationSignature
    ) external nonReentrant whenNotPaused {
        uint256 appliedFeeBps = _feeBps;
        uint256 appliedFeeSplitBps = _feeSplitBps;
        if (appliedFeeBps > maximumFeeBps) {
            revert FeeBpsExceedsLimit(appliedFeeBps, maximumFeeBps);
        }
        _validateFeeAuthorization(msg.sender, inputs, affiliate, feeAuthorizationDeadline, feeAuthorizationSignature);

        for (uint256 i = 0; i < inputs.length; i++) {
            _settle(inputs[i], Role.Bid, msg.sender, address(0), affiliate, appliedFeeBps, appliedFeeSplitBps, 0);
        }
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
        remaining = filled >= quantity ? 0 : quantity - filled;
    }

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
        emit FeeBpsUpdated(_feeBps, newFeeBps);
        // forge-lint: disable-next-line(unsafe-typecast)
        _feeBps = uint16(newFeeBps);
    }

    function setFeeSplitBps(uint256 newFeeSplitBps) external onlyOwner {
        if (newFeeSplitBps > BPS_DENOMINATOR) revert InvalidFeeSplitBps();
        emit FeeSplitBpsUpdated(_feeSplitBps, newFeeSplitBps);
        // forge-lint: disable-next-line(unsafe-typecast)
        _feeSplitBps = uint16(newFeeSplitBps);
    }

    /// Settles the selected fills of one submission and returns the native
    /// currency it spent. The maker is the recovered signer and the taker is the
    /// caller, so NFTs leave only the signing seller or the calling seller, and
    /// payment leaves only the calling buyer or the signing bidder. For routed
    /// listing buys, `fulfiller` is the attributed buyer while `msg.sender` pays.
    function _settle(
        FillInput calldata input,
        Role role,
        address fulfiller,
        address listingRecipient,
        address affiliate,
        uint256 appliedFeeBps,
        uint256 appliedFeeSplitBps,
        uint256 nativeAvailable
    ) internal returns (uint256 nativeSpent) {
        ScatterSubmission calldata submission = input.submission;
        ScatterFill[] calldata fills = input.fills;
        if (submission.role != role) revert InvalidRole();

        (bytes32 submissionHash, address signer, uint256 totalPrice) = _validateFills(input, appliedFeeBps);

        address currency = submission.listings[fills[0].itemIndex].currency;
        if (currency == address(0)) {
            if (totalPrice > nativeAvailable) {
                revert InvalidNativeValue(msg.value, msg.value - nativeAvailable + totalPrice);
            }
            nativeSpent = totalPrice;
        }

        for (uint256 i = 0; i < fills.length; i++) {
            filledListingQuantity[signer][submissionHash][fills[i].itemIndex] += fills[i].quantity;
        }

        (address seller, address buyer, address payer, address nftRecipient) = role == Role.Listing
            ? (signer, fulfiller, msg.sender, listingRecipient)
            : (msg.sender, signer, signer, signer);

        Fees memory totalFees;
        for (uint256 i = 0; i < fills.length; i++) {
            ScatterFill calldata fill = fills[i];
            ScatterListing calldata item = submission.listings[fill.itemIndex];
            uint256 price = item.assetType == AssetType.ERC1155 ? item.priceWei * fill.quantity : item.priceWei;
            address rewardsRecipient =
                affiliate == address(0) ? scatterCollectionRegistry.rewardsRecipient(item.collection) : address(0);
            Fees memory fees = _computeFee(price, appliedFeeBps, appliedFeeSplitBps, affiliate, rewardsRecipient);
            totalFees.sellerAmount += fees.sellerAmount;
            totalFees.platformAmount += fees.platformAmount;
            totalFees.affiliateAmount += fees.affiliateAmount;

            if (item.assetType == AssetType.ERC1155) {
                IERC1155(item.collection).safeTransferFrom(seller, nftRecipient, fill.tokenId, fill.quantity, "");
            } else {
                IERC721(item.collection).transferFrom(seller, nftRecipient, fill.tokenId);
            }
            _pay(currency, payer, rewardsRecipient, fees.rewardsAmount);

            emit ScatterSale({
                submissionHash: submissionHash,
                role: uint8(role),
                seller: seller,
                buyer: buyer,
                collection: item.collection,
                itemIndex: fill.itemIndex,
                tokenId: fill.tokenId,
                quantity: fill.quantity,
                currency: currency,
                totalPrice: price,
                affiliate: fees.affiliateAmount > 0 ? affiliate : address(0),
                rewardsRecipient: fees.rewardsAmount > 0 ? rewardsRecipient : address(0),
                sellerAmount: fees.sellerAmount,
                platformAmount: fees.platformAmount,
                rewardsAmount: fees.rewardsAmount,
                affiliateAmount: fees.affiliateAmount
            });
        }

        _pay(currency, payer, seller, totalFees.sellerAmount);
        _pay(currency, payer, PLATFORM, totalFees.platformAmount);
        _pay(currency, payer, affiliate, totalFees.affiliateAmount);
    }

    /// Native payments come from the `msg.value` of the buying caller.
    function _pay(address currency, address payer, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (currency == address(0)) {
            (bool ok, bytes memory reason) = to.call{value: amount}("");
            if (!ok) revert NativeTransferFailed(to, reason);
        } else {
            IERC20(currency).safeTransferFrom(payer, to, amount);
        }
    }

    /// Affiliate attribution takes precedence over rewards.
    function _computeFee(
        uint256 price,
        uint256 appliedFeeBps,
        uint256 appliedFeeSplitBps,
        address affiliate,
        address rewardsRecipient
    ) internal pure returns (Fees memory fees) {
        uint256 totalFee = Math.mulDiv(price, appliedFeeBps, BPS_DENOMINATOR);
        fees.sellerAmount = price - totalFee;

        if (affiliate != address(0)) {
            fees.platformAmount = Math.mulDiv(totalFee, appliedFeeSplitBps, BPS_DENOMINATOR);
            fees.affiliateAmount = totalFee - fees.platformAmount;
            return fees;
        }

        if (rewardsRecipient != address(0)) {
            fees.platformAmount = Math.mulDiv(totalFee, appliedFeeSplitBps, BPS_DENOMINATOR);
            fees.rewardsAmount = totalFee - fees.platformAmount;
            return fees;
        }

        fees.platformAmount = totalFee;
    }

    /// For routed listing buys, read the buyer from the trusted router so sale
    /// attribution and affiliate authorizations bind to the router's caller
    /// rather than the shared router address.
    function _resolveFulfiller(address caller) internal view returns (address fulfiller) {
        if (!trustedRouters[caller]) return caller;

        (bool ok, bytes memory data) = caller.staticcall(abi.encodeWithSignature("activeRoutedFulfiller()"));
        if (!ok || data.length != 32) revert InvalidRoutedFulfiller();
        fulfiller = abi.decode(data, (address));
        if (fulfiller == address(0)) revert InvalidRoutedFulfiller();
    }

    /// The authorization binds the affiliate to the fulfiller and to these
    /// exact inputs, so a fulfiller cannot name an affiliate of their own
    /// choosing.
    function _validateFeeAuthorization(
        address fulfiller,
        FillInput[] calldata inputs,
        address affiliate,
        uint256 deadline,
        bytes calldata signature
    ) internal view {
        if (affiliate == address(0)) {
            if (signature.length != 0) revert InvalidFeeAuthorization();
            return;
        }
        if (block.timestamp > deadline) revert FeeAuthorizationExpired();
        if (deadline > block.timestamp + MAX_AUTHORIZATION_WINDOW) revert InvalidFeeAuthorization();

        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(FEE_AUTHORIZATION_TYPEHASH, fulfiller, affiliate, keccak256(abi.encode(inputs)), deadline)
            )
        );
        if (ECDSA.recover(digest, signature) != feeAuthorizer) revert InvalidFeeAuthorization();
    }

    function _validateFills(FillInput calldata input, uint256 appliedFeeBps)
        internal
        view
        returns (bytes32 submissionHash, address signer, uint256 totalPrice)
    {
        ScatterSubmission calldata submission = input.submission;
        ScatterFill[] calldata fills = input.fills;
        if (appliedFeeBps > submission.maxFeeBps) revert FeeBpsExceedsLimit(appliedFeeBps, submission.maxFeeBps);
        if (submission.listings.length == 0 || fills.length == 0) revert EmptySpec();

        bool needsCriteriaProofs = submission.role == Role.Bid && submission.criteriaRoot != bytes32(0);
        if (needsCriteriaProofs && input.criteriaProofs.length != fills.length) revert InvalidCriteriaProof();

        _validateNoDuplicateTokenIds(submission);
        _validateNoDuplicateItemIndexes(fills);

        if (fills[0].itemIndex >= submission.listings.length) revert InvalidFill();
        address fillCurrency = submission.listings[fills[0].itemIndex].currency;
        for (uint256 i = 0; i < fills.length; i++) {
            _validateFill(submission, fills[i], fillCurrency);
            ScatterListing calldata item = submission.listings[fills[i].itemIndex];
            totalPrice += item.assetType == AssetType.ERC1155 ? item.priceWei * fills[i].quantity : item.priceWei;
        }

        if (block.timestamp < submission.startTime || block.timestamp >= submission.endTime) revert OrderExpired();

        submissionHash = _hashSubmission(submission);
        signer = ECDSA.recover(submissionHash, input.submissionSig);
        if (submission.nonce != counter[signer]) revert NonceMismatch();

        for (uint256 i = 0; i < fills.length; i++) {
            ScatterFill calldata fill = fills[i];
            if (cancelledListings[signer][submissionHash][fill.itemIndex]) revert OrderCancelled();
            if (
                filledListingQuantity[signer][submissionHash][fill.itemIndex] + fill.quantity
                    > submission.listings[fill.itemIndex].quantity
            ) {
                revert QuantityExceeded();
            }
            if (needsCriteriaProofs) {
                bytes32 leaf = keccak256(abi.encode(fill.tokenId));
                if (!MerkleProof.verifyCalldata(input.criteriaProofs[i], submission.criteriaRoot, leaf)) {
                    revert InvalidCriteriaProof();
                }
            }
        }
    }

    function _validateNoDuplicateTokenIds(ScatterSubmission calldata submission) internal pure {
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

    function _validateNoDuplicateItemIndexes(ScatterFill[] calldata fills) internal pure {
        for (uint256 i = 0; i < fills.length; i++) {
            for (uint256 j = i + 1; j < fills.length; j++) {
                if (fills[j].itemIndex == fills[i].itemIndex) revert DuplicateListingItem();
            }
        }
    }

    function _validateFill(ScatterSubmission calldata submission, ScatterFill calldata fill, address fillCurrency)
        internal
        pure
    {
        if (fill.itemIndex >= submission.listings.length) revert InvalidFill();
        if (fill.quantity == 0) revert EmptySpec();

        ScatterListing calldata item = submission.listings[fill.itemIndex];

        if (item.currency != fillCurrency) revert CurrencyMismatch();
        if (submission.role == Role.Bid && item.currency == address(0)) revert CurrencyMismatch();

        // A bid for token ID zero accepts any token, limited by its criteria root.
        if (submission.role == Role.Listing && fill.tokenId != item.tokenId) revert TokenIdMismatch();
        if (submission.role == Role.Bid && item.tokenId != 0 && fill.tokenId != item.tokenId) revert TokenIdMismatch();

        if (item.assetType == AssetType.ERC721) {
            if (fill.quantity != 1) revert QuantityExceeded();
            if (submission.role == Role.Listing && item.quantity != 1) revert QuantityExceeded();
            if (submission.role == Role.Bid && item.tokenId != 0 && item.quantity != 1) revert QuantityExceeded();
        }
    }

    function _hashSubmission(ScatterSubmission calldata submission) internal view returns (bytes32) {
        bytes32[] memory listingHashes = new bytes32[](submission.listings.length);
        for (uint256 i = 0; i < submission.listings.length; i++) {
            ScatterListing calldata listing = submission.listings[i];
            listingHashes[i] = keccak256(
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
}
