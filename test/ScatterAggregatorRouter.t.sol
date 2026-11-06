// SPDX-License-Identifier: UNLICENSED
// forge-lint: disable-start(mixed-case-function, mixed-case-variable, asm-keccak256)
pragma solidity ^0.8.20;

import {ConduitTest} from "./helpers/ConduitTest.sol";
import {TokenTransferrerErrors} from "seaport-types/src/interfaces/TokenTransferrerErrors.sol";
import {SeaportInterface} from "seaport-types/src/interfaces/SeaportInterface.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ScatterAggregatorRouter,
    SeaportCallFailed,
    RefundFailed,
    FeeTransferFailed,
    InvalidListingAmount,
    InsufficientPayment,
    LengthMismatch,
    InvalidSweepOrderIndex,
    DuplicateSweepCurrency,
    DuplicateSweepOrderHash,
    InvalidSweepCalldataSelector,
    InvalidSweepRecipient,
    InvalidFulfillerConduitKey,
    InvalidTotalOriginalConsiderationItems,
    UnsupportedSweepCurrency,
    UnsupportedContractOrder,
    VariableSweepConsiderationAmount,
    OrderNotFilled,
    InvalidFeeAuthorizer,
    InvalidScatterCollectionRegistry,
    InvalidListingCollection,
    InvalidScatterOfferer,
    InvalidFeeAuthorization,
    FeeAuthorizationExpired,
    InvalidFeeBps,
    InvalidFeeSplitBps,
    FeeBpsExceedsLimit
} from "../src/ScatterAggregatorRouter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {
    AdvancedOrder,
    ConsiderationItem,
    CriteriaResolver,
    FulfillmentComponent,
    OfferItem,
    OrderComponents,
    OrderParameters
} from "seaport-types/src/lib/ConsiderationStructs.sol";
import {ItemType, OrderType} from "seaport-types/src/lib/ConsiderationEnums.sol";
import {ScatterCollectionRegistry} from "../src/ScatterCollectionRegistry.sol";

