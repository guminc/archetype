// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ConduitControllerInterface} from "seaport-types/src/interfaces/ConduitControllerInterface.sol";
import {ConduitInterface} from "seaport-types/src/interfaces/ConduitInterface.sol";
import {ConduitTransfer} from "seaport-types/src/conduit/lib/ConduitStructs.sol";

error InvalidConduit(bytes32 conduitKey);
error ConduitExecutionFailed();

abstract contract ConduitConsumer {
    ConduitInterface public immutable CONDUIT;

    constructor(bytes32 conduitKey) {
        if (conduitKey == bytes32(0)) revert InvalidConduit(conduitKey);
        address controller = block.chainid == 4326
            ? 0x1Bd5F90EA0f24Ba5773BDbABa23363225e99d2aF
            : 0x00000000F9490004C11Cef243f5400493c00Ad63;
        (address conduit, bool exists) = ConduitControllerInterface(controller).getConduit(conduitKey);
        if (!exists) revert InvalidConduit(conduitKey);
        CONDUIT = ConduitInterface(conduit);
    }

    function _executeConduit(ConduitTransfer[] memory transfers) internal {
        if (CONDUIT.execute(transfers) != ConduitInterface.execute.selector) revert ConduitExecutionFailed();
    }
}
