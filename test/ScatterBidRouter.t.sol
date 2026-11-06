// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ConduitTest} from "./helpers/ConduitTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {
    ScatterBidRouter,
    InsufficientSellerPayout,
    InvalidBidCurrency,
    InvalidScatterOfferer,
    InvalidMinimumPayouts,
    InvalidConsiderationShape,
    InvalidOfferShape,
    MissingCriteriaResolver,
    SeaportCallFailed,
    InvalidFeeAuthorization,
    InvalidFeeAuthorizer,
    FeeAuthorizationExpired,
    InvalidFeeBps,
    InvalidFeeSplitBps
} from "../src/ScatterBidRouter.sol";
import {
    AdvancedOrder,
    CriteriaResolver,
    OfferItem,
    ConsiderationItem,
    OrderComponents,
    OrderParameters
} from "seaport-types/src/lib/ConsiderationStructs.sol";
import {ItemType, OrderType, Side} from "seaport-types/src/lib/ConsiderationEnums.sol";
import {ScatterCollectionRegistry} from "../src/ScatterCollectionRegistry.sol";

contract ScatterBidRouterTest is ConduitTest {
    uint256 internal constant FEE_AUTHORIZER_PK = 0xA11CE;
    address internal owner = makeAddr("owner");
    address internal seller = makeAddr("seller");
    address internal bidder = makeAddr("bidder");
    address internal affiliate = makeAddr("affiliate");
    address internal rewardsRecipient = makeAddr("rewardsRecipient");
    address internal openseaFee = makeAddr("openseaFee");
    address internal feeAuthorizer = vm.addr(FEE_AUTHORIZER_PK);

    MockERC20Bid internal currency;
    MockERC20Bid internal otherCurrency;
    MockERC721Bid internal nft721;
    MockERC1155Bid internal nft1155;
    ScatterBidRouter internal subject;
    MockBidSeaport internal seaport;
    address internal scatterOfferer;
    ScatterCollectionRegistry internal scatterCollectionRegistry;

    function setUp() public {
        _setUpConduit();
        currency = new MockERC20Bid();
        otherCurrency = new MockERC20Bid();
        nft721 = new MockERC721Bid();
        nft1155 = new MockERC1155Bid();
        scatterCollectionRegistry = new ScatterCollectionRegistry(address(this));
        scatterOfferer = address(new MockBidSeaport());
        subject = new ScatterBidRouter(owner, feeAuthorizer, scatterCollectionRegistry, scatterOfferer, conduitKey);
        vm.startPrank(owner);
        subject.setAllowedCurrency(address(currency), true);
        subject.setAllowedCurrency(address(otherCurrency), true);
        vm.stopPrank();
        _openConduitChannel(address(subject));
        _openConduitChannel(subject.SEAPORT());

        vm.etch(subject.SEAPORT(), address(new MockBidSeaport()).code);
        seaport = MockBidSeaport(subject.SEAPORT());

        nft721.mint(seller, 1);
        nft721.mint(seller, 2);
        nft1155.mint(seller, 1, 10);

        vm.startPrank(seller);
        nft721.setApprovalForAll(address(conduit), true);
        nft1155.setApprovalForAll(address(conduit), true);
        vm.stopPrank();
    }

    function test_constructorRejectsZeroScatterOfferer() public {
        vm.expectRevert(InvalidScatterOfferer.selector);
        new ScatterBidRouter(owner, feeAuthorizer, scatterCollectionRegistry, address(0), conduitKey);
    }

    function test_constructorRejectsNoCodeScatterOfferer() public {
        vm.expectRevert(InvalidScatterOfferer.selector);
        new ScatterBidRouter(owner, feeAuthorizer, scatterCollectionRegistry, makeAddr("noCodeOfferer"), conduitKey);
    }

    function test_constructorRejectsZeroFeeAuthorizer() public {
        vm.expectRevert(InvalidFeeAuthorizer.selector);
        new ScatterBidRouter(owner, address(0), scatterCollectionRegistry, scatterOfferer, conduitKey);
    }

    function test_transferOwnershipRequiresAcceptance() public {
        address nextOwner = makeAddr("nextOwner");

        vm.prank(owner);
        subject.transferOwnership(nextOwner);

        assertEq(subject.owner(), owner);
        assertEq(subject.pendingOwner(), nextOwner);

        vm.prank(nextOwner);
        subject.acceptOwnership();
        vm.prank(nextOwner);
        subject.setFeeBps(1000);

        assertEq(subject.owner(), nextOwner);
        assertEq(subject.pendingOwner(), address(0));
        assertEq(subject.feeBps(), 1000);
    }

    function test_setAllowedCurrency_isOwnerOnly() public {
        vm.prank(seller);
        vm.expectRevert();
        subject.setAllowedCurrency(address(currency), true);
    }

    function test_setAllowedCurrency_rejectsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(InvalidBidCurrency.selector);
        subject.setAllowedCurrency(address(0), true);
    }

    function test_sellIntoBids_rejectsCurrencyMissingFromTheAllowlist() public {
        AdvancedOrder memory order = _erc721Order(1, 1 ether);
        order.parameters.offer[0].token = address(new MockERC20Bid());

        vm.prank(seller);
        vm.expectRevert(InvalidBidCurrency.selector);
        _sell(order, _noResolvers(), address(0), 0, _authDeadline(), "");
    }

    function test_setAllowedCurrency_stopsSettlementAfterRemoval() public {
        vm.prank(owner);
        subject.setAllowedCurrency(address(currency), false);

        AdvancedOrder memory order = _erc721Order(1, 1 ether);
        vm.prank(seller);
        vm.expectRevert(InvalidBidCurrency.selector);
        _sell(order, _noResolvers(), address(0), 0, _authDeadline(), "");
    }

    function test_sellIntoBids_rejectsWrongFeeAuthorizationSigner() public {
        uint256 deadline = _authDeadline();
        AdvancedOrder memory order = _erc721Order(1, 1 ether);

        bytes memory signature = _feeAuth(order, affiliate, deadline, 0xB0B);

        vm.expectRevert(InvalidFeeAuthorization.selector);
        vm.prank(seller);
        _sell(order, _noResolvers(), affiliate, 0, deadline, signature);
    }

    function test_sellIntoBids_rejectsAuthorizationForDifferentSeller() public {
        uint256 deadline = _authDeadline();
        address otherSeller = makeAddr("otherSeller");
        AdvancedOrder memory order = _erc721Order(1, 1 ether);

        bytes memory signature = _feeAuthFor(seller, affiliate, _singleFillsHash(order), deadline, FEE_AUTHORIZER_PK);

        vm.expectRevert(InvalidFeeAuthorization.selector);
        vm.prank(otherSeller);
        _sell(order, _noResolvers(), affiliate, 0, deadline, signature);
    }

    function test_sellIntoBids_rejectsAuthorizationForDifferentAffiliate() public {
        uint256 deadline = _authDeadline();
        AdvancedOrder memory order = _erc721Order(1, 1 ether);

        bytes memory signature = _feeAuth(order, affiliate, deadline, FEE_AUTHORIZER_PK);

        vm.expectRevert(InvalidFeeAuthorization.selector);
        vm.prank(seller);
        _sell(order, _noResolvers(), rewardsRecipient, 0, deadline, signature);
    }

    function test_sellIntoBids_rejectsAuthorizationForDifferentOrder() public {
        uint256 deadline = _authDeadline();
        AdvancedOrder memory authorizedOrder = _erc721Order(1, 1 ether);
        AdvancedOrder memory submittedOrder = _erc721Order(2, 1 ether);

        bytes memory signature = _feeAuth(authorizedOrder, affiliate, deadline, FEE_AUTHORIZER_PK);

        vm.expectRevert(InvalidFeeAuthorization.selector);
        vm.prank(seller);
        _sell(submittedOrder, _noResolvers(), affiliate, 0, deadline, signature);
    }

    function test_sellIntoBids_rejectsAuthorizationForDifferentNftRecipient() public {
        uint256 deadline = _authDeadline();
        AdvancedOrder memory order = _erc721Order(1, 1 ether);
        bytes memory signature = _feeAuth(order, affiliate, deadline, FEE_AUTHORIZER_PK);
        order.parameters.consideration[0].recipient = payable(makeAddr("recipient"));

        vm.expectRevert(InvalidFeeAuthorization.selector);
        vm.prank(seller);
        _sell(order, _noResolvers(), affiliate, 0, deadline, signature);
        assertEq(nft721.ownerOf(1), seller);
        assertEq(currency.balanceOf(seller), 0);
    }

    function test_setFeeAuthorizer_rotatesAndOldSignaturesStopWorking() public {
        AdvancedOrder memory order = _erc721Order(1, 1 ether);
        uint256 deadline = _authDeadline();
        address newAuthorizer = vm.addr(0xB0B);

        vm.stopPrank();
        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true);
        emit ScatterBidRouter.FeeAuthorizerUpdated(feeAuthorizer, newAuthorizer);
        subject.setFeeAuthorizer(newAuthorizer);
        assertEq(subject.feeAuthorizer(), newAuthorizer);

        bytes memory staleSig = _feeAuth(order, affiliate, deadline, FEE_AUTHORIZER_PK);
        vm.stopPrank();
        vm.startPrank(seller);
        vm.expectRevert(InvalidFeeAuthorization.selector);
        _sell(order, _noResolvers(), affiliate, 0, deadline, staleSig);

        bytes memory freshSig = _feeAuthFor(seller, affiliate, _singleFillsHash(order), deadline, 0xB0B);
        vm.stopPrank();
        vm.startPrank(seller);
        _sell(order, _noResolvers(), affiliate, 0, deadline, freshSig);
    }

    function test_setFeeAuthorizer_revertsForNonOwner() public {
        vm.prank(seller);
        vm.expectRevert();
        subject.setFeeAuthorizer(vm.addr(0xB0B));
    }

    function test_setFeeAuthorizer_revertsForZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(InvalidFeeAuthorizer.selector);
        subject.setFeeAuthorizer(address(0));
    }

    function test_setFeeSplitBps_requiresOwnerAndValidBasisPoints() public {
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, seller));
        subject.setFeeSplitBps(3000);

        vm.startPrank(owner);
        vm.expectRevert(InvalidFeeSplitBps.selector);
        subject.setFeeSplitBps(10001);
        vm.expectRevert(InvalidFeeSplitBps.selector);
        subject.setFeeSplitBps(type(uint256).max);
        vm.expectEmit(true, true, true, true);
        emit ScatterBidRouter.FeeSplitBpsUpdated(5000, 3000);
        subject.setFeeSplitBps(3000);
        assertEq(subject.feeSplitBps(), 3000);
        vm.expectEmit(true, true, true, true);
        emit ScatterBidRouter.FeeSplitBpsUpdated(3000, 0);
        subject.setFeeSplitBps(0);
        assertEq(subject.feeSplitBps(), 0);
        vm.expectEmit(true, true, true, true);
        emit ScatterBidRouter.FeeSplitBpsUpdated(0, 10000);
        subject.setFeeSplitBps(10000);
        assertEq(subject.feeSplitBps(), 10000);
        vm.stopPrank();
    }

    function test_sellIntoBids_configurableFeeSplit_extremesAndAffiliatePrecedence() public {
        uint256[3] memory splits = [uint256(0), 3000, 10000];
        uint256 tokenId = 3;
        for (uint256 i; i < splits.length; i++) {
            for (uint8 recipientMode; recipientMode < 3; recipientMode++) {
                _assertConfiguredBidSettlement(splits[i], 1 ether, recipientMode, tokenId++);
            }
        }
    }

    function testFuzz_sellIntoBids_configurableFeeSplit_conservesProceeds(
        uint256 split,
        uint256 gross,
        uint8 recipientMode
    ) public {
        _assertConfiguredBidSettlement(
            bound(split, 0, 10000), bound(gross, 20, 2 ether), uint8(bound(recipientMode, 0, 2)), 3
        );
    }

    function _assertConfiguredBidSettlement(uint256 split, uint256 gross, uint8 recipientMode, uint256 tokenId)
        internal
    {
        vm.prank(owner);
        subject.setFeeSplitBps(split);
        scatterCollectionRegistry.setRewardsOverride(
            address(nft721), recipientMode == 0 ? address(0) : rewardsRecipient
        );
        nft721.mint(seller, tokenId);
        AdvancedOrder memory order = _erc721Order(tokenId, gross);
        address fillAffiliate = recipientMode == 2 ? affiliate : address(0);
        bytes memory signature =
            recipientMode == 2 ? _feeAuth(order, fillAffiliate, _authDeadline(), FEE_AUTHORIZER_PK) : bytes("");
        uint256 sellerBefore = currency.balanceOf(seller);
        uint256 platformBefore = currency.balanceOf(subject.PLATFORM());
        uint256 rewardsBefore = currency.balanceOf(rewardsRecipient);
        uint256 affiliateBefore = currency.balanceOf(affiliate);
        uint256 fee = gross * 500 / 10000;

        vm.prank(seller);
        _sell(order, _noResolvers(), fillAffiliate, gross - fee, _authDeadline(), signature);

        uint256 platformFee = recipientMode == 0 ? fee : fee * split / 10000;
        assertEq(nft721.ownerOf(tokenId), bidder);
        assertEq(currency.balanceOf(seller) - sellerBefore, gross - fee);
        assertEq(currency.balanceOf(subject.PLATFORM()) - platformBefore, platformFee);
        assertEq(currency.balanceOf(rewardsRecipient) - rewardsBefore, recipientMode == 1 ? fee - platformFee : 0);
        assertEq(currency.balanceOf(affiliate) - affiliateBefore, recipientMode == 2 ? fee - platformFee : 0);
        assertEq(currency.balanceOf(address(subject)), 0);
    }

    function test_sellIntoBids_usesFeeSplitFrozenAtEntryAcrossBatch() public {
        FeeSplitRotatingBidder rotatingBidder = new FeeSplitRotatingBidder(subject);
        scatterCollectionRegistry.setRewardsOverride(address(nft721), rewardsRecipient);
        scatterCollectionRegistry.setRewardsOverride(address(nft1155), rewardsRecipient);
        vm.startPrank(owner);
        subject.setFeeSplitBps(3000);
        subject.transferOwnership(address(rotatingBidder));
        vm.stopPrank();
        vm.prank(address(rotatingBidder));
        subject.acceptOwnership();

        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = _erc1155Order(1, 1, 1 ether, 1, 1);
        orders[0].parameters.offerer = address(rotatingBidder);
        orders[0].parameters.consideration[0].recipient = payable(address(rotatingBidder));
        orders[1] = _erc721Order(2, 1 ether);

        vm.prank(seller);
        _sellBatch(orders, new CriteriaResolver[][](2), address(0), 1.9 ether, _authDeadline(), "");

        assertEq(subject.feeSplitBps(), 10000);
        assertEq(nft1155.balanceOf(address(rotatingBidder), 1), 1);
        assertEq(nft721.ownerOf(2), bidder);
        assertEq(currency.balanceOf(seller), 1.9 ether);
        assertEq(currency.balanceOf(subject.PLATFORM()), 0.03 ether);
        assertEq(currency.balanceOf(rewardsRecipient), 0.07 ether);
        assertEq(currency.balanceOf(address(subject)), 0);
    }

    function test_setFeeBps_updatesFeeCharged() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit ScatterBidRouter.FeeBpsUpdated(500, 1000);
        subject.setFeeBps(1000);

        AdvancedOrder memory order = _erc721Order(1, 1 ether);
        vm.prank(seller);
        _sell(order, _noResolvers(), address(0), 0.9 ether, _authDeadline(), "");

        assertEq(subject.feeBps(), 1000);
        assertEq(currency.balanceOf(seller), 0.9 ether);
        assertEq(currency.balanceOf(subject.PLATFORM()), 0.1 ether);
    }

    function test_setFeeBps_revertsForNonOwner() public {
        vm.prank(seller);
        vm.expectRevert();
        subject.setFeeBps(1000);
    }

    function test_setFeeBps_revertsAboveMaximum() public {
        vm.prank(owner);
        vm.expectRevert(InvalidFeeBps.selector);
        subject.setFeeBps(5001);
    }

    function test_setFeeBps_acceptsMaximum() public {
        vm.prank(owner);
        subject.setFeeBps(5000);
        assertEq(subject.feeBps(), 5000);
    }

    function test_sellIntoBids_rejectsExpiredFeeAuthorization() public {
        uint256 deadline = block.timestamp - 1;
        AdvancedOrder memory order = _erc721Order(1, 1 ether);

        bytes memory signature = _feeAuth(order, affiliate, deadline, FEE_AUTHORIZER_PK);

        vm.expectRevert(FeeAuthorizationExpired.selector);
        vm.prank(seller);
        _sell(order, _noResolvers(), affiliate, 0, deadline, signature);
    }

    function test_sellIntoBids_acceptsMaximumFeeAuthorizationWindow() public {
        uint256 deadline = block.timestamp + subject.MAX_AUTHORIZATION_WINDOW();
        AdvancedOrder memory order = _erc721Order(1, 1 ether);
        bytes memory signature = _feeAuth(order, affiliate, deadline, FEE_AUTHORIZER_PK);

        vm.prank(seller);
        _sell(order, _noResolvers(), affiliate, 0, deadline, signature);

        assertEq(currency.balanceOf(affiliate), 0.025 ether);
    }

    function test_sellIntoBids_rejectsFeeAuthorizationBeyondMaximumWindow() public {
        uint256 deadline = block.timestamp + subject.MAX_AUTHORIZATION_WINDOW() + 1;
        AdvancedOrder memory order = _erc721Order(1, 1 ether);
        bytes memory signature = _feeAuth(order, affiliate, deadline, FEE_AUTHORIZER_PK);

        vm.expectRevert(InvalidFeeAuthorization.selector);
        vm.prank(seller);
        _sell(order, _noResolvers(), affiliate, 0, deadline, signature);
    }

    function test_sellIntoBids_affiliateTakesPriorityOverRegistryRewards() public {
        AdvancedOrder memory order = _erc721Order(1, 1 ether);
        uint256 deadline = _authDeadline();
        scatterCollectionRegistry.setRewardsOverride(address(nft721), rewardsRecipient);
        bytes memory signature = _feeAuth(order, affiliate, deadline, FEE_AUTHORIZER_PK);

        vm.prank(seller);
        _sell(order, _noResolvers(), affiliate, 0, deadline, signature);

        assertEq(currency.balanceOf(subject.PLATFORM()), 0.025 ether);
        assertEq(currency.balanceOf(affiliate), 0.025 ether);
        assertEq(currency.balanceOf(rewardsRecipient), 0);
    }

    function test_sellIntoBids_erc721PaysSellerAndEmitsFacts() public {
        AdvancedOrder memory order = _erc721Order(1, 1 ether);
        bytes32 orderHash = seaport.getOrderHash(_components(order.parameters));

        vm.expectEmit(true, true, true, true);
        emit ScatterBidRouter.ExternalBidFilled(
            seller,
            address(currency),
            orderHash,
            address(nft721),
            1,
            1,
            bidder,
            1 ether,
            0.05 ether,
            0.95 ether,
            address(0),
            address(0),
            0.05 ether,
            0,
            0
        );

        vm.prank(seller);
        _sell(order, _noResolvers(), address(0), 0, _authDeadline(), "");

        assertEq(nft721.ownerOf(1), bidder);
        assertEq(currency.balanceOf(seller), 0.95 ether);
        assertEq(currency.balanceOf(subject.PLATFORM()), 0.05 ether);
        assertEq(currency.balanceOf(address(subject)), 0);
    }

    function test_sellIntoBids_chargesFeeRateFrozenAtEntryAcrossBatch() public {
        FeeRotatingBidder rotatingBidder = new FeeRotatingBidder(subject);

        vm.prank(owner);
        subject.transferOwnership(address(rotatingBidder));
        vm.prank(address(rotatingBidder));
        subject.acceptOwnership();

        AdvancedOrder memory order = _erc1155Order(1, 1, 1 ether, 1, 1);
        order.parameters.offerer = address(rotatingBidder);
        order.parameters.consideration[0].recipient = payable(address(rotatingBidder));
        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = order;
        orders[1] = _erc721Order(2, 1 ether);

        vm.prank(seller);
        _sellBatch(orders, new CriteriaResolver[][](2), address(0), 1.9 ether, _authDeadline(), "");

        assertTrue(rotatingBidder.rotated());
        assertEq(subject.feeBps(), 5000);
        assertEq(nft1155.balanceOf(address(rotatingBidder), 1), 1);
        assertEq(nft721.ownerOf(2), bidder);
        assertEq(currency.balanceOf(seller), 1.9 ether);
        assertEq(currency.balanceOf(subject.PLATFORM()), 0.1 ether);
    }

    function test_sellIntoBids_erc1155PartialPaysPostFeeSellerPayout() public {
        vm.prank(seller);
        _sell(_erc1155Order(1, 10, 2 ether, 5, 10), _noResolvers(), address(0), 0.95 ether, _authDeadline(), "");

        assertEq(nft1155.balanceOf(bidder, 1), 5);
        assertEq(nft1155.balanceOf(seller, 1), 5);
        assertEq(currency.balanceOf(seller), 0.95 ether);
        assertEq(nft1155.isApprovedForAll(address(subject), subject.SEAPORT()), false);
    }

    function test_sellIntoBids_criteriaResolvesTokenId() public {
        vm.prank(seller);
        _sell(_erc721CriteriaOrder(1 ether), _criteriaResolvers(2), address(0), 0, _authDeadline(), "");

        assertEq(nft721.ownerOf(2), bidder);
        assertEq(currency.balanceOf(seller), 0.95 ether);
    }

    function test_sellIntoBids_externalFeeConsiderationReducesSellerPayoutBeforeScatterFee() public {
        AdvancedOrder memory order = _erc721OrderWithFee(1, 1 ether, 0.02 ether, openseaFee);

        scatterCollectionRegistry.setRewardsOverride(address(nft721), rewardsRecipient);

        vm.prank(seller);
        _sell(order, _noResolvers(), address(0), 0.931 ether, _authDeadline(), "");

        assertEq(currency.balanceOf(openseaFee), 0.02 ether);
        assertEq(currency.balanceOf(seller), 0.931 ether);
        assertEq(currency.balanceOf(subject.PLATFORM()), 0.0245 ether);
        assertEq(currency.balanceOf(rewardsRecipient), 0.0245 ether);
        assertEq(currency.allowance(address(subject), subject.SEAPORT()), 0);
    }

    function test_sellIntoBids_affiliateSplitsCurrentScatterFee() public {
        AdvancedOrder memory order = _erc721Order(1, 1 ether);
        uint256 deadline = _authDeadline();

        bytes memory signature = _feeAuth(order, affiliate, deadline, FEE_AUTHORIZER_PK);

        vm.prank(seller);
        _sell(order, _noResolvers(), affiliate, 0, deadline, signature);

        assertEq(currency.balanceOf(subject.PLATFORM()), 0.025 ether);
        assertEq(currency.balanceOf(affiliate), 0.025 ether);
        assertEq(currency.balanceOf(rewardsRecipient), 0);
    }

    function test_sellIntoBids_minSellerPayoutUsesPostExternalAndPostScatterAmount() public {
        AdvancedOrder memory order = _erc721OrderWithFee(1, 1 ether, 0.02 ether, openseaFee);

        vm.prank(seller);
        vm.expectRevert(InsufficientSellerPayout.selector);
        _sell(order, _noResolvers(), address(0), 0.932 ether, _authDeadline(), "");
    }

    function test_sellIntoBids_rejectsNoCodeOfferCurrency() public {
        AdvancedOrder memory order = _erc721Order(1, 1 ether);
        order.parameters.offer[0].token = makeAddr("noCodeCurrency");

        vm.prank(seller);
        vm.expectRevert(InvalidBidCurrency.selector);
        _sell(order, _noResolvers(), address(0), 0, _authDeadline(), "");
    }

    function test_sellIntoBids_rejectsWrongFeeCurrencyAndDirectSellerFeeRecipient() public {
        AdvancedOrder memory wrongCurrency = _erc721OrderWithFee(1, 1 ether, 0.02 ether, openseaFee);
        wrongCurrency.parameters.consideration[1].token = address(otherCurrency);

        vm.prank(seller);
        vm.expectRevert(InvalidBidCurrency.selector);
        _sell(wrongCurrency, _noResolvers(), address(0), 0, _authDeadline(), "");

        AdvancedOrder memory sellerRecipient = _erc721OrderWithFee(1, 1 ether, 0.02 ether, seller);
        vm.prank(seller);
        vm.expectRevert(InvalidConsiderationShape.selector);
        _sell(sellerRecipient, _noResolvers(), address(0), 0, _authDeadline(), "");
    }

    function test_sellIntoBids_rejectsMalformedOrder() public {
        AdvancedOrder memory order = _erc721Order(1, 1 ether);
        order.parameters.offer = new OfferItem[](2);

        vm.prank(seller);
        vm.expectRevert(InvalidOfferShape.selector);
        _sell(order, _noResolvers(), address(0), 0, _authDeadline(), "");
    }

    function test_sellIntoBids_rejectsMissingCriteriaResolver() public {
        vm.prank(seller);
        vm.expectRevert(MissingCriteriaResolver.selector);
        _sell(_erc721CriteriaOrder(1 ether), _noResolvers(), address(0), 0, _authDeadline(), "");
    }

    function test_sellIntoBids_rejectsReorderedAuthorization() public {
        AdvancedOrder[] memory authorizedOrders = new AdvancedOrder[](2);
        authorizedOrders[0] = _erc721Order(1, 1 ether);
        authorizedOrders[1] = _erc721Order(2, 1 ether);

        AdvancedOrder[] memory submittedOrders = new AdvancedOrder[](2);
        submittedOrders[0] = authorizedOrders[1];
        submittedOrders[1] = authorizedOrders[0];

        CriteriaResolver[][] memory resolvers = new CriteriaResolver[][](2);
        resolvers[0] = _noResolvers();
        resolvers[1] = _noResolvers();
        uint256 deadline = _authDeadline();

        bytes memory signature = _feeAuth(authorizedOrders, affiliate, deadline, FEE_AUTHORIZER_PK);

        vm.expectRevert(InvalidFeeAuthorization.selector);
        vm.prank(seller);
        _sellBatch(submittedOrders, resolvers, affiliate, 0, deadline, signature);
    }

    function test_sellIntoBids_rejectsDuplicateHashReplay() public {
        AdvancedOrder[] memory authorizedOrders = new AdvancedOrder[](2);
        authorizedOrders[0] = _erc721Order(1, 1 ether);
        authorizedOrders[1] = _erc721Order(2, 1 ether);

        AdvancedOrder[] memory submittedOrders = new AdvancedOrder[](2);
        submittedOrders[0] = authorizedOrders[0];
        submittedOrders[1] = authorizedOrders[0];

        CriteriaResolver[][] memory resolvers = new CriteriaResolver[][](2);
        resolvers[0] = _noResolvers();
        resolvers[1] = _noResolvers();
        uint256 deadline = _authDeadline();

        bytes memory signature = _feeAuth(authorizedOrders, affiliate, deadline, FEE_AUTHORIZER_PK);

        vm.expectRevert(InvalidFeeAuthorization.selector);
        vm.prank(seller);
        _sellBatch(submittedOrders, resolvers, affiliate, 0, deadline, signature);
    }

    function test_sellIntoBids_acceptsValidAffiliateAuthorization() public {
        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = _erc721Order(1, 1 ether);
        orders[1] = _erc721Order(2, 1 ether);
        CriteriaResolver[][] memory resolvers = new CriteriaResolver[][](2);
        resolvers[0] = _noResolvers();
        resolvers[1] = _noResolvers();
        uint256 deadline = _authDeadline();

        bytes memory signature = _feeAuth(orders, affiliate, deadline, FEE_AUTHORIZER_PK);

        vm.prank(seller);
        _sellBatch(orders, resolvers, affiliate, 1.9 ether, deadline, signature);

        assertEq(nft721.ownerOf(1), bidder);
        assertEq(nft721.ownerOf(2), bidder);
        assertEq(currency.balanceOf(seller), 1.9 ether);
        assertEq(currency.balanceOf(subject.PLATFORM()), 0.05 ether);
        assertEq(currency.balanceOf(affiliate), 0.05 ether);
    }

    function test_sellIntoBids_revertsAtomicallyWhenSecondFillFails() public {
        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = _erc721Order(1, 1 ether);
        orders[1] = _erc721Order(2, 1 ether);
        CriteriaResolver[][] memory resolvers = new CriteriaResolver[][](2);
        resolvers[0] = _noResolvers();
        resolvers[1] = _noResolvers();
        seaport.setReturnFalseOnCall(2);

        vm.prank(seller);
        vm.expectRevert(SeaportCallFailed.selector);
        _sellBatch(orders, resolvers, address(0), 0, _authDeadline(), "");

        assertEq(nft721.ownerOf(1), seller);
        assertEq(nft721.ownerOf(2), seller);
        assertEq(currency.balanceOf(seller), 0);
    }

    function test_sellIntoBids_cleansApprovalsWhenSeaportReturnsFalse() public {
        AdvancedOrder memory order = _erc1155Order(1, 4, 1 ether, 1, 1);
        order.parameters.consideration = new ConsiderationItem[](2);
        order.parameters.consideration[0] = _erc1155Item(1, 4);
        order.parameters.consideration[1] = _erc20ConsiderationItem(0.02 ether, openseaFee);
        order.parameters.totalOriginalConsiderationItems = 2;
        seaport.setReturnFalseOnCall(1);

        vm.prank(seller);
        vm.expectRevert(SeaportCallFailed.selector);
        _sell(order, _noResolvers(), address(0), 0, _authDeadline(), "");

        assertEq(currency.allowance(address(subject), subject.SEAPORT()), 0);
        assertEq(nft1155.isApprovedForAll(address(subject), subject.SEAPORT()), false);
    }

    function test_pauseBlocksSales() public {
        vm.prank(owner);
        subject.pause();
        vm.prank(seller);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _sell(_erc721Order(1, 1 ether), _noResolvers(), address(0), 0, _authDeadline(), "");
    }

    function test_sellIntoBids_allowsErc721RecipientWithoutReceiverHook() public {
        address recipient = address(otherCurrency);
        AdvancedOrder memory order = _erc721Order(1, 1 ether);
        order.parameters.offerer = recipient;
        order.parameters.consideration[0].recipient = payable(recipient);

        vm.prank(seller);
        _sell(order, _noResolvers(), address(0), 0, _authDeadline(), "");

        assertEq(nft721.ownerOf(1), recipient);
        assertEq(currency.balanceOf(seller), 0.95 ether);
        assertEq(currency.balanceOf(subject.PLATFORM()), 0.05 ether);
        assertEq(currency.balanceOf(address(subject)), 0);
    }

    function test_sellIntoBids_zeroAffiliateIgnoresDeadlineButRequiresEmptySignature() public {
        AdvancedOrder memory order = _erc721Order(1, 1 ether);

        bytes memory signature = _feeAuth(order, address(0), _authDeadline(), FEE_AUTHORIZER_PK);
        vm.expectRevert(InvalidFeeAuthorization.selector);
        vm.prank(seller);
        _sell(order, _noResolvers(), address(0), 0, 0, signature);

        vm.prank(seller);
        _sell(order, _noResolvers(), address(0), 0.95 ether, 0, "");
        assertEq(nft721.ownerOf(1), bidder);
        assertEq(currency.balanceOf(seller), 0.95 ether);

        order = _erc721Order(2, 1 ether);
        vm.prank(seller);
        _sell(order, _noResolvers(), address(0), 0.95 ether, type(uint256).max, "");
        assertEq(nft721.ownerOf(2), bidder);
        assertEq(currency.balanceOf(seller), 1.9 ether);
    }

    function test_sellIntoBids_multiCurrencyMinimaUseAggregatedNetPayouts() public {
        AdvancedOrder[] memory orders = new AdvancedOrder[](3);
        orders[0] = _erc721OrderWithFee(1, 1 ether, 0.02 ether, openseaFee);
        orders[1] = _erc721OrderWithFee(2, 2 ether, 0.04 ether, openseaFee);
        orders[1].parameters.offer[0].token = address(otherCurrency);
        orders[1].parameters.consideration[1].token = address(otherCurrency);
        orders[2] = _erc1155Order(1, 2, 0.5 ether, 1, 1);
        CriteriaResolver[][] memory resolvers = new CriteriaResolver[][](3);
        ScatterBidRouter.MinimumPayout[] memory minima = new ScatterBidRouter.MinimumPayout[](2);
        minima[0] = ScatterBidRouter.MinimumPayout(address(otherCurrency), 1.862 ether + 1);
        minima[1] = ScatterBidRouter.MinimumPayout(address(currency), 1.406 ether);

        vm.expectRevert(InsufficientSellerPayout.selector);
        vm.prank(seller);
        subject.sellIntoBids(orders, resolvers, address(0), minima, _authDeadline(), "");
        assertEq(nft721.ownerOf(1), seller);
        assertEq(nft721.ownerOf(2), seller);
        assertEq(nft1155.balanceOf(seller, 1), 10);
        assertEq(currency.balanceOf(seller), 0);
        assertEq(otherCurrency.balanceOf(seller), 0);
        assertEq(currency.balanceOf(openseaFee), 0);
        assertEq(otherCurrency.balanceOf(openseaFee), 0);

        minima[0].amount = 1.862 ether;
        vm.prank(seller);
        subject.sellIntoBids(orders, resolvers, address(0), minima, _authDeadline(), "");
        assertEq(nft721.ownerOf(1), bidder);
        assertEq(nft721.ownerOf(2), bidder);
        assertEq(nft1155.balanceOf(bidder, 1), 2);
        assertEq(currency.balanceOf(seller), 1.406 ether);
        assertEq(otherCurrency.balanceOf(seller), 1.862 ether);
        assertEq(currency.balanceOf(openseaFee), 0.02 ether);
        assertEq(otherCurrency.balanceOf(openseaFee), 0.04 ether);
        assertEq(currency.balanceOf(subject.PLATFORM()), 0.074 ether);
        assertEq(otherCurrency.balanceOf(subject.PLATFORM()), 0.098 ether);
        assertEq(currency.balanceOf(address(subject)), 0);
        assertEq(otherCurrency.balanceOf(address(subject)), 0);
        assertEq(currency.allowance(address(subject), subject.SEAPORT()), 0);
        assertEq(otherCurrency.allowance(address(subject), subject.SEAPORT()), 0);
    }

    function test_sellIntoBids_minimaRequireExactCurrencyCoverageWithoutDuplicates() public {
        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = _erc721Order(1, 1 ether);
        orders[1] = _erc721Order(2, 1 ether);
        orders[1].parameters.offer[0].token = address(otherCurrency);
        CriteriaResolver[][] memory resolvers = new CriteriaResolver[][](2);

        vm.expectRevert(InvalidMinimumPayouts.selector);
        vm.prank(seller);
        subject.sellIntoBids(
            orders, resolvers, address(0), new ScatterBidRouter.MinimumPayout[](0), _authDeadline(), ""
        );

        vm.expectRevert(InvalidMinimumPayouts.selector);
        vm.prank(seller);
        subject.sellIntoBids(orders, resolvers, address(0), _minimum(address(currency), 0), _authDeadline(), "");

        ScatterBidRouter.MinimumPayout[] memory minima = new ScatterBidRouter.MinimumPayout[](2);
        minima[0] = ScatterBidRouter.MinimumPayout(address(currency), 0);
        minima[1] = ScatterBidRouter.MinimumPayout(address(currency), 0);
        vm.expectRevert(InvalidMinimumPayouts.selector);
        vm.prank(seller);
        subject.sellIntoBids(orders, resolvers, address(0), minima, _authDeadline(), "");

        orders[1].parameters.offer[0].token = address(currency);
        minima[1].currency = address(otherCurrency);
        vm.expectRevert(InvalidMinimumPayouts.selector);
        vm.prank(seller);
        subject.sellIntoBids(orders, resolvers, address(0), minima, _authDeadline(), "");

        assertEq(nft721.ownerOf(1), seller);
        assertEq(nft721.ownerOf(2), seller);
        assertEq(currency.balanceOf(seller), 0);
        assertEq(otherCurrency.balanceOf(seller), 0);
    }

    function test_sellIntoBids_authorizationBindsCriteriaAndFractionForEntireBatch() public {
        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = _erc1155Order(1, 10, 2 ether, 1, 2);
        orders[0].parameters.consideration[0].itemType = ItemType.ERC1155_WITH_CRITERIA;
        orders[0].parameters.consideration[0].identifierOrCriteria = 0;
        orders[1] = _erc721Order(1, 1 ether);
        CriteriaResolver[][] memory resolvers = new CriteriaResolver[][](2);
        resolvers[0] = _criteriaResolvers(1);
        uint256 deadline = _authDeadline();
        bytes memory signature =
            _feeAuthFor(seller, affiliate, keccak256(abi.encode(orders, resolvers)), deadline, FEE_AUTHORIZER_PK);

        resolvers[0][0].identifier = 2;
        vm.expectRevert(InvalidFeeAuthorization.selector);
        vm.prank(seller);
        _sellBatch(orders, resolvers, affiliate, 0, deadline, signature);

        resolvers[0][0].identifier = 1;
        resolvers[0][0].criteriaProof = new bytes32[](1);
        resolvers[0][0].criteriaProof[0] = keccak256("different proof");
        vm.expectRevert(InvalidFeeAuthorization.selector);
        vm.prank(seller);
        _sellBatch(orders, resolvers, affiliate, 0, deadline, signature);

        resolvers[0][0].criteriaProof = new bytes32[](0);
        orders[0].numerator = 2;
        vm.expectRevert(InvalidFeeAuthorization.selector);
        vm.prank(seller);
        _sellBatch(orders, resolvers, affiliate, 0, deadline, signature);

        orders[0].numerator = 1;
        orders[0].denominator = 5;
        vm.expectRevert(InvalidFeeAuthorization.selector);
        vm.prank(seller);
        _sellBatch(orders, resolvers, affiliate, 0, deadline, signature);

        orders[0].denominator = 2;
        vm.prank(seller);
        _sellBatch(orders, resolvers, affiliate, 1.9 ether, deadline, signature);
        assertEq(nft1155.balanceOf(bidder, 1), 5);
        assertEq(nft1155.balanceOf(seller, 1), 5);
        assertEq(nft721.ownerOf(1), bidder);
        assertEq(currency.balanceOf(seller), 1.9 ether);
        assertEq(currency.balanceOf(affiliate), 0.05 ether);
    }

    function test_sellIntoBids_repeatedOrderUsesRemainingCapacityAtEachFill() public {
        AdvancedOrder memory order = _erc1155Order(1, 10, 2 ether, 3, 5);
        order.parameters.consideration = new ConsiderationItem[](2);
        order.parameters.consideration[0] = _erc1155Item(1, 10);
        order.parameters.consideration[1] = _erc20ConsiderationItem(0.1 ether, openseaFee);
        order.parameters.totalOriginalConsiderationItems = 2;
        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = order;
        orders[1] = order;
        CriteriaResolver[][] memory resolvers = new CriteriaResolver[][](2);
        uint256 deadline = _authDeadline();
        bytes memory signature = _feeAuth(orders, affiliate, deadline, FEE_AUTHORIZER_PK);

        vm.prank(seller);
        _sellBatch(orders, resolvers, affiliate, 1.805 ether, deadline, signature);

        assertEq(nft1155.balanceOf(seller, 1), 0);
        assertEq(nft1155.balanceOf(bidder, 1), 10);
        assertEq(nft1155.balanceOf(address(subject), 1), 0);
        assertEq(currency.balanceOf(seller), 1.805 ether);
        assertEq(currency.balanceOf(openseaFee), 0.1 ether);
        assertEq(currency.balanceOf(subject.PLATFORM()), 0.0475 ether);
        assertEq(currency.balanceOf(affiliate), 0.0475 ether);
        assertEq(currency.allowance(address(subject), subject.SEAPORT()), 0);
        assertFalse(nft1155.isApprovedForAll(address(subject), subject.SEAPORT()));
        (,, uint256 filled, uint256 size) = seaport.getOrderStatus(seaport.getOrderHash(_components(order.parameters)));
        assertEq(filled, size);
        assertGt(size, 0);
    }

    function _authDeadline() internal view returns (uint256) {
        return block.timestamp + 1 hours;
    }

    function _feeAuth(AdvancedOrder memory order, address authAffiliate, uint256 deadline, uint256 signerPk)
        internal
        view
        returns (bytes memory)
    {
        return _feeAuthFor(seller, authAffiliate, _singleFillsHash(order), deadline, signerPk);
    }

    function _feeAuth(AdvancedOrder[] memory orders, address authAffiliate, uint256 deadline, uint256 signerPk)
        internal
        view
        returns (bytes memory)
    {
        return _feeAuthFor(seller, authAffiliate, _batchFillsHash(orders), deadline, signerPk);
    }

    function _feeAuthFor(
        address authSeller,
        address authAffiliate,
        bytes32 fillsHash,
        uint256 deadline,
        uint256 signerPk
    ) internal view returns (bytes memory) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("ScatterBidRouter"),
                keccak256("1"),
                block.chainid,
                address(subject)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("FeeAuthorization(address seller,address affiliate,bytes32 fillsHash,uint256 deadline)"),
                authSeller,
                authAffiliate,
                fillsHash,
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(signerPk, keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _singleFillsHash(AdvancedOrder memory order) internal pure returns (bytes32) {
        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = order;
        return keccak256(abi.encode(orders, new CriteriaResolver[][](1)));
    }

    function _batchFillsHash(AdvancedOrder[] memory orders) internal pure returns (bytes32) {
        return keccak256(abi.encode(orders, new CriteriaResolver[][](orders.length)));
    }

    function _sell(
        AdvancedOrder memory order,
        CriteriaResolver[] memory resolvers,
        address authAffiliate,
        uint256 minimum,
        uint256 deadline,
        bytes memory signature
    ) internal {
        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = order;
        CriteriaResolver[][] memory batchResolvers = new CriteriaResolver[][](1);
        batchResolvers[0] = resolvers;
        _sellBatch(orders, batchResolvers, authAffiliate, minimum, deadline, signature);
    }

    function _sellBatch(
        AdvancedOrder[] memory orders,
        CriteriaResolver[][] memory resolvers,
        address authAffiliate,
        uint256 minimum,
        uint256 deadline,
        bytes memory signature
    ) internal {
        subject.sellIntoBids(
            orders, resolvers, authAffiliate, _minimum(address(currency), minimum), deadline, signature
        );
    }

    function _minimum(address token, uint256 amount)
        internal
        pure
        returns (ScatterBidRouter.MinimumPayout[] memory minima)
    {
        minima = new ScatterBidRouter.MinimumPayout[](1);
        minima[0] = ScatterBidRouter.MinimumPayout({currency: token, amount: amount});
    }

    function _erc721Order(uint256 tokenId, uint256 amount) internal view returns (AdvancedOrder memory order) {
        order = _baseOrder(amount, 1, 1);
        order.parameters.consideration = new ConsiderationItem[](1);
        order.parameters.consideration[0] = ConsiderationItem({
            itemType: ItemType.ERC721,
            token: address(nft721),
            identifierOrCriteria: tokenId,
            startAmount: 1,
            endAmount: 1,
            recipient: payable(bidder)
        });
        order.parameters.totalOriginalConsiderationItems = 1;
    }

    function _erc721CriteriaOrder(uint256 amount) internal view returns (AdvancedOrder memory order) {
        order = _baseOrder(amount, 1, 1);
        order.parameters.consideration = new ConsiderationItem[](1);
        order.parameters.consideration[0] = ConsiderationItem({
            itemType: ItemType.ERC721_WITH_CRITERIA,
            token: address(nft721),
            identifierOrCriteria: 0,
            startAmount: 1,
            endAmount: 1,
            recipient: payable(bidder)
        });
        order.parameters.totalOriginalConsiderationItems = 1;
    }

    function _erc721OrderWithFee(uint256 tokenId, uint256 amount, uint256 fee, address feeRecipient)
        internal
        view
        returns (AdvancedOrder memory order)
    {
        order = _erc721Order(tokenId, amount);
        order.parameters.consideration = new ConsiderationItem[](2);
        order.parameters.consideration[0] = ConsiderationItem({
            itemType: ItemType.ERC721,
            token: address(nft721),
            identifierOrCriteria: tokenId,
            startAmount: 1,
            endAmount: 1,
            recipient: payable(bidder)
        });
        order.parameters.consideration[1] = _erc20ConsiderationItem(fee, feeRecipient);
        order.parameters.totalOriginalConsiderationItems = 2;
    }

    function _erc1155Order(uint256 tokenId, uint256 quantity, uint256 amount, uint120 numerator, uint120 denominator)
        internal
        view
        returns (AdvancedOrder memory order)
    {
        order = _baseOrder(amount, numerator, denominator);
        order.parameters.orderType = denominator == 1 ? OrderType.FULL_OPEN : OrderType.PARTIAL_OPEN;
        order.parameters.consideration = new ConsiderationItem[](1);
        order.parameters.consideration[0] = _erc1155Item(tokenId, quantity);
        order.parameters.totalOriginalConsiderationItems = 1;
    }

    function _baseOrder(uint256 amount, uint120 numerator, uint120 denominator)
        internal
        view
        returns (AdvancedOrder memory order)
    {
        order.parameters.offerer = bidder;
        order.parameters.orderType = OrderType.FULL_OPEN;
        order.parameters.startTime = block.timestamp;
        order.parameters.endTime = block.timestamp + 1 hours;
        order.parameters.salt = uint256(keccak256(abi.encode(amount, numerator, denominator, block.timestamp)));
        order.parameters.offer = new OfferItem[](1);
        order.parameters.offer[0] = OfferItem({
            itemType: ItemType.ERC20,
            token: address(currency),
            identifierOrCriteria: 0,
            startAmount: amount,
            endAmount: amount
        });
        order.numerator = numerator;
        order.denominator = denominator;
    }

    function _erc1155Item(uint256 tokenId, uint256 quantity) internal view returns (ConsiderationItem memory) {
        return ConsiderationItem({
            itemType: ItemType.ERC1155,
            token: address(nft1155),
            identifierOrCriteria: tokenId,
            startAmount: quantity,
            endAmount: quantity,
            recipient: payable(bidder)
        });
    }

    function _erc20ConsiderationItem(uint256 amount, address recipient)
        internal
        view
        returns (ConsiderationItem memory)
    {
        return ConsiderationItem({
            itemType: ItemType.ERC20,
            token: address(currency),
            identifierOrCriteria: 0,
            startAmount: amount,
            endAmount: amount,
            recipient: payable(recipient)
        });
    }

    function _criteriaResolvers(uint256 identifier) internal pure returns (CriteriaResolver[] memory resolvers) {
        resolvers = new CriteriaResolver[](1);
        resolvers[0] = CriteriaResolver({
            orderIndex: 0, side: Side.CONSIDERATION, index: 0, identifier: identifier, criteriaProof: new bytes32[](0)
        });
    }

    function _noResolvers() internal pure returns (CriteriaResolver[] memory) {
        return new CriteriaResolver[](0);
    }

    function _components(OrderParameters memory params) internal view returns (OrderComponents memory) {
        return OrderComponents({
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
            counter: seaport.getCounter(params.offerer)
        });
    }
}

