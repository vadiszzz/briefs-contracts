// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ImdOracle} from "../src/ImdOracle.sol";

contract V2LiveHarness {
    function recover(ImdOracle.AttestationV2 calldata a, bytes calldata sig) external pure returns (address) {
        return ECDSA.recover(ImdOracle.digestV2(ImdOracle.domainSeparatorV("2", 1, address(0)), a), sig);
    }

    function decode(bytes calldata answer) external pure returns (bool ok, bool value) {
        return ImdOracle.decodeBool(answer);
    }
}

/// Real v2 attestations from IdentityMD on Ethereum mainnet (2026-10-01, 5/4 panels, signer 0x5598…2982),
/// fetched by the panel probe. The contract's own EIP-712 encoding must recover IMD's attester from them.
contract V2LiveTest is Test {
    address constant IMD_ATTESTER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;

    function _att(bytes32 rq, bytes32 qh, bool yes, uint64 fromB, uint64 toB, bytes32 bh, bytes32 job, uint64 issued)
        internal
        pure
        returns (ImdOracle.AttestationV2 memory)
    {
        return ImdOracle.AttestationV2({
            requestId: rq, chainId: 1, questionHash: qh, answerType: 0, answer: abi.encode(yes), figure: 0,
            fromBlock: fromB, toBlock: toB, blockHash: bh, panelJobId: job, panelSize: 5, quorum: 4, agreed: 4,
            issuedAt: issued, expiresAt: issued + 86400
        });
    }

    function test_LiveNoVerdictRecoversImdAttester() public {
        V2LiveHarness h = new V2LiveHarness();
        ImdOracle.AttestationV2 memory a = _att(
            0x4e420ddd9fa445a280be8aef9e3cb1db00000000000000000000000000000000,
            0x87dee637bd9b81088783a8401cdbbf9952b86d9a9dae9aa63c8de2f2732d4800,
            false, 26097771, 26098071,
            0x411470eb05ed62227d96019f2046a7e0ea910d67838006f6d2d96033281b7a64,
            0x17ef0fbb4e31487ea5ef3c6ffdd07b3a00000000000000000000000000000000,
            1790865146
        );
        bytes memory sig = hex"5e9ed0ae884cbc621a8c9ca496b287f226fbfdb59478e603cfd09767fb4acd0b0b003c3304576ec620893b6fc8243b16d66305a9a857a101165d549569e160e21c";
        assertEq(h.recover(a, sig), IMD_ATTESTER);
        (bool ok, bool yes) = h.decode(a.answer);
        assertTrue(ok);
        assertFalse(yes);
    }

    function test_LiveYesVerdictRecoversImdAttester() public {
        V2LiveHarness h = new V2LiveHarness();
        ImdOracle.AttestationV2 memory a = _att(
            0xffc901326ad84637b798fe7723c2a96300000000000000000000000000000000,
            0x77009172e381aa0c1e5db0fe5bc2888c2bfb078d038b2c99a7975d7ffe3dd5c7,
            true, 26097775, 26098075,
            0x4767a5efd724dba0f441d78c5853fabc6a685607f9dca8a361e65e6bf1f62a3b,
            0x193a58a075f54170ade630a8fca83f3a00000000000000000000000000000000,
            1790865176
        );
        bytes memory sig = hex"e2ed8d8218c5232c4c7abcf99e9a3ed1a61ced32585d1859fb1f01b4f07663653aabf026b8884e8671bdb8c3f8c144e7c6d88f2fa77683936db71c4baa3cefd71b";
        assertEq(h.recover(a, sig), IMD_ATTESTER);
        (bool ok, bool yes) = h.decode(a.answer);
        assertTrue(ok);
        assertTrue(yes);
        // a single changed field breaks the signature
        a.agreed = 5;
        assertTrue(h.recover(a, sig) != IMD_ATTESTER);
    }
}
