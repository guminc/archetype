// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DN404} from "dn404/src/DN404.sol";
import {DN404Mirror} from "dn404/src/DN404Mirror.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ConduitTest} from "./helpers/ConduitTest.sol";
import {ISeaportDeployer} from "./helpers/ISeaportDeployer.sol";
import {ScatterOfferer} from "../src/ScatterOfferer.sol";
import {ScatterBidRouter} from "../src/ScatterBidRouter.sol";
import {ScatterCollectionRegistry} from "../src/ScatterCollectionRegistry.sol";
import {TestErc20} from "../src/TestErc20.sol";
import {SeaportInterface} from "seaport-types/src/interfaces/SeaportInterface.sol";
import {
    AdvancedOrder,
    CriteriaResolver,
    OfferItem,
    ConsiderationItem,
    SpentItem,
    ReceivedItem
} from "seaport-types/src/lib/ConsiderationStructs.sol";
import {OrderType} from "seaport-types/src/lib/ConsiderationEnums.sol";

contract DN404MarketplaceE2ETest is ConduitTest {
    uint256 internal constant SELLER_PK = 0x5E11;
    uint256 internal constant BIDDER_PK = 0xB1D;
    address internal seller = vm.addr(SELLER_PK);
    address internal bidder = vm.addr(BIDDER_PK);
    address internal buyer = makeAddr("buyer");
    address internal creator = makeAddr("creator");
    address internal rewards = makeAddr("mirrorRewards");
    address internal other = makeAddr("other");
    ScatterCollectionRegistry internal registry;
    ScatterOfferer internal offerer;
    ScatterBidRouter internal router;
    SeaportInterface internal seaport;
    TestErc20 internal currency;
    MarketplaceDN404 internal base;
    DN404Mirror internal mirror;

    function setUp() public {
        _setUpConduit();
        registry = new ScatterCollectionRegistry(address(this));
        offerer = new ScatterOfferer(address(this), registry, makeAddr("authorizer"), conduitKey);
        router = new ScatterBidRouter(address(this), makeAddr("authorizer"), registry, address(offerer), conduitKey);
        offerer.setTrustedRouter(address(router), true);
        address deployer = deployCode("test/helpers/SeaportDeployer.sol:SeaportDeployer");
        address realSeaport = ISeaportDeployer(deployer).deploy();
        vm.etch(offerer.SEAPORT(), realSeaport.code);
        seaport = SeaportInterface(offerer.SEAPORT());
        _openConduitChannel(address(offerer));
        _openConduitChannel(address(router));
        _openConduitChannel(address(seaport));
        currency = new TestErc20();
        router.setAllowedCurrency(address(currency), true);
        vm.startPrank(bidder);
        currency.mint(10 ether);
        currency.approve(address(conduit), type(uint256).max);
        vm.stopPrank();
        vm.deal(buyer, 10 ether);
        base = new MarketplaceDN404();
        base.mint(seller, 2 ether);
        base.transferOwnership(creator);
        mirror = DN404Mirror(payable(base.mirrorERC721()));
    }

    function test_listingRequiresMirrorApprovalAndBaseRegistrationDoesNotPayMirrorRewards() public {
        address[] memory collections = new address[](1);
        collections[0] = address(base);
        registry.registerScatterCollections(collections);
        assertEq(registry.rewardsRecipient(address(base)), creator);
        AdvancedOrder memory order = _order(ScatterOfferer.Role.Listing, 1);
        vm.prank(seller);
        base.approve(address(conduit), type(uint256).max);

        vm.expectRevert();
        vm.prank(buyer);
        seaport.fulfillAdvancedOrder{value: 1 ether}(order, new CriteriaResolver[](0), conduitKey, buyer);
        assertEq(mirror.ownerOf(1), seller);
        assertEq(buyer.balance, 10 ether);
        assertEq(seller.balance, 0);

        vm.prank(seller);
        mirror.setApprovalForAll(address(conduit), true);
        vm.prank(buyer);
        seaport.fulfillAdvancedOrder{value: 1 ether}(order, new CriteriaResolver[](0), conduitKey, buyer);

        assertEq(mirror.ownerOf(1), buyer);
        assertEq(mirror.ownerOf(2), seller);
        assertEq(base.balanceOf(seller), 1 ether);
        assertEq(base.balanceOf(buyer), 1 ether);
        assertEq(base.balanceOf(address(offerer)), 0);
        assertEq(seller.balance, 0.95 ether);
        assertEq(offerer.PLATFORM().balance, 0.05 ether);
        assertEq(creator.balance, 0);
        assertEq(buyer.balance, 9 ether);
        assertEq(address(offerer).balance, 0);
    }

    function test_listingPaysConfiguredMirrorRewardsRatherThanBaseRewards() public {
        registry.setRewardsOverride(address(base), creator);
        registry.setRewardsOverride(address(mirror), rewards);
        AdvancedOrder memory order = _order(ScatterOfferer.Role.Listing, 1);
        vm.prank(seller);
        mirror.approve(address(conduit), 1);
        vm.prank(buyer);
        seaport.fulfillAdvancedOrder{value: 1 ether}(order, new CriteriaResolver[](0), conduitKey, buyer);

        assertEq(mirror.ownerOf(1), buyer);
        assertEq(mirror.getApproved(1), address(0));
        assertEq(base.allowance(seller, address(conduit)), 0);
        assertEq(base.balanceOf(buyer), 1 ether);
        assertEq(seller.balance, 0.95 ether);
        assertEq(rewards.balance, 0.025 ether);
        assertEq(offerer.PLATFORM().balance, 0.025 ether);
        assertEq(creator.balance, 0);
    }

    function test_registeredMirrorRewardsFollowPulledOwnerNotLiveBaseOwner() public {
        address[] memory collections = new address[](1);
        collections[0] = address(mirror);
        registry.registerScatterCollections(collections);
        assertEq(registry.rewardsRecipient(address(mirror)), address(0));
        mirror.pullOwner();
        assertEq(registry.rewardsRecipient(address(mirror)), creator);
        vm.prank(creator);
        base.transferOwnership(rewards);
        assertEq(registry.rewardsRecipient(address(mirror)), creator);
        mirror.pullOwner();

        AdvancedOrder memory order = _order(ScatterOfferer.Role.Listing, 1);
        vm.prank(seller);
        mirror.setApprovalForAll(address(conduit), true);
        vm.prank(buyer);
        seaport.fulfillAdvancedOrder{value: 1 ether}(order, new CriteriaResolver[](0), conduitKey, buyer);

        assertEq(mirror.ownerOf(1), buyer);
        assertEq(rewards.balance, 0.025 ether);
        assertEq(creator.balance, 0);
        assertEq(seller.balance, 0.95 ether);
        assertEq(offerer.PLATFORM().balance, 0.025 ether);
    }

    function test_collectionBidAcceptsMirrorNftAndPaysRewardsWithoutDoubleFees() public {
        registry.setRewardsOverride(address(base), creator);
        registry.setRewardsOverride(address(mirror), rewards);
        AdvancedOrder memory order = _order(ScatterOfferer.Role.Bid, 2);
        vm.prank(seller);
        base.approve(address(conduit), type(uint256).max);
        vm.expectRevert();
        _acceptBid(order);
        assertEq(currency.balanceOf(bidder), 10 ether);
        assertEq(mirror.ownerOf(2), seller);

        vm.prank(seller);
        mirror.approve(address(conduit), 2);
        _acceptBid(order);

        assertEq(mirror.ownerOf(2), bidder);
        assertEq(mirror.ownerOf(1), seller);
        assertEq(base.balanceOf(bidder), 1 ether);
        assertEq(base.balanceOf(seller), 1 ether);
        assertEq(base.balanceOf(address(router)), 0);
        assertEq(mirror.getApproved(2), address(0));
        assertEq(currency.balanceOf(bidder), 9 ether);
        assertEq(currency.balanceOf(seller), 0.95 ether);
        assertEq(currency.balanceOf(rewards), 0.025 ether);
        assertEq(currency.balanceOf(offerer.PLATFORM()), 0.025 ether);
        assertEq(currency.balanceOf(creator), 0);
        assertEq(currency.balanceOf(address(router)), 0);
        assertEq(currency.balanceOf(address(offerer)), 0);
        assertEq(router.activeRoutedFulfiller(), address(0));
    }

    function test_erc20TransferBurningListedNftRevertsListingWithoutPayment() public {
        _assertInvalidatedSettlement(ScatterOfferer.Role.Listing, true);
    }

    function test_erc20TransferMovingListedNftRevertsListingWithoutPayment() public {
        _assertInvalidatedSettlement(ScatterOfferer.Role.Listing, false);
    }

    function test_erc20TransferBurningNftRevertsBidAcceptanceWithoutPayment() public {
        _assertInvalidatedSettlement(ScatterOfferer.Role.Bid, true);
    }

    function test_erc20TransferMovingNftRevertsBidAcceptanceWithoutPayment() public {
        _assertInvalidatedSettlement(ScatterOfferer.Role.Bid, false);
    }

    function _assertInvalidatedSettlement(ScatterOfferer.Role role, bool burn) internal {
        registry.setRewardsOverride(address(mirror), rewards);
        AdvancedOrder memory order = _order(role, 2);
        ScatterOfferer.ScatterSubmission memory submission =
            abi.decode(order.extraData, (ScatterOfferer.ScatterSubmission));
        bytes32 submissionHash = offerer.hashSubmission(submission);
        vm.prank(seller);
        mirror.setApprovalForAll(address(conduit), true);
        vm.prank(other);
        base.setSkipNFT(burn);
        vm.prank(seller);
        base.transfer(other, 1 ether);
        assertEq(mirror.ownerAt(2), burn ? address(0) : other);

        if (role == ScatterOfferer.Role.Listing) {
            vm.expectRevert();
            vm.prank(buyer);
            seaport.fulfillAdvancedOrder{value: 1 ether}(order, new CriteriaResolver[](0), conduitKey, buyer);
        } else {
            vm.expectRevert();
            _acceptBid(order);
        }

        assertEq(
            offerer.filledListingQuantity(role == ScatterOfferer.Role.Listing ? seller : bidder, submissionHash, 0), 0
        );
        assertEq(mirror.ownerAt(2), burn ? address(0) : other);
        assertEq(mirror.ownerOf(1), seller);
        assertEq(base.balanceOf(seller), 1 ether);
        assertEq(base.balanceOf(other), 1 ether);
        assertEq(base.balanceOf(buyer), 0);
        assertEq(base.balanceOf(bidder), 0);
        assertEq(buyer.balance, 10 ether);
        assertEq(seller.balance, 0);
        assertEq(rewards.balance, 0);
        assertEq(offerer.PLATFORM().balance, 0);
        assertEq(currency.balanceOf(bidder), 10 ether);
        assertEq(currency.balanceOf(seller), 0);
        assertEq(currency.balanceOf(rewards), 0);
        assertEq(currency.balanceOf(offerer.PLATFORM()), 0);
        assertEq(currency.balanceOf(address(router)), 0);
        assertEq(currency.balanceOf(address(offerer)), 0);
        assertEq(router.activeRoutedFulfiller(), address(0));
    }

    function _acceptBid(AdvancedOrder memory order) internal {
        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = order;
        CriteriaResolver[][] memory resolvers = new CriteriaResolver[][](1);
        resolvers[0] = new CriteriaResolver[](0);
        ScatterBidRouter.MinimumPayout[] memory minima = new ScatterBidRouter.MinimumPayout[](1);
        minima[0] = ScatterBidRouter.MinimumPayout(address(currency), 0.95 ether);
        vm.prank(seller);
        router.sellIntoBids(orders, resolvers, address(0), minima, block.timestamp + 1 hours, "");
    }

    function _order(ScatterOfferer.Role role, uint256 tokenId) internal view returns (AdvancedOrder memory order) {
        ScatterOfferer.ScatterListing[] memory listings = new ScatterOfferer.ScatterListing[](1);
        listings[0] = ScatterOfferer.ScatterListing({
            assetType: ScatterOfferer.AssetType.ERC721,
            collection: address(mirror),
            tokenId: role == ScatterOfferer.Role.Listing ? tokenId : 0,
            quantity: 1,
            currency: role == ScatterOfferer.Role.Listing ? address(0) : address(currency),
            priceWei: 1 ether
        });
        ScatterOfferer.ScatterSubmission memory submission = ScatterOfferer.ScatterSubmission({
            role: role,
            listings: listings,
            criteriaRoot: bytes32(0),
            maxFeeBps: 500,
            startTime: block.timestamp,
            endTime: block.timestamp + 1 hours,
            nonce: 0,
            salt: bytes32(tokenId)
        });
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(role == ScatterOfferer.Role.Listing ? SELLER_PK : BIDDER_PK, offerer.hashSubmission(submission));
        ScatterOfferer.ScatterFill[] memory fills = new ScatterOfferer.ScatterFill[](1);
        fills[0] = ScatterOfferer.ScatterFill(0, tokenId, 1);
        order.extraData = abi.encode(
            submission, abi.encodePacked(r, s, v), address(0), fills, new bytes32[][](0), uint256(0), bytes("")
        );
        (SpentItem[] memory offers, ReceivedItem[] memory considerations) =
            offerer.previewOrder(address(seaport), seller, new SpentItem[](0), new SpentItem[](0), order.extraData);
        order.parameters.offerer = address(offerer);
        order.parameters.orderType = OrderType.CONTRACT;
        order.parameters.startTime = submission.startTime;
        order.parameters.endTime = submission.endTime;
        order.parameters.offer = new OfferItem[](offers.length);
        for (uint256 i; i < offers.length; ++i) {
            SpentItem memory item = offers[i];
            order.parameters.offer[i] = OfferItem(item.itemType, item.token, item.identifier, item.amount, item.amount);
        }
        order.parameters.consideration = new ConsiderationItem[](considerations.length);
        for (uint256 i; i < considerations.length; ++i) {
            ReceivedItem memory item = considerations[i];
            order.parameters.consideration[i] =
                ConsiderationItem(item.itemType, item.token, item.identifier, item.amount, item.amount, item.recipient);
        }
        order.parameters.totalOriginalConsiderationItems = considerations.length;
        order.numerator = 1;
        order.denominator = 1;
    }
}

contract MarketplaceDN404 is DN404, Ownable {
    constructor() Ownable(msg.sender) {
        _initializeDN404(0, address(0), address(new DN404Mirror(msg.sender)));
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function name() public pure override returns (string memory) {
        return "Marketplace DN404";
    }

    function symbol() public pure override returns (string memory) {
        return "DN";
    }

    function _tokenURI(uint256) internal pure override returns (string memory) {
        return "";
    }
}
