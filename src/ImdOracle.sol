// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title ImdOracle — verify IdentityMD (imd.fun) oracle answers on chain
/// @notice The IMD attester signs an EIP-712 `OracleAttestation`. Its `questionHash` is
///         keccak256 of the canonical JSON of the request: keys sorted, no whitespace, over
///         {answerType, chainId, definitions, evidence, question, v, window{fromBlock,toBlock}}.
///         Rebuilding that JSON here ties a signed answer to the exact question text, so a
///         contract knows what the swarm was asked, not just that it answered something.
///         Reverse-engineered from live requests and checked against real signatures in the tests.
library ImdOracle {
    struct Attestation {
        bytes32 requestId;
        uint256 chainId;
        bytes32 questionHash;
        uint8 answerType;
        bytes answer;
        uint256 figure;
        uint64 fromBlock;
        uint64 toBlock;
        bytes32 blockHash;
        bytes32 panelJobId;
        uint64 issuedAt;
        uint64 expiresAt;
    }

    uint8 internal constant ANSWER_TYPE_BOOL = 0; // "bool" is 0 in the signed message

    bytes32 internal constant ATTESTATION_TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint64 issuedAt,uint64 expiresAt)"
    );

    /// @dev Domain of attestations requested without a `consumer`: chainId 1, verifyingContract 0x0.
    function domainSeparator(uint256 chainId, address verifyingContract) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("IdentityMD Oracle"),
                keccak256("1"),
                chainId,
                verifyingContract
            )
        );
    }

    function digest(bytes32 domain, Attestation calldata a) internal pure returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                ATTESTATION_TYPEHASH,
                a.requestId,
                a.chainId,
                a.questionHash,
                a.answerType,
                keccak256(a.answer),
                a.figure,
                a.fromBlock,
                a.toBlock,
                a.blockHash,
                a.panelJobId,
                a.issuedAt,
                a.expiresAt
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    // ------------------------------------------------------------ v2: the panel is signed too

    /// @notice v2 attestation (EIP-712 domain version "2"): v1 plus the panel that answered, signed right
    ///         after panelJobId. Announced by the IMD team; verify against a live v2 attestation before use.
    struct AttestationV2 {
        bytes32 requestId;
        uint256 chainId;
        bytes32 questionHash;
        uint8 answerType;
        bytes answer;
        uint256 figure;
        uint64 fromBlock;
        uint64 toBlock;
        bytes32 blockHash;
        bytes32 panelJobId;
        uint16 panelSize; // seats the request opened
        uint16 quorum; // answers required to agree
        uint16 agreed; // members who gave the signed answer
        uint64 issuedAt;
        uint64 expiresAt;
    }

    bytes32 internal constant ATTESTATION_V2_TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
    );

    function domainSeparatorV(string memory version, uint256 chainId, address verifyingContract)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("IdentityMD Oracle"),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );
    }

    function digestV2(bytes32 domain, AttestationV2 calldata a) internal pure returns (bytes32) {
        bytes32 structHash = keccak256(
            bytes.concat(
                abi.encode(
                    ATTESTATION_V2_TYPEHASH,
                    a.requestId,
                    a.chainId,
                    a.questionHash,
                    a.answerType,
                    keccak256(a.answer),
                    a.figure,
                    a.fromBlock,
                    a.toBlock,
                    a.blockHash,
                    a.panelJobId
                ),
                abi.encode(a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    /// @notice questionHash of a bool, panel-evidence question on chainId 1.
    /// @param question the question, already valid inside a JSON string (no `"`, `\` or control bytes)
    /// @param definitionsJson the canonical JSON object of definitions (keys sorted, no whitespace)
    function boolPanelQuestionHash(
        string memory question,
        string memory definitionsJson,
        uint64 fromBlock,
        uint64 toBlock
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                '{"answerType":"bool","chainId":1,"definitions":',
                definitionsJson,
                ',"evidence":"panel","question":"',
                question,
                '","v":1,"window":{"fromBlock":',
                Strings.toString(fromBlock),
                ',"toBlock":',
                Strings.toString(toBlock),
                "}}"
            )
        );
    }

    /// @dev A bool answer is abi.encode(bool): 32 bytes, 0 or 1.
    function decodeBool(bytes calldata answer) internal pure returns (bool ok, bool value) {
        if (answer.length != 32) return (false, false);
        uint256 v = uint256(bytes32(answer));
        if (v > 1) return (false, false);
        return (true, v == 1);
    }
}
