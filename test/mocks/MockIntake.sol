// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IIntake} from "../../src/interfaces/IIntake.sol";

/// Stand-in for IMD's Intake, after its ABI and its deployed bytecode (Robinhood Chain, read 7 Oct 2026):
/// request() takes the price to payTo, ids are keccak256(chainid, intake, ++nonce); the writer's complete() calls
/// callback.target with abi.encodePacked(selector, args) and callbackGas, only when status == 0 and the target has code,
/// after checking gasleft >= callbackGas + callbackGas / 63 + 20000.
contract MockIntake is IIntake {
    struct Req {
        address payer;
        address callbackTarget;
        bytes4 callbackSelector;
        bool completed;
    }

    address public immutable payTo;
    address public writer;
    uint64 public callbackGas = 200_000;
    uint256 public nonce;
    mapping(bytes32 => mapping(address => uint256)) internal prices;
    mapping(bytes32 => Req) public requests;

    event Requested(bytes32 indexed requestId, address indexed payer, bytes32 indexed action, bytes body, address callbackTarget, bytes4 callbackSelector, address asset, uint256 amount);
    event Completed(bytes32 indexed requestId, uint8 status, bytes32 resultHash, string uri, bool delivered);

    error ActionNotSold(bytes32 action, address asset);
    error PriceNotMet(uint256 price, uint256 amount);
    error NotWriter();
    error AlreadyCompleted(bytes32 requestId);
    error UnknownRequest(bytes32 requestId);
    error CallbackGasShort(uint256 needed, uint256 left);

    constructor(address payTo_, address writer_) {
        payTo = payTo_;
        writer = writer_;
    }

    function setPrice(bytes32 action, address asset, uint256 amount) external {
        prices[action][asset] = amount;
    }

    function setCallbackGas(uint64 g) external {
        callbackGas = g;
    }

    function priceOf(bytes32 action, address asset) external view returns (uint256) {
        return prices[action][asset];
    }

    function request(bytes32 action, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        payable
        returns (bytes32 requestId)
    {
        uint256 price = prices[action][asset];
        if (price == 0) revert ActionNotSold(action, asset);
        if (amount < price) revert PriceNotMet(price, amount);
        IERC20(asset).transferFrom(msg.sender, payTo, amount);
        requestId = keccak256(abi.encode(block.chainid, address(this), ++nonce));
        requests[requestId] = Req(msg.sender, callback.target, callback.selector, false);
        emit Requested(requestId, msg.sender, action, body, callback.target, callback.selector, asset, amount);
    }

    function complete(bytes32 requestId, uint8 status, bytes32 resultHash, string calldata uri, bytes calldata args)
        external
    {
        if (msg.sender != writer) revert NotWriter();
        Req storage r = requests[requestId];
        if (r.payer == address(0)) revert UnknownRequest(requestId);
        if (r.completed) revert AlreadyCompleted(requestId);
        r.completed = true;
        bool delivered;
        if (status == 0 && r.callbackTarget != address(0)) {
            uint256 needed = uint256(callbackGas) + callbackGas / 63 + 20_000;
            if (gasleft() < needed) revert CallbackGasShort(needed, gasleft());
            if (r.callbackTarget.code.length != 0) {
                (delivered,) = r.callbackTarget.call{gas: callbackGas}(abi.encodePacked(r.callbackSelector, args));
            }
        }
        emit Completed(requestId, status, resultHash, uri, delivered);
    }
}
