// SPDX-License-Identifier: MIT
// forge-lint: disable-start(mixed-case-function, mixed-case-variable)
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC721} from "openzeppelin-v4/token/ERC721/IERC721.sol";
import {IERC721AUpgradeable} from "erc721a-upgradeable/contracts/IERC721AUpgradeable.sol";
import {ArchetypeBatchV100} from "../src/ArchetypeBatchV100.sol";
import "../src/AffiliateAuthorization.sol";
import {
    ArchetypePayouts,
    BalanceEmpty as PayoutBalanceEmpty,
    InvalidSplitShares,
    NotApprovedToWithdraw,
    UnexpectedTokenBalanceChange,
    InvalidPayouts
} from "../src/ArchetypePayouts.sol";
import {TestErc20} from "../src/TestErc20.sol";
import {RoyaltyPolicyRegistry} from "../src/RoyaltyPolicyRegistry.sol";
import {NoReturnErc20} from "./mocks/NoReturnErc20.sol";
import {FeeOnTransferErc20} from "./mocks/FeeOnTransferErc20.sol";
import {ReentrantAffiliate} from "./mocks/ReentrantAffiliate.sol";
import {MintFeeRegistry} from "../src/MintFeeRegistry.sol";
import {AffiliateSignerRegistry} from "../src/AffiliateSignerRegistry.sol";
import {
    MintConstraints,
    BurnConstraints,
    UnexpectedMintCurrency,
    InsufficientMintOutput,
    ExcessiveNativeValue,
    UnexpectedBurnCollection,
    UnexpectedBurnRecipient
} from "../src/MintConstraints.sol";
import {ArchetypeErc721a, Config, PayoutConfig, Invite, Auth} from "../src/ERC721a/ArchetypeErc721a.sol";
import {
    InvalidConfig,
    BonusDiscount,
    BurnInvite,
    NotOwner,
    LockedForever,
    Blacklisted,
    WalletUnauthorizedToMint,
    MintNotYetStarted,
    MintEnded,
    InsufficientEthSent,
    Erc20BalanceTooLow,
    MaxSupplyExceeded,
    ListMaxSupplyExceeded,
    NumberOfMintsExceeded,
    MintingPaused,
    NotApprovedToTransfer,
    InvalidAmountOfTokens,
    NotTokenOwner,
    MintCostOverflow,
    ExcessiveCurrencyCost,
    Erc721BatchMint,
    ArchetypeAddresses
} from "../src/ERC721a/ArchetypeLogicErc721a.sol";
import {
    FactoryErc721a,
    InsufficientDeployFee,
    InvalidOwner as FactoryInvalidOwner
} from "../src/ERC721a/FactoryErc721a.sol";

