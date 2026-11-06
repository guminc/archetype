// SPDX-License-Identifier: MIT
// forge-lint: disable-start(mixed-case-function, mixed-case-variable, asm-keccak256)
pragma solidity 0.8.36;

import {ScatterAggregatorRouter, ScatterAggregatorRouterE2ETest} from "./ScatterAggregatorRouterE2E.t.sol";
import {ERC1820Registry} from "./helpers/ERC1820Registry.sol";
import {ERC1820Implementer} from "openzeppelin-v4/utils/introspection/ERC1820Implementer.sol";
import {IERC777Recipient} from "openzeppelin-v4/token/ERC777/IERC777Recipient.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    AdvancedOrder,
    CriteriaResolver,
    Order,
    OrderComponents,
    OrderParameters
} from "seaport-types/src/lib/ConsiderationStructs.sol";
import {SeaportInterface} from "seaport-types/src/interfaces/SeaportInterface.sol";
import {OrderLib} from "seaport-sol/lib/OrderLib.sol";
import {OrderParametersLib} from "seaport-sol/lib/OrderParametersLib.sol";

/// Sweep fees must be charged only on the fills the buyer's own sweep executed.
///
/// The fee loop in sweepERC20 reads each completed order's fill delta from Seaport
/// immediately before distributing that order's fees. A currency whose transfers
/// notify registered recipients (ERC777-style hooks on the ERC20 path) lets a
/// rewards recipient reenter Seaport while an earlier order's rewards is being
/// paid and fill more of a later order with its own funds. Seaport has already
/// returned, so its reentrancy guard is down and the direct fill succeeds. When
/// the router then reads the later order's fill status, the foreign fill is
/// included and the buyer is charged its fee.
///
/// The scenario: the buyer sweeps three ERC20-priced listings best effort. Order
/// A (full fill) belongs to a collection whose registered rewards recipient is a
/// contract controlled by order B's seller. Order B (100 ERC1155 units) is
/// requested at half. Order C is cancelled, so Seaport skips it and its funds
/// stay as refund slack. During A's rewards payment the recipient buys B's
/// remaining half directly on Seaport with its own funds and its own NFT
/// recipient, completing B on-chain. The buyer must still be charged only for
/// the half of B their sweep filled.
contract ScatterAggregatorRouterE2ESweepReentrancyTest is ScatterAggregatorRouterE2ETest {
    using OrderLib for Order;
    using OrderParametersLib for OrderParameters;

    uint256 internal constant SELLER_A_PK = uint256(keccak256("sellerA"));
    uint256 internal constant SELLER_C_PK = uint256(keccak256("sellerC"));

    ERC1820Registry internal erc1820Registry;
    CallbackErc20 internal token;
    ReentrantRewardsRecipient internal rewardsReentrant;
    OwnedErc1155 internal attackerCollection;
    address internal sellerA;
    address internal sellerC;
    address internal attackerNftRecipient;

    function setUp() public override {
        super.setUp();
        sellerA = vm.addr(SELLER_A_PK);
        sellerC = vm.addr(SELLER_C_PK);
        attackerNftRecipient = makeAddr("attackerNftRecipient");

        erc1820Registry = new ERC1820Registry();
        token = new CallbackErc20(erc1820Registry);
        rewardsReentrant = new ReentrantRewardsRecipient(erc1820Registry, seaport, token, attackerNftRecipient);

        // Order B's seller owns the collection; its rewards recipient (the
        // collection owner) is the callback contract.
        attackerCollection = new OwnedErc1155(seller);
        attackerCollection.mint(sellerA, 1, 10);
        _prank(seller);
        attackerCollection.transferOwnership(address(rewardsReentrant));

        address[] memory collections = new address[](1);
        collections[0] = address(attackerCollection);
        _prank(address(this));
        scatterCollectionRegistry.registerScatterCollections(collections);

        _prank(sellerA);
        attackerCollection.setApprovalForAll(SEAPORT, true);

        nft721.mint(sellerC, 3);
        _prank(sellerC);
        nft721.setApprovalForAll(SEAPORT, true);

        token.mint(buyer, 158_550);
        token.mint(address(rewardsReentrant), 50_000);
    }

    function test_e2e_sweepErc20ChargesFeesOnlyForSweepExecutedFills() public {
        Order memory orderA =
            _buildErc1155Order(sellerA, SELLER_A_PK, address(attackerCollection), 1, 10, address(token), 1_000);
        Order memory orderB = _buildErc1155Order(seller, SELLER_PK, address(nft1155), 1, 100, address(token), 100_000);
        Order memory orderC = _buildErc20Order(sellerC, SELLER_C_PK, address(nft721), 3, address(token), 100_000);

        // Pull order C off the market so the sweep skips it (listing unavailable).
        OrderComponents[] memory orderCComponents = new OrderComponents[](1);
        orderCComponents[0] = orderC.parameters.toOrderComponents(seaport.getCounter(sellerC));
        _prank(sellerC);
        seaport.cancel(orderCComponents);

        bytes32 orderHashA = seaport.getOrderHash(orderA.parameters.toOrderComponents(seaport.getCounter(sellerA)));
        bytes32 orderHashB = seaport.getOrderHash(orderB.parameters.toOrderComponents(seaport.getCounter(seller)));

        AdvancedOrder[] memory orders = new AdvancedOrder[](3);
        orders[0] = orderA.toAdvancedOrder(1, 1, ""); // full fill
        orders[1] = orderB.toAdvancedOrder(1, 2, ""); // buyer requests half
        orders[2] = orderC.toAdvancedOrder(1, 1, ""); // full fill, unavailable

        // Arm the rewards recipient to buy B's remaining half directly on Seaport
        // the moment it receives A's rewards.
        rewardsReentrant.arm(orderB.toAdvancedOrder(1, 2, ""), 50_000);

        uint256 seaportTotalErc20Amount = 151_000; // A (1,000) + half of B (50,000) + C (100,000)
        uint256 maximumScatterFee = 7_550; // 5% of the three requested fills

        uint256[] memory feeChargedOrderIndexes = new uint256[](3);
        feeChargedOrderIndexes[0] = 0;
        feeChargedOrderIndexes[1] = 1;
        feeChargedOrderIndexes[2] = 2;

        uint256 buyerTokenBefore = token.balanceOf(buyer);
        uint256 platformTokenBefore = token.balanceOf(PLATFORM);
        uint256 sellerATokenBefore = token.balanceOf(sellerA);
        uint256 sellerBTokenBefore = token.balanceOf(seller);

        _prank(buyer);
        token.approve(address(conduit), seaportTotalErc20Amount + maximumScatterFee);

        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.ExternalListingFilled(
            buyer, address(token), orderHashA, 1_000, 50, address(0), address(rewardsReentrant), 25, 25, 0
        );
        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.ExternalListingFilled(
            buyer, address(token), orderHashB, 50_000, 2_500, address(0), address(0), 2_500, 0, 0
        );

        subject.sweepERC20(
            _generateSweepCalldata(orders, buyer),
            address(token),
            seaportTotalErc20Amount,
            feeChargedOrderIndexes,
            address(0),
            0,
            "",
            500
        );

        // The callback fired during A's rewards payment and completed order B on
        // Seaport. Both half-fills landed on the order, so it reports fully
        // filled: numerator 2 of denominator 2 (the sweep alone would leave 1
        // of 2).
        assertTrue(rewardsReentrant.triggered());
        (,, uint256 filledB, uint256 sizeB) = seaport.getOrderStatus(orderHashB);
        assertEq(filledB, 2);
        assertEq(sizeB, 2);

        // The buyer keeps exactly what their sweep bought; the callback's
        // purchase went to the attacker's own recipient.
        assertEq(attackerCollection.balanceOf(buyer, 1), 10);
        assertEq(nft1155.balanceOf(buyer, 1), 50);
        assertEq(nft1155.balanceOf(attackerNftRecipient, 1), 50);
        assertEq(nft721.ownerOf(3), sellerC);

        // Buyer pays 51,000 to Seaport (A plus half of B) plus 2,550 in fees:
        // 53,550 total. A callback fill of the other half of B must not add the
        // 2,500 fee on it to the buyer's debit, and the refund must stay whole.
        assertEq(buyerTokenBefore - token.balanceOf(buyer), 53_550);
        assertEq(token.balanceOf(buyer), 105_000);

        // Fees cover only the sweep's fills: A's 50 (25 platform, 25 rewards)
        // and B's half at 2,500, all to the platform.
        assertEq(token.balanceOf(PLATFORM) - platformTokenBefore, 2_525);
        // The recipient was prefunded 50,000, spent it on the purchase, and
        // kept only the 25-token rewards.
        assertEq(token.balanceOf(address(rewardsReentrant)), 25);

        // Sellers were paid for every unit that actually changed hands.
        assertEq(token.balanceOf(sellerA) - sellerATokenBefore, 1_000);
        assertEq(token.balanceOf(seller) - sellerBTokenBefore, 100_000);

        // The router refunds the unused pull and holds nothing.
        assertEq(token.balanceOf(address(subject)), 0);
        assertEq(token.allowance(address(subject), SEAPORT), 0);
    }
}

