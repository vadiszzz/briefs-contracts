// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Stand-in for IMD and $OATH in tests.
contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s, address to) ERC20(n, s) {
        _mint(to, 1_000_000_000 ether);
    }
}
