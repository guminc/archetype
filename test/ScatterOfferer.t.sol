// SPDX-License-Identifier: MIT
// forge-lint: disable-start(mixed-case-function, mixed-case-variable, asm-keccak256)
pragma solidity ^0.8.20;

import {ConduitTest} from "./helpers/ConduitTest.sol";
import {TokenTransferrerErrors} from "seaport-types/src/interfaces/TokenTransferrerErrors.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ScatterOfferer,
    OnlySeaport,
    OrderExpired,
    OrderCancelled,
    InvalidSignature,
    NonceMismatch,
    QuantityExceeded,
    InvalidCriteriaProof,
    TokenIdNotZeroForCriteria,
    InvalidRole,
    InvalidAssetType,
    EmptySpec,
    CurrencyMismatch,
    InvalidRouter,
    InvalidFill,
    DuplicateListingItem,
    InvalidFeeAuthorizer,
    InvalidFeeAuthorization,
    FeeAuthorizationExpired,
    InvalidRoutedFulfiller,
    InvalidFeeBps,
    InvalidFeeSplitBps,
    FeeBpsExceedsLimit
} from "../src/ScatterOfferer.sol";
import {ContractOffererInterface} from "seaport-types/src/interfaces/ContractOffererInterface.sol";
import {ItemType, ReceivedItem, SpentItem, Schema} from "seaport-types/src/lib/ConsiderationStructs.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ScatterCollectionRegistry} from "../src/ScatterCollectionRegistry.sol";

