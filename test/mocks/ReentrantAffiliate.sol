// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract ReentrantAffiliate {
    address private target;
    bytes private data;
    bool public callSucceeded;

    function setCall(address target_, bytes calldata data_) external {
        target = target_;
        data = data_;
    }

    receive() external payable {
        (callSucceeded,) = target.call(data);
    }
}
