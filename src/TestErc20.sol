// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TestErc20 is ERC20 {
    constructor() ERC20("Token", "TKN") {}

    function mint(uint256 quantity) public {
        _mint(msg.sender, quantity);
    }
}
