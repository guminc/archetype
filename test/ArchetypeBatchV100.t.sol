// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-v4/token/ERC20/IERC20.sol";
import {ArchetypeBatchV100} from "../src/ArchetypeBatchV100.sol";
import {ArchetypePayouts} from "../src/ArchetypePayouts.sol";
import {ArchetypeErc721a, Auth, Config, Invite, PayoutConfig} from "../src/ERC721a/ArchetypeErc721a.sol";
import {ArchetypeAddresses} from "../src/ERC721a/ArchetypeLogicErc721a.sol";
import {FactoryErc721a} from "../src/ERC721a/FactoryErc721a.sol";
import {MintFeeRegistry} from "../src/MintFeeRegistry.sol";
import {AffiliateSignerRegistry} from "../src/AffiliateSignerRegistry.sol";
import {MintConstraints} from "../src/MintConstraints.sol";
import {RoyaltyPolicyRegistry} from "../src/RoyaltyPolicyRegistry.sol";
import {TestErc20} from "../src/TestErc20.sol";

contract ArchetypeBatchV100Test is Test {
    address internal constant PLATFORM = 0x2222222222222222222222222222222222222221;
    address internal constant AFFILIATE_SIGNER = 0x3333333333333333333333333333333333333333;
    bytes32 internal constant PUBLIC_KEY = bytes32(uint256(1));
    bytes32 internal constant CID_ZERO = bytes32(0);

    address internal owner = makeAddr("owner");
    address internal buyer = makeAddr("buyer");

    ArchetypePayouts internal payouts;
    ArchetypeBatchV100 internal batch;
    MintFeeRegistry internal feeRegistry;
    AffiliateSignerRegistry internal affiliateSignerRegistry;
    RoyaltyPolicyRegistry internal royaltyPolicyRegistry;
    ArchetypeErc721a internal archetype;
    FactoryErc721a internal factory;

    function setUp() public {
        vm.deal(owner, 100 ether);
        vm.deal(buyer, 100 ether);

        payouts = new ArchetypePayouts();
        royaltyPolicyRegistry = new RoyaltyPolicyRegistry(owner);
        batch = new ArchetypeBatchV100(owner, royaltyPolicyRegistry);
        feeRegistry = new MintFeeRegistry(owner, owner, 0, 1 ether, 0);
        affiliateSignerRegistry = new AffiliateSignerRegistry(owner, AFFILIATE_SIGNER);
        archetype =
            new ArchetypeErc721a(PLATFORM, address(payouts), address(batch), feeRegistry, affiliateSignerRegistry);

        vm.startPrank(owner);
        factory = new FactoryErc721a(address(archetype), owner, royaltyPolicyRegistry);
        royaltyPolicyRegistry.setApprovedFactory(address(factory), true);
        vm.stopPrank();
    }

    function test_constructor_rejectsAMissingRegistry() public {
        vm.expectRevert(ArchetypeBatchV100.InvalidRoyaltyPolicyRegistry.selector);
        new ArchetypeBatchV100(owner, RoyaltyPolicyRegistry(address(0)));
    }

    function test_executeBatch_mintsFromEveryListWithTheExactNativePayment() public {
        ArchetypeErc721a collection = _createCollection();
        _setPublicInvite(collection, 0.1 ether);

        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory datas = new bytes[](2);
        for (uint256 i; i < targets.length; ++i) {
            targets[i] = address(collection);
            values[i] = 0.1 ether;
            datas[i] = abi.encodeCall(collection.mint, (_auth(PUBLIC_KEY), 1, address(0), "", _constraints()));
        }

        vm.txGasPrice(0);
        uint256 buyerBalanceBefore = buyer.balance;
        vm.prank(buyer);
        batch.executeBatch{value: 0.2 ether}(targets, values, datas);

        assertEq(collection.balanceOf(buyer), 2);
        assertEq(collection.balanceOf(address(batch)), 0);
        assertEq(buyerBalanceBefore - buyer.balance, 0.2 ether);
        assertEq(address(batch).balance, 0);
        assertEq(batch.currentCaller(), address(0));
    }

    function test_executeBatch_rejectsSurplusNativePayment() public {
        ArchetypeErc721a collection = _createCollection();
        _setPublicInvite(collection, 0);

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory datas = new bytes[](1);
        targets[0] = address(collection);
        datas[0] = abi.encodeCall(collection.mint, (_auth(PUBLIC_KEY), 1, address(0), "", _constraints()));

        vm.prank(buyer);
        vm.expectRevert(ArchetypeBatchV100.BatchValueMismatch.selector);
        batch.executeBatch{value: 1}(targets, values, datas);

        assertEq(collection.totalSupply(), 0);
        assertEq(address(batch).balance, 0);
    }

    function test_executeBatch_cannotSpendNativeBalanceHeldBeforeTheCall() public {
        ArchetypeErc721a collection = _createCollection();
        _setPublicInvite(collection, 0.1 ether);

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory datas = new bytes[](1);
        targets[0] = address(collection);
        values[0] = 0.1 ether;
        datas[0] = abi.encodeCall(collection.mint, (_auth(PUBLIC_KEY), 1, address(0), "", _constraints()));

        vm.deal(address(batch), 0.1 ether);
        vm.prank(buyer);
        vm.expectRevert(ArchetypeBatchV100.BatchValueMismatch.selector);
        batch.executeBatch(targets, values, datas);

        assertEq(address(batch).balance, 0.1 ether);
        assertEq(collection.totalSupply(), 0);
    }

    function test_executeBatch_rejectsANonRegisteredTarget() public {
        TestErc20 token = new TestErc20();
        token.mint(1 ether);
        token.transfer(address(batch), 1 ether);

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory datas = new bytes[](1);
        targets[0] = address(token);
        datas[0] = abi.encodeCall(IERC20.transfer, (buyer, 1 ether));

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ArchetypeBatchV100.UnsupportedCollection.selector, address(token)));
        batch.executeBatch(targets, values, datas);

        assertEq(token.balanceOf(address(batch)), 1 ether);
        assertEq(token.balanceOf(buyer), 0);
    }

    function test_executeBatch_rejectsACollectionWiredToAnotherBatch() public {
        ArchetypeErc721a collection = _createCollection();
        _setPublicInvite(collection, 0);
        ArchetypeBatchV100 otherBatch = new ArchetypeBatchV100(owner, royaltyPolicyRegistry);

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory datas = new bytes[](1);
        targets[0] = address(collection);
        datas[0] = abi.encodeCall(collection.mint, (_auth(PUBLIC_KEY), 1, address(0), "", _constraints()));

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ArchetypeBatchV100.UnsupportedCollection.selector, address(collection)));
        otherBatch.executeBatch(targets, values, datas);

        assertEq(collection.totalSupply(), 0);
    }

    function test_executeBatch_nestedCallUsesItsOwnCaller() public {
        ReentrantMintCollection target = new ReentrantMintCollection(batch);
        address[] memory registered = new address[](1);
        registered[0] = address(target);
        vm.prank(owner);
        royaltyPolicyRegistry.registerScatterCollections(registered);

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory datas = new bytes[](1);
        targets[0] = address(target);
        Auth memory auth = _auth(PUBLIC_KEY);
        datas[0] = abi.encodeCall(target.mint, (auth, 1, address(0), "", _constraints()));

        vm.prank(buyer);
        batch.executeBatch(targets, values, datas);

        assertEq(target.nestedCaller(), address(target));
        assertEq(target.restoredOuterCaller(), buyer);
        assertEq(batch.currentCaller(), address(0));
    }

    function test_rescueETH_movesOnlyWithOwnerAuthority() public {
        vm.deal(address(batch), 0.1 ether);

        vm.prank(buyer);
        vm.expectRevert("Ownable: caller is not the owner");
        batch.rescueETH(buyer);

        uint256 buyerBalanceBefore = buyer.balance;
        vm.prank(owner);
        batch.rescueETH(buyer);

        assertEq(buyer.balance - buyerBalanceBefore, 0.1 ether);
        assertEq(address(batch).balance, 0);
    }

    function test_rescueERC20_movesOnlyWithOwnerAuthority() public {
        TestErc20 token = new TestErc20();
        token.mint(1 ether);
        token.transfer(address(batch), 1 ether);

        vm.prank(buyer);
        vm.expectRevert("Ownable: caller is not the owner");
        batch.rescueERC20(IERC20(address(token)), buyer);

        vm.prank(owner);
        batch.rescueERC20(IERC20(address(token)), buyer);

        assertEq(token.balanceOf(buyer), 1 ether);
        assertEq(token.balanceOf(address(batch)), 0);
    }

    function _createCollection() internal returns (ArchetypeErc721a collection) {
        collection = ArchetypeErc721a(factory.createCollection(owner, "Pookie", "POOKIE", _config(), _payoutConfig()));
    }

    function _config() internal view returns (Config memory config) {
        config = Config({
            baseUri: "ipfs://test",
            maxSupply: 10,
            maxBatchSize: 10,
            affiliateFee: 1500,
            affiliateDiscount: 0,
            defaultRoyalty: 0
        });
    }

    function _payoutConfig() internal pure returns (PayoutConfig memory payoutConfig) {
        payoutConfig = PayoutConfig({
            ownerBps: 9500,
            platformBps: 500,
            partnerBps: 0,
            superAffiliateBps: 0,
            partner: address(0),
            superAffiliate: address(0),
            ownerAltPayout: address(0)
        });
    }

    function _setPublicInvite(ArchetypeErc721a collection, uint128 price) internal {
        vm.prank(owner);
        collection.setInvite(
            PUBLIC_KEY,
            CID_ZERO,
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

    function _auth(bytes32 key) internal pure returns (Auth memory auth) {
        auth.key = key;
        auth.proof = new bytes32[](0);
    }

    function _constraints() internal pure returns (MintConstraints memory) {
        return MintConstraints({
            currency: address(0),
            maxCurrencyCost: type(uint128).max,
            maxNativeValue: type(uint256).max,
            minTotalMints: 0
        });
    }
}

contract ReentrantMintCollection {
    ArchetypeBatchV100 private immutable batch;
    bool private entered;
    address public nestedCaller;
    address public restoredOuterCaller;

    constructor(ArchetypeBatchV100 batch_) {
        batch = batch_;
    }

    function archetypeAddresses() external view returns (ArchetypeAddresses memory addrs) {
        addrs.batch = address(batch);
    }

    function mint(
        Auth calldata auth,
        uint256 quantity,
        address affiliate,
        bytes calldata signature,
        MintConstraints calldata
    ) external payable {
        if (entered) {
            nestedCaller = batch.currentCaller();
            return;
        }

        entered = true;
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory datas = new bytes[](1);
        targets[0] = address(this);
        datas[0] = abi.encodeCall(
            this.mint,
            (
                auth,
                quantity,
                affiliate,
                signature,
                MintConstraints({
                    currency: address(0),
                    maxCurrencyCost: type(uint128).max,
                    maxNativeValue: type(uint256).max,
                    minTotalMints: 0
                })
            )
        );
        batch.executeBatch(targets, values, datas);
        restoredOuterCaller = batch.currentCaller();
    }
}
