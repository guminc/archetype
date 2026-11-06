// SPDX-License-Identifier: MIT
// forge-lint: disable-start(mixed-case-function, mixed-case-variable, asm-keccak256)
pragma solidity 0.8.36;

import {ConduitTest} from "./helpers/ConduitTest.sol";
import {
    ScatterAggregatorRouter,
    InvalidFulfillmentCalldataSelector,
    InvalidFulfillmentRecipient,
    InvalidFeeAuthorization,
    InvalidSweepOrderIndex,
    InvalidTotalOriginalConsiderationItems,
    OrderHashMismatch
} from "../src/ScatterAggregatorRouter.sol";
import {ScatterOfferer} from "../src/ScatterOfferer.sol";
import {
    AdvancedOrder,
    CriteriaResolver,
    Order,
    OrderParameters,
    OfferItem,
    ConsiderationItem,
    FulfillmentComponent,
    ReceivedItem,
    SpentItem
} from "seaport-types/src/lib/ConsiderationStructs.sol";
import {OrderType, ItemType} from "seaport-types/src/lib/ConsiderationEnums.sol";
import {SeaportInterface} from "seaport-types/src/interfaces/SeaportInterface.sol";
import {OrderLib} from "seaport-sol/lib/OrderLib.sol";
import {OrderParametersLib} from "seaport-sol/lib/OrderParametersLib.sol";
import {OfferItemLib} from "seaport-sol/lib/OfferItemLib.sol";
import {ConsiderationItemLib} from "seaport-sol/lib/ConsiderationItemLib.sol";
import {FulfillAvailableHelper} from "seaport-sol/fulfillments/available/FulfillAvailableHelper.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ScatterCollectionRegistry} from "../src/ScatterCollectionRegistry.sol";

