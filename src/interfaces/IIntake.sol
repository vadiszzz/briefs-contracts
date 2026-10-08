// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IIntake — the part of IMD's on-chain Intake that Briefs uses
/// @notice IMD's Intake on Robinhood Chain: 0x1397434cd35e8a9c8ac312a61d3a285eb31dea56 (ABI from the IMD team,
///         October 2026). A request pays the action's price in `asset` (transferFrom the caller) and names a callback;
///         IMD's writer later calls complete(requestId, status, resultHash, uri, args) and the Intake calls
///         callback.target with callback.selector and `args` (abi.encode(requestId, AttestationV2, signature)),
///         giving it callbackGas (200k at launch).
interface IIntake {
    struct Callback {
        address target;
        bytes4 selector;
    }

    function request(bytes32 action, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        payable
        returns (bytes32 requestId);

    function priceOf(bytes32 action, address asset) external view returns (uint256 amount);

    function callbackGas() external view returns (uint64);
}
