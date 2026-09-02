// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {
    ArchetypePayouts,
    InvalidRecipient,
    NativeMintCredit,
    UnexpectedTokenBalanceChange
} from "../src/ArchetypePayouts.sol";
import {FeeOnTransferErc20} from "./mocks/FeeOnTransferErc20.sol";

contract NativeMintCreditCaller {
    ArchetypePayouts internal immutable payouts;

    constructor(ArchetypePayouts payouts_) {
        payouts = payouts_;
    }

    function credit(NativeMintCredit calldata credit_, address[] calldata recipients, uint16[] calldata splits)
        external
        payable
    {
        payouts.creditMint{value: msg.value}(credit_, recipients, splits);
    }
}

contract ArchetypePayoutsTest is Test {
    ArchetypePayouts internal payouts;
    address internal creator = makeAddr("creator");
    address internal platform = makeAddr("platform");

    function setUp() public {
        payouts = new ArchetypePayouts();
    }

    function test_updateBalances_assignsRoundingResidual() public {
        address[] memory recipients = new address[](2);
        recipients[0] = creator;
        recipients[1] = platform;
        uint16[] memory splits = new uint16[](2);
        splits[0] = 9500;
        splits[1] = 500;

        payouts.updateBalances{value: 1}(1, address(0), recipients, splits);
        payouts.updateBalances{value: 101}(101, address(0), recipients, splits);

        assertEq(payouts.balance(creator), 97);
        assertEq(payouts.balance(platform), 5);
        assertEq(address(payouts).balance, 102);
    }

    function test_updateBalances_rejectsPositiveSplitForZeroRecipient() public {
        address[] memory recipients = new address[](2);
        recipients[0] = creator;
        uint16[] memory splits = new uint16[](2);
        splits[0] = 9500;
        splits[1] = 500;

        vm.expectRevert(InvalidRecipient.selector);
        payouts.updateBalances{value: 1 ether}(1 ether, address(0), recipients, splits);
    }

    function test_creditMint_preservesBalancesAndEventOrder() public {
        NativeMintCreditCaller caller = new NativeMintCreditCaller(payouts);
        address affiliate = makeAddr("affiliate");
        address[] memory recipients = new address[](2);
        recipients[0] = creator;
        recipients[1] = platform;
        uint16[] memory splits = new uint16[](2);
        splits[0] = 9500;
        splits[1] = 500;
        NativeMintCredit memory credit = NativeMintCredit({
            payoutAmount: 86, affiliateAmount: 15, platformSurcharge: 3, affiliate: affiliate, platform: platform
        });

        vm.recordLogs();
        caller.credit{value: 104}(credit, recipients, splits);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(payouts.balance(creator), 82);
        assertEq(payouts.balance(platform), 7);
        assertEq(payouts.balance(affiliate), 15);
        assertEq(address(payouts).balance, 104);

        assertEq(logs.length, 4);
        _assertFundsAdded(logs[0], address(caller), platform, 4);
        _assertFundsAdded(logs[1], address(caller), creator, 82);
        _assertFundsAdded(logs[2], address(caller), affiliate, 15);
        _assertFundsAdded(logs[3], address(caller), platform, 3);
    }

    function test_updateBalances_rejectsFeeOnTransferErc20() public {
        FeeOnTransferErc20 token = new FeeOnTransferErc20();
        address[] memory recipients = new address[](1);
        recipients[0] = creator;
        uint16[] memory splits = new uint16[](1);
        splits[0] = 10000;
        token.mint(address(this), 1 ether);
        token.approve(address(payouts), 1 ether);

        vm.expectRevert(UnexpectedTokenBalanceChange.selector);
        payouts.updateBalances(1 ether, address(token), recipients, splits);

        assertEq(token.balanceOf(address(this)), 1 ether);
        assertEq(token.balanceOf(address(payouts)), 0);
        assertEq(payouts.balanceToken(creator, address(token)), 0);
    }

    function _assertFundsAdded(Vm.Log memory log, address source, address recipient, uint256 amount) internal view {
        assertEq(log.emitter, address(payouts));
        assertEq(log.topics[0], keccak256("FundsAdded(address,address,address,uint256)"));
        assertEq(address(uint160(uint256(log.topics[1]))), source);
        assertEq(address(uint160(uint256(log.topics[2]))), recipient);
        (address token, uint256 loggedAmount) = abi.decode(log.data, (address, uint256));
        assertEq(token, address(0));
        assertEq(loggedAmount, amount);
    }
}
