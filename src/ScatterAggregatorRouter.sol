// SPDX-License-Identifier: BUSL-1.1
// ScatterAggregatorRouter v0.3.0
//
//        d8888                 888               888
//       d88888                 888               888
//      d88P888                 888               888
//     d88P 888 888d888 .d8888b 88888b.   .d88b.  888888 888  888 88888b.   .d88b.
//    d88P  888 888P"  d88P"    888 "88b d8P  Y8b 888    888  888 888 "88b d8P  Y8b
//   d88P   888 888    888      888  888 88888888 888    888  888 888  888 88888888
//  d8888888888 888    Y88b.    888  888 Y8b.     Y88b.  Y88b 888 888 d88P Y8b.
// d88P     888 888     "Y8888P 888  888  "Y8888   "Y888  "Y88888 88888P"   "Y8888
//                                                            888 888
//                                                       Y8b d88P 888
//                                                        "Y88P"  888
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ConduitConsumer} from "./ConduitConsumer.sol";
import {ConduitTransfer} from "seaport-types/src/conduit/lib/ConduitStructs.sol";
import {ConduitItemType} from "seaport-types/src/conduit/lib/ConduitEnums.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
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
import {SeaportInterface} from "seaport-types/src/interfaces/SeaportInterface.sol";
import {ScatterCollectionRegistry} from "./ScatterCollectionRegistry.sol";

error InsufficientPayment();
error InvalidListingAmount();
error SeaportCallFailed();
error RefundFailed();
error FeeTransferFailed();
error LengthMismatch();
error InvalidSweepOrderIndex();
error DuplicateSweepCurrency();
error DuplicateSweepOrderHash();
error InvalidSweepCalldataSelector();
error InvalidSweepRecipient();
error InvalidFulfillerConduitKey();
error InvalidTotalOriginalConsiderationItems();
error UnsupportedSweepCurrency();
error UnsupportedContractOrder();
error VariableSweepConsiderationAmount();
error InvalidFulfillmentCalldataSelector();
error InvalidFulfillmentRecipient();
error InvalidListingCollection();
error OrderHashMismatch();
error InvalidScatterCollectionRegistry();
error InvalidFeeAuthorizer();
error InvalidScatterOfferer();
error InvalidFeeAuthorization();
error FeeAuthorizationExpired();
error InvalidFeeBps();
error InvalidFeeSplitBps();
error FeeBpsExceedsLimit(uint256 currentFeeBps, uint256 maximumFeeBps);

error OrderNotFilled(bytes32 orderHash);