contract ScatterOffererTest is ConduitTest {
    uint256 internal constant FEE_AUTHORIZER_PK = 0xA11CE;

    ScatterOffererWrapperExposingInternalMethods internal subject;

    MockERC721 internal nft721;
    MockERC1155 internal nft1155;
    ERC20Mock internal weth;
    ScatterCollectionRegistry internal scatterCollectionRegistry;

    address internal owner;
    address internal seller;
    address internal bidder;
    address internal buyer;
    address internal rewardsRecipient;
    address internal affiliate;
    address internal feeAuthorizer = vm.addr(FEE_AUTHORIZER_PK);
    address internal router;
    address internal other;

    uint256 internal constant SELLER_PK = uint256(keccak256("seller"));
    uint256 internal constant BIDDER_PK = uint256(keccak256("bidder"));

    function setUp() public {
        _setUpConduit();
        owner = makeAddr("owner");
        seller = vm.addr(SELLER_PK);
        bidder = vm.addr(BIDDER_PK);
        buyer = makeAddr("buyer");
        rewardsRecipient = makeAddr("rewardsRecipient");
        affiliate = makeAddr("affiliate");
        router = makeAddr("router");
        other = makeAddr("other");

        vm.deal(buyer, 100 ether);

        scatterCollectionRegistry = new ScatterCollectionRegistry(address(this));
        _prank(owner);
        subject = new ScatterOffererWrapperExposingInternalMethods(
            owner, scatterCollectionRegistry, feeAuthorizer, conduitKey
        );
        vm.stopPrank();
        _openConduitChannel(address(subject));
        _openConduitChannel(subject.SEAPORT());

        nft721 = new MockERC721();
        nft1155 = new MockERC1155();
        weth = new ERC20Mock();

        nft721.mint(seller, 1);
        nft721.mint(seller, 2);
        nft1155.mint(seller, 1, 10);
        weth.mint(bidder, 100 ether);

        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);
        nft1155.setApprovalForAll(address(conduit), true);

        _prank(bidder);
        weth.approve(address(conduit), type(uint256).max);

        _prank(other);
    }

    function test_constructor_setsOwner() public view {
        assertEq(subject.owner(), owner);
    }

    function test_pause_requiresCurrentOwner() public {
        _prank(other);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        subject.pause();
        assertFalse(subject.paused());

        _prank(owner);
        subject.pause();
        subject.transferOwnership(other);
        assertTrue(subject.paused());

        _prank(other);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        subject.unpause();
        subject.acceptOwnership();

        _prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        subject.unpause();

        _prank(other);
        subject.unpause();
        assertFalse(subject.paused());
    }

    function test_pausedOfferer_allowsCancellationAndCounterInvalidation(bool invalidateCounter) public {
        ScatterOfferer.ScatterSubmission memory listing = _generateListing();
        bytes memory signature = _signListing(listing, SELLER_PK);
        bytes memory context = _encodeContext(listing, signature, address(0), 1, 1, new bytes32[](0));
        bytes32 listingHash = subject.hashSubmission(listing);

        _prank(owner);
        subject.pause();

        _prank(seller);
        if (invalidateCounter) {
            subject.incrementCounter();
            assertEq(subject.counter(seller), 1);
        } else {
            subject.cancelListings(_singleCancelItem(listingHash));
            (, bool cancelled,,) = subject.listingStatus(seller, listing, 0);
            assertTrue(cancelled);
        }

        _prank(owner);
        subject.unpause();

        _prank(subject.SEAPORT());
        vm.expectRevert(invalidateCounter ? NonceMismatch.selector : OrderCancelled.selector);
        subject.generateOrder(buyer, new SpentItem[](0), new SpentItem[](0), context);
        assertEq(nft721.ownerOf(1), seller);
        assertEq(subject.filledListingQuantity(seller, listingHash, 0), 0);
    }

    function test_setFeeSplitBps_requiresOwnerAndValidBasisPoints() public {
        _prank(other);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        subject.setFeeSplitBps(3000);

        _prank(owner);
        vm.expectRevert(InvalidFeeSplitBps.selector);
        subject.setFeeSplitBps(10001);
        vm.expectRevert(InvalidFeeSplitBps.selector);
        subject.setFeeSplitBps(type(uint256).max);

        vm.expectEmit(true, true, true, true);
        emit ScatterOfferer.FeeSplitBpsUpdated(5000, 3000);
        subject.setFeeSplitBps(3000);
        assertEq(subject.feeSplitBps(), 3000);
        vm.expectEmit(true, true, true, true);
        emit ScatterOfferer.FeeSplitBpsUpdated(3000, 0);
        subject.setFeeSplitBps(0);
        assertEq(subject.feeSplitBps(), 0);
        vm.expectEmit(true, true, true, true);
        emit ScatterOfferer.FeeSplitBpsUpdated(0, 10000);
        subject.setFeeSplitBps(10000);
        assertEq(subject.feeSplitBps(), 10000);
    }

    function test_transferOwnershipRequiresAcceptance() public {
        _prank(owner);
        subject.transferOwnership(other);

        assertEq(subject.owner(), owner);
        assertEq(subject.pendingOwner(), other);

        _prank(other);
        subject.acceptOwnership();
        subject.setTrustedRouter(router, true);

        assertEq(subject.owner(), other);
        assertEq(subject.pendingOwner(), address(0));
        assertTrue(subject.trustedRouters(router));
    }

    function test_constructor_initializesCounterToZero() public view {
        assertEq(subject.counter(seller), 0);
        assertEq(subject.counter(bidder), 0);
    }

    function test_constructor_startsTrustedRoutersFalse() public view {
        assertFalse(subject.trustedRouters(router));
        assertFalse(subject.trustedRouters(other));
    }

    function test_hashSubmission_isBoundToContractDomain() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateListing();

        ScatterOfferer subject2 = new ScatterOfferer(owner, scatterCollectionRegistry, feeAuthorizer, conduitKey);
        assertTrue(subject.hashSubmission(listing) != subject2.hashSubmission(listing));
    }

    function test_hashSubmission_changesWhenChildListingChanges() public view {
        ScatterOfferer.ScatterSubmission memory listing = _generateTwoItemListing();
        bytes32 baseHash = subject.hashSubmission(listing);

        listing.listings[1].priceWei = 3 ether;

        assertTrue(subject.hashSubmission(listing) != baseHash);
    }

    function test_hashSubmission_changesWhenChildListingOrderChanges() public view {
        ScatterOfferer.ScatterSubmission memory listing = _generateTwoItemListing();
        bytes32 baseHash = subject.hashSubmission(listing);

        ScatterOfferer.ScatterListing memory first = listing.listings[0];
        listing.listings[0] = listing.listings[1];
        listing.listings[1] = first;

        assertTrue(subject.hashSubmission(listing) != baseHash);
    }

    function test_listingStatus_returnsListingHash() public view {
        ScatterOfferer.ScatterSubmission memory listing = _generateListing();
        bytes32 expectedHash = subject.hashSubmission(listing);

        (bytes32 listingHash,,,) = subject.listingStatus(seller, listing, 0);

        assertEq(listingHash, expectedHash);
    }

    function test_listingStatus_returnsFalseIsCancelledWhenNotCancelled() public view {
        ScatterOfferer.ScatterSubmission memory listing = _generateListing();

        (, bool isCancelled,,) = subject.listingStatus(seller, listing, 0);

        assertEq(isCancelled, false);
    }

    function test_listingStatus_returnsZeroFilledAndFullRemainingWhenFresh() public view {
        ScatterOfferer.ScatterSubmission memory listing = _generateListing();
        listing.listings[0].quantity = 5;

        (,, uint256 filled, uint256 remaining) = subject.listingStatus(seller, listing, 0);

        assertEq(filled, 0);
        assertEq(remaining, 5);
    }

    function test_listingStatus_returnsPartialFilledAndRemainingAfterPartialFill() public {
        _prank(seller);
        ScatterOfferer.ScatterSubmission memory listing = _generateListing();
        listing.listings[0].quantity = 5;

        subject._cheat_alterFilledQuantity(seller, listing, 2);

        (,, uint256 filled, uint256 remaining) = subject.listingStatus(seller, listing, 0);

        assertEq(filled, 2);
        assertEq(remaining, 3);
    }

    function test_listingStatus_returnsZeroRemainingWhenFullyFilled() public {
        _prank(seller);
        ScatterOfferer.ScatterSubmission memory listing = _generateListing();
        listing.listings[0].quantity = 3;

        subject._cheat_alterFilledQuantity(seller, listing, 3);

        (,, uint256 filled, uint256 remaining) = subject.listingStatus(seller, listing, 0);

        assertEq(filled, 3);
        assertEq(remaining, 0);
    }

    function test_listingStatus_returnsZeroRemainingWhenOverFilled() public {
        _prank(seller);
        ScatterOfferer.ScatterSubmission memory listing = _generateListing();
        listing.listings[0].quantity = 3;

        subject._cheat_alterFilledQuantity(seller, listing, 5);

        (,, uint256 filled, uint256 remaining) = subject.listingStatus(seller, listing, 0);

        assertEq(filled, 5);
        assertEq(remaining, 0);
    }

    function test_listingStatus_fillsAreScopedBySigner() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateListing();
        listing.listings[0].quantity = 5;

        subject._cheat_alterFilledQuantity(seller, listing, 5);

        (,, uint256 filledForSeller, uint256 remainingForSeller) = subject.listingStatus(seller, listing, 0);
        (,, uint256 filledForBidder, uint256 remainingForBidder) = subject.listingStatus(bidder, listing, 0);

        assertEq(filledForSeller, 5);
        assertEq(remainingForSeller, 0);
        assertEq(filledForBidder, 0);
        assertEq(remainingForBidder, 5);
    }

    function test_listingStatus_fillsAreScopedByItemIndex() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateTwoItemListing();

        subject._cheat_alterFilledQuantity(seller, listing, 0, 1);

        (,, uint256 filledFirst, uint256 remainingFirst) = subject.listingStatus(seller, listing, 0);
        (,, uint256 filledSecond, uint256 remainingSecond) = subject.listingStatus(seller, listing, 1);

        assertEq(filledFirst, 1);
        assertEq(remainingFirst, 0);
        assertEq(filledSecond, 0);
        assertEq(remainingSecond, 1);
    }

    function test_listingStatus_failsWhenItemIndexInvalid() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateListing();

        vm.expectRevert(InvalidFill.selector);
        subject.listingStatus(seller, listing, 1);
    }

    function test_listingStatus_returnsTrueIsCancelledWhenIsCancelled() public {
        _prank(seller);
        ScatterOfferer.ScatterSubmission memory listing = _generateListing();
        bytes32 listingHash = subject.hashSubmission(listing);

        ScatterOfferer.CancelListingItem[] memory hashes = _singleCancelItem(listingHash);

        subject.cancelListings(hashes);

        (, bool isCancelled,,) = subject.listingStatus(seller, listing, 0);

        assertEq(isCancelled, true);
    }

    function test_cancelListings_cancelsListing() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateListing();
        bytes32 listingHash = subject.hashSubmission(listing);

        ScatterOfferer.CancelListingItem[] memory hashes = _singleCancelItem(listingHash);

        _prank(seller);
        subject.cancelListings(hashes);

        assertEq(subject.cancelledListings(seller, listingHash, 0), true);
    }

    function test_cancelListings_cancelsMultipleListings() public {
        ScatterOfferer.ScatterSubmission memory listingA = _generateListing();
        ScatterOfferer.ScatterSubmission memory listingB = _generateListing();
        listingB.salt = bytes32(uint256(0xbeef));

        bytes32 hashA = subject.hashSubmission(listingA);
        bytes32 hashB = subject.hashSubmission(listingB);

        ScatterOfferer.CancelListingItem[] memory hashes = new ScatterOfferer.CancelListingItem[](2);
        hashes[0] = ScatterOfferer.CancelListingItem({submissionHash: hashA, itemIndex: 0});
        hashes[1] = ScatterOfferer.CancelListingItem({submissionHash: hashB, itemIndex: 0});

        _prank(seller);
        subject.cancelListings(hashes);

        assertEq(subject.cancelledListings(seller, hashA, 0), true);
        assertEq(subject.cancelledListings(seller, hashB, 0), true);
    }

    function test_cancelListings_cancelsOnlySelectedItemIndex() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateTwoItemListing();
        bytes32 listingHash = subject.hashSubmission(listing);

        ScatterOfferer.CancelListingItem[] memory hashes = new ScatterOfferer.CancelListingItem[](1);
        hashes[0] = ScatterOfferer.CancelListingItem({submissionHash: listingHash, itemIndex: 1});

        _prank(seller);
        subject.cancelListings(hashes);

        assertEq(subject.cancelledListings(seller, listingHash, 0), false);
        assertEq(subject.cancelledListings(seller, listingHash, 1), true);
    }

    function test_cancelListings_doesNotCancelListingForOtherAddress() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateListing();
        bytes32 listingHash = subject.hashSubmission(listing);

        ScatterOfferer.CancelListingItem[] memory hashes = _singleCancelItem(listingHash);

        _prank(other);
        subject.cancelListings(hashes);

        assertEq(subject.cancelledListings(seller, listingHash, 0), false);
    }

    function test_cancelListings_emitsListingCancelledEvent() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateListing();
        bytes32 listingHash = subject.hashSubmission(listing);

        ScatterOfferer.CancelListingItem[] memory hashes = _singleCancelItem(listingHash);

        _prank(seller);
        vm.expectEmit(true, true, false, false, address(subject));
        emit ScatterOfferer.ListingCancelled(listingHash, seller, 0);
        subject.cancelListings(hashes);
    }

    function test_cancelListings_emitsEventForEachHashInBatch() public {
        ScatterOfferer.ScatterSubmission memory listingA = _generateListing();
        ScatterOfferer.ScatterSubmission memory listingB = _generateListing();
        listingB.salt = bytes32(uint256(0xbeef));

        bytes32 hashA = subject.hashSubmission(listingA);
        bytes32 hashB = subject.hashSubmission(listingB);

        ScatterOfferer.CancelListingItem[] memory hashes = new ScatterOfferer.CancelListingItem[](2);
        hashes[0] = ScatterOfferer.CancelListingItem({submissionHash: hashA, itemIndex: 0});
        hashes[1] = ScatterOfferer.CancelListingItem({submissionHash: hashB, itemIndex: 0});

        _prank(seller);
        vm.expectEmit(true, true, false, false, address(subject));
        emit ScatterOfferer.ListingCancelled(hashA, seller, 0);
        vm.expectEmit(true, true, false, false, address(subject));
        emit ScatterOfferer.ListingCancelled(hashB, seller, 0);
        subject.cancelListings(hashes);
    }

    function test_incrementCounter_incrementsCounter() public {
        _prank(seller);
        subject.incrementCounter();

        assertEq(subject.counter(seller), 1);
    }

    function test_incrementCounter_doesNotAffectOtherAddresses() public {
        _prank(seller);
        subject.incrementCounter();

        assertEq(subject.counter(other), 0);
    }

    function test_incrementCounter_emitsCounterIncrementedEvent() public {
        _prank(seller);
        vm.expectEmit(true, true, false, false, address(subject));
        emit ScatterOfferer.CounterIncremented(seller, 1);
        subject.incrementCounter();
    }

    function test_generateOrder_failsWhenNotCalledBySeaport() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateListing();

        bytes memory signature = _signListing(listing, SELLER_PK);
        bytes memory context = _encodeContext(listing, signature, address(0), 1, 1, new bytes32[](0));

        _prank(other);
        vm.expectRevert(OnlySeaport.selector);
        subject.generateOrder(
            other, // requester
            new SpentItem[](0), // minimumReceived
            new SpentItem[](0), // maximumSpent
            context // seaportFillInputContextCalldata
        );
    }

    function test_generateOrder_incrementsFilledQuantityForListing() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateListing();

        bytes32 listingHash = subject.hashSubmission(listing);
        bytes memory signature = _signListing(listing, SELLER_PK);
        bytes memory context = _encodeContext(listing, signature, address(0), 1, 1, new bytes32[](0));

        assertEq(subject.filledListingQuantity(seller, listingHash, 0), 0);

        _prank(subject.SEAPORT());
        subject.generateOrder(
            buyer, // requester
            new SpentItem[](0), // minimumReceived
            new SpentItem[](0), // maximumSpent
            context // seaportFillInputContextCalldata
        );

        assertEq(subject.filledListingQuantity(seller, listingHash, 0), 1);
    }

    function test_generateOrder_incrementsFilledQuantityForEachFilledItemIndex() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateTwoItemListing();

        bytes32 listingHash = subject.hashSubmission(listing);
        bytes memory signature = _signListing(listing, SELLER_PK);
        ScatterOfferer.ScatterFill[] memory fills = _twoFills(0, 1, 1, 1, 2, 1);
        bytes memory context = _encodeContext(listing, signature, address(0), fills, new bytes32[][](0));

        _prank(subject.SEAPORT());
        subject.generateOrder(
            buyer, // requester
            new SpentItem[](0), // minimumReceived
            new SpentItem[](0), // maximumSpent
            context // seaportFillInputContextCalldata
        );

        assertEq(subject.filledListingQuantity(seller, listingHash, 0), 1);
        assertEq(subject.filledListingQuantity(seller, listingHash, 1), 1);
    }

    function test_generateOrder_failsWhenUnfilledItemsCollectionChangesAfterSigning() public {
        /*
         * Changing item 1's collection must stop item 0 from being sold with the old signature.
         * 1. Seller signs two items from different collections. Buyer wants only item 0.
         * 2. Change item 1's collection but keep the seller's original signature.
         * 3. Assert the changed submission reverts, item 0 stays with the seller, and its fill count is 0.
         * 4. Submit the original data. Assert item 0 transfers to the offerer and its fill count is 1.
         *    Assert item 1 stays with the seller and its fill count is 0.
         */
        // 1. Seller signs two items from different collections. Buyer wants only item 0.
        MockERC721 secondCollection = new MockERC721();
        secondCollection.mint(seller, 2);
        ScatterOfferer.ScatterSubmission memory listing = _generateTwoItemListing();
        listing.listings[1].collection = address(secondCollection);

        bytes32 listingHash = subject.hashSubmission(listing);
        bytes memory signature = _signListing(listing, SELLER_PK);
        ScatterOfferer.ScatterFill[] memory fills = _singleFill({itemIndex: 0, tokenId: 1, quantity: 1});
        bytes memory originalContext = _encodeContext(listing, signature, address(0), fills, new bytes32[][](0));

        // 2. Change item 1's collection but keep the seller's original signature.
        listing.listings[1].collection = address(nft721);
        bytes memory tamperedContext = _encodeContext(listing, signature, address(0), fills, new bytes32[][](0));

        // 3. Assert the changed submission reverts.
        _prank(subject.SEAPORT());
        vm.expectRevert();
        subject.generateOrder(
            buyer, // requester
            new SpentItem[](0), // minimumReceived
            new SpentItem[](0), // maximumSpent
            tamperedContext // seaportFillInputContextCalldata
        );

        // Assert item 0 stays with the seller and its fill count is 0.
        assertEq(nft721.ownerOf(1), seller);
        assertEq(subject.filledListingQuantity(seller, listingHash, 0), 0);

        // 4. Submit the original data.
        subject.generateOrder(
            buyer, // requester
            new SpentItem[](0), // minimumReceived
            new SpentItem[](0), // maximumSpent
            originalContext // seaportFillInputContextCalldata
        );

        // Assert item 0 transfers to the offerer and its fill count is 1.
        assertEq(nft721.ownerOf(1), address(subject));
        assertEq(subject.filledListingQuantity(seller, listingHash, 0), 1);
        // Assert item 1 stays with the seller and its fill count is 0.
        assertEq(secondCollection.ownerOf(2), seller);
        assertEq(subject.filledListingQuantity(seller, listingHash, 1), 0);
    }

    function test_generateOrder_failsWhenSignedCollectionsAreSwapped() public {
        /*
         * Swapping the items' collection addresses must make the old signature unusable.
         * 1. Seller signs token 1 from each of two collections and approves both for transfer.
         * 2. Swap the two collection addresses but keep the original signature.
         * 3. Assert the call reverts, both NFTs stay with the seller, and both fill counts stay 0.
         * 4. Submit the original data. Assert both NFTs transfer to the offerer and both fill counts become 1.
         */
        // 1. Seller signs token 1 from each of two collections and approves both for transfer.
        MockERC721 secondCollection = new MockERC721();
        secondCollection.mint(seller, 1);
        _prank(seller);
        secondCollection.setApprovalForAll(address(conduit), true);

        ScatterOfferer.ScatterSubmission memory listing = _generateTwoItemListing();
        listing.listings[1].collection = address(secondCollection);
        listing.listings[1].tokenId = 1;
        bytes32 listingHash = subject.hashSubmission(listing);
        bytes memory signature = _signListing(listing, SELLER_PK);
        ScatterOfferer.ScatterFill[] memory fills = _twoFills({
            firstItemIndex: 1,
            firstTokenId: 1,
            firstQuantity: 1,
            secondItemIndex: 0,
            secondTokenId: 1,
            secondQuantity: 1
        });
        bytes memory originalContext = _encodeContext(listing, signature, address(0), fills, new bytes32[][](0));

        // 2. Swap the two collection addresses but keep the original signature.
        listing.listings[0].collection = address(secondCollection);
        listing.listings[1].collection = address(nft721);
        bytes memory tamperedContext = _encodeContext(listing, signature, address(0), fills, new bytes32[][](0));

        // 3. Assert the call with swapped collections reverts.
        _prank(subject.SEAPORT());
        vm.expectRevert();
        subject.generateOrder(
            buyer, // requester
            new SpentItem[](0), // minimumReceived
            new SpentItem[](0), // maximumSpent
            tamperedContext // seaportFillInputContextCalldata
        );
        // Assert both NFTs stay with the seller and both fill counts stay 0.
        assertEq(nft721.ownerOf(1), seller);
        assertEq(secondCollection.ownerOf(1), seller);
        assertEq(subject.filledListingQuantity(seller, listingHash, 0), 0);
        assertEq(subject.filledListingQuantity(seller, listingHash, 1), 0);

        // 4. Submit the original data.
        subject.generateOrder(
            buyer, // requester
            new SpentItem[](0), // minimumReceived
            new SpentItem[](0), // maximumSpent
            originalContext // seaportFillInputContextCalldata
        );
        // Assert both NFTs transfer to the offerer and both fill counts become 1.
        assertEq(nft721.ownerOf(1), address(subject));
        assertEq(secondCollection.ownerOf(1), address(subject));
        assertEq(subject.filledListingQuantity(seller, listingHash, 0), 1);
        assertEq(subject.filledListingQuantity(seller, listingHash, 1), 1);
    }

    function test_generateOrder_incrementsFilledQuantityForBid() public {
        ScatterOfferer.ScatterSubmission memory bid = _generateBid();

        bytes32 listingHash = subject.hashSubmission(bid);
        bytes memory signature = _signListing(bid, BIDDER_PK);
        bytes memory context = _encodeContext(bid, signature, address(0), 1, 1, new bytes32[](0));

        assertEq(subject.filledListingQuantity(bidder, listingHash, 0), 0);

        _prank(subject.SEAPORT());
        subject.generateOrder(
            seller, // requester
            new SpentItem[](0), // minimumReceived
            new SpentItem[](0), // maximumSpent
            context // seaportFillInputContextCalldata
        );

        assertEq(subject.filledListingQuantity(bidder, listingHash, 0), 1);
    }

    function test_generateOrder_transfersNftFromSeller() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateListing();

        bytes memory signature = _signListing(listing, SELLER_PK);
        bytes memory context = _encodeContext(listing, signature, address(0), 1, 1, new bytes32[](0));

        assertEq(nft721.ownerOf(1), seller);

        _prank(subject.SEAPORT());
        subject.generateOrder(
            buyer, // requester
            new SpentItem[](0), // minimumReceived
            new SpentItem[](0), // maximumSpent
            context // seaportFillInputContextCalldata
        );

        assertEq(nft721.ownerOf(1), address(subject));
    }

    function test_generateOrder_pullsErc20FromBidderAndApprovesSeaport() public {
        ScatterOfferer.ScatterSubmission memory bid = _generateBid();
        bytes memory signature = _signListing(bid, BIDDER_PK);
        bytes memory context = _encodeContext(bid, signature, address(0), 1, 1, new bytes32[](0));

        // fee breakdown:
        //   listingPrice  = 1 ether
        //   totalFee      = 1 ether * 500 / 10000 = 0.05 ether
        //   platformFee   = 0.05 ether (no affiliate or rewards)
        //   sellerAmount  = 0.95 ether  ← amount approved to Seaport
        //   bidder        =  100 ether (minted in setUp) - 1 ether = 99 ether
        _prank(subject.SEAPORT());
        subject.generateOrder(
            seller, // requester
            new SpentItem[](0), // minimumReceived
            new SpentItem[](0), // maximumSpent
            context // seaportFillInputContextCalldata
        );

        assertEq(weth.balanceOf(bidder), 99 ether);
        assertEq(weth.allowance(address(subject), subject.SEAPORT()), 0.95 ether);
    }

    function test_generateOrder_affiliateWithoutFeeAuthorizationReverts() public {
        ScatterOfferer.ScatterSubmission memory bid = _generateBid();
        bytes memory signature = _signListing(bid, BIDDER_PK);
        bytes memory context = _encodeContext(bid, signature, affiliate, 1, 1, new bytes32[](0));

        _prank(subject.SEAPORT());
        vm.expectRevert(FeeAuthorizationExpired.selector);
        subject.generateOrder(seller, new SpentItem[](0), new SpentItem[](0), context);
    }

    function test_generateOrder_affiliateWithFeeAuthorizationSplitsFee() public {
        ScatterOfferer.ScatterSubmission memory bid = _generateBid();
        bytes memory signature = _signListing(bid, BIDDER_PK);
        uint256 deadline = block.timestamp + 1 hours;
        ScatterOfferer.ScatterFill[] memory fills = _singleFill(0, 1, 1);
        bytes memory feeAuthSig = _feeAuthSig(seller, affiliate, subject.hashSubmission(bid), fills, deadline);
        bytes memory context =
            _encodeContextWithAuth(bid, signature, affiliate, fills, new bytes32[][](0), deadline, feeAuthSig);

        _prank(subject.SEAPORT());
        subject.generateOrder(seller, new SpentItem[](0), new SpentItem[](0), context);

        assertEq(weth.balanceOf(subject.PLATFORM()), 0.025 ether);
        assertEq(weth.balanceOf(affiliate), 0.025 ether);
        assertEq(weth.balanceOf(rewardsRecipient), 0);
    }

    function test_generateOrder_acceptsMaximumFeeAuthorizationWindow() public {
        ScatterOfferer.ScatterSubmission memory bid = _generateBid();
        bytes memory signature = _signListing(bid, BIDDER_PK);
        uint256 deadline = block.timestamp + subject.MAX_AUTHORIZATION_WINDOW();
        ScatterOfferer.ScatterFill[] memory fills = _singleFill(0, 1, 1);
        bytes memory feeAuthSig = _feeAuthSig(seller, affiliate, subject.hashSubmission(bid), fills, deadline);
        bytes memory context =
            _encodeContextWithAuth(bid, signature, affiliate, fills, new bytes32[][](0), deadline, feeAuthSig);

        _prank(subject.SEAPORT());
        subject.generateOrder(seller, new SpentItem[](0), new SpentItem[](0), context);

        assertEq(weth.balanceOf(affiliate), 0.025 ether);
    }

    function test_generateOrder_rejectsFeeAuthorizationBeyondMaximumWindow() public {
        ScatterOfferer.ScatterSubmission memory bid = _generateBid();
        bytes memory signature = _signListing(bid, BIDDER_PK);
        uint256 deadline = block.timestamp + subject.MAX_AUTHORIZATION_WINDOW() + 1;
        ScatterOfferer.ScatterFill[] memory fills = _singleFill(0, 1, 1);
        bytes memory feeAuthSig = _feeAuthSig(seller, affiliate, subject.hashSubmission(bid), fills, deadline);
        bytes memory context =
            _encodeContextWithAuth(bid, signature, affiliate, fills, new bytes32[][](0), deadline, feeAuthSig);

        _prank(subject.SEAPORT());
        vm.expectRevert(InvalidFeeAuthorization.selector);
        subject.generateOrder(seller, new SpentItem[](0), new SpentItem[](0), context);
    }

    function test_generateOrder_feeAuthorizationCannotBeUsedForDifferentFill() public {
        ScatterOfferer.ScatterSubmission memory bid = _generateTwoItemBid();
        bytes memory signature = _signListing(bid, BIDDER_PK);
        uint256 deadline = block.timestamp + 1 hours;
        ScatterOfferer.ScatterFill[] memory authorizedFills = _singleFill(0, 1, 1);
        bytes memory feeAuthSig = _feeAuthSig(seller, affiliate, subject.hashSubmission(bid), authorizedFills, deadline);
        ScatterOfferer.ScatterFill[] memory differentFills = _singleFill(1, 2, 1);
        bytes memory context =
            _encodeContextWithAuth(bid, signature, affiliate, differentFills, new bytes32[][](0), deadline, feeAuthSig);

        _prank(subject.SEAPORT());
        vm.expectRevert(InvalidFeeAuthorization.selector);
        subject.generateOrder(seller, new SpentItem[](0), new SpentItem[](0), context);

        assertEq(subject.filledListingQuantity(bidder, subject.hashSubmission(bid), 1), 0);
        assertEq(weth.balanceOf(affiliate), 0);
    }

    function test_setFeeAuthorizer_rotatesAndOldSignaturesStopWorking() public {
        ScatterOfferer.ScatterSubmission memory bid = _generateBid();
        bytes memory signature = _signListing(bid, BIDDER_PK);
        uint256 deadline = block.timestamp + 1 hours;
        address newAuthorizer = vm.addr(0xB0B);

        _prank(owner);
        vm.expectEmit(true, true, true, true);
        emit ScatterOfferer.FeeAuthorizerUpdated(feeAuthorizer, newAuthorizer);
        subject.setFeeAuthorizer(newAuthorizer);

        ScatterOfferer.ScatterFill[] memory fills = _singleFill(0, 1, 1);
        bytes memory staleSig = _feeAuthSig(seller, affiliate, subject.hashSubmission(bid), fills, deadline);
        bytes memory staleContext =
            _encodeContextWithAuth(bid, signature, affiliate, fills, new bytes32[][](0), deadline, staleSig);
        _prank(subject.SEAPORT());
        vm.expectRevert(InvalidFeeAuthorization.selector);
        subject.generateOrder(seller, new SpentItem[](0), new SpentItem[](0), staleContext);

        bytes memory freshSig = _feeAuthSigFor(seller, affiliate, subject.hashSubmission(bid), fills, deadline, 0xB0B);
        bytes memory freshContext =
            _encodeContextWithAuth(bid, signature, affiliate, fills, new bytes32[][](0), deadline, freshSig);
        _prank(subject.SEAPORT());
        subject.generateOrder(seller, new SpentItem[](0), new SpentItem[](0), freshContext);
        assertEq(weth.balanceOf(affiliate), 0.025 ether);
    }

    function test_setFeeBps_updatesFeeCharged() public {
        _prank(owner);
        vm.expectEmit(true, true, true, true);
        emit ScatterOfferer.FeeBpsUpdated(500, 1000);
        subject.setFeeBps(1000);

        ScatterOfferer.ScatterSubmission memory listing = _generateListing();
        listing.maxFeeBps = 1000;
        bytes memory signature = _signListing(listing, SELLER_PK);
        bytes memory context = _encodeContext(listing, signature, address(0), 1, 1, new bytes32[](0));
        (, ReceivedItem[] memory consideration) =
            subject.previewOrder(address(0), buyer, new SpentItem[](0), new SpentItem[](0), context);

        assertEq(subject.feeBps(), 1000);
        assertEq(consideration.length, 2);
        assertEq(consideration[0].recipient, seller);
        assertEq(consideration[0].amount, 0.9 ether);
        assertEq(consideration[1].recipient, subject.PLATFORM());
        assertEq(consideration[1].amount, 0.1 ether);
    }

    function test_generateOrder_revertsWhenFeeExceedsSignedLimit() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateListing();
        bytes memory signature = _signListing(listing, SELLER_PK);
        bytes memory context = _encodeContext(listing, signature, address(0), 1, 1, new bytes32[](0));

        _prank(owner);
        subject.setFeeBps(501);

        _prank(subject.SEAPORT());
        vm.expectRevert(abi.encodeWithSelector(FeeBpsExceedsLimit.selector, 501, 500));
        subject.generateOrder(seller, new SpentItem[](0), new SpentItem[](0), context);
    }

    function test_setFeeBps_revertsForNonOwner() public {
        _prank(other);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        subject.setFeeBps(1000);
    }

    function test_setFeeBps_revertsAboveMaximum() public {
        _prank(owner);
        vm.expectRevert(InvalidFeeBps.selector);
        subject.setFeeBps(5001);
    }

    function test_setFeeBps_acceptsMaximum() public {
        _prank(owner);
        subject.setFeeBps(5000);
        assertEq(subject.feeBps(), 5000);
    }

    function test_generateOrder_distributesErc20FeesForBid() public {
        ScatterOfferer.ScatterSubmission memory bid = _generateBid();

        bytes memory signature = _signListing(bid, BIDDER_PK);
        bytes memory context = _encodeContext(bid, signature, address(0), 1, 1, new bytes32[](0));

        // fee breakdown:
        //   listingPrice  = 1 ether
        //   totalFee      = 1 ether * 500 / 10000 = 0.05 ether
        //   platformFee   = 0.05 ether (no affiliate or rewards)
        //   sellerAmount  = 0.95 ether
        //   PLATFORM starts with 0 WETH
        _prank(subject.SEAPORT());
        subject.generateOrder(
            seller, // requester
            new SpentItem[](0), // minimumReceived
            new SpentItem[](0), // maximumSpent
            context // seaportFillInputContextCalldata
        );

        assertEq(weth.balanceOf(subject.PLATFORM()), 0.05 ether);
    }

    function test_generateOrder_emitsScatterSaleEventForListing() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateListing();

        bytes32 listingHash = subject.hashSubmission(listing);
        bytes memory signature = _signListing(listing, SELLER_PK);
        bytes memory context = _encodeContext(listing, signature, address(0), 1, 1, new bytes32[](0));

        // fee breakdown:
        //   listingPrice  = 1 ether
        //   totalFee      = 1 ether * 500 / 10000 = 0.05 ether
        //   platformFee   = 0.05 ether
        //   sellerAmount  = 0.95 ether
        _prank(subject.SEAPORT());
        vm.expectEmit(true, true, true, true, address(subject));
        emit ScatterOfferer.ScatterSale(
            listingHash, // listingHash
            uint8(ScatterOfferer.Role.Listing), // role
            seller, // seller
            buyer, // buyer
            address(nft721), // collection
            0, // itemIndex
            1, // tokenId
            1, // quantity
            address(0), // currency (native)
            1 ether, // totalPrice
            address(0), // affiliate
            address(0), // rewardsRecipient
            0.95 ether, // sellerAmount
            0.05 ether, // platformAmount
            0, // rewardsAmount
            0 // affiliateAmount
        );
        subject.generateOrder(
            buyer, // requester
            new SpentItem[](0), // minimumReceived
            new SpentItem[](0), // maximumSpent
            context // seaportFillInputContextCalldata
        );
    }

    function test_generateOrder_emitsScatterSaleEventForBid() public {
        ScatterOfferer.ScatterSubmission memory bid = _generateBid();

        bytes32 listingHash = subject.hashSubmission(bid);
        bytes memory signature = _signListing(bid, BIDDER_PK);
        bytes memory context = _encodeContext(bid, signature, address(0), 1, 1, new bytes32[](0));

        // fee breakdown:
        //   listingPrice  = 1 ether
        //   totalFee      = 1 ether * 500 / 10000 = 0.05 ether
        //   platformFee   = 0.05 ether
        //   sellerAmount  = 0.95 ether
        _prank(subject.SEAPORT());
        vm.expectEmit(true, true, true, true, address(subject));
        emit ScatterOfferer.ScatterSale(
            listingHash, // listingHash
            uint8(ScatterOfferer.Role.Bid), // role
            seller, // seller (requester — fulfiller of a bid)
            bidder, // buyer  (signer of the bid)
            address(nft721), // collection
            0, // itemIndex
            1, // tokenId
            1, // quantity
            address(weth), // currency
            1 ether, // totalPrice
            address(0), // affiliate
            address(0), // rewardsRecipient
            0.95 ether, // sellerAmount
            0.05 ether, // platformAmount
            0, // rewardsAmount
            0 // affiliateAmount
        );
        subject.generateOrder(
            seller, // requester
            new SpentItem[](0), // minimumReceived
            new SpentItem[](0), // maximumSpent
            context // seaportFillInputContextCalldata
        );
    }

    function test_ratifyOrder_returnsMagicValue() public {
        _prank(subject.SEAPORT());
        bytes4 result = subject.ratifyOrder(new SpentItem[](0), new ReceivedItem[](0), "", new bytes32[](0), 0);
        assertTrue(result == ContractOffererInterface.ratifyOrder.selector);
    }

    function test_ratifyOrder_failsWhenCalledByNonSeaport() public {
        vm.expectRevert(OnlySeaport.selector);
        subject.ratifyOrder(new SpentItem[](0), new ReceivedItem[](0), "", new bytes32[](0), 0);
    }

    function test_previewOrder_returnsScalerOfferAndConsiderationForListing() public view {
        ScatterOfferer.ScatterSubmission memory listing = _generateListing();
        bytes memory signature = _signListing(listing, SELLER_PK);
        bytes memory context = _encodeContext(listing, signature, address(0), 1, 1, new bytes32[](0));

        (SpentItem[] memory offer, ReceivedItem[] memory consideration) = subject.previewOrder(
            address(0), // caller
            buyer, // fulfiller
            new SpentItem[](0), // minimumReceived
            new SpentItem[](0), // maximumSpent
            context // seaportFillInputContextCalldata
        );

        // offer and consideration is tested by other tests we just need to check if they are returned
        assertEq(offer.length, 1);
        assertEq(uint8(offer[0].itemType), uint8(ItemType.ERC721));
        assertEq(consideration[0].recipient, seller);
    }

    function test_previewOrder_returnsScalerOfferAndConsiderationForBid() public view {
        ScatterOfferer.ScatterSubmission memory bid = _generateBid();
        bytes memory signature = _signListing(bid, BIDDER_PK);
        bytes memory context = _encodeContext(bid, signature, address(0), 1, 1, new bytes32[](0));

        (SpentItem[] memory offer, ReceivedItem[] memory consideration) = subject.previewOrder(
            address(0), // caller
            buyer, // fulfiller
            new SpentItem[](0), // minimumReceived
            new SpentItem[](0), // maximumSpent
            context // seaportFillInputContextCalldata
        );

        // offer and consideration is tested by other tests we just need to check if they are returned
        assertEq(offer.length, 1);
        assertEq(uint8(offer[0].itemType), uint8(ItemType.ERC20));
        assertEq(consideration[0].recipient, bidder);
    }

    function test_previewOrder_returnsMultipleOfferItemsForListing() public view {
        ScatterOfferer.ScatterSubmission memory listing = _generateTwoItemListing();
        bytes memory signature = _signListing(listing, SELLER_PK);
        ScatterOfferer.ScatterFill[] memory fills = _twoFills(0, 1, 1, 1, 2, 1);
        bytes memory context = _encodeContext(listing, signature, address(0), fills, new bytes32[][](0));

        (SpentItem[] memory offer, ReceivedItem[] memory consideration) = subject.previewOrder(
            address(0), // caller
            buyer, // fulfiller
            new SpentItem[](0), // minimumReceived
            new SpentItem[](0), // maximumSpent
            context // seaportFillInputContextCalldata
        );

        assertEq(offer.length, 2);
        assertEq(offer[0].identifier, 1);
        assertEq(offer[1].identifier, 2);
        // fee breakdown:
        //   listingPrice = 1 ether + 2 ether = 3 ether
        //   totalFee     = 3 ether * 500 / 10000 = 0.15 ether
        //   sellerAmount = 3 ether - 0.15 ether = 2.85 ether
        assertEq(consideration[0].amount, 2.85 ether);
    }

    function test_previewOrder_returnsMultipleConsiderationItemsForBid() public view {
        ScatterOfferer.ScatterSubmission memory bid = _generateTwoItemBid();
        bytes memory signature = _signListing(bid, BIDDER_PK);
        ScatterOfferer.ScatterFill[] memory fills = _twoFills(0, 1, 1, 1, 2, 1);
        bytes memory context = _encodeContext(bid, signature, address(0), fills, new bytes32[][](0));

        (SpentItem[] memory offer, ReceivedItem[] memory consideration) = subject.previewOrder(
            address(0), // caller
            buyer, // fulfiller
            new SpentItem[](0), // minimumReceived
            new SpentItem[](0), // maximumSpent
            context // seaportFillInputContextCalldata
        );

        assertEq(offer.length, 1);
        // fee breakdown:
        //   listingPrice = 1 ether + 2 ether = 3 ether
        //   totalFee     = 3 ether * 500 / 10000 = 0.15 ether
        //   sellerAmount = 3 ether - 0.15 ether = 2.85 ether
        assertEq(offer[0].amount, 2.85 ether);
        assertEq(consideration.length, 2);
        assertEq(consideration[0].identifier, 1);
        assertEq(consideration[1].identifier, 2);
    }

    function test_getSeaportMetadata_returnsNameAndEmptySchemas() public view {
        (string memory name, Schema[] memory schemas) = subject.getSeaportMetadata();

        assertEq(name, "Scatter Marketplace");
        assertEq(schemas.length, 0);
    }

    function test_supportsInterface_returnsTrueForContractOffererInterface() public view {
        assertTrue(subject.supportsInterface(type(ContractOffererInterface).interfaceId));
    }

    function test_supportsInterface_returnsTrueForTokenReceivers() public view {
        // tokens that ERC165-check receivers before transferring in
        assertTrue(subject.supportsInterface(0x150b7a02)); // ERC721TokenReceiver
        assertTrue(subject.supportsInterface(0x4e2312e0)); // ERC1155TokenReceiver
    }

    function test_supportsInterface_returnsTrueForErc165() public view {
        assertTrue(subject.supportsInterface(0x01ffc9a7));
    }

    function test_supportsInterface_returnsFalseForUnknownInterface() public view {
        assertFalse(subject.supportsInterface(0xdeadbeef));
    }

    function test_setTrustedRouter_setsRouterToTrusted() public {
        _prank(owner);

        subject.setTrustedRouter(router, true);

        assertTrue(subject.trustedRouters(router));
    }

    function test_setTrustedRouter_setsRouterToUntrusted() public {
        _prank(owner);
        subject.setTrustedRouter(router, true);

        subject.setTrustedRouter(router, false);

        assertFalse(subject.trustedRouters(router));
    }

    function test_setTrustedRouter_emitsTrustedRouterUpdatedEvent() public {
        _prank(owner);

        vm.expectEmit(true, true, true, true, address(subject));
        emit ScatterOfferer.TrustedRouterUpdated(router, true);
        subject.setTrustedRouter(router, true);
    }

    function test_setTrustedRouter_failsWhenRouterIsAddressZero() public {
        _prank(owner);

        vm.expectRevert(InvalidRouter.selector);
        subject.setTrustedRouter(address(0), true);
    }

    function test_setTrustedRouter_failsWhenCalledByNonOwner() public {
        address nonOwner = makeAddr("nonOwner");
        _prank(nonOwner);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        subject.setTrustedRouter(router, true);
    }

    function test_onERC721Received_returnsSelectorMagicValue() public view {
        bytes4 result = subject.onERC721Received(address(0), address(0), 0, "");
        assertEq(result, subject.onERC721Received.selector);
    }

    function test_onERC1155Received_returnsSelectorMagicValue() public view {
        bytes4 result = subject.onERC1155Received(address(0), address(0), 0, 0, "");
        assertEq(result, subject.onERC1155Received.selector);
    }

    function test_onERC1155BatchReceived_returnsSelectorMagicValue() public view {
        uint256[] memory ids = new uint256[](0);
        uint256[] memory values = new uint256[](0);
        bytes4 result = subject.onERC1155BatchReceived(address(0), address(0), ids, values, "");
        assertEq(result, subject.onERC1155BatchReceived.selector);
    }

    function test_constants_seaportAddress() public view {
        assertEq(subject.SEAPORT(), 0x0000000000000068F116a894984e2DB1123eB395);
    }

    function test_constants_platformAddress() public view {
        assertEq(subject.PLATFORM(), 0x8952caF7E5bf1fe63ebe94148ca802F3eF127C98);
    }

    function test_hashSubmission_changesWhenAnyFieldChanges() public view {
        ScatterOfferer.ScatterSubmission memory tempListing;
        ScatterOfferer.ScatterSubmission memory baseListing = _generateListing();
        bytes32 baseHash = subject.hashSubmission(baseListing);

        tempListing = _generateListing();
        tempListing.role = ScatterOfferer.Role.Bid;
        assertTrue(subject.hashSubmission(tempListing) != baseHash);

        tempListing = _generateListing();
        tempListing.listings[0].assetType = ScatterOfferer.AssetType.ERC1155;
        assertTrue(subject.hashSubmission(tempListing) != baseHash);

        tempListing = _generateListing();
        tempListing.listings[0].collection = address(weth);
        assertTrue(subject.hashSubmission(tempListing) != baseHash);

        tempListing = _generateListing();
        tempListing.listings[0].tokenId = 99;
        assertTrue(subject.hashSubmission(tempListing) != baseHash);

        tempListing = _generateListing();
        tempListing.criteriaRoot = keccak256("root");
        assertTrue(subject.hashSubmission(tempListing) != baseHash);

        tempListing = _generateListing();
        tempListing.maxFeeBps++;
        assertTrue(subject.hashSubmission(tempListing) != baseHash);

        tempListing = _generateListing();
        tempListing.listings[0].quantity = 5;
        assertTrue(subject.hashSubmission(tempListing) != baseHash);

        tempListing = _generateListing();
        tempListing.listings[0].currency = address(weth);
        assertTrue(subject.hashSubmission(tempListing) != baseHash);

        tempListing = _generateListing();
        tempListing.listings[0].priceWei = 2 ether;
        assertTrue(subject.hashSubmission(tempListing) != baseHash);

        tempListing = _generateListing();
        tempListing.startTime = block.timestamp + 1;
        assertTrue(subject.hashSubmission(tempListing) != baseHash);

        tempListing = _generateListing();
        tempListing.endTime = block.timestamp + 2 hours;
        assertTrue(subject.hashSubmission(tempListing) != baseHash);

        tempListing = _generateListing();
        tempListing.nonce = 7;
        assertTrue(subject.hashSubmission(tempListing) != baseHash);

        tempListing = _generateListing();
        tempListing.salt = keccak256("salt");
        assertTrue(subject.hashSubmission(tempListing) != baseHash);
    }

    function test_internal_computeFillData_returnsFillDataForNative() public view {
        ScatterOfferer.ScatterSubmission memory listing = _generateListing();
        bytes memory signature = _signListing(listing, SELLER_PK);
        ScatterOfferer.SeaportFillInput memory input = _generateFillInput(
            GenerateFillInputParams({listing: listing, signature: signature, fillTokenId: 1, fillQuantity: 1})
        );

        ScatterOfferer.ValidatedFillData memory fillData = subject.internal__computeFillData(input);

        assertEq(fillData.submissionHash, subject.hashSubmission(listing));
        assertEq(fillData.signer, seller);
        assertEq(fillData.totalFillPrice, 1 ether);
    }

    function test_internal_computeFillData_returnsFillDataForERC1155() public view {
        ScatterOfferer.ScatterSubmission memory listing = _generateListing(
            GenerateListingParams({
                assetType: ScatterOfferer.AssetType.ERC1155,
                collection: address(nft1155),
                tokenId: 1,
                quantity: 5,
                currency: address(0),
                priceWei: 0.1 ether,
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours
            })
        );
        bytes memory signature = _signListing(listing, SELLER_PK);
        ScatterOfferer.SeaportFillInput memory input = _generateFillInput(
            GenerateFillInputParams({listing: listing, signature: signature, fillTokenId: 1, fillQuantity: 3})
        );

        ScatterOfferer.ValidatedFillData memory fillData = subject.internal__computeFillData(input);

        // price breakdown:
        //   totalFillPrice = priceWei * fillQuantity = 0.1 ether * 3 = 0.3 ether
        assertEq(fillData.submissionHash, subject.hashSubmission(listing));
        assertEq(fillData.signer, seller);
        assertEq(fillData.totalFillPrice, 0.3 ether);
    }

    function test_internal_computeFillData_returnsAggregatedFillDataForMultipleListingItems() public view {
        ScatterOfferer.ScatterSubmission memory listing = _generateTwoItemListing();
        bytes memory signature = _signListing(listing, SELLER_PK);
        ScatterOfferer.SeaportFillInput memory input =
            _generateFillInput(listing, signature, _twoFills(0, 1, 1, 1, 2, 1), new bytes32[][](0));

        ScatterOfferer.ValidatedFillData memory fillData = subject.internal__computeFillData(input);

        assertEq(fillData.submissionHash, subject.hashSubmission(listing));
        assertEq(fillData.signer, seller);
        // price breakdown:
        //   totalFillPrice = 1 ether + 2 ether = 3 ether
        assertEq(fillData.totalFillPrice, 3 ether);
    }

    function test_internal_computeFillData_returnsFillDataForBidWithCriteriaProof() public view {
        ScatterOfferer.ScatterSubmission memory bid = _generateBid();

        uint256 fillTokenId = 2;
        bid.criteriaRoot = keccak256(abi.encode(fillTokenId));

        bytes memory signature = _signListing(bid, BIDDER_PK);
        ScatterOfferer.SeaportFillInput memory input = _generateFillInput(
            GenerateFillInputParams({listing: bid, signature: signature, fillTokenId: fillTokenId, fillQuantity: 1})
        );
        input.criteriaProofs = new bytes32[][](1);
        input.criteriaProofs[0] = new bytes32[](0);

        ScatterOfferer.ValidatedFillData memory fillData = subject.internal__computeFillData(input);

        assertEq(fillData.submissionHash, subject.hashSubmission(bid));
        assertEq(fillData.signer, bidder);
        assertEq(fillData.totalFillPrice, 1 ether);
    }

    function test_internal_computeFillData_allowsErc721BidQuantityAboveOne() public view {
        ScatterOfferer.ScatterSubmission memory bid = _generateBid();
        bid.listings[0].quantity = 5;

        bytes memory signature = _signListing(bid, BIDDER_PK);
        ScatterOfferer.SeaportFillInput memory input = _generateFillInput(
            GenerateFillInputParams({listing: bid, signature: signature, fillTokenId: 2, fillQuantity: 1})
        );

        ScatterOfferer.ValidatedFillData memory fillData = subject.internal__computeFillData(input);

        assertEq(fillData.submissionHash, subject.hashSubmission(bid));
        assertEq(fillData.signer, bidder);
        assertEq(fillData.totalFillPrice, 1 ether);
    }

    function test_internal_computeFillData_allowsDuplicateZeroTokenIdsForCollectionBid() public view {
        ScatterOfferer.ScatterSubmission memory bid = _generateTwoItemBid();
        bytes memory signature = _signListing(bid, BIDDER_PK);
        ScatterOfferer.SeaportFillInput memory input =
            _generateFillInput(bid, signature, _twoFills(0, 1, 1, 1, 2, 1), new bytes32[][](0));

        ScatterOfferer.ValidatedFillData memory fillData = subject.internal__computeFillData(input);

        assertEq(fillData.submissionHash, subject.hashSubmission(bid));
        assertEq(fillData.signer, bidder);
        // price breakdown:
        //   totalFillPrice = 1 ether + 2 ether = 3 ether
        assertEq(fillData.totalFillPrice, 3 ether);
    }

    function test_internal_computeFillData_allowsSelectedItemWhenSiblingIsCancelled() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateTwoItemListing();
        bytes32 listingHash = subject.hashSubmission(listing);
        ScatterOfferer.CancelListingItem[] memory hashes = new ScatterOfferer.CancelListingItem[](1);
        hashes[0] = ScatterOfferer.CancelListingItem({submissionHash: listingHash, itemIndex: 0});

        _prank(seller);
        subject.cancelListings(hashes);

        bytes memory signature = _signListing(listing, SELLER_PK);
        ScatterOfferer.SeaportFillInput memory input =
            _generateFillInput(listing, signature, _singleFill(1, 2, 1), new bytes32[][](0));

        ScatterOfferer.ValidatedFillData memory fillData = subject.internal__computeFillData(input);

        assertEq(fillData.submissionHash, listingHash);
        assertEq(fillData.signer, seller);
        // price breakdown:
        //   totalFillPrice = selected item price = 2 ether
        assertEq(fillData.totalFillPrice, 2 ether);
    }

    function test_internal_computeFillData_allowsSelectedItemWhenSiblingIsFilled() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateTwoItemListing();
        subject._cheat_alterFilledQuantity(seller, listing, 0, 1);

        bytes memory signature = _signListing(listing, SELLER_PK);
        ScatterOfferer.SeaportFillInput memory input =
            _generateFillInput(listing, signature, _singleFill(1, 2, 1), new bytes32[][](0));

        ScatterOfferer.ValidatedFillData memory fillData = subject.internal__computeFillData(input);

        assertEq(fillData.submissionHash, subject.hashSubmission(listing));
        assertEq(fillData.signer, seller);
        // price breakdown:
        //   totalFillPrice = selected item price = 2 ether
        assertEq(fillData.totalFillPrice, 2 ether);
    }

    function test_internal_computeFillData_failsWhenBidUsesNativeCurrency() public {
        ScatterOfferer.ScatterSubmission memory bid = _generateBid();
        bid.listings[0].currency = address(0); // native currency
        bytes memory signature = _signListing(bid, BIDDER_PK);
        ScatterOfferer.SeaportFillInput memory input = _generateFillInput(
            GenerateFillInputParams({listing: bid, signature: signature, fillTokenId: 1, fillQuantity: 1})
        );

        vm.expectRevert(CurrencyMismatch.selector);
        subject.internal__computeFillData(input);
    }

    function test_internal_computeFillData_failsWhenListingsAreEmpty() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateListing();
        listing.listings = new ScatterOfferer.ScatterListing[](0);

        ScatterOfferer.SeaportFillInput memory input;
        input.submission = listing;
        input.fills = _singleFill(0, 1, 1);

        vm.expectRevert(EmptySpec.selector);
        subject.internal__computeFillData(input);
    }

    function test_internal_computeFillData_failsWhenFillsAreEmpty() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateListing();

        ScatterOfferer.SeaportFillInput memory input;
        input.submission = listing;
        input.fills = new ScatterOfferer.ScatterFill[](0);

        vm.expectRevert(EmptySpec.selector);
        subject.internal__computeFillData(input);
    }

    function test_internal_computeFillData_failsWhenFirstFillItemIndexInvalid() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateListing();
        bytes memory signature = _signListing(listing, SELLER_PK);
        ScatterOfferer.SeaportFillInput memory input =
            _generateFillInput(listing, signature, _singleFill(1, 1, 1), new bytes32[][](0));

        vm.expectRevert(InvalidFill.selector);
        subject.internal__computeFillData(input);
    }

    function test_internal_computeFillData_failsWhenLaterFillItemIndexInvalid() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateTwoItemListing();
        bytes memory signature = _signListing(listing, SELLER_PK);
        ScatterOfferer.SeaportFillInput memory input =
            _generateFillInput(listing, signature, _twoFills(0, 1, 1, 2, 2, 1), new bytes32[][](0));

        vm.expectRevert(InvalidFill.selector);
        subject.internal__computeFillData(input);
    }

    function test_internal_computeFillData_failsWhenConcreteTokenIdsAreDuplicated() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateTwoItemListing();
        listing.listings[1].tokenId = listing.listings[0].tokenId;
        bytes memory signature = _signListing(listing, SELLER_PK);
        ScatterOfferer.SeaportFillInput memory input =
            _generateFillInput(listing, signature, _singleFill(0, 1, 1), new bytes32[][](0));

        vm.expectRevert(DuplicateListingItem.selector);
        subject.internal__computeFillData(input);
    }

    function test_internal_computeFillData_failsWhenFillItemIndexesAreDuplicated() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateTwoItemListing();
        bytes memory signature = _signListing(listing, SELLER_PK);
        ScatterOfferer.SeaportFillInput memory input =
            _generateFillInput(listing, signature, _twoFills(0, 1, 1, 0, 1, 1), new bytes32[][](0));

        vm.expectRevert(DuplicateListingItem.selector);
        subject.internal__computeFillData(input);
    }

    function test_internal_computeFillData_failsWhenSelectedItemsUseMixedCurrencies() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateTwoItemListing();
        listing.listings[1].currency = address(weth);
        bytes memory signature = _signListing(listing, SELLER_PK);
        ScatterOfferer.SeaportFillInput memory input =
            _generateFillInput(listing, signature, _twoFills(0, 1, 1, 1, 2, 1), new bytes32[][](0));

        vm.expectRevert(CurrencyMismatch.selector);
        subject.internal__computeFillData(input);
    }

    function test_internal_computeFillData_failsWhenListingFillTokenIdDiffersFromListingTokenId() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateListing();
        bytes memory signature = _signListing(listing, SELLER_PK);
        ScatterOfferer.SeaportFillInput memory input = _generateFillInput(
            GenerateFillInputParams({
                listing: listing,
                signature: signature,
                fillTokenId: 2, // listing.tokenId == 1, fillTokenId == 2
                fillQuantity: 1
            })
        );

        vm.expectRevert(TokenIdNotZeroForCriteria.selector);
        subject.internal__computeFillData(input);
    }

    function test_internal_computeFillData_failsWhenTimestampBeforeStart() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateListing(
            GenerateListingParams({
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 1,
                quantity: 1,
                currency: address(0),
                priceWei: 1 ether,
                startTime: block.timestamp + 1 hours, // not yet started
                endTime: block.timestamp + 2 hours
            })
        );
        bytes memory signature = _signListing(listing, SELLER_PK);
        ScatterOfferer.SeaportFillInput memory input = _generateFillInput(
            GenerateFillInputParams({listing: listing, signature: signature, fillTokenId: 1, fillQuantity: 1})
        );

        vm.expectRevert(OrderExpired.selector);
        subject.internal__computeFillData(input);
    }

    function test_internal_computeFillData_failsWhenTimestampAtOrAfterEnd() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateListing(
            GenerateListingParams({
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 1,
                quantity: 1,
                currency: address(0),
                priceWei: 1 ether,
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours // will be finished because of vm.warp(3 hours);
            })
        );
        bytes memory signature = _signListing(listing, SELLER_PK);
        ScatterOfferer.SeaportFillInput memory input = _generateFillInput(
            GenerateFillInputParams({listing: listing, signature: signature, fillTokenId: 1, fillQuantity: 1})
        );

        vm.warp(3 hours);

        vm.expectRevert(OrderExpired.selector);
        subject.internal__computeFillData(input);
    }

    function test_internal_computeFillData_failsWhenNonceMismatch() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateListing();
        _prank(seller);
        subject.incrementCounter(); // listing.nonce == 0 but seller's counter is now 1

        bytes memory signature = _signListing(listing, SELLER_PK);
        ScatterOfferer.SeaportFillInput memory input = _generateFillInput(
            GenerateFillInputParams({listing: listing, signature: signature, fillTokenId: 1, fillQuantity: 1})
        );

        vm.expectRevert(NonceMismatch.selector);
        subject.internal__computeFillData(input);
    }

    function test_internal_computeFillData_failsWhenOrderCancelled() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateListing();
        bytes32 listingHash = subject.hashSubmission(listing);

        ScatterOfferer.CancelListingItem[] memory hashes = _singleCancelItem(listingHash);
        _prank(seller);
        subject.cancelListings(hashes);

        bytes memory signature = _signListing(listing, SELLER_PK);
        ScatterOfferer.SeaportFillInput memory input = _generateFillInput(
            GenerateFillInputParams({listing: listing, signature: signature, fillTokenId: 1, fillQuantity: 1})
        );

        vm.expectRevert(OrderCancelled.selector);
        subject.internal__computeFillData(input);
    }

    function test_internal_computeFillData_failsWhenSelectedItemIndexCancelled() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateTwoItemListing();
        bytes32 listingHash = subject.hashSubmission(listing);
        ScatterOfferer.CancelListingItem[] memory hashes = new ScatterOfferer.CancelListingItem[](1);
        hashes[0] = ScatterOfferer.CancelListingItem({submissionHash: listingHash, itemIndex: 1});

        _prank(seller);
        subject.cancelListings(hashes);

        bytes memory signature = _signListing(listing, SELLER_PK);
        ScatterOfferer.SeaportFillInput memory input =
            _generateFillInput(listing, signature, _singleFill(1, 2, 1), new bytes32[][](0));

        vm.expectRevert(OrderCancelled.selector);
        subject.internal__computeFillData(input);
    }

    function test_internal_computeFillData_failsWhenFillQuantityIsZero() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateListing();
        bytes memory signature = _signListing(listing, SELLER_PK);
        ScatterOfferer.SeaportFillInput memory input = _generateFillInput(
            GenerateFillInputParams({
                listing: listing,
                signature: signature,
                fillTokenId: 1,
                fillQuantity: 0 // fillQuantity = 0
            })
        );

        vm.expectRevert(EmptySpec.selector);
        subject.internal__computeFillData(input);
    }

    function test_internal_computeFillData_failsWhenFillExceedsRemainingQuantity() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateListing(
            GenerateListingParams({
                assetType: ScatterOfferer.AssetType.ERC1155,
                collection: address(nft1155),
                tokenId: 1,
                quantity: 3,
                currency: address(0),
                priceWei: 1 ether,
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours
            })
        );
        // pre-fill 2 units so only 1 remains
        subject._cheat_alterFilledQuantity(seller, listing, 2);

        bytes memory signature = _signListing(listing, SELLER_PK);
        ScatterOfferer.SeaportFillInput memory input = _generateFillInput(
            GenerateFillInputParams({
                listing: listing,
                signature: signature,
                fillTokenId: 1,
                fillQuantity: 2 // pre-fill 2 units so only 1 remains, we cant fill another 2
            })
        );

        vm.expectRevert(QuantityExceeded.selector);
        subject.internal__computeFillData(input);
    }

    function test_internal_computeFillData_failsWhenSelectedItemIndexIsFilled() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateTwoItemListing();
        subject._cheat_alterFilledQuantity(seller, listing, 1, 1);

        bytes memory signature = _signListing(listing, SELLER_PK);
        ScatterOfferer.SeaportFillInput memory input =
            _generateFillInput(listing, signature, _singleFill(1, 2, 1), new bytes32[][](0));

        vm.expectRevert(QuantityExceeded.selector);
        subject.internal__computeFillData(input);
    }

    function test_internal_computeFillData_failsWhenErc721ListingQuantityNotOne() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateListing(
            GenerateListingParams({
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 1,
                quantity: 2, // nft721 has to be 1
                currency: address(0),
                priceWei: 1 ether,
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours
            })
        );
        bytes memory signature = _signListing(listing, SELLER_PK);
        ScatterOfferer.SeaportFillInput memory input = _generateFillInput(
            GenerateFillInputParams({listing: listing, signature: signature, fillTokenId: 1, fillQuantity: 1})
        );

        vm.expectRevert(QuantityExceeded.selector);
        subject.internal__computeFillData(input);
    }

    function test_internal_computeFillData_failsWhenErc721FillInputQuantityIsNotOne() public {
        ScatterOfferer.ScatterSubmission memory listing = _generateListing();
        bytes memory signature = _signListing(listing, SELLER_PK);
        ScatterOfferer.SeaportFillInput memory input = _generateFillInput(
            GenerateFillInputParams({
                listing: listing,
                signature: signature,
                fillTokenId: 1,
                fillQuantity: 2 // listing.quantity == 1, fillQuantity == 2
            })
        );

        vm.expectRevert(QuantityExceeded.selector);
        subject.internal__computeFillData(input);
    }

    function test_internal_computeFillData_failsWhenErc721BidConcreteItemQuantityIsNotOne() public {
        ScatterOfferer.ScatterSubmission memory bid = _generateBid();
        bid.listings[0].tokenId = 1;
        bid.listings[0].quantity = 2;
        bytes memory signature = _signListing(bid, BIDDER_PK);
        ScatterOfferer.SeaportFillInput memory input = _generateFillInput(
            GenerateFillInputParams({listing: bid, signature: signature, fillTokenId: 1, fillQuantity: 1})
        );

        vm.expectRevert(QuantityExceeded.selector);
        subject.internal__computeFillData(input);
    }

    function test_internal_computeFillData_failsWhenCriteriaProofCountDoesNotMatchFills() public {
        ScatterOfferer.ScatterSubmission memory bid = _generateBid();
        bid.criteriaRoot = keccak256(abi.encode(uint256(1)));
        bytes memory signature = _signListing(bid, BIDDER_PK);
        ScatterOfferer.SeaportFillInput memory input = _generateFillInput(
            GenerateFillInputParams({listing: bid, signature: signature, fillTokenId: 1, fillQuantity: 1})
        );
        input.criteriaProofs = new bytes32[][](0);

        vm.expectRevert(InvalidCriteriaProof.selector);
        subject.internal__computeFillData(input);
    }

    function test_internal_computeFillData_failsWhenCriteriaProofInvalid() public {
        ScatterOfferer.ScatterSubmission memory bid = _generateBid();

        uint256 tokenId = 1;
        uint256 fillTokenId = 2;
        bid.criteriaRoot = keccak256(abi.encode(tokenId));

        bytes memory signature = _signListing(bid, BIDDER_PK);
        ScatterOfferer.SeaportFillInput memory input = _generateFillInput(
            GenerateFillInputParams({listing: bid, signature: signature, fillTokenId: fillTokenId, fillQuantity: 1})
        );
        input.criteriaProofs = new bytes32[][](1);
        input.criteriaProofs[0] = new bytes32[](0);

        vm.expectRevert(InvalidCriteriaProof.selector);
        subject.internal__computeFillData(input);
    }

    function test_internal_computeListingFee_routesAllFeeToPlatformWhenNoAffiliateOrRewards() public view {
        ScatterOfferer.Fees memory fees = subject.internal__computeListingFee(1 ether, address(0), address(0));

        // fee breakdown:
        //   listingPrice = 1 ether
        //   totalFee     = 1 ether * 500 / 10000      = 0.05 ether
        //   platformFee  = 0.05 ether (all to platform)
        //   sellerAmount = 1 ether - 0.05 ether        = 0.95 ether
        assertEq(fees.sellerAmount, 0.95 ether);
        assertEq(fees.platformAmount, 0.05 ether);
        assertEq(fees.rewardsAmount, 0);
        assertEq(fees.affiliateAmount, 0);
    }

    function test_internal_computeListingFee_splitsFeeBetweenPlatformAndRewards() public view {
        ScatterOfferer.Fees memory fees = subject.internal__computeListingFee(1 ether, address(0), rewardsRecipient);

        // fee breakdown:
        //   listingPrice = 1 ether
        //   totalFee     = 1 ether * 500 / 10000      = 0.05 ether
        //   platformFee  = 0.05 ether * 5000 / 10000  = 0.025 ether
        //   rewardsFee   = 0.05 ether - 0.025 ether   = 0.025 ether
        //   sellerAmount = 0.95 ether
        assertEq(fees.sellerAmount, 0.95 ether);
        assertEq(fees.platformAmount, 0.025 ether);
        assertEq(fees.rewardsAmount, 0.025 ether);
        assertEq(fees.affiliateAmount, 0);
    }

    function test_internal_computeListingFee_splitsFeeBetweenPlatformAndAffiliate() public view {
        ScatterOfferer.Fees memory fees = subject.internal__computeListingFee(1 ether, affiliate, address(0));

        // fee breakdown:
        //   listingPrice  = 1 ether
        //   totalFee      = 1 ether * 500 / 10000     = 0.05 ether
        //   platformFee   = 0.05 ether * 5000 / 10000 = 0.025 ether
        //   affiliateFee  = 0.05 ether - 0.025 ether  = 0.025 ether
        //   sellerAmount  = 0.95 ether
        assertEq(fees.sellerAmount, 0.95 ether);
        assertEq(fees.platformAmount, 0.025 ether);
        assertEq(fees.rewardsAmount, 0);
        assertEq(fees.affiliateAmount, 0.025 ether);
    }

    function test_internal_computeListingFee_affiliateTakesPriorityOverRegistryRewards() public view {
        ScatterOfferer.Fees memory fees = subject.internal__computeListingFee(1 ether, affiliate, rewardsRecipient);

        // Affiliate takes priority over rewards attribution.
        // fee breakdown:
        //   listingPrice = 1 ether
        //   totalFee     = 1 ether * 500 / 10000      = 0.05 ether
        //   platformFee  = 0.05 ether * 5000 / 10000  = 0.025 ether
        //   rewardsFee   = 0
        //   affiliateFee = 0.05 ether - 0.025 ether   = 0.025 ether
        //   sellerAmount = 1 ether - 0.05 ether        = 0.95 ether
        assertEq(fees.sellerAmount, 0.95 ether);
        assertEq(fees.platformAmount, 0.025 ether);
        assertEq(fees.rewardsAmount, 0);
        assertEq(fees.affiliateAmount, 0.025 ether);
    }

    function test_internal_computeListingFee_sellerAmountPlusTotalFeeEqualsListingPrice() public view {
        ScatterOfferer.Fees memory fees = subject.internal__computeListingFee(1 ether, affiliate, rewardsRecipient);

        uint256 totalFee = fees.platformAmount + fees.rewardsAmount + fees.affiliateAmount;
        // fee breakdown:
        //   listingPrice = 1 ether
        //   totalFee     = platformFee + rewardsFee + affiliateFee
        //   sellerAmount + totalFee = listingPrice
        assertEq(fees.sellerAmount + totalFee, 1 ether);
    }

    function test_internal_emitScatterSale_omitsRewardsRecipientWhenAffiliateTakesPriority() public {
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Listing,
                signer: seller,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(0),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(0),
                totalFillPrice: 1 ether,
                rewardsRecipient: rewardsRecipient,
                affiliate: affiliate,
                sellerAmount: 0.95 ether,
                platformAmount: 0.025 ether,
                rewardsAmount: 0,
                affiliateAmount: 0.025 ether
            })
        );
        ScatterOfferer.SeaportFillInput memory input = context.input;
        ScatterOfferer.ValidatedFillData memory fillData = context.fillData;
        ScatterOfferer.Fees memory fees = context.fillFees[0].fees;

        vm.expectEmit(true, true, true, true, address(subject));
        emit ScatterOfferer.ScatterSale({
            submissionHash: fillData.submissionHash,
            role: uint8(ScatterOfferer.Role.Listing),
            seller: seller,
            buyer: buyer,
            collection: context.submission.listings[0].collection,
            itemIndex: input.fills[0].itemIndex,
            tokenId: input.fills[0].tokenId,
            quantity: input.fills[0].quantity,
            currency: context.submission.listings[0].currency,
            totalPrice: fillData.totalFillPrice,
            affiliate: affiliate,
            rewardsRecipient: address(0),
            sellerAmount: fees.sellerAmount,
            platformAmount: fees.platformAmount,
            rewardsAmount: fees.rewardsAmount,
            affiliateAmount: fees.affiliateAmount
        });

        subject.internal__emitScatterSale(context, buyer);
    }

    function test_internal_emitScatterSale_emitsCorrectSellerAndBuyerForListingRole() public {
        // fee breakdown:
        //   listingPrice = 1 ether
        //   totalFee     = 1 ether * 500 / 10000 = 0.05 ether
        //   platformFee  = 0.05 ether (no affiliate or rewards)
        //   sellerAmount = 0.95 ether
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Listing,
                signer: seller,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(0),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(0),
                totalFillPrice: 1 ether,
                rewardsRecipient: address(0),
                affiliate: address(0),
                sellerAmount: 0.95 ether,
                platformAmount: 0.05 ether,
                rewardsAmount: 0,
                affiliateAmount: 0
            })
        );
        ScatterOfferer.SeaportFillInput memory input = context.input;
        ScatterOfferer.ValidatedFillData memory fillData = context.fillData;
        ScatterOfferer.Fees memory fees = context.fillFees[0].fees;

        vm.expectEmit(true, true, true, true, address(subject));
        emit ScatterOfferer.ScatterSale({
            submissionHash: fillData.submissionHash,
            role: uint8(ScatterOfferer.Role.Listing),
            seller: seller, // signer is seller for Listing role
            buyer: buyer, // fulfiller is buyer
            collection: context.submission.listings[0].collection,
            itemIndex: input.fills[0].itemIndex,
            tokenId: input.fills[0].tokenId,
            quantity: input.fills[0].quantity,
            currency: context.submission.listings[0].currency,
            totalPrice: fillData.totalFillPrice,
            affiliate: input.affiliate,
            rewardsRecipient: context.fillFees[0].rewardsRecipient,
            sellerAmount: fees.sellerAmount,
            platformAmount: fees.platformAmount,
            rewardsAmount: fees.rewardsAmount,
            affiliateAmount: fees.affiliateAmount
        });

        subject.internal__emitScatterSale(context, buyer);
    }

    function test_internal_emitScatterSale_emitsCorrectSellerAndBuyerForBidRole() public {
        // fee breakdown:
        //   listingPrice = 1 ether
        //   totalFee     = 1 ether * 500 / 10000 = 0.05 ether
        //   platformFee  = 0.05 ether (no affiliate or rewards)
        //   sellerAmount = 0.95 ether
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Bid,
                signer: bidder,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(0),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(0),
                totalFillPrice: 1 ether,
                rewardsRecipient: address(0),
                affiliate: address(0),
                sellerAmount: 0.95 ether,
                platformAmount: 0.05 ether,
                rewardsAmount: 0,
                affiliateAmount: 0
            })
        );
        ScatterOfferer.SeaportFillInput memory input = context.input;
        ScatterOfferer.ValidatedFillData memory fillData = context.fillData;
        ScatterOfferer.Fees memory fees = context.fillFees[0].fees;

        vm.expectEmit(true, true, true, true, address(subject));
        emit ScatterOfferer.ScatterSale({
            submissionHash: fillData.submissionHash,
            role: uint8(ScatterOfferer.Role.Bid),
            seller: seller, // fulfiller is seller for Bid role
            buyer: bidder, // signer is buyer
            collection: context.submission.listings[0].collection,
            itemIndex: input.fills[0].itemIndex,
            tokenId: input.fills[0].tokenId,
            quantity: input.fills[0].quantity,
            currency: context.submission.listings[0].currency,
            totalPrice: fillData.totalFillPrice,
            affiliate: input.affiliate,
            rewardsRecipient: context.fillFees[0].rewardsRecipient,
            sellerAmount: fees.sellerAmount,
            platformAmount: fees.platformAmount,
            rewardsAmount: fees.rewardsAmount,
            affiliateAmount: fees.affiliateAmount
        });

        subject.internal__emitScatterSale(context, seller);
    }

    function test_internal_emitScatterSale_emitsRoutedFulfillerAsBuyerWhenRequesterIsTrustedRouter() public {
        // the trusted router reports its current caller via
        // activeRoutedFulfiller(); the offerer attributes the sale to that
        // address — extraData has no say (a direct sweep caller could
        // forge extraData, but not the router's own msg.sender)
        RoutedFulfillerProviderMock mockRouter = new RoutedFulfillerProviderMock();
        mockRouter.setActiveRoutedFulfiller(buyer);
        _prank(owner);
        subject.setTrustedRouter(address(mockRouter), true);

        // fee breakdown:
        //   listingPrice = 1 ether
        //   totalFee     = 1 ether * 500 / 10000 = 0.05 ether
        //   platformFee  = 0.05 ether (no affiliate or rewards)
        //   sellerAmount = 0.95 ether
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Listing,
                signer: seller,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(0),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(0),
                totalFillPrice: 1 ether,
                rewardsRecipient: address(0),
                affiliate: address(0),
                sellerAmount: 0.95 ether,
                platformAmount: 0.05 ether,
                rewardsAmount: 0,
                affiliateAmount: 0
            })
        );
        ScatterOfferer.SeaportFillInput memory input = context.input;
        ScatterOfferer.ValidatedFillData memory fillData = context.fillData;
        ScatterOfferer.Fees memory fees = context.fillFees[0].fees;

        _prank(other);
        vm.expectEmit(true, true, true, true, address(subject));
        emit ScatterOfferer.ScatterSale({
            submissionHash: fillData.submissionHash,
            role: uint8(ScatterOfferer.Role.Listing),
            seller: seller,
            buyer: buyer, // the router's reported caller, not the router
            collection: context.submission.listings[0].collection,
            itemIndex: input.fills[0].itemIndex,
            tokenId: input.fills[0].tokenId,
            quantity: input.fills[0].quantity,
            currency: context.submission.listings[0].currency,
            totalPrice: fillData.totalFillPrice,
            affiliate: input.affiliate,
            rewardsRecipient: context.fillFees[0].rewardsRecipient,
            sellerAmount: fees.sellerAmount,
            platformAmount: fees.platformAmount,
            rewardsAmount: fees.rewardsAmount,
            affiliateAmount: fees.affiliateAmount
        });

        subject.internal__emitScatterSale(context, address(mockRouter));
    }

    function test_generateOrder_revertsWhenTrustedRouterReportsZeroFulfiller() public {
        RoutedFulfillerProviderMock mockRouter = new RoutedFulfillerProviderMock();
        _prank(owner);
        subject.setTrustedRouter(address(mockRouter), true);

        ScatterOfferer.ScatterSubmission memory listing = _generateListing();
        bytes memory signature = _signListing(listing, SELLER_PK);
        bytes memory context = _encodeContext(listing, signature, address(0), 1, 1, new bytes32[](0));

        _prank(subject.SEAPORT());
        vm.expectRevert(InvalidRoutedFulfiller.selector);
        subject.generateOrder(address(mockRouter), new SpentItem[](0), new SpentItem[](0), context);
    }

    function test_generateOrder_revertsWhenTrustedRouterHasNoGetter() public {
        _prank(owner);
        subject.setTrustedRouter(router, true);

        ScatterOfferer.ScatterSubmission memory listing = _generateListing();
        bytes memory signature = _signListing(listing, SELLER_PK);
        bytes memory context = _encodeContext(listing, signature, address(0), 1, 1, new bytes32[](0));

        _prank(subject.SEAPORT());
        vm.expectRevert(InvalidRoutedFulfiller.selector);
        subject.generateOrder(router, new SpentItem[](0), new SpentItem[](0), context);
    }

    function test_internal_emitScatterSale_emitsRequesterAsBuyerWhenRouterIsUntrusted() public {
        // an UNTRUSTED router's getter is never consulted, even if it
        // would report a fulfiller — the requester itself is the buyer
        RoutedFulfillerProviderMock mockRouter = new RoutedFulfillerProviderMock();
        mockRouter.setActiveRoutedFulfiller(buyer);

        // fee breakdown:
        //   listingPrice = 1 ether
        //   totalFee     = 1 ether * 500 / 10000 = 0.05 ether
        //   platformFee  = 0.05 ether (no affiliate or rewards)
        //   sellerAmount = 0.95 ether
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Listing,
                signer: seller,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(0),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(0),
                totalFillPrice: 1 ether,
                rewardsRecipient: address(0),
                affiliate: address(0),
                sellerAmount: 0.95 ether,
                platformAmount: 0.05 ether,
                rewardsAmount: 0,
                affiliateAmount: 0
            })
        );
        ScatterOfferer.SeaportFillInput memory input = context.input;
        ScatterOfferer.ValidatedFillData memory fillData = context.fillData;
        ScatterOfferer.Fees memory fees = context.fillFees[0].fees;

        vm.expectEmit(true, true, true, true, address(subject));
        emit ScatterOfferer.ScatterSale({
            submissionHash: fillData.submissionHash,
            role: uint8(ScatterOfferer.Role.Listing),
            seller: seller,
            buyer: address(mockRouter), // requester used, getter not consulted
            collection: context.submission.listings[0].collection,
            itemIndex: input.fills[0].itemIndex,
            tokenId: input.fills[0].tokenId,
            quantity: input.fills[0].quantity,
            currency: context.submission.listings[0].currency,
            totalPrice: fillData.totalFillPrice,
            affiliate: input.affiliate,
            rewardsRecipient: context.fillFees[0].rewardsRecipient,
            sellerAmount: fees.sellerAmount,
            platformAmount: fees.platformAmount,
            rewardsAmount: fees.rewardsAmount,
            affiliateAmount: fees.affiliateAmount
        });

        subject.internal__emitScatterSale(context, address(mockRouter));
    }

    function test_internal_emitScatterSale_emitsAllFeeFields() public {
        // fee breakdown:
        //   listingPrice  = 1 ether
        //   totalFee      = 1 ether * 500 / 10000      = 0.05 ether
        //   platformFee   = 0.05 ether * 5000 / 10000  = 0.025 ether
        //   rewardsFee    = 0.05 ether - 0.025 ether   = 0.025 ether
        //   sellerAmount  = 0.95 ether
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Listing,
                signer: seller,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(0),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(0),
                totalFillPrice: 1 ether,
                rewardsRecipient: address(0),
                affiliate: address(0),
                sellerAmount: 0.95 ether,
                platformAmount: 0.025 ether,
                rewardsAmount: 0.025 ether,
                affiliateAmount: 0
            })
        );
        ScatterOfferer.SeaportFillInput memory input = context.input;
        ScatterOfferer.ValidatedFillData memory fillData = context.fillData;
        ScatterOfferer.Fees memory fees = context.fillFees[0].fees;

        vm.expectEmit(true, true, true, true, address(subject));
        emit ScatterOfferer.ScatterSale({
            submissionHash: fillData.submissionHash,
            role: uint8(ScatterOfferer.Role.Listing),
            seller: seller,
            buyer: buyer,
            collection: context.submission.listings[0].collection,
            itemIndex: input.fills[0].itemIndex,
            tokenId: input.fills[0].tokenId,
            quantity: input.fills[0].quantity,
            currency: context.submission.listings[0].currency,
            totalPrice: fillData.totalFillPrice,
            affiliate: input.affiliate,
            rewardsRecipient: context.fillFees[0].rewardsRecipient,
            sellerAmount: fees.sellerAmount,
            platformAmount: fees.platformAmount,
            rewardsAmount: fees.rewardsAmount,
            affiliateAmount: fees.affiliateAmount
        });

        subject.internal__emitScatterSale(context, buyer);
    }

    function test_internal_distributeFeesErc20_transfersPlatformFeeWhenNoAffiliateOrRewards() public {
        // fee breakdown:
        //   listingPrice = 1 ether
        //   totalFee     = 1 ether * 500 / 10000 = 0.05 ether
        //   platformFee  = 0.05 ether (no affiliate or rewards)
        //   sellerAmount = 0.95 ether
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Bid,
                signer: seller,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(0),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(weth),
                totalFillPrice: 1 ether,
                rewardsRecipient: address(0),
                affiliate: address(0),
                sellerAmount: 0.95 ether,
                platformAmount: 0.05 ether,
                rewardsAmount: 0,
                affiliateAmount: 0
            })
        );

        weth.mint(address(subject), 0.05 ether);

        subject.internal__distributeFeesErc20(context);

        assertEq(weth.balanceOf(subject.PLATFORM()), 0.05 ether);
        assertEq(weth.balanceOf(rewardsRecipient), 0);
        assertEq(weth.balanceOf(affiliate), 0);
    }

    function test_internal_distributeFeesErc20_transfersPlatformAndRewardsFees() public {
        // fee breakdown:
        //   listingPrice = 1 ether
        //   totalFee     = 1 ether * 500 / 10000      = 0.05 ether
        //   platformFee  = 0.05 ether * 5000 / 10000  = 0.025 ether
        //   rewardsFee   = 0.05 ether - 0.025 ether   = 0.025 ether
        //   sellerAmount = 0.95 ether
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Bid,
                signer: seller,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(0),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(weth),
                totalFillPrice: 1 ether,
                rewardsRecipient: rewardsRecipient,
                affiliate: address(0),
                sellerAmount: 0.95 ether,
                platformAmount: 0.025 ether,
                rewardsAmount: 0.025 ether,
                affiliateAmount: 0
            })
        );

        weth.mint(address(subject), 0.05 ether);

        subject.internal__distributeFeesErc20(context);

        assertEq(weth.balanceOf(subject.PLATFORM()), 0.025 ether);
        assertEq(weth.balanceOf(rewardsRecipient), 0.025 ether);
        assertEq(weth.balanceOf(affiliate), 0);
    }

    function test_internal_distributeFeesErc20_transfersPlatformAndAffiliateFees() public {
        // fee breakdown:
        //   listingPrice  = 1 ether
        //   totalFee      = 1 ether * 500 / 10000     = 0.05 ether
        //   platformFee   = 0.05 ether * 5000 / 10000 = 0.025 ether
        //   affiliateFee  = 0.05 ether - 0.025 ether  = 0.025 ether
        //   sellerAmount  = 0.95 ether
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Bid,
                signer: seller,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(0),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(weth),
                totalFillPrice: 1 ether,
                rewardsRecipient: address(0),
                affiliate: affiliate,
                sellerAmount: 0.95 ether,
                platformAmount: 0.025 ether,
                rewardsAmount: 0,
                affiliateAmount: 0.025 ether
            })
        );

        weth.mint(address(subject), 0.05 ether);

        subject.internal__distributeFeesErc20(context);

        assertEq(weth.balanceOf(subject.PLATFORM()), 0.025 ether);
        assertEq(weth.balanceOf(rewardsRecipient), 0);
        assertEq(weth.balanceOf(affiliate), 0.025 ether);
    }

    function test_internal_distributeFeesErc20_doesNotTransferWhenPlatformAmountIsZero() public {
        // fee breakdown:
        //   listingPrice = 1 ether
        //   totalFee     = 0 (platform amount explicitly zeroed for this test)
        //   sellerAmount = 1 ether
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Bid,
                signer: seller,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(0),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(weth),
                totalFillPrice: 1 ether,
                rewardsRecipient: address(0),
                affiliate: address(0),
                sellerAmount: 1 ether,
                platformAmount: 0,
                rewardsAmount: 0,
                affiliateAmount: 0
            })
        );

        uint256 platformBefore = weth.balanceOf(subject.PLATFORM());
        subject.internal__distributeFeesErc20(context);

        assertEq(weth.balanceOf(subject.PLATFORM()), platformBefore);
    }

    function test_internal_distributeFeesErc20_doesNotTransferWhenRewardsAmountIsZero() public {
        // fee breakdown:
        //   listingPrice = 1 ether
        //   totalFee     = 1 ether * 500 / 10000 = 0.05 ether
        //   platformFee  = 0.05 ether (rewards amount is zero)
        //   sellerAmount = 0.95 ether
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Bid,
                signer: seller,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(0),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(weth),
                totalFillPrice: 1 ether,
                rewardsRecipient: rewardsRecipient,
                affiliate: address(0),
                sellerAmount: 0.95 ether,
                platformAmount: 0.05 ether,
                rewardsAmount: 0,
                affiliateAmount: 0
            })
        );

        weth.mint(address(subject), 0.05 ether);
        subject.internal__distributeFeesErc20(context);

        assertEq(weth.balanceOf(rewardsRecipient), 0);
    }

    function test_internal_distributeFeesErc20_doesNotTransferWhenAffiliateAmountIsZero() public {
        // fee breakdown:
        //   listingPrice  = 1 ether
        //   totalFee      = 1 ether * 500 / 10000 = 0.05 ether
        //   platformFee   = 0.05 ether (affiliate amount is zero)
        //   sellerAmount  = 0.95 ether
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Bid,
                signer: seller,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(0),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(weth),
                totalFillPrice: 1 ether,
                rewardsRecipient: address(0),
                affiliate: affiliate,
                sellerAmount: 0.95 ether,
                platformAmount: 0.05 ether,
                rewardsAmount: 0,
                affiliateAmount: 0
            })
        );

        weth.mint(address(subject), 0.05 ether);
        subject.internal__distributeFeesErc20(context);

        assertEq(weth.balanceOf(affiliate), 0);
    }

    function test_internal_distributeFeesErc20_failsWhenPlatformTransferReturnsFalse() public {
        ReturnFalseERC20 badToken = new ReturnFalseERC20();
        // fee breakdown:
        //   listingPrice = 1 ether
        //   totalFee     = 1 ether * 500 / 10000 = 0.05 ether
        //   platformFee  = 0.05 ether (no affiliate or rewards)
        //   sellerAmount = 0.95 ether
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Bid,
                signer: seller,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(0),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(badToken),
                totalFillPrice: 1 ether,
                rewardsRecipient: address(0),
                affiliate: address(0),
                sellerAmount: 0.95 ether,
                platformAmount: 0.05 ether,
                rewardsAmount: 0,
                affiliateAmount: 0
            })
        );

        vm.expectPartialRevert(SafeERC20.SafeERC20FailedOperation.selector);
        subject.internal__distributeFeesErc20(context);
    }

    function test_internal_distributeFeesErc20_failsWhenRewardsTransferReturnsFalse() public {
        ReturnFalseOnSecondCallERC20 badToken = new ReturnFalseOnSecondCallERC20();
        // fee breakdown:
        //   listingPrice = 1 ether
        //   totalFee     = 1 ether * 500 / 10000      = 0.05 ether
        //   platformFee  = 0.05 ether * 5000 / 10000  = 0.025 ether
        //   rewardsFee   = 0.05 ether - 0.025 ether   = 0.025 ether
        //   sellerAmount = 0.95 ether
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Bid,
                signer: seller,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(0),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(badToken),
                totalFillPrice: 1 ether,
                rewardsRecipient: rewardsRecipient,
                affiliate: address(0),
                sellerAmount: 0.95 ether,
                platformAmount: 0.025 ether,
                rewardsAmount: 0.025 ether,
                affiliateAmount: 0
            })
        );

        vm.expectPartialRevert(SafeERC20.SafeERC20FailedOperation.selector);
        subject.internal__distributeFeesErc20(context);
    }

    function test_internal_distributeFeesErc20_failsWhenAffiliateTransferReturnsFalse() public {
        ReturnFalseOnThirdCallERC20 badToken = new ReturnFalseOnThirdCallERC20();
        // fee breakdown:
        //   listingPrice  = 1 ether
        //   totalFee      = 1 ether * 500 / 10000      = 0.05 ether
        //   platformFee   = 0.05 ether * 5000 / 10000  = 0.025 ether
        //   rewardsFee    = 0.05 ether - 0.025 ether   = 0.025 ether (used to reach affiliate call)
        //   affiliateFee  = 0.025 ether (third transfer — returns false)
        //   sellerAmount  = 0.95 ether
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Bid,
                signer: seller,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(0),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(badToken),
                totalFillPrice: 1 ether,
                rewardsRecipient: rewardsRecipient,
                affiliate: affiliate,
                sellerAmount: 0.95 ether,
                platformAmount: 0.025 ether,
                rewardsAmount: 0.025 ether,
                affiliateAmount: 0.025 ether
            })
        );

        vm.expectPartialRevert(SafeERC20.SafeERC20FailedOperation.selector);
        subject.internal__distributeFeesErc20(context);
    }

    function test_internal_pullAndApproveErc20_pullsTotalPriceFromSigner() public {
        // fee breakdown:
        //   listingPrice   = 1 ether
        //   totalFee       = 1 ether * 500 / 10000 = 0.05 ether
        //   sellerAmount   = 0.95 ether
        //   totalFillPrice = 1 ether (pulled from signer)
        // transfer breakdown:
        //   bidder starts with 100 ether weth (minted in setUp)
        //   transferFrom pulls totalFillPrice = 1 ether from bidder
        //   bidder balance after = 100 ether - 1 ether = 99 ether
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Bid,
                signer: bidder,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(0),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(weth),
                totalFillPrice: 1 ether,
                rewardsRecipient: address(0),
                affiliate: address(0),
                sellerAmount: 0.95 ether,
                platformAmount: 0.05 ether,
                rewardsAmount: 0,
                affiliateAmount: 0
            })
        );

        subject.internal__pullAndApproveErc20(context);

        assertEq(weth.balanceOf(bidder), 99 ether);
        assertEq(weth.balanceOf(address(subject)), 1 ether);
    }

    function test_internal_pullAndApproveErc20_approvesSeaportForSellerAmount() public {
        // fee breakdown:
        //   listingPrice   = 1 ether
        //   totalFee       = 1 ether * 500 / 10000 = 0.05 ether
        //   sellerAmount   = 0.95 ether (approved to Seaport)
        //   totalFillPrice = 1 ether (pulled from signer)
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Bid,
                signer: bidder,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(0),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(weth),
                totalFillPrice: 1 ether,
                rewardsRecipient: address(0),
                affiliate: address(0),
                sellerAmount: 0.95 ether,
                platformAmount: 0.05 ether,
                rewardsAmount: 0,
                affiliateAmount: 0
            })
        );

        subject.internal__pullAndApproveErc20(context);

        assertEq(weth.allowance(address(subject), subject.SEAPORT()), 0.95 ether);
    }

    function test_internal_pullAndApproveErc20_accumulatesSeaportAllowance() public {
        ScatterOfferer.SeaportOrderContext memory firstContext = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Bid,
                signer: bidder,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(0),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(weth),
                totalFillPrice: 1 ether,
                rewardsRecipient: address(0),
                affiliate: address(0),
                sellerAmount: 0.95 ether,
                platformAmount: 0.05 ether,
                rewardsAmount: 0,
                affiliateAmount: 0
            })
        );
        ScatterOfferer.SeaportOrderContext memory secondContext = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Bid,
                signer: bidder,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(0),
                tokenId: 2,
                fillTokenId: 2,
                fillQuantity: 1,
                currency: address(weth),
                totalFillPrice: 2 ether,
                rewardsRecipient: address(0),
                affiliate: address(0),
                sellerAmount: 1.9 ether,
                platformAmount: 0.1 ether,
                rewardsAmount: 0,
                affiliateAmount: 0
            })
        );

        subject.internal__pullAndApproveErc20(firstContext);
        subject.internal__pullAndApproveErc20(secondContext);

        // fee breakdown:
        //   firstSellerAmount  = 1 ether - (1 ether * 500 / 10000) = 0.95 ether
        //   secondSellerAmount = 2 ether - (2 ether * 500 / 10000) = 1.9 ether
        //   totalAllowance     = 0.95 ether + 1.9 ether = 2.85 ether
        assertEq(weth.allowance(address(subject), subject.SEAPORT()), 2.85 ether);
    }

    function test_internal_pullAndApproveErc20_failsWhenTransferFromReturnsFalse() public {
        ReturnFalseERC20 badToken = new ReturnFalseERC20();
        // fee breakdown:
        //   totalFillPrice = 1 ether (transferFrom returns false)
        //   sellerAmount   = 0.95 ether
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Bid,
                signer: bidder,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(0),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(badToken),
                totalFillPrice: 1 ether,
                rewardsRecipient: address(0),
                affiliate: address(0),
                sellerAmount: 0.95 ether,
                platformAmount: 0.05 ether,
                rewardsAmount: 0,
                affiliateAmount: 0
            })
        );

        vm.expectPartialRevert(TokenTransferrerErrors.BadReturnValueFromERC20OnTransfer.selector);
        subject.internal__pullAndApproveErc20(context);
    }

    function test_internal_pullAndApproveErc20_failsWhenApproveReturnsFalse() public {
        ReturnFalseOnSecondCallERC20 badToken = new ReturnFalseOnSecondCallERC20();
        // fee breakdown:
        //   totalFillPrice = 1 ether (transferFrom succeeds)
        //   sellerAmount   = 0.95 ether (approve returns false)
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Bid,
                signer: bidder,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(0),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(badToken),
                totalFillPrice: 1 ether,
                rewardsRecipient: address(0),
                affiliate: address(0),
                sellerAmount: 0.95 ether,
                platformAmount: 0.05 ether,
                rewardsAmount: 0,
                affiliateAmount: 0
            })
        );

        vm.expectPartialRevert(SafeERC20.SafeERC20FailedOperation.selector);
        subject.internal__pullAndApproveErc20(context);
    }

    function test_internal_pullAndApproveNft_pullsErc721FromSigner() public {
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Listing,
                signer: seller,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(0),
                totalFillPrice: 1 ether,
                rewardsRecipient: address(0),
                affiliate: address(0),
                sellerAmount: 0.95 ether,
                platformAmount: 0.05 ether,
                rewardsAmount: 0,
                affiliateAmount: 0
            })
        );

        subject.internal__pullAndApproveNft(context);

        assertEq(nft721.ownerOf(1), address(subject));
    }

    function test_internal_pullAndApproveNft_approvesSeaportForErc721WhenNotApproved() public {
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Listing,
                signer: seller,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(0),
                totalFillPrice: 1 ether,
                rewardsRecipient: address(0),
                affiliate: address(0),
                sellerAmount: 0.95 ether,
                platformAmount: 0.05 ether,
                rewardsAmount: 0,
                affiliateAmount: 0
            })
        );

        assertFalse(nft721.isApprovedForAll(address(subject), subject.SEAPORT()));

        subject.internal__pullAndApproveNft(context);

        assertTrue(nft721.isApprovedForAll(address(subject), subject.SEAPORT()));
    }

    function test_internal_pullAndApproveNft_keepsErc721SeaportApprovalWhenAlreadyApproved() public {
        _prank(address(subject));
        nft721.setApprovalForAll(subject.SEAPORT(), true);

        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Listing,
                signer: seller,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(0),
                totalFillPrice: 1 ether,
                rewardsRecipient: address(0),
                affiliate: address(0),
                sellerAmount: 0.95 ether,
                platformAmount: 0.05 ether,
                rewardsAmount: 0,
                affiliateAmount: 0
            })
        );

        _prank(other);
        subject.internal__pullAndApproveNft(context);

        assertTrue(nft721.isApprovedForAll(address(subject), subject.SEAPORT()));
    }

    function test_internal_pullAndApproveNft_pullsErc1155FromSigner() public {
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Listing,
                signer: seller,
                assetType: ScatterOfferer.AssetType.ERC1155,
                collection: address(nft1155),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 3, // transfering 3 tokens
                currency: address(0),
                totalFillPrice: 0.3 ether,
                rewardsRecipient: address(0),
                affiliate: address(0),
                sellerAmount: 0.285 ether,
                platformAmount: 0.015 ether,
                rewardsAmount: 0,
                affiliateAmount: 0
            })
        );

        // balance breakdown:
        //   seller starts with 10 units of tokenId 1 (minted in setUp)
        //   subject starts with 0 units of tokenId 1
        //   safeTransferFrom pulls fillQuantity = 3 from seller to subject
        //   seller balance after = 10 - 3 = 7
        //   subject balance after = 0 + 3 = 3
        assertEq(nft1155.balanceOf(seller, 1), 10);
        assertEq(nft1155.balanceOf(address(subject), 1), 0);

        subject.internal__pullAndApproveNft(context);

        assertEq(nft1155.balanceOf(seller, 1), 7);
        assertEq(nft1155.balanceOf(address(subject), 1), 3);
    }

    function test_internal_pullAndApproveNft_approvesSeaportForErc1155WhenNotApproved() public {
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Listing,
                signer: seller,
                assetType: ScatterOfferer.AssetType.ERC1155,
                collection: address(nft1155),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 3,
                currency: address(0),
                totalFillPrice: 0.3 ether,
                rewardsRecipient: address(0),
                affiliate: address(0),
                sellerAmount: 0.285 ether,
                platformAmount: 0.015 ether,
                rewardsAmount: 0,
                affiliateAmount: 0
            })
        );

        assertFalse(nft1155.isApprovedForAll(address(subject), subject.SEAPORT()));

        subject.internal__pullAndApproveNft(context);

        assertTrue(nft1155.isApprovedForAll(address(subject), subject.SEAPORT()));
    }

    function test_internal_pullAndApproveNft_keepsErc1155SeaportApprovalWhenAlreadyApproved() public {
        _prank(address(subject));
        nft1155.setApprovalForAll(subject.SEAPORT(), true);

        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Listing,
                signer: seller,
                assetType: ScatterOfferer.AssetType.ERC1155,
                collection: address(nft1155),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 3,
                currency: address(0),
                totalFillPrice: 0.3 ether,
                rewardsRecipient: address(0),
                affiliate: address(0),
                sellerAmount: 0.285 ether,
                platformAmount: 0.015 ether,
                rewardsAmount: 0,
                affiliateAmount: 0
            })
        );

        _prank(other);
        subject.internal__pullAndApproveNft(context);

        assertTrue(nft1155.isApprovedForAll(address(subject), subject.SEAPORT()));
    }

    function test_internal_buildConsiderationArrayBid_setsErc721ConsiderationItem() public view {
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Bid,
                signer: bidder,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 0,
                fillTokenId: 2,
                fillQuantity: 1,
                currency: address(weth),
                totalFillPrice: 1 ether,
                rewardsRecipient: address(0),
                affiliate: address(0),
                sellerAmount: 0.95 ether,
                platformAmount: 0.05 ether,
                rewardsAmount: 0,
                affiliateAmount: 0
            })
        );

        ReceivedItem[] memory consideration = subject.internal__buildConsiderationArrayBid(context);

        assertEq(consideration.length, 1);
        _assertReceivedItem(consideration[0], ItemType.ERC721, address(nft721), 2, 1, bidder);
    }

    function test_internal_buildConsiderationArrayBid_setsErc1155ConsiderationItem() public view {
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Bid,
                signer: bidder,
                assetType: ScatterOfferer.AssetType.ERC1155,
                collection: address(nft1155),
                tokenId: 0,
                fillTokenId: 1,
                fillQuantity: 3,
                currency: address(weth),
                totalFillPrice: 0.3 ether,
                rewardsRecipient: address(0),
                affiliate: address(0),
                sellerAmount: 0.285 ether,
                platformAmount: 0.015 ether,
                rewardsAmount: 0,
                affiliateAmount: 0
            })
        );

        ReceivedItem[] memory consideration = subject.internal__buildConsiderationArrayBid(context);

        assertEq(consideration.length, 1);
        _assertReceivedItem(consideration[0], ItemType.ERC1155, address(nft1155), 1, 3, bidder);
    }

    function test_internal_buildConsiderationArrayListing_setsNativeSellerPlatformRewardsAffiliateItems() public view {
        // fee breakdown:
        //   listingPrice  = 1 ether
        //   sellerAmount  = 0.95 ether
        //   platformFee   = 0.025 ether
        //   rewardsFee    = 0.015 ether
        //   affiliateFee  = 0.01 ether
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Listing,
                signer: seller,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(0),
                totalFillPrice: 1 ether,
                rewardsRecipient: rewardsRecipient,
                affiliate: affiliate,
                sellerAmount: 0.95 ether,
                platformAmount: 0.025 ether,
                rewardsAmount: 0.015 ether,
                affiliateAmount: 0.01 ether
            })
        );

        ReceivedItem[] memory consideration = subject.internal__buildConsiderationArrayListing(context);

        assertEq(consideration.length, 4);
        _assertReceivedItem(consideration[0], ItemType.NATIVE, address(0), 0, 0.95 ether, seller);
        _assertReceivedItem(consideration[1], ItemType.NATIVE, address(0), 0, 0.025 ether, subject.PLATFORM());
        _assertReceivedItem(consideration[2], ItemType.NATIVE, address(0), 0, 0.015 ether, rewardsRecipient);
        _assertReceivedItem(consideration[3], ItemType.NATIVE, address(0), 0, 0.01 ether, affiliate);
    }

    function test_internal_buildConsiderationArrayListing_setsNativePlatformRewardsAffiliateItemsWhenSellerAmountIsZero()
        public
        view
    {
        // fee breakdown:
        //   listingPrice  = 1 ether
        //   sellerAmount  = 0 (omitted)
        //   platformFee   = 0.025 ether
        //   rewardsFee    = 0.015 ether
        //   affiliateFee  = 0.01 ether
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Listing,
                signer: seller,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(0),
                totalFillPrice: 1 ether,
                rewardsRecipient: rewardsRecipient,
                affiliate: affiliate,
                sellerAmount: 0,
                platformAmount: 0.025 ether,
                rewardsAmount: 0.015 ether,
                affiliateAmount: 0.01 ether
            })
        );

        ReceivedItem[] memory consideration = subject.internal__buildConsiderationArrayListing(context);

        assertEq(consideration.length, 3);
        _assertReceivedItem(consideration[0], ItemType.NATIVE, address(0), 0, 0.025 ether, subject.PLATFORM());
        _assertReceivedItem(consideration[1], ItemType.NATIVE, address(0), 0, 0.015 ether, rewardsRecipient);
        _assertReceivedItem(consideration[2], ItemType.NATIVE, address(0), 0, 0.01 ether, affiliate);
    }

    function test_internal_buildConsiderationArrayListing_setsNativeSellerRewardsAffiliateItemsWhenPlatformAmountIsZero()
        public
        view
    {
        // fee breakdown:
        //   listingPrice  = 1 ether
        //   sellerAmount  = 0.95 ether
        //   platformFee   = 0 (omitted)
        //   rewardsFee    = 0.015 ether
        //   affiliateFee  = 0.01 ether
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Listing,
                signer: seller,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(0),
                totalFillPrice: 1 ether,
                rewardsRecipient: rewardsRecipient,
                affiliate: affiliate,
                sellerAmount: 0.95 ether,
                platformAmount: 0,
                rewardsAmount: 0.015 ether,
                affiliateAmount: 0.01 ether
            })
        );

        ReceivedItem[] memory consideration = subject.internal__buildConsiderationArrayListing(context);

        assertEq(consideration.length, 3);
        _assertReceivedItem(consideration[0], ItemType.NATIVE, address(0), 0, 0.95 ether, seller);
        _assertReceivedItem(consideration[1], ItemType.NATIVE, address(0), 0, 0.015 ether, rewardsRecipient);
        _assertReceivedItem(consideration[2], ItemType.NATIVE, address(0), 0, 0.01 ether, affiliate);
    }

    function test_internal_buildConsiderationArrayListing_setsNativeSellerPlatformAffiliateItemsWhenRewardsAmountIsZero()
        public
        view
    {
        // fee breakdown:
        //   listingPrice  = 1 ether
        //   sellerAmount  = 0.95 ether
        //   platformFee   = 0.025 ether
        //   rewardsFee    = 0 (omitted)
        //   affiliateFee  = 0.01 ether
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Listing,
                signer: seller,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(0),
                totalFillPrice: 1 ether,
                rewardsRecipient: rewardsRecipient,
                affiliate: affiliate,
                sellerAmount: 0.95 ether,
                platformAmount: 0.025 ether,
                rewardsAmount: 0,
                affiliateAmount: 0.01 ether
            })
        );

        ReceivedItem[] memory consideration = subject.internal__buildConsiderationArrayListing(context);

        assertEq(consideration.length, 3);
        _assertReceivedItem(consideration[0], ItemType.NATIVE, address(0), 0, 0.95 ether, seller);
        _assertReceivedItem(consideration[1], ItemType.NATIVE, address(0), 0, 0.025 ether, subject.PLATFORM());
        _assertReceivedItem(consideration[2], ItemType.NATIVE, address(0), 0, 0.01 ether, affiliate);
    }

    function test_internal_buildConsiderationArrayListing_setsNativeSellerPlatformRewardsItemsWhenAffiliateAmountIsZero()
        public
        view
    {
        // fee breakdown:
        //   listingPrice  = 1 ether
        //   sellerAmount  = 0.95 ether
        //   platformFee   = 0.025 ether
        //   rewardsFee    = 0.015 ether
        //   affiliateFee  = 0 (omitted)
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Listing,
                signer: seller,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(0),
                totalFillPrice: 1 ether,
                rewardsRecipient: rewardsRecipient,
                affiliate: affiliate,
                sellerAmount: 0.95 ether,
                platformAmount: 0.025 ether,
                rewardsAmount: 0.015 ether,
                affiliateAmount: 0
            })
        );

        ReceivedItem[] memory consideration = subject.internal__buildConsiderationArrayListing(context);

        assertEq(consideration.length, 3);
        _assertReceivedItem(consideration[0], ItemType.NATIVE, address(0), 0, 0.95 ether, seller);
        _assertReceivedItem(consideration[1], ItemType.NATIVE, address(0), 0, 0.025 ether, subject.PLATFORM());
        _assertReceivedItem(consideration[2], ItemType.NATIVE, address(0), 0, 0.015 ether, rewardsRecipient);
    }

    function test_internal_buildConsiderationArrayListing_setsErc20SellerPlatformRewardsAffiliateItems() public view {
        // fee breakdown:
        //   listingPrice  = 1 ether
        //   sellerAmount  = 0.95 ether
        //   platformFee   = 0.025 ether
        //   rewardsFee    = 0.015 ether
        //   affiliateFee  = 0.01 ether
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Listing,
                signer: seller,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(weth),
                totalFillPrice: 1 ether,
                rewardsRecipient: rewardsRecipient,
                affiliate: affiliate,
                sellerAmount: 0.95 ether,
                platformAmount: 0.025 ether,
                rewardsAmount: 0.015 ether,
                affiliateAmount: 0.01 ether
            })
        );

        ReceivedItem[] memory consideration = subject.internal__buildConsiderationArrayListing(context);

        assertEq(consideration.length, 4);
        _assertReceivedItem(consideration[0], ItemType.ERC20, address(weth), 0, 0.95 ether, seller);
        _assertReceivedItem(consideration[1], ItemType.ERC20, address(weth), 0, 0.025 ether, subject.PLATFORM());
        _assertReceivedItem(consideration[2], ItemType.ERC20, address(weth), 0, 0.015 ether, rewardsRecipient);
        _assertReceivedItem(consideration[3], ItemType.ERC20, address(weth), 0, 0.01 ether, affiliate);
    }

    function test_internal_buildConsiderationArrayListing_setsErc20PlatformRewardsAffiliateItemsWhenSellerAmountIsZero()
        public
        view
    {
        // fee breakdown:
        //   listingPrice  = 1 ether
        //   sellerAmount  = 0 (omitted)
        //   platformFee   = 0.025 ether
        //   rewardsFee    = 0.015 ether
        //   affiliateFee  = 0.01 ether
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Listing,
                signer: seller,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(weth),
                totalFillPrice: 1 ether,
                rewardsRecipient: rewardsRecipient,
                affiliate: affiliate,
                sellerAmount: 0,
                platformAmount: 0.025 ether,
                rewardsAmount: 0.015 ether,
                affiliateAmount: 0.01 ether
            })
        );

        ReceivedItem[] memory consideration = subject.internal__buildConsiderationArrayListing(context);

        assertEq(consideration.length, 3);
        _assertReceivedItem(consideration[0], ItemType.ERC20, address(weth), 0, 0.025 ether, subject.PLATFORM());
        _assertReceivedItem(consideration[1], ItemType.ERC20, address(weth), 0, 0.015 ether, rewardsRecipient);
        _assertReceivedItem(consideration[2], ItemType.ERC20, address(weth), 0, 0.01 ether, affiliate);
    }

    function test_internal_buildConsiderationArrayListing_setsErc20SellerRewardsAffiliateItemsWhenPlatformAmountIsZero()
        public
        view
    {
        // fee breakdown:
        //   listingPrice  = 1 ether
        //   sellerAmount  = 0.95 ether
        //   platformFee   = 0 (omitted)
        //   rewardsFee    = 0.015 ether
        //   affiliateFee  = 0.01 ether
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Listing,
                signer: seller,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(weth),
                totalFillPrice: 1 ether,
                rewardsRecipient: rewardsRecipient,
                affiliate: affiliate,
                sellerAmount: 0.95 ether,
                platformAmount: 0,
                rewardsAmount: 0.015 ether,
                affiliateAmount: 0.01 ether
            })
        );

        ReceivedItem[] memory consideration = subject.internal__buildConsiderationArrayListing(context);

        assertEq(consideration.length, 3);
        _assertReceivedItem(consideration[0], ItemType.ERC20, address(weth), 0, 0.95 ether, seller);
        _assertReceivedItem(consideration[1], ItemType.ERC20, address(weth), 0, 0.015 ether, rewardsRecipient);
        _assertReceivedItem(consideration[2], ItemType.ERC20, address(weth), 0, 0.01 ether, affiliate);
    }

    function test_internal_buildConsiderationArrayListing_setsErc20SellerPlatformAffiliateItemsWhenRewardsAmountIsZero()
        public
        view
    {
        // fee breakdown:
        //   listingPrice  = 1 ether
        //   sellerAmount  = 0.95 ether
        //   platformFee   = 0.025 ether
        //   rewardsFee    = 0 (omitted)
        //   affiliateFee  = 0.01 ether
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Listing,
                signer: seller,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(weth),
                totalFillPrice: 1 ether,
                rewardsRecipient: rewardsRecipient,
                affiliate: affiliate,
                sellerAmount: 0.95 ether,
                platformAmount: 0.025 ether,
                rewardsAmount: 0,
                affiliateAmount: 0.01 ether
            })
        );

        ReceivedItem[] memory consideration = subject.internal__buildConsiderationArrayListing(context);

        assertEq(consideration.length, 3);
        _assertReceivedItem(consideration[0], ItemType.ERC20, address(weth), 0, 0.95 ether, seller);
        _assertReceivedItem(consideration[1], ItemType.ERC20, address(weth), 0, 0.025 ether, subject.PLATFORM());
        _assertReceivedItem(consideration[2], ItemType.ERC20, address(weth), 0, 0.01 ether, affiliate);
    }

    function test_internal_buildConsiderationArrayListing_setsErc20SellerPlatformRewardsItemsWhenAffiliateAmountIsZero()
        public
        view
    {
        // fee breakdown:
        //   listingPrice  = 1 ether
        //   sellerAmount  = 0.95 ether
        //   platformFee   = 0.025 ether
        //   rewardsFee    = 0.015 ether
        //   affiliateFee  = 0 (omitted)
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Listing,
                signer: seller,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 1,
                fillTokenId: 1,
                fillQuantity: 1,
                currency: address(weth),
                totalFillPrice: 1 ether,
                rewardsRecipient: rewardsRecipient,
                affiliate: affiliate,
                sellerAmount: 0.95 ether,
                platformAmount: 0.025 ether,
                rewardsAmount: 0.015 ether,
                affiliateAmount: 0
            })
        );

        ReceivedItem[] memory consideration = subject.internal__buildConsiderationArrayListing(context);

        assertEq(consideration.length, 3);
        _assertReceivedItem(consideration[0], ItemType.ERC20, address(weth), 0, 0.95 ether, seller);
        _assertReceivedItem(consideration[1], ItemType.ERC20, address(weth), 0, 0.025 ether, subject.PLATFORM());
        _assertReceivedItem(consideration[2], ItemType.ERC20, address(weth), 0, 0.015 ether, rewardsRecipient);
    }

    function test_internal_buildSeaportArraysBid_setsNativeOfferItem() public view {
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Bid,
                signer: bidder,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 0,
                fillTokenId: 2,
                fillQuantity: 1,
                currency: address(0),
                totalFillPrice: 1 ether,
                rewardsRecipient: address(0),
                affiliate: address(0),
                sellerAmount: 0.95 ether,
                platformAmount: 0.05 ether,
                rewardsAmount: 0,
                affiliateAmount: 0
            })
        );

        (SpentItem[] memory offer, ReceivedItem[] memory consideration) =
            subject.internal__buildSeaportArraysBid(context);

        assertEq(offer.length, 1);
        assertEq(uint8(offer[0].itemType), uint8(ItemType.NATIVE));
        assertEq(offer[0].token, address(0));
        assertEq(offer[0].identifier, 0);
        // fee breakdown:
        //   listingPrice = 1 ether
        //   totalFee     = 1 ether * 500 / 10000 = 0.05 ether
        //   sellerAmount = 1 ether - 0.05 ether = 0.95 ether
        assertEq(offer[0].amount, 0.95 ether);

        // Detailed consideration fields are covered by _buildConsiderationArrayBid tests.
        assertEq(consideration.length, 1);
    }

    function test_internal_buildSeaportArraysBid_setsErc20OfferItem() public view {
        ScatterOfferer.SeaportOrderContext memory context = _generateContext(
            GenerateContextParams({
                role: ScatterOfferer.Role.Bid,
                signer: bidder,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 0,
                fillTokenId: 2,
                fillQuantity: 1,
                currency: address(weth),
                totalFillPrice: 1 ether,
                rewardsRecipient: address(0),
                affiliate: address(0),
                sellerAmount: 0.95 ether,
                platformAmount: 0.05 ether,
                rewardsAmount: 0,
                affiliateAmount: 0
            })
        );

        (SpentItem[] memory offer, ReceivedItem[] memory consideration) =
            subject.internal__buildSeaportArraysBid(context);

        assertEq(offer.length, 1);
        assertEq(uint8(offer[0].itemType), uint8(ItemType.ERC20));
        assertEq(offer[0].token, address(weth));
        assertEq(offer[0].identifier, 0);
        // fee breakdown:
        //   listingPrice = 1 ether
        //   totalFee     = 1 ether * 500 / 10000 = 0.05 ether
        //   sellerAmount = 1 ether - 0.05 ether = 0.95 ether
        assertEq(offer[0].amount, 0.95 ether);

        // Detailed consideration fields are covered by _buildConsiderationArrayBid tests.
        assertEq(consideration.length, 1);
    }

    struct GenerateContextParams {
        ScatterOfferer.Role role;
        address signer;
        ScatterOfferer.AssetType assetType;
        address collection;
        uint256 tokenId;
        uint256 fillTokenId;
        uint256 fillQuantity;
        address currency;
        uint256 totalFillPrice;
        address rewardsRecipient;
        address affiliate;
        uint256 sellerAmount;
        uint256 platformAmount;
        uint256 rewardsAmount;
        uint256 affiliateAmount;
    }

    function _generateContext(GenerateContextParams memory p)
        internal
        view
        returns (ScatterOfferer.SeaportOrderContext memory context)
    {
        context.role = p.role;
        context.currency = p.currency;

        context.submission.role = p.role;
        context.submission.listings = new ScatterOfferer.ScatterListing[](1);
        context.submission.listings[0] = ScatterOfferer.ScatterListing({
            assetType: p.assetType,
            collection: p.collection,
            tokenId: p.tokenId,
            quantity: p.fillQuantity,
            currency: p.currency,
            priceWei: p.totalFillPrice
        });
        context.submission.startTime = block.timestamp;
        context.submission.endTime = block.timestamp + 1 hours;

        context.input.submission = context.submission;
        context.input.affiliate = p.affiliate;
        context.input.fills = new ScatterOfferer.ScatterFill[](1);
        context.input.fills[0] =
            ScatterOfferer.ScatterFill({itemIndex: 0, tokenId: p.fillTokenId, quantity: p.fillQuantity});
        context.input.criteriaProofs = new bytes32[][](0);

        context.fillData.signer = p.signer;
        context.fillData.submissionHash = keccak256(abi.encode(p.role, p.signer, p.totalFillPrice));
        context.fillData.totalFillPrice = p.totalFillPrice;

        context.fillFees = new ScatterOfferer.FillFeeData[](1);
        context.fillFees[0] = ScatterOfferer.FillFeeData({
            rewardsRecipient: p.rewardsRecipient,
            totalPrice: p.totalFillPrice,
            fees: ScatterOfferer.Fees({
                sellerAmount: p.sellerAmount,
                platformAmount: p.platformAmount,
                rewardsAmount: p.rewardsAmount,
                affiliateAmount: p.affiliateAmount
            })
        });

        context.totalFees.sellerAmount = p.sellerAmount;
        context.totalFees.platformAmount = p.platformAmount;
        context.totalFees.affiliateAmount = p.affiliateAmount;
    }

    function _encodeContextWithAuth(
        ScatterOfferer.ScatterSubmission memory submission,
        bytes memory signature,
        address fillAffiliate,
        ScatterOfferer.ScatterFill[] memory fills,
        bytes32[][] memory criteriaProofs,
        uint256 feeAuthorizationDeadline,
        bytes memory feeAuthorizationSignature
    ) internal pure returns (bytes memory context) {
        context = abi.encode(
            submission,
            signature,
            fillAffiliate,
            fills,
            criteriaProofs,
            feeAuthorizationDeadline,
            feeAuthorizationSignature
        );
    }

    function _feeAuthSig(
        address fulfiller,
        address authAffiliate,
        bytes32 submissionHash,
        ScatterOfferer.ScatterFill[] memory fills,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _feeAuthSigFor(fulfiller, authAffiliate, submissionHash, fills, deadline, FEE_AUTHORIZER_PK);
    }

    function _feeAuthSigFor(
        address fulfiller,
        address authAffiliate,
        bytes32 submissionHash,
        ScatterOfferer.ScatterFill[] memory fills,
        uint256 deadline,
        uint256 signerPk
    ) internal view returns (bytes memory) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Scatter Marketplace"),
                keccak256("1"),
                block.chainid,
                address(subject)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "FeeAuthorization(address fulfiller,address affiliate,bytes32 submissionHash,bytes32 fillsHash,uint256 deadline)"
                ),
                fulfiller,
                authAffiliate,
                submissionHash,
                keccak256(abi.encode(fills)),
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(signerPk, keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _signListing(ScatterOfferer.ScatterSubmission memory listing, uint256 pk)
        internal
        view
        returns (bytes memory signature)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, subject.hashSubmission(listing));
        signature = abi.encodePacked(r, s, v);
    }

    function _generateBid() internal view returns (ScatterOfferer.ScatterSubmission memory bid) {
        bid.role = ScatterOfferer.Role.Bid;
        bid.listings = new ScatterOfferer.ScatterListing[](1);
        bid.listings[0].assetType = ScatterOfferer.AssetType.ERC721;
        bid.listings[0].collection = address(nft721);
        bid.listings[0].tokenId = 0;
        bid.criteriaRoot = bytes32(0);
        bid.listings[0].quantity = 1;
        bid.listings[0].currency = address(weth);
        bid.listings[0].priceWei = 1 ether;
        bid.maxFeeBps = 500;
        bid.startTime = block.timestamp;
        bid.endTime = block.timestamp + 1 hours;
        bid.nonce = 0;
        bid.salt = bytes32(uint256(0xface));
    }

    function _generateTwoItemBid() internal view returns (ScatterOfferer.ScatterSubmission memory bid) {
        bid = _generateBid();
        bid.listings = new ScatterOfferer.ScatterListing[](2);
        bid.listings[0] = ScatterOfferer.ScatterListing({
            assetType: ScatterOfferer.AssetType.ERC721,
            collection: address(nft721),
            tokenId: 0,
            quantity: 1,
            currency: address(weth),
            priceWei: 1 ether
        });
        bid.listings[1] = ScatterOfferer.ScatterListing({
            assetType: ScatterOfferer.AssetType.ERC721,
            collection: address(nft721),
            tokenId: 0,
            quantity: 1,
            currency: address(weth),
            priceWei: 2 ether
        });
    }

    struct GenerateFillInputParams {
        ScatterOfferer.ScatterSubmission listing;
        bytes signature;
        uint256 fillTokenId;
        uint256 fillQuantity;
    }

    function _generateFillInput(GenerateFillInputParams memory p)
        internal
        pure
        returns (ScatterOfferer.SeaportFillInput memory input)
    {
        input.submission = p.listing;
        input.submissionSig = p.signature;
        input.affiliate = address(0);
        input.fills = new ScatterOfferer.ScatterFill[](1);
        input.fills[0] = ScatterOfferer.ScatterFill({itemIndex: 0, tokenId: p.fillTokenId, quantity: p.fillQuantity});
        input.criteriaProofs = new bytes32[][](0);
    }

    function _generateFillInput(
        ScatterOfferer.ScatterSubmission memory submission,
        bytes memory signature,
        ScatterOfferer.ScatterFill[] memory fills,
        bytes32[][] memory criteriaProofs
    ) internal pure returns (ScatterOfferer.SeaportFillInput memory input) {
        input.submission = submission;
        input.submissionSig = signature;
        input.affiliate = address(0);
        input.fills = fills;
        input.criteriaProofs = criteriaProofs;
    }

    function _encodeContext(
        ScatterOfferer.ScatterSubmission memory submission,
        bytes memory signature,
        address fillAffiliate,
        uint256 fillTokenId,
        uint256 fillQuantity,
        bytes32[] memory criteriaProof
    ) internal pure returns (bytes memory context) {
        ScatterOfferer.ScatterFill[] memory fills = new ScatterOfferer.ScatterFill[](1);
        fills[0] = ScatterOfferer.ScatterFill({itemIndex: 0, tokenId: fillTokenId, quantity: fillQuantity});

        bytes32[][] memory criteriaProofs = new bytes32[][](criteriaProof.length == 0 ? 0 : 1);
        if (criteriaProof.length != 0) {
            criteriaProofs[0] = criteriaProof;
        }

        context = abi.encode(submission, signature, fillAffiliate, fills, criteriaProofs, 0, "");
    }

    function _encodeContext(
        ScatterOfferer.ScatterSubmission memory submission,
        bytes memory signature,
        address fillAffiliate,
        ScatterOfferer.ScatterFill[] memory fills,
        bytes32[][] memory criteriaProofs
    ) internal pure returns (bytes memory context) {
        context = abi.encode(submission, signature, fillAffiliate, fills, criteriaProofs, 0, "");
    }

    struct GenerateListingParams {
        ScatterOfferer.AssetType assetType;
        address collection;
        uint256 tokenId;
        uint256 quantity;
        address currency;
        uint256 priceWei;
        uint256 startTime;
        uint256 endTime;
    }

    function _generateListing(GenerateListingParams memory p)
        internal
        pure
        returns (ScatterOfferer.ScatterSubmission memory listing)
    {
        listing.role = ScatterOfferer.Role.Listing;
        listing.listings = new ScatterOfferer.ScatterListing[](1);
        listing.listings[0].assetType = p.assetType;
        listing.listings[0].collection = p.collection;
        listing.listings[0].tokenId = p.tokenId;
        listing.criteriaRoot = bytes32(0);
        listing.listings[0].quantity = p.quantity;
        listing.listings[0].currency = p.currency;
        listing.listings[0].priceWei = p.priceWei;
        listing.maxFeeBps = 500;
        listing.startTime = p.startTime;
        listing.endTime = p.endTime;
        listing.nonce = 0;
        listing.salt = bytes32(uint256(0xdead));
    }

    function _generateListing() internal view returns (ScatterOfferer.ScatterSubmission memory listing) {
        listing = _generateListing(
            GenerateListingParams({
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 1,
                quantity: 1,
                currency: address(0),
                priceWei: 1 ether,
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours
            })
        );
    }

    function _generateTwoItemListing() internal view returns (ScatterOfferer.ScatterSubmission memory listing) {
        listing = _generateListing();
        listing.listings = new ScatterOfferer.ScatterListing[](2);
        listing.listings[0] = ScatterOfferer.ScatterListing({
            assetType: ScatterOfferer.AssetType.ERC721,
            collection: address(nft721),
            tokenId: 1,
            quantity: 1,
            currency: address(0),
            priceWei: 1 ether
        });
        listing.listings[1] = ScatterOfferer.ScatterListing({
            assetType: ScatterOfferer.AssetType.ERC721,
            collection: address(nft721),
            tokenId: 2,
            quantity: 1,
            currency: address(0),
            priceWei: 2 ether
        });
    }

    function _singleFill(uint256 itemIndex, uint256 tokenId, uint256 quantity)
        internal
        pure
        returns (ScatterOfferer.ScatterFill[] memory fills)
    {
        fills = new ScatterOfferer.ScatterFill[](1);
        fills[0] = ScatterOfferer.ScatterFill({itemIndex: itemIndex, tokenId: tokenId, quantity: quantity});
    }

    function _twoFills(
        uint256 firstItemIndex,
        uint256 firstTokenId,
        uint256 firstQuantity,
        uint256 secondItemIndex,
        uint256 secondTokenId,
        uint256 secondQuantity
    ) internal pure returns (ScatterOfferer.ScatterFill[] memory fills) {
        fills = new ScatterOfferer.ScatterFill[](2);
        fills[0] =
            ScatterOfferer.ScatterFill({itemIndex: firstItemIndex, tokenId: firstTokenId, quantity: firstQuantity});
        fills[1] =
            ScatterOfferer.ScatterFill({itemIndex: secondItemIndex, tokenId: secondTokenId, quantity: secondQuantity});
    }

    function _assertReceivedItem(
        ReceivedItem memory item,
        ItemType itemType,
        address token,
        uint256 identifier,
        uint256 amount,
        address recipient
    ) internal pure {
        assertEq(uint8(item.itemType), uint8(itemType));
        assertEq(item.token, token);
        assertEq(item.identifier, identifier);
        assertEq(item.amount, amount);
        assertEq(item.recipient, recipient);
    }

    function _singleCancelItem(bytes32 submissionHash)
        internal
        pure
        returns (ScatterOfferer.CancelListingItem[] memory items)
    {
        items = new ScatterOfferer.CancelListingItem[](1);
        items[0] = ScatterOfferer.CancelListingItem({submissionHash: submissionHash, itemIndex: 0});
    }

    function _prank(address actor) internal {
        vm.stopPrank();
        vm.startPrank(actor);
    }
}

