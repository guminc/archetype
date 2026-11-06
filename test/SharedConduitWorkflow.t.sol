// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ConduitTransfer} from "seaport-types/src/conduit/lib/ConduitStructs.sol";
import {ConduitItemType} from "seaport-types/src/conduit/lib/ConduitEnums.sol";
import {
    TransferHelperItem,
    TransferHelperItemsWithRecipient
} from "seaport-types/src/helpers/TransferHelperStructs.sol";
import {TransferHelper} from "../lib/seaport/contracts/helpers/TransferHelper.sol";
import {SeaportInterface} from "seaport-types/src/interfaces/SeaportInterface.sol";
import {
    AdvancedOrder,
    OrderParameters,
    OrderComponents,
    OfferItem,
    ConsiderationItem,
    CriteriaResolver
} from "seaport-types/src/lib/ConsiderationStructs.sol";
import {ItemType, OrderType} from "seaport-types/src/lib/ConsiderationEnums.sol";
import {ScatterCollectionRegistry} from "../src/ScatterCollectionRegistry.sol";
import {ScatterOfferer} from "../src/ScatterOfferer.sol";
import {ScatterBidRouter} from "../src/ScatterBidRouter.sol";
import {ScatterAggregatorRouter} from "../src/ScatterAggregatorRouter.sol";
import {ConduitConsumer, InvalidConduit} from "../src/ConduitConsumer.sol";
import {ConduitTest} from "./helpers/ConduitTest.sol";