/// ERC20 whose transfers notify recipients that registered an
/// ERC777TokensRecipient implementer in the ERC1820 registry, mirroring the
/// ERC777 hook on its ERC20-compatible path. Unlike full ERC777, transfers to
/// contracts that never registered still succeed, so ordinary participants
/// (including the router) can hold the token; only the opting-in recipient is
/// called back.
contract CallbackErc20 is ERC20 {
    ERC1820Registry internal immutable registry;
    bytes32 internal constant TOKENS_RECIPIENT_INTERFACE_HASH = keccak256("ERC777TokensRecipient");

    constructor(ERC1820Registry registry_) ERC20("CallbackE2E", "CBE2E") {
        registry = registry_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from == address(0)) {
            return;
        }
        address implementer = registry.getInterfaceImplementer(to, TOKENS_RECIPIENT_INTERFACE_HASH);
        if (implementer != address(0)) {
            IERC777Recipient(implementer).tokensReceived(msg.sender, from, to, value, "", "");
        }
    }
}

/// Rewards recipient that fills a prepared Seaport order directly when it
/// receives tokens. It funds the purchase itself and takes the NFTs at its own
/// recipient address.
contract ReentrantRewardsRecipient is ERC1820Implementer, IERC777Recipient {
    bytes32 private constant TOKENS_RECIPIENT_INTERFACE_HASH = keccak256("ERC777TokensRecipient");

    SeaportInterface private immutable seaport;
    IERC20 private immutable token;
    address private immutable nftRecipient;
    AdvancedOrder private orderToFill;
    bool public triggered;

    constructor(ERC1820Registry registry, SeaportInterface seaport_, IERC20 token_, address nftRecipient_) {
        seaport = seaport_;
        token = token_;
        nftRecipient = nftRecipient_;
        _registerInterfaceForAddress(TOKENS_RECIPIENT_INTERFACE_HASH, address(this));
        registry.setInterfaceImplementer(address(this), TOKENS_RECIPIENT_INTERFACE_HASH, address(this));
    }

    function arm(AdvancedOrder calldata order, uint256 purchaseAmount) external {
        orderToFill = order;
        token.approve(address(seaport), purchaseAmount);
    }

    function tokensReceived(address, address, address, uint256, bytes calldata, bytes calldata) external override {
        require(msg.sender == address(token), "untrusted token");
        require(!triggered, "already triggered");
        triggered = true;
        bool filled = seaport.fulfillAdvancedOrder(orderToFill, new CriteriaResolver[](0), bytes32(0), nftRecipient);
        require(filled, "reentrant fill failed");
    }
}

