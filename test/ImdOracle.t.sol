// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ImdOracle} from "../src/ImdOracle.sol";

contract OracleHarness {
    function digest(ImdOracle.Attestation calldata a) external pure returns (bytes32) {
        return ImdOracle.digest(ImdOracle.domainSeparator(1, address(0)), a);
    }

    function qhash(string calldata q, string calldata d, uint64 f, uint64 t) external pure returns (bytes32) {
        return ImdOracle.boolPanelQuestionHash(q, d, f, t);
    }
}

/// Real, live data from api.imd.fun — request 3e184f85-b9ca-4453-aac3-22130ed3fbc0.
contract ImdOracleTest is Test {
    address constant IMD_ATTESTER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    string constant QUESTION = "Is Australia a constitutional monarchy?";
    string constant DEFINITIONS =
        '{"answer":"true or false","missing":"If you cannot establish the fact from a source, report that; do not guess.","source":"Answer from a reputable public source you actually read (an official government, parliament or electoral-commission site, the text of a treaty or constitution, Britannica, or a major news archive) and name it.","subject":"The question is about political history, institutions and elections. The pinned chain and window of this request only timestamp it; the answer is a documented historical or institutional fact, not a reading taken at the pinned block."}';
    bytes32 constant QHASH = 0x88dec27ba62069d0524719adcd6e53e8385cc076becdd17f8b6d71c904d6b518;

    OracleHarness h = new OracleHarness();

    function _real() internal pure returns (ImdOracle.Attestation memory) {
        return ImdOracle.Attestation({
            requestId: 0x3e184f85b9ca4453aac322130ed3fbc000000000000000000000000000000000,
            chainId: 1,
            questionHash: QHASH,
            answerType: 0,
            answer: abi.encode(true),
            figure: 0,
            fromBlock: 26049507,
            toBlock: 26049805,
            blockHash: 0xc4f9ad7b95a6872d3533fd510ab9ef4897dce8c3974a53c63b7c7a70af6e677d,
            panelJobId: 0x4a408f04c83446b3b6e3a73c72a6fb3c00000000000000000000000000000000,
            issuedAt: 1790298458,
            expiresAt: 1790903258
        });
    }

    function test_QuestionHashMatchesLiveRequest() public view {
        assertEq(h.qhash(QUESTION, DEFINITIONS, 26049507, 26049805), QHASH);
    }

    function test_QuestionHashChangesWithText() public view {
        assertTrue(h.qhash("Is Australia a republic?", DEFINITIONS, 26049507, 26049805) != QHASH);
        assertTrue(h.qhash(QUESTION, DEFINITIONS, 26049507, 26049806) != QHASH);
    }

    function test_LiveSignatureRecoversAttester() public view {
        bytes memory sig =
            hex"8d5017746c9c50d0d80b13256d3d0c92d4e945ae43fca7badf24bae5392b9bb343f9c31315a62626492bec1802de3c58ff9159a5bd010f5373a221d6f77f4cb31c";
        assertEq(ECDSA.recover(h.digest(_real()), sig), IMD_ATTESTER);
    }
}
