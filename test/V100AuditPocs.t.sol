// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-v4/token/ERC20/IERC20.sol";
import {ArchetypeBatchV100} from "../src/ArchetypeBatchV100.sol";
import "../src/AffiliateAuthorization.sol";
import {ArchetypePayouts} from "../src/ArchetypePayouts.sol";
import {ArchetypeErc721a, Auth, Config, Invite, PayoutConfig} from "../src/ERC721a/ArchetypeErc721a.sol";
import {ExcessiveCurrencyCost, InsufficientEthSent, MintEnded} from "../src/ERC721a/ArchetypeLogicErc721a.sol";
import {FactoryErc721a} from "../src/ERC721a/FactoryErc721a.sol";
import {MintFeeRegistry} from "../src/MintFeeRegistry.sol";
import {AffiliateSignerRegistry} from "../src/AffiliateSignerRegistry.sol";
import {MintConstraints} from "../src/MintConstraints.sol";
import {RoyaltyPolicyRegistry} from "../src/RoyaltyPolicyRegistry.sol";
import {TestErc20} from "../src/TestErc20.sol";

contract V100AuditPocsTest is Test {
    address internal constant PLATFORM = 0x2222222222222222222222222222222222222221;
    bytes32 internal constant PUBLIC_KEY = bytes32(uint256(1));
    bytes32 internal constant CID_ZERO = bytes32(0);
    uint256 internal constant AFFILIATE_SIGNER_PK = 0xA11CE;

    address internal owner = makeAddr("owner");
    address internal buyer = makeAddr("buyer");
    address internal other = makeAddr("other");
    address internal affiliate = makeAddr("affiliate");

    ArchetypePayouts internal payouts;
    ArchetypeBatchV100 internal batch;
    MintFeeRegistry internal feeRegistry;
    AffiliateSignerRegistry internal affiliateSignerRegistry;
    ArchetypeErc721a internal archetype;
    RoyaltyPolicyRegistry internal royaltyRegistry;
    FactoryErc721a internal factory;

    function setUp() public {
        vm.deal(owner, 100 ether);
        vm.deal(buyer, 100 ether);
        vm.deal(other, 100 ether);

        payouts = new ArchetypePayouts();
        royaltyRegistry = new RoyaltyPolicyRegistry(owner);
        batch = new ArchetypeBatchV100(owner, royaltyRegistry);
        feeRegistry = new MintFeeRegistry(owner, owner, 0, 1 ether, 0);
        affiliateSignerRegistry = new AffiliateSignerRegistry(owner, vm.addr(AFFILIATE_SIGNER_PK));
        archetype =
            new ArchetypeErc721a(PLATFORM, address(payouts), address(batch), feeRegistry, affiliateSignerRegistry);

        vm.startPrank(owner);
        factory = new FactoryErc721a(address(archetype), owner, royaltyRegistry);
        royaltyRegistry.setApprovedFactory(address(factory), true);
        vm.stopPrank();
    }

    function testAudit_executeBatchCannotSpendRetainedAssets() public {
        ArchetypeBatchV100 target = new ArchetypeBatchV100(owner, royaltyRegistry);
        TestErc20 token = new TestErc20();
        token.mint(10 ether);

        vm.deal(address(target), 0.1 ether);
        token.transfer(address(target), 10 ether);

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory datas = new bytes[](1);
        targets[0] = address(token);
        values[0] = 0.1 ether;
        datas[0] = abi.encodeCall(IERC20.transfer, (buyer, 10 ether));

        vm.prank(buyer);
        vm.expectRevert(ArchetypeBatchV100.BatchValueMismatch.selector);
        target.executeBatch(targets, values, datas);
        assertEq(address(target).balance, 0.1 ether);

        values[0] = 0;
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ArchetypeBatchV100.UnsupportedCollection.selector, address(token)));
        target.executeBatch(targets, values, datas);

        assertEq(address(target).balance, 0.1 ether);
        assertEq(buyer.balance, 100 ether);
        assertEq(token.balanceOf(buyer), 0);
        assertEq(token.balanceOf(address(target)), 10 ether);
    }

    function testAudit_inviteCounterHistoryIsLostWhenCapsBecomeActive() public {
        Config memory config = _config();
        config.maxSupply = 1000;
        config.maxBatchSize = 20;
        ArchetypeErc721a collection = _createCollection(config);

        _setInvite(
            collection,
            PUBLIC_KEY,
            Invite({
                price: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: type(uint32).max,
                maxSupply: type(uint32).max,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );
        _mint(collection, buyer, 10);
        assertEq(collection.balanceOf(buyer), 10);

        _setInvite(
            collection,
            PUBLIC_KEY,
            Invite({
                price: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: 1,
                maxSupply: 20,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );
        _mint(collection, buyer, 1);
        _setInvite(
            collection,
            PUBLIC_KEY,
            Invite({
                price: 0,
                start: uint32(block.timestamp),
                end: 0,
                limit: 1000,
                maxSupply: 20,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );
        _mint(collection, other, 19);

        assertEq(collection.balanceOf(buyer), 11);
        assertEq(collection.balanceOf(other), 19);
        assertEq(collection.totalSupply(), 30);
    }

    function testAudit_editingAnExpiredInvitePreservesItsEnd() public {
        ArchetypeErc721a collection = _createCollection(_config());
        uint32 start = uint32(block.timestamp);
        Invite memory invite = Invite({
            price: 0,
            start: start,
            end: start + 1 hours,
            limit: 10,
            maxSupply: 10,
            unitSize: 1,
            tokenAddress: address(0),
            isBlacklist: false
        });
        _setInvite(collection, PUBLIC_KEY, invite);

        vm.warp(start + 1 hours + 1);
        _setInvite(collection, PUBLIC_KEY, invite);

        vm.prank(buyer);
        vm.expectRevert(MintEnded.selector);
        collection.mint(_auth(PUBLIC_KEY), 1, address(0), "", _constraints(address(0), type(uint128).max, 1));

        assertEq(collection.balanceOf(buyer), 0);
    }

    function testAudit_affiliateAuthorizationIsBoundToItsCollection() public {
        ArchetypeErc721a first = _createCollection(_config());
        vm.warp(block.timestamp + 1);
        ArchetypeErc721a second = _createCollection(_config());
        bytes memory firstAuthorization = _affiliateAuthorization(address(first), affiliate, buyer);

        _setPublicInvite(first, 0.1 ether);
        _setPublicInvite(second, 0.1 ether);

        _mintWithAffiliate(first, buyer, affiliate, firstAuthorization, 0.1 ether);
        vm.prank(buyer);
        vm.expectRevert(InvalidAffiliateAuthorization.selector);
        second.mint{value: 0.1 ether}(
            _auth(PUBLIC_KEY), 1, affiliate, firstAuthorization, _constraints(address(0), type(uint128).max, 1)
        );

        assertEq(first.balanceOf(buyer), 1);
        assertEq(second.balanceOf(buyer), 0);
        assertEq(payouts.balance(affiliate), 0.015 ether);
    }

    function testAudit_erc20MintCannotExceedItsExecutionPriceLimit() public {
        ArchetypeErc721a collection = _createCollection(_config());
        TestErc20 token = new TestErc20();
        bytes32 key = keccak256(abi.encodePacked(address(token)));

        _setInvite(collection, key, _erc20Invite(address(token), 1 ether));

        vm.prank(buyer);
        token.mint(3 ether);
        vm.prank(buyer);
        token.approve(address(collection), 3 ether);

        _setInvite(collection, key, _erc20Invite(address(token), 2 ether));
        vm.prank(buyer);
        vm.expectRevert(ExcessiveCurrencyCost.selector);
        collection.mint(_auth(key), 1, address(0), "", _constraints(address(token), 1 ether, 1));

        assertEq(token.balanceOf(buyer), 3 ether);
        assertEq(payouts.balanceToken(owner, address(token)), 0);
        assertEq(payouts.balanceToken(PLATFORM, address(token)), 0);
    }

    function testAudit_repeatedErc20MintsAssignEveryPlatformResidualToOwner() public {
        Config memory config = _config();
        config.maxSupply = 40;
        config.maxBatchSize = 20;
        ArchetypeErc721a collection = _createCollection(config);
        TestErc20 token = new TestErc20();
        bytes32 key = keccak256(abi.encodePacked(address(token)));

        _setInvite(
            collection,
            key,
            Invite({
                price: 1,
                start: uint32(block.timestamp),
                end: 0,
                limit: 40,
                maxSupply: 40,
                unitSize: 1,
                tokenAddress: address(token),
                isBlacklist: false
            })
        );

        vm.prank(buyer);
        token.mint(40);
        vm.prank(buyer);
        token.approve(address(collection), 40);
        for (uint256 i; i < 40; ++i) {
            vm.prank(buyer);
            collection.mint(_auth(key), 1, address(0), "", _constraints(address(token), type(uint128).max, 1));
        }

        assertEq(payouts.balanceToken(owner, address(token)), 40);
        assertEq(payouts.balanceToken(PLATFORM, address(token)), 0);
    }

    function testAudit_feeIncreaseRequiresTheLiveMinimumFee() public {
        feeRegistry = new MintFeeRegistry(owner, owner, 0, 1 ether, 0.01 ether);
        archetype =
            new ArchetypeErc721a(PLATFORM, address(payouts), address(batch), feeRegistry, affiliateSignerRegistry);
        vm.startPrank(owner);
        factory = new FactoryErc721a(address(archetype), owner, royaltyRegistry);
        royaltyRegistry.setApprovedFactory(address(factory), true);
        vm.stopPrank();

        ArchetypeErc721a collection = _createCollection(_config());
        _setPublicInvite(collection, 0);

        vm.prank(owner);
        feeRegistry.setNativeMinimumFee(0.02 ether);

        vm.txGasPrice(0);
        uint256 balanceBefore = buyer.balance;
        vm.prank(buyer);
        vm.expectRevert(InsufficientEthSent.selector);
        collection.mint{value: 0.01 ether}(_auth(PUBLIC_KEY), 1, address(0), "", _constraints(address(0), 0, 1));

        assertEq(buyer.balance, balanceBefore);
        assertEq(payouts.balance(PLATFORM), 0);
    }

    function _config() internal pure returns (Config memory) {
        return Config({
            baseUri: "ipfs://test",
            maxSupply: 10,
            maxBatchSize: 10,
            affiliateFee: 1500,
            affiliateDiscount: 0,
            defaultRoyalty: 0
        });
    }

    function _payoutConfig() internal pure returns (PayoutConfig memory) {
        return PayoutConfig({
            ownerBps: 9500,
            platformBps: 500,
            partnerBps: 0,
            superAffiliateBps: 0,
            partner: address(0),
            superAffiliate: address(0),
            ownerAltPayout: address(0)
        });
    }

    function _createCollection(Config memory config) internal returns (ArchetypeErc721a collection) {
        collection = ArchetypeErc721a(factory.createCollection(owner, "Pookie", "POOKIE", config, _payoutConfig()));
    }

    function _setInvite(ArchetypeErc721a collection, bytes32 key, Invite memory invite) internal {
        vm.prank(owner);
        collection.setInvite(key, CID_ZERO, invite);
    }

    function _setPublicInvite(ArchetypeErc721a collection, uint128 price) internal {
        _setInvite(
            collection,
            PUBLIC_KEY,
            Invite({
                price: price,
                start: uint32(block.timestamp),
                end: 0,
                limit: 10,
                maxSupply: 10,
                unitSize: 1,
                tokenAddress: address(0),
                isBlacklist: false
            })
        );
    }

    function _erc20Invite(address token, uint128 price) internal view returns (Invite memory) {
        return Invite({
            price: price,
            start: uint32(block.timestamp),
            end: 0,
            limit: 1,
            maxSupply: 1,
            unitSize: 1,
            tokenAddress: token,
            isBlacklist: false
        });
    }

    function _mint(ArchetypeErc721a collection, address minter, uint256 quantity) internal {
        _mint(collection, minter, quantity, PUBLIC_KEY);
    }

    function _mint(ArchetypeErc721a collection, address minter, uint256 quantity, bytes32 key) internal {
        vm.prank(minter);
        collection.mint(_auth(key), quantity, address(0), "", _constraints(address(0), type(uint128).max, quantity));
    }

    function _mintWithAffiliate(
        ArchetypeErc721a collection,
        address minter,
        address affiliate_,
        bytes memory signature,
        uint256 value
    ) internal {
        vm.prank(minter);
        collection.mint{value: value}(
            _auth(PUBLIC_KEY), 1, affiliate_, signature, _constraints(address(0), type(uint128).max, 1)
        );
    }

    function _auth(bytes32 key) internal pure returns (Auth memory auth) {
        auth.key = key;
        auth.proof = new bytes32[](0);
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

    function _affiliateAuthorization(address collection, address affiliate_, address minter)
        internal
        view
        returns (bytes memory)
    {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Archetype"),
                keccak256("1"),
                block.chainid,
                collection
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("AffiliateAuthorization(address affiliate,address minter,uint256 deadline)"),
                affiliate_,
                minter,
                block.timestamp + 1 hours
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(AFFILIATE_SIGNER_PK, digest);
        return abi.encodePacked(bytes32(block.timestamp + 1 hours), r, s, v);
    }
}