contract ScatterAggregatorRouter is Ownable2Step, Pausable, ReentrancyGuard, EIP712, ConduitConsumer {
    using SafeERC20 for IERC20;

    address public immutable SEAPORT =
        block.chainid == 4326 ? 0x00000000006687982678b03100B9bDC8be440814 : 0x0000000000000068F116a894984e2DB1123eB395;
    bytes4 private constant FULFILL_ADVANCED_ORDER_SELECTOR = 0xe7acab24;
    bytes4 private constant FULFILL_AVAILABLE_ADVANCED_ORDERS_SELECTOR = 0x87201b41;
    address public constant PLATFORM = 0x8952caF7E5bf1fe63ebe94148ca802F3eF127C98;

    uint256 public constant DEFAULT_FEE_BPS = 500;
    uint256 public constant MAX_FEE_BPS = 5000;
    uint256 public constant DEFAULT_FEE_SPLIT_BPS = 5000;
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant MAX_AUTHORIZATION_WINDOW = 7 days;

    /// The external caller whose Seaport fulfillment is in progress, or zero between calls.
    /// ScatterOfferer uses this value for sale attribution because Seaport sees the router
    /// as the fulfiller and a direct caller can forge an address in extraData.
    address private _activeRoutedFulfiller;
    ScatterCollectionRegistry public immutable scatterCollectionRegistry;
    address public immutable SCATTER_OFFERER;

    /// Server-held signer for affiliate fee authorizations. The owner may rotate it.
    address public feeAuthorizer;
    uint256 public feeBps = DEFAULT_FEE_BPS;
    uint256 public feeSplitBps = DEFAULT_FEE_SPLIT_BPS;

    bytes32 public constant FEE_AUTHORIZATION_TYPEHASH =
        keccak256("FeeAuthorization(address buyer,address affiliate,bytes32 ordersHash,uint256 deadline)");

    function activeRoutedFulfiller() external view returns (address) {
        return _activeRoutedFulfiller;
    }

    struct Fees {
        uint256 totalAmount;
        uint256 platformAmount;
        uint256 rewardsAmount;
        uint256 affiliateAmount;
        address rewardsRecipient;
        address affiliate;
    }

    event FeeAuthorizerUpdated(address indexed oldFeeAuthorizer, address indexed newFeeAuthorizer);
    event FeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event FeeSplitBpsUpdated(uint256 oldFeeSplitBps, uint256 newFeeSplitBps);
    event SweepFilled(
        address indexed buyer,
        uint256 seaportNativeSpent,
        uint256 totalScatterFee,
        uint256 platformAmount,
        uint256 rewardsAmount,
        uint256 affiliateAmount
    );
    event SweepERC20Filled(
        address indexed buyer,
        address indexed currency,
        uint256 seaportAmountSpent,
        uint256 totalScatterFee,
        uint256 platformAmount,
        uint256 rewardsAmount,
        uint256 affiliateAmount
    );
    event ExternalListingFilled(
        address indexed buyer,
        address indexed currency,
        bytes32 indexed orderHash,
        uint256 feeBaseAmount,
        uint256 scatterFee,
        address affiliate,
        address rewardsRecipient,
        uint256 platformAmount,
        uint256 rewardsAmount,
        uint256 affiliateAmount
    );

    constructor(
        address initialOwner,
        ScatterCollectionRegistry scatterCollectionRegistry_,
        address initialFeeAuthorizer,
        address scatterOfferer,
        bytes32 conduitKey
    ) Ownable(initialOwner) EIP712("ScatterAggregatorRouter", "1") ConduitConsumer(conduitKey) {
        if (address(scatterCollectionRegistry_).code.length == 0) {
            revert InvalidScatterCollectionRegistry();
        }
        if (initialFeeAuthorizer == address(0)) revert InvalidFeeAuthorizer();
        if (scatterOfferer.code.length == 0) revert InvalidScatterOfferer();
        scatterCollectionRegistry = scatterCollectionRegistry_;
        feeAuthorizer = initialFeeAuthorizer;
        SCATTER_OFFERER = scatterOfferer;
    }

    function buyExternalListing(
        bytes calldata seaportFulfillCalldata,
        uint256 maximumSeaportAmount,
        address affiliate,
        bytes32 orderHash,
        uint256 feeAuthorizationDeadline,
        bytes calldata feeAuthorizationSignature,
        uint256 maximumFeeBps
    ) external payable nonReentrant whenNotPaused {
        uint256 appliedFeeBps = _validatedFeeBps(maximumFeeBps);
        uint256 appliedFeeSplitBps = feeSplitBps;
        AdvancedOrder memory order = _decodeSingleOrder(seaportFulfillCalldata);
        ConsiderationItem[] memory originalConsideration = _originalConsideration(order);
        if (_orderHash(order, originalConsideration) != orderHash) revert OrderHashMismatch();
        _validateNativeFeeOrder(order, originalConsideration);
        _validateFeeAuthorization(
            affiliate, keccak256(abi.encode(orderHash)), feeAuthorizationDeadline, feeAuthorizationSignature
        );
        address rewardsRecipient = scatterCollectionRegistry.rewardsRecipient(_listingCollection(order));
        uint256 maximumScatterFee =
            _computeListingFee(maximumSeaportAmount, appliedFeeBps, appliedFeeSplitBps, affiliate, rewardsRecipient)
        .totalAmount;

        if (maximumSeaportAmount == 0) revert InvalidListingAmount();
        if (msg.value < maximumSeaportAmount + maximumScatterFee) revert InsufficientPayment();

        uint256 balanceBefore = address(this).balance - msg.value;
        OrderFillStatus memory fillStatusBefore = _getOrderFillStatus(orderHash);
        _seaportFulfillmentCall(seaportFulfillCalldata, maximumSeaportAmount);
        (uint256 fillNumerator, uint256 fillDenominator) = _orderFillDelta(orderHash, fillStatusBefore);
        uint256 actualFeeBaseAmount = _deriveNativeFeeBase(originalConsideration, fillNumerator, fillDenominator);
        Fees memory fees =
            _computeListingFee(actualFeeBaseAmount, appliedFeeBps, appliedFeeSplitBps, affiliate, rewardsRecipient);
        _distributeFeesNative(fees);
        uint256 balanceAfter = address(this).balance;

        _refundLeftoverNative(msg.sender, balanceBefore, balanceAfter);

        emit ExternalListingFilled(
            msg.sender,
            address(0), // native currency
            orderHash,
            actualFeeBaseAmount,
            fees.totalAmount,
            fees.affiliate,
            fees.rewardsRecipient,
            fees.platformAmount,
            fees.rewardsAmount,
            fees.affiliateAmount
        );
    }

    function buyExternalListingERC20(
        bytes calldata seaportFulfillCalldata,
        address erc20,
        uint256 maximumSeaportAmount,
        address affiliate,
        bytes32 orderHash,
        uint256 feeAuthorizationDeadline,
        bytes calldata feeAuthorizationSignature,
        uint256 maximumFeeBps
    ) external nonReentrant whenNotPaused {
        uint256 appliedFeeBps = _validatedFeeBps(maximumFeeBps);
        uint256 appliedFeeSplitBps = feeSplitBps;
        AdvancedOrder memory order = _decodeSingleOrder(seaportFulfillCalldata);
        ConsiderationItem[] memory originalConsideration = _originalConsideration(order);
        if (_orderHash(order, originalConsideration) != orderHash) revert OrderHashMismatch();
        _deriveErc20FeeBase(
            order.parameters.orderType, originalConsideration, erc20, order.numerator, order.denominator
        );
        _validateFeeAuthorization(
            affiliate, keccak256(abi.encode(orderHash)), feeAuthorizationDeadline, feeAuthorizationSignature
        );
        address rewardsRecipient = scatterCollectionRegistry.rewardsRecipient(_listingCollection(order));
        IERC20 token = IERC20(erc20);
        uint256 maximumScatterFee =
            _computeListingFee(maximumSeaportAmount, appliedFeeBps, appliedFeeSplitBps, affiliate, rewardsRecipient)
        .totalAmount;

        if (maximumSeaportAmount == 0) revert InvalidListingAmount();

        uint256 balanceBefore = token.balanceOf(address(this));
        _pullFunds(token, maximumSeaportAmount + maximumScatterFee);
        _approveSeaport(token, maximumSeaportAmount);
        OrderFillStatus memory fillStatusBefore = _getOrderFillStatus(orderHash);
        _seaportFulfillmentCall(seaportFulfillCalldata, 0);
        (uint256 fillNumerator, uint256 fillDenominator) = _orderFillDelta(orderHash, fillStatusBefore);
        uint256 actualFeeBaseAmount = _deriveErc20FeeBase(
            order.parameters.orderType, originalConsideration, erc20, fillNumerator, fillDenominator
        );
        Fees memory fees =
            _computeListingFee(actualFeeBaseAmount, appliedFeeBps, appliedFeeSplitBps, affiliate, rewardsRecipient);
        _distributeFeesErc20(token, fees);
        _disapproveSeaport(token);
        uint256 balanceAfter = token.balanceOf(address(this));

        _refundLeftoverErc20(token, balanceBefore, balanceAfter);

        emit ExternalListingFilled(
            msg.sender,
            erc20,
            orderHash,
            actualFeeBaseAmount,
            fees.totalAmount,
            fees.affiliate,
            fees.rewardsRecipient,
            fees.platformAmount,
            fees.rewardsAmount,
            fees.affiliateAmount
        );
    }

    function sweepMixed(
        bytes calldata seaportFulfillAvailableCalldata,
        uint256 seaportTotalNativeValue,
        uint256[] calldata feeChargedOrderIndexes,
        address[] calldata erc20s,
        uint256[] calldata erc20Amounts,
        address affiliate,
        uint256 feeAuthorizationDeadline,
        bytes calldata feeAuthorizationSignature,
        uint256 maximumFeeBps
    ) external payable nonReentrant whenNotPaused {
        uint256 appliedFeeBps = _validatedFeeBps(maximumFeeBps);
        uint256 appliedFeeSplitBps = feeSplitBps;
        if (erc20s.length != erc20Amounts.length) revert LengthMismatch();
        if (
            seaportFulfillAvailableCalldata.length < 4
                || bytes4(seaportFulfillAvailableCalldata[0:4]) != FULFILL_AVAILABLE_ADVANCED_ORDERS_SELECTOR
        ) {
            revert InvalidSweepCalldataSelector();
        }
        AdvancedOrder[] memory orders = _decodeAndValidateSweepOrders(seaportFulfillAvailableCalldata[4:]);
        for (uint256 i = 0; i < feeChargedOrderIndexes.length; i++) {
            if (i > 0 && feeChargedOrderIndexes[i] <= feeChargedOrderIndexes[i - 1]) {
                revert InvalidSweepOrderIndex();
            }
        }

        uint256 balanceNativeBefore = address(this).balance - msg.value;
        uint256[] memory balancesErc20Before = new uint256[](erc20s.length);

        for (uint256 i = 0; i < erc20s.length; i++) {
            uint256 amount = erc20Amounts[i];
            if (amount == 0) revert InvalidListingAmount();
            for (uint256 j = 0; j < i; j++) {
                if (erc20s[j] == erc20s[i]) revert DuplicateSweepCurrency();
            }

            IERC20 token = IERC20(erc20s[i]);
            balancesErc20Before[i] = token.balanceOf(address(this));
            _pullFunds(token, amount);
            _approveSeaport(token, amount);
        }

        // Measure the native actually consumed by the fills via the balance delta:
        // Seaport refunds unspent native to this router, so (before - after) is the
        // true spend. The caller-supplied seaportTotalNativeValue is only the amount
        // offered and overstates partial sweeps, so it must not be the recorded total.
        bytes32[] memory sweepOrderHashes = new bytes32[](orders.length);
        ConsiderationItem[][] memory originalConsiderations = new ConsiderationItem[][](orders.length);
        for (uint256 i = 0; i < orders.length; i++) {
            originalConsiderations[i] = _originalConsideration(orders[i]);
            sweepOrderHashes[i] = _orderHash(orders[i], originalConsiderations[i]);
        }
        bytes32[] memory orderHashes = new bytes32[](feeChargedOrderIndexes.length);
        OrderFillStatus[] memory fillStatusesBefore = new OrderFillStatus[](feeChargedOrderIndexes.length);
        uint256 feeIndex;
        for (uint256 orderIndex = 0; orderIndex < orders.length; orderIndex++) {
            if (!_requiresRouterFee(
                    orderIndex,
                    orders[orderIndex].parameters.orderType,
                    orders[orderIndex].parameters.offerer,
                    feeChargedOrderIndexes,
                    feeIndex
                )) {
                continue;
            }

            _validateNativeFeeOrder(orders[orderIndex], originalConsiderations[orderIndex]);
            bytes32 orderHash = sweepOrderHashes[orderIndex];
            for (uint256 j = 0; j < sweepOrderHashes.length; j++) {
                if (j != orderIndex && sweepOrderHashes[j] == orderHash) revert DuplicateSweepOrderHash();
            }
            orderHashes[feeIndex] = orderHash;
            fillStatusesBefore[feeIndex] = _getOrderFillStatus(orderHash);
            feeIndex++;
        }
        if (feeIndex != feeChargedOrderIndexes.length) revert InvalidSweepOrderIndex();
        _validateFeeAuthorization(
            affiliate, keccak256(abi.encode(orderHashes)), feeAuthorizationDeadline, feeAuthorizationSignature
        );
        uint256 balanceNativeBeforeFills = address(this).balance;
        bool[] memory fillsCompleted =
            _seaportAvailableFulfillmentCall(seaportFulfillAvailableCalldata, seaportTotalNativeValue);
        // Seaport refunds its caller everything it holds, so the balance can
        // rise over the fills when Seaport was pre-funded; only the drop is
        // the fills' spend.
        uint256 balanceAfterFills = address(this).balance;
        uint256 seaportNativeSpent =
            balanceNativeBeforeFills > balanceAfterFills ? balanceNativeBeforeFills - balanceAfterFills : 0;

        // Measure every fill delta before any other external call. The swept
        // currencies and the collections are reached by the later refunds,
        // approval clearing, fee computation, and fee distribution, and their
        // hooks can reenter Seaport to fill more of an order whose delta has
        // not been read yet.
        uint256[] memory fillNumerators = new uint256[](feeChargedOrderIndexes.length);
        uint256[] memory fillDenominators = new uint256[](feeChargedOrderIndexes.length);
        for (uint256 i = 0; i < feeChargedOrderIndexes.length; i++) {
            uint256 orderIndex = feeChargedOrderIndexes[i];
            if (orderIndex >= fillsCompleted.length) revert InvalidSweepOrderIndex();
            if (!fillsCompleted[orderIndex]) continue;
            (fillNumerators[i], fillDenominators[i]) = _orderFillDelta(orderHashes[i], fillStatusesBefore[i]);
        }

        for (uint256 i = 0; i < erc20s.length; i++) {
            IERC20 token = IERC20(erc20s[i]);
            uint256 balanceBeforeErc20 = balancesErc20Before[i];
            uint256 balanceAfterErc20 = token.balanceOf(address(this));
            _refundLeftoverErc20(token, balanceBeforeErc20, balanceAfterErc20);
            _disapproveSeaport(token);
        }

        Fees memory aggregateFees;
        Fees[] memory fillFees = new Fees[](feeChargedOrderIndexes.length);
        for (uint256 i = 0; i < feeChargedOrderIndexes.length; i++) {
            uint256 orderIndex = feeChargedOrderIndexes[i];
            if (!fillsCompleted[orderIndex]) continue;

            uint256 feeBaseAmount =
                _deriveNativeFeeBase(originalConsiderations[orderIndex], fillNumerators[i], fillDenominators[i]);
            address rewardsRecipient =
                scatterCollectionRegistry.rewardsRecipient(_listingCollection(orders[orderIndex]));
            Fees memory fees =
                _computeListingFee(feeBaseAmount, appliedFeeBps, appliedFeeSplitBps, affiliate, rewardsRecipient);
            fillFees[i] = fees;
            aggregateFees.totalAmount += fees.totalAmount;
            aggregateFees.platformAmount += fees.platformAmount;
            aggregateFees.rewardsAmount += fees.rewardsAmount;
            aggregateFees.affiliateAmount += fees.affiliateAmount;
            if (fees.affiliateAmount > 0) aggregateFees.affiliate = fees.affiliate;

            emit ExternalListingFilled(
                msg.sender,
                address(0),
                orderHashes[i],
                feeBaseAmount,
                fees.totalAmount,
                fees.affiliate,
                fees.rewardsRecipient,
                fees.platformAmount,
                fees.rewardsAmount,
                fees.affiliateAmount
            );
        }

        if (address(this).balance < balanceNativeBefore + aggregateFees.totalAmount) revert InsufficientPayment();

        _distributeSweepFeesNative(aggregateFees, fillFees);

        uint256 balanceAfterNative = address(this).balance;
        _refundLeftoverNative(msg.sender, balanceNativeBefore, balanceAfterNative);

        emit SweepFilled(
            msg.sender,
            seaportNativeSpent,
            aggregateFees.totalAmount,
            aggregateFees.platformAmount,
            aggregateFees.rewardsAmount,
            aggregateFees.affiliateAmount
        );
    }

    function sweepERC20(
        bytes calldata seaportFulfillAvailableCalldata,
        address erc20,
        uint256 seaportTotalErc20Amount,
        uint256[] calldata feeChargedOrderIndexes,
        address affiliate,
        uint256 feeAuthorizationDeadline,
        bytes calldata feeAuthorizationSignature,
        uint256 maximumFeeBps
    ) external nonReentrant whenNotPaused {
        uint256 appliedFeeBps = _validatedFeeBps(maximumFeeBps);
        uint256 appliedFeeSplitBps = feeSplitBps;
        if (erc20 == address(0) || seaportTotalErc20Amount == 0) {
            revert InvalidListingAmount();
        }
        if (
            seaportFulfillAvailableCalldata.length < 4
                || bytes4(seaportFulfillAvailableCalldata[0:4]) != FULFILL_AVAILABLE_ADVANCED_ORDERS_SELECTOR
        ) {
            revert InvalidSweepCalldataSelector();
        }
        AdvancedOrder[] memory orders = _decodeAndValidateSweepOrders(seaportFulfillAvailableCalldata[4:]);
        for (uint256 i = 0; i < feeChargedOrderIndexes.length; i++) {
            if (i > 0 && feeChargedOrderIndexes[i] <= feeChargedOrderIndexes[i - 1]) {
                revert InvalidSweepOrderIndex();
            }
        }

        bytes32[] memory orderHashes = new bytes32[](feeChargedOrderIndexes.length);
        ConsiderationItem[][] memory originalConsiderations = new ConsiderationItem[][](feeChargedOrderIndexes.length);
        OrderFillStatus[] memory fillStatusesBefore = new OrderFillStatus[](feeChargedOrderIndexes.length);
        uint256 maximumScatterFee;
        uint256 feeIndex;

        for (uint256 orderIndex = 0; orderIndex < orders.length; orderIndex++) {
            OrderParameters memory parameters = orders[orderIndex].parameters;
            if (!_requiresRouterFee(
                    orderIndex, parameters.orderType, parameters.offerer, feeChargedOrderIndexes, feeIndex
                )) {
                continue;
            }

            uint256 totalOriginalConsiderationItems = parameters.totalOriginalConsiderationItems;
            if (totalOriginalConsiderationItems != parameters.consideration.length) {
                revert InvalidTotalOriginalConsiderationItems();
            }
            ConsiderationItem[] memory originalConsideration = new ConsiderationItem[](totalOriginalConsiderationItems);
            for (uint256 j = 0; j < totalOriginalConsiderationItems; j++) {
                originalConsideration[j] = parameters.consideration[j];
            }

            bytes32 orderHash = _orderHash(orders[orderIndex], originalConsideration);
            for (uint256 j = 0; j < feeIndex; j++) {
                if (orderHashes[j] == orderHash) revert DuplicateSweepOrderHash();
            }
            orderHashes[feeIndex] = orderHash;
            uint256 feeBaseAmount = _deriveErc20FeeBase(
                parameters.orderType,
                originalConsideration,
                erc20,
                orders[orderIndex].numerator,
                orders[orderIndex].denominator
            );
            originalConsiderations[feeIndex] = originalConsideration;
            maximumScatterFee += Math.mulDiv(feeBaseAmount, appliedFeeBps, BPS_DENOMINATOR);
            feeIndex++;
        }
        if (feeIndex != feeChargedOrderIndexes.length) revert InvalidSweepOrderIndex();

        _validateFeeAuthorization(
            affiliate, keccak256(abi.encode(orderHashes)), feeAuthorizationDeadline, feeAuthorizationSignature
        );

        IERC20 token = IERC20(erc20);
        uint256 balanceBefore = token.balanceOf(address(this));
        _pullFunds(token, seaportTotalErc20Amount + maximumScatterFee);
        _approveSeaport(token, seaportTotalErc20Amount);
        uint256 balanceBeforeFills = token.balanceOf(address(this));
        // Snapshot the fill statuses only after the currency pull: its transfer
        // hooks can reenter Seaport, and those fills must not be charged.
        for (uint256 i = 0; i < orderHashes.length; i++) {
            fillStatusesBefore[i] = _getOrderFillStatus(orderHashes[i]);
        }
        bool[] memory fillsCompleted = _seaportAvailableFulfillmentCall(seaportFulfillAvailableCalldata, 0);

        // Measure every fill delta before any other external call. The currency
        // and the collections are reached by the later approval clearing, fee
        // computation, and fee distribution, and their hooks can reenter
        // Seaport to fill more of an order whose delta has not been read yet.
        uint256[] memory fillNumerators = new uint256[](feeChargedOrderIndexes.length);
        uint256[] memory fillDenominators = new uint256[](feeChargedOrderIndexes.length);
        for (uint256 i = 0; i < feeChargedOrderIndexes.length; i++) {
            uint256 orderIndex = feeChargedOrderIndexes[i];
            if (orderIndex >= fillsCompleted.length) revert InvalidSweepOrderIndex();
            if (!fillsCompleted[orderIndex]) continue;
            (fillNumerators[i], fillDenominators[i]) = _orderFillDelta(orderHashes[i], fillStatusesBefore[i]);
        }

        uint256 seaportAmountSpent = balanceBeforeFills - token.balanceOf(address(this));
        _disapproveSeaport(token);

        Fees memory aggregateFees;
        Fees[] memory fillFees = new Fees[](feeChargedOrderIndexes.length);
        for (uint256 i = 0; i < feeChargedOrderIndexes.length; i++) {
            uint256 orderIndex = feeChargedOrderIndexes[i];
            if (!fillsCompleted[orderIndex]) continue;
            uint256 feeBaseAmount = _deriveErc20FeeBase(
                orders[orderIndex].parameters.orderType,
                originalConsiderations[i],
                erc20,
                fillNumerators[i],
                fillDenominators[i]
            );
            address rewardsRecipient =
                scatterCollectionRegistry.rewardsRecipient(_listingCollection(orders[orderIndex]));
            Fees memory fees =
                _computeListingFee(feeBaseAmount, appliedFeeBps, appliedFeeSplitBps, affiliate, rewardsRecipient);
            fillFees[i] = fees;
            aggregateFees.totalAmount += fees.totalAmount;
            aggregateFees.platformAmount += fees.platformAmount;
            aggregateFees.rewardsAmount += fees.rewardsAmount;
            aggregateFees.affiliateAmount += fees.affiliateAmount;

            emit ExternalListingFilled(
                msg.sender,
                erc20,
                orderHashes[i],
                feeBaseAmount,
                fees.totalAmount,
                fees.affiliate,
                fees.rewardsRecipient,
                fees.platformAmount,
                fees.rewardsAmount,
                fees.affiliateAmount
            );
        }

        for (uint256 i = 0; i < fillFees.length; i++) {
            _distributeFeesErc20(token, fillFees[i]);
        }

        _refundLeftoverErc20(token, balanceBefore, token.balanceOf(address(this)));

        emit SweepERC20Filled(
            msg.sender,
            erc20,
            seaportAmountSpent,
            aggregateFees.totalAmount,
            aggregateFees.platformAmount,
            aggregateFees.rewardsAmount,
            aggregateFees.affiliateAmount
        );
    }

    function setFeeAuthorizer(address newFeeAuthorizer) external onlyOwner {
        if (newFeeAuthorizer == address(0)) revert InvalidFeeAuthorizer();
        emit FeeAuthorizerUpdated(feeAuthorizer, newFeeAuthorizer);
        feeAuthorizer = newFeeAuthorizer;
    }

    function setFeeBps(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert InvalidFeeBps();
        emit FeeBpsUpdated(feeBps, newFeeBps);
        feeBps = newFeeBps;
    }

    function setFeeSplitBps(uint256 newFeeSplitBps) external onlyOwner {
        if (newFeeSplitBps > BPS_DENOMINATOR) revert InvalidFeeSplitBps();
        emit FeeSplitBpsUpdated(feeSplitBps, newFeeSplitBps);
        feeSplitBps = newFeeSplitBps;
    }

    function _validatedFeeBps(uint256 maximumFeeBps) internal view returns (uint256 currentFeeBps) {
        currentFeeBps = feeBps;
        if (currentFeeBps > maximumFeeBps) revert FeeBpsExceedsLimit(currentFeeBps, maximumFeeBps);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _validateFeeAuthorization(
        address affiliate,
        bytes32 ordersHash,
        uint256 deadline,
        bytes calldata signature
    ) internal view {
        if (affiliate == address(0)) {
            if (signature.length != 0) revert InvalidFeeAuthorization();
            return;
        }
        if (block.timestamp > deadline) revert FeeAuthorizationExpired();
        if (deadline > block.timestamp + MAX_AUTHORIZATION_WINDOW) revert InvalidFeeAuthorization();

        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(FEE_AUTHORIZATION_TYPEHASH, msg.sender, affiliate, ordersHash, deadline))
        );
        if (ECDSA.recover(digest, signature) != feeAuthorizer) revert InvalidFeeAuthorization();
    }

    function _computeListingFee(
        uint256 listingPrice,
        uint256 appliedFeeBps,
        uint256 appliedFeeSplitBps,
        address affiliate,
        address rewardsRecipient
    ) internal pure returns (Fees memory fees) {
        if (affiliate != address(0)) {
            fees.totalAmount = Math.mulDiv(listingPrice, appliedFeeBps, BPS_DENOMINATOR);
            fees.platformAmount = Math.mulDiv(fees.totalAmount, appliedFeeSplitBps, BPS_DENOMINATOR);
            fees.affiliateAmount = fees.totalAmount - fees.platformAmount;
            fees.rewardsAmount = 0;
            fees.affiliate = affiliate;
            fees.rewardsRecipient = address(0);
            return fees;
        }

        if (rewardsRecipient != address(0)) {
            fees.totalAmount = Math.mulDiv(listingPrice, appliedFeeBps, BPS_DENOMINATOR);
            fees.platformAmount = Math.mulDiv(fees.totalAmount, appliedFeeSplitBps, BPS_DENOMINATOR);
            fees.affiliateAmount = 0;
            fees.rewardsAmount = fees.totalAmount - fees.platformAmount;
            fees.affiliate = address(0);
            fees.rewardsRecipient = rewardsRecipient;
            return fees;
        }

        fees.totalAmount = Math.mulDiv(listingPrice, appliedFeeBps, BPS_DENOMINATOR);
        fees.platformAmount = fees.totalAmount;
        fees.affiliateAmount = 0;
        fees.rewardsAmount = 0;
        fees.affiliate = address(0);
        fees.rewardsRecipient = address(0);
        return fees;
    }

    struct OrderFillStatus {
        uint256 filled;
        uint256 size;
    }

    function _decodeSingleOrder(bytes calldata seaportFulfillCalldata)
        internal
        view
        returns (AdvancedOrder memory order)
    {
        if (seaportFulfillCalldata.length < 4 || bytes4(seaportFulfillCalldata[0:4]) != FULFILL_ADVANCED_ORDER_SELECTOR)
        {
            revert InvalidFulfillmentCalldataSelector();
        }

        address recipient;
        (order,,, recipient) =
            abi.decode(seaportFulfillCalldata[4:], (AdvancedOrder, CriteriaResolver[], bytes32, address));
        // Seaport sends zero-recipient fills to its caller. Neither form may
        // leave NFTs in this router, which cannot send them on.
        if (recipient == address(0) || recipient == address(this)) revert InvalidFulfillmentRecipient();
    }

    function _listingCollection(AdvancedOrder memory order) internal pure returns (address collection) {
        if (order.parameters.orderType == OrderType.CONTRACT) revert UnsupportedContractOrder();

        for (uint256 i = 0; i < order.parameters.offer.length; i++) {
            OfferItem memory item = order.parameters.offer[i];
            if (
                item.itemType != ItemType.ERC721 && item.itemType != ItemType.ERC1155
                    && item.itemType != ItemType.ERC721_WITH_CRITERIA && item.itemType != ItemType.ERC1155_WITH_CRITERIA
            ) {
                continue;
            }

            if (collection == address(0)) {
                collection = item.token;
            } else if (collection != item.token) {
                revert InvalidListingCollection();
            }
        }

        if (collection == address(0)) revert InvalidListingCollection();
    }

    function _requiresRouterFee(
        uint256 orderIndex,
        OrderType orderType,
        address offerer,
        uint256[] calldata feeChargedOrderIndexes,
        uint256 feeIndex
    ) internal view returns (bool) {
        bool isFeeCharged =
            feeIndex < feeChargedOrderIndexes.length && feeChargedOrderIndexes[feeIndex] == orderIndex;
        if (orderType == OrderType.CONTRACT) {
            if (offerer != SCATTER_OFFERER) revert UnsupportedContractOrder();
            if (isFeeCharged) revert UnsupportedContractOrder();
            return false;
        }
        if (!isFeeCharged) revert InvalidSweepOrderIndex();
        return true;
    }

    function _originalConsideration(AdvancedOrder memory order)
        internal
        pure
        returns (ConsiderationItem[] memory originalConsideration)
    {
        // Consideration beyond the signed items is paid by Seaport but not
        // covered by the fee, so fee-charged orders must carry exactly the
        // signed items.
        uint256 totalOriginalConsiderationItems = order.parameters.totalOriginalConsiderationItems;
        if (totalOriginalConsiderationItems != order.parameters.consideration.length) {
            revert InvalidTotalOriginalConsiderationItems();
        }

        originalConsideration = new ConsiderationItem[](totalOriginalConsiderationItems);
        for (uint256 i = 0; i < totalOriginalConsiderationItems; i++) {
            originalConsideration[i] = order.parameters.consideration[i];
        }
    }

    function _orderHash(AdvancedOrder memory order, ConsiderationItem[] memory originalConsideration)
        internal
        view
        returns (bytes32)
    {
        OrderParameters memory parameters = order.parameters;
        OrderComponents memory components = OrderComponents({
            offerer: parameters.offerer,
            zone: parameters.zone,
            offer: parameters.offer,
            consideration: originalConsideration,
            orderType: parameters.orderType,
            startTime: parameters.startTime,
            endTime: parameters.endTime,
            zoneHash: parameters.zoneHash,
            salt: parameters.salt,
            conduitKey: parameters.conduitKey,
            counter: SeaportInterface(SEAPORT).getCounter(parameters.offerer)
        });
        return SeaportInterface(SEAPORT).getOrderHash(components);
    }

    function _validateNativeFeeOrder(AdvancedOrder memory order, ConsiderationItem[] memory originalConsideration)
        internal
        pure
    {
        // Contract orders return their consideration from `generateOrder` at fill
        // time; calldata contains only the minimum. ScatterOfferer charges its own
        // fee, so the router must not charge the contract order again.
        if (order.parameters.orderType == OrderType.CONTRACT) revert UnsupportedContractOrder();

        bool hasPositiveAmount;
        for (uint256 i = 0; i < originalConsideration.length; i++) {
            ConsiderationItem memory item = originalConsideration[i];
            if (item.itemType != ItemType.NATIVE) revert UnsupportedSweepCurrency();
            if (item.startAmount != item.endAmount) revert VariableSweepConsiderationAmount();
            if (item.startAmount > 0) hasPositiveAmount = true;
        }
        if (!hasPositiveAmount) revert InvalidListingAmount();
    }

    function _deriveNativeFeeBase(
        ConsiderationItem[] memory originalConsideration,
        uint256 fillNumerator,
        uint256 fillDenominator
    ) internal pure returns (uint256 feeBaseAmount) {
        for (uint256 i = 0; i < originalConsideration.length; i++) {
            feeBaseAmount += Math.mulDiv(
                originalConsideration[i].startAmount, fillNumerator, fillDenominator, Math.Rounding.Ceil
            );
        }
    }

    function _deriveErc20FeeBase(
        OrderType orderType,
        ConsiderationItem[] memory originalConsideration,
        address erc20,
        uint256 numerator,
        uint256 denominator
    ) internal pure returns (uint256 feeBaseAmount) {
        if (orderType == OrderType.CONTRACT) revert UnsupportedContractOrder();
        for (uint256 i = 0; i < originalConsideration.length; i++) {
            ConsiderationItem memory item = originalConsideration[i];
            if (item.itemType != ItemType.ERC20 || item.token != erc20) revert UnsupportedSweepCurrency();
            if (item.startAmount != item.endAmount) revert VariableSweepConsiderationAmount();
            feeBaseAmount += Math.mulDiv(item.startAmount, numerator, denominator, Math.Rounding.Ceil);
        }
        if (feeBaseAmount == 0) revert InvalidListingAmount();
    }

    function _decodeAndValidateSweepOrders(bytes calldata encodedArguments)
        internal
        view
        returns (AdvancedOrder[] memory orders)
    {
        bytes32 fulfillerConduitKey;
        address recipient;
        (orders,,,, fulfillerConduitKey, recipient,) = abi.decode(
            encodedArguments,
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
        if (fulfillerConduitKey != bytes32(0)) revert InvalidFulfillerConduitKey();
        if (recipient == address(0) || recipient == address(this)) revert InvalidSweepRecipient();
    }

    function _getOrderFillStatus(bytes32 orderHash) internal view returns (OrderFillStatus memory status) {
        (,, status.filled, status.size) = SeaportInterface(SEAPORT).getOrderStatus(orderHash);
    }

    function _orderFillDelta(bytes32 orderHash, OrderFillStatus memory beforeStatus)
        internal
        view
        returns (uint256 numerator, uint256 denominator)
    {
        OrderFillStatus memory afterStatus = _getOrderFillStatus(orderHash);
        uint256 beforeSize = beforeStatus.size == 0 ? 1 : beforeStatus.size;
        if (afterStatus.size == 0) revert OrderNotFilled(orderHash);

        uint256 afterScaled = afterStatus.filled * beforeSize;
        uint256 beforeScaled = beforeStatus.filled * afterStatus.size;
        if (afterScaled <= beforeScaled) revert OrderNotFilled(orderHash);

        numerator = afterScaled - beforeScaled;
        denominator = afterStatus.size * beforeSize;
    }

    struct SeaportFulfillAvailableExecutionReceivedItem {
        uint8 itemType;
        address token;
        uint256 identifier;
        uint256 amount;
        address recipient;
    }

    struct SeaportFulfillAvailableExecution {
        SeaportFulfillAvailableExecutionReceivedItem item;
        address offerer;
        bytes32 conduitKey;
    }

    function _seaportAvailableFulfillmentCall(bytes calldata seaportFulfillAvailableCalldata, uint256 amountNative)
        internal
        returns (bool[] memory fillsCompleted)
    {
        _activeRoutedFulfiller = msg.sender;
        (bool success, bytes memory result) = SEAPORT.call{value: amountNative}(seaportFulfillAvailableCalldata);
        _activeRoutedFulfiller = address(0);
        if (!success) revert SeaportCallFailed();
        if (result.length == 0) revert SeaportCallFailed();

        (fillsCompleted,) = abi.decode(result, (bool[], SeaportFulfillAvailableExecution[]));
    }

    function _seaportFulfillmentCall(bytes calldata seaportFulfillCalldata, uint256 value) internal {
        _activeRoutedFulfiller = msg.sender;
        (bool success, bytes memory returndata) = SEAPORT.call{value: value}(seaportFulfillCalldata);
        _activeRoutedFulfiller = address(0);
        if (!success) revert SeaportCallFailed();
        if (returndata.length != 32 || !abi.decode(returndata, (bool))) revert SeaportCallFailed();
    }

    function _distributeFeesNative(Fees memory fees) internal {
        if (fees.platformAmount > 0) {
            (bool success,) = PLATFORM.call{value: fees.platformAmount}("");
            if (!success) revert FeeTransferFailed();
        }

        if (fees.rewardsAmount > 0) {
            (bool success,) = fees.rewardsRecipient.call{value: fees.rewardsAmount}("");
            if (!success) revert FeeTransferFailed();
        }

        if (fees.affiliateAmount > 0) {
            (bool success,) = fees.affiliate.call{value: fees.affiliateAmount}("");
            if (!success) revert FeeTransferFailed();
        }
    }

    function _distributeSweepFeesNative(Fees memory aggregateFees, Fees[] memory fillFees) internal {
        if (aggregateFees.platformAmount > 0) {
            (bool platformSuccess,) = PLATFORM.call{value: aggregateFees.platformAmount}("");
            if (!platformSuccess) revert FeeTransferFailed();
        }

        for (uint256 i = 0; i < fillFees.length; i++) {
            Fees memory fees = fillFees[i];
            if (fees.rewardsAmount > 0) {
                (bool rewardsSuccess,) = fees.rewardsRecipient.call{value: fees.rewardsAmount}("");
                if (!rewardsSuccess) revert FeeTransferFailed();
            }
        }

        if (aggregateFees.affiliateAmount > 0) {
            (bool affiliateSuccess,) = aggregateFees.affiliate.call{value: aggregateFees.affiliateAmount}("");
            if (!affiliateSuccess) revert FeeTransferFailed();
        }
    }

    function _distributeFeesErc20(IERC20 token, Fees memory fees) internal {
        // SafeERC20 throughout: non-bool-returning tokens (USDT-style)
        // would revert the bool decode and brick the currency entirely
        if (fees.platformAmount > 0) {
            token.safeTransfer(PLATFORM, fees.platformAmount);
        }

        if (fees.rewardsAmount > 0) {
            token.safeTransfer(fees.rewardsRecipient, fees.rewardsAmount);
        }

        if (fees.affiliateAmount > 0) {
            token.safeTransfer(fees.affiliate, fees.affiliateAmount);
        }
    }

    function _approveSeaport(IERC20 token, uint256 amount) internal {
        // forceApprove: handles reset-to-zero tokens and missing bool returns
        token.forceApprove(SEAPORT, amount);
    }

    function _disapproveSeaport(IERC20 token) internal {
        token.forceApprove(SEAPORT, 0);
    }

    function _pullFunds(IERC20 token, uint256 amount) internal {
        ConduitTransfer[] memory transfers = new ConduitTransfer[](1);
        transfers[0] = ConduitTransfer(ConduitItemType.ERC20, address(token), msg.sender, address(this), 0, amount);
        _executeConduit(transfers);
    }

    function _refundLeftoverNative(address to, uint256 balanceBefore, uint256 balanceAfter) internal {
        if (balanceAfter <= balanceBefore) return;

        uint256 leftover = balanceAfter - balanceBefore;
        (bool success,) = to.call{value: leftover}("");
        if (!success) revert RefundFailed();
    }

    function _refundLeftoverErc20(IERC20 token, uint256 balanceBefore, uint256 balanceAfter) internal {
        if (balanceAfter <= balanceBefore) return;

        uint256 leftover = balanceAfter - balanceBefore;
        token.safeTransfer(msg.sender, leftover);
    }

    receive() external payable {}
}
