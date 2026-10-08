// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Briefs} from "../../src/Briefs.sol";
import {BriefsText} from "../../src/BriefsText.sol";
import {BriefsJury} from "../../src/BriefsJury.sol";
import {ImdOracle} from "../../src/ImdOracle.sol";
import {IImdRequester} from "../../src/interfaces/IImdRequester.sol";
import {IRewardsSink} from "../../src/interfaces/IRewardsSink.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRequester} from "../mocks/MockRequester.sol";

// ------------------------------------------------------------------ audit mocks

contract AuditDigester {
    function digest(bytes32 domain, ImdOracle.AttestationV2 calldata a) external pure returns (bytes32) {
        return ImdOracle.digestV2(domain, a);
    }
}

/// A requester whose gas grows with the input (it stores it), like any requester that keeps the question on chain.
contract StoringRequester is IImdRequester {
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

/// A requester that tries to re-enter Briefs from request().
contract ReentrantRequester is IImdRequester {
    IERC20 public immutable imd;
    Briefs public b;
    uint256 public count;
    uint256 public mode; // 0 none, 1 fileBrief, 2 settle, 3 withdrawPlatform, 4 openHearing direct

    constructor(IERC20 imd_) {
        imd = imd_;
    }

    function setB(Briefs b_) external {
        b = b_;
    }

    function setMode(uint256 m) external {
        mode = m;
    }

    function answerSource() external pure returns (address) {
        return address(0);
    }

    function fee() external pure returns (uint256) {
        return 0.5 ether;
    }

    function request(string calldata, address) external returns (bytes32) {
        imd.transferFrom(msg.sender, address(this), 0.5 ether);
        if (mode == 1) b.fileBrief(1, "reentered brief");
        if (mode == 2) b.settle(1);
        if (mode == 3) b.withdrawPlatform();
        if (mode == 4) b.openHearing(1, 3, 0, this, "");
        return bytes32(uint256(keccak256(abi.encode(address(this), ++count))) << 128);
    }
}

/// A rewards sink that tries everything: pull more than approved, re-enter, steal via other paths.
contract GreedySink is IRewardsSink {
    Briefs public b;
    uint256 public mode; // 0 honest, 1 pull double, 2 reenter withdrawPlatform, 3 reenter claimCreator, 4 pull then refund half

    constructor(Briefs b_) {
        b = b_;
    }

    function setMode(uint256 m) external {
        mode = m;
    }

    function notifyReward(uint256 amount) external {
        IERC20 t = IERC20(b.imd());
        if (mode == 1) {
            t.transferFrom(msg.sender, address(this), amount * 2);
        } else if (mode == 2) {
            t.transferFrom(msg.sender, address(this), amount);
            b.withdrawPlatform();
        } else if (mode == 3) {
            uint256[] memory ids = new uint256[](1);
            ids[0] = 1;
            b.claimCreator(ids);
        } else if (mode == 4) {
            t.transferFrom(msg.sender, address(this), amount);
            t.transfer(msg.sender, amount / 2);
        } else {
            t.transferFrom(msg.sender, address(this), amount);
        }
    }
}

/// 1% burned on every transfer (fee-on-transfer).
contract FotToken is ERC20 {
    constructor(address to) ERC20("FOT", "FOT") {
        _mint(to, 1_000_000_000 ether);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 burn = value / 100;
            super._update(from, address(0), burn);
            value -= burn;
        }
        super._update(from, to, value);
    }
}

// ------------------------------------------------------------------ base

