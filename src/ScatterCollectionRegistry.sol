// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IOwnable} from "./IOwnable.sol";

error UnauthorizedFactory();
error CollectionAlreadyRegistered();
error InvalidCollection();
error InvalidFactory();

/// Records Scatter collection membership and resolves marketplace rewards recipients.
///
/// `setRewardsOverride` takes priority over the default policy. Without an
/// override, registered Scatter collections pay their current owner and other
/// collections return the zero address. A zero override disables rewards.
/// `clearRewardsOverride` restores the default policy.
///
/// Router fills revert if the recipient rejects an ETH or ERC20 transfer. Set
/// an override to a recipient that accepts the collection's payment currency.
contract ScatterCollectionRegistry is Ownable2Step {
    struct RewardsOverride {
        address recipient;
        bool configured;
    }

    mapping(address collection => bool) public scatterCollections;
    mapping(address collection => RewardsOverride) private overrides;
    mapping(address factory => bool) public approvedFactories;

    event ApprovedFactoryUpdated(address indexed factory, bool approved);
    event ScatterCollectionRegistered(address indexed collection, address indexed registrar);
    event RewardsOverrideUpdated(address indexed collection, address indexed recipient, bool configured);

    constructor(address initialOwner) Ownable(initialOwner) {}

    function setApprovedFactory(address factory, bool approved) external onlyOwner {
        if (factory == address(0) || (approved && factory.code.length == 0)) revert InvalidFactory();
        approvedFactories[factory] = approved;
        emit ApprovedFactoryUpdated(factory, approved);
    }

    function registerScatterCollection(address collection) external {
        if (!approvedFactories[msg.sender]) revert UnauthorizedFactory();
        _registerScatterCollection(collection);
    }

    function registerScatterCollections(address[] calldata collections) external onlyOwner {
        for (uint256 i = 0; i < collections.length; i++) {
            _registerScatterCollection(collections[i]);
        }
    }

    /// @notice Sets the recipient for a collection. The zero address disables rewards.
    function setRewardsOverride(address collection, address recipient) external onlyOwner {
        if (collection == address(0) || collection.code.length == 0) revert InvalidCollection();
        overrides[collection] = RewardsOverride({recipient: recipient, configured: true});
        emit RewardsOverrideUpdated(collection, recipient, true);
    }

    /// @notice Restores the default policy for a collection.
    function clearRewardsOverride(address collection) external onlyOwner {
        if (collection == address(0)) revert InvalidCollection();
        delete overrides[collection];
        emit RewardsOverrideUpdated(collection, address(0), false);
    }

    /// @notice Returns an override, the current owner of a registered Scatter collection, or zero for other collections.
    function rewardsRecipient(address collection) external view returns (address) {
        RewardsOverride memory rewardsOverride = overrides[collection];

        if (rewardsOverride.configured) {
            return rewardsOverride.recipient;
        }

        if (!scatterCollections[collection]) {
            return address(0);
        }

        return IOwnable(collection).owner();
    }

    function _registerScatterCollection(address collection) private {
        if (collection == address(0) || collection.code.length == 0) revert InvalidCollection();
        if (scatterCollections[collection]) revert CollectionAlreadyRegistered();

        scatterCollections[collection] = true;
        emit ScatterCollectionRegistered(collection, msg.sender);
    }
}
