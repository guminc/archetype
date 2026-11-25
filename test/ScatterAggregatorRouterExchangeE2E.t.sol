// SPDX-License-Identifier: MIT
// forge-lint: disable-start(mixed-case-function, mixed-case-variable, asm-keccak256)
pragma solidity 0.8.36;

import {ConduitTest} from "./helpers/ConduitTest.sol";
import {
    ScatterAggregatorRouter,
    EmptyExchangeSweep,
    InsufficientPayment,
    InvalidExchangeCalldata,
    InvalidSweepRecipient
} from "../src/ScatterAggregatorRouter.sol";
import {ScatterExchange} from "../src/ScatterExchange.sol";
import {ScatterOfferer} from "../src/ScatterOfferer.sol";
import {ScatterCollectionRegistry} from "../src/ScatterCollectionRegistry.sol";
import {
    AdvancedOrder,
    ConsiderationItem,
    CriteriaResolver,
    FulfillmentComponent,
    OfferItem,
    Order,
    OrderComponents,
    OrderParameters,
    ReceivedItem,
    SpentItem
} from "seaport-types/src/lib/ConsiderationStructs.sol";
import {ItemType, OrderType} from "seaport-types/src/lib/ConsiderationEnums.sol";
import {SeaportInterface} from "seaport-types/src/interfaces/SeaportInterface.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IValidator {
    function createList(string calldata name) external returns (uint120 id);
    function addAccountsToWhitelist(uint120 id, address[] calldata accounts) external;
    function applyListToCollection(address collection, uint120 id) external;
    function validateTransfer(address caller, address from, address to, uint256 tokenId) external view;
}

contract CreatorToken721 is ERC721, Ownable {
    IValidator public immutable validator;

    constructor(IValidator validator_) ERC721("Creator Token", "CT") Ownable(msg.sender) {
        validator = validator_;
    }

    function mint(address to, uint256 tokenId) external onlyOwner {
        _mint(to, tokenId);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = super._update(to, tokenId, auth);
        if (from != address(0) && to != address(0)) {
            validator.validateTransfer(msg.sender, from, to, tokenId);
        }
    }
}

contract Open721 is ERC721 {
    constructor() ERC721("Open Token", "OT") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}

