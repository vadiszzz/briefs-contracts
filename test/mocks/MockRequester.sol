// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IImdRequester} from "../../src/interfaces/IImdRequester.sol";

/// A stand-in for IMD's on-chain request contract: takes the fee, records the input, returns a request id
/// shaped like IMD's (a UUID left-aligned in bytes32).
contract MockRequester is IImdRequester {
    IERC20 public immutable imd;
    uint256 internal fee_;
    uint256 public count;
    bytes32 public lastInputHash; // only the hash: storing the text would dwarf the gas we want to measure
    event Requested(bytes32 requestId, string input);
    address public lastConsumer;
    bool public greedy; // takes more than it quoted
    bool public broken; // reverts every request
    bool public brokenFee; // fee() reverts
    bool public shortFee; // fee() returns one byte instead of a uint256
    bool public shortSource; // answerSource() returns one byte instead of an address

    constructor(IERC20 imd_, uint256 fee__) {
        imd = imd_;
        fee_ = fee__;
    }

    function answerSource() external view returns (address) {
        if (shortSource) assembly { return(0, 1) }
        return address(0);
    }

    function fee() external view returns (uint256) {
        require(!brokenFee, "fee down");
        if (shortFee) assembly { return(0, 1) }
        return fee_;
    }

    function setShort(bool fee__, bool source) external {
        shortFee = fee__;
        shortSource = source;
    }

    function setFee(uint256 f) external {
        fee_ = f;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function setBrokenFee(bool b) external {
        brokenFee = b;
    }

    function setGreedy(bool g) external {
        greedy = g;
    }

    function request(string calldata input, address consumer) external returns (bytes32 requestId) {
        require(!broken, "requester down");
        imd.transferFrom(msg.sender, address(this), greedy ? fee_ + 1 : fee_);
        lastInputHash = keccak256(bytes(input));
        lastConsumer = consumer;
        requestId = bytes32(uint256(keccak256(abi.encode(address(this), ++count))) << 128);
        emit Requested(requestId, input);
    }
}
