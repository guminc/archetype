// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

error UnauthorizedFeeUpdater();
error FeeOutsideUpdaterBounds();
error InvalidUpdaterBounds();

contract MintFeeRegistry is Ownable {
    address public updater;
    uint256 public updaterMinimumFee;
    uint256 public updaterMaximumFee;
    uint256 public nativeMinimumFee;

    event UpdaterChanged(
        address indexed previousUpdater, address indexed newUpdater, uint256 minimumFee, uint256 maximumFee
    );
    event NativeMinimumFeeChanged(uint256 previousFee, uint256 newFee);

    constructor(
        address initialOwner,
        address initialUpdater,
        uint256 minimumFee,
        uint256 maximumFee,
        uint256 initialFee
    ) Ownable(initialOwner) {
        _setUpdater(initialUpdater, minimumFee, maximumFee);
        nativeMinimumFee = initialFee;
    }

    function setUpdater(address newUpdater, uint256 minimumFee, uint256 maximumFee) external onlyOwner {
        _setUpdater(newUpdater, minimumFee, maximumFee);
    }

    function _setUpdater(address newUpdater, uint256 minimumFee, uint256 maximumFee) internal {
        if (minimumFee > maximumFee) revert InvalidUpdaterBounds();
        address previousUpdater = updater;
        updater = newUpdater;
        updaterMinimumFee = minimumFee;
        updaterMaximumFee = maximumFee;
        emit UpdaterChanged(previousUpdater, newUpdater, minimumFee, maximumFee);
    }

    function setNativeMinimumFee(uint256 newFee) external {
        if (msg.sender != owner()) {
            if (msg.sender != updater) revert UnauthorizedFeeUpdater();
            if (newFee < updaterMinimumFee || newFee > updaterMaximumFee) revert FeeOutsideUpdaterBounds();
        }

        uint256 previousFee = nativeMinimumFee;
        nativeMinimumFee = newFee;
        emit NativeMinimumFeeChanged(previousFee, newFee);
    }
}
