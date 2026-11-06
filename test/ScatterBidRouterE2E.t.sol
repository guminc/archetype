// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ConduitTest} from "./helpers/ConduitTest.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ScatterOfferer, OrderExpired} from "../src/ScatterOfferer.sol";
import {
    ScatterBidRouter,
    InvalidConsiderationShape,
    InvalidScatterOfferer,
    InvalidFeeAuthorization,
    InvalidBidCurrency,
    InvalidNftRecipient,
    CurrencyBalanceInvariant,
    InsufficientSellerPayout
} from "../src/ScatterBidRouter.sol";
import {ScatterCollectionRegistry} from "../src/ScatterCollectionRegistry.sol";
import {SeaportInterface} from "seaport-types/src/interfaces/SeaportInterface.sol";
import {
    AdvancedOrder,
    CriteriaResolver,
    OfferItem,
    ConsiderationItem,
    OrderComponents,
    SpentItem,
    ReceivedItem
} from "seaport-types/src/lib/ConsiderationStructs.sol";
import {ItemType, OrderType} from "seaport-types/src/lib/ConsiderationEnums.sol";

contract ScatterBidRouterE2ETest is ConduitTest {
    uint256 internal constant BIDDER_PK = 0xB1D;
    uint256 internal constant AUTHORIZER_PK = 0xA11CE;
    address internal bidder = vm.addr(BIDDER_PK);
    address internal seller = makeAddr("seller");
    address internal affiliate = makeAddr("affiliate");
    address internal rewards = makeAddr("rewards");
    ScatterCollectionRegistry internal registry;
    ScatterOfferer internal offerer;
    ScatterBidRouter internal router;
    SeaportInterface internal seaport;
    RouterE2EERC20 internal currency;
    RouterE2EERC20 internal secondCurrency;
    RouterE2EERC721 internal nft721;
    RouterE2EERC1155 internal nft1155;

    function setUp() public virtual {
        _setUpConduit();
        registry = new ScatterCollectionRegistry(address(this));
        offerer = new ScatterOfferer(address(this), registry, vm.addr(AUTHORIZER_PK), conduitKey);
        router = new ScatterBidRouter(address(this), vm.addr(AUTHORIZER_PK), registry, address(offerer), conduitKey);
        offerer.setTrustedRouter(address(router), true);
        _setUpSeaport(router.SEAPORT());
        seaport = SeaportInterface(router.SEAPORT());
        _openConduitChannel(address(offerer));
        _openConduitChannel(address(router));
        _openConduitChannel(address(seaport));
        currency = new RouterE2EERC20();
        secondCurrency = new RouterE2EERC20();
        router.setAllowedCurrency(address(currency), true);
        router.setAllowedCurrency(address(secondCurrency), true);
        nft721 = new RouterE2EERC721();
        nft1155 = new RouterE2EERC1155();
        nft721.mint(seller, 1);
        nft721.mint(seller, 2);
        nft1155.mint(seller, 7, 20);
        currency.mint(bidder, 100 ether);
        secondCurrency.mint(bidder, 100 ether);
        vm.startPrank(bidder);
        currency.approve(address(conduit), type(uint256).max);
        secondCurrency.approve(address(conduit), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(seller);
        nft721.setApprovalForAll(address(conduit), true);
        nft1155.setApprovalForAll(address(conduit), true);
        vm.stopPrank();
    }

    function test_mixedSourcesStandardsAndCurrenciesPayPerFillWithoutDoubleFees() public {
        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = this.nativeOrder(false, 1, 1, address(currency), 1 ether, address(0));
        orders[1] = _externalOrder(true, 7, 4, address(secondCurrency), 8 ether, 1, 1);
        ScatterBidRouter.MinimumPayout[] memory minima = new ScatterBidRouter.MinimumPayout[](2);
        minima[0] = ScatterBidRouter.MinimumPayout(address(currency), 0.95 ether);
        minima[1] = ScatterBidRouter.MinimumPayout(address(secondCurrency), 7.6 ether);
        vm.recordLogs();
        vm.prank(seller);
        router.sellIntoBids(orders, _resolvers(2), address(0), minima, 0, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 nativeSales;
        uint256 externalSales;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(offerer) && logs[i].topics.length == 4) {
                assertEq(address(uint160(uint256(logs[i].topics[2]))), seller);
                assertEq(address(uint160(uint256(logs[i].topics[3]))), bidder);
                nativeSales++;
            }
            if (logs[i].emitter == address(router) && logs[i].topics.length == 4) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), seller);
                externalSales++;
            }
        }
        assertEq(nativeSales, 1);
        assertEq(externalSales, 1);
        assertEq(currency.balanceOf(seller), 0.95 ether);
        assertEq(secondCurrency.balanceOf(seller), 7.6 ether);
        assertEq(currency.balanceOf(router.PLATFORM()), 0.05 ether);
        assertEq(secondCurrency.balanceOf(router.PLATFORM()), 0.4 ether);
        assertEq(nft721.ownerOf(1), bidder);
        assertEq(nft1155.balanceOf(bidder, 7), 4);
        assertEq(router.activeRoutedFulfiller(), address(0));
        assertFalse(nft1155.isApprovedForAll(address(router), address(seaport)));
        assertEq(currency.allowance(address(offerer), address(seaport)), 0);
    }

    function test_expiredNativeAndExternalOrdersRejectWithoutAffiliateAuthorization() public {
        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = this.nativeOrder(false, 1, 1, address(currency), 1 ether, address(0));
        orders[1] = _externalOrder(false, 2, 1, address(currency), 1 ether, 1, 1);
        vm.warp(orders[0].parameters.endTime);
        orders[0].parameters.endTime += 1 days;

        for (uint256 i; i < orders.length; ++i) {
            AdvancedOrder[] memory batch = new AdvancedOrder[](1);
            batch[0] = orders[i];
            if (i == 0) {
                vm.expectRevert(OrderExpired.selector);
            } else {
                vm.expectRevert(
                    abi.encodeWithSignature(
                        "InvalidTime(uint256,uint256)", batch[0].parameters.startTime, batch[0].parameters.endTime
                    )
                );
            }
            vm.prank(seller);
            router.sellIntoBids(batch, _resolvers(1), address(0), _minimum(address(currency), 0.95 ether), 0, "");
        }

        assertEq(nft721.ownerOf(1), seller);
        assertEq(nft721.ownerOf(2), seller);
        assertEq(currency.balanceOf(seller), 0);
        assertEq(currency.balanceOf(bidder), 100 ether);
    }

    function test_nativeSingletonPreservesRouterTokenAndNftDust() public {
        currency.mint(address(router), 13 ether);
        nft721.mint(address(router), 99);
        nft1155.mint(address(router), 7, 11);
        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = this.nativeOrder(true, 7, 3, address(currency), 2 ether, address(0));
        _sell(orders, _minimum(address(currency), 5.7 ether), address(0));
        assertEq(currency.balanceOf(address(router)), 13 ether);
        assertEq(nft721.ownerOf(99), address(router));
        assertEq(nft1155.balanceOf(address(router), 7), 11);
        assertEq(nft1155.balanceOf(seller, 7), 17);
        assertEq(nft1155.balanceOf(bidder, 7), 3);
        assertEq(currency.balanceOf(seller), 5.7 ether);
    }

    function test_repeatedExternalOrderUsesCurrentRemainingFraction() public {
        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = _externalOrder(true, 7, 10, address(currency), 10 ether, 7, 10);
        orders[1] = orders[0];
        _sell(orders, _minimum(address(currency), 9.5 ether), address(0));
        assertEq(nft1155.balanceOf(bidder, 7), 10);
        assertEq(nft1155.balanceOf(seller, 7), 10);
        assertEq(currency.balanceOf(seller), 9.5 ether);
        assertEq(currency.balanceOf(bidder), 90 ether);
    }

    function test_externalSignedRecipientsPreserveBidderFeesAndRouterDust() public {
        address recipient = makeAddr("recipient");
        currency.mint(address(router), 13 ether);
        nft1155.mint(address(router), 7, 11);
        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = _externalOrder(false, 1, 1, address(currency), 2 ether, 1, 1);
        orders[1] = _externalOrder(true, 7, 10, address(currency), 10 ether, 2, 5);
        for (uint256 i; i < orders.length; ++i) {
            orders[i].parameters.consideration[0].recipient = payable(recipient);
            _signExternalOrder(orders[i]);
        }

        vm.expectEmit(true, true, true, true, address(router));
        emit ScatterBidRouter.ExternalBidFilled(
            seller,
            address(currency),
            seaport.getOrderHash(_externalComponents(orders[0])),
            address(nft721),
            1,
            1,
            bidder,
            2 ether,
            0.1 ether,
            1.9 ether,
            affiliate,
            address(0),
            0.05 ether,
            0,
            0.05 ether
        );
        vm.expectEmit(true, true, true, true, address(router));
        emit ScatterBidRouter.ExternalBidFilled(
            seller,
            address(currency),
            seaport.getOrderHash(_externalComponents(orders[1])),
            address(nft1155),
            7,
            4,
            bidder,
            4 ether,
            0.2 ether,
            3.8 ether,
            affiliate,
            address(0),
            0.1 ether,
            0,
            0.1 ether
        );
        _sell(orders, _minimum(address(currency), 5.7 ether), affiliate);

        assertEq(nft721.ownerOf(1), recipient);
        assertEq(nft1155.balanceOf(recipient, 7), 4);
        assertEq(nft1155.balanceOf(bidder, 7), 0);
        assertEq(nft1155.balanceOf(seller, 7), 16);
        assertEq(currency.balanceOf(bidder), 94 ether);
        assertEq(currency.balanceOf(recipient), 0);
        assertEq(currency.balanceOf(seller), 5.7 ether);
        assertEq(currency.balanceOf(affiliate), 0.15 ether);
        assertEq(currency.balanceOf(router.PLATFORM()), 0.15 ether);
        assertEq(currency.balanceOf(address(router)), 13 ether);
        assertEq(nft1155.balanceOf(address(router), 7), 11);
        assertFalse(nft1155.isApprovedForAll(address(router), address(seaport)));
    }

    function test_externalRecipientCannotChangeAfterBidderSigns() public {
        address recipient = makeAddr("recipient");
        registry.setRewardsOverride(address(nft721), rewards);
        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = _externalOrder(false, 1, 1, address(currency), 2 ether, 1, 1);
        orders[0].parameters.consideration[0].recipient = payable(recipient);

        vm.expectRevert(bytes4(keccak256("InvalidSigner()")));
        _sell(orders, _minimum(address(currency), 1.9 ether), address(0));
        assertEq(nft721.ownerOf(1), seller);
        assertEq(currency.balanceOf(bidder), 100 ether);
        assertEq(currency.balanceOf(seller), 0);

        _signExternalOrder(orders[0]);
        _sell(orders, _minimum(address(currency), 1.9 ether), address(0));
        assertEq(nft721.ownerOf(1), recipient);
        assertEq(currency.balanceOf(bidder), 98 ether);
        assertEq(currency.balanceOf(seller), 1.9 ether);
        assertEq(currency.balanceOf(rewards), 0.05 ether);
        assertEq(currency.balanceOf(router.PLATFORM()), 0.05 ether);
    }

    function testFuzz_externalRejectsZeroAndRouterRecipients(bool erc1155, bool routerRecipient) public {
        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = _externalOrder(erc1155, erc1155 ? 7 : 1, 1, address(currency), 2 ether, 1, 1);
        orders[0].parameters.consideration[0].recipient = payable(routerRecipient ? address(router) : address(0));
        _signExternalOrder(orders[0]);

        vm.expectRevert(InvalidNftRecipient.selector);
        _sell(orders, _minimum(address(currency), 1.9 ether), address(0));
        assertEq(nft721.ownerOf(1), seller);
        assertEq(nft1155.balanceOf(seller, 7), 20);
        assertEq(currency.balanceOf(bidder), 100 ether);
        assertEq(currency.balanceOf(seller), 0);
    }

    function test_repeatedNativeOrderAccumulatesItemQuantity() public {
        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = this.nativeOrder(true, 7, 3, address(currency), 1 ether, address(0));
        orders[1] = orders[0];
        _sell(orders, _minimum(address(currency), 5.7 ether), address(0));
        assertEq(nft1155.balanceOf(bidder, 7), 6);
        assertEq(currency.balanceOf(seller), 5.7 ether);
    }

    function test_laterFundingFailureRollsBackNativeAndExternalFills() public {
        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = this.nativeOrder(false, 1, 1, address(currency), 80 ether, address(0));
        orders[1] = _externalOrder(false, 2, 1, address(currency), 30 ether, 1, 1);
        vm.expectRevert();
        _sell(orders, _minimum(address(currency), 0), address(0));
        assertEq(nft721.ownerOf(1), seller);
        assertEq(nft721.ownerOf(2), seller);
        assertEq(currency.balanceOf(bidder), 100 ether);
        assertEq(currency.balanceOf(seller), 0);
        assertEq(currency.balanceOf(router.PLATFORM()), 0);
        assertEq(router.activeRoutedFulfiller(), address(0));
        AdvancedOrder[] memory retry = new AdvancedOrder[](1);
        retry[0] = orders[0];
        _sell(retry, _minimum(address(currency), 76 ether), address(0));
        assertEq(nft721.ownerOf(1), bidder);
    }

    function test_nativeAffiliateAuthorizationUsesOriginalSeller() public {
        registry.setRewardsOverride(address(nft721), rewards);
        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = this.nativeOrder(false, 1, 1, address(currency), 2 ether, affiliate);
        orders[1] = _externalOrder(false, 2, 1, address(currency), 2 ether, 1, 1);
        _sell(orders, _minimum(address(currency), 3.8 ether), affiliate);
        assertEq(currency.balanceOf(affiliate), 0.1 ether);
        assertEq(currency.balanceOf(router.PLATFORM()), 0.1 ether);
        assertEq(currency.balanceOf(seller), 3.8 ether);
        assertEq(currency.balanceOf(rewards), 0);
    }

    function test_externalThenNativePreservesCollectionRewardsAndPerFillFees() public {
        registry.setRewardsOverride(address(nft721), rewards);
        registry.setRewardsOverride(address(nft1155), rewards);
        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = _externalOrder(false, 1, 1, address(currency), 2 ether, 1, 1);
        orders[1] = this.nativeOrder(true, 7, 2, address(currency), 2 ether, address(0));
        _sell(orders, _minimum(address(currency), 5.7 ether), address(0));
        assertEq(currency.balanceOf(rewards), 0.15 ether);
        assertEq(currency.balanceOf(router.PLATFORM()), 0.15 ether);
        assertEq(currency.balanceOf(seller), 5.7 ether);
        assertEq(nft721.ownerOf(1), bidder);
        assertEq(nft1155.balanceOf(bidder, 7), 2);
    }

    function test_cancelledNativeItemRevertsEarlierExternalFill() public {
        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = _externalOrder(false, 1, 1, address(currency), 2 ether, 1, 1);
        orders[1] = this.nativeOrder(true, 7, 2, address(currency), 2 ether, address(0));
        ScatterOfferer.ScatterSubmission memory submission =
            abi.decode(orders[1].extraData, (ScatterOfferer.ScatterSubmission));
        ScatterOfferer.CancelListingItem[] memory cancellations = new ScatterOfferer.CancelListingItem[](1);
        cancellations[0] = ScatterOfferer.CancelListingItem(offerer.hashSubmission(submission), 0);
        vm.prank(bidder);
        offerer.cancelListings(cancellations);
        vm.expectRevert();
        _sell(orders, _minimum(address(currency), 0), address(0));
        assertEq(nft721.ownerOf(1), seller);
        assertEq(nft1155.balanceOf(seller, 7), 20);
        assertEq(currency.balanceOf(bidder), 100 ether);
        assertEq(currency.balanceOf(seller), 0);
    }

    function test_nativeCriteriaProofLivesInOffererPayload() public {
        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = this.nativeOrder(true, 7, 2, address(currency), 2 ether, address(0));
        ScatterOfferer.ScatterSubmission memory submission =
            abi.decode(orders[0].extraData, (ScatterOfferer.ScatterSubmission));
        submission.listings[0].tokenId = 0;
        submission.criteriaRoot = keccak256(abi.encode(uint256(7)));
        ScatterOfferer.ScatterFill[] memory fills = new ScatterOfferer.ScatterFill[](1);
        fills[0] = ScatterOfferer.ScatterFill(0, 7, 2);
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](1);
        proofs[0][0] = keccak256("invalid proof");
        bytes memory signature = _sign(BIDDER_PK, offerer.hashSubmission(submission));
        orders[0].extraData = abi.encode(submission, signature, address(0), fills, proofs, uint256(0), bytes(""));
        vm.expectRevert();
        _sell(orders, _minimum(address(currency), 0), address(0));
        assertEq(nft1155.balanceOf(seller, 7), 20);
        proofs[0] = new bytes32[](0);
        orders[0].extraData = abi.encode(submission, signature, address(0), fills, proofs, uint256(0), bytes(""));
        _sell(orders, _minimum(address(currency), 3.8 ether), address(0));
        assertEq(nft1155.balanceOf(bidder, 7), 2);
        assertEq(currency.balanceOf(seller), 3.8 ether);
    }

    function testFuzz_nativeQuantityAndFundsAreConserved(uint256 quantity, uint256 price, uint256 dust) public {
        quantity = bound(quantity, 1, 20);
        price = bound(price, 1, 1 ether);
        dust = bound(dust, 0, 100 ether);
        currency.mint(address(router), dust);
        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = this.nativeOrder(true, 7, quantity, address(currency), price, address(0));
        _sell(orders, _minimum(address(currency), 0), address(0));
        assertEq(currency.balanceOf(bidder), 100 ether - price * quantity);
        assertEq(currency.balanceOf(seller) + currency.balanceOf(router.PLATFORM()), price * quantity);
        assertEq(currency.balanceOf(address(router)), dust);
        assertEq(currency.balanceOf(address(offerer)), 0);
        assertEq(nft1155.balanceOf(seller, 7) + nft1155.balanceOf(bidder, 7), 20);
        assertEq(nft1155.balanceOf(bidder, 7), quantity);
        assertFalse(nft1155.isApprovedForAll(address(router), address(seaport)));
    }

    function test_nativeAffiliateMustMatchBatchAffiliate() public {
        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = this.nativeOrder(false, 1, 1, address(currency), 1 ether, affiliate);
        vm.expectRevert(InvalidFeeAuthorization.selector);
        _sell(orders, _minimum(address(currency), 0), address(0));
        assertEq(nft721.ownerOf(1), seller);
    }

    function test_nativeDeclaredNftCannotSpendRouterDust() public {
        nft721.mint(address(router), 99);
        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = this.nativeOrder(false, 1, 1, address(currency), 1 ether, address(0));
        orders[0].parameters.consideration[0].identifierOrCriteria = 99;
        vm.expectRevert(InvalidConsiderationShape.selector);
        _sell(orders, _minimum(address(currency), 0), address(0));
        assertEq(nft721.ownerOf(99), address(router));
        assertEq(nft721.ownerOf(1), seller);
    }

    function test_nativeDeclaredCurrencyMustMatchSignedCurrency() public {
        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = this.nativeOrder(false, 1, 1, address(currency), 1 ether, address(0));
        orders[0].parameters.offer[0].token = address(secondCurrency);
        vm.expectRevert(InvalidBidCurrency.selector);
        _sell(orders, _minimum(address(secondCurrency), 0), address(0));
        assertEq(nft721.ownerOf(1), seller);
    }

    function test_nativeContractOrderCannotChooseAnotherOfferer() public {
        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = this.nativeOrder(false, 1, 1, address(currency), 1 ether, address(0));
        orders[0].parameters.offerer = address(currency);
        vm.expectRevert(InvalidScatterOfferer.selector);
        _sell(orders, _minimum(address(currency), 0), address(0));
    }

    function test_nativeRequiresTrustedRouterForSellerAttribution() public {
        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = this.nativeOrder(false, 1, 1, address(currency), 1 ether, address(0));
        offerer.setTrustedRouter(address(router), false);
        vm.expectRevert(InvalidScatterOfferer.selector);
        _sell(orders, _minimum(address(currency), 0), address(0));
    }

    function test_nativeCannotSellFromAnotherApprovedWallet() public {
        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = this.nativeOrder(false, 1, 1, address(currency), 1 ether, address(0));
        vm.expectRevert();
        vm.prank(makeAddr("attacker"));
        router.sellIntoBids(orders, _resolvers(1), address(0), _minimum(address(currency), 0), block.timestamp + 1, "");
        assertEq(nft721.ownerOf(1), seller);
    }

    function test_perCurrencyMinimumFailureRollsBackEarlierFill() public {
        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = this.nativeOrder(false, 1, 1, address(currency), 5 ether, address(0));
        orders[1] = _externalOrder(false, 2, 1, address(secondCurrency), 1 ether, 1, 1);
        ScatterBidRouter.MinimumPayout[] memory minima = new ScatterBidRouter.MinimumPayout[](2);
        minima[0] = ScatterBidRouter.MinimumPayout(address(currency), 0);
        minima[1] = ScatterBidRouter.MinimumPayout(address(secondCurrency), 1 ether);
        vm.expectRevert(InsufficientSellerPayout.selector);
        _sell(orders, minima, address(0));
        assertEq(nft721.ownerOf(1), seller);
        assertEq(nft721.ownerOf(2), seller);
        assertEq(currency.balanceOf(bidder), 100 ether);
        assertEq(secondCurrency.balanceOf(bidder), 100 ether);
    }

    function test_nativeCurrencyCallbackCannotReenterAndContextClears() public {
        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = this.nativeOrder(false, 1, 1, address(currency), 1 ether, address(0));
        currency.configureCallback(
            router,
            abi.encodeCall(
                router.sellIntoBids,
                (orders, _resolvers(1), address(0), _minimum(address(currency), 0), block.timestamp + 1, bytes(""))
            )
        );
        _sell(orders, _minimum(address(currency), 0.95 ether), address(0));
        assertTrue(currency.callbackAttempted());
        assertFalse(currency.callbackSucceeded());
        assertEq(currency.observedFulfiller(), seller);
        assertEq(router.activeRoutedFulfiller(), address(0));
        assertEq(nft721.ownerOf(1), bidder);
        assertEq(currency.balanceOf(seller), 0.95 ether);
    }

    function test_transferTaxCannotSatisfyNetSellerMinimum() public {
        currency.setTaxedSender(address(router));
        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = this.nativeOrder(false, 1, 1, address(currency), 1 ether, address(0));
        vm.expectRevert(CurrencyBalanceInvariant.selector);
        _sell(orders, _minimum(address(currency), 0.95 ether), address(0));
        assertEq(nft721.ownerOf(1), seller);
        assertEq(currency.balanceOf(bidder), 100 ether);
        assertEq(currency.balanceOf(seller), 0);
    }

    function nativeOrder(
        bool erc1155,
        uint256 tokenId,
        uint256 quantity,
        address token,
        uint256 price,
        address referrer
    ) external view returns (AdvancedOrder memory order) {
        ScatterOfferer.ScatterListing[] memory listings = new ScatterOfferer.ScatterListing[](1);
        listings[0] = ScatterOfferer.ScatterListing({
            assetType: erc1155 ? ScatterOfferer.AssetType.ERC1155 : ScatterOfferer.AssetType.ERC721,
            collection: erc1155 ? address(nft1155) : address(nft721),
            tokenId: tokenId,
            quantity: erc1155 ? 20 : 1,
            currency: token,
            priceWei: price
        });
        ScatterOfferer.ScatterSubmission memory submission = ScatterOfferer.ScatterSubmission({
            role: ScatterOfferer.Role.Bid,
            listings: listings,
            criteriaRoot: bytes32(0),
            maxFeeBps: 500,
            startTime: block.timestamp,
            endTime: block.timestamp + 1 hours,
            nonce: 0,
            salt: bytes32(tokenId)
        });
        ScatterOfferer.ScatterFill[] memory fills = new ScatterOfferer.ScatterFill[](1);
        fills[0] = ScatterOfferer.ScatterFill(0, tokenId, quantity);
        bytes32 submissionHash = offerer.hashSubmission(submission);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory feeSignature;
        if (referrer != address(0)) {
            feeSignature = _sign(
                AUTHORIZER_PK,
                _digest(
                    address(offerer),
                    "Scatter Marketplace",
                    keccak256(
                        abi.encode(
                            offerer.FEE_AUTHORIZATION_TYPEHASH(),
                            seller,
                            referrer,
                            submissionHash,
                            keccak256(abi.encode(fills)),
                            deadline
                        )
                    )
                )
            );
        }
        order.extraData = abi.encode(
            submission, _sign(BIDDER_PK, submissionHash), referrer, fills, new bytes32[][](0), deadline, feeSignature
        );
        (SpentItem[] memory offers, ReceivedItem[] memory considerations) =
            offerer.previewOrder(address(seaport), seller, new SpentItem[](0), new SpentItem[](0), order.extraData);
        order.parameters.offerer = address(offerer);
        order.parameters.orderType = OrderType.CONTRACT;
        order.parameters.startTime = block.timestamp;
        order.parameters.endTime = block.timestamp + 1 hours;
        order.parameters.offer = new OfferItem[](1);
        order.parameters.offer[0] =
            OfferItem(offers[0].itemType, offers[0].token, offers[0].identifier, offers[0].amount, offers[0].amount);
        order.parameters.consideration = new ConsiderationItem[](1);
        ReceivedItem memory item = considerations[0];
        order.parameters.consideration[0] =
            ConsiderationItem(item.itemType, item.token, item.identifier, item.amount, item.amount, item.recipient);
        order.parameters.totalOriginalConsiderationItems = 1;
        order.numerator = 1;
        order.denominator = 1;
    }

    function _externalOrder(
        bool erc1155,
        uint256 tokenId,
        uint256 quantity,
        address token,
        uint256 amount,
        uint120 numerator,
        uint120 denominator
    ) internal view returns (AdvancedOrder memory order) {
        order.parameters.offerer = bidder;
        order.parameters.orderType = denominator == 1 ? OrderType.FULL_OPEN : OrderType.PARTIAL_OPEN;
        order.parameters.startTime = block.timestamp;
        order.parameters.endTime = block.timestamp + 1 hours;
        order.parameters.salt = tokenId;
        order.parameters.conduitKey = conduitKey;
        order.parameters.offer = new OfferItem[](1);
        order.parameters.offer[0] = OfferItem(ItemType.ERC20, token, 0, amount, amount);
        order.parameters.consideration = new ConsiderationItem[](1);
        order.parameters.consideration[0] = ConsiderationItem(
            erc1155 ? ItemType.ERC1155 : ItemType.ERC721,
            erc1155 ? address(nft1155) : address(nft721),
            tokenId,
            quantity,
            quantity,
            payable(bidder)
        );
        order.parameters.totalOriginalConsiderationItems = 1;
        order.numerator = numerator;
        order.denominator = denominator;
        _signExternalOrder(order);
    }

    function _externalComponents(AdvancedOrder memory order) internal view returns (OrderComponents memory) {
        return OrderComponents({
            offerer: bidder,
            zone: address(0),
            offer: order.parameters.offer,
            consideration: order.parameters.consideration,
            orderType: order.parameters.orderType,
            startTime: order.parameters.startTime,
            endTime: order.parameters.endTime,
            zoneHash: bytes32(0),
            salt: order.parameters.salt,
            conduitKey: conduitKey,
            counter: 0
        });
    }

    function _signExternalOrder(AdvancedOrder memory order) internal view {
        (, bytes32 domainSeparator,) = seaport.information();
        order.signature = _sign(
            BIDDER_PK,
            keccak256(abi.encodePacked("\x19\x01", domainSeparator, seaport.getOrderHash(_externalComponents(order))))
        );
    }

    function _sell(AdvancedOrder[] memory orders, ScatterBidRouter.MinimumPayout[] memory minima, address referrer)
        internal
    {
        CriteriaResolver[][] memory resolvers = _resolvers(orders.length);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature;
        if (referrer != address(0)) {
            signature = _sign(
                AUTHORIZER_PK,
                _digest(
                    address(router),
                    "ScatterBidRouter",
                    keccak256(
                        abi.encode(
                            router.FEE_AUTHORIZATION_TYPEHASH(),
                            seller,
                            referrer,
                            keccak256(abi.encode(orders, resolvers)),
                            deadline
                        )
                    )
                )
            );
        }
        vm.prank(seller);
        router.sellIntoBids(orders, resolvers, referrer, minima, deadline, signature);
    }

    function _resolvers(uint256 count) internal pure returns (CriteriaResolver[][] memory resolvers) {
        resolvers = new CriteriaResolver[][](count);
        for (uint256 i; i < count; ++i) {
            resolvers[i] = new CriteriaResolver[](0);
        }
    }

    function _minimum(address token, uint256 amount)
        internal
        pure
        returns (ScatterBidRouter.MinimumPayout[] memory minima)
    {
        minima = new ScatterBidRouter.MinimumPayout[](1);
        minima[0] = ScatterBidRouter.MinimumPayout(token, amount);
    }

    function _digest(address verifyingContract, string memory name, bytes32 structHash)
        internal
        view
        returns (bytes32)
    {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256("1"),
                block.chainid,
                verifyingContract
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}

contract RouterE2EERC20 is ERC20 {
    ScatterBidRouter internal callbackRouter;
    bytes internal callbackData;
    bool public callbackAttempted;
    bool public callbackSucceeded;
    address public observedFulfiller;
    address internal taxedSender;

    constructor() ERC20("Bid currency", "BID") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configureCallback(ScatterBidRouter target, bytes memory data) external {
        callbackRouter = target;
        callbackData = data;
    }

    function setTaxedSender(address sender) external {
        taxedSender = sender;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (address(callbackRouter) != address(0) && !callbackAttempted) {
            callbackAttempted = true;
            observedFulfiller = callbackRouter.activeRoutedFulfiller();
            (callbackSucceeded,) = address(callbackRouter).call(callbackData);
        }
        uint256 tax = from != address(0) && from == taxedSender ? amount / 10 : 0;
        super._update(from, to, amount - tax);
        if (tax != 0) super._update(from, address(0), tax);
    }
}

contract RouterE2EERC721 is ERC721 {
    constructor() ERC721("NFT", "NFT") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}

contract RouterE2EERC1155 is ERC1155 {
    constructor() ERC1155("") {}

    function mint(address to, uint256 tokenId, uint256 amount) external {
        _mint(to, tokenId, amount, "");
    }
}