contract OwnedErc1155 is ERC1155, Ownable {
    constructor(address initialOwner) ERC1155("") Ownable(initialOwner) {}

    function mint(address to, uint256 tokenId, uint256 amount) external {
        _mint(to, tokenId, amount, "");
    }
}

/// Sweep fees must be charged only on the fills the buyer's own sweep
/// executed, whatever the swept currency does between the pull and the refund.
/// The router hands the currency control at three points — the pull, the
/// Seaport allowance reset after the fills, and the leftover refund — and a
/// hooked currency can fill more of a swept order directly on Seaport there,
/// since Seaport has already returned. Every fill delta is read around the
/// router's own Seaport call, before any other external call, so those fills
/// are never charged to the buyer.
contract ScatterAggregatorRouterE2ESweepCurrencyHookTest is ScatterAggregatorRouterE2ETest {
    using OrderLib for Order;
    using OrderParametersLib for OrderParameters;

    ReenteringErc20 internal token;
    DirectFiller internal filler;
    address internal attackerNftRecipient;

    function setUp() public override {
        super.setUp();
        attackerNftRecipient = makeAddr("attackerNftRecipient");
        token = new ReenteringErc20(SEAPORT, address(subject), address(conduit));
        filler = new DirectFiller(seaport, attackerNftRecipient);
        vm.deal(address(filler), 1 ether);

        token.mint(buyer, 60_000);
        token.mint(address(filler), 50_000);
        vm.startPrank(address(filler));
        token.approve(SEAPORT, 50_000);
        vm.stopPrank();
        vm.startPrank(buyer);
        token.approve(address(conduit), 60_000);
        vm.stopPrank();
    }

    function test_e2e_sweepErc20IgnoresFillsMadeDuringTheCurrencyPull() public {
        token.arm(ReenteringErc20.Trigger.Pull, address(filler));

        Order memory orderB = _buildErc1155Order(seller, SELLER_PK, address(nft1155), 1, 100, address(token), 100_000);
        bytes32 orderHashB = seaport.getOrderHash(orderB.parameters.toOrderComponents(seaport.getCounter(seller)));
        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = orderB.toAdvancedOrder(1, 2, "");
        uint256[] memory feeChargedOrderIndexes = new uint256[](1);
        feeChargedOrderIndexes[0] = 0;

        // The currency hands control to the filler during the pull, before the
        // sweep's Seaport call runs, and the filler buys order B's other half
        // with its own funds.
        filler.arm(orderB.toAdvancedOrder(1, 2, ""), 0);

        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.ExternalListingFilled(
            buyer, address(token), orderHashB, 50_000, 2_500, address(0), address(0), 2_500, 0, 0
        );

        _prank(buyer);
        subject.sweepERC20(
            _generateSweepCalldata(orders, buyer),
            address(token),
            50_000,
            feeChargedOrderIndexes,
            address(0),
            0,
            "",
            500
        );

        assertTrue(filler.triggered());
        (,, uint256 filledB, uint256 sizeB) = seaport.getOrderStatus(orderHashB);
        assertEq(filledB, 2);
        assertEq(sizeB, 2);

        // The buyer's sweep bought half; the filler's direct purchase took the
        // rest to its own recipient.
        assertEq(nft1155.balanceOf(buyer, 1), 50);
        assertEq(nft1155.balanceOf(attackerNftRecipient, 1), 50);

        // The buyer is charged only for the half their sweep filled: 50,000 to
        // Seaport plus the 2,500 fee on it.
        assertEq(token.balanceOf(buyer), 7_500);
        assertEq(token.balanceOf(PLATFORM), 2_500);
        assertEq(token.balanceOf(seller), 100_000);

        assertEq(token.balanceOf(address(subject)), 0);
        assertEq(token.allowance(address(subject), SEAPORT), 0);
    }

    function test_e2e_sweepErc20IgnoresFillsMadeDuringTheSeaportAllowanceReset() public {
        token.arm(ReenteringErc20.Trigger.Disapprove, address(filler));

        Order memory orderB = _buildErc1155Order(seller, SELLER_PK, address(nft1155), 1, 100, address(token), 100_000);
        bytes32 orderHashB = seaport.getOrderHash(orderB.parameters.toOrderComponents(seaport.getCounter(seller)));
        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = orderB.toAdvancedOrder(1, 2, "");
        uint256[] memory feeChargedOrderIndexes = new uint256[](1);
        feeChargedOrderIndexes[0] = 0;

        // The currency hands control to the filler while the router resets its
        // Seaport allowance, after the sweep's fills, and the filler buys
        // order B's remaining half with its own funds.
        filler.arm(orderB.toAdvancedOrder(1, 2, ""), 0);

        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.ExternalListingFilled(
            buyer, address(token), orderHashB, 50_000, 2_500, address(0), address(0), 2_500, 0, 0
        );

        _prank(buyer);
        subject.sweepERC20(
            _generateSweepCalldata(orders, buyer),
            address(token),
            50_000,
            feeChargedOrderIndexes,
            address(0),
            0,
            "",
            500
        );

        assertTrue(filler.triggered());
        (,, uint256 filledB, uint256 sizeB) = seaport.getOrderStatus(orderHashB);
        assertEq(filledB, 2);
        assertEq(sizeB, 2);

        assertEq(nft1155.balanceOf(buyer, 1), 50);
        assertEq(nft1155.balanceOf(attackerNftRecipient, 1), 50);

        assertEq(token.balanceOf(buyer), 7_500);
        assertEq(token.balanceOf(PLATFORM), 2_500);
        assertEq(token.balanceOf(seller), 100_000);

        assertEq(token.balanceOf(address(subject)), 0);
        assertEq(token.allowance(address(subject), SEAPORT), 0);
    }

    function test_e2e_sweepMixedIgnoresFillsMadeDuringTheCurrencyRefund() public {
        token.arm(ReenteringErc20.Trigger.Refund, address(filler));

        Order memory orderN = _buildErc1155Order(seller, SELLER_PK, address(nft1155), 1, 100, address(0), 1 ether);
        bytes32 orderHashN = seaport.getOrderHash(orderN.parameters.toOrderComponents(seaport.getCounter(seller)));
        AdvancedOrder[] memory orders = new AdvancedOrder[](1);
        orders[0] = orderN.toAdvancedOrder(1, 2, "");
        uint256[] memory feeChargedOrderIndexes = new uint256[](1);
        feeChargedOrderIndexes[0] = 0;

        // The currency hands control to the filler when the leftover refund lands
        // back on the buyer, and the filler buys order N's remaining half with
        // its own native value.
        filler.arm(orderN.toAdvancedOrder(1, 2, ""), 0.5 ether);

        address[] memory erc20s = new address[](1);
        erc20s[0] = address(token);
        uint256[] memory erc20Amounts = new uint256[](1);
        erc20Amounts[0] = 1_000;

        uint256 platformNativeBefore = PLATFORM.balance;
        uint256 sellerNativeBefore = seller.balance;

        vm.expectEmit(true, true, true, true);
        emit ScatterAggregatorRouter.ExternalListingFilled(
            buyer, address(0), orderHashN, 0.5 ether, 0.025 ether, address(0), address(0), 0.025 ether, 0, 0
        );

        _prank(buyer);
        subject.sweepMixed{value: 0.6 ether}(
            _generateSweepCalldata(orders, buyer),
            0.5 ether,
            feeChargedOrderIndexes,
            erc20s,
            erc20Amounts,
            address(0),
            0,
            "",
            500
        );

        assertTrue(filler.triggered());
        (,, uint256 filledN, uint256 sizeN) = seaport.getOrderStatus(orderHashN);
        assertEq(filledN, 2);
        assertEq(sizeN, 2);

        assertEq(nft1155.balanceOf(buyer, 1), 50);
        assertEq(nft1155.balanceOf(attackerNftRecipient, 1), 50);

        // The buyer is charged only for the half their sweep filled: 0.5 ether
        // to Seaport plus the 0.025 ether fee on it.
        assertEq(buyer.balance, 10 ether - 0.525 ether);
        assertEq(PLATFORM.balance - platformNativeBefore, 0.025 ether);
        assertEq(seller.balance - sellerNativeBefore, 1 ether);

        // The pulled currency came back whole.
        assertEq(token.balanceOf(buyer), 60_000);
        assertEq(token.balanceOf(address(subject)), 0);
    }
}