contract ScatterAggregatorRouterTest is ConduitTest {
    uint256 internal constant FEE_AUTHORIZER_PK = 0xA11CE;

    address internal constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    address internal constant PLATFORM = 0x8952caF7E5bf1fe63ebe94148ca802F3eF127C98;
    address internal constant SCATTER_OFFERER = address(0x1001);
    address internal constant COLLECTION_ONE = address(0x1003);
    address internal constant COLLECTION_TWO = address(0x1004);

    address internal owner;
    address internal buyer;
    address internal rewardsRecipient;
    address internal affiliate;
    address internal feeAuthorizer = vm.addr(FEE_AUTHORIZER_PK);
    ScatterAggregatorRouter internal subject;
    MockSeaport internal mockSeaport;
    ScatterCollectionRegistry internal scatterCollectionRegistry;

    bytes internal seaportFulfillCalldata;
    bytes internal seaportFulfillErc20Calldata;
    bytes internal seaportSweepCalldata;
    bytes32 internal externalOrderHash;
    bytes32 internal externalErc20OrderHash;
    ERC20Mock internal token;
    ERC20Mock internal token2;

    function setUp() public {
        _setUpConduit();
        owner = makeAddr("owner");
        buyer = makeAddr("buyer");
        rewardsRecipient = makeAddr("rewardsRecipient");
        affiliate = makeAddr("affiliate");

        vm.etch(COLLECTION_ONE, hex"00");
        vm.etch(COLLECTION_TWO, hex"00");
        vm.etch(SCATTER_OFFERER, hex"00");
        seaportFulfillCalldata = _seaportFulfillAdvancedCalldata(_sweepOrders()[0]);
        seaportSweepCalldata = _sweepCalldata(_sweepOrders());
        externalOrderHash = _orderHashes(_singleOrder(_sweepOrders()[0]))[0];

        scatterCollectionRegistry = new ScatterCollectionRegistry(address(this));
        subject =
            new ScatterAggregatorRouter(owner, scatterCollectionRegistry, feeAuthorizer, SCATTER_OFFERER, conduitKey);
        _openConduitChannel(address(subject));
        _openConduitChannel(SEAPORT);
        token = new ERC20Mock();
        token2 = new ERC20Mock();
        AdvancedOrder memory erc20Order = _erc20SweepOrder(address(0x1001), 1, 1 ether, address(token));
        seaportFulfillErc20Calldata = _seaportFulfillAdvancedCalldata(erc20Order);
        externalErc20OrderHash = _orderHashes(_singleOrder(erc20Order))[0];

        // Etching copies runtime code, not constructor-initialized storage.
        vm.etch(SEAPORT, address(new MockSeaport()).code);
        mockSeaport = MockSeaport(payable(SEAPORT));
        mockSeaport.setShouldFillOrder(true);
        mockSeaport.setOrderHashToFill(externalOrderHash);
        mockSeaport.setAvailableOrderHashes(_sweepOrderHashes());

        vm.deal(buyer, 10 ether);
        // Existing router funds must not be refunded to the next buyer.
        vm.deal(address(subject), 1 ether);

        _prank(buyer);
        token.mint(buyer, 10 ether);
        token.approve(address(conduit), type(uint256).max);
        token2.mint(buyer, 10 ether);
        token2.approve(address(conduit), type(uint256).max);

        vm.stopPrank();
    }

    function test_transferOwnershipRequiresAcceptance() public {
        address nextOwner = makeAddr("nextOwner");

        _prank(owner);
        subject.transferOwnership(nextOwner);

        assertEq(subject.owner(), owner);
        assertEq(subject.pendingOwner(), nextOwner);

        _prank(nextOwner);
        subject.acceptOwnership();
        subject.setFeeBps(1000);

        assertEq(subject.owner(), nextOwner);
        assertEq(subject.pendingOwner(), address(0));
        assertEq(subject.feeBps(), 1000);
    }

    function test_constructor_rejectsInvalidDependencies() public {
        vm.expectRevert(InvalidScatterCollectionRegistry.selector);
        new ScatterAggregatorRouter(
            owner, ScatterCollectionRegistry(address(0)), feeAuthorizer, SCATTER_OFFERER, conduitKey
        );

        vm.expectRevert(InvalidFeeAuthorizer.selector);
        new ScatterAggregatorRouter(owner, scatterCollectionRegistry, address(0), SCATTER_OFFERER, conduitKey);

        vm.expectRevert(InvalidScatterOfferer.selector);
        new ScatterAggregatorRouter(owner, scatterCollectionRegistry, feeAuthorizer, address(0x9999), conduitKey);
    }

    function test_pause_pausesContract() public {
        _prank(owner);
        subject.pause();
        assertEq(subject.paused(), true);
    }

    function test_pause_failsWhenCalledByNonOwner() public {
        address nonOwner = makeAddr("nonOwner");
        _prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        subject.pause();
    }

    function test_unpause_unpausesContract() public {
        _prank(owner);
        subject.pause();
        subject.unpause();
        assertEq(subject.paused(), false);
    }

    function test_unpause_failsWhenCalledByNonOwner() public {
        _prank(owner);
        subject.pause();

        address nonOwner = makeAddr("nonOwner");
        _prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        subject.unpause();
    }

    function test_buyExternalListing_settlesAndRefundsOverpayment() public {
        _prank(buyer);
        subject.buyExternalListing{value: 1.2 ether}(
            seaportFulfillCalldata, 1 ether, address(0), externalOrderHash, 0, "", 500
        );

        assertEq(buyer.balance, 8.95 ether);
        assertEq(SEAPORT.balance, 1 ether);
        assertEq(PLATFORM.balance, 0.05 ether);
        assertEq(address(subject).balance, 1 ether);
        assertEq(rewardsRecipient.balance, 0);
        assertEq(affiliate.balance, 0);
    }

    function test_buyExternalListing_distributesPlatformAndRewardsFees() public {
        _prank(address(this));
        scatterCollectionRegistry.setRewardsOverride(COLLECTION_ONE, rewardsRecipient);
        _prank(buyer);

        subject.buyExternalListing{value: 1.05 ether}(
            seaportFulfillCalldata,
            1 ether, // listingPrice
            address(0),
            externalOrderHash,
            0,
            "",
            500
        );

        // Fee breakdown: 1 ether listing * 5% = 0.05 ether.
        // Platform/rewards split 50/50 = 0.025 each.
        assertEq(subject.PLATFORM().balance, 0.025 ether);
        assertEq(rewardsRecipient.balance, 0.025 ether);
        assertEq(affiliate.balance, 0);
    }

    function test_buyExternalListing_distributesPlatformAndAffiliateFees() public {
        _prank(buyer);

        subject.buyExternalListing{value: 1.05 ether}(
            seaportFulfillCalldata,
            1 ether, // listingPrice
            affiliate,
            externalOrderHash,
            _feeAuthDeadline(),
            _feeAuthSig(buyer, affiliate, keccak256(abi.encode(externalOrderHash))),
            500
        );

        // Fee breakdown: 1 ether listing * 5% = 0.05 ether.
        // No rewards, platform/affiliate split 50/50 = 0.025 each.
        assertEq(subject.PLATFORM().balance, 0.025 ether);
        assertEq(rewardsRecipient.balance, 0);
        assertEq(affiliate.balance, 0.025 ether);
    }

    function test_buyExternalListing_affiliateTakesPriorityOverRegistryRewards() public {
        _prank(address(this));
        scatterCollectionRegistry.setRewardsOverride(COLLECTION_ONE, rewardsRecipient);
        _prank(buyer);

        subject.buyExternalListing{value: 1.05 ether}(
            seaportFulfillCalldata,
            1 ether, // listingPrice
            affiliate,
            externalOrderHash,
            _feeAuthDeadline(),
            _feeAuthSig(buyer, affiliate, keccak256(abi.encode(externalOrderHash))),
            500
        );

        // Affiliate takes priority over rewards attribution.
        assertEq(subject.PLATFORM().balance, 0.025 ether);
        assertEq(affiliate.balance, 0.025 ether);
        assertEq(rewardsRecipient.balance, 0);
    }

    function test_buyExternalListing_refundsNativeReturnedFromSeaport() public {
        (bytes memory fulfillCalldata, bytes32 orderHash) = _prepareNativeListing(0.9 ether);
        mockSeaport.setRefundAmount(0.1 ether);

        _prank(buyer);

        subject.buyExternalListing{value: 1.05 ether}(
            fulfillCalldata,
            1 ether, // listingPrice
            address(0),
            orderHash,
            0,
            "",
            500
        );

        // Seaport spends 0.9 ether, so the fee is 0.045 ether and the buyer's
        // total cost is 0.945 ether.
        assertEq(buyer.balance, 9.055 ether);
        assertEq(subject.SEAPORT().balance, 0.9 ether);
    }

    function test_buyExternalListing_emitsExternalListingFilledEvent() public {
        bytes32 orderHash = externalOrderHash;

        _prank(buyer);
        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.ExternalListingFilled(
            buyer, // buyer
            address(0), // currency
            orderHash,
            1 ether, // feeBaseAmount
            0.05 ether, // scatterFee
            affiliate, // affiliate
            address(0), // rewardsRecipient
            0.025 ether, // platformAmount
            0, // rewardsAmount
            0.025 ether // affiliateAmount
        );
        subject.buyExternalListing{value: 1.05 ether}(
            seaportFulfillCalldata,
            1 ether,
            affiliate,
            orderHash,
            _feeAuthDeadline(),
            _feeAuthSig(buyer, affiliate, keccak256(abi.encode(orderHash))),
            500
        );
    }

    function test_buyExternalListing_emitsOnlyActualPayoutRecipientsWhenAffiliateAndRewardsSupplied() public {
        _prank(address(this));
        scatterCollectionRegistry.setRewardsOverride(COLLECTION_ONE, rewardsRecipient);
        _prank(buyer);
        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.ExternalListingFilled(
            buyer,
            address(0),
            externalOrderHash,
            1 ether,
            0.05 ether,
            affiliate,
            address(0),
            0.025 ether,
            0,
            0.025 ether
        );
        subject.buyExternalListing{value: 1.05 ether}(
            seaportFulfillCalldata,
            1 ether,
            affiliate,
            externalOrderHash,
            _feeAuthDeadline(),
            _feeAuthSig(buyer, affiliate, keccak256(abi.encode(externalOrderHash))),
            500
        );
    }

    function test_buyExternalListing_expiredFeeAuthorizationReverts() public {
        uint256 deadline = _feeAuthDeadline();
        bytes memory signature =
            _feeAuthFor(buyer, affiliate, keccak256(abi.encode(externalOrderHash)), deadline, FEE_AUTHORIZER_PK);
        vm.warp(deadline + 1);
        _prank(buyer);
        vm.expectRevert(FeeAuthorizationExpired.selector);
        subject.buyExternalListing{value: 1.05 ether}(
            seaportFulfillCalldata, 1 ether, affiliate, externalOrderHash, deadline, signature, 500
        );
    }

    function test_buyExternalListing_feeAuthorizationBindsBuyerAffiliateAndOrder() public {
        uint256 deadline = _feeAuthDeadline();
        bytes memory signature =
            _feeAuthFor(buyer, affiliate, keccak256(abi.encode(externalOrderHash)), deadline, FEE_AUTHORIZER_PK);
        address otherBuyer = makeAddr("otherBuyer");
        address otherAffiliate = makeAddr("otherAffiliate");
        vm.deal(otherBuyer, 10 ether);
        _prank(otherBuyer);
        vm.expectRevert(InvalidFeeAuthorization.selector);
        subject.buyExternalListing{value: 1.05 ether}(
            seaportFulfillCalldata, 1 ether, affiliate, externalOrderHash, deadline, signature, 500
        );

        _prank(buyer);
        vm.expectRevert(InvalidFeeAuthorization.selector);
        subject.buyExternalListing{value: 1.05 ether}(
            seaportFulfillCalldata, 1 ether, otherAffiliate, externalOrderHash, deadline, signature, 500
        );

        AdvancedOrder memory otherOrder = _sweepOrders()[1];
        bytes32 otherHash = _orderHashes(_singleOrder(otherOrder))[0];
        vm.expectRevert(InvalidFeeAuthorization.selector);
        subject.buyExternalListing{value: 0.63 ether}(
            _seaportFulfillAdvancedCalldata(otherOrder), 0.6 ether, affiliate, otherHash, deadline, signature, 500
        );

        subject.buyExternalListing{value: 1.05 ether}(
            seaportFulfillCalldata, 1 ether, affiliate, externalOrderHash, deadline, signature, 500
        );
        assertEq(buyer.balance, 8.95 ether);
        assertEq(affiliate.balance, 0.025 ether);
        assertEq(rewardsRecipient.balance, 0);
        assertEq(PLATFORM.balance, 0.025 ether);
        assertEq(SEAPORT.balance, 1 ether);
    }

    function test_sweepMixed_feeAuthorizationBindsSubmittedOrderSequence() public {
        uint256 deadline = _feeAuthDeadline();
        bytes memory signature = _feeAuthFor(buyer, affiliate, _sweepOrdersHash(), deadline, FEE_AUTHORIZER_PK);
        AdvancedOrder[] memory reordered = _sweepOrders();
        AdvancedOrder memory first = reordered[0];
        reordered[0] = reordered[1];
        reordered[1] = first;

        _prank(buyer);
        vm.expectRevert(InvalidFeeAuthorization.selector);
        subject.sweepMixed{value: 1.68 ether}(
            _sweepCalldata(reordered),
            1.6 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            affiliate,
            deadline,
            signature,
            500
        );

        vm.expectRevert(InvalidFeeAuthorization.selector);
        subject.sweepMixed{value: 1.05 ether}(
            _sweepCalldata(_singleOrder(first)),
            1 ether,
            _singleUint(0),
            _emptyAddresses(),
            _emptyUints(),
            affiliate,
            deadline,
            signature,
            500
        );

        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, false));
        mockSeaport.setRefundAmount(0.6 ether);
        subject.sweepMixed{value: 1.68 ether}(
            seaportSweepCalldata,
            1.6 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            affiliate,
            deadline,
            signature,
            500
        );

        assertEq(buyer.balance, 8.95 ether);
        assertEq(PLATFORM.balance, 0.025 ether);
        assertEq(affiliate.balance, 0.025 ether);
        assertEq(SEAPORT.balance, 1 ether);
        assertEq(address(subject).balance, 1 ether);
    }

    function test_buyExternalListing_rejectsInvalidListingCollections() public {
        AdvancedOrder memory order = _sweepOrders()[0];
        OfferItem memory originalOffer = order.parameters.offer[0];
        order.parameters.offer = new OfferItem[](0);
        bytes32 orderHash = _orderHashes(_singleOrder(order))[0];

        _prank(buyer);
        vm.expectRevert(InvalidListingCollection.selector);
        subject.buyExternalListing{value: 1.05 ether}(
            _seaportFulfillAdvancedCalldata(order), 1 ether, address(0), orderHash, 0, "", 500
        );

        order.parameters.offer = new OfferItem[](2);
        order.parameters.offer[0] = originalOffer;
        order.parameters.offer[1] = OfferItem(ItemType.ERC721, COLLECTION_TWO, 2, 1, 1);
        orderHash = _orderHashes(_singleOrder(order))[0];
        vm.expectRevert(InvalidListingCollection.selector);
        subject.buyExternalListing{value: 1.05 ether}(
            _seaportFulfillAdvancedCalldata(order), 1 ether, address(0), orderHash, 0, "", 500
        );
    }

    function test_buyExternalListing_rejectsContractOrdersInBothCurrencies() public {
        AdvancedOrder memory nativeOrder = _sweepOrders()[0];
        nativeOrder.parameters.orderType = OrderType.CONTRACT;
        bytes32 nativeHash = _orderHashes(_singleOrder(nativeOrder))[0];

        _prank(buyer);
        vm.expectRevert(UnsupportedContractOrder.selector);
        subject.buyExternalListing{value: 1.05 ether}(
            _seaportFulfillAdvancedCalldata(nativeOrder), 1 ether, address(0), nativeHash, 0, "", 500
        );

        AdvancedOrder memory erc20Order = _erc20SweepOrder(address(0x1001), 1, 1 ether, address(token));
        erc20Order.parameters.orderType = OrderType.CONTRACT;
        bytes32 erc20Hash = _orderHashes(_singleOrder(erc20Order))[0];
        vm.expectRevert(UnsupportedContractOrder.selector);
        subject.buyExternalListingERC20(
            _seaportFulfillAdvancedCalldata(erc20Order), address(token), 1 ether, address(0), erc20Hash, 0, "", 500
        );
    }

    function test_buyExternalListing_affiliateWithWrongSignerReverts() public {
        _prank(buyer);
        vm.expectRevert(InvalidFeeAuthorization.selector);
        subject.buyExternalListing{value: 1.05 ether}(
            seaportFulfillCalldata,
            1 ether,
            affiliate,
            externalOrderHash,
            _feeAuthDeadline(),
            _feeAuthFor(buyer, affiliate, keccak256(abi.encode(externalOrderHash)), _feeAuthDeadline(), 0xB0B),
            500
        );
    }

    function test_buyExternalListing_acceptsMaximumFeeAuthorizationWindow() public {
        uint256 deadline = block.timestamp + subject.MAX_AUTHORIZATION_WINDOW();
        bytes memory signature =
            _feeAuthFor(buyer, affiliate, keccak256(abi.encode(externalOrderHash)), deadline, FEE_AUTHORIZER_PK);

        _prank(buyer);
        subject.buyExternalListing{value: 1.05 ether}(
            seaportFulfillCalldata, 1 ether, affiliate, externalOrderHash, deadline, signature, 500
        );

        assertEq(affiliate.balance, 0.025 ether);
    }

    function test_buyExternalListing_rejectsFeeAuthorizationBeyondMaximumWindow() public {
        uint256 deadline = block.timestamp + subject.MAX_AUTHORIZATION_WINDOW() + 1;
        bytes memory signature =
            _feeAuthFor(buyer, affiliate, keccak256(abi.encode(externalOrderHash)), deadline, FEE_AUTHORIZER_PK);

        _prank(buyer);
        vm.expectRevert(InvalidFeeAuthorization.selector);
        subject.buyExternalListing{value: 1.05 ether}(
            seaportFulfillCalldata, 1 ether, affiliate, externalOrderHash, deadline, signature, 500
        );
    }

    function test_buyExternalListing_signatureWithNoAffiliateReverts() public {
        _prank(buyer);
        vm.expectRevert(InvalidFeeAuthorization.selector);
        subject.buyExternalListing{value: 1.05 ether}(
            seaportFulfillCalldata,
            1 ether,
            address(0),
            externalOrderHash,
            _feeAuthDeadline(),
            _feeAuthSig(buyer, affiliate, keccak256(abi.encode(externalOrderHash))),
            500
        );
    }

    function test_setFeeAuthorizer_rotatesAndOldSignaturesStopWorking() public {
        address newAuthorizer = vm.addr(0xB0B);

        _prank(owner);
        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.FeeAuthorizerUpdated(feeAuthorizer, newAuthorizer);
        subject.setFeeAuthorizer(newAuthorizer);
        assertEq(subject.feeAuthorizer(), newAuthorizer);

        bytes memory staleSig = _feeAuthFor(
            buyer, affiliate, keccak256(abi.encode(externalOrderHash)), _feeAuthDeadline(), FEE_AUTHORIZER_PK
        );
        _prank(buyer);
        vm.expectRevert(InvalidFeeAuthorization.selector);
        subject.buyExternalListing{value: 1.05 ether}(
            seaportFulfillCalldata, 1 ether, affiliate, externalOrderHash, _feeAuthDeadline(), staleSig, 500
        );

        bytes memory freshSig =
            _feeAuthFor(buyer, affiliate, keccak256(abi.encode(externalOrderHash)), _feeAuthDeadline(), 0xB0B);
        _prank(buyer);
        subject.buyExternalListing{value: 1.05 ether}(
            seaportFulfillCalldata, 1 ether, affiliate, externalOrderHash, _feeAuthDeadline(), freshSig, 500
        );
        assertEq(affiliate.balance, 0.025 ether);
    }

    function test_setFeeAuthorizer_revertsForNonOwner() public {
        _prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, buyer));
        subject.setFeeAuthorizer(vm.addr(0xB0B));
    }

    function test_setFeeAuthorizer_revertsForZeroAddress() public {
        _prank(owner);
        vm.expectRevert(InvalidFeeAuthorizer.selector);
        subject.setFeeAuthorizer(address(0));
    }

    function test_setFeeSplitBps_requiresOwnerAndValidBasisPoints() public {
        _prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, buyer));
        subject.setFeeSplitBps(3000);

        _prank(owner);
        vm.expectRevert(InvalidFeeSplitBps.selector);
        subject.setFeeSplitBps(10001);
        vm.expectRevert(InvalidFeeSplitBps.selector);
        subject.setFeeSplitBps(type(uint256).max);
        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.FeeSplitBpsUpdated(5000, 3000);
        subject.setFeeSplitBps(3000);
        assertEq(subject.feeSplitBps(), 3000);
        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.FeeSplitBpsUpdated(3000, 0);
        subject.setFeeSplitBps(0);
        assertEq(subject.feeSplitBps(), 0);
        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.FeeSplitBpsUpdated(0, 10000);
        subject.setFeeSplitBps(10000);
        assertEq(subject.feeSplitBps(), 10000);
    }

    function test_buyExternalListing_configurableFeeSplit_extremesAndAffiliatePrecedence() public {
        uint256[3] memory splits = [uint256(0), 3000, 10000];
        uint256 salt = 3;
        for (uint256 i; i < splits.length; i++) {
            for (uint8 recipientMode; recipientMode < 3; recipientMode++) {
                _assertConfiguredListingSettlement(splits[i], 1 ether, recipientMode, false, salt++);
                _assertConfiguredListingSettlement(splits[i], 1 ether, recipientMode, true, salt++);
            }
        }
    }

    function testFuzz_buyExternalListing_configurableFeeSplit_conservesPayment(
        uint256 split,
        uint256 price,
        uint8 recipientMode,
        bool useErc20
    ) public {
        _assertConfiguredListingSettlement(
            bound(split, 0, 10000), bound(price, 20, 2 ether), uint8(bound(recipientMode, 0, 2)), useErc20, 3
        );
    }

    function _assertConfiguredListingSettlement(
        uint256 split,
        uint256 price,
        uint8 recipientMode,
        bool useErc20,
        uint256 salt
    ) internal {
        _prank(owner);
        subject.setFeeSplitBps(split);
        _prank(address(this));
        scatterCollectionRegistry.setRewardsOverride(COLLECTION_TWO, recipientMode == 0 ? address(0) : rewardsRecipient);
        AdvancedOrder memory order = useErc20
            ? _erc20SweepOrder(address(0x1002), salt, price, address(token))
            : _sweepOrder(address(0x1002), salt, price);
        bytes32 orderHash = mockSeaport.getOrderHash(_toOrderComponents(order.parameters));
        mockSeaport.setOrderHashToFill(orderHash);
        if (useErc20) mockSeaport.setConsumeToken(address(token), price);
        else mockSeaport.setConsumeToken(address(0), 0);
        address fillAffiliate = recipientMode == 2 ? affiliate : address(0);
        bytes memory signature =
            recipientMode == 2 ? _feeAuthSig(buyer, fillAffiliate, keccak256(abi.encode(orderHash))) : bytes("");
        uint256 buyerBefore = useErc20 ? token.balanceOf(buyer) : buyer.balance;
        uint256 platformBefore = useErc20 ? token.balanceOf(PLATFORM) : PLATFORM.balance;
        uint256 rewardsBefore = useErc20 ? token.balanceOf(rewardsRecipient) : rewardsRecipient.balance;
        uint256 affiliateBefore = useErc20 ? token.balanceOf(affiliate) : affiliate.balance;
        uint256 seaportBefore = useErc20 ? token.balanceOf(SEAPORT) : SEAPORT.balance;
        uint256 fee = price * 500 / 10000;
        _prank(buyer);
        if (useErc20) {
            subject.buyExternalListingERC20(
                _seaportFulfillAdvancedCalldata(order),
                address(token),
                price,
                fillAffiliate,
                orderHash,
                recipientMode == 2 ? _feeAuthDeadline() : 0,
                signature,
                500
            );
        } else {
            subject.buyExternalListing{value: price + fee}(
                _seaportFulfillAdvancedCalldata(order),
                price,
                fillAffiliate,
                orderHash,
                recipientMode == 2 ? _feeAuthDeadline() : 0,
                signature,
                500
            );
        }
        uint256 platformFee = recipientMode == 0 ? fee : fee * split / 10000;
        assertEq(buyerBefore - (useErc20 ? token.balanceOf(buyer) : buyer.balance), price + fee);
        assertEq((useErc20 ? token.balanceOf(SEAPORT) : SEAPORT.balance) - seaportBefore, price);
        assertEq((useErc20 ? token.balanceOf(PLATFORM) : PLATFORM.balance) - platformBefore, platformFee);
        assertEq(
            (useErc20 ? token.balanceOf(rewardsRecipient) : rewardsRecipient.balance) - rewardsBefore,
            recipientMode == 1 ? fee - platformFee : 0
        );
        assertEq(
            (useErc20 ? token.balanceOf(affiliate) : affiliate.balance) - affiliateBefore,
            recipientMode == 2 ? fee - platformFee : 0
        );
        assertEq(token.balanceOf(address(subject)), 0);
        assertEq(address(subject).balance, 1 ether);
    }

    function test_buyExternalListing_usesFeeSplitFrozenBeforeSeaportCall() public {
        _assertListingFeeSplitSnapshot(false);
    }

    function test_buyExternalListingERC20_usesFeeSplitFrozenBeforeSeaportCall() public {
        _assertListingFeeSplitSnapshot(true);
    }

    function _assertListingFeeSplitSnapshot(bool useErc20) internal {
        scatterCollectionRegistry.setRewardsOverride(COLLECTION_ONE, rewardsRecipient);
        _prank(owner);
        subject.setFeeSplitBps(3000);
        subject.transferOwnership(address(mockSeaport));
        _prank(address(mockSeaport));
        subject.acceptOwnership();
        mockSeaport.setFeeSplitBpsDuringFill(subject, 10000);

        _prank(buyer);
        if (useErc20) {
            mockSeaport.setOrderHashToFill(externalErc20OrderHash);
            mockSeaport.setConsumeToken(address(token), 1 ether);
            subject.buyExternalListingERC20(
                seaportFulfillErc20Calldata, address(token), 1 ether, address(0), externalErc20OrderHash, 0, "", 500
            );
        } else {
            subject.buyExternalListing{value: 1.05 ether}(
                seaportFulfillCalldata, 1 ether, address(0), externalOrderHash, 0, "", 500
            );
        }

        assertEq(subject.feeSplitBps(), 10000);
        assertEq(useErc20 ? token.balanceOf(PLATFORM) : PLATFORM.balance, 0.015 ether);
        assertEq(useErc20 ? token.balanceOf(rewardsRecipient) : rewardsRecipient.balance, 0.035 ether);
        assertEq(token.balanceOf(address(subject)), 0);
        assertEq(address(subject).balance, 1 ether);
    }

    function test_sweepMixed_usesFeeSplitFrozenBeforeSeaportCall() public {
        _assertSweepFeeSplitSnapshot(false);
    }

    function test_sweepERC20_usesFeeSplitFrozenBeforeSeaportCall() public {
        _assertSweepFeeSplitSnapshot(true);
    }

    function _assertSweepFeeSplitSnapshot(bool useErc20) internal {
        scatterCollectionRegistry.setRewardsOverride(COLLECTION_ONE, rewardsRecipient);
        scatterCollectionRegistry.setRewardsOverride(COLLECTION_TWO, rewardsRecipient);
        _prank(owner);
        subject.setFeeSplitBps(3000);
        subject.transferOwnership(address(mockSeaport));
        _prank(address(mockSeaport));
        subject.acceptOwnership();
        mockSeaport.setFeeSplitBpsDuringFill(subject, 10000);
        AdvancedOrder[] memory orders = useErc20 ? _erc20SweepOrders(address(token)) : _sweepOrders();
        mockSeaport.setAvailableOrderHashes(_orderHashes(orders));
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, true));
        uint256[] memory indexes = new uint256[](2);
        indexes[1] = 1;
        _prank(buyer);
        if (useErc20) {
            mockSeaport.setConsumeToken(address(token), 1.6 ether);
            subject.sweepERC20(_sweepCalldata(orders), address(token), 1.6 ether, indexes, address(0), 0, "", 500);
        } else {
            subject.sweepMixed{value: 1.68 ether}(
                _sweepCalldata(orders), 1.6 ether, indexes, _emptyAddresses(), _emptyUints(), address(0), 0, "", 500
            );
        }
        assertEq(subject.feeSplitBps(), 10000);
        assertEq(useErc20 ? token.balanceOf(PLATFORM) : PLATFORM.balance, 0.024 ether);
        assertEq(useErc20 ? token.balanceOf(rewardsRecipient) : rewardsRecipient.balance, 0.056 ether);
        assertEq(useErc20 ? token.balanceOf(buyer) : buyer.balance, 8.32 ether);
        assertEq(token.balanceOf(address(subject)), 0);
        assertEq(address(subject).balance, 1 ether);
    }

    function test_setFeeBps_updatesFeeCharged() public {
        _prank(owner);
        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.FeeBpsUpdated(500, 1000);
        subject.setFeeBps(1000);

        _prank(buyer);
        subject.buyExternalListing{value: 1.1 ether}(
            seaportFulfillCalldata, 1 ether, address(0), externalOrderHash, 0, "", 1000
        );

        assertEq(subject.feeBps(), 1000);
        assertEq(subject.PLATFORM().balance, 0.1 ether);
    }

    function test_feeLimitAppliesToEveryEntryPoint() public {
        _prank(owner);
        subject.setFeeBps(501);

        _prank(buyer);
        bytes memory expectedError = abi.encodeWithSelector(FeeBpsExceedsLimit.selector, 501, 500);

        vm.expectRevert(expectedError);
        subject.buyExternalListing("", 0, address(0), bytes32(0), 0, "", 500);

        vm.expectRevert(expectedError);
        subject.buyExternalListingERC20("", address(token), 0, address(0), bytes32(0), 0, "", 500);

        vm.expectRevert(expectedError);
        subject.sweepMixed("", 0, new uint256[](0), new address[](0), new uint256[](0), address(0), 0, "", 500);

        vm.expectRevert(expectedError);
        subject.sweepERC20("", address(token), 0, new uint256[](0), address(0), 0, "", 500);
    }

    function test_buyExternalListing_usesFeeRateValidatedBeforeSeaportCall() public {
        _prank(owner);
        subject.transferOwnership(address(mockSeaport));
        _prank(address(mockSeaport));
        subject.acceptOwnership();
        mockSeaport.setFeeBpsDuringFill(subject, 1000);
        uint256 platformBalanceBefore = subject.PLATFORM().balance;

        _prank(buyer);
        subject.buyExternalListing{value: 1.05 ether}(
            seaportFulfillCalldata, 1 ether, address(0), externalOrderHash, 0, "", 500
        );

        assertEq(subject.feeBps(), 1000);
        assertEq(subject.PLATFORM().balance - platformBalanceBefore, 0.05 ether);
        assertEq(address(subject).balance, 1 ether);
    }

    function test_setFeeBps_revertsForNonOwner() public {
        _prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, buyer));
        subject.setFeeBps(1000);
    }

    function test_setFeeBps_revertsAboveMaximum() public {
        _prank(owner);
        vm.expectRevert(InvalidFeeBps.selector);
        subject.setFeeBps(5001);
    }

    function test_setFeeBps_chargesTheMaximumRate() public {
        _prank(owner);
        subject.setFeeBps(5000);
        _prank(buyer);
        subject.buyExternalListing{value: 1.5 ether}(
            seaportFulfillCalldata, 1 ether, address(0), externalOrderHash, 0, "", 5000
        );
        assertEq(buyer.balance, 8.5 ether);
        assertEq(PLATFORM.balance, 0.5 ether);
        assertEq(SEAPORT.balance, 1 ether);
    }

    function test_buyExternalListing_failsWhenListingPriceIsZero() public {
        _prank(buyer);

        vm.expectRevert(InvalidListingAmount.selector);
        subject.buyExternalListing{value: 1 ether}(
            seaportFulfillCalldata,
            0, // listingPrice
            address(0),
            externalOrderHash,
            0,
            "",
            500
        );
    }

    function test_buyExternalListing_rejectsChangingPrice() public {
        AdvancedOrder memory order = _sweepOrders()[0];
        order.parameters.consideration[0].endAmount = 2 ether;
        bytes32 orderHash = mockSeaport.getOrderHash(_toOrderComponents(order.parameters));

        _prank(buyer);
        vm.expectRevert(VariableSweepConsiderationAmount.selector);
        subject.buyExternalListing{value: 1.05 ether}(
            _seaportFulfillAdvancedCalldata(order), 1 ether, address(0), orderHash, 0, "", 500
        );
    }

    function test_buyExternalListing_failsWhenInsufficientPayment() public {
        _prank(buyer);

        vm.expectRevert(InsufficientPayment.selector);
        subject.buyExternalListing{value: 1 ether}(
            seaportFulfillCalldata,
            1 ether, // listingPrice
            address(0),
            externalOrderHash,
            0,
            "",
            500
        );
    }

    function test_buyExternalListing_failsWhenSeaportReverts() public {
        mockSeaport.setShouldRevert(true);

        _prank(buyer);
        vm.expectRevert(SeaportCallFailed.selector);
        subject.buyExternalListing{value: 1.05 ether}(
            seaportFulfillCalldata,
            1 ether, // listingPrice
            address(0),
            externalOrderHash,
            0,
            "",
            500
        );
    }

    function test_buyExternalListing_failsWhenSeaportReturnsFalse() public {
        mockSeaport.setShouldReturnFalse(true);

        _prank(buyer);
        vm.expectRevert(SeaportCallFailed.selector);
        subject.buyExternalListing{value: 1.05 ether}(
            seaportFulfillCalldata,
            1 ether, // listingPrice
            address(0),
            externalOrderHash,
            0,
            "",
            500
        );
    }

    function test_buyExternalListing_failsWhenSeaportReturnsBadData() public {
        mockSeaport.setShouldReturnBadData(true);

        _prank(buyer);
        vm.expectRevert(SeaportCallFailed.selector);
        subject.buyExternalListing{value: 1.05 ether}(
            seaportFulfillCalldata,
            1 ether, // listingPrice
            address(0),
            externalOrderHash,
            0,
            "",
            500
        );
    }

    function test_buyExternalListing_revertsWhenSeaportReturnsTrueWithoutFillingOrder() public {
        mockSeaport.setShouldFillOrder(false);

        _prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(OrderNotFilled.selector, externalOrderHash));
        subject.buyExternalListing{value: 1.05 ether}(
            seaportFulfillCalldata, 1 ether, address(0), externalOrderHash, 0, "", 500
        );
    }

    function test_buyExternalListing_revertsWhenDeclaredOrderHashDoesNotMatchFilledOrder() public {
        mockSeaport.setOrderHashToFill(keccak256("different-order"));

        _prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(OrderNotFilled.selector, externalOrderHash));
        subject.buyExternalListing{value: 1.05 ether}(
            seaportFulfillCalldata, 1 ether, address(0), externalOrderHash, 0, "", 500
        );
    }

    function test_buyExternalListing_failsWhenFeeTransferFails() public {
        RejectEther rejecter = new RejectEther();
        vm.etch(subject.PLATFORM(), address(rejecter).code);

        _prank(buyer);
        vm.expectRevert(FeeTransferFailed.selector);
        subject.buyExternalListing{value: 1.05 ether}(
            seaportFulfillCalldata,
            1 ether, // listingPrice
            address(0),
            externalOrderHash,
            0,
            "",
            500
        );
    }

    function test_buyExternalListing_failsWhenRefundFails() public {
        RejectEther rejecter = new RejectEther();
        vm.deal(address(rejecter), 2 ether);

        _prank(address(rejecter));
        vm.expectRevert(RefundFailed.selector);
        subject.buyExternalListing{value: 1.1 ether}(
            seaportFulfillCalldata,
            1 ether, // listingPrice
            address(0),
            externalOrderHash,
            0,
            "",
            500
        );
    }

    function test_buyExternalListing_failsWhenPaused() public {
        _prank(owner);
        subject.pause();

        _prank(buyer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        subject.buyExternalListing{value: 1.05 ether}(
            seaportFulfillCalldata,
            1 ether, // listingPrice
            address(0),
            externalOrderHash,
            0,
            "",
            500
        );
    }

    function test_buyExternalListingERC20_refundsUnspentListingAmountAndFee() public {
        token.mint(address(subject), 3 ether);
        (bytes memory fulfillCalldata, bytes32 orderHash) = _prepareErc20Listing(address(token), 0.4 ether);
        mockSeaport.setConsumeToken(address(token), 0.4 ether);
        _prank(buyer);

        subject.buyExternalListingERC20(
            fulfillCalldata,
            address(token), // erc20
            1 ether,
            address(0),
            orderHash,
            0,
            "",
            500
        );

        // Seaport spends 0.4 ether, so the fee is 0.02 ether and the buyer's
        // total cost is 0.42 ether. The rest of the prefunding is refunded.
        assertEq(token.balanceOf(buyer), 9.58 ether);
        assertEq(token.balanceOf(subject.PLATFORM()), 0.02 ether);
        assertEq(token.balanceOf(subject.SEAPORT()), 0.4 ether);
        assertEq(token.balanceOf(address(subject)), 3 ether);
        assertEq(token.allowance(address(subject), subject.SEAPORT()), 0);
    }

    function test_buyExternalListingERC20_settlesAndClearsAllowance() public {
        mockSeaport.setOrderHashToFill(externalErc20OrderHash);
        mockSeaport.setConsumeToken(address(token), 1 ether);

        _prank(buyer);
        subject.buyExternalListingERC20(
            seaportFulfillErc20Calldata, address(token), 1 ether, address(0), externalErc20OrderHash, 0, "", 500
        );

        assertEq(token.balanceOf(buyer), 8.95 ether);
        assertEq(token.balanceOf(address(subject)), 0);
        assertEq(token.balanceOf(SEAPORT), 1 ether);
        assertEq(token.balanceOf(PLATFORM), 0.05 ether);
        assertEq(token.allowance(address(subject), SEAPORT), 0);
        assertEq(token.balanceOf(rewardsRecipient), 0);
        assertEq(token.balanceOf(affiliate), 0);
    }

    function test_buyExternalListingERC20_distributesPlatformAndRewardsFees() public {
        mockSeaport.setOrderHashToFill(externalErc20OrderHash);
        mockSeaport.setConsumeToken(address(token), 1 ether);
        _prank(address(this));
        scatterCollectionRegistry.setRewardsOverride(COLLECTION_ONE, rewardsRecipient);
        _prank(buyer);

        subject.buyExternalListingERC20(
            seaportFulfillErc20Calldata,
            address(token), // erc20
            1 ether,
            address(0),
            externalErc20OrderHash,
            0,
            "",
            500
        );

        // Fee breakdown: 1 ether listing * 5% = 0.05 ether.
        // Platform/rewards split 50/50 = 0.025 each.
        assertEq(token.balanceOf(subject.PLATFORM()), 0.025 ether);
        assertEq(token.balanceOf(rewardsRecipient), 0.025 ether);
        assertEq(token.balanceOf(affiliate), 0);
    }

    function test_buyExternalListingERC20_distributesPlatformAndAffiliateFees() public {
        mockSeaport.setOrderHashToFill(externalErc20OrderHash);
        mockSeaport.setConsumeToken(address(token), 1 ether);
        _prank(buyer);

        subject.buyExternalListingERC20(
            seaportFulfillErc20Calldata,
            address(token), // erc20
            1 ether,
            affiliate,
            externalErc20OrderHash,
            _feeAuthDeadline(),
            _feeAuthSig(buyer, affiliate, keccak256(abi.encode(externalErc20OrderHash))),
            500
        );

        // Fee breakdown: 1 ether listing * 5% = 0.05 ether.
        // No rewards, platform/affiliate split 50/50 = 0.025 each.
        assertEq(token.balanceOf(subject.PLATFORM()), 0.025 ether);
        assertEq(token.balanceOf(rewardsRecipient), 0);
        assertEq(token.balanceOf(affiliate), 0.025 ether);
    }

    function test_buyExternalListingERC20_affiliateTakesPriorityOverRegistryRewards() public {
        mockSeaport.setOrderHashToFill(externalErc20OrderHash);
        mockSeaport.setConsumeToken(address(token), 1 ether);
        _prank(address(this));
        scatterCollectionRegistry.setRewardsOverride(COLLECTION_ONE, rewardsRecipient);
        _prank(buyer);

        subject.buyExternalListingERC20(
            seaportFulfillErc20Calldata,
            address(token), // erc20
            1 ether,
            affiliate,
            externalErc20OrderHash,
            _feeAuthDeadline(),
            _feeAuthSig(buyer, affiliate, keccak256(abi.encode(externalErc20OrderHash))),
            500
        );

        // Affiliate takes priority over rewards attribution.
        assertEq(token.balanceOf(subject.PLATFORM()), 0.025 ether);
        assertEq(token.balanceOf(affiliate), 0.025 ether);
        assertEq(token.balanceOf(rewardsRecipient), 0);
    }

    function test_buyExternalListingERC20_emitsExternalListingFilledEvent() public {
        mockSeaport.setOrderHashToFill(externalErc20OrderHash);
        bytes32 orderHash = externalErc20OrderHash;
        mockSeaport.setConsumeToken(address(token), 1 ether);

        _prank(buyer);
        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.ExternalListingFilled(
            buyer, // buyer
            address(token), // currency
            orderHash,
            1 ether, // feeBaseAmount
            0.05 ether, // scatterFee
            affiliate, // affiliate
            address(0), // rewardsRecipient
            0.025 ether, // platformAmount
            0, // rewardsAmount
            0.025 ether // affiliateAmount
        );
        subject.buyExternalListingERC20(
            seaportFulfillErc20Calldata,
            address(token), // erc20
            1 ether,
            affiliate,
            externalErc20OrderHash,
            _feeAuthDeadline(),
            _feeAuthSig(buyer, affiliate, keccak256(abi.encode(externalErc20OrderHash))),
            500
        );
    }

    function test_buyExternalListingERC20_failsWhenListingAmountIsZero() public {
        mockSeaport.setOrderHashToFill(externalErc20OrderHash);
        _prank(buyer);

        vm.expectRevert(InvalidListingAmount.selector);
        subject.buyExternalListingERC20(
            seaportFulfillErc20Calldata,
            address(token), // erc20
            0,
            address(0),
            externalErc20OrderHash,
            0,
            "",
            500
        );
    }

    function test_buyExternalListingERC20_rejectsChangingPrice() public {
        AdvancedOrder memory order = _erc20SweepOrder(address(0x1001), 1, 1 ether, address(token));
        order.parameters.consideration[0].endAmount = 2 ether;
        bytes32 orderHash = mockSeaport.getOrderHash(_toOrderComponents(order.parameters));

        _prank(buyer);
        vm.expectRevert(VariableSweepConsiderationAmount.selector);
        subject.buyExternalListingERC20(
            _seaportFulfillAdvancedCalldata(order), address(token), 1 ether, address(0), orderHash, 0, "", 500
        );
    }

    function test_buyExternalListingERC20_failsWhenPullFundsTransferReturnsFalse() public {
        IERC20 badToken = IERC20(new ReturnFalseERC20());
        (bytes memory fulfillCalldata, bytes32 orderHash) = _prepareErc20Listing(address(badToken), 1 ether);

        _prank(buyer);
        vm.expectPartialRevert(TokenTransferrerErrors.BadReturnValueFromERC20OnTransfer.selector);
        subject.buyExternalListingERC20(
            fulfillCalldata,
            address(badToken), // erc20
            1 ether,
            address(0),
            orderHash,
            0,
            "",
            500
        );
    }

    function test_buyExternalListingERC20_failsWhenApproveSeaportReturnsFalse() public {
        IERC20 badToken = IERC20(new ApproveFalseERC20());
        (bytes memory fulfillCalldata, bytes32 orderHash) = _prepareErc20Listing(address(badToken), 1 ether);

        _prank(buyer);
        vm.expectPartialRevert(SafeERC20.SafeERC20FailedOperation.selector);
        subject.buyExternalListingERC20(
            fulfillCalldata,
            address(badToken), // erc20
            1 ether,
            address(0),
            orderHash,
            0,
            "",
            500
        );
    }

    function test_buyExternalListingERC20_failsWhenSeaportReverts() public {
        mockSeaport.setOrderHashToFill(externalErc20OrderHash);
        mockSeaport.setShouldRevert(true);

        _prank(buyer);
        vm.expectRevert(SeaportCallFailed.selector);
        subject.buyExternalListingERC20(
            seaportFulfillErc20Calldata,
            address(token), // erc20
            1 ether,
            address(0),
            externalErc20OrderHash,
            0,
            "",
            500
        );
    }

    function test_buyExternalListingERC20_failsWhenSeaportReturnsFalse() public {
        mockSeaport.setOrderHashToFill(externalErc20OrderHash);
        mockSeaport.setShouldReturnFalse(true);

        _prank(buyer);
        vm.expectRevert(SeaportCallFailed.selector);
        subject.buyExternalListingERC20(
            seaportFulfillErc20Calldata,
            address(token), // erc20
            1 ether,
            address(0),
            externalErc20OrderHash,
            0,
            "",
            500
        );
    }

    function test_buyExternalListingERC20_failsWhenSeaportReturnsBadData() public {
        mockSeaport.setOrderHashToFill(externalErc20OrderHash);
        mockSeaport.setShouldReturnBadData(true);

        _prank(buyer);
        vm.expectRevert(SeaportCallFailed.selector);
        subject.buyExternalListingERC20(
            seaportFulfillErc20Calldata,
            address(token), // erc20
            1 ether,
            address(0),
            externalErc20OrderHash,
            0,
            "",
            500
        );
    }

    function test_buyExternalListingERC20_failsWhenFeeTransferFails() public {
        IERC20 badToken = IERC20(new TransferFalseAfterPullERC20());
        (bytes memory fulfillCalldata, bytes32 orderHash) = _prepareErc20Listing(address(badToken), 1 ether);

        _prank(buyer);
        vm.expectPartialRevert(SafeERC20.SafeERC20FailedOperation.selector);
        subject.buyExternalListingERC20(
            fulfillCalldata,
            address(badToken), // erc20
            1 ether,
            address(0),
            orderHash,
            0,
            "",
            500
        );
    }

    function test_buyExternalListingERC20_failsWhenPaused() public {
        mockSeaport.setOrderHashToFill(externalErc20OrderHash);
        _prank(owner);
        subject.pause();

        _prank(buyer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        subject.buyExternalListingERC20(
            seaportFulfillErc20Calldata,
            address(token), // erc20
            1 ether,
            address(0),
            externalErc20OrderHash,
            0,
            "",
            500
        );
    }

    function test_sweepMixed_revertsWhenCalldataSelectorIsNotFulfillAvailableAdvancedOrders() public {
        _prank(buyer);
        vm.expectRevert(InvalidSweepCalldataSelector.selector);
        subject.sweepMixed(hex"aabbccdd", 0, _emptyUints(), _emptyAddresses(), _emptyUints(), address(0), 0, "", 500);
    }

    function test_sweepMixed_pullsRefundsAndResetsAllowanceForMultipleErc20s() public {
        token.mint(address(subject), 3 ether);
        token2.mint(address(subject), 7 ether);
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(false, false));
        mockSeaport.setConsumeToken(address(token), 0.4 ether);
        address[] memory erc20s = new address[](2);
        erc20s[0] = address(token);
        erc20s[1] = address(token2);
        uint256[] memory erc20Amounts = new uint256[](2);
        erc20Amounts[0] = 1 ether;
        erc20Amounts[1] = 2 ether;

        _prank(buyer);
        subject.sweepMixed{value: 1 ether}(
            seaportSweepCalldata,
            1 ether, // seaportTotalNativeValue
            _externalSweepFills(),
            erc20s,
            erc20Amounts,
            address(0),
            0,
            "",
            500
        );

        assertEq(token.balanceOf(buyer), 9.6 ether);
        assertEq(token2.balanceOf(buyer), 10 ether);
        assertEq(token.balanceOf(subject.SEAPORT()), 0.4 ether);
        assertEq(token2.balanceOf(subject.SEAPORT()), 0);
        assertEq(token.balanceOf(address(subject)), 3 ether);
        assertEq(token2.balanceOf(address(subject)), 7 ether);
        assertEq(token.allowance(address(subject), subject.SEAPORT()), 0);
        assertEq(token2.allowance(address(subject), subject.SEAPORT()), 0);
    }

    function test_sweepERC20_settlesSuccessfulFillsInOneCurrency() public {
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));
        mockSeaport.setAvailableOrderHashes(_orderHashes(orders));
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, true));
        mockSeaport.setConsumeToken(address(token), 1.6 ether);

        _prank(buyer);
        subject.sweepERC20(
            _sweepCalldata(orders), address(token), 1.6 ether, _externalSweepFills(), address(0), 0, "", 500
        );

        assertEq(token.balanceOf(buyer), 8.32 ether);
        assertEq(token.balanceOf(subject.PLATFORM()), 0.08 ether);
        assertEq(token.balanceOf(subject.SEAPORT()), 1.6 ether);
        assertEq(token.balanceOf(address(subject)), 0);
        assertEq(token.allowance(address(subject), subject.SEAPORT()), 0);
        assertEq(token.balanceOf(rewardsRecipient), 0);
        assertEq(token.balanceOf(affiliate), 0);
    }

    function test_sweepERC20_chargesOnlySuccessfulFillAndRefundsRemainder() public {
        token.mint(address(subject), 3 ether);
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));
        mockSeaport.setAvailableOrderHashes(_orderHashes(orders));
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, false));
        mockSeaport.setConsumeToken(address(token), 1 ether);

        _prank(buyer);
        subject.sweepERC20(
            _sweepCalldata(orders), address(token), 1.6 ether, _externalSweepFills(), address(0), 0, "", 500
        );

        assertEq(token.balanceOf(buyer), 8.95 ether);
        assertEq(token.balanceOf(subject.PLATFORM()), 0.05 ether);
        assertEq(token.balanceOf(subject.SEAPORT()), 1 ether);
        assertEq(token.balanceOf(address(subject)), 3 ether);
        assertEq(token.allowance(address(subject), subject.SEAPORT()), 0);
    }

    function test_sweepERC20_chargesFeeOnActualRemainderOfFullRequest() public {
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));
        orders[0].parameters.orderType = OrderType.PARTIAL_OPEN;
        bytes32[] memory orderHashes = _orderHashes(orders);
        mockSeaport.setAvailableOrderHashes(orderHashes);
        mockSeaport.setOrderStatus(orderHashes[0], 9, 10);
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, false));
        mockSeaport.setConsumeToken(address(token), 0.1 ether);

        _prank(buyer);
        subject.sweepERC20(
            _sweepCalldata(orders), address(token), 1.6 ether, _externalSweepFills(), address(0), 0, "", 500
        );

        assertEq(token.balanceOf(buyer), 9.895 ether);
        assertEq(token.balanceOf(subject.PLATFORM()), 0.005 ether);
        assertEq(token.balanceOf(subject.SEAPORT()), 0.1 ether);
        assertEq(token.balanceOf(address(subject)), 0);
    }

    function test_sweepERC20_rejectsMixedCurrencies() public {
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));
        orders[1].parameters.consideration = _erc20Consideration(0.6 ether, address(0x1002), address(token2));

        _prank(buyer);
        vm.expectRevert(UnsupportedSweepCurrency.selector);
        subject.sweepERC20(
            _sweepCalldata(orders), address(token), 1.6 ether, _externalSweepFills(), address(0), 0, "", 500
        );
    }

    function test_sweepERC20_rejectsFeeChargedContractOrder() public {
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));
        orders[0].parameters.orderType = OrderType.CONTRACT;

        _prank(buyer);
        vm.expectRevert(UnsupportedContractOrder.selector);
        subject.sweepERC20(
            _sweepCalldata(orders), address(token), 1.6 ether, _externalSweepFills(), address(0), 0, "", 500
        );
    }

    function test_sweepERC20_skipsContractOrderFeeAndChargesExternalOrder() public {
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));
        orders[0].parameters.orderType = OrderType.CONTRACT;
        mockSeaport.setAvailableOrderHashes(_orderHashes(orders));
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, true));
        mockSeaport.setConsumeToken(address(token), 1.6 ether);

        _prank(buyer);
        subject.sweepERC20(_sweepCalldata(orders), address(token), 1.6 ether, _singleUint(1), address(0), 0, "", 500);

        assertEq(token.balanceOf(buyer), 8.37 ether);
        assertEq(token.balanceOf(subject.PLATFORM()), 0.03 ether);
        assertEq(token.balanceOf(subject.SEAPORT()), 1.6 ether);
        assertEq(token.balanceOf(address(subject)), 0);
    }

    function test_sweepERC20_rejectsOmittedExternalOrderIndex() public {
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));

        _prank(buyer);
        vm.expectRevert(InvalidSweepOrderIndex.selector);
        subject.sweepERC20(_sweepCalldata(orders), address(token), 1.6 ether, _singleUint(0), address(0), 0, "", 500);
    }

    function test_sweepERC20_revertsWhenCalldataSelectorIsNotFulfillAvailableAdvancedOrders() public {
        _prank(buyer);
        vm.expectRevert(InvalidSweepCalldataSelector.selector);
        subject.sweepERC20(hex"aabbccdd", address(token), 1.6 ether, _externalSweepFills(), address(0), 0, "", 500);
    }

    function test_sweepERC20_rejectsZeroAndRouterRecipients() public {
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));
        address[2] memory recipients = [address(0), address(subject)];
        for (uint256 i = 0; i < recipients.length; i++) {
            _prank(buyer);
            vm.expectRevert(InvalidSweepRecipient.selector);
            subject.sweepERC20(
                _sweepCalldata(orders, recipients[i]),
                address(token),
                1.6 ether,
                _externalSweepFills(),
                address(0),
                0,
                "",
                500
            );
        }
    }

    function test_sweepERC20_rejectsFulfillerConduit() public {
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));

        _prank(buyer);
        vm.expectRevert(InvalidFulfillerConduitKey.selector);
        subject.sweepERC20(
            _sweepCalldata(orders, bytes32(uint256(1)), buyer),
            address(token),
            1.6 ether,
            _externalSweepFills(),
            address(0),
            0,
            "",
            500
        );
    }

    function test_sweepERC20_failsWhenCurrencyIsZeroAddress() public {
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));

        _prank(buyer);
        vm.expectRevert(InvalidListingAmount.selector);
        subject.sweepERC20(_sweepCalldata(orders), address(0), 1.6 ether, _externalSweepFills(), address(0), 0, "", 500);
    }

    function test_sweepERC20_failsWhenSeaportAmountIsZero() public {
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));

        _prank(buyer);
        vm.expectRevert(InvalidListingAmount.selector);
        subject.sweepERC20(_sweepCalldata(orders), address(token), 0, _externalSweepFills(), address(0), 0, "", 500);
    }

    function test_sweepERC20_rejectsDuplicateOrderIndex() public {
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));
        uint256[] memory fills = new uint256[](2);
        fills[0] = 0;
        fills[1] = 0;

        _prank(buyer);
        vm.expectRevert(InvalidSweepOrderIndex.selector);
        subject.sweepERC20(_sweepCalldata(orders), address(token), 1.6 ether, fills, address(0), 0, "", 500);
    }

    function test_sweepERC20_rejectsUnsortedOrderIndex() public {
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));
        uint256[] memory fills = new uint256[](2);
        fills[0] = 1;
        fills[1] = 0;

        _prank(buyer);
        vm.expectRevert(InvalidSweepOrderIndex.selector);
        subject.sweepERC20(_sweepCalldata(orders), address(token), 1.6 ether, fills, address(0), 0, "", 500);
    }

    function test_sweepERC20_revertsWhenTwoSlotsDeriveSameOrderHash() public {
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));
        orders[1] = orders[0];

        _prank(buyer);
        vm.expectRevert(DuplicateSweepOrderHash.selector);
        subject.sweepERC20(
            _sweepCalldata(orders), address(token), 1.6 ether, _externalSweepFills(), address(0), 0, "", 500
        );
    }

    function test_sweepERC20_revertsWhenOriginalConsiderationCountExceedsLength() public {
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));
        orders[0].parameters.totalOriginalConsiderationItems = 2;

        _prank(buyer);
        vm.expectRevert(InvalidTotalOriginalConsiderationItems.selector);
        subject.sweepERC20(
            _sweepCalldata(orders), address(token), 1.6 ether, _externalSweepFills(), address(0), 0, "", 500
        );
    }

    function test_sweepERC20_revertsWhenFeeChargedOrderIsPricedInNative() public {
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));
        orders[0].parameters.consideration = _nativeConsideration(1 ether, address(0x1001));

        _prank(buyer);
        vm.expectRevert(UnsupportedSweepCurrency.selector);
        subject.sweepERC20(
            _sweepCalldata(orders), address(token), 1.6 ether, _externalSweepFills(), address(0), 0, "", 500
        );
    }

    function test_sweepERC20_revertsWhenFeeChargedOrderMixesErc20Currencies() public {
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));
        ConsiderationItem[] memory consideration = new ConsiderationItem[](2);
        consideration[0] = _erc20Consideration(1 ether, address(0x1001), address(token))[0];
        consideration[1] = _erc20Consideration(1 ether, address(0x1002), address(token2))[0];
        orders[0].parameters.consideration = consideration;
        orders[0].parameters.totalOriginalConsiderationItems = 2;

        _prank(buyer);
        vm.expectRevert(UnsupportedSweepCurrency.selector);
        subject.sweepERC20(
            _sweepCalldata(orders), address(token), 1.6 ether, _externalSweepFills(), address(0), 0, "", 500
        );
    }

    function test_sweepERC20_revertsWhenFeeChargedOrderPriceVariesOverTime() public {
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));
        orders[0].parameters.consideration[0].endAmount = 0.5 ether;

        _prank(buyer);
        vm.expectRevert(VariableSweepConsiderationAmount.selector);
        subject.sweepERC20(
            _sweepCalldata(orders), address(token), 1.6 ether, _externalSweepFills(), address(0), 0, "", 500
        );
    }

    function test_sweepERC20_revertsWhenFeeChargedOrderHasZeroErc20Consideration() public {
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));
        orders[0].parameters.consideration[0].startAmount = 0;
        orders[0].parameters.consideration[0].endAmount = 0;

        _prank(buyer);
        vm.expectRevert(InvalidListingAmount.selector);
        subject.sweepERC20(
            _sweepCalldata(orders), address(token), 1.6 ether, _externalSweepFills(), address(0), 0, "", 500
        );
    }

    function test_sweepERC20_feeBaseSumsEveryErc20ConsiderationItem() public {
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));
        ConsiderationItem[] memory consideration = new ConsiderationItem[](3);
        consideration[0] = _erc20Consideration(0.9 ether, address(0x1001), address(token))[0];
        consideration[1] = _erc20Consideration(0.025 ether, address(0x2001), address(token))[0];
        consideration[2] = _erc20Consideration(0.075 ether, address(0x2002), address(token))[0];
        orders[0].parameters.consideration = consideration;
        orders[0].parameters.totalOriginalConsiderationItems = 3;
        mockSeaport.setAvailableOrderHashes(_orderHashes(orders));
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, false));
        mockSeaport.setConsumeToken(address(token), 1 ether);

        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.ExternalListingFilled(
            buyer,
            address(token),
            _orderHashes(orders)[0],
            1 ether,
            0.05 ether,
            address(0),
            address(0),
            0.05 ether,
            0,
            0
        );

        _prank(buyer);
        subject.sweepERC20(
            _sweepCalldata(orders), address(token), 1.6 ether, _externalSweepFills(), address(0), 0, "", 500
        );
    }

    function test_sweepERC20_feeBaseRoundsEachConsiderationItemOnPartialFills() public {
        uint256 itemAmount = 1 ether + 1;
        uint256 expectedBase = 3 * ((itemAmount + 1) / 2);
        uint256 expectedFee = (expectedBase * 500) / 10000;
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));
        ConsiderationItem[] memory consideration = new ConsiderationItem[](3);
        consideration[0] = _erc20Consideration(itemAmount, address(0x1001), address(token))[0];
        consideration[1] = _erc20Consideration(itemAmount, address(0x2001), address(token))[0];
        consideration[2] = _erc20Consideration(itemAmount, address(0x2002), address(token))[0];
        orders[0].parameters.consideration = consideration;
        orders[0].parameters.totalOriginalConsiderationItems = 3;
        orders[0].numerator = 1;
        orders[0].denominator = 2;
        mockSeaport.setAvailableOrderHashes(_orderHashes(orders));
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, false));
        mockSeaport.setConsumeToken(address(token), expectedBase);

        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.ExternalListingFilled(
            buyer,
            address(token),
            _orderHashes(orders)[0],
            expectedBase,
            expectedFee,
            address(0),
            address(0),
            expectedFee,
            0,
            0
        );

        _prank(buyer);
        subject.sweepERC20(
            _sweepCalldata(orders), address(token), 5 ether, _externalSweepFills(), address(0), 0, "", 500
        );
    }

    function test_sweepERC20_rejectsConsiderationBeyondSignedItems() public {
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));
        ConsiderationItem[] memory consideration = new ConsiderationItem[](2);
        consideration[0] = _erc20Consideration(1 ether, address(0x1001), address(token))[0];
        consideration[1] = _erc20Consideration(5 ether, address(0x2002), address(token))[0];
        orders[0].parameters.consideration = consideration;
        orders[0].parameters.totalOriginalConsiderationItems = 1;

        bytes memory seaportCalldata = _sweepCalldata(orders);
        uint256[] memory feeChargedOrderIndexes = _externalSweepFills();
        uint256 balanceBefore = token.balanceOf(buyer);

        _prank(buyer);
        vm.expectRevert(InvalidTotalOriginalConsiderationItems.selector);
        subject.sweepERC20(seaportCalldata, address(token), 6 ether, feeChargedOrderIndexes, address(0), 0, "", 500);
        assertEq(token.balanceOf(buyer), balanceBefore);
    }

    function test_sweepERC20_revertsWhenCompletedSlotDidNotFillCalldataOrderHash() public {
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, true));
        bytes32[] memory actualOrderHashes = _orderHashes(orders);
        actualOrderHashes[1] = keccak256("different-sweep-order");
        mockSeaport.setAvailableOrderHashes(actualOrderHashes);

        _prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(OrderNotFilled.selector, _orderHashes(orders)[1]));
        subject.sweepERC20(
            _sweepCalldata(orders), address(token), 1.6 ether, _externalSweepFills(), address(0), 0, "", 500
        );
    }

    function test_sweepERC20_revertsWhenCompletedSlotReportsNoFill() public {
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));
        mockSeaport.setAvailableOrderHashes(_orderHashes(orders));
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, false));
        mockSeaport.setShouldFillOrder(false);

        _prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(OrderNotFilled.selector, _orderHashes(orders)[0]));
        subject.sweepERC20(
            _sweepCalldata(orders), address(token), 1.6 ether, _externalSweepFills(), address(0), 0, "", 500
        );
    }

    function test_sweepERC20_distributesPlatformAndRewardsFees() public {
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));
        mockSeaport.setAvailableOrderHashes(_orderHashes(orders));
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, true));
        mockSeaport.setConsumeToken(address(token), 1.6 ether);
        _prank(address(this));
        scatterCollectionRegistry.setRewardsOverride(COLLECTION_ONE, rewardsRecipient);
        scatterCollectionRegistry.setRewardsOverride(COLLECTION_TWO, rewardsRecipient);

        _prank(buyer);
        subject.sweepERC20(
            _sweepCalldata(orders), address(token), 1.6 ether, _externalSweepFills(), address(0), 0, "", 500
        );

        assertEq(token.balanceOf(subject.PLATFORM()), 0.04 ether);
        assertEq(token.balanceOf(rewardsRecipient), 0.04 ether);
        assertEq(token.balanceOf(affiliate), 0);
    }

    function test_sweepERC20_distributesPlatformAndAffiliateFees() public {
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));
        mockSeaport.setAvailableOrderHashes(_orderHashes(orders));
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, true));
        mockSeaport.setConsumeToken(address(token), 1.6 ether);

        _prank(buyer);
        subject.sweepERC20(
            _sweepCalldata(orders),
            address(token),
            1.6 ether,
            _externalSweepFills(),
            affiliate,
            _feeAuthDeadline(),
            _feeAuthFor(
                buyer, affiliate, keccak256(abi.encode(_orderHashes(orders))), _feeAuthDeadline(), FEE_AUTHORIZER_PK
            ),
            500
        );

        assertEq(token.balanceOf(subject.PLATFORM()), 0.04 ether);
        assertEq(token.balanceOf(rewardsRecipient), 0);
        assertEq(token.balanceOf(affiliate), 0.04 ether);
    }

    function test_sweepERC20_prioritizesAffiliateOverRewards() public {
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));
        mockSeaport.setAvailableOrderHashes(_orderHashes(orders));
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, true));
        mockSeaport.setConsumeToken(address(token), 1.6 ether);
        _prank(address(this));
        scatterCollectionRegistry.setRewardsOverride(COLLECTION_ONE, rewardsRecipient);
        scatterCollectionRegistry.setRewardsOverride(COLLECTION_TWO, rewardsRecipient);

        _prank(buyer);
        subject.sweepERC20(
            _sweepCalldata(orders),
            address(token),
            1.6 ether,
            _externalSweepFills(),
            affiliate,
            _feeAuthDeadline(),
            _feeAuthFor(
                buyer, affiliate, keccak256(abi.encode(_orderHashes(orders))), _feeAuthDeadline(), FEE_AUTHORIZER_PK
            ),
            500
        );

        assertEq(token.balanceOf(subject.PLATFORM()), 0.04 ether);
        assertEq(token.balanceOf(rewardsRecipient), 0);
        assertEq(token.balanceOf(affiliate), 0.04 ether);
    }

    function test_sweepERC20_emitsExternalListingFilledEvent() public {
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));
        mockSeaport.setAvailableOrderHashes(_orderHashes(orders));
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, false));
        mockSeaport.setConsumeToken(address(token), 1 ether);

        _prank(buyer);
        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.ExternalListingFilled(
            buyer,
            address(token),
            _orderHashes(orders)[0],
            1 ether,
            0.05 ether,
            address(0),
            address(0),
            0.05 ether,
            0,
            0
        );
        subject.sweepERC20(
            _sweepCalldata(orders), address(token), 1.6 ether, _externalSweepFills(), address(0), 0, "", 500
        );
    }

    function test_sweepERC20_emitsSweepERC20FilledEvent() public {
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));
        mockSeaport.setAvailableOrderHashes(_orderHashes(orders));
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, true));
        mockSeaport.setConsumeToken(address(token), 1.6 ether);

        _prank(address(this));
        scatterCollectionRegistry.setRewardsOverride(COLLECTION_ONE, rewardsRecipient);
        scatterCollectionRegistry.setRewardsOverride(COLLECTION_TWO, rewardsRecipient);

        _prank(buyer);
        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.SweepERC20Filled(
            buyer, address(token), 1.6 ether, 0.08 ether, 0.04 ether, 0, 0.04 ether
        );
        subject.sweepERC20(
            _sweepCalldata(orders),
            address(token),
            1.6 ether,
            _externalSweepFills(),
            affiliate,
            _feeAuthDeadline(),
            _feeAuthFor(
                buyer, affiliate, keccak256(abi.encode(_orderHashes(orders))), _feeAuthDeadline(), FEE_AUTHORIZER_PK
            ),
            500
        );
    }

    function test_sweepERC20_emitsMeasuredErc20SpentWhenSeaportConsumesLess() public {
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));
        mockSeaport.setAvailableOrderHashes(_orderHashes(orders));
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, false));
        mockSeaport.setConsumeToken(address(token), 1 ether);

        _prank(buyer);
        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.SweepERC20Filled(buyer, address(token), 1 ether, 0.05 ether, 0.05 ether, 0, 0);
        subject.sweepERC20(
            _sweepCalldata(orders), address(token), 1.6 ether, _externalSweepFills(), address(0), 0, "", 500
        );
    }

    function test_sweepERC20_failsWhenPullFundsTransferReturnsFalse() public {
        IERC20 badToken = IERC20(new ReturnFalseERC20());
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(badToken));

        _prank(buyer);
        vm.expectPartialRevert(TokenTransferrerErrors.BadReturnValueFromERC20OnTransfer.selector);
        subject.sweepERC20(
            _sweepCalldata(orders), address(badToken), 1.6 ether, _externalSweepFills(), address(0), 0, "", 500
        );
    }

    function test_sweepERC20_failsWhenApproveSeaportReturnsFalse() public {
        IERC20 badToken = IERC20(new ApproveFalseERC20());
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(badToken));

        _prank(buyer);
        vm.expectPartialRevert(SafeERC20.SafeERC20FailedOperation.selector);
        subject.sweepERC20(
            _sweepCalldata(orders), address(badToken), 1.6 ether, _externalSweepFills(), address(0), 0, "", 500
        );
    }

    function test_sweepERC20_failsWhenSeaportReverts() public {
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));
        mockSeaport.setShouldRevert(true);

        _prank(buyer);
        vm.expectRevert(SeaportCallFailed.selector);
        subject.sweepERC20(
            _sweepCalldata(orders), address(token), 1.6 ether, _externalSweepFills(), address(0), 0, "", 500
        );
    }

    function test_sweepERC20_failsWhenSeaportReturnsBadData() public {
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));
        mockSeaport.setShouldReturnBadData(true);

        _prank(buyer);
        vm.expectRevert(SeaportCallFailed.selector);
        subject.sweepERC20(
            _sweepCalldata(orders), address(token), 1.6 ether, _externalSweepFills(), address(0), 0, "", 500
        );
    }

    function test_sweepERC20_failsWhenDisapproveSeaportReturnsFalse() public {
        IERC20 badToken = IERC20(new ApproveFalseOnSecondCallERC20());
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(badToken));
        mockSeaport.setAvailableOrderHashes(_orderHashes(orders));
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(false, false));

        _prank(buyer);
        vm.expectPartialRevert(SafeERC20.SafeERC20FailedOperation.selector);
        subject.sweepERC20(
            _sweepCalldata(orders), address(badToken), 1.6 ether, _externalSweepFills(), address(0), 0, "", 500
        );
    }

    function test_sweepERC20_failsWhenRefundLeftoverErc20ReturnsFalse() public {
        IERC20 badToken = IERC20(new TransferFalseAfterPullERC20());
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(badToken));
        mockSeaport.setAvailableOrderHashes(_orderHashes(orders));
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(false, false));

        _prank(buyer);
        vm.expectPartialRevert(SafeERC20.SafeERC20FailedOperation.selector);
        subject.sweepERC20(
            _sweepCalldata(orders), address(badToken), 1.6 ether, _externalSweepFills(), address(0), 0, "", 500
        );
    }

    function test_sweepERC20_failsWhenFeeTransferFails() public {
        IERC20 badToken = IERC20(new TransferFalseAfterPullERC20());
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(badToken));
        mockSeaport.setAvailableOrderHashes(_orderHashes(orders));
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, false));

        _prank(buyer);
        vm.expectPartialRevert(SafeERC20.SafeERC20FailedOperation.selector);
        subject.sweepERC20(
            _sweepCalldata(orders), address(badToken), 1.6 ether, _externalSweepFills(), address(0), 0, "", 500
        );
    }

    function test_sweepERC20_failsWhenPaused() public {
        AdvancedOrder[] memory orders = _erc20SweepOrders(address(token));
        _prank(owner);
        subject.pause();

        _prank(buyer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        subject.sweepERC20(
            _sweepCalldata(orders), address(token), 1.6 ether, _externalSweepFills(), address(0), 0, "", 500
        );
    }

    function test_sweepMixed_refundsNativeReturnedFromSeaport() public {
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, false));
        mockSeaport.setRefundAmount(0.1 ether);

        _prank(buyer);
        subject.sweepMixed{value: 2.05 ether}(
            seaportSweepCalldata,
            2 ether, // seaportTotalNativeValue
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            address(0),
            0,
            "",
            500
        );

        // Payment breakdown: buyer starts with 10 ether, sends 2.05 ether.
        // Only the first fill (1 ether) completes, so Scatter fee is 0.05 ether.
        // 2 ether is forwarded to Seaport, which refunds 0.1 ether.
        // 10 ether - 2 ether + 0.1 ether refund - 0.05 ether fee = 8.05 ether.
        assertEq(buyer.balance, 8.05 ether);
        assertEq(subject.SEAPORT().balance, 1.9 ether);
    }

    function test_sweepMixed_rejectsDuplicateErc20s() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(token);
        tokens[1] = address(token); // duplicate — allowance would overwrite
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100;
        amounts[1] = 200;

        _prank(buyer);
        vm.expectRevert(DuplicateSweepCurrency.selector);
        subject.sweepMixed{value: 2.08 ether}(
            seaportSweepCalldata, 2 ether, _externalSweepFills(), tokens, amounts, address(0), 0, "", 500
        );
    }

    function test_sweepMixed_rejectsDuplicateOrderIndex() public {
        uint256[] memory fills = new uint256[](2);
        fills[0] = 0;
        fills[1] = 0;

        _prank(buyer);
        vm.expectRevert(InvalidSweepOrderIndex.selector);
        subject.sweepMixed{value: 2.08 ether}(
            seaportSweepCalldata,
            2 ether, // seaportTotalNativeValue
            fills,
            _emptyAddresses(),
            _emptyUints(),
            address(0),
            0,
            "",
            500
        );
    }

    function test_sweepMixed_settlesCompletedOrdersAndEmitsTheirHashes() public {
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, true));
        mockSeaport.setRefundAmount(0.4 ether);
        bytes32[] memory orderHashes = _sweepOrderHashes();

        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.ExternalListingFilled(
            buyer, address(0), orderHashes[0], 1 ether, 0.05 ether, address(0), address(0), 0.05 ether, 0, 0
        );
        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.ExternalListingFilled(
            buyer, address(0), orderHashes[1], 0.6 ether, 0.03 ether, address(0), address(0), 0.03 ether, 0, 0
        );
        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.SweepFilled(buyer, 1.6 ether, 0.08 ether, 0.08 ether, 0, 0);

        _prank(buyer);
        subject.sweepMixed{value: 2.08 ether}(
            seaportSweepCalldata,
            2 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            address(0),
            0,
            "",
            500
        );
        assertEq(buyer.balance, 8.32 ether);
        assertEq(SEAPORT.balance, 1.6 ether);
        assertEq(PLATFORM.balance, 0.08 ether);
        assertEq(address(subject).balance, 1 ether);
    }

    function test_sweepMixed_chargesFeeOnlyForTheNamedOrderWhenFeeListIsASubset() public {
        AdvancedOrder[] memory orders = _sweepOrders();
        orders[0].parameters.orderType = OrderType.CONTRACT;
        mockSeaport.setAvailableOrderHashes(_orderHashes(orders));
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, true));

        _prank(buyer);
        subject.sweepMixed{value: 2.03 ether}(
            _sweepCalldata(orders),
            2 ether, // seaportTotalNativeValue
            _singleUint(1), // feeChargedOrderIndexes: batch order 1 only
            _emptyAddresses(), // erc20s
            _emptyUints(), // erc20Amounts
            address(0),
            0,
            "",
            500
        );

        // fee breakdown:
        //   feeBase     = 0.6 ether                     (batch order 1's own consideration)
        //   totalFee    = 0.6 ether * 500 / 10000        = 0.03 ether
        //   platformFee = 0.03 ether                     (no rewards or affiliate)
        assertEq(subject.PLATFORM().balance, 0.03 ether);
    }

    function test_sweepMixed_emitsNamedOrdersOwnHashAndFeeBaseWhenFeeListIsASubset() public {
        AdvancedOrder[] memory orders = _sweepOrders();
        orders[0].parameters.orderType = OrderType.CONTRACT;
        bytes32[] memory orderHashes = _orderHashes(orders);
        mockSeaport.setAvailableOrderHashes(orderHashes);
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, true));

        // Both the hash and fee base must come from the named batch order,
        // not from its position in the shorter fee-index list.
        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.ExternalListingFilled(
            buyer,
            address(0), // currency
            orderHashes[1], // batch order 1, though it sits at fee-list position 0
            0.6 ether, // feeBaseAmount
            0.03 ether, // scatterFee
            address(0), // affiliate
            address(0), // rewardsRecipient
            0.03 ether, // platformAmount
            0, // rewardsAmount
            0 // affiliateAmount
        );

        _prank(buyer);
        subject.sweepMixed{value: 2.03 ether}(
            _sweepCalldata(orders),
            2 ether, // seaportTotalNativeValue
            _singleUint(1), // feeChargedOrderIndexes: batch order 1 only
            _emptyAddresses(), // erc20s
            _emptyUints(), // erc20Amounts
            address(0),
            0,
            "",
            500
        );
    }

    function test_sweepMixed_rejectsOmittedExternalOrderIndex() public {
        _prank(buyer);
        vm.expectRevert(InvalidSweepOrderIndex.selector);
        subject.sweepMixed{value: 2.03 ether}(
            seaportSweepCalldata, 2 ether, _singleUint(1), _emptyAddresses(), _emptyUints(), address(0), 0, "", 500
        );
    }

    function test_sweepMixed_derivesFeeBaseFromCalldataConsiderationNotCallerInput() public {
        // The basis tracks the order's own consideration, independent of the
        // seaportTotalNativeValue the caller funds Seaport with: a 4 ether
        // order is charged as 4 ether however the sweep is funded.
        AdvancedOrder[] memory orders = _sweepOrders();
        orders[0].parameters.consideration = _nativeConsideration(4 ether, address(0x1001));
        bytes memory sweepCalldata = _sweepCalldata(orders);
        mockSeaport.setAvailableOrderHashes(_orderHashes(orders));
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, false));

        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.ExternalListingFilled(
            buyer, address(0), _orderHashes(orders)[0], 4 ether, 0.2 ether, address(0), address(0), 0.2 ether, 0, 0
        );

        _prank(buyer);
        subject.sweepMixed{value: 4.2 ether}(
            sweepCalldata, 4 ether, _externalSweepFills(), _emptyAddresses(), _emptyUints(), address(0), 0, "", 500
        );
    }

    function test_sweepMixed_feeBaseSumsEveryNativeConsiderationItem() public {
        // A real listing splits its price across seller, marketplace fee and
        // rewards items. The fee basis is the whole price the buyer pays.
        AdvancedOrder[] memory orders = _sweepOrders();
        ConsiderationItem[] memory consideration = new ConsiderationItem[](3);
        consideration[0] = _nativeConsideration(0.9 ether, address(0x1001))[0];
        consideration[1] = _nativeConsideration(0.025 ether, address(0x2001))[0];
        consideration[2] = _nativeConsideration(0.075 ether, address(0x2002))[0];
        orders[0].parameters.consideration = consideration;
        orders[0].parameters.totalOriginalConsiderationItems = 3;
        bytes memory sweepCalldata = _sweepCalldata(orders);
        mockSeaport.setAvailableOrderHashes(_orderHashes(orders));
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, false));

        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.ExternalListingFilled(
            buyer, address(0), _orderHashes(orders)[0], 1 ether, 0.05 ether, address(0), address(0), 0.05 ether, 0, 0
        );

        _prank(buyer);
        subject.sweepMixed{value: 2.05 ether}(
            sweepCalldata, 2 ether, _externalSweepFills(), _emptyAddresses(), _emptyUints(), address(0), 0, "", 500
        );
    }

    function test_sweepMixed_feeBaseScalesWithPartialFillFraction() public {
        // Half of a 1 ether order is filled, so half its price is the basis.
        AdvancedOrder[] memory orders = _sweepOrders();
        orders[0].numerator = 1;
        orders[0].denominator = 2;
        bytes memory sweepCalldata = _sweepCalldata(orders);
        mockSeaport.setAvailableOrderHashes(_orderHashes(orders));
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, false));

        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.ExternalListingFilled(
            buyer,
            address(0),
            _orderHashes(orders)[0],
            0.5 ether,
            0.025 ether,
            address(0),
            address(0),
            0.025 ether,
            0,
            0
        );

        _prank(buyer);
        subject.sweepMixed{value: 2.05 ether}(
            sweepCalldata, 2 ether, _externalSweepFills(), _emptyAddresses(), _emptyUints(), address(0), 0, "", 500
        );
    }

    function test_sweepMixed_feeBaseRoundsEachConsiderationItemOnPartialFills() public {
        // Seaport scales and rounds up each consideration item separately, so
        // an odd amount costs the buyer a rounded-up half three times over —
        // not half of the rounded-up whole.
        uint256 itemAmount = 1 ether + 1;
        uint256 expectedBase = 3 * ((itemAmount + 1) / 2);

        AdvancedOrder[] memory orders = _sweepOrders();
        ConsiderationItem[] memory consideration = new ConsiderationItem[](3);
        consideration[0] = _nativeConsideration(itemAmount, address(0x1001))[0];
        consideration[1] = _nativeConsideration(itemAmount, address(0x2001))[0];
        consideration[2] = _nativeConsideration(itemAmount, address(0x2002))[0];
        orders[0].parameters.consideration = consideration;
        orders[0].parameters.totalOriginalConsiderationItems = 3;
        orders[0].numerator = 1;
        orders[0].denominator = 2;
        bytes memory sweepCalldata = _sweepCalldata(orders);
        mockSeaport.setAvailableOrderHashes(_orderHashes(orders));
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, false));

        uint256 expectedFee = (expectedBase * 500) / 10000;
        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.ExternalListingFilled(
            buyer,
            address(0),
            _orderHashes(orders)[0],
            expectedBase,
            expectedFee,
            address(0),
            address(0),
            expectedFee,
            0,
            0
        );

        _prank(buyer);
        subject.sweepMixed{value: 2.2 ether}(
            sweepCalldata, 2 ether, _externalSweepFills(), _emptyAddresses(), _emptyUints(), address(0), 0, "", 500
        );
    }

    function test_sweepMixed_chargesFeeOnActualRemainderOfPartiallyFilledOrder() public {
        AdvancedOrder[] memory orders = _sweepOrders();
        orders[0].parameters.orderType = OrderType.PARTIAL_OPEN;
        orders[0].parameters.offer[0].itemType = ItemType.ERC1155;
        orders[0].parameters.offer[0].startAmount = 100;
        orders[0].parameters.offer[0].endAmount = 100;
        bytes32[] memory orderHashes = _orderHashes(orders);
        mockSeaport.setAvailableOrderHashes(orderHashes);
        mockSeaport.setOrderStatus(orderHashes[0], 99, 100);
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, false));
        mockSeaport.setRefundAmount(0.99 ether);

        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.ExternalListingFilled(
            buyer, address(0), orderHashes[0], 0.01 ether, 0.0005 ether, address(0), address(0), 0.0005 ether, 0, 0
        );

        _prank(buyer);
        subject.sweepMixed{value: 1.05 ether}(
            _sweepCalldata(orders),
            1 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            address(0),
            0,
            "",
            500
        );

        assertEq(subject.PLATFORM().balance, 0.0005 ether);
        assertEq(buyer.balance, 9.9895 ether);
    }

    function test_sweepMixed_rejectsConsiderationBeyondSignedItems() public {
        // Seaport pays items appended beyond the signed consideration, so
        // orders carrying more consideration than was signed must be rejected
        // or those payments escape the fee.
        AdvancedOrder[] memory orders = _sweepOrders();
        ConsiderationItem[] memory consideration = new ConsiderationItem[](2);
        consideration[0] = _nativeConsideration(1 ether, address(0x1001))[0];
        consideration[1] = _nativeConsideration(5 ether, address(0x2002))[0]; // tip
        orders[0].parameters.consideration = consideration;
        orders[0].parameters.totalOriginalConsiderationItems = 1;

        _prank(buyer);
        vm.expectRevert(InvalidTotalOriginalConsiderationItems.selector);
        subject.sweepMixed{value: 2.05 ether}(
            _sweepCalldata(orders),
            2 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            address(0),
            0,
            "",
            500
        );
    }

    function test_sweepMixed_revertsWhenFeeChargedOrderIsAContractOrder() public {
        // Contract orders (ScatterOfferer among them) return their real
        // consideration from generateOrder at fill time, so the calldata
        // carries no price to charge against — and a native listing already
        // pays its fee inside the offerer.
        AdvancedOrder[] memory orders = _sweepOrders();
        orders[0].parameters.orderType = OrderType.CONTRACT;

        _prank(buyer);
        vm.expectRevert(UnsupportedContractOrder.selector);
        subject.sweepMixed{value: 2.08 ether}(
            _sweepCalldata(orders),
            2 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            address(0),
            0,
            "",
            500
        );
    }

    function test_sweepMixed_revertsForUntrustedContractOfferer() public {
        AdvancedOrder[] memory orders = _sweepOrders();
        orders[0].parameters.orderType = OrderType.CONTRACT;
        orders[0].parameters.offerer = address(0x9999);

        _prank(buyer);
        vm.expectRevert(UnsupportedContractOrder.selector);
        subject.sweepMixed{value: 2.03 ether}(
            _sweepCalldata(orders), 2 ether, _singleUint(1), _emptyAddresses(), _emptyUints(), address(0), 0, "", 500
        );
    }

    function test_sweepMixed_revertsWhenFeeChargedOrderPriceVariesOverTime() public {
        // Seaport interpolates a start/end spread against the block timestamp;
        // the router refuses rather than charge against a price it guessed.
        AdvancedOrder[] memory orders = _sweepOrders();
        orders[0].parameters.consideration[0].endAmount = 0.5 ether;

        _prank(buyer);
        vm.expectRevert(VariableSweepConsiderationAmount.selector);
        subject.sweepMixed{value: 2.08 ether}(
            _sweepCalldata(orders),
            2 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            address(0),
            0,
            "",
            500
        );
    }

    function test_sweepMixed_revertsWhenFeeChargedOrderIsPricedInAnErc20() public {
        AdvancedOrder[] memory orders = _sweepOrders();
        orders[0].parameters.consideration[0].itemType = ItemType.ERC20;
        orders[0].parameters.consideration[0].token = address(token);

        _prank(buyer);
        vm.expectRevert(UnsupportedSweepCurrency.selector);
        subject.sweepMixed{value: 2.08 ether}(
            _sweepCalldata(orders),
            2 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            address(0),
            0,
            "",
            500
        );
    }

    function test_sweepMixed_revertsWhenFeeChargedOrderMixesNativeAndErc20Consideration() public {
        // The sweep charges in native only. Deriving the basis from the native
        // leg alone would price this order at 1 wei — a zero fee on a 100-token
        // sale, with that 1 wei reported as the basis — while
        // `erc20s`/`erc20Amounts` funds the ERC-20 leg and lets the fill go
        // through.
        AdvancedOrder[] memory orders = _sweepOrders();
        ConsiderationItem[] memory consideration = new ConsiderationItem[](2);
        consideration[0] = ConsiderationItem({
            itemType: ItemType.NATIVE,
            token: address(0),
            identifierOrCriteria: 0,
            startAmount: 1, // 1 wei of native, to keep the fee near zero
            endAmount: 1,
            recipient: payable(address(0x1001))
        });
        consideration[1] = ConsiderationItem({
            itemType: ItemType.ERC20,
            token: address(token),
            identifierOrCriteria: 0,
            startAmount: 100 ether,
            endAmount: 100 ether,
            recipient: payable(address(0x1001))
        });
        orders[0].parameters.consideration = consideration;
        orders[0].parameters.totalOriginalConsiderationItems = 2;

        _prank(buyer);
        vm.expectRevert(UnsupportedSweepCurrency.selector);
        subject.sweepMixed{value: 2.08 ether}(
            _sweepCalldata(orders),
            2 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            address(0),
            0,
            "",
            500
        );
    }

    function test_sweepMixed_revertsWhenFeeChargedOrderHasZeroNativeConsideration() public {
        // Native currency is valid, but the order has no payment to charge.
        AdvancedOrder[] memory orders = _sweepOrders();
        orders[0].parameters.consideration[0].startAmount = 0;
        orders[0].parameters.consideration[0].endAmount = 0;

        _prank(buyer);
        vm.expectRevert(InvalidListingAmount.selector);
        subject.sweepMixed{value: 2.08 ether}(
            _sweepCalldata(orders),
            2 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            address(0),
            0,
            "",
            500
        );
    }

    function test_sweepMixed_revertsWhenOriginalConsiderationCountExceedsLength() public {
        AdvancedOrder[] memory orders = _sweepOrders();
        orders[0].parameters.totalOriginalConsiderationItems = 2;
        bytes memory malformedSeaportCalldata = _sweepCalldata(orders);

        _prank(buyer);
        vm.expectRevert(InvalidTotalOriginalConsiderationItems.selector);
        subject.sweepMixed{value: 2.08 ether}(
            malformedSeaportCalldata,
            2 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            address(0),
            0,
            "",
            500
        );
    }

    function test_sweepMixed_revertsWhenTwoSlotsDeriveSameOrderHash() public {
        AdvancedOrder[] memory orders = _sweepOrders();
        orders[1] = orders[0]; // second slot duplicates the first order
        bytes memory duplicateOrderCalldata = _sweepCalldata(orders);

        _prank(buyer);
        vm.expectRevert(DuplicateSweepOrderHash.selector);
        subject.sweepMixed{value: 2.08 ether}(
            duplicateOrderCalldata,
            2 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            address(0),
            0,
            "",
            500
        );
    }

    function test_sweepMixed_skipsUnavailableExternalFills() public {
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, false));

        _prank(buyer);
        subject.sweepMixed{value: 2.08 ether}(
            seaportSweepCalldata,
            2 ether, // seaportTotalNativeValue
            _externalSweepFills(),
            _emptyAddresses(), // erc20s
            _emptyUints(), // erc20Amounts
            address(0),
            0,
            "",
            500
        );

        // Fee breakdown: only first fill completed, so only 1 ether * 5% = 0.05 ether fee is collected.
        assertEq(subject.PLATFORM().balance, 0.05 ether);
    }

    function test_sweepMixed_revertsWhenCompletedSlotDidNotFillCalldataOrderHash() public {
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, true));
        bytes32[] memory actualOrderHashes = _sweepOrderHashes();
        actualOrderHashes[1] = keccak256("different-sweep-order");
        mockSeaport.setAvailableOrderHashes(actualOrderHashes);
        bytes32[] memory calldataOrderHashes = _sweepOrderHashes();

        _prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(OrderNotFilled.selector, calldataOrderHashes[1]));
        subject.sweepMixed{value: 2.08 ether}(
            seaportSweepCalldata,
            2 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            address(0),
            0,
            "",
            500
        );
    }

    function test_sweepMixed_revertsWhenCompletedSlotReportsNoFill() public {
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, false));
        mockSeaport.setShouldFillOrder(false);
        bytes32 unfilledOrderHash = _sweepOrderHashes()[0];

        _prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(OrderNotFilled.selector, unfilledOrderHash));
        subject.sweepMixed{value: 2.05 ether}(
            seaportSweepCalldata,
            2 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            address(0),
            0,
            "",
            500
        );
    }

    function test_sweepMixed_distributesPlatformFeeWhenNoAffiliateOrRewards() public {
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, true));

        _prank(buyer);
        subject.sweepMixed{value: 2.08 ether}(
            seaportSweepCalldata,
            2 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            address(0),
            0,
            "",
            500
        );

        // Fee breakdown: aggregate fee is 0.08 ether.
        // No affiliate/rewards means all fee goes to platform.
        assertEq(subject.PLATFORM().balance, 0.08 ether);
        assertEq(rewardsRecipient.balance, 0);
        assertEq(affiliate.balance, 0);
    }

    function test_sweepMixed_distributesPlatformAndRewardsFees() public {
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, true));
        _prank(address(this));
        scatterCollectionRegistry.setRewardsOverride(COLLECTION_ONE, rewardsRecipient);
        scatterCollectionRegistry.setRewardsOverride(COLLECTION_TWO, rewardsRecipient);

        _prank(buyer);
        subject.sweepMixed{value: 2.08 ether}(
            seaportSweepCalldata,
            2 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            address(0),
            0,
            "",
            500
        );

        // Fee breakdown: aggregate fee is 0.08 ether.
        // Platform/rewards split 50/50 = 0.04 ether each.
        assertEq(subject.PLATFORM().balance, 0.04 ether);
        assertEq(rewardsRecipient.balance, 0.04 ether);
        assertEq(affiliate.balance, 0);
    }

    function test_sweepMixed_distributesRewardsToEachCollectionsRecipient() public {
        address secondRewardsRecipient = makeAddr("secondRewardsRecipient");
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, true));
        _prank(address(this));
        scatterCollectionRegistry.setRewardsOverride(COLLECTION_ONE, rewardsRecipient);
        scatterCollectionRegistry.setRewardsOverride(COLLECTION_TWO, secondRewardsRecipient);

        _prank(buyer);
        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.SweepFilled(buyer, 2 ether, 0.08 ether, 0.04 ether, 0.04 ether, 0);
        subject.sweepMixed{value: 2.08 ether}(
            seaportSweepCalldata,
            2 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            address(0),
            0,
            "",
            500
        );

        assertEq(rewardsRecipient.balance, 0.025 ether);
        assertEq(secondRewardsRecipient.balance, 0.015 ether);
    }

    function test_sweepMixed_distributesPlatformAndAffiliateFees() public {
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, true));

        _prank(buyer);
        subject.sweepMixed{value: 2.08 ether}(
            seaportSweepCalldata,
            2 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            affiliate,
            _feeAuthDeadline(),
            _feeAuthSig(buyer, affiliate, _sweepOrdersHash()),
            500
        );

        // Fee breakdown: aggregate fee is 0.08 ether.
        // No rewards, platform/affiliate split 50/50 = 0.04 ether each.
        assertEq(subject.PLATFORM().balance, 0.04 ether);
        assertEq(rewardsRecipient.balance, 0);
        assertEq(affiliate.balance, 0.04 ether);
    }

    function test_sweepMixed_affiliateTakesPriorityOverRegistryRewards() public {
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, true));
        _prank(address(this));
        scatterCollectionRegistry.setRewardsOverride(COLLECTION_ONE, rewardsRecipient);
        scatterCollectionRegistry.setRewardsOverride(COLLECTION_TWO, rewardsRecipient);

        _prank(buyer);
        subject.sweepMixed{value: 2.08 ether}(
            seaportSweepCalldata,
            2 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            affiliate,
            _feeAuthDeadline(),
            _feeAuthSig(buyer, affiliate, _sweepOrdersHash()),
            500
        );

        // Affiliate takes priority over rewards attribution.
        assertEq(subject.PLATFORM().balance, 0.04 ether);
        assertEq(affiliate.balance, 0.04 ether);
        assertEq(rewardsRecipient.balance, 0);
    }

    function test_sweepMixed_aggregatesPartialRewardsAcrossFills() public {
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, true));
        _prank(address(this));
        scatterCollectionRegistry.setRewardsOverride(COLLECTION_ONE, rewardsRecipient);

        _prank(buyer);
        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.SweepFilled(buyer, 2 ether, 0.08 ether, 0.055 ether, 0.025 ether, 0);
        subject.sweepMixed{value: 2.08 ether}(
            seaportSweepCalldata,
            2 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            address(0),
            0,
            "",
            500
        );

        assertEq(subject.PLATFORM().balance, 0.055 ether);
        assertEq(rewardsRecipient.balance, 0.025 ether);
        assertEq(affiliate.balance, 0);
    }

    function test_sweepMixed_refundsExcessNativePayment() public {
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, false));

        _prank(buyer);
        subject.sweepMixed{value: 2.2 ether}(
            seaportSweepCalldata,
            2 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            address(0),
            0,
            "",
            500
        );

        // Payment breakdown: buyer starts with 10 ether.
        // Buyer sends 2.2 ether and gets 0.15 ether overpayment refunded.
        // Final cost is 2 ether Seaport native value + 0.05 ether Scatter fee = 2.05 ether.
        assertEq(buyer.balance, 7.95 ether);
    }

    function test_sweepMixed_emitsExternalListingFilledEvent() public {
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, false));
        uint256[] memory fills = _externalSweepFills();
        bytes32[] memory orderHashes = _sweepOrderHashes();

        _prank(buyer);
        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.ExternalListingFilled(
            buyer, // buyer
            address(0), // currency
            orderHashes[0], // orderHash
            1 ether, // feeBaseAmount, derived from the order's consideration
            0.05 ether, // scatterFee
            address(0), // affiliate
            address(0), // rewardsRecipient
            0.05 ether, // platformAmount
            0, // rewardsAmount
            0 // affiliateAmount
        );
        subject.sweepMixed{value: 2.05 ether}(
            seaportSweepCalldata, 2 ether, fills, _emptyAddresses(), _emptyUints(), address(0), 0, "", 500
        );
    }

    function test_sweepMixed_emitsSweepFilledEvent() public {
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, true));

        _prank(buyer);
        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.SweepFilled(
            buyer, // buyer
            2 ether, // seaportNativeSpent
            0.08 ether, // totalScatterFee
            0.04 ether, // platformAmount
            0, // rewardsAmount
            0.04 ether
        );
        subject.sweepMixed{value: 2.08 ether}(
            seaportSweepCalldata,
            2 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            affiliate,
            _feeAuthDeadline(),
            _feeAuthSig(buyer, affiliate, _sweepOrdersHash()),
            500
        );
    }

    function test_sweepMixed_emitsMeasuredNativeSpentWhenSeaportRefunds() public {
        // Seaport refunds part of the forwarded native (over-funded / partial sweep),
        // so the true spend is 1.5 ether even though 2 ether was forwarded. The event
        // must report the measured spend, not the caller-supplied 2 ether input.
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, true));
        mockSeaport.setRefundAmount(0.5 ether);

        _prank(buyer);
        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.SweepFilled(
            buyer, // buyer
            1.5 ether, // measured native spend (2 ether forwarded - 0.5 ether refunded)
            0.08 ether, // totalScatterFee
            0.04 ether, // platformAmount
            0, // rewardsAmount
            0.04 ether
        );
        subject.sweepMixed{value: 2.08 ether}(
            seaportSweepCalldata,
            2 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            affiliate,
            _feeAuthDeadline(),
            _feeAuthSig(buyer, affiliate, _sweepOrdersHash()),
            500
        );
    }

    function test_sweepMixed_failsWhenErc20ArrayLengthMismatch() public {
        address[] memory erc20s = _singleAddress(address(token));

        vm.expectRevert(LengthMismatch.selector);
        subject.sweepMixed(seaportSweepCalldata, 0, _emptyUints(), erc20s, _emptyUints(), address(0), 0, "", 500);
    }

    function test_sweepMixed_failsWhenErc20AmountIsZero() public {
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(false, false));

        _prank(buyer);
        vm.expectRevert(InvalidListingAmount.selector);
        subject.sweepMixed{value: 1 ether}(
            seaportSweepCalldata,
            1 ether,
            _externalSweepFills(),
            _singleAddress(address(token)),
            _singleUint(0),
            address(0),
            0,
            "",
            500
        );
    }

    function test_sweepMixed_failsWhenPullFundsTransferReturnsFalse() public {
        IERC20 badToken = IERC20(new ReturnFalseERC20());

        _prank(buyer);
        vm.expectPartialRevert(TokenTransferrerErrors.BadReturnValueFromERC20OnTransfer.selector);
        subject.sweepMixed{value: 1 ether}(
            seaportSweepCalldata,
            1 ether,
            _emptyUints(),
            _singleAddress(address(badToken)),
            _singleUint(1 ether),
            address(0),
            0,
            "",
            500
        );
    }

    function test_sweepMixed_failsWhenApproveSeaportReturnsFalse() public {
        IERC20 badToken = IERC20(new ApproveFalseERC20());

        _prank(buyer);
        vm.expectPartialRevert(SafeERC20.SafeERC20FailedOperation.selector);
        subject.sweepMixed{value: 1 ether}(
            seaportSweepCalldata,
            1 ether,
            _emptyUints(),
            _singleAddress(address(badToken)),
            _singleUint(1 ether),
            address(0),
            0,
            "",
            500
        );
    }

    function test_sweepMixed_failsWhenSeaportReverts() public {
        mockSeaport.setShouldRevert(true);

        _prank(buyer);
        vm.expectRevert(SeaportCallFailed.selector);
        subject.sweepMixed{value: 2.08 ether}(
            seaportSweepCalldata,
            2 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            address(0),
            0,
            "",
            500
        );
    }

    function test_sweepMixed_failsWhenSeaportReturnsBadData() public {
        mockSeaport.setShouldReturnBadData(true);

        _prank(buyer);
        vm.expectRevert(SeaportCallFailed.selector);
        subject.sweepMixed{value: 2.08 ether}(
            seaportSweepCalldata,
            2 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            address(0),
            0,
            "",
            500
        );
    }

    function test_sweepMixed_failsWhenRefundLeftoverErc20ReturnsFalse() public {
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(false, false));
        IERC20 badToken = IERC20(new TransferFalseAfterPullERC20());

        _prank(buyer);
        vm.expectPartialRevert(SafeERC20.SafeERC20FailedOperation.selector);
        subject.sweepMixed{value: 1 ether}(
            seaportSweepCalldata,
            1 ether,
            _externalSweepFills(),
            _singleAddress(address(badToken)),
            _singleUint(1 ether),
            address(0),
            0,
            "",
            500
        );
    }

    function test_sweepMixed_failsWhenDisapproveSeaportReturnsFalse() public {
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(false, false));
        IERC20 badToken = IERC20(new ApproveFalseOnSecondCallERC20());

        _prank(buyer);
        vm.expectPartialRevert(SafeERC20.SafeERC20FailedOperation.selector);
        subject.sweepMixed{value: 1 ether}(
            seaportSweepCalldata,
            1 ether,
            _externalSweepFills(),
            _singleAddress(address(badToken)),
            _singleUint(1 ether),
            address(0),
            0,
            "",
            500
        );
    }

    function test_sweepMixed_failsWhenInsufficientPaymentForAggregateFees() public {
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, true));

        _prank(buyer);
        vm.expectRevert(InsufficientPayment.selector);
        subject.sweepMixed{value: 2.07 ether}(
            seaportSweepCalldata,
            2 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            address(0),
            0,
            "",
            500
        );
    }

    function test_sweepMixed_failsWhenFeeTransferFails() public {
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, false));
        RejectEther rejecter = new RejectEther();
        vm.etch(subject.PLATFORM(), address(rejecter).code);

        _prank(buyer);
        vm.expectRevert(FeeTransferFailed.selector);
        subject.sweepMixed{value: 2.05 ether}(
            seaportSweepCalldata,
            2 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            address(0),
            0,
            "",
            500
        );
    }

    function test_sweepMixed_failsWhenNativeRefundFails() public {
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, false));
        RejectEther rejecter = new RejectEther();
        vm.deal(address(rejecter), 3 ether);

        _prank(address(rejecter));
        vm.expectRevert(RefundFailed.selector);
        subject.sweepMixed{value: 2.2 ether}(
            _sweepCalldata(_sweepOrders(), address(rejecter)),
            2 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            address(0),
            0,
            "",
            500
        );
    }

    function test_sweepMixed_rejectsZeroAndRouterRecipients() public {
        address[2] memory recipients = [address(0), address(subject)];
        for (uint256 i = 0; i < recipients.length; i++) {
            _prank(buyer);
            vm.expectRevert(InvalidSweepRecipient.selector);
            subject.sweepMixed{value: 2.08 ether}(
                _sweepCalldata(_sweepOrders(), recipients[i]),
                2 ether,
                _externalSweepFills(),
                _emptyAddresses(),
                _emptyUints(),
                address(0),
                0,
                "",
                500
            );
        }
    }

    function test_sweepMixed_rejectsFulfillerConduit() public {
        _prank(buyer);
        vm.expectRevert(InvalidFulfillerConduitKey.selector);
        subject.sweepMixed{value: 2.08 ether}(
            _sweepCalldata(_sweepOrders(), bytes32(uint256(1)), buyer),
            2 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            address(0),
            0,
            "",
            500
        );
    }

    function test_sweepMixed_failsWhenPaused() public {
        _prank(owner);
        subject.pause();

        _prank(buyer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        subject.sweepMixed{value: 2.08 ether}(
            seaportSweepCalldata,
            2 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            address(0),
            0,
            "",
            500
        );
    }

    function test_buyExternalListing_rejectsUnpayableRewardsAndAffiliate() public {
        address rejecter = address(new RejectEther());
        _prank(address(this));
        scatterCollectionRegistry.setRewardsOverride(COLLECTION_ONE, rejecter);

        _prank(buyer);
        vm.expectRevert(FeeTransferFailed.selector);
        subject.buyExternalListing{value: 1.05 ether}(
            seaportFulfillCalldata, 1 ether, address(0), externalOrderHash, 0, "", 500
        );

        _prank(address(this));
        scatterCollectionRegistry.setRewardsOverride(COLLECTION_ONE, address(0));
        bytes memory signature = _feeAuthSig(buyer, rejecter, keccak256(abi.encode(externalOrderHash)));
        _prank(buyer);
        vm.expectRevert(FeeTransferFailed.selector);
        subject.buyExternalListing{value: 1.05 ether}(
            seaportFulfillCalldata, 1 ether, rejecter, externalOrderHash, _feeAuthDeadline(), signature, 500
        );

        _prank(address(this));
        scatterCollectionRegistry.setRewardsOverride(COLLECTION_ONE, rewardsRecipient);
        _prank(buyer);
        subject.buyExternalListing{value: 1.05 ether}(
            seaportFulfillCalldata, 1 ether, address(0), externalOrderHash, 0, "", 500
        );

        assertEq(buyer.balance, 8.95 ether);
        assertEq(address(subject).balance, 1 ether);
        assertEq(subject.SEAPORT().balance, 1 ether);
        assertEq(subject.PLATFORM().balance, 0.025 ether);
        assertEq(rewardsRecipient.balance, 0.025 ether);
    }

    function test_sweepMixed_rejectsUnpayableRewardsAndAffiliate() public {
        address rejecter = address(new RejectEther());
        mockSeaport.setAvailableFulfillmentReturn(_fillsCompleted(true, true));
        _prank(address(this));
        scatterCollectionRegistry.setRewardsOverride(COLLECTION_ONE, rejecter);

        _prank(buyer);
        vm.expectRevert(FeeTransferFailed.selector);
        subject.sweepMixed{value: 1.68 ether}(
            seaportSweepCalldata,
            1.6 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            address(0),
            0,
            "",
            500
        );

        _prank(address(this));
        scatterCollectionRegistry.setRewardsOverride(COLLECTION_ONE, address(0));
        bytes memory signature = _feeAuthSig(buyer, rejecter, _sweepOrdersHash());
        _prank(buyer);
        vm.expectRevert(FeeTransferFailed.selector);
        subject.sweepMixed{value: 1.68 ether}(
            seaportSweepCalldata,
            1.6 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            rejecter,
            _feeAuthDeadline(),
            signature,
            500
        );

        subject.sweepMixed{value: 1.68 ether}(
            seaportSweepCalldata,
            1.6 ether,
            _externalSweepFills(),
            _emptyAddresses(),
            _emptyUints(),
            address(0),
            0,
            "",
            500
        );

        assertEq(buyer.balance, 8.32 ether);
        assertEq(address(subject).balance, 1 ether);
        assertEq(subject.SEAPORT().balance, 1.6 ether);
        assertEq(subject.PLATFORM().balance, 0.08 ether);
    }

    function test_buyExternalListing_roundsFeeSplitWithoutLosingTheRemainder() public {
        (bytes memory fulfillCalldata, bytes32 orderHash) = _prepareNativeListing(60);
        bytes memory signature = _feeAuthSig(buyer, affiliate, keccak256(abi.encode(orderHash)));
        _prank(buyer);
        subject.buyExternalListing{value: 63}(
            fulfillCalldata, 60, affiliate, orderHash, _feeAuthDeadline(), signature, 500
        );

        assertEq(buyer.balance, 10 ether - 63);
        assertEq(SEAPORT.balance, 60);
        assertEq(PLATFORM.balance, 1);
        assertEq(affiliate.balance, 2);
        assertEq(address(subject).balance, 1 ether);

        // A one-unit fee rounds the platform share to zero; the affiliate gets the remainder.
        (fulfillCalldata, orderHash) = _prepareNativeListing(20);
        signature = _feeAuthSig(buyer, affiliate, keccak256(abi.encode(orderHash)));
        mockSeaport.setRefundAmount(40);
        subject.buyExternalListing{value: 63}(
            fulfillCalldata, 60, affiliate, orderHash, _feeAuthDeadline(), signature, 500
        );
        assertEq(buyer.balance, 10 ether - 84);
        assertEq(SEAPORT.balance, 80);
        assertEq(PLATFORM.balance, 1);
        assertEq(affiliate.balance, 3);
        assertEq(address(subject).balance, 1 ether);

        // Below the fee threshold, prefunding above the listing price is fully refunded.
        (fulfillCalldata, orderHash) = _prepareNativeListing(19);
        signature = _feeAuthSig(buyer, affiliate, keccak256(abi.encode(orderHash)));
        mockSeaport.setRefundAmount(41);
        subject.buyExternalListing{value: 63}(
            fulfillCalldata, 60, affiliate, orderHash, _feeAuthDeadline(), signature, 500
        );
        assertEq(buyer.balance, 10 ether - 103);
        assertEq(SEAPORT.balance, 99);
        assertEq(PLATFORM.balance, 1);
        assertEq(affiliate.balance, 3);
        assertEq(address(subject).balance, 1 ether);
    }

    function test_buyExternalListingERC20_roundsFeeSplitAndPreservesExistingFunds() public {
        token.mint(address(subject), 3 ether);
        (bytes memory fulfillCalldata, bytes32 orderHash) = _prepareErc20Listing(address(token), 60);
        mockSeaport.setConsumeToken(address(token), 60);
        _prank(address(this));
        scatterCollectionRegistry.setRewardsOverride(COLLECTION_ONE, rewardsRecipient);
        _prank(buyer);
        subject.buyExternalListingERC20(fulfillCalldata, address(token), 60, address(0), orderHash, 0, "", 500);

        assertEq(token.balanceOf(buyer), 10 ether - 63);
        assertEq(token.balanceOf(SEAPORT), 60);
        assertEq(token.balanceOf(PLATFORM), 1);
        assertEq(token.balanceOf(rewardsRecipient), 2);
        assertEq(token.balanceOf(address(subject)), 3 ether);
        assertEq(token.allowance(address(subject), subject.SEAPORT()), 0);

        // A one-unit fee rounds the platform share to zero; rewards get the remainder.
        (fulfillCalldata, orderHash) = _prepareErc20Listing(address(token), 20);
        mockSeaport.setConsumeToken(address(token), 20);
        subject.buyExternalListingERC20(fulfillCalldata, address(token), 60, address(0), orderHash, 0, "", 500);
        assertEq(token.balanceOf(buyer), 10 ether - 84);
        assertEq(token.balanceOf(SEAPORT), 80);
        assertEq(token.balanceOf(PLATFORM), 1);
        assertEq(token.balanceOf(rewardsRecipient), 3);
        assertEq(token.balanceOf(address(subject)), 3 ether);
        assertEq(token.allowance(address(subject), SEAPORT), 0);

        // Below the fee threshold, prefunding above the listing price is fully refunded.
        (fulfillCalldata, orderHash) = _prepareErc20Listing(address(token), 19);
        mockSeaport.setConsumeToken(address(token), 19);
        subject.buyExternalListingERC20(fulfillCalldata, address(token), 60, address(0), orderHash, 0, "", 500);
        assertEq(token.balanceOf(buyer), 10 ether - 103);
        assertEq(token.balanceOf(SEAPORT), 99);
        assertEq(token.balanceOf(PLATFORM), 1);
        assertEq(token.balanceOf(rewardsRecipient), 3);
        assertEq(token.balanceOf(address(subject)), 3 ether);
        assertEq(token.allowance(address(subject), SEAPORT), 0);
    }

    function test_buyExternalListingERC20_rejectsUnpayableRewardsAndAffiliate() public {
        address rejectedRecipient = makeAddr("rejectedRecipient");
        RejectRecipientERC20 paymentToken = new RejectRecipientERC20(rejectedRecipient);
        paymentToken.mint(buyer, 10 ether);
        paymentToken.mint(address(subject), 3 ether);
        _prank(buyer);
        paymentToken.approve(address(conduit), type(uint256).max);
        (bytes memory fulfillCalldata, bytes32 orderHash) = _prepareErc20Listing(address(paymentToken), 1 ether);
        mockSeaport.setConsumeToken(address(paymentToken), 1 ether);
        _prank(address(this));
        scatterCollectionRegistry.setRewardsOverride(COLLECTION_ONE, rejectedRecipient);

        _prank(buyer);
        vm.expectPartialRevert(SafeERC20.SafeERC20FailedOperation.selector);
        subject.buyExternalListingERC20(
            fulfillCalldata, address(paymentToken), 1 ether, address(0), orderHash, 0, "", 500
        );

        _prank(address(this));
        scatterCollectionRegistry.setRewardsOverride(COLLECTION_ONE, address(0));
        bytes memory signature = _feeAuthSig(buyer, rejectedRecipient, keccak256(abi.encode(orderHash)));
        _prank(buyer);
        vm.expectPartialRevert(SafeERC20.SafeERC20FailedOperation.selector);
        subject.buyExternalListingERC20(
            fulfillCalldata,
            address(paymentToken),
            1 ether,
            rejectedRecipient,
            orderHash,
            _feeAuthDeadline(),
            signature,
            500
        );

        subject.buyExternalListingERC20(
            fulfillCalldata, address(paymentToken), 1 ether, address(0), orderHash, 0, "", 500
        );
        assertEq(paymentToken.balanceOf(buyer), 8.95 ether);
        assertEq(paymentToken.balanceOf(address(subject)), 3 ether);
        assertEq(paymentToken.balanceOf(subject.SEAPORT()), 1 ether);
        assertEq(paymentToken.balanceOf(subject.PLATFORM()), 0.05 ether);
        assertEq(paymentToken.allowance(address(subject), subject.SEAPORT()), 0);
    }

    function _externalSweepFills() internal pure returns (uint256[] memory orderIndexes) {
        orderIndexes = new uint256[](2);
        orderIndexes[0] = 0;
        orderIndexes[1] = 1;
    }

    function _seaportFulfillAdvancedCalldata(AdvancedOrder memory order) internal view returns (bytes memory) {
        return abi.encodeWithSelector(bytes4(0xe7acab24), order, new CriteriaResolver[](0), bytes32(0), buyer);
    }

    function _sweepCalldata(AdvancedOrder[] memory orders) internal view returns (bytes memory) {
        return _sweepCalldata(orders, buyer);
    }

    function _sweepCalldata(AdvancedOrder[] memory orders, address recipient) internal pure returns (bytes memory) {
        return _sweepCalldata(orders, bytes32(0), recipient);
    }

    function _sweepCalldata(AdvancedOrder[] memory orders, bytes32 fulfillerConduitKey, address recipient)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(
            SeaportInterface.fulfillAvailableAdvancedOrders.selector,
            orders,
            new CriteriaResolver[](0),
            new FulfillmentComponent[][](0),
            new FulfillmentComponent[][](0),
            fulfillerConduitKey,
            recipient,
            type(uint256).max
        );
    }

    function _sweepOrders() internal pure returns (AdvancedOrder[] memory orders) {
        // Prices double as the fee bases the router must derive: the sweep
        // charges 5% of each order's own native consideration.
        orders = new AdvancedOrder[](2);
        orders[0] = _sweepOrder(address(0x1001), 1, 1 ether);
        orders[1] = _sweepOrder(address(0x1002), 2, 0.6 ether);
    }

    function _sweepOrder(address offerer, uint256 salt, uint256 price) internal pure returns (AdvancedOrder memory) {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem({
            itemType: ItemType.ERC721,
            token: salt == 1 ? COLLECTION_ONE : COLLECTION_TWO,
            identifierOrCriteria: salt,
            startAmount: 1,
            endAmount: 1
        });
        return AdvancedOrder({
            parameters: OrderParameters({
                offerer: offerer,
                zone: address(0),
                offer: offer,
                consideration: _nativeConsideration(price, offerer),
                orderType: OrderType.FULL_OPEN,
                startTime: 0,
                endTime: type(uint256).max,
                zoneHash: bytes32(0),
                salt: salt,
                conduitKey: bytes32(0),
                totalOriginalConsiderationItems: 1
            }),
            numerator: 1,
            denominator: 1,
            signature: "",
            extraData: ""
        });
    }

    function _nativeConsideration(uint256 amount, address recipient)
        internal
        pure
        returns (ConsiderationItem[] memory consideration)
    {
        consideration = new ConsiderationItem[](1);
        consideration[0] = ConsiderationItem({
            itemType: ItemType.NATIVE,
            token: address(0),
            identifierOrCriteria: 0,
            startAmount: amount,
            endAmount: amount,
            recipient: payable(recipient)
        });
    }

    function _erc20SweepOrders(address currency) internal pure returns (AdvancedOrder[] memory orders) {
        orders = new AdvancedOrder[](2);
        orders[0] = _erc20SweepOrder(address(0x1001), 1, 1 ether, currency);
        orders[1] = _erc20SweepOrder(address(0x1002), 2, 0.6 ether, currency);
    }

    function _erc20SweepOrder(address offerer, uint256 salt, uint256 price, address currency)
        internal
        pure
        returns (AdvancedOrder memory)
    {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem({
            itemType: ItemType.ERC721,
            token: salt == 1 ? COLLECTION_ONE : COLLECTION_TWO,
            identifierOrCriteria: salt,
            startAmount: 1,
            endAmount: 1
        });
        return AdvancedOrder({
            parameters: OrderParameters({
                offerer: offerer,
                zone: address(0),
                offer: offer,
                consideration: _erc20Consideration(price, offerer, currency),
                orderType: OrderType.FULL_OPEN,
                startTime: 0,
                endTime: type(uint256).max,
                zoneHash: bytes32(0),
                salt: salt,
                conduitKey: bytes32(0),
                totalOriginalConsiderationItems: 1
            }),
            numerator: 1,
            denominator: 1,
            signature: "",
            extraData: ""
        });
    }

    function _erc20Consideration(uint256 amount, address recipient, address currency)
        internal
        pure
        returns (ConsiderationItem[] memory consideration)
    {
        consideration = new ConsiderationItem[](1);
        consideration[0] = ConsiderationItem({
            itemType: ItemType.ERC20,
            token: currency,
            identifierOrCriteria: 0,
            startAmount: amount,
            endAmount: amount,
            recipient: payable(recipient)
        });
    }

    function _sweepOrderHashes() internal pure returns (bytes32[] memory hashes) {
        return _orderHashes(_sweepOrders());
    }

    function _orderHashes(AdvancedOrder[] memory orders) internal pure returns (bytes32[] memory hashes) {
        hashes = new bytes32[](orders.length);
        for (uint256 i = 0; i < orders.length; i++) {
            hashes[i] = keccak256(abi.encode(_toOrderComponents(orders[i].parameters)));
        }
    }

    function _singleOrder(AdvancedOrder memory order) internal pure returns (AdvancedOrder[] memory orders) {
        orders = new AdvancedOrder[](1);
        orders[0] = order;
    }

    function _toOrderComponents(OrderParameters memory parameters) internal pure returns (OrderComponents memory) {
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
            counter: 0
        });
    }

    function _fillsCompleted(bool first, bool second) internal pure returns (bool[] memory fillsCompleted) {
        fillsCompleted = new bool[](2);
        fillsCompleted[0] = first;
        fillsCompleted[1] = second;
    }

    function _emptyAddresses() internal pure returns (address[] memory values) {
        values = new address[](0);
    }

    function _emptyUints() internal pure returns (uint256[] memory values) {
        values = new uint256[](0);
    }

    function _singleAddress(address value) internal pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = value;
    }

    function _singleUint(uint256 value) internal pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = value;
    }

    function _prank(address actor) internal {
        vm.stopPrank();
        vm.startPrank(actor);
    }

    function _prepareNativeListing(uint256 price) internal returns (bytes memory fulfillCalldata, bytes32 orderHash) {
        AdvancedOrder memory order = _sweepOrder(address(0x1001), 1, price);
        fulfillCalldata = _seaportFulfillAdvancedCalldata(order);
        orderHash = _orderHashes(_singleOrder(order))[0];
        mockSeaport.setOrderHashToFill(orderHash);
    }

    function _prepareErc20Listing(address currency, uint256 price)
        internal
        returns (bytes memory fulfillCalldata, bytes32 orderHash)
    {
        AdvancedOrder memory order = _erc20SweepOrder(address(0x1001), 1, price, currency);
        fulfillCalldata = _seaportFulfillAdvancedCalldata(order);
        orderHash = _orderHashes(_singleOrder(order))[0];
        mockSeaport.setOrderHashToFill(orderHash);
    }

    function _feeAuthDeadline() internal view returns (uint256) {
        return vm.getBlockTimestamp() + 1 hours;
    }

    function _sweepOrdersHash() internal pure returns (bytes32) {
        return keccak256(abi.encode(_sweepOrderHashes()));
    }

    function _feeAuthSig(address authBuyer, address authAffiliate, bytes32 ordersHash)
        internal
        view
        returns (bytes memory)
    {
        return _feeAuthFor(authBuyer, authAffiliate, ordersHash, _feeAuthDeadline(), FEE_AUTHORIZER_PK);
    }

    function _feeAuthFor(
        address authBuyer,
        address authAffiliate,
        bytes32 ordersHash,
        uint256 deadline,
        uint256 signerPk
    ) internal view returns (bytes memory) {
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
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(signerPk, keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash)));
        return abi.encodePacked(r, s, v);
    }

    receive() external payable {}
}

