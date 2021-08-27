// SPDX-License-Identifier: MIT
/**
 * WATER Token forked from open source code of DAM Token, Submitted for verification at Etherscan.io on 2020-05-08
 * Dam Token: https://github.com/Datamine-Crypto/white-paper/blob/master/contracts/dam.sol
*/

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/token/ERC777/IERC777.sol";
import "@openzeppelin/contracts/token/ERC777/IERC777Recipient.sol";
import "@openzeppelin/contracts/token/ERC777/IERC777Sender.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/introspection/IERC1820Registry.sol";
import "@openzeppelin/contracts/token/ERC777/ERC777.sol";


contract WATERToken is ERC777 {
    constructor () public ERC777("Waterwood WATER", "WATER", new address[](0)) {
        _mint(msg.sender, 1386000000 * (10 ** 18), "", "");
    }
}