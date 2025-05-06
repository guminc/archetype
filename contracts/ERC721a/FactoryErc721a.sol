// SPDX-License-Identifier: BUSL-1.1
// Factory v0.8.1
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

import "./ArchetypeErc721a.sol";
import "./ArchetypeLogicErc721a.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

error InsufficientDeployFee();

contract FactoryErc721a is Ownable {
  event CollectionAdded(address indexed sender, address indexed receiver, address collection);
  event DeployFeeChanged(uint256 oldFee, uint256 newFee);
  
  address public archetype;
  uint256 public deployFee;
  
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
    if (msg.value < deployFee) {
      revert InsufficientDeployFee();
    }
    
    bytes32 salt = keccak256(abi.encodePacked(block.timestamp, msg.sender, block.chainid));
    address clone = Clones.cloneDeterministic(archetype, salt);
    ArchetypeErc721a token = ArchetypeErc721a(clone);
    token.initialize(name, symbol, config, payoutConfig, _receiver);
    token.transferOwnership(_receiver);
    
    if (deployFee > 0) {
      address[] memory recipients = new address[](1);
      recipients[0] = PLATFORM;
      uint16[] memory splits = new uint16[](1);
      splits[0] = 10000;
      ArchetypePayouts(PAYOUTS).updateBalances{value: deployFee}(
        deployFee,
        address(0), // native token
        recipients,
        splits
      );
      
      // Forward any excess payment to the receiver
      uint256 excess = msg.value - deployFee;
      if (excess > 0) {
        _refund(_receiver, excess);
      }
    } else if (msg.value > 0) {
      _refund(_receiver, msg.value);
    }
    
    emit CollectionAdded(_msgSender(), _receiver, clone);
    return clone;
  }
  
  function setArchetype(address archetype_) public onlyOwner {
    archetype = archetype_;
  }
  
  function setDeployFee(uint256 newFee) public onlyOwner {
    uint256 oldFee = deployFee;
    deployFee = newFee;
    emit DeployFeeChanged(oldFee, newFee);
  }

  function _refund(address to, uint256 refund) internal {
    (bool success, ) = payable(to).call{ value: refund }("");
    if (!success) {
      revert TransferFailed();
    }
  }
}