// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ArchetypeErc721a.t.sol";

contract ExternalPricingCurve {
    function getQuote(uint256 sold, uint256 quantity) external pure returns (uint256) {
        return (quantity * (sold + 1) + quantity * (quantity - 1) / 2) * 0.01 ether;
    }
}

contract ExternalQuantityPricing {
    function getQuote(uint256, uint256 quantity) external pure returns (uint256) {
        return quantity * quantity * 0.01 ether;
    }
}

contract ExternalGradualPricing {
    function getQuote(uint256 sold, uint256 quantity) external pure returns (uint256) {
        return quantity * 1 ether + (quantity * sold + quantity * (quantity - 1) / 2) * 0.005 ether;
    }
}

contract InvalidExternalPricing {
    error QuoteUnavailable();
    uint256 public writes;
    uint256 public immutable mode;

    constructor(uint256 mode_) {
        mode = mode_;
    }

    function getQuote(uint256, uint256) external returns (uint256) {
        if (mode == 0) revert QuoteUnavailable();
        if (mode == 1) {
            assembly {
                return(0, 1)
            }
        }
        if (mode == 2) ++writes;
        return uint256(type(uint128).max) + 1;
    }
}

contract ExternalMintPricingTest is ArchetypeErc721aTest {
    function test_externalPricing_twoPercentCapSurvivesConcurrentSalesWithoutOvercharging() public {
        ArchetypeErc721a collection = _createCollection(owner);
        _setPublicInvite(collection, 0, uint32(block.timestamp));
        collection.setMintPricing(PUBLIC_KEY, address(new ExternalGradualPricing()));
        (uint256 cost, uint256 nativeValue,,) = collection.computeMintPayment(PUBLIC_KEY, 1, false);
        MintConstraints memory caps = _constraints(address(0), uint128(cost * 102 / 100), 1);
        caps.maxNativeValue = nativeValue * 102 / 100;
        _mint(collection, other, _publicAuth(), 1, 1 ether);

        _prank(buyer);
        uint256 balanceBefore = buyer.balance;
        for (uint256 i; i < 4; ++i) {
            collection.mint{value: 1.02 ether}(_publicAuth(), 1, address(0), "", caps);
        }
        assertEq(balanceBefore - buyer.balance, 4.05 ether);
        assertEq(collection.balanceOf(buyer), 4);
        assertEq(PAYOUTS.balance, 5.05 ether);
        assertEq(address(collection).balance, 0);
        vm.expectRevert(ExcessiveCurrencyCost.selector);
        collection.mint{value: 1.02 ether}(_publicAuth(), 1, address(0), "", caps);
        (, uint256 sold) = collection.mintPricing(PUBLIC_KEY);
        assertEq(sold, 5);
        assertEq(balanceBefore - buyer.balance, 4.05 ether);
    }

    function test_externalPricing_batchRefundsBuyerWithinApprovedCapAndRejectsLaterSale() public {
        ArchetypeErc721a collection = _createCollection(owner);
        _setPublicInvite(collection, 0, uint32(block.timestamp));
        collection.setMintPricing(PUBLIC_KEY, address(new ExternalPricingCurve()));
        MintConstraints memory caps = _constraints(address(0), 0.03 ether, 1);
        caps.maxNativeValue = 0.03 ether;
        _mint(collection, other, _publicAuth(), 1, 0.01 ether);

        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory calls = new bytes[](2);
        for (uint256 i; i < 2; ++i) {
            targets[i] = address(collection);
            values[i] = 0.03 ether;
            calls[i] = abi.encodeCall(collection.mint, (_publicAuth(), 1, address(0), "", caps));
        }
        _prank(buyer);
        uint256 balanceBefore = buyer.balance;
        uint256 batchBalanceBefore = BATCH.balance;
        ArchetypeBatchV100(BATCH).executeBatch{value: 0.06 ether}(targets, values, calls);
        assertEq(balanceBefore - buyer.balance, 0.05 ether);
        assertEq(BATCH.balance, batchBalanceBefore);
        assertEq(address(collection).balance, 0);
        assertEq(collection.balanceOf(buyer), 2);
        assertEq(PAYOUTS.balance, 0.06 ether);
        assertEq(ArchetypeBatchV100(BATCH).currentCaller(), address(0));

        vm.expectRevert(ExcessiveCurrencyCost.selector);
        ArchetypeBatchV100(BATCH).executeBatch{value: 0.06 ether}(targets, values, calls);
        (, uint256 sold) = collection.mintPricing(PUBLIC_KEY);
        assertEq(sold, 3);
        assertEq(balanceBefore - buyer.balance, 0.05 ether);
        assertEq(BATCH.balance, batchBalanceBefore);
        assertEq(ArchetypeBatchV100(BATCH).currentCaller(), address(0));
    }

    function test_externalPricing_supplyAndWalletLimitsRejectWithoutAdvancingSold() public {
        ArchetypeErc721a collection = _createCollection(owner);
        _setInvite(collection, PUBLIC_KEY, Invite(0, uint32(block.timestamp), 0, 1, 2, 1, address(0), false));
        collection.setMintPricing(PUBLIC_KEY, address(new ExternalPricingCurve()));
        _mint(collection, buyer, _publicAuth(), 1, 0.01 ether);
        vm.expectRevert(NumberOfMintsExceeded.selector);
        collection.mint{value: 0.02 ether}(_publicAuth(), 1, address(0), "", _constraints());
        _mint(collection, other, _publicAuth(), 1, 0.02 ether);
        _prank(owner);
        vm.expectRevert(ListMaxSupplyExceeded.selector);
        collection.mint{value: 0.03 ether}(_publicAuth(), 1, address(0), "", _constraints());
        (, uint256 sold) = collection.mintPricing(PUBLIC_KEY);
        assertEq(sold, 2);
        assertEq(collection.totalSupply(), 2);
        assertEq(collection.listSupply(PUBLIC_KEY), 2);
        assertEq(PAYOUTS.balance, 0.03 ether);
    }

    function test_externalPricing_staleQuotesRespectBothPaymentCaps() public {
        ArchetypeErc721a collection = _createCollection(owner);
        _setPublicInvite(collection, 9 ether, uint32(block.timestamp));
        collection.setMintPricing(PUBLIC_KEY, address(new ExternalPricingCurve()));
        (uint256 cost, uint256 nativeValue, address currency, uint256 output) =
            collection.computeMintPayment(PUBLIC_KEY, 2, false);
        assertEq(cost, 0.03 ether);
        assertEq(nativeValue, cost);
        assertEq(currency, address(0));
        assertEq(output, 2);
        assertEq(collection.computePrice(PUBLIC_KEY, 2, false), cost);
        _mint(collection, other, _publicAuth(), 1, 0.01 ether);

        _prank(buyer);
        MintConstraints memory caps = _constraints(address(0), uint128(cost), 2);
        vm.expectRevert(ExcessiveCurrencyCost.selector);
        collection.mint{value: 0.05 ether}(_publicAuth(), 2, address(0), "", caps);
        caps.maxCurrencyCost = 0.05 ether;
        caps.maxNativeValue = nativeValue;
        vm.expectRevert(ExcessiveNativeValue.selector);
        collection.mint{value: 0.05 ether}(_publicAuth(), 2, address(0), "", caps);
        assertEq(collection.totalSupply(), 1);
        (, uint256 sold) = collection.mintPricing(PUBLIC_KEY);
        assertEq(sold, 1);
        caps.maxNativeValue = 0.05 ether;
        uint256 beforeBalance = buyer.balance;
        collection.mint{value: 0.06 ether}(_publicAuth(), 2, address(0), "", caps);
        assertEq(beforeBalance - buyer.balance, 0.05 ether);
        assertEq(collection.balanceOf(buyer), 2);
        assertEq(collection.computePrice(PUBLIC_KEY, 1, false), 0.04 ether);
    }

    function test_externalPricing_soldSurvivesInviteReplacementAndDisableWithBatchBonuses() public {
        ArchetypeErc721a collection = _createCollection(owner);
        Invite memory invite =
            Invite(0, uint32(block.timestamp), 0, type(uint32).max, type(uint32).max, 2, address(0), false);
        _setInvite(collection, PUBLIC_KEY, invite);
        _mint(collection, buyer, _publicAuth(), 1, 0);
        _prank(owner);
        ExternalPricingCurve curve = new ExternalPricingCurve();
        collection.setMintPricing(PUBLIC_KEY, address(curve));
        BonusDiscount[] memory discounts = new BonusDiscount[](1);
        discounts[0] = BonusDiscount(3, 1);
        collection.setBonusDiscounts(PUBLIC_KEY, discounts);
        address[] memory recipients = new address[](2);
        recipients[0] = buyer;
        recipients[1] = other;
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 1;
        quantities[1] = 2;
        collection.setMintPricing(PUBLIC_KEY, address(new ExternalQuantityPricing()));
        collection.batchMintTo{value: 0.36 ether}(
            _publicAuth(), _batchMintArgs(recipients, quantities, _constraints(address(0), 0.36 ether, 7))
        );
        assertEq(PAYOUTS.balance, 0.36 ether);
        collection.setMintPricing(PUBLIC_KEY, address(curve));
        assertEq(collection.balanceOf(buyer), 4);
        assertEq(collection.balanceOf(other), 5);
        (, uint256 sold) = collection.mintPricing(PUBLIC_KEY);
        assertEq(sold, 8);
        assertEq(collection.totalSupply(), 9);
        assertEq(collection.listSupply(PUBLIC_KEY), 0);
        assertEq(collection.computePrice(PUBLIC_KEY, 1, false), 0.09 ether);

        collection.setMintPricing(PUBLIC_KEY, address(0));
        invite.price = 0.001 ether;
        _setInvite(collection, PUBLIC_KEY, invite);
        _mint(collection, buyer, _publicAuth(), 1, 0.002 ether);
        _prank(owner);
        collection.setMintPricing(PUBLIC_KEY, address(curve));
        (, sold) = collection.mintPricing(PUBLIC_KEY);
        assertEq(sold, 10);
        (uint256 cost,,, uint256 output) = collection.computeMintPayment(PUBLIC_KEY, 1, false);
        assertEq(cost, 0.23 ether);
        assertEq(output, 2);
    }

    function test_externalPricing_invalidQuotesCannotMintOrChangeAccounting() public {
        ArchetypeErc721a collection = _createCollection(owner);
        _setPublicInvite(collection, 0, uint32(block.timestamp));
        collection.setAffiliateDiscount(5000);
        for (uint256 mode; mode < 4; ++mode) {
            _prank(owner);
            InvalidExternalPricing calculator = new InvalidExternalPricing(mode);
            collection.setMintPricing(PUBLIC_KEY, address(calculator));
            if (mode == 0) vm.expectRevert(InvalidExternalPricing.QuoteUnavailable.selector);
            else if (mode == 3) vm.expectRevert(MintCostOverflow.selector);
            else vm.expectRevert();
            collection.computePrice(PUBLIC_KEY, 1, true);
            _prank(buyer);
            vm.expectRevert();
            collection.mint(_publicAuth(), 1, address(0), "", _constraints());
            assertEq(calculator.writes(), 0);
            assertEq(collection.totalSupply(), 0);
            (, uint256 sold) = collection.mintPricing(PUBLIC_KEY);
            assertEq(sold, 0);
            assertEq(PAYOUTS.balance, 0);
        }
    }

    function test_externalPricing_callbackFailureRollsBackSoldAndCanRetrySameQuote() public {
        ArchetypeErc721a collection = _createCollection(owner);
        _setPublicInvite(collection, 0, uint32(block.timestamp));
        collection.setMintPricing(PUBLIC_KEY, address(new ExternalPricingCurve()));
        MintCallback callback = new MintCallback(collection);
        collection.setMintCallback(address(callback));
        callback.setFailAt(2);
        _prank(buyer);
        uint256 balanceBefore = buyer.balance;
        vm.expectRevert(MintCallback.CommitmentFailed.selector);
        collection.mint{value: 0.03 ether}(_publicAuth(), 2, address(0), "", _constraints());
        (, uint256 sold) = collection.mintPricing(PUBLIC_KEY);
        assertEq(sold, 0);
        assertEq(collection.totalSupply(), 0);
        assertEq(callback.count(), 0);
        assertEq(PAYOUTS.balance, 0);
        assertEq(buyer.balance, balanceBefore);
        assertEq(collection.computePrice(PUBLIC_KEY, 2, false), 0.03 ether);
        callback.setFailAt(0);
        collection.mint{value: 0.03 ether}(_publicAuth(), 2, address(0), "", _constraints());
        (, sold) = collection.mintPricing(PUBLIC_KEY);
        assertEq(sold, 2);
        assertEq(callback.count(), 2);
        assertEq(PAYOUTS.balance, 0.03 ether);
    }

    function test_externalPricing_publicListEligibilityAndOwnerCanAlwaysClear() public {
        ArchetypeErc721a collection = _createCollection(owner);
        bytes32 key = keccak256("private merkle root");
        Invite memory invite = Invite(0, uint32(block.timestamp), 0, 100, 100, 1, address(0), false);
        _setInvite(collection, key, invite);
        ExternalPricingCurve calculator = new ExternalPricingCurve();
        vm.expectRevert(InvalidConfig.selector);
        collection.setMintPricing(key, address(calculator));
        invite.isBlacklist = true;
        _setInvite(collection, key, invite);
        collection.setMintPricing(key, address(calculator));
        assertEq(collection.computePrice(key, 1, false), 0.01 ether);
        invite.isBlacklist = false;
        _setInvite(collection, key, invite);
        vm.expectRevert(InvalidConfig.selector);
        collection.computeMintPayment(key, 1, false);
        _prank(buyer);
        vm.expectRevert(NotOwner.selector);
        collection.setMintPricing(key, address(0));
        _prank(owner);
        collection.setMintPricing(key, address(0));
        assertEq(collection.computePrice(key, 1, false), 0);
        vm.expectRevert(InvalidConfig.selector);
        collection.setMintPricing(PUBLIC_KEY, buyer);
        vm.expectRevert(InvalidConfig.selector);
        collection.setMintPricing(PUBLIC_KEY, address(collection));
    }

    function test_externalPricing_erc20DiscountAndNativeMinimumConservePayment() public {
        ArchetypeErc721a collection = _createCollection(owner);
        TestErc20 token = new TestErc20();
        bytes32 key = keccak256(abi.encodePacked(address(token)));
        _setInvite(collection, key, _erc20Invite(address(token), 9 ether));
        collection.setMintPricing(key, address(new ExternalPricingCurve()));
        collection.setAffiliateDiscount(2000);
        mintFeeRegistry.setNativeMinimumFee(0.001 ether);
        address affiliate = makeAddr("external pricing affiliate");
        (uint256 cost, uint256 nativeValue, address currency, uint256 output) =
            collection.computeMintPayment(key, 2, true);
        assertEq(cost, 0.024 ether);
        assertEq(nativeValue, 0.002 ether);
        assertEq(currency, address(token));
        assertEq(output, 2);
        _prank(buyer);
        token.mint(1 ether);
        token.approve(address(collection), 1 ether);
        collection.mint{value: nativeValue}(
            _auth(key),
            2,
            affiliate,
            _affiliateSignature(collection, affiliate),
            _constraints(address(token), uint128(cost), 2)
        );
        ArchetypePayouts payouts = ArchetypePayouts(PAYOUTS);
        assertEq(token.balanceOf(buyer), 0.976 ether);
        assertEq(token.balanceOf(PAYOUTS), cost);
        assertEq(payouts.balanceToken(affiliate, address(token)), 0.0036 ether);
        assertEq(payouts.balanceToken(owner, address(token)), 0.01938 ether);
        assertEq(payouts.balanceToken(PLATFORM, address(token)), 0.00102 ether);
        assertEq(payouts.balance(PLATFORM), nativeValue);
        (, uint256 sold) = collection.mintPricing(key);
        assertEq(sold, 2);
    }

    function test_externalPricing_burnOutputsDoNotAdvanceOrdinaryMintPrice() public {
        ArchetypeErc721a source = _createCollection(owner);
        ArchetypeErc721a collection = _createCollection(owner);
        _setPublicInvite(source, 0, uint32(block.timestamp));
        _mint(source, buyer, _publicAuth(), 1, 0);
        _setPublicInvite(collection, 0, uint32(block.timestamp));
        collection.setMintPricing(PUBLIC_KEY, address(new ExternalPricingCurve()));
        _mint(collection, buyer, _publicAuth(), 1, 0.01 ether);
        _setBurnInvite(
            collection,
            PUBLIC_KEY,
            BurnInvite(IERC721(address(source)), DEAD, address(0), 0, true, 2, uint32(block.timestamp), 0, 10)
        );
        _prank(buyer);
        source.setApprovalForAll(address(collection), true);
        collection.burnToMint(
            _publicAuth(), _rangeTokenIds(1, 1), _burnConstraints(address(source), DEAD, _constraints())
        );
        assertEq(source.ownerOf(1), DEAD);
        assertEq(collection.balanceOf(buyer), 3);
        (, uint256 sold) = collection.mintPricing(PUBLIC_KEY);
        assertEq(sold, 1);
        assertEq(collection.computePrice(PUBLIC_KEY, 1, false), 0.02 ether);
        collection.mintTo{value: 0.02 ether}(_publicAuth(), 1, other, address(0), "", _constraints());
        assertEq(collection.balanceOf(other), 1);
        (, sold) = collection.mintPricing(PUBLIC_KEY);
        assertEq(sold, 2);
    }

    function test_externalPricing_ownerCallbackCannotReplaceCalculatorDuringMint() public {
        ArchetypeErc721a collection = _createCollection(owner);
        _setPublicInvite(collection, 0, uint32(block.timestamp));
        ExternalPricingCurve calculator = new ExternalPricingCurve();
        collection.setMintPricing(PUBLIC_KEY, address(calculator));
        MintCallback callback = new MintCallback(collection);
        collection.setMintCallback(address(callback));
        collection.transferOwnership(address(callback));
        callback.addAttempt(abi.encodeCall(collection.setMintPricing, (PUBLIC_KEY, address(0))));
        _mint(collection, buyer, _publicAuth(), 1, 0.01 ether);
        assertEq(callback.failures(0), abi.encodeWithSelector(Reentrancy.selector));
        (address activeCalculator, uint256 sold) = collection.mintPricing(PUBLIC_KEY);
        assertEq(activeCalculator, address(calculator));
        assertEq(sold, 1);
        assertEq(collection.ownerOf(1), buyer);
    }
}
