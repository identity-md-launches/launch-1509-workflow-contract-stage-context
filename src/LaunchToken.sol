// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice The factory's plain, fixed-supply launch token. All supply is minted exactly once.
contract LaunchToken is ERC20 {
    constructor() ERC20("PONZIRAMID", "PONZIRAM") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
