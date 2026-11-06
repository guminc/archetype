// SPDX-License-Identifier: MIT
// forge-lint: disable-start(mixed-case-function, mixed-case-variable, asm-keccak256)
pragma solidity 0.8.36;

import {ConduitTest} from "./helpers/ConduitTest.sol";
import {Vm} from "forge-std/Vm.sol";
import {
    ScatterOfferer,
    OrderCancelled,
    QuantityExceeded,
    CurrencyMismatch,
    DuplicateListingItem,
    InvalidCriteriaProof,
    NonceMismatch
} from "../src/ScatterOfferer.sol";
import {
    AdvancedOrder,
    ConsiderationItem,
    CriteriaResolver,
    OfferItem,
    OrderParameters,
    ReceivedItem,
    SpentItem
} from "seaport-types/src/lib/ConsiderationStructs.sol";
import {ItemType, OrderType} from "seaport-types/src/lib/ConsiderationEnums.sol";
import {SeaportInterface} from "seaport-types/src/interfaces/SeaportInterface.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ScatterCollectionRegistry} from "../src/ScatterCollectionRegistry.sol";

contract ScatterOffererE2ETest is ConduitTest {
    uint256 internal constant FEE_AUTHORIZER_PK = 0xA11CE;

    address internal SEAPORT;
    address internal PLATFORM;
    uint256 internal FEE_BPS;
    uint256 internal FEE_SPLIT_BPS;
    uint256 internal BPS_DENOMINATOR;

    ScatterOfferer internal subject;
    ScatterCollectionRegistry internal scatterCollectionRegistry;

    MockERC721E2E internal nft721;
    MockERC1155E2E internal nft1155;
    MockERC20E2E internal weth;
    SeaportInterface internal seaport;

    address internal owner;
    address internal seller;
    address internal bidder;
    address internal buyer;
    address internal rewardsRecipient;
    address internal affiliate;
    address internal other;
    address internal feeAuthorizer = vm.addr(FEE_AUTHORIZER_PK);

    uint256 internal constant SELLER_PK = uint256(keccak256("seller"));
    uint256 internal constant BIDDER_PK = uint256(keccak256("bidder"));

    function setUp() public virtual {
        _setUpConduit();
        vm.txGasPrice(0);

        owner = makeAddr("owner");
        seller = vm.addr(SELLER_PK);
        bidder = vm.addr(BIDDER_PK);
        buyer = makeAddr("buyer");
        rewardsRecipient = makeAddr("rewardsRecipient");
        affiliate = makeAddr("affiliate");
        other = makeAddr("other");

        vm.deal(buyer, 100 ether);

        scatterCollectionRegistry = new ScatterCollectionRegistry(address(this));
        subject = new ScatterOfferer(owner, scatterCollectionRegistry, feeAuthorizer, conduitKey);
        _openConduitChannel(address(subject));
        _openConduitChannel(subject.SEAPORT());

        SEAPORT = subject.SEAPORT();
        PLATFORM = subject.PLATFORM();
        FEE_BPS = subject.feeBps();
        FEE_SPLIT_BPS = subject.feeSplitBps();
        BPS_DENOMINATOR = subject.BPS_DENOMINATOR();

        _setUpSeaport(SEAPORT);
        seaport = SeaportInterface(SEAPORT);

        nft721 = new MockERC721E2E();
        nft1155 = new MockERC1155E2E();
        weth = new MockERC20E2E();

        nft721.mint(seller, 1);
        nft721.mint(seller, 2);
        nft1155.mint(seller, 1, 10);
        weth.mint(bidder, 100 ether);
        weth.mint(buyer, 100 ether);

        _prank(other);
    }

    function test_e2e_pause_blocksListingsAndBidsUntilUnpaused(bool isBid) public {
        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);
        _prank(bidder);
        weth.approve(address(conduit), type(uint256).max);

        ScatterOfferer.ScatterSubmission memory submission = _generateListing(
            GenerateListingParams({
                role: isBid ? ScatterOfferer.Role.Bid : ScatterOfferer.Role.Listing,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: isBid ? 0 : 1,
                criteriaRoot: bytes32(0),
                quantity: 1,
                currency: isBid ? address(weth) : address(0),
                priceWei: 1 ether,
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours,
                nonce: 0,
                salt: bytes32(uint256(0xdead))
            })
        );
        AdvancedOrder memory order = _buildSeaportOrder(
            BuildContractOrderParams({
                listing: submission,
                signerPk: isBid ? BIDDER_PK : SELLER_PK,
                affiliate: address(0),
                fillTokenId: 1,
                fillQuantity: 1,
                criteriaProof: new bytes32[](0),
                attributedFulfiller: address(0)
            })
        );
        bytes32 submissionHash = subject.hashSubmission(submission);
        address signer = isBid ? bidder : seller;
        address taker = isBid ? seller : buyer;
        uint256 payment = isBid ? 0 : 1 ether;

        _prank(owner);
        subject.pause();

        _prank(taker);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        seaport.fulfillAdvancedOrder{value: payment}(order, new CriteriaResolver[](0), conduitKey, taker);
        assertEq(nft721.ownerOf(1), seller);
        assertEq(weth.balanceOf(bidder), 100 ether);
        assertEq(buyer.balance, 100 ether);
        assertEq(subject.filledListingQuantity(signer, submissionHash, 0), 0);

        _prank(owner);
        subject.unpause();

        _prank(taker);
        assertTrue(seaport.fulfillAdvancedOrder{value: payment}(order, new CriteriaResolver[](0), conduitKey, taker));
        assertEq(nft721.ownerOf(1), isBid ? bidder : buyer);
        assertEq(subject.filledListingQuantity(signer, submissionHash, 0), 1);
        if (isBid) {
            assertEq(weth.balanceOf(bidder), 99 ether);
            assertEq(weth.balanceOf(seller), 0.95 ether);
            assertEq(weth.balanceOf(PLATFORM), 0.05 ether);
        } else {
            assertEq(buyer.balance, 99 ether);
            assertEq(seller.balance, 0.95 ether);
            assertEq(PLATFORM.balance, 0.05 ether);
        }
    }

    function test_e2e_configurableFeeSplit_settlesListingsAndBidsAtBothExtremesAndNonEqualSplit() public {
        uint256[3] memory splits = [uint256(0), 3000, 10000];
        uint256 tokenId = 3;
        for (uint256 i; i < splits.length; i++) {
            for (uint8 recipientMode; recipientMode < 3; recipientMode++) {
                _assertConfiguredFeeSettlement(splits[i], 1 ether, recipientMode, false, tokenId++);
                _assertConfiguredFeeSettlement(splits[i], 1 ether, recipientMode, true, tokenId++);
            }
        }
    }

    function testFuzz_e2e_configurableFeeSplit_conservesListingPayment(
        uint256 split,
        uint256 price,
        uint8 recipientMode
    ) public {
        _assertConfiguredFeeSettlement(
            bound(split, 0, 10000), bound(price, 20, 2 ether), uint8(bound(recipientMode, 0, 2)), false, 3
        );
    }

    function testFuzz_e2e_configurableFeeSplit_conservesBidPayment(uint256 split, uint256 price, uint8 recipientMode)
        public
    {
        _assertConfiguredFeeSettlement(
            bound(split, 0, 10000), bound(price, 20, 2 ether), uint8(bound(recipientMode, 0, 2)), true, 3
        );
    }

    function _assertConfiguredFeeSettlement(
        uint256 split,
        uint256 price,
        uint8 recipientMode,
        bool isBid,
        uint256 tokenId
    ) internal {
        _prank(owner);
        subject.setFeeSplitBps(split);
        _prank(address(this));
        scatterCollectionRegistry.setRewardsOverride(
            address(nft721), recipientMode == 0 ? address(0) : rewardsRecipient
        );
        nft721.mint(seller, tokenId);
        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);
        _prank(bidder);
        weth.approve(address(conduit), type(uint256).max);

        ScatterOfferer.ScatterSubmission memory submission = _generateListing(
            GenerateListingParams({
                role: isBid ? ScatterOfferer.Role.Bid : ScatterOfferer.Role.Listing,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: isBid ? 0 : tokenId,
                criteriaRoot: bytes32(0),
                quantity: 1,
                currency: isBid ? address(weth) : address(0),
                priceWei: price,
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours,
                nonce: 0,
                salt: bytes32(tokenId)
            })
        );
        AdvancedOrder memory order = _buildSeaportOrder(
            BuildContractOrderParams({
                listing: submission,
                signerPk: isBid ? BIDDER_PK : SELLER_PK,
                affiliate: recipientMode == 2 ? affiliate : address(0),
                fillTokenId: tokenId,
                fillQuantity: 1,
                criteriaProof: new bytes32[](0),
                attributedFulfiller: address(0)
            })
        );
        Balances memory beforeBalances = _snapshotBalances();
        _prank(isBid ? seller : buyer);
        assertTrue(
            seaport.fulfillAdvancedOrder{value: isBid ? 0 : price}(
                order, new CriteriaResolver[](0), conduitKey, isBid ? seller : buyer
            )
        );
        Balances memory afterBalances = _snapshotBalances();
        uint256 fee = price * 500 / 10000;
        uint256 platformFee = recipientMode == 0 ? fee : fee * split / 10000;
        uint256 rewardsFee = recipientMode == 1 ? fee - platformFee : 0;
        uint256 affiliateFee = recipientMode == 2 ? fee - platformFee : 0;
        assertEq(nft721.ownerOf(tokenId), isBid ? bidder : buyer);
        if (isBid) {
            assertEq(beforeBalances.bidderWeth - afterBalances.bidderWeth, price);
            assertEq(afterBalances.sellerWeth - beforeBalances.sellerWeth, price - fee);
            assertEq(afterBalances.platformWeth - beforeBalances.platformWeth, platformFee);
            assertEq(afterBalances.rewardsWeth - beforeBalances.rewardsWeth, rewardsFee);
            assertEq(afterBalances.affiliateWeth - beforeBalances.affiliateWeth, affiliateFee);
            assertEq(weth.balanceOf(address(subject)), 0);
        } else {
            assertEq(beforeBalances.buyerNative - afterBalances.buyerNative, price);
            assertEq(afterBalances.sellerNative - beforeBalances.sellerNative, price - fee);
            assertEq(afterBalances.platformNative - beforeBalances.platformNative, platformFee);
            assertEq(afterBalances.rewardsNative - beforeBalances.rewardsNative, rewardsFee);
            assertEq(afterBalances.affiliateNative - beforeBalances.affiliateNative, affiliateFee);
            assertEq(address(subject).balance, 0);
        }
    }

    function test_e2e_buyer_buys_native_erc721_listing_and_platform_receives_full_fee() public {
        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);

        ScatterOfferer.ScatterSubmission memory listing = _generateListing(
            GenerateListingParams({
                role: ScatterOfferer.Role.Listing,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 1,
                criteriaRoot: bytes32(0),
                quantity: 1,
                currency: address(0),
                priceWei: 1 ether,
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours,
                nonce: 0,
                salt: bytes32(uint256(0xdead))
            })
        );
        AdvancedOrder memory order = _buildSeaportOrder(
            BuildContractOrderParams({
                listing: listing,
                signerPk: SELLER_PK,
                affiliate: address(0), // no affiliate
                fillTokenId: 1,
                fillQuantity: 1,
                criteriaProof: new bytes32[](0),
                attributedFulfiller: address(0)
            })
        );

        _prank(buyer);
        Balances memory balancesBefore = _snapshotBalances();
        seaport.fulfillAdvancedOrder{value: 1 ether}(
            order,
            new CriteriaResolver[](0), // criteriaResolvers
            conduitKey,
            buyer // recipient
        );
        Balances memory balancesAfter = _snapshotBalances();

        // fee breakdown:
        //   listingPrice = 1 ether (paid by the buyer; fees come out of seller proceeds)
        //   totalFee     = 1 ether * 500 / 10000 = 0.05 ether
        //   platformFee  = 0.05 ether
        //   rewardsFee   = 0 ether
        //   affiliateFee = 0 ether
        //   sellerAmount = 1 ether - 0.05 ether  = 0.95 ether
        //   msg.value    = 1 ether
        assertEq(nft721.ownerOf(1), buyer);
        assertEq(balancesAfter.sellerNative - balancesBefore.sellerNative, 0.95 ether);
        assertEq(balancesAfter.platformNative - balancesBefore.platformNative, 0.05 ether);
        assertEq(balancesAfter.rewardsNative - balancesBefore.rewardsNative, 0);
        assertEq(balancesAfter.affiliateNative - balancesBefore.affiliateNative, 0);
        assertEq(balancesBefore.buyerNative - balancesAfter.buyerNative, 1 ether);
        assertEq(address(subject).balance, 0);
    }

    function test_e2e_buyer_buys_native_erc721_listing_and_fee_is_split_with_rewards() public {
        _prank(address(this));
        scatterCollectionRegistry.setRewardsOverride(address(nft721), rewardsRecipient);

        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);

        ScatterOfferer.ScatterSubmission memory listing = _generateListing(
            GenerateListingParams({
                role: ScatterOfferer.Role.Listing,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 1,
                criteriaRoot: bytes32(0),
                quantity: 1,
                currency: address(0),
                priceWei: 1 ether,
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours,
                nonce: 0,
                salt: bytes32(uint256(0xdead))
            })
        );
        AdvancedOrder memory order = _buildSeaportOrder(
            BuildContractOrderParams({
                listing: listing,
                signerPk: SELLER_PK,
                affiliate: address(0), // no affiliate
                fillTokenId: 1,
                fillQuantity: 1,
                criteriaProof: new bytes32[](0),
                attributedFulfiller: address(0)
            })
        );

        _prank(buyer);
        Balances memory balancesBefore = _snapshotBalances();
        seaport.fulfillAdvancedOrder{value: 1 ether}(
            order,
            new CriteriaResolver[](0), // criteriaResolvers
            conduitKey,
            buyer // recipient
        );
        Balances memory balancesAfter = _snapshotBalances();

        // fee breakdown:
        //   listingPrice = 1 ether
        //   totalFee     = 1 ether * 500 / 10000     = 0.05 ether
        //   platformFee  = 0.05 ether * 5000 / 10000 = 0.025 ether
        //   rewardsFee   = 0.05 ether - 0.025 ether  = 0.025 ether
        //   affiliateFee = 0 ether
        //   sellerAmount = 0.95 ether
        assertEq(nft721.ownerOf(1), buyer);
        assertEq(balancesAfter.sellerNative - balancesBefore.sellerNative, 0.95 ether);
        assertEq(balancesAfter.platformNative - balancesBefore.platformNative, 0.025 ether);
        assertEq(balancesAfter.rewardsNative - balancesBefore.rewardsNative, 0.025 ether);
        assertEq(balancesAfter.affiliateNative - balancesBefore.affiliateNative, 0);
        assertEq(address(subject).balance, 0);
    }

    function test_e2e_buyer_buys_native_erc721_listing_and_fee_is_split_with_affiliate() public {
        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);

        ScatterOfferer.ScatterSubmission memory listing = _generateListing(
            GenerateListingParams({
                role: ScatterOfferer.Role.Listing,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 1,
                criteriaRoot: bytes32(0),
                quantity: 1,
                currency: address(0),
                priceWei: 1 ether,
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours,
                nonce: 0,
                salt: bytes32(uint256(0xdead))
            })
        );
        AdvancedOrder memory order = _buildSeaportOrder(
            BuildContractOrderParams({
                listing: listing,
                signerPk: SELLER_PK,
                affiliate: affiliate, // affiliate
                fillTokenId: 1,
                fillQuantity: 1,
                criteriaProof: new bytes32[](0),
                attributedFulfiller: address(0)
            })
        );

        _prank(buyer);
        Balances memory balancesBefore = _snapshotBalances();
        seaport.fulfillAdvancedOrder{value: 1 ether}(
            order,
            new CriteriaResolver[](0), // criteriaResolvers
            conduitKey,
            buyer // recipient
        );
        Balances memory balancesAfter = _snapshotBalances();

        // fee breakdown:
        //   listingPrice = 1 ether
        //   totalFee     = 1 ether * 500 / 10000     = 0.05 ether
        //   platformFee  = 0.05 ether * 5000 / 10000 = 0.025 ether
        //   rewardsFee   = 0 ether
        //   affiliateFee = 0.05 ether - 0.025 ether  = 0.025 ether
        //   sellerAmount = 0.95 ether
        assertEq(nft721.ownerOf(1), buyer);
        assertEq(balancesAfter.sellerNative - balancesBefore.sellerNative, 0.95 ether);
        assertEq(balancesAfter.platformNative - balancesBefore.platformNative, 0.025 ether);
        assertEq(balancesAfter.rewardsNative - balancesBefore.rewardsNative, 0);
        assertEq(balancesAfter.affiliateNative - balancesBefore.affiliateNative, 0.025 ether);
        assertEq(address(subject).balance, 0);
    }

    function test_e2e_buyer_buys_native_erc721_listing_and_affiliate_takes_priority_over_registry_rewards() public {
        _prank(address(this));
        scatterCollectionRegistry.setRewardsOverride(address(nft721), rewardsRecipient);

        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);

        ScatterOfferer.ScatterSubmission memory listing = _generateListing(
            GenerateListingParams({
                role: ScatterOfferer.Role.Listing,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 1,
                criteriaRoot: bytes32(0),
                quantity: 1,
                currency: address(0),
                priceWei: 1 ether,
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours,
                nonce: 0,
                salt: bytes32(uint256(0xdead))
            })
        );
        AdvancedOrder memory order = _buildSeaportOrder(
            BuildContractOrderParams({
                listing: listing,
                signerPk: SELLER_PK,
                affiliate: affiliate, // affiliate
                fillTokenId: 1,
                fillQuantity: 1,
                criteriaProof: new bytes32[](0),
                attributedFulfiller: address(0)
            })
        );

        _prank(buyer);
        Balances memory balancesBefore = _snapshotBalances();
        seaport.fulfillAdvancedOrder{value: 1 ether}(
            order,
            new CriteriaResolver[](0), // criteriaResolvers
            conduitKey,
            buyer // recipient
        );
        Balances memory balancesAfter = _snapshotBalances();

        // fee breakdown (affiliate takes the split slot; the registry rewards is not paid):
        //   listingPrice = 1 ether
        //   totalFee     = 1 ether * 500 / 10000     = 0.05 ether
        //   platformFee  = 0.05 ether * 5000 / 10000 = 0.025 ether
        //   rewardsFee   = 0
        //   affiliateFee = 0.05 ether - 0.025 ether  = 0.025 ether
        //   sellerAmount = 0.95 ether
        assertEq(nft721.ownerOf(1), buyer);
        assertEq(balancesAfter.platformNative - balancesBefore.platformNative, 0.025 ether);
        assertEq(balancesAfter.rewardsNative - balancesBefore.rewardsNative, 0);
        assertEq(balancesAfter.affiliateNative - balancesBefore.affiliateNative, 0.025 ether);
        assertEq(address(subject).balance, 0);
    }

    function test_e2e_buyer_buys_native_erc721_listing_and_excess_native_is_refunded() public {
        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);

        ScatterOfferer.ScatterSubmission memory listing = _generateListing(
            GenerateListingParams({
                role: ScatterOfferer.Role.Listing,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 1,
                criteriaRoot: bytes32(0),
                quantity: 1,
                currency: address(0),
                priceWei: 1 ether,
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours,
                nonce: 0,
                salt: bytes32(uint256(0xdead))
            })
        );
        AdvancedOrder memory order = _buildSeaportOrder(
            BuildContractOrderParams({
                listing: listing,
                signerPk: SELLER_PK,
                affiliate: address(0), // no affiliate
                fillTokenId: 1,
                fillQuantity: 1,
                criteriaProof: new bytes32[](0),
                attributedFulfiller: address(0)
            })
        );

        _prank(buyer);
        Balances memory balancesBefore = _snapshotBalances();

        seaport.fulfillAdvancedOrder{value: 1 ether + 0.2 ether}( // overpay by 0.2 ether
            order,
            new CriteriaResolver[](0), // criteriaResolvers
            conduitKey,
            buyer // recipient
        );
        Balances memory balancesAfter = _snapshotBalances();

        // fee breakdown:
        //   listingPrice = 1 ether
        //   totalFee     = 1 ether * 500 / 10000 = 0.05 ether
        //   platformFee  = 0.05 ether
        //   rewardsFee   = 0 ether
        //   affiliateFee = 0 ether
        //   sellerAmount = 1 ether - 0.05 ether  = 0.95 ether
        //   msg.value    = 1.2 ether
        //   refund       = 1.2 ether - 1 ether    = 0.2 ether
        assertEq(nft721.ownerOf(1), buyer);
        assertEq(balancesAfter.platformNative - balancesBefore.platformNative, 0.05 ether);
        assertEq(balancesAfter.rewardsNative - balancesBefore.rewardsNative, 0);
        assertEq(balancesAfter.affiliateNative - balancesBefore.affiliateNative, 0);
        assertEq(balancesBefore.buyerNative - balancesAfter.buyerNative, 1 ether);
        assertEq(address(subject).balance, 0);
    }

    function test_e2e_buyer_buys_native_erc721_listing_and_nft_is_delivered_to_separate_recipient() public {
        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);

        ScatterOfferer.ScatterSubmission memory listing = _generateListing(
            GenerateListingParams({
                role: ScatterOfferer.Role.Listing,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 1,
                criteriaRoot: bytes32(0),
                quantity: 1,
                currency: address(0),
                priceWei: 1 ether,
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours,
                nonce: 0,
                salt: bytes32(uint256(0xdead))
            })
        );
        AdvancedOrder memory order = _buildSeaportOrder(
            BuildContractOrderParams({
                listing: listing,
                signerPk: SELLER_PK,
                affiliate: address(0),
                fillTokenId: 1,
                fillQuantity: 1,
                criteriaProof: new bytes32[](0),
                attributedFulfiller: address(0)
            })
        );

        _prank(buyer);
        seaport.fulfillAdvancedOrder{value: 1 ether}(
            order,
            new CriteriaResolver[](0), // criteriaResolvers
            conduitKey,
            other // recipient — buyer pays but `other` receives the NFT
        );

        assertEq(nft721.ownerOf(1), other);
    }

    function test_e2e_buyer_buys_native_erc721_listing_and_scatter_sale_event_is_emitted() public {
        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);

        ScatterOfferer.ScatterSubmission memory listing = _generateListing(
            GenerateListingParams({
                role: ScatterOfferer.Role.Listing,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 1,
                criteriaRoot: bytes32(0),
                quantity: 1,
                currency: address(0),
                priceWei: 1 ether,
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours,
                nonce: 0,
                salt: bytes32(uint256(0xdead))
            })
        );
        bytes32 listingHash = subject.hashSubmission(listing);
        AdvancedOrder memory order = _buildSeaportOrder(
            BuildContractOrderParams({
                listing: listing,
                signerPk: SELLER_PK,
                affiliate: address(0),
                fillTokenId: 1,
                fillQuantity: 1,
                criteriaProof: new bytes32[](0),
                attributedFulfiller: address(0)
            })
        );

        _prank(buyer);
        vm.expectEmit(true, true, true, true, address(subject));
        emit ScatterOfferer.ScatterSale(
            listingHash, // listingHash
            uint8(ScatterOfferer.Role.Listing), // role
            seller, // seller
            buyer, // buyer (Seaport requester)
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
        seaport.fulfillAdvancedOrder{value: 1 ether}(
            order,
            new CriteriaResolver[](0), // criteriaResolvers
            conduitKey,
            buyer // recipient
        );
    }

    function test_e2e_buyer_buys_native_erc721_listing_through_trusted_router() public {
        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);

        MockRouterE2E mockRouter = new MockRouterE2E();

        _prank(owner);
        subject.setTrustedRouter(address(mockRouter), true); // mark router as trusted

        ScatterOfferer.ScatterSubmission memory listing = _generateListing(
            GenerateListingParams({
                role: ScatterOfferer.Role.Listing,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 1,
                criteriaRoot: bytes32(0),
                quantity: 1,
                currency: address(0),
                priceWei: 1 ether,
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours,
                nonce: 0,
                salt: bytes32(uint256(0xdead))
            })
        );
        AdvancedOrder memory order = _buildSeaportOrder(
            BuildContractOrderParams({
                listing: listing,
                signerPk: SELLER_PK,
                affiliate: address(0),
                fillTokenId: 1,
                fillQuantity: 1,
                criteriaProof: new bytes32[](0),
                // Seaport still sees the router as `requester`; this field is
                // only consumed by ScatterOfferer when emitting ScatterSale.
                attributedFulfiller: buyer
            })
        );

        _prank(buyer);
        Balances memory balancesBefore = _snapshotBalances();
        mockRouter.buy{value: 1 ether}(seaport, order, buyer);
        Balances memory balancesAfter = _snapshotBalances();

        // fee breakdown:
        //   listingPrice = 1 ether
        //   totalFee     = 1 ether * 500 / 10000 = 0.05 ether
        //   platformFee  = 0.05 ether
        //   rewardsFee   = 0 ether
        //   affiliateFee = 0 ether
        //   sellerAmount = 1 ether - 0.05 ether  = 0.95 ether
        assertEq(nft721.ownerOf(1), buyer);
        assertEq(balancesAfter.platformNative - balancesBefore.platformNative, 0.05 ether);
        assertEq(balancesAfter.rewardsNative - balancesBefore.rewardsNative, 0);
        assertEq(balancesAfter.affiliateNative - balancesBefore.affiliateNative, 0);
    }

    function test_e2e_routed_fill_with_affiliate_authorizes_the_buyer_not_the_router() public {
        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);

        MockRouterE2E mockRouter = new MockRouterE2E();

        _prank(owner);
        subject.setTrustedRouter(address(mockRouter), true); // mark router as trusted

        ScatterOfferer.ScatterSubmission memory listing = _generateListing(
            GenerateListingParams({
                role: ScatterOfferer.Role.Listing,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 1,
                criteriaRoot: bytes32(0),
                quantity: 1,
                currency: address(0),
                priceWei: 1 ether,
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours,
                nonce: 0,
                salt: bytes32(uint256(0xdead))
            })
        );
        AdvancedOrder memory order = _buildSeaportOrder(
            BuildContractOrderParams({
                listing: listing,
                signerPk: SELLER_PK,
                affiliate: affiliate, // affiliate
                fillTokenId: 1,
                fillQuantity: 1,
                criteriaProof: new bytes32[](0),
                attributedFulfiller: buyer
            })
        );

        _prank(buyer);
        Balances memory balancesBefore = _snapshotBalances();
        mockRouter.buy{value: 1 ether}(seaport, order, buyer);
        Balances memory balancesAfter = _snapshotBalances();

        assertEq(nft721.ownerOf(1), buyer);
        assertEq(balancesAfter.sellerNative - balancesBefore.sellerNative, 0.95 ether);
        assertEq(balancesAfter.platformNative - balancesBefore.platformNative, 0.025 ether);
        assertEq(balancesAfter.rewardsNative - balancesBefore.rewardsNative, 0);
        assertEq(balancesAfter.affiliateNative - balancesBefore.affiliateNative, 0.025 ether);
    }

    function test_e2e_buyer_buys_native_erc721_listing_and_trusted_router_attributes_buyer_as_fulfiller_event() public {
        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);

        MockRouterE2E mockRouter = new MockRouterE2E();

        // Mark the router as trusted so ScatterOfferer can attribute the
        // eventual sale to the human buyer supplied in `attributedFulfiller`.
        _prank(owner);
        subject.setTrustedRouter(address(mockRouter), true);

        ScatterOfferer.ScatterSubmission memory listing = _generateListing(
            GenerateListingParams({
                role: ScatterOfferer.Role.Listing,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 1,
                criteriaRoot: bytes32(0),
                quantity: 1,
                currency: address(0),
                priceWei: 1 ether,
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours,
                nonce: 0,
                salt: bytes32(uint256(0xdead))
            })
        );
        bytes32 listingHash = subject.hashSubmission(listing);
        AdvancedOrder memory order = _buildSeaportOrder(
            BuildContractOrderParams({
                listing: listing,
                signerPk: SELLER_PK,
                affiliate: address(0),
                fillTokenId: 1,
                fillQuantity: 1,
                criteriaProof: new bytes32[](0),
                // Seaport still sees the router as `requester`; this field is
                // only consumed by ScatterOfferer when emitting ScatterSale.
                attributedFulfiller: buyer
            })
        );

        _prank(buyer);
        // Flow:
        //   1. buyer calls MockRouterE2E.buy and supplies the ETH.
        //   2. router calls Seaport, so Seaport passes `requester=router` into
        //      ScatterOfferer.generateOrder.
        //   3. ScatterOfferer detects that the router is trusted and swaps the
        //      event's buyer from `requester` to `attributedFulfiller`.
        //   4. Seaport still transfers the NFT to the explicit `recipient`
        //      argument passed by the router, which is also `buyer` here.
        vm.expectEmit(true, true, true, true, address(subject));
        emit ScatterOfferer.ScatterSale(
            listingHash, // listingHash
            uint8(ScatterOfferer.Role.Listing), // role
            seller, // seller
            buyer, // buyer (attributedFulfiller, not the router)
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
        mockRouter.buy{value: 1 ether}(seaport, order, buyer);
    }

    function test_e2e_buyer_buys_erc20_erc721_listing_and_platform_receives_full_fee() public {
        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);

        _prank(buyer);
        weth.approve(address(conduit), 1 ether);

        ScatterOfferer.ScatterSubmission memory listing = _generateListing(
            GenerateListingParams({
                role: ScatterOfferer.Role.Listing,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 1,
                criteriaRoot: bytes32(0),
                quantity: 1,
                currency: address(weth),
                priceWei: 1 ether,
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours,
                nonce: 0,
                salt: bytes32(uint256(0xdead))
            })
        );
        AdvancedOrder memory order = _buildSeaportOrder(
            BuildContractOrderParams({
                listing: listing,
                signerPk: SELLER_PK,
                affiliate: address(0), // no affiliate
                fillTokenId: 1,
                fillQuantity: 1,
                criteriaProof: new bytes32[](0),
                attributedFulfiller: address(0)
            })
        );

        _prank(buyer);
        Balances memory balancesBefore = _snapshotBalances();
        seaport.fulfillAdvancedOrder(
            order,
            new CriteriaResolver[](0), // criteriaResolvers
            conduitKey,
            buyer // recipient
        );
        Balances memory balancesAfter = _snapshotBalances();

        // fee breakdown:
        //   listingPrice = 1 ether (ERC20)
        //   totalFee     = 1 ether * 500 / 10000 = 0.05 ether
        //   platformFee  = 0.05 ether
        //   rewardsFee   = 0 ether
        //   affiliateFee = 0 ether
        //   sellerAmount = 0.95 ether
        //   totalPulled  = 1 ether from buyer
        assertEq(nft721.ownerOf(1), buyer);
        assertEq(balancesAfter.sellerWeth - balancesBefore.sellerWeth, 0.95 ether);
        assertEq(balancesAfter.platformWeth - balancesBefore.platformWeth, 0.05 ether);
        assertEq(balancesAfter.rewardsWeth - balancesBefore.rewardsWeth, 0);
        assertEq(balancesAfter.affiliateWeth - balancesBefore.affiliateWeth, 0);
        assertEq(balancesBefore.buyerWeth - balancesAfter.buyerWeth, 1 ether);
        assertEq(weth.balanceOf(address(subject)), 0);
    }

    function test_e2e_buyer_buys_native_erc1155_listing_with_partial_fill_and_platform_receives_full_fee() public {
        _prank(seller);
        nft1155.setApprovalForAll(address(conduit), true);

        ScatterOfferer.ScatterSubmission memory listing = _generateListing(
            GenerateListingParams({
                role: ScatterOfferer.Role.Listing,
                assetType: ScatterOfferer.AssetType.ERC1155,
                collection: address(nft1155),
                tokenId: 1,
                criteriaRoot: bytes32(0),
                quantity: 10,
                currency: address(0),
                priceWei: 0.1 ether,
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours,
                nonce: 0,
                salt: bytes32(uint256(0xdead))
            })
        );
        AdvancedOrder memory order = _buildSeaportOrder(
            BuildContractOrderParams({
                listing: listing,
                signerPk: SELLER_PK,
                affiliate: address(0),
                fillTokenId: 1,
                fillQuantity: 3, // partial fill order
                criteriaProof: new bytes32[](0),
                attributedFulfiller: address(0)
            })
        );

        _prank(buyer);
        Balances memory balancesBefore = _snapshotBalances();
        seaport.fulfillAdvancedOrder{value: 0.3 ether}(
            order,
            new CriteriaResolver[](0), // criteriaResolvers
            conduitKey,
            buyer // recipient
        );
        Balances memory balancesAfter = _snapshotBalances();

        // fee breakdown:
        //   totalFillPrice = 0.1 ether * 3 = 0.3 ether
        //   totalFee       = 0.3 ether * 500 / 10000 = 0.015 ether
        //   platformFee    = 0.015 ether
        //   rewardsFee     = 0 ether
        //   affiliateFee   = 0 ether
        //   sellerAmount   = 0.3 ether - 0.015 ether = 0.285 ether
        assertEq(nft1155.balanceOf(buyer, 1), 3);
        assertEq(nft1155.balanceOf(seller, 1), 7);
        assertEq(balancesAfter.sellerNative - balancesBefore.sellerNative, 0.285 ether);
        assertEq(balancesAfter.platformNative - balancesBefore.platformNative, 0.015 ether);
        assertEq(balancesAfter.rewardsNative - balancesBefore.rewardsNative, 0);
        assertEq(balancesAfter.affiliateNative - balancesBefore.affiliateNative, 0);
        assertEq(address(subject).balance, 0);

        (,, uint256 filled, uint256 remaining) = subject.listingStatus(seller, listing, 0);
        assertEq(filled, 3);
        assertEq(remaining, 7);
    }

    function test_e2e_buyer_buys_native_erc1155_listing_in_two_fills_and_quantity_is_exhausted() public {
        _prank(seller);
        nft1155.setApprovalForAll(address(conduit), true);

        ScatterOfferer.ScatterSubmission memory listing = _generateListing(
            GenerateListingParams({
                role: ScatterOfferer.Role.Listing,
                assetType: ScatterOfferer.AssetType.ERC1155,
                collection: address(nft1155),
                tokenId: 1,
                criteriaRoot: bytes32(0),
                quantity: 10,
                currency: address(0),
                priceWei: 0.1 ether,
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours,
                nonce: 0,
                salt: bytes32(uint256(0xdead))
            })
        );
        AdvancedOrder memory orderFirstFill = _buildSeaportOrder(
            BuildContractOrderParams({
                listing: listing,
                signerPk: SELLER_PK,
                affiliate: address(0),
                fillTokenId: 1,
                fillQuantity: 3,
                criteriaProof: new bytes32[](0),
                attributedFulfiller: address(0)
            })
        );
        AdvancedOrder memory orderSecondFill = _buildSeaportOrder(
            BuildContractOrderParams({
                listing: listing,
                signerPk: SELLER_PK,
                affiliate: address(0),
                fillTokenId: 1,
                fillQuantity: 7,
                criteriaProof: new bytes32[](0),
                attributedFulfiller: address(0)
            })
        );

        _prank(buyer);
        Balances memory balancesBefore = _snapshotBalances();
        seaport.fulfillAdvancedOrder{value: 0.3 ether}(
            orderFirstFill,
            new CriteriaResolver[](0), // criteriaResolvers
            conduitKey,
            buyer // recipient
        );

        seaport.fulfillAdvancedOrder{value: 0.7 ether}(
            orderSecondFill,
            new CriteriaResolver[](0), // criteriaResolvers
            conduitKey,
            buyer // recipient
        );
        Balances memory balancesAfter = _snapshotBalances();

        // fee breakdown (cumulative over both fills):
        //   fill 1 price     = 0.3 ether
        //   fill 1 fee       = 0.015 ether
        //   fill 1 platform  = 0.015 ether
        //   fill 1 rewards   = 0 ether
        //   fill 1 affiliate = 0 ether
        //   fill 1 seller    = 0.285 ether
        //   fill 2 price     = 0.7 ether
        //   fill 2 fee       = 0.035 ether
        //   fill 2 platform  = 0.035 ether
        //   fill 2 rewards   = 0 ether
        //   fill 2 affiliate = 0 ether
        //   fill 2 seller    = 0.665 ether
        //   totalPlatformFee = 0.05 ether
        //   totalRewardsFee  = 0 ether
        //   totalAffiliateFee = 0 ether
        //   totalSellerAmount = 0.95 ether
        assertEq(nft1155.balanceOf(buyer, 1), 10);
        assertEq(balancesAfter.sellerNative - balancesBefore.sellerNative, 0.95 ether);
        assertEq(balancesAfter.platformNative - balancesBefore.platformNative, 0.05 ether);
        assertEq(balancesAfter.rewardsNative - balancesBefore.rewardsNative, 0);
        assertEq(balancesAfter.affiliateNative - balancesBefore.affiliateNative, 0);
        assertEq(address(subject).balance, 0);

        (,, uint256 filled, uint256 remaining) = subject.listingStatus(seller, listing, 0);
        assertEq(filled, 10);
        assertEq(remaining, 0);
    }

    function test_e2e_seller_sells_into_weth_erc721_bid_and_platform_receives_full_fee() public {
        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);

        _prank(bidder);
        weth.approve(address(conduit), type(uint256).max);

        ScatterOfferer.ScatterSubmission memory bid = _generateListing(
            GenerateListingParams({
                role: ScatterOfferer.Role.Bid,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 0,
                criteriaRoot: bytes32(0),
                quantity: 1,
                currency: address(weth),
                priceWei: 1 ether,
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours,
                nonce: 0,
                salt: bytes32(uint256(0xface))
            })
        );
        AdvancedOrder memory order = _buildSeaportOrder(
            BuildContractOrderParams({
                listing: bid,
                signerPk: BIDDER_PK,
                affiliate: address(0),
                fillTokenId: 1,
                fillQuantity: 1,
                criteriaProof: new bytes32[](0),
                attributedFulfiller: address(0) // no affiliate
            })
        );

        _prank(seller);
        Balances memory balancesBefore = _snapshotBalances();
        seaport.fulfillAdvancedOrder(
            order,
            new CriteriaResolver[](0), // criteriaResolvers
            conduitKey,
            seller // recipient — seller receives the WETH offer
        );
        Balances memory balancesAfter = _snapshotBalances();

        // fee breakdown:
        //   bidPrice     = 1 ether (WETH, pulled from bidder by the offerer)
        //   totalFee     = 1 ether * 500 / 10000 = 0.05 ether
        //   platformFee  = 0.05 ether
        //   rewardsFee   = 0 ether
        //   affiliateFee = 0 ether
        //   sellerAmount = 0.95 ether (offered through Seaport)
        assertEq(nft721.ownerOf(1), bidder);
        assertEq(balancesAfter.sellerWeth - balancesBefore.sellerWeth, 0.95 ether);
        assertEq(balancesAfter.platformWeth - balancesBefore.platformWeth, 0.05 ether);
        assertEq(balancesAfter.rewardsWeth - balancesBefore.rewardsWeth, 0);
        assertEq(balancesAfter.affiliateWeth - balancesBefore.affiliateWeth, 0);
        assertEq(balancesBefore.bidderWeth - balancesAfter.bidderWeth, 1 ether);
        assertEq(weth.balanceOf(address(subject)), 0);
        assertEq(weth.allowance(address(subject), SEAPORT), 0);
    }

    function test_e2e_seller_sells_into_weth_erc721_bid_and_fee_is_split_with_rewards() public {
        _prank(address(this));
        scatterCollectionRegistry.setRewardsOverride(address(nft721), rewardsRecipient);

        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);

        _prank(bidder);
        weth.approve(address(conduit), type(uint256).max);

        ScatterOfferer.ScatterSubmission memory bid = _generateListing(
            GenerateListingParams({
                role: ScatterOfferer.Role.Bid,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 0,
                criteriaRoot: bytes32(0),
                quantity: 1,
                currency: address(weth),
                priceWei: 1 ether,
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours,
                nonce: 0,
                salt: bytes32(uint256(0xface))
            })
        );
        AdvancedOrder memory order = _buildSeaportOrder(
            BuildContractOrderParams({
                listing: bid,
                signerPk: BIDDER_PK,
                affiliate: address(0),
                fillTokenId: 1,
                fillQuantity: 1,
                criteriaProof: new bytes32[](0),
                attributedFulfiller: address(0) // no affiliate
            })
        );

        _prank(seller);
        Balances memory balancesBefore = _snapshotBalances();
        seaport.fulfillAdvancedOrder(
            order,
            new CriteriaResolver[](0), // criteriaResolvers
            conduitKey,
            seller // recipient
        );
        Balances memory balancesAfter = _snapshotBalances();

        // fee breakdown:
        //   bidPrice     = 1 ether (WETH)
        //   totalFee     = 1 ether * 500 / 10000     = 0.05 ether
        //   platformFee  = 0.05 ether * 5000 / 10000 = 0.025 ether
        //   rewardsFee   = 0.05 ether - 0.025 ether  = 0.025 ether
        //   affiliateFee = 0 ether
        //   sellerAmount = 0.95 ether
        assertEq(nft721.ownerOf(1), bidder);
        assertEq(balancesAfter.sellerWeth - balancesBefore.sellerWeth, 0.95 ether);
        assertEq(balancesAfter.platformWeth - balancesBefore.platformWeth, 0.025 ether);
        assertEq(balancesAfter.rewardsWeth - balancesBefore.rewardsWeth, 0.025 ether);
        assertEq(balancesAfter.affiliateWeth - balancesBefore.affiliateWeth, 0);
        assertEq(weth.balanceOf(address(subject)), 0);
        assertEq(weth.allowance(address(subject), SEAPORT), 0);
    }

    function test_e2e_seller_sells_into_weth_erc721_bid_and_fee_is_split_with_affiliate() public {
        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);

        _prank(bidder);
        weth.approve(address(conduit), type(uint256).max);

        ScatterOfferer.ScatterSubmission memory bid = _generateListing(
            GenerateListingParams({
                role: ScatterOfferer.Role.Bid,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 0,
                criteriaRoot: bytes32(0),
                quantity: 1,
                currency: address(weth),
                priceWei: 1 ether,
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours,
                nonce: 0,
                salt: bytes32(uint256(0xface))
            })
        );
        AdvancedOrder memory order = _buildSeaportOrder(
            BuildContractOrderParams({
                listing: bid,
                signerPk: BIDDER_PK,
                affiliate: affiliate, // affiliate
                fillTokenId: 1,
                fillQuantity: 1,
                criteriaProof: new bytes32[](0),
                attributedFulfiller: address(0)
            })
        );

        _prank(seller);
        Balances memory balancesBefore = _snapshotBalances();
        seaport.fulfillAdvancedOrder(
            order,
            new CriteriaResolver[](0), // criteriaResolvers
            conduitKey,
            seller // recipient
        );
        Balances memory balancesAfter = _snapshotBalances();

        // fee breakdown:
        //   bidPrice     = 1 ether (WETH)
        //   totalFee     = 1 ether * 500 / 10000     = 0.05 ether
        //   platformFee  = 0.05 ether * 5000 / 10000 = 0.025 ether
        //   rewardsFee   = 0 ether
        //   affiliateFee = 0.05 ether - 0.025 ether  = 0.025 ether
        //   sellerAmount = 0.95 ether
        assertEq(nft721.ownerOf(1), bidder);
        assertEq(balancesAfter.sellerWeth - balancesBefore.sellerWeth, 0.95 ether);
        assertEq(balancesAfter.platformWeth - balancesBefore.platformWeth, 0.025 ether);
        assertEq(balancesAfter.rewardsWeth - balancesBefore.rewardsWeth, 0);
        assertEq(balancesAfter.affiliateWeth - balancesBefore.affiliateWeth, 0.025 ether);
        assertEq(weth.balanceOf(address(subject)), 0);
        assertEq(weth.allowance(address(subject), SEAPORT), 0);
    }

    function test_e2e_seller_sells_into_weth_erc721_bid_and_scatter_sale_event_is_emitted() public {
        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);

        _prank(bidder);
        weth.approve(address(conduit), type(uint256).max);

        ScatterOfferer.ScatterSubmission memory bid = _generateListing(
            GenerateListingParams({
                role: ScatterOfferer.Role.Bid,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 0,
                criteriaRoot: bytes32(0),
                quantity: 1,
                currency: address(weth),
                priceWei: 1 ether,
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours,
                nonce: 0,
                salt: bytes32(uint256(0xface))
            })
        );
        AdvancedOrder memory order = _buildSeaportOrder(
            BuildContractOrderParams({
                listing: bid,
                signerPk: BIDDER_PK,
                affiliate: address(0),
                fillTokenId: 1,
                fillQuantity: 1,
                criteriaProof: new bytes32[](0),
                attributedFulfiller: address(0)
            })
        );

        _prank(seller);
        vm.expectEmit(true, true, true, true, address(subject));
        emit ScatterOfferer.ScatterSale(
            subject.hashSubmission(bid), // submissionHash
            uint8(ScatterOfferer.Role.Bid), // role
            seller, // seller (Seaport requester — fulfiller of a bid)
            bidder, // buyer (signer of the bid)
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
        seaport.fulfillAdvancedOrder(
            order,
            new CriteriaResolver[](0), // criteriaResolvers
            conduitKey,
            seller // recipient
        );
    }

    function test_e2e_seller_sells_into_weth_erc721_criteria_bid_with_merkle_proof() public {
        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);

        _prank(bidder);
        weth.approve(address(conduit), type(uint256).max);

        (bytes32 criteriaRoot, bytes32[] memory criteriaProof) = _generateCriteriaData(1, 2);
        ScatterOfferer.ScatterSubmission memory bid = _generateListing(
            GenerateListingParams({
                role: ScatterOfferer.Role.Bid,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId: 0,
                criteriaRoot: criteriaRoot, // criteriaRoot
                quantity: 1,
                currency: address(weth),
                priceWei: 1 ether,
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours,
                nonce: 0,
                salt: bytes32(uint256(0xface))
            })
        );

        AdvancedOrder memory order = _buildSeaportOrder(
            BuildContractOrderParams({
                listing: bid,
                signerPk: BIDDER_PK,
                affiliate: address(0),
                fillTokenId: 2,
                fillQuantity: 1,
                criteriaProof: criteriaProof, // criteriaProof
                attributedFulfiller: address(0)
            })
        );

        _prank(seller);
        Balances memory balancesBefore = _snapshotBalances();
        seaport.fulfillAdvancedOrder(
            order,
            new CriteriaResolver[](0), // criteriaResolvers
            conduitKey,
            seller // recipient
        );
        Balances memory balancesAfter = _snapshotBalances();

        // fee breakdown:
        //   bidPrice     = 1 ether (WETH)
        //   totalFee     = 1 ether * 500 / 10000 = 0.05 ether
        //   platformFee  = 0.05 ether
        //   rewardsFee   = 0 ether
        //   affiliateFee = 0 ether
        //   sellerAmount = 0.95 ether
        assertEq(nft721.ownerOf(2), bidder);
        assertEq(balancesAfter.sellerWeth - balancesBefore.sellerWeth, 0.95 ether);
        assertEq(balancesAfter.platformWeth - balancesBefore.platformWeth, 0.05 ether);
        assertEq(balancesAfter.rewardsWeth - balancesBefore.rewardsWeth, 0);
        assertEq(balancesAfter.affiliateWeth - balancesBefore.affiliateWeth, 0);
        assertEq(weth.balanceOf(address(subject)), 0);
        assertEq(weth.allowance(address(subject), SEAPORT), 0);
    }

    function test_e2e_seller_sells_into_weth_erc1155_bid_with_partial_fill_and_platform_receives_full_fee() public {
        _prank(seller);
        nft1155.setApprovalForAll(address(conduit), true);

        _prank(bidder);
        weth.approve(address(conduit), type(uint256).max);

        ScatterOfferer.ScatterSubmission memory bid = _generateListing(
            GenerateListingParams({
                role: ScatterOfferer.Role.Bid,
                assetType: ScatterOfferer.AssetType.ERC1155,
                collection: address(nft1155),
                tokenId: 0,
                criteriaRoot: bytes32(0),
                quantity: 10,
                currency: address(weth),
                priceWei: 0.1 ether,
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours,
                nonce: 0,
                salt: bytes32(uint256(0xface))
            })
        );

        AdvancedOrder memory order = _buildSeaportOrder(
            BuildContractOrderParams({
                listing: bid,
                signerPk: BIDDER_PK,
                affiliate: address(0),
                fillTokenId: 1,
                fillQuantity: 4, // partial fill order
                criteriaProof: new bytes32[](0),
                attributedFulfiller: address(0) // no affiliate
            })
        );

        _prank(seller);
        Balances memory balancesBefore = _snapshotBalances();
        seaport.fulfillAdvancedOrder(
            order,
            new CriteriaResolver[](0), // criteriaResolvers
            conduitKey,
            seller // recipient
        );
        Balances memory balancesAfter = _snapshotBalances();

        // fee breakdown:
        //   totalFillPrice = 0.1 ether * 4 = 0.4 ether (WETH)
        //   totalFee       = 0.4 ether * 500 / 10000 = 0.02 ether
        //   platformFee    = 0.02 ether
        //   rewardsFee     = 0 ether
        //   affiliateFee   = 0 ether
        //   sellerAmount   = 0.4 ether - 0.02 ether  = 0.38 ether
        assertEq(nft1155.balanceOf(bidder, 1), 4);
        assertEq(nft1155.balanceOf(seller, 1), 6);
        assertEq(balancesAfter.sellerWeth - balancesBefore.sellerWeth, 0.38 ether);
        assertEq(balancesAfter.platformWeth - balancesBefore.platformWeth, 0.02 ether);
        assertEq(balancesAfter.rewardsWeth - balancesBefore.rewardsWeth, 0);
        assertEq(balancesAfter.affiliateWeth - balancesBefore.affiliateWeth, 0);
        assertEq(balancesBefore.bidderWeth - balancesAfter.bidderWeth, 0.4 ether);
        assertEq(weth.balanceOf(address(subject)), 0);
        assertEq(weth.allowance(address(subject), SEAPORT), 0);

        (,, uint256 filled, uint256 remaining) = subject.listingStatus(bidder, bid, 0);
        assertEq(filled, 4);
        assertEq(remaining, 6);
    }

    function test_e2e_buyer_buys_one_item_from_multi_item_erc721_listing_and_sibling_remains_fillable() public {
        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);

        ScatterOfferer.ScatterSubmission memory listing = _generateTwoItemListing(
            GenerateTwoItemListingParams({
                role: ScatterOfferer.Role.Listing,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId0: 1,
                quantity0: 1,
                currency0: address(0),
                priceWei0: 1 ether,
                tokenId1: 2,
                quantity1: 1,
                currency1: address(0),
                priceWei1: 2 ether,
                criteriaRoot: bytes32(0),
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours,
                nonce: 0,
                salt: bytes32(uint256(0x1111))
            })
        );
        AdvancedOrder memory firstOrder = _buildSeaportOrder(
            BuildContractOrderParams({
                listing: listing,
                signerPk: SELLER_PK,
                affiliate: address(0),
                fillTokenId: 1,
                fillQuantity: 1,
                criteriaProof: new bytes32[](0),
                attributedFulfiller: address(0)
            })
        );

        _prank(buyer);
        seaport.fulfillAdvancedOrder{value: 1 ether}(
            firstOrder,
            new CriteriaResolver[](0), // criteriaResolvers
            conduitKey,
            buyer // recipient
        );

        uint256[] memory siblingItemIndexes = _singleUintArray(1);
        uint256[] memory siblingFillTokenIds = _singleUintArray(2);
        uint256[] memory siblingFillQuantities = _singleUintArray(1);
        AdvancedOrder memory siblingOrder = _buildSeaportOrderWithFills(
            BuildContractOrderWithFillsParams({
                listing: listing,
                signerPk: SELLER_PK,
                affiliate: address(0),
                itemIndexes: siblingItemIndexes,
                fillTokenIds: siblingFillTokenIds,
                fillQuantities: siblingFillQuantities,
                criteriaProofs: new bytes32[][](0),
                attributedFulfiller: address(0)
            })
        );
        seaport.fulfillAdvancedOrder{value: 2 ether}(
            siblingOrder,
            new CriteriaResolver[](0), // criteriaResolvers
            conduitKey,
            buyer // recipient
        );

        assertEq(nft721.ownerOf(1), buyer);
        assertEq(nft721.ownerOf(2), buyer);

        (,, uint256 firstFilled, uint256 firstRemaining) = subject.listingStatus(seller, listing, 0);
        assertEq(firstFilled, 1);
        assertEq(firstRemaining, 0);

        (,, uint256 siblingFilled, uint256 siblingRemaining) = subject.listingStatus(seller, listing, 1);
        assertEq(siblingFilled, 1);
        assertEq(siblingRemaining, 0);
    }

    function test_e2e_buyer_buys_two_erc721_items_from_one_multi_item_listing_in_one_fulfillment() public {
        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);

        ScatterOfferer.ScatterSubmission memory listing = _generateTwoItemListing(
            GenerateTwoItemListingParams({
                role: ScatterOfferer.Role.Listing,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId0: 1,
                quantity0: 1,
                currency0: address(0),
                priceWei0: 1 ether,
                tokenId1: 2,
                quantity1: 1,
                currency1: address(0),
                priceWei1: 2 ether,
                criteriaRoot: bytes32(0),
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours,
                nonce: 0,
                salt: bytes32(uint256(0x2222))
            })
        );
        uint256[] memory itemIndexes = _twoUintArray(0, 1);
        uint256[] memory fillTokenIds = _twoUintArray(1, 2);
        uint256[] memory fillQuantities = _twoUintArray(1, 1);
        AdvancedOrder memory order = _buildSeaportOrderWithFills(
            BuildContractOrderWithFillsParams({
                listing: listing,
                signerPk: SELLER_PK,
                affiliate: address(0),
                itemIndexes: itemIndexes,
                fillTokenIds: fillTokenIds,
                fillQuantities: fillQuantities,
                criteriaProofs: new bytes32[][](0),
                attributedFulfiller: address(0)
            })
        );

        _prank(buyer);
        Balances memory balancesBefore = _snapshotBalances();
        vm.expectEmit(true, true, true, true, address(subject));
        emit ScatterOfferer.ScatterSale(
            subject.hashSubmission(listing), // listingHash
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
        vm.expectEmit(true, true, true, true, address(subject));
        emit ScatterOfferer.ScatterSale(
            subject.hashSubmission(listing), // listingHash
            uint8(ScatterOfferer.Role.Listing), // role
            seller, // seller
            buyer, // buyer
            address(nft721), // collection
            1, // itemIndex
            2, // tokenId
            1, // quantity
            address(0), // currency (native)
            2 ether, // totalPrice
            address(0), // affiliate
            address(0), // rewardsRecipient
            1.9 ether, // sellerAmount
            0.1 ether, // platformAmount
            0, // rewardsAmount
            0 // affiliateAmount
        );
        seaport.fulfillAdvancedOrder{value: 3 ether}(
            order,
            new CriteriaResolver[](0), // criteriaResolvers
            conduitKey,
            buyer // recipient
        );
        Balances memory balancesAfter = _snapshotBalances();

        // fee breakdown:
        //   totalFillPrice = 1 ether + 2 ether = 3 ether
        //   totalFee       = 3 ether * 500 / 10000 = 0.15 ether
        //   platformFee    = 0.15 ether
        //   rewardsFee     = 0 ether
        //   affiliateFee   = 0 ether
        //   sellerAmount   = 3 ether - 0.15 ether = 2.85 ether
        assertEq(nft721.ownerOf(1), buyer);
        assertEq(nft721.ownerOf(2), buyer);
        assertEq(balancesAfter.sellerNative - balancesBefore.sellerNative, 2.85 ether);
        assertEq(balancesAfter.platformNative - balancesBefore.platformNative, 0.15 ether);
        assertEq(balancesAfter.rewardsNative - balancesBefore.rewardsNative, 0);
        assertEq(balancesAfter.affiliateNative - balancesBefore.affiliateNative, 0);
        assertEq(address(subject).balance, 0);

        (,, uint256 firstFilled, uint256 firstRemaining) = subject.listingStatus(seller, listing, 0);
        assertEq(firstFilled, 1);
        assertEq(firstRemaining, 0);

        (,, uint256 secondFilled, uint256 secondRemaining) = subject.listingStatus(seller, listing, 1);
        assertEq(secondFilled, 1);
        assertEq(secondRemaining, 0);
    }

    function test_e2e_buyer_buys_two_erc721_items_from_one_multi_item_erc20_listing_in_one_fulfillment() public {
        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);

        _prank(buyer);
        weth.approve(address(conduit), 3 ether);

        ScatterOfferer.ScatterSubmission memory listing = _generateTwoItemListing(
            GenerateTwoItemListingParams({
                role: ScatterOfferer.Role.Listing,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId0: 1,
                quantity0: 1,
                currency0: address(weth),
                priceWei0: 1 ether,
                tokenId1: 2,
                quantity1: 1,
                currency1: address(weth),
                priceWei1: 2 ether,
                criteriaRoot: bytes32(0),
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours,
                nonce: 0,
                salt: bytes32(uint256(0x2323))
            })
        );
        uint256[] memory itemIndexes = _twoUintArray(0, 1);
        uint256[] memory fillTokenIds = _twoUintArray(1, 2);
        uint256[] memory fillQuantities = _twoUintArray(1, 1);
        AdvancedOrder memory order = _buildSeaportOrderWithFills(
            BuildContractOrderWithFillsParams({
                listing: listing,
                signerPk: SELLER_PK,
                affiliate: address(0),
                itemIndexes: itemIndexes,
                fillTokenIds: fillTokenIds,
                fillQuantities: fillQuantities,
                criteriaProofs: new bytes32[][](0),
                attributedFulfiller: address(0)
            })
        );

        _prank(buyer);
        Balances memory balancesBefore = _snapshotBalances();
        seaport.fulfillAdvancedOrder(
            order,
            new CriteriaResolver[](0), // criteriaResolvers
            conduitKey,
            buyer // recipient
        );
        Balances memory balancesAfter = _snapshotBalances();

        // fee breakdown:
        //   totalFillPrice = 1 ether + 2 ether = 3 ether (WETH)
        //   totalFee       = 3 ether * 500 / 10000 = 0.15 ether
        //   platformFee    = 0.15 ether
        //   rewardsFee     = 0 ether
        //   affiliateFee   = 0 ether
        //   sellerAmount   = 3 ether - 0.15 ether = 2.85 ether
        assertEq(nft721.ownerOf(1), buyer);
        assertEq(nft721.ownerOf(2), buyer);
        assertEq(balancesAfter.sellerWeth - balancesBefore.sellerWeth, 2.85 ether);
        assertEq(balancesAfter.platformWeth - balancesBefore.platformWeth, 0.15 ether);
        assertEq(balancesAfter.rewardsWeth - balancesBefore.rewardsWeth, 0);
        assertEq(balancesAfter.affiliateWeth - balancesBefore.affiliateWeth, 0);
        assertEq(balancesBefore.buyerWeth - balancesAfter.buyerWeth, 3 ether);
        assertEq(weth.balanceOf(address(subject)), 0);

        (,, uint256 firstFilled, uint256 firstRemaining) = subject.listingStatus(seller, listing, 0);
        assertEq(firstFilled, 1);
        assertEq(firstRemaining, 0);

        (,, uint256 secondFilled, uint256 secondRemaining) = subject.listingStatus(seller, listing, 1);
        assertEq(secondFilled, 1);
        assertEq(secondRemaining, 0);
    }

    function test_e2e_buyer_partially_buys_one_item_from_multi_item_erc1155_listing_and_sibling_is_untouched() public {
        nft1155.mint(seller, 2, 5);

        _prank(seller);
        nft1155.setApprovalForAll(address(conduit), true);

        ScatterOfferer.ScatterSubmission memory listing = _generateTwoItemListing(
            GenerateTwoItemListingParams({
                role: ScatterOfferer.Role.Listing,
                assetType: ScatterOfferer.AssetType.ERC1155,
                collection: address(nft1155),
                tokenId0: 1,
                quantity0: 10,
                currency0: address(0),
                priceWei0: 0.1 ether,
                tokenId1: 2,
                quantity1: 5,
                currency1: address(0),
                priceWei1: 0.2 ether,
                criteriaRoot: bytes32(0),
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours,
                nonce: 0,
                salt: bytes32(uint256(0x3333))
            })
        );
        uint256[] memory itemIndexes = _singleUintArray(1);
        uint256[] memory fillTokenIds = _singleUintArray(2);
        uint256[] memory fillQuantities = _singleUintArray(2);
        AdvancedOrder memory order = _buildSeaportOrderWithFills(
            BuildContractOrderWithFillsParams({
                listing: listing,
                signerPk: SELLER_PK,
                affiliate: address(0),
                itemIndexes: itemIndexes,
                fillTokenIds: fillTokenIds,
                fillQuantities: fillQuantities,
                criteriaProofs: new bytes32[][](0),
                attributedFulfiller: address(0)
            })
        );

        _prank(buyer);
        Balances memory balancesBefore = _snapshotBalances();
        seaport.fulfillAdvancedOrder{value: 0.4 ether}(
            order,
            new CriteriaResolver[](0), // criteriaResolvers
            conduitKey,
            buyer // recipient
        );
        Balances memory balancesAfter = _snapshotBalances();

        // fee breakdown:
        //   totalFillPrice = 0.2 ether * 2 = 0.4 ether
        //   totalFee       = 0.4 ether * 500 / 10000 = 0.02 ether
        //   platformFee    = 0.02 ether
        //   rewardsFee     = 0 ether
        //   affiliateFee   = 0 ether
        //   sellerAmount   = 0.4 ether - 0.02 ether = 0.38 ether
        assertEq(nft1155.balanceOf(buyer, 2), 2);
        assertEq(nft1155.balanceOf(seller, 2), 3);
        assertEq(nft1155.balanceOf(seller, 1), 10);
        assertEq(balancesAfter.sellerNative - balancesBefore.sellerNative, 0.38 ether);
        assertEq(balancesAfter.platformNative - balancesBefore.platformNative, 0.02 ether);
        assertEq(balancesAfter.rewardsNative - balancesBefore.rewardsNative, 0);
        assertEq(balancesAfter.affiliateNative - balancesBefore.affiliateNative, 0);
        assertEq(address(subject).balance, 0);

        (,, uint256 firstFilled, uint256 firstRemaining) = subject.listingStatus(seller, listing, 0);
        assertEq(firstFilled, 0);
        assertEq(firstRemaining, 10);

        (,, uint256 secondFilled, uint256 secondRemaining) = subject.listingStatus(seller, listing, 1);
        assertEq(secondFilled, 2);
        assertEq(secondRemaining, 3);
    }

    function test_e2e_seller_sells_two_erc721s_into_multi_item_weth_bid_in_one_fulfillment() public {
        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);

        _prank(bidder);
        weth.approve(address(conduit), type(uint256).max);

        ScatterOfferer.ScatterSubmission memory bid = _generateTwoItemListing(
            GenerateTwoItemListingParams({
                role: ScatterOfferer.Role.Bid,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId0: 1,
                quantity0: 1,
                currency0: address(weth),
                priceWei0: 1 ether,
                tokenId1: 2,
                quantity1: 1,
                currency1: address(weth),
                priceWei1: 2 ether,
                criteriaRoot: bytes32(0),
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours,
                nonce: 0,
                salt: bytes32(uint256(0x4444))
            })
        );
        uint256[] memory itemIndexes = _twoUintArray(0, 1);
        uint256[] memory fillTokenIds = _twoUintArray(1, 2);
        uint256[] memory fillQuantities = _twoUintArray(1, 1);
        AdvancedOrder memory order = _buildSeaportOrderWithFills(
            BuildContractOrderWithFillsParams({
                listing: bid,
                signerPk: BIDDER_PK,
                affiliate: address(0),
                itemIndexes: itemIndexes,
                fillTokenIds: fillTokenIds,
                fillQuantities: fillQuantities,
                criteriaProofs: new bytes32[][](0),
                attributedFulfiller: address(0)
            })
        );

        _prank(seller);
        Balances memory balancesBefore = _snapshotBalances();
        seaport.fulfillAdvancedOrder(
            order,
            new CriteriaResolver[](0), // criteriaResolvers
            conduitKey,
            seller // recipient
        );
        Balances memory balancesAfter = _snapshotBalances();

        // fee breakdown:
        //   totalFillPrice = 1 ether + 2 ether = 3 ether (WETH)
        //   totalFee       = 3 ether * 500 / 10000 = 0.15 ether
        //   platformFee    = 0.15 ether
        //   rewardsFee     = 0 ether
        //   affiliateFee   = 0 ether
        //   sellerAmount   = 3 ether - 0.15 ether = 2.85 ether
        assertEq(nft721.ownerOf(1), bidder);
        assertEq(nft721.ownerOf(2), bidder);
        assertEq(balancesAfter.sellerWeth - balancesBefore.sellerWeth, 2.85 ether);
        assertEq(balancesAfter.platformWeth - balancesBefore.platformWeth, 0.15 ether);
        assertEq(balancesAfter.rewardsWeth - balancesBefore.rewardsWeth, 0);
        assertEq(balancesAfter.affiliateWeth - balancesBefore.affiliateWeth, 0);
        assertEq(balancesBefore.bidderWeth - balancesAfter.bidderWeth, 3 ether);
        assertEq(weth.balanceOf(address(subject)), 0);
        assertEq(weth.allowance(address(subject), SEAPORT), 0);
    }

    function test_e2e_seller_sells_two_erc721s_into_multi_item_weth_criteria_bid_in_one_fulfillment() public {
        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);

        _prank(bidder);
        weth.approve(address(conduit), type(uint256).max);

        (bytes32 criteriaRoot, bytes32[] memory proofForToken2) = _generateCriteriaData(1, 2);
        (, bytes32[] memory proofForToken1) = _generateCriteriaData(2, 1);
        ScatterOfferer.ScatterSubmission memory bid = _generateTwoItemListing(
            GenerateTwoItemListingParams({
                role: ScatterOfferer.Role.Bid,
                assetType: ScatterOfferer.AssetType.ERC721,
                collection: address(nft721),
                tokenId0: 0,
                quantity0: 1,
                currency0: address(weth),
                priceWei0: 1 ether,
                tokenId1: 0,
                quantity1: 1,
                currency1: address(weth),
                priceWei1: 2 ether,
                criteriaRoot: criteriaRoot,
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours,
                nonce: 0,
                salt: bytes32(uint256(0x4545))
            })
        );
        uint256[] memory itemIndexes = _twoUintArray(0, 1);
        uint256[] memory fillTokenIds = _twoUintArray(1, 2);
        uint256[] memory fillQuantities = _twoUintArray(1, 1);
        bytes32[][] memory criteriaProofs = new bytes32[][](2);
        criteriaProofs[0] = proofForToken1;
        criteriaProofs[1] = proofForToken2;
        AdvancedOrder memory order = _buildSeaportOrderWithFills(
            BuildContractOrderWithFillsParams({
                listing: bid,
                signerPk: BIDDER_PK,
                affiliate: address(0),
                itemIndexes: itemIndexes,
                fillTokenIds: fillTokenIds,
                fillQuantities: fillQuantities,
                criteriaProofs: criteriaProofs,
                attributedFulfiller: address(0)
            })
        );

        _prank(seller);
        Balances memory balancesBefore = _snapshotBalances();
        seaport.fulfillAdvancedOrder(
            order,
            new CriteriaResolver[](0), // criteriaResolvers
            conduitKey,
            seller // recipient
        );
        Balances memory balancesAfter = _snapshotBalances();

        // fee breakdown:
        //   totalFillPrice = 1 ether + 2 ether = 3 ether (WETH)
        //   totalFee       = 3 ether * 500 / 10000 = 0.15 ether
        //   platformFee    = 0.15 ether
        //   rewardsFee     = 0 ether
        //   affiliateFee   = 0 ether
        //   sellerAmount   = 3 ether - 0.15 ether = 2.85 ether
        assertEq(nft721.ownerOf(1), bidder);
        assertEq(nft721.ownerOf(2), bidder);
        assertEq(balancesAfter.sellerWeth - balancesBefore.sellerWeth, 2.85 ether);
        assertEq(balancesAfter.platformWeth - balancesBefore.platformWeth, 0.15 ether);
        assertEq(balancesAfter.rewardsWeth - balancesBefore.rewardsWeth, 0);
        assertEq(balancesAfter.affiliateWeth - balancesBefore.affiliateWeth, 0);
        assertEq(balancesBefore.bidderWeth - balancesAfter.bidderWeth, 3 ether);
        assertEq(weth.balanceOf(address(subject)), 0);
        assertEq(weth.allowance(address(subject), SEAPORT), 0);
    }

    function test_e2e_multiCollectionErc721_nativePayment_paysEachCollectionsRewards() public {
        /*
         * Buying NFTs from three collections must pay each collection's rewards recipient in ETH.
         * 1. Sign three listings priced at 1, 2, and 3 ETH. Only the first two collections pay rewards.
         * 2. Buy all three in item order 2, 0, 1 and record the sale events.
         * 3. Assert the events identify the correct collections, prices, and rewards.
         * 4. Assert the buyer owns all three NFTs and each recipient got the expected ETH payment.
         */
        // 1. Sign three listings priced at 1, 2, and 3 ETH. Only the first two collections pay rewards.
        (MockERC721E2E second, MockERC721E2E third, AdvancedOrder memory order) =
            _prepareThreeCollectionListing(address(0), address(0));

        // 2. Buy all three in item order 2, 0, 1 and record the sale events.
        _prank(buyer);
        vm.recordLogs();
        seaport.fulfillAdvancedOrder{value: 6 ether}(order, new CriteriaResolver[](0), conduitKey, buyer);
        SaleData[] memory sales = _recordedSales();

        // Price breakdown (ETH):
        //   prices           = 1 + 2 + 3 = 6
        //   fees (5%)        = 0.05 + 0.10 + 0.15 = 0.30
        //   platform         = 0.025 + 0.05 + 0.15 = 0.225
        //   rewards          = 0.025 to rewardsRecipient + 0.05 to other
        //   seller           = 6 - 0.30 = 5.70; affiliate = 0
        // 3. Assert the events identify the correct collections, prices, and rewards.
        assertEq(sales.length, 3);
        assertEq(sales[0].collection, address(third));
        assertEq(sales[0].itemIndex, 2);
        assertEq(sales[0].totalPrice, 3 ether);
        assertEq(sales[0].rewardsRecipient, address(0));
        assertEq(sales[0].rewardsAmount, 0);
        assertEq(sales[1].collection, address(nft721));
        assertEq(sales[1].itemIndex, 0);
        assertEq(sales[1].totalPrice, 1 ether);
        assertEq(sales[1].rewardsRecipient, rewardsRecipient);
        assertEq(sales[1].rewardsAmount, 0.025 ether);
        assertEq(sales[2].collection, address(second));
        assertEq(sales[2].itemIndex, 1);
        assertEq(sales[2].totalPrice, 2 ether);
        assertEq(sales[2].rewardsRecipient, other);
        assertEq(sales[2].rewardsAmount, 0.05 ether);

        // 4. Assert the buyer owns all three NFTs and each recipient got the expected ETH payment.
        assertEq(nft721.ownerOf(1), buyer);
        assertEq(second.ownerOf(1), buyer);
        assertEq(third.ownerOf(1), buyer);
        assertEq(buyer.balance, 94 ether);
        assertEq(seller.balance, 5.7 ether);
        assertEq(PLATFORM.balance, 0.225 ether);
        assertEq(rewardsRecipient.balance, 0.025 ether);
        assertEq(other.balance, 0.05 ether);
        assertEq(affiliate.balance, 0);
        assertEq(address(subject).balance, 0);
    }

    function test_e2e_multiCollectionErc721_erc20Payment_paysEachCollectionsRewards() public {
        /*
         * Buying NFTs from three collections must pay each collection's rewards recipient in WETH.
         * 1. Sign three listings priced at 1, 2, and 3 WETH. Only the first two collections pay rewards.
         * 2. Approve 6 WETH and buy all three in item order 2, 0, 1.
         * 3. Assert the events identify the correct collections, prices, and rewards.
         * 4. Assert the buyer owns all three NFTs, payments use WETH, and the buyer's ETH is untouched.
         */
        // 1. Sign three listings priced at 1, 2, and 3 WETH. Only the first two collections pay rewards.
        (MockERC721E2E second, MockERC721E2E third, AdvancedOrder memory order) =
            _prepareThreeCollectionListing(address(weth), address(0));

        // 2. Approve 6 WETH and buy all three in item order 2, 0, 1.
        _prank(buyer);
        weth.approve(address(conduit), 6 ether);
        vm.recordLogs();
        seaport.fulfillAdvancedOrder(order, new CriteriaResolver[](0), conduitKey, buyer);
        SaleData[] memory sales = _recordedSales();

        // Price breakdown (WETH):
        //   prices           = 1 + 2 + 3 = 6
        //   fees (5%)        = 0.05 + 0.10 + 0.15 = 0.30
        //   platform         = 0.025 + 0.05 + 0.15 = 0.225
        //   rewards          = 0.025 to rewardsRecipient + 0.05 to other
        //   seller           = 6 - 0.30 = 5.70; affiliate = 0
        // 3. Assert the events identify the correct collections, prices, and rewards.
        assertEq(sales.length, 3);
        assertEq(sales[0].collection, address(third));
        assertEq(sales[0].itemIndex, 2);
        assertEq(sales[0].totalPrice, 3 ether);
        assertEq(sales[0].rewardsRecipient, address(0));
        assertEq(sales[0].rewardsAmount, 0);
        assertEq(sales[1].collection, address(nft721));
        assertEq(sales[1].itemIndex, 0);
        assertEq(sales[1].totalPrice, 1 ether);
        assertEq(sales[1].rewardsRecipient, rewardsRecipient);
        assertEq(sales[1].rewardsAmount, 0.025 ether);
        assertEq(sales[2].collection, address(second));
        assertEq(sales[2].itemIndex, 1);
        assertEq(sales[2].totalPrice, 2 ether);
        assertEq(sales[2].rewardsRecipient, other);
        assertEq(sales[2].rewardsAmount, 0.05 ether);

        // 4. Assert the buyer owns all three NFTs, payments use WETH, and the buyer's ETH is untouched.
        assertEq(nft721.ownerOf(1), buyer);
        assertEq(second.ownerOf(1), buyer);
        assertEq(third.ownerOf(1), buyer);
        assertEq(weth.balanceOf(buyer), 94 ether);
        assertEq(weth.balanceOf(seller), 5.7 ether);
        assertEq(weth.balanceOf(PLATFORM), 0.225 ether);
        assertEq(weth.balanceOf(rewardsRecipient), 0.025 ether);
        assertEq(weth.balanceOf(other), 0.05 ether);
        assertEq(weth.balanceOf(affiliate), 0);
        assertEq(weth.balanceOf(address(subject)), 0);
        assertEq(buyer.balance, 100 ether);
    }

    function test_e2e_multiCollectionErc721_nativePayment_affiliateTakesPriorityOverRewards() public {
        /*
         * An affiliate must receive the fee share instead of either collection's rewards recipient.
         * 1. Sign three ETH listings with collection rewards configured and an affiliate authorization.
         * 2. Buy all three in item order 2, 0, 1 and record the sale events.
         * 3. Assert every event reports the affiliate payment and no rewards payment.
         * 4. Assert the buyer owns all NFTs, the affiliate gets 0.15 ETH, and both rewards recipients get 0.
         */
        // 1. Sign three ETH listings with collection rewards configured and an affiliate authorization.
        (MockERC721E2E second, MockERC721E2E third, AdvancedOrder memory order) =
            _prepareThreeCollectionListing(address(0), affiliate);

        // 2. Buy all three in item order 2, 0, 1 and record the sale events.
        _prank(buyer);
        vm.recordLogs();
        seaport.fulfillAdvancedOrder{value: 6 ether}(order, new CriteriaResolver[](0), conduitKey, buyer);
        SaleData[] memory sales = _recordedSales();

        // Price breakdown (ETH):
        //   prices           = 1 + 2 + 3 = 6
        //   fees (5%)        = 0.05 + 0.10 + 0.15 = 0.30
        //   platform         = 0.025 + 0.05 + 0.075 = 0.15
        //   affiliate        = 0.025 + 0.05 + 0.075 = 0.15; rewards = 0
        //   seller           = 6 - 0.30 = 5.70
        // 3. Assert every event reports the affiliate payment and no rewards payment.
        assertEq(sales.length, 3);
        assertEq(sales[0].collection, address(third));
        assertEq(sales[0].itemIndex, 2);
        assertEq(sales[0].totalPrice, 3 ether);
        assertEq(sales[0].affiliate, affiliate);
        assertEq(sales[0].affiliateAmount, 0.075 ether);
        assertEq(sales[0].rewardsRecipient, address(0));
        assertEq(sales[0].rewardsAmount, 0);
        assertEq(sales[1].collection, address(nft721));
        assertEq(sales[1].itemIndex, 0);
        assertEq(sales[1].totalPrice, 1 ether);
        assertEq(sales[1].affiliate, affiliate);
        assertEq(sales[1].affiliateAmount, 0.025 ether);
        assertEq(sales[1].rewardsRecipient, address(0));
        assertEq(sales[1].rewardsAmount, 0);
        assertEq(sales[2].collection, address(second));
        assertEq(sales[2].itemIndex, 1);
        assertEq(sales[2].totalPrice, 2 ether);
        assertEq(sales[2].affiliate, affiliate);
        assertEq(sales[2].affiliateAmount, 0.05 ether);
        assertEq(sales[2].rewardsRecipient, address(0));
        assertEq(sales[2].rewardsAmount, 0);

        // 4. Assert the buyer owns all NFTs, the affiliate gets 0.15 ETH, and both rewards recipients get 0.
        assertEq(nft721.ownerOf(1), buyer);
        assertEq(second.ownerOf(1), buyer);
        assertEq(third.ownerOf(1), buyer);
        assertEq(buyer.balance, 94 ether);
        assertEq(seller.balance, 5.7 ether);
        assertEq(PLATFORM.balance, 0.15 ether);
        assertEq(affiliate.balance, 0.15 ether);
        assertEq(rewardsRecipient.balance, 0);
        assertEq(other.balance, 0);
        assertEq(address(subject).balance, 0);
    }

    function test_e2e_multiCollectionErc721_erc20Payment_affiliateTakesPriorityOverRewards() public {
        /*
         * A WETH purchase must pay the affiliate instead of either collection's rewards recipient.
         * 1. Sign three WETH listings with collection rewards configured and an affiliate authorization.
         * 2. Approve 6 WETH and buy all three in item order 2, 0, 1.
         * 3. Assert every event reports the affiliate payment and no rewards payment.
         * 4. Assert the buyer owns all NFTs, the affiliate gets 0.15 WETH, and both rewards recipients get 0.
         */
        // 1. Sign three WETH listings with collection rewards configured and an affiliate authorization.
        (MockERC721E2E second, MockERC721E2E third, AdvancedOrder memory order) =
            _prepareThreeCollectionListing(address(weth), affiliate);

        // 2. Approve 6 WETH and buy all three in item order 2, 0, 1.
        _prank(buyer);
        weth.approve(address(conduit), 6 ether);
        vm.recordLogs();
        seaport.fulfillAdvancedOrder(order, new CriteriaResolver[](0), conduitKey, buyer);
        SaleData[] memory sales = _recordedSales();

        // Price breakdown (WETH):
        //   prices           = 1 + 2 + 3 = 6
        //   fees (5%)        = 0.05 + 0.10 + 0.15 = 0.30
        //   platform         = 0.025 + 0.05 + 0.075 = 0.15
        //   affiliate        = 0.025 + 0.05 + 0.075 = 0.15; rewards = 0
        //   seller           = 6 - 0.30 = 5.70
        // 3. Assert every event reports the affiliate payment and no rewards payment.
        assertEq(sales.length, 3);
        assertEq(sales[0].collection, address(third));
        assertEq(sales[0].itemIndex, 2);
        assertEq(sales[0].totalPrice, 3 ether);
        assertEq(sales[0].affiliate, affiliate);
        assertEq(sales[0].affiliateAmount, 0.075 ether);
        assertEq(sales[0].rewardsRecipient, address(0));
        assertEq(sales[0].rewardsAmount, 0);
        assertEq(sales[1].collection, address(nft721));
        assertEq(sales[1].itemIndex, 0);
        assertEq(sales[1].totalPrice, 1 ether);
        assertEq(sales[1].affiliate, affiliate);
        assertEq(sales[1].affiliateAmount, 0.025 ether);
        assertEq(sales[1].rewardsRecipient, address(0));
        assertEq(sales[1].rewardsAmount, 0);
        assertEq(sales[2].collection, address(second));
        assertEq(sales[2].itemIndex, 1);
        assertEq(sales[2].totalPrice, 2 ether);
        assertEq(sales[2].affiliate, affiliate);
        assertEq(sales[2].affiliateAmount, 0.05 ether);
        assertEq(sales[2].rewardsRecipient, address(0));
        assertEq(sales[2].rewardsAmount, 0);

        // 4. Assert the buyer owns all NFTs, the affiliate gets 0.15 WETH, and both rewards recipients get 0.
        assertEq(nft721.ownerOf(1), buyer);
        assertEq(second.ownerOf(1), buyer);
        assertEq(third.ownerOf(1), buyer);
        assertEq(weth.balanceOf(buyer), 94 ether);
        assertEq(weth.balanceOf(seller), 5.7 ether);
        assertEq(weth.balanceOf(PLATFORM), 0.15 ether);
        assertEq(weth.balanceOf(affiliate), 0.15 ether);
        assertEq(weth.balanceOf(rewardsRecipient), 0);
        assertEq(weth.balanceOf(other), 0);
        assertEq(weth.balanceOf(address(subject)), 0);
        assertEq(buyer.balance, 100 ether);
    }

    function test_multiCollection_erc1155_partialFillsAndCancellationArePerItem() public {
        /*
         * Buying or cancelling one collection's item must not change how many units can be bought from the other.
         * 1. List five units of token 1 from each of two ERC1155 collections.
         * 2. Buy three units of item 0 and two of item 1. Assert two and three units remain for sale, respectively.
         * 3. Cancel item 0. Assert another purchase of it reverts with OrderCancelled.
         * 4. Buy item 1's last three units. Assert the buyer now has five of item 1 and still three of item 0.
         *    Assert the seller and platform got their payments, and another purchase reverts with QuantityExceeded.
         */
        // 1. List five units of token 1 from each of two ERC1155 collections.
        MockERC1155E2E second = new MockERC1155E2E();
        second.mint(seller, 1, 10);
        _prank(seller);
        nft1155.setApprovalForAll(address(conduit), true);
        second.setApprovalForAll(address(conduit), true);
        ScatterOfferer.ScatterSubmission memory listing = _multiCollectionSubmission(
            address(nft1155), address(second), ScatterOfferer.AssetType.ERC1155, 5, address(0)
        );
        // 2. Buy three units of item 0 and two of item 1.
        BuildContractOrderWithFillsParams memory params = BuildContractOrderWithFillsParams({
            listing: listing,
            signerPk: SELLER_PK,
            affiliate: address(0),
            itemIndexes: _twoUintArray(1, 0),
            fillTokenIds: _twoUintArray(1, 1),
            fillQuantities: _twoUintArray(2, 3),
            criteriaProofs: new bytes32[][](0),
            attributedFulfiller: address(0)
        });
        AdvancedOrder memory order = _buildSeaportOrderWithFills(params);
        _prank(buyer);
        seaport.fulfillAdvancedOrder{value: 7 ether}(order, new CriteriaResolver[](0), conduitKey, buyer);
        // Assert the buyer received those units and two of item 0 and three of item 1 remain for sale.
        assertEq(nft1155.balanceOf(buyer, 1), 3);
        assertEq(second.balanceOf(buyer, 1), 2);
        (bytes32 hash,, uint256 filled, uint256 remaining) = subject.listingStatus(seller, listing, 0);
        assertEq(filled, 3);
        assertEq(remaining, 2);
        (,, filled, remaining) = subject.listingStatus(seller, listing, 1);
        assertEq(filled, 2);
        assertEq(remaining, 3);

        // 3. Cancel item 0. Assert another purchase of it reverts with OrderCancelled.
        ScatterOfferer.CancelListingItem[] memory cancelled = new ScatterOfferer.CancelListingItem[](1);
        cancelled[0] = ScatterOfferer.CancelListingItem({submissionHash: hash, itemIndex: 0});
        _prank(seller);
        subject.cancelListings(cancelled);
        params.itemIndexes = _singleUintArray(0);
        params.fillTokenIds = _singleUintArray(1);
        params.fillQuantities = _singleUintArray(1);
        vm.expectRevert(OrderCancelled.selector);
        _buildSeaportOrderWithFills(params);

        // 4. Buy item 1's last three units.
        params.itemIndexes[0] = 1;
        params.fillQuantities[0] = 3;
        order = _buildSeaportOrderWithFills(params);
        _prank(buyer);
        seaport.fulfillAdvancedOrder{value: 6 ether}(order, new CriteriaResolver[](0), conduitKey, buyer);
        // Assert item 1 reaches five units, item 0 stays at three, and the seller and platform are paid.
        // Price breakdown (ETH): first purchase = 3 * 1 + 2 * 2 = 7; second = 3 * 2 = 6.
        // Total = 13; platform (5%, no rewards) = 0.35 + 0.30 = 0.65; seller = 12.35.
        assertEq(second.balanceOf(buyer, 1), 5);
        assertEq(nft1155.balanceOf(buyer, 1), 3);
        assertEq(seller.balance, 12.35 ether);
        assertEq(PLATFORM.balance, 0.65 ether);
        // Assert another purchase of the sold-out item reverts with QuantityExceeded.
        params.fillQuantities[0] = 1;
        vm.expectRevert(QuantityExceeded.selector);
        _buildSeaportOrderWithFills(params);
    }

    function test_multiCollection_missingApprovalRevertsWholeFill() public {
        /*
         * If either collection lacks transfer approval, the buyer must get neither NFT and spend nothing.
         * 1. Seller signs one item from each collection but approves only the first collection.
         * 2. Try buying both. Assert the call reverts, both NFTs stay with the seller, and no payment or fill is recorded.
         * 3. Approve the second collection and retry the same order.
         *    Assert the buyer gets both NFTs, the seller gets 2.85 ETH, and the platform gets 0.15 ETH.
         */
        // 1. Seller signs one item from each collection but approves only the first collection.
        MockERC721E2E second = new MockERC721E2E();
        second.mint(seller, 1);
        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);
        ScatterOfferer.ScatterSubmission memory listing = _multiCollectionSubmission(
            address(nft721), address(second), ScatterOfferer.AssetType.ERC721, 1, address(0)
        );
        AdvancedOrder memory order = _buildSeaportOrderWithFills(
            BuildContractOrderWithFillsParams({
                listing: listing,
                signerPk: SELLER_PK,
                affiliate: address(0),
                itemIndexes: _twoUintArray(0, 1),
                fillTokenIds: _twoUintArray(1, 1),
                fillQuantities: _twoUintArray(1, 1),
                criteriaProofs: new bytes32[][](0),
                attributedFulfiller: address(0)
            })
        );
        // 2. Try buying both. Assert the call reverts.
        _prank(buyer);
        vm.expectRevert();
        seaport.fulfillAdvancedOrder{value: 3 ether}(order, new CriteriaResolver[](0), conduitKey, buyer);
        // Assert both NFTs stay with the seller and no payment or fill is recorded.
        // Reverted purchase: buyer spends 0 ETH; seller and platform each receive 0 ETH.
        assertEq(nft721.ownerOf(1), seller);
        assertEq(second.ownerOf(1), seller);
        assertEq(buyer.balance, 100 ether);
        assertEq(seller.balance, 0);
        assertEq(PLATFORM.balance, 0);
        (,, uint256 filled,) = subject.listingStatus(seller, listing, 0);
        assertEq(filled, 0);
        (,, filled,) = subject.listingStatus(seller, listing, 1);
        assertEq(filled, 0);

        // 3. Approve the second collection and retry the same order.
        _prank(seller);
        second.setApprovalForAll(address(conduit), true);
        _prank(buyer);
        seaport.fulfillAdvancedOrder{value: 3 ether}(order, new CriteriaResolver[](0), conduitKey, buyer);
        // Assert the buyer gets both NFTs, the seller gets 2.85 ETH, and the platform gets 0.15 ETH.
        // Price breakdown (ETH): prices = 1 + 2 = 3; platform (5%, no rewards) = 0.15; seller = 2.85.
        assertEq(nft721.ownerOf(1), buyer);
        assertEq(second.ownerOf(1), buyer);
        assertEq(seller.balance, 2.85 ether);
        assertEq(PLATFORM.balance, 0.15 ether);
    }

    function test_e2e_multiCollectionListings_fillSeparatelyInTheirOwnCurrencies() public {
        /*
         * Items signed together can have different currencies, but the buyer must purchase them separately.
         * 1. List item 0 in ETH and item 1 in WETH, with different rewards recipients.
         * 2. Assert buying both in one call reverts with CurrencyMismatch.
         * 3. Approve and buy only item 1. Assert it transfers and pays its recipients in WETH.
         *    Assert item 0 stays with the seller, its fill count stays 0, and its recipient gets no WETH.
         * 4. Approve and buy item 0. Assert it transfers and pays its recipients in ETH.
         *    Assert the offerer keeps no funds and buying item 0 again reverts with QuantityExceeded.
         */
        // 1. List item 0 in ETH and item 1 in WETH, with different rewards recipients.
        _prank(address(this));
        MockERC721E2E secondCollection = new MockERC721E2E();
        secondCollection.mint(seller, 1);
        scatterCollectionRegistry.setRewardsOverride(address(nft721), rewardsRecipient);
        scatterCollectionRegistry.setRewardsOverride(address(secondCollection), other);
        ScatterOfferer.ScatterSubmission memory listing = _multiCollectionSubmission({
            first: address(nft721),
            second: address(secondCollection),
            assetType: ScatterOfferer.AssetType.ERC721,
            quantity: 1,
            currency: address(0)
        });
        listing.listings[1].currency = address(weth);
        BuildContractOrderWithFillsParams memory params = BuildContractOrderWithFillsParams({
            listing: listing,
            signerPk: SELLER_PK,
            affiliate: address(0),
            itemIndexes: _twoUintArray(0, 1),
            fillTokenIds: _twoUintArray(1, 1),
            fillQuantities: _twoUintArray(1, 1),
            criteriaProofs: new bytes32[][](0),
            attributedFulfiller: address(0)
        });

        // 2. Assert buying both in one call reverts with CurrencyMismatch.
        vm.expectRevert(CurrencyMismatch.selector);
        _buildSeaportOrderWithFills(params);

        // 3. Approve and buy only item 1.
        _prank(seller);
        secondCollection.setApprovalForAll(address(conduit), true);
        params.itemIndexes = _singleUintArray(1);
        params.fillTokenIds = _singleUintArray(1);
        params.fillQuantities = _singleUintArray(1);
        AdvancedOrder memory secondOrder = _buildSeaportOrderWithFills(params);
        _prank(buyer);
        weth.approve(address(conduit), 2 ether);
        seaport.fulfillAdvancedOrder(secondOrder, new CriteriaResolver[](0), conduitKey, buyer);

        // Assert item 1 transfers and pays its recipients in WETH; item 0 stays unsold and receives no rewards.
        // Price breakdown (WETH): price = 2; fee (5%) = 0.10; seller = 1.90.
        // Platform = 0.05; second collection's rewards recipient = 0.05; first collection = 0.
        assertEq(nft721.ownerOf(1), seller);
        assertEq(secondCollection.ownerOf(1), buyer);
        assertEq(weth.balanceOf(buyer), 98 ether);
        assertEq(weth.balanceOf(seller), 1.9 ether);
        assertEq(weth.balanceOf(PLATFORM), 0.05 ether);
        assertEq(weth.balanceOf(other), 0.05 ether);
        assertEq(weth.balanceOf(rewardsRecipient), 0);
        assertEq(buyer.balance, 100 ether);
        (,, uint256 firstFilled,) = subject.listingStatus(seller, listing, 0);
        (,, uint256 secondFilled,) = subject.listingStatus(seller, listing, 1);
        assertEq(firstFilled, 0);
        assertEq(secondFilled, 1);

        // 4. Approve and buy item 0.
        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);
        params.itemIndexes[0] = 0;
        AdvancedOrder memory firstOrder = _buildSeaportOrderWithFills(params);
        _prank(buyer);
        seaport.fulfillAdvancedOrder{value: 1 ether}(firstOrder, new CriteriaResolver[](0), conduitKey, buyer);

        // Assert item 0 transfers, its recipients get ETH, and the offerer keeps no funds.
        // Price breakdown (ETH): price = 1; fee (5%) = 0.05; seller = 0.95.
        // Platform = 0.025; first collection's rewards recipient = 0.025; second collection = 0.
        assertEq(nft721.ownerOf(1), buyer);
        assertEq(seller.balance, 0.95 ether);
        assertEq(PLATFORM.balance, 0.025 ether);
        assertEq(rewardsRecipient.balance, 0.025 ether);
        assertEq(other.balance, 0);
        assertEq(address(subject).balance, 0);
        assertEq(weth.balanceOf(address(subject)), 0);
        // Assert buying item 0 again reverts with QuantityExceeded.
        vm.expectRevert(QuantityExceeded.selector);
        _buildSeaportOrderWithFills(params);
    }

    function test_e2e_multiCollectionListings_rejectDuplicatePairsAndAllowDifferentTokensInOneCollection() public {
        /*
         * The same NFT cannot appear twice, but different collections can have the same token ID.
         * 1. List token 1 from collection A, token 1 from B, and token 1 from A again. Both collections pay one recipient.
         * 2. Assert the repeated NFT causes DuplicateListingItem.
         * 3. Replace the last item with token 2 from A, sign again, and buy all three for 3,071 wei.
         * 4. Assert the buyer owns all three NFTs and spent 3,071 wei.
         *    Assert the seller gets 2,918 wei, the platform gets 76 wei, and the shared recipient gets 77 wei.
         */
        // 1. List token 1 from A, token 1 from B, and token 1 from A again, with one rewards recipient.
        _prank(address(this));
        MockERC721E2E secondCollection = new MockERC721E2E();
        secondCollection.mint(seller, 1);
        scatterCollectionRegistry.setRewardsOverride(address(nft721), rewardsRecipient);
        scatterCollectionRegistry.setRewardsOverride(address(secondCollection), rewardsRecipient);
        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);
        secondCollection.setApprovalForAll(address(conduit), true);
        ScatterOfferer.ScatterSubmission memory listing = _multiCollectionSubmission({
            first: address(nft721),
            second: address(secondCollection),
            assetType: ScatterOfferer.AssetType.ERC721,
            quantity: 1,
            currency: address(0)
        });
        ScatterOfferer.ScatterListing[] memory items = new ScatterOfferer.ScatterListing[](3);
        items[0] = listing.listings[0];
        items[1] = listing.listings[1];
        items[0].priceWei = 1_001;
        items[1].priceWei = 1_023;
        items[2] = ScatterOfferer.ScatterListing({
            assetType: ScatterOfferer.AssetType.ERC721,
            collection: address(nft721),
            tokenId: 1,
            quantity: 1,
            currency: address(0),
            priceWei: 1_047
        });
        listing.listings = items;
        uint256[] memory itemIndexes = new uint256[](3);
        itemIndexes[0] = 0;
        itemIndexes[1] = 1;
        itemIndexes[2] = 2;
        uint256[] memory tokenIds = new uint256[](3);
        tokenIds[0] = tokenIds[1] = tokenIds[2] = 1;
        uint256[] memory quantities = new uint256[](3);
        quantities[0] = quantities[1] = quantities[2] = 1;
        BuildContractOrderWithFillsParams memory params = BuildContractOrderWithFillsParams({
            listing: listing,
            signerPk: SELLER_PK,
            affiliate: address(0),
            itemIndexes: itemIndexes,
            fillTokenIds: tokenIds,
            fillQuantities: quantities,
            criteriaProofs: new bytes32[][](0),
            attributedFulfiller: address(0)
        });

        // 2. Assert the repeated NFT causes DuplicateListingItem.
        vm.expectRevert(DuplicateListingItem.selector);
        _buildSeaportOrderWithFills(params);

        // 3. Replace the last item with token 2 from A, sign again, and buy all three for 3,071 wei.
        listing.listings[2].tokenId = 2;
        tokenIds[2] = 2;
        AdvancedOrder memory order = _buildSeaportOrderWithFills(params);
        _prank(buyer);
        seaport.fulfillAdvancedOrder{value: 3_071}(order, new CriteriaResolver[](0), conduitKey, buyer);

        // 4. Assert the buyer owns all three NFTs and each recipient got the expected rounded payment.
        // Price breakdown (wei): prices = 1,001 + 1,023 + 1,047 = 3,071.
        // Fees (5%, rounded down per item) = 50 + 51 + 52 = 153; seller = 3,071 - 153 = 2,918.
        // Platform (half each fee, rounded down) = 25 + 25 + 26 = 76.
        // Shared rewards recipient (rest of each fee) = 25 + 26 + 26 = 77.
        assertEq(nft721.ownerOf(1), buyer);
        assertEq(nft721.ownerOf(2), buyer);
        assertEq(secondCollection.ownerOf(1), buyer);
        assertEq(seller.balance, 2_918);
        assertEq(PLATFORM.balance, 76);
        assertEq(rewardsRecipient.balance, 77);
        assertEq(buyer.balance, 100 ether - 3_071);
    }

    function testFuzz_e2e_multiCollectionErc1155Bid_conservesPaymentsAndTracksEachCollection(
        uint8 firstQuantity,
        uint8 secondQuantity,
        uint96 unitPrice
    ) public {
        /*
         * Selling part of each collection's bid must transfer and charge only for the units sold.
         * 1. Choose 1-9 units per collection and their prices. Each collection has its own rewards recipient.
         * 2. Bid for ten units per collection, approve payment for the chosen units, and sell them in order 1, 0.
         * 3. Assert the bidder receives the chosen units and the seller keeps the rest.
         *    Assert each fill count, remaining quantity, payment, rounded fee, and rewards amount is correct.
         *    Assert the offerer holds no WETH and both payment allowances are 0.
         * 4. Increment the bidder's nonce. Assert another fill reverts with NonceMismatch.
         */
        // 1. Choose 1-9 units per collection and their prices, with separate rewards recipients.
        uint256 firstFillQuantity = bound(firstQuantity, 1, 9);
        uint256 secondFillQuantity = bound(secondQuantity, 1, 9);
        uint256 firstUnitPrice = bound(unitPrice, 1, 1 ether);
        uint256 secondUnitPrice = firstUnitPrice + 23;
        uint256 firstPrice = firstUnitPrice * firstFillQuantity;
        uint256 secondPrice = secondUnitPrice * secondFillQuantity;

        _prank(address(this));
        MockERC1155E2E secondCollection = new MockERC1155E2E();
        secondCollection.mint(seller, 1, 10);
        scatterCollectionRegistry.setRewardsOverride(address(nft1155), rewardsRecipient);
        scatterCollectionRegistry.setRewardsOverride(address(secondCollection), other);
        _prank(seller);
        nft1155.setApprovalForAll(address(conduit), true);
        secondCollection.setApprovalForAll(address(conduit), true);
        // 2. Bid for ten units per collection, approve payment for the chosen units, and sell them in order 1, 0.
        _prank(bidder);
        weth.approve(address(conduit), firstPrice + secondPrice);

        ScatterOfferer.ScatterSubmission memory bid = _multiCollectionSubmission({
            first: address(nft1155),
            second: address(secondCollection),
            assetType: ScatterOfferer.AssetType.ERC1155,
            quantity: 10,
            currency: address(weth)
        });
        bid.role = ScatterOfferer.Role.Bid;
        bid.listings[0].priceWei = firstUnitPrice;
        bid.listings[1].priceWei = secondUnitPrice;
        BuildContractOrderWithFillsParams memory params = BuildContractOrderWithFillsParams({
            listing: bid,
            signerPk: BIDDER_PK,
            affiliate: address(0),
            itemIndexes: _twoUintArray(1, 0),
            fillTokenIds: _twoUintArray(1, 1),
            fillQuantities: _twoUintArray(secondFillQuantity, firstFillQuantity),
            criteriaProofs: new bytes32[][](0),
            attributedFulfiller: address(0)
        });
        AdvancedOrder memory order = _buildSeaportOrderWithFills(params);
        _prank(seller);
        seaport.fulfillAdvancedOrder(order, new CriteriaResolver[](0), conduitKey, seller);

        // 3. Assert the bidder gets the chosen units, the seller keeps the rest, and each fill count is correct.
        assertEq(nft1155.balanceOf(bidder, 1), firstFillQuantity);
        assertEq(secondCollection.balanceOf(bidder, 1), secondFillQuantity);
        assertEq(nft1155.balanceOf(seller, 1), 10 - firstFillQuantity);
        assertEq(secondCollection.balanceOf(seller, 1), 10 - secondFillQuantity);
        (,, uint256 firstFilled, uint256 firstRemaining) = subject.listingStatus(bidder, bid, 0);
        (,, uint256 secondFilled, uint256 secondRemaining) = subject.listingStatus(bidder, bid, 1);
        assertEq(firstFilled, firstFillQuantity);
        assertEq(secondFilled, secondFillQuantity);
        assertEq(firstRemaining, 10 - firstFillQuantity);
        assertEq(secondRemaining, 10 - secondFillQuantity);

        // Price breakdown (WETH wei), calculated separately for each collection:
        //   price = unit price * units sold; fee = floor(price / 20)
        //   platform = floor(fee / 2); rewards = fee - platform; seller = price - fee
        // The bidder pays both prices; each rewards recipient gets only its collection's share.
        uint256 firstFee = firstPrice / 20;
        uint256 secondFee = secondPrice / 20;
        uint256 firstReward = firstFee - firstFee / 2;
        uint256 secondReward = secondFee - secondFee / 2;
        assertEq(weth.balanceOf(bidder), 100 ether - firstPrice - secondPrice);
        assertEq(weth.balanceOf(seller), firstPrice + secondPrice - firstFee - secondFee);
        assertEq(weth.balanceOf(PLATFORM), firstFee / 2 + secondFee / 2);
        assertEq(weth.balanceOf(rewardsRecipient), firstReward);
        assertEq(weth.balanceOf(other), secondReward);
        // Assert the offerer holds no WETH and both payment allowances are 0.
        assertEq(weth.balanceOf(address(subject)), 0);
        assertEq(weth.allowance(address(subject), SEAPORT), 0);
        assertEq(weth.allowance(bidder, address(conduit)), 0);

        // 4. Increment the bidder's nonce. Assert another fill reverts with NonceMismatch.
        _prank(bidder);
        subject.incrementCounter();
        params.fillQuantities = _twoUintArray(1, 1);
        vm.expectRevert(NonceMismatch.selector);
        _buildSeaportOrderWithFills(params);
    }

    function test_multiCollection_collectionBid_paysEachCollectionsRewards() public {
        /*
         * A bid covering two collections must pay the right rewards recipient for each NFT sold.
         * 1. Bid 1 WETH for an NFT from the first collection and 2 WETH for one from the second.
         * 2. Accept any token ID from either collection without requiring proofs.
         * 3. Seller sells both NFTs to the bidder in item order 1, 0.
         * 4. Assert the bidder owns both NFTs and spent 3 WETH; the seller gets 2.85 WETH.
         *    Assert the platform gets 0.075 WETH and the two rewards recipients get 0.025 and 0.05 WETH.
         *    Assert the offerer keeps no WETH and its Seaport allowance is 0.
         */
        // 1. Bid 1 WETH for an NFT from the first collection and 2 WETH for one from the second.
        _prank(address(this));
        MockERC721E2E second = new MockERC721E2E();
        second.mint(seller, 1);
        scatterCollectionRegistry.setRewardsOverride(address(nft721), rewardsRecipient);
        scatterCollectionRegistry.setRewardsOverride(address(second), other);
        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);
        second.setApprovalForAll(address(conduit), true);
        _prank(bidder);
        weth.approve(address(conduit), 3 ether);
        ScatterOfferer.ScatterSubmission memory bid = _multiCollectionSubmission(
            address(nft721), address(second), ScatterOfferer.AssetType.ERC721, 1, address(weth)
        );
        bid.role = ScatterOfferer.Role.Bid;
        bid.listings[0].tokenId = bid.listings[1].tokenId = 0;
        BuildContractOrderWithFillsParams memory params = BuildContractOrderWithFillsParams({
            listing: bid,
            signerPk: BIDDER_PK,
            affiliate: address(0),
            itemIndexes: _twoUintArray(1, 0),
            fillTokenIds: _twoUintArray(1, 1),
            fillQuantities: _twoUintArray(1, 1),
            criteriaProofs: new bytes32[][](0),
            attributedFulfiller: address(0)
        });
        // 2. Accept any token ID from either collection without requiring proofs.
        // 3. Seller sells both NFTs to the bidder in item order 1, 0.
        AdvancedOrder memory order = _buildSeaportOrderWithFills(params);
        _prank(seller);
        seaport.fulfillAdvancedOrder(order, new CriteriaResolver[](0), conduitKey, seller);
        // 4. Assert the bidder owns both NFTs and spent 3 WETH; assert each recipient's WETH payment.
        // Price breakdown (WETH): prices = 1 + 2 = 3; fees = 0.05 + 0.10 = 0.15.
        // Seller = 3 - 0.15 = 2.85; platform = 0.025 + 0.05 = 0.075.
        // Rewards = 0.025 to rewardsRecipient and 0.05 to other.
        assertEq(nft721.ownerOf(1), bidder);
        assertEq(second.ownerOf(1), bidder);
        assertEq(weth.balanceOf(seller), 2.85 ether);
        assertEq(weth.balanceOf(bidder), 97 ether);
        assertEq(weth.balanceOf(PLATFORM), 0.075 ether);
        assertEq(weth.balanceOf(rewardsRecipient), 0.025 ether);
        assertEq(weth.balanceOf(other), 0.05 ether);
        // Assert the offerer keeps no WETH and its Seaport allowance is 0.
        assertEq(weth.balanceOf(address(subject)), 0);
        assertEq(weth.allowance(address(subject), SEAPORT), 0);
    }

    function testFuzz_multiCollectionErc1155Bid_combinesRewardsForSharedRecipient(
        uint8 firstQuantity,
        uint8 secondQuantity,
        uint96 unitPrice
    ) public {
        /*
         * Two collections paying the same rewards recipient must add both payments together.
         * 1. Choose partial quantities and prices; configure one recipient for both collections.
         * 2. Sell the chosen units to the bidder in item order 1, 0.
         * 3. Assert each collection transfers only the chosen units and records its own remaining quantity.
         * 4. Assert both rewards reach the shared recipient and every WETH payment is accounted for.
         */
        // 1. Choose partial quantities and prices; configure one recipient for both collections.
        uint256 firstFill = bound(firstQuantity, 1, 9);
        uint256 secondFill = bound(secondQuantity, 1, 9);
        uint256 firstUnitPrice = bound(unitPrice, 1, 1 ether);
        uint256 secondUnitPrice = firstUnitPrice + 23;
        uint256 firstPrice = firstUnitPrice * firstFill;
        uint256 secondPrice = secondUnitPrice * secondFill;
        _prank(address(this));
        MockERC1155E2E second = new MockERC1155E2E();
        second.mint(seller, 1, 10);
        scatterCollectionRegistry.setRewardsOverride(address(nft1155), rewardsRecipient);
        scatterCollectionRegistry.setRewardsOverride(address(second), rewardsRecipient);
        _prank(seller);
        nft1155.setApprovalForAll(address(conduit), true);
        second.setApprovalForAll(address(conduit), true);
        _prank(bidder);
        weth.approve(address(conduit), firstPrice + secondPrice);
        ScatterOfferer.ScatterSubmission memory bid = _multiCollectionSubmission(
            address(nft1155), address(second), ScatterOfferer.AssetType.ERC1155, 10, address(weth)
        );
        bid.role = ScatterOfferer.Role.Bid;
        bid.listings[0].priceWei = firstUnitPrice;
        bid.listings[1].priceWei = secondUnitPrice;

        // 2. Sell the chosen units to the bidder in item order 1, 0.
        AdvancedOrder memory order = _buildSeaportOrderWithFills(
            BuildContractOrderWithFillsParams({
                listing: bid,
                signerPk: BIDDER_PK,
                affiliate: address(0),
                itemIndexes: _twoUintArray(1, 0),
                fillTokenIds: _twoUintArray(1, 1),
                fillQuantities: _twoUintArray(secondFill, firstFill),
                criteriaProofs: new bytes32[][](0),
                attributedFulfiller: address(0)
            })
        );
        _prank(seller);
        seaport.fulfillAdvancedOrder(order, new CriteriaResolver[](0), conduitKey, seller);

        // 3. Assert each collection transfers only the chosen units and records its own remaining quantity.
        assertEq(nft1155.balanceOf(bidder, 1), firstFill);
        assertEq(second.balanceOf(bidder, 1), secondFill);
        assertEq(nft1155.balanceOf(seller, 1), 10 - firstFill);
        assertEq(second.balanceOf(seller, 1), 10 - secondFill);
        (,, uint256 firstFilled, uint256 firstRemaining) = subject.listingStatus(bidder, bid, 0);
        (,, uint256 secondFilled, uint256 secondRemaining) = subject.listingStatus(bidder, bid, 1);
        assertEq(firstFilled, firstFill);
        assertEq(secondFilled, secondFill);
        assertEq(firstRemaining, 10 - firstFill);
        assertEq(secondRemaining, 10 - secondFill);

        // Price breakdown (WETH wei), calculated separately for each collection:
        //   price = unit price * units sold; fee = floor(price / 20)
        //   platform = floor(fee / 2); rewards = fee - platform; seller = price - fee
        // 4. Assert the shared recipient gets both rewards, rounded per collection before adding.
        uint256 firstFee = firstPrice / 20;
        uint256 secondFee = secondPrice / 20;
        uint256 firstReward = firstFee - firstFee / 2;
        uint256 secondReward = secondFee - secondFee / 2;
        assertEq(weth.balanceOf(bidder), 100 ether - firstPrice - secondPrice);
        assertEq(weth.balanceOf(seller), firstPrice + secondPrice - firstFee - secondFee);
        assertEq(weth.balanceOf(PLATFORM), firstFee / 2 + secondFee / 2);
        assertEq(weth.balanceOf(rewardsRecipient), firstReward + secondReward);
        assertEq(weth.balanceOf(other), 0);
        assertEq(weth.balanceOf(address(subject)), 0);
        assertEq(weth.allowance(address(subject), SEAPORT), 0);
        assertEq(weth.allowance(bidder, address(conduit)), 0);
    }

    function test_multiCollection_criteriaBid_requiresBothProofsAndPaysEachCollectionsRewards() public {
        /*
         * A bid limited to allowed token IDs must check both proofs and pay each collection's rewards.
         * 1. Bid 1 and 2 WETH for two collections, limited to token IDs 1 and 2.
         * 2. Omit the second proof and assert InvalidCriteriaProof, then supply it.
         * 3. Sell token 1 from both collections in item order 1, 0.
         * 4. Assert NFT ownership and each WETH payment, including separate rewards.
         */
        // 1. Bid 1 and 2 WETH for two collections, limited to token IDs 1 and 2.
        _prank(address(this));
        MockERC721E2E second = new MockERC721E2E();
        second.mint(seller, 1);
        scatterCollectionRegistry.setRewardsOverride(address(nft721), rewardsRecipient);
        scatterCollectionRegistry.setRewardsOverride(address(second), other);
        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);
        second.setApprovalForAll(address(conduit), true);
        _prank(bidder);
        weth.approve(address(conduit), 3 ether);
        ScatterOfferer.ScatterSubmission memory bid = _multiCollectionSubmission(
            address(nft721), address(second), ScatterOfferer.AssetType.ERC721, 1, address(weth)
        );
        bid.role = ScatterOfferer.Role.Bid;
        bid.listings[0].tokenId = bid.listings[1].tokenId = 0;
        (bytes32 root, bytes32[] memory proof) = _generateCriteriaData(2, 1);
        bid.criteriaRoot = root;
        BuildContractOrderWithFillsParams memory params = BuildContractOrderWithFillsParams({
            listing: bid,
            signerPk: BIDDER_PK,
            affiliate: address(0),
            itemIndexes: _twoUintArray(1, 0),
            fillTokenIds: _twoUintArray(1, 1),
            fillQuantities: _twoUintArray(1, 1),
            criteriaProofs: new bytes32[][](2),
            attributedFulfiller: address(0)
        });
        // 2. Omit the second proof and assert InvalidCriteriaProof, then supply it.
        params.criteriaProofs[0] = proof;
        params.criteriaProofs[1] = new bytes32[](0);
        vm.expectRevert(InvalidCriteriaProof.selector);
        _buildSeaportOrderWithFills(params);
        params.criteriaProofs[1] = proof;

        // 3. Sell token 1 from both collections in item order 1, 0.
        AdvancedOrder memory order = _buildSeaportOrderWithFills(params);
        _prank(seller);
        seaport.fulfillAdvancedOrder(order, new CriteriaResolver[](0), conduitKey, seller);

        // Price breakdown (WETH): prices = 1 + 2 = 3; fees = 0.05 + 0.10 = 0.15.
        // Seller = 3 - 0.15 = 2.85; platform = 0.025 + 0.05 = 0.075.
        // Rewards = 0.025 to rewardsRecipient and 0.05 to other.
        // 4. Assert NFT ownership and each WETH payment, including separate rewards.
        assertEq(nft721.ownerOf(1), bidder);
        assertEq(second.ownerOf(1), bidder);
        assertEq(weth.balanceOf(seller), 2.85 ether);
        assertEq(weth.balanceOf(bidder), 97 ether);
        assertEq(weth.balanceOf(PLATFORM), 0.075 ether);
        assertEq(weth.balanceOf(rewardsRecipient), 0.025 ether);
        assertEq(weth.balanceOf(other), 0.05 ether);
        assertEq(weth.balanceOf(address(subject)), 0);
        assertEq(weth.allowance(address(subject), SEAPORT), 0);
    }

    function test_e2e_mixedListing_settlesEachAssetTypeAndCancelsOnlyRemainingItem() public {
        _prank(address(this));
        scatterCollectionRegistry.setRewardsOverride(address(nft1155), rewardsRecipient);
        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);
        nft1155.setApprovalForAll(address(conduit), true);

        ScatterOfferer.ScatterSubmission memory listing = _multiCollectionSubmission(
            address(nft721), address(nft1155), ScatterOfferer.AssetType.ERC721, 1, address(0)
        );
        listing.listings[1].assetType = ScatterOfferer.AssetType.ERC1155;
        listing.listings[1].quantity = 5;
        BuildContractOrderWithFillsParams memory params = BuildContractOrderWithFillsParams({
            listing: listing,
            signerPk: SELLER_PK,
            affiliate: address(0),
            itemIndexes: _twoUintArray(1, 0),
            fillTokenIds: _twoUintArray(1, 1),
            fillQuantities: _twoUintArray(3, 1),
            criteriaProofs: new bytes32[][](0),
            attributedFulfiller: address(0)
        });
        AdvancedOrder memory order = _buildSeaportOrderWithFills(params);
        _prank(buyer);
        vm.recordLogs();
        seaport.fulfillAdvancedOrder{value: 7 ether}(order, new CriteriaResolver[](0), conduitKey, buyer);
        SaleData[] memory sales = _recordedSales();

        assertEq(nft721.ownerOf(1), buyer);
        assertEq(nft1155.balanceOf(buyer, 1), 3);
        assertEq(nft1155.balanceOf(seller, 1), 7);
        assertEq(nft1155.balanceOf(address(subject), 1), 0);
        assertEq(buyer.balance, 93 ether);
        assertEq(seller.balance, 6.65 ether);
        assertEq(PLATFORM.balance, 0.2 ether);
        assertEq(rewardsRecipient.balance, 0.15 ether);
        assertEq(address(subject).balance, 0);
        assertEq(sales.length, 2);
        assertEq(sales[0].collection, address(nft1155));
        assertEq(sales[0].itemIndex, 1);
        assertEq(sales[0].quantity, 3);
        assertEq(sales[0].totalPrice, 6 ether);
        assertEq(sales[1].collection, address(nft721));
        assertEq(sales[1].itemIndex, 0);
        assertEq(sales[1].totalPrice, 1 ether);

        (bytes32 hash,, uint256 filled, uint256 remaining) = subject.listingStatus(seller, listing, 1);
        assertEq(filled, 3);
        assertEq(remaining, 2);
        ScatterOfferer.CancelListingItem[] memory cancellations = new ScatterOfferer.CancelListingItem[](1);
        cancellations[0] = ScatterOfferer.CancelListingItem(hash, 1);
        _prank(seller);
        subject.cancelListings(cancellations);
        (, bool cancelled721, uint256 filled721, uint256 remaining721) = subject.listingStatus(seller, listing, 0);
        assertFalse(cancelled721);
        assertEq(filled721, 1);
        assertEq(remaining721, 0);
        params.itemIndexes = _singleUintArray(1);
        params.fillTokenIds = _singleUintArray(1);
        params.fillQuantities = _singleUintArray(2);
        vm.expectRevert(OrderCancelled.selector);
        _buildSeaportOrderWithFills(params);
    }

    function testFuzz_e2e_mixedBid_conservesPaymentsAndTracksPartialQuantities(uint8 quantity, uint96 price) public {
        uint256 fillQuantity = bound(quantity, 1, 9);
        uint256 unitPrice = bound(price, 1, 1 ether);
        uint256 erc1155Price = unitPrice * fillQuantity;
        uint256 totalPrice = 1 ether + erc1155Price;
        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);
        nft1155.setApprovalForAll(address(conduit), true);
        _prank(bidder);
        weth.approve(address(conduit), totalPrice);

        ScatterOfferer.ScatterSubmission memory bid = _multiCollectionSubmission(
            address(nft1155), address(nft721), ScatterOfferer.AssetType.ERC721, 1, address(weth)
        );
        bid.role = ScatterOfferer.Role.Bid;
        bid.listings[0].assetType = ScatterOfferer.AssetType.ERC1155;
        bid.listings[0].quantity = 10;
        bid.listings[0].priceWei = unitPrice;
        bid.listings[1].priceWei = 1 ether;
        BuildContractOrderWithFillsParams memory params = BuildContractOrderWithFillsParams({
            listing: bid,
            signerPk: BIDDER_PK,
            affiliate: address(0),
            itemIndexes: _twoUintArray(0, 1),
            fillTokenIds: _twoUintArray(1, 1),
            fillQuantities: _twoUintArray(fillQuantity, 1),
            criteriaProofs: new bytes32[][](0),
            attributedFulfiller: address(0)
        });
        AdvancedOrder memory order = _buildSeaportOrderWithFills(params);
        _prank(seller);
        seaport.fulfillAdvancedOrder(order, new CriteriaResolver[](0), conduitKey, seller);

        assertEq(nft721.ownerOf(1), bidder);
        assertEq(nft1155.balanceOf(bidder, 1), fillQuantity);
        assertEq(nft1155.balanceOf(seller, 1), 10 - fillQuantity);
        assertEq(weth.balanceOf(bidder), 100 ether - totalPrice);
        assertEq(weth.balanceOf(seller), totalPrice - 0.05 ether - erc1155Price / 20);
        assertEq(weth.balanceOf(PLATFORM), 0.05 ether + erc1155Price / 20);
        assertEq(weth.balanceOf(address(subject)), 0);
        assertEq(weth.allowance(address(subject), SEAPORT), 0);
        assertEq(weth.allowance(bidder, address(conduit)), 0);
        (,, uint256 filled1155, uint256 remaining1155) = subject.listingStatus(bidder, bid, 0);
        (,, uint256 filled721, uint256 remaining721) = subject.listingStatus(bidder, bid, 1);
        assertEq(filled1155, fillQuantity);
        assertEq(remaining1155, 10 - fillQuantity);
        assertEq(filled721, 1);
        assertEq(remaining721, 0);
    }

    function test_e2e_mixedCriteriaBid_checksEachProofAndErc721Quantity() public {
        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);
        nft1155.setApprovalForAll(address(conduit), true);
        _prank(bidder);
        weth.approve(address(conduit), 7 ether);
        ScatterOfferer.ScatterSubmission memory bid = _multiCollectionSubmission(
            address(nft721), address(nft1155), ScatterOfferer.AssetType.ERC1155, 5, address(weth)
        );
        bid.role = ScatterOfferer.Role.Bid;
        bid.listings[0].assetType = ScatterOfferer.AssetType.ERC721;
        bid.listings[0].quantity = 2;
        bid.listings[0].tokenId = bid.listings[1].tokenId = 0;
        (bytes32 root, bytes32[] memory proof1) = _generateCriteriaData(2, 1);
        (, bytes32[] memory proof2) = _generateCriteriaData(1, 2);
        bid.criteriaRoot = root;
        BuildContractOrderWithFillsParams memory params = BuildContractOrderWithFillsParams({
            listing: bid,
            signerPk: BIDDER_PK,
            affiliate: address(0),
            itemIndexes: _twoUintArray(1, 0),
            fillTokenIds: _twoUintArray(1, 2),
            fillQuantities: _twoUintArray(3, 2),
            criteriaProofs: new bytes32[][](2),
            attributedFulfiller: address(0)
        });
        params.criteriaProofs[0] = proof1;
        params.criteriaProofs[1] = proof2;
        vm.expectRevert(QuantityExceeded.selector);
        _buildSeaportOrderWithFills(params);
        params.fillQuantities[1] = 1;
        params.criteriaProofs[1] = proof1;
        vm.expectRevert(InvalidCriteriaProof.selector);
        _buildSeaportOrderWithFills(params);
        params.criteriaProofs[1] = proof2;
        AdvancedOrder memory order = _buildSeaportOrderWithFills(params);
        _prank(seller);
        seaport.fulfillAdvancedOrder(order, new CriteriaResolver[](0), conduitKey, seller);

        assertEq(nft721.ownerOf(2), bidder);
        assertEq(nft721.ownerOf(1), seller);
        assertEq(nft1155.balanceOf(bidder, 1), 3);
        assertEq(weth.balanceOf(bidder), 93 ether);
        assertEq(weth.balanceOf(seller), 6.65 ether);
        assertEq(weth.balanceOf(PLATFORM), 0.35 ether);
        (,, uint256 filled721, uint256 remaining721) = subject.listingStatus(bidder, bid, 0);
        (,, uint256 filled1155, uint256 remaining1155) = subject.listingStatus(bidder, bid, 1);
        assertEq(filled721, 1);
        assertEq(remaining721, 1);
        assertEq(filled1155, 3);
        assertEq(remaining1155, 2);
    }

    function test_mixedSubmission_rejectsDuplicateCollectionAndTokenRegardlessOfAssetType() public {
        ScatterOfferer.ScatterSubmission memory submission = _multiCollectionSubmission(
            address(nft721), address(nft721), ScatterOfferer.AssetType.ERC721, 1, address(weth)
        );
        submission.listings[1].assetType = ScatterOfferer.AssetType.ERC1155;
        BuildContractOrderWithFillsParams memory params = BuildContractOrderWithFillsParams({
            listing: submission,
            signerPk: SELLER_PK,
            affiliate: address(0),
            itemIndexes: _twoUintArray(0, 1),
            fillTokenIds: _twoUintArray(1, 1),
            fillQuantities: _twoUintArray(1, 1),
            criteriaProofs: new bytes32[][](0),
            attributedFulfiller: address(0)
        });
        vm.expectRevert(DuplicateListingItem.selector);
        _buildSeaportOrderWithFills(params);
        submission.role = ScatterOfferer.Role.Bid;
        params.signerPk = BIDDER_PK;
        vm.expectRevert(DuplicateListingItem.selector);
        _buildSeaportOrderWithFills(params);
    }

    struct SaleData {
        uint8 role;
        address collection;
        uint256 itemIndex;
        uint256 tokenId;
        uint256 quantity;
        address currency;
        uint256 totalPrice;
        address affiliate;
        address rewardsRecipient;
        uint256 sellerAmount;
        uint256 platformAmount;
        uint256 rewardsAmount;
        uint256 affiliateAmount;
    }

    function _recordedSales() internal returns (SaleData[] memory sales) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(subject)) count++;
        }
        sales = new SaleData[](count);
        uint256 index;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(subject)) {
                sales[index++] = abi.decode(logs[i].data, (SaleData));
            }
        }
    }

    function _prepareThreeCollectionListing(address currency, address orderAffiliate)
        internal
        returns (MockERC721E2E second, MockERC721E2E third, AdvancedOrder memory order)
    {
        _prank(address(this));
        second = new MockERC721E2E();
        third = new MockERC721E2E();
        second.mint(seller, 1);
        third.mint(seller, 1);
        scatterCollectionRegistry.setRewardsOverride(address(nft721), rewardsRecipient);
        scatterCollectionRegistry.setRewardsOverride(address(second), other);
        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);
        second.setApprovalForAll(address(conduit), true);
        third.setApprovalForAll(address(conduit), true);

        ScatterOfferer.ScatterSubmission memory listing =
            _multiCollectionSubmission(address(nft721), address(second), ScatterOfferer.AssetType.ERC721, 1, currency);
        ScatterOfferer.ScatterListing[] memory items = new ScatterOfferer.ScatterListing[](3);
        items[0] = listing.listings[0];
        items[1] = listing.listings[1];
        items[2] = ScatterOfferer.ScatterListing({
            assetType: ScatterOfferer.AssetType.ERC721,
            collection: address(third),
            tokenId: 1,
            quantity: 1,
            currency: currency,
            priceWei: 3 ether
        });
        listing.listings = items;
        uint256[] memory indexes = new uint256[](3);
        indexes[0] = 2;
        indexes[1] = 0;
        indexes[2] = 1;
        uint256[] memory tokens = new uint256[](3);
        tokens[0] = tokens[1] = tokens[2] = 1;
        order = _buildSeaportOrderWithFills(
            BuildContractOrderWithFillsParams({
                listing: listing,
                signerPk: SELLER_PK,
                affiliate: orderAffiliate,
                itemIndexes: indexes,
                fillTokenIds: tokens,
                fillQuantities: tokens,
                criteriaProofs: new bytes32[][](0),
                attributedFulfiller: address(0)
            })
        );
    }

    function _multiCollectionSubmission(
        address first,
        address second,
        ScatterOfferer.AssetType assetType,
        uint256 quantity,
        address currency
    ) internal view returns (ScatterOfferer.ScatterSubmission memory submission) {
        submission.role = ScatterOfferer.Role.Listing;
        submission.listings = new ScatterOfferer.ScatterListing[](2);
        submission.listings[0] = ScatterOfferer.ScatterListing({
            assetType: assetType,
            collection: first,
            tokenId: 1,
            quantity: quantity,
            currency: currency,
            priceWei: 1 ether
        });
        submission.listings[1] = ScatterOfferer.ScatterListing({
            assetType: assetType,
            collection: second,
            tokenId: 1,
            quantity: quantity,
            currency: currency,
            priceWei: 2 ether
        });
        submission.maxFeeBps = 500;
        submission.startTime = block.timestamp;
        submission.endTime = block.timestamp + 1 hours;
    }

    // Private
    struct GenerateListingParams {
        ScatterOfferer.Role role;
        ScatterOfferer.AssetType assetType;
        address collection;
        uint256 tokenId;
        bytes32 criteriaRoot;
        uint256 quantity;
        address currency;
        uint256 priceWei;
        uint256 startTime;
        uint256 endTime;
        uint256 nonce;
        bytes32 salt;
    }

    struct GenerateTwoItemListingParams {
        ScatterOfferer.Role role;
        ScatterOfferer.AssetType assetType;
        address collection;
        uint256 tokenId0;
        uint256 quantity0;
        address currency0;
        uint256 priceWei0;
        uint256 tokenId1;
        uint256 quantity1;
        address currency1;
        uint256 priceWei1;
        bytes32 criteriaRoot;
        uint256 startTime;
        uint256 endTime;
        uint256 nonce;
        bytes32 salt;
    }

    function _generateListing(GenerateListingParams memory p)
        internal
        pure
        returns (ScatterOfferer.ScatterSubmission memory listing)
    {
        listing.role = p.role;
        listing.listings = new ScatterOfferer.ScatterListing[](1);
        listing.listings[0].assetType = p.assetType;
        listing.listings[0].collection = p.collection;
        listing.listings[0].tokenId = p.tokenId;
        listing.criteriaRoot = p.criteriaRoot;
        listing.listings[0].quantity = p.quantity;
        listing.listings[0].currency = p.currency;
        listing.listings[0].priceWei = p.priceWei;
        listing.maxFeeBps = 500;
        listing.startTime = p.startTime;
        listing.endTime = p.endTime;
        listing.nonce = p.nonce;
        listing.salt = p.salt;
    }

    function _generateTwoItemListing(GenerateTwoItemListingParams memory p)
        internal
        pure
        returns (ScatterOfferer.ScatterSubmission memory listing)
    {
        listing.role = p.role;
        listing.listings = new ScatterOfferer.ScatterListing[](2);
        listing.listings[0] = ScatterOfferer.ScatterListing({
            assetType: p.assetType,
            collection: p.collection,
            tokenId: p.tokenId0,
            quantity: p.quantity0,
            currency: p.currency0,
            priceWei: p.priceWei0
        });
        listing.listings[1] = ScatterOfferer.ScatterListing({
            assetType: p.assetType,
            collection: p.collection,
            tokenId: p.tokenId1,
            quantity: p.quantity1,
            currency: p.currency1,
            priceWei: p.priceWei1
        });
        listing.criteriaRoot = p.criteriaRoot;
        listing.maxFeeBps = 500;
        listing.startTime = p.startTime;
        listing.endTime = p.endTime;
        listing.nonce = p.nonce;
        listing.salt = p.salt;
    }

    function _generateCriteriaData(uint256 siblingTokenId, uint256 fillTokenId)
        internal
        pure
        returns (bytes32 criteriaRoot, bytes32[] memory criteriaProof)
    {
        bytes32 siblingLeaf = keccak256(abi.encode(siblingTokenId));
        bytes32 fillLeaf = keccak256(abi.encode(fillTokenId));

        // OpenZeppelin MerkleProof sorts sibling pairs before hashing.
        criteriaRoot = siblingLeaf < fillLeaf
            ? keccak256(abi.encodePacked(siblingLeaf, fillLeaf))
            : keccak256(abi.encodePacked(fillLeaf, siblingLeaf));
        criteriaProof = new bytes32[](1);
        criteriaProof[0] = siblingLeaf;
    }

    /// Signs `FeeAuthorization(fulfiller, affiliate, submissionHash, fillsHash, deadline)`
    /// with `FEE_AUTHORIZER_PK` over the `Scatter Marketplace` EIP-712 domain.
    function _feeAuthSig(
        address fulfiller,
        address authAffiliate,
        ScatterOfferer.ScatterSubmission memory listing,
        ScatterOfferer.ScatterFill[] memory fills
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
                subject.hashSubmission(listing),
                keccak256(abi.encode(fills)),
                block.timestamp + 1 hours
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(FEE_AUTHORIZER_PK, keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash)));
        return abi.encodePacked(r, s, v);
    }

    struct BuildContractOrderParams {
        ScatterOfferer.ScatterSubmission listing;
        uint256 signerPk;
        address affiliate;
        uint256 fillTokenId;
        uint256 fillQuantity;
        bytes32[] criteriaProof;
        address attributedFulfiller;
    }

    struct BuildContractOrderWithFillsParams {
        ScatterOfferer.ScatterSubmission listing;
        uint256 signerPk;
        address affiliate;
        uint256[] itemIndexes;
        uint256[] fillTokenIds;
        uint256[] fillQuantities;
        bytes32[][] criteriaProofs;
        address attributedFulfiller;
    }

    function _buildSeaportOrder(BuildContractOrderParams memory p) internal view returns (AdvancedOrder memory order) {
        uint256[] memory itemIndexes = _singleUintArray(0);
        uint256[] memory fillTokenIds = _singleUintArray(p.fillTokenId);
        uint256[] memory fillQuantities = _singleUintArray(p.fillQuantity);
        bytes32[][] memory criteriaProofs = new bytes32[][](p.criteriaProof.length == 0 ? 0 : 1);
        if (p.criteriaProof.length != 0) {
            criteriaProofs[0] = p.criteriaProof;
        }

        order = _buildSeaportOrderWithFills(
            BuildContractOrderWithFillsParams({
                listing: p.listing,
                signerPk: p.signerPk,
                affiliate: p.affiliate,
                itemIndexes: itemIndexes,
                fillTokenIds: fillTokenIds,
                fillQuantities: fillQuantities,
                criteriaProofs: criteriaProofs,
                attributedFulfiller: p.attributedFulfiller
            })
        );
    }

    function _buildSeaportOrderWithFills(BuildContractOrderWithFillsParams memory p)
        internal
        view
        returns (AdvancedOrder memory order)
    {
        // Sign independently of the contract's hashing implementation.
        bytes32 structHash = vm.eip712HashStruct(
            "ScatterSubmission(uint8 role,ScatterListing[] listings,bytes32 criteriaRoot,uint256 maxFeeBps,uint256 startTime,uint256 endTime,uint256 nonce,bytes32 salt)ScatterListing(uint8 assetType,address collection,uint256 tokenId,uint256 quantity,address currency,uint256 priceWei)",
            abi.encode(p.listing)
        );
        bytes32 domainHash = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Scatter Marketplace"),
                keccak256("1"),
                block.chainid,
                address(subject)
            )
        );
        bytes32 listingHash = keccak256(abi.encodePacked("\x19\x01", domainHash, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(p.signerPk, listingHash);
        bytes memory listingSignature = abi.encodePacked(r, s, v);

        // 2: encode the fill context Seaport passes into generateOrder
        ScatterOfferer.ScatterFill[] memory fills = new ScatterOfferer.ScatterFill[](p.itemIndexes.length);
        for (uint256 i = 0; i < p.itemIndexes.length; i++) {
            fills[i] = ScatterOfferer.ScatterFill({
                itemIndex: p.itemIndexes[i], tokenId: p.fillTokenIds[i], quantity: p.fillQuantities[i]
            });
        }

        // Seaport's requester is the seller for bids and the buyer for listings.
        uint256 feeAuthorizationDeadline;
        bytes memory feeAuthorizationSignature;
        if (p.affiliate != address(0)) {
            feeAuthorizationDeadline = block.timestamp + 1 hours;
            address fulfiller = p.listing.role == ScatterOfferer.Role.Bid ? seller : buyer;
            feeAuthorizationSignature = _feeAuthSig(fulfiller, p.affiliate, p.listing, fills);
        }
        bytes memory extraData = abi.encode(
            p.listing,
            listingSignature,
            p.affiliate,
            fills,
            p.criteriaProofs,
            feeAuthorizationDeadline,
            feeAuthorizationSignature
        );

        // 3: derive the exact Seaport arrays ScatterOfferer will return
        (SpentItem[] memory previewOffer, ReceivedItem[] memory previewConsideration) = subject.previewOrder(
            SEAPORT, // caller
            address(0), // fulfiller (unused)
            new SpentItem[](0), // minimumReceived
            new SpentItem[](0), // maximumSpent
            extraData // seaportFillInputContextCalldata
        );

        // 4a: convert the previewed offer items into Seaport OfferItem structs
        OfferItem[] memory offer = new OfferItem[](previewOffer.length);
        for (uint256 i = 0; i < previewOffer.length; i++) {
            offer[i] = OfferItem({
                itemType: previewOffer[i].itemType,
                token: previewOffer[i].token,
                identifierOrCriteria: previewOffer[i].identifier,
                startAmount: previewOffer[i].amount,
                endAmount: previewOffer[i].amount
            });
        }

        // 4b: convert the previewed consideration items into Seaport ConsiderationItem structs
        ConsiderationItem[] memory consideration = new ConsiderationItem[](previewConsideration.length);
        for (uint256 i = 0; i < previewConsideration.length; i++) {
            consideration[i] = ConsiderationItem({
                itemType: previewConsideration[i].itemType,
                token: previewConsideration[i].token,
                identifierOrCriteria: previewConsideration[i].identifier,
                startAmount: previewConsideration[i].amount,
                endAmount: previewConsideration[i].amount,
                recipient: previewConsideration[i].recipient
            });
        }

        // 4c: assemble the Seaport contract-order parameters around those arrays
        OrderParameters memory parameters = OrderParameters({
            offerer: address(subject),
            zone: address(0), // unused for contract orders
            offer: offer,
            consideration: consideration,
            orderType: OrderType.CONTRACT,
            startTime: p.listing.startTime,
            endTime: p.listing.endTime,
            zoneHash: bytes32(0), // unused for contract orders
            salt: 0, // unused for contract orders
            conduitKey: bytes32(0), // offerer approves Seaport directly
            totalOriginalConsiderationItems: consideration.length
        });

        // 5: wrap the parameters into the final AdvancedOrder payload
        order = AdvancedOrder({
            parameters: parameters,
            numerator: 1, // contract orders must be 1/1
            denominator: 1,
            signature: "", // ignored for contract orders
            extraData: extraData
        });
    }

    function _singleUintArray(uint256 a) internal pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = a;
    }

    function _twoUintArray(uint256 a, uint256 b) internal pure returns (uint256[] memory values) {
        values = new uint256[](2);
        values[0] = a;
        values[1] = b;
    }

    struct Balances {
        uint256 sellerNative;
        uint256 platformNative;
        uint256 rewardsNative;
        uint256 affiliateNative;
        uint256 buyerNative;
        uint256 sellerWeth;
        uint256 platformWeth;
        uint256 rewardsWeth;
        uint256 affiliateWeth;
        uint256 buyerWeth;
        uint256 bidderWeth;
    }

    function _snapshotBalances() internal view returns (Balances memory balances) {
        balances = Balances({
            sellerNative: seller.balance,
            platformNative: PLATFORM.balance,
            rewardsNative: rewardsRecipient.balance,
            affiliateNative: affiliate.balance,
            buyerNative: buyer.balance,
            sellerWeth: weth.balanceOf(seller),
            platformWeth: weth.balanceOf(PLATFORM),
            rewardsWeth: weth.balanceOf(rewardsRecipient),
            affiliateWeth: weth.balanceOf(affiliate),
            buyerWeth: weth.balanceOf(buyer),
            bidderWeth: weth.balanceOf(bidder)
        });
    }

    function _prank(address actor) internal {
        vm.stopPrank();
        vm.startPrank(actor);
    }
}

// supporting mock contracts
contract MockERC721E2E is ERC721 {
    constructor() ERC721("MockE2E", "ME2E") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}

contract MockERC1155E2E is ERC1155 {
    constructor() ERC1155("") {}

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }
}

contract MockERC20E2E is ERC20 {
    constructor() ERC20("MockE2E", "ME2E") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockRouterE2E {
    address private _activeRoutedFulfiller;

    function buy(SeaportInterface seaport, AdvancedOrder calldata order, address recipient) external payable {
        _activeRoutedFulfiller = recipient;
        seaport.fulfillAdvancedOrder{value: msg.value}(
            order,
            new CriteriaResolver[](0), // criteriaResolvers
            bytes32(0), // fulfillerConduitKey
            recipient // recipient
        );
        _activeRoutedFulfiller = address(0);
    }

    function activeRoutedFulfiller() external view returns (address) {
        return _activeRoutedFulfiller;
    }

    receive() external payable {}
}
