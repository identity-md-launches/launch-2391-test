// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Local-only token with recipient failure injection for fee-delivery resilience tests.
contract MockIMD is ERC20 {
    mapping(address => bool) public rejected;

    constructor() ERC20("Identity.md", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function reject(address recipient, bool value) external {
        rejected[recipient] = value;
    }

    function _update(address from, address to, uint256 amount) internal override {
        require(!rejected[to], "recipient rejects IMD");
        super._update(from, to, amount);
    }
}
