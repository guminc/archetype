// SPDX-License-Identifier: BUSL-1.1
// Factory v0.8.0
//
// 8888888888                888
// 888                       888
// 888                       888
// 8888888  8888b.   .d8888b 888888 .d88b.  888d888 888  888
// 888         "88b d88P"    888   d88""88b 888P"   888  888
// 888     .d888888 888      888   888  888 888     888  888
// 888     888  888 Y88b.    Y88b. Y88..88P 888     Y88b 888
// 888     "Y888888  "Y8888P  "Y888 "Y88P"  888      "Y88888
//                                                       888
//                                                  Y8b d88P
//                                                   "Y88P"

pragma solidity ^0.8.20;

import "./ArchetypeBurgers404.sol";
import "./ArchetypeLogicBurgers404.sol";
import "openzeppelin-v4/proxy/Clones.sol";
import "openzeppelin-v4/access/Ownable.sol";

contract FactoryBurgers404 is Ownable {
  event CollectionAdded(address indexed sender, address indexed receiver, address collection);
  address public archetype;

  constructor(address archetype_) {
    archetype = archetype_;
  }

  function createCollection(
    address _receiver,
    string memory name,
    string memory symbol,
    Config calldata config,
    PayoutConfig calldata payoutConfig
  ) external payable returns (address) {
    bytes32 salt = keccak256(abi.encodePacked(block.timestamp, msg.sender, block.chainid));
    address clone = Clones.cloneDeterministic(archetype, salt);
    ArchetypeBurgers404 token = ArchetypeBurgers404(payable(clone));
    token.initialize(name, symbol, config, payoutConfig, _receiver);

    token.transferOwnership(_receiver);
    if (msg.value > 0) {
      (bool sent, ) = payable(_receiver).call{ value: msg.value }("");
      require(sent, "1");
    }
    emit CollectionAdded(_msgSender(), _receiver, clone);
    return clone;
  }

  function setArchetype(address archetype_) public onlyOwner {
    archetype = archetype_;
  }
}
