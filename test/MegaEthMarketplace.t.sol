// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ScatterOffererE2ETest} from "./ScatterOffererE2E.t.sol";
import {ScatterAggregatorRouterE2ETest} from "./ScatterAggregatorRouterE2E.t.sol";
import {ScatterBidRouterMatchedTest} from "./ScatterBidRouterMatched.t.sol";

contract MegaEthOffererTest is ScatterOffererE2ETest {
    function setUp() public override {
        vm.chainId(4326);
        super.setUp();
    }
}

contract MegaEthAggregatorTest is ScatterAggregatorRouterE2ETest {
    function setUp() public override {
        vm.chainId(4326);
        super.setUp();
    }
}

contract MegaEthBidRouterTest is ScatterBidRouterMatchedTest {
    function setUp() public override {
        vm.chainId(4326);
        super.setUp();
    }
}
