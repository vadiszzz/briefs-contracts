// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Briefs} from "../src/Briefs.sol";
import {BriefsText} from "../src/BriefsText.sol";
import {BriefsJury, IBriefsCourt} from "../src/BriefsJury.sol";
import {ImdOracle} from "../src/ImdOracle.sol";
import {IImdRequester} from "../src/interfaces/IImdRequester.sol";
import {IRewardsSink} from "../src/interfaces/IRewardsSink.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockRequester} from "./mocks/MockRequester.sol";

contract Digester {
    function digest(bytes32 domain, ImdOracle.AttestationV2 calldata a) external pure returns (bytes32) {
        return ImdOracle.digestV2(domain, a);
    }
}

contract Sink is IRewardsSink {
    uint256 public notified;
    bool public broken;

    function setBroken(bool b_) external {
        broken = b_;
    }

    function notifyReward(uint256 amount) external {
        require(!broken, "sink down");
        IERC20(Briefs(msg.sender).imd()).transferFrom(msg.sender, address(this), amount);
        notified += amount;
    }
}

/// a requester whose request() burns a lot of gas (stores the input), to test out-of-gas griefing
contract HeavyRequester is IImdRequester {
    IERC20 public immutable imd;
    uint256 public count;
    mapping(uint256 => string) public inputs;

    constructor(IERC20 imd_) {
        imd = imd_;
    }

    function answerSource() external pure returns (address) {
        return address(0);
    }

    function fee() external pure returns (uint256) {
        return 0.5 ether;
    }

    function request(string calldata input, address) external returns (bytes32) {
        imd.transferFrom(msg.sender, address(this), 0.5 ether);
        inputs[++count] = input;
        return bytes32(uint256(keccak256(abi.encode(address(this), count))) << 128);
    }
}

