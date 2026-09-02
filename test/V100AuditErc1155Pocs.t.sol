// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ArchetypeBatchV100} from "../src/ArchetypeBatchV100.sol";
import "../src/AffiliateAuthorization.sol";
import {ArchetypePayouts} from "../src/ArchetypePayouts.sol";
import {ArchetypeErc1155, Auth, Config, Invite, PayoutConfig} from "../src/ERC1155/ArchetypeErc1155.sol";
import {ExcessiveCurrencyCost, InsufficientEthSent, MintEnded} from "../src/ERC1155/ArchetypeLogicErc1155.sol";
import {FactoryErc1155} from "../src/ERC1155/FactoryErc1155.sol";
import {MintFeeRegistry} from "../src/MintFeeRegistry.sol";
import {AffiliateSignerRegistry} from "../src/AffiliateSignerRegistry.sol";
import {MintConstraints} from "../src/MintConstraints.sol";
import {RoyaltyPolicyRegistry} from "../src/RoyaltyPolicyRegistry.sol";
import {TestErc20} from "../src/TestErc20.sol";

contract V100AuditErc1155PocsTest is Test {
    address internal constant PLATFORM = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    bytes32 internal constant PUBLIC_KEY = bytes32(uint256(1));
    bytes32 internal constant CID_ZERO = bytes32(0);
    uint256 internal constant AFFILIATE_SIGNER_PK = 0xA11CE;
    uint256 internal constant TOKEN_ID = 1;

    address internal owner = makeAddr("owner");
    address internal buyer = makeAddr("buyer");
    address internal other = makeAddr("other");
    address internal affiliate = makeAddr("affiliate");

    ArchetypePayouts internal payouts;
    ArchetypeBatchV100 internal batch;
    MintFeeRegistry internal feeRegistry;
    AffiliateSignerRegistry internal affiliateSignerRegistry;
    ArchetypeErc1155 internal archetype;
    RoyaltyPolicyRegistry internal royaltyRegistry;
    FactoryErc1155 internal factory;

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
            new ArchetypeErc1155(PLATFORM, address(payouts), address(batch), feeRegistry, affiliateSignerRegistry);

        vm.startPrank(owner);
        factory = new FactoryErc1155(address(archetype), owner, royaltyRegistry);
        royaltyRegistry.setApprovedFactory(address(factory), true);
        vm.stopPrank();
    }

    function testAudit_inviteCounterHistoryIsLostWhenCapsBecomeActive() public {
        ArchetypeErc1155 collection = _createCollection();

        _setInvite(collection, PUBLIC_KEY, _invite(0, type(uint32).max, type(uint32).max, 0, address(0)));
        _mint(collection, buyer, 10);
        assertEq(collection.balanceOf(buyer, TOKEN_ID), 10);

        _setInvite(collection, PUBLIC_KEY, _invite(0, 1, 20, 0, address(0)));
        _mint(collection, buyer, 1);

        _setInvite(collection, PUBLIC_KEY, _invite(0, 1000, 20, 0, address(0)));
        _mint(collection, other, 19);

        assertEq(collection.balanceOf(buyer, TOKEN_ID), 11);
        assertEq(collection.balanceOf(other, TOKEN_ID), 19);
        assertEq(collection.tokenSupply(TOKEN_ID), 30);
    }

    function testAudit_editingAnExpiredInvitePreservesItsEnd() public {
        ArchetypeErc1155 collection = _createCollection();
        uint32 start = uint32(block.timestamp);
        Invite memory invite = _invite(0, 10, 10, start + 1 hours, address(0));
        invite.start = start;
        _setInvite(collection, PUBLIC_KEY, invite);

        vm.warp(start + 1 hours + 1);
        _setInvite(collection, PUBLIC_KEY, invite);

        vm.prank(buyer);
        vm.expectRevert(MintEnded.selector);
        collection.mintToken(
            _auth(PUBLIC_KEY), 1, TOKEN_ID, address(0), "", _constraints(address(0), type(uint128).max, 1)
        );

        assertEq(collection.balanceOf(buyer, TOKEN_ID), 0);
    }

    function testAudit_affiliateAuthorizationIsBoundToItsCollection() public {
        ArchetypeErc1155 first = _createCollection();
        vm.warp(block.timestamp + 1);
        ArchetypeErc1155 second = _createCollection();
        bytes memory firstAuthorization = _affiliateAuthorization(address(first), affiliate, buyer);

        _setInvite(first, PUBLIC_KEY, _invite(0.1 ether, 10, 10, 0, address(0)));
        _setInvite(second, PUBLIC_KEY, _invite(0.1 ether, 10, 10, 0, address(0)));

        _mintWithAffiliate(first, affiliate, firstAuthorization, 0.1 ether);
        vm.prank(buyer);
        vm.expectRevert(InvalidAffiliateAuthorization.selector);
        second.mintToken{value: 0.1 ether}(
            _auth(PUBLIC_KEY),
            1,
            TOKEN_ID,
            affiliate,
            firstAuthorization,
            _constraints(address(0), type(uint128).max, 1)
        );

        assertEq(first.balanceOf(buyer, TOKEN_ID), 1);
        assertEq(second.balanceOf(buyer, TOKEN_ID), 0);
        assertEq(payouts.balance(affiliate), 0.015 ether);
    }

    function testAudit_erc20MintCannotExceedItsExecutionPriceLimit() public {
        ArchetypeErc1155 collection = _createCollection();
        TestErc20 token = new TestErc20();
        bytes32 key = keccak256(abi.encodePacked(address(token)));

        _setInvite(collection, key, _invite(1 ether, 1, 1, 0, address(token)));

        vm.prank(buyer);
        token.mint(3 ether);
        vm.prank(buyer);
        token.approve(address(collection), 3 ether);

        _setInvite(collection, key, _invite(2 ether, 1, 1, 0, address(token)));
        vm.prank(buyer);
        vm.expectRevert(ExcessiveCurrencyCost.selector);
        collection.mintToken(_auth(key), 1, TOKEN_ID, address(0), "", _constraints(address(token), 1 ether, 1));

        assertEq(token.balanceOf(buyer), 3 ether);
        assertEq(payouts.balanceToken(owner, address(token)), 0);
        assertEq(payouts.balanceToken(PLATFORM, address(token)), 0);
    }

    function testAudit_feeIncreaseRequiresTheLiveMinimumFee() public {
        ArchetypeErc1155 collection = _createCollection();
        _setInvite(collection, PUBLIC_KEY, _invite(0, 10, 10, 0, address(0)));

        vm.prank(owner);
        feeRegistry.setNativeMinimumFee(0.01 ether);
        vm.prank(owner);
        feeRegistry.setNativeMinimumFee(0.02 ether);

        vm.txGasPrice(0);
        uint256 balanceBefore = buyer.balance;
        vm.prank(buyer);
        vm.expectRevert(InsufficientEthSent.selector);
        collection.mintToken{value: 0.01 ether}(
            _auth(PUBLIC_KEY), 1, TOKEN_ID, address(0), "", _constraints(address(0), 0, 1)
        );

        assertEq(buyer.balance, balanceBefore);
        assertEq(payouts.balance(PLATFORM), 0);
    }

    function _createCollection() internal returns (ArchetypeErc1155 collection) {
        collection = ArchetypeErc1155(factory.createCollection(owner, "Pookie", "POOKIE", _config(), _payoutConfig()));
    }

    function _config() internal view returns (Config memory) {
        uint32[] memory maxSupply = new uint32[](1);
        maxSupply[0] = 1000;
        return Config({
            baseUri: "ipfs://test/",
            maxSupply: maxSupply,
            maxBatchSize: 20,
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

    function _invite(uint128 price, uint32 limit, uint32 maxSupply, uint32 end, address token)
        internal
        view
        returns (Invite memory)
    {
        uint32[] memory tokenIds = new uint32[](1);
        tokenIds[0] = uint32(TOKEN_ID);
        return Invite({
            price: price,
            start: uint32(block.timestamp),
            end: end,
            limit: limit,
            maxSupply: maxSupply,
            unitSize: 1,
            tokenIds: tokenIds,
            tokenAddress: token
        });
    }

    function _setInvite(ArchetypeErc1155 collection, bytes32 key, Invite memory invite) internal {
        vm.prank(owner);
        collection.setInvite(key, CID_ZERO, invite);
    }

    function _mint(ArchetypeErc1155 collection, address minter, uint256 quantity) internal {
        _mint(collection, minter, quantity, PUBLIC_KEY);
    }

    function _mint(ArchetypeErc1155 collection, address minter, uint256 quantity, bytes32 key) internal {
        vm.prank(minter);
        collection.mintToken(
            _auth(key), quantity, TOKEN_ID, address(0), "", _constraints(address(0), type(uint128).max, quantity)
        );
    }

    function _mintWithAffiliate(ArchetypeErc1155 collection, address affiliate_, bytes memory signature, uint256 value)
        internal
    {
        vm.prank(buyer);
        collection.mintToken{value: value}(
            _auth(PUBLIC_KEY), 1, TOKEN_ID, affiliate_, signature, _constraints(address(0), type(uint128).max, 1)
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
