// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Briefs} from "../../src/Briefs.sol";
import {BriefsText} from "../../src/BriefsText.sol";
import {BriefsJury} from "../../src/BriefsJury.sol";
import {ImdOracle} from "../../src/ImdOracle.sol";
import {IImdRequester} from "../../src/interfaces/IImdRequester.sol";
import {MockRequester} from "../mocks/MockRequester.sol";

contract DigesterA {
    function digest(bytes32 domain, ImdOracle.AttestationV2 calldata a) external pure returns (bytes32) {
        return ImdOracle.digestV2(domain, a);
    }
}

/// IMD stand-in with an issuer blacklist (USDC/USDT-style), to test push payouts
contract BlacklistERC20 is ERC20 {
    mapping(address => bool) public blocked;

    constructor(address to) ERC20("IMD", "IMD") {
        _mint(to, 1_000_000_000 ether);
    }

    function setBlocked(address a, bool v) external {
        blocked[a] = v;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[from] && !blocked[to], "blacklisted");
        super._update(from, to, value);
    }
}

/// records how much of hearingGas is left when request() is entered
contract GasProbeRequester is IImdRequester {
    IERC20 public immutable imd;
    uint256 public count;
    uint256 public gasAtEntry;

    constructor(IERC20 imd_) {
        imd = imd_;
    }

    function answerSource() external pure returns (address) {
        return address(0);
    }

    function fee() external pure returns (uint256) {
        return 0.5 ether;
    }

    function request(string calldata, address) external returns (bytes32) {
        gasAtEntry = gasleft();
        imd.transferFrom(msg.sender, address(this), 0.5 ether);
        return bytes32(uint256(keccak256(abi.encode(address(this), ++count))) << 128);
    }
}

/// a requester that needs nearly all of its hearingGas (a "tight" but honest hearingGas setting)
contract BurnRequester is IImdRequester {
    IERC20 public immutable imd;
    uint256 public immutable burn;
    uint256 public count;

    constructor(IERC20 imd_, uint256 burn_) {
        imd = imd_;
        burn = burn_;
    }

    function answerSource() external pure returns (address) {
        return address(0);
    }

    function fee() external pure returns (uint256) {
        return 0.5 ether;
    }

    function request(string calldata, address) external returns (bytes32) {
        imd.transferFrom(msg.sender, address(this), 0.5 ether);
        uint256 g = gasleft();
        while (g - gasleft() < burn) {}
        return bytes32(uint256(keccak256(abi.encode(address(this), ++count))) << 128);
    }
}

