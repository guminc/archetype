// SPDX-License-Identifier: MIT
// forge-lint: disable-start(mixed-case-function, mixed-case-variable, asm-keccak256)
pragma solidity 0.8.24;

import {ConduitTest} from "./helpers/ConduitTest.sol";
import {
    AdvancedOrder,
    ConsiderationItem,
    CriteriaResolver,
    Fulfillment,
    FulfillmentComponent,
    OfferItem,
    OrderComponents,
    OrderParameters
} from "seaport-types/src/lib/ConsiderationStructs.sol";
import {ItemType, OrderType, Side} from "seaport-types/src/lib/ConsiderationEnums.sol";
import {SeaportInterface} from "seaport-types/src/interfaces/SeaportInterface.sol";
import {ConduitController} from "seaport-core/conduit/ConduitController.sol";
import {Seaport} from "seaport-core/Seaport.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract SeaportBidBatchE2ETest is ConduitTest {
    SeaportInterface internal seaport;
    MockERC1155BidBatchE2E internal nft1155;
    MockERC20BidBatchE2E internal weth;
    bytes32 internal domainSeparator;

    address internal seller;
    address internal bidder;
    address internal feeRecipient;

    uint256 internal constant SELLER_PK = uint256(keccak256("seller"));
    uint256 internal constant BIDDER_PK = uint256(keccak256("bidder"));

    function setUp() public {
        _setUpConduit();
        seller = vm.addr(SELLER_PK);
        bidder = vm.addr(BIDDER_PK);
        feeRecipient = makeAddr("feeRecipient");

        seaport = SeaportInterface(address(new Seaport(address(conduitController))));
        _openConduitChannel(address(seaport));
        (, domainSeparator,) = seaport.information();

        nft1155 = new MockERC1155BidBatchE2E();
        weth = new MockERC20BidBatchE2E();

        nft1155.mint(seller, 1, 1);
        nft1155.mint(seller, 2, 1);
        weth.mint(bidder, 3000 ether);

        vm.prank(seller);
        nft1155.setApprovalForAll(address(conduit), true);

        vm.prank(bidder);
        weth.approve(address(conduit), type(uint256).max);
    }

    // Regression for the direct Seaport batch assembled in https://github.com/guminc/scatter/pull/631.
    function test_matchAdvancedOrders_fills_fee_bearing_erc1155_bid_batch() public {
        (bytes32 criteriaRoot, bytes32[] memory proofForToken1, bytes32[] memory proofForToken2) =
            _criteriaForTokenIds(1, 2);

        AdvancedOrder memory sourceOrder = _buildBidOrder(criteriaRoot);
        AdvancedOrder[] memory orders = new AdvancedOrder[](4);
        orders[0] = sourceOrder;
        orders[1] = sourceOrder;
        orders[2] = _buildSellerMirrorOrder(1, 1, 950 ether, 0x3333);
        orders[3] = _buildSellerMirrorOrder(2, 1, 950 ether, 0x4444);

        CriteriaResolver[] memory criteriaResolvers = new CriteriaResolver[](2);
        criteriaResolvers[0] = CriteriaResolver({
            orderIndex: 0, side: Side.CONSIDERATION, index: 0, identifier: 1, criteriaProof: proofForToken1
        });
        criteriaResolvers[1] = CriteriaResolver({
            orderIndex: 1, side: Side.CONSIDERATION, index: 0, identifier: 2, criteriaProof: proofForToken2
        });

        Balances memory balancesBefore = _snapshotBalances();

        vm.prank(seller);
        seaport.matchAdvancedOrders(orders, criteriaResolvers, _buildBidBatchFulfillments(2), seller);
        Balances memory balancesAfter = _snapshotBalances();

        assertEq(nft1155.balanceOf(bidder, 1), 1);
        assertEq(nft1155.balanceOf(bidder, 2), 1);
        assertEq(nft1155.balanceOf(seller, 1), 0);
        assertEq(nft1155.balanceOf(seller, 2), 0);
        assertEq(balancesAfter.sellerWeth - balancesBefore.sellerWeth, 1900 ether);
        assertEq(balancesAfter.feeRecipientWeth - balancesBefore.feeRecipientWeth, 100 ether);
        assertEq(balancesBefore.bidderWeth - balancesAfter.bidderWeth, 2000 ether);
        assertEq(weth.balanceOf(address(seaport)), 0);
    }

    function _buildBidOrder(bytes32 criteriaRoot) internal view returns (AdvancedOrder memory order) {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem({
            itemType: ItemType.ERC20,
            token: address(weth),
            identifierOrCriteria: 0,
            startAmount: 2000 ether,
            endAmount: 2000 ether
        });

        ConsiderationItem[] memory consideration = new ConsiderationItem[](2);
        consideration[0] = ConsiderationItem({
            itemType: ItemType.ERC1155_WITH_CRITERIA,
            token: address(nft1155),
            identifierOrCriteria: uint256(criteriaRoot),
            startAmount: 2,
            endAmount: 2,
            recipient: payable(bidder)
        });
        consideration[1] = ConsiderationItem({
            itemType: ItemType.ERC20,
            token: address(weth),
            identifierOrCriteria: 0,
            startAmount: 100 ether,
            endAmount: 100 ether,
            recipient: payable(feeRecipient)
        });

        OrderParameters memory parameters = OrderParameters({
            offerer: bidder,
            zone: address(0),
            offer: offer,
            consideration: consideration,
            orderType: OrderType.PARTIAL_OPEN,
            startTime: block.timestamp,
            endTime: block.timestamp + 1 hours,
            zoneHash: bytes32(0),
            salt: 0x1111,
            conduitKey: conduitKey,
            totalOriginalConsiderationItems: consideration.length
        });

        order = AdvancedOrder({
            parameters: parameters,
            numerator: 1,
            denominator: 2,
            signature: _signOrder(parameters, BIDDER_PK),
            extraData: ""
        });
    }

    function _buildSellerMirrorOrder(uint256 tokenId, uint256 quantity, uint256 sellerProceeds, uint256 salt)
        internal
        view
        returns (AdvancedOrder memory order)
    {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem({
            itemType: ItemType.ERC1155,
            token: address(nft1155),
            identifierOrCriteria: tokenId,
            startAmount: quantity,
            endAmount: quantity
        });

        ConsiderationItem[] memory consideration = new ConsiderationItem[](1);
        consideration[0] = ConsiderationItem({
            itemType: ItemType.ERC20,
            token: address(weth),
            identifierOrCriteria: 0,
            startAmount: sellerProceeds,
            endAmount: sellerProceeds,
            recipient: payable(seller)
        });

        order = AdvancedOrder({
            parameters: OrderParameters({
                offerer: seller,
                zone: address(0),
                offer: offer,
                consideration: consideration,
                orderType: OrderType.FULL_OPEN,
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours,
                zoneHash: bytes32(0),
                salt: salt,
                conduitKey: conduitKey,
                totalOriginalConsiderationItems: consideration.length
            }),
            numerator: 1,
            denominator: 1,
            signature: "",
            extraData: ""
        });
    }

    function _buildBidBatchFulfillments(uint256 sourceOrderCount)
        internal
        pure
        returns (Fulfillment[] memory fulfillments)
    {
        fulfillments = new Fulfillment[](sourceOrderCount * 3);

        for (uint256 sourceIndex = 0; sourceIndex < sourceOrderCount; sourceIndex++) {
            uint256 mirrorIndex = sourceOrderCount + sourceIndex;
            uint256 fulfillmentIndex = sourceIndex * 3;

            fulfillments[fulfillmentIndex] = _fulfillment(mirrorIndex, 0, sourceIndex, 0);
            fulfillments[fulfillmentIndex + 1] = _fulfillment(sourceIndex, 0, mirrorIndex, 0);
            fulfillments[fulfillmentIndex + 2] = _fulfillment(sourceIndex, 0, sourceIndex, 1);
        }
    }

    function _criteriaForTokenIds(uint256 tokenId0, uint256 tokenId1)
        internal
        pure
        returns (bytes32 criteriaRoot, bytes32[] memory proofForToken0, bytes32[] memory proofForToken1)
    {
        bytes32 leaf0 = keccak256(abi.encode(tokenId0));
        bytes32 leaf1 = keccak256(abi.encode(tokenId1));
        criteriaRoot =
            leaf0 < leaf1 ? keccak256(abi.encodePacked(leaf0, leaf1)) : keccak256(abi.encodePacked(leaf1, leaf0));

        proofForToken0 = new bytes32[](1);
        proofForToken0[0] = leaf1;
        proofForToken1 = new bytes32[](1);
        proofForToken1[0] = leaf0;
    }

    function _fulfillment(
        uint256 offerOrderIndex,
        uint256 offerItemIndex,
        uint256 considerationOrderIndex,
        uint256 considerationItemIndex
    ) internal pure returns (Fulfillment memory fulfillment) {
        fulfillment.offerComponents = new FulfillmentComponent[](1);
        fulfillment.offerComponents[0] = FulfillmentComponent({orderIndex: offerOrderIndex, itemIndex: offerItemIndex});
        fulfillment.considerationComponents = new FulfillmentComponent[](1);
        fulfillment.considerationComponents[0] =
            FulfillmentComponent({orderIndex: considerationOrderIndex, itemIndex: considerationItemIndex});
    }

    function _signOrder(OrderParameters memory parameters, uint256 signerPk) internal view returns (bytes memory) {
        OrderComponents memory components = OrderComponents({
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
        bytes32 orderHash = seaport.getOrderHash(components);
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(signerPk, keccak256(abi.encodePacked("\x19\x01", domainSeparator, orderHash)));
        return abi.encodePacked(r, s, v);
    }

    struct Balances {
        uint256 sellerWeth;
        uint256 bidderWeth;
        uint256 feeRecipientWeth;
    }

    function _snapshotBalances() internal view returns (Balances memory balances) {
        balances = Balances({
            sellerWeth: weth.balanceOf(seller),
            bidderWeth: weth.balanceOf(bidder),
            feeRecipientWeth: weth.balanceOf(feeRecipient)
        });
    }
}

contract MockERC1155BidBatchE2E is ERC1155 {
    constructor() ERC1155("") {}

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }
}

contract MockERC20BidBatchE2E is ERC20 {
    constructor() ERC20("MockWETH", "WETH") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
