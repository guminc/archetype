// SPDX-License-Identifier: MIT
// forge-lint: disable-start(mixed-case-function, mixed-case-variable)
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestErc20} from "../src/TestErc20.sol";

contract TestErc20Test is Test {
    TestErc20 internal subject;

    address internal minter;
    address internal other;

    function setUp() public {
        subject = new TestErc20();

        minter = makeAddr("minter");
        other = makeAddr("other");

        // End setUp pranking a neutral actor so a test that forgets to prank
        // does not silently run as a privileged/default account.
        _prank(other);
    }

    function test_constructor_setsName() public view {
        assertEq(subject.name(), "Token");
    }

    function test_constructor_setsSymbol() public view {
        assertEq(subject.symbol(), "TKN");
    }

    function test_constructor_usesDefaultDecimals() public view {
        assertEq(subject.decimals(), 18);
    }

    function test_constructor_mintsNoInitialSupply() public view {
        assertEq(subject.totalSupply(), 0);
    }

    function test_mint_mintsQuantityToCaller() public {
        _prank(minter);
        subject.mint(1000);

        assertEq(subject.balanceOf(minter), 1000);
        assertEq(subject.totalSupply(), 1000);
    }

    function test_mint_creditsTheCallerNotOtherAccounts() public {
        _prank(minter);
        subject.mint(1000);

        assertEq(subject.balanceOf(other), 0);
    }

    function test_mint_emitsTransferEvent() public {
        _prank(minter);

        vm.expectEmit(true, true, false, true, address(subject));
        //            from  to    -     value  emitter
        emit IERC20.Transfer(address(0), minter, 1000);
        subject.mint(1000);
    }

    function test_mint_accumulatesAcrossCalls() public {
        _prank(minter);
        subject.mint(1000);
        subject.mint(500);

        assertEq(subject.balanceOf(minter), 1500);
        assertEq(subject.totalSupply(), 1500);
    }

    function _prank(address actor) internal {
        vm.stopPrank();
        vm.startPrank(actor);
    }
}
