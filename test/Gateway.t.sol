// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Briefs} from "../src/Briefs.sol";
import {BriefsText} from "../src/BriefsText.sol";
import {BriefsJury} from "../src/BriefsJury.sol";
import {ImdOracle} from "../src/ImdOracle.sol";
import {ImdGatewayRequester} from "../src/ImdGatewayRequester.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockIntake} from "./mocks/MockIntake.sol";

contract IntakeDigester {
    function digest(bytes32 domain, ImdOracle.AttestationV2 calldata a) external pure returns (bytes32) {
        return ImdOracle.digestV2(domain, a);
    }
}

/// Briefs on IMD's Intake: each hearing pays the Intake and names Briefs as the callback; the Intake delivers the
/// answer to the jury's onImdAnswer, and fulfill() lands that answer and no other.
contract GatewayTest is Test {
    // Briefs keeps the money and docket; its BriefsJury names itself as the Intake callback
    bytes32 constant ACTION = "oracle.request@oracle-1";
    MockERC20 imd;
    MockIntake intake;
    ImdGatewayRequester adapter;
    Briefs b;
    IntakeDigester dg = new IntakeDigester();
    uint256 key = 0xA77E57;
    address payee = makeAddr("imd-payee");
    address writer = makeAddr("imd-writer");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_790_800_000);
        imd = new MockERC20("IMD", "IMD", address(this));
        intake = new MockIntake(payee, writer);
        intake.setPrice(ACTION, address(imd), 0.5 ether);
        adapter = new ImdGatewayRequester(IIntake(address(intake)), IERC20(address(imd)), ACTION, address(this));
        BriefsJury jury = new BriefsJury(
            BriefsJury.Oracle({signer: vm.addr(key), requester: adapter, domain: bytes32(0), chainId: 1, hearingGas: 3_000_000}),
            address(this), address(0)
        );
        b = new Briefs(
            IERC20(address(imd)),
            new BriefsText(),
            jury,
            address(this),
            Briefs.Params({
                minSeed: 10 ether,
                minFee: 1 ether,
                maxOracleFee: 0.9 ether,
                creatorBps: 1_500,
                platformBps: 500,
                panelSize: 11,
                quorum: 6,
                answerTimeout: 4 minutes,
                caseFee: 2 ether,
                minDuration: 10 minutes,
                maxDuration: 90 days,
                maxBrief: 500
            })
        );
        adapter.setClient(address(b));
        address[3] memory users = [creator, alice, bob];
        for (uint256 i; i < users.length; i++) {
            imd.transfer(users[i], 10_000 ether);
            vm.prank(users[i]);
            imd.approve(address(b), type(uint256).max);
        }
    }

    function _case() internal returns (uint256) {
        vm.prank(creator);
        return b.openCase(
            Briefs.CaseInput({
                title: "Dragon Jokes",
                task: "Write the funniest joke about dragons.",
                standard: "The funnier brief wins.",
                opening: "Dragons never use banks. Too many firewalls.",
                avatar: 1,
                seed: 100 ether,
                fee: 2 ether,
                endsAt: uint64(block.timestamp + 1 days),
                minHold: 0
            })
        );
    }

    function _file(uint256 c, address who, string memory words) internal returns (uint256) {
        vm.prank(who);
        return b.fileBrief(c, words);
    }

    /// an attestation for the hearing's question, signed for Briefs' domain, with IMD's own request id
    function _answer(uint256 briefId, bool better, uint128 imdId) internal view returns (ImdOracle.AttestationV2 memory a, bytes memory sig) {
        a = ImdOracle.AttestationV2({
            requestId: bytes32(uint256(imdId) << 128),
            chainId: 1,
            questionHash: b.jury().questionHashOf(briefId, 26134774, 26141951),
            answerType: 0,
            answer: abi.encode(better),
            figure: 0,
            fromBlock: 26134774,
            toBlock: 26141951,
            blockHash: keccak256("b"),
            panelJobId: keccak256("p"),
            panelSize: 11,
            quorum: 6,
            agreed: 7,
            issuedAt: b.getBrief(briefId).heardAt + 120,
            expiresAt: uint64(block.timestamp + 1 days)
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, dg.digest(ImdOracle.domainSeparatorV("2", block.chainid, address(b.jury())), a));
        sig = abi.encodePacked(r, s, v);
    }

    /// what IMD's writer does: complete() with args = abi.encode(requestId, attestation, signature)
    function _complete(uint256 briefId, ImdOracle.AttestationV2 memory a, bytes memory sig) internal returns (bool delivered) {
        bytes32 rid = b.getBrief(briefId).requestId;
        vm.recordLogs();
        vm.prank(writer);
        intake.complete(rid, 0, keccak256("result"), "https://api.imd.fun/oracle/requests/x/attestation", abi.encode(rid, a, sig));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (,,, delivered) = abi.decode(logs[logs.length - 1].data, (uint8, bytes32, string, bool));
    }

    function test_AHearingPaysTheIntakeNamesBriefsAndTakesTheDeliveredAnswer() public {
        uint256 c = _case();
        vm.recordLogs();
        uint256 id = _file(c, alice, "A dragon walked into a bar. Now it is a barbecue.");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(intake) && logs[i].topics[0] == MockIntake.Requested.selector) {
                assertEq(logs[i].topics[0], 0x1c521a43c9b0f72a335bc80a6918abce08af7949ebbd1c41fe2a576074379063); // as live
                assertEq(logs[i].topics[1], b.getBrief(id).requestId); // Briefs keeps the Intake's id
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(adapter));
                (, address target, bytes4 selector,,) = abi.decode(logs[i].data, (bytes, address, bytes4, address, uint256));
                assertEq(target, address(b.jury())); // the jury takes the answer (and IMD signs for its domain)
                assertEq(selector, BriefsJury.onImdAnswer.selector);
                seen = true;
            }
        }
        assertTrue(seen);
        assertEq(imd.balanceOf(payee), 0.5 ether);
        assertEq(imd.balanceOf(address(adapter)), 0);

        vm.warp(block.timestamp + 2 minutes);
        (ImdOracle.AttestationV2 memory a, bytes memory sig) = _answer(id, true, 0x76ea04d9);
        vm.expectRevert(BriefsJury.NotDelivered.selector); // not delivered yet: nobody can land it early
        b.fulfill(id, a, sig);
        assertTrue(_complete(id, a, sig), "the callback ran within the Intake's 200k gas");
        assertEq(b.jury().delivered(address(intake), b.getBrief(id).requestId), keccak256(abi.encode(a)));
        b.fulfill(id, a, sig);
        assertEq(uint8(b.getBrief(id).status), uint8(Briefs.BriefStatus.Overruled));
    }

    /// FIXED (answer shopping): another genuine IMD answer to the same question can't replace the delivered one
    function test_AnAnswerBoughtElsewhereIsRefused() public {
        uint256 c = _case();
        uint256 id = _file(c, alice, "My brief");
        vm.warp(block.timestamp + 2 minutes);
        (ImdOracle.AttestationV2 memory ours, bytes memory ourSig) = _answer(id, false, 0x11);
        (ImdOracle.AttestationV2 memory bought, bytes memory boughtSig) = _answer(id, true, 0x22); // same question, signed by IMD
        vm.expectRevert(BriefsJury.NotDelivered.selector);
        b.fulfill(id, bought, boughtSig);
        _complete(id, ours, ourSig);
        vm.expectRevert(BriefsJury.NotDelivered.selector);
        b.fulfill(id, bought, boughtSig);
        b.fulfill(id, ours, ourSig);
        assertEq(uint8(b.getBrief(id).status), uint8(Briefs.BriefStatus.Sustained));
    }

    /// anyone can call onImdAnswer, but it only records what the caller delivered: the hearing reads the Intake's
    function test_OnlyTheIntakesDeliveryCounts() public {
        uint256 c = _case();
        uint256 id = _file(c, alice, "My brief");
        vm.warp(block.timestamp + 2 minutes);
        (ImdOracle.AttestationV2 memory a, bytes memory sig) = _answer(id, true, 0x33);
        bytes32 rid = b.getBrief(id).requestId;
        BriefsJury jury = b.jury();
        vm.prank(bob);
        jury.onImdAnswer(rid, a, sig); // bob "delivers" for the real request id
        assertEq(jury.delivered(bob, rid), keccak256(abi.encode(a)));
        vm.expectRevert(BriefsJury.NotDelivered.selector);
        b.fulfill(id, a, sig);
        assertTrue(_complete(id, a, sig));
        b.fulfill(id, a, sig);
        assertEq(uint8(b.getBrief(id).status), uint8(Briefs.BriefStatus.Overruled));
    }

    function test_NoAnswerMeansAMistrial() public {
        uint256 c = _case();
        uint256 id1 = _file(c, alice, "First");
        uint256 id2 = _file(c, bob, "Second");
        vm.warp(block.timestamp + 4 minutes + 2 minutes + 1);
        b.mistrial(c);
        assertEq(uint8(b.getBrief(id1).status), uint8(Briefs.BriefStatus.Mistrial));
        assertEq(uint8(b.getBrief(id2).status), uint8(Briefs.BriefStatus.Hearing));
        assertEq(imd.balanceOf(payee), 1 ether);
    }

    function test_FeeFollowsTheIntake_UpToTheCaseReserve() public {
        uint256 c = _case();
        uint256 id1 = _file(c, alice, "First"); // heard at 0.5
        uint256 id2 = _file(c, bob, "Second"); // queued
        intake.setPrice(ACTION, address(imd), 0.6 ether); // IMD raises its price, still within the case's 0.9 reserve
        assertEq(adapter.fee(), 0.6 ether);
        vm.warp(block.timestamp + 2 minutes);
        (ImdOracle.AttestationV2 memory a, bytes memory sig) = _answer(id1, false, 0x44);
        _complete(id1, a, sig);
        b.fulfill(id1, a, sig);
        assertEq(uint8(b.getBrief(id2).status), uint8(Briefs.BriefStatus.Hearing)); // heard at the new price
        assertEq(b.getBrief(id2).oracleReserve, 0.6 ether);
        uint256 id3 = _file(c, alice, "Third"); // queued
        intake.setPrice(ACTION, address(imd), 1 ether); // above the reserve: id3 is not heard, its whole fee goes back
        vm.warp(block.timestamp + 2 minutes);
        (a, sig) = _answer(id2, false, 0x45);
        _complete(id2, a, sig);
        uint256 before = imd.balanceOf(alice);
        b.fulfill(id2, a, sig);
        assertEq(uint8(b.getBrief(id3).status), uint8(Briefs.BriefStatus.Unheard));
        assertEq(imd.balanceOf(alice), before + 2 ether);
        assertEq(imd.balanceOf(payee), 1.1 ether);
    }

    function test_OnlyBriefsMayRequest_AndTheClientIsSetOnce() public {
        imd.approve(address(adapter), 1 ether);
        vm.expectRevert(ImdGatewayRequester.NotClient.selector);
        adapter.request("{}", address(this));
        vm.expectRevert(ImdGatewayRequester.NotClient.selector);
        adapter.setClient(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        adapter.transferOwnership(alice);
    }

    /// the live Intake only calls back when the writer reports status 0: anything else is no answer, so a mistrial
    function test_NoCallbackOnAFailedStatus_MeansAMistrial() public {
        uint256 c = _case();
        uint256 id = _file(c, alice, "My brief");
        vm.warp(block.timestamp + 2 minutes);
        (ImdOracle.AttestationV2 memory a, bytes memory sig) = _answer(id, true, 0x55);
        bytes32 rid = b.getBrief(id).requestId;
        vm.prank(writer);
        intake.complete(rid, 2, bytes32(0), "", abi.encode(rid, a, sig));
        vm.expectRevert(BriefsJury.NotDelivered.selector);
        b.fulfill(id, a, sig);
        vm.warp(block.timestamp + 4 minutes + 1);
        uint256 before = imd.balanceOf(alice);
        b.mistrial(c);
        assertEq(uint8(b.getBrief(id).status), uint8(Briefs.BriefStatus.Mistrial));
        assertEq(imd.balanceOf(alice), before + 2 ether - 0.5 ether); // the fee back, less IMD's price
    }

    /// ids follow the live Intake's formula, so the keeper and tests can predict them
    function test_RequestIdsFollowTheIntakesFormula() public {
        uint256 c = _case();
        uint256 id = _file(c, alice, "My brief");
        assertEq(b.getBrief(id).requestId, keccak256(abi.encode(block.chainid, address(intake), uint256(1))));
    }

    /// an Intake setup can't pin a domain: IMD signs for the callback's domain, so answers would never verify
    function test_Jury_RefusesAPinnedDomainWithAnIntake() public {
        BriefsJury.Oracle memory o =
            BriefsJury.Oracle({signer: vm.addr(key), requester: adapter, domain: bytes32(uint256(1)), chainId: 1, hearingGas: 3_000_000});
        BriefsJury jury = b.jury();
        vm.expectRevert(BriefsJury.BadOracle.selector);
        jury.proposeOracle(o);
        vm.expectRevert(BriefsJury.BadOracle.selector);
        new BriefsJury(o, address(this), address(0));
    }

    /// a proposed setup nobody applied lapses ORACLE_WINDOW after it was ready
    function test_Jury_AnOldProposalLapses() public {
        BriefsJury jury = b.jury();
        BriefsJury.Oracle memory o =
            BriefsJury.Oracle({signer: vm.addr(key), requester: adapter, domain: bytes32(0), chainId: 1, hearingGas: 3_000_000});
        jury.proposeOracle(o);
        uint256 ready = jury.readyAt();
        vm.warp(ready + 7 days + 1);
        vm.expectRevert(BriefsJury.Lapsed.selector);
        jury.applyOracle();
        vm.warp(ready + 7 days);
        jury.applyOracle();
        assertEq(jury.count(), 2);
    }

    /// stray IMD on the adapter can only go to the platform treasury of its Briefs
    function test_SweepGoesToTheTreasury() public {
        imd.transfer(address(adapter), 3 ether);
        address t = makeAddr("treasury");
        b.setTreasury(t);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        adapter.sweep();
        adapter.sweep();
        assertEq(imd.balanceOf(t), 3 ether);
        assertEq(imd.balanceOf(address(adapter)), 0);
    }

    /// once the Intake has delivered an answer, nobody who dislikes it can race the keeper with a mistrial for an hour
    function test_ADeliveredAnswerHoldsOffTheMistrial() public {
        uint256 c = _case();
        uint256 id = _file(c, alice, "My brief");
        vm.warp(block.timestamp + 2 minutes);
        (ImdOracle.AttestationV2 memory a, bytes memory sig) = _answer(id, false, 0x66);
        assertTrue(_complete(id, a, sig));
        assertTrue(b.jury().wasDelivered(id));
        vm.warp(b.getBrief(id).heardAt + 4 minutes + 2 minutes + 1); // past the usual grace
        vm.prank(alice); // the losing author
        vm.expectRevert(Briefs.TooEarly.selector);
        b.mistrial(c);
        b.fulfill(id, a, sig); // the keeper lands it
        assertEq(uint8(b.getBrief(id).status), uint8(Briefs.BriefStatus.Sustained));
    }

    /// an answer delivered but never landable still ends in a mistrial, an hour after the timeout
    function test_ADeliveredButUnlandableAnswerStillEndsInAMistrial() public {
        uint256 c = _case();
        uint256 id = _file(c, alice, "My brief");
        vm.warp(block.timestamp + 2 minutes);
        (ImdOracle.AttestationV2 memory a, bytes memory sig) = _answer(id, false, 0x67);
        a.agreed = 3; // below quorum: the jury refuses it
        (uint8 v, bytes32 r, bytes32 s_) = vm.sign(key, dg.digest(ImdOracle.domainSeparatorV("2", block.chainid, address(b.jury())), a));
        sig = abi.encodePacked(r, s_, v);
        _complete(id, a, sig);
        vm.expectRevert(BriefsJury.WrongPanel.selector);
        b.fulfill(id, a, sig);
        vm.warp(b.getBrief(id).heardAt + 4 minutes + 1 hours);
        vm.expectRevert(Briefs.TooEarly.selector);
        b.mistrial(c);
        vm.warp(block.timestamp + 1);
        b.mistrial(c);
        assertEq(uint8(b.getBrief(id).status), uint8(Briefs.BriefStatus.Mistrial));
    }
}
