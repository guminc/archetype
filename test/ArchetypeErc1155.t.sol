// SPDX-License-Identifier: MIT
// forge-lint: disable-start(mixed-case-function, mixed-case-variable)
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ArchetypeBatch} from "../src/ArchetypeBatch.sol";
import {ArchetypePayouts, BalanceEmpty as PayoutBalanceEmpty, NotApprovedToWithdraw} from "../src/ArchetypePayouts.sol";
import {ArchetypeErc1155, Config, PayoutConfig, Invite, Auth} from "../src/ERC1155/ArchetypeErc1155.sol";
import {
    AdvancedInvite,
    NotOwner,
    WalletUnauthorizedToMint,
    MintNotYetStarted,
    MintEnded,
    MintingPaused,
    InvalidSignature,
    InvalidTokenId,
    NotShareholder,
    BalanceEmpty,
    LockedForever,
    InsufficientEthSent,
    MaxSupplyExceeded,
    ListMaxSupplyExceeded,
    NumberOfMintsExceeded,
    NotApprovedToTransfer,
    Erc20BalanceTooLow,
    MintToZeroAddress,
    ArchetypeAddresses
} from "../src/ERC1155/ArchetypeLogicErc1155.sol";
import {FactoryErc1155, InsufficientDeployFee} from "../src/ERC1155/FactoryErc1155.sol";
import {TestErc20} from "../src/TestErc20.sol";

