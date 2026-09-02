// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    RoyaltyPolicyRegistry,
    UnauthorizedFactory,
    CollectionAlreadyRegistered,
    InvalidCollection,
    InvalidFactory
} from "../src/RoyaltyPolicyRegistry.sol";

contract RoyaltyPolicyRegistryTest is Test {
    address internal owner = makeAddr("owner");
    address internal recipient = makeAddr("recipient");
    RoyaltyPolicyRegistry internal registry;
    RegistryFactoryCaller internal factory;
    MutableCollectionOwner internal collection;

    function setUp() public {
        registry = new RoyaltyPolicyRegistry(owner);
        factory = new RegistryFactoryCaller();
        collection = new MutableCollectionOwner(owner);
    }

    function test_unregisteredCollectionHasNoRoyalty() public view {
        assertEq(registry.royaltyRecipient(address(collection)), address(0));
    }

    function test_approvedFactoryRegistersCollection() public {
        vm.prank(owner);
        registry.setApprovedFactory(address(factory), true);

        factory.register(registry, address(collection));

        assertTrue(registry.scatterCollections(address(collection)));
        assertEq(registry.royaltyRecipient(address(collection)), owner);
    }

    function test_unapprovedFactoryCannotRegisterCollection() public {
        vm.expectRevert(UnauthorizedFactory.selector);
        factory.register(registry, address(collection));
    }

    function test_collectionCannotBeRegisteredTwice() public {
        vm.prank(owner);
        registry.setApprovedFactory(address(factory), true);
        factory.register(registry, address(collection));

        vm.expectRevert(CollectionAlreadyRegistered.selector);
        factory.register(registry, address(collection));
    }

    function test_ownerBatchRegistersExistingCollections() public {
        MutableCollectionOwner secondCollection = new MutableCollectionOwner(recipient);
        address[] memory collections = new address[](2);
        collections[0] = address(collection);
        collections[1] = address(secondCollection);

        vm.prank(owner);
        registry.registerScatterCollections(collections);

        assertEq(registry.royaltyRecipient(address(collection)), owner);
        assertEq(registry.royaltyRecipient(address(secondCollection)), recipient);
    }

    function test_registeredCollectionUsesCurrentOwner() public {
        address[] memory collections = new address[](1);
        collections[0] = address(collection);
        vm.prank(owner);
        registry.registerScatterCollections(collections);

        collection.setOwner(recipient);

        assertEq(registry.royaltyRecipient(address(collection)), recipient);
    }

    function test_nonzeroOverrideReplacesCollectionOwner() public {
        vm.prank(owner);
        registry.setRoyaltyOverride(address(collection), recipient);

        assertEq(registry.royaltyRecipient(address(collection)), recipient);
    }

    function test_zeroOverrideDisablesRoyalties() public {
        address[] memory collections = new address[](1);
        collections[0] = address(collection);
        vm.startPrank(owner);
        registry.registerScatterCollections(collections);
        registry.setRoyaltyOverride(address(collection), address(0));
        vm.stopPrank();

        assertEq(registry.royaltyRecipient(address(collection)), address(0));
    }

    function test_clearingOverrideRestoresCollectionOwner() public {
        address[] memory collections = new address[](1);
        collections[0] = address(collection);
        vm.startPrank(owner);
        registry.registerScatterCollections(collections);
        registry.setRoyaltyOverride(address(collection), recipient);
        registry.clearRoyaltyOverride(address(collection));
        vm.stopPrank();

        assertEq(registry.royaltyRecipient(address(collection)), owner);
    }

    function test_registeredCollectionReturningZeroHasNoRoyalty() public {
        address[] memory collections = new address[](1);
        collections[0] = address(collection);
        vm.prank(owner);
        registry.registerScatterCollections(collections);
        collection.setOwner(address(0));

        assertEq(registry.royaltyRecipient(address(collection)), address(0));
    }

    function test_registeredCollectionOwnerFailureReverts() public {
        RevertingCollectionOwner revertingCollection = new RevertingCollectionOwner();
        address[] memory collections = new address[](1);
        collections[0] = address(revertingCollection);
        vm.prank(owner);
        registry.registerScatterCollections(collections);

        vm.expectRevert(RevertingCollectionOwner.OwnerUnavailable.selector);
        registry.royaltyRecipient(address(revertingCollection));
    }

    function test_onlyOwnerCanConfigureRegistry() public {
        address caller = makeAddr("caller");
        vm.startPrank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        registry.setApprovedFactory(address(factory), true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        registry.setRoyaltyOverride(address(collection), recipient);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        registry.clearRoyaltyOverride(address(collection));
        vm.stopPrank();
    }

    function test_cannotApproveNonContractFactory() public {
        vm.prank(owner);
        vm.expectRevert(InvalidFactory.selector);
        registry.setApprovedFactory(makeAddr("notAContract"), true);
    }

    function test_cannotRegisterNonContractCollection() public {
        address[] memory collections = new address[](1);
        collections[0] = makeAddr("notAContract");

        vm.prank(owner);
        vm.expectRevert(InvalidCollection.selector);
        registry.registerScatterCollections(collections);
    }
}

contract RegistryFactoryCaller {
    function register(RoyaltyPolicyRegistry registry, address collection) external {
        registry.registerScatterCollection(collection);
    }
}

contract MutableCollectionOwner {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function setOwner(address owner_) external {
        owner = owner_;
    }
}

contract RevertingCollectionOwner {
    error OwnerUnavailable();

    function owner() external pure returns (address) {
        revert OwnerUnavailable();
    }
}