contract RejectEther {
    receive() external payable {
        revert("RejectEther: rejected");
    }
}

contract RejectRecipientERC20 is ERC20Mock {
    address internal immutable rejectedRecipient;

    constructor(address recipient) {
        rejectedRecipient = recipient;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == rejectedRecipient) return false;
        return super.transfer(to, amount);
    }
}

contract ReturnFalseERC20 is IERC20 {
    mapping(address => uint256) public balanceOf;

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    function approve(address, uint256) external pure returns (bool) {
        return false;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}

contract ApproveFalseERC20 is IERC20 {
    mapping(address => uint256) public balanceOf;

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    function approve(address, uint256) external pure returns (bool) {
        return false;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }
}

contract TransferFalseAfterPullERC20 is IERC20 {
    mapping(address => uint256) public balanceOf;

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function transferFrom(address, address to, uint256 amount) external returns (bool) {
        balanceOf[to] += amount;
        return true;
    }
}

contract ApproveFalseOnSecondCallERC20 is IERC20 {
    mapping(address => uint256) public balanceOf;
    uint256 public approveCalls;

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    function approve(address, uint256) external returns (bool) {
        approveCalls++;
        return approveCalls == 1;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }
}

contract MockSeaport {
    bool public shouldRevert;
    bool public shouldReturnFalse;
    bool public shouldReturnBadData;
    uint256 public refundAmount;
    bool[] public fillsCompleted;
    address public consumeToken;
    uint256 public consumeAmount;
    bytes32 public orderHashToFill;
    bytes32[] public availableOrderHashes;
    mapping(bytes32 orderHash => uint256 totalFilled) public filledByOrder;
    mapping(bytes32 orderHash => uint256 totalSize) public sizeByOrder;
    bool public shouldFillOrder = true;
    ScatterAggregatorRouter public feeRouter;
    uint256 public feeBpsDuringFill;
    ScatterAggregatorRouter public feeSplitRouter;
    uint256 public feeSplitBpsDuringFill;

    function getCounter(address) external pure returns (uint256 counter) {
        return 0;
    }

    function getOrderHash(OrderComponents calldata order) external pure returns (bytes32 orderHash) {
        return keccak256(abi.encode(order));
    }

    function getOrderStatus(bytes32 orderHash)
        external
        view
        returns (bool isValidated, bool isCancelled, uint256 totalFilled, uint256 totalSize)
    {
        return (false, false, filledByOrder[orderHash], sizeByOrder[orderHash]);
    }

    function setOrderHashToFill(bytes32 v) external {
        orderHashToFill = v;
    }

    function setOrderStatus(bytes32 orderHash, uint256 filled, uint256 size) external {
        filledByOrder[orderHash] = filled;
        sizeByOrder[orderHash] = size;
    }

    function setAvailableOrderHashes(bytes32[] memory v) external {
        availableOrderHashes = v;
    }

    function setShouldFillOrder(bool v) external {
        shouldFillOrder = v;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function setShouldReturnFalse(bool v) external {
        shouldReturnFalse = v;
    }

    function setShouldReturnBadData(bool v) external {
        shouldReturnBadData = v;
    }

    function setRefundAmount(uint256 v) external {
        refundAmount = v;
    }

    function setAvailableFulfillmentReturn(bool[] memory v) external {
        fillsCompleted = v;
    }

    function setConsumeToken(address tokenAddress, uint256 amount) external {
        consumeToken = tokenAddress;
        consumeAmount = amount;
    }

    function setFeeBpsDuringFill(ScatterAggregatorRouter router, uint256 newFeeBps) external {
        feeRouter = router;
        feeBpsDuringFill = newFeeBps;
    }

    function setFeeSplitBpsDuringFill(ScatterAggregatorRouter router, uint256 newFeeSplitBps) external {
        feeSplitRouter = router;
        feeSplitBpsDuringFill = newFeeSplitBps;
    }

    fallback() external payable {
        if (shouldRevert) revert("MockSeaport: revert");
        if (shouldReturnBadData) {
            assembly { return(0, 0) }
        }

        if (address(feeRouter) != address(0)) feeRouter.setFeeBps(feeBpsDuringFill);
        if (address(feeSplitRouter) != address(0)) feeSplitRouter.setFeeSplitBps(feeSplitBpsDuringFill);

        if (consumeToken != address(0)) {
            bool consumed = IERC20(consumeToken).transferFrom(msg.sender, address(this), consumeAmount);
            require(consumed, "MockSeaport: consume failed");
        }

        if (refundAmount > 0) {
            (bool refundSuccess,) = msg.sender.call{value: refundAmount}("");
            require(refundSuccess, "MockSeaport: refund failed");
        }

        if (msg.sig == SeaportInterface.fulfillAvailableAdvancedOrders.selector) {
            AdvancedOrder[] memory orders;
            (orders,,,,,,) = abi.decode(
                msg.data[4:],
                (
                    AdvancedOrder[],
                    CriteriaResolver[],
                    FulfillmentComponent[][],
                    FulfillmentComponent[][],
                    bytes32,
                    address,
                    uint256
                )
            );
            bool[] memory resultFillsCompleted = new bool[](fillsCompleted.length);
            for (uint256 i = 0; i < fillsCompleted.length; i++) {
                resultFillsCompleted[i] = fillsCompleted[i];
                if (shouldFillOrder && resultFillsCompleted[i] && i < availableOrderHashes.length) {
                    _recordFill(availableOrderHashes[i], orders[i].numerator, orders[i].denominator);
                }
            }
            ScatterAggregatorRouter.SeaportFulfillAvailableExecution[] memory executions =
                new ScatterAggregatorRouter.SeaportFulfillAvailableExecution[](0);
            bytes memory encoded = abi.encode(resultFillsCompleted, executions);
            assembly {
                return(add(encoded, 32), mload(encoded))
            }
        }
        if (shouldFillOrder && !shouldReturnFalse) {
            filledByOrder[orderHashToFill] += 1;
            sizeByOrder[orderHashToFill] = 1;
        }
        bool fulfilled = !shouldReturnFalse;
        assembly {
            mstore(0, fulfilled)
            return(0, 32)
        }
    }

    function _recordFill(bytes32 orderHash, uint256 numerator, uint256 denominator) private {
        uint256 filled = filledByOrder[orderHash];
        uint256 size = sizeByOrder[orderHash];
        if (size == 0) {
            filledByOrder[orderHash] = numerator;
            sizeByOrder[orderHash] = denominator;
            return;
        }

        uint256 newFilled = filled * denominator + numerator * size;
        uint256 newSize = size * denominator;
        filledByOrder[orderHash] = newFilled > newSize ? newSize : newFilled;
        sizeByOrder[orderHash] = newSize;
    }

    receive() external payable {}
}
