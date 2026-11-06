// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ConduitController} from "seaport-core/conduit/ConduitController.sol";
import {Seaport} from "seaport-core/Seaport.sol";
import {ISeaportDeployer} from "./ISeaportDeployer.sol";

contract SeaportDeployer is ISeaportDeployer {
    function deploy() external override returns (address) {
        return address(
            new Seaport(
                block.chainid == 4326
                    ? 0x1Bd5F90EA0f24Ba5773BDbABa23363225e99d2aF
                    : 0x00000000F9490004C11Cef243f5400493c00Ad63
            )
        );
    }
}
