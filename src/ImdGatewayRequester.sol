// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IImdRequester} from "./interfaces/IImdRequester.sol";
import {IIntake} from "./interfaces/IIntake.sol";
import {ImdOracle} from "./ImdOracle.sol";

/// @notice What the Intake calls back on BriefsJury: its selector followed by complete()'s `args`, which IMD's writer
///         fills with abi.encode(requestId, AttestationV2, signature).
interface IBriefsAnswer {
    function onImdAnswer(bytes32 requestId, ImdOracle.AttestationV2 calldata att, bytes calldata signature) external;
}

interface ITreasury {
    function treasury() external view returns (address);
}

/// @title ImdGatewayRequester — Briefs' requester on IMD's Intake (Robinhood Chain)
/// @notice Each hearing pays the Intake's price for the oracle action in IMD and names Briefs' jury (BriefsJury) as the
///         callback. Naming the callback also makes IMD sign the answer for the jury's EIP-712 domain (IMD sets the
///         request's consumer to the callback target). The Intake calls BriefsJury.onImdAnswer with the answer; the
///         jury records it, and Briefs.fulfill later accepts that answer and no other.
///
///         Holds no IMD between calls: each request pulls the price from Briefs and passes it straight on.
contract ImdGatewayRequester is IImdRequester, Ownable2Step {
    using SafeERC20 for IERC20;

    IIntake public immutable intake;
    IERC20 public immutable imd;
    bytes32 public immutable action;
    address public client; // the only caller of request(): Briefs, set once after it is deployed

    event ClientSet(address client);

    error NotClient();
    error ZeroAddress();

    constructor(IIntake intake_, IERC20 imd_, bytes32 action_, address owner_) Ownable(owner_) {
        if (address(intake_) == address(0) || address(imd_) == address(0)) revert ZeroAddress();
        intake = intake_;
        imd = imd_;
        action = action_;
    }

    /// @notice Name the Briefs contract this requester serves. Once: it can never be pointed elsewhere.
    function setClient(address c) external onlyOwner {
        if (client != address(0) || c == address(0)) revert NotClient();
        client = c;
        emit ClientSet(c);
    }

    /// @notice The Intake's current price for the action, in IMD.
    function fee() external view returns (uint256) {
        return intake.priceOf(action, address(imd));
    }

    function answerSource() external view returns (address) {
        return address(intake);
    }

    /// @notice Open one oracle request; the answer comes back to `consumer` (Briefs' jury) through onImdAnswer.
    /// @return requestId the Intake's request id, the one its callback and complete() carry
    function request(string calldata input, address consumer) external returns (bytes32 requestId) {
        if (msg.sender != client) revert NotClient();
        uint256 price = intake.priceOf(action, address(imd));
        imd.safeTransferFrom(msg.sender, address(this), price);
        imd.forceApprove(address(intake), price);
        requestId = intake.request(
            action, bytes(input), IIntake.Callback(consumer, IBriefsAnswer.onImdAnswer.selector), address(imd), price
        );
        imd.forceApprove(address(intake), 0);
    }

    /// @notice IMD only passes through here; anything left (sent by mistake, or an Intake that took less than it
    ///         was offered) goes to the platform treasury of the Briefs it serves. Briefs' own funds never sit here.
    function sweep() external onlyOwner {
        if (client == address(0)) revert NotClient();
        imd.safeTransfer(ITreasury(client).treasury(), imd.balanceOf(address(this)));
    }

    /// @dev Ownership can be handed over (two-step) but never dropped.
    function renounceOwnership() public view override onlyOwner {
        revert ZeroAddress();
    }
}