contract ArchetypeErc721aTest is Test {
    address internal constant PLATFORM = 0x2222222222222222222222222222222222222221;
    address internal constant BATCH = 0x2222222222222222222222222222222222222223;
    address internal constant PAYOUTS = 0x2222222222222222222222222222222222222222;
    uint256 internal constant AFFILIATE_SIGNER_PK = 0xA11CE;
    uint256 internal constant WRONG_AFFILIATE_SIGNER_PK = 0xB0B;
    bytes32 internal constant PUBLIC_KEY = bytes32(uint256(1));
    bytes32 internal constant ZERO_KEY = bytes32(0);
    bytes32 internal constant HASH256 = bytes32(uint256(0xff));
    bytes32 internal constant CID_ZERO = bytes32(0);
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    ArchetypeErc721a internal archetypeImplementation;
    FactoryErc721a internal factory;
    RoyaltyPolicyRegistry internal royaltyPolicyRegistry;
    MintFeeRegistry internal mintFeeRegistry;
    AffiliateSignerRegistry internal affiliateSignerRegistry;

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

        defaultConfig = Config({
            baseUri: "ipfs://bafkreieqcdphcfojcd2vslsxrhzrjqr6cxjlyuekpghzehfexi5c3w55eq",
            maxSupply: 5000,
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

        royaltyPolicyRegistry = new RoyaltyPolicyRegistry(owner);
        ArchetypeBatchV100 batchImpl = new ArchetypeBatchV100(address(this), royaltyPolicyRegistry);
        vm.etch(BATCH, address(batchImpl).code);

        mintFeeRegistry = new MintFeeRegistry(owner, other, 0, 1 ether, 0);
        affiliateSignerRegistry = new AffiliateSignerRegistry(owner, affiliateSigner);
        archetypeImplementation =
            new ArchetypeErc721a(PLATFORM, PAYOUTS, BATCH, mintFeeRegistry, affiliateSignerRegistry);

        _prank(owner);
        factory = new FactoryErc721a(address(archetypeImplementation), owner, royaltyPolicyRegistry);
        royaltyPolicyRegistry.setApprovedFactory(address(factory), true);

        _prank(other);
    }

    function test_archetypeAddresses_returnsConstructorAddresses() public view {
        ArchetypeAddresses memory addrs = archetypeImplementation.archetypeAddresses();

        assertEq(addrs.platform, PLATFORM);
        assertEq(addrs.payouts, PAYOUTS);
        assertEq(addrs.batch, BATCH);
    }

    function test_constructor_revertsWhenPayoutsIsZero() public {
        vm.expectRevert(InvalidPayouts.selector);
        new ArchetypeErc721a(PLATFORM, address(0), BATCH, mintFeeRegistry, affiliateSignerRegistry);
    }

    function test_constructor_revertsWhenPayoutsIsEoa() public {
        vm.expectRevert(InvalidPayouts.selector);
        new ArchetypeErc721a(PLATFORM, makeAddr("payoutsEoa"), BATCH, mintFeeRegistry, affiliateSignerRegistry);
    }

    function test_constructor_acceptsArchetypePayouts() public {
        ArchetypePayouts payouts = new ArchetypePayouts();
        ArchetypeErc721a implementation =
            new ArchetypeErc721a(PLATFORM, address(payouts), BATCH, mintFeeRegistry, affiliateSignerRegistry);

        assertEq(implementation.archetypeAddresses().payouts, address(payouts));
    }

    function test_constructor_rejectsZeroOrCodelessBatch() public {
        vm.expectRevert(InvalidConfig.selector);
        new ArchetypeErc721a(PLATFORM, PAYOUTS, address(0), mintFeeRegistry, affiliateSignerRegistry);

        vm.expectRevert(InvalidConfig.selector);
        new ArchetypeErc721a(PLATFORM, PAYOUTS, makeAddr("codeless batch"), mintFeeRegistry, affiliateSignerRegistry);
    }

    function test_factoryConstructor_setsOwnerFromArgument() public {
        _prank(other);
        FactoryErc721a factoryWithOwnerArg =
            new FactoryErc721a(address(archetypeImplementation), owner, royaltyPolicyRegistry);

        assertEq(factoryWithOwnerArg.owner(), owner);
        assertEq(factoryWithOwnerArg.archetype(), address(archetypeImplementation));
    }

    function test_factoryConstructor_failsWhenOwnerIsZero() public {
        vm.expectRevert(FactoryInvalidOwner.selector);
        new FactoryErc721a(address(archetypeImplementation), address(0), royaltyPolicyRegistry);
    }

    function test_createCollection_initializesClone() public {
        _prank(other);
        ArchetypeErc721a collection = _createCollection(owner);

        assertEq(collection.symbol(), "POOKIE");
        assertEq(collection.owner(), owner);
        assertTrue(royaltyPolicyRegistry.scatterCollections(address(collection)));
    }

    function test_createCollection_allowsTheSameSenderTwiceInOneBlock() public {
        _prank(other);
        address first = factory.createCollection(owner, "Pookie", "POOKIE", defaultConfig, defaultPayoutConfig);
        address second = factory.createCollection(owner, "Snoozle", "SNOOZ", defaultConfig, defaultPayoutConfig);

        assertFalse(first == second);
        assertEq(factory.senderSaltNonce(other), 2);
        assertEq(ArchetypeErc721a(first).name(), "Pookie");
        assertEq(ArchetypeErc721a(second).name(), "Snoozle");
    }

    function test_setBonusDiscounts_failsWhenCallerIsNotOwner() public {
        ArchetypeErc721a collection = _createCollection(owner);
        BonusDiscount[] memory discounts = new BonusDiscount[](1);
        discounts[0] = BonusDiscount({numMints: 2, numBonusMints: 1});

        _prank(other);
        vm.expectRevert(NotOwner.selector);
        collection.setBonusDiscounts(PUBLIC_KEY, discounts);
    }

    function test_setBonusDiscounts_acceptsTheOwnerThroughItsConfiguredBatch() public {
        ArchetypeErc721a collection = _createCollection(owner);
        BonusDiscount[] memory discounts = new BonusDiscount[](1);
        discounts[0] = BonusDiscount({numMints: 2, numBonusMints: 1});
        CurrentCallerBatch batchCaller = new CurrentCallerBatch(owner);
        vm.etch(BATCH, address(batchCaller).code);

        _prank(BATCH);
        collection.setBonusDiscounts(PUBLIC_KEY, discounts);

        assertEq(collection.packedBonusDiscounts(PUBLIC_KEY), uint256(2) << 16 | 1);
    }

    function test_implementationCannotBeInitialized() public {
        _prank(other);
        vm.expectRevert(bytes("ERC721A__Initializable: contract is already initialized"));
        archetypeImplementation.initialize("Flookie", "POOKIE", defaultConfig, defaultPayoutConfig, owner);
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

    function test_createCollection_paidDeployFeeCreditsPlatformAndRefundsExcess() public {
        ArchetypePayouts payouts = ArchetypePayouts(PAYOUTS);

        _prank(owner);
        factory.setDeployFee(0.05 ether);

        _prank(other);
        factory.createCollection{value: 0.05 ether}(other, "Pookie", "POOKIE", defaultConfig, defaultPayoutConfig);

        assertEq(payouts.balance(PLATFORM), 0.05 ether);

        vm.warp(block.timestamp + 1);
        vm.txGasPrice(0);
        uint256 otherBalanceBefore = other.balance;

        _prank(other);
        factory.createCollection{value: 0.1 ether}(other, "Pookie", "POOKIE", defaultConfig, defaultPayoutConfig);

        assertEq(otherBalanceBefore - other.balance, 0.05 ether);
        assertEq(payouts.balance(PLATFORM), 0.1 ether);
        assertEq(address(factory).balance, 0);
    }

    function test_mint_mintsWhenPublicInviteIsSet() public {
        ArchetypeErc721a collection = _createCollection(owner);

        _prank(owner);
        collection.setInvite(
            PUBLIC_KEY,
            CID_ZERO,
            Invite({
                price: 0.1 ether,
                start: uint32(block.timestamp),
                end: 0,
                limit: 5000,
                maxSupply: 5000,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );

        bytes32[] memory proof = new bytes32[](0);
        Auth memory auth = Auth({key: PUBLIC_KEY, proof: proof});

        _prank(buyer);
        collection.mint{value: 0.1 ether}(auth, 1, address(0), "", _constraints());

        assertEq(collection.ownerOf(1), buyer);
        assertEq(collection.totalSupply(), 1);
    }

    function test_mint_publicMinimumChargesPaidQuantityAndExcludesBonuses() public {
        ArchetypeErc721a collection = _createCollection(owner);
        ArchetypePayouts payouts = ArchetypePayouts(PAYOUTS);
        _setPublicInvite(collection, 0.1 ether, uint32(block.timestamp));

        BonusDiscount[] memory discounts = new BonusDiscount[](1);
        discounts[0] = BonusDiscount({numMints: 2, numBonusMints: 1});
        _prank(owner);
        collection.setBonusDiscounts(PUBLIC_KEY, discounts);
        _prank(owner);
        mintFeeRegistry.setNativeMinimumFee(0.01 ether);

        (uint256 currencyCost, uint256 nativeValue,,) = collection.computeMintPayment(PUBLIC_KEY, 2, false);
        assertEq(currencyCost, 0.2 ether);
        assertEq(nativeValue, 0.21 ether);

        _prank(buyer);
        collection.mint{value: nativeValue}(_publicAuth(), 2, address(0), "", _constraints());

        assertEq(collection.balanceOf(buyer), 3);
        assertEq(address(collection).balance, 0);
        assertEq(payouts.balance(owner), 0.19 ether);
        assertEq(payouts.balance(PLATFORM), 0.02 ether);

        _prank(owner);
        mintFeeRegistry.setNativeMinimumFee(0.02 ether);
        (, nativeValue,,) = collection.computeMintPayment(PUBLIC_KEY, 1, false);
        assertEq(nativeValue, 0.115 ether);
    }

    function test_mint_publicMinimumIncludesUnitSize() public {
        ArchetypeErc721a collection = _createCollection(owner);
        Invite memory invite = Invite({
            price: 0,
            start: uint32(block.timestamp),
            end: 0,
            limit: 100,
            maxSupply: 100,
            unitSize: 3,
            tokenAddress: address(0),
            isBlacklist: false
        });
        _setInvite(collection, PUBLIC_KEY, invite);

        _prank(owner);
        mintFeeRegistry.setNativeMinimumFee(0.01 ether);

        (, uint256 nativeValue,,) = collection.computeMintPayment(PUBLIC_KEY, 2, false);
        assertEq(nativeValue, 0.06 ether);

        _prank(buyer);
        collection.mint{value: nativeValue}(_publicAuth(), 2, address(0), "", _constraints());
        assertEq(collection.balanceOf(buyer), 6);
        assertEq(ArchetypePayouts(PAYOUTS).balance(PLATFORM), 0.06 ether);
    }

    function test_mint_feeIncreaseRequiresPaymentAtTheLiveFee() public {
        ArchetypeErc721a collection = _createCollection(owner);
        _setPublicInvite(collection, 0.1 ether, uint32(block.timestamp));

        _prank(owner);
        mintFeeRegistry.setNativeMinimumFee(0.01 ether);
        (, uint256 previousNativeValue,,) = collection.computeMintPayment(PUBLIC_KEY, 1, false);
        assertEq(previousNativeValue, 0.105 ether);

        _prank(owner);
        mintFeeRegistry.setNativeMinimumFee(0.02 ether);
        (, uint256 currentNativeValue,,) = collection.computeMintPayment(PUBLIC_KEY, 1, false);
        assertEq(currentNativeValue, 0.115 ether);

        _prank(buyer);
        vm.expectRevert(InsufficientEthSent.selector);
        collection.mint{value: previousNativeValue}(_publicAuth(), 1, address(0), "", _constraints());

        MintConstraints memory constraints = _constraints();
        constraints.maxNativeValue = previousNativeValue + 0.001 ether;
        _prank(buyer);
        vm.expectRevert(ExcessiveNativeValue.selector);
        collection.mint{value: currentNativeValue}(_publicAuth(), 1, address(0), "", constraints);

        _prank(buyer);
        constraints.maxNativeValue = currentNativeValue;
        collection.mint{value: currentNativeValue}(_publicAuth(), 1, address(0), "", constraints);

        assertEq(collection.ownerOf(1), buyer);
        assertEq(ArchetypePayouts(PAYOUTS).balance(owner), 0.095 ether);
        assertEq(ArchetypePayouts(PAYOUTS).balance(PLATFORM), 0.02 ether);
    }

    function test_mint_nativeValueConstraintRejectsAboveAndAllowsEqualOrBelowWithRefund() public {
        ArchetypeErc721a collection = _createCollection(owner);
        _setPublicInvite(collection, 0, uint32(block.timestamp));

        _prank(owner);
        mintFeeRegistry.setNativeMinimumFee(0.01 ether);

        MintConstraints memory constraints = _constraints();
        constraints.maxNativeValue = 0.01 ether - 1;
        _prank(buyer);
        vm.expectRevert(ExcessiveNativeValue.selector);
        collection.mint{value: 0.02 ether}(_publicAuth(), 1, address(0), "", constraints);

        constraints.maxNativeValue = 0.01 ether;
        collection.mint{value: 0.01 ether}(_publicAuth(), 1, address(0), "", constraints);

        constraints.maxNativeValue = 0.02 ether;
        vm.txGasPrice(0);
        uint256 buyerBalanceBefore = buyer.balance;
        collection.mint{value: 0.02 ether}(_publicAuth(), 1, address(0), "", constraints);

        assertEq(collection.balanceOf(buyer), 2);
        assertEq(buyerBalanceBefore - buyer.balance, 0.01 ether);
        assertEq(address(collection).balance, 0);
    }

    function test_mint_percentageFeeAbovePublicMinimumAddsNoSurcharge() public {
        PayoutConfig memory payout = defaultPayoutConfig;
        payout.ownerBps = 8500;
        payout.platformBps = 1500;
        ArchetypeErc721a collection = _createCollectionWithPayout(owner, defaultConfig, payout);
        _setPublicInvite(collection, 0.1 ether, uint32(block.timestamp));

        _prank(owner);
        mintFeeRegistry.setNativeMinimumFee(0.01 ether);

        (, uint256 nativeValue,,) = collection.computeMintPayment(PUBLIC_KEY, 1, false);
        assertEq(nativeValue, 0.1 ether);

        _prank(buyer);
        collection.mint{value: nativeValue}(_publicAuth(), 1, address(0), "", _constraints());

        ArchetypePayouts payouts = ArchetypePayouts(PAYOUTS);
        assertEq(payouts.balance(owner), 0.085 ether);
        assertEq(payouts.balance(PLATFORM), 0.015 ether);
    }

    function test_mint_publicMinimumWithAffiliateAccountsForEveryWei() public {
        ArchetypeErc721a collection = _createCollection(owner);
        ArchetypePayouts payouts = ArchetypePayouts(PAYOUTS);
        address affiliate = makeAddr("minimum fee affiliate");
        _setPublicInvite(collection, 101, uint32(block.timestamp));

        _prank(owner);
        mintFeeRegistry.setNativeMinimumFee(7);

        (uint256 currencyCost, uint256 nativeValue,,) = collection.computeMintPayment(PUBLIC_KEY, 1, true);
        assertEq(currencyCost, 101);
        assertEq(nativeValue, 104);

        vm.recordLogs();
        _prank(buyer);
        collection.mint{value: nativeValue}(
            _publicAuth(), 1, affiliate, _affiliateSignature(collection, affiliate), _constraints()
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(payouts.balance(affiliate), 15);
        assertEq(payouts.balance(owner), 82);
        assertEq(payouts.balance(PLATFORM), 7);
        assertEq(address(collection).balance, 0);

        _assertReferralLog(logs, affiliate, address(0), 15, 1, 104);
    }

    function test_mint_erc20ReferralEventCarriesThePulledCurrencyCost() public {
        ArchetypeErc721a collection = _createCollection(owner);
        TestErc20 erc20 = new TestErc20();
        address affiliate = makeAddr("erc20 affiliate");
        bytes32 key = keccak256(abi.encodePacked(address(erc20)));
        _setInvite(collection, key, _erc20Invite(address(erc20), 1 ether));

        _prank(buyer);
        erc20.mint(2 ether);
        erc20.approve(address(collection), 2 ether);

        vm.recordLogs();
        _prank(buyer);
        collection.mint(
            _auth(key),
            2,
            affiliate,
            _affiliateSignature(collection, affiliate),
            _constraints(address(erc20), type(uint128).max, 2)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertReferralLog(logs, affiliate, address(erc20), 0.3 ether, 2, 2 ether);
    }

    function test_mint_zeroPriceAffiliateEventCarriesZeroPaymentValue() public {
        ArchetypeErc721a collection = _createCollection(owner);
        address affiliate = makeAddr("free affiliate");
        _setPublicInvite(collection, 0, uint32(block.timestamp));

        vm.recordLogs();
        _prank(buyer);
        collection.mint(_publicAuth(), 1, affiliate, _affiliateSignature(collection, affiliate), _constraints());
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(collection.ownerOf(1), buyer);
        _assertReferralLog(logs, affiliate, address(0), 0, 1, 0);
    }

    function _assertReferralLog(
        Vm.Log[] memory logs,
        address affiliate,
        address token,
        uint128 wad,
        uint256 numMints,
        uint256 paymentValue
    ) internal pure {
        bytes32 referralTopic = keccak256("Referral(address,address,uint128,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != referralTopic) continue;
            assertEq(logs[i].topics.length, 2, "Referral must index only the affiliate");
            assertEq(address(uint160(uint256(logs[i].topics[1]))), affiliate, "Referral affiliate");
            (address loggedToken, uint128 loggedWad, uint256 loggedNumMints, uint256 loggedPaymentValue) =
                abi.decode(logs[i].data, (address, uint128, uint256, uint256));
            assertEq(loggedToken, token, "Referral token");
            assertEq(loggedWad, wad, "Referral wad");
            assertEq(loggedNumMints, numMints, "Referral numMints");
            assertEq(loggedPaymentValue, paymentValue, "Referral paymentValue");
            return;
        }
        revert("no Referral log recorded");
    }

    function test_mint_paidExclusiveInviteHasNoNativeMinimum() public {
        ArchetypeErc721a collection = _createCollection(owner);
        ArchetypePayouts payouts = ArchetypePayouts(PAYOUTS);
        bytes32 allowlistRoot = keccak256(abi.encodePacked(buyer));
        _setInvite(
            collection,
            allowlistRoot,
            Invite({
                price: 0.1 ether,
                start: uint32(block.timestamp),
                end: 0,
                limit: 1,
                maxSupply: 1,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );

        _prank(owner);
        mintFeeRegistry.setNativeMinimumFee(0.01 ether);

        (, uint256 nativeValue,,) = collection.computeMintPayment(allowlistRoot, 1, false);
        assertEq(nativeValue, 0.1 ether);

        _prank(buyer);
        collection.mint{value: nativeValue}(_auth(allowlistRoot), 1, address(0), "", _constraints());
        assertEq(collection.balanceOf(buyer), 1);
        assertEq(payouts.balance(owner), 0.095 ether);
        assertEq(payouts.balance(PLATFORM), 0.005 ether);
    }

    function test_mint_publicErc20InviteChargesNativeMinimumAndRefundsExcess() public {
        ArchetypeErc721a collection = _createCollection(owner);
        ArchetypePayouts payouts = ArchetypePayouts(PAYOUTS);
        TestErc20 erc20 = new TestErc20();
        bytes32 key = keccak256(abi.encodePacked(address(erc20)));
        _setInvite(
            collection,
            key,
            Invite({
                price: 1 ether,
                start: uint32(block.timestamp),
                end: 0,
                limit: 2,
                maxSupply: 2,
                unitSize: 1,
                tokenAddress: address(erc20),
                isBlacklist: false
            })
        );

        _prank(owner);
        mintFeeRegistry.setNativeMinimumFee(0.01 ether);
        _prank(buyer);
        erc20.mint(2 ether);
        erc20.approve(address(collection), 2 ether);

        (uint256 currencyCost, uint256 nativeValue,,) = collection.computeMintPayment(key, 2, false);
        assertEq(currencyCost, 2 ether);
        assertEq(nativeValue, 0.02 ether);

        vm.txGasPrice(0);
        uint256 buyerNativeBefore = buyer.balance;
        MintConstraints memory constraints = _constraints(address(erc20), type(uint128).max, 2);
        constraints.maxNativeValue = 0.03 ether;
        collection.mint{value: 0.03 ether}(_auth(key), 2, address(0), "", constraints);

        assertEq(buyerNativeBefore - buyer.balance, 0.02 ether);
        assertEq(erc20.balanceOf(address(collection)), 0);
        assertEq(payouts.balanceToken(owner, address(erc20)), 1.9 ether);
        assertEq(payouts.balanceToken(PLATFORM, address(erc20)), 0.1 ether);
        assertEq(payouts.balance(PLATFORM), 0.02 ether);
        assertEq(address(collection).balance, 0);
    }

    function test_mint_erc20PriceIncreaseAfterQuoteRevertsInsteadOfPullingMore() public {
        ArchetypeErc721a collection = _createCollection(owner);
        TestErc20 erc20 = new TestErc20();
        bytes32 key = keccak256(abi.encodePacked(address(erc20)));
        _setInvite(collection, key, _erc20Invite(address(erc20), 1 ether));

        _prank(buyer);
        erc20.mint(4 ether);
        erc20.approve(address(collection), 4 ether);

        (uint256 quotedCost,,,) = collection.computeMintPayment(key, 2, false);
        assertEq(quotedCost, 2 ether);

        _setInvite(collection, key, _erc20Invite(address(erc20), 1.5 ether));

        _prank(buyer);
        vm.expectRevert(ExcessiveCurrencyCost.selector);
        collection.mint(_auth(key), 2, address(0), "", _constraints(address(erc20), uint128(quotedCost), 2));

        assertEq(collection.totalSupply(), 0);
        assertEq(erc20.balanceOf(buyer), 4 ether);
        assertEq(erc20.balanceOf(address(collection)), 0);
        assertEq(ArchetypePayouts(PAYOUTS).balanceToken(owner, address(erc20)), 0);

        _prank(buyer);
        collection.mint(_auth(key), 2, address(0), "", _constraints(address(erc20), 3 ether, 2));

        assertEq(collection.balanceOf(buyer), 2);
        assertEq(erc20.balanceOf(buyer), 1 ether);
    }

    function test_mint_rejectsAChangedPaymentToken() public {
        ArchetypeErc721a collection = _createCollection(owner);
        TestErc20 quotedToken = new TestErc20();
        TestErc20 replacementToken = new TestErc20();
        bytes32 key = keccak256(abi.encodePacked(address(quotedToken)));
        _setInvite(collection, key, _erc20Invite(address(quotedToken), 1 ether));

        _prank(buyer);
        replacementToken.mint(1 ether);
        replacementToken.approve(address(collection), 1 ether);
        _setInvite(collection, key, _erc20Invite(address(replacementToken), 1 ether));

        _prank(buyer);
        vm.expectRevert(UnexpectedMintCurrency.selector);
        collection.mint(_auth(key), 1, address(0), "", _constraints(address(quotedToken), 1 ether, 1));

        assertEq(replacementToken.balanceOf(buyer), 1 ether);
        assertEq(collection.totalSupply(), 0);
    }

    function test_mint_rejectsReducedOutput() public {
        ArchetypeErc721a collection = _createCollection(owner);
        Invite memory invite = _erc20Invite(address(0), 0);
        invite.unitSize = 2;
        _setInvite(collection, PUBLIC_KEY, invite);
        invite.unitSize = 1;
        _setInvite(collection, PUBLIC_KEY, invite);

        _prank(buyer);
        vm.expectRevert(InsufficientMintOutput.selector);
        collection.mint(_publicAuth(), 1, address(0), "", _constraints(address(0), 0, 2));

        assertEq(collection.totalSupply(), 0);
    }

    function test_createCollection_rejectsPlatformShareBelowFivePercent() public {
        PayoutConfig memory payoutConfig = defaultPayoutConfig;
        payoutConfig.ownerBps = 9501;
        payoutConfig.platformBps = 499;

        _prank(owner);
        vm.expectRevert(InvalidSplitShares.selector);
        factory.createCollection(owner, "Pookie", "POOKIE", defaultConfig, payoutConfig);
    }

    function test_mintTo_rejectsAContractThatCannotReceiveErc721() public {
        ArchetypeErc721a collection = _createCollection(owner);
        _setPublicInvite(collection, 0, uint32(block.timestamp));
        NonErc721Receiver receiver = new NonErc721Receiver();

        _prank(buyer);
        vm.expectRevert(IERC721AUpgradeable.TransferToNonERC721ReceiverImplementer.selector);
        collection.mintTo(_publicAuth(), 1, address(receiver), address(0), "", _constraints());
    }

    function test_batchMintTo_erc20PriceIncreaseAfterQuoteRevertsInsteadOfPullingMore() public {
        ArchetypeErc721a collection = _createCollection(owner);
        TestErc20 erc20 = new TestErc20();
        bytes32 key = keccak256(abi.encodePacked(address(erc20)));
        _setInvite(collection, key, _erc20Invite(address(erc20), 1 ether));

        _prank(owner);
        erc20.mint(4 ether);
        erc20.approve(address(collection), 4 ether);

        (uint256 quotedCost,,,) = collection.computeMintPayment(key, 2, false);

        _setInvite(collection, key, _erc20Invite(address(erc20), 1.5 ether));

        address[] memory toList = new address[](1);
        toList[0] = buyer;
        uint256[] memory quantityList = new uint256[](1);
        quantityList[0] = 2;

        _prank(owner);
        vm.expectRevert(ExcessiveCurrencyCost.selector);
        collection.batchMintTo(
            _auth(key), _batchMintArgs(toList, quantityList, _constraints(address(erc20), uint128(quotedCost), 2))
        );

        assertEq(collection.totalSupply(), 0);
        assertEq(erc20.balanceOf(owner), 4 ether);
    }

    function test_burnToMint_erc20PriceIncreaseAfterQuoteRevertsInsteadOfPullingMore() public {
        ArchetypeErc721a nftBurn = _createCollection(owner);
        vm.warp(block.timestamp + 1);
        ArchetypeErc721a nftMint = _createCollection(owner);
        TestErc20 erc20 = new TestErc20();
        _setBurnInvite(nftBurn, ZERO_KEY, _erc20BurnInvite(nftMint, erc20, 1 ether));
        _setInvite(
            nftMint,
            ZERO_KEY,
            Invite({
                price: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: 5000,
                maxSupply: 5000,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );

        _mint(nftMint, buyer, _auth(ZERO_KEY), 2, 0);
        _prank(buyer);
        nftMint.setApprovalForAll(address(nftBurn), true);
        _prank(buyer);
        erc20.mint(4 ether);
        erc20.approve(address(nftBurn), 4 ether);

        uint256[] memory tokenIds = _rangeTokenIds(1, 2);

        _setBurnInvite(nftBurn, ZERO_KEY, _erc20BurnInvite(nftMint, erc20, 1.5 ether));

        _prank(buyer);
        vm.expectRevert(ExcessiveCurrencyCost.selector);
        nftBurn.burnToMint(
            _auth(ZERO_KEY),
            tokenIds,
            _burnConstraints(address(nftMint), DEAD, _constraints(address(erc20), 1 ether, 1))
        );

        assertEq(nftBurn.totalSupply(), 0);
        assertEq(nftMint.ownerOf(1), buyer);
        assertEq(nftMint.ownerOf(2), buyer);
        assertEq(erc20.balanceOf(buyer), 4 ether);
        assertEq(erc20.balanceOf(address(nftBurn)), 0);
        assertEq(ArchetypePayouts(PAYOUTS).balanceToken(owner, address(erc20)), 0);
    }

    function test_burnToMint_rejectsChangedCollectionAndRecipient() public {
        ArchetypeErc721a destination = _createCollection(owner);
        vm.warp(block.timestamp + 1);
        ArchetypeErc721a expectedSource = _createCollection(owner);
        vm.warp(block.timestamp + 1);
        ArchetypeErc721a replacementSource = _createCollection(owner);
        _setPublicInvite(expectedSource, 0, uint32(block.timestamp));
        _setPublicInvite(replacementSource, 0, uint32(block.timestamp));
        _mint(expectedSource, buyer, _publicAuth(), 1, 0);
        _mint(replacementSource, buyer, _publicAuth(), 1, 0);

        _prank(buyer);
        expectedSource.setApprovalForAll(address(destination), true);
        replacementSource.setApprovalForAll(address(destination), true);

        BurnInvite memory invite = BurnInvite({
            burnErc721: IERC721(address(expectedSource)),
            burnAddress: DEAD,
            tokenAddress: address(0),
            price: 0,
            reversed: false,
            ratio: 1,
            start: uint32(block.timestamp),
            end: 0,
            limit: 10
        });
        _setBurnInvite(destination, ZERO_KEY, invite);
        BurnConstraints memory constraints = BurnConstraints({
            mint: _constraints(address(0), 0, 1), burnCollection: address(expectedSource), burnRecipient: DEAD
        });
        uint256[] memory tokenIds = _rangeTokenIds(1, 1);

        invite.burnErc721 = IERC721(address(replacementSource));
        _setBurnInvite(destination, ZERO_KEY, invite);
        _prank(buyer);
        vm.expectRevert(UnexpectedBurnCollection.selector);
        destination.burnToMint(_auth(ZERO_KEY), tokenIds, constraints);

        invite.burnErc721 = IERC721(address(expectedSource));
        invite.burnAddress = owner;
        _setBurnInvite(destination, ZERO_KEY, invite);
        _prank(buyer);
        vm.expectRevert(UnexpectedBurnRecipient.selector);
        destination.burnToMint(_auth(ZERO_KEY), tokenIds, constraints);

        assertEq(expectedSource.ownerOf(1), buyer);
        assertEq(replacementSource.ownerOf(1), buyer);
    }

    function test_burnToMint_blocksBurnInviteMutationDuringTransfer() public {
        ReentrantBurnSource source = new ReentrantBurnSource(buyer);
        ArchetypeErc721a destination = _createCollection(address(source));
        source.configure(destination);
        uint256[] memory tokenIds = _rangeTokenIds(1, 1);

        _prank(buyer);
        destination.burnToMint(
            _auth(ZERO_KEY),
            tokenIds,
            BurnConstraints({
                mint: _constraints(address(0), 0, 1), burnCollection: address(source), burnRecipient: DEAD
            })
        );

        assertTrue(source.mutationBlocked());
        assertEq(source.ownerOf(1), DEAD);
        assertEq(destination.ownerOf(1), buyer);
    }

    function _erc20Invite(address token, uint128 price) internal view returns (Invite memory) {
        return Invite({
            price: price,
            start: uint32(block.timestamp),
            end: 0,
            limit: 100,
            maxSupply: 100,
            unitSize: 1,
            tokenAddress: token,
            isBlacklist: false
        });
    }

    function _erc20BurnInvite(ArchetypeErc721a source, TestErc20 erc20, uint128 price)
        internal
        view
        returns (BurnInvite memory)
    {
        return BurnInvite({
            burnErc721: IERC721(address(source)),
            burnAddress: DEAD,
            tokenAddress: address(erc20),
            price: price,
            reversed: false,
            ratio: 1,
            start: uint32(block.timestamp),
            end: 0,
            limit: 100
        });
    }

    function test_mint_privateErc20InviteRequiresProofAndHasNoNativeMinimum() public {
        ArchetypeErc721a collection = _createCollection(owner);
        TestErc20 erc20 = new TestErc20();
        bytes32 allowlistRoot = keccak256(abi.encodePacked(buyer));
        Invite memory invite = Invite({
            price: 1 ether,
            start: uint32(block.timestamp),
            end: 0,
            limit: 10,
            maxSupply: 10,
            unitSize: 1,
            tokenAddress: address(erc20),
            isBlacklist: false
        });
        _setInvite(collection, allowlistRoot, invite);

        _prank(owner);
        mintFeeRegistry.setNativeMinimumFee(0.01 ether);
        _prank(buyer);
        erc20.mint(1 ether);
        erc20.approve(address(collection), 1 ether);

        (uint256 currencyCost, uint256 nativeValue,,) = collection.computeMintPayment(allowlistRoot, 1, false);
        assertEq(currencyCost, 1 ether);
        assertEq(nativeValue, 0);

        _prank(other);
        vm.expectRevert(WalletUnauthorizedToMint.selector);
        collection.mint(_auth(allowlistRoot), 1, address(0), "", _constraints(address(erc20), type(uint128).max, 1));

        _prank(buyer);
        collection.mint(_auth(allowlistRoot), 1, address(0), "", _constraints(address(erc20), type(uint128).max, 1));
        assertEq(collection.balanceOf(buyer), 1);
        assertEq(ArchetypePayouts(PAYOUTS).balanceToken(owner, address(erc20)), 0.95 ether);
    }

    function test_mint_acceptsAttributionMarkerAfterCalldata() public {
        ArchetypeErc721a collection = _createCollection(owner);

        _prank(owner);
        collection.setInvite(
            PUBLIC_KEY,
            CID_ZERO,
            Invite({
                price: 0.1 ether,
                start: uint32(block.timestamp),
                end: 0,
                limit: 5000,
                maxSupply: 5000,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );

        bytes memory markedCalldata = bytes.concat(
            abi.encodeCall(collection.mint, (_publicAuth(), 1, address(0), "", _constraints())),
            hex"736361747465722d6d696e742d76310100112233445566778899aabbccddeeff"
        );

        _prank(buyer);
        (bool success,) = address(collection).call{value: 0.1 ether}(markedCalldata);

        assertTrue(success);
        assertEq(collection.ownerOf(1), buyer);
        assertEq(collection.totalSupply(), 1);
    }

    function test_mint_mintsWhenWalletIsOnValidSingleLeafList() public {
        ArchetypeErc721a collection = _createCollection(owner);
        bytes32 allowlistRoot = keccak256(abi.encodePacked(buyer));

        _prank(owner);
        collection.setInvite(
            allowlistRoot,
            CID_ZERO,
            Invite({
                price: 0.1 ether,
                start: uint32(block.timestamp),
                end: 0,
                limit: 5000,
                maxSupply: 5000,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );

        bytes32[] memory proof = new bytes32[](0);
        Auth memory auth = Auth({key: allowlistRoot, proof: proof});

        _prank(buyer);
        collection.mint{value: 0.1 ether}(auth, 1, address(0), "", _constraints());

        assertEq(collection.ownerOf(1), buyer);
        assertEq(collection.totalSupply(), 1);
    }

    function test_mint_allowlistTracksTokensOfOwner() public {
        ArchetypeErc721a collection = _createCollection(owner);
        bytes32 allowlistRoot = keccak256(abi.encodePacked(buyer));

        _setInvite(
            collection,
            allowlistRoot,
            Invite({
                price: 0.1 ether,
                start: uint32(block.timestamp),
                end: 0,
                limit: 5000,
                maxSupply: 5000,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );

        _mint(collection, buyer, _auth(allowlistRoot), 6, 0.6 ether);

        uint256[] memory tokenIds = collection.tokensOfOwner(buyer);

        assertEq(tokenIds.length, 6);
        for (uint256 i; i < tokenIds.length; ++i) {
            assertEq(tokenIds[i], i + 1);
        }
    }

    function test_mint_failsWhenWalletIsNotOnList() public {
        ArchetypeErc721a collection = _createCollection(owner);
        bytes32 allowlistRoot = keccak256(abi.encodePacked(buyer));

        _prank(owner);
        collection.setInvite(
            allowlistRoot,
            CID_ZERO,
            Invite({
                price: 0.1 ether,
                start: uint32(block.timestamp),
                end: 0,
                limit: 5000,
                maxSupply: 5000,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );

        bytes32[] memory proof = new bytes32[](0);
        Auth memory auth = Auth({key: allowlistRoot, proof: proof});

        _prank(other);
        vm.expectRevert(WalletUnauthorizedToMint.selector);
        collection.mint{value: 0.1 ether}(auth, 1, address(0), "", _constraints());
    }

    function test_mint_failsWhenInviteNotYetStarted() public {
        ArchetypeErc721a collection = _createCollection(owner);

        _setPublicInvite(collection, 0.1 ether, uint32(block.timestamp + 1 days));

        _prank(buyer);
        vm.expectRevert(MintNotYetStarted.selector);
        collection.mint{value: 0.1 ether}(_publicAuth(), 1, address(0), "", _constraints());
    }

    function test_mint_failsWhenInviteEnded() public {
        ArchetypeErc721a collection = _createCollection(owner);

        _setInvite(
            collection,
            PUBLIC_KEY,
            Invite({
                price: 0.1 ether,
                start: uint32(block.timestamp),
                end: uint32(block.timestamp + 1 hours),
                limit: 5000,
                maxSupply: 5000,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );
        vm.warp(block.timestamp + 1 hours + 1);

        _prank(buyer);
        vm.expectRevert(MintEnded.selector);
        collection.mint{value: 0.1 ether}(_publicAuth(), 1, address(0), "", _constraints());
    }

    function test_setInvite_preservesAnExpiredWindowOnEdit() public {
        ArchetypeErc721a collection = _createCollection(owner);
        uint32 start = uint32(block.timestamp);
        uint32 end = start + 1 hours;
        Invite memory invite = Invite({
            price: 0.1 ether,
            start: start,
            end: end,
            limit: 5000,
            maxSupply: 5000,
            unitSize: 1,
            tokenAddress: address(0),
            isBlacklist: false
        });

        _setInvite(collection, PUBLIC_KEY, invite);
        vm.warp(end + 1);
        _setInvite(collection, PUBLIC_KEY, invite);

        (, uint32 storedStart, uint32 storedEnd,,,,,) = collection.invites(PUBLIC_KEY);
        assertEq(storedStart, start);
        assertEq(storedEnd, end);

        _prank(buyer);
        vm.expectRevert(MintEnded.selector);
        collection.mint{value: 0.1 ether}(_publicAuth(), 1, address(0), "", _constraints());
    }

    function test_mint_failsWhenFixedPriceInviteIsUnderpaid() public {
        ArchetypeErc721a collection = _createCollection(owner);

        _setPublicInvite(collection, 0.08 ether, uint32(block.timestamp));

        _prank(buyer);
        vm.expectRevert(InsufficientEthSent.selector);
        collection.mint{value: 0.079 ether}(_publicAuth(), 1, address(0), "", _constraints());
    }

    function test_mint_revertsWhenCostExceedsUint128() public {
        ArchetypeErc721a collection = _createCollection(owner);
        _setPublicInvite(collection, type(uint128).max, uint32(block.timestamp));

        _prank(buyer);
        vm.expectRevert(MintCostOverflow.selector);
        collection.mint(_publicAuth(), 2, address(0), "", _constraints());
    }

    function test_lockURI_failsWhenCallerIsNotOwner() public {
        ArchetypeErc721a collection = _createCollection(owner);

        _prank(other);
        vm.expectRevert(NotOwner.selector);
        collection.lockURI("forever");
    }

    function test_config_ownerCanUpdateAndLockMutableFields() public {
        ArchetypeErc721a collection = _createCollection(owner);
        address altPayout = makeAddr("altPayout");

        _prank(owner);
        collection.setBaseURI("ipfs://updated/");
        assertEq(_configBaseUri(collection), "ipfs://updated/");

        collection.lockURI("forever");
        vm.expectRevert(LockedForever.selector);
        collection.setBaseURI("ipfs://locked/");

        collection.setMaxSupply(100, "forever");
        assertEq(_configMaxSupply(collection), 100);

        collection.lockMaxSupply("forever");
        vm.expectRevert(LockedForever.selector);
        collection.setMaxSupply(99, "forever");

        collection.setAffiliateFee(1000);
        collection.setAffiliateDiscount(1000);
        assertEq(_configAffiliateFee(collection), 1000);
        assertEq(_configAffiliateDiscount(collection), 1000);

        collection.lockAffiliateFee("forever");
        vm.expectRevert(LockedForever.selector);
        collection.setAffiliateFee(20);

        collection.setOwnerAltPayout(altPayout);
        assertEq(_payoutOwnerAltPayout(collection), altPayout);

        collection.lockOwnerAltPayout();
        vm.expectRevert(LockedForever.selector);
        collection.setOwnerAltPayout(other);
    }

    function test_payouts_withdrawalApprovalFlow() public {
        ArchetypeErc721a collection = _createCollection(owner);
        ArchetypePayouts payouts = ArchetypePayouts(PAYOUTS);
        address alt = makeAddr("alt");
        address delegate = makeAddr("delegate");

        _setPublicInvite(collection, 0.2 ether, uint32(block.timestamp));
        _mintPublic(collection, owner, address(0), 0.2 ether);

        _prank(other);
        vm.expectRevert(NotApprovedToWithdraw.selector);
        payouts.withdrawFrom(owner, alt);

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

        _mintPublic(collection, owner, address(0), 0.2 ether);

        _prank(owner);
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

    function test_mint_blacklistInviteBlocksBlacklistedWalletOnly() public {
        ArchetypeErc721a collection = _createCollection(owner);
        bytes32 blacklistRoot = keccak256(abi.encodePacked(buyer));

        _prank(owner);
        collection.setInvite(
            PUBLIC_KEY,
            CID_ZERO,
            Invite({
                price: 0.1 ether,
                start: uint32(block.timestamp + 1 days),
                end: 0,
                limit: 5000,
                maxSupply: 5000,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );
        collection.setInvite(
            blacklistRoot,
            CID_ZERO,
            Invite({
                price: 0.1 ether,
                start: uint32(block.timestamp),
                end: 0,
                limit: 5000,
                maxSupply: 5000,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: true
            })
        );

        Auth memory auth = _auth(blacklistRoot);

        _prank(buyer);
        vm.expectRevert(Blacklisted.selector);
        collection.mint{value: 0.1 ether}(auth, 1, address(0), "", _constraints());

        _prank(other);
        collection.mint{value: 0.1 ether}(auth, 1, address(0), "", _constraints());

        assertEq(collection.balanceOf(other), 1);
    }

    function test_mint_blacklistInviteChargesPublicMinimum() public {
        ArchetypeErc721a collection = _createCollection(owner);
        bytes32 blacklistRoot = keccak256(abi.encodePacked(buyer));
        _setInvite(
            collection,
            blacklistRoot,
            Invite({
                price: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: 1,
                maxSupply: 1,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: true
            })
        );

        _prank(owner);
        mintFeeRegistry.setNativeMinimumFee(0.01 ether);

        _prank(buyer);
        vm.expectRevert(Blacklisted.selector);
        collection.mint{value: 0.01 ether}(_auth(blacklistRoot), 1, address(0), "", _constraints());

        _prank(other);
        collection.mint{value: 0.01 ether}(_auth(blacklistRoot), 1, address(0), "", _constraints());
        assertEq(collection.balanceOf(other), 1);
    }

    function test_mint_refundsOverpayment() public {
        ArchetypeErc721a collection = _createCollection(owner);

        _setPublicInvite(collection, 0.08 ether, uint32(block.timestamp));

        vm.txGasPrice(0);
        uint256 buyerBalanceBefore = buyer.balance;
        uint256 collectionBalanceBefore = address(collection).balance;

        _prank(buyer);
        collection.mint{value: 0.12 ether}(_publicAuth(), 1, address(0), "", _constraints());

        assertEq(address(collection).balance, collectionBalanceBefore);
        assertEq(buyerBalanceBefore - buyer.balance, 0.08 ether);
    }

    function test_mint_refundsOverpaymentWithAffiliateAccounting() public {
        ArchetypeErc721a collection = _createCollection(owner);
        address affiliate = makeAddr("affiliate");
        bytes memory signature = _affiliateSignature(collection, affiliate);

        _setPublicInvite(collection, 0.08 ether, uint32(block.timestamp));

        vm.txGasPrice(0);
        uint256 buyerBalanceBefore = buyer.balance;
        uint256 collectionBalanceBefore = address(collection).balance;

        _prank(buyer);
        collection.mint{value: 0.2 ether}(_publicAuth(), 1, affiliate, signature, _constraints());

        // fee breakdown:
        //   mintPrice        = 0.08 ether
        //   payoutBalance    = 0.08 ether * 8500 / 10000 = 0.068 ether
        //   affiliatePayout  = 0.08 ether * 1500 / 10000 = 0.012 ether
        assertEq(buyerBalanceBefore - buyer.balance, 0.08 ether);
        assertEq(address(collection).balance, collectionBalanceBefore);
        assertEq(ArchetypePayouts(PAYOUTS).balance(owner), 0.0646 ether);
        assertEq(ArchetypePayouts(PAYOUTS).balance(PLATFORM), 0.0034 ether);
        assertEq(ArchetypePayouts(PAYOUTS).balance(affiliate), 0.012 ether);
    }

    function test_mint_creditsAffiliateWithoutCallingRecipient() public {
        ArchetypeErc721a collection = _createCollection(owner);
        ReentrantAffiliate affiliate = new ReentrantAffiliate();
        bytes32 freeKey = bytes32(uint256(2));

        _setPublicInvite(collection, 0.08 ether, uint32(block.timestamp));
        _setInvite(
            collection,
            freeKey,
            Invite({
                price: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: 5000,
                maxSupply: 5000,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );
        affiliate.setCall(
            address(collection), abi.encodeCall(collection.mint, (_auth(freeKey), 1, address(0), "", _constraints()))
        );

        _prank(buyer);
        collection.mint{value: 0.08 ether}(
            _publicAuth(), 1, address(affiliate), _affiliateSignature(collection, address(affiliate)), _constraints()
        );

        assertFalse(affiliate.callSucceeded());
        assertEq(collection.balanceOf(buyer), 1);
        assertEq(collection.totalSupply(), 1);
        assertEq(ArchetypePayouts(PAYOUTS).balance(owner), 0.0646 ether);
        assertEq(ArchetypePayouts(PAYOUTS).balance(PLATFORM), 0.0034 ether);
        assertEq(ArchetypePayouts(PAYOUTS).balance(address(affiliate)), 0.012 ether);
        assertEq(address(affiliate).balance, 0);
    }

    function test_batch_rejectsNonMintCollectionCall() public {
        ArchetypeErc721a collection = _createCollection(owner);
        ArchetypeBatchV100 batch = ArchetypeBatchV100(BATCH);
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory datas = new bytes[](1);

        targets[0] = address(collection);
        datas[0] = abi.encodeCall(collection.setOwnerAltPayout, (other));

        _prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ArchetypeBatchV100.UnsupportedMintCall.selector, bytes4(datas[0])));
        batch.executeBatch(targets, values, datas);

        assertEq(_payoutOwnerAltPayout(collection), address(0));
    }

    function test_affiliateAuthorizationIsBoundToCollectionAndMinter() public {
        ArchetypeErc721a first = _createCollection(owner);
        vm.warp(block.timestamp + 1);
        ArchetypeErc721a second = _createCollection(owner);
        address affiliate = makeAddr("affiliate");
        bytes memory firstAuthorization = _affiliateSignature(first, affiliate);

        _setPublicInvite(first, 0.08 ether, uint32(block.timestamp));
        _setPublicInvite(second, 0.08 ether, uint32(block.timestamp));

        _prank(buyer);
        vm.expectRevert(InvalidAffiliateAuthorization.selector);
        second.mint{value: 0.08 ether}(_publicAuth(), 1, affiliate, firstAuthorization, _constraints());

        bytes memory otherMinterAuthorization =
            _affiliateSignatureFor(first, affiliate, other, block.timestamp + 1 hours, AFFILIATE_SIGNER_PK);
        _prank(buyer);
        vm.expectRevert(InvalidAffiliateAuthorization.selector);
        first.mint{value: 0.08 ether}(_publicAuth(), 1, affiliate, otherMinterAuthorization, _constraints());
    }

    function test_affiliateAuthorizationExpires() public {
        ArchetypeErc721a collection = _createCollection(owner);
        address affiliate = makeAddr("affiliate");
        bytes memory authorization =
            _affiliateSignatureFor(collection, affiliate, buyer, block.timestamp + 1 hours, AFFILIATE_SIGNER_PK);

        _setPublicInvite(collection, 0.08 ether, uint32(block.timestamp));
        vm.warp(block.timestamp + 1 hours + 1);

        _prank(buyer);
        vm.expectRevert(ExpiredAffiliateAuthorization.selector);
        collection.mint{value: 0.08 ether}(_publicAuth(), 1, affiliate, authorization, _constraints());
    }

    function test_affiliateSignerRegistryUpdatesCollectionValidation() public {
        ArchetypeErc721a collection = _createCollection(owner);
        address affiliate = makeAddr("affiliate");
        _setPublicInvite(collection, 0.08 ether, uint32(block.timestamp));
        bytes memory oldAuthorization = _affiliateSignature(collection, affiliate);

        _prank(owner);
        affiliateSignerRegistry.setAffiliateSigner(vm.addr(WRONG_AFFILIATE_SIGNER_PK));

        _prank(buyer);
        vm.expectRevert(InvalidAffiliateAuthorization.selector);
        collection.mint{value: 0.08 ether}(_publicAuth(), 1, affiliate, oldAuthorization, _constraints());

        bytes memory newAuthorization =
            _affiliateSignatureFor(collection, affiliate, buyer, block.timestamp + 1 hours, WRONG_AFFILIATE_SIGNER_PK);
        _prank(buyer);
        collection.mint{value: 0.08 ether}(_publicAuth(), 1, affiliate, newAuthorization, _constraints());

        assertEq(collection.ownerOf(1), buyer);
    }

    function test_affiliateSignatureValidationAndPayoutCredits() public {
        ArchetypeErc721a collection = _createCollection(owner);
        ArchetypePayouts payouts = ArchetypePayouts(PAYOUTS);
        address affiliate = makeAddr("affiliate");
        bytes memory invalidSignature =
            _affiliateSignatureFor(collection, affiliate, buyer, block.timestamp + 1 hours, WRONG_AFFILIATE_SIGNER_PK);
        bytes memory validSignature = _affiliateSignature(collection, affiliate);
        address[] memory tokens = _nativeTokenList();

        _setPublicInvite(collection, 0.08 ether, uint32(block.timestamp));

        _prank(buyer);
        vm.expectRevert(InvalidAffiliateAuthorization.selector);
        collection.mint{value: 0.08 ether}(_publicAuth(), 1, affiliate, invalidSignature, _constraints());

        _prank(buyer);
        collection.mint{value: 0.08 ether}(_publicAuth(), 1, affiliate, validSignature, _constraints());

        // fee breakdown:
        //   mintPrice        = 0.08 ether
        //   payoutBalance    = 0.08 ether * 8500 / 10000 = 0.068 ether
        //   affiliatePayout  = 0.08 ether * 1500 / 10000 = 0.012 ether
        assertEq(payouts.balance(affiliate), 0.012 ether);

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
        collection.mint{value: 0.08 ether}(_publicAuth(), 1, affiliate, validSignature, _constraints());
        // fee breakdown:
        //   firstAffiliatePayout  = 0.08 ether * 1500 / 10000 = 0.012 ether
        //   secondAffiliatePayout = 0.08 ether * 1500 / 10000 = 0.012 ether
        //   totalAffiliatePayout  = 0.012 ether * 2 = 0.024 ether
        assertEq(payouts.balance(affiliate), 0.024 ether);

        // fee breakdown:
        //   previousPlatformPayout = 0.0034 ether
        //   secondPlatformPayout   = 0.0034 ether
        //   totalPlatformPayout    = 0.0034 ether * 2 = 0.0068 ether
        assertEq(payouts.balance(owner), 0.0646 ether);
        assertEq(payouts.balance(PLATFORM), 0.0068 ether);

        uint256 affiliateBalanceBefore = affiliate.balance;
        _prank(affiliate);
        payouts.withdraw();
        assertEq(affiliate.balance - affiliateBalanceBefore, 0.024 ether);

        ownerBalanceBefore = owner.balance;
        _prank(owner);
        payouts.withdraw();
        assertEq(owner.balance - ownerBalanceBefore, 0.0646 ether);

        uint256 platformBalanceBefore = PLATFORM.balance;
        _prank(PLATFORM);
        payouts.withdraw();
        assertEq(PLATFORM.balance - platformBalanceBefore, 0.0068 ether);

        _prank(owner);
        vm.expectRevert(PayoutBalanceEmpty.selector);
        payouts.withdraw();

        _prank(PLATFORM);
        vm.expectRevert(PayoutBalanceEmpty.selector);
        payouts.withdrawTokens(tokens);
    }

    function test_burnToMint_basicFunctionality() public {
        ArchetypeErc721a nftBurn = _createCollection(owner);
        vm.warp(block.timestamp + 1);
        ArchetypeErc721a nftMint = _createCollection(owner);

        _setInvite(
            nftMint,
            ZERO_KEY,
            Invite({
                price: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: 5000,
                maxSupply: 5000,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );
        _setBurnInvite(
            nftBurn,
            ZERO_KEY,
            BurnInvite({
                burnErc721: IERC721(address(nftMint)),
                burnAddress: DEAD,
                tokenAddress: address(0),
                price: 0,
                reversed: false,
                ratio: 2,
                start: uint32(block.timestamp),
                end: 0,
                limit: 5000
            })
        );

        _mint(nftMint, buyer, _auth(ZERO_KEY), 12, 0);

        _prank(buyer);
        nftMint.setApprovalForAll(address(nftBurn), true);
        nftMint.transferFrom(buyer, owner, 10);

        uint256[] memory tokenIds = _rangeTokenIds(9, 2);
        _prank(buyer);
        vm.expectRevert(NotTokenOwner.selector);
        nftBurn.burnToMint(_auth(ZERO_KEY), tokenIds, _burnConstraints(address(nftMint), DEAD, _constraints()));

        tokenIds = _rangeTokenIds(9, 1);
        _prank(buyer);
        vm.expectRevert(InvalidAmountOfTokens.selector);
        nftBurn.burnToMint(_auth(ZERO_KEY), tokenIds, _burnConstraints(address(nftMint), DEAD, _constraints()));

        tokenIds = new uint256[](2);
        tokenIds[0] = 2;
        tokenIds[1] = 4;
        _prank(buyer);
        nftBurn.burnToMint(_auth(ZERO_KEY), tokenIds, _burnConstraints(address(nftMint), DEAD, _constraints()));

        tokenIds = new uint256[](4);
        tokenIds[0] = 1;
        tokenIds[1] = 3;
        tokenIds[2] = 5;
        tokenIds[3] = 8;
        _prank(buyer);
        nftBurn.burnToMint(_auth(ZERO_KEY), tokenIds, _burnConstraints(address(nftMint), DEAD, _constraints()));

        _setBurnInvite(
            nftBurn,
            ZERO_KEY,
            BurnInvite({
                burnErc721: IERC721(address(nftMint)),
                burnAddress: DEAD,
                tokenAddress: address(0),
                price: 0,
                reversed: false,
                ratio: 2,
                start: uint32(block.timestamp),
                end: 0,
                limit: 0
            })
        );
        tokenIds = _rangeTokenIds(11, 2);
        _prank(buyer);
        vm.expectRevert(MintingPaused.selector);
        nftBurn.burnToMint(_auth(ZERO_KEY), tokenIds, _burnConstraints(address(nftMint), DEAD, _constraints()));

        _setBurnInvite(
            nftBurn,
            ZERO_KEY,
            BurnInvite({
                burnErc721: IERC721(address(nftMint)),
                burnAddress: DEAD,
                tokenAddress: address(0),
                price: 0,
                reversed: false,
                ratio: 2,
                start: uint32(block.timestamp + 100),
                end: 0,
                limit: 5000
            })
        );
        _prank(buyer);
        vm.expectRevert(MintNotYetStarted.selector);
        nftBurn.burnToMint(_auth(ZERO_KEY), tokenIds, _burnConstraints(address(nftMint), DEAD, _constraints()));

        _setBurnInvite(
            nftBurn,
            ZERO_KEY,
            BurnInvite({
                burnErc721: IERC721(address(nftMint)),
                burnAddress: DEAD,
                tokenAddress: address(0),
                price: 0,
                reversed: false,
                ratio: 2,
                start: uint32(block.timestamp),
                end: 0,
                limit: 5000
            })
        );
        _prank(buyer);
        nftBurn.burnToMint(_auth(ZERO_KEY), tokenIds, _burnConstraints(address(nftMint), DEAD, _constraints()));

        tokenIds = _rangeTokenIds(7, 1);
        _setBurnInvite(
            nftBurn,
            ZERO_KEY,
            BurnInvite({
                burnErc721: IERC721(address(nftMint)),
                burnAddress: DEAD,
                tokenAddress: address(0),
                price: 0,
                reversed: true,
                ratio: 4,
                start: uint32(block.timestamp),
                end: 0,
                limit: 5000
            })
        );
        _prank(buyer);
        nftBurn.burnToMint(_auth(ZERO_KEY), tokenIds, _burnConstraints(address(nftMint), DEAD, _constraints()));

        assertEq(nftMint.ownerOf(1), DEAD);
        assertEq(nftMint.ownerOf(2), DEAD);
        assertEq(nftMint.ownerOf(3), DEAD);
        assertEq(nftMint.ownerOf(4), DEAD);
        assertEq(nftMint.ownerOf(5), DEAD);
        assertEq(nftMint.ownerOf(7), DEAD);
        assertEq(nftMint.ownerOf(8), DEAD);
        assertEq(nftMint.ownerOf(11), DEAD);
        assertEq(nftMint.ownerOf(12), DEAD);
        assertEq(nftMint.balanceOf(buyer), 2);
        assertEq(nftBurn.balanceOf(buyer), 8);
    }

    function test_burnToMint_privateList() public {
        ArchetypeErc721a nftBurn = _createCollection(owner);
        vm.warp(block.timestamp + 1);
        ArchetypeErc721a nftMint = _createCollection(owner);
        bytes32 allowlistRoot = keccak256(abi.encodePacked(buyer));

        _setInvite(
            nftMint,
            ZERO_KEY,
            Invite({
                price: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: 5000,
                maxSupply: 5000,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );
        _setBurnInvite(
            nftBurn,
            allowlistRoot,
            BurnInvite({
                burnErc721: IERC721(address(nftMint)),
                burnAddress: DEAD,
                tokenAddress: address(0),
                price: 0.05 ether,
                reversed: true,
                ratio: 2,
                start: uint32(block.timestamp),
                end: 0,
                limit: 5000
            })
        );

        _mint(nftMint, buyer, _auth(ZERO_KEY), 4, 0);
        _mint(nftMint, other, _auth(ZERO_KEY), 2, 0);

        _prank(buyer);
        nftMint.setApprovalForAll(address(nftBurn), true);
        _prank(other);
        nftMint.setApprovalForAll(address(nftBurn), true);

        uint256[] memory tokenIds = _rangeTokenIds(1, 2);
        _prank(buyer);
        nftBurn.burnToMint{value: 0.05 ether}(
            _auth(allowlistRoot), tokenIds, _burnConstraints(address(nftMint), DEAD, _constraints())
        );

        _prank(other);
        vm.expectRevert(WalletUnauthorizedToMint.selector);
        nftBurn.burnToMint{value: 0.05 ether}(
            _auth(allowlistRoot), _rangeTokenIds(5, 2), _burnConstraints(address(nftMint), DEAD, _constraints())
        );

        assertEq(nftMint.ownerOf(1), DEAD);
        assertEq(nftMint.ownerOf(2), DEAD);
        assertEq(nftMint.balanceOf(buyer), 2);
        assertEq(nftBurn.balanceOf(buyer), 4);
    }

    function test_burnToMint_publicListHasNoMinimumFee() public {
        ArchetypeErc721a nftBurn = _createCollection(owner);
        vm.warp(block.timestamp + 1);
        ArchetypeErc721a nftMint = _createCollection(owner);

        _setInvite(
            nftMint,
            ZERO_KEY,
            Invite({
                price: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: 5000,
                maxSupply: 5000,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );
        _setBurnInvite(
            nftBurn,
            ZERO_KEY,
            BurnInvite({
                burnErc721: IERC721(address(nftMint)),
                burnAddress: DEAD,
                tokenAddress: address(0),
                price: 0.1 ether,
                reversed: true,
                ratio: 2,
                start: uint32(block.timestamp),
                end: 0,
                limit: 5000
            })
        );
        _mint(nftMint, buyer, _auth(ZERO_KEY), 1, 0);

        _prank(buyer);
        nftMint.setApprovalForAll(address(nftBurn), true);
        _prank(owner);
        mintFeeRegistry.setNativeMinimumFee(1 ether);

        _prank(buyer);
        nftBurn.burnToMint{value: 0.1 ether}(
            _auth(ZERO_KEY), _rangeTokenIds(1, 1), _burnConstraints(address(nftMint), DEAD, _constraints())
        );

        assertEq(nftBurn.balanceOf(buyer), 2);
        assertEq(nftMint.ownerOf(1), DEAD);
        assertEq(ArchetypePayouts(PAYOUTS).balance(owner), 0.095 ether);
        assertEq(ArchetypePayouts(PAYOUTS).balance(PLATFORM), 0.005 ether);
    }

    function test_burnToMint_erc20PaymentAndSelfBurn() public {
        ArchetypeErc721a nftBurn = _createCollection(owner);
        TestErc20 erc20 = new TestErc20();

        _setInvite(
            nftBurn,
            ZERO_KEY,
            Invite({
                price: 1 ether,
                start: uint32(block.timestamp),
                end: 0,
                limit: 5000,
                maxSupply: 5000,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );
        _mint(nftBurn, buyer, _auth(ZERO_KEY), 4, 4 ether);

        _setBurnInvite(
            nftBurn,
            ZERO_KEY,
            BurnInvite({
                burnErc721: IERC721(address(nftBurn)),
                burnAddress: DEAD,
                tokenAddress: address(erc20),
                price: 10 ether,
                reversed: false,
                ratio: 2,
                start: uint32(block.timestamp),
                end: 0,
                limit: 5000
            })
        );

        _prank(buyer);
        erc20.mint(20 ether);
        _prank(buyer);
        erc20.approve(address(nftBurn), type(uint256).max);
        _prank(buyer);
        nftBurn.setApprovalForAll(address(nftBurn), true);

        uint256[] memory tokenIds = _rangeTokenIds(1, 2);
        _prank(buyer);
        nftBurn.burnToMint(
            _auth(ZERO_KEY),
            tokenIds,
            _burnConstraints(address(nftBurn), DEAD, _constraints(address(erc20), type(uint128).max, 1))
        );

        assertEq(nftBurn.balanceOf(buyer), 3);
        assertEq(erc20.balanceOf(buyer), 10 ether);
        assertEq(erc20.balanceOf(address(nftBurn)), 0);
        assertEq(ArchetypePayouts(PAYOUTS).balanceToken(owner, address(erc20)), 9.5 ether);
        assertEq(ArchetypePayouts(PAYOUTS).balanceToken(PLATFORM, address(erc20)), 0.5 ether);
        assertEq(ArchetypePayouts(PAYOUTS).balance(PLATFORM), 0.2 ether);
        assertEq(nftBurn.ownerOf(1), DEAD);
        assertEq(nftBurn.ownerOf(2), DEAD);

        _prank(buyer);
        vm.expectRevert(NotTokenOwner.selector);
        nftBurn.burnToMint(
            _auth(ZERO_KEY),
            tokenIds,
            _burnConstraints(address(nftBurn), DEAD, _constraints(address(erc20), type(uint128).max, 1))
        );
    }

    function test_maxSupply_checksMintAndBurnToMint() public {
        Config memory config = _configWithSupply(5000, 5000);
        ArchetypeErc721a nftBurn = _createCollectionWithConfig(owner, config);
        vm.warp(block.timestamp + 1);
        ArchetypeErc721a nftMint = _createCollectionWithConfig(owner, config);
        BonusDiscount[] memory discounts = new BonusDiscount[](1);

        _setInvite(
            nftBurn,
            ZERO_KEY,
            Invite({
                price: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: 5000,
                maxSupply: 5000,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );
        _setInvite(
            nftMint,
            ZERO_KEY,
            Invite({
                price: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: 5000,
                maxSupply: 5000,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );
        _setBurnInvite(
            nftBurn,
            ZERO_KEY,
            BurnInvite({
                burnErc721: IERC721(address(nftMint)),
                burnAddress: address(0),
                tokenAddress: address(0),
                price: 0,
                reversed: false,
                ratio: 2,
                start: uint32(block.timestamp),
                end: 0,
                limit: 5000
            })
        );

        _mint(nftMint, buyer, _auth(ZERO_KEY), 10, 0);

        _prank(buyer);
        vm.expectRevert(MaxSupplyExceeded.selector);
        nftMint.mint(_auth(ZERO_KEY), 4991, address(0), "", _constraints());

        _mint(nftMint, buyer, _auth(ZERO_KEY), 4989, 0);
        discounts[0] = BonusDiscount({numMints: 1, numBonusMints: 1});
        _prank(owner);
        nftMint.setBonusDiscounts(ZERO_KEY, discounts);

        _prank(buyer);
        vm.expectRevert(MaxSupplyExceeded.selector);
        nftMint.mint(_auth(ZERO_KEY), 1, address(0), "", _constraints());

        BonusDiscount[] memory emptyDiscounts = new BonusDiscount[](0);
        _prank(owner);
        nftMint.setBonusDiscounts(ZERO_KEY, emptyDiscounts);
        _mint(nftMint, buyer, _auth(ZERO_KEY), 1, 0);

        _prank(buyer);
        vm.expectRevert(MaxSupplyExceeded.selector);
        nftMint.mint(_auth(ZERO_KEY), 1, address(0), "", _constraints());

        _mint(nftBurn, buyer, _auth(ZERO_KEY), 4990, 0);
        _prank(buyer);
        nftMint.setApprovalForAll(address(nftBurn), true);

        uint256[] memory tokenIds = _rangeTokenIds(1, 40);
        _prank(buyer);
        vm.expectRevert(MaxSupplyExceeded.selector);
        nftBurn.burnToMint(_auth(ZERO_KEY), tokenIds, _burnConstraints(address(nftMint), DEAD, _constraints()));

        tokenIds = _rangeTokenIds(1, 20);
        _prank(buyer);
        nftBurn.burnToMint(_auth(ZERO_KEY), tokenIds, _burnConstraints(address(nftMint), DEAD, _constraints()));

        tokenIds = _rangeTokenIds(21, 2);
        _prank(buyer);
        vm.expectRevert(MaxSupplyExceeded.selector);
        nftBurn.burnToMint(_auth(ZERO_KEY), tokenIds, _burnConstraints(address(nftMint), DEAD, _constraints()));

        assertEq(nftBurn.totalSupply(), 5000);
        assertEq(nftMint.totalSupply(), 5000);
    }

    function test_mint_inviteListMaxSupply() public {
        ArchetypeErc721a collection = _createCollectionWithConfig(owner, _configWithSupply(100, 100));

        _setInvite(
            collection,
            ZERO_KEY,
            Invite({
                price: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: 70,
                maxSupply: 90,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );

        _mint(collection, buyer, _auth(ZERO_KEY), 40, 0);

        _prank(other);
        vm.expectRevert(ListMaxSupplyExceeded.selector);
        collection.mint(_auth(ZERO_KEY), 60, address(0), "", _constraints());

        _mint(collection, other, _auth(ZERO_KEY), 50, 0);

        assertEq(collection.totalSupply(), 90);
    }

    function test_mint_multiplePublicInviteLists() public {
        ArchetypeErc721a collection = _createCollectionWithConfig(owner, _configWithSupply(100, 100));

        _setInvite(
            collection,
            ZERO_KEY,
            Invite({
                price: 1 ether,
                start: uint32(block.timestamp),
                end: 0,
                limit: 100,
                maxSupply: 100,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );
        _mint(collection, buyer, _auth(ZERO_KEY), 40, 40 ether);

        _setInvite(
            collection,
            PUBLIC_KEY,
            Invite({
                price: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: 100,
                maxSupply: 100,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );
        _mint(collection, other, _auth(PUBLIC_KEY), 20, 0);

        _setInvite(
            collection,
            HASH256,
            Invite({
                price: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: 100,
                maxSupply: 100,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );
        _mint(collection, other, _auth(HASH256), 40, 0);

        assertEq(collection.totalSupply(), 100);
    }

    function test_mint_unitSizeMintOneGetX() public {
        ArchetypeErc721a collection = _createCollectionWithConfig(owner, _configWithSupply(100, 100));

        _setInvite(
            collection,
            ZERO_KEY,
            Invite({
                price: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: 24,
                maxSupply: 36,
                unitSize: 12,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );

        _mint(collection, buyer, _auth(ZERO_KEY), 1, 0);

        _prank(buyer);
        vm.expectRevert(NumberOfMintsExceeded.selector);
        collection.mint(_auth(ZERO_KEY), 2, address(0), "", _constraints());

        _mint(collection, other, _auth(ZERO_KEY), 2, 0);

        _prank(owner);
        vm.expectRevert(ListMaxSupplyExceeded.selector);
        collection.mint(_auth(ZERO_KEY), 1, address(0), "", _constraints());

        assertEq(collection.balanceOf(buyer), 12);
        assertEq(collection.balanceOf(other), 24);
        assertEq(collection.totalSupply(), 36);
    }

    function test_defaultRoyalty_erc2981() public {
        ArchetypeErc721a collection = _createCollection(owner);
        (address receiver, uint256 royaltyAmount) = collection.royaltyInfo(0, 1 ether);

        assertEq(receiver, owner);
        assertEq(royaltyAmount, 0.05 ether);

        _prank(owner);
        collection.setDefaultRoyalty(buyer, 1000);

        (receiver, royaltyAmount) = collection.royaltyInfo(0, 1 ether);
        assertEq(receiver, buyer);
        assertEq(royaltyAmount, 0.1 ether);
    }

    function test_mint_erc20PricedInvite() public {
        ArchetypeErc721a collection = _createCollection(owner);
        ArchetypePayouts payouts = ArchetypePayouts(PAYOUTS);
        TestErc20 erc20 = new TestErc20();
        bytes32 erc20Key = keccak256(abi.encodePacked(address(erc20)));
        address[] memory tokens = new address[](1);
        tokens[0] = address(erc20);

        _setInvite(
            collection,
            erc20Key,
            Invite({
                price: 1 ether,
                start: uint32(block.timestamp),
                end: 0,
                limit: 5000,
                maxSupply: 5000,
                unitSize: 1,
                tokenAddress: address(erc20),
                isBlacklist: false
            })
        );

        _prank(buyer);
        vm.expectRevert(NotApprovedToTransfer.selector);
        collection.mint(_auth(erc20Key), 3, address(0), "", _constraints(address(erc20), type(uint128).max, 3));

        _prank(buyer);
        erc20.approve(address(collection), type(uint256).max);
        _prank(buyer);
        vm.expectRevert(Erc20BalanceTooLow.selector);
        collection.mint(_auth(erc20Key), 3, address(0), "", _constraints(address(erc20), type(uint128).max, 3));

        _prank(buyer);
        erc20.mint(3 ether);
        _prank(buyer);
        collection.mint(_auth(erc20Key), 3, address(0), "", _constraints(address(erc20), type(uint128).max, 3));

        assertEq(collection.balanceOf(buyer), 3);
        assertEq(erc20.balanceOf(buyer), 0);
        assertEq(erc20.balanceOf(address(collection)), 0);
        assertEq(erc20.balanceOf(PAYOUTS), 3 ether);

        _prank(owner);
        payouts.withdrawTokens(tokens);
        // fee breakdown:
        //   tokenBalance   = 3 ether
        //   ownerPayout    = 3 ether * 9500 / 10000 = 2.85 ether
        //   platformPayout = 3 ether * 500 / 10000  = 0.15 ether
        assertEq(erc20.balanceOf(PAYOUTS), 0.15 ether);

        _prank(PLATFORM);
        payouts.withdrawTokens(tokens);
        assertEq(erc20.balanceOf(owner), 2.85 ether);
        assertEq(erc20.balanceOf(PLATFORM), 0.15 ether);
    }

    function test_mint_rejectsFeeOnTransferErc20() public {
        ArchetypeErc721a collection = _createCollection(owner);
        FeeOnTransferErc20 erc20 = new FeeOnTransferErc20();
        bytes32 erc20Key = keccak256(abi.encodePacked(address(erc20)));

        _setInvite(
            collection,
            erc20Key,
            Invite({
                price: 1 ether,
                start: uint32(block.timestamp),
                end: 0,
                limit: 5000,
                maxSupply: 5000,
                unitSize: 1,
                tokenAddress: address(erc20),
                isBlacklist: false
            })
        );

        erc20.mint(buyer, 1 ether);
        _prank(buyer);
        erc20.approve(address(collection), type(uint256).max);

        _prank(buyer);
        vm.expectRevert(UnexpectedTokenBalanceChange.selector);
        collection.mint(_auth(erc20Key), 1, address(0), "", _constraints(address(erc20), type(uint128).max, 1));

        assertEq(collection.totalSupply(), 0);
        assertEq(erc20.balanceOf(buyer), 1 ether);
        assertEq(erc20.balanceOf(address(collection)), 0);
        assertEq(erc20.balanceOf(PAYOUTS), 0);
    }

    function test_mint_noReturnErc20PricedInvite() public {
        ArchetypeErc721a collection = _createCollection(owner);
        ArchetypePayouts payouts = ArchetypePayouts(PAYOUTS);
        NoReturnErc20 erc20 = new NoReturnErc20();
        address affiliate = makeAddr("affiliate");
        bytes32 erc20Key = keccak256(abi.encodePacked(address(erc20)));
        address[] memory tokens = new address[](1);
        tokens[0] = address(erc20);

        Invite memory invite = Invite({
            price: 1 ether,
            start: uint32(block.timestamp),
            end: 0,
            limit: 5000,
            maxSupply: 5000,
            unitSize: 1,
            tokenAddress: address(erc20),
            isBlacklist: false
        });
        _setInvite(collection, erc20Key, invite);
        _setInvite(collection, erc20Key, invite);

        erc20.mint(buyer, 3 ether);
        _prank(buyer);
        erc20.approve(address(collection), type(uint256).max);
        collection.mint(
            _auth(erc20Key),
            3,
            affiliate,
            _affiliateSignature(collection, affiliate),
            _constraints(address(erc20), type(uint128).max, 3)
        );

        assertEq(collection.balanceOf(buyer), 3);
        assertEq(erc20.balanceOf(address(collection)), 0);
        assertEq(payouts.balanceToken(affiliate, address(erc20)), 0.45 ether);
        _prank(owner);
        payouts.withdrawTokens(tokens);

        _prank(PLATFORM);
        payouts.withdrawTokens(tokens);

        _prank(affiliate);
        payouts.withdrawTokens(tokens);

        assertEq(erc20.balanceOf(owner), 2.4225 ether);
        assertEq(erc20.balanceOf(PLATFORM), 0.1275 ether);
        assertEq(erc20.balanceOf(affiliate), 0.45 ether);
    }

    function test_setBurnInvite_reapprovesZeroFirstErc20() public {
        ArchetypeErc721a collection = _createCollection(owner);
        NoReturnErc20 erc20 = new NoReturnErc20();
        BurnInvite memory invite = BurnInvite({
            burnErc721: IERC721(address(collection)),
            burnAddress: DEAD,
            tokenAddress: address(erc20),
            price: 1 ether,
            reversed: false,
            ratio: 1,
            start: uint32(block.timestamp),
            end: 0,
            limit: 5000
        });

        _setBurnInvite(collection, ZERO_KEY, invite);
        _setBurnInvite(collection, ZERO_KEY, invite);

        assertEq(erc20.allowance(address(collection), PAYOUTS), type(uint256).max);
    }

    function test_setBurnInvite_preservesAnExpiredWindowOnEdit() public {
        ArchetypeErc721a collection = _createCollection(owner);
        uint32 start = uint32(block.timestamp);
        uint32 end = start + 1 hours;
        BurnInvite memory invite = BurnInvite({
            burnErc721: IERC721(address(collection)),
            burnAddress: DEAD,
            tokenAddress: address(0),
            price: 0,
            reversed: false,
            ratio: 1,
            start: start,
            end: end,
            limit: 5000
        });

        _setBurnInvite(collection, ZERO_KEY, invite);
        vm.warp(end + 1);
        _setBurnInvite(collection, ZERO_KEY, invite);

        (,,,,,, uint32 storedStart, uint32 storedEnd,) = collection.burnInvites(ZERO_KEY);
        assertEq(storedStart, start);
        assertEq(storedEnd, end);
    }

    function test_mint_bonusDiscountsAndAffiliateDiscounts() public {
        Config memory config = defaultConfig;
        config.maxBatchSize = 100;
        config.affiliateFee = 1500;
        config.affiliateDiscount = 1000;
        ArchetypeErc721a collection = _createCollectionWithConfig(owner, config);
        address affiliate = makeAddr("affiliate");
        bytes memory signature = _affiliateSignature(collection, affiliate);
        BonusDiscount[] memory discounts = new BonusDiscount[](3);

        discounts[0] = BonusDiscount({numMints: 20, numBonusMints: 10});
        discounts[1] = BonusDiscount({numMints: 10, numBonusMints: 4});
        discounts[2] = BonusDiscount({numMints: 3, numBonusMints: 1});

        _prank(owner);
        collection.setBonusInvite(
            ZERO_KEY,
            CID_ZERO,
            Invite({
                price: 0.01 ether,
                start: uint32(block.timestamp),
                end: 0,
                limit: 300,
                maxSupply: defaultConfig.maxSupply,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            }),
            discounts
        );

        _prank(buyer);
        collection.mint{value: 0.027 ether}(_auth(ZERO_KEY), 3, affiliate, signature, _constraints());

        assertEq(collection.ownerOf(4), buyer);
        assertEq(collection.totalSupply(), 4);

        _prank(buyer);
        collection.mint{value: 0.08 ether}(_auth(ZERO_KEY), 8, address(0), "", _constraints());

        assertEq(collection.totalSupply(), 14);

        _prank(buyer);
        collection.mint{value: 0.21 ether}(_auth(ZERO_KEY), 21, address(0), "", _constraints());

        assertEq(collection.totalSupply(), 45);
    }

    function test_mint_creditsSuperAffiliatePayout() public {
        address affiliate = makeAddr("affiliate");
        address superAffiliate = makeAddr("superAffiliate");
        PayoutConfig memory payoutConfig = PayoutConfig({
            ownerBps: 9000,
            platformBps: 500,
            partnerBps: 0,
            superAffiliateBps: 500,
            partner: address(0),
            superAffiliate: superAffiliate,
            ownerAltPayout: address(0)
        });
        ArchetypeErc721a collection = _createCollectionWithPayout(owner, defaultConfig, payoutConfig);
        ArchetypePayouts payouts = ArchetypePayouts(PAYOUTS);
        bytes memory signature = _affiliateSignature(collection, affiliate);

        vm.deal(superAffiliate, 100 ether);

        _setInvite(
            collection,
            ZERO_KEY,
            Invite({
                price: 0.1 ether,
                start: uint32(block.timestamp),
                end: 0,
                limit: 300,
                maxSupply: defaultConfig.maxSupply,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );

        _prank(buyer);
        collection.mint{value: 0.1 ether}(_auth(ZERO_KEY), 1, affiliate, signature, _constraints());

        // fee breakdown:
        //   mintPrice        = 0.1 ether
        //   payoutBalance    = 0.1 ether * 8500 / 10000 = 0.085 ether
        //   affiliatePayout  = 0.1 ether * 1500 / 10000 = 0.015 ether
        assertEq(payouts.balance(affiliate), 0.015 ether);

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
    }

    function test_mint_usesOwnerAltPayout() public {
        address altPayout = makeAddr("altPayout");
        PayoutConfig memory payoutConfig = PayoutConfig({
            ownerBps: 9000,
            platformBps: 500,
            partnerBps: 500,
            superAffiliateBps: 0,
            partner: buyer,
            superAffiliate: address(0),
            ownerAltPayout: altPayout
        });
        ArchetypeErc721a collection = _createCollectionWithPayout(owner, defaultConfig, payoutConfig);
        ArchetypePayouts payouts = ArchetypePayouts(PAYOUTS);

        vm.deal(altPayout, 100 ether);

        _setInvite(
            collection,
            ZERO_KEY,
            Invite({
                price: 0.1 ether,
                start: uint32(block.timestamp),
                end: 0,
                limit: 300,
                maxSupply: defaultConfig.maxSupply,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );

        _mint(collection, other, _auth(ZERO_KEY), 1, 0.1 ether);

        vm.txGasPrice(0);
        uint256 altBalanceBefore = altPayout.balance;

        // fee breakdown:
        //   ownerBalance   = 0.1 ether
        //   altPayout      = 0.1 ether * 9000 / 10000 = 0.09 ether
        //   platformPayout = 0.1 ether * 500 / 10000  = 0.005 ether
        //   partnerPayout  = 0.1 ether * 500 / 10000  = 0.005 ether
        assertEq(altPayout.balance, altBalanceBefore);
        assertEq(payouts.balance(owner), 0);
        assertEq(payouts.balance(altPayout), 0.09 ether);
        assertEq(payouts.balance(PLATFORM), 0.005 ether);
        assertEq(payouts.balance(buyer), 0.005 ether);

        _mint(collection, other, _auth(ZERO_KEY), 1, 0.1 ether);

        // fee breakdown:
        //   previousAltPayout      = 0.09 ether
        //   secondAltPayout        = 0.09 ether
        //   totalAltPayout         = 0.09 ether * 2 = 0.18 ether
        //   totalPlatformPayout    = 0.005 ether * 2 = 0.01 ether
        //   totalPartnerPayout     = 0.005 ether * 2 = 0.01 ether
        assertEq(altPayout.balance, altBalanceBefore);
        assertEq(payouts.balance(altPayout), 0.18 ether);
        assertEq(payouts.balance(PLATFORM), 0.01 ether);
        assertEq(payouts.balance(buyer), 0.01 ether);

        _prank(owner);
        collection.setOwnerAltPayout(address(0));

        _mint(collection, other, _auth(ZERO_KEY), 1, 0.1 ether);
        assertEq(payouts.balance(altPayout), 0.18 ether);
        assertEq(payouts.balance(owner), 0.09 ether);
    }

    function test_mint_creditsCurrentOwner() public {
        ArchetypeErc721a collection = _createCollection(owner);
        ArchetypePayouts payouts = ArchetypePayouts(PAYOUTS);
        _setPublicInvite(collection, 0.1 ether, uint32(block.timestamp));

        _mintPublic(collection, buyer, address(0), 0.1 ether);
        _prank(owner);
        collection.transferOwnership(other);
        _mintPublic(collection, buyer, address(0), 0.1 ether);

        assertEq(payouts.balance(owner), 0.095 ether);
        assertEq(payouts.balance(other), 0.095 ether);
        assertEq(payouts.balance(PLATFORM), 0.01 ether);
    }

    function test_mint_afterRenouncingOwnership_creditsPlatform() public {
        ArchetypeErc721a collection = _createCollection(owner);
        ArchetypePayouts payouts = ArchetypePayouts(PAYOUTS);
        _setPublicInvite(collection, 0.1 ether, uint32(block.timestamp));

        _prank(owner);
        collection.renounceOwnership();
        _mintPublic(collection, buyer, address(0), 0.1 ether);

        assertEq(collection.balanceOf(buyer), 1);
        assertEq(payouts.balance(owner), 0);
        assertEq(payouts.balance(PLATFORM), 0.1 ether);
    }

    function test_mint_failsWhenDefaultPublicInviteIsPaused() public {
        ArchetypeErc721a collection = _createCollection(owner);

        _prank(buyer);
        vm.expectRevert(MintingPaused.selector);
        collection.mint{value: 0.08 ether}(_auth(ZERO_KEY), 1, address(0), "", _constraints());
    }

    function test_mintTo_mintsToAnotherWallet() public {
        ArchetypeErc721a collection = _createCollection(owner);

        _setInvite(
            collection,
            ZERO_KEY,
            Invite({
                price: 0.02 ether,
                start: uint32(block.timestamp),
                end: 0,
                limit: 300,
                maxSupply: defaultConfig.maxSupply,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );

        _prank(owner);
        collection.mintTo{value: 0.06 ether}(_auth(ZERO_KEY), 3, buyer, address(0), "", _constraints());

        assertEq(collection.balanceOf(buyer), 3);
        assertEq(collection.balanceOf(owner), 0);

        _prank(owner);
        vm.expectRevert(IERC721AUpgradeable.MintToZeroAddress.selector);
        collection.mintTo{value: 0.02 ether}(_auth(ZERO_KEY), 1, address(0), address(0), "", _constraints());
    }

    function test_batchMintTo_airdrop() public {
        ArchetypeErc721a collection =
            _createCollectionWithConfig(owner, _configWithSupply(defaultConfig.maxSupply, 100));
        bytes32 ownerRoot = keccak256(abi.encodePacked(owner));
        address[] memory recipients = new address[](100);
        uint256[] memory quantities = new uint256[](100);

        _setInvite(
            collection,
            ownerRoot,
            Invite({
                price: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: 5000,
                maxSupply: defaultConfig.maxSupply,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );

        for (uint256 i; i < 100; ++i) {
            recipients[i] = vm.addr(i + 1);
            quantities[i] = 1;
        }

        address[] memory firstRecipients = new address[](50);
        address[] memory secondRecipients = new address[](50);
        uint256[] memory firstQuantities = new uint256[](50);
        uint256[] memory secondQuantities = new uint256[](50);

        for (uint256 i; i < 50; ++i) {
            firstRecipients[i] = recipients[i];
            firstQuantities[i] = quantities[i];
            secondRecipients[i] = recipients[i + 50];
            secondQuantities[i] = quantities[i + 50];
        }

        _prank(owner);
        collection.batchMintTo(_auth(ownerRoot), _batchMintArgs(firstRecipients, firstQuantities, _constraints()));
        collection.batchMintTo(_auth(ownerRoot), _batchMintArgs(secondRecipients, secondQuantities, _constraints()));

        assertEq(collection.totalSupply(), 100);
        assertEq(collection.ownerOf(1), recipients[0]);
        assertEq(collection.ownerOf(10), recipients[9]);
        assertEq(collection.ownerOf(20), recipients[19]);
        assertEq(collection.ownerOf(60), recipients[59]);
        assertEq(collection.ownerOf(100), recipients[99]);
    }

    function test_batchMintTo_rejectsNonOwner() public {
        ArchetypeErc721a collection = _createCollection(owner);
        address[] memory recipients = new address[](1);
        recipients[0] = buyer;
        uint256[] memory quantities = new uint256[](1);
        quantities[0] = 1;

        _prank(buyer);
        vm.expectRevert(NotOwner.selector);
        collection.batchMintTo(_publicAuth(), _batchMintArgs(recipients, quantities, _constraints()));
    }

    function test_batch_executeBatch_mintsAndConservesNativeValue() public {
        ArchetypeErc721a collection = _createCollectionWithConfig(owner, _configWithSupply(100, 100));
        ArchetypeBatchV100 batch = ArchetypeBatchV100(BATCH);
        address[] memory targets = new address[](3);
        uint256[] memory values = new uint256[](3);
        bytes[] memory datas = new bytes[](3);

        _setInvite(
            collection,
            ZERO_KEY,
            Invite({
                price: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: 100,
                maxSupply: 100,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );
        _setInvite(
            collection,
            PUBLIC_KEY,
            Invite({
                price: 0.1 ether,
                start: uint32(block.timestamp),
                end: 0,
                limit: 100,
                maxSupply: 100,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );

        for (uint256 i; i < targets.length; ++i) {
            targets[i] = address(collection);
        }

        values[2] = 0.2 ether;
        datas[0] = abi.encodeCall(collection.mint, (_auth(ZERO_KEY), 1, address(0), "", _constraints()));
        datas[1] = abi.encodeCall(collection.mint, (_auth(ZERO_KEY), 2, address(0), "", _constraints()));
        datas[2] = abi.encodeCall(collection.mint, (_auth(PUBLIC_KEY), 2, address(0), "", _constraints()));

        vm.txGasPrice(0);
        uint256 buyerBalanceBefore = buyer.balance;
        vm.stopPrank();
        vm.startPrank(buyer, buyer);
        batch.executeBatch{value: 0.2 ether}(targets, values, datas);
        vm.stopPrank();

        assertEq(collection.balanceOf(BATCH), 0);
        assertEq(collection.balanceOf(buyer), 5);
        assertEq(collection.totalSupply(), 5);
        assertEq(buyerBalanceBefore - buyer.balance, 0.2 ether);
        assertEq(address(batch).balance, 0);
    }

    function test_batch_usesDirectCaller() public {
        ArchetypeErc721a collection = _createCollectionWithConfig(owner, _configWithSupply(100, 100));
        ArchetypeBatchV100 batch = ArchetypeBatchV100(BATCH);
        bytes32 buyerRoot = keccak256(abi.encodePacked(buyer));
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory datas = new bytes[](2);

        _setInvite(
            collection,
            buyerRoot,
            Invite({
                price: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: 100,
                maxSupply: 100,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );
        _setInvite(
            collection,
            ZERO_KEY,
            Invite({
                price: 0.1 ether,
                start: uint32(block.timestamp),
                end: 0,
                limit: 100,
                maxSupply: 100,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );

        targets[0] = address(collection);
        targets[1] = address(collection);
        values[0] = 0.5 ether;
        datas[0] = abi.encodeCall(collection.mint, (_auth(ZERO_KEY), 5, address(0), "", _constraints()));
        datas[1] = abi.encodeCall(collection.mint, (_auth(buyerRoot), 5, address(0), "", _constraints()));

        vm.stopPrank();
        vm.startPrank(buyer, owner);
        batch.executeBatch{value: 0.5 ether}(targets, values, datas);
        vm.stopPrank();

        assertEq(collection.balanceOf(buyer), 10);
        assertEq(collection.totalSupply(), 10);
        assertEq(batch.currentCaller(), address(0));
    }

    function _createCollection(address receiver) internal returns (ArchetypeErc721a collection) {
        address collectionAddress =
            factory.createCollection(receiver, "Pookie", "POOKIE", defaultConfig, defaultPayoutConfig);
        collection = ArchetypeErc721a(collectionAddress);
    }

    function _createCollectionWithConfig(address receiver, Config memory config)
        internal
        returns (ArchetypeErc721a collection)
    {
        address collectionAddress = factory.createCollection(receiver, "Pookie", "POOKIE", config, defaultPayoutConfig);
        collection = ArchetypeErc721a(collectionAddress);
    }

    function _createCollectionWithPayout(address receiver, Config memory config, PayoutConfig memory payoutConfig)
        internal
        returns (ArchetypeErc721a collection)
    {
        address collectionAddress = factory.createCollection(receiver, "Pookie", "POOKIE", config, payoutConfig);
        collection = ArchetypeErc721a(collectionAddress);
    }

    function _configWithSupply(uint32 maxSupply, uint32 maxBatchSize) internal view returns (Config memory config) {
        config = defaultConfig;
        config.maxSupply = maxSupply;
        config.maxBatchSize = maxBatchSize;
    }

    function _setInvite(ArchetypeErc721a collection, bytes32 key, Invite memory invite) internal {
        _prank(owner);
        collection.setInvite(key, CID_ZERO, invite);
    }

    function _setBurnInvite(ArchetypeErc721a collection, bytes32 key, BurnInvite memory invite) internal {
        _prank(owner);
        collection.setBurnInvite(key, CID_ZERO, invite);
    }

    function _setPublicInvite(ArchetypeErc721a collection, uint128 price, uint32 start) internal {
        _prank(owner);
        collection.setInvite(
            PUBLIC_KEY,
            CID_ZERO,
            Invite({
                price: price,
                start: start,
                end: 0,
                limit: 5000,
                maxSupply: 5000,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );
    }

    function _mintPublic(ArchetypeErc721a collection, address minter, address affiliate, uint256 value) internal {
        _prank(minter);
        collection.mint{value: value}(_publicAuth(), 1, affiliate, "", _constraints());
    }

    function _mint(ArchetypeErc721a collection, address minter, Auth memory auth, uint256 quantity, uint256 value)
        internal
    {
        _prank(minter);
        collection.mint{value: value}(auth, quantity, address(0), "", _constraints());
    }

    function _publicAuth() internal pure returns (Auth memory) {
        return _auth(PUBLIC_KEY);
    }

    function _auth(bytes32 key) internal pure returns (Auth memory auth) {
        auth.key = key;
        auth.proof = new bytes32[](0);
    }

    function _nativeTokenList() internal pure returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = address(0);
    }

    function _rangeTokenIds(uint256 start, uint256 count) internal pure returns (uint256[] memory tokenIds) {
        tokenIds = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            tokenIds[i] = start + i;
        }
    }

    function _affiliateSignature(ArchetypeErc721a collection, address affiliate) internal view returns (bytes memory) {
        return _affiliateSignatureFor(collection, affiliate, buyer, block.timestamp + 1 hours, AFFILIATE_SIGNER_PK);
    }

    function _affiliateSignatureFor(
        ArchetypeErc721a collection,
        address affiliate,
        address minter,
        uint256 deadline,
        uint256 privateKey
    ) internal view returns (bytes memory) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Archetype"),
                keccak256("1"),
                block.chainid,
                address(collection)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("AffiliateAuthorization(address affiliate,address minter,uint256 deadline)"),
                affiliate,
                minter,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(bytes32(deadline), r, s, v);
    }

    function _configBaseUri(ArchetypeErc721a collection) internal view returns (string memory baseUri) {
        (baseUri,,,,,) = collection.config();
    }

    function _configMaxSupply(ArchetypeErc721a collection) internal view returns (uint32 maxSupply) {
        (, maxSupply,,,,) = collection.config();
    }

    function _configAffiliateFee(ArchetypeErc721a collection) internal view returns (uint16 affiliateFee) {
        (,,, affiliateFee,,) = collection.config();
    }

    function _configAffiliateDiscount(ArchetypeErc721a collection) internal view returns (uint16 affiliateDiscount) {
        (,,,, affiliateDiscount,) = collection.config();
    }

    function _payoutOwnerAltPayout(ArchetypeErc721a collection) internal view returns (address ownerAltPayout) {
        (,,,,,, ownerAltPayout) = collection.payoutConfig();
    }

    function _prank(address actor) internal {
        vm.stopPrank();
        vm.startPrank(actor);
    }

    function _constraints() internal pure returns (MintConstraints memory) {
        return _constraints(address(0), type(uint128).max, 0);
    }

    function _constraints(address currency, uint128 maxCurrencyCost, uint256 minTotalMints)
        internal
        pure
        returns (MintConstraints memory)
    {
        return MintConstraints({
            currency: currency,
            maxCurrencyCost: maxCurrencyCost,
            maxNativeValue: type(uint256).max,
            minTotalMints: minTotalMints
        });
    }

    function _burnConstraints(address burnCollection, address burnRecipient, MintConstraints memory constraints)
        internal
        pure
        returns (BurnConstraints memory)
    {
        return BurnConstraints({mint: constraints, burnCollection: burnCollection, burnRecipient: burnRecipient});
    }

    function _batchMintArgs(
        address[] memory recipients,
        uint256[] memory quantities,
        MintConstraints memory constraints
    ) internal pure returns (Erc721BatchMint memory) {
        return Erc721BatchMint({
            recipients: recipients,
            quantities: quantities,
            affiliate: address(0),
            affiliateAuthorization: "",
            constraints: constraints
        });
    }
}

contract CurrentCallerBatch {
    address private immutable caller;

    constructor(address caller_) {
        caller = caller_;
    }

    function currentCaller() external view returns (address) {
        return caller;
    }
}

contract NonErc721Receiver {}

contract ReentrantBurnSource {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    ArchetypeErc721a private destination;
    address private tokenOwner;
    bool public mutationBlocked;

    constructor(address tokenOwner_) {
        tokenOwner = tokenOwner_;
    }

    function configure(ArchetypeErc721a destination_) external {
        destination = destination_;
        destination.setBurnInvite(bytes32(0), bytes32(0), _invite(DEAD));
    }

    function ownerOf(uint256) external view returns (address) {
        return tokenOwner;
    }

    function isApprovedForAll(address, address) external pure returns (bool) {
        return true;
    }

    function transferFrom(address from, address to, uint256) external {
        require(from == tokenOwner);
        tokenOwner = to;
        try destination.setBurnInvite(bytes32(0), bytes32(0), _invite(address(this))) {}
        catch {
            mutationBlocked = true;
        }
    }

    function _invite(address burnRecipient) internal view returns (BurnInvite memory) {
        return BurnInvite({
            burnErc721: IERC721(address(this)),
            burnAddress: burnRecipient,
            tokenAddress: address(0),
            price: 0,
            reversed: false,
            ratio: 1,
            start: uint32(block.timestamp),
            end: 0,
            limit: 1
        });
    }
}