contract SharedConduitWorkflowTest is ConduitTest {
    uint256 internal constant ALICE_KEY = 0xA11CE;
    uint256 internal constant BOB_KEY = 0xB0B;
    address internal alice = vm.addr(ALICE_KEY);
    address internal bob = vm.addr(BOB_KEY);
    address internal attacker = makeAddr("attacker");
    address internal recipient = makeAddr("recipient");
    ConduitCurrency internal currency;
    ConduitNft internal nft;
    ConduitEdition internal edition;
    ScatterCollectionRegistry internal registry;
    ScatterOfferer internal offerer;
    ScatterBidRouter internal bidRouter;
    ScatterAggregatorRouter internal aggregator;
    TransferHelper internal helper;
    SeaportInterface internal seaport;

    function setUp() public {
        _setUpConduit();
        currency = new ConduitCurrency();
        nft = new ConduitNft();
        edition = new ConduitEdition();
        registry = new ScatterCollectionRegistry(address(this));
        offerer = new ScatterOfferer(address(this), registry, address(this), conduitKey);
        bidRouter = new ScatterBidRouter(address(this), address(this), registry, address(offerer), conduitKey);
        bidRouter.setAllowedCurrency(address(currency), true);
        aggregator = new ScatterAggregatorRouter(address(this), registry, address(this), address(offerer), conduitKey);
        offerer.setTrustedRouter(address(aggregator), true);
        deployCodeTo("Seaport.sol:Seaport", abi.encode(address(conduitController)), offerer.SEAPORT());
        seaport = SeaportInterface(offerer.SEAPORT());
        helper = new TransferHelper(address(conduitController));
        _openConduitChannel(address(offerer));
        _openConduitChannel(address(bidRouter));
        _openConduitChannel(address(aggregator));
        _openConduitChannel(address(seaport));
        _openConduitChannel(address(helper));
        nft.mint(alice, 1);
        nft.mint(alice, 2);
        nft.mint(bob, 3);
        edition.mint(alice, 7, 20);
        currency.mint(alice, 100 ether);
        currency.mint(bob, 100 ether);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(conduit), true);
        edition.setApprovalForAll(address(conduit), true);
        currency.approve(address(conduit), 20 ether);
        vm.stopPrank();
        vm.startPrank(bob);
        nft.setApprovalForAll(address(seaport), true);
        currency.approve(address(seaport), type(uint256).max);
        vm.stopPrank();
    }

    function test_oneNftApprovalSupportsBatchTransferAndExternalBid() public {
        TransferHelperItem[] memory items = new TransferHelperItem[](2);
        items[0] = TransferHelperItem(ConduitItemType.ERC721, address(nft), 1, 1);
        items[1] = TransferHelperItem(ConduitItemType.ERC1155, address(edition), 7, 3);
        TransferHelperItemsWithRecipient[] memory groups = new TransferHelperItemsWithRecipient[](1);
        groups[0] = TransferHelperItemsWithRecipient(items, recipient, true);
        vm.prank(alice);
        helper.bulkTransfer(groups, conduitKey);
        AdvancedOrder memory order = _bid(address(nft), ItemType.ERC721, 2, 1, 1 ether);
        vm.prank(alice);
        _sellBid(order, 0.95 ether);
        assertEq(nft.ownerOf(1), recipient);
        assertEq(nft.ownerOf(2), bob);
        assertEq(edition.balanceOf(recipient, 7), 3);
        assertEq(edition.balanceOf(alice, 7), 17);
        assertEq(currency.balanceOf(alice), 100.95 ether);
        assertEq(currency.balanceOf(bob), 99 ether);
        assertEq(currency.balanceOf(bidRouter.PLATFORM()), 0.05 ether);
        assertEq(currency.balanceOf(address(bidRouter)), 0);
        assertFalse(nft.isApprovedForAll(alice, address(helper)));
        assertFalse(nft.isApprovedForAll(alice, address(bidRouter)));
        assertFalse(nft.isApprovedForAll(alice, address(seaport)));
    }

    function test_oneCurrencyAllowanceSupportsHelperTransferAndMarketplacePurchase() public {
        TransferHelperItem[] memory items = new TransferHelperItem[](1);
        items[0] = TransferHelperItem(ConduitItemType.ERC20, address(currency), 0, 10 ether);
        TransferHelperItemsWithRecipient[] memory groups = new TransferHelperItemsWithRecipient[](1);
        groups[0] = TransferHelperItemsWithRecipient(items, recipient, false);
        vm.prank(alice);
        helper.bulkTransfer(groups, conduitKey);
        AdvancedOrder memory order = _listing();
        bytes32 orderHash = seaport.getOrderHash(_components(order.parameters));
        bytes memory data = abi.encodeCall(
            SeaportInterface.fulfillAdvancedOrder, (order, new CriteriaResolver[](0), bytes32(0), alice)
        );
        vm.prank(alice);
        aggregator.buyExternalListingERC20(data, address(currency), 1 ether, address(0), orderHash, 0, "", 500);
        assertEq(nft.ownerOf(3), alice);
        assertEq(currency.balanceOf(alice), 88.95 ether);
        assertEq(currency.balanceOf(recipient), 10 ether);
        assertEq(currency.balanceOf(bob), 101 ether);
        assertEq(currency.balanceOf(aggregator.PLATFORM()), 0.05 ether);
        assertEq(currency.allowance(alice, address(conduit)), 8.95 ether);
        assertEq(currency.allowance(alice, address(aggregator)), 0);
        assertEq(currency.allowance(alice, address(seaport)), 0);
        assertEq(currency.allowance(address(aggregator), address(seaport)), 0);
        assertEq(currency.balanceOf(address(aggregator)), 0);
    }

    function test_approvalDoesNotLetAnotherCallerSellTheVictimsNft() public {
        AdvancedOrder memory order = _bid(address(nft), ItemType.ERC721, 2, 1, 1 ether);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("ERC721IncorrectOwner(address,uint256,address)", attacker, 2, alice));
        _sellBid(order, 0);
        assertEq(nft.ownerOf(2), alice);
        assertEq(currency.balanceOf(bob), 100 ether);
        assertEq(currency.balanceOf(attacker), 0);
        assertEq(currency.balanceOf(address(bidRouter)), 0);
        (,, uint256 filled,) = seaport.getOrderStatus(seaport.getOrderHash(_components(order.parameters)));
        assertEq(filled, 0);
    }

    function test_closingOneChannelDoesNotGrantOtherChannelsItsPermissions() public {
        conduitController.updateChannel(address(conduit), address(bidRouter), false);
        AdvancedOrder memory order = _bid(address(nft), ItemType.ERC721, 2, 1, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("ChannelClosed(address)", address(bidRouter)));
        _sellBid(order, 0);
        assertEq(nft.ownerOf(2), alice);
        assertEq(currency.balanceOf(bob), 100 ether);
        assertTrue(conduitController.getChannelStatus(address(conduit), address(helper)));
        assertTrue(conduitController.getChannelStatus(address(conduit), address(aggregator)));
    }

    function test_erc721RouterIngressDoesNotRequireASafeTransferCallback() public {
        nft.rejectSafeTransfers();
        AdvancedOrder memory order = _bid(address(nft), ItemType.ERC721, 2, 1, 1 ether);
        vm.prank(alice);
        _sellBid(order, 0.95 ether);
        assertEq(nft.ownerOf(2), bob);
        assertEq(currency.balanceOf(alice), 100.95 ether);
    }

    function test_erc1155ExternalBidPreservesBalancesAndClearsInternalApproval() public {
        AdvancedOrder memory order = _bid(address(edition), ItemType.ERC1155, 7, 4, 2 ether);
        vm.prank(alice);
        _sellBid(order, 1.9 ether);
        assertEq(edition.balanceOf(alice, 7), 16);
        assertEq(edition.balanceOf(bob, 7), 4);
        assertEq(edition.balanceOf(address(bidRouter), 7), 0);
        assertEq(currency.balanceOf(alice), 101.9 ether);
        assertEq(currency.balanceOf(bob), 98 ether);
        assertFalse(edition.isApprovedForAll(address(bidRouter), address(seaport)));
    }

    function test_badConduitKeysCannotCreateMarketplaceConsumers() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidConduit.selector, bytes32(0)));
        new ScatterOfferer(address(this), registry, address(this), bytes32(0));
        bytes32 unknown = keccak256("undeployed conduit");
        vm.expectRevert(abi.encodeWithSelector(InvalidConduit.selector, unknown));
        new ScatterOfferer(address(this), registry, address(this), unknown);
        vm.etch(address(conduit), hex"00");
        vm.expectRevert(abi.encodeWithSelector(InvalidConduit.selector, conduitKey));
        new ScatterOfferer(address(this), registry, address(this), conduitKey);
    }

    function testFuzz_sharedEditionApprovalConservesAssetsAndFees(uint8 sent, uint8 sold, uint96 price) public {
        uint256 transferQuantity = bound(sent, 1, 19);
        uint256 saleQuantity = bound(sold, 1, 20 - transferQuantity);
        uint256 salePrice = bound(price, 1, 100 ether);
        TransferHelperItem[] memory items = new TransferHelperItem[](1);
        items[0] = TransferHelperItem(ConduitItemType.ERC1155, address(edition), 7, transferQuantity);
        TransferHelperItemsWithRecipient[] memory groups = new TransferHelperItemsWithRecipient[](1);
        groups[0] = TransferHelperItemsWithRecipient(items, recipient, true);
        vm.prank(alice);
        helper.bulkTransfer(groups, conduitKey);
        AdvancedOrder memory order = _bid(address(edition), ItemType.ERC1155, 7, saleQuantity, salePrice);
        uint256 fee = salePrice / 20;
        vm.prank(alice);
        _sellBid(order, salePrice - fee);
        assertEq(edition.balanceOf(alice, 7), 20 - transferQuantity - saleQuantity);
        assertEq(edition.balanceOf(recipient, 7), transferQuantity);
        assertEq(edition.balanceOf(bob, 7), saleQuantity);
        assertEq(edition.balanceOf(address(bidRouter), 7), 0);
        assertEq(currency.balanceOf(alice), 100 ether + salePrice - fee);
        assertEq(currency.balanceOf(bob), 100 ether - salePrice);
        assertEq(currency.balanceOf(bidRouter.PLATFORM()), fee);
        assertEq(currency.balanceOf(address(bidRouter)), 0);
        assertFalse(edition.isApprovedForAll(address(bidRouter), address(seaport)));
    }

    function _sellBid(AdvancedOrder memory order, uint256 minimumPayout) internal {
        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = order;
        ScatterBidRouter.MinimumPayout[] memory minima = new ScatterBidRouter.MinimumPayout[](1);
        minima[0] = ScatterBidRouter.MinimumPayout(address(currency), minimumPayout);
        bidRouter.sellIntoBids(orders, new CriteriaResolver[][](1), address(0), minima, block.timestamp + 1 hours, "");
    }

    function _bid(address collection, ItemType itemType, uint256 id, uint256 quantity, uint256 price)
        internal
        returns (AdvancedOrder memory order)
    {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem(ItemType.ERC20, address(currency), 0, price, price);
        ConsiderationItem[] memory consideration = new ConsiderationItem[](1);
        consideration[0] = ConsiderationItem(itemType, collection, id, quantity, quantity, payable(bob));
        return _signedOrder(offer, consideration);
    }

    function _listing() internal returns (AdvancedOrder memory order) {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem(ItemType.ERC721, address(nft), 3, 1, 1);
        ConsiderationItem[] memory consideration = new ConsiderationItem[](1);
        consideration[0] = ConsiderationItem(ItemType.ERC20, address(currency), 0, 1 ether, 1 ether, payable(bob));
        return _signedOrder(offer, consideration);
    }

    function _signedOrder(OfferItem[] memory offer, ConsiderationItem[] memory consideration)
        internal
        returns (AdvancedOrder memory order)
    {
        order.parameters = OrderParameters({
            offerer: bob,
            zone: address(0),
            offer: offer,
            consideration: consideration,
            orderType: OrderType.FULL_OPEN,
            startTime: block.timestamp,
            endTime: block.timestamp + 1 days,
            zoneHash: bytes32(0),
            salt: 1,
            conduitKey: bytes32(0),
            totalOriginalConsiderationItems: consideration.length
        });
        bytes32 orderHash = seaport.getOrderHash(_components(order.parameters));
        (, bytes32 domainSeparator,) = seaport.information();
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(BOB_KEY, keccak256(abi.encodePacked(hex"1901", domainSeparator, orderHash)));
        order.signature = abi.encodePacked(r, s, v);
        order.numerator = 1;
        order.denominator = 1;
    }

    function _components(OrderParameters memory parameters) internal view returns (OrderComponents memory) {
        return OrderComponents({
            offerer: parameters.offerer,
            zone: parameters.zone,
            offer: parameters.offer,
            consideration: parameters.consideration,
            orderType: parameters.orderType,
            startTime: parameters.startTime,
            endTime: parameters.endTime,
            zoneHash: parameters.zoneHash,
            salt: parameters.salt,
            conduitKey: parameters.conduitKey,
            counter: seaport.getCounter(parameters.offerer)
        });
    }
}

contract ConduitCurrency is ERC20 {
    constructor() ERC20("Currency", "CUR") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract ConduitNft is ERC721 {
    bool internal safeTransfersRejected;

    constructor() ERC721("NFT", "NFT") {}

    function mint(address account, uint256 id) external {
        _mint(account, id);
    }

    function rejectSafeTransfers() external {
        safeTransfersRejected = true;
    }

    function safeTransferFrom(address from, address to, uint256 id, bytes memory data) public override {
        require(!safeTransfersRejected, "Safe transfers rejected");
        super.safeTransferFrom(from, to, id, data);
    }
}

contract ConduitEdition is ERC1155 {
    constructor() ERC1155("") {}

    function mint(address account, uint256 id, uint256 quantity) external {
        _mint(account, id, quantity, "");
    }
}
