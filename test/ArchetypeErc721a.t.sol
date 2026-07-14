// SPDX-License-Identifier: MIT
// forge-lint: disable-start(mixed-case-function, mixed-case-variable)
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IERC721} from "openzeppelin-v4/token/ERC721/IERC721.sol";
import {IERC721AUpgradeable} from "erc721a-upgradeable/contracts/IERC721AUpgradeable.sol";
import {ArchetypeBatch} from "../src/ArchetypeBatch.sol";
import {ArchetypePayouts, BalanceEmpty as PayoutBalanceEmpty, NotApprovedToWithdraw} from "../src/ArchetypePayouts.sol";
import {TestErc20} from "../src/TestErc20.sol";
import {ArchetypeErc721a, Config, PayoutConfig, Invite, Auth} from "../src/ERC721a/ArchetypeErc721a.sol";
import {
    AdvancedInvite,
    BonusDiscount,
    BurnInvite,
    NotOwner,
    LockedForever,
    InvalidSignature,
    NotShareholder,
    BalanceEmpty,
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
            affiliateSigner: affiliateSigner,
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

        ArchetypeBatch batchImpl = new ArchetypeBatch();
        vm.etch(BATCH, address(batchImpl).code);

        archetypeImplementation = new ArchetypeErc721a(PLATFORM, PAYOUTS, BATCH);

        _prank(owner);
        factory = new FactoryErc721a(address(archetypeImplementation), owner);

        _prank(other);
    }

    function test_archetypeAddresses_returnsConstructorAddresses() public view {
        ArchetypeAddresses memory addrs = archetypeImplementation.archetypeAddresses();

        assertEq(addrs.platform, PLATFORM);
        assertEq(addrs.payouts, PAYOUTS);
        assertEq(addrs.batch, BATCH);
    }

    function test_factoryConstructor_setsOwnerFromArgument() public {
        _prank(other);
        FactoryErc721a factoryWithOwnerArg = new FactoryErc721a(address(archetypeImplementation), owner);

        assertEq(factoryWithOwnerArg.owner(), owner);
        assertEq(factoryWithOwnerArg.archetype(), address(archetypeImplementation));
    }

    function test_factoryConstructor_failsWhenOwnerIsZero() public {
        vm.expectRevert(FactoryInvalidOwner.selector);
        new FactoryErc721a(address(archetypeImplementation), address(0));
    }

    function test_createCollection_initializesClone() public {
        _prank(other);
        ArchetypeErc721a collection = _createCollection(owner);

        assertEq(collection.symbol(), "POOKIE");
        assertEq(collection.owner(), owner);
    }

    function test_initialize_failsWhenCalledTwice() public {
        _prank(other);
        archetypeImplementation.initialize("Flookie", "POOKIE", defaultConfig, defaultPayoutConfig, owner);

        assertEq(archetypeImplementation.name(), "Flookie");

        vm.expectRevert(bytes("ERC721A__Initializable: contract is already initialized"));
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
        collection.mint{value: 0.1 ether}(auth, 1, address(0), "");

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
        collection.mint{value: 0.1 ether}(auth, 1, address(0), "");

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
        collection.mint{value: 0.1 ether}(auth, 1, address(0), "");
    }

    function test_mint_failsWhenInviteNotYetStarted() public {
        ArchetypeErc721a collection = _createCollection(owner);

        _setPublicInvite(collection, 0.1 ether, uint32(block.timestamp + 1 days));

        _prank(buyer);
        vm.expectRevert(MintNotYetStarted.selector);
        collection.mint{value: 0.1 ether}(_publicAuth(), 1, address(0), "");
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
        collection.mint{value: 0.1 ether}(_publicAuth(), 1, address(0), "");
    }

    function test_mint_failsWhenFixedPriceInviteIsUnderpaid() public {
        ArchetypeErc721a collection = _createCollection(owner);

        _setPublicInvite(collection, 0.08 ether, uint32(block.timestamp));

        _prank(buyer);
        vm.expectRevert(InsufficientEthSent.selector);
        collection.mint{value: 0.079 ether}(_publicAuth(), 1, address(0), "");
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

        _prank(owner);
        collection.withdraw();

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
        collection.mint{value: 0.1 ether}(auth, 1, address(0), "");

        _prank(other);
        collection.mint{value: 0.1 ether}(auth, 1, address(0), "");

        assertEq(collection.balanceOf(other), 1);
    }

    function test_mint_refundsOverpayment() public {
        ArchetypeErc721a collection = _createCollection(owner);

        _setPublicInvite(collection, 0.08 ether, uint32(block.timestamp));

        vm.txGasPrice(0);
        uint256 buyerBalanceBefore = buyer.balance;
        uint256 collectionBalanceBefore = address(collection).balance;

        _prank(buyer);
        collection.mint{value: 0.12 ether}(_publicAuth(), 1, address(0), "");

        assertEq(address(collection).balance - collectionBalanceBefore, 0.08 ether);
        assertEq(buyerBalanceBefore - buyer.balance, 0.08 ether);
    }

    function test_mint_refundsOverpaymentWithAffiliateAccounting() public {
        ArchetypeErc721a collection = _createCollection(owner);
        address affiliate = makeAddr("affiliate");
        bytes memory signature = _affiliateSignature(affiliate);

        _setPublicInvite(collection, 0.08 ether, uint32(block.timestamp));

        vm.txGasPrice(0);
        uint256 buyerBalanceBefore = buyer.balance;
        uint256 collectionBalanceBefore = address(collection).balance;

        _prank(buyer);
        collection.mint{value: 0.2 ether}(_publicAuth(), 1, affiliate, signature);

        // fee breakdown:
        //   mintPrice        = 0.08 ether
        //   ownerBalance     = 0.08 ether * 8500 / 10000 = 0.068 ether
        //   affiliateBalance = 0.08 ether * 1500 / 10000 = 0.012 ether
        assertEq(buyerBalanceBefore - buyer.balance, 0.08 ether);
        assertEq(address(collection).balance - collectionBalanceBefore, 0.08 ether);
        assertEq(collection.ownerBalance(), 0.068 ether);
        assertEq(collection.affiliateBalance(affiliate), 0.012 ether);
    }

    function test_affiliateSignatureValidationAndWithdrawals() public {
        ArchetypeErc721a collection = _createCollection(owner);
        ArchetypePayouts payouts = ArchetypePayouts(PAYOUTS);
        address affiliate = makeAddr("affiliate");
        bytes memory invalidSignature = _affiliateSignatureWithPk(affiliate, WRONG_AFFILIATE_SIGNER_PK);
        bytes memory validSignature = _affiliateSignature(affiliate);
        address[] memory tokens = _nativeTokenList();

        _setPublicInvite(collection, 0.08 ether, uint32(block.timestamp));

        _prank(buyer);
        vm.expectRevert(InvalidSignature.selector);
        collection.mint{value: 0.08 ether}(_publicAuth(), 1, affiliate, invalidSignature);

        _prank(buyer);
        collection.mint{value: 0.08 ether}(_publicAuth(), 1, affiliate, validSignature);

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
        collection.mint{value: 0.08 ether}(_publicAuth(), 1, affiliate, validSignature);
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

        ownerBalanceBefore = owner.balance;
        _prank(owner);
        payouts.withdraw();
        assertEq(owner.balance - ownerBalanceBefore, 0.0646 ether);

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

    function test_withdrawAffiliate_failsWhenWalletNeverEarnedAffiliateBalance() public {
        ArchetypeErc721a collection = _createCollection(owner);

        _prank(other);
        vm.expectRevert(BalanceEmpty.selector);
        collection.withdrawAffiliate();
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
        nftBurn.burnToMint(_auth(ZERO_KEY), tokenIds);

        tokenIds = _rangeTokenIds(9, 1);
        _prank(buyer);
        vm.expectRevert(InvalidAmountOfTokens.selector);
        nftBurn.burnToMint(_auth(ZERO_KEY), tokenIds);

        tokenIds = new uint256[](2);
        tokenIds[0] = 2;
        tokenIds[1] = 4;
        _prank(buyer);
        nftBurn.burnToMint(_auth(ZERO_KEY), tokenIds);

        tokenIds = new uint256[](4);
        tokenIds[0] = 1;
        tokenIds[1] = 3;
        tokenIds[2] = 5;
        tokenIds[3] = 8;
        _prank(buyer);
        nftBurn.burnToMint(_auth(ZERO_KEY), tokenIds);

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
        nftBurn.burnToMint(_auth(ZERO_KEY), tokenIds);

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
        nftBurn.burnToMint(_auth(ZERO_KEY), tokenIds);

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
        nftBurn.burnToMint(_auth(ZERO_KEY), tokenIds);

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
        nftBurn.burnToMint(_auth(ZERO_KEY), tokenIds);

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
        nftBurn.burnToMint{value: 0.05 ether}(_auth(allowlistRoot), tokenIds);

        _prank(other);
        vm.expectRevert(WalletUnauthorizedToMint.selector);
        nftBurn.burnToMint{value: 0.05 ether}(_auth(allowlistRoot), _rangeTokenIds(5, 2));

        assertEq(nftMint.ownerOf(1), DEAD);
        assertEq(nftMint.ownerOf(2), DEAD);
        assertEq(nftMint.balanceOf(buyer), 2);
        assertEq(nftBurn.balanceOf(buyer), 4);
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
        nftBurn.burnToMint(_auth(ZERO_KEY), tokenIds);

        assertEq(nftBurn.balanceOf(buyer), 3);
        assertEq(erc20.balanceOf(buyer), 10 ether);
        assertEq(erc20.balanceOf(address(nftBurn)), 10 ether);
        assertEq(nftBurn.ownerOf(1), DEAD);
        assertEq(nftBurn.ownerOf(2), DEAD);

        _prank(buyer);
        vm.expectRevert(NotTokenOwner.selector);
        nftBurn.burnToMint(_auth(ZERO_KEY), tokenIds);
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
        nftMint.mint(_auth(ZERO_KEY), 4991, address(0), "");

        _mint(nftMint, buyer, _auth(ZERO_KEY), 4989, 0);
        discounts[0] = BonusDiscount({numMints: 1, numBonusMints: 1});
        _prank(owner);
        nftMint.setBonusDiscounts(ZERO_KEY, discounts);

        _prank(buyer);
        vm.expectRevert(MaxSupplyExceeded.selector);
        nftMint.mint(_auth(ZERO_KEY), 1, address(0), "");

        BonusDiscount[] memory emptyDiscounts = new BonusDiscount[](0);
        _prank(owner);
        nftMint.setBonusDiscounts(ZERO_KEY, emptyDiscounts);
        _mint(nftMint, buyer, _auth(ZERO_KEY), 1, 0);

        _prank(buyer);
        vm.expectRevert(MaxSupplyExceeded.selector);
        nftMint.mint(_auth(ZERO_KEY), 1, address(0), "");

        _mint(nftBurn, buyer, _auth(ZERO_KEY), 4990, 0);
        _prank(buyer);
        nftMint.setApprovalForAll(address(nftBurn), true);

        uint256[] memory tokenIds = _rangeTokenIds(1, 40);
        _prank(buyer);
        vm.expectRevert(MaxSupplyExceeded.selector);
        nftBurn.burnToMint(_auth(ZERO_KEY), tokenIds);

        tokenIds = _rangeTokenIds(1, 20);
        _prank(buyer);
        nftBurn.burnToMint(_auth(ZERO_KEY), tokenIds);

        tokenIds = _rangeTokenIds(21, 2);
        _prank(buyer);
        vm.expectRevert(MaxSupplyExceeded.selector);
        nftBurn.burnToMint(_auth(ZERO_KEY), tokenIds);

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
        collection.mint(_auth(ZERO_KEY), 60, address(0), "");

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
        collection.mint(_auth(ZERO_KEY), 2, address(0), "");

        _mint(collection, other, _auth(ZERO_KEY), 2, 0);

        _prank(owner);
        vm.expectRevert(ListMaxSupplyExceeded.selector);
        collection.mint(_auth(ZERO_KEY), 1, address(0), "");

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
        collection.mint(_auth(erc20Key), 3, address(0), "");

        _prank(buyer);
        erc20.approve(address(collection), type(uint256).max);
        _prank(buyer);
        vm.expectRevert(Erc20BalanceTooLow.selector);
        collection.mint(_auth(erc20Key), 3, address(0), "");

        _prank(buyer);
        erc20.mint(3 ether);
        _prank(buyer);
        collection.mint(_auth(erc20Key), 3, address(0), "");

        assertEq(collection.balanceOf(buyer), 3);
        assertEq(erc20.balanceOf(buyer), 0);
        assertEq(erc20.balanceOf(address(collection)), 3 ether);
        assertEq(collection.ownerBalanceToken(address(erc20)), 3 ether);

        _prank(owner);
        collection.withdrawTokens(tokens);
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

    function test_mint_descendingDutchInvite() public {
        ArchetypeErc721a collection = _createCollection(owner);

        _setAdvancedInvite(
            collection,
            ZERO_KEY,
            AdvancedInvite({
                price: 1 ether,
                reservePrice: 0.1 ether,
                delta: 0.1 ether,
                start: uint32(block.timestamp),
                end: 0,
                limit: 5000,
                maxSupply: 5000,
                interval: 1000,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );

        _prank(buyer);
        vm.expectRevert(InsufficientEthSent.selector);
        collection.mint{value: 0.5 ether}(_auth(ZERO_KEY), 1, address(0), "");

        _mint(collection, buyer, _auth(ZERO_KEY), 1, 1 ether);
        vm.warp(block.timestamp + 5000);
        _mint(collection, buyer, _auth(ZERO_KEY), 1, 0.5 ether);
        vm.warp(block.timestamp + 50000);
        _mint(collection, buyer, _auth(ZERO_KEY), 1, 0.1 ether);

        assertEq(collection.balanceOf(buyer), 3);
    }

    function test_mint_increasingDutchInvite() public {
        ArchetypeErc721a collection = _createCollection(owner);

        _setAdvancedInvite(
            collection,
            ZERO_KEY,
            AdvancedInvite({
                price: 1 ether,
                reservePrice: 10 ether,
                delta: 1 ether,
                start: uint32(block.timestamp),
                end: 0,
                limit: 5000,
                maxSupply: 5000,
                interval: 1000,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );

        _mint(collection, buyer, _auth(ZERO_KEY), 1, 1 ether);
        vm.warp(block.timestamp + 5000);

        _prank(buyer);
        vm.expectRevert(InsufficientEthSent.selector);
        collection.mint{value: 1 ether}(_auth(ZERO_KEY), 1, address(0), "");

        _mint(collection, buyer, _auth(ZERO_KEY), 1, 6 ether);
        vm.warp(block.timestamp + 50000);
        _mint(collection, buyer, _auth(ZERO_KEY), 1, 10 ether);

        assertEq(collection.balanceOf(buyer), 3);
    }

    function test_mint_linearPricingCurve() public {
        ArchetypeErc721a collection = _createCollection(owner);

        _setAdvancedInvite(
            collection,
            ZERO_KEY,
            AdvancedInvite({
                price: 1 ether,
                reservePrice: 0.1 ether,
                delta: 0.01 ether,
                start: uint32(block.timestamp),
                end: 0,
                limit: 5000,
                maxSupply: 5000,
                interval: 0,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );

        _mint(collection, buyer, _auth(ZERO_KEY), 1, 1 ether);

        _prank(buyer);
        vm.expectRevert(InsufficientEthSent.selector);
        collection.mint{value: 1 ether}(_auth(ZERO_KEY), 1, address(0), "");

        _mint(collection, buyer, _auth(ZERO_KEY), 1, 1.01 ether);
        _mint(collection, buyer, _auth(ZERO_KEY), 10, 10.65 ether);

        assertEq(collection.balanceOf(buyer), 12);
    }

    function test_mint_bonusDiscountsAndAffiliateDiscounts() public {
        Config memory config = defaultConfig;
        config.maxBatchSize = 100;
        config.affiliateFee = 1500;
        config.affiliateDiscount = 1000;
        ArchetypeErc721a collection = _createCollectionWithConfig(owner, config);
        address affiliate = makeAddr("affiliate");
        bytes memory signature = _affiliateSignature(affiliate);
        BonusDiscount[] memory discounts = new BonusDiscount[](3);

        discounts[0] = BonusDiscount({numMints: 20, numBonusMints: 10});
        discounts[1] = BonusDiscount({numMints: 10, numBonusMints: 4});
        discounts[2] = BonusDiscount({numMints: 3, numBonusMints: 1});

        _prank(owner);
        collection.setBonusInvite(
            ZERO_KEY,
            CID_ZERO,
            AdvancedInvite({
                price: 0.01 ether,
                reservePrice: 0.01 ether,
                delta: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: 300,
                maxSupply: defaultConfig.maxSupply,
                interval: 0,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            }),
            discounts
        );

        _prank(buyer);
        collection.mint{value: 0.027 ether}(_auth(ZERO_KEY), 3, affiliate, signature);

        assertEq(collection.ownerOf(4), buyer);
        assertEq(collection.totalSupply(), 4);

        _prank(buyer);
        collection.mint{value: 0.08 ether}(_auth(ZERO_KEY), 8, address(0), "");

        assertEq(collection.totalSupply(), 14);

        _prank(buyer);
        collection.mint{value: 0.21 ether}(_auth(ZERO_KEY), 21, address(0), "");

        assertEq(collection.totalSupply(), 45);
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
        ArchetypeErc721a collection = _createCollectionWithPayout(owner, defaultConfig, payoutConfig);
        ArchetypePayouts payouts = ArchetypePayouts(PAYOUTS);

        vm.deal(affiliate, 100 ether);
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
        collection.mint{value: 0.1 ether}(_auth(ZERO_KEY), 1, affiliate, signature);

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

    function test_withdraw_usesOwnerAltPayout() public {
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
        assertEq(collection.ownerBalance(), 0.1 ether);

        vm.txGasPrice(0);
        uint256 altBalanceBefore = altPayout.balance;

        _prank(owner);
        collection.withdraw();

        // fee breakdown:
        //   ownerBalance   = 0.1 ether
        //   altPayout      = 0.1 ether * 9000 / 10000 = 0.09 ether
        //   platformPayout = 0.1 ether * 500 / 10000  = 0.005 ether
        //   partnerPayout  = 0.1 ether * 500 / 10000  = 0.005 ether
        assertEq(altPayout.balance - altBalanceBefore, 0.09 ether);
        assertEq(payouts.balance(owner), 0);
        assertEq(payouts.balance(altPayout), 0);
        assertEq(payouts.balance(PLATFORM), 0.005 ether);
        assertEq(payouts.balance(buyer), 0.005 ether);

        _mint(collection, other, _auth(ZERO_KEY), 1, 0.1 ether);

        _prank(altPayout);
        collection.withdraw();

        // fee breakdown:
        //   previousAltPayout      = 0.09 ether
        //   secondAltPayout        = 0.09 ether
        //   totalAltPayout         = 0.09 ether * 2 = 0.18 ether
        //   totalPlatformPayout    = 0.005 ether * 2 = 0.01 ether
        //   totalPartnerPayout     = 0.005 ether * 2 = 0.01 ether
        assertEq(altPayout.balance - altBalanceBefore, 0.18 ether);
        assertEq(payouts.balance(PLATFORM), 0.01 ether);
        assertEq(payouts.balance(buyer), 0.01 ether);

        _prank(owner);
        collection.setOwnerAltPayout(address(0));

        _prank(altPayout);
        vm.expectRevert(NotShareholder.selector);
        collection.withdraw();
    }

    function test_mint_failsWhenDefaultPublicInviteIsPaused() public {
        ArchetypeErc721a collection = _createCollection(owner);

        _prank(buyer);
        vm.expectRevert(MintingPaused.selector);
        collection.mint{value: 0.08 ether}(_auth(ZERO_KEY), 1, address(0), "");
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
        collection.mintTo{value: 0.06 ether}(_auth(ZERO_KEY), 3, buyer, address(0), "");

        assertEq(collection.balanceOf(buyer), 3);
        assertEq(collection.balanceOf(owner), 0);

        _prank(owner);
        vm.expectRevert(IERC721AUpgradeable.MintToZeroAddress.selector);
        collection.mintTo{value: 0.02 ether}(_auth(ZERO_KEY), 1, address(0), address(0), "");
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
        collection.batchMintTo(_auth(ownerRoot), firstRecipients, firstQuantities, address(0), "");
        collection.batchMintTo(_auth(ownerRoot), secondRecipients, secondQuantities, address(0), "");

        assertEq(collection.totalSupply(), 100);
        assertEq(collection.ownerOf(1), recipients[0]);
        assertEq(collection.ownerOf(10), recipients[9]);
        assertEq(collection.ownerOf(20), recipients[19]);
        assertEq(collection.ownerOf(60), recipients[59]);
        assertEq(collection.ownerOf(100), recipients[99]);
    }

    function test_batch_executeBatch_mintsAndRescues() public {
        ArchetypeErc721a collection = _createCollectionWithConfig(owner, _configWithSupply(100, 100));
        ArchetypeBatch batch = ArchetypeBatch(BATCH);
        address[] memory targets = new address[](5);
        uint256[] memory values = new uint256[](5);
        bytes[] memory datas = new bytes[](5);
        uint256[] memory rescuedIds = new uint256[](1);

        _setBatchOwner(owner);
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

        values[3] = 0.2 ether;
        values[4] = 0.3 ether;

        datas[0] = abi.encodeCall(collection.mintTo, (_auth(ZERO_KEY), 1, BATCH, address(0), ""));
        datas[1] = abi.encodeCall(collection.mint, (_auth(ZERO_KEY), 2, address(0), ""));
        datas[2] = abi.encodeCall(collection.mintTo, (_auth(ZERO_KEY), 5, other, address(0), ""));
        datas[3] = abi.encodeCall(collection.mintTo, (_auth(PUBLIC_KEY), 2, buyer, address(0), ""));
        datas[4] = abi.encodeCall(collection.mintTo, (_auth(PUBLIC_KEY), 3, other, address(0), ""));

        vm.stopPrank();
        vm.startPrank(buyer, buyer);
        batch.executeBatch{value: 0.6 ether}(targets, values, datas);
        vm.stopPrank();

        assertEq(collection.balanceOf(BATCH), 1);
        assertEq(collection.balanceOf(buyer), 4);
        assertEq(collection.balanceOf(other), 8);
        assertEq(collection.totalSupply(), 13);

        rescuedIds[0] = 1;
        _prank(owner);
        batch.rescueERC721(address(collection), rescuedIds, owner);
        assertEq(collection.ownerOf(1), owner);

        vm.txGasPrice(0);
        uint256 ownerBalanceBefore = owner.balance;
        _prank(owner);
        batch.rescueETH(owner);
        assertEq(owner.balance - ownerBalanceBefore, 0.1 ether);
    }

    function test_batch_txOriginBehavior() public {
        ArchetypeErc721a collection = _createCollectionWithConfig(owner, _configWithSupply(100, 100));
        ArchetypeBatch batch = ArchetypeBatch(BATCH);
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
        datas[0] = abi.encodeCall(collection.mint, (_auth(ZERO_KEY), 5, address(0), ""));
        datas[1] = abi.encodeCall(collection.mint, (_auth(buyerRoot), 5, address(0), ""));

        vm.stopPrank();
        vm.startPrank(buyer, buyer);
        batch.executeBatch{value: 0.5 ether}(targets, values, datas);
        vm.stopPrank();

        assertEq(collection.balanceOf(buyer), 10);
        assertEq(collection.totalSupply(), 10);
    }

    function test_batch_ownerMethodsWorkThroughBatch() public {
        ArchetypeErc721a collection = _createCollection(owner);
        ArchetypeBatch batch = ArchetypeBatch(BATCH);
        address[] memory targets = new address[](3);
        uint256[] memory values = new uint256[](3);
        bytes[] memory datas = new bytes[](3);

        for (uint256 i; i < targets.length; ++i) {
            targets[i] = address(collection);
        }

        datas[0] = abi.encodeCall(
            collection.setInvite,
            (
                ZERO_KEY,
                CID_ZERO,
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
            )
        );
        datas[1] = abi.encodeCall(collection.setMaxSupply, (1000, "forever"));
        datas[2] = abi.encodeCall(collection.setBaseURI, ("test"));

        vm.stopPrank();
        vm.startPrank(owner, owner);
        batch.executeBatch(targets, values, datas);
        vm.stopPrank();

        assertEq(_configMaxSupply(collection), 1000);
        assertEq(_configBaseUri(collection), "test");
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

    function _setAdvancedInvite(ArchetypeErc721a collection, bytes32 key, AdvancedInvite memory invite) internal {
        _prank(owner);
        collection.setAdvancedInvite(key, CID_ZERO, invite);
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
        collection.mint{value: value}(_publicAuth(), 1, affiliate, "");
    }

    function _mint(ArchetypeErc721a collection, address minter, Auth memory auth, uint256 quantity, uint256 value)
        internal
    {
        _prank(minter);
        collection.mint{value: value}(auth, quantity, address(0), "");
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

    function _affiliateSignature(address affiliate) internal view returns (bytes memory) {
        return _affiliateSignatureWithPk(affiliate, AFFILIATE_SIGNER_PK);
    }

    function _affiliateSignatureWithPk(address affiliate, uint256 privateKey) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(keccak256(abi.encodePacked(affiliate)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _setBatchOwner(address batchOwner) internal {
        vm.store(BATCH, bytes32(0), bytes32(uint256(uint160(batchOwner))));
    }

    function _configBaseUri(ArchetypeErc721a collection) internal view returns (string memory baseUri) {
        (baseUri,,,,,,) = collection.config();
    }

    function _configMaxSupply(ArchetypeErc721a collection) internal view returns (uint32 maxSupply) {
        (,, maxSupply,,,,) = collection.config();
    }

    function _configAffiliateFee(ArchetypeErc721a collection) internal view returns (uint16 affiliateFee) {
        (,,,, affiliateFee,,) = collection.config();
    }

    function _configAffiliateDiscount(ArchetypeErc721a collection) internal view returns (uint16 affiliateDiscount) {
        (,,,,, affiliateDiscount,) = collection.config();
    }

    function _payoutOwnerAltPayout(ArchetypeErc721a collection) internal view returns (address ownerAltPayout) {
        (,,,,,, ownerAltPayout) = collection.payoutConfig();
    }

    function _prank(address actor) internal {
        vm.stopPrank();
        vm.startPrank(actor);
    }
}
