// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Briefs} from "../../src/Briefs.sol";

/// CaseInput.terms for a court's settings: what openCase compares with the settings it finds
library Terms {
    function pack(Briefs.Params memory p) internal pure returns (uint256) {
        return uint256(p.panelSize) | uint256(p.quorum) << 16 | uint256(p.answerTimeout) << 32 | uint256(p.maxBrief) << 64
            | uint256(p.maxOracleFee) << 80;
    }
}