/// ERC20 that hands control to the configured filler at one chosen point the
/// router reaches — the pull (transferFrom), the Seaport allowance reset
/// (approve to Seaport for zero), or the leftover refund (transfer) —
/// standing in for a currency whose hooks run attacker code.
contract ReenteringErc20 is ERC20 {
    enum Trigger {
        None,
        Pull,
        Disapprove,
        Refund
    }

    Trigger public trigger = Trigger.None;
    address public hook;
    address private immutable seaport;
    address private immutable router;
    address private immutable pullSpender;

    constructor(address seaport_, address router_, address pullSpender_) ERC20("HookE2E", "HKE2E") {
        seaport = seaport_;
        router = router_;
        pullSpender = pullSpender_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(Trigger trigger_, address hook_) external {
        trigger = trigger_;
        hook = hook_;
    }

    function _reenter() private {
        if (hook == address(0)) return;
        address filler = hook;
        hook = address(0);
        DirectFiller(filler).reenter();
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        bool ok = super.transferFrom(from, to, value);
        if (trigger == Trigger.Pull && msg.sender == pullSpender && to == router) _reenter();
        return ok;
    }

    function approve(address spender, uint256 value) public override returns (bool) {
        bool ok = super.approve(spender, value);
        if (trigger == Trigger.Disapprove && msg.sender == router && spender == seaport && value == 0) _reenter();
        return ok;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        bool ok = super.transfer(to, value);
        if (trigger == Trigger.Refund && msg.sender == router) _reenter();
        return ok;
    }
}

/// Fills a prepared Seaport order directly when the hooked currency hands it
/// control. It funds the purchase itself and takes the NFTs at its own
/// recipient address.
contract DirectFiller {
    SeaportInterface private immutable seaport;
    address private immutable nftRecipient;
    AdvancedOrder private orderToFill;
    uint256 private valueToSend;
    bool public triggered;

    constructor(SeaportInterface seaport_, address nftRecipient_) {
        seaport = seaport_;
        nftRecipient = nftRecipient_;
    }

    function arm(AdvancedOrder calldata order, uint256 valueToSend_) external {
        orderToFill = order;
        valueToSend = valueToSend_;
    }

    function reenter() external {
        require(!triggered, "already triggered");
        triggered = true;
        bool filled = seaport.fulfillAdvancedOrder{value: valueToSend}(
            orderToFill, new CriteriaResolver[](0), bytes32(0), nftRecipient
        );
        require(filled, "reentrant fill failed");
    }
}
