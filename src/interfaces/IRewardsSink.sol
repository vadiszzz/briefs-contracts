// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IRewardsSink — a future receiver of part of the platform's share
/// @notice Not used at launch (the platform keeps 100% of its share). A sink is set later, after a public delay,
///         and receives at most half of the platform's share, in IMD. It never sees pots or creator earnings.
interface IRewardsSink {
    /// @notice `amount` IMD is approved to the sink for this call only: the sink pulls it with transferFrom.
    ///         Whatever it does not pull (or if it reverts) goes to the treasury instead.
    function notifyReward(uint256 amount) external;
}
