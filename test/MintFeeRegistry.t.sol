// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    MintFeeRegistry,
    UnauthorizedFeeUpdater,
    FeeOutsideUpdaterBounds,
    InvalidUpdaterBounds
} from "../src/MintFeeRegistry.sol";

contract MintFeeRegistryTest is Test {
    event NativeMinimumFeeChanged(uint256 previousFee, uint256 newFee);

    address internal owner = makeAddr("owner");
    address internal updater = makeAddr("updater");
    address internal other = makeAddr("other");

    function testFuzz_updaterAcceptsFeeWithinBounds(uint32 fee) public {
        vm.assume(fee >= 100 && fee <= 1_000);
        MintFeeRegistry registry = new MintFeeRegistry(owner, updater, 100, 1_000, 100);

        vm.prank(updater);
        registry.setNativeMinimumFee(fee);

        assertEq(registry.nativeMinimumFee(), fee);
    }

    function testFuzz_updaterRejectsFeeOutsideBounds(uint32 fee) public {
        vm.assume(fee < 100 || fee > 1_000);
        MintFeeRegistry registry = new MintFeeRegistry(owner, updater, 100, 1_000, 100);

        vm.prank(updater);
        vm.expectRevert(FeeOutsideUpdaterBounds.selector);
        registry.setNativeMinimumFee(fee);
    }

    function testFuzz_unauthorizedAccountCannotSetFee(uint32 fee) public {
        MintFeeRegistry registry = new MintFeeRegistry(owner, updater, 100, 1_000, 100);

        vm.prank(other);
        vm.expectRevert(UnauthorizedFeeUpdater.selector);
        registry.setNativeMinimumFee(fee);
    }

    function test_updaterChangesFeeWithinOwnerLimit() public {
        MintFeeRegistry registry = new MintFeeRegistry(owner, updater, 0.001 ether, 0.01 ether, 0.005 ether);

        vm.prank(updater);
        vm.expectEmit();
        emit NativeMinimumFeeChanged(0.005 ether, 0.006 ether);
        registry.setNativeMinimumFee(0.006 ether);

        assertEq(registry.nativeMinimumFee(), 0.006 ether);

        vm.prank(updater);
        vm.expectRevert(FeeOutsideUpdaterBounds.selector);
        registry.setNativeMinimumFee(0.02 ether);

        vm.prank(updater);
        vm.expectRevert(FeeOutsideUpdaterBounds.selector);
        registry.setNativeMinimumFee(0);
    }

    function test_constructorSetsInitialFee() public {
        MintFeeRegistry registry = new MintFeeRegistry(owner, updater, 0, 1 ether, 0.005 ether);

        assertEq(registry.nativeMinimumFee(), 0.005 ether);
    }

    function test_ownerCanSetEqualUpdaterBounds() public {
        MintFeeRegistry registry = new MintFeeRegistry(owner, updater, 0, 1 ether, 0.005 ether);

        vm.prank(owner);
        registry.setUpdater(updater, 0.01 ether, 0.01 ether);

        assertEq(registry.updaterMinimumFee(), 0.01 ether);
        assertEq(registry.updaterMaximumFee(), 0.01 ether);
    }

    function test_accountsOnEitherSideOfAuthorizedAddressesCannotSetFee() public {
        address fixedOwner = address(100);
        address fixedUpdater = address(200);
        MintFeeRegistry registry = new MintFeeRegistry(fixedOwner, fixedUpdater, 0, 1 ether, 0.005 ether);

        vm.expectRevert(UnauthorizedFeeUpdater.selector);
        vm.prank(address(1));
        registry.setNativeMinimumFee(0);

        vm.expectRevert(UnauthorizedFeeUpdater.selector);
        vm.prank(address(300));
        registry.setNativeMinimumFee(0);
    }

    function test_ownerChangesFeeAndUpdaterLimit() public {
        MintFeeRegistry registry = new MintFeeRegistry(owner, updater, 0.001 ether, 0.01 ether, 0.005 ether);
        address nextUpdater = makeAddr("nextUpdater");

        vm.startPrank(owner);
        registry.setNativeMinimumFee(1 ether);
        registry.setUpdater(nextUpdater, 0.5 ether, 2 ether);
        vm.stopPrank();

        vm.prank(nextUpdater);
        registry.setNativeMinimumFee(2 ether);

        assertEq(registry.nativeMinimumFee(), 2 ether);
        assertEq(registry.updater(), nextUpdater);
        assertEq(registry.updaterMinimumFee(), 0.5 ether);
        assertEq(registry.updaterMaximumFee(), 2 ether);
    }

    function test_unauthorizedAccountCannotChangeConfiguration() public {
        MintFeeRegistry registry = new MintFeeRegistry(owner, updater, 0.001 ether, 0.01 ether, 0.005 ether);

        vm.prank(other);
        vm.expectRevert(UnauthorizedFeeUpdater.selector);
        registry.setNativeMinimumFee(0);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        registry.setUpdater(other, 0, 1 ether);
    }

    function test_ownerCannotSetInvertedUpdaterBounds() public {
        MintFeeRegistry registry = new MintFeeRegistry(owner, updater, 0, 1 ether, 0.005 ether);

        vm.prank(owner);
        vm.expectRevert(InvalidUpdaterBounds.selector);
        registry.setUpdater(updater, 2 ether, 1 ether);
    }
}