contract ScatterAggregatorRouterE2ETest is ConduitTest {
    uint256 internal constant FEE_AUTHORIZER_PK = 0xA11CE;

    using OrderLib for Order;
    using OrderParametersLib for OrderParameters;
    using OfferItemLib for OfferItem;
    using ConsiderationItemLib for ConsiderationItem;

    address internal SEAPORT;
    address internal PLATFORM;
    uint256 internal FEE_BPS;
    uint256 internal FEE_SPLIT_BPS;
    uint256 internal BPS_DENOMINATOR;

    ScatterAggregatorRouter internal subject;
    ScatterOfferer internal scatterOfferer;
    address internal feeAuthorizer = vm.addr(FEE_AUTHORIZER_PK);
    ScatterCollectionRegistry internal scatterCollectionRegistry;
    MockERC721E2E internal nft721;
    MockERC1155E2E internal nft1155;
    MockERC20E2E internal erc20;
    SeaportInterface internal seaport;
    FulfillAvailableHelper internal fulfillHelper;
    bytes32 internal domainSeparator;

    address internal owner;
    address internal rewardsRecipient;
    address internal affiliate;
    address internal buyer;
    address internal seller;
    uint256 internal constant SELLER_PK = uint256(keccak256("seller"));

    function setUp() public virtual {
        _setUpConduit();
        owner = makeAddr("owner");
        rewardsRecipient = makeAddr("rewardsRecipient");
        affiliate = makeAddr("affiliate");
        seller = vm.addr(SELLER_PK);
        buyer = makeAddr("buyer");
        vm.deal(buyer, 10 ether);

        scatterCollectionRegistry = new ScatterCollectionRegistry(address(this));
        scatterOfferer = new ScatterOfferer(owner, scatterCollectionRegistry, feeAuthorizer, conduitKey);
        subject = new ScatterAggregatorRouter(
            owner, scatterCollectionRegistry, feeAuthorizer, address(scatterOfferer), conduitKey
        );
        _openConduitChannel(address(scatterOfferer));
        _openConduitChannel(address(subject));
        _openConduitChannel(subject.SEAPORT());
        _prank(owner);
        scatterOfferer.setTrustedRouter(address(subject), true);
        nft721 = new MockERC721E2E();
        nft1155 = new MockERC1155E2E();
        erc20 = new MockERC20E2E();

        SEAPORT = subject.SEAPORT();
        PLATFORM = subject.PLATFORM();
        FEE_BPS = subject.feeBps();
        FEE_SPLIT_BPS = subject.feeSplitBps();
        BPS_DENOMINATOR = subject.BPS_DENOMINATOR();

        fulfillHelper = new FulfillAvailableHelper();
        _setUpSeaport(SEAPORT);
        seaport = SeaportInterface(SEAPORT);
        (, domainSeparator,) = seaport.information();

        erc20.mint(buyer, 100 ether);
        nft721.mint(seller, 1);
        nft721.mint(seller, 2);
        nft1155.mint(seller, 1, 100);

        _prank(seller);
        nft721.setApprovalForAll(SEAPORT, true);
        nft1155.setApprovalForAll(SEAPORT, true);
    }

    function test_e2e_buyer_buys_native_listing_and_platform_receives_full_fee() public {
        uint256 tokenId = 1;
        uint256 listingPrice = 1 ether;

        uint256 totalFee = (listingPrice * FEE_BPS) / BPS_DENOMINATOR;

        // create order
        Order memory order = _buildNativeOrder(seller, SELLER_PK, address(nft721), tokenId, listingPrice);
        bytes32 orderHash =
            seaport.getOrderHash(order.parameters.toOrderComponents(seaport.getCounter(order.parameters.offerer)));

        // generate buy calldata
        bytes memory seaportCalldata = _generateBuyCalldata(order, buyer);

        _prank(buyer);
        Balances memory balancesBefore = _snapshotBalances();
        subject.buyExternalListing{value: listingPrice + totalFee}(
            seaportCalldata,
            listingPrice,
            address(0), // rewardsRecipient
            orderHash,
            0,
            "",
            500
        );
        Balances memory balancesAfter = _snapshotBalances();

        // fee breakdown:
        //   listingPrice = 1 ether
        //   fee          = 1 ether * 500 / 10000 = 0.05 ether  → platform only
        //   msg.value    = 1.05 ether
        assertEq(nft721.ownerOf(tokenId), buyer);
        assertEq(balancesAfter.sellerNative - balancesBefore.sellerNative, 1 ether);
        assertEq(balancesAfter.platformNative - balancesBefore.platformNative, 0.05 ether);
        assertEq(address(subject).balance, 0);
    }

    function test_e2e_buyer_buys_native_listing_and_fee_is_split_with_rewards() public {
        _prank(address(this));
        scatterCollectionRegistry.setRewardsOverride(address(nft721), rewardsRecipient);

        uint256 tokenId = 1;
        uint256 listingPrice = 1 ether;

        uint256 totalFee = (listingPrice * FEE_BPS) / BPS_DENOMINATOR;

        // create order
        Order memory order = _buildNativeOrder(seller, SELLER_PK, address(nft721), tokenId, listingPrice);
        bytes32 orderHash =
            seaport.getOrderHash(order.parameters.toOrderComponents(seaport.getCounter(order.parameters.offerer)));

        // generate buy calldata
        bytes memory seaportCalldata = _generateBuyCalldata(order, buyer);

        _prank(buyer);
        Balances memory balancesBefore = _snapshotBalances();
        subject.buyExternalListing{value: listingPrice + totalFee}(
            seaportCalldata,
            listingPrice,
            address(0), // rewardsRecipient
            orderHash,
            0,
            "",
            500
        );
        Balances memory balancesAfter = _snapshotBalances();

        // fee breakdown:
        //   listingPrice  = 1 ether
        //   totalFee      = 1 ether * 500 / 10000    = 0.05 ether
        //   platformFee   = 0.05 ether * 5000 / 10000 = 0.025 ether
        //   rewardsFee    = 0.05 ether - 0.025 ether  = 0.025 ether
        //   msg.value     = 1.05 ether
        assertEq(nft721.ownerOf(tokenId), buyer);
        assertEq(balancesAfter.sellerNative - balancesBefore.sellerNative, 1 ether);
        assertEq(balancesAfter.platformNative - balancesBefore.platformNative, 0.025 ether);
        assertEq(balancesAfter.rewardsNative - balancesBefore.rewardsNative, 0.025 ether);
        assertEq(address(subject).balance, 0);
    }

    function _feeAuthDeadline() internal view returns (uint256) {
        return block.timestamp + 1 hours;
    }

    function _feeAuthSig(address authBuyer, address authAffiliate, bytes32 ordersHash)
        internal
        view
        returns (bytes memory)
    {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("ScatterAggregatorRouter"),
                keccak256("1"),
                block.chainid,
                address(subject)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("FeeAuthorization(address buyer,address affiliate,bytes32 ordersHash,uint256 deadline)"),
                authBuyer,
                authAffiliate,
                ordersHash,
                _feeAuthDeadline()
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(FEE_AUTHORIZER_PK, keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash)));
        return abi.encodePacked(r, s, v);
    }

    function test_e2e_buyer_buys_native_listing_and_fee_is_split_with_affiliate() public {
        uint256 tokenId = 1;
        uint256 listingPrice = 1 ether;

        uint256 totalFee = (listingPrice * FEE_BPS) / BPS_DENOMINATOR;

        // create order
        Order memory order = _buildNativeOrder(seller, SELLER_PK, address(nft721), tokenId, listingPrice);
        bytes32 orderHash =
            seaport.getOrderHash(order.parameters.toOrderComponents(seaport.getCounter(order.parameters.offerer)));

        // generate buy calldata
        bytes memory seaportCalldata = _generateBuyCalldata(order, buyer);

        _prank(buyer);
        Balances memory balancesBefore = _snapshotBalances();
        subject.buyExternalListing{value: listingPrice + totalFee}(
            seaportCalldata,
            listingPrice,
            affiliate, // rewardsRecipient
            orderHash,
            _feeAuthDeadline(),
            _feeAuthSig(buyer, affiliate, keccak256(abi.encode(orderHash))),
            500
        );
        Balances memory balancesAfter = _snapshotBalances();

        // fee breakdown:
        //   listingPrice  = 1 ether
        //   totalFee      = 1 ether * 500 / 10000    = 0.05 ether
        //   platformFee   = 0.05 ether * 5000 / 10000 = 0.025 ether
        //   affiliateFee  = 0.05 ether - 0.025 ether  = 0.025 ether
        //   msg.value     = 1.05 ether
        assertEq(nft721.ownerOf(tokenId), buyer);
        assertEq(balancesAfter.sellerNative - balancesBefore.sellerNative, 1 ether);
        assertEq(balancesAfter.platformNative - balancesBefore.platformNative, 0.025 ether);
        assertEq(balancesAfter.affiliateNative - balancesBefore.affiliateNative, 0.025 ether);
        assertEq(address(subject).balance, 0);
    }

    function test_e2e_buyer_buys_erc20_listing_and_platform_receives_full_fee() public {
        uint256 tokenId = 1;
        uint256 listingPrice = 1 ether;

        uint256 fee = (listingPrice * FEE_BPS) / BPS_DENOMINATOR;

        // create order
        Order memory order = _buildErc20Order(seller, SELLER_PK, address(nft721), tokenId, address(erc20), listingPrice);
        bytes32 orderHash =
            seaport.getOrderHash(order.parameters.toOrderComponents(seaport.getCounter(order.parameters.offerer)));

        // generate buy calldata
        bytes memory seaportCalldata = _generateBuyCalldata(order, buyer);

        _prank(buyer);
        erc20.approve(address(conduit), listingPrice + fee);

        Balances memory balancesBefore = _snapshotBalances();
        subject.buyExternalListingERC20(
            seaportCalldata,
            address(erc20),
            listingPrice,
            address(0), // rewardsRecipient
            orderHash,
            0,
            "",
            500
        );
        Balances memory balancesAfter = _snapshotBalances();

        // fee breakdown:
        //   listingPrice = 1 ether (ERC20)
        //   fee          = 1 ether * 500 / 10000 = 0.05 ether  → platform only
        //   totalPulled  = 1.05 ether from buyer
        assertEq(nft721.ownerOf(tokenId), buyer);
        assertEq(balancesAfter.sellerErc20 - balancesBefore.sellerErc20, 1 ether);
        assertEq(balancesAfter.platformErc20 - balancesBefore.platformErc20, 0.05 ether);
        assertEq(balancesBefore.buyerErc20 - balancesAfter.buyerErc20, 1.05 ether);
        assertEq(erc20.balanceOf(address(subject)), 0);
        assertEq(erc20.allowance(address(subject), SEAPORT), 0);
    }

    function test_e2e_buyer_buys_erc20_listing_and_fee_is_split_with_rewards() public {
        _prank(address(this));
        scatterCollectionRegistry.setRewardsOverride(address(nft721), rewardsRecipient);

        uint256 tokenId = 1;
        uint256 listingPrice = 1 ether;

        uint256 totalFee = (listingPrice * FEE_BPS) / BPS_DENOMINATOR;

        // create order
        Order memory order = _buildErc20Order(seller, SELLER_PK, address(nft721), tokenId, address(erc20), listingPrice);
        bytes32 orderHash =
            seaport.getOrderHash(order.parameters.toOrderComponents(seaport.getCounter(order.parameters.offerer)));

        // generate buy calldata
        bytes memory seaportCalldata = _generateBuyCalldata(order, buyer);

        _prank(buyer);
        erc20.approve(address(conduit), listingPrice + totalFee);

        Balances memory balancesBefore = _snapshotBalances();
        subject.buyExternalListingERC20(
            seaportCalldata,
            address(erc20),
            listingPrice,
            address(0), // rewardsRecipient
            orderHash,
            0,
            "",
            500
        );
        Balances memory balancesAfter = _snapshotBalances();

        // fee breakdown:
        //   listingPrice  = 1 ether (ERC20)
        //   totalFee      = 1 ether * 500 / 10000    = 0.05 ether
        //   platformFee   = 0.05 ether * 5000 / 10000 = 0.025 ether
        //   rewardsFee    = 0.05 ether - 0.025 ether  = 0.025 ether
        //   totalPulled   = 1.05 ether from buyer
        assertEq(nft721.ownerOf(tokenId), buyer);
        assertEq(balancesAfter.sellerErc20 - balancesBefore.sellerErc20, 1 ether);
        assertEq(balancesAfter.platformErc20 - balancesBefore.platformErc20, 0.025 ether);
        assertEq(balancesAfter.rewardsErc20 - balancesBefore.rewardsErc20, 0.025 ether);
        assertEq(balancesBefore.buyerErc20 - balancesAfter.buyerErc20, 1.05 ether);
        assertEq(erc20.balanceOf(address(subject)), 0);
        assertEq(erc20.allowance(address(subject), SEAPORT), 0);
    }

    function test_e2e_buyer_buys_erc20_listing_and_fee_is_split_with_affiliate() public {
        uint256 tokenId = 1;
        uint256 listingPrice = 1 ether;

        uint256 totalFee = (listingPrice * FEE_BPS) / BPS_DENOMINATOR;

        // create order
        Order memory order = _buildErc20Order(seller, SELLER_PK, address(nft721), tokenId, address(erc20), listingPrice);
        bytes32 orderHash =
            seaport.getOrderHash(order.parameters.toOrderComponents(seaport.getCounter(order.parameters.offerer)));

        // generate buy calldata
        bytes memory seaportCalldata = _generateBuyCalldata(order, buyer);

        _prank(buyer);
        erc20.approve(address(conduit), listingPrice + totalFee);

        Balances memory balancesBefore = _snapshotBalances();
        subject.buyExternalListingERC20(
            seaportCalldata,
            address(erc20),
            listingPrice,
            affiliate, // rewardsRecipient
            orderHash,
            _feeAuthDeadline(),
            _feeAuthSig(buyer, affiliate, keccak256(abi.encode(orderHash))),
            500
        );
        Balances memory balancesAfter = _snapshotBalances();

        // fee breakdown:
        //   listingPrice  = 1 ether (ERC20)
        //   totalFee      = 1 ether * 500 / 10000    = 0.05 ether
        //   platformFee   = 0.05 ether * 5000 / 10000 = 0.025 ether
        //   affiliateFee  = 0.05 ether - 0.025 ether  = 0.025 ether
        //   totalPulled   = 1.05 ether from buyer
        assertEq(nft721.ownerOf(tokenId), buyer);
        assertEq(balancesAfter.sellerErc20 - balancesBefore.sellerErc20, 1 ether);
        assertEq(balancesAfter.platformErc20 - balancesBefore.platformErc20, 0.025 ether);
        assertEq(balancesAfter.affiliateErc20 - balancesBefore.affiliateErc20, 0.025 ether);
        assertEq(balancesBefore.buyerErc20 - balancesAfter.buyerErc20, 1.05 ether);
        assertEq(erc20.balanceOf(address(subject)), 0);
        assertEq(erc20.allowance(address(subject), SEAPORT), 0);
    }

    function test_e2e_buyer_sweeps_two_native_listings_and_platform_receives_full_fee() public {
        uint256 tokenId0 = 1;
        uint256 tokenId1 = 2;
        uint256 price0 = 1 ether;
        uint256 price1 = 0.5 ether;

        uint256 totalNative = price0 + price1;
        uint256 fee0 = (price0 * FEE_BPS) / BPS_DENOMINATOR;
        uint256 fee1 = (price1 * FEE_BPS) / BPS_DENOMINATOR;
        uint256 totalFee = fee0 + fee1;

        // create orders
        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = _buildNativeOrder(seller, SELLER_PK, address(nft721), tokenId0, price0).toAdvancedOrder(1, 1, "");
        orders[1] = _buildNativeOrder(seller, SELLER_PK, address(nft721), tokenId1, price1).toAdvancedOrder(1, 1, "");

        // create fills
        uint256[] memory fills = _generateSweepFills();

        // generate sweep calldata
        bytes memory seaportCalldata = _generateSweepCalldata(orders, buyer);

        _prank(buyer);
        Balances memory balancesBefore = _snapshotBalances();
        subject.sweepMixed{value: totalNative + totalFee}(
            seaportCalldata,
            totalNative,
            fills,
            new address[](0), // erc20s
            new uint256[](0), // erc20Amounts
            address(0),
            0,
            "",
            500
        );
        Balances memory balancesAfter = _snapshotBalances();

        // fee breakdown:
        //   price0      = 1 ether,   fee0 = 1 ether * 500 / 10000   = 0.05 ether
        //   price1      = 0.5 ether, fee1 = 0.5 ether * 500 / 10000 = 0.025 ether
        //   totalNative = 1.5 ether forwarded to Seaport
        //   totalFee    = 0.075 ether → platform only
        //   msg.value   = 1.575 ether
        assertEq(nft721.ownerOf(tokenId0), buyer);
        assertEq(nft721.ownerOf(tokenId1), buyer);
        assertEq(balancesAfter.sellerNative - balancesBefore.sellerNative, 1.5 ether);
        assertEq(balancesAfter.platformNative - balancesBefore.platformNative, 0.075 ether);
        assertEq(address(subject).balance, 0);
    }

    function test_e2e_sweepRejectsExternalOrderOmittedFromFeeIndexes() public {
        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = _buildNativeOrder(seller, SELLER_PK, address(nft721), 1, 1 ether).toAdvancedOrder(1, 1, "");
        bytes memory seaportCalldata = _generateSweepCalldata(orders, buyer);
        uint256 buyerBalanceBefore = buyer.balance;
        uint256 sellerBalanceBefore = seller.balance;
        uint256 platformBalanceBefore = subject.PLATFORM().balance;

        _prank(buyer);
        vm.expectRevert(InvalidSweepOrderIndex.selector);
        subject.sweepMixed{value: 1 ether}(
            seaportCalldata, 1 ether, new uint256[](0), new address[](0), new uint256[](0), address(0), 0, "", 500
        );

        assertEq(nft721.ownerOf(1), seller);
        assertEq(buyer.balance, buyerBalanceBefore);
        assertEq(seller.balance, sellerBalanceBefore);
        assertEq(subject.PLATFORM().balance, platformBalanceBefore);
    }

    function test_e2e_sweepCombinesMultiCollectionScatterAndExternalNativeListings() public {
        /*
         * A buyer can buy two Scatter-listed NFTs from different collections and an external listing together.
         * 1. Seller signs one Scatter submission for two collections and approves their NFTs.
         * 2. Add an external listing. Charge the extra router fee only on that listing.
         * 3. Buyer pays 3.525 ETH to buy all three NFTs in one call.
         * 4. Assert the buyer owns all three NFTs, the seller receives 3.35 ETH, and the platform receives 0.175 ETH.
         *    Assert the buyer spent 3.525 ETH and neither contract kept any ETH.
         */
        // 1. Seller signs one Scatter submission for two collections and approves their NFTs.
        MockERC721E2E secondCollection = new MockERC721E2E();
        secondCollection.mint(seller, 1);
        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);
        secondCollection.setApprovalForAll(address(conduit), true);

        ScatterOfferer.ScatterListing[] memory listings = new ScatterOfferer.ScatterListing[](2);
        listings[0] = ScatterOfferer.ScatterListing({
            assetType: ScatterOfferer.AssetType.ERC721,
            collection: address(nft721),
            tokenId: 1,
            quantity: 1,
            currency: address(0),
            priceWei: 1 ether
        });
        listings[1] = ScatterOfferer.ScatterListing({
            assetType: ScatterOfferer.AssetType.ERC721,
            collection: address(secondCollection),
            tokenId: 1,
            quantity: 1,
            currency: address(0),
            priceWei: 2 ether
        });

        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = _buildScatterContractOrder(scatterOfferer, listings);
        // 2. Add an external listing. Charge the extra router fee only on that listing.
        orders[1] = _buildNativeOrder(seller, SELLER_PK, address(nft721), 2, 0.5 ether).toAdvancedOrder(1, 1, "");
        uint256[] memory feeChargedOrderIndexes = new uint256[](1);
        feeChargedOrderIndexes[0] = 1;

        // 3. Buyer pays 3.525 ETH to buy all three NFTs in one call.
        _prank(buyer);
        Balances memory balancesBefore = _snapshotBalances();
        subject.sweepMixed{value: 3.525 ether}(
            _generateSweepCalldata(orders, buyer),
            3.5 ether,
            feeChargedOrderIndexes,
            new address[](0),
            new uint256[](0),
            address(0),
            0,
            "",
            500
        );
        Balances memory balancesAfter = _snapshotBalances();

        // 4. Assert the buyer owns all three NFTs and each payment reached its recipient.
        assertEq(nft721.ownerOf(1), buyer);
        assertEq(nft721.ownerOf(2), buyer);
        assertEq(secondCollection.ownerOf(1), buyer);
        // Price breakdown (ETH):
        //   Scatter prices = 1 + 2 = 3; included platform fee (5%) = 0.05 + 0.10 = 0.15.
        //   Scatter seller proceeds = 3 - 0.15 = 2.85.
        //   External price = 0.50 to seller; extra router fee (5%) = 0.025 to platform.
        //   Seller total = 2.85 + 0.50 = 3.35; platform total = 0.15 + 0.025 = 0.175.
        //   Buyer spends = 3 + 0.50 + 0.025 = 3.525; no rewards or affiliate payments.
        assertEq(balancesAfter.sellerNative - balancesBefore.sellerNative, 3.35 ether);
        assertEq(balancesAfter.platformNative - balancesBefore.platformNative, 0.175 ether);
        assertEq(balancesBefore.buyerNative - balancesAfter.buyerNative, 3.525 ether);
        // Assert neither contract kept any ETH.
        assertEq(address(subject).balance, 0);
        assertEq(address(scatterOfferer).balance, 0);
    }

    function test_e2e_buyer_sweeps_two_native_listings_and_fee_is_split_with_rewards() public {
        _prank(address(this));
        scatterCollectionRegistry.setRewardsOverride(address(nft721), rewardsRecipient);

        uint256 tokenId0 = 1;
        uint256 tokenId1 = 2;
        uint256 price0 = 1 ether;
        uint256 price1 = 0.5 ether;

        uint256 totalNative = price0 + price1;
        uint256 fee0 = (price0 * FEE_BPS) / BPS_DENOMINATOR;
        uint256 fee1 = (price1 * FEE_BPS) / BPS_DENOMINATOR;
        uint256 totalFee = fee0 + fee1;

        // create orders
        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = _buildNativeOrder(seller, SELLER_PK, address(nft721), tokenId0, price0).toAdvancedOrder(1, 1, "");
        orders[1] = _buildNativeOrder(seller, SELLER_PK, address(nft721), tokenId1, price1).toAdvancedOrder(1, 1, "");

        // create fills
        uint256[] memory fills = _generateSweepFills();

        // generate sweep calldata
        bytes memory seaportCalldata = _generateSweepCalldata(orders, buyer);

        _prank(buyer);
        Balances memory balancesBefore = _snapshotBalances();
        subject.sweepMixed{value: totalNative + totalFee}(
            seaportCalldata,
            totalNative,
            fills,
            new address[](0), // erc20s
            new uint256[](0), // erc20Amounts
            address(0),
            0,
            "",
            500
        );
        Balances memory balancesAfter = _snapshotBalances();

        // fee breakdown:
        //   price0      = 1 ether,   fee0 = 0.05 ether
        //   price1      = 0.5 ether, fee1 = 0.025 ether
        //   totalFee    = 0.075 ether
        //   platformFee = 0.075 ether * 5000 / 10000 = 0.0375 ether
        //   rewardsFee  = 0.075 ether - 0.0375 ether = 0.0375 ether
        //   msg.value   = 1.575 ether
        assertEq(nft721.ownerOf(tokenId0), buyer);
        assertEq(nft721.ownerOf(tokenId1), buyer);
        assertEq(balancesAfter.sellerNative - balancesBefore.sellerNative, 1.5 ether);
        assertEq(balancesAfter.platformNative - balancesBefore.platformNative, 0.0375 ether);
        assertEq(balancesAfter.rewardsNative - balancesBefore.rewardsNative, 0.0375 ether);
        assertEq(address(subject).balance, 0);
    }

    function test_e2e_buyer_sweeps_two_native_listings_and_fee_is_split_with_affiliate() public {
        uint256 tokenId0 = 1;
        uint256 tokenId1 = 2;
        uint256 price0 = 1 ether;
        uint256 price1 = 0.5 ether;

        uint256 totalNative = price0 + price1;
        uint256 fee0 = (price0 * FEE_BPS) / BPS_DENOMINATOR;
        uint256 fee1 = (price1 * FEE_BPS) / BPS_DENOMINATOR;
        uint256 totalFee = fee0 + fee1;

        // create orders
        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = _buildNativeOrder(seller, SELLER_PK, address(nft721), tokenId0, price0).toAdvancedOrder(1, 1, "");
        orders[1] = _buildNativeOrder(seller, SELLER_PK, address(nft721), tokenId1, price1).toAdvancedOrder(1, 1, "");

        // create fills
        uint256[] memory fills = _generateSweepFills();

        // generate sweep calldata
        bytes memory seaportCalldata = _generateSweepCalldata(orders, buyer);

        _prank(buyer);
        Balances memory balancesBefore = _snapshotBalances();
        bytes32[] memory sweptHashes = new bytes32[](orders.length);
        for (uint256 i = 0; i < orders.length; i++) {
            sweptHashes[i] = seaport.getOrderHash(
                orders[i].parameters.toOrderComponents(seaport.getCounter(orders[i].parameters.offerer))
            );
        }
        subject.sweepMixed{value: totalNative + totalFee}(
            seaportCalldata,
            totalNative,
            fills,
            new address[](0), // erc20s
            new uint256[](0), // erc20Amounts
            affiliate,
            _feeAuthDeadline(),
            _feeAuthSig(buyer, affiliate, keccak256(abi.encode(sweptHashes))),
            500
        );
        Balances memory balancesAfter = _snapshotBalances();

        // fee breakdown:
        //   price0       = 1 ether,   fee0 = 0.05 ether
        //   price1       = 0.5 ether, fee1 = 0.025 ether
        //   totalFee     = 0.075 ether
        //   platformFee  = 0.075 ether * 5000 / 10000 = 0.0375 ether
        //   affiliateFee = 0.075 ether - 0.0375 ether = 0.0375 ether
        //   msg.value    = 1.575 ether
        assertEq(nft721.ownerOf(tokenId0), buyer);
        assertEq(nft721.ownerOf(tokenId1), buyer);
        assertEq(balancesAfter.sellerNative - balancesBefore.sellerNative, 1.5 ether);
        assertEq(balancesAfter.platformNative - balancesBefore.platformNative, 0.0375 ether);
        assertEq(balancesAfter.affiliateNative - balancesBefore.affiliateNative, 0.0375 ether);
        assertEq(address(subject).balance, 0);
    }

    function test_e2e_buyer_sweeps_two_erc20_listings_to_self() public {
        uint256 price0 = 1 ether;
        uint256 price1 = 0.5 ether;
        uint256 totalPrice = price0 + price1;
        uint256 totalFee = (totalPrice * FEE_BPS) / BPS_DENOMINATOR;

        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] =
            _buildErc20Order(seller, SELLER_PK, address(nft721), 1, address(erc20), price0).toAdvancedOrder(1, 1, "");
        orders[1] =
            _buildErc20Order(seller, SELLER_PK, address(nft721), 2, address(erc20), price1).toAdvancedOrder(1, 1, "");

        _prank(buyer);
        erc20.approve(address(conduit), totalPrice + totalFee);
        Balances memory balancesBefore = _snapshotBalances();
        subject.sweepERC20(
            _generateSweepCalldata(orders, buyer),
            address(erc20),
            totalPrice,
            _generateSweepFills(),
            address(0),
            0,
            "",
            500
        );
        Balances memory balancesAfter = _snapshotBalances();

        assertEq(nft721.ownerOf(1), buyer);
        assertEq(nft721.ownerOf(2), buyer);
        assertEq(balancesAfter.sellerErc20 - balancesBefore.sellerErc20, totalPrice);
        assertEq(balancesAfter.platformErc20 - balancesBefore.platformErc20, totalFee);
        assertEq(erc20.balanceOf(address(subject)), 0);
        assertEq(erc20.allowance(address(subject), SEAPORT), 0);
    }

    function test_e2e_nativeSweepDeliversToRecipientAndRefundsAuthorizedPayer() public {
        CallbackDonationBuyer payer = new CallbackDonationBuyer();
        payer.configure(payable(address(subject)), IERC20(address(0)), 1 ether, 0);
        vm.deal(address(payer), 1 ether);
        address recipient = address(payer);
        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = _buildNativeOrder(seller, SELLER_PK, address(nft721), 1, 1 ether).toAdvancedOrder(1, 1, "");
        orders[1] = _buildErc1155Order(seller, SELLER_PK, address(nft1155), 1, 100, address(0), 1 ether)
            .toAdvancedOrder(1, 2, "");
        bytes memory data = _generateSweepCalldata(orders, recipient);
        bytes32[] memory hashes = new bytes32[](2);
        for (uint256 i = 0; i < orders.length; i++) {
            hashes[i] = seaport.getOrderHash(orders[i].parameters.toOrderComponents(seaport.getCounter(seller)));
        }
        bytes32 ordersHash = keccak256(abi.encode(hashes));
        Balances memory beforeBalances = _snapshotBalances();
        _prank(buyer);
        vm.expectRevert(InvalidFeeAuthorization.selector);
        subject.sweepMixed{value: 2.1 ether}(
            data,
            2 ether,
            _generateSweepFills(),
            new address[](0),
            new uint256[](0),
            affiliate,
            _feeAuthDeadline(),
            _feeAuthSig(recipient, affiliate, ordersHash),
            500
        );

        vm.expectEmit(true, true, true, true, address(subject));
        // The recipient's callback donation lands during the fills, so the
        // event's informational native spend is understated by the donated
        // amount; the fees come from order fill deltas and are unaffected.
        emit ScatterAggregatorRouter.SweepFilled(buyer, 0.5 ether, 0.075 ether, 0.0375 ether, 0, 0.0375 ether);
        subject.sweepMixed{value: 2.1 ether}(
            data,
            2 ether,
            _generateSweepFills(),
            new address[](0),
            new uint256[](0),
            affiliate,
            _feeAuthDeadline(),
            _feeAuthSig(buyer, affiliate, ordersHash),
            500
        );

        Balances memory afterBalances = _snapshotBalances();
        assertEq(nft721.ownerOf(1), recipient);
        assertEq(nft1155.balanceOf(recipient, 1), 50);
        assertEq(nft1155.balanceOf(seller, 1), 50);
        assertEq(beforeBalances.buyerNative - afterBalances.buyerNative, 0.575 ether);
        assertEq(afterBalances.sellerNative - beforeBalances.sellerNative, 1.5 ether);
        assertEq(afterBalances.platformNative - beforeBalances.platformNative, 0.0375 ether);
        assertEq(afterBalances.affiliateNative - beforeBalances.affiliateNative, 0.0375 ether);
        assertEq(recipient.balance, 0);
        assertEq(address(subject).balance, 0);
    }

    function test_e2e_erc20SweepDeliversToRecipientAndRefundsPayer() public {
        CallbackDonationBuyer payer = new CallbackDonationBuyer();
        payer.configure(payable(address(subject)), IERC20(address(erc20)), 0, 1 ether);
        erc20.mint(address(payer), 1 ether);
        address recipient = address(payer);
        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] =
            _buildErc20Order(seller, SELLER_PK, address(nft721), 1, address(erc20), 1 ether).toAdvancedOrder(1, 1, "");
        orders[1] = _buildErc1155Order(seller, SELLER_PK, address(nft1155), 1, 100, address(erc20), 1 ether)
            .toAdvancedOrder(1, 2, "");
        Balances memory beforeBalances = _snapshotBalances();
        _prank(buyer);
        erc20.approve(address(conduit), 2.1 ether);
        vm.expectEmit(true, true, true, true, address(subject));
        // The recipient's callback donation lands during the fills, so the
        // event's informational ERC-20 spend is understated by the donated
        // amount; the fees come from order fill deltas and are unaffected.
        emit ScatterAggregatorRouter.SweepERC20Filled(buyer, address(erc20), 0.5 ether, 0.075 ether, 0.075 ether, 0, 0);
        subject.sweepERC20(
            _generateSweepCalldata(orders, recipient),
            address(erc20),
            2 ether,
            _generateSweepFills(),
            address(0),
            0,
            "",
            500
        );

        Balances memory afterBalances = _snapshotBalances();
        assertEq(nft721.ownerOf(1), recipient);
        assertEq(nft1155.balanceOf(recipient, 1), 50);
        assertEq(nft1155.balanceOf(seller, 1), 50);
        assertEq(beforeBalances.buyerErc20 - afterBalances.buyerErc20, 0.575 ether);
        assertEq(afterBalances.sellerErc20 - beforeBalances.sellerErc20, 1.5 ether);
        assertEq(afterBalances.platformErc20 - beforeBalances.platformErc20, 0.075 ether);
        assertEq(erc20.balanceOf(recipient), 0);
        assertEq(erc20.balanceOf(address(subject)), 0);
        assertEq(erc20.allowance(address(subject), SEAPORT), 0);
    }

    function test_e2e_sweepChargesFeeOnActualRemainderOfPartiallyFilledOrder() public {
        uint256 listingPrice = 1 ether;
        Order memory order = _buildErc1155Order(seller, SELLER_PK, address(nft1155), 1, 100, address(0), listingPrice);
        bytes32 orderHash =
            seaport.getOrderHash(order.parameters.toOrderComponents(seaport.getCounter(order.parameters.offerer)));

        _prank(buyer);
        bool firstFillCompleted = seaport.fulfillAdvancedOrder{value: 0.99 ether}(
            order.toAdvancedOrder(99, 100, ""), new CriteriaResolver[](0), bytes32(0), buyer
        );
        assertTrue(firstFillCompleted);

        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = order.toAdvancedOrder(1, 1, "");
        uint256[] memory feeChargedOrderIndexes = new uint256[](1);
        feeChargedOrderIndexes[0] = 0;
        Balances memory balancesBefore = _snapshotBalances();

        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.ExternalListingFilled(
            buyer, address(0), orderHash, 0.01 ether, 0.0005 ether, address(0), address(0), 0.0005 ether, 0, 0
        );

        subject.sweepMixed{value: 1.05 ether}(
            _generateSweepCalldata(orders, buyer),
            1 ether,
            feeChargedOrderIndexes,
            new address[](0),
            new uint256[](0),
            address(0),
            0,
            "",
            500
        );
        Balances memory balancesAfter = _snapshotBalances();

        assertEq(nft1155.balanceOf(buyer, 1), 100);
        assertEq(balancesAfter.sellerNative - balancesBefore.sellerNative, 0.01 ether);
        assertEq(balancesAfter.platformNative - balancesBefore.platformNative, 0.0005 ether);
        assertEq(balancesBefore.buyerNative - balancesAfter.buyerNative, 0.0105 ether);
        assertEq(address(subject).balance, 0);
    }

    // Seaport refunds its caller everything it holds, so native sitting in
    // Seaport flows into the sweep's caller instead of underflowing the
    // balance delta.
    function test_e2e_sweepMixedSucceedsWhenSeaportHoldsNative() public {
        Order memory order = _buildErc1155Order(seller, SELLER_PK, address(nft1155), 1, 100, address(0), 1 ether);
        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = order.toAdvancedOrder(1, 2, "");
        uint256[] memory feeChargedOrderIndexes = new uint256[](1);
        feeChargedOrderIndexes[0] = 0;
        Balances memory balancesBefore = _snapshotBalances();

        vm.deal(SEAPORT, 1 ether);

        _prank(buyer);
        subject.sweepMixed{value: 0.6 ether}(
            _generateSweepCalldata(orders, buyer),
            0.5 ether,
            feeChargedOrderIndexes,
            new address[](0),
            new uint256[](0),
            address(0),
            0,
            "",
            500
        );
        Balances memory balancesAfter = _snapshotBalances();

        // The sweep fills half (0.5 ether, 0.025 ether fee); the native
        // Seaport held beyond the spend is refunded to the buyer with the
        // leftover.
        assertEq(nft1155.balanceOf(buyer, 1), 50);
        assertEq(balancesAfter.sellerNative - balancesBefore.sellerNative, 0.5 ether);
        assertEq(balancesAfter.platformNative - balancesBefore.platformNative, 0.025 ether);
        assertEq(balancesAfter.buyerNative - balancesBefore.buyerNative, 0.475 ether);
        assertEq(address(subject).balance, 0);
    }

    // A fill may attach payments the seller never signed; Seaport pays them,
    // so orders carrying more consideration than was signed must be rejected
    // or those payments escape the fee.
    function test_e2e_buyRejectsConsiderationBeyondSignedItems() public {
        uint256 tokenId = 1;
        uint256 listingPrice = 1 ether;
        Order memory order = _buildNativeOrder(seller, SELLER_PK, address(nft721), tokenId, listingPrice);
        bytes32 orderHash =
            seaport.getOrderHash(order.parameters.toOrderComponents(seaport.getCounter(order.parameters.offerer)));

        ConsiderationItem[] memory withTip = new ConsiderationItem[](2);
        withTip[0] = order.parameters.consideration[0];
        withTip[1] = ConsiderationItem({
            itemType: ItemType.NATIVE,
            token: address(0),
            identifierOrCriteria: 0,
            startAmount: 0.9 ether,
            endAmount: 0.9 ether,
            recipient: payable(seller)
        });
        order.parameters.consideration = withTip;

        vm.expectRevert(InvalidTotalOriginalConsiderationItems.selector);
        _prank(buyer);
        subject.buyExternalListing{value: 2 ether}(
            _generateBuyCalldata(order, buyer), 1.9 ether, address(0), orderHash, 0, "", 500
        );

        assertEq(nft721.ownerOf(tokenId), seller);
    }

    function test_e2e_sweepErc20RejectsConsiderationBeyondSignedItems() public {
        Order memory order = _buildErc1155Order(seller, SELLER_PK, address(nft1155), 1, 100, address(erc20), 100_000);
        ConsiderationItem[] memory withTip = new ConsiderationItem[](2);
        withTip[0] = order.parameters.consideration[0];
        withTip[1] = ConsiderationItem({
            itemType: ItemType.ERC20,
            token: address(erc20),
            identifierOrCriteria: 0,
            startAmount: 90_000,
            endAmount: 90_000,
            recipient: payable(seller)
        });
        order.parameters.consideration = withTip;

        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = order.toAdvancedOrder(1, 1, "");
        uint256[] memory feeChargedOrderIndexes = new uint256[](1);
        feeChargedOrderIndexes[0] = 0;

        _prank(buyer);
        erc20.approve(address(conduit), 195_000);
        bytes memory sweepCalldata = _generateSweepCalldata(orders, buyer);

        vm.expectRevert(InvalidTotalOriginalConsiderationItems.selector);
        subject.sweepERC20(sweepCalldata, address(erc20), 190_000, feeChargedOrderIndexes, address(0), 0, "", 500);

        assertEq(erc20.balanceOf(address(subject)), 0);
    }

    function test_e2e_buyRejectsRouterDelivery() public {
        uint256 tokenId = 1;
        uint256 listingPrice = 1 ether;
        Order memory order = _buildNativeOrder(seller, SELLER_PK, address(nft721), tokenId, listingPrice);
        bytes32 orderHash =
            seaport.getOrderHash(order.parameters.toOrderComponents(seaport.getCounter(order.parameters.offerer)));

        address[2] memory recipients = [address(0), address(subject)];
        uint256 balanceBefore = buyer.balance;
        for (uint256 i; i < recipients.length; ++i) {
            bytes memory calldata_ = _generateBuyCalldata(order, recipients[i]);
            _prank(buyer);
            vm.expectRevert(InvalidFulfillmentRecipient.selector);
            subject.buyExternalListing{value: 1.05 ether}(calldata_, listingPrice, address(0), orderHash, 0, "", 500);
        }

        assertEq(nft721.ownerOf(tokenId), seller);
        assertEq(buyer.balance, balanceBefore);
    }

    function test_e2e_buyERC20RejectsRouterDelivery() public {
        uint256 tokenId = 1;
        uint256 listingPrice = 100_000;
        Order memory order = _buildErc20Order(seller, SELLER_PK, address(nft721), tokenId, address(erc20), listingPrice);
        bytes32 orderHash =
            seaport.getOrderHash(order.parameters.toOrderComponents(seaport.getCounter(order.parameters.offerer)));
        _prank(buyer);
        erc20.approve(address(conduit), 105_000);
        uint256 balanceBefore = erc20.balanceOf(buyer);

        address[2] memory recipients = [address(0), address(subject)];
        for (uint256 i; i < recipients.length; ++i) {
            bytes memory calldata_ = _generateBuyCalldata(order, recipients[i]);
            _prank(buyer);
            vm.expectRevert(InvalidFulfillmentRecipient.selector);
            subject.buyExternalListingERC20(calldata_, address(erc20), listingPrice, address(0), orderHash, 0, "", 500);
        }

        assertEq(nft721.ownerOf(tokenId), seller);
        assertEq(erc20.balanceOf(buyer), balanceBefore);
    }

    function test_e2e_buyChargesFeeOnActualRemainderOfPartiallyFilledOrder() public {
        uint256 listingPrice = 1 ether;
        Order memory order = _buildErc1155Order(seller, SELLER_PK, address(nft1155), 1, 100, address(0), listingPrice);
        bytes32 orderHash =
            seaport.getOrderHash(order.parameters.toOrderComponents(seaport.getCounter(order.parameters.offerer)));

        _prank(buyer);
        bool firstFillCompleted = seaport.fulfillAdvancedOrder{value: 0.99 ether}(
            order.toAdvancedOrder(99, 100, ""), new CriteriaResolver[](0), bytes32(0), buyer
        );
        assertTrue(firstFillCompleted);

        Balances memory balancesBefore = _snapshotBalances();
        subject.buyExternalListing{value: 1.05 ether}(
            _generateBuyCalldata(order, buyer), listingPrice, address(0), orderHash, 0, "", 500
        );
        Balances memory balancesAfter = _snapshotBalances();

        assertEq(nft1155.balanceOf(buyer, 1), 100);
        assertEq(balancesAfter.sellerNative - balancesBefore.sellerNative, 0.01 ether);
        assertEq(balancesAfter.platformNative - balancesBefore.platformNative, 0.0005 ether);
        assertEq(balancesBefore.buyerNative - balancesAfter.buyerNative, 0.0105 ether);
    }

    function test_e2e_nativeCallbackDonationDoesNotReduceFee() public {
        uint256 listingPrice = 1 ether;
        Order memory order = _buildErc1155Order(seller, SELLER_PK, address(nft1155), 1, 1, address(0), listingPrice);
        bytes32 orderHash =
            seaport.getOrderHash(order.parameters.toOrderComponents(seaport.getCounter(order.parameters.offerer)));
        CallbackDonationBuyer attacker = new CallbackDonationBuyer();
        attacker.configure(payable(address(subject)), IERC20(address(0)), listingPrice, 0);
        vm.deal(address(attacker), 2.05 ether);
        uint256 sellerBalanceBefore = seller.balance;
        uint256 platformBalanceBefore = PLATFORM.balance;

        _prank(address(attacker));
        subject.buyExternalListing{value: 1.05 ether}(
            _generateBuyCalldata(order, address(attacker)), listingPrice, address(0), orderHash, 0, "", 500
        );

        assertEq(nft1155.balanceOf(address(attacker), 1), 1);
        assertEq(seller.balance - sellerBalanceBefore, listingPrice);
        assertEq(PLATFORM.balance - platformBalanceBefore, 0.05 ether);
        assertEq(address(attacker).balance, 1 ether);
        assertEq(address(subject).balance, 0);
    }

    function test_e2e_erc20CallbackDonationDoesNotReduceFee() public {
        uint256 listingPrice = 1 ether;
        Order memory order = _buildErc1155Order(seller, SELLER_PK, address(nft1155), 1, 1, address(erc20), listingPrice);
        bytes32 orderHash =
            seaport.getOrderHash(order.parameters.toOrderComponents(seaport.getCounter(order.parameters.offerer)));
        CallbackDonationBuyer attacker = new CallbackDonationBuyer();
        attacker.configure(payable(address(subject)), IERC20(address(erc20)), 0, listingPrice);
        erc20.mint(address(attacker), 2.05 ether);
        uint256 sellerBalanceBefore = erc20.balanceOf(seller);
        uint256 platformBalanceBefore = erc20.balanceOf(PLATFORM);

        _prank(address(attacker));
        erc20.approve(address(conduit), 1.05 ether);
        subject.buyExternalListingERC20(
            _generateBuyCalldata(order, address(attacker)),
            address(erc20),
            listingPrice,
            address(0),
            orderHash,
            0,
            "",
            500
        );

        assertEq(nft1155.balanceOf(address(attacker), 1), 1);
        assertEq(erc20.balanceOf(seller) - sellerBalanceBefore, listingPrice);
        assertEq(erc20.balanceOf(PLATFORM) - platformBalanceBefore, 0.05 ether);
        assertEq(erc20.balanceOf(address(attacker)), 1 ether);
        assertEq(erc20.balanceOf(address(subject)), 0);
    }

    function test_e2e_validateCalldataRevertsWithoutFillingOrder() public {
        uint256 tokenId = 1;
        uint256 listingPrice = 1 ether;
        uint256 fee = (listingPrice * FEE_BPS) / BPS_DENOMINATOR;
        Order memory order = _buildErc20Order(seller, SELLER_PK, address(nft721), tokenId, address(erc20), listingPrice);
        bytes32 orderHash =
            seaport.getOrderHash(order.parameters.toOrderComponents(seaport.getCounter(order.parameters.offerer)));
        Order[] memory orders = new Order[](1);
        orders[0] = order;
        bytes memory validateCalldata = abi.encodeCall(seaport.validate, (orders));

        _prank(buyer);
        erc20.approve(address(conduit), listingPrice + fee);
        vm.expectRevert(InvalidFulfillmentCalldataSelector.selector);
        subject.buyExternalListingERC20(
            validateCalldata, address(erc20), listingPrice, address(0), orderHash, 0, "", 500
        );

        assertEq(nft721.ownerOf(tokenId), seller);
    }

    function test_e2e_declaredOrderHashMismatchRevertsActualFill() public {
        uint256 tokenId = 1;
        uint256 listingPrice = 1 ether;
        uint256 fee = (listingPrice * FEE_BPS) / BPS_DENOMINATOR;
        Order memory order = _buildNativeOrder(seller, SELLER_PK, address(nft721), tokenId, listingPrice);
        bytes32 declaredOrderHash = keccak256("different-order");
        bytes memory seaportCalldata = _generateBuyCalldata(order, buyer);

        _prank(buyer);
        vm.expectRevert(OrderHashMismatch.selector);
        subject.buyExternalListing{value: listingPrice + fee}(
            seaportCalldata, listingPrice, address(0), declaredOrderHash, 0, "", 500
        );

        assertEq(nft721.ownerOf(tokenId), seller);
    }

    function test_e2e_sweepEmitsHashesDerivedFromOrderIndexes() public {
        uint256 price0 = 1 ether;
        uint256 price1 = 0.5 ether;
        uint256 totalNative = price0 + price1;
        uint256 totalFee = (totalNative * FEE_BPS) / BPS_DENOMINATOR;
        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = _buildNativeOrder(seller, SELLER_PK, address(nft721), 1, price0).toAdvancedOrder(1, 1, "");
        orders[1] = _buildNativeOrder(seller, SELLER_PK, address(nft721), 2, price1).toAdvancedOrder(1, 1, "");
        uint256[] memory fills = _generateSweepFills();
        bytes memory seaportCalldata = _generateSweepCalldata(orders, buyer);
        bytes32 orderHash0 = seaport.getOrderHash(
            orders[0].parameters.toOrderComponents(seaport.getCounter(orders[0].parameters.offerer))
        );
        bytes32 orderHash1 = seaport.getOrderHash(
            orders[1].parameters.toOrderComponents(seaport.getCounter(orders[1].parameters.offerer))
        );

        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.ExternalListingFilled(
            buyer, address(0), orderHash0, price0, 0.05 ether, address(0), address(0), 0.05 ether, 0, 0
        );
        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.ExternalListingFilled(
            buyer, address(0), orderHash1, price1, 0.025 ether, address(0), address(0), 0.025 ether, 0, 0
        );

        _prank(buyer);
        subject.sweepMixed{value: totalNative + totalFee}(
            seaportCalldata, totalNative, fills, new address[](0), new uint256[](0), address(0), 0, "", 500
        );

        assertEq(nft721.ownerOf(1), buyer);
        assertEq(nft721.ownerOf(2), buyer);
    }

    // Private
    /// Both orders are fee-charged; their bases come from their own consideration.
    function _generateSweepFills() internal pure returns (uint256[] memory orderIndexes) {
        orderIndexes = new uint256[](2);
        orderIndexes[0] = 0;
        orderIndexes[1] = 1;
    }

    function _generateBuyCalldata(Order memory order, address recipient) internal view returns (bytes memory) {
        return abi.encodeCall(
            seaport.fulfillAdvancedOrder,
            (
                order.toAdvancedOrder(1, 1, ""), // advancedOrder
                new CriteriaResolver[](0), // criteriaResolvers
                bytes32(0), // fulfillerConduitKey
                recipient // recipient
            )
        );
    }

    function _generateSweepCalldata(AdvancedOrder[] memory orders, address recipient)
        internal
        view
        returns (bytes memory)
    {
        (FulfillmentComponent[][] memory offerFulfillments, FulfillmentComponent[][] memory considerationFulfillments) =
            fulfillHelper.getNaiveFulfillmentComponents(orders);

        return abi.encodeCall(
            seaport.fulfillAvailableAdvancedOrders,
            (
                orders,
                new CriteriaResolver[](0), // criteriaResolvers
                offerFulfillments,
                considerationFulfillments,
                bytes32(0), // fulfillerConduitKey — no conduit
                recipient,
                orders.length // maximumFulfilled
            )
        );
    }

    struct Balances {
        uint256 sellerNative;
        uint256 platformNative;
        uint256 rewardsNative;
        uint256 affiliateNative;
        uint256 buyerNative;
        uint256 sellerErc20;
        uint256 platformErc20;
        uint256 rewardsErc20;
        uint256 affiliateErc20;
        uint256 buyerErc20;
    }

    function _snapshotBalances() internal view returns (Balances memory balances) {
        balances = Balances({
            sellerNative: seller.balance,
            platformNative: PLATFORM.balance,
            rewardsNative: rewardsRecipient.balance,
            affiliateNative: affiliate.balance,
            buyerNative: buyer.balance,
            sellerErc20: erc20.balanceOf(seller),
            platformErc20: erc20.balanceOf(PLATFORM),
            rewardsErc20: erc20.balanceOf(rewardsRecipient),
            affiliateErc20: erc20.balanceOf(affiliate),
            buyerErc20: erc20.balanceOf(buyer)
        });
    }

    // forgefmt: disable-next-item
    function _buildNativeOrder(address _seller, uint256 _sellerPk, address _nft, uint256 _tokenId, uint256 _price)
        internal
        view
        returns (Order memory order)
    {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItemLib
            .empty()
            .withItemType(ItemType.ERC721)
            .withToken(_nft)
            .withIdentifierOrCriteria(_tokenId)
            .withAmount(1);

        ConsiderationItem[] memory consideration = new ConsiderationItem[](1);
        consideration[0] = ConsiderationItemLib
            .empty()
            .withItemType(ItemType.NATIVE)
            .withAmount(_price)
            .withRecipient(payable(_seller));

        OrderParameters memory params = OrderParametersLib.empty()
            .withOfferer(_seller)
            .withOffer(offer)
            .withTotalConsideration(consideration)
            .withOrderType(OrderType.FULL_OPEN)
            .withStartTime(block.timestamp)
            .withEndTime(block.timestamp + 1 hours)
            .withSalt(uint256(keccak256(abi.encode(_tokenId, _price))));

        uint256 counter = seaport.getCounter(_seller);
        bytes32 orderHash = seaport.getOrderHash(params.toOrderComponents(counter));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            _sellerPk,
            keccak256(abi.encodePacked("\x19\x01", domainSeparator, orderHash))
        );

        order = OrderLib
            .empty()
            .withParameters(params)
            .withSignature(abi.encodePacked(r, s, v));
    }

    // forgefmt: disable-next-item
    function _buildErc20Order(
        address _seller,
        uint256 _sellerPk,
        address _nft,
        uint256 _tokenId,
        address _erc20,
        uint256 _price
    ) internal view returns (Order memory order) {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItemLib
            .empty()
            .withItemType(ItemType.ERC721)
            .withToken(_nft)
            .withIdentifierOrCriteria(_tokenId)
            .withAmount(1);

        ConsiderationItem[] memory consideration = new ConsiderationItem[](1);
        consideration[0] = ConsiderationItemLib
            .empty()
            .withItemType(ItemType.ERC20)
            .withToken(_erc20)
            .withAmount(_price)
            .withRecipient(payable(_seller));

        OrderParameters memory params = OrderParametersLib
            .empty()
            .withOfferer(_seller)
            .withOffer(offer)
            .withTotalConsideration(consideration)
            .withOrderType(OrderType.FULL_OPEN)
            .withStartTime(block.timestamp)
            .withEndTime(block.timestamp + 1 hours).withSalt(uint256(keccak256(abi.encode(_tokenId, _erc20, _price))));

        uint256 counter = seaport.getCounter(_seller);
        bytes32 orderHash = seaport.getOrderHash(params.toOrderComponents(counter));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            _sellerPk,
            keccak256(abi.encodePacked("\x19\x01", domainSeparator, orderHash))
        );

        order = OrderLib
            .empty()
            .withParameters(params)
            .withSignature(abi.encodePacked(r, s, v));
    }

    function _buildErc1155Order(
        address _seller,
        uint256 _sellerPk,
        address _nft,
        uint256 _tokenId,
        uint256 _quantity,
        address _currency,
        uint256 _price
    ) internal view returns (Order memory order) {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItemLib.empty()
            .withItemType(ItemType.ERC1155)
            .withToken(_nft)
            .withIdentifierOrCriteria(_tokenId)
            .withAmount(_quantity);

        ConsiderationItem[] memory consideration = new ConsiderationItem[](1);
        consideration[0] = ConsiderationItemLib.empty()
            .withItemType(_currency == address(0) ? ItemType.NATIVE : ItemType.ERC20)
            .withToken(_currency)
            .withAmount(_price)
            .withRecipient(payable(_seller));

        OrderParameters memory params = OrderParametersLib.empty()
            .withOfferer(_seller)
            .withOffer(offer)
            .withTotalConsideration(consideration)
            .withOrderType(OrderType.PARTIAL_OPEN)
            .withStartTime(block.timestamp)
            .withEndTime(block.timestamp + 1 hours)
            .withSalt(uint256(keccak256(abi.encode(_tokenId, _quantity, _currency, _price))));

        bytes32 orderHash = seaport.getOrderHash(params.toOrderComponents(seaport.getCounter(_seller)));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(_sellerPk, keccak256(abi.encodePacked("\x19\x01", domainSeparator, orderHash)));
        order = OrderLib.empty().withParameters(params).withSignature(abi.encodePacked(r, s, v));
    }

    function _buildScatterContractOrder(ScatterOfferer offerer, ScatterOfferer.ScatterListing[] memory listings)
        internal
        view
        returns (AdvancedOrder memory order)
    {
        ScatterOfferer.ScatterSubmission memory submission = ScatterOfferer.ScatterSubmission({
            role: ScatterOfferer.Role.Listing,
            listings: listings,
            criteriaRoot: bytes32(0),
            maxFeeBps: 500,
            startTime: block.timestamp,
            endTime: block.timestamp + 1 hours,
            nonce: 0,
            salt: bytes32(uint256(0xdead))
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SELLER_PK, offerer.hashSubmission(submission));
        ScatterOfferer.ScatterFill[] memory fills = new ScatterOfferer.ScatterFill[](listings.length);
        for (uint256 i = 0; i < listings.length; i++) {
            fills[i] = ScatterOfferer.ScatterFill({itemIndex: i, tokenId: listings[i].tokenId, quantity: 1});
        }
        bytes memory extraData = abi.encode(
            submission, abi.encodePacked(r, s, v), address(0), fills, new bytes32[][](0), uint256(0), bytes("")
        );
        (SpentItem[] memory previewOffer, ReceivedItem[] memory previewConsideration) =
            offerer.previewOrder(SEAPORT, buyer, new SpentItem[](0), new SpentItem[](0), extraData);

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
        order = AdvancedOrder({
            parameters: OrderParameters({
                offerer: address(offerer),
                zone: address(0),
                offer: offer,
                consideration: consideration,
                orderType: OrderType.CONTRACT,
                startTime: submission.startTime,
                endTime: submission.endTime,
                zoneHash: bytes32(0),
                salt: 0,
                conduitKey: bytes32(0),
                totalOriginalConsiderationItems: consideration.length
            }),
            numerator: 1,
            denominator: 1,
            signature: "",
            extraData: extraData
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

    function mint(address to, uint256 tokenId, uint256 amount) external {
        _mint(to, tokenId, amount, "");
    }
}

contract MockERC20E2E is ERC20 {
    constructor() ERC20("MockE2E", "ME2E") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract CallbackDonationBuyer is ERC1155Holder {
    address payable private router;
    IERC20 private token;
    uint256 private nativeDonation;
    uint256 private erc20Donation;

    function configure(address payable router_, IERC20 token_, uint256 nativeDonation_, uint256 erc20Donation_)
        external
    {
        router = router_;
        token = token_;
        nativeDonation = nativeDonation_;
        erc20Donation = erc20Donation_;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes memory) public override returns (bytes4) {
        uint256 nativeAmount = nativeDonation;
        if (nativeAmount > 0) {
            nativeDonation = 0;
            (bool sent,) = router.call{value: nativeAmount}("");
            require(sent, "native donation failed");
        }

        uint256 tokenAmount = erc20Donation;
        if (tokenAmount > 0) {
            erc20Donation = 0;
            require(token.transfer(router, tokenAmount), "ERC20 donation failed");
        }
        return this.onERC1155Received.selector;
    }

    receive() external payable {}
}