contract ArchetypeErc1155Test is Test {
    address internal constant PLATFORM = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address internal constant BATCH = 0x5FbDB2315678afecb367f032d93F642f64180aa3;
    address internal constant PAYOUTS = 0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0;
    bytes32 internal constant PUBLIC_KEY = bytes32(uint256(1));
    bytes32 internal constant ZERO_KEY = bytes32(0);
    bytes32 internal constant CID_ZERO = bytes32(0);
    uint256 internal constant FIRST_TOKEN_ID = 1;
    uint256 internal constant AFFILIATE_SIGNER_PK = 0xA11CE;
    uint256 internal constant WRONG_AFFILIATE_SIGNER_PK = 0xB0B;

    ArchetypeErc1155 internal archetypeImplementation;
    FactoryErc1155 internal factory;

    address internal owner;
    address internal buyer;
    address internal other;
    address internal affiliateSigner;

    Config internal defaultConfig;
    PayoutConfig internal defaultPayoutConfig;

    function setUp() public {
        owner = makeAddr("owner");
        buyer = makeAddr("buyer");
        other = makeAddr("other");
        affiliateSigner = vm.addr(AFFILIATE_SIGNER_PK);

        vm.deal(owner, 100 ether);
        vm.deal(buyer, 100 ether);
        vm.deal(other, 100 ether);
        vm.deal(affiliateSigner, 100 ether);
        vm.deal(PLATFORM, 100 ether);

        uint32[] memory maxSupply = new uint32[](3);
        maxSupply[0] = 5000;
        maxSupply[1] = 5000;
        maxSupply[2] = 5000;

        defaultConfig = Config({
            baseUri: "ipfs://bafkreieqcdphcfojcd2vslsxrhzrjqr6cxjlyuekpghzehfexi5c3w55eq/",
            affiliateSigner: affiliateSigner,
            maxSupply: maxSupply,
            maxBatchSize: 20,
            affiliateFee: 1500,
            affiliateDiscount: 0,
            defaultRoyalty: 500
        });
        defaultPayoutConfig = PayoutConfig({
            ownerBps: 9500,
            platformBps: 500,
            partnerBps: 0,
            superAffiliateBps: 0,
            partner: address(0),
            superAffiliate: address(0),
            ownerAltPayout: address(0)
        });

        ArchetypePayouts payoutsImpl = new ArchetypePayouts();
        vm.etch(PAYOUTS, address(payoutsImpl).code);

        ArchetypeBatch batchImpl = new ArchetypeBatch();
        vm.etch(BATCH, address(batchImpl).code);

        archetypeImplementation = new ArchetypeErc1155(PLATFORM, PAYOUTS, BATCH);

        _prank(owner);
        factory = new FactoryErc1155(address(archetypeImplementation), owner);

        _prank(other);
    }

    function test_archetypeAddresses_returnsConstructorAddresses() public view {
        ArchetypeAddresses memory addrs = archetypeImplementation.archetypeAddresses();

        assertEq(addrs.platform, PLATFORM);
        assertEq(addrs.payouts, PAYOUTS);
        assertEq(addrs.batch, BATCH);
    }

    function test_createCollection_initializesClone() public {
        _prank(other);
        ArchetypeErc1155 collection = _createCollection(owner);

        assertEq(collection.symbol(), "POOKIE");
        assertEq(collection.owner(), owner);
    }

    function test_initialize_failsWhenCalledTwice() public {
        _prank(other);
        archetypeImplementation.initialize("Flookie", "POOKIE", defaultConfig, defaultPayoutConfig, owner);

        assertEq(archetypeImplementation.name(), "Flookie");

        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        archetypeImplementation.initialize("Wookie", "POOKIE", defaultConfig, defaultPayoutConfig, owner);
    }

    function test_createCollection_failsWhenDeployFeeNotPaid() public {
        _prank(owner);
        factory.setDeployFee(0.1 ether);

        _prank(other);
        vm.expectRevert(InsufficientDeployFee.selector);
        factory.createCollection(owner, "Pookie", "POOKIE", defaultConfig, defaultPayoutConfig);
    }

    function test_setDeployFee_failsWhenCallerIsNotOwner() public {
        _prank(other);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        factory.setDeployFee(0.1 ether);
    }

    function test_lockURI_failsWhenCallerIsNotOwner() public {
        ArchetypeErc1155 collection = _createCollection(owner);

        _prank(other);
        vm.expectRevert(NotOwner.selector);
        collection.lockURI("forever");
    }

    function test_mint_mintsWhenPublicInviteIsSet() public {
        ArchetypeErc1155 collection = _createCollection(owner);

        _setInvite(collection, PUBLIC_KEY, _defaultInvite(0.1 ether));

        _prank(buyer);
        collection.mintToken{value: 0.1 ether}(_publicAuth(), 1, FIRST_TOKEN_ID, address(0), "");

        assertEq(collection.balanceOf(buyer, FIRST_TOKEN_ID), 1);
    }

    function test_mint_mintsWhenWalletIsOnValidSingleLeafList() public {
        ArchetypeErc1155 collection = _createCollection(owner);
        bytes32 allowlistRoot = keccak256(abi.encodePacked(buyer));

        _setInvite(collection, allowlistRoot, _defaultInvite(0.1 ether));

        _prank(buyer);
        collection.mintToken{value: 0.1 ether}(_auth(allowlistRoot), 1, FIRST_TOKEN_ID, address(0), "");

        assertEq(collection.balanceOf(buyer, FIRST_TOKEN_ID), 1);
    }

    function test_mint_failsWhenWalletIsNotOnList() public {
        ArchetypeErc1155 collection = _createCollection(owner);
        bytes32 allowlistRoot = keccak256(abi.encodePacked(buyer));

        _setInvite(collection, allowlistRoot, _defaultInvite(0.1 ether));

        _prank(other);
        vm.expectRevert(WalletUnauthorizedToMint.selector);
        collection.mintToken{value: 0.1 ether}(_auth(allowlistRoot), 1, FIRST_TOKEN_ID, address(0), "");
    }

    function test_mint_failsWhenDefaultPublicInviteIsPaused() public {
        ArchetypeErc1155 collection = _createCollection(owner);

        _prank(buyer);
        vm.expectRevert(MintingPaused.selector);
        collection.mintToken{value: 0.1 ether}(_auth(ZERO_KEY), 1, FIRST_TOKEN_ID, address(0), "");
    }

    function test_mint_failsWhenInviteNotYetStarted() public {
        ArchetypeErc1155 collection = _createCollection(owner);
        Invite memory invite = _defaultInvite(0.08 ether);
        invite.start = uint32(block.timestamp + 1 days);

        _setInvite(collection, PUBLIC_KEY, invite);

        _prank(buyer);
        vm.expectRevert(MintNotYetStarted.selector);
        collection.mintToken{value: 0.08 ether}(_publicAuth(), 1, FIRST_TOKEN_ID, address(0), "");
    }

    function test_mint_failsWhenInviteEnded() public {
        ArchetypeErc1155 collection = _createCollection(owner);
        Invite memory invite = _defaultInvite(0.08 ether);
        invite.end = uint32(block.timestamp + 1 hours);

        _setInvite(collection, PUBLIC_KEY, invite);

        vm.warp(block.timestamp + 1 hours + 1);

        _prank(buyer);
        vm.expectRevert(MintEnded.selector);
        collection.mintToken{value: 0.08 ether}(_publicAuth(), 1, FIRST_TOKEN_ID, address(0), "");
    }

    function test_mint_failsWhenFixedPriceInviteIsUnderpaid() public {
        ArchetypeErc1155 collection = _createCollection(owner);

        _setInvite(collection, PUBLIC_KEY, _defaultInvite(0.08 ether));

        _prank(buyer);
        vm.expectRevert(InsufficientEthSent.selector);
        collection.mintToken{value: 0.079 ether}(_publicAuth(), 1, FIRST_TOKEN_ID, address(0), "");
    }

    function test_mint_failsWhenPublicInviteLimitIsZero() public {
        ArchetypeErc1155 collection = _createCollection(owner);
        Invite memory invite = _defaultInvite(0.08 ether);
        invite.limit = 0;

        _setInvite(collection, PUBLIC_KEY, invite);

        _prank(buyer);
        vm.expectRevert(MintingPaused.selector);
        collection.mintToken{value: 0.08 ether}(_publicAuth(), 1, FIRST_TOKEN_ID, address(0), "");
    }

    function test_createCollection_paidDeployFeeCreditsPlatformAndRefundsExcess() public {
        ArchetypePayouts payouts = ArchetypePayouts(PAYOUTS);

        _prank(owner);
        factory.setDeployFee(0.05 ether);

        _prank(owner);
        factory.createCollection{value: 0.05 ether}(owner, "Pookie", "POOKIE", defaultConfig, defaultPayoutConfig);

        assertEq(payouts.balance(PLATFORM), 0.05 ether);
        assertEq(address(factory).balance, 0);

        vm.warp(block.timestamp + 1);
        vm.txGasPrice(0);
        uint256 ownerBalanceBefore = owner.balance;

        _prank(owner);
        factory.createCollection{value: 0.1 ether}(owner, "Pookie", "POOKIE", defaultConfig, defaultPayoutConfig);

        assertEq(ownerBalanceBefore - owner.balance, 0.05 ether);
        assertEq(payouts.balance(PLATFORM), 0.1 ether);
        assertEq(address(factory).balance, 0);
    }

    function test_affiliateSignatureValidation_withdrawsToCorrectAccount() public {
        ArchetypeErc1155 collection = _createCollection(owner);
        ArchetypePayouts payouts = ArchetypePayouts(PAYOUTS);
        address affiliate = makeAddr("affiliate");
        vm.deal(affiliate, 100 ether);

        bytes memory invalidSignature = _affiliateSignatureWithPk(affiliate, WRONG_AFFILIATE_SIGNER_PK);
        bytes memory validSignature = _affiliateSignature(affiliate);
        address[] memory tokens = _nativeTokenList();

        _setInvite(collection, PUBLIC_KEY, _defaultInvite(0.08 ether));

        _prank(buyer);
        vm.expectRevert(InvalidSignature.selector);
        collection.mintToken{value: 0.08 ether}(_publicAuth(), 1, FIRST_TOKEN_ID, affiliate, invalidSignature);

        _prank(buyer);
        collection.mintToken{value: 0.08 ether}(_publicAuth(), 1, FIRST_TOKEN_ID, affiliate, validSignature);

        // fee breakdown:
        //   mintPrice        = 0.08 ether
        //   ownerBalance     = 0.08 ether * 8500 / 10000 = 0.068 ether
        //   affiliateBalance = 0.08 ether * 1500 / 10000 = 0.012 ether
        assertEq(collection.ownerBalance(), 0.068 ether);
        assertEq(collection.affiliateBalance(affiliate), 0.012 ether);

        _prank(owner);
        collection.withdraw();

        // fee breakdown:
        //   ownerBalance   = 0.068 ether
        //   ownerPayout    = 0.068 ether * 9500 / 10000 = 0.0646 ether
        //   platformPayout = 0.068 ether * 500 / 10000  = 0.0034 ether
        assertEq(payouts.balance(owner), 0.0646 ether);
        assertEq(payouts.balance(PLATFORM), 0.0034 ether);

        vm.txGasPrice(0);
        uint256 ownerBalanceBefore = owner.balance;
        _prank(owner);
        payouts.withdraw();
        assertEq(owner.balance - ownerBalanceBefore, 0.0646 ether);

        _prank(buyer);
        collection.mintToken{value: 0.08 ether}(_publicAuth(), 1, FIRST_TOKEN_ID, affiliate, validSignature);
        // fee breakdown:
        //   firstAffiliateCredit  = 0.08 ether * 1500 / 10000 = 0.012 ether
        //   secondAffiliateCredit = 0.08 ether * 1500 / 10000 = 0.012 ether
        //   totalAffiliateBalance = 0.012 ether * 2 = 0.024 ether
        assertEq(collection.affiliateBalance(affiliate), 0.024 ether);

        _prank(PLATFORM);
        collection.withdraw();

        // fee breakdown:
        //   previousPlatformPayout = 0.0034 ether
        //   secondPlatformPayout   = 0.0034 ether
        //   totalPlatformPayout    = 0.0034 ether * 2 = 0.0068 ether
        assertEq(payouts.balance(owner), 0.0646 ether);
        assertEq(payouts.balance(PLATFORM), 0.0068 ether);

        uint256 ownerBalanceBefore2 = owner.balance;
        _prank(owner);
        payouts.withdraw();
        assertEq(owner.balance - ownerBalanceBefore2, 0.0646 ether);

        uint256 platformBalanceBefore = PLATFORM.balance;
        _prank(PLATFORM);
        payouts.withdraw();
        assertEq(PLATFORM.balance - platformBalanceBefore, 0.0068 ether);

        _prank(affiliate);
        vm.expectRevert(NotShareholder.selector);
        collection.withdraw();

        uint256 affiliateBalanceBefore = affiliate.balance;
        _prank(affiliate);
        collection.withdrawAffiliate();
        // fee breakdown:
        //   firstAffiliateCredit  = 0.08 ether * 1500 / 10000 = 0.012 ether
        //   secondAffiliateCredit = 0.08 ether * 1500 / 10000 = 0.012 ether
        //   affiliatePayout       = 0.012 ether * 2 = 0.024 ether
        assertEq(affiliate.balance - affiliateBalanceBefore, 0.024 ether);

        _prank(affiliate);
        vm.expectRevert(BalanceEmpty.selector);
        collection.withdrawAffiliate();

        _prank(owner);
        vm.expectRevert(PayoutBalanceEmpty.selector);
        payouts.withdraw();

        _prank(PLATFORM);
        vm.expectRevert(PayoutBalanceEmpty.selector);
        payouts.withdrawTokens(tokens);
    }

    function test_config_ownerCanUpdateAndLockMutableFields() public {
        ArchetypeErc1155 collection = _createCollection(owner);
        address altPayout = makeAddr("altPayout");

        _prank(owner);
        collection.setBaseURI("ipfs://updated/");
        // uri(tokenId) encodes baseUri + tokenId, so checking uri(1) reveals the baseUri
        assertEq(collection.uri(1), "ipfs://updated/1");

        collection.lockURI("forever");
        vm.expectRevert(LockedForever.selector);
        collection.setBaseURI("ipfs://locked/");

        uint32[] memory newMaxSupply = new uint32[](3);
        newMaxSupply[0] = 100;
        newMaxSupply[1] = 100;
        newMaxSupply[2] = 100;
        collection.setMaxSupply(newMaxSupply, "forever");
        assertEq(collection.maxSupply()[0], 100);
        assertEq(collection.maxSupply()[1], 100);
        assertEq(collection.maxSupply()[2], 100);

        collection.lockMaxSupply("forever");
        vm.expectRevert(LockedForever.selector);
        collection.setMaxSupply(newMaxSupply, "forever");

        collection.setAffiliateFee(1000);
        assertEq(_configAffiliateFee(collection), 1000);

        collection.setAffiliateDiscount(1000);
        assertEq(_configAffiliateDiscount(collection), 1000);

        collection.lockAffiliateFee("forever");
        vm.expectRevert(LockedForever.selector);
        collection.setAffiliateFee(20);

        collection.setOwnerAltPayout(altPayout);
        assertEq(_payoutOwnerAltPayout(collection), altPayout);

        collection.lockOwnerAltPayout("forever");
        vm.expectRevert(LockedForever.selector);
        collection.setOwnerAltPayout(other);
    }

    function test_config_lockAffiliateFeeAlsoLocksAffiliateDiscount() public {
        ArchetypeErc1155 collection = _createCollection(owner);

        _prank(owner);
        collection.lockAffiliateFee("forever");

        vm.expectRevert(LockedForever.selector);
        collection.setAffiliateFee(1000);

        vm.expectRevert(LockedForever.selector);
        collection.setAffiliateDiscount(1000);
    }

    function test_defaultRoyalty_erc2981() public {
        ArchetypeErc1155 collection = _createCollection(owner);

        (address receiver, uint256 royaltyAmount) = collection.royaltyInfo(1, 1 ether);
        assertEq(receiver, owner);
        assertEq(royaltyAmount, 0.05 ether);

        _prank(owner);
        collection.setDefaultRoyalty(buyer, 1000);

        (receiver, royaltyAmount) = collection.royaltyInfo(1, 1 ether);
        assertEq(receiver, buyer);
        assertEq(royaltyAmount, 0.1 ether);
    }

    function test_withdraw_splitsWithSuperAffiliate() public {
        address affiliate = makeAddr("affiliate");
        address superAffiliate = makeAddr("superAffiliate");
        bytes memory signature = _affiliateSignature(affiliate);
        PayoutConfig memory payoutConfig = PayoutConfig({
            ownerBps: 9000,
            platformBps: 500,
            partnerBps: 0,
            superAffiliateBps: 500,
            partner: address(0),
            superAffiliate: superAffiliate,
            ownerAltPayout: address(0)
        });
        ArchetypeErc1155 collection = _createCollectionWithPayout(owner, defaultConfig, payoutConfig);
        ArchetypePayouts payouts = ArchetypePayouts(PAYOUTS);

        vm.deal(affiliate, 100 ether);
        vm.deal(superAffiliate, 100 ether);

        _setInvite(collection, PUBLIC_KEY, _inviteWithPrice(0.1 ether));

        _prank(buyer);
        collection.mintToken{value: 0.1 ether}(_publicAuth(), 1, FIRST_TOKEN_ID, affiliate, signature);

        // fee breakdown:
        //   mintPrice        = 0.1 ether
        //   ownerBalance     = 0.1 ether * 8500 / 10000 = 0.085 ether
        //   affiliateBalance = 0.1 ether * 1500 / 10000 = 0.015 ether
        assertEq(collection.ownerBalance(), 0.085 ether);
        assertEq(collection.affiliateBalance(affiliate), 0.015 ether);

        _prank(owner);
        collection.withdraw();

        // fee breakdown:
        //   ownerBalance         = 0.085 ether
        //   ownerPayout          = 0.085 ether * 9000 / 10000 = 0.0765 ether
        //   platformPayout       = 0.085 ether * 500 / 10000  = 0.00425 ether
        //   superAffiliatePayout = 0.085 ether * 500 / 10000  = 0.00425 ether
        assertEq(payouts.balance(owner), 0.0765 ether);
        assertEq(payouts.balance(PLATFORM), 0.00425 ether);
        assertEq(payouts.balance(superAffiliate), 0.00425 ether);

        vm.txGasPrice(0);

        uint256 ownerBalanceBefore = owner.balance;
        _prank(owner);
        payouts.withdraw();
        assertEq(owner.balance - ownerBalanceBefore, 0.0765 ether);

        uint256 platformBalanceBefore = PLATFORM.balance;
        _prank(PLATFORM);
        payouts.withdraw();
        assertEq(PLATFORM.balance - platformBalanceBefore, 0.00425 ether);

        uint256 superAffiliateBalanceBefore = superAffiliate.balance;
        _prank(superAffiliate);
        payouts.withdraw();
        assertEq(superAffiliate.balance - superAffiliateBalanceBefore, 0.00425 ether);

        uint256 affiliateBalanceBefore = affiliate.balance;
        _prank(affiliate);
        collection.withdrawAffiliate();
        assertEq(affiliate.balance - affiliateBalanceBefore, 0.015 ether);
    }

    function test_withdrawAffiliate_failsWhenWalletNeverEarnedAffiliateBalance() public {
        ArchetypeErc1155 collection = _createCollection(owner);

        _prank(other);
        vm.expectRevert(BalanceEmpty.selector);
        collection.withdrawAffiliate();
    }

    function test_withdraw_usesOwnerAltPayout() public {
        address alt = makeAddr("alt");
        PayoutConfig memory payoutConfig = PayoutConfig({
            ownerBps: 9000,
            platformBps: 500,
            partnerBps: 500,
            superAffiliateBps: 0,
            partner: buyer,
            superAffiliate: address(0),
            ownerAltPayout: alt
        });
        ArchetypeErc1155 collection = _createCollectionWithPayout(owner, defaultConfig, payoutConfig);
        ArchetypePayouts payouts = ArchetypePayouts(PAYOUTS);

        vm.deal(alt, 100 ether);

        _setInvite(collection, PUBLIC_KEY, _inviteWithPrice(0.1 ether));

        _prank(other);
        collection.mintToken{value: 0.1 ether}(_publicAuth(), 1, FIRST_TOKEN_ID, address(0), "");
        assertEq(collection.ownerBalance(), 0.1 ether);

        vm.txGasPrice(0);
        uint256 altBalanceBefore = alt.balance;

        _prank(owner);
        collection.withdraw();

        // fee breakdown:
        //   ownerBalance   = 0.1 ether
        //   altPayout      = 0.1 ether * 9000 / 10000 = 0.09 ether
        //   platformPayout = 0.1 ether * 500 / 10000  = 0.005 ether
        //   partnerPayout  = 0.1 ether * 500 / 10000  = 0.005 ether
        assertEq(alt.balance - altBalanceBefore, 0.09 ether);
        assertEq(payouts.balance(owner), 0);
        assertEq(payouts.balance(alt), 0);
        assertEq(payouts.balance(PLATFORM), 0.005 ether);
        assertEq(payouts.balance(buyer), 0.005 ether);

        _prank(other);
        collection.mintToken{value: 0.1 ether}(_publicAuth(), 1, FIRST_TOKEN_ID, address(0), "");

        _prank(alt);
        collection.withdraw();

        // fee breakdown:
        //   previousAltPayout = 0.09 ether
        //   secondAltPayout   = 0.09 ether
        //   totalAltPayout    = 0.09 ether * 2 = 0.18 ether
        assertEq(alt.balance - altBalanceBefore, 0.18 ether);

        _prank(owner);
        collection.setOwnerAltPayout(address(0));

        _prank(alt);
        vm.expectRevert(NotShareholder.selector);
        collection.withdraw();
    }

    function test_mint_refundsOverpayment() public {
        ArchetypeErc1155 collection = _createCollection(owner);

        _setInvite(collection, PUBLIC_KEY, _defaultInvite(0.08 ether));

        vm.txGasPrice(0);
        uint256 buyerBalanceBefore = buyer.balance;
        uint256 collectionBalanceBefore = address(collection).balance;

        _prank(buyer);
        collection.mintToken{value: 0.12 ether}(_publicAuth(), 1, FIRST_TOKEN_ID, address(0), "");

        assertEq(address(collection).balance - collectionBalanceBefore, 0.08 ether);
        assertEq(buyerBalanceBefore - buyer.balance, 0.08 ether);
    }

    function test_mint_refundsOverpaymentWithAffiliateAccounting() public {
        ArchetypeErc1155 collection = _createCollection(owner);
        address affiliate = makeAddr("affiliate");
        bytes memory signature = _affiliateSignature(affiliate);

        _setInvite(collection, PUBLIC_KEY, _defaultInvite(0.08 ether));

        vm.txGasPrice(0);
        uint256 buyerBalanceBefore = buyer.balance;
        uint256 collectionBalanceBefore = address(collection).balance;

        _prank(buyer);
        collection.mintToken{value: 0.2 ether}(_publicAuth(), 1, FIRST_TOKEN_ID, affiliate, signature);

        // fee breakdown:
        //   mintPrice        = 0.08 ether
        //   ownerBalance     = 0.08 ether * 8500 / 10000 = 0.068 ether
        //   affiliateBalance = 0.08 ether * 1500 / 10000 = 0.012 ether
        assertEq(buyerBalanceBefore - buyer.balance, 0.08 ether);
        assertEq(address(collection).balance - collectionBalanceBefore, 0.08 ether);
        assertEq(collection.ownerBalance(), 0.068 ether);
        assertEq(collection.affiliateBalance(affiliate), 0.012 ether);
    }

    function test_mint_affiliateDiscountsAffectAccounting() public {
        Config memory config = Config({
            baseUri: defaultConfig.baseUri,
            affiliateSigner: affiliateSigner,
            maxSupply: _filledMaxSupplyArray(3, 5000),
            maxBatchSize: 100,
            affiliateFee: 1500,
            affiliateDiscount: 1000,
            defaultRoyalty: 500
        });

        ArchetypeErc1155 collection = _createCollectionWithConfig(owner, config);
        address affiliate = makeAddr("affiliate");

        _setInvite(collection, PUBLIC_KEY, _defaultInvite(0.01 ether));

        _prank(buyer);
        collection.mintToken{value: 0.027 ether}(
            _publicAuth(), 3, FIRST_TOKEN_ID, affiliate, _affiliateSignature(affiliate)
        );

        // fee breakdown:
        //   discountedPrice   = 0.027 ether
        //   ownerBalance      = 0.027 ether * 8500 / 10000 = 0.02295 ether
        //   affiliateBalance  = 0.027 ether * 1500 / 10000 = 0.00405 ether
        assertEq(collection.ownerBalance(), 0.02295 ether);
        assertEq(collection.affiliateBalance(affiliate), 0.00405 ether);
    }

    function test_payouts_withdrawalApprovalFlow() public {
        ArchetypeErc1155 collection = _createCollection(owner);
        ArchetypePayouts payouts = ArchetypePayouts(PAYOUTS);
        address alt = makeAddr("alt");
        address delegate = makeAddr("delegate");

        _setInvite(collection, PUBLIC_KEY, _inviteWithPrice(0.2 ether));

        _prank(other);
        collection.mintToken{value: 0.2 ether}(_publicAuth(), 1, FIRST_TOKEN_ID, address(0), "");

        _prank(owner);
        collection.withdraw();

        _prank(other);
        vm.expectRevert(NotApprovedToWithdraw.selector);
        payouts.withdrawFrom(owner, delegate);

        address[] memory tokens = _nativeTokenList();
        vm.expectRevert(NotApprovedToWithdraw.selector);
        payouts.withdrawTokensFrom(owner, alt, tokens);

        uint256 altBalanceBefore = alt.balance;
        _prank(owner);
        payouts.withdrawFrom(owner, alt);
        // fee breakdown:
        //   collectionBalance = 0.2 ether
        //   ownerPayout       = 0.2 ether * 9500 / 10000 = 0.19 ether
        assertEq(alt.balance - altBalanceBefore, 0.19 ether);

        _prank(other);
        collection.mintToken{value: 0.2 ether}(_publicAuth(), 1, FIRST_TOKEN_ID, address(0), "");

        _prank(owner);
        collection.withdraw();
        payouts.approveWithdrawal(delegate, true);

        uint256 delegateBalanceBefore = delegate.balance;
        _prank(delegate);
        payouts.withdrawFrom(owner, delegate);
        // fee breakdown:
        //   collectionBalance = 0.2 ether
        //   ownerPayout       = 0.2 ether * 9500 / 10000 = 0.19 ether
        assertEq(delegate.balance - delegateBalanceBefore, 0.19 ether);

        _prank(delegate);
        vm.expectRevert(PayoutBalanceEmpty.selector);
        payouts.withdrawTokensFrom(owner, delegate, tokens);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _createCollection(address receiver) internal returns (ArchetypeErc1155 collection) {
        address collectionAddress =
            factory.createCollection(receiver, "Pookie", "POOKIE", defaultConfig, defaultPayoutConfig);
        collection = ArchetypeErc1155(collectionAddress);
    }

    function _createCollectionWithPayout(address receiver, Config memory config, PayoutConfig memory payoutConfig)
        internal
        returns (ArchetypeErc1155 collection)
    {
        address collectionAddress = factory.createCollection(receiver, "Pookie", "POOKIE", config, payoutConfig);
        collection = ArchetypeErc1155(collectionAddress);
    }

    function _setInvite(ArchetypeErc1155 collection, bytes32 key, Invite memory invite) internal {
        _prank(owner);
        collection.setInvite(key, CID_ZERO, invite);
    }

    function _defaultInvite(uint128 price) internal view returns (Invite memory invite) {
        uint32[] memory tokenIds = new uint32[](1);
        tokenIds[0] = uint32(FIRST_TOKEN_ID);

        invite = Invite({
            price: price,
            start: uint32(block.timestamp),
            end: 0,
            limit: 5000,
            maxSupply: 5000,
            unitSize: 1,
            tokenIds: tokenIds,
            tokenAddress: address(0)
        });
    }

    function _inviteWithPrice(uint128 price) internal view returns (Invite memory invite) {
        return _defaultInvite(price);
    }

    function _affiliateSignature(address affiliate) internal view returns (bytes memory) {
        return _affiliateSignatureWithPk(affiliate, AFFILIATE_SIGNER_PK);
    }

    function _affiliateSignatureWithPk(address affiliate, uint256 privateKey) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(keccak256(abi.encodePacked(affiliate)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _nativeTokenList() internal pure returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = address(0);
    }

    function _publicAuth() internal pure returns (Auth memory) {
        return _auth(PUBLIC_KEY);
    }

    function _auth(bytes32 key) internal pure returns (Auth memory auth) {
        auth.key = key;
        auth.proof = new bytes32[](0);
    }

    // Config field accessors
    // config() returns (string baseUri, address affiliateSigner, uint16 maxBatchSize, uint16 affiliateFee, uint16 affiliateDiscount, uint16 defaultRoyalty)
    // note: uint32[] maxSupply is excluded from auto-getter (use collection.maxSupply())
    function _configAffiliateFee(ArchetypeErc1155 collection) internal view returns (uint16 affiliateFee) {
        (,,, affiliateFee,,) = collection.config();
    }

    function _configAffiliateDiscount(ArchetypeErc1155 collection) internal view returns (uint16 affiliateDiscount) {
        (,,,, affiliateDiscount,) = collection.config();
    }

    // payoutConfig() returns (uint16 ownerBps, uint16 platformBps, uint16 partnerBps, uint16 superAffiliateBps, address partner, address superAffiliate, address ownerAltPayout)
    function _payoutOwnerAltPayout(ArchetypeErc1155 collection) internal view returns (address ownerAltPayout) {
        (,,,,,, ownerAltPayout) = collection.payoutConfig();
    }

    function _prank(address actor) internal {
        vm.stopPrank();
        vm.startPrank(actor);
    }

    // =========================================================================
    // Ported from the legacy ERC1155 Hardhat suite
    // =========================================================================

    // ------------------------------------------------------------------
    // #1  test_mint_bonusDiscountsAndAffiliateDiscounts
    //
    // NOTE: The ERC1155 contract stores `packedBonusDiscounts` but never
    // reads it during minting – bonus-mint logic exists only in the ERC721a
    // variant.  This test therefore verifies the *non-bonus* portions of the
    // scenario (affiliate discount pricing, regular minting) and documents
    // the gap.  Bonus totals match a pure-mint count (no bonus tokens added).
    // ------------------------------------------------------------------
    function test_mint_bonusDiscountsAndAffiliateDiscounts() public {
        uint32[] memory maxSupply = new uint32[](3);
        maxSupply[0] = 5000;
        maxSupply[1] = 5000;
        maxSupply[2] = 5000;

        Config memory config = Config({
            baseUri: defaultConfig.baseUri,
            affiliateSigner: affiliateSigner,
            maxSupply: maxSupply,
            maxBatchSize: 100,
            affiliateFee: 1500,
            affiliateDiscount: 1000,
            defaultRoyalty: 500
        });

        ArchetypeErc1155 collection = _createCollectionWithConfig(owner, config);
        address affiliate = makeAddr("affiliate");
        bytes memory signature = _affiliateSignature(affiliate);

        // Set a simple invite (no bonus in ERC1155)
        uint32[] memory noTokenIds = new uint32[](0);
        _prank(owner);
        collection.setAdvancedInvite(
            PUBLIC_KEY,
            CID_ZERO,
            AdvancedInvite({
                price: 0.01 ether,
                reservePrice: 0.01 ether,
                delta: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: 300,
                maxSupply: UINT32_MAX_VAL,
                interval: 0,
                unitSize: 1,
                tokenIds: noTokenIds,
                tokenAddress: address(0)
            })
        );

        // Buyer mints 3 with affiliate (10% discount → 0.009 ether each)
        _prank(buyer);
        collection.mintToken{value: 0.027 ether}(_publicAuth(), 3, FIRST_TOKEN_ID, affiliate, signature);

        // No bonus mints in ERC1155 – only 3 tokens minted
        assertEq(collection.balanceOf(buyer, FIRST_TOKEN_ID), 3);

        // Buyer mints 8 without affiliate (no discount)
        _prank(buyer);
        collection.mintToken{value: 0.08 ether}(_publicAuth(), 8, FIRST_TOKEN_ID, address(0), "");

        assertEq(collection.balanceOf(buyer, FIRST_TOKEN_ID), 11);

        // Buyer mints 21 without affiliate
        _prank(buyer);
        collection.mintToken{value: 0.21 ether}(_publicAuth(), 21, FIRST_TOKEN_ID, address(0), "");

        assertEq(collection.balanceOf(buyer, FIRST_TOKEN_ID), 32);
    }

    // ------------------------------------------------------------------
    // #2  test_mint_maxSupplyChecks
    // ------------------------------------------------------------------
    function test_mint_maxSupplyChecks() public {
        uint32[] memory maxSupply = new uint32[](3);
        maxSupply[0] = 100;
        maxSupply[1] = 100;
        maxSupply[2] = 100;

        Config memory config = Config({
            baseUri: defaultConfig.baseUri,
            affiliateSigner: affiliateSigner,
            maxSupply: maxSupply,
            maxBatchSize: 500,
            affiliateFee: 1500,
            affiliateDiscount: 0,
            defaultRoyalty: 500
        });

        ArchetypeErc1155 collection = _createCollectionWithConfig(owner, config);

        // Public free invite for all tokenIds
        uint32[] memory noTokenIds = new uint32[](0);
        _prank(owner);
        collection.setAdvancedInvite(
            ZERO_KEY,
            CID_ZERO,
            AdvancedInvite({
                price: 0,
                reservePrice: 0,
                delta: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: 1000,
                maxSupply: UINT32_MAX_VAL,
                interval: 0,
                unitSize: 1,
                tokenIds: noTokenIds,
                tokenAddress: address(0)
            })
        );

        // Minting 301 for tokenId 1 should fail (maxSupply = 100)
        _prank(buyer);
        vm.expectRevert(MaxSupplyExceeded.selector);
        collection.mintToken(Auth({key: ZERO_KEY, proof: new bytes32[](0)}), 301, 1, address(0), "");

        // Mint 100 of tokenId 1
        _prank(buyer);
        collection.mintToken(Auth({key: ZERO_KEY, proof: new bytes32[](0)}), 100, 1, address(0), "");

        // Mint 100 of tokenId 2
        _prank(buyer);
        collection.mintToken(Auth({key: ZERO_KEY, proof: new bytes32[](0)}), 100, 2, address(0), "");

        // Mint 100 of tokenId 3
        _prank(buyer);
        collection.mintToken(Auth({key: ZERO_KEY, proof: new bytes32[](0)}), 100, 3, address(0), "");

        // Minting 1 more of tokenId 1 should fail
        _prank(buyer);
        vm.expectRevert(MaxSupplyExceeded.selector);
        collection.mintToken(Auth({key: ZERO_KEY, proof: new bytes32[](0)}), 1, 1, address(0), "");

        // Minting 1 more of tokenId 3 should fail
        _prank(buyer);
        vm.expectRevert(MaxSupplyExceeded.selector);
        collection.mintToken(Auth({key: ZERO_KEY, proof: new bytes32[](0)}), 1, 3, address(0), "");

        assertEq(collection.totalSupply(), 300);
    }

    // ------------------------------------------------------------------
    // #3  test_mint_inviteListMaxSupply
    // ------------------------------------------------------------------
    function test_mint_inviteListMaxSupply() public {
        uint32[] memory maxSupply = new uint32[](3);
        maxSupply[0] = 100;
        maxSupply[1] = 100;
        maxSupply[2] = 100;

        Config memory config = Config({
            baseUri: defaultConfig.baseUri,
            affiliateSigner: affiliateSigner,
            maxSupply: maxSupply,
            maxBatchSize: 1000,
            affiliateFee: 1500,
            affiliateDiscount: 0,
            defaultRoyalty: 500
        });

        ArchetypeErc1155 collection = _createCollectionWithConfig(owner, config);

        uint32[] memory tokenId1Only = new uint32[](1);
        tokenId1Only[0] = 1;

        // invite: maxSupply=90, limit=70, tokenId=1 only
        _prank(owner);
        collection.setAdvancedInvite(
            ZERO_KEY,
            CID_ZERO,
            AdvancedInvite({
                price: 0,
                reservePrice: 0,
                delta: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: 70,
                maxSupply: 90,
                interval: 0,
                unitSize: 1,
                tokenIds: tokenId1Only,
                tokenAddress: address(0)
            })
        );

        // buyer mints 40
        _prank(buyer);
        collection.mintToken(Auth({key: ZERO_KEY, proof: new bytes32[](0)}), 40, 1, address(0), "");

        // other minting 60 would exceed list maxSupply (40+60=100 > 90)
        _prank(other);
        vm.expectRevert(ListMaxSupplyExceeded.selector);
        collection.mintToken(Auth({key: ZERO_KEY, proof: new bytes32[](0)}), 60, 1, address(0), "");

        // other mints 50 (40+50=90 == maxSupply)
        _prank(other);
        collection.mintToken(Auth({key: ZERO_KEY, proof: new bytes32[](0)}), 50, 1, address(0), "");

        assertEq(collection.tokenSupply(1), 90);
        assertEq(collection.totalSupply(), 90);
    }

    // ------------------------------------------------------------------
    // #4  test_mint_increasingMaxSupply
    // ------------------------------------------------------------------
    function test_mint_increasingMaxSupply() public {
        uint32[] memory maxSupply = new uint32[](3);
        maxSupply[0] = 10;
        maxSupply[1] = 0;
        maxSupply[2] = 0;

        Config memory config = Config({
            baseUri: defaultConfig.baseUri,
            affiliateSigner: affiliateSigner,
            maxSupply: maxSupply,
            maxBatchSize: 1000,
            affiliateFee: 1500,
            affiliateDiscount: 0,
            defaultRoyalty: 500
        });

        ArchetypeErc1155 collection = _createCollectionWithConfig(owner, config);

        uint32[] memory noTokenIds = new uint32[](0);
        _prank(owner);
        collection.setAdvancedInvite(
            ZERO_KEY,
            CID_ZERO,
            AdvancedInvite({
                price: 0,
                reservePrice: 0,
                delta: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: UINT32_MAX_VAL,
                maxSupply: UINT32_MAX_VAL,
                interval: 0,
                unitSize: 1,
                tokenIds: noTokenIds,
                tokenAddress: address(0)
            })
        );

        // Mint 10 for tokenId 1
        _prank(buyer);
        collection.mintToken(Auth({key: ZERO_KEY, proof: new bytes32[](0)}), 10, 1, address(0), "");
        assertEq(collection.tokenSupply(1), 10);

        // Trying to mint 1 more reverts MaxSupplyExceeded
        _prank(buyer);
        vm.expectRevert(MaxSupplyExceeded.selector);
        collection.mintToken(Auth({key: ZERO_KEY, proof: new bytes32[](0)}), 1, 1, address(0), "");

        // Owner increases maxSupply
        uint32[] memory newMaxSupply = new uint32[](3);
        newMaxSupply[0] = 20;
        newMaxSupply[1] = 0;
        newMaxSupply[2] = 0;
        _prank(owner);
        collection.setMaxSupply(newMaxSupply, "forever");

        // Mint 10 more
        _prank(buyer);
        collection.mintToken(Auth({key: ZERO_KEY, proof: new bytes32[](0)}), 10, 1, address(0), "");

        assertEq(collection.tokenSupply(1), 20);
    }

    function test_mint_increasingMaxSupply_enablesNewTokenIds() public {
        Config memory config = Config({
            baseUri: defaultConfig.baseUri,
            affiliateSigner: affiliateSigner,
            maxSupply: _filledMaxSupplyArray(1, 10),
            maxBatchSize: 100,
            affiliateFee: 1500,
            affiliateDiscount: 0,
            defaultRoyalty: 500
        });

        ArchetypeErc1155 collection = _createCollectionWithConfig(owner, config);

        uint32[] memory noTokenIds = new uint32[](0);
        _prank(owner);
        collection.setAdvancedInvite(
            ZERO_KEY,
            CID_ZERO,
            AdvancedInvite({
                price: 0,
                reservePrice: 0,
                delta: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: UINT32_MAX_VAL,
                maxSupply: UINT32_MAX_VAL,
                interval: 0,
                unitSize: 1,
                tokenIds: noTokenIds,
                tokenAddress: address(0)
            })
        );

        _prank(buyer);
        collection.mintToken(_auth(ZERO_KEY), 10, 1, address(0), "");
        assertEq(collection.balanceOf(buyer, 1), 10);

        _prank(buyer);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x32));
        collection.mintToken(_auth(ZERO_KEY), 1, 2, address(0), "");

        uint32[] memory expandedMaxSupply = new uint32[](2);
        expandedMaxSupply[0] = 10;
        expandedMaxSupply[1] = 5;

        _prank(owner);
        collection.setMaxSupply(expandedMaxSupply, "forever");

        _prank(buyer);
        collection.mintToken(_auth(ZERO_KEY), 1, 2, address(0), "");

        assertEq(collection.balanceOf(buyer, 2), 1);
    }

    // ------------------------------------------------------------------
    // #5  test_mintTo_mintsToAnotherWallet
    // ------------------------------------------------------------------
    function test_mintTo_mintsToAnotherWallet() public {
        ArchetypeErc1155 collection = _createCollection(owner);

        uint32[] memory noTokenIds = new uint32[](0);
        _prank(owner);
        collection.setAdvancedInvite(
            ZERO_KEY,
            CID_ZERO,
            AdvancedInvite({
                price: 0.02 ether,
                reservePrice: 0.02 ether,
                delta: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: 300,
                maxSupply: UINT32_MAX_VAL,
                interval: 0,
                unitSize: 1,
                tokenIds: noTokenIds,
                tokenAddress: address(0)
            })
        );

        // Owner mints to buyer's address
        _prank(owner);
        collection.mintTo{value: 0.06 ether}(
            Auth({key: ZERO_KEY, proof: new bytes32[](0)}), 3, buyer, FIRST_TOKEN_ID, address(0), ""
        );

        assertEq(collection.balanceOf(buyer, FIRST_TOKEN_ID), 3);
        assertEq(collection.balanceOf(owner, FIRST_TOKEN_ID), 0);

        // mintTo(zero address) reverts
        _prank(owner);
        vm.expectRevert(MintToZeroAddress.selector);
        collection.mintTo{value: 0.02 ether}(
            Auth({key: ZERO_KEY, proof: new bytes32[](0)}), 1, address(0), FIRST_TOKEN_ID, address(0), ""
        );
    }

    // ------------------------------------------------------------------
    // #6  test_batchMintTo_airdrop
    // ------------------------------------------------------------------
    function test_batchMintTo_airdrop() public {
        uint32[] memory maxSupply = new uint32[](1);
        maxSupply[0] = 5000;

        Config memory config = Config({
            baseUri: defaultConfig.baseUri,
            affiliateSigner: affiliateSigner,
            maxSupply: maxSupply,
            maxBatchSize: 5000,
            affiliateFee: 1500,
            affiliateDiscount: 0,
            defaultRoyalty: 500
        });

        ArchetypeErc1155 collection = _createCollectionWithConfig(owner, config);

        // Single-leaf Merkle root for owner address
        bytes32 ownerRoot = keccak256(abi.encodePacked(owner));

        uint32[] memory noTokenIds = new uint32[](0);
        _prank(owner);
        collection.setAdvancedInvite(
            ownerRoot,
            CID_ZERO,
            AdvancedInvite({
                price: 0,
                reservePrice: 0,
                delta: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: 5000,
                maxSupply: UINT32_MAX_VAL,
                interval: 0,
                unitSize: 1,
                tokenIds: noTokenIds,
                tokenAddress: address(0)
            })
        );

        // Build deterministic airdrop list of 50 entries
        address[] memory recipients = new address[](50);
        for (uint256 i = 0; i < 50; i++) {
            recipients[i] = vm.addr(i + 1);
        }

        uint256[] memory quantities = new uint256[](25);
        uint256[] memory tokenIds = new uint256[](25);
        for (uint256 i = 0; i < 25; i++) {
            quantities[i] = 1;
            tokenIds[i] = 1;
        }

        // Owner auth with empty proof (single-leaf tree: owner verifies itself)
        Auth memory ownerAuth = Auth({key: ownerRoot, proof: new bytes32[](0)});

        // Batch 1: recipients[0..24]
        address[] memory batch1 = new address[](25);
        for (uint256 i = 0; i < 25; i++) {
            batch1[i] = recipients[i];
        }

        _prank(owner);
        collection.batchMintTo(ownerAuth, batch1, quantities, tokenIds, address(0), "");

        // Batch 2: recipients[25..49]
        address[] memory batch2 = new address[](25);
        for (uint256 i = 0; i < 25; i++) {
            batch2[i] = recipients[25 + i];
        }

        _prank(owner);
        collection.batchMintTo(ownerAuth, batch2, quantities, tokenIds, address(0), "");

        assertEq(collection.tokenSupply(1), 50);
        assertEq(collection.balanceOf(recipients[0], 1), 1);
        assertEq(collection.balanceOf(recipients[24], 1), 1);
        assertEq(collection.balanceOf(recipients[25], 1), 1);
        assertEq(collection.balanceOf(recipients[49], 1), 1);
    }

    function test_batchMintTo_validatesAggregateSupply() public {
        Config memory config = Config({
            baseUri: defaultConfig.baseUri,
            affiliateSigner: affiliateSigner,
            maxSupply: _filledMaxSupplyArray(1, 100),
            maxBatchSize: 200,
            affiliateFee: 1500,
            affiliateDiscount: 0,
            defaultRoyalty: 500
        });

        ArchetypeErc1155 collection = _createCollectionWithConfig(owner, config);
        bytes32 ownerRoot = keccak256(abi.encodePacked(owner));
        uint32[] memory tokenId1Only = new uint32[](1);
        tokenId1Only[0] = 1;

        _prank(owner);
        collection.setAdvancedInvite(
            ownerRoot,
            CID_ZERO,
            AdvancedInvite({
                price: 0,
                reservePrice: 0,
                delta: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: UINT32_MAX_VAL,
                maxSupply: UINT32_MAX_VAL,
                interval: 0,
                unitSize: 1,
                tokenIds: tokenId1Only,
                tokenAddress: address(0)
            })
        );

        Auth memory ownerAuth = _auth(ownerRoot);
        address[] memory recipients = new address[](2);
        recipients[0] = makeAddr("airdropOne");
        recipients[1] = makeAddr("airdropTwo");

        uint256[] memory tooLargeQuantities = new uint256[](2);
        tooLargeQuantities[0] = 60;
        tooLargeQuantities[1] = 41;

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 1;
        tokenIds[1] = 1;

        _prank(owner);
        vm.expectRevert(MaxSupplyExceeded.selector);
        collection.batchMintTo(ownerAuth, recipients, tooLargeQuantities, tokenIds, address(0), "");

        uint256[] memory validQuantities = new uint256[](2);
        validQuantities[0] = 60;
        validQuantities[1] = 40;

        _prank(owner);
        collection.batchMintTo(ownerAuth, recipients, validQuantities, tokenIds, address(0), "");

        assertEq(collection.totalSupply(), 100);
        assertEq(collection.tokenSupply(1), 100);
        assertEq(collection.balanceOf(recipients[0], 1), 60);
        assertEq(collection.balanceOf(recipients[1], 1), 40);
    }

    // ------------------------------------------------------------------
    // #7  test_mint_erc20PricedInvite
    // ------------------------------------------------------------------
    function test_mint_erc20PricedInvite() public {
        ArchetypeErc1155 collection = _createCollection(owner);
        ArchetypePayouts payouts = ArchetypePayouts(PAYOUTS);

        TestErc20 erc20 = new TestErc20();
        address tokenAddress = address(erc20);

        bytes32 erc20Key = keccak256(abi.encodePacked(tokenAddress));

        uint32[] memory noTokenIds = new uint32[](0);
        _prank(owner);
        collection.setAdvancedInvite(
            erc20Key,
            CID_ZERO,
            AdvancedInvite({
                price: 1 ether,
                reservePrice: 1 ether,
                delta: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: 300,
                maxSupply: UINT32_MAX_VAL,
                interval: 0,
                unitSize: 1,
                tokenIds: noTokenIds,
                tokenAddress: tokenAddress
            })
        );

        Auth memory erc20Auth = Auth({key: erc20Key, proof: new bytes32[](0)});

        // Without approval → NotApprovedToTransfer
        _prank(buyer);
        vm.expectRevert(NotApprovedToTransfer.selector);
        collection.mintToken(erc20Auth, 3, FIRST_TOKEN_ID, address(0), "");

        // With approval but no balance → Erc20BalanceTooLow
        _prank(buyer);
        erc20.approve(address(collection), type(uint256).max);

        _prank(buyer);
        vm.expectRevert(Erc20BalanceTooLow.selector);
        collection.mintToken(erc20Auth, 3, FIRST_TOKEN_ID, address(0), "");

        // Mint 3 ether of erc20 to buyer
        _prank(buyer);
        erc20.mint(3 ether);

        // Now mint 3 tokens
        _prank(buyer);
        collection.mintToken(erc20Auth, 3, FIRST_TOKEN_ID, address(0), "");

        assertEq(collection.balanceOf(buyer, FIRST_TOKEN_ID), 3);
        assertEq(erc20.balanceOf(address(collection)), 3 ether);

        // Owner withdraws erc20
        address[] memory tokens = new address[](1);
        tokens[0] = tokenAddress;

        _prank(owner);
        collection.withdrawTokens(tokens);

        assertEq(erc20.balanceOf(address(payouts)), 3 ether);

        // Owner withdraws from payouts (9500 bps = 2.85 ether)
        vm.txGasPrice(0);
        uint256 ownerErc20Before = erc20.balanceOf(owner);
        _prank(owner);
        payouts.withdrawTokens(tokens);
        assertEq(erc20.balanceOf(owner) - ownerErc20Before, 2.85 ether);

        // Platform withdraws from payouts (500 bps = 0.15 ether)
        uint256 platformErc20Before = erc20.balanceOf(PLATFORM);
        _prank(PLATFORM);
        payouts.withdrawTokens(tokens);
        assertEq(erc20.balanceOf(PLATFORM) - platformErc20Before, 0.15 ether);
    }

    // ------------------------------------------------------------------
    // #8  test_mint_tokenIdRestriction
    // ------------------------------------------------------------------
    function test_mint_tokenIdRestriction() public {
        ArchetypeErc1155 collection = _createCollection(owner);

        // Invite restricted to tokenId 1 only
        uint32[] memory allowedTokenIds = new uint32[](1);
        allowedTokenIds[0] = 1;

        _prank(owner);
        collection.setAdvancedInvite(
            PUBLIC_KEY,
            CID_ZERO,
            AdvancedInvite({
                price: 0,
                reservePrice: 0,
                delta: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: 300,
                maxSupply: UINT32_MAX_VAL,
                interval: 0,
                unitSize: 1,
                tokenIds: allowedTokenIds,
                tokenAddress: address(0)
            })
        );

        // Buyer minting tokenId 2 from that invite reverts InvalidTokenId
        _prank(buyer);
        vm.expectRevert(InvalidTokenId.selector);
        collection.mintToken(_publicAuth(), 1, 2, address(0), "");

        // Buyer minting tokenId 1 succeeds
        _prank(buyer);
        collection.mintToken(_publicAuth(), 1, FIRST_TOKEN_ID, address(0), "");

        assertEq(collection.balanceOf(buyer, FIRST_TOKEN_ID), 1);
    }

    function test_largeMaxSupplyArray_allowsHighTokenIdMint() public {
        Config memory config = Config({
            baseUri: defaultConfig.baseUri,
            affiliateSigner: affiliateSigner,
            maxSupply: _filledMaxSupplyArray(500, 1),
            maxBatchSize: 10,
            affiliateFee: 1500,
            affiliateDiscount: 0,
            defaultRoyalty: 500
        });

        ArchetypeErc1155 collection = _createCollectionWithConfig(owner, config);

        uint32[] memory tokenId500Only = new uint32[](1);
        tokenId500Only[0] = 500;

        _prank(owner);
        collection.setAdvancedInvite(
            PUBLIC_KEY,
            CID_ZERO,
            AdvancedInvite({
                price: 0,
                reservePrice: 0,
                delta: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: 1,
                maxSupply: 1,
                interval: 0,
                unitSize: 1,
                tokenIds: tokenId500Only,
                tokenAddress: address(0)
            })
        );

        _prank(buyer);
        collection.mintToken(_publicAuth(), 1, 500, address(0), "");

        assertEq(collection.balanceOf(buyer, 500), 1);
    }

    // ------------------------------------------------------------------
    // #9  test_mint_unitSizeMintOneGetX
    // ------------------------------------------------------------------
    function test_mint_unitSizeMintOneGetX() public {
        uint32[] memory maxSupply = new uint32[](1);
        maxSupply[0] = 15;

        Config memory config = Config({
            baseUri: defaultConfig.baseUri,
            affiliateSigner: affiliateSigner,
            maxSupply: maxSupply,
            maxBatchSize: 50,
            affiliateFee: 1500,
            affiliateDiscount: 0,
            defaultRoyalty: 500
        });

        ArchetypeErc1155 collection = _createCollectionWithConfig(owner, config);

        address third = makeAddr("third");
        vm.deal(third, 10 ether);

        uint32[] memory tokenId1Only = new uint32[](1);
        tokenId1Only[0] = 1;

        // invite: unitSize=5, limit=10, maxSupply=15
        _prank(owner);
        collection.setAdvancedInvite(
            ZERO_KEY,
            CID_ZERO,
            AdvancedInvite({
                price: 0,
                reservePrice: 0,
                delta: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: 10,
                maxSupply: 15,
                interval: 0,
                unitSize: 5,
                tokenIds: tokenId1Only,
                tokenAddress: address(0)
            })
        );

        // buyer mints quantity 1 → gets 5 tokens (unitSize=5)
        _prank(buyer);
        collection.mintToken(Auth({key: ZERO_KEY, proof: new bytes32[](0)}), 1, 1, address(0), "");
        assertEq(collection.balanceOf(buyer, 1), 5);

        // Same buyer minting 2 more reverts NumberOfMintsExceeded
        // (limit=10, already used 5 units, buying 2 more = 10 units total → 5+10=15 > 10)
        _prank(buyer);
        vm.expectRevert(NumberOfMintsExceeded.selector);
        collection.mintToken(Auth({key: ZERO_KEY, proof: new bytes32[](0)}), 2, 1, address(0), "");

        // other mints quantity 2 → gets 10 tokens
        _prank(other);
        collection.mintToken(Auth({key: ZERO_KEY, proof: new bytes32[](0)}), 2, 1, address(0), "");
        assertEq(collection.balanceOf(other, 1), 10);

        // third wallet minting 1 more reverts ListMaxSupplyExceeded (5+10=15 == maxSupply)
        _prank(third);
        vm.expectRevert(ListMaxSupplyExceeded.selector);
        collection.mintToken(Auth({key: ZERO_KEY, proof: new bytes32[](0)}), 1, 1, address(0), "");

        assertEq(collection.tokenSupply(1), 15);
    }

    // ------------------------------------------------------------------
    // #10  test_mint_descendingDutchInvite
    // ------------------------------------------------------------------
    function test_mint_descendingDutchInvite() public {
        ArchetypeErc1155 collection = _createCollection(owner);

        uint32[] memory noTokenIds = new uint32[](0);
        uint32 startTs = uint32(block.timestamp);
        _prank(owner);
        collection.setAdvancedInvite(
            ZERO_KEY,
            CID_ZERO,
            AdvancedInvite({
                price: 1 ether,
                reservePrice: 0.1 ether,
                delta: 0.1 ether,
                start: startTs,
                end: 0,
                limit: 300,
                maxSupply: UINT32_MAX_VAL,
                interval: 1000,
                unitSize: 1,
                tokenIds: noTokenIds,
                tokenAddress: address(0)
            })
        );

        Auth memory zeroAuth = Auth({key: ZERO_KEY, proof: new bytes32[](0)});

        // 0.5 ether at t=0 → reverts InsufficientEthSent (price=1 ether)
        _prank(buyer);
        vm.expectRevert(InsufficientEthSent.selector);
        collection.mintToken{value: 0.5 ether}(zeroAuth, 1, FIRST_TOKEN_ID, address(0), "");

        // 1 ether mint succeeds at t=0
        _prank(buyer);
        collection.mintToken{value: 1 ether}(zeroAuth, 1, FIRST_TOKEN_ID, address(0), "");

        // Warp +5000s → price = 1 - (5000/1000)*0.1 = 1 - 0.5 = 0.5 ether
        vm.warp(block.timestamp + 5000);

        _prank(buyer);
        collection.mintToken{value: 0.5 ether}(zeroAuth, 1, FIRST_TOKEN_ID, address(0), "");

        // Warp +50000s more → price floored at reservePrice 0.1 ether
        vm.warp(block.timestamp + 50000);

        _prank(buyer);
        collection.mintToken{value: 0.1 ether}(zeroAuth, 1, FIRST_TOKEN_ID, address(0), "");

        assertEq(collection.balanceOf(buyer, FIRST_TOKEN_ID), 3);
    }

    // ------------------------------------------------------------------
    // #11  test_mint_increasingDutchInvite
    // ------------------------------------------------------------------
    function test_mint_increasingDutchInvite() public {
        ArchetypeErc1155 collection = _createCollection(owner);

        uint32[] memory noTokenIds = new uint32[](0);
        _prank(owner);
        collection.setAdvancedInvite(
            ZERO_KEY,
            CID_ZERO,
            AdvancedInvite({
                price: 1 ether,
                reservePrice: 10 ether,
                delta: 1 ether,
                start: uint32(block.timestamp),
                end: 0,
                limit: 300,
                maxSupply: UINT32_MAX_VAL,
                interval: 1000,
                unitSize: 1,
                tokenIds: noTokenIds,
                tokenAddress: address(0)
            })
        );

        Auth memory zeroAuth = Auth({key: ZERO_KEY, proof: new bytes32[](0)});

        // 1 ether mint succeeds at t=0
        _prank(buyer);
        collection.mintToken{value: 1 ether}(zeroAuth, 1, FIRST_TOKEN_ID, address(0), "");

        // Warp +5000s → price = 1 + (5000/1000)*1 = 6 ether
        vm.warp(block.timestamp + 5000);

        // 1 ether now insufficient
        _prank(buyer);
        vm.expectRevert(InsufficientEthSent.selector);
        collection.mintToken{value: 1 ether}(zeroAuth, 1, FIRST_TOKEN_ID, address(0), "");

        // 6 ether succeeds
        _prank(buyer);
        collection.mintToken{value: 6 ether}(zeroAuth, 1, FIRST_TOKEN_ID, address(0), "");

        // Warp large → price capped at reservePrice 10 ether
        vm.warp(block.timestamp + 1000000);

        _prank(buyer);
        collection.mintToken{value: 10 ether}(zeroAuth, 1, FIRST_TOKEN_ID, address(0), "");

        assertEq(collection.balanceOf(buyer, FIRST_TOKEN_ID), 3);
    }

    // ------------------------------------------------------------------
    // #12  test_mint_multiplePublicInviteLists
    // ------------------------------------------------------------------
    function test_mint_multiplePublicInviteLists() public {
        uint32[] memory maxSupply = new uint32[](3);
        maxSupply[0] = 100;
        maxSupply[1] = 100;
        maxSupply[2] = 100;

        Config memory config = Config({
            baseUri: defaultConfig.baseUri,
            affiliateSigner: affiliateSigner,
            maxSupply: maxSupply,
            maxBatchSize: 100,
            affiliateFee: 1500,
            affiliateDiscount: 0,
            defaultRoyalty: 500
        });

        ArchetypeErc1155 collection = _createCollectionWithConfig(owner, config);

        uint32[] memory noTokenIds = new uint32[](0);
        bytes32 KEY_ZERO = bytes32(0);
        bytes32 KEY_ONE = bytes32(uint256(1));
        bytes32 KEY_FF = bytes32(uint256(0xff));

        // Key 0: 1 ether, all tokenIds
        _prank(owner);
        collection.setAdvancedInvite(
            KEY_ZERO,
            CID_ZERO,
            AdvancedInvite({
                price: 1 ether,
                reservePrice: 1 ether,
                delta: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: 100,
                maxSupply: UINT32_MAX_VAL,
                interval: 0,
                unitSize: 1,
                tokenIds: noTokenIds,
                tokenAddress: address(0)
            })
        );

        // buyer mints 40 tokenId 1 from key 0 paying 40 ether
        _prank(buyer);
        collection.mintToken{value: 40 ether}(Auth({key: KEY_ZERO, proof: new bytes32[](0)}), 40, 1, address(0), "");

        // Key 1: free, all tokenIds (public key ≤ 0xff)
        _prank(owner);
        collection.setAdvancedInvite(
            KEY_ONE,
            CID_ZERO,
            AdvancedInvite({
                price: 0,
                reservePrice: 0,
                delta: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: 100,
                maxSupply: UINT32_MAX_VAL,
                interval: 0,
                unitSize: 1,
                tokenIds: noTokenIds,
                tokenAddress: address(0)
            })
        );

        // other mints 20 tokenId 1 from key 1
        _prank(other);
        collection.mintToken(Auth({key: KEY_ONE, proof: new bytes32[](0)}), 20, 1, address(0), "");

        // Key 0xff: free, all tokenIds (public key = 0xff)
        _prank(owner);
        collection.setAdvancedInvite(
            KEY_FF,
            CID_ZERO,
            AdvancedInvite({
                price: 0,
                reservePrice: 0,
                delta: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: 100,
                maxSupply: UINT32_MAX_VAL,
                interval: 0,
                unitSize: 1,
                tokenIds: noTokenIds,
                tokenAddress: address(0)
            })
        );

        // other mints 40 tokenId 1 from key 0xff
        _prank(other);
        collection.mintToken(Auth({key: KEY_FF, proof: new bytes32[](0)}), 40, 1, address(0), "");

        assertEq(collection.tokenSupply(1), 100);
    }

    // ------------------------------------------------------------------
    // #13  test_batch_batchMintVerification
    // ------------------------------------------------------------------
    function test_batch_batchMintVerification() public {
        uint32[] memory maxSupply = new uint32[](1);
        maxSupply[0] = 1000;

        Config memory config = Config({
            baseUri: defaultConfig.baseUri,
            affiliateSigner: affiliateSigner,
            maxSupply: maxSupply,
            maxBatchSize: 1000,
            affiliateFee: 1500,
            affiliateDiscount: 0,
            defaultRoyalty: 500
        });

        ArchetypeErc1155 collection = _createCollectionWithConfig(owner, config);

        uint32[] memory noTokenIds = new uint32[](0);
        _prank(owner);
        collection.setAdvancedInvite(
            ZERO_KEY,
            CID_ZERO,
            AdvancedInvite({
                price: 0,
                reservePrice: 0,
                delta: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: UINT32_MAX_VAL,
                maxSupply: UINT32_MAX_VAL,
                interval: 0,
                unitSize: 1,
                tokenIds: noTokenIds,
                tokenAddress: address(0)
            })
        );

        // Mint 1000 of tokenId 1 in one call
        _prank(buyer);
        collection.mintToken(Auth({key: ZERO_KEY, proof: new bytes32[](0)}), 1000, 1, address(0), "");

        assertEq(collection.balanceOf(buyer, 1), 1000);
    }

    // =========================================================================
    // Additional Helpers
    // =========================================================================

    uint32 internal constant UINT32_MAX_VAL = 2 ** 32 - 1;

    function _filledMaxSupplyArray(uint256 length, uint32 value) internal pure returns (uint32[] memory maxSupply) {
        maxSupply = new uint32[](length);
        for (uint256 i = 0; i < length; i++) {
            maxSupply[i] = value;
        }
    }

    function _createCollectionWithConfig(address receiver, Config memory config)
        internal
        returns (ArchetypeErc1155 collection)
    {
        address collectionAddress = factory.createCollection(receiver, "Pookie", "POOKIE", config, defaultPayoutConfig);
        collection = ArchetypeErc1155(collectionAddress);
    }
}
