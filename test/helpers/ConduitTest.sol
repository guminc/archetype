// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ConduitControllerInterface} from "seaport-types/src/interfaces/ConduitControllerInterface.sol";
import {ConduitInterface} from "seaport-types/src/interfaces/ConduitInterface.sol";
import {ISeaportDeployer} from "./ISeaportDeployer.sol";

abstract contract ConduitTest is Test {
    ConduitControllerInterface internal conduitController =
        ConduitControllerInterface(0x00000000F9490004C11Cef243f5400493c00Ad63);
    ConduitInterface internal conduit;
    bytes32 internal conduitKey;

    function _setUpConduit() internal virtual {
        if (block.chainid == 4326) {
            conduitController = ConduitControllerInterface(0x1Bd5F90EA0f24Ba5773BDbABa23363225e99d2aF);
        }
        deployCodeTo("ConduitController.sol:ConduitController", address(conduitController));
        conduitKey = bytes32(uint256(uint160(address(this))) << 96 | 1);
        conduit = ConduitInterface(conduitController.createConduit(conduitKey, address(this)));
    }

    function _setUpSeaport(address target) internal virtual {
        address deployer = deployCode("test/helpers/SeaportDeployer.sol:SeaportDeployer");
        vm.etch(target, ISeaportDeployer(deployer).deploy().code);
    }

    function _openConduitChannel(address channel) internal {
        conduitController.updateChannel(address(conduit), channel, true);
    }
}
