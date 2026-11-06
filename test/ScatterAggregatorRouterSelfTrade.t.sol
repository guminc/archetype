// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ScatterAggregatorRouterE2ETest} from "./ScatterAggregatorRouterE2E.t.sol";
import {InsufficientPayment} from "../src/ScatterAggregatorRouter.sol";
import {ScatterOfferer} from "../src/ScatterOfferer.sol";
import {Order, OrderParameters, AdvancedOrder, CriteriaResolver} from "seaport-types/src/lib/ConsiderationStructs.sol";
import {OrderParametersLib} from "seaport-sol/lib/OrderParametersLib.sol";

contract ScatterAggregatorRouterSelfTradeTest is ScatterAggregatorRouterE2ETest {
    using OrderParametersLib for OrderParameters;

    function test_selfTradeNativeERC721CostsOnlyFees() public {
        _assertListingSettlement(seller, seller, false, false);
    }

    function test_selfTradeNativeERC1155CostsOnlyFees() public {
        _assertListingSettlement(seller, seller, true, false);
    }

    function test_selfTradeERC20ERC721CostsOnlyFees() public {
        _assertListingSettlement(seller, seller, false, true);
    }

    function test_selfTradeERC20ERC1155CostsOnlyFees() public {
        _assertListingSettlement(seller, seller, true, true);
    }

    function test_selfTradeLinkedWalletNativeERC721PaysMakerAndTransfersNft() public {
        _assertListingSettlement(buyer, buyer, false, false);
    }

    function test_selfTradeLinkedWalletNativeERC1155PaysMakerAndTransfersNft() public {
        _assertListingSettlement(buyer, buyer, true, false);
    }

    function test_selfTradeLinkedWalletERC20ERC721PaysMakerAndTransfersNft() public {
        _assertListingSettlement(buyer, buyer, false, true);
    }

    function test_selfTradeLinkedWalletERC20ERC1155PaysMakerAndTransfersNft() public {
        _assertListingSettlement(buyer, buyer, true, true);
    }

    function test_selfTradeListingCanSendNftToDistinctRecipient() public {
        _assertListingSettlement(seller, buyer, false, false);
    }

    function test_selfTradeScatterListingsDirectNativeSettlement() public {
        _assertScatterListingSettlement(seller, false, false);
    }

    function test_selfTradeScatterListingsDirectERC20Settlement() public {
        _assertScatterListingSettlement(seller, false, true);
    }

    function test_selfTradeScatterListingsSweepNativeSettlement() public {
        _assertScatterListingSettlement(seller, true, false);
    }

    function test_selfTradeScatterListingsSweepERC20Settlement() public {
        _assertScatterListingSettlement(seller, true, true);
    }

    function test_selfTradeLinkedWalletScatterListingsDirectNativeSettlement() public {
        _assertScatterListingSettlement(buyer, false, false);
    }

    function test_selfTradeLinkedWalletScatterListingsDirectERC20Settlement() public {
        _assertScatterListingSettlement(buyer, false, true);
    }

    function test_selfTradeLinkedWalletScatterListingsSweepNativeSettlement() public {
        _assertScatterListingSettlement(buyer, true, false);
    }

    function test_selfTradeLinkedWalletScatterListingsSweepERC20Settlement() public {
        _assertScatterListingSettlement(buyer, true, true);
    }

    function _assertScatterListingSettlement(address payer, bool routed, bool tokenPayment) internal {
        _prank(address(this));
        scatterCollectionRegistry.setRewardsOverride(address(nft721), rewardsRecipient);
        scatterCollectionRegistry.setRewardsOverride(address(nft1155), rewardsRecipient);
        vm.deal(seller, 10 ether);
        erc20.mint(seller, 100 ether);
        _prank(seller);
        nft721.setApprovalForAll(address(conduit), true);
        nft1155.setApprovalForAll(address(conduit), true);

        ScatterOfferer.ScatterListing[] memory listings = new ScatterOfferer.ScatterListing[](2);
        address currency = tokenPayment ? address(erc20) : address(0);
        listings[0] =
            ScatterOfferer.ScatterListing(ScatterOfferer.AssetType.ERC721, address(nft721), 1, 1, currency, 1 ether);
        listings[1] =
            ScatterOfferer.ScatterListing(ScatterOfferer.AssetType.ERC1155, address(nft1155), 1, 4, currency, 2 ether);
        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = _buildScatterContractOrder(scatterOfferer, listings);
        _prank(payer);
        if (tokenPayment) erc20.approve(routed ? address(conduit) : SEAPORT, 3 ether);
        if (routed) {
            address[] memory currencies = new address[](tokenPayment ? 1 : 0);
            uint256[] memory amounts = new uint256[](currencies.length);
            if (tokenPayment) {
                currencies[0] = address(erc20);
                amounts[0] = 3 ether;
            }
            subject.sweepMixed{value: tokenPayment ? 0 : 3.1 ether}(
                _generateSweepCalldata(orders, payer),
                tokenPayment ? 0 : 3 ether,
                new uint256[](0),
                currencies,
                amounts,
                address(0),
                0,
                "",
                500
            );
        } else {
            assertTrue(
                seaport.fulfillAdvancedOrder{value: tokenPayment ? 0 : 3.1 ether}(
                    orders[0], new CriteriaResolver[](0), bytes32(0), payer
                )
            );
        }

        if (tokenPayment) {
            assertEq(erc20.balanceOf(payer), payer == seller ? 99.85 ether : 97 ether);
            assertEq(erc20.balanceOf(seller), payer == seller ? 99.85 ether : 102.85 ether);
            assertEq(erc20.balanceOf(PLATFORM), 0.075 ether);
            assertEq(erc20.balanceOf(rewardsRecipient), 0.075 ether);
            assertEq(erc20.balanceOf(address(subject)), 0);
            assertEq(erc20.balanceOf(address(scatterOfferer)), 0);
            assertEq(erc20.balanceOf(SEAPORT), 0);
            assertEq(erc20.allowance(address(subject), SEAPORT), 0);
        } else {
            assertEq(payer.balance, payer == seller ? 9.85 ether : 7 ether);
            assertEq(seller.balance, payer == seller ? 9.85 ether : 12.85 ether);
            assertEq(PLATFORM.balance, 0.075 ether);
            assertEq(rewardsRecipient.balance, 0.075 ether);
            assertEq(address(subject).balance, 0);
            assertEq(address(scatterOfferer).balance, 0);
            assertEq(SEAPORT.balance, 0);
        }
        assertEq(nft721.ownerOf(1), payer);
        assertEq(nft1155.balanceOf(seller, 1), payer == seller ? 100 : 99);
        assertEq(nft1155.balanceOf(payer, 1), payer == seller ? 100 : 1);
        assertEq(nft1155.balanceOf(address(subject), 1), 0);
        assertEq(nft1155.balanceOf(address(scatterOfferer), 1), 0);
        ScatterOfferer.ScatterSubmission memory submission =
            abi.decode(orders[0].extraData, (ScatterOfferer.ScatterSubmission));
        for (uint256 i; i < 2; ++i) {
            (, bool cancelled, uint256 filled, uint256 remaining) = scatterOfferer.listingStatus(seller, submission, i);
            assertFalse(cancelled);
            assertEq(filled, 1);
            assertEq(remaining, i == 0 ? 0 : 3);
        }
    }

    function test_selfTradeNativeRequiresGrossPaymentNotOnlyNetFee() public {
        Order memory order = _buildNativeOrder(seller, SELLER_PK, address(nft721), 1, 1 ether);
        bytes32 orderHash = seaport.getOrderHash(order.parameters.toOrderComponents(0));
        bytes memory data = _generateBuyCalldata(order, seller);
        vm.deal(seller, 1.05 ether);
        _prank(seller);
        vm.expectRevert(InsufficientPayment.selector);
        subject.buyExternalListing{value: 0.05 ether}(data, 1 ether, address(0), orderHash, 0, "", 500);
        assertEq(seller.balance, 1.05 ether);
        assertEq(PLATFORM.balance, 0);
        assertEq(nft721.ownerOf(1), seller);
        (,, uint256 filled,) = seaport.getOrderStatus(orderHash);
        assertEq(filled, 0);
    }

    function test_selfTradeERC20RequiresGrossBalanceAndConduitAllowance() public {
        Order memory order = _buildErc20Order(seller, SELLER_PK, address(nft721), 1, address(erc20), 1 ether);
        bytes32 orderHash = seaport.getOrderHash(order.parameters.toOrderComponents(0));
        bytes memory data = _generateBuyCalldata(order, seller);
        erc20.mint(seller, 0.05 ether);
        _prank(seller);
        erc20.approve(address(conduit), 1.05 ether);
        vm.expectRevert();
        subject.buyExternalListingERC20(data, address(erc20), 1 ether, address(0), orderHash, 0, "", 500);
        assertEq(erc20.balanceOf(seller), 0.05 ether);
        erc20.mint(seller, 1 ether);
        erc20.approve(address(conduit), 0.05 ether);
        vm.expectRevert();
        subject.buyExternalListingERC20(data, address(erc20), 1 ether, address(0), orderHash, 0, "", 500);
        assertEq(erc20.balanceOf(seller), 1.05 ether);
        assertEq(erc20.balanceOf(PLATFORM), 0);
        assertEq(erc20.balanceOf(address(subject)), 0);
        assertEq(nft721.ownerOf(1), seller);
        (,, uint256 filled,) = seaport.getOrderStatus(orderHash);
        assertEq(filled, 0);

        erc20.approve(address(conduit), 1.05 ether);
        subject.buyExternalListingERC20(data, address(erc20), 1 ether, address(0), orderHash, 0, "", 500);
        assertEq(erc20.balanceOf(seller), 1 ether);
        assertEq(erc20.balanceOf(PLATFORM), 0.05 ether);
        (,, filled,) = seaport.getOrderStatus(orderHash);
        assertEq(filled, 1);
    }

    function _assertListingSettlement(address payer, address recipient, bool is1155, bool tokenPayment) internal {
        _prank(address(this));
        scatterCollectionRegistry.setRewardsOverride(is1155 ? address(nft1155) : address(nft721), rewardsRecipient);
        vm.deal(seller, 10 ether);
        erc20.mint(seller, 100 ether);
        Order memory order = is1155
            ? _buildErc1155Order(
                seller, SELLER_PK, address(nft1155), 1, 4, tokenPayment ? address(erc20) : address(0), 1 ether
            )
            : tokenPayment
                ? _buildErc20Order(seller, SELLER_PK, address(nft721), 1, address(erc20), 1 ether)
                : _buildNativeOrder(seller, SELLER_PK, address(nft721), 1, 1 ether);
        bytes32 orderHash = seaport.getOrderHash(order.parameters.toOrderComponents(0));
        bytes memory data = _generateBuyCalldata(order, recipient);
        _prank(payer);
        if (tokenPayment) {
            erc20.approve(address(conduit), 1.05 ether);
            subject.buyExternalListingERC20(data, address(erc20), 1 ether, address(0), orderHash, 0, "", 500);
            assertEq(erc20.balanceOf(payer), payer == seller ? 99.95 ether : 98.95 ether);
            assertEq(erc20.balanceOf(seller), payer == seller ? 99.95 ether : 101 ether);
            assertEq(erc20.balanceOf(PLATFORM), 0.025 ether);
            assertEq(erc20.balanceOf(rewardsRecipient), 0.025 ether);
            assertEq(erc20.balanceOf(address(subject)), 0);
            assertEq(erc20.balanceOf(SEAPORT), 0);
            assertEq(erc20.allowance(address(subject), SEAPORT), 0);
            assertEq(erc20.allowance(payer, address(conduit)), 0);
        } else {
            subject.buyExternalListing{value: 1.1 ether}(data, 1 ether, address(0), orderHash, 0, "", 500);
            assertEq(payer.balance, payer == seller ? 9.95 ether : 8.95 ether);
            assertEq(seller.balance, payer == seller ? 9.95 ether : 11 ether);
            assertEq(PLATFORM.balance, 0.025 ether);
            assertEq(rewardsRecipient.balance, 0.025 ether);
            assertEq(address(subject).balance, 0);
            assertEq(SEAPORT.balance, 0);
        }
        if (is1155) {
            assertEq(nft1155.balanceOf(seller, 1), recipient == seller ? 100 : 96);
            assertEq(nft1155.balanceOf(recipient, 1), recipient == seller ? 100 : 4);
            assertEq(nft1155.balanceOf(address(subject), 1), 0);
        } else {
            assertEq(nft721.ownerOf(1), recipient);
        }
        (, bool cancelled, uint256 filled, uint256 size) = seaport.getOrderStatus(orderHash);
        assertFalse(cancelled);
        assertEq(filled, 1);
        assertEq(size, 1);
        if (tokenPayment) {
            erc20.approve(address(conduit), 1.05 ether);
            vm.expectRevert();
            subject.buyExternalListingERC20(data, address(erc20), 1 ether, address(0), orderHash, 0, "", 500);
        } else {
            vm.expectRevert();
            subject.buyExternalListing{value: 1.05 ether}(data, 1 ether, address(0), orderHash, 0, "", 500);
        }
    }
}
