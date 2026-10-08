// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IImdRequester — how Briefs opens an IdentityMD oracle request
/// @notice Briefs only needs "open a request for this input, pay in IMD, get an id back". On Robinhood Chain this is
///         ImdGatewayRequester on IMD's Intake; in tests and on the testnet, a mock.
interface IImdRequester {
    /// @notice IMD charged per request, pulled from the caller with transferFrom.
    function fee() external view returns (uint256);

    /// @notice Open an oracle request. `input` is the JSON body of an IMD `oracle.request`.
    /// @return requestId the IMD request id, as signed later in the attestation
    function request(string calldata input, address consumer) external returns (bytes32 requestId);

    /// @notice The contract that calls BriefsJury.onImdAnswer with each request's answer (IMD's Intake), or address(0)
    ///         when answers are only brought to fulfill() by anyone (tests, the testnet mock).
    function answerSource() external view returns (address);
}
