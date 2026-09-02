// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

error Reentrancy();

abstract contract TransientReentrancyGuard {
    uint256 private constant _REENTRANCY_GUARD_SLOT = 0x929eee149b4bd21268;

    modifier nonReentrant() {
        assembly ("memory-safe") {
            if tload(_REENTRANCY_GUARD_SLOT) {
                mstore(0x00, 0xab143c06)
                revert(0x1c, 0x04)
            }
            tstore(_REENTRANCY_GUARD_SLOT, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(_REENTRANCY_GUARD_SLOT, 0)
        }
    }
}