contract BriefsTest is Test {
    Digester digester = new Digester();
    string constant TITLE = "Dragon Jokes";
    string constant TASK = "Write the funniest joke about dragons.";
    string constant STANDARD = "The funnier brief wins.";
    string constant OPENING = "Dragons never use banks. Too many firewalls.";
    string constant B1 = unicode"A dragon walked into a bar. The bar is now a barbecue. 🐉";
    string constant B2 = "My dragon asked for a raise. HR said to stop burning through the budget.";

    uint256 constant ORACLE_FEE = 0.5 ether;
    uint256 constant SEED = 500 ether;
    uint256 constant FEE = 5 ether;
    uint256 constant CASE_FEE = 2 ether; // flat price of opening a case, to the treasury
    // 5 - 0.5 = 4.5: creator 15% 0.675, platform 5% 0.225, pot 80% 3.6
    uint256 constant TO_POT = 3.6 ether;
    uint256 constant TO_CREATOR = 0.675 ether;
    uint256 constant TO_PLATFORM = 0.225 ether;

    MockERC20 imd;
    MockRequester requester;
    Briefs b;
    uint32 oid; // the setup new cases name (jury.latest())
    BriefsJury jury;
    uint256 key = 0xB21EF;
    bytes32 domain;

    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address treasury = makeAddr("treasury");
    address keeper = makeAddr("keeper");

    function setUp() public {
        vm.warp(1_790_800_000);
        imd = new MockERC20("IMD", "IMD", address(this));
        requester = new MockRequester(IERC20(address(imd)), ORACLE_FEE);
        domain = ImdOracle.domainSeparatorV("2", 1, address(0));
        jury = new BriefsJury(_oracle(vm.addr(key), requester), address(this), address(0));
        b = new Briefs(IERC20(address(imd)), new BriefsText(), jury, treasury, _params());
        address[4] memory users = [creator, alice, bob, carol];
        for (uint256 i; i < users.length; i++) {
            imd.transfer(users[i], 1_000_000 ether);
            vm.prank(users[i]);
            imd.approve(address(b), type(uint256).max);
        }
    }

    // ------------------------------------------------------------ helpers

    function _params() internal pure returns (Briefs.Params memory) {
        return Briefs.Params({
            minSeed: 10 ether,
            minFee: 1 ether,
            maxOracleFee: 0.9 ether,
            creatorBps: 1_500,
            platformBps: 500,
            panelSize: 11,
            quorum: 6,
            answerTimeout: 4 minutes,
            caseFee: CASE_FEE,
            minDuration: 10 minutes, maxDuration: 90 days, maxBrief: 500, reignBps: 0, overtime: 0, finalCap: 0, creatorSetsReign: false, creatorSetsCap: false
        });
    }

    function _oracle(address signer, IImdRequester r) internal view returns (BriefsJury.Oracle memory) {
        return BriefsJury.Oracle({signer: signer, requester: r, domain: domain, chainId: 1, hearingGas: 3_000_000});
    }

    // what _input asks for (the settings the owner set, or the creator's pick): a view call here would eat a vm.prank
    uint16 inReign;
    uint32 inCap;
    uint32 inOvertime;
    uint8 inLang;
    uint16 inMax;
    uint256 inCaseFee = CASE_FEE;
    uint16 inCreatorBps = 1_500;
    uint16 inPlatformBps = 500;

    function _input(uint64 endsAt) internal view returns (Briefs.CaseInput memory) {
        return Briefs.CaseInput({
            title: TITLE, task: TASK, standard: STANDARD, opening: OPENING, avatar: 3, seed: SEED, fee: FEE, endsAt: endsAt, minHold: 0, oracleId: oid, reignBps: inReign, finalCap: inCap, overtime: inOvertime, lang: inLang, maxBrief: inMax, caseFee: inCaseFee, creatorBps: inCreatorBps, platformBps: inPlatformBps
        });
    }

    function _case() internal returns (uint256) {
        vm.prank(creator);
        return b.openCase(_input(uint64(block.timestamp + 1 days)));
    }

    function _file(uint256 c, address who, string memory words) internal returns (uint256) {
        vm.prank(who);
        return b.fileBrief(c, words);
    }

    function _att(uint256 briefId, bool better) internal view returns (ImdOracle.AttestationV2 memory a, bytes memory sig) {
        a = _attWith(briefId, abi.encode(better), 11, 6, 6);
        sig = _sign(key, a);
    }

    function _attWith(uint256 briefId, bytes memory answer, uint16 panelSize, uint16 quorum, uint16 agreed)
        internal
        view
        returns (ImdOracle.AttestationV2 memory a)
    {
        a = ImdOracle.AttestationV2({
            requestId: b.getBrief(briefId).requestId,
            chainId: 1,
            questionHash: b.jury().questionHashOf(briefId, 1, 2),
            answerType: 0,
            answer: answer,
            figure: 0,
            fromBlock: 1,
            toBlock: 2,
            blockHash: keccak256("b"),
            panelJobId: keccak256("p"),
            panelSize: panelSize,
            quorum: quorum,
            agreed: agreed,
            issuedAt: b.getBrief(briefId).heardAt + 30, // the jury answers ~30 s after the hearing opens
            expiresAt: uint64(block.timestamp + 1 days)
        });
    }

    function _sign(uint256 k, ImdOracle.AttestationV2 memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(k, digester.digest(domain, a));
        return abi.encodePacked(r, s, v);
    }

    /// the jury answers a minute later and a keeper delivers it
    function _judge(uint256 briefId, bool better) internal {
        vm.warp(block.timestamp + 1 minutes);
        (ImdOracle.AttestationV2 memory a, bytes memory sig) = _att(briefId, better);
        vm.prank(keeper);
        b.fulfill(b.briefOfRequest(a.requestId), a, sig);
    }

    function _status(uint256 briefId) internal view returns (Briefs.BriefStatus) {
        return b.getBrief(briefId).status;
    }

    // ------------------------------------------------------------ opening a case

    function test_OpenCaseLocksSeedAndSetsTheOpeningPrecedent() public {
        uint256 before = imd.balanceOf(creator);
        uint256 c = _case();
        Briefs.Case memory k = b.getCase(c);
        assertEq(imd.balanceOf(creator), before - SEED - CASE_FEE);
        assertEq(imd.balanceOf(treasury), CASE_FEE); // the opening fee goes to the project
        assertEq(k.pot, SEED);
        assertEq(k.creator, creator);
        assertEq(uint8(k.status), uint8(Briefs.CaseStatus.Open));
        assertEq(b.briefText(k.precedent), OPENING);
        assertEq(b.getBrief(k.precedent).author, creator);
        assertEq(uint8(_status(k.precedent)), uint8(Briefs.BriefStatus.Opening));
        assertEq(b.taskOf(c), TASK);
        assertEq(b.standardOf(c), STANDARD);
        assertEq(b.titleOf(c), TITLE);
        assertEq(b.avatarOf(c), 3);
    }

    function test_AnyAvatarNumberIsAccepted() public {
        Briefs.CaseInput memory x = _input(uint64(block.timestamp + 1 days));
        x.avatar = 255;
        vm.prank(creator);
        uint256 c = b.openCase(x);
        assertEq(b.avatarOf(c), 255);
    }

    function test_OpenCaseRejectsBadInput() public {
        Briefs.CaseInput memory x = _input(uint64(block.timestamp + 1 days));
        vm.startPrank(creator);
        x.endsAt = uint64(block.timestamp + 9 minutes);
        vm.expectRevert(Briefs.BadDuration.selector);
        b.openCase(x);
        x.endsAt = uint64(block.timestamp + 91 days);
        vm.expectRevert(Briefs.BadDuration.selector);
        b.openCase(x);
        x.endsAt = uint64(block.timestamp + 1 days);
        x.fee = 0.9 ether;
        vm.expectRevert(Briefs.FeeTooSmall.selector);
        b.openCase(x);
        x.fee = FEE;
        x.seed = 1 ether;
        vm.expectRevert(Briefs.SeedTooSmall.selector);
        b.openCase(x);
        x.seed = SEED;
        x.title = "ab";
        vm.expectRevert(BriefsText.BadText.selector);
        b.openCase(x);
        x.title = TITLE;
        x.task = "Say \"hi\" to the jury now";
        vm.expectRevert(BriefsText.BadText.selector);
        b.openCase(x);
        vm.stopPrank();
    }

    function test_DurationBoundsAreInclusiveOfTenMinutesAndNinetyDays() public {
        vm.startPrank(creator);
        b.openCase(_input(uint64(block.timestamp + 10 minutes)));
        b.openCase(_input(uint64(block.timestamp + 90 days)));
        vm.stopPrank();
        assertEq(b.caseCount(), 2);
    }

    // ------------------------------------------------------------ filing and the fee split

    function test_FilingOpensTheHearingAtOnceAndTheVerdictSplitsTheFee() public {
        uint256 c = _case();
        uint256 id = _file(c, alice, B1);
        Briefs.Case memory k = b.getCase(c);
        assertEq(k.pot, SEED); // nothing is split until the verdict
        assertEq(k.creatorOwed, 0);
        assertEq(b.platformOwed(), 0);
        assertEq(imd.balanceOf(address(requester)), ORACLE_FEE); // the jury is paid from the brief's own fee
        assertEq(imd.balanceOf(address(b)), SEED + FEE - ORACLE_FEE);
        assertEq(k.hearing, id);
        assertEq(uint8(_status(id)), uint8(Briefs.BriefStatus.Hearing));
        Briefs.Brief memory br = b.getBrief(id);
        assertEq(br.against, k.precedent);
        assertEq(b.briefOfRequest(br.requestId), id);
        assertEq(requester.lastConsumer(), address(b.jury())); // the jury takes the answer
        assertEq(requester.lastInputHash(), keccak256(bytes(b.jury().requestOf(id))));
        _judge(id, false);
        k = b.getCase(c);
        assertEq(k.pot, SEED + TO_POT);
        assertEq(k.creatorOwed, TO_CREATOR);
        assertEq(b.platformOwed(), TO_PLATFORM);
    }

    function test_TheQuestionQuotesTaskStandardPrecedentAndChallenger() public {
        uint256 c = _case();
        uint256 id = _file(c, alice, B1);
        string memory input = b.jury().requestOf(id);
        assertEq(vm.parseJsonUint(input, ".panelSize"), 11);
        assertEq(vm.parseJsonUint(input, ".quorum"), 6);
        assertEq(vm.parseJsonString(input, ".answerType"), "bool");
        assertTrue(vm.parseJsonBool(input, ".allowAmbiguous"));
        assertFalse(vm.keyExistsJson(input, ".consumer")); // a pinned domain: the request names no consumer
        assertEq(
            vm.parseJsonString(input, ".question"),
            string.concat(
                unicode"You judge a contest. The task: «",
                TASK,
                unicode"» The standard: «",
                STANDARD,
                unicode"» The current leader's answer: «",
                OPENING,
                unicode"» A challenger's answer: «",
                B1,
                unicode"» Judged by the standard, is the challenger's answer better than the leader's? (Case ",
                Strings.toHexString(address(b.jury())), // the question names the jury: one per Briefs
                "-",
                Strings.toString(id),
                ")"
            )
        );
        assertEq(
            vm.parseJsonString(input, ".definitions.answer"),
            "true only if the challenger's answer meets the task better than the leader's, judged by the standard in good faith. False if it is worse, if the two are about equal, or if you are unsure: a tie keeps the leader. Also false if it reuses the leader's answer: the same words or sentences reordered, a paraphrase or translation, the leader's answer with small edits, additions or padding, or the same idea retold. A challenger wins only with something of its own that is better."
        );
    }

    function test_TheDocketIsHeardStrictlyInOrder() public {
        uint256 c = _case();
        uint256 a1 = _file(c, alice, B1);
        uint256 b1 = _file(c, bob, B2);
        uint256 a2 = _file(c, alice, "Third joke, still about dragons.");
        assertEq(b.getCase(c).hearing, a1);
        assertEq(uint8(_status(b1)), uint8(Briefs.BriefStatus.Queued));
        assertEq(b.waiting(c), 3);

        _judge(a1, true); // overruled: a1 is the precedent; b1 is heard against it
        assertEq(b.getCase(c).precedent, a1);
        assertEq(b.getCase(c).hearing, b1);
        assertEq(b.getBrief(b1).against, a1);

        _judge(b1, false); // sustained
        assertEq(b.getCase(c).precedent, a1);
        assertEq(b.getCase(c).streak, 1);
        assertEq(b.getCase(c).hearing, a2);
        assertEq(b.getBrief(a2).against, a1);
        assertEq(uint8(_status(b1)), uint8(Briefs.BriefStatus.Sustained));
        assertEq(uint8(_status(a1)), uint8(Briefs.BriefStatus.Overruled));
    }

    function test_NoQueueLimitPerAddress() public {
        uint256 c = _case();
        for (uint256 i; i < 10; i++) _file(c, alice, string.concat("Dragon joke number ", vm.toString(i), "."));
        assertEq(b.waiting(c), 10);
    }

    function test_BriefTextRules() public {
        uint256 c = _case();
        vm.startPrank(alice);
        vm.expectRevert(BriefsText.BadText.selector);
        b.fileBrief(c, "");
        vm.expectRevert(BriefsText.BadText.selector);
        b.fileBrief(c, " padded ");
        vm.expectRevert(BriefsText.BadText.selector);
        b.fileBrief(c, "two  spaces"); // a server that tidies spaces would hash another question
        string memory long = "";
        for (uint256 i; i < 501; i++) long = string.concat(long, "x");
        vm.expectRevert(BriefsText.BadText.selector);
        b.fileBrief(c, long);
        string memory cyr = "";
        for (uint256 i; i < 250; i++) cyr = string.concat(cyr, unicode"ж"); // 250 characters, 500 bytes
        b.fileBrief(c, cyr);
        vm.expectRevert(BriefsText.BadText.selector);
        b.fileBrief(c, string.concat(cyr, "x")); // the limit counts bytes: whatever IMD counts, it never exceeds them
        vm.stopPrank();
    }

    // ------------------------------------------------------------ verdicts

    function test_AnswersAreCheckedStrictly() public {
        uint256 c = _case();
        uint256 id = _file(c, alice, B1);
        vm.warp(block.timestamp + 1 minutes);
        (ImdOracle.AttestationV2 memory a, bytes memory sig) = _att(id, true);

        bytes memory bad = _sign(0xBAD, a);
        {
            uint256 bid_ = b.briefOfRequest(a.requestId);
            vm.expectRevert(BriefsJury.BadSignature.selector);
            b.fulfill(bid_, a, bad);
        }

        ImdOracle.AttestationV2 memory w = _attWith(id, abi.encode(true), 9, 6, 6);
        bad = _sign(key, w);
        {
            uint256 bid_ = b.briefOfRequest(w.requestId);
            vm.expectRevert(BriefsJury.WrongPanel.selector);
            b.fulfill(bid_, w, bad);
        }
        w = _attWith(id, abi.encode(true), 11, 6, 5);
        bad = _sign(key, w);
        {
            uint256 bid_ = b.briefOfRequest(w.requestId);
            vm.expectRevert(BriefsJury.WrongPanel.selector);
            b.fulfill(bid_, w, bad);
        }
        w = _attWith(id, abi.encode(uint256(2)), 11, 6, 6);
        bad = _sign(key, w);
        {
            uint256 bid_ = b.briefOfRequest(w.requestId);
            vm.expectRevert(BriefsJury.NotBool.selector);
            b.fulfill(bid_, w, bad);
        }
        (w,) = _att(id, true);
        w.chainId = 4663;
        bad = _sign(key, w);
        {
            uint256 bid_ = b.briefOfRequest(w.requestId);
            vm.expectRevert(BriefsJury.WrongChain.selector);
            b.fulfill(bid_, w, bad);
        }
        (w,) = _att(id, true);
        w.issuedAt = b.getBrief(id).heardAt - 2 minutes - 1; // beyond the allowed clock skew
        bad = _sign(key, w);
        {
            uint256 bid_ = b.briefOfRequest(w.requestId);
            vm.expectRevert(BriefsJury.AnsweredBeforeAsked.selector);
            b.fulfill(bid_, w, bad);
        }
        (w,) = _att(id, true);
        w.issuedAt = b.getBrief(id).heardAt + 4 minutes + 1;
        bad = _sign(key, w);
        {
            uint256 bid_ = b.briefOfRequest(w.requestId);
            vm.expectRevert(BriefsJury.Expired.selector);
            b.fulfill(bid_, w, bad);
        }
        (w,) = _att(id, true);
        w.questionHash = keccak256("another question");
        bad = _sign(key, w);
        vm.expectRevert(BriefsJury.WrongQuestion.selector);
        b.fulfill(id, w, bad);
        (w,) = _att(id, true);
        w.toBlock = 3; // the hash was for blocks 1..2
        bad = _sign(key, w);
        vm.expectRevert(BriefsJury.WrongQuestion.selector);
        b.fulfill(id, w, bad);
        vm.expectRevert(Briefs.WrongStatus.selector); // only a hearing takes an answer
        b.fulfill(id + 1, a, sig);

        b.fulfill(b.briefOfRequest(a.requestId), a, sig);
        {
            uint256 bid_ = b.briefOfRequest(a.requestId);
            vm.expectRevert(Briefs.WrongStatus.selector);
            b.fulfill(bid_, a, sig); // no double delivery
        }
    }

    function test_MistrialAfterTimeoutKeepsThePrecedentAndMovesOn() public {
        uint256 c = _case();
        uint256 a1 = _file(c, alice, B1);
        uint256 b1 = _file(c, bob, B2);
        vm.expectRevert(Briefs.TooEarly.selector);
        b.mistrial(c);
        vm.warp(block.timestamp + 4 minutes + 1);
        vm.expectRevert(Briefs.TooEarly.selector);
        b.mistrial(c); // a timely answer may still be on its way
        vm.warp(block.timestamp + 2 minutes);
        uint256 aliceBefore = imd.balanceOf(alice);
        uint256 pot = b.getCase(c).pot;
        b.mistrial(c);
        assertEq(uint8(_status(a1)), uint8(Briefs.BriefStatus.Mistrial));
        assertEq(imd.balanceOf(alice), aliceBefore + FEE - ORACLE_FEE); // the fee comes back, less the jury's price
        assertEq(b.getCase(c).pot, pot); // a failing jury never feeds the leader's pot
        assertEq(b.getCase(c).creatorOwed, 0);
        assertEq(b.platformOwed(), 0);
        assertEq(b.getCase(c).precedent, 1); // the opening brief stands
        assertEq(b.getCase(c).hearing, b1);
        // a valid answer arriving after the mistrial no longer counts
        ImdOracle.AttestationV2 memory a = _attWith(a1, abi.encode(true), 11, 6, 6);
        a.issuedAt = b.getBrief(a1).heardAt + 1;
        bytes memory sig = _sign(key, a);
        {
            uint256 bid_ = b.briefOfRequest(a.requestId);
            vm.expectRevert(Briefs.WrongStatus.selector);
            b.fulfill(bid_, a, sig);
        }
    }

    // ------------------------------------------------------------ deadline and settlement

    function test_EntriesCloseAtTheDeadlineButTheDocketIsHeardToTheEnd() public {
        uint256 c = _case();
        uint256 a1 = _file(c, alice, B1);
        uint256 b1 = _file(c, bob, B2);
        vm.warp(b.getCase(c).endsAt);
        vm.prank(carol);
        vm.expectRevert(Briefs.EntriesClosed.selector);
        b.fileBrief(c, "Too late for the court.");
        vm.expectRevert(Briefs.TooEarly.selector);
        b.settle(c); // a hearing is still running

        _judge(a1, false);
        assertEq(uint8(b.getCase(c).status), uint8(Briefs.CaseStatus.Open));
        uint256 bobBefore = imd.balanceOf(bob);
        _judge(b1, true); // the last brief overrules and the case settles by itself
        Briefs.Case memory k = b.getCase(c);
        assertEq(uint8(k.status), uint8(Briefs.CaseStatus.Settled));
        assertEq(k.winner, bob);
        assertEq(k.pot, 0);
        assertEq(imd.balanceOf(bob), bobBefore + SEED + 2 * TO_POT); // 100% of the pot
    }

    function test_NoEntriesTheCreatorsOpeningTakesTheSeed() public {
        uint256 c = _case();
        vm.expectRevert(Briefs.TooEarly.selector);
        b.settle(c);
        vm.warp(block.timestamp + 1 days);
        uint256 before = imd.balanceOf(creator);
        b.settle(c);
        assertEq(imd.balanceOf(creator), before + SEED);
        assertEq(b.getCase(c).winner, creator);
        vm.expectRevert(Briefs.TooEarly.selector);
        b.settle(c); // once
    }

    function test_SettledCaseTakesNoEntries() public {
        uint256 c = _case();
        vm.warp(block.timestamp + 1 days);
        b.settle(c);
        vm.prank(alice);
        vm.expectRevert(Briefs.NotOpen.selector);
        b.fileBrief(c, B1);
    }

    // ------------------------------------------------------------ creator earnings

    function test_CreatorEarningsAccrueOnTheCaseAndAreClaimed() public {
        uint256 c = _case();
        uint256 c2 = _case();
        uint256 a1 = _file(c, alice, B1);
        _file(c, bob, B2);
        _file(c2, alice, B1);
        assertEq(b.getCase(c).creatorOwed, 0); // every fee waits in escrow until its verdict
        _judge(a1, false);
        _judge(b.getCase(c).hearing, false);
        _judge(b.getCase(c2).hearing, false);
        assertEq(b.getCase(c).creatorOwed, 2 * TO_CREATOR);
        uint256 before = imd.balanceOf(creator);

        uint256[] memory one = new uint256[](1);
        one[0] = c;
        vm.prank(alice);
        vm.expectRevert(Briefs.NotCreator.selector);
        b.claimCreator(one);

        vm.prank(creator);
        b.claimCreator(one);
        assertEq(imd.balanceOf(creator), before + 2 * TO_CREATOR);
        assertEq(b.getCase(c).creatorOwed, 0);
        assertEq(b.getCase(c).creatorClaimed, 2 * TO_CREATOR);

        uint256[] memory both = new uint256[](2);
        both[0] = c;
        both[1] = c2;
        vm.prank(creator);
        b.claimCreator(both); // c is empty, c2 pays
        assertEq(imd.balanceOf(creator), before + 3 * TO_CREATOR);
        vm.prank(creator);
        vm.expectRevert(Briefs.NothingToClaim.selector);
        b.claimCreator(both);
    }

    function test_CreatorCanClaimAfterSettlement() public {
        uint256 c = _case();
        uint256 a1 = _file(c, alice, B1);
        vm.warp(block.timestamp + 1 days);
        _judge(a1, false);
        assertEq(uint8(b.getCase(c).status), uint8(Briefs.CaseStatus.Settled));
        uint256[] memory one = new uint256[](1);
        one[0] = c;
        vm.prank(creator);
        assertEq(b.claimCreator(one), TO_CREATOR);
    }

    // ------------------------------------------------------------ platform share

    function test_PlatformShareGoesToTheTreasuryAtLaunch() public {
        uint256 c = _case();
        uint256 a1 = _file(c, alice, B1);
        uint256 b1 = _file(c, bob, B2);
        _judge(a1, false);
        _judge(b1, false);
        vm.prank(carol); // anyone can trigger it; it only ever pays the treasury (and the sink, when set)
        b.withdrawPlatform();
        assertEq(imd.balanceOf(treasury), CASE_FEE + 2 * TO_PLATFORM);
        assertEq(b.platformOwed(), 0);
        vm.expectRevert(Briefs.NothingToClaim.selector);
        b.withdrawPlatform();
    }

    // ------------------------------------------------------------ the oracle misbehaving

    function test_ARequesterFailureStallsTheDocketWithoutBlockingAnswers() public {
        uint256 c = _case();
        uint256 a1 = _file(c, alice, B1);
        uint256 b1 = _file(c, bob, B2);
        requester.setBroken(true);
        _judge(a1, true); // the answer lands even though the next hearing cannot open
        assertEq(b.getCase(c).precedent, a1);
        assertEq(b.getCase(c).hearing, 0);
        assertEq(uint8(_status(b1)), uint8(Briefs.BriefStatus.Queued));
        requester.setBroken(false);
        b.hear(c);
        assertEq(b.getCase(c).hearing, b1);
    }

    function test_AGreedyRequesterIsRolledBack() public {
        uint256 c = _case();
        requester.setGreedy(true);
        uint256 a1 = _file(c, alice, B1); // filing works; the hearing does not open
        assertEq(b.getCase(c).hearing, 0);
        assertEq(imd.balanceOf(address(requester)), 0);
        assertEq(uint8(_status(a1)), uint8(Briefs.BriefStatus.Queued));
        requester.setGreedy(false);
        b.hear(c);
        assertEq(b.getCase(c).hearing, a1);
    }

    function test_OraclePriceChangesNeverTouchThePot() public {
        uint256 c = _case();
        _file(c, alice, B1); // hearing open at 0.5
        uint256 b1 = _file(c, bob, B2); // reserved 0.5
        uint256 c1 = _file(c, carol, "Cheaper joke."); // reserved 0.5
        uint256 pot = b.getCase(c).pot;
        assertEq(pot, SEED); // nothing is split before a verdict

        requester.setFee(0.4 ether); // cheaper: bob's hearing pays 0.4, and his split is 4.6 on the verdict
        _judge(b.getCase(c).hearing, false);
        assertEq(b.getCase(c).hearing, b1);
        assertEq(b.getCase(c).pot, pot + TO_POT);

        requester.setFee(1 ether); // dearer than the case's reserve (0.9): carol's whole fee comes back, she is not heard
        uint256 carolBefore = imd.balanceOf(carol);
        _judge(b1, false);
        assertEq(uint8(_status(c1)), uint8(Briefs.BriefStatus.Unheard));
        assertEq(imd.balanceOf(carol), carolBefore + FEE);
        assertEq(b.getCase(c).pot, pot + TO_POT + (FEE - 0.4 ether) * 8_000 / 10_000);
        assertEq(b.waiting(c), 0);
    }

    /// filing never asks the oracle: the case's reserve (maxOracleFee when it opened) is the most a hearing may pay
    function test_FilingNeverCallsTheOracle() public {
        uint256 c = _case();
        assertEq(b.getCase(c).reserve, 0.9 ether);
        requester.setBroken(true); // fee() and request() revert
        uint256 a1 = _file(c, alice, B1); // filed anyway; its hearing stalls
        assertEq(b.getBrief(a1).oracleReserve, 0.9 ether);
        assertEq(uint8(_status(a1)), uint8(Briefs.BriefStatus.Queued));
        requester.setBroken(false);
        requester.setFee(1 ether); // dearer than the case's reserve: skipped, whole fee back
        uint256 before = imd.balanceOf(alice);
        b.hear(c);
        assertEq(uint8(_status(a1)), uint8(Briefs.BriefStatus.Unheard));
        assertEq(imd.balanceOf(alice), before + FEE);
        assertEq(b.getCase(c).pot, SEED);
    }

    function test_SkipStalledLetsADeadOracleCaseSettle() public {
        uint256 c = _case();
        requester.setBroken(true);
        uint256 a1 = _file(c, alice, B1);
        assertEq(b.getCase(c).stalledSince, block.timestamp); // the stall clock starts with the first failure
        vm.warp(block.timestamp + 6 hours - 1);
        vm.expectRevert(Briefs.TooEarly.selector);
        b.skipStalled(c);
        requester.setBroken(false);
        vm.warp(block.timestamp + 1);
        uint256 snap = vm.snapshotState();
        b.skipStalled(c); // the oracle works again: the hearing opens instead of a skip
        assertEq(b.getCase(c).hearing, a1);
        assertEq(b.getCase(c).stalledSince, 0);
        vm.revertToState(snap);
        requester.setBroken(true);
        vm.warp(b.getCase(c).endsAt); // entries closed: the brief is skipped and the case settles
        uint256 aliceBefore = imd.balanceOf(alice);
        uint256 creatorBefore = imd.balanceOf(creator);
        b.skipStalled(c);
        assertEq(uint8(_status(a1)), uint8(Briefs.BriefStatus.Unheard));
        assertEq(imd.balanceOf(alice), aliceBefore + FEE); // never heard: the whole fee comes back
        assertEq(uint8(b.getCase(c).status), uint8(Briefs.CaseStatus.Settled));
        assertEq(imd.balanceOf(creator), creatorBefore + SEED); // the pot never grew from an unheard brief
        assertEq(b.getCase(c).creatorOwed, 0);
        assertEq(b.platformOwed(), 0);
        assertEq(imd.balanceOf(address(b)), 0);
    }

    /// a brief whose hearing keeps failing can't hold the docket until the deadline: STALL_WAIT after the first
    /// failure it is skipped (whole fee back) and the next brief gets its own wait
    function test_SkipStalledFreesTheDocketBeforeTheDeadline() public {
        uint256 c = _case();
        uint256 a1 = _file(c, alice, B1);
        uint256 b1 = _file(c, bob, B2);
        requester.setBroken(true);
        _judge(a1, false);
        uint64 since = b.getCase(c).stalledSince;
        assertEq(since, block.timestamp);
        vm.warp(block.timestamp + 1 hours);
        b.hear(c); // still failing: the clock keeps its start
        assertEq(b.getCase(c).stalledSince, since);
        vm.warp(since + 6 hours);
        uint256 before = imd.balanceOf(bob);
        b.skipStalled(c);
        assertEq(uint8(_status(b1)), uint8(Briefs.BriefStatus.Unheard));
        assertEq(imd.balanceOf(bob), before + FEE);
        assertEq(b.getCase(c).stalledSince, 0);
        assertLt(block.timestamp, b.getCase(c).endsAt);
        uint256 c1 = _file(c, carol, "A third joke about dragons."); // stalls: a fresh clock for carol
        assertEq(b.getCase(c).stalledSince, block.timestamp);
        vm.expectRevert(Briefs.TooEarly.selector);
        b.skipStalled(c);
        requester.setBroken(false);
        b.hear(c);
        assertEq(b.getCase(c).hearing, c1);
        assertEq(b.getCase(c).stalledSince, 0);
    }

    /// a brief skipped for price takes the stall clock with it: the next brief gets its own wait
    function test_APriceSkipResetsTheStallClock() public {
        uint256 c = _case();
        requester.setBroken(true);
        uint256 a1 = _file(c, alice, B1);
        assertGt(b.getCase(c).stalledSince, 0);
        requester.setBroken(false);
        requester.setFee(1 ether); // above the reserve: a1 is skipped, whole fee back
        b.hear(c);
        assertEq(uint8(_status(a1)), uint8(Briefs.BriefStatus.Unheard));
        assertEq(b.getCase(c).stalledSince, 0);
        vm.warp(block.timestamp + 12 hours); // longer than STALL_WAIT since the first stall
        requester.setFee(ORACLE_FEE);
        requester.setBroken(true);
        _file(c, bob, B2); // its first failure starts a fresh clock
        assertEq(b.getCase(c).stalledSince, block.timestamp);
        vm.expectRevert(Briefs.TooEarly.selector);
        b.skipStalled(c);
    }

    function test_SkipStalledRefundsTheFullFeeOfEveryUnheardBrief() public {
        uint256 c = _case();
        uint256 a1 = _file(c, alice, B1); // heard: its fee is split
        uint256 b1 = _file(c, bob, B2);
        uint256 c1 = _file(c, carol, "A third joke about dragons.");
        requester.setBroken(true);
        _judge(a1, true); // the next hearing stalls
        assertEq(b.getCase(c).hearing, 0);
        Briefs.Case memory k = b.getCase(c);
        assertEq(k.pot, SEED + TO_POT);
        vm.warp(k.endsAt + 3 days); // past STALL_GRACE: every stalled brief can go at once
        uint256 bobBefore = imd.balanceOf(bob);
        uint256 carolBefore = imd.balanceOf(carol);
        uint256 aliceBefore = imd.balanceOf(alice);
        b.skipStalled(c);
        assertEq(uint8(_status(b1)), uint8(Briefs.BriefStatus.Unheard));
        assertEq(imd.balanceOf(bob), bobBefore + FEE);
        assertEq(b.getBrief(b1).oracleReserve, 0);
        assertEq(uint8(b.getCase(c).status), uint8(Briefs.CaseStatus.Open));
        b.skipStalled(c);
        assertEq(uint8(_status(c1)), uint8(Briefs.BriefStatus.Unheard));
        assertEq(imd.balanceOf(carol), carolBefore + FEE);
        assertEq(uint8(b.getCase(c).status), uint8(Briefs.CaseStatus.Settled));
        assertEq(imd.balanceOf(alice), aliceBefore + SEED + TO_POT); // only alice's heard fee ever reached the pot
        assertEq(b.getCase(c).creatorOwed, TO_CREATOR);
        assertEq(b.platformOwed(), TO_PLATFORM);
        assertEq(imd.balanceOf(address(b)), TO_CREATOR + TO_PLATFORM);
    }

    function test_AFeeIsEscrowedAndSplitOnlyOnItsVerdict() public {
        uint256 c = _case();
        uint256 a1 = _file(c, alice, B1);
        Briefs.Case memory k0 = b.getCase(c);
        uint256 plat0 = b.platformOwed();
        uint256 bal0 = imd.balanceOf(address(b));
        uint256 b1 = _file(c, bob, B2); // queued behind alice's running hearing
        Briefs.Case memory k1 = b.getCase(c);
        assertEq(uint8(_status(b1)), uint8(Briefs.BriefStatus.Queued));
        assertEq(k1.pot, k0.pot);
        assertEq(k1.creatorOwed, k0.creatorOwed);
        assertEq(b.platformOwed(), plat0);
        assertEq(imd.balanceOf(address(b)), bal0 + FEE); // the whole fee sits in escrow
        assertEq(b.getBrief(b1).oracleReserve, 0.9 ether); // the case's reserve, until the hearing pays the real price
        assertEq(imd.balanceOf(address(requester)), ORACLE_FEE); // only alice's hearing was paid for

        _judge(a1, false); // alice's fee is split; bob's hearing opens, his fee still waits
        Briefs.Case memory k2 = b.getCase(c);
        assertEq(k2.hearing, b1);
        assertEq(k2.pot, k0.pot + TO_POT);
        assertEq(k2.creatorOwed, k0.creatorOwed + TO_CREATOR);
        assertEq(b.platformOwed(), plat0 + TO_PLATFORM);
        assertEq(imd.balanceOf(address(requester)), 2 * ORACLE_FEE);
        assertEq(imd.balanceOf(address(b)), bal0 + FEE - ORACLE_FEE);
        assertEq(b.getBrief(b1).oracleReserve, ORACLE_FEE);
        _judge(b1, false);
        assertEq(b.getCase(c).pot, k0.pot + 2 * TO_POT);
    }

    // ------------------------------------------------------------ owner powers

    function test_PauseStopsNewCasesButNeverEntriesHearingsOrPayouts() public {
        uint256 c = _case();
        uint256 a1 = _file(c, alice, B1);
        b.setPaused(true);
        uint256 b1 = _file(c, bob, B2); // a running case keeps taking entries
        assertEq(uint8(_status(b1)), uint8(Briefs.BriefStatus.Queued));
        vm.prank(creator);
        vm.expectRevert(Briefs.IsPaused.selector);
        b.openCase(_input(uint64(block.timestamp + 1 days)));
        vm.warp(block.timestamp + 1 days);
        _judge(a1, true);
        _judge(b1, false);
        assertEq(b.getCase(c).winner, alice);
        assertEq(b.getCase(c).pot, 0);
        b.setPaused(false);
        vm.prank(creator);
        b.openCase(_input(uint64(block.timestamp + 1 days)));
    }

    /// a new setup applies to cases opened after it, and only when their creator names it: nothing moves a case
    function test_OracleChangeIsDelayedAndPinnedPerCase() public {
        vm.prank(creator);
        uint256 c = b.openCase(_input(uint64(block.timestamp + 30 days)));
        MockRequester r2 = new MockRequester(IERC20(address(imd)), ORACLE_FEE);
        jury.proposeOracle(_oracle(vm.addr(0xC0FFEE), r2));
        vm.expectRevert(BriefsJury.TooEarly.selector);
        jury.applyOracle();
        oid = uint32(jury.latest()); // new cases must name the live setup
        vm.warp(block.timestamp + 7 days);
        jury.applyOracle();
        oid = uint32(jury.latest()); // new cases must name the live setup
        assertEq(b.getCase(c).oracleId, 0); // the open case keeps its setup, for life
        uint256 a1 = _file(c, alice, B1);
        assertEq(b.getBrief(a1).oracleId, 0);
        _judge(a1, true); // judged under setup 0 (key), not the new signer

        // a creator who saw setup 0 can't land on setup 1 applied in between
        Briefs.CaseInput memory x = _input(uint64(block.timestamp + 1 days));
        x.oracleId = 0; // the setup it saw before the switch
        vm.prank(creator);
        vm.expectRevert(Briefs.WrongOracle.selector);
        b.openCase(x);
        x.oracleId = 1;
        vm.prank(creator);
        uint256 c2 = b.openCase(x);
        assertEq(b.getCase(c2).oracleId, 1);
        assertEq(address(jury.get(b.getCase(c2).oracleId).requester), address(r2));
    }

    function test_RenounceOwnershipReverts() public {
        vm.expectRevert(Briefs.BadParams.selector);
        b.renounceOwnership();
        vm.expectRevert(BriefsJury.BadOracle.selector);
        jury.renounceOwnership();
        assertEq(b.owner(), address(this));
        assertEq(jury.owner(), address(this));
    }

    function test_OnlyTheOwnerProposesOracles() public {
        MockRequester r2 = new MockRequester(IERC20(address(imd)), ORACLE_FEE);
        BriefsJury.Oracle memory o = _oracle(vm.addr(0xC0FFEE), r2);
        vm.prank(alice);
        vm.expectRevert();
        jury.proposeOracle(o);
        o.hearingGas = 100_000; // too little for any real request
        vm.expectRevert(BriefsJury.BadOracle.selector);
        jury.proposeOracle(o);
    }

    function test_ParamChangesNeverReachRunningCases() public {
        uint256 c = _case();
        Briefs.Params memory p = _params();
        p.panelSize = 7;
        p.quorum = 4;
        p.answerTimeout = 3 minutes;
        b.setParams(p);
        uint256 a1 = _file(c, alice, B1);
        Briefs.Brief memory br = b.getBrief(a1);
        assertEq(br.panelSize, 11);
        assertEq(br.quorum, 6);
        assertEq(br.answerTimeout, 4 minutes);
        assertEq(vm.parseJsonUint(b.jury().requestOf(a1), ".panelSize"), 11);
        _judge(a1, true); // an 11/6 answer is still accepted
        assertEq(b.getCase(c).precedent, a1);
    }

    function test_OutOfGasCannotFakeAStall() public {
        HeavyRequester heavy = new HeavyRequester(IERC20(address(imd)));
        jury.proposeOracle(_oracle(vm.addr(key), heavy));
        vm.warp(block.timestamp + 7 days);
        jury.applyOracle();
        oid = uint32(jury.latest()); // new cases must name the live setup
        vm.prank(creator);
        uint256 c = b.openCase(_input(uint64(block.timestamp + 1 days)));
        uint256 a1 = _file(c, alice, B1);
        uint256 b1 = _file(c, bob, B2);
        vm.warp(b.getCase(c).endsAt + 3 days);
        // a mistrial sent with just too little gas for the heavy request must revert, not stall the docket
        bool stalledSomewhere;
        for (uint256 g = 150_000; g < 2_000_000; g += 50_000) {
            uint256 snap = vm.snapshotState();
            try b.mistrial{gas: g}(c) {
                if (b.getCase(c).hearing == 0) { stalledSomewhere = true; emit log_named_uint("stalled at gas", g); }
            } catch {}
            vm.revertToState(snap);
        }
        assertFalse(stalledSomewhere);
        b.mistrial(c);
        assertEq(b.getCase(c).hearing, b1);
        assertEq(uint8(_status(a1)), uint8(Briefs.BriefStatus.Mistrial));
        vm.expectRevert(Briefs.WrongStatus.selector);
        b.skipStalled(c); // a hearing is running: nothing to skip
    }

    function test_ParamsBounds() public {
        Briefs.Params memory p = _params();
        p.creatorBps = 2_000;
        p.platformBps = 1_001;
        vm.expectRevert(Briefs.BadParams.selector);
        b.setParams(p);
        p = _params();
        p.quorum = 5; // 5 of 11 is not a majority
        vm.expectRevert(Briefs.BadParams.selector);
        b.setParams(p);
        p = _params();
        p.minFee = 0.5 ether; // must exceed the oracle's max price
        vm.expectRevert(Briefs.BadParams.selector);
        b.setParams(p);
    }

    // ------------------------------------------------------------ solvency

    /// Whatever happens, the contract holds every pot, every unclaimed creator share, the platform's share,
    /// the whole escrowed fee of every brief not yet heard and the rest of the fee of the brief being heard.
    function testFuzz_Solvency(uint8 n, uint256 seed) public {
        n = uint8(bound(n, 1, 12));
        uint256 c = _case();
        address[3] memory who = [alice, bob, carol];
        for (uint256 i; i < n; i++) {
            _file(c, who[i % 3], "A joke about dragons, honestly.");
            uint256 h = b.getCase(c).hearing;
            if (h != 0 && (uint256(keccak256(abi.encode(seed, i))) % 3) != 0) {
                _judge(h, uint256(keccak256(abi.encode(seed, i, 1))) % 2 == 0);
            }
        }
        _assertSolvent(c);
        vm.warp(block.timestamp + 1 days);
        while (b.getCase(c).hearing != 0) _judge(b.getCase(c).hearing, seed % 2 == 0);
        if (b.canSettle(c)) b.settle(c);
        assertEq(uint8(b.getCase(c).status), uint8(Briefs.CaseStatus.Settled));
        _assertSolvent(c);
    }

    function _assertSolvent(uint256 c) internal view {
        Briefs.Case memory k = b.getCase(c);
        uint256 escrow;
        uint256 queued = b.waiting(c) - (k.hearing != 0 ? 1 : 0);
        for (uint256 i; i < queued; i++) {
            assertEq(uint8(_status(b.docketOf(c, k.head + i))), uint8(Briefs.BriefStatus.Queued));
            escrow += k.fee; // a queued brief owes its whole fee back if it is never heard
        }
        // the brief being heard: its fee less the jury's price waits for the verdict (or goes back on a mistrial)
        if (k.hearing != 0) escrow += k.fee - b.getBrief(k.hearing).oracleReserve;
        assertEq(imd.balanceOf(address(b)), k.pot + k.creatorOwed + b.platformOwed() + escrow);
    }

    /// Every IMD that enters Briefs for a case leaves it again once the case is settled and every share claimed:
    /// to the winner, the creator, the treasury, the jury, or back to an unheard author. Prices move and the
    /// requester fails at random along the way.
    function testFuzz_EverythingInComesOutAfterSettlement(uint8 n, uint256 seed) public {
        n = uint8(bound(n, 1, 16));
        address[4] memory who = [alice, bob, carol, creator];
        uint256 start;
        for (uint256 i; i < who.length; i++) start += imd.balanceOf(who[i]);
        start += imd.balanceOf(treasury) + imd.balanceOf(address(requester));
        uint256 c = _case();
        for (uint256 i; i < n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            if (r % 7 == 0) requester.setFee(0.3 ether + (r >> 8) % 0.4 ether); // cheaper or dearer than reserved
            requester.setBroken(r % 11 == 0);
            _file(c, who[r % 4], "A joke about dragons, honestly.");
            uint256 h = b.getCase(c).hearing;
            if (h != 0 && (r >> 16) % 3 != 0) _judge(h, (r >> 24) % 2 == 0);
            _assertSolvent(c);
        }
        requester.setBroken(false);
        vm.warp(b.getCase(c).endsAt);
        for (uint256 guard; guard < 64 && b.getCase(c).status == Briefs.CaseStatus.Open; guard++) {
            uint256 h = b.getCase(c).hearing;
            if (h != 0) _judge(h, (seed >> guard) % 2 == 0);
            else b.hear(c);
            _assertSolvent(c);
        }
        assertEq(uint8(b.getCase(c).status), uint8(Briefs.CaseStatus.Settled));
        uint256[] memory one = new uint256[](1);
        one[0] = c;
        if (b.getCase(c).creatorOwed != 0) {
            vm.prank(creator);
            b.claimCreator(one);
        }
        if (b.platformOwed() != 0) b.withdrawPlatform();
        assertEq(imd.balanceOf(address(b)), 0, "nothing left behind");
        uint256 end;
        for (uint256 i; i < who.length; i++) end += imd.balanceOf(who[i]);
        end += imd.balanceOf(treasury) + imd.balanceOf(address(requester));
        assertEq(end, start, "IMD out equals IMD in");
    }

    // ------------------------------------------------------------ consumer-addressed attestations

    function _consumerGame() internal returns (Briefs b2, uint256 id) {
        BriefsJury.Oracle memory o = _oracle(vm.addr(key), requester);
        o.domain = bytes32(0);
        b2 = new Briefs(IERC20(address(imd)), new BriefsText(), new BriefsJury(o, address(this), address(0)), treasury, _params());
        vm.prank(creator);
        imd.approve(address(b2), type(uint256).max);
        vm.prank(alice);
        imd.approve(address(b2), type(uint256).max);
        vm.prank(creator);
        uint256 c = b2.openCase(_input(uint64(block.timestamp + 1 days)));
        vm.prank(alice);
        id = b2.fileBrief(c, B1);
    }

    function _signFor(bytes32 dom, ImdOracle.AttestationV2 memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s_) = vm.sign(key, digester.digest(dom, a));
        return abi.encodePacked(r, s_, v);
    }

    function test_ConsumerDomain_RequestNamesThisContract() public {
        (Briefs b2, uint256 id) = _consumerGame();
        string memory input = b2.jury().requestOf(id);
        assertEq(vm.parseJsonUint(input, ".consumer.chainId"), block.chainid);
        assertEq(vm.parseJsonAddress(input, ".consumer.verifyingContract"), address(b2.jury())); // IMD signs for the jury, which checks answers
        // and IMD only takes it in lowercase
        assertEq(vm.parseJsonString(input, ".consumer.verifyingContract"), Strings.toHexString(address(b2.jury())));
        assertEq(vm.parseJsonUint(input, ".panelSize"), 11);
        assertEq(vm.parseJsonUint(input, ".quorum"), 6);
        assertEq(vm.parseJsonUint(input, ".chainId"), 1);
        assertEq(requester.lastInputHash(), keccak256(bytes(input))); // exactly what the hearing sent
    }

    function test_ConsumerDomain_OnlyThisContractsDomainVerifies() public {
        (Briefs b2, uint256 id) = _consumerGame();
        vm.warp(block.timestamp + 1 minutes);
        ImdOracle.AttestationV2 memory a = ImdOracle.AttestationV2({
            requestId: b2.getBrief(id).requestId, chainId: 1, questionHash: b2.jury().questionHashOf(id, 1, 2), answerType: 0,
            answer: abi.encode(true), figure: 0, fromBlock: 1, toBlock: 2, blockHash: keccak256("b"),
            panelJobId: keccak256("p"), panelSize: 11, quorum: 6, agreed: 6,
            issuedAt: b2.getBrief(id).heardAt + 30, expiresAt: uint64(block.timestamp + 1 days)
        });
        bytes memory imdDefault = _signFor(ImdOracle.domainSeparatorV("2", 1, address(0)), a);
        {
            uint256 bid_ = b2.briefOfRequest(a.requestId);
            vm.expectRevert(BriefsJury.BadSignature.selector);
            b2.fulfill(bid_, a, imdDefault);
        }
        bytes memory otherGame = _signFor(ImdOracle.domainSeparatorV("2", block.chainid, address(b)), a);
        {
            uint256 bid_ = b2.briefOfRequest(a.requestId);
            vm.expectRevert(BriefsJury.BadSignature.selector);
            b2.fulfill(bid_, a, otherGame);
        }
        b2.fulfill(b2.briefOfRequest(a.requestId), a, _signFor(ImdOracle.domainSeparatorV("2", block.chainid, address(b2.jury())), a));
        assertEq(uint8(b2.getBrief(id).status), uint8(Briefs.BriefStatus.Overruled));
    }

    /// IMD's on-chain request key and the id it signs differ, so the answer is matched by its question
    function test_QuestionHash_TiesTheAnswerToItsHearing() public {
        uint256 c = _case();
        uint256 id1 = _file(c, alice, B1);
        uint256 id2 = _file(c, bob, B2);
        vm.warp(block.timestamp + 1 minutes);
        // any request id and any pinned window, as long as the question is this hearing's
        ImdOracle.AttestationV2 memory a = _attWith(id1, abi.encode(true), 11, 6, 6);
        a.requestId = bytes32(uint256(0x76ea04d9));
        a.fromBlock = 26134774;
        a.toBlock = 26141951;
        a.questionHash = b.jury().questionHashOf(id1, 26134774, 26141951);
        // the next brief's question does not fit this hearing
        ImdOracle.AttestationV2 memory other = _attWith(id1, abi.encode(true), 11, 6, 6); // a copy, not an alias
        other.fromBlock = 26134774;
        other.toBlock = 26141951;
        other.questionHash = b.jury().questionHashOf(id2, 26134774, 26141951);
        bytes memory otherSig = _sign(key, other);
        vm.expectRevert(BriefsJury.WrongQuestion.selector);
        b.fulfill(id1, other, otherSig);
        b.fulfill(id1, a, _sign(key, a));
        assertEq(uint8(_status(id1)), uint8(Briefs.BriefStatus.Overruled));
    }

    /// the hash is IMD's canonical JSON of the request, exactly as the site and keeper build it
    function test_QuestionHash_IsTheCanonicalRequest() public {
        uint256 c = _case();
        uint256 id = _file(c, alice, B1);
        string memory q = b.jury().question(id, b.getBrief(id).against);
        bytes32 expected = keccak256(
            bytes(
                string.concat(
                    '{"answerType":"bool","chainId":1,"definitions":',
                    b.text().DEFINITIONS(),
                    ',"evidence":"panel","question":"',
                    q,
                    '","v":1,"window":{"fromBlock":7,"toBlock":9}}'
                )
            )
        );
        assertEq(b.jury().questionHashOf(id, 7, 9), expected);
    }

    /// the jury reads a hearing through IBriefsCourt.BriefView: it must mirror Briefs.Brief field for field
    function test_Jury_BriefViewMirrorsBriefs() public {
        uint256 c = _case();
        uint256 id = _file(c, alice, B1);
        Briefs.Brief memory x = b.getBrief(id);
        IBriefsCourt.BriefView memory v = IBriefsCourt(address(b)).getBrief(id);
        assertEq(v.author, x.author);
        assertEq(v.caseId, x.caseId);
        assertEq(v.status, uint8(x.status));
        assertEq(v.panelSize, x.panelSize);
        assertEq(v.quorum, x.quorum);
        assertEq(v.filedAt, x.filedAt);
        assertEq(v.heardAt, x.heardAt);
        assertEq(v.answerTimeout, x.answerTimeout);
        assertEq(v.oracleId, x.oracleId);
        assertEq(v.against, x.against);
        assertEq(v.oracleReserve, x.oracleReserve);
        assertEq(v.requestId, x.requestId);
        assertEq(v.status, 3); // Hearing: the value the jury checks for
    }

    /// one jury, one Briefs: bound when Briefs is deployed, never again
    function test_Jury_IsBoundOnceToItsBriefs() public {
        assertEq(address(jury.court()), address(b));
        BriefsText t = new BriefsText();
        Briefs.Params memory p = _params();
        vm.expectRevert(BriefsJury.AlreadyBound.selector);
        jury.bind(t);
        vm.expectRevert(BriefsJury.AlreadyBound.selector);
        new Briefs(IERC20(address(imd)), t, jury, treasury, p); // can't reuse a jury
    }

    /// the jury names the Briefs that may bind it when it is deployed: nobody else can bind it first
    function test_Jury_ExpectedCourtStopsAFrontRunBind() public {
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        BriefsJury j = new BriefsJury(_oracle(vm.addr(key), requester), address(this), next);
        BriefsText t = new BriefsText();
        Briefs.Params memory p = _params();
        assertEq(j.expectedCourt(), next);
        vm.prank(alice);
        vm.expectRevert(BriefsJury.WrongCourt.selector);
        j.bind(t); // the front-runner
        Briefs b3 = new Briefs(IERC20(address(imd)), t, j, treasury, p);
        assertEq(address(b3), next);
        assertEq(address(j.court()), address(b3));
    }

    /// a requester that can't say where its answers come from is refused as a setup
    function test_Jury_RefusesASetupWhoseRequesterCantAnswer() public {
        BriefsJury.Oracle memory o = _oracle(vm.addr(key), IImdRequester(address(imd))); // an ERC20, no answerSource()
        vm.expectRevert();
        jury.proposeOracle(o);
    }

    // ------------------------------------------------------------ IMD swarm audit (Oct 2026), one test per finding

    /// 2: a requester that answers fee() or answerSource() with garbage stalls the case; it never freezes it
    function test_Swarm2_MalformedRequesterRepliesStallInsteadOfFreezing() public {
        uint256 c = _case();
        uint256 a1 = _file(c, alice, B1); // heard
        uint256 a2 = _file(c, bob, B2); // queued
        requester.setShort(true, true);
        assertFalse(b.jury().wasDelivered(a1));
        vm.warp(block.timestamp + 4 minutes + 2 minutes + 1);
        b.mistrial(c); // goes through; the next hearing can't be priced, so it stalls
        assertEq(uint8(_status(a1)), uint8(Briefs.BriefStatus.Mistrial));
        assertEq(uint8(_status(a2)), uint8(Briefs.BriefStatus.Queued));
        assertEq(b.getCase(c).stalledSince, block.timestamp);
        vm.warp(block.timestamp + 6 hours);
        uint256 before = imd.balanceOf(bob);
        b.skipStalled(c);
        assertEq(uint8(_status(a2)), uint8(Briefs.BriefStatus.Unheard));
        assertEq(imd.balanceOf(bob), before + FEE);
        vm.warp(b.getCase(c).endsAt);
        b.settle(c);
        assertEq(uint8(b.getCase(c).status), uint8(Briefs.CaseStatus.Settled));
    }

    /// 3: the treasury can't be the court itself, its jury or the jury's requester (the IMD would be stranded)
    function test_Swarm3_TreasuryCannotBeTheCourtItsJuryOrItsRequester() public {
        address[3] memory bad = [address(b), address(jury), address(requester)];
        for (uint256 i; i < bad.length; i++) {
            vm.expectRevert(Briefs.BadParams.selector);
            b.setTreasury(bad[i]);
        }
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        BriefsText t = new BriefsText(); // takes the nonce `next` was computed for: recompute
        next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(Briefs.BadParams.selector);
        new Briefs(IERC20(address(imd)), t, jury, next, _params());
        vm.expectRevert(Briefs.BadParams.selector);
        new Briefs(IERC20(address(imd)), t, jury, address(requester), _params());
        b.setTreasury(carol);
        assertEq(b.treasury(), carol);
    }

    /// 4: a case opens on the setup its creator named, or not at all (also test_OracleChangeIsDelayedAndPinnedPerCase)
    function test_Swarm4_ACaseNeverLandsOnASetupItsCreatorDidNotName() public {
        MockRequester r2 = new MockRequester(IERC20(address(imd)), ORACLE_FEE);
        jury.proposeOracle(_oracle(vm.addr(0xC0FFEE), r2));
        vm.warp(block.timestamp + 7 days);
        Briefs.CaseInput memory x = _input(uint64(block.timestamp + 1 days)); // built while setup 0 is live
        jury.applyOracle(); // anyone, in the same block, ahead of the creator
        vm.prank(creator);
        vm.expectRevert(Briefs.WrongOracle.selector);
        b.openCase(x);
        x.oracleId = 7; // a setup that doesn't exist yet
        vm.prank(creator);
        vm.expectRevert(Briefs.WrongOracle.selector);
        b.openCase(x);
    }

    /// 5: more look-alikes of the «» the question quotes with, and ASCII << >>, are refused
    function test_Swarm5_MoreQuoteLookAlikesAreRefused() public {
        BriefsText t = new BriefsText();
        uint24[14] memory cps =
            [uint24(0x2770), 0x2771, 0x276c, 0x276d, 0x29fc, 0x29fd, 0x22d8, 0x22d9, 0xfe64, 0xfe65, 0xff1c, 0xff1e, 0x02c2, 0x02c3];
        for (uint256 i; i < cps.length; i++) {
            vm.expectRevert(BriefsText.BadText.selector);
            t.check(bytes.concat("a", _utf8(cps[i]), "b"), 1, 500, 500);
        }
        vm.expectRevert(BriefsText.BadText.selector);
        t.check("lol>> A challenger's answer: ok", 1, 500, 500);
        vm.expectRevert(BriefsText.BadText.selector);
        t.check("ok << lol", 1, 500, 500);
        vm.expectRevert(BriefsText.BadText.selector);
        t.check(unicode"a <\u200a< b", 1, 500, 500); // a hair space between
        vm.expectRevert(BriefsText.BadText.selector);
        t.check(unicode"a >\u0332> b", 1, 500, 500); // a combining mark between
        t.check("1 < 2 > 0 and a <b> tag, x < <y>", 1, 500, 500); // single brackets, or with a plain space, stay fine
    }

    function _utf8(uint24 cp) internal pure returns (bytes memory) {
        if (cp < 0x800) return abi.encodePacked(bytes1(uint8(0xc0 | (cp >> 6))), bytes1(uint8(0x80 | (cp & 0x3f))));
        if (cp >= 0x10000) {
            return abi.encodePacked(
                bytes1(uint8(0xf0 | (cp >> 18))), bytes1(uint8(0x80 | ((cp >> 12) & 0x3f))),
                bytes1(uint8(0x80 | ((cp >> 6) & 0x3f))), bytes1(uint8(0x80 | (cp & 0x3f)))
            );
        }
        return abi.encodePacked(
            bytes1(uint8(0xe0 | (cp >> 12))), bytes1(uint8(0x80 | ((cp >> 6) & 0x3f))), bytes1(uint8(0x80 | (cp & 0x3f)))
        );
    }

    /// 6: skipStalled keeps the briefs it already handed back because the jury got dearer, and finishes the case
    function test_Swarm6_SkipStalledKeepsPriceSkipProgress() public {
        uint256 c = _case();
        for (uint256 i; i < 18; i++) _file(c, alice, string.concat(B1, " #", vm.toString(i))); // 1 heard, 17 queued
        requester.setFee(1 ether); // dearer than the case's 0.9 reserve
        vm.warp(b.getCase(c).endsAt + 3 days);
        b.mistrial(c); // hands back 16 of the 17
        assertEq(b.waiting(c), 1);
        assertEq(b.getCase(c).hearing, 0);
        b.skipStalled(c); // hands back the last one and settles, instead of reverting
        assertEq(b.waiting(c), 0);
        assertEq(uint8(b.getCase(c).status), uint8(Briefs.CaseStatus.Settled));
    }

    /// 7: a brief that would be skipped at once because the jury is dearer than the case's reserve is refused instead
    function test_Swarm7_FilingIntoACaseTheJuryIsTooDearForIsRefused() public {
        uint256 c = _case();
        requester.setFee(0.9 ether + 1);
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(Briefs.OracleTooExpensive.selector);
        b.fileBrief(c, B1);
        assertEq(imd.balanceOf(alice), before);
        requester.setFee(0.9 ether); // at the reserve: fine
        uint256 a1 = _file(c, alice, B1);
        assertEq(b.getCase(c).hearing, a1);
        requester.setFee(1 ether);
        uint256 a2 = _file(c, bob, B2); // a hearing is running: it queues (the price is checked when its turn comes)
        assertEq(uint8(_status(a2)), uint8(Briefs.BriefStatus.Queued));
    }

    /// 7, behind a stalled head: the new brief would be skipped in the same call too, so it is refused as well
    function test_Swarm7_FilingBehindAStalledHeadIsRefusedWhenTheJuryIsTooDear() public {
        uint256 c = _case();
        requester.setBroken(true);
        uint256 a1 = _file(c, alice, B1); // stalls at the head
        assertEq(b.getCase(c).hearing, 0);
        requester.setBroken(false);
        requester.setFee(1 ether);
        vm.prank(bob);
        vm.expectRevert(Briefs.OracleTooExpensive.selector);
        b.fileBrief(c, B2);
        b.hear(c); // the stalled one is handed back as before
        assertEq(uint8(_status(a1)), uint8(Briefs.BriefStatus.Unheard));
    }

    // ------------------------------------------------------------ IMD swarm re-audit (Oct 2026)

    /// R2: if IMD's price passes a running case's reserve, the owner raises maxOracleFee and anyone lifts the case
    function test_Reaudit_R2_ARunningCaseCanFollowARisenJuryPrice() public {
        uint256 c = _case();
        requester.setFee(1.2 ether);
        vm.prank(alice);
        vm.expectRevert(Briefs.OracleTooExpensive.selector);
        b.fileBrief(c, B1);
        vm.expectRevert(Briefs.BadParams.selector);
        b.raiseReserve(c); // nothing to raise to yet
        Briefs.Params memory p = _params();
        p.maxOracleFee = 1.5 ether;
        p.minFee = 2 ether;
        b.setParams(p);
        vm.prank(carol);
        b.raiseReserve(c); // anyone
        assertEq(b.getCase(c).reserve, 1.5 ether);
        uint256 a1 = _file(c, alice, B1);
        assertEq(b.getCase(c).hearing, a1);
        assertEq(b.getBrief(a1).oracleReserve, 1.2 ether); // the price actually paid
        _judge(a1, true);
        assertEq(b.getCase(c).pot, SEED + (FEE - 1.2 ether) * 8_000 / 10_000);
        // never at or above the case's fee, never down
        p.maxOracleFee = 5 ether;
        p.minFee = 6 ether;
        b.setParams(p);
        vm.expectRevert(Briefs.BadParams.selector);
        b.raiseReserve(c);
    }

    /// R3: an answer IMD delivered on chain has 6 hours to be relayed before a mistrial can void it
    function test_Reaudit_R3_ADeliveredAnswerGetsSixHours() public view {
        assertEq(b.DELIVERED_GRACE(), 6 hours);
    }

    /// R4: the text rules look characters up by range (plain ASCII takes a short path), so a full-length check stays
    ///     cheap, and the longest brief of any script opens its hearing within 6M (the site and keeper send 7M)
    function test_Reaudit_R4_TextRulesAreCheapAndTheLongestBriefFitsTheGasFloor() public {
        BriefsText t = new BriefsText();
        bytes memory x = bytes(_repeat("a", 600));
        uint256 g = gasleft();
        t.check(x, 1, 600, 600);
        assertLt(g - gasleft(), 300_000, "600 ASCII bytes");
        x = bytes(_repeat(unicode"ж", 300));
        g = gasleft();
        t.check(x, 1, 600, 600);
        assertLt(g - gasleft(), 700_000, "300 Cyrillic letters");
        uint256 c = _case();
        string[3] memory longest = [_repeat("a", 500), _repeat(unicode"ж", 250), _repeat(unicode"🐉", 125)];
        for (uint256 i; i < 3; i++) {
            vm.cool(address(b));
            vm.cool(address(imd));
            vm.prank(alice);
            uint256 id = b.fileBrief{gas: 6_000_000}(c, longest[i]);
            assertEq(b.getCase(c).hearing, id);
            _judge(id, false);
        }
    }

    function _repeat(string memory unit, uint256 n) internal pure returns (string memory out) {
        for (uint256 i; i < n; i++) out = string.concat(out, unit);
    }

    /// R5: see test_ASmallClockSkewIsTolerated in Gateway.t.sol (the skew applies with an on-chain answer source);
    ///     without one, the strict bound stays (anyone can buy an answer to the same question there)
    function test_Reaudit_R5_NoSkewWithoutAnOnChainSource() public {
        uint256 c = _case();
        uint256 a1 = _file(c, alice, B1);
        vm.warp(block.timestamp + 1 minutes);
        ImdOracle.AttestationV2 memory a = _attWith(a1, abi.encode(true), 11, 6, 6);
        a.issuedAt = b.getBrief(a1).heardAt - 1;
        bytes memory sig = _sign(key, a);
        vm.expectRevert(BriefsJury.AnsweredBeforeAsked.selector);
        b.fulfill(a1, a, sig);
    }

    /// R6: more invisible format characters, noncharacters, private use and look-alikes of «» are refused
    function test_Reaudit_R6_MoreTextGapsAreClosed() public {
        BriefsText t = new BriefsText();
        uint24[26] memory cps = [
            uint24(0x206a), 0x206f, 0x1bca0, 0x1bca3, 0xfff0, 0xfff8, 0xe0080, 0xe0fff, 0x2af7, 0x2af8, 0x2991, 0x2992,
            0x2995, 0x2996, 0x1438, 0x1433, 0xfe3f, 0xfe40, 0xffff, 0xfffe, 0xfdd0, 0xfdef, 0x1ffff, 0xe000, 0xf0000, 0x10ffff
        ];
        for (uint256 i; i < cps.length; i++) {
            vm.expectRevert(BriefsText.BadText.selector);
            t.check(bytes.concat("a", _utf8(cps[i]), "b"), 1, 500, 500);
        }
        t.check(bytes.concat("a", _utf8(0x1f409), _utf8(0xfdcf), _utf8(0xfdf0), "b"), 1, 500, 500); // around them: fine
    }

    // ------------------------------------------------------------ own audit before the redeploy (Oct 2026)

    /// a raise applies to briefs filed after it: one already queued never pays the jury more than it reserved
    function test_Own_ARaiseNeverChargesAQueuedBriefMoreThanItReserved() public {
        uint256 c = _case();
        uint256 a1 = _file(c, alice, B1); // heard
        uint256 b1 = _file(c, bob, B2); // queued with the 0.9 reserve
        requester.setFee(0.95 ether);
        Briefs.Params memory p = _params();
        p.maxOracleFee = 0.99 ether;
        b.setParams(p);
        b.raiseReserve(c);
        uint256 before = imd.balanceOf(bob);
        _judge(a1, true);
        assertEq(uint8(_status(b1)), uint8(Briefs.BriefStatus.Unheard)); // handed back, whole fee
        assertEq(imd.balanceOf(bob), before + FEE);
        uint256 c1 = _file(c, carol, "A new brief, filed after the raise"); // reserves 0.99: heard at 0.95
        assertEq(b.getCase(c).hearing, c1);
        assertEq(b.getBrief(c1).oracleReserve, 0.95 ether);
    }

    /// IMD swarm audit 3, finding 1: after skipStalled hands the head back, the next brief's wait starts at once
    function test_Own_SkipStalledStartsTheNextBriefsWait() public {
        uint256 c = _case();
        requester.setBroken(true); // the oracle is down
        uint256 t0 = block.timestamp;
        uint256 a1 = _file(c, alice, B1);
        uint256 b1 = _file(c, bob, B2);
        vm.warp(t0 + 6 hours);
        b.skipStalled(c);
        assertEq(uint8(_status(a1)), uint8(Briefs.BriefStatus.Unheard));
        assertEq(b.getCase(c).stalledSince, t0 + 6 hours);
        vm.warp(t0 + 12 hours - 1);
        vm.expectRevert(Briefs.TooEarly.selector);
        b.skipStalled(c);
        vm.warp(t0 + 12 hours);
        b.skipStalled(c);
        assertEq(uint8(_status(b1)), uint8(Briefs.BriefStatus.Unheard));
    }

    /// IMD swarm audit 3, finding 3: << or >> with any non-ASCII between them (a mark of any script) is refused
    function test_Own_NoMarkOfAnyScriptBetweenAngleBrackets() public {
        BriefsText t = new BriefsText();
        bytes[13] memory marks = [
            bytes(hex"d283"), hex"d288", hex"d6b0", hex"d98b", hex"e0a58d", hex"e0b8b1", hex"e0b8b4", hex"e0bdb1",
            hex"e38299", hex"ea99b0", hex"f09d85a5", hex"f09d85a7", hex"cc81"
        ];
        for (uint256 i; i < marks.length; i++) {
            vm.expectRevert(BriefsText.BadText.selector);
            t.check(bytes.concat("a<", marks[i], "<b"), 1, 500, 500);
            vm.expectRevert(BriefsText.BadText.selector);
            t.check(bytes.concat("a>", marks[i], marks[i], ">b"), 1, 500, 500);
        }
        t.check(bytes.concat("a<", hex"d283", "x<b"), 1, 500, 500); // an ASCII letter between: fine
        t.check("x < <y>", 1, 500, 500);
    }

    /// IMD swarm audit 3, finding 4: the treasury can't be the IMD token or the text contract either
    function test_Own_TreasuryCannotBeTheTokenOrTheText() public {
        vm.expectRevert(Briefs.BadParams.selector);
        b.setTreasury(address(imd));
        address text = address(b.text());
        vm.expectRevert(Briefs.BadParams.selector);
        b.setTreasury(text);
    }

    /// a hearing may get at most 4M gas (the site and the keeper send 7M on calls that may open one)
    function test_Own_HearingGasIsCappedForTheGasTheSiteSends() public {
        BriefsJury.Oracle memory o = _oracle(vm.addr(key), requester);
        o.hearingGas = 4_000_001;
        vm.expectRevert(BriefsJury.BadOracle.selector);
        jury.proposeOracle(o);
        o.hearingGas = 4_000_000;
        jury.proposeOracle(o);
    }

    // ------------------------------------------------------------ time as the leader, final share, overtime

    function _reignParams() internal {
        Briefs.Params memory p = _params();
        p.reignBps = 6_000;
        p.overtime = 10 minutes;
        b.setParams(p);
        inReign = 6_000;
        inOvertime = 10 minutes;
    }

    /// files at `t`: time as the leader counts from when a brief was filed
    function _fileAt(uint256 c, address who, string memory words, uint256 t) internal returns (uint256) {
        vm.warp(t);
        return _file(c, who, words);
    }

    /// the verdict on `briefId` lands at `t`
    function _verdictAt(uint256 briefId, bool better, uint256 t) internal {
        vm.warp(t);
        (ImdOracle.AttestationV2 memory a, bytes memory sig) = _att(briefId, better);
        vm.prank(keeper);
        b.fulfill(briefId, a, sig);
    }

    /// 24 h case: alice leads from 6 h to 12 h, bob from 12 h to the end. The first 6 h are nobody's, so the pool for
    /// time as the leader is 60% × 18/24 of the pot, split 6:12; the final leader (bob) also takes the rest
    function test_Reign_ThePotIsSplitByTimeAsTheLeaderAndTheFinalLeader() public {
        _reignParams();
        uint256 t0 = block.timestamp;
        uint256 c = _case();
        uint256 a1 = _fileAt(c, alice, B1, t0 + 6 hours);
        _verdictAt(a1, true, t0 + 6 hours); // alice takes the lead
        uint256 b1 = _fileAt(c, bob, B2, t0 + 12 hours);
        _verdictAt(b1, true, t0 + 12 hours); // bob takes it from her
        uint256 c1 = _fileAt(c, carol, "A third brief", t0 + 20 hours);
        _verdictAt(c1, false, t0 + 20 hours); // denied: bob keeps leading
        vm.warp(t0 + 1 days);
        uint256 pot = b.getCase(c).pot;
        assertEq(pot, SEED + 3 * TO_POT);
        uint256 bobBefore = imd.balanceOf(bob);
        b.settle(c);
        Briefs.Case memory k = b.getCase(c);
        assertEq(k.reignTotal, 18 hours);
        assertEq(k.reignPool, (pot * 6_000 * 18 hours) / (10_000 * 24 hours)); // 45% of the pot
        assertEq(b.reignOf(c, alice), 6 hours);
        assertEq(b.reignOf(c, bob), 12 hours);
        assertEq(b.reignOf(c, creator), 0); // the opening brief earns no time
        assertEq(imd.balanceOf(bob), bobBefore + pot - k.reignPool); // the final share, pushed at settlement
        uint256 aliceBefore = imd.balanceOf(alice);
        vm.prank(carol);
        b.claimReign(c, alice); // anyone may pay it out
        assertEq(imd.balanceOf(alice), aliceBefore + k.reignPool / 3);
        b.claimReign(c, bob);
        assertEq(imd.balanceOf(bob), bobBefore + pot - k.reignPool + (k.reignPool * 2) / 3);
        vm.expectRevert(Briefs.NothingToClaim.selector);
        b.claimReign(c, bob); // once
        vm.expectRevert(Briefs.NothingToClaim.selector);
        b.claimReign(c, carol); // never led
        assertLe(b.getCase(c).reignPaid, k.reignPool);
        assertLt(k.reignPool - b.getCase(c).reignPaid, 3); // rounding dust only
    }

    /// nobody ever took the lead: the creator's opening brief takes the whole pot, as before
    function test_Reign_NoChallengerWinsThenTheWholePotGoesToTheOpeningBrief() public {
        _reignParams();
        uint256 c = _case();
        _judge(_file(c, alice, B1), false);
        vm.warp(b.getCase(c).endsAt);
        uint256 before = imd.balanceOf(creator);
        uint256 pot = b.getCase(c).pot;
        b.settle(c);
        assertEq(b.getCase(c).reignPool, 0);
        assertEq(imd.balanceOf(creator), before + pot);
    }

    /// a new leader in the last 10 minutes pushes the deadline to now + 10 minutes, again and again, with no cap;
    /// entries stay open meanwhile and the extra time counts as time as the leader
    function test_Reign_OvertimeKeepsTheEndAlive() public {
        _reignParams();
        uint256 c = _case();
        uint256 end0 = b.getCase(c).endsAt;
        uint256 a1 = _fileAt(c, alice, B1, end0 - 11 minutes);
        _verdictAt(a1, true, end0 - 11 minutes); // not in the last 10 minutes: no overtime
        assertEq(b.getCase(c).endsAt, end0);
        uint256 b1 = _fileAt(c, bob, B2, end0 - 4 minutes);
        _verdictAt(b1, true, end0 - 4 minutes);
        assertEq(b.getCase(c).endsAt, end0 + 6 minutes); // now + 10 min
        uint256 t = end0 - 4 minutes;
        for (uint256 i; i < 20; i++) {
            // past the original deadline, entries are still open
            address who = i % 2 == 0 ? carol : alice;
            t = b.getCase(c).endsAt - 1;
            uint256 id = _fileAt(c, who, string.concat("Overtime brief ", vm.toString(i)), t);
            _verdictAt(id, true, t);
            assertEq(b.getCase(c).endsAt, t + 10 minutes);
        }
        uint256 end = b.getCase(c).endsAt;
        assertGt(end, end0 + 3 hours); // no cap
        vm.warp(end);
        vm.prank(bob);
        vm.expectRevert(Briefs.EntriesClosed.selector);
        b.fileBrief(c, "Too late");
        b.settle(c);
        Briefs.Case memory k = b.getCase(c);
        // time in the lead stops at the first deadline: the hours of overtime only decided the final leader
        assertEq(k.reignTotal, 11 minutes);
        assertEq(b.reignOf(c, alice), 7 minutes);
        assertEq(b.reignOf(c, bob), 4 minutes);
        assertEq(b.reignOf(c, alice) + b.reignOf(c, bob) + b.reignOf(c, carol), k.reignTotal);
        // the 20 briefs filed in overtime fed the final leader only: the pool counts the first two
        assertEq(k.overtimePot, 20 * TO_POT);
        assertEq(k.reignPool, (SEED + 2 * TO_POT) * 6_000 * 11 minutes / (10_000 * (end0 - k.createdAt)));
    }

    /// a brief filed before the deadline but heard after it can still take the lead and the final share; its time
    /// counts from its filing to the deadline, and it adds no overtime
    function test_Reign_ALeaderHeardAfterTheDeadlineTakesTheFinalShareAndTimeFromItsFiling() public {
        _reignParams();
        uint256 t0 = block.timestamp;
        uint256 c = _case();
        uint256 a1 = _fileAt(c, alice, B1, t0 + 1 hours);
        _verdictAt(a1, true, t0 + 1 hours);
        uint256 end = b.getCase(c).endsAt;
        uint256 b1 = _fileAt(c, bob, B2, end - 1 hours); // its verdict lands after the deadline
        _verdictAt(b1, true, end + 1 minutes);
        assertEq(b.getCase(c).endsAt, end); // no overtime after the deadline
        assertEq(uint8(b.getCase(c).status), uint8(Briefs.CaseStatus.Settled)); // the docket is clear: settled
        Briefs.Case memory k = b.getCase(c);
        assertEq(k.winner, bob);
        assertEq(b.reignOf(c, alice), end - 1 hours - (t0 + 1 hours)); // alice led until bob filed
        assertEq(b.reignOf(c, bob), 1 hours); // bob from his filing to the deadline
        assertEq(k.reignTotal, end - (t0 + 1 hours));
    }

    /// a leader can't keep the lead longer by stuffing the queue: a challenger's time starts when it filed, however
    /// long it waited behind the leader's own briefs
    function test_Reign_StuffingTheQueueBuysTheLeaderNothing() public {
        _reignParams();
        uint256 t0 = block.timestamp;
        uint256 c = _case();
        _verdictAt(_fileAt(c, alice, B1, t0 + 1 hours), true, t0 + 1 hours);
        vm.warp(t0 + 2 hours);
        uint256 a2 = _file(c, alice, "Alice blocks the queue"); // heard first
        uint256 b1 = _file(c, bob, B2); // waits behind it
        _verdictAt(a2, false, t0 + 8 hours); // a slow hearing
        _verdictAt(b1, true, t0 + 8 hours);
        vm.warp(t0 + 1 days);
        b.settle(c);
        assertEq(b.reignOf(c, alice), 1 hours); // 1 h to 2 h, not until bob's verdict
        assertEq(b.reignOf(c, bob), 22 hours);
    }

    /// leading twice adds up
    function test_Reign_LeadingTwiceAddsUp() public {
        _reignParams();
        uint256 t0 = block.timestamp;
        uint256 c = _case();
        _verdictAt(_fileAt(c, alice, B1, t0 + 1 hours), true, t0 + 1 hours);
        _verdictAt(_fileAt(c, bob, B2, t0 + 3 hours), true, t0 + 3 hours);
        _verdictAt(_fileAt(c, alice, "Alice strikes back", t0 + 4 hours), true, t0 + 4 hours);
        vm.warp(t0 + 1 days);
        b.settle(c);
        assertEq(b.reignOf(c, alice), 2 hours + 20 hours);
        assertEq(b.reignOf(c, bob), 1 hours);
    }

    // ------------------------------------------------------------ briefs filed for their author (paid elsewhere)

    uint256 constant DAN_KEY = 0xDA;

    function _relaySig(uint256 pk, uint256 c, string memory words, uint256 deadline) internal view returns (bytes memory) {
        string memory m = jury.relayMessage(c, words, vm.addr(pk), deadline);
        (uint8 v, bytes32 r, bytes32 s_) = vm.sign(pk, MessageHashUtils.toEthSignedMessageHash(bytes(m)));
        return abi.encodePacked(r, s_, v);
    }

    /// the author signs; the relayer (keeper) pays: the brief is the author's, the relayer's IMD pays the fee
    function test_Relay_ARelayerFilesASignedBriefForItsAuthor() public {
        address dan = vm.addr(DAN_KEY); // no IMD, no approval: pays on another chain
        uint256 c = _case();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _relaySig(DAN_KEY, c, B1, deadline);
        assertEq(
            jury.relayMessage(c, B1, dan, deadline),
            string.concat(
                "File this brief on briefs.fun\nCase: ", vm.toString(c), "\nAuthor: ", vm.toLowercase(vm.toString(dan)),
                "\nValid until (unix time): ", vm.toString(deadline),
                "\nCourt: ", vm.toLowercase(vm.toString(address(b))), " on chain ", vm.toString(block.chainid), "\n\n", B1
            )
        );
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice); // alice relays
        uint256 id = b.fileBriefFor(c, B1, dan, deadline, sig);
        assertEq(b.getBrief(id).author, dan);
        assertEq(imd.balanceOf(alice), before - FEE);
        assertEq(imd.balanceOf(dan), 0);
        // once only
        vm.prank(alice);
        vm.expectRevert(BriefsJury.BadSignature.selector);
        b.fileBriefFor(c, B1, dan, deadline, sig);
        // dan takes the lead and the pot, though he never paid here
        _judge(id, true);
        vm.warp(b.getCase(c).endsAt);
        uint256 pot = b.getCase(c).pot;
        b.settle(c);
        assertEq(imd.balanceOf(dan), pot);
    }

    function test_Relay_OnlyTheSignedBriefForTheSignedCaseInTime() public {
        address dan = vm.addr(DAN_KEY);
        uint256 c = _case();
        uint256 c2 = _case();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _relaySig(DAN_KEY, c, B1, deadline);
        vm.startPrank(alice);
        vm.expectRevert(BriefsJury.BadSignature.selector);
        b.fileBriefFor(c, B2, dan, deadline, sig); // other words
        vm.expectRevert(BriefsJury.BadSignature.selector);
        b.fileBriefFor(c2, B1, dan, deadline, sig); // other case
        vm.expectRevert(BriefsJury.BadSignature.selector);
        b.fileBriefFor(c, B1, bob, deadline, sig); // credited to someone else
        vm.expectRevert(BriefsJury.BadSignature.selector);
        b.fileBriefFor(c, B1, dan, deadline + 1, sig); // stretched deadline
        vm.expectRevert(BriefsJury.BadSignature.selector);
        b.fileBriefFor(c, B1, dan, deadline, hex"1234"); // junk
        vm.stopPrank();
        // another wallet signing the very same words, case and deadline files its own brief, and doesn't use up dan's
        uint256 eveKey = 0xE7E;
        bytes memory eveSig = _relaySig(eveKey, c, B1, deadline);
        vm.prank(alice);
        b.fileBriefFor(c, B1, vm.addr(eveKey), deadline, eveSig);
        vm.prank(alice);
        uint256 mine = b.fileBriefFor(c, B1, dan, deadline, sig);
        assertEq(b.getBrief(mine).author, dan);
        vm.warp(deadline + 1);
        bytes memory late = _relaySig(DAN_KEY, c, B2, deadline);
        vm.prank(alice);
        vm.expectRevert(BriefsJury.Expired.selector);
        b.fileBriefFor(c, B2, dan, deadline, late);
        // only Briefs may spend a signature
        bytes memory fresh = _relaySig(DAN_KEY, c, B1, deadline + 1 hours);
        vm.expectRevert(BriefsJury.WrongCourt.selector);
        jury.useRelay(c, B1, dan, deadline + 1 hours, fresh);
    }

    /// a refund (jury split here) goes to the author, not the relayer
    function test_Relay_RefundsGoToTheAuthor() public {
        address dan = vm.addr(DAN_KEY);
        uint256 c = _case();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _relaySig(DAN_KEY, c, B1, deadline);
        vm.prank(alice);
        uint256 id = b.fileBriefFor(c, B1, dan, deadline, sig);
        vm.warp(block.timestamp + 4 minutes + 2 minutes + 1);
        uint256 aliceBefore = imd.balanceOf(alice);
        b.mistrial(c);
        assertEq(imd.balanceOf(dan), FEE - ORACLE_FEE);
        assertEq(imd.balanceOf(alice), aliceBefore);
        assertEq(uint8(b.getBrief(id).status), uint8(Briefs.BriefStatus.Mistrial));
    }

    // ------------------------------------------------------------ who sets the share and the final cap

    /// the owner's settings: a creator must ask for exactly them (they may have changed since the creator looked)
    function test_Settings_OwnerModeTakesTheOwnersNumbersOnly() public {
        _reignParams();
        inReign = 5_000;
        vm.prank(creator);
        vm.expectRevert(Briefs.SettingsChanged.selector);
        b.openCase(_input(uint64(block.timestamp + 1 days)));
        inReign = 6_000;
        inCap = 1 hours;
        vm.prank(creator);
        vm.expectRevert(Briefs.SettingsChanged.selector);
        b.openCase(_input(uint64(block.timestamp + 1 days)));
        inCap = 0;
        uint256 c = _case();
        assertEq(b.getCase(c).reignBps, 6_000);
        assertEq(b.getCase(c).finalEnd, 0);
    }

    function test_Settings_CreatorsPickTheShareWhenAllowed() public {
        Briefs.Params memory p = _params();
        p.creatorSetsReign = true;
        p.reignBps = 6_000; // ignored in this mode
        b.setParams(p);
        inReign = 2_500;
        uint256 c = _case();
        assertEq(b.getCase(c).reignBps, 2_500);
        inReign = 0;
        assertEq(b.getCase(_case()).reignBps, 0); // all to the final leader
        inReign = 9_001; // the final leader always keeps 10%
        vm.prank(creator);
        vm.expectRevert(Briefs.SettingsChanged.selector);
        b.openCase(_input(uint64(block.timestamp + 1 days)));
    }

    /// the owner turns on a final limit: overtime stops 15 minutes after the first deadline
    function test_Settings_TheFinalCapStopsOvertime() public {
        Briefs.Params memory p = _params();
        p.reignBps = 6_000;
        p.overtime = 10 minutes;
        p.finalCap = 15 minutes;
        b.setParams(p);
        inReign = 6_000;
        inCap = 15 minutes;
        inOvertime = 10 minutes;
        uint256 c = _case();
        uint256 end0 = b.getCase(c).endsAt;
        assertEq(b.getCase(c).finalEnd, end0 + 15 minutes);
        _verdictAt(_fileAt(c, alice, B1, end0 - 1 minutes), true, end0 - 1 minutes);
        assertEq(b.getCase(c).endsAt, end0 + 9 minutes);
        _verdictAt(_fileAt(c, bob, B2, end0 + 8 minutes), true, end0 + 8 minutes);
        assertEq(b.getCase(c).endsAt, end0 + 15 minutes); // not +18: capped
        _verdictAt(_fileAt(c, carol, "A third brief", end0 + 14 minutes), true, end0 + 14 minutes);
        assertEq(b.getCase(c).endsAt, end0 + 15 minutes); // stays at the cap
        vm.warp(end0 + 15 minutes);
        vm.prank(alice);
        vm.expectRevert(Briefs.EntriesClosed.selector);
        b.fileBrief(c, "Too late");
        b.settle(c);
        assertEq(b.getCase(c).winner, carol);
    }

    /// creators pick the final cap (0: none) when the owner allows it
    function test_Settings_CreatorsPickTheFinalCapWhenAllowed() public {
        Briefs.Params memory p = _params();
        p.overtime = 10 minutes;
        p.finalCap = 1 hours; // ignored in this mode
        p.creatorSetsCap = true;
        b.setParams(p);
        inCap = 5 minutes;
        inOvertime = 10 minutes;
        uint256 c = _case();
        uint256 end0 = b.getCase(c).endsAt;
        _verdictAt(_fileAt(c, alice, B1, end0 - 1 minutes), true, end0 - 1 minutes);
        assertEq(b.getCase(c).endsAt, end0 + 5 minutes);
        inCap = 0;
        uint256 c2 = _case();
        assertEq(b.getCase(c2).finalEnd, 0);
        inCap = 365 days + 1;
        vm.prank(creator);
        vm.expectRevert(Briefs.SettingsChanged.selector);
        b.openCase(_input(uint64(block.timestamp + 1 days)));
    }

    function test_Settings_Bounds() public {
        Briefs.Params memory p = _params();
        p.finalCap = 365 days + 1;
        vm.expectRevert(Briefs.BadParams.selector);
        b.setParams(p);
        p.finalCap = 365 days;
        b.setParams(p);
        vm.prank(alice);
        vm.expectRevert();
        b.setParams(p);
    }

    /// a leader can't stretch the case to dilute what earlier leaders earned: time stops at the first deadline
    function test_Reign_OvertimeEarnsNoTimeAndDilutesNobody() public {
        _reignParams();
        uint256 c = _case();
        Briefs.Case memory k0 = b.getCase(c);
        uint256 end0 = k0.endsAt;
        _verdictAt(_fileAt(c, alice, B1, k0.createdAt + 1 hours), true, k0.createdAt + 1 hours);
        _verdictAt(_fileAt(c, bob, B2, end0 - 5 minutes), true, end0 - 5 minutes);
        for (uint256 i; i < 30; i++) { // bob keeps beating himself in overtime
            uint256 id = _fileAt(c, bob, string.concat("Bob again ", vm.toString(i)), b.getCase(c).endsAt - 1);
            _verdictAt(id, true, b.getCase(c).endsAt - 1);
        }
        assertGt(b.getCase(c).endsAt, end0 + 4 hours);
        vm.warp(b.getCase(c).endsAt);
        b.settle(c);
        Briefs.Case memory k = b.getCase(c);
        assertEq(b.reignOf(c, alice), end0 - 5 minutes - (k0.createdAt + 1 hours));
        assertEq(b.reignOf(c, bob), 5 minutes);
        assertEq(k.reignTotal, end0 - (k0.createdAt + 1 hours));
        // the pool is measured against the first deadline, and what overtime added goes to the final leader alone
        uint256 pot = SEED + 2 * TO_POT;
        assertEq(k.overtimePot, 30 * TO_POT);
        assertEq(k.reignPool, (pot * 6_000 * k.reignTotal) / (10_000 * (end0 - k0.createdAt)));
    }

    /// a COOKED during overtime makes the final leader and pushes the deadline, but earns no time
    function test_Reign_ALeadTakenInOvertimeEarnsNoTime() public {
        _reignParams();
        uint256 c = _case();
        uint256 end0 = b.getCase(c).endsAt;
        _verdictAt(_fileAt(c, alice, B1, end0 - 2 minutes), true, end0 - 2 minutes); // pushes to end0 + 8 min
        _verdictAt(_fileAt(c, bob, B2, end0 + 3 minutes), true, end0 + 3 minutes); // in overtime
        assertEq(b.getCase(c).endsAt, end0 + 13 minutes);
        vm.warp(end0 + 13 minutes);
        b.settle(c);
        assertEq(b.getCase(c).winner, bob);
        assertEq(b.reignOf(c, alice), 2 minutes);
        assertEq(b.reignOf(c, bob), 0);
    }

    /// IMD paid in overtime goes to the final leader alone; a brief filed before the deadline and heard in overtime
    /// still feeds the pool for time in the lead
    function test_Reign_OvertimeEntriesPayOnlyTheFinalLeader() public {
        _reignParams();
        uint256 c = _case();
        uint256 end0 = b.getCase(c).endsAt;
        _verdictAt(_fileAt(c, alice, B1, end0 - 9 hours), true, end0 - 9 hours);
        _verdictAt(_fileAt(c, bob, B2, end0 - 3 minutes), true, end0 - 3 minutes); // overtime to end0 + 7 min
        uint256 late = _fileAt(c, carol, "Filed on time", end0 - 1 minutes);
        _verdictAt(late, false, end0 + 1 minutes); // filed on time, heard in overtime: counts for the pool
        uint256 t = end0 + 2 minutes;
        _verdictAt(_fileAt(c, carol, "Overtime one", t), false, t);
        _verdictAt(_fileAt(c, alice, "Overtime two", t + 1), false, t + 1);
        vm.warp(b.getCase(c).endsAt);
        b.settle(c);
        Briefs.Case memory k = b.getCase(c);
        assertEq(k.overtimePot, 2 * TO_POT);
        uint256 base = SEED + 3 * TO_POT;
        assertEq(k.reignPool, (base * 6_000 * k.reignTotal) / (10_000 * (end0 - k.createdAt)));
        assertEq(k.winner, bob);
    }

    /// overtime is pinned like the share and the limit: the owner can't change it under a pending openCase
    function test_Settings_OvertimeIsWhatTheCreatorSaw() public {
        _reignParams();
        inOvertime = 1 hours;
        vm.prank(creator);
        vm.expectRevert(Briefs.SettingsChanged.selector);
        b.openCase(_input(uint64(block.timestamp + 1 days)));
    }

    /// a relayer that refunds does it through the jury: the chain records what was paid back, and the message can
    /// never be filed after; a filed one can't be refunded
    function test_Relay_ARefundedSignatureCanNeverBeFiled() public {
        address dan = vm.addr(DAN_KEY);
        uint256 c = _case();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _relaySig(DAN_KEY, c, B1, deadline);
        bytes32 h = MessageHashUtils.toEthSignedMessageHash(bytes(jury.relayMessage(c, B1, dan, deadline)));
        vm.prank(carol);
        imd.approve(address(jury), type(uint256).max);
        vm.prank(carol); // a refund of nothing would cancel the brief for free
        vm.expectRevert(BriefsJury.NothingToRefund.selector);
        jury.refundRelay(c, B1, dan, deadline, sig, 0);
        assertEq(jury.relayed(h), 0);
        vm.prank(carol); // anyone holding the signature, paying the refund
        jury.refundRelay(c, B1, dan, deadline, sig, 2 ether);
        assertEq(jury.relayed(h), 2);
        assertEq(jury.refunded(h), 2 ether);
        assertEq(imd.balanceOf(dan), 2 ether);
        vm.prank(carol); // a top-up adds to the record
        jury.refundRelay(c, B1, dan, deadline, sig, 1 ether);
        assertEq(jury.refunded(h), 3 ether);
        vm.prank(alice);
        vm.expectRevert(BriefsJury.BadSignature.selector);
        b.fileBriefFor(c, B1, dan, deadline, sig);
        // filed first: then it can't be refunded
        bytes memory sig2 = _relaySig(DAN_KEY, c, B2, deadline);
        vm.prank(alice);
        b.fileBriefFor(c, B2, dan, deadline, sig2);
        vm.prank(carol);
        vm.expectRevert(BriefsJury.BadSignature.selector);
        jury.refundRelay(c, B2, dan, deadline, sig2, 1 ether);
        // a forged signature refunds nobody, and the jury never holds IMD
        bytes memory forged = _relaySig(0xBAD, c, "Something else", deadline);
        vm.prank(carol);
        vm.expectRevert(BriefsJury.BadSignature.selector);
        jury.refundRelay(c, "Something else", dan, deadline, forged, 1 ether);
        assertEq(imd.balanceOf(address(jury)), 0);
    }

    // random cases (share, overtime, limit, who files, when, verdicts, mistrials): seconds add up to the total, claims
    // never pass the pool, the deadline never passes its limit, and the contract holds exactly what it owes
    // (from the v2 audit, part A)
    address[5] who5;

    function testFuzz_Reign_TheBooksAlwaysBalance(uint256 seed) public {
        Briefs.Params memory p = _params();
        p.overtime = uint32(bound(seed, 0, 1 hours));
        p.creatorSetsReign = true;
        p.creatorSetsCap = true;
        b.setParams(p);
        inOvertime = p.overtime;
        inReign = uint16(uint256(keccak256(abi.encode(seed, "r"))) % 9_001);
        inCap = uint32(uint256(keccak256(abi.encode(seed, "c"))) % 3 hours);
        uint256 c = _case();
        who5 = [creator, alice, bob, carol, keeper];
        vm.prank(keeper);
        imd.approve(address(b), type(uint256).max);
        imd.transfer(keeper, 1_000 ether);

        uint256 steps = 1 + uint256(keccak256(abi.encode(seed, "n"))) % 14;
        for (uint256 i; i < steps; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            Briefs.Case memory k = b.getCase(c);
            if (k.status != Briefs.CaseStatus.Open) break;
            // jump: often small (end-game), sometimes hours
            uint256 dt = r % 4 == 0 ? 30 + (r >> 8) % 10 hours : 30 + (r >> 8) % 15 minutes;
            if (block.timestamp + 1 < k.endsAt) {
                uint256 near = (r >> 40) % 3 == 0 ? k.endsAt - 1 - (r >> 48) % 20 minutes : block.timestamp;
                if (near > block.timestamp) vm.warp(near);
                uint256 id = _file(c, who5[(r >> 16) % 5], string.concat("brief ", vm.toString(i)));
                if (b.getCase(c).hearing != id) break;
                uint256 kind = (r >> 24) % 5;
                if (kind == 0) {
                    vm.warp(block.timestamp + 6 minutes + 1);
                    b.mistrial(c);
                } else {
                    _verdictAt(id, kind != 1, block.timestamp + dt);
                }
            } else {
                break;
            }
        }
        Briefs.Case memory k2 = b.getCase(c);
        if (k2.status == Briefs.CaseStatus.Open) {
            if (k2.hearing != 0) _verdictAt(k2.hearing, true, block.timestamp + 31);
            if (block.timestamp < b.getCase(c).endsAt) vm.warp(b.getCase(c).endsAt);
            if (b.getCase(c).status == Briefs.CaseStatus.Open) b.settle(c);
        }
        k2 = b.getCase(c);
        uint256 sum;
        assertLe(k2.firstReign == 0 ? 0 : k2.reignEnd - k2.firstReign, k2.reignEnd - k2.createdAt);
        for (uint256 j; j < 5; j++) sum += b.reignOf(c, who5[j]);
        assertEq(sum, k2.reignTotal, "seconds add up");
        if (k2.finalEnd != 0) assertLe(k2.endsAt, k2.finalEnd);
        for (uint256 j; j < 5; j++) {
            if (b.reignOf(c, who5[j]) != 0) b.claimReign(c, who5[j]);
        }
        k2 = b.getCase(c);
        assertLe(k2.reignPaid, k2.reignPool);
        assertLt(k2.reignPool - k2.reignPaid, 5);
        assertEq(
            imd.balanceOf(address(b)),
            b.platformOwed() + k2.creatorOwed + (k2.reignPool - k2.reignPaid) + b.unpaidTotal(),
            "solvent to the wei"
        );
    }

    // ------------------------------------------------------------ a case's language and brief limit

    /// an English case with a 100-character limit: plain ASCII only, at most 100 characters, and the jury is told
    function test_Lang_AnEnglishCaseTakesShortEnglishBriefsOnly() public {
        inLang = 1;
        inMax = 100;
        uint256 c = _case();
        assertEq(b.langOf(c), 1);
        assertEq(b.getCase(c).maxBrief, 100);
        vm.startPrank(alice);
        vm.expectRevert(BriefsText.NotEnglish.selector);
        b.fileBrief(c, unicode"Драконы не пользуются банками");
        vm.expectRevert(BriefsText.NotEnglish.selector);
        b.fileBrief(c, unicode"A dragon walks into a café");
        vm.expectRevert(BriefsText.BadText.selector);
        b.fileBrief(c, string(_repeat("a", 101)));
        uint256 id = b.fileBrief(c, string(_repeat("a", 100)));
        vm.stopPrank();
        string memory q = jury.question(id, b.getCase(c).precedent);
        assertTrue(_contains(q, unicode"» Answers must be written in English. The current leader's answer: «"));
        _judge(id, true); // the attestation is checked against the English question
        assertEq(b.getCase(c).precedent, id);
    }

    /// any language (the default) asks exactly the question v1 asked, and takes any script
    function test_Lang_AnyLanguageKeepsTheQuestionAsItWas() public {
        uint256 c = _case();
        assertEq(b.langOf(c), 0);
        uint256 id = _file(c, alice, unicode"Драконы не пользуются банками");
        string memory q = jury.question(id, b.getCase(c).precedent);
        assertFalse(_contains(q, "English"));
        assertTrue(_contains(q, unicode"» The current leader's answer: «"));
    }

    function test_Lang_ALimitComesWithALanguageWithinBounds() public {
        inMax = 100; // a limit without a language
        vm.prank(creator);
        vm.expectRevert(BriefsText.BadText.selector);
        b.openCase(_input(uint64(block.timestamp + 1 days)));
        inLang = 1;
        inMax = 19; // under MIN_LIMIT
        vm.prank(creator);
        vm.expectRevert(BriefsText.BadText.selector);
        b.openCase(_input(uint64(block.timestamp + 1 days)));
        inMax = 501; // over the court's maxBrief (500 here)
        vm.prank(creator);
        vm.expectRevert(BriefsText.BadText.selector);
        b.openCase(_input(uint64(block.timestamp + 1 days)));
        inMax = 0; // English with the court's limit
        assertEq(b.getCase(_case()).maxBrief, 500);
        inLang = 2; // no such language yet
        vm.prank(creator);
        vm.expectRevert(BriefsText.UnknownLanguage.selector);
        b.openCase(_input(uint64(block.timestamp + 1 days)));
    }

    function test_Lang_TheOpeningBriefAndRelayedBriefsFollowTheLanguage() public {
        inLang = 1;
        Briefs.CaseInput memory x = _input(uint64(block.timestamp + 1 days));
        x.opening = unicode"Драконы";
        vm.prank(creator);
        vm.expectRevert(BriefsText.NotEnglish.selector);
        b.openCase(x);
        uint256 c = _case();
        address dan = vm.addr(DAN_KEY);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _relaySig(DAN_KEY, c, unicode"Ça va", deadline);
        vm.prank(alice);
        vm.expectRevert(BriefsText.NotEnglish.selector);
        b.fileBriefFor(c, unicode"Ça va", dan, deadline, sig);
    }

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        for (uint256 i; i + n.length <= h.length; i++) {
            bool ok = true;
            for (uint256 j; j < n.length && ok; j++) ok = h[i + j] == n[j];
            if (ok) return true;
        }
        return false;
    }
}
