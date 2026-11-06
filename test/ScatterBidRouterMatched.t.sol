// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ScatterBidRouterE2ETest} from "./ScatterBidRouterE2E.t.sol";
import {
    ScatterBidRouter,
    InvalidFeeAuthorization,
    InsufficientSellerPayout,
    CurrencyBalanceInvariant,
    InvalidSettlementOrder,
    OnlySeaport
} from "../src/ScatterBidRouter.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ZoneInterface} from "seaport-types/src/interfaces/ZoneInterface.sol";
import {
    AdvancedOrder,
    OfferItem,
    ConsiderationItem,
    OrderComponents,
    CriteriaResolver,
    Fulfillment,
    FulfillmentComponent,
    ZoneParameters,
    Schema
} from "seaport-types/src/lib/ConsiderationStructs.sol";
import {ItemType, OrderType, Side} from "seaport-types/src/lib/ConsiderationEnums.sol";

error SignedOwnerMismatch();
error InvalidOwnerAuthorization();
error LateValidationRejected(uint256 sellerBalance);

contract ScatterBidRouterMatchedTest is ScatterBidRouterE2ETest {
    uint256 internal constant ZONE_SIGNER_PK = 0x205E;
    bytes32 internal constant MATCHED_AUTHORIZATION_TYPEHASH = keccak256(
        "MatchedFeeAuthorization(address seller,address affiliate,bytes32 orderHash,bytes32 sourceOrderHash,uint256 deadline)"
    );
    MatchedOwnerBoundZone internal signedZone = new MatchedOwnerBoundZone(vm.addr(ZONE_SIGNER_PK));
    address internal marketplaceFeeRecipient = makeAddr("marketplace fee recipient");

    function test_matchedOwnerBoundBidPaysFeesWhereLegacyRouterCannotFulfill() public {
        registry.setRewardsOverride(address(nft721), rewards);
        AdvancedOrder[] memory orders = _pair(false, 1, 1, address(currency), 2 ether, 1, 1);
        AdvancedOrder[] memory legacyOrders = new AdvancedOrder[](1);
        legacyOrders[0] = orders[1];
        CriteriaResolver[][] memory legacyResolvers = new CriteriaResolver[][](1);
        legacyResolvers[0] = new CriteriaResolver[](1);
        legacyResolvers[0][0] = CriteriaResolver(0, Side.CONSIDERATION, 0, 1, new bytes32[](0));

        vm.expectRevert(SignedOwnerMismatch.selector);
        vm.prank(seller);
        router.sellIntoBids(legacyOrders, legacyResolvers, address(0), _minimum(address(currency), 0), 0, "");
        assertEq(nft721.ownerOf(1), seller);
        assertEq(currency.balanceOf(bidder), 100 ether);

        bytes32 sourceHash = _matchedHash(orders[1]);
        bytes32 settlementHash = _matchedHash(orders[0]);
        vm.expectEmit(true, true, true, true, address(router));
        emit ScatterBidRouter.BidProceedsPaid(
            seller,
            address(currency),
            settlementHash,
            address(nft721),
            1,
            1,
            1.95 ether,
            0.0975 ether,
            1.8525 ether,
            address(0),
            rewards,
            0.04875 ether,
            0.04875 ether,
            0
        );
        _match(orders);

        assertEq(nft721.ownerOf(1), bidder);
        assertEq(currency.balanceOf(bidder), 98 ether);
        assertEq(currency.balanceOf(marketplaceFeeRecipient), 0.05 ether);
        assertEq(currency.balanceOf(router.PLATFORM()), 0.04875 ether);
        assertEq(currency.balanceOf(rewards), 0.04875 ether);
        assertEq(currency.balanceOf(seller), 1.8525 ether);
        assertEq(currency.balanceOf(address(router)), 0);
        _assertFilled(sourceHash, 1, 1);
        _assertFilled(settlementHash, 1, 1);
    }

    function test_matchedSingleThenTwoItemBatchFillsCollectionBidAndPreservesDonation() public {
        currency.mint(address(router), 13 ether);
        AdvancedOrder[] memory first = _pair(false, 1, 3, address(currency), 6 ether, 1, 3);
        AdvancedOrder[] memory second = _pair(false, 2, 3, address(currency), 6 ether, 1, 3);
        bytes32 sourceHash = _matchedHash(first[1]);
        assertEq(sourceHash, _matchedHash(second[1]));
        _match(first);

        assertEq(nft721.ownerOf(1), bidder);
        assertEq(nft721.ownerOf(2), seller);
        assertEq(currency.balanceOf(bidder), 98 ether);
        assertEq(currency.balanceOf(marketplaceFeeRecipient), 0.05 ether);
        assertEq(currency.balanceOf(router.PLATFORM()), 0.0975 ether);
        assertEq(currency.balanceOf(seller), 1.8525 ether);
        assertEq(currency.balanceOf(address(router)), 13 ether);
        _assertFilled(sourceHash, 1, 3);

        nft721.mint(seller, 3);
        _match(_join(second, _pair(false, 3, 3, address(currency), 6 ether, 1, 3)));
        assertEq(nft721.ownerOf(2), bidder);
        assertEq(nft721.ownerOf(3), bidder);
        assertEq(currency.balanceOf(bidder), 94 ether);
        assertEq(currency.balanceOf(marketplaceFeeRecipient), 0.15 ether);
        assertEq(currency.balanceOf(router.PLATFORM()), 0.2925 ether);
        assertEq(currency.balanceOf(seller), 5.5575 ether);
        assertEq(currency.balanceOf(address(router)), 13 ether);
        _assertFilled(sourceHash, 1, 1);
    }

    function test_matchedMixedCurrencyBatchPartiallyFillsErc1155() public {
        currency.mint(address(router), 3 ether);
        secondCurrency.mint(address(router), 7 ether);
        AdvancedOrder[] memory first = _pair(true, 7, 10, address(currency), 10 ether, 1, 2);
        AdvancedOrder[] memory second = _pair(false, 1, 1, address(secondCurrency), 2 ether, 1, 1);
        bytes32 sourceHash = _matchedHash(first[1]);
        _match(_join(first, second));

        assertEq(nft1155.balanceOf(bidder, 7), 5);
        assertEq(nft1155.balanceOf(seller, 7), 15);
        assertEq(nft721.ownerOf(1), bidder);
        assertEq(currency.balanceOf(bidder), 95 ether);
        assertEq(currency.balanceOf(marketplaceFeeRecipient), 0.125 ether);
        assertEq(currency.balanceOf(router.PLATFORM()), 0.24375 ether);
        assertEq(currency.balanceOf(seller), 4.63125 ether);
        assertEq(secondCurrency.balanceOf(bidder), 98 ether);
        assertEq(secondCurrency.balanceOf(marketplaceFeeRecipient), 0.05 ether);
        assertEq(secondCurrency.balanceOf(router.PLATFORM()), 0.0975 ether);
        assertEq(secondCurrency.balanceOf(seller), 1.8525 ether);
        assertEq(currency.balanceOf(address(router)), 3 ether);
        assertEq(secondCurrency.balanceOf(address(router)), 7 ether);
        _assertFilled(sourceHash, 1, 2);
    }

    function test_matchedLateSourceRejectionRevertsPayoutsAndAllowsCleanRetry() public {
        currency.mint(address(router), 13 ether);
        AdvancedOrder[] memory orders = _join(
            _pair(false, 1, 2, address(currency), 4 ether, 1, 2), _pair(false, 2, 2, address(currency), 4 ether, 1, 2)
        );
        bytes32 sourceHash = _matchedHash(orders[1]);
        bytes32 firstCounterHash = _matchedHash(orders[0]);
        bytes32 secondCounterHash = _matchedHash(orders[2]);
        signedZone.setLateRejection(true, currency, seller);

        vm.expectRevert(abi.encodeWithSelector(LateValidationRejected.selector, 1.8525 ether));
        _match(orders);
        assertEq(nft721.ownerOf(1), seller);
        assertEq(nft721.ownerOf(2), seller);
        assertEq(currency.balanceOf(bidder), 100 ether);
        assertEq(currency.balanceOf(seller), 0);
        assertEq(currency.balanceOf(router.PLATFORM()), 0);
        assertEq(currency.balanceOf(marketplaceFeeRecipient), 0);
        assertEq(currency.balanceOf(address(router)), 13 ether);
        (,, uint256 sourceFilled,) = seaport.getOrderStatus(sourceHash);
        (,, uint256 firstCounterFilled,) = seaport.getOrderStatus(firstCounterHash);
        (,, uint256 secondCounterFilled,) = seaport.getOrderStatus(secondCounterHash);
        assertEq(sourceFilled, 0);
        assertEq(firstCounterFilled, 0);
        assertEq(secondCounterFilled, 0);

        signedZone.setLateRejection(false, currency, seller);
        _match(orders);
        assertEq(nft721.ownerOf(1), bidder);
        assertEq(nft721.ownerOf(2), bidder);
        assertEq(currency.balanceOf(bidder), 96 ether);
        assertEq(currency.balanceOf(seller), 3.705 ether);
        assertEq(currency.balanceOf(router.PLATFORM()), 0.195 ether);
        assertEq(currency.balanceOf(marketplaceFeeRecipient), 0.1 ether);
        assertEq(currency.balanceOf(address(router)), 13 ether);
        _assertFilled(sourceHash, 1, 1);
        _assertFilled(firstCounterHash, 1, 1);
        _assertFilled(secondCounterHash, 1, 1);
    }

    function test_matchedPayoutCallbackCannotReenterLegacyOrZoneSettlement() public {
        MatchedPayoutCallbackToken callbackCurrency = new MatchedPayoutCallbackToken();
        router.setAllowedCurrency(address(callbackCurrency), true);
        callbackCurrency.mint(bidder, 100 ether);
        callbackCurrency.mint(address(router), 13 ether);
        vm.prank(bidder);
        callbackCurrency.approve(address(conduit), type(uint256).max);
        AdvancedOrder[] memory orders = _pair(false, 1, 1, address(callbackCurrency), 2 ether, 1, 1);
        ZoneParameters memory parameters;
        bytes[3] memory callbacks;
        callbacks[0] = abi.encodeCall(
            ScatterBidRouter.sellIntoBids,
            (
                new AdvancedOrder[](0),
                new CriteriaResolver[][](0),
                address(0),
                new ScatterBidRouter.MinimumPayout[](0),
                0,
                bytes("")
            )
        );
        callbacks[1] = abi.encodeCall(ScatterBidRouter.authorizeOrder, (parameters));
        callbacks[2] = abi.encodeCall(ScatterBidRouter.validateOrder, (parameters));
        callbackCurrency.configureCallbacks(router, callbacks);

        _match(orders);
        assertTrue(callbackCurrency.callbackAttempted());
        for (uint256 i; i < callbacks.length; ++i) {
            assertFalse(callbackCurrency.callbackSucceeded(i));
            assertEq(callbackCurrency.callbackErrors(i), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        }
        assertEq(nft721.ownerOf(1), bidder);
        assertEq(callbackCurrency.balanceOf(bidder), 98 ether);
        assertEq(callbackCurrency.balanceOf(seller), 1.8525 ether);
        assertEq(callbackCurrency.balanceOf(router.PLATFORM()), 0.0975 ether);
        assertEq(callbackCurrency.balanceOf(marketplaceFeeRecipient), 0.05 ether);
        assertEq(callbackCurrency.balanceOf(address(router)), 13 ether);
        assertEq(router.activeRoutedFulfiller(), address(0));
        _assertFilled(_matchedHash(orders[1]), 1, 1);
        _assertFilled(_matchedHash(orders[0]), 1, 1);
    }

    function test_matchedAffiliateAuthorizationBindsRecipientAndCounterorder() public {
        registry.setRewardsOverride(address(nft721), rewards);
        AdvancedOrder[] memory orders = _pair(false, 1, 1, address(currency), 2 ether, 1, 1);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory authorization = _matchedAuthorization(orders[0], affiliate, deadline);
        ScatterBidRouter.MatchedBidContext memory context =
            abi.decode(orders[0].extraData, (ScatterBidRouter.MatchedBidContext));

        context.affiliate = affiliate;
        context.feeAuthorizationDeadline = deadline;
        orders[0].extraData = abi.encode(context);
        vm.expectRevert(InvalidFeeAuthorization.selector);
        _match(orders);

        context.affiliate = makeAddr("substituted affiliate");
        context.feeAuthorizationSignature = authorization;
        orders[0].extraData = abi.encode(context);
        vm.expectRevert(InvalidFeeAuthorization.selector);
        _match(orders);

        context.affiliate = affiliate;
        orders[0].extraData = abi.encode(context);
        orders[0].parameters.salt++;
        vm.expectRevert(InvalidFeeAuthorization.selector);
        _match(orders);
        orders[0].parameters.salt--;

        context.minimumSellerPayout = 1.8525 ether + 1;
        orders[0].extraData = abi.encode(context);
        vm.expectRevert(InsufficientSellerPayout.selector);
        _match(orders);
        assertEq(nft721.ownerOf(1), seller);
        assertEq(currency.balanceOf(bidder), 100 ether);
        assertEq(currency.balanceOf(affiliate), 0);

        context.minimumSellerPayout = 1.8525 ether;
        orders[0].extraData = abi.encode(context);
        _match(orders);
        assertEq(nft721.ownerOf(1), bidder);
        assertEq(currency.balanceOf(seller), 1.8525 ether);
        assertEq(currency.balanceOf(affiliate), 0.04875 ether);
        assertEq(currency.balanceOf(router.PLATFORM()), 0.04875 ether);
        assertEq(currency.balanceOf(rewards), 0);
        assertEq(currency.balanceOf(marketplaceFeeRecipient), 0.05 ether);
        assertEq(currency.balanceOf(address(router)), 0);
    }

    function test_matchedFeesUseOnchainRateAndRejectStaleMinimum() public {
        AdvancedOrder[] memory orders = _pair(false, 1, 1, address(currency), 2 ether, 1, 1);
        ScatterBidRouter.MatchedBidContext memory context =
            abi.decode(orders[0].extraData, (ScatterBidRouter.MatchedBidContext));
        context.minimumSellerPayout = 1.8525 ether;
        orders[0].extraData = abi.encode(context);
        router.setFeeBps(1000);
        vm.expectRevert(InsufficientSellerPayout.selector);
        _match(orders);
        assertEq(nft721.ownerOf(1), seller);
        assertEq(currency.balanceOf(bidder), 100 ether);

        context.minimumSellerPayout = 1.755 ether;
        orders[0].extraData = abi.encode(context);
        _match(orders);
        assertEq(currency.balanceOf(seller), 1.755 ether);
        assertEq(currency.balanceOf(router.PLATFORM()), 0.195 ether);
        assertEq(currency.balanceOf(marketplaceFeeRecipient), 0.05 ether);
        assertEq(currency.balanceOf(address(router)), 0);
    }

    function test_matchedUnderstatedProceedsCannotDivertUntaxedSourceExcess() public {
        AdvancedOrder[] memory orders = _pair(false, 1, 1, address(currency), 2 ether, 1, 1);
        orders[0].parameters.consideration[0].startAmount = 1 ether;
        orders[0].parameters.consideration[0].endAmount = 1 ether;
        bytes32 sourceHash = _matchedHash(orders[1]);

        vm.expectRevert(InvalidSettlementOrder.selector);
        _match(orders);
        assertEq(nft721.ownerOf(1), seller);
        assertEq(currency.balanceOf(bidder), 100 ether);
        assertEq(currency.balanceOf(seller), 0);
        assertEq(currency.balanceOf(router.PLATFORM()), 0);
        assertEq(currency.balanceOf(marketplaceFeeRecipient), 0);
        (,, uint256 filled,) = seaport.getOrderStatus(sourceHash);
        assertEq(filled, 0);
    }

    function test_matchedCrossFillCannotShiftQuantityToHigherPricedSource() public {
        AdvancedOrder[] memory higher = _pair(true, 7, 4, address(currency), 8 ether, 1, 2);
        AdvancedOrder[] memory lower = _pair(true, 7, 4, address(currency), 4 ether, 1, 2);
        bytes32 higherHash = _matchedHash(higher[1]);
        bytes32 lowerHash = _matchedHash(lower[1]);
        higher[1].numerator = 3;
        higher[1].denominator = 4;
        lower[1].numerator = 1;
        lower[1].denominator = 4;
        AdvancedOrder[] memory orders = _join(higher, lower);
        Fulfillment[] memory fulfillments = new Fulfillment[](3);
        for (uint256 i; i < fulfillments.length; ++i) {
            fulfillments[i].offerComponents = new FulfillmentComponent[](2);
            fulfillments[i].considerationComponents = new FulfillmentComponent[](2);
        }
        fulfillments[0].offerComponents[0] = FulfillmentComponent(1, 0);
        fulfillments[0].offerComponents[1] = FulfillmentComponent(3, 0);
        fulfillments[0].considerationComponents[0] = FulfillmentComponent(0, 0);
        fulfillments[0].considerationComponents[1] = FulfillmentComponent(2, 0);
        fulfillments[1].offerComponents = new FulfillmentComponent[](1);
        fulfillments[1].offerComponents[0] = FulfillmentComponent(1, 0);
        fulfillments[1].considerationComponents[0] = FulfillmentComponent(1, 1);
        fulfillments[1].considerationComponents[1] = FulfillmentComponent(3, 1);
        fulfillments[2].offerComponents[0] = FulfillmentComponent(0, 0);
        fulfillments[2].offerComponents[1] = FulfillmentComponent(2, 0);
        fulfillments[2].considerationComponents[0] = FulfillmentComponent(1, 0);
        fulfillments[2].considerationComponents[1] = FulfillmentComponent(3, 0);

        vm.expectRevert(InvalidSettlementOrder.selector);
        vm.prank(seller);
        seaport.matchAdvancedOrders(orders, new CriteriaResolver[](0), fulfillments, seller);
        assertEq(nft1155.balanceOf(seller, 7), 20);
        assertEq(nft1155.balanceOf(bidder, 7), 0);
        assertEq(currency.balanceOf(bidder), 100 ether);
        assertEq(currency.balanceOf(seller), 0);
        assertEq(currency.balanceOf(router.PLATFORM()), 0);
        assertEq(currency.balanceOf(marketplaceFeeRecipient), 0);
        (,, uint256 higherFilled,) = seaport.getOrderStatus(higherHash);
        (,, uint256 lowerFilled,) = seaport.getOrderStatus(lowerHash);
        assertEq(higherFilled, 0);
        assertEq(lowerFilled, 0);
    }

    function test_matchedCallbacksRejectCallsOutsideSeaport() public {
        ZoneParameters memory parameters;
        vm.expectRevert(OnlySeaport.selector);
        vm.prank(seller);
        router.authorizeOrder(parameters);
        vm.expectRevert(OnlySeaport.selector);
        vm.prank(seller);
        router.validateOrder(parameters);
        assertEq(currency.balanceOf(bidder), 100 ether);
        assertEq(currency.balanceOf(seller), 0);
    }

    function test_matchedSourceCannotPrecedeItsFirstCounterorder() public {
        AdvancedOrder[] memory pair = _pair(true, 7, 2, address(currency), 2 ether, 1, 1);
        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = pair[1];
        orders[1] = pair[0];
        Fulfillment[] memory fulfillments = new Fulfillment[](3);
        for (uint256 i; i < fulfillments.length; ++i) {
            fulfillments[i].offerComponents = new FulfillmentComponent[](1);
            fulfillments[i].considerationComponents = new FulfillmentComponent[](1);
        }
        fulfillments[0].offerComponents[0] = FulfillmentComponent(0, 0);
        fulfillments[0].considerationComponents[0] = FulfillmentComponent(1, 0);
        fulfillments[1].offerComponents[0] = FulfillmentComponent(0, 0);
        fulfillments[1].considerationComponents[0] = FulfillmentComponent(0, 1);
        fulfillments[2].offerComponents[0] = FulfillmentComponent(1, 0);
        fulfillments[2].considerationComponents[0] = FulfillmentComponent(0, 0);

        vm.expectRevert(InvalidSettlementOrder.selector);
        vm.prank(seller);
        seaport.matchAdvancedOrders(orders, new CriteriaResolver[](0), fulfillments, seller);
        assertEq(nft1155.balanceOf(seller, 7), 20);
        assertEq(nft1155.balanceOf(bidder, 7), 0);
        assertEq(currency.balanceOf(bidder), 100 ether);
        assertEq(currency.balanceOf(seller), 0);
    }

    function test_matchedCounterorderCannotSendProceedsDirectlyToSeller() public {
        AdvancedOrder[] memory orders = _pair(false, 1, 1, address(currency), 2 ether, 1, 1);
        orders[0].parameters.consideration[0].recipient = payable(seller);
        vm.expectRevert(InvalidSettlementOrder.selector);
        _match(orders);
        assertEq(nft721.ownerOf(1), seller);
        assertEq(currency.balanceOf(bidder), 100 ether);
        assertEq(currency.balanceOf(seller), 0);
        assertEq(currency.balanceOf(router.PLATFORM()), 0);
        assertEq(currency.balanceOf(marketplaceFeeRecipient), 0);
    }

    function test_matchedBatchRejectsUnrelatedUnroutedSale() public {
        AdvancedOrder[] memory first = _pair(false, 1, 1, address(currency), 2 ether, 1, 1);
        AdvancedOrder[] memory unrelated = _pair(true, 7, 4, address(currency), 4 ether, 1, 1);
        unrelated[0].parameters.zone = address(0);
        unrelated[0].parameters.orderType = OrderType.FULL_OPEN;
        unrelated[0].parameters.consideration[0].recipient = payable(seller);
        AdvancedOrder[] memory batch = _join(first, unrelated);

        vm.expectRevert(InvalidSettlementOrder.selector);
        _match(batch);
        assertEq(nft721.ownerOf(1), seller);
        assertEq(nft1155.balanceOf(seller, 7), 20);
        assertEq(nft1155.balanceOf(bidder, 7), 0);
        assertEq(currency.balanceOf(bidder), 100 ether);
        assertEq(currency.balanceOf(seller), 0);
        assertEq(currency.balanceOf(router.PLATFORM()), 0);
    }

    function test_matchedCanceledSourceRollsBackEntireBatch() public {
        currency.mint(address(router), 13 ether);
        AdvancedOrder[] memory first = _pair(false, 1, 1, address(currency), 2 ether, 1, 1);
        AdvancedOrder[] memory second = _pair(true, 7, 4, address(currency), 4 ether, 1, 1);
        bytes32 firstHash = _matchedHash(first[1]);
        bytes32 canceledHash = _matchedHash(second[1]);
        OrderComponents[] memory cancellations = new OrderComponents[](1);
        cancellations[0] = _matchedComponents(second[1]);
        vm.prank(bidder);
        seaport.cancel(cancellations);
        AdvancedOrder[] memory batch = _join(first, second);

        vm.expectRevert(abi.encodeWithSignature("OrderIsCancelled(bytes32)", canceledHash));
        _match(batch);
        assertEq(nft721.ownerOf(1), seller);
        assertEq(nft1155.balanceOf(seller, 7), 20);
        assertEq(nft1155.balanceOf(bidder, 7), 0);
        assertEq(currency.balanceOf(bidder), 100 ether);
        assertEq(currency.balanceOf(seller), 0);
        assertEq(currency.balanceOf(router.PLATFORM()), 0);
        assertEq(currency.balanceOf(marketplaceFeeRecipient), 0);
        assertEq(currency.balanceOf(address(router)), 13 ether);
        (,, uint256 filled,) = seaport.getOrderStatus(firstHash);
        assertEq(filled, 0);
    }

    function test_matchedTaxedCurrencyCannotSpendDonationsToCoverShortReceipt() public {
        currency.mint(address(router), 13 ether);
        currency.setTaxedSender(bidder);
        AdvancedOrder[] memory batch = _join(
            _pair(false, 1, 4, address(currency), 8 ether, 1, 4), _pair(false, 2, 4, address(currency), 8 ether, 1, 4)
        );
        vm.expectRevert(CurrencyBalanceInvariant.selector);
        _match(batch);
        assertEq(nft721.ownerOf(1), seller);
        assertEq(nft721.ownerOf(2), seller);
        assertEq(currency.balanceOf(bidder), 100 ether);
        assertEq(currency.balanceOf(seller), 0);
        assertEq(currency.balanceOf(router.PLATFORM()), 0);
        assertEq(currency.balanceOf(address(router)), 13 ether);
    }

    function _pair(
        bool erc1155,
        uint256 tokenId,
        uint256 quantity,
        address token,
        uint256 gross,
        uint120 numerator,
        uint120 denominator
    ) internal view returns (AdvancedOrder[] memory orders) {
        orders = new AdvancedOrder[](2);
        AdvancedOrder memory source = _externalOrder(erc1155, tokenId, quantity, token, gross, numerator, denominator);
        source.parameters.zone = address(signedZone);
        source.parameters.orderType = denominator == 1 ? OrderType.FULL_RESTRICTED : OrderType.PARTIAL_RESTRICTED;
        source.parameters.salt = 77;
        source.parameters.consideration = new ConsiderationItem[](2);
        source.parameters.consideration[0] = ConsiderationItem(
            erc1155 ? ItemType.ERC1155 : ItemType.ERC721_WITH_CRITERIA,
            erc1155 ? address(nft1155) : address(nft721),
            erc1155 ? tokenId : 0,
            quantity,
            quantity,
            payable(bidder)
        );
        uint256 marketplaceFee = gross / 40;
        source.parameters.consideration[1] = ConsiderationItem(
            ItemType.ERC20, token, 0, marketplaceFee, marketplaceFee, payable(marketplaceFeeRecipient)
        );
        source.parameters.totalOriginalConsiderationItems = 2;
        bytes32 sourceHash = _matchedHash(source);
        (, bytes32 seaportDomain,) = seaport.information();
        source.signature = _sign(BIDDER_PK, keccak256(abi.encodePacked("\x19\x01", seaportDomain, sourceHash)));
        uint256 deadline = block.timestamp + 1 hours;
        source.extraData = abi.encode(
            seller,
            tokenId,
            deadline,
            _sign(
                ZONE_SIGNER_PK,
                _digest(
                    address(signedZone),
                    "MatchedOwnerBoundZone",
                    keccak256(abi.encode(signedZone.AUTHORIZATION_TYPEHASH(), seller, sourceHash, tokenId, deadline))
                )
            )
        );
        orders[1] = source;

        AdvancedOrder memory counter;
        counter.parameters.offerer = seller;
        counter.parameters.zone = address(router);
        counter.parameters.orderType = OrderType.FULL_RESTRICTED;
        counter.parameters.startTime = block.timestamp;
        counter.parameters.endTime = block.timestamp + 1 hours;
        counter.parameters.salt = tokenId;
        counter.parameters.conduitKey = conduitKey;
        counter.parameters.offer = new OfferItem[](1);
        uint256 filledQuantity = quantity * numerator / denominator;
        counter.parameters.offer[0] = OfferItem(
            erc1155 ? ItemType.ERC1155 : ItemType.ERC721,
            erc1155 ? address(nft1155) : address(nft721),
            tokenId,
            filledQuantity,
            filledQuantity
        );
        counter.parameters.consideration = new ConsiderationItem[](1);
        uint256 proceeds = (gross - marketplaceFee) * numerator / denominator;
        counter.parameters.consideration[0] =
            ConsiderationItem(ItemType.ERC20, token, 0, proceeds, proceeds, payable(address(router)));
        counter.parameters.totalOriginalConsiderationItems = 1;
        counter.numerator = 1;
        counter.denominator = 1;
        counter.extraData = abi.encode(
            ScatterBidRouter.MatchedBidContext({
                sourceOrder: _matchedComponents(source),
                criteriaProof: new bytes32[](0),
                affiliate: address(0),
                minimumSellerPayout: 0,
                feeAuthorizationDeadline: 0,
                feeAuthorizationSignature: ""
            })
        );
        orders[0] = counter;
    }

    function _match(AdvancedOrder[] memory orders) internal {
        uint256 criteriaCount;
        for (uint256 i; i < orders.length; i += 2) {
            if (orders[i + 1].parameters.consideration[0].itemType == ItemType.ERC721_WITH_CRITERIA) criteriaCount++;
        }
        CriteriaResolver[] memory resolvers = new CriteriaResolver[](criteriaCount);
        Fulfillment[] memory fulfillments = new Fulfillment[](orders.length / 2 * 3);
        uint256 resolverIndex;
        for (uint256 i; i < orders.length; i += 2) {
            if (orders[i + 1].parameters.consideration[0].itemType == ItemType.ERC721_WITH_CRITERIA) {
                resolvers[resolverIndex++] = CriteriaResolver(
                    i + 1, Side.CONSIDERATION, 0, orders[i].parameters.offer[0].identifierOrCriteria, new bytes32[](0)
                );
            }
            uint256 offset = i / 2 * 3;
            for (uint256 j; j < 3; ++j) {
                fulfillments[offset + j].offerComponents = new FulfillmentComponent[](1);
                fulfillments[offset + j].considerationComponents = new FulfillmentComponent[](1);
            }
            fulfillments[offset].offerComponents[0] = FulfillmentComponent(i + 1, 0);
            fulfillments[offset].considerationComponents[0] = FulfillmentComponent(i, 0);
            fulfillments[offset + 1].offerComponents[0] = FulfillmentComponent(i + 1, 0);
            fulfillments[offset + 1].considerationComponents[0] = FulfillmentComponent(i + 1, 1);
            fulfillments[offset + 2].offerComponents[0] = FulfillmentComponent(i, 0);
            fulfillments[offset + 2].considerationComponents[0] = FulfillmentComponent(i + 1, 0);
        }
        vm.prank(seller);
        seaport.matchAdvancedOrders(orders, resolvers, fulfillments, seller);
    }

    function _join(AdvancedOrder[] memory first, AdvancedOrder[] memory second)
        internal
        pure
        returns (AdvancedOrder[] memory orders)
    {
        orders = new AdvancedOrder[](4);
        orders[0] = first[0];
        orders[1] = first[1];
        orders[2] = second[0];
        orders[3] = second[1];
    }

    function _matchedComponents(AdvancedOrder memory order) internal view returns (OrderComponents memory) {
        return OrderComponents({
            offerer: order.parameters.offerer,
            zone: order.parameters.zone,
            offer: order.parameters.offer,
            consideration: order.parameters.consideration,
            orderType: order.parameters.orderType,
            startTime: order.parameters.startTime,
            endTime: order.parameters.endTime,
            zoneHash: order.parameters.zoneHash,
            salt: order.parameters.salt,
            conduitKey: order.parameters.conduitKey,
            counter: seaport.getCounter(order.parameters.offerer)
        });
    }

    function _matchedHash(AdvancedOrder memory order) internal view returns (bytes32) {
        return seaport.getOrderHash(_matchedComponents(order));
    }

    function _matchedAuthorization(AdvancedOrder memory counter, address referrer, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        ScatterBidRouter.MatchedBidContext memory context =
            abi.decode(counter.extraData, (ScatterBidRouter.MatchedBidContext));
        return _sign(
            AUTHORIZER_PK,
            _digest(
                address(router),
                "ScatterBidRouter",
                keccak256(
                    abi.encode(
                        MATCHED_AUTHORIZATION_TYPEHASH,
                        seller,
                        referrer,
                        _matchedHash(counter),
                        seaport.getOrderHash(context.sourceOrder),
                        deadline
                    )
                )
            )
        );
    }

    function _assertFilled(bytes32 orderHash, uint256 numerator, uint256 denominator) internal view {
        (, bool canceled, uint256 filled, uint256 total) = seaport.getOrderStatus(orderHash);
        assertFalse(canceled);
        assertGt(total, 0);
        assertEq(filled * denominator, total * numerator);
    }
}

contract MatchedOwnerBoundZone is ZoneInterface, EIP712 {
    bytes32 public constant AUTHORIZATION_TYPEHASH =
        keccak256("OwnerAuthorization(address owner,bytes32 orderHash,uint256 tokenId,uint256 deadline)");
    address internal immutable signer;
    bool internal rejectValidation;
    IERC20 internal rejectionCurrency;
    address internal rejectionSeller;

    constructor(address signer_) EIP712("MatchedOwnerBoundZone", "1") {
        signer = signer_;
    }

    function authorizeOrder(ZoneParameters calldata parameters) external view returns (bytes4) {
        (address owner, uint256 tokenId, uint256 deadline, bytes memory signature) =
            abi.decode(parameters.extraData, (address, uint256, uint256, bytes));
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(AUTHORIZATION_TYPEHASH, owner, parameters.orderHash, tokenId, deadline))
        );
        if (block.timestamp > deadline || ECDSA.recover(digest, signature) != signer) {
            revert InvalidOwnerAuthorization();
        }
        if (parameters.fulfiller != owner) revert SignedOwnerMismatch();
        if (parameters.consideration[0].identifier != tokenId) revert InvalidOwnerAuthorization();
        return ZoneInterface.authorizeOrder.selector;
    }

    function setLateRejection(bool enabled, IERC20 currency, address seller) external {
        rejectValidation = enabled;
        rejectionCurrency = currency;
        rejectionSeller = seller;
    }

    function validateOrder(ZoneParameters calldata) external view returns (bytes4) {
        if (rejectValidation) revert LateValidationRejected(rejectionCurrency.balanceOf(rejectionSeller));
        return ZoneInterface.validateOrder.selector;
    }

    function getSeaportMetadata() external pure returns (string memory, Schema[] memory schemas) {
        return ("Local owner-bound signed zone", new Schema[](0));
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ZoneInterface).interfaceId || interfaceId == 0x01ffc9a7;
    }
}

contract MatchedPayoutCallbackToken is ERC20 {
    ScatterBidRouter internal callbackRouter;
    bytes[3] internal callbacks;
    bool public callbackAttempted;
    bool[3] public callbackSucceeded;
    bytes4[3] public callbackErrors;

    constructor() ERC20("Payout callback currency", "CALLBACK") {}

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }

    function configureCallbacks(ScatterBidRouter router, bytes[3] calldata data) external {
        callbackRouter = router;
        callbacks = data;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from == address(callbackRouter) && from != address(0) && !callbackAttempted) {
            callbackAttempted = true;
            for (uint256 i; i < callbacks.length; ++i) {
                (bool success, bytes memory result) = address(callbackRouter).call(callbacks[i]);
                callbackSucceeded[i] = success;
                callbackErrors[i] = bytes4(result);
            }
        }
        super._update(from, to, amount);
    }
}
