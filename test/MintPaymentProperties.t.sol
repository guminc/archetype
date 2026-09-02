// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {
    ArchetypeLogicErc721a,
    Config,
    Invite,
    MintPayment,
    PayoutConfig
} from "../src/ERC721a/ArchetypeLogicErc721a.sol";

contract MintPaymentPropertiesTest is Test {
    bytes32 internal constant PUBLIC_KEY = bytes32(uint256(1));
    bytes32 internal constant PRIVATE_KEY = keccak256("private invite");

    Invite internal invite;
    Config internal config;
    PayoutConfig internal payoutConfig;

    function testFuzz_publicNativeMintChargesTheLargerPlatformFee(uint64 price, uint32 nativeMinimumFee) public {
        invite.price = price;
        invite.tokenAddress = address(0);
        config.affiliateFee = 1_500;
        payoutConfig.platformBps = 500;

        MintPayment memory payment = ArchetypeLogicErc721a.computeMintPayment(
            invite, config, payoutConfig, PUBLIC_KEY, 2, true, nativeMinimumFee
        );

        uint256 currencyCost = uint256(price) * 2;
        uint256 affiliateShare = (currencyCost * 1_500) / 10_000;
        uint256 percentageFee = ((currencyCost - affiliateShare) * 500) / 10_000;
        uint256 minimumFee = uint256(nativeMinimumFee) * 2;
        uint256 surcharge = minimumFee > percentageFee ? minimumFee - percentageFee : 0;

        assertEq(payment.currencyCost, currencyCost);
        assertEq(payment.platformSurcharge, surcharge);
        assertEq(payment.nativeValue, currencyCost + surcharge);
    }

    function testFuzz_publicErc20MintChargesNativeMinimum(uint64 price, uint32 nativeMinimumFee) public {
        invite.price = price;
        invite.tokenAddress = address(1);
        bytes32 key = keccak256(abi.encodePacked(invite.tokenAddress));

        MintPayment memory payment =
            ArchetypeLogicErc721a.computeMintPayment(invite, config, payoutConfig, key, 2, false, nativeMinimumFee);

        uint256 minimumFee = uint256(nativeMinimumFee) * 2;
        assertEq(payment.currencyCost, uint256(price) * 2);
        assertEq(payment.platformSurcharge, minimumFee);
        assertEq(payment.nativeValue, minimumFee);
    }

    function testFuzz_privateNativeMintIsExempt(uint64 price, uint32 nativeMinimumFee) public {
        invite.price = price;
        invite.tokenAddress = address(0);

        MintPayment memory payment = ArchetypeLogicErc721a.computeMintPayment(
            invite, config, payoutConfig, PRIVATE_KEY, 2, false, nativeMinimumFee
        );

        uint256 currencyCost = uint256(price) * 2;
        assertEq(payment.currencyCost, currencyCost);
        assertEq(payment.platformSurcharge, 0);
        assertEq(payment.nativeValue, currencyCost);
    }
}