abstract contract AuditBase is Test {
    AuditDigester digester = new AuditDigester();
    string constant TITLE = "Dragon Jokes";
    string constant TASK = "Write the funniest joke about dragons.";
    string constant STANDARD = "The funnier brief wins.";
    string constant OPENING = "Dragons never use banks. Too many firewalls.";
    uint256 constant ORACLE_FEE = 0.5 ether;
    uint256 constant SEED = 10 ether;
    uint256 constant FEE = 1 ether;
    uint256 constant CASE_FEE = 2 ether;

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

    function setUp() public virtual {
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

    function _input(uint64 endsAt) internal view returns (Briefs.CaseInput memory) {
        return Briefs.CaseInput({
            title: TITLE, task: TASK, standard: STANDARD, opening: OPENING, avatar: 3, seed: SEED, fee: FEE, endsAt: endsAt, minHold: 0, oracleId: oid
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
        a = ImdOracle.AttestationV2({
            requestId: b.getBrief(briefId).requestId,
            chainId: 1,
            questionHash: b.jury().questionHashOf(briefId, 1, 2),
            answerType: 0,
            answer: abi.encode(better),
            figure: 0,
            fromBlock: 1,
            toBlock: 2,
            blockHash: keccak256("b"),
            panelJobId: keccak256("p"),
            panelSize: 11,
            quorum: 6,
            agreed: 6,
            issuedAt: b.getBrief(briefId).heardAt + 30,
            expiresAt: uint64(block.timestamp + 1 days)
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digester.digest(domain, a));
        sig = abi.encodePacked(r, s, v);
    }

    function _judge(uint256 briefId, bool better) internal {
        vm.warp(block.timestamp + 1 minutes);
        (ImdOracle.AttestationV2 memory a, bytes memory sig) = _att(briefId, better);
        vm.prank(keeper);
        b.fulfill(b.briefOfRequest(a.requestId), a, sig);
    }

    function _repeat(string memory s, uint256 n) internal pure returns (string memory out) {
        for (uint256 i; i < n; i++) out = string.concat(out, s);
    }

    function _useOracle(IImdRequester r) internal {
        jury.proposeOracle(_oracle(vm.addr(key), r));
        vm.warp(block.timestamp + 7 days);
        jury.applyOracle();
        oid = uint32(jury.latest()); // new cases must name the live setup
    }
}

// ------------------------------------------------------------------ PoCs

contract FundsTest is AuditBase {
    // F-1 (FIXED, economic part): with a requester whose own gas grows with the input (it stores it), a long
    // leader can still make a long challenger's hearing stall; that cost is the requester's and hearingGas must
    // be sized for it. What was fixed: the stalled challenger is skipped as Unheard with its WHOLE fee back,
    // and none of it ever reached the pot, so the leader gains nothing from silencing it.
    function test_Fixed_F1_StalledLongChallengerGetsItsWholeFeeBack() public {
        StoringRequester heavy = new StoringRequester(IERC20(address(imd)));
        BriefsJury.Oracle memory o = _oracle(vm.addr(key), heavy);
        o.hearingGas = 1_600_000; // sized too small for this requester's storage of a full-size question
        jury.proposeOracle(o);
        vm.warp(block.timestamp + 7 days);
        jury.applyOracle();
        oid = uint32(jury.latest()); // new cases must name the live setup
        uint256 c = _case();

        string memory leader = _repeat(unicode"🐉", 125); // 125 characters, 500 bytes: the longest legal brief
        string memory victim = _repeat(unicode"🔥", 125);

        uint256 l = _file(c, alice, leader);
        assertEq(b.getCase(c).hearing, l, "the long brief is heard against a short opening");
        _judge(l, true);
        assertEq(b.getCase(c).precedent, l);

        uint256 v = _file(c, bob, victim);
        assertEq(b.getCase(c).hearing, 0, "a long challenger vs a long leader cannot open its hearing");
        assertEq(uint8(b.getBrief(v).status), uint8(Briefs.BriefStatus.Queued));
        // hear() stalls again; STALL_WAIT after the first failure anyone may skip it
        b.hear(c);
        assertEq(b.getCase(c).hearing, 0);
        vm.expectRevert(Briefs.TooEarly.selector);
        b.skipStalled(c);

        uint256 potBefore = b.getCase(c).pot;
        uint256 creatorOwedBefore = b.getCase(c).creatorOwed;
        uint256 platformBefore = b.platformOwed();
        uint256 bobBefore = imd.balanceOf(bob);
        uint256 aliceBefore = imd.balanceOf(alice);
        vm.warp(b.getCase(c).stalledSince + 6 hours);
        b.skipStalled(c);
        vm.warp(b.getCase(c).endsAt);
        b.settle(c);
        assertEq(uint8(b.getBrief(v).status), uint8(Briefs.BriefStatus.Unheard));
        assertEq(imd.balanceOf(bob) - bobBefore, FEE, "bob gets his whole fee back");
        assertEq(b.getCase(c).winner, alice);
        assertEq(imd.balanceOf(alice) - aliceBefore, potBefore, "the leader wins nothing of bob's fee");
        assertEq(b.getCase(c).creatorOwed, creatorOwedBefore);
        assertEq(b.platformOwed(), platformBefore);
    }

    // F-2 (FIXED): a price rise above the case's reserve makes every queued brief Unheard. Fees are escrowed until the
    // verdict, so each unheard author gets the whole fee back and nothing of it reaches pot/creator/platform.
    function test_Fixed_F2_PriceBumpRefundsQueuedEntrantsInFull() public {
        uint256 c = _case();
        uint256 a1 = _file(c, alice, "Joke one, about a dragon.");
        uint256[5] memory q;
        for (uint256 i; i < 5; i++) q[i] = _file(c, bob, string.concat("Bob's joke number ", vm.toString(i)));
        Briefs.Case memory k0 = b.getCase(c);
        uint256 platform0 = b.platformOwed();
        uint256 bobBefore = imd.balanceOf(bob);
        requester.setFee(0.9 ether + 1); // just above the case's reserve
        _judge(a1, true); // alice leads; the next hearing finds the price above the case's reserve
        for (uint256 i; i < 5; i++) assertEq(uint8(b.getBrief(q[i]).status), uint8(Briefs.BriefStatus.Unheard));
        assertEq(imd.balanceOf(bob) - bobBefore, 5 * FEE, "bob paid 5 IMD and gets all 5 back");
        // only alice's own verdict was split
        assertEq(b.getCase(c).pot + b.getCase(c).creatorOwed + b.platformOwed(), k0.pot + k0.creatorOwed + platform0 + FEE - ORACLE_FEE);
        vm.warp(b.getCase(c).endsAt);
        b.settle(c);
        assertEq(b.getCase(c).winner, alice);
    }

    // F-3 (KNOWN, by design): a fee-on-transfer / deflationary token makes the contract credit nominal amounts and
    // become insolvent. IMD is a plain ERC-20, so this is accepted; Briefs must never be deployed on such a token.
    function test_Known_F3_FeeOnTransferBreaksSolvency() public {
        FotToken fot = new FotToken(address(this));
        MockRequester r = new MockRequester(IERC20(address(fot)), ORACLE_FEE);
        BriefsJury j = new BriefsJury(_oracle(vm.addr(key), r), address(this), address(0));
        Briefs bb = new Briefs(IERC20(address(fot)), new BriefsText(), j, treasury, _params());
        fot.transfer(creator, 1000 ether);
        fot.transfer(alice, 1000 ether);
        vm.prank(creator);
        fot.approve(address(bb), type(uint256).max);
        vm.prank(alice);
        fot.approve(address(bb), type(uint256).max);
        vm.prank(creator);
        uint256 c = bb.openCase(_input(uint64(block.timestamp + 1 days)));
        requester; // silence
        r.setBroken(true); // keep the brief queued: its whole fee is owed back
        vm.prank(alice);
        bb.fileBrief(c, "A joke about dragons.");
        Briefs.Case memory k = bb.getCase(c);
        uint256 liabilities = k.pot + k.creatorOwed + bb.platformOwed() + FEE;
        assertLt(fot.balanceOf(address(bb)), liabilities, "balance below liabilities");
    }

    // F-4 (KNOWN): IMD sent to Briefs outside the accounting (a requester refund for an unanswered request, a
    // mistaken transfer) is locked for good: there is no sweep.
    function test_Known_F4_SurplusIsLockedForever() public {
        uint256 c = _case();
        uint256 a1 = _file(c, alice, "A joke about dragons.");
        // e.g. IMD's requester refunds the unanswered request to the payer (Briefs)
        vm.warp(block.timestamp + 7 minutes);
        b.mistrial(c);
        vm.prank(address(requester));
        imd.transfer(address(b), ORACLE_FEE);
        a1;
        vm.warp(b.getCase(c).endsAt);
        b.settle(c);
        uint256[] memory ids = new uint256[](1);
        ids[0] = c;
        vm.prank(creator);
        vm.expectRevert(Briefs.NothingToClaim.selector); // a mistrial splits nothing: the author got the rest back
        b.claimCreator(ids);
        assertEq(imd.balanceOf(address(b)), ORACLE_FEE, "0.5 IMD stuck with no liability and no way out");
    }

    // F-5 (KNOWN): owner changes caseFee without delay; a creator whose leftover allowance covers the new price
    // pays it (no max-price argument on openCase).
    function test_Known_F5_CaseFeeChangeHitsPendingOpenCase() public {
        Briefs.Params memory p = _params();
        p.caseFee = 1_000 ether;
        b.setParams(p); // e.g. front-running the creator's openCase
        uint256 before = imd.balanceOf(creator);
        _case();
        assertEq(before - imd.balanceOf(creator), 1_000 ether + SEED, "no max-price guard on openCase");
    }

    // ------------------------------------------------------------ checked and fine

    function test_OK_SplitRoundingDustGoesToPot() public {
        Briefs.CaseInput memory x = _input(uint64(block.timestamp + 1 days));
        x.fee = 1 ether + 7; // rest = 0.5 ether + 7 wei
        vm.prank(creator);
        uint256 c = b.openCase(x);
        _judge(_file(c, alice, "A joke about dragons."), false);
        Briefs.Case memory k = b.getCase(c);
        assertEq(k.creatorOwed + b.platformOwed() + (k.pot - SEED), 0.5 ether + 7);
        assertEq(imd.balanceOf(address(b)), k.pot + k.creatorOwed + b.platformOwed());
    }

    function test_OK_ClaimCreatorDuplicateIdsPayOnce() public {
        uint256 c = _case();
        _judge(_file(c, alice, "A joke about dragons."), false);
        uint256[] memory ids = new uint256[](3);
        ids[0] = c;
        ids[1] = c;
        ids[2] = c;
        uint256 before = imd.balanceOf(creator);
        vm.prank(creator);
        b.claimCreator(ids);
        assertEq(imd.balanceOf(creator) - before, 0.075 ether);
    }

    function test_OK_SinkCannotTakeMoreThanHalfOrReenter() public {
        GreedySink sink = new GreedySink(b);
        b.proposeSink(sink, 5_000);
        vm.warp(block.timestamp + 2 days);
        b.applySink();
        uint256 c = _case();
        for (uint256 i; i < 4; i++) _file(c, alice, string.concat("Joke ", vm.toString(i)));
        uint256 owedCreator = b.getCase(c).creatorOwed;
        uint256 pot = b.getCase(c).pot;

        uint256[4] memory modes = [uint256(1), 2, 3, 4];
        for (uint256 m; m < 4; m++) {
            _file(c, bob, string.concat("More ", vm.toString(m)));
            _judge(b.getCase(c).hearing, false); // the next hearing opens: its fee is split, the platform accrues
            owedCreator = b.getCase(c).creatorOwed;
            pot = b.getCase(c).pot;
            sink.setMode(modes[m]);
            uint256 owed = b.platformOwed();
            uint256 sinkBefore = imd.balanceOf(address(sink));
            uint256 tBefore = imd.balanceOf(treasury);
            b.withdrawPlatform();
            uint256 toSink = imd.balanceOf(address(sink)) - sinkBefore;
            assertLe(toSink, owed / 2);
            assertEq(toSink + imd.balanceOf(treasury) - tBefore, owed);
            assertEq(b.getCase(c).creatorOwed, owedCreator);
            assertEq(b.getCase(c).pot, pot);
        }
    }

    function test_OK_SinkTimelockResetsOnRepropose() public {
        GreedySink sink = new GreedySink(b);
        b.proposeSink(sink, 5_000);
        vm.warp(block.timestamp + 2 days - 1);
        b.proposeSink(sink, 5_000); // re-propose: the clock restarts
        vm.warp(block.timestamp + 1);
        vm.expectRevert(Briefs.TooEarly.selector);
        b.applySink();
        vm.expectRevert(Briefs.BadParams.selector);
        b.proposeSink(sink, 5_001);
        vm.expectRevert(Briefs.BadParams.selector);
        b.proposeSink(IRewardsSink(address(0)), 1);
        // note: a ready proposal never expires; anyone can apply it a year later
        vm.warp(block.timestamp + 365 days);
        b.applySink();
        assertEq(b.rewardsBps(), 5_000);
    }

    function test_OK_RequesterCannotReenter() public {
        ReentrantRequester r = new ReentrantRequester(IERC20(address(imd)));
        _useOracle(r);
        r.setB(b);
        uint256 c = _case();
        for (uint256 m = 1; m <= 4; m++) {
            r.setMode(m);
            uint256 bal = imd.balanceOf(address(b));
            uint256 id = _file(c, alice, string.concat("Joke ", vm.toString(m)));
            assertEq(b.getCase(c).hearing, 0, "re-entry rolls the hearing back");
            assertEq(uint8(b.getBrief(id).status), uint8(Briefs.BriefStatus.Queued));
            assertEq(imd.balanceOf(address(b)), bal + FEE);
        }
        r.setMode(0);
        b.hear(c);
        assertTrue(b.getCase(c).hearing != 0);
    }

    function test_OK_OpenHearingNotCallableExternally() public {
        uint256 c = _case();
        _file(c, alice, "A joke.");
        vm.expectRevert(Briefs.NotCreator.selector);
        b.openHearing(c, 2, 0, requester, "");
    }
}

// ------------------------------------------------------------------ invariant: balance >= liabilities

contract FundsHandler is Test {
    Briefs b;
    MockERC20 imd;
    MockRequester requester;
    AuditDigester digester;
    uint256 key;
    bytes32 domain;
    address[4] actors;
    uint256[] public caseIds;
    uint256 public ghostBriefs;

    constructor(Briefs b_, MockERC20 imd_, MockRequester r_, AuditDigester d_, uint256 key_, bytes32 domain_, address[4] memory a) {
        b = b_;
        imd = imd_;
        requester = r_;
        digester = d_;
        key = key_;
        domain = domain_;
        actors = a;
    }

    function casesLength() external view returns (uint256) {
        return caseIds.length;
    }

    function openCase(uint256 who, uint256 seed, uint256 fee, uint256 dur) external {
        address a = actors[who % 4];
        seed = bound(seed, 10 ether, 1000 ether);
        fee = bound(fee, 1 ether, 50 ether);
        dur = bound(dur, 10 minutes, 3 days);
        Briefs.CaseInput memory x = Briefs.CaseInput({
            title: "Title", task: "Do something funny.", standard: "Funnier wins", opening: "Opening", avatar: 1,
            seed: seed, fee: fee, endsAt: uint64(block.timestamp + dur), minHold: 0, oracleId: uint32(b.jury().latest())
        });
        vm.prank(a);
        caseIds.push(b.openCase(x));
    }

    function file(uint256 who, uint256 ci) external {
        if (caseIds.length == 0) return;
        uint256 c = caseIds[ci % caseIds.length];
        Briefs.Case memory k = b.getCase(c);
        if (k.status != Briefs.CaseStatus.Open || block.timestamp >= k.endsAt) return;
        vm.prank(actors[who % 4]);
        b.fileBrief(c, string.concat("Brief ", vm.toString(++ghostBriefs)));
    }

    function judge(uint256 ci, bool better) external {
        if (caseIds.length == 0) return;
        uint256 c = caseIds[ci % caseIds.length];
        uint256 h = b.getCase(c).hearing;
        if (h == 0) return;
        Briefs.Brief memory br = b.getBrief(h);
        if (block.timestamp < br.heardAt + 30) vm.warp(br.heardAt + 30);
        ImdOracle.AttestationV2 memory a = ImdOracle.AttestationV2({
            requestId: br.requestId, chainId: 1, questionHash: b.jury().questionHashOf(h, 1, 2), answerType: 0, answer: abi.encode(better),
            figure: 0, fromBlock: 1, toBlock: 2, blockHash: keccak256("b"), panelJobId: keccak256("p"), panelSize: 11,
            quorum: 6, agreed: 6, issuedAt: br.heardAt + 30, expiresAt: uint64(block.timestamp + 1 days)
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digester.digest(domain, a));
        b.fulfill(b.briefOfRequest(a.requestId), a, abi.encodePacked(r, s, v));
    }

    function mistrial(uint256 ci) external {
        if (caseIds.length == 0) return;
        uint256 c = caseIds[ci % caseIds.length];
        uint256 h = b.getCase(c).hearing;
        if (h == 0) return;
        Briefs.Brief memory br = b.getBrief(h);
        uint256 t = uint256(br.heardAt) + br.answerTimeout + 2 minutes + 1;
        if (block.timestamp < t) vm.warp(t);
        b.mistrial(c);
    }

    function hear(uint256 ci) external {
        if (caseIds.length == 0) return;
        uint256 c = caseIds[ci % caseIds.length];
        if (b.getCase(c).hearing != 0) return;
        b.hear(c);
    }

    function skipHead(uint256 ci) external {
        if (caseIds.length == 0) return;
        uint256 c = caseIds[ci % caseIds.length];
        try b.skipStalled(c) {} catch {}
    }

    function settle(uint256 ci) external {
        if (caseIds.length == 0) return;
        try b.settle(caseIds[ci % caseIds.length]) {} catch {}
    }

    function claim(uint256 ci) external {
        if (caseIds.length == 0) return;
        uint256 c = caseIds[ci % caseIds.length];
        uint256[] memory ids = new uint256[](1);
        ids[0] = c;
        vm.prank(b.getCase(c).creator);
        try b.claimCreator(ids) {} catch {}
    }

    bool public shareLocked; // withdrawPlatform failed while something was owed (a sink must never lock the share)

    function withdraw() external {
        bool owed = b.platformOwed() != 0;
        try b.withdrawPlatform() {} catch {
            if (owed) shareLocked = true;
        }
    }

    function setPrice(uint256 p) external {
        requester.setFee(bound(p, 0, 0.9 ether));
    }

    function setBroken(bool x, bool y) external {
        requester.setBroken(x);
        requester.setBrokenFee(y);
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 4 days));
    }

    // ---- owner paths (this handler owns Briefs): none of them may move IMD the contract owes

    MockERC20 public holderToken;

    function setParams(uint256 creatorBps, uint256 platformBps, uint256 maxOracleFee, uint256 caseFee, uint256 maxBrief)
        external
    {
        Briefs.Params memory p = Briefs.Params({
            minSeed: 10 ether, minFee: 1 ether, maxOracleFee: bound(maxOracleFee, 0, 5 ether),
            creatorBps: uint16(bound(creatorBps, 0, 3_000)), platformBps: uint16(bound(platformBps, 0, 3_000)),
            panelSize: 11, quorum: 6, answerTimeout: 4 minutes, caseFee: bound(caseFee, 0, 1_000 ether),
            minDuration: 10 minutes, maxDuration: 90 days, maxBrief: uint16(bound(maxBrief, 100, 600))
        });
        try b.setParams(p) {} catch {}
    }

    /// any address, including the court itself, its jury and its requester (those must be refused)
    function setTreasury(uint256 pick) external {
        address[6] memory t =
            [actors[0], actors[1], address(0xBEEF), address(b), address(b.jury()), address(requester)];
        try b.setTreasury(t[pick % t.length]) {} catch {}
    }

    /// a rewards sink: honest, pulling double, re-entering, or with no code at all; applied after its delay
    function setSink(uint256 mode, uint256 bps) external {
        bps = bound(bps, 0, 5_000);
        IRewardsSink sink;
        if (bps != 0) {
            GreedySink g = new GreedySink(b);
            g.setMode(mode % 4); // not mode 4: a sink that hands IMD back is a donation, outside the accounting
            sink = g;
        }
        try b.proposeSink(sink, uint16(bps)) {} catch { return; }
        vm.warp(block.timestamp + 2 days);
        try b.applySink() {} catch {}
        if (bps != 0 && mode % 5 == 4) vm.etch(address(sink), ""); // the sink loses its code after the fact
    }

    /// a holders-only case (only the owner opens them); actors 0 and 1 hold the token, 2 and 3 don't
    function openHoldersCase(uint256 seed, uint256 fee, uint256 dur, uint256 minHold) external {
        if (address(holderToken) == address(0)) {
            holderToken = new MockERC20("HOLD", "HOLD", address(this));
            holderToken.transfer(actors[0], 100 ether);
            holderToken.transfer(actors[1], 100 ether);
            b.setHolderToken(IERC20(address(holderToken)));
        }
        Briefs.CaseInput memory x = Briefs.CaseInput({
            title: "Holders", task: "Do something funny.", standard: "Funnier wins", opening: "Opening", avatar: 2,
            seed: bound(seed, 10 ether, 1000 ether), fee: bound(fee, 1 ether, 50 ether),
            endsAt: uint64(block.timestamp + bound(dur, 10 minutes, 3 days)), minHold: bound(minHold, 1, 100 ether),
            oracleId: uint32(b.jury().latest())
        });
        try b.openCase(x) returns (uint256 c) {
            caseIds.push(c);
        } catch {}
    }
}

contract FundsInvariantTest is StdInvariant, AuditBase {
    FundsHandler h;

    function setUp() public override {
        super.setUp();
        address[4] memory a = [creator, alice, bob, carol];
        h = new FundsHandler(b, imd, requester, digester, key, domain, a);
        b.transferOwnership(address(h)); // the handler drives the owner paths too
        vm.prank(address(h));
        b.acceptOwnership();
        imd.transfer(address(h), 1_000_000 ether);
        vm.prank(address(h));
        imd.approve(address(b), type(uint256).max);
        targetContract(address(h));
    }

    /// every pot of an open case, every unclaimed creator share, the platform's share, the WHOLE escrowed fee
    /// of every brief still waiting on a docket (refunded if never heard), and the fee less the jury's price of the
    /// brief being heard (split on its verdict, handed back on a mistrial)
    function _liabilities() internal view returns (uint256 total) {
        total = b.platformOwed();
        for (uint256 i; i < h.casesLength(); i++) {
            uint256 c = h.caseIds(i);
            Briefs.Case memory k = b.getCase(c);
            total += k.creatorOwed;
            if (k.status == Briefs.CaseStatus.Open) total += k.pot;
            uint256[] memory ids = b.docket(c, k.head, type(uint256).max);
            for (uint256 j; j < ids.length; j++) {
                require(b.getBrief(ids[j]).status == Briefs.BriefStatus.Queued, "waiting brief not queued");
                total += k.fee;
            }
            if (k.hearing != 0) total += k.fee - b.getBrief(k.hearing).oracleReserve;
        }
    }

    /// balance == liabilities exactly (nothing leaks, nothing is double counted)
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 200
    function invariant_BalanceEqualsLiabilities() public view {
        assertEq(imd.balanceOf(address(b)), _liabilities());
    }

    /// the platform's share can always be paid out, whatever sink is set
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 200
    function invariant_PlatformShareNeverLocks() public view {
        assertFalse(h.shareLocked());
    }

    /// settled cases hold no pot
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 200
    function invariant_SettledPotsAreZero() public view {
        for (uint256 i; i < h.casesLength(); i++) {
            Briefs.Case memory k = b.getCase(h.caseIds(i));
            if (k.status == Briefs.CaseStatus.Settled) assertEq(k.pot, 0);
        }
    }
}