contract SweepErc20 is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ScatterAggregatorRouterExchangeE2ETest is ConduitTest {
    uint256 internal constant FEE_AUTHORIZER_PK = 0xA11CE;
    uint256 internal constant EXCHANGE_SELLER_PK = uint256(keccak256("exchangeSeller"));
    uint256 internal constant EXTERNAL_SELLER_PK = uint256(keccak256("externalSeller"));
    uint256 internal constant OFFERER_SELLER_PK = uint256(keccak256("offererSeller"));

    address internal owner = makeAddr("owner");
    address internal creator = makeAddr("creator");
    address internal buyer = makeAddr("buyer");
    address internal recipient = makeAddr("recipient");
    address internal affiliate = makeAddr("affiliate");
    address internal rewardsRecipient = makeAddr("rewardsRecipient");
    address internal feeAuthorizer = vm.addr(FEE_AUTHORIZER_PK);
    address internal exchangeSeller = vm.addr(EXCHANGE_SELLER_PK);
    address internal externalSeller = vm.addr(EXTERNAL_SELLER_PK);
    address internal offererSeller = vm.addr(OFFERER_SELLER_PK);

    ScatterCollectionRegistry internal registry;
    ScatterOfferer internal offerer;
    ScatterExchange internal exchange;
    ScatterAggregatorRouter internal router;
    SeaportInterface internal seaport;
    IValidator internal validator;
    CreatorToken721 internal creatorNft;
    Open721 internal openNft;
    SweepErc20 internal weth;

    bytes32 internal routerDomainSeparator;
    bytes32 internal seaportDomainSeparator;

    function setUp() public {
        _setUpConduit();
        string memory artifact = vm.readFile("test/fixtures/creator-token-transfer-validator.json");
        validator = IValidator(vm.parseJsonAddress(artifact, ".address"));
        vm.etch(address(validator), vm.parseJsonBytes(artifact, ".runtime"));

        registry = new ScatterCollectionRegistry(address(this));
        offerer = new ScatterOfferer(owner, registry, feeAuthorizer, conduitKey);
        exchange = new ScatterExchange(owner, registry, feeAuthorizer);
        router = new ScatterAggregatorRouter(
            owner, registry, feeAuthorizer, address(offerer), address(exchange), conduitKey
        );

        deployCodeTo("Seaport.sol:Seaport", abi.encode(address(conduitController)), router.SEAPORT());
        seaport = SeaportInterface(router.SEAPORT());

        _openConduitChannel(address(offerer));
        _openConduitChannel(address(router));
        _openConduitChannel(address(seaport));

        vm.startPrank(owner);
        offerer.setTrustedRouter(address(router), true);
        exchange.setTrustedRouter(address(router), true);
        vm.stopPrank();

        vm.startPrank(creator);
        creatorNft = new CreatorToken721(validator);
        creatorNft.mint(exchangeSeller, 1);
        creatorNft.mint(externalSeller, 2);
        // Whitelist ONLY ScatterExchange and Seaport (as OpenSea's operator).
        // ScatterAggregatorRouter is deliberately NOT whitelisted.
        uint120 listId = validator.createList("exchange-and-seaport");
        address[] memory allowed = new address[](2);
        allowed[0] = address(exchange);
        allowed[1] = address(seaport);
        validator.addAccountsToWhitelist(listId, allowed);
        validator.applyListToCollection(address(creatorNft), listId);
        vm.stopPrank();

        openNft = new Open721();
        openNft.mint(offererSeller, 3);
        weth = new SweepErc20();

        vm.prank(exchangeSeller);
        creatorNft.setApprovalForAll(address(exchange), true);
        vm.prank(externalSeller);
        creatorNft.setApprovalForAll(address(seaport), true);
        vm.prank(offererSeller);
        openNft.setApprovalForAll(address(conduit), true);

        vm.deal(buyer, 20 ether);
        vm.deal(address(router), 1 ether); // Pre-existing dust must never be spent or refunded.
        weth.mint(buyer, 20 ether);
        weth.mint(address(router), 1 ether);
        // Buyer approves ONLY the shared conduit — never ScatterExchange or router directly.
        vm.prank(buyer);
        weth.approve(address(conduit), type(uint256).max);

        routerDomainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("ScatterAggregatorRouter"),
                keccak256("1"),
                block.chainid,
                address(router)
            )
        );
        (, bytes32 domainSep,) = seaport.information();
        seaportDomainSeparator = domainSep;
    }

    function test_e2e_sweepMixedWithExchange_nativeCreatorTokenWithExternalAndAffiliate() public {
        ScatterExchange.ScatterSubmission memory submission =
            _exchangeListing(address(creatorNft), 1, address(0), 1 ether);
        ScatterExchange.FillInput[] memory inputs = _exchangeInput(submission, EXCHANGE_SELLER_PK, 1);
        uint256 deadline = block.timestamp + 1 hours;

        (AdvancedOrder memory externalOrder, bytes32 externalHash) =
            _signedExternalListing(address(creatorNft), 2, address(0), 2 ether, EXTERNAL_SELLER_PK, 1);
        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = externalOrder;
        bytes memory seaportData = _encodeSweep(orders, recipient);

        uint256[] memory feeIndexes = new uint256[](1);
        feeIndexes[0] = 0;
        bytes32[] memory orderHashes = new bytes32[](1);
        orderHashes[0] = externalHash;

        bytes memory exchangeCalldata = abi.encodeCall(
            ScatterExchange.buyListings,
            (inputs, recipient, affiliate, deadline, _signExchangeAuth(buyer, affiliate, inputs, deadline))
        );

        uint256 buyerBefore = buyer.balance;
        uint256 exchangeSellerBefore = exchangeSeller.balance;
        uint256 externalSellerBefore = externalSeller.balance;
        uint256 platformBefore = router.PLATFORM().balance;
        uint256 affiliateBefore = affiliate.balance;

        vm.expectEmit(true, true, true, true, address(exchange));
        emit ScatterExchange.ScatterSale({
            submissionHash: exchange.hashSubmission(submission),
            role: uint8(ScatterExchange.Role.Listing),
            seller: exchangeSeller,
            buyer: buyer,
            collection: address(creatorNft),
            itemIndex: 0,
            tokenId: 1,
            quantity: 1,
            currency: address(0),
            totalPrice: 1 ether,
            affiliate: affiliate,
            rewardsRecipient: address(0),
            sellerAmount: 0.95 ether,
            platformAmount: 0.025 ether,
            rewardsAmount: 0,
            affiliateAmount: 0.025 ether
        });

        bytes memory routerSig = _signRouterAuth(buyer, affiliate, orderHashes, deadline);
        ScatterAggregatorRouter.SeaportMixedSweep memory seaportSweep = ScatterAggregatorRouter.SeaportMixedSweep({
            fulfillAvailableCalldata: seaportData,
            totalNativeValue: 2 ether,
            feeChargedOrderIndexes: feeIndexes,
            erc20s: new address[](0),
            erc20Amounts: new uint256[](0),
            affiliate: affiliate,
            feeAuthorizationDeadline: deadline,
            feeAuthorizationSignature: routerSig,
            maximumFeeBps: 500
        });

        vm.prank(buyer);
        router.sweepMixedWithExchange{value: 3.6 ether}(seaportSweep, exchangeCalldata, 1 ether);

        assertEq(creatorNft.ownerOf(1), recipient);
        assertEq(creatorNft.ownerOf(2), recipient);
        assertEq(buyerBefore - buyer.balance, 3.1 ether);
        assertEq(exchangeSeller.balance - exchangeSellerBefore, 0.95 ether);
        assertEq(externalSeller.balance - externalSellerBefore, 2 ether);
        assertEq(router.PLATFORM().balance - platformBefore, 0.075 ether);
        assertEq(affiliate.balance - affiliateBefore, 0.075 ether);
        assertEq(address(router).balance, 1 ether);
    }

    function test_e2e_sweepERC20WithExchange_erc20CreatorTokenThroughSharedConduit() public {
        registry.setRewardsOverride(address(creatorNft), rewardsRecipient);

        ScatterExchange.ScatterSubmission memory submission =
            _exchangeListing(address(creatorNft), 1, address(weth), 1 ether);
        ScatterExchange.FillInput[] memory inputs = _exchangeInput(submission, EXCHANGE_SELLER_PK, 1);

        (AdvancedOrder memory externalOrder,) =
            _signedExternalListing(address(creatorNft), 2, address(weth), 2 ether, EXTERNAL_SELLER_PK, 2);
        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = externalOrder;
        bytes memory seaportData = _encodeSweep(orders, recipient);

        uint256[] memory feeIndexes = new uint256[](1);
        feeIndexes[0] = 0;

        bytes memory exchangeCalldata =
            abi.encodeCall(ScatterExchange.buyListings, (inputs, recipient, address(0), 0, ""));

        uint256 buyerBefore = weth.balanceOf(buyer);

        vm.prank(buyer);
        router.sweepERC20WithExchange(
            ScatterAggregatorRouter.SeaportErc20Sweep({
                fulfillAvailableCalldata: seaportData,
                erc20: address(weth),
                totalErc20Amount: 2 ether,
                feeChargedOrderIndexes: feeIndexes,
                affiliate: address(0),
                feeAuthorizationDeadline: 0,
                feeAuthorizationSignature: "",
                maximumFeeBps: 500
            }),
            exchangeCalldata,
            1 ether
        );

        assertEq(creatorNft.ownerOf(1), recipient);
        assertEq(creatorNft.ownerOf(2), recipient);
        assertEq(buyerBefore - weth.balanceOf(buyer), 3.1 ether);
        assertEq(weth.balanceOf(exchangeSeller), 0.95 ether);
        assertEq(weth.balanceOf(externalSeller), 2 ether);
        assertEq(weth.balanceOf(router.PLATFORM()), 0.075 ether);
        assertEq(weth.balanceOf(rewardsRecipient), 0.075 ether);
        assertEq(weth.balanceOf(address(router)), 1 ether);
        assertEq(weth.allowance(address(router), address(exchange)), 0);
        assertEq(weth.allowance(address(router), address(seaport)), 0);
    }

    function test_e2e_sweepMixedWithExchange_combinesExchangeOffererAndExternalInOneTx() public {
        ScatterExchange.ScatterSubmission memory exSub = _exchangeListing(address(creatorNft), 1, address(0), 1 ether);
        ScatterExchange.FillInput[] memory exInputs = _exchangeInput(exSub, EXCHANGE_SELLER_PK, 1);

        (AdvancedOrder memory externalOrder,) =
            _signedExternalListing(address(creatorNft), 2, address(0), 2 ether, EXTERNAL_SELLER_PK, 3);
        AdvancedOrder memory offererOrder = _signedOffererListing(address(openNft), 3, 0.5 ether, OFFERER_SELLER_PK);

        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = offererOrder;
        orders[1] = externalOrder;
        bytes memory seaportData = _encodeSweep(orders, recipient);

        uint256[] memory feeIndexes = new uint256[](1);
        feeIndexes[0] = 1; // Only the external order is charged by the router.

        bytes memory exchangeCalldata =
            abi.encodeCall(ScatterExchange.buyListings, (exInputs, recipient, address(0), 0, ""));

        uint256 buyerBefore = buyer.balance;
        vm.prank(buyer);
        router.sweepMixedWithExchange{value: 3.6 ether}(
            ScatterAggregatorRouter.SeaportMixedSweep({
                fulfillAvailableCalldata: seaportData,
                totalNativeValue: 2.5 ether,
                feeChargedOrderIndexes: feeIndexes,
                erc20s: new address[](0),
                erc20Amounts: new uint256[](0),
                affiliate: address(0),
                feeAuthorizationDeadline: 0,
                feeAuthorizationSignature: "",
                maximumFeeBps: 500
            }),
            exchangeCalldata,
            1 ether
        );

        assertEq(creatorNft.ownerOf(1), recipient);
        assertEq(creatorNft.ownerOf(2), recipient);
        assertEq(openNft.ownerOf(3), recipient);
        assertEq(buyerBefore - buyer.balance, 3.6 ether);
        assertEq(address(router).balance, 1 ether);
    }

    function test_e2e_sweepMixedWithExchange_partialExternalFillRefundsUnspentWhileKeepingExchangeFill() public {
        vm.prank(creator);
        creatorNft.mint(externalSeller, 4);

        ScatterExchange.ScatterSubmission memory exSub = _exchangeListing(address(creatorNft), 1, address(0), 1 ether);
        ScatterExchange.FillInput[] memory exInputs = _exchangeInput(exSub, EXCHANGE_SELLER_PK, 1);

        (AdvancedOrder memory cancelledExternal,) =
            _signedExternalListing(address(creatorNft), 2, address(0), 2 ether, EXTERNAL_SELLER_PK, 4);
        (AdvancedOrder memory liveExternal,) =
            _signedExternalListing(address(creatorNft), 4, address(0), 1 ether, EXTERNAL_SELLER_PK, 44);
        // External seller cancels token 2 before sweep so Seaport fills token 4 and refunds token 2 + its fee.
        OrderComponents[] memory toCancel = new OrderComponents[](1);
        toCancel[0] = OrderComponents({
            offerer: cancelledExternal.parameters.offerer,
            zone: cancelledExternal.parameters.zone,
            offer: cancelledExternal.parameters.offer,
            consideration: cancelledExternal.parameters.consideration,
            orderType: cancelledExternal.parameters.orderType,
            startTime: cancelledExternal.parameters.startTime,
            endTime: cancelledExternal.parameters.endTime,
            zoneHash: cancelledExternal.parameters.zoneHash,
            salt: cancelledExternal.parameters.salt,
            conduitKey: cancelledExternal.parameters.conduitKey,
            counter: seaport.getCounter(externalSeller)
        });
        vm.prank(externalSeller);
        seaport.cancel(toCancel);

        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = cancelledExternal;
        orders[1] = liveExternal;
        bytes memory seaportData = _encodeSweep(orders, recipient);
        uint256[] memory feeIndexes = new uint256[](2);
        feeIndexes[0] = 0;
        feeIndexes[1] = 1;

        bytes memory exchangeCalldata =
            abi.encodeCall(ScatterExchange.buyListings, (exInputs, recipient, address(0), 0, ""));

        uint256 buyerBefore = buyer.balance;
        vm.prank(buyer);
        router.sweepMixedWithExchange{value: 4.15 ether}(
            ScatterAggregatorRouter.SeaportMixedSweep({
                fulfillAvailableCalldata: seaportData,
                totalNativeValue: 3 ether,
                feeChargedOrderIndexes: feeIndexes,
                erc20s: new address[](0),
                erc20Amounts: new uint256[](0),
                affiliate: address(0),
                feeAuthorizationDeadline: 0,
                feeAuthorizationSignature: "",
                maximumFeeBps: 500
            }),
            exchangeCalldata,
            1 ether
        );

        assertEq(creatorNft.ownerOf(1), recipient);
        assertEq(creatorNft.ownerOf(2), externalSeller);
        assertEq(creatorNft.ownerOf(4), recipient);
        // Paid 1 ETH exchange + 1 ETH live external + 0.05 ETH fee = 2.05 ETH; 2.10 ETH refunded.
        assertEq(buyerBefore - buyer.balance, 2.05 ether);
        assertEq(address(router).balance, 1 ether);
    }

    function test_e2e_sweepMixedWithExchange_validatesInputsAndRollsBackAtomically() public {
        ScatterExchange.ScatterSubmission memory exSub = _exchangeListing(address(creatorNft), 1, address(0), 1 ether);
        ScatterExchange.FillInput[] memory exInputs = _exchangeInput(exSub, EXCHANGE_SELLER_PK, 1);

        (AdvancedOrder memory externalOrder, bytes32 externalHash) =
            _signedExternalListing(address(creatorNft), 2, address(0), 2 ether, EXTERNAL_SELLER_PK, 5);
        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = externalOrder;
        bytes memory seaportData = _encodeSweep(orders, recipient);
        uint256[] memory feeIndexes = new uint256[](1);
        feeIndexes[0] = 0;
        bytes32[] memory orderHashes = new bytes32[](1);
        orderHashes[0] = externalHash;

        ScatterAggregatorRouter.SeaportMixedSweep memory baseSeaport = ScatterAggregatorRouter.SeaportMixedSweep({
            fulfillAvailableCalldata: seaportData,
            totalNativeValue: 2 ether,
            feeChargedOrderIndexes: feeIndexes,
            erc20s: new address[](0),
            erc20Amounts: new uint256[](0),
            affiliate: address(0),
            feeAuthorizationDeadline: 0,
            feeAuthorizationSignature: "",
            maximumFeeBps: 500
        });

        // 1. Wrong selector or empty inputs revert.
        vm.prank(buyer);
        vm.expectRevert(InvalidExchangeCalldata.selector);
        router.sweepMixedWithExchange{value: 2.1 ether}(baseSeaport, abi.encodeWithSignature("incrementCounter()"), 0);

        bytes memory emptyCalldata = abi.encodeCall(
            ScatterExchange.buyListings, (new ScatterExchange.FillInput[](0), recipient, address(0), 0, "")
        );
        vm.prank(buyer);
        vm.expectRevert(EmptyExchangeSweep.selector);
        router.sweepMixedWithExchange{value: 2.1 ether}(baseSeaport, emptyCalldata, 0);

        // 2. Invalid recipient (zero or router itself) reverts.
        bytes memory badRecipientCalldata =
            abi.encodeCall(ScatterExchange.buyListings, (exInputs, address(router), address(0), 0, ""));
        vm.prank(buyer);
        vm.expectRevert(InvalidSweepRecipient.selector);
        router.sweepMixedWithExchange{value: 3.1 ether}(baseSeaport, badRecipientCalldata, 1 ether);

        // 3. Underfunded msg.value reverts even though router holds 1 ETH dust.
        bytes memory validCalldata =
            abi.encodeCall(ScatterExchange.buyListings, (exInputs, recipient, address(0), 0, ""));
        vm.prank(buyer);
        vm.expectRevert(InsufficientPayment.selector);
        router.sweepMixedWithExchange{value: 2.9 ether}(baseSeaport, validCalldata, 1 ether);

        // 4. Exchange affiliate signature bound to router instead of buyer reverts.
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory routerBoundCalldata = abi.encodeCall(
            ScatterExchange.buyListings,
            (
                exInputs,
                recipient,
                affiliate,
                deadline,
                _signExchangeAuth(address(router), affiliate, exInputs, deadline)
            )
        );
        ScatterAggregatorRouter.SeaportMixedSweep memory affiliateSeaport = ScatterAggregatorRouter.SeaportMixedSweep({
            fulfillAvailableCalldata: seaportData,
            totalNativeValue: 2 ether,
            feeChargedOrderIndexes: feeIndexes,
            erc20s: new address[](0),
            erc20Amounts: new uint256[](0),
            affiliate: affiliate,
            feeAuthorizationDeadline: deadline,
            feeAuthorizationSignature: _signRouterAuth(buyer, affiliate, orderHashes, deadline),
            maximumFeeBps: 500
        });
        vm.prank(buyer);
        vm.expectRevert(ScatterExchange.InvalidFeeAuthorization.selector);
        router.sweepMixedWithExchange{value: 3.1 ether}(affiliateSeaport, routerBoundCalldata, 1 ether);

        // 5. Cancelled exchange listing reverts entire sweep atomically; external NFT stays with seller.
        ScatterExchange.CancelListingItem[] memory cancelItems = new ScatterExchange.CancelListingItem[](1);
        cancelItems[0] =
            ScatterExchange.CancelListingItem({submissionHash: exchange.hashSubmission(exSub), itemIndex: 0});
        vm.prank(exchangeSeller);
        exchange.cancelListings(cancelItems);

        vm.prank(buyer);
        vm.expectRevert(ScatterExchange.OrderCancelled.selector);
        router.sweepMixedWithExchange{value: 3.1 ether}(baseSeaport, validCalldata, 1 ether);
        assertEq(creatorNft.ownerOf(1), exchangeSeller);
        assertEq(creatorNft.ownerOf(2), externalSeller);
        assertEq(address(router).balance, 1 ether);
    }

    function _exchangeListing(address collection, uint256 tokenId, address currency, uint256 price)
        internal
        view
        returns (ScatterExchange.ScatterSubmission memory submission)
    {
        submission.role = ScatterExchange.Role.Listing;
        submission.listings = new ScatterExchange.ScatterListing[](1);
        submission.listings[0] = ScatterExchange.ScatterListing({
            assetType: ScatterExchange.AssetType.ERC721,
            collection: collection,
            tokenId: tokenId,
            quantity: 1,
            currency: currency,
            priceWei: price
        });
        submission.maxFeeBps = 500;
        submission.startTime = block.timestamp;
        submission.endTime = block.timestamp + 1 hours;
        submission.salt = bytes32(tokenId);
    }

    function _exchangeInput(ScatterExchange.ScatterSubmission memory submission, uint256 sellerPk, uint256 tokenId)
        internal
        view
        returns (ScatterExchange.FillInput[] memory inputs)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sellerPk, exchange.hashSubmission(submission));
        ScatterExchange.ScatterFill[] memory fills = new ScatterExchange.ScatterFill[](1);
        fills[0] = ScatterExchange.ScatterFill({itemIndex: 0, tokenId: tokenId, quantity: 1});
        inputs = new ScatterExchange.FillInput[](1);
        inputs[0] = ScatterExchange.FillInput({
            submission: submission,
            submissionSig: abi.encodePacked(r, s, v),
            fills: fills,
            criteriaProofs: new bytes32[][](0)
        });
    }

    function _signedExternalListing(
        address collection,
        uint256 tokenId,
        address currency,
        uint256 price,
        uint256 sellerPk,
        uint256 salt
    ) internal view returns (AdvancedOrder memory advancedOrder, bytes32 orderHash) {
        address maker = vm.addr(sellerPk);
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem({
            itemType: ItemType.ERC721, token: collection, identifierOrCriteria: tokenId, startAmount: 1, endAmount: 1
        });
        ConsiderationItem[] memory consideration = new ConsiderationItem[](1);
        consideration[0] = ConsiderationItem({
            itemType: currency == address(0) ? ItemType.NATIVE : ItemType.ERC20,
            token: currency,
            identifierOrCriteria: 0,
            startAmount: price,
            endAmount: price,
            recipient: payable(maker)
        });
        OrderParameters memory params = OrderParameters({
            offerer: maker,
            zone: address(0),
            offer: offer,
            consideration: consideration,
            orderType: OrderType.FULL_OPEN,
            startTime: block.timestamp,
            endTime: block.timestamp + 1 hours,
            zoneHash: bytes32(0),
            salt: salt,
            conduitKey: bytes32(0),
            totalOriginalConsiderationItems: 1
        });
        orderHash = seaport.getOrderHash(
            OrderComponents({
                offerer: maker,
                zone: address(0),
                offer: offer,
                consideration: consideration,
                orderType: OrderType.FULL_OPEN,
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours,
                zoneHash: bytes32(0),
                salt: salt,
                conduitKey: bytes32(0),
                counter: seaport.getCounter(maker)
            })
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", seaportDomainSeparator, orderHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sellerPk, digest);
        advancedOrder = AdvancedOrder({
            parameters: params, numerator: 1, denominator: 1, signature: abi.encodePacked(r, s, v), extraData: ""
        });
    }

    function _signedOffererListing(address collection, uint256 tokenId, uint256 price, uint256 sellerPk)
        internal
        view
        returns (AdvancedOrder memory)
    {
        ScatterOfferer.ScatterListing[] memory listings = new ScatterOfferer.ScatterListing[](1);
        listings[0] = ScatterOfferer.ScatterListing({
            assetType: ScatterOfferer.AssetType.ERC721,
            collection: collection,
            tokenId: tokenId,
            quantity: 1,
            currency: address(0),
            priceWei: price
        });
        ScatterOfferer.ScatterSubmission memory submission = ScatterOfferer.ScatterSubmission({
            role: ScatterOfferer.Role.Listing,
            listings: listings,
            criteriaRoot: bytes32(0),
            maxFeeBps: 500,
            startTime: block.timestamp,
            endTime: block.timestamp + 1 hours,
            nonce: 0,
            salt: bytes32(tokenId)
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sellerPk, offerer.hashSubmission(submission));
        ScatterOfferer.ScatterFill[] memory fills = new ScatterOfferer.ScatterFill[](1);
        fills[0] = ScatterOfferer.ScatterFill({itemIndex: 0, tokenId: tokenId, quantity: 1});
        bytes memory extraData = abi.encode(
            submission, abi.encodePacked(r, s, v), address(0), fills, new bytes32[][](0), uint256(0), bytes("")
        );
        (SpentItem[] memory previewOffer, ReceivedItem[] memory previewCons) =
            offerer.previewOrder(buyer, buyer, new SpentItem[](0), new SpentItem[](0), extraData);
        OfferItem[] memory offer = new OfferItem[](previewOffer.length);
        for (uint256 i; i < previewOffer.length; ++i) {
            offer[i] = OfferItem({
                itemType: previewOffer[i].itemType,
                token: previewOffer[i].token,
                identifierOrCriteria: previewOffer[i].identifier,
                startAmount: previewOffer[i].amount,
                endAmount: previewOffer[i].amount
            });
        }
        ConsiderationItem[] memory cons = new ConsiderationItem[](previewCons.length);
        for (uint256 i; i < previewCons.length; ++i) {
            cons[i] = ConsiderationItem({
                itemType: previewCons[i].itemType,
                token: previewCons[i].token,
                identifierOrCriteria: previewCons[i].identifier,
                startAmount: previewCons[i].amount,
                endAmount: previewCons[i].amount,
                recipient: previewCons[i].recipient
            });
        }
        return AdvancedOrder({
            parameters: OrderParameters({
                offerer: address(offerer),
                zone: address(0),
                offer: offer,
                consideration: cons,
                orderType: OrderType.CONTRACT,
                startTime: submission.startTime,
                endTime: submission.endTime,
                zoneHash: bytes32(0),
                salt: 0,
                conduitKey: bytes32(0),
                totalOriginalConsiderationItems: cons.length
            }),
            numerator: 1,
            denominator: 1,
            signature: "",
            extraData: extraData
        });
    }

    function _encodeSweep(AdvancedOrder[] memory orders, address nftRecipient) internal pure returns (bytes memory) {
        uint256 offerCount;
        uint256 consCount;
        for (uint256 i; i < orders.length; ++i) {
            offerCount += orders[i].parameters.offer.length;
            consCount += orders[i].parameters.consideration.length;
        }
        FulfillmentComponent[][] memory offerFulfillments = new FulfillmentComponent[][](offerCount);
        FulfillmentComponent[][] memory consFulfillments = new FulfillmentComponent[][](consCount);
        uint256 o;
        uint256 c;
        for (uint256 i; i < orders.length; ++i) {
            for (uint256 j; j < orders[i].parameters.offer.length; ++j) {
                offerFulfillments[o] = new FulfillmentComponent[](1);
                offerFulfillments[o][0] = FulfillmentComponent({orderIndex: i, itemIndex: j});
                o++;
            }
            for (uint256 j; j < orders[i].parameters.consideration.length; ++j) {
                consFulfillments[c] = new FulfillmentComponent[](1);
                consFulfillments[c][0] = FulfillmentComponent({orderIndex: i, itemIndex: j});
                c++;
            }
        }
        return abi.encodeWithSelector(
            SeaportInterface.fulfillAvailableAdvancedOrders.selector,
            orders,
            new CriteriaResolver[](0),
            offerFulfillments,
            consFulfillments,
            bytes32(0),
            nftRecipient,
            orders.length
        );
    }

    function _signExchangeAuth(
        address fulfiller,
        address affiliate_,
        ScatterExchange.FillInput[] memory inputs,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Scatter Exchange"),
                keccak256("1"),
                block.chainid,
                address(exchange)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                exchange.FEE_AUTHORIZATION_TYPEHASH(), fulfiller, affiliate_, keccak256(abi.encode(inputs)), deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(FEE_AUTHORIZER_PK, keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _signRouterAuth(address buyer_, address affiliate_, bytes32[] memory orderHashes, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                router.FEE_AUTHORIZATION_TYPEHASH(), buyer_, affiliate_, keccak256(abi.encode(orderHashes)), deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(FEE_AUTHORIZER_PK, keccak256(abi.encodePacked("\x19\x01", routerDomainSeparator, structHash)));
        return abi.encodePacked(r, s, v);
    }
}
