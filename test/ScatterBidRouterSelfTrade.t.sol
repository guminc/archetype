// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ScatterBidRouterE2ETest} from "./ScatterBidRouterE2E.t.sol";
import {ScatterOfferer} from "../src/ScatterOfferer.sol";
import {InvalidConsiderationShape} from "../src/ScatterBidRouter.sol";
import {AdvancedOrder, OrderParameters, ConsiderationItem} from "seaport-types/src/lib/ConsiderationStructs.sol";
import {ItemType} from "seaport-types/src/lib/ConsiderationEnums.sol";
import {OrderParametersLib} from "seaport-sol/lib/OrderParametersLib.sol";

contract ScatterBidRouterSelfTradeTest is ScatterBidRouterE2ETest {
    using OrderParametersLib for OrderParameters;

    function test_selfTradeExternalBidsReturnBothNftStandardsAndChargeFees() public {
        _makeBidderNftSeller();
        _assertBidSettlement(false);
    }

    function test_selfTradeNativeBidsReturnBothNftStandardsAndChargeFees() public {
        _makeBidderNftSeller();
        _assertBidSettlement(true);
    }

    function test_selfTradeLinkedWalletExternalBidsPaySenderAndTransferBothNftStandards() public {
        _assertBidSettlement(false);
    }

    function test_selfTradeLinkedWalletNativeBidsPaySenderAndTransferBothNftStandards() public {
        _assertBidSettlement(true);
    }

    function test_selfTradeExternalBidRequiresGrossFundsAndBothConduitApprovals() public {
        _assertBidFundingConstraints(false);
    }

    function test_selfTradeNativeBidRequiresGrossFundsAndBothConduitApprovals() public {
        _assertBidFundingConstraints(true);
    }

    function test_selfTradeExternalBidRejectsCurrencyConsiderationPaidToCaller() public {
        _makeBidderNftSeller();
        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = _externalOrder(false, 1, 1, address(currency), 2 ether, 1, 1);
        ConsiderationItem[] memory consideration = new ConsiderationItem[](2);
        consideration[0] = orders[0].parameters.consideration[0];
        consideration[1] =
            ConsiderationItem(ItemType.ERC20, address(currency), 0, 0.1 ether, 0.1 ether, payable(seller));
        orders[0].parameters.consideration = consideration;
        orders[0].parameters.totalOriginalConsiderationItems = 2;
        bytes32 orderHash = seaport.getOrderHash(orders[0].parameters.toOrderComponents(0));
        (, bytes32 domain,) = seaport.information();
        orders[0].signature = _sign(BIDDER_PK, keccak256(abi.encodePacked("\x19\x01", domain, orderHash)));
        vm.expectRevert(InvalidConsiderationShape.selector);
        _sell(orders, _minimum(address(currency), 0), address(0));
        assertEq(currency.balanceOf(bidder), 100 ether);
        assertEq(currency.balanceOf(router.PLATFORM()), 0);
        assertEq(nft721.ownerOf(1), bidder);
        (,, uint256 filled,) = seaport.getOrderStatus(orderHash);
        assertEq(filled, 0);
    }

    function test_selfTradeExternalBidRequiresBidderSignatureForSellerRecipient() public {
        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = _externalOrder(false, 1, 1, address(currency), 2 ether, 1, 1);
        orders[0].parameters.consideration[0].recipient = payable(seller);
        bytes32 orderHash = seaport.getOrderHash(orders[0].parameters.toOrderComponents(0));
        vm.expectRevert(bytes4(keccak256("InvalidSigner()")));
        _sell(orders, _minimum(address(currency), 0), address(0));
        assertEq(currency.balanceOf(bidder), 100 ether);
        assertEq(currency.balanceOf(seller), 0);
        assertEq(nft721.ownerOf(1), seller);
        (,, uint256 filled,) = seaport.getOrderStatus(orderHash);
        assertEq(filled, 0);

        (, bytes32 domain,) = seaport.information();
        orders[0].signature = _sign(BIDDER_PK, keccak256(abi.encodePacked("\x19\x01", domain, orderHash)));
        _sell(orders, _minimum(address(currency), 1.9 ether), address(0));
        assertEq(currency.balanceOf(bidder), 98 ether);
        assertEq(currency.balanceOf(seller), 1.9 ether);
        assertEq(currency.balanceOf(router.PLATFORM()), 0.1 ether);
        assertEq(currency.balanceOf(address(router)), 0);
        assertEq(nft721.ownerOf(1), seller);
        (,, uint256 finalFilled, uint256 size) = seaport.getOrderStatus(orderHash);
        assertEq(finalFilled, 1);
        assertEq(size, 1);
    }

    function test_selfTradeLinkedWalletBidderCannotSupplyOtherWalletsApprovedNft() public {
        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = _externalOrder(false, 1, 1, address(currency), 2 ether, 1, 1);
        vm.expectRevert();
        vm.prank(bidder);
        router.sellIntoBids(orders, _resolvers(1), address(0), _minimum(address(currency), 0), block.timestamp + 1, "");
        assertEq(nft721.ownerOf(1), seller);
        assertEq(currency.balanceOf(bidder), 100 ether);
        assertEq(currency.balanceOf(seller), 0);
        bytes32 orderHash = seaport.getOrderHash(orders[0].parameters.toOrderComponents(0));
        (,, uint256 filled,) = seaport.getOrderStatus(orderHash);
        assertEq(filled, 0);
    }

    function _assertBidFundingConstraints(bool nativeBid) internal {
        _makeBidderNftSeller();
        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = nativeBid
            ? this.nativeOrder(false, 1, 1, address(currency), 2 ether, address(0))
            : _externalOrder(false, 1, 1, address(currency), 2 ether, 1, 1);
        vm.prank(bidder);
        currency.transfer(makeAddr("unavailableFunds"), 99.9 ether);
        vm.expectRevert();
        _sell(orders, _minimum(address(currency), 1.9 ether), address(0));
        assertEq(currency.balanceOf(bidder), 0.1 ether);
        assertEq(nft721.ownerOf(1), bidder);
        currency.mint(bidder, 1.9 ether);
        vm.prank(bidder);
        currency.approve(address(conduit), 0.1 ether);
        vm.expectRevert();
        _sell(orders, _minimum(address(currency), 1.9 ether), address(0));
        assertEq(currency.balanceOf(bidder), 2 ether);
        assertEq(nft721.ownerOf(1), bidder);
        vm.startPrank(bidder);
        currency.approve(address(conduit), 2 ether);
        nft721.setApprovalForAll(address(conduit), false);
        vm.stopPrank();
        vm.expectRevert();
        _sell(orders, _minimum(address(currency), 1.9 ether), address(0));
        assertEq(currency.balanceOf(bidder), 2 ether);
        assertEq(currency.balanceOf(router.PLATFORM()), 0);
        assertEq(nft721.ownerOf(1), bidder);
        vm.prank(bidder);
        nft721.setApprovalForAll(address(conduit), true);
        _sell(orders, _minimum(address(currency), 1.9 ether), address(0));
        assertEq(currency.balanceOf(bidder), 1.9 ether);
        assertEq(currency.balanceOf(router.PLATFORM()), 0.1 ether);
        assertEq(currency.balanceOf(address(router)), 0);
        assertEq(nft721.ownerOf(1), bidder);
    }

    function _assertBidSettlement(bool nativeBid) internal {
        registry.setRewardsOverride(address(nft721), rewards);
        registry.setRewardsOverride(address(nft1155), rewards);
        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = nativeBid
            ? this.nativeOrder(false, 1, 1, address(currency), 2 ether, address(0))
            : _externalOrder(false, 1, 1, address(currency), 2 ether, 1, 1);
        orders[1] = nativeBid
            ? this.nativeOrder(true, 7, 4, address(currency), 1 ether, address(0))
            : _externalOrder(true, 7, 4, address(currency), 4 ether, 1, 1);
        _sell(orders, _minimum(address(currency), 5.7 ether), address(0));

        assertEq(currency.balanceOf(bidder), seller == bidder ? 99.7 ether : 94 ether);
        assertEq(currency.balanceOf(seller), seller == bidder ? 99.7 ether : 5.7 ether);
        assertEq(currency.balanceOf(router.PLATFORM()), 0.15 ether);
        assertEq(currency.balanceOf(rewards), 0.15 ether);
        assertEq(currency.balanceOf(address(router)), 0);
        assertEq(currency.balanceOf(address(offerer)), 0);
        assertEq(currency.balanceOf(address(seaport)), 0);
        assertEq(nft721.ownerOf(1), bidder);
        assertEq(nft1155.balanceOf(seller, 7), seller == bidder ? 20 : 16);
        assertEq(nft1155.balanceOf(bidder, 7), seller == bidder ? 20 : 4);
        assertEq(nft1155.balanceOf(address(router), 7), 0);
        assertFalse(nft1155.isApprovedForAll(address(router), address(seaport)));
        assertEq(router.activeRoutedFulfiller(), address(0));
        assertEq(currency.allowance(address(offerer), address(seaport)), 0);
        for (uint256 i; i < orders.length; ++i) {
            if (nativeBid) {
                ScatterOfferer.ScatterSubmission memory submission =
                    abi.decode(orders[i].extraData, (ScatterOfferer.ScatterSubmission));
                (, bool cancelled, uint256 filled, uint256 remaining) = offerer.listingStatus(bidder, submission, 0);
                assertFalse(cancelled);
                assertEq(filled, i == 0 ? 1 : 4);
                assertEq(remaining, i == 0 ? 0 : 16);
            } else {
                bytes32 orderHash = seaport.getOrderHash(orders[i].parameters.toOrderComponents(0));
                (, bool cancelled, uint256 filled, uint256 size) = seaport.getOrderStatus(orderHash);
                assertFalse(cancelled);
                assertEq(filled, 1);
                assertEq(size, 1);
            }
        }
    }

    function _makeBidderNftSeller() internal {
        vm.startPrank(seller);
        nft721.transferFrom(seller, bidder, 1);
        nft1155.safeTransferFrom(seller, bidder, 7, 20, "");
        vm.stopPrank();
        seller = bidder;
        vm.startPrank(seller);
        nft721.setApprovalForAll(address(conduit), true);
        nft1155.setApprovalForAll(address(conduit), true);
        vm.stopPrank();
    }
}
