// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

struct Users {
    // Owner of Protocol
    address payable owner;
    // Protocol treasury receiving protocol fees
    address payable treasury;
    // Creator of Meme
    address payable creator;
    // Buyer of Memes 1
    address payable buyerOne;
    // Buyer of Memes 2
    address payable buyerTwo;
    // Buyer of Memes 1
    address payable buyerThree;
}