contract MockBidSeaport {
    uint256 public calls;
    uint256 public returnFalseOnCall;

    struct FillStatus {
        uint256 numerator;
        uint256 denominator;
    }
    mapping(bytes32 => FillStatus) internal fills;

    function setReturnFalseOnCall(uint256 callNumber) external {
        returnFalseOnCall = callNumber;
    }

    function getCounter(address) external pure returns (uint256) {
        return 0;
    }

    function getOrderHash(OrderComponents calldata components) external pure returns (bytes32) {
        return keccak256(abi.encode(components));
    }

    function getOrderStatus(bytes32 orderHash) external view returns (bool, bool, uint256, uint256) {
        FillStatus memory status = fills[orderHash];
        return (false, false, status.numerator, status.denominator);
    }

    function fulfillAdvancedOrder(
        AdvancedOrder calldata order,
        CriteriaResolver[] calldata resolvers,
        bytes32,
        address recipient
    ) external returns (bool) {
        calls++;
        if (calls == returnFalseOnCall) return false;

        uint256 numerator = order.numerator;
        uint256 denominator = order.denominator;
        OrderParameters calldata params = order.parameters;
        bytes32 orderHash = keccak256(
            abi.encode(
                OrderComponents({
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
                    counter: 0
                })
            )
        );
        FillStatus storage status = fills[orderHash];
        if (status.denominator == 0) {
            status.numerator = numerator;
            status.denominator = denominator;
        } else {
            uint256 remaining = (status.denominator - status.numerator) * denominator;
            uint256 requested = numerator * status.denominator;
            numerator = requested < remaining ? requested : remaining;
            uint256 previouslyFilled = status.numerator * denominator;
            denominator *= status.denominator;
            status.numerator = previouslyFilled + numerator;
            status.denominator = denominator;
        }
        require(numerator != 0, "MockBidSeaport: already filled");

        uint256 proceeds = (order.parameters.offer[0].startAmount * numerator) / denominator;
        MockERC20Bid(order.parameters.offer[0].token).mint(recipient, proceeds);

        for (uint256 i = 0; i < order.parameters.consideration.length; i++) {
            ConsiderationItem calldata item = order.parameters.consideration[i];
            uint256 amount = (item.startAmount * numerator) / denominator;
            if (item.itemType == ItemType.ERC721 || item.itemType == ItemType.ERC721_WITH_CRITERIA) {
                uint256 tokenId = item.itemType == ItemType.ERC721_WITH_CRITERIA
                    ? _resolveIdentifier(resolvers, i)
                    : item.identifierOrCriteria;
                ERC721(item.token).transferFrom(msg.sender, order.parameters.offerer, tokenId);
            } else if (item.itemType == ItemType.ERC1155 || item.itemType == ItemType.ERC1155_WITH_CRITERIA) {
                uint256 tokenId = item.itemType == ItemType.ERC1155_WITH_CRITERIA
                    ? _resolveIdentifier(resolvers, i)
                    : item.identifierOrCriteria;
                ERC1155(item.token).safeTransferFrom(msg.sender, order.parameters.offerer, tokenId, amount, "");
            } else if (item.itemType == ItemType.ERC20) {
                bool transferred = IERC20(item.token).transferFrom(msg.sender, item.recipient, amount);
                require(transferred, "MockBidSeaport: transferFrom failed");
            }
        }

        return true;
    }

    function _resolveIdentifier(CriteriaResolver[] calldata resolvers, uint256 index) internal pure returns (uint256) {
        for (uint256 i = 0; i < resolvers.length; i++) {
            if (resolvers[i].side == Side.CONSIDERATION && resolvers[i].index == index) return resolvers[i].identifier;
        }
        return 0;
    }
}

contract MockERC20Bid is ERC20 {
    constructor() ERC20("MockBid", "MBID") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockERC721Bid is ERC721 {
    constructor() ERC721("Mock721Bid", "M721B") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}

contract MockERC1155Bid is ERC1155 {
    constructor() ERC1155("") {}

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }
}

contract FeeSplitRotatingBidder is ERC1155Holder {
    ScatterBidRouter private immutable router;

    constructor(ScatterBidRouter router_) {
        router = router_;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes memory) public override returns (bytes4) {
        router.setFeeSplitBps(10000);
        return this.onERC1155Received.selector;
    }
}

contract FeeRotatingBidder is ERC1155Holder {
    ScatterBidRouter private immutable router;
    bool public rotated;

    constructor(ScatterBidRouter router_) {
        router = router_;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes memory) public override returns (bytes4) {
        router.setFeeBps(5000);
        rotated = true;
        return this.onERC1155Received.selector;
    }
}
