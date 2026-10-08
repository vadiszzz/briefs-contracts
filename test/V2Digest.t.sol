// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {ImdOracle} from "../src/ImdOracle.sol";

contract V2DigestHarness {
    function digest(bytes32 domain, ImdOracle.AttestationV2 calldata a) external pure returns (bytes32) {
        return ImdOracle.digestV2(domain, a);
    }
}

/// Independent check of the v2 EIP-712 encoding: viem's hashTypedData over the same message must give
/// V2_DIGEST (computed independently with viem.hashTypedData).
contract V2DigestTest is Test {
    bytes32 constant V2_DIGEST = 0x28fe262e0896eb1777dc4440203f5bf4a460988b8df99e04f17da68aeeed675e;

    function test_V2DigestMatchesViem() public {
        V2DigestHarness h = new V2DigestHarness();
        ImdOracle.AttestationV2 memory a = ImdOracle.AttestationV2({
            requestId: 0x3e184f85b9ca4453aac322130ed3fbc000000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x88dec27ba62069d0524719adcd6e53e8385cc076becdd17f8b6d71c904d6b518,
            answerType: 0,
            answer: abi.encode(true),
            figure: 0,
            fromBlock: 23_000_000,
            toBlock: 23_000_300,
            blockHash: 0xc4f9ad7b95a6872d3533fd510ab9ef4897dce8c3974a53c63b7c7a70af6e677d,
            panelJobId: 0x4a408f04c83446b3b6e3a73c72a6fb3c00000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: 1_790_800_000,
            expiresAt: 1_790_886_400
        });
        bytes32 d = h.digest(ImdOracle.domainSeparatorV("2", 1, address(0)), a);
        console.logBytes32(d);
        if (V2_DIGEST != bytes32(0)) assertEq(d, V2_DIGEST);
    }
}
