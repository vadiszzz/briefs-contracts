// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

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
            minDuration: 10 minutes, maxDuration: 90 days, maxBrief: 500
        });
    }

    function _oracle(address signer, IImdRequester r) internal view returns (BriefsJury.Oracle memory) {
        return BriefsJury.Oracle({signer: signer, requester: r, domain: domain, chainId: 1, hearingGas: 3_000_000});
    }

    function _input(uint64 endsAt) internal pure returns (Briefs.CaseInput memory) {
        return Briefs.CaseInput({
            title: TITLE, task: TASK, standard: STANDARD, opening: OPENING, avatar: 3, seed: SEED, fee: FEE, endsAt: endsAt, minHold: 0
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
        w.issuedAt = b.getBrief(id).heardAt - 1;
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

    function test_RewardsSinkIsDelayedCappedAndNeverReachesBack() public {
        Sink sink = new Sink();
        vm.expectRevert(Briefs.BadParams.selector);
        b.proposeSink(sink, 5_001); // never more than half of the platform's share
        vm.prank(alice);
        vm.expectRevert();
        b.proposeSink(sink, 5_000); // owner only

        uint256 c = _case();
        _judge(_file(c, alice, B1), false); // accrued before the change: all to the treasury
        b.proposeSink(sink, 5_000);
        vm.expectRevert(Briefs.TooEarly.selector);
        b.applySink();
        vm.warp(block.timestamp + 2 days);
        b.applySink();
        assertEq(imd.balanceOf(treasury), CASE_FEE + TO_PLATFORM);
        assertEq(address(b.rewardsSink()), address(sink));
        assertEq(b.rewardsBps(), 5_000);

        vm.prank(creator);
        uint256 c2 = b.openCase(_input(uint64(block.timestamp + 1 days)));
        _judge(_file(c2, bob, B2), false);
        b.withdrawPlatform();
        assertEq(imd.balanceOf(address(sink)), TO_PLATFORM / 2);
        assertEq(sink.notified(), TO_PLATFORM / 2);
        assertEq(imd.balanceOf(treasury), 2 * CASE_FEE + TO_PLATFORM + TO_PLATFORM / 2);
        assertEq(b.getCase(c2).pot, SEED + TO_POT); // pots untouched
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

    function test_OracleChangeIsDelayedAndOptInPerCase() public {
        vm.prank(creator);
        uint256 c = b.openCase(_input(uint64(block.timestamp + 30 days)));
        MockRequester r2 = new MockRequester(IERC20(address(imd)), ORACLE_FEE);
        jury.proposeOracle(_oracle(vm.addr(0xC0FFEE), r2));
        vm.expectRevert(Briefs.TooEarly.selector);
        jury.applyOracle();
        vm.warp(block.timestamp + 7 days);
        jury.applyOracle();
        assertEq(b.getCase(c).oracleId, 0); // the open case keeps its oracle
        vm.prank(alice);
        vm.expectRevert(Briefs.NotCreator.selector);
        b.useLatestOracle(c);
        vm.prank(creator);
        b.useLatestOracle(c); // allowed only before the first entry
        assertEq(b.getCase(c).oracleId, 1);
        assertEq(address(jury.get(b.getCase(c).oracleId).requester), address(r2));

        uint256 a1 = _file(c, alice, B1);
        assertEq(b.getBrief(a1).oracleId, 1);
        jury.proposeOracle(_oracle(vm.addr(key), requester));
        vm.warp(block.timestamp + 7 days);
        jury.applyOracle();
        vm.prank(creator);
        vm.expectRevert(Briefs.WrongStatus.selector); // once anyone has filed, the case's jury never changes
        b.useLatestOracle(c);
        vm.warp(block.timestamp + 1 minutes);
        ImdOracle.AttestationV2 memory a = _attWith(a1, abi.encode(false), 11, 6, 6);
        (uint8 v, bytes32 r, bytes32 s_) = vm.sign(0xC0FFEE, digester.digest(domain, a));
        b.fulfill(b.briefOfRequest(a.requestId), a, abi.encodePacked(r, s_, v)); // judged by the setup it was filed under
        vm.prank(creator);
        vm.expectRevert(Briefs.WrongStatus.selector); // not even with the docket empty again
        b.useLatestOracle(c);
        assertEq(b.getCase(c).oracleId, 1);
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

    function test_ABrokenSinkCannotLockThePlatformShare() public {
        Sink sink = new Sink();
        b.proposeSink(sink, 5_000);
        vm.warp(block.timestamp + 2 days);
        b.applySink();
        uint256 c = _case();
        _judge(_file(c, alice, B1), false);
        sink.setBroken(true);
        b.withdrawPlatform(); // the sink's part goes to the treasury instead
        assertEq(imd.balanceOf(treasury), CASE_FEE + TO_PLATFORM);
        assertEq(imd.balanceOf(address(sink)), 0);
        _judge(_file(c, bob, B2), false); // bob's fee is split on his verdict
        b.proposeSink(IRewardsSink(address(0)), 0); // and it can still be removed
        vm.warp(block.timestamp + 2 days);
        b.applySink();
        assertEq(address(b.rewardsSink()), address(0));
        assertEq(imd.balanceOf(treasury), CASE_FEE + 2 * TO_PLATFORM);
    }

    function test_OutOfGasCannotFakeAStall() public {
        HeavyRequester heavy = new HeavyRequester(IERC20(address(imd)));
        jury.proposeOracle(_oracle(vm.addr(key), heavy));
        vm.warp(block.timestamp + 7 days);
        jury.applyOracle();
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
        uint256[] memory ids = b.docket(c, k.head, 100);
        for (uint256 i; i < ids.length; i++) {
            assertEq(uint8(_status(ids[i])), uint8(Briefs.BriefStatus.Queued));
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
}