// supporting mock contracts

contract MockERC721 is ERC721 {
    constructor() ERC721("Mock", "M") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}

contract MockERC1155 is ERC1155 {
    constructor() ERC1155("") {}

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }
}

contract ScatterOffererWrapperExposingInternalMethods is ScatterOfferer {
    constructor(
        address initialOwner,
        ScatterCollectionRegistry scatterCollectionRegistry_,
        address initialFeeAuthorizer,
        bytes32 conduitKey_
    ) ScatterOfferer(initialOwner, scatterCollectionRegistry_, initialFeeAuthorizer, conduitKey_) {}

    function internal__computeListingFee(uint256 listingPrice, address affiliate, address rewardsRecipient)
        external
        view
        returns (Fees memory)
    {
        return _computeListingFee(listingPrice, affiliate, rewardsRecipient);
    }

    function internal__emitScatterSale(SeaportOrderContext memory context, address requester) external {
        _emitScatterSale(context, requester);
    }

    function internal__distributeFeesErc20(SeaportOrderContext memory context) external {
        _distributeFeesErc20(context);
    }

    function internal__pullAndApproveErc20(SeaportOrderContext memory context) external {
        _pullAndApproveErc20(context);
    }

    function internal__pullAndApproveNft(SeaportOrderContext memory context) external {
        _pullAndApproveNft(context);
    }

    function internal__buildConsiderationArrayBid(SeaportOrderContext memory context)
        external
        pure
        returns (ReceivedItem[] memory)
    {
        return _buildConsiderationArrayBid(context);
    }

    function internal__buildConsiderationArrayListing(SeaportOrderContext memory context)
        external
        pure
        returns (ReceivedItem[] memory)
    {
        return _buildConsiderationArrayListing(context);
    }

    function internal__buildSeaportArraysBid(SeaportOrderContext memory context)
        external
        pure
        returns (SpentItem[] memory, ReceivedItem[] memory)
    {
        return _buildSeaportArraysBid(context);
    }

    function _cheat_alterFilledQuantity(address signer, ScatterSubmission memory submission, uint256 quantity)
        external
    {
        filledListingQuantity[signer][_hashSubmission(submission)][0] = quantity;
    }

    function _cheat_alterFilledQuantity(
        address signer,
        ScatterSubmission memory submission,
        uint256 itemIndex,
        uint256 quantity
    ) external {
        filledListingQuantity[signer][_hashSubmission(submission)][itemIndex] = quantity;
    }

    function internal__computeFillData(SeaportFillInput memory input) external view returns (ValidatedFillData memory) {
        return _computeFillData(input);
    }
}

/**
 *  Stands in for ScatterAggregatorRouter's attribution surface: the
 * offerer staticcalls activeRoutedFulfiller() on trusted routers.
 */
contract RoutedFulfillerProviderMock {
    address public activeRoutedFulfiller;

    function setActiveRoutedFulfiller(address fulfiller) external {
        activeRoutedFulfiller = fulfiller;
    }
}

contract ReturnFalseERC20 {
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}

contract ReturnFalseOnSecondCallERC20 {
    uint256 private _calls;

    function transfer(address, uint256) external returns (bool) {
        _calls++;
        return _calls < 2;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    // transferFrom succeeds; approve (second distinct call) returns false
    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }

    function approve(address, uint256) external pure returns (bool) {
        return false;
    }
}

contract ReturnFalseOnThirdCallERC20 {
    uint256 private _calls;

    function transfer(address, uint256) external returns (bool) {
        _calls++;
        return _calls < 3;
    }
}
