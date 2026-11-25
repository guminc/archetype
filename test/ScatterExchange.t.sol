// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {ScatterExchange} from "../src/ScatterExchange.sol";
import {ScatterCollectionRegistry} from "../src/ScatterCollectionRegistry.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract ScatterExchangeTest is Test {
    uint256 internal constant SELLER_PK = uint256(keccak256("seller"));
    uint256 internal constant SECOND_SELLER_PK = uint256(keccak256("secondSeller"));
    uint256 internal constant BIDDER_PK = uint256(keccak256("bidder"));
    uint256 internal constant FEE_AUTHORIZER_PK = 0xA11CE;

    ScatterExchange internal subject;

    ScatterCollectionRegistry internal registry;
    ExchangeTestErc721 internal nft721;
    ExchangeTestErc1155 internal nft1155;
    ExchangeTestErc20 internal weth;

    address internal owner = makeAddr("owner");
    address internal seller = vm.addr(SELLER_PK);
    address internal secondSeller = vm.addr(SECOND_SELLER_PK);
    address internal bidder = vm.addr(BIDDER_PK);
    address internal buyer = makeAddr("buyer");
    address internal recipient = makeAddr("recipient");
    address internal rewardsRecipient = makeAddr("rewardsRecipient");
    address internal affiliate = makeAddr("affiliate");
    address internal other = makeAddr("other");
    address internal platform;

    struct Balances {
        uint256 buyer;
        uint256 seller;
        uint256 platform;
        uint256 rewards;
        uint256 affiliate;
    }

    function setUp() public {
        vm.txGasPrice(0);

        registry = new ScatterCollectionRegistry(address(this));
        subject = new ScatterExchange(owner, registry, vm.addr(FEE_AUTHORIZER_PK));
        platform = subject.PLATFORM();

        nft721 = new ExchangeTestErc721();
        nft1155 = new ExchangeTestErc1155();
        weth = new ExchangeTestErc20();

        nft721.mint(seller, 1);
        nft721.mint(seller, 2);
        nft721.mint(secondSeller, 3);
        nft1155.mint(seller, 1, 10);
        weth.mint(buyer, 100 ether);
        weth.mint(bidder, 100 ether);
        vm.deal(buyer, 100 ether);

        _prank(seller);
        nft721.setApprovalForAll(address(subject), true);
        nft1155.setApprovalForAll(address(subject), true);
        _prank(secondSeller);
        nft721.setApprovalForAll(address(subject), true);
        _prank(buyer);
        weth.approve(address(subject), type(uint256).max);
        _prank(bidder);
        weth.approve(address(subject), type(uint256).max);

        _prank(other);
    }

    function test_buyListings_nativeSaleSplitsFeeBetweenPlatformAndRewards() public {
        registry_setRewards(address(nft721), rewardsRecipient);
        ScatterExchange.ScatterSubmission memory submission = _listing721(1, address(0), 1 ether);
        ScatterExchange.FillInput[] memory inputs = _single(_input(submission, SELLER_PK, 1, 1));
        Balances memory beforeBalances = _nativeBalances();

        vm.expectEmit(true, true, true, true, address(subject));
        emit ScatterExchange.ScatterSale({
            submissionHash: subject.hashSubmission(submission),
            role: uint8(ScatterExchange.Role.Listing),
            seller: seller,
            buyer: buyer,
            collection: address(nft721),
            itemIndex: 0,
            tokenId: 1,
            quantity: 1,
            currency: address(0),
            totalPrice: 1 ether,
            affiliate: address(0),
            rewardsRecipient: rewardsRecipient,
            sellerAmount: 0.95 ether,
            platformAmount: 0.025 ether,
            rewardsAmount: 0.025 ether,
            affiliateAmount: 0
        });
        _prank(buyer);
        subject.buyListings{value: 1 ether}(inputs, buyer, address(0), 0, "");

        Balances memory afterBalances = _nativeBalances();
        assertEq(nft721.ownerOf(1), buyer);
        assertEq(beforeBalances.buyer - afterBalances.buyer, 1 ether);
        assertEq(afterBalances.seller - beforeBalances.seller, 0.95 ether);
        assertEq(afterBalances.platform - beforeBalances.platform, 0.025 ether);
        assertEq(afterBalances.rewards - beforeBalances.rewards, 0.025 ether);
        assertEq(address(subject).balance, 0);
    }

    function test_buyListings_erc20SaleWithAffiliatePaysAffiliateInsteadOfRewards() public {
        registry_setRewards(address(nft721), rewardsRecipient);
        ScatterExchange.FillInput[] memory inputs =
            _single(_input(_listing721(1, address(weth), 2 ether), SELLER_PK, 1, 1));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory authorization = _authorize(buyer, affiliate, inputs, deadline);
        Balances memory beforeBalances = _wethBalances();

        _prank(buyer);
        subject.buyListings(inputs, buyer, affiliate, deadline, authorization);

        Balances memory afterBalances = _wethBalances();
        assertEq(nft721.ownerOf(1), buyer);
        assertEq(beforeBalances.buyer - afterBalances.buyer, 2 ether);
        assertEq(afterBalances.seller - beforeBalances.seller, 1.9 ether);
        assertEq(afterBalances.platform - beforeBalances.platform, 0.05 ether);
        assertEq(afterBalances.affiliate - beforeBalances.affiliate, 0.05 ether);
        assertEq(afterBalances.rewards, beforeBalances.rewards);
        assertEq(weth.balanceOf(address(subject)), 0);
    }

    function testFuzz_buyListings_buyerPaysExactlyThePriceAndRecipientsReceiveAllOfIt(
        uint96 price,
        uint16 feeBps,
        uint16 feeSplitBps,
        bool hasRewards,
        bool hasAffiliate
    ) public {
        feeBps = uint16(bound(feeBps, 0, subject.MAX_FEE_BPS()));
        feeSplitBps = uint16(bound(feeSplitBps, 0, subject.BPS_DENOMINATOR()));
        _prank(owner);
        subject.setFeeBps(feeBps);
        subject.setFeeSplitBps(feeSplitBps);
        if (hasRewards) registry_setRewards(address(nft721), rewardsRecipient);
        vm.deal(buyer, price);

        ScatterExchange.ScatterSubmission memory submission = _listing721(1, address(0), price);
        submission.maxFeeBps = feeBps;
        ScatterExchange.FillInput[] memory inputs = _single(_input(submission, SELLER_PK, 1, 1));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory authorization = hasAffiliate ? _authorize(buyer, affiliate, inputs, deadline) : bytes("");
        Balances memory beforeBalances = _nativeBalances();

        _prank(buyer);
        subject.buyListings{value: price}(inputs, buyer, hasAffiliate ? affiliate : address(0), deadline, authorization);

        Balances memory afterBalances = _nativeBalances();
        uint256 sellerReceived = afterBalances.seller - beforeBalances.seller;
        uint256 feeReceived = (afterBalances.platform - beforeBalances.platform)
            + (afterBalances.rewards - beforeBalances.rewards) + (afterBalances.affiliate - beforeBalances.affiliate);
        assertEq(beforeBalances.buyer - afterBalances.buyer, price);
        assertEq(sellerReceived + feeReceived, price);
        assertLe(feeReceived, uint256(price) * feeBps / 10_000);
        if (hasAffiliate) assertEq(afterBalances.rewards, beforeBalances.rewards);
        if (!hasAffiliate) assertEq(afterBalances.affiliate, beforeBalances.affiliate);
        assertEq(address(subject).balance, 0);
    }

    function test_buyListings_fillsSeveralSellersInOneCallAndSendsNftsToRecipient() public {
        ScatterExchange.FillInput[] memory inputs = new ScatterExchange.FillInput[](2);
        inputs[0] = _input(_listing1155(1, 10, address(0), 0.1 ether), SELLER_PK, 1, 3);
        inputs[1] = _input(_listing721(3, address(0), 1 ether), SECOND_SELLER_PK, 3, 1);
        uint256 sellerBefore = seller.balance;
        uint256 secondSellerBefore = secondSeller.balance;

        _prank(buyer);
        subject.buyListings{value: 1.3 ether}(inputs, recipient, address(0), 0, "");

        assertEq(nft1155.balanceOf(recipient, 1), 3);
        assertEq(nft1155.balanceOf(seller, 1), 7);
        assertEq(nft721.ownerOf(3), recipient);
        assertEq(seller.balance - sellerBefore, 0.285 ether);
        assertEq(secondSeller.balance - secondSellerBefore, 0.95 ether);
    }

    function test_buyListings_failsWhenNativeValueDiffersFromTheListingPrices(bool overpays) public {
        ScatterExchange.FillInput[] memory inputs =
            _single(_input(_listing721(1, address(0), 1 ether), SELLER_PK, 1, 1));
        uint256 sent = overpays ? 1 ether + 1 : 1 ether - 1;

        _prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ScatterExchange.InvalidNativeValue.selector, sent, 1 ether));
        subject.buyListings{value: sent}(inputs, buyer, address(0), 0, "");

        assertEq(nft721.ownerOf(1), seller);
    }

    function test_buyListings_partiallyFillsErc1155UntilTheSignedQuantityIsSold() public {
        ScatterExchange.ScatterSubmission memory submission = _listing1155(1, 5, address(0), 0.1 ether);
        _prank(buyer);

        subject.buyListings{value: 0.2 ether}(_single(_input(submission, SELLER_PK, 1, 2)), buyer, address(0), 0, "");
        subject.buyListings{value: 0.3 ether}(_single(_input(submission, SELLER_PK, 1, 3)), buyer, address(0), 0, "");

        assertEq(nft1155.balanceOf(buyer, 1), 5);
        (,, uint256 filled, uint256 remaining) = subject.listingStatus(seller, submission, 0);
        assertEq(filled, 5);
        assertEq(remaining, 0);
        ScatterExchange.FillInput[] memory oneMore = _single(_input(submission, SELLER_PK, 1, 1));
        vm.expectRevert(ScatterExchange.QuantityExceeded.selector);
        subject.buyListings{value: 0.1 ether}(oneMore, buyer, address(0), 0, "");
    }

    function test_buyListings_failsWhenSellerCancelledTheItem() public {
        ScatterExchange.ScatterSubmission memory submission = _listing721(1, address(0), 1 ether);
        ScatterExchange.FillInput[] memory inputs = _single(_input(submission, SELLER_PK, 1, 1));
        ScatterExchange.CancelListingItem[] memory cancellations = new ScatterExchange.CancelListingItem[](1);
        cancellations[0] =
            ScatterExchange.CancelListingItem({submissionHash: subject.hashSubmission(submission), itemIndex: 0});
        _prank(seller);
        subject.cancelListings(cancellations);

        _prank(buyer);
        vm.expectRevert(ScatterExchange.OrderCancelled.selector);
        subject.buyListings{value: 1 ether}(inputs, buyer, address(0), 0, "");
    }

    function test_buyListings_failsWhenSellerIncrementedTheirCounter() public {
        ScatterExchange.FillInput[] memory inputs =
            _single(_input(_listing721(1, address(0), 1 ether), SELLER_PK, 1, 1));
        _prank(seller);
        subject.incrementCounter();

        _prank(buyer);
        vm.expectRevert(ScatterExchange.NonceMismatch.selector);
        subject.buyListings{value: 1 ether}(inputs, buyer, address(0), 0, "");
    }

    function test_buyListings_failsWhenOutsideTheSignedTimeWindow() public {
        ScatterExchange.FillInput[] memory inputs =
            _single(_input(_listing721(1, address(0), 1 ether), SELLER_PK, 1, 1));
        vm.warp(block.timestamp + 1 hours);

        _prank(buyer);
        vm.expectRevert(ScatterExchange.OrderExpired.selector);
        subject.buyListings{value: 1 ether}(inputs, buyer, address(0), 0, "");
    }

    function test_buyListings_failsWhenFeeRisesAboveTheSellersSignedMaximum() public {
        ScatterExchange.FillInput[] memory inputs =
            _single(_input(_listing721(1, address(0), 1 ether), SELLER_PK, 1, 1));
        _prank(owner);
        subject.setFeeBps(600);

        _prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ScatterExchange.FeeBpsExceedsLimit.selector, 600, 500));
        subject.buyListings{value: 1 ether}(inputs, buyer, address(0), 0, "");
    }

    function test_buyListings_failsWhenSubmissionWasSignedForAnotherExchange() public {
        ScatterExchange otherExchange = new ScatterExchange(owner, registry, vm.addr(FEE_AUTHORIZER_PK));
        ScatterExchange.ScatterSubmission memory submission = _listing721(1, address(0), 1 ether);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SELLER_PK, otherExchange.hashSubmission(submission));
        ScatterExchange.FillInput[] memory inputs = _single(
            ScatterExchange.FillInput({
                submission: submission,
                submissionSig: abi.encodePacked(r, s, v),
                fills: _fills(1, 1),
                criteriaProofs: new bytes32[][](0)
            })
        );

        _prank(buyer);
        vm.expectPartialRevert(IERC721Errors.ERC721IncorrectOwner.selector);
        subject.buyListings{value: 1 ether}(inputs, buyer, address(0), 0, "");

        assertEq(nft721.ownerOf(1), seller);
    }

    function test_buyListings_failsWhenAffiliateAuthorizationIsForAnotherCallerOrOtherInputs() public {
        ScatterExchange.FillInput[] memory inputs =
            _single(_input(_listing721(1, address(0), 1 ether), SELLER_PK, 1, 1));
        ScatterExchange.FillInput[] memory otherInputs =
            _single(_input(_listing721(2, address(0), 1 ether), SELLER_PK, 2, 1));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory forOtherCaller = _authorize(other, affiliate, inputs, deadline);
        bytes memory forOtherInputs = _authorize(buyer, affiliate, otherInputs, deadline);
        _prank(buyer);

        vm.expectRevert(ScatterExchange.InvalidFeeAuthorization.selector);
        subject.buyListings{value: 1 ether}(inputs, buyer, affiliate, deadline, forOtherCaller);
        vm.expectRevert(ScatterExchange.InvalidFeeAuthorization.selector);
        subject.buyListings{value: 1 ether}(inputs, buyer, affiliate, deadline, forOtherInputs);
        vm.expectRevert(ScatterExchange.InvalidFeeAuthorization.selector);
        subject.buyListings{value: 1 ether}(inputs, buyer, address(0), deadline, forOtherCaller);
    }

    function test_buyListings_failsWhenAFeeRecipientRejectsNativePayment() public {
        address rejecting = address(new RejectsNative());
        registry_setRewards(address(nft721), rejecting);
        ScatterExchange.FillInput[] memory inputs =
            _single(_input(_listing721(1, address(0), 1 ether), SELLER_PK, 1, 1));
        uint256 sellerBefore = seller.balance;

        _prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ScatterExchange.NativeTransferFailed.selector,
                rejecting,
                abi.encodeWithSignature("Error(string)", "no native")
            )
        );
        subject.buyListings{value: 1 ether}(inputs, buyer, address(0), 0, "");

        assertEq(nft721.ownerOf(1), seller);
        assertEq(seller.balance, sellerBefore);
    }

    function test_buyListings_failsWhenPausedUntilUnpaused() public {
        ScatterExchange.FillInput[] memory inputs =
            _single(_input(_listing721(1, address(0), 1 ether), SELLER_PK, 1, 1));
        _prank(owner);
        subject.pause();

        _prank(buyer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        subject.buyListings{value: 1 ether}(inputs, buyer, address(0), 0, "");

        _prank(owner);
        subject.unpause();
        _prank(buyer);
        subject.buyListings{value: 1 ether}(inputs, buyer, address(0), 0, "");
        assertEq(nft721.ownerOf(1), buyer);
    }

    function test_buyListings_failsWhenSubmissionIsABid() public {
        ScatterExchange.FillInput[] memory inputs = _single(_input(_bid721(0, 1, bytes32(0), 1 ether), BIDDER_PK, 1, 1));

        _prank(seller);
        vm.expectRevert(ScatterExchange.InvalidRole.selector);
        subject.buyListings(inputs, seller, address(0), 0, "");
    }

    function test_sellIntoBids_sellsOnlyTokensInsideTheBiddersCriteria() public {
        registry_setRewards(address(nft721), rewardsRecipient);
        bytes32 leafOne = keccak256(abi.encode(uint256(1)));
        bytes32 leafThree = keccak256(abi.encode(uint256(3)));
        bytes32 root = leafOne < leafThree
            ? keccak256(abi.encodePacked(leafOne, leafThree))
            : keccak256(abi.encodePacked(leafThree, leafOne));
        ScatterExchange.ScatterSubmission memory submission = _bid721(0, 2, root, 1 ether);

        ScatterExchange.FillInput memory accepted = _input(submission, BIDDER_PK, 1, 1);
        accepted.criteriaProofs = new bytes32[][](1);
        accepted.criteriaProofs[0] = new bytes32[](1);
        accepted.criteriaProofs[0][0] = leafThree;
        ScatterExchange.FillInput memory outsideCriteria = _input(submission, BIDDER_PK, 2, 1);
        outsideCriteria.criteriaProofs = accepted.criteriaProofs;
        Balances memory beforeBalances = _wethBalances();
        uint256 bidderBefore = weth.balanceOf(bidder);

        _prank(seller);
        vm.expectRevert(ScatterExchange.InvalidCriteriaProof.selector);
        subject.sellIntoBids(_single(outsideCriteria), 500, address(0), 0, "");
        subject.sellIntoBids(_single(accepted), 500, address(0), 0, "");

        Balances memory afterBalances = _wethBalances();
        assertEq(nft721.ownerOf(1), bidder);
        assertEq(nft721.ownerOf(2), seller);
        assertEq(bidderBefore - weth.balanceOf(bidder), 1 ether);
        assertEq(afterBalances.seller - beforeBalances.seller, 0.95 ether);
        assertEq(afterBalances.platform - beforeBalances.platform, 0.025 ether);
        assertEq(afterBalances.rewards - beforeBalances.rewards, 0.025 ether);
    }

    function test_sellIntoBids_failsWhenFeeExceedsTheSellersMaximum() public {
        ScatterExchange.ScatterSubmission memory submission = _bid721(0, 1, bytes32(0), 1 ether);
        submission.maxFeeBps = 1000;
        ScatterExchange.FillInput[] memory inputs = _single(_input(submission, BIDDER_PK, 1, 1));
        _prank(owner);
        subject.setFeeBps(1000);

        _prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ScatterExchange.FeeBpsExceedsLimit.selector, 1000, 500));
        subject.sellIntoBids(inputs, 500, address(0), 0, "");
    }

    function test_sellIntoBids_failsWhenSubmissionIsAListing() public {
        ScatterExchange.FillInput[] memory inputs =
            _single(_input(_listing721(1, address(weth), 1 ether), SELLER_PK, 1, 1));

        _prank(buyer);
        vm.expectRevert(ScatterExchange.InvalidRole.selector);
        subject.sellIntoBids(inputs, 500, address(0), 0, "");
    }

    function test_sellIntoBids_failsWhenBidIsInNativeCurrency() public {
        ScatterExchange.ScatterSubmission memory submission = _bid721(0, 1, bytes32(0), 1 ether);
        submission.listings[0].currency = address(0);
        ScatterExchange.FillInput[] memory inputs = _single(_input(submission, BIDDER_PK, 1, 1));

        _prank(seller);
        vm.expectRevert(ScatterExchange.CurrencyMismatch.selector);
        subject.sellIntoBids(inputs, 500, address(0), 0, "");
    }

    function test_setTrustedRouter_onlyOwnerAndRejectsZeroAddress() public {
        address router = makeAddr("router");

        _prank(other);
        vm.expectRevert();
        subject.setTrustedRouter(router, true);

        _prank(owner);
        vm.expectRevert(ScatterExchange.InvalidRouter.selector);
        subject.setTrustedRouter(address(0), true);

        vm.expectEmit(true, false, false, true, address(subject));
        emit ScatterExchange.TrustedRouterUpdated(router, true);
        subject.setTrustedRouter(router, true);
        assertTrue(subject.trustedRouters(router));

        subject.setTrustedRouter(router, false);
        assertFalse(subject.trustedRouters(router));
    }

    function test_buyListings_trustedRouterAttributesBuyerAndAuthorizesAffiliateWhilePayingItself() public {
        MockExchangeRouter router = new MockExchangeRouter();
        _prank(owner);
        subject.setTrustedRouter(address(router), true);

        // Native routed buy with affiliate bound to `buyer`, not `router`.
        ScatterExchange.ScatterSubmission memory nativeListing = _listing721(1, address(0), 1 ether);
        ScatterExchange.FillInput[] memory nativeInputs = _single(_input(nativeListing, SELLER_PK, 1, 1));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory buyerAuth = _authorize(buyer, affiliate, nativeInputs, deadline);
        bytes memory routerAuth = _authorize(address(router), affiliate, nativeInputs, deadline);

        vm.deal(address(router), 1 ether);
        router.setActiveRoutedFulfiller(buyer);

        _prank(address(router));
        vm.expectRevert(ScatterExchange.InvalidFeeAuthorization.selector);
        subject.buyListings{value: 1 ether}(nativeInputs, recipient, affiliate, deadline, routerAuth);

        vm.expectEmit(true, true, true, true, address(subject));
        emit ScatterExchange.ScatterSale({
            submissionHash: subject.hashSubmission(nativeListing),
            role: uint8(ScatterExchange.Role.Listing),
            seller: seller,
            buyer: buyer,
            collection: address(nft721),
            itemIndex: 0,
            tokenId: 1,
            quantity: 1,
            currency: address(0),
            totalPrice: 1 ether,
            affiliate: affiliate,
            rewardsRecipient: address(0),
            sellerAmount: 0.95 ether,
            platformAmount: 0.025 ether,
            rewardsAmount: 0,
            affiliateAmount: 0.025 ether
        });
        subject.buyListings{value: 1 ether}(nativeInputs, recipient, affiliate, deadline, buyerAuth);
        assertEq(nft721.ownerOf(1), recipient);

        // ERC20 routed buy pulls payment from `router` (`msg.sender`), leaving `buyer`'s balance untouched.
        ScatterExchange.ScatterSubmission memory erc20Listing = _listing721(2, address(weth), 2 ether);
        ScatterExchange.FillInput[] memory erc20Inputs = _single(_input(erc20Listing, SELLER_PK, 2, 1));
        weth.mint(address(router), 2 ether);
        _prank(address(router));
        weth.approve(address(subject), 2 ether);
        uint256 buyerWethBefore = weth.balanceOf(buyer);

        subject.buyListings(erc20Inputs, recipient, address(0), 0, "");

        assertEq(nft721.ownerOf(2), recipient);
        assertEq(weth.balanceOf(address(router)), 0);
        assertEq(weth.balanceOf(buyer), buyerWethBefore);
    }

    function test_buyListings_revertsWhenTrustedRouterReturnsZeroOrHasNoGetter() public {
        MockExchangeRouter router = new MockExchangeRouter();
        address noGetterRouter = makeAddr("noGetterRouter");
        _prank(owner);
        subject.setTrustedRouter(address(router), true);
        subject.setTrustedRouter(noGetterRouter, true);

        ScatterExchange.FillInput[] memory inputs =
            _single(_input(_listing721(1, address(0), 1 ether), SELLER_PK, 1, 1));
        vm.deal(address(router), 1 ether);
        vm.deal(noGetterRouter, 1 ether);

        _prank(address(router));
        vm.expectRevert(ScatterExchange.InvalidRoutedFulfiller.selector);
        subject.buyListings{value: 1 ether}(inputs, buyer, address(0), 0, "");

        _prank(noGetterRouter);
        vm.expectRevert(ScatterExchange.InvalidRoutedFulfiller.selector);
        subject.buyListings{value: 1 ether}(inputs, buyer, address(0), 0, "");
    }

    function test_buyListings_untrustedRouterDoesNotSpoofBuyer() public {
        MockExchangeRouter router = new MockExchangeRouter();
        router.setActiveRoutedFulfiller(buyer);
        ScatterExchange.ScatterSubmission memory submission = _listing721(1, address(0), 1 ether);
        ScatterExchange.FillInput[] memory inputs = _single(_input(submission, SELLER_PK, 1, 1));
        vm.deal(address(router), 1 ether);

        vm.expectEmit(true, true, true, true, address(subject));
        emit ScatterExchange.ScatterSale({
            submissionHash: subject.hashSubmission(submission),
            role: uint8(ScatterExchange.Role.Listing),
            seller: seller,
            buyer: address(router),
            collection: address(nft721),
            itemIndex: 0,
            tokenId: 1,
            quantity: 1,
            currency: address(0),
            totalPrice: 1 ether,
            affiliate: address(0),
            rewardsRecipient: address(0),
            sellerAmount: 0.95 ether,
            platformAmount: 0.05 ether,
            rewardsAmount: 0,
            affiliateAmount: 0
        });
        _prank(address(router));
        subject.buyListings{value: 1 ether}(inputs, buyer, address(0), 0, "");
    }

    function test_sellIntoBids_trustedRouterCannotSellAnotherWalletsNft() public {
        MockExchangeRouter router = new MockExchangeRouter();
        router.setActiveRoutedFulfiller(seller);
        _prank(owner);
        subject.setTrustedRouter(address(router), true);

        ScatterExchange.FillInput[] memory inputs = _single(_input(_bid721(0, 1, bytes32(0), 1 ether), BIDDER_PK, 1, 1));

        _prank(address(router));
        vm.expectPartialRevert(IERC721Errors.ERC721IncorrectOwner.selector);
        subject.sellIntoBids(inputs, 500, address(0), 0, "");
        assertEq(nft721.ownerOf(1), seller);
    }

    function test_buyListings_rejectsExchangeAsRecipient() public {
        ScatterExchange.FillInput[] memory inputs =
            _single(_input(_listing721(1, address(0), 1 ether), SELLER_PK, 1, 1));

        _prank(buyer);
        vm.expectRevert(ScatterExchange.InvalidRecipient.selector);
        subject.buyListings{value: 1 ether}(inputs, address(subject), address(0), 0, "");
    }

    function test_buyListings_affiliateSkipsRewardsRecipientLookup() public {
        ScatterExchange.FillInput[] memory inputs =
            _single(_input(_listing721(1, address(0), 1 ether), SELLER_PK, 1, 1));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _authorize(buyer, affiliate, inputs, deadline);

        vm.expectCall(address(registry), abi.encodeWithSelector(ScatterCollectionRegistry.rewardsRecipient.selector), 0);
        _prank(buyer);
        subject.buyListings{value: 1 ether}(inputs, buyer, affiliate, deadline, sig);

        assertEq(platform.balance, 0.025 ether);
        assertEq(affiliate.balance, 0.025 ether);
    }

    function test_buyListings_freezesFeeRatesAtEntryAcrossBatch() public {
        FeeMutatingErc1155Receiver receiver = new FeeMutatingErc1155Receiver(subject, 2000, 1000);
        _prank(owner);
        subject.transferOwnership(address(receiver));
        receiver.acceptOwnership();
        nft1155.mint(seller, 10, 2);

        ScatterExchange.ScatterSubmission memory first = _listing1155(10, 1, address(0), 1 ether);
        ScatterExchange.ScatterSubmission memory second = _listing1155(10, 1, address(0), 1 ether);
        second.salt = bytes32(uint256(999));

        ScatterExchange.FillInput[] memory inputs = new ScatterExchange.FillInput[](2);
        inputs[0] = _input(first, SELLER_PK, 10, 1);
        inputs[1] = _input(second, SELLER_PK, 10, 1);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _authorize(buyer, affiliate, inputs, deadline);

        _prank(buyer);
        subject.buyListings{value: 2 ether}(inputs, address(receiver), affiliate, deadline, sig);

        assertEq(subject.feeBps(), 2000);
        assertEq(subject.feeSplitBps(), 1000);
        // Both fills settle at the entry-snapshotted 5% fee / 50-50 split (0.05 ETH platform, 0.05 ETH affiliate total).
        assertEq(seller.balance, 1.9 ether);
        assertEq(platform.balance, 0.05 ether);
        assertEq(affiliate.balance, 0.05 ether);
    }

    function _prank(address actor) internal {
        vm.stopPrank();
        vm.startPrank(actor);
    }

    function registry_setRewards(address collection, address to) internal {
        _prank(address(this));
        registry.setRewardsOverride(collection, to);
        _prank(other);
    }

    function _submission(ScatterExchange.Role role, ScatterExchange.ScatterListing memory item, bytes32 criteriaRoot)
        internal
        view
        returns (ScatterExchange.ScatterSubmission memory submission)
    {
        submission.role = role;
        submission.listings = new ScatterExchange.ScatterListing[](1);
        submission.listings[0] = item;
        submission.criteriaRoot = criteriaRoot;
        submission.maxFeeBps = 500;
        submission.startTime = block.timestamp;
        submission.endTime = block.timestamp + 1 hours;
        submission.salt = bytes32(item.tokenId);
    }

    function _listing721(uint256 tokenId, address currency, uint256 price)
        internal
        view
        returns (ScatterExchange.ScatterSubmission memory)
    {
        return _submission(
            ScatterExchange.Role.Listing,
            ScatterExchange.ScatterListing({
                assetType: ScatterExchange.AssetType.ERC721,
                collection: address(nft721),
                tokenId: tokenId,
                quantity: 1,
                currency: currency,
                priceWei: price
            }),
            bytes32(0)
        );
    }

    function _listing1155(uint256 tokenId, uint256 quantity, address currency, uint256 unitPrice)
        internal
        view
        returns (ScatterExchange.ScatterSubmission memory)
    {
        return _submission(
            ScatterExchange.Role.Listing,
            ScatterExchange.ScatterListing({
                assetType: ScatterExchange.AssetType.ERC1155,
                collection: address(nft1155),
                tokenId: tokenId,
                quantity: quantity,
                currency: currency,
                priceWei: unitPrice
            }),
            bytes32(0)
        );
    }

    function _bid721(uint256 tokenId, uint256 quantity, bytes32 criteriaRoot, uint256 price)
        internal
        view
        returns (ScatterExchange.ScatterSubmission memory)
    {
        return _submission(
            ScatterExchange.Role.Bid,
            ScatterExchange.ScatterListing({
                assetType: ScatterExchange.AssetType.ERC721,
                collection: address(nft721),
                tokenId: tokenId,
                quantity: quantity,
                currency: address(weth),
                priceWei: price
            }),
            criteriaRoot
        );
    }

    function _input(
        ScatterExchange.ScatterSubmission memory submission,
        uint256 signerPk,
        uint256 fillTokenId,
        uint256 fillQuantity
    ) internal view returns (ScatterExchange.FillInput memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, subject.hashSubmission(submission));
        return ScatterExchange.FillInput({
            submission: submission,
            submissionSig: abi.encodePacked(r, s, v),
            fills: _fills(fillTokenId, fillQuantity),
            criteriaProofs: new bytes32[][](0)
        });
    }

    function _fills(uint256 tokenId, uint256 quantity)
        internal
        pure
        returns (ScatterExchange.ScatterFill[] memory fills)
    {
        fills = new ScatterExchange.ScatterFill[](1);
        fills[0] = ScatterExchange.ScatterFill({itemIndex: 0, tokenId: tokenId, quantity: quantity});
    }

    function _single(ScatterExchange.FillInput memory input)
        internal
        pure
        returns (ScatterExchange.FillInput[] memory inputs)
    {
        inputs = new ScatterExchange.FillInput[](1);
        inputs[0] = input;
    }

    function _authorize(
        address fulfiller,
        address affiliate_,
        ScatterExchange.FillInput[] memory inputs,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Scatter Exchange"),
                keccak256("1"),
                block.chainid,
                address(subject)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                subject.FEE_AUTHORIZATION_TYPEHASH(), fulfiller, affiliate_, keccak256(abi.encode(inputs)), deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(FEE_AUTHORIZER_PK, keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _nativeBalances() internal view returns (Balances memory) {
        return Balances({
            buyer: buyer.balance,
            seller: seller.balance,
            platform: platform.balance,
            rewards: rewardsRecipient.balance,
            affiliate: affiliate.balance
        });
    }

    function _wethBalances() internal view returns (Balances memory) {
        return Balances({
            buyer: weth.balanceOf(buyer),
            seller: weth.balanceOf(seller),
            platform: weth.balanceOf(platform),
            rewards: weth.balanceOf(rewardsRecipient),
            affiliate: weth.balanceOf(affiliate)
        });
    }
}

contract ExchangeTestErc721 is ERC721 {
    constructor() ERC721("Exchange Test 721", "X721") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}

contract ExchangeTestErc1155 is ERC1155 {
    constructor() ERC1155("") {}

    function mint(address to, uint256 tokenId, uint256 amount) external {
        _mint(to, tokenId, amount, "");
    }
}

contract ExchangeTestErc20 is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RejectsNative {
    receive() external payable {
        revert("no native");
    }
}

contract MockExchangeRouter {
    address public activeRoutedFulfiller;

    function setActiveRoutedFulfiller(address fulfiller) external {
        activeRoutedFulfiller = fulfiller;
    }
}

contract FeeMutatingErc1155Receiver {
    ScatterExchange internal immutable exchange;
    uint256 internal immutable nextFeeBps;
    uint256 internal immutable nextFeeSplitBps;
    bool internal mutated;

    constructor(ScatterExchange exchange_, uint256 nextFeeBps_, uint256 nextFeeSplitBps_) {
        exchange = exchange_;
        nextFeeBps = nextFeeBps_;
        nextFeeSplitBps = nextFeeSplitBps_;
    }

    function acceptOwnership() external {
        exchange.acceptOwnership();
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        if (!mutated) {
            mutated = true;
            exchange.setFeeBps(nextFeeBps);
            exchange.setFeeSplitBps(nextFeeSplitBps);
        }
        return this.onERC1155Received.selector;
    }
}