contract LivenessAudit is Test {
    DigesterA digester = new DigesterA();
    string constant TASK = "Write the funniest joke about dragons.";
    string constant STANDARD = "The funnier brief wins.";
    string constant OPENING = "Dragons never use banks. Too many firewalls.";
    string constant B1 = "A dragon walked into a bar. The bar is now a barbecue.";
    string constant B2 = "My dragon asked for a raise. HR said to stop burning through the budget.";

    uint256 constant ORACLE_FEE = 0.5 ether;
    uint256 constant SEED = 500 ether;
    uint256 constant FEE = 5 ether;

    IERC20 imd;
    MockRequester requester;
    Briefs b;
    BriefsJury jury;
    uint256 key = 0xB21EF;
    bytes32 domain;

    address creator = makeAddr("creator"); // the team: owner of Briefs + BriefsJury and creator of launch cases
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address treasury = makeAddr("treasury");
    address keeper = makeAddr("keeper");

    function setUp() public {
        vm.warp(1_790_800_000);
        _deploy(IERC20(address(new BlacklistERC20(address(this)))));
    }

    function _deploy(IERC20 token) internal {
        imd = token;
        requester = new MockRequester(imd, ORACLE_FEE);
        domain = ImdOracle.domainSeparatorV("2", 1, address(0));
        jury = new BriefsJury(_oracle(vm.addr(key), requester), address(this), address(0));
        b = new Briefs(imd, new BriefsText(), jury, treasury, _params());
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
            caseFee: 2 ether,
            minDuration: 10 minutes, maxDuration: 90 days, maxBrief: 500
        });
    }

    function _oracle(address signer, IImdRequester r) internal view returns (BriefsJury.Oracle memory) {
        return BriefsJury.Oracle({signer: signer, requester: r, domain: domain, chainId: 1, hearingGas: 3_000_000});
    }

    function _input(uint64 endsAt) internal pure returns (Briefs.CaseInput memory) {
        return Briefs.CaseInput({
            title: "Dragon Jokes", task: TASK, standard: STANDARD, opening: OPENING, avatar: 3, seed: SEED, fee: FEE, endsAt: endsAt, minHold: 0
        });
    }

    function _case(uint256 dur) internal returns (uint256) {
        vm.prank(creator);
        return b.openCase(_input(uint64(block.timestamp + dur)));
    }

    function _file(uint256 c, address who, string memory words) internal returns (uint256) {
        vm.prank(who);
        return b.fileBrief(c, words);
    }

    function _att(uint256 k, uint256 briefId, bool better) internal view returns (ImdOracle.AttestationV2 memory a, bytes memory sig) {
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(k, digester.digest(domain, a));
        sig = abi.encodePacked(r, s, v);
    }

    function _judge(uint256 briefId, bool better) internal {
        vm.warp(block.timestamp + 1 minutes);
        (ImdOracle.AttestationV2 memory a, bytes memory sig) = _att(key, briefId, better);
        vm.prank(keeper);
        b.fulfill(b.briefOfRequest(a.requestId), a, sig);
    }

    function _status(uint256 id) internal view returns (Briefs.BriefStatus) {
        return b.getBrief(id).status;
    }

    // =====================================================================================================
    // M-1 (FIXED): an owner pause (or a maxOracleFee cut) used to freeze entries of LIVE cases while their
    //      deadline kept running, locking in whoever led. Now pause blocks only openCase and fileBrief no longer
    //      looks at maxOracleFee.
    // =====================================================================================================

    function test_Fixed_M1_PauseNoLongerLocksInTheLeaderOfALiveCase() public {
        uint256 c = _case(1 days);
        uint256 a1 = _file(c, alice, B1);
        _judge(a1, true); // alice (say, an insider) leads
        b.setPaused(true);
        uint256 b1 = _file(c, bob, B2); // the challenger still gets in
        assertEq(b.getCase(c).hearing, b1);
        vm.prank(creator);
        vm.expectRevert(Briefs.IsPaused.selector);
        b.openCase(_input(uint64(block.timestamp + 1 days))); // only new cases are paused
        vm.warp(b.getCase(c).endsAt);
        _judge(b1, true);
        assertEq(b.getCase(c).winner, bob);
    }

    function test_Fixed_M1_MaxOracleFeeCutDoesNotFreezeEntriesOfLiveCases() public {
        uint256 c = _case(1 days);
        Briefs.Params memory p = _params();
        p.maxOracleFee = 0.4 ether; // under IMD's 0.5 price
        b.setParams(p);
        uint256 b1 = _file(c, bob, B2); // entries only need reserve < fee
        assertEq(b.getCase(c).hearing, b1);
        assertEq(b.getBrief(b1).oracleReserve, ORACLE_FEE);
        assertFalse(b.paused());
    }

    // =====================================================================================================
    // M-2 (FIXED): jury owner + case creator used to be able to re-wire a LIVE case (with players' money in it)
    //      to a jury they control. useLatestOracle now works only before the first entry, so players always
    //      join on the jury the case names, and it never changes under them.
    // =====================================================================================================

    function test_Fixed_M2_CreatorCannotMoveACaseWithEntries() public {
        uint256 c = _case(30 days); // a team-created case
        uint256 a1 = _file(c, alice, B1);
        _judge(a1, true); // alice legitimately leads; docket empty again
        uint256 evilKey = 0xE11;
        jury.proposeOracle(_oracle(vm.addr(evilKey), requester)); // owner: a signer it controls
        vm.warp(block.timestamp + 7 days);
        jury.applyOracle();
        vm.prank(creator);
        vm.expectRevert(Briefs.WrongStatus.selector);
        b.useLatestOracle(c);
        assertEq(b.getCase(c).oracleId, 0);
        // a forged answer for the next hearing is rejected: the case still checks the original signer
        uint256 y = _file(c, bob, B2);
        vm.warp(block.timestamp + 1 minutes);
        (ImdOracle.AttestationV2 memory a, bytes memory sig) = _att(evilKey, y, false);
        {
            uint256 bid_ = b.briefOfRequest(a.requestId);
            vm.expectRevert(BriefsJury.BadSignature.selector);
            b.fulfill(bid_, a, sig);
        }
        // a fresh case with no entries yet may still opt in, before anyone pays
        uint256 c2 = _case(1 days);
        vm.prank(creator);
        b.useLatestOracle(c2);
        assertEq(b.getCase(c2).oracleId, 1);
    }

    // =====================================================================================================
    // Push payout to a blacklisted/paused-for winner bricks the case forever (only if IMD can blacklist)
    // =====================================================================================================

    // KNOWN: push payouts; only matters if the IMD token can blacklist (it cannot today).
    function test_Known_L_BlacklistedWinnerBricksTheLastVerdictAndMistrial() public {
        uint256 c = _case(1 days);
        uint256 a1 = _file(c, alice, B1);
        vm.warp(b.getCase(c).endsAt); // entries closed; a1 is the last hearing
        BlacklistERC20(address(imd)).setBlocked(alice, true);
        (ImdOracle.AttestationV2 memory a, bytes memory sig) = _att(key, a1, true);
        {
            uint256 bid_ = b.briefOfRequest(a.requestId);
            vm.expectRevert(bytes("blacklisted"));
            b.fulfill(bid_, a, sig); // COOKED cannot land: settle pays alice inside fulfill
        }
        // a mistrial hands alice the rest of her fee: blocked as well, so only a DENIED answer can end the case
        vm.warp(block.timestamp + 7 minutes);
        vm.expectRevert(bytes("blacklisted"));
        b.mistrial(c);
    }

    // KNOWN: as above, a blacklisted leader bricks the case (push payout inside fulfill/mistrial/settle).
    function test_Known_L_BlacklistedLeaderBricksTheCaseForever() public {
        uint256 c = _case(1 days);
        uint256 a1 = _file(c, alice, B1);
        _judge(a1, true); // alice leads
        uint256 b1 = _file(c, bob, B2);
        vm.warp(b.getCase(c).endsAt);
        BlacklistERC20(address(imd)).setBlocked(alice, true);
        (ImdOracle.AttestationV2 memory a, bytes memory sig) = _att(key, b1, false);
        {
            uint256 bid_ = b.briefOfRequest(a.requestId);
            vm.expectRevert(bytes("blacklisted"));
            b.fulfill(bid_, a, sig);
        }
        vm.warp(block.timestamp + 10 minutes);
        vm.expectRevert(bytes("blacklisted"));
        b.mistrial(c);
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(Briefs.WrongStatus.selector);
        b.skipStalled(c);
        vm.expectRevert(Briefs.TooEarly.selector);
        b.settle(c); // hearing is stuck at b1 forever; whole pot locked
        assertEq(b.getCase(c).hearing, b1);
    }

    // KNOWN: the refund of an unheard brief is pushed too, so a blacklisted queued author blocks the verdict.
    function test_Known_L_BlacklistedQueuedAuthorBlocksSkipOnPriceRise() public {
        uint256 c = _case(1 days);
        uint256 a1 = _file(c, alice, B1);
        _file(c, carol, B2);
        BlacklistERC20(address(imd)).setBlocked(carol, true);
        requester.setFee(1 ether); // above the case's reserve: carol's whole fee must be returned on the next _hearNext
        vm.warp(block.timestamp + 1 minutes);
        (ImdOracle.AttestationV2 memory a, bytes memory sig) = _att(key, a1, true);
        {
            uint256 bid_ = b.briefOfRequest(a.requestId);
            vm.expectRevert(bytes("blacklisted"));
            b.fulfill(bid_, a, sig); // even alice's own verdict cannot land
        }
    }

    // =====================================================================================================
    // KNOWN: leader-driven skipStalled during any transient requester failure, once a backlog outlives
    // STALL_GRACE. Still possible; since the escrow fix the skipped challenger at least gets the whole fee back.
    // =====================================================================================================

    function test_Known_L_LeaderSkipsChallengersOnAnyTransientRequesterFailure() public {
        uint256 c = _case(1 days);
        uint256 a1 = _file(c, alice, B1);
        _judge(a1, true); // alice leads
        uint256 b1 = _file(c, bob, B2);
        uint256 c1 = _file(c, carol, "A third, even better dragon joke.");
        // backlog: b1 hearing gets stuck (no answer), docket still has c1 at endsAt + 3 days
        vm.warp(b.getCase(c).endsAt + 3 days);
        requester.setBroken(true); // a blip of the requester, seconds long
        b.mistrial(c); // b1: mistrial, c1 stalls
        uint256 carolBefore = imd.balanceOf(carol);
        vm.prank(alice);
        b.skipStalled(c); // the leader skips carol during the blip and settles
        assertEq(uint8(_status(b1)), uint8(Briefs.BriefStatus.Mistrial));
        assertEq(uint8(_status(c1)), uint8(Briefs.BriefStatus.Unheard));
        assertEq(b.getCase(c).winner, alice);
        assertEq(imd.balanceOf(carol) - carolBefore, FEE); // carol is not heard, but gets all 5 IMD back
    }

    // =====================================================================================================
    // KNOWN: mistrial race: once the 2-min grace passes, the leader can kill a valid in-time COOKED answer
    // that no keeper delivered yet (documented trade-off of MISTRIAL_GRACE).
    // =====================================================================================================

    function test_Known_L_LeaderMistrialsAValidUndeliveredOverrule() public {
        uint256 c = _case(1 days);
        uint256 a1 = _file(c, alice, B1);
        (ImdOracle.AttestationV2 memory a, bytes memory sig) = _att(key, a1, true); // issued at +30s, valid 1 day
        vm.warp(block.timestamp + 6 minutes + 1); // keeper late by >2 min
        vm.prank(creator); // the leader
        b.mistrial(c);
        {
            uint256 bid_ = b.briefOfRequest(a.requestId);
            vm.expectRevert(Briefs.WrongStatus.selector);
            b.fulfill(bid_, a, sig);
        }
    }

    // =====================================================================================================
    // Verified behaviour
    // =====================================================================================================

    function test_OK_DeadlineBoundaryIsConsistent() public {
        uint256 c = _case(1 days);
        uint64 end = b.getCase(c).endsAt;
        vm.warp(end - 1);
        uint256 a1 = _file(c, alice, B1); // last second still allowed
        vm.expectRevert(Briefs.TooEarly.selector);
        b.settle(c);
        vm.warp(end);
        vm.prank(bob);
        vm.expectRevert(Briefs.EntriesClosed.selector);
        b.fileBrief(c, B2);
        _judge(a1, false);
        assertEq(uint8(b.getCase(c).status), uint8(Briefs.CaseStatus.Settled));
    }

    function test_OK_PriceSpikeWithManyQueuedBriefsSkipsInBoundedSteps() public {
        uint256 c = _case(1 days);
        uint256 first = _file(c, alice, B1);
        for (uint256 i; i < 40; i++) _file(c, bob, B2);
        requester.setFee(1 ether); // above the case's reserve
        vm.warp(b.getCase(c).endsAt);
        uint256 g = gasleft();
        _judge(first, false); // lands; skips 16
        emit log_named_uint("fulfill + 16 skips gas", g - gasleft());
        assertEq(b.waiting(c), 40 - 16);
        b.hear(c);
        b.hear(c);
        assertEq(uint8(b.getCase(c).status), uint8(Briefs.CaseStatus.Settled));
    }

    function test_OK_SkipStalledSkipsOnePerCall() public {
        uint256 c = _case(1 days);
        requester.setBroken(true);
        for (uint256 i; i < 5; i++) _file(c, bob, B2);
        vm.warp(b.getCase(c).endsAt + 3 days);
        for (uint256 i; i < 4; i++) b.skipStalled(c);
        assertEq(uint8(b.getCase(c).status), uint8(Briefs.CaseStatus.Open));
        b.skipStalled(c);
        assertEq(uint8(b.getCase(c).status), uint8(Briefs.CaseStatus.Settled));
    }

    function test_OK_CreatorMayPlayAndGetsAKickback() public {
        uint256 c = _case(1 days);
        uint256 x = _file(c, creator, B1);
        _judge(x, true);
        // 15% of (fee - the jury's price) returns to the creator as earnings
        assertEq(b.getCase(c).creatorOwed, 0.675 ether);
    }

    function _big(string memory unit, uint256 n) internal pure returns (string memory s) {
        bytes memory u = bytes(unit);
        bytes memory out = new bytes(u.length * n);
        for (uint256 i; i < n; i++) {
            for (uint256 j; j < u.length; j++) out[i * u.length + j] = u[j];
        }
        s = string(out);
    }

    function test_Gas_MaxSizeTextsAndHearingOverhead() public {
        GasProbeRequester probe = new GasProbeRequester(imd);
        jury.proposeOracle(_oracle(vm.addr(key), probe));
        vm.warp(block.timestamp + 7 days);
        jury.applyOracle();
        string memory big = _big(unicode"😀", 125); // 500 bytes, the longest brief
        Briefs.CaseInput memory x = _input(uint64(block.timestamp + 1 days));
        x.task = _big(unicode"😀", 60); // 240 bytes
        x.standard = _big(unicode"😀", 40); // 160 bytes
        x.opening = big;
        vm.prank(creator);
        uint256 g = gasleft();
        uint256 c = b.openCase(x);
        emit log_named_uint("openCase max", g - gasleft());
        vm.prank(alice);
        g = gasleft();
        uint256 a1 = b.fileBrief(c, big);
        emit log_named_uint("fileBrief max (+opens hearing)", g - gasleft());
        emit log_named_uint("hearingGas consumed before request() is entered", 3_000_000 - probe.gasAtEntry());
        vm.prank(bob);
        g = gasleft();
        b.fileBrief(c, big);
        emit log_named_uint("fileBrief max (queued)", g - gasleft());
        vm.warp(block.timestamp + 1 minutes);
        (ImdOracle.AttestationV2 memory a, bytes memory sig) = _att(key, a1, true);
        g = gasleft();
        b.fulfill(b.briefOfRequest(a.requestId), a, sig);
        emit log_named_uint("fulfill max (+opens next hearing)", g - gasleft());
        emit log_named_uint("hearingGas consumed before request() is entered", 3_000_000 - probe.gasAtEntry());
    }

    // =====================================================================================================
    // M-3 (FIXED): hearingGas used to also pay Briefs' own input building (up to ~0.5M gas cold for max-size
    // texts), so with a hearingGas "measured on the real requester" one max-size brief stalled the whole docket
    // until endsAt + STALL_GRACE. The JSON is now built in _hearNext, outside the gas-capped frame.
    // =====================================================================================================

    function test_Fixed_M3_MaxSizeBriefIsHeardWithTightHearingGas() public {
        BriefsJury.Oracle memory o = _oracle(vm.addr(key), requester);
        o.hearingGas = 300_000; // allowed (>= 200k); MockRequester itself needs ~60k, so a "measured" value
        jury.proposeOracle(o);
        vm.warp(block.timestamp + 7 days);
        jury.applyOracle();
        uint256 c = _case(60 days);
        uint256 a1 = _file(c, alice, B1); // short texts: heard fine
        assertEq(b.getCase(c).hearing, a1);
        uint256 x = _file(c, bob, _big(unicode"😀", 125)); // one max-size brief, one fee
        uint256 y = _file(c, carol, B2); // honest briefs behind it
        vm.cool(address(b)); // a later tx: the stored texts are read cold (as on chain; also run with --isolate)
        _judge(a1, true); // the verdict lands and x is heard at once, cold texts and all
        assertEq(b.getCase(c).hearing, x);
        assertEq(uint8(_status(x)), uint8(Briefs.BriefStatus.Hearing));
        assertEq(requester.lastInputHash(), keccak256(bytes(b.jury().requestOf(x))));
        _judge(x, true); // a max-size precedent now; y is heard against it, again within 300k
        assertEq(b.getCase(c).precedent, x);
        vm.cool(address(b));
        _judge(b.getCase(c).hearing, false);
        assertEq(uint8(_status(y)), uint8(Briefs.BriefStatus.Sustained));
        assertEq(b.getBrief(y).against, x);
        assertEq(b.getCase(c).hearing, 0);
    }

    // =====================================================================================================
    // KNOWN (new, from the M-3 fix): _hearNext checks gasleft() >= hearingGas*64/63 + RESERVE_GAS BEFORE it
    // builds requestInput (up to a few 100k gas cold for max-size texts). A caller can send just enough gas to
    // pass the check, let the input building eat the margin, and the requester then gets less than hearingGas:
    // a fake HearingStalled. With a requester that needs most of its hearingGas, the leader can do this inside
    // skipStalled after endsAt + STALL_GRACE to skip a challenger (who at least gets the whole fee back).
    // Fixed in src: the gasleft() check now runs after the input is built.
    // =====================================================================================================

    function test_Fixed_L_NoCallerGasFakesAStallAfterTheInputIsBuilt() public {
        BurnRequester r = new BurnRequester(imd, 2_750_000); // honest, needs ~2.85M of its 3M hearingGas
        jury.proposeOracle(_oracle(vm.addr(key), r));
        vm.warp(block.timestamp + 7 days);
        jury.applyOracle();
        uint256 c = _case(1 days);
        string memory big = _big(unicode"😀", 125);
        uint256 a1 = _file(c, alice, big);
        _judge(a1, true); // a max-size leader
        uint256 x = _file(c, bob, big); // heard at once (enough gas)
        assertEq(b.getCase(c).hearing, x);
        uint256 y = _file(c, carol, big); // queued
        vm.warp(b.getCase(c).endsAt + 3 days);

        uint256 faked;
        for (uint256 g = 3_150_000; g < 3_500_000 && faked == 0; g += 10_000) {
            uint256 snap = vm.snapshotState();
            vm.cool(address(b));
            try b.mistrial{gas: g}(c) {
                if (b.getCase(c).hearing == 0 && b.getBrief(y).status == Briefs.BriefStatus.Queued) faked = g;
            } catch {}
            vm.revertToState(snap);
        }
        assertEq(faked, 0, "no caller-chosen gas may fake a stall");
    }
}
