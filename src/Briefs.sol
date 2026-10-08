// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ImdOracle} from "./ImdOracle.sol";
import {IImdRequester} from "./interfaces/IImdRequester.sol";
import {IRewardsSink} from "./interfaces/IRewardsSink.sol";
import {BriefsText} from "./BriefsText.sol";
import {BriefsJury} from "./BriefsJury.sol";

/// @title Briefs — file a better brief, hold the precedent, take the pot
/// @notice Anyone opens a CASE: a task ("write the funniest joke about dragons"), a standard ("the funnier one
///         wins"), an opening brief that becomes the first PRECEDENT, a seed pot in IMD, a fixed entry fee and a
///         deadline. Anyone files BRIEFS (answers) until the deadline; each pays the fee and joins a public FIFO
///         DOCKET. Briefs are heard one at a time, strictly in docket order: each HEARING asks the IdentityMD
///         swarm (the JURY) whether the brief is better than the precedent standing at that moment (a tie
///         or a reworded copy keeps the precedent).
///         Yes: OVERRULED, the brief becomes the precedent. No: SUSTAINED. No answer in time (the panel could
///         not agree): MISTRIAL, the precedent stands. After the deadline the docket is still heard to the end;
///         then the standing precedent's author takes 100% of the pot. A case runs once and never restarts.
///
///         Each entry fee waits in escrow until the brief's verdict. When its hearing opens, the oracle's price
///         pays the jury (at most the case's reserve, fixed when the case opens). On a verdict, of the rest,
///         creatorBps to the case creator (accrues on the case, claimed by the creator), platformBps to the
///         platform, the rest into the pot. A mistrial hands the rest back to the brief's author; a brief that is
///         never heard gets its whole fee back. The pot is never used to pay the jury.
///
///         Platform share: kept in the contract and withdrawn to the treasury by anyone. Later a rewards sink can
///         receive up to half of it (MAX_REWARDS_BPS), set only after a public CONFIG_DELAY and only for fees
///         accrued after the change. Neither the owner nor the sink can touch pots or creator earnings.
///
///         The owner tunes numbers within hard bounds (new cases and new hearings only), pauses new cases
///         (entries, hearings and payouts keep running). Opening a case costs a flat caseFee, paid to the treasury.
///
///         The owner can open holders-only cases (minHold > 0): only addresses holding at least that much of
///         holderToken may file briefs in them. Token and amount are fixed when the case opens.
///         Oracle setups and answer checks live in BriefsJury (new setups only after a public delay).
contract Briefs is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- constants

    uint256 public constant BPS = 10_000;
    uint256 public constant CONFIG_DELAY = 2 days;
    uint256 public constant MAX_REWARDS_BPS = 5_000; // at most half of the platform's share ever leaves to a sink
    uint256 public constant MIN_TITLE = 3;
    uint256 public constant MAX_TITLE = 48;
    // the task, the standard and the briefs go to the jury, so their limits count UTF-8 bytes: IMD takes questions
    // up to 2,000 characters, and a byte is never less than a character however IMD counts them (code points, UTF-16
    // units or bytes). A question carries the task, the standard, two briefs and under 400 bytes of wording, so a
    // brief can never be longer than 600 bytes. Titles never reach the jury and count characters.
    uint256 public constant MIN_TASK = 10;
    uint256 public constant MAX_TASK = 240;
    uint256 public constant MIN_STANDARD = 5;
    uint256 public constant MAX_STANDARD = 160;
    uint256 public constant MIN_BRIEF = 1;
    uint256 public constant BRIEF_CAP = 600;
    uint256 public constant BRIEF_FLOOR = 100;
    uint256 public constant DURATION_FLOOR = 5 minutes;
    uint256 public constant DURATION_CAP = 365 days;
    uint256 public constant CASE_FEE_CAP = 1_000 ether;
    uint256 public constant STALL_GRACE = 3 days; // see skipStalled
    uint256 public constant STALL_WAIT = 6 hours; // see skipStalled
    uint256 public constant MISTRIAL_GRACE = 2 minutes; // a timely answer can still land this long after the timeout
    uint256 public constant DELIVERED_GRACE = 1 hours; // the same, once IMD's Intake has delivered an answer on chain
    uint256 internal constant STEPS = 16; // briefs skipped at most per call while looking for the next hearing
    uint256 internal constant QUOTE_GAS = 100_000; // gas the requester's fee() gets
    uint256 internal constant SINK_GAS = 500_000; // gas a rewards sink gets to pull its part
    uint256 internal constant RESERVE_GAS = 60_000; // kept back to finish the call after a failed sub-call
    uint256 internal constant HOLD_GAS = 50_000; // gas the holder token's balanceOf gets

    // ---------------------------------------------------------------- settings

    struct Params {
        uint256 minSeed; // smallest seed pot, IMD
        uint256 minFee; // smallest entry fee, IMD
        uint256 maxOracleFee; // the most a hearing may pay the jury in a new case (its reserve); below minFee
        uint16 creatorBps; // of each fee after the oracle's price
        uint16 platformBps; // of each fee after the oracle's price; the pot gets the rest
        uint16 panelSize; // the IMD panel every hearing orders and every answer must show
        uint16 quorum;
        uint32 answerTimeout; // a hearing without an answer by then is a mistrial
        uint256 caseFee; // flat IMD price of opening a case, paid to the treasury
        uint32 minDuration; // shortest and longest a new case may run
        uint32 maxDuration;
        uint16 maxBrief; // longest brief (and opening brief) in a new case, in UTF-8 bytes
    }

    IERC20 public immutable imd;
    BriefsText public immutable text;
    BriefsJury public immutable jury;

    Params internal params;

    bool public paused; // no new cases; entries, hearings, payouts and claims continue
    address public treasury;
    uint256 public platformOwed; // the platform's share, not yet withdrawn
    IRewardsSink public rewardsSink; // none at launch
    uint16 public rewardsBps; // share of platformOwed routed to the sink on withdrawal (0 at launch)
    IRewardsSink public pendingSink;
    uint16 public pendingRewardsBps;
    uint256 public sinkReadyAt;
    IERC20 public holderToken; // the token holders-only cases check (none at launch)

    // ---------------------------------------------------------------- types

    enum CaseStatus {
        None,
        Open, // entries until endsAt, then the docket is heard to the end
        Settled // paid to the final precedent; closed for good
    }

    struct Case {
        address creator;
        uint64 createdAt;
        uint32 oracleId; // the oracle setup this case's hearings use; only its creator can move it
        address winner; // set on settlement
        uint64 endsAt; // entries close at this second
        CaseStatus status;
        uint16 creatorBps; // the split, fixed at creation
        uint16 platformBps;
        uint64 precedent; // brief id of the standing precedent
        uint64 hearing; // brief id being heard (0: none)
        uint32 head; // index in docketOf of the next brief to hear
        uint32 streak; // hearings the precedent has survived
        uint16 panelSize; // the jury of every hearing in this case, fixed at creation
        uint16 quorum;
        uint32 answerTimeout;
        uint128 fee; // fixed entry fee
        uint128 seed;
        uint256 pot;
        uint256 creatorOwed; // creator earnings not yet claimed
        uint256 creatorClaimed;
        address holdToken; // holders only: the token checked when filing (0: open to everyone)
        uint16 maxBrief; // longest brief, in UTF-8 bytes
        uint256 minHold; // holders only: the balance of holdToken a brief's author must hold when filing
        uint96 reserve; // the most a hearing may pay the jury, fixed at creation (params.maxOracleFee then)
        uint64 stalledSince; // when the brief at the head of the docket first failed to open (0: not stalled)
    }

    enum BriefStatus {
        None,
        Opening, // the creator's opening brief, the first precedent
        Queued, // waiting on the docket
        Hearing, // the jury is reading it
        Overruled, // it beat the precedent and became the precedent
        Sustained, // the precedent held
        Mistrial, // no answer in time; the precedent held
        Unheard // never heard (the oracle got dearer than reserved, or kept failing): the whole entry fee was returned
    }

    /// @dev Everything an answer is checked against is fixed when its hearing opens. 4 slots.
    struct Brief {
        address author;
        uint64 caseId;
        BriefStatus status;
        uint16 panelSize;
        uint16 quorum;
        uint64 filedAt;
        uint64 heardAt;
        uint32 answerTimeout;
        uint32 oracleId;
        uint64 against; // the precedent it was heard against
        uint96 oracleReserve; // queued: the case's reserve; heard: the oracle's price actually paid
        bytes32 requestId;
    }

    // ---------------------------------------------------------------- storage

    uint256 public caseCount;
    uint256 public briefCount;
    mapping(uint256 => Case) internal cases;
    mapping(uint256 => Brief) internal briefs;
    mapping(uint256 => string) public titleOf;
    mapping(uint256 => string) public taskOf;
    mapping(uint256 => string) public standardOf;
    mapping(uint256 => uint8) public avatarOf;
    /// @notice the brief's words (stored: each hearing quotes the standing precedent)
    mapping(uint256 => string) public briefText;
    /// @notice every filed brief id of a case, in docket order
    mapping(uint256 => uint256[]) internal docketOf;
    mapping(bytes32 => uint256) public briefOfRequest;

    // ---------------------------------------------------------------- events

    /// @notice avatar, deadline, seed and fee are in getCase(caseId) / avatarOf(caseId)
    event CaseOpened(uint256 indexed caseId, address indexed creator, uint256 openingBrief, string title, string task, string standard);
    /// @notice also emitted for a case's opening brief (position 0)
    event BriefFiled(uint256 indexed briefId, uint256 indexed caseId, address indexed author, uint256 position, string text);
    event HearingOpened(uint256 indexed briefId, uint256 indexed caseId, uint256 precedent, bytes32 requestId);
    event HearingStalled(uint256 indexed caseId, uint256 indexed briefId); // the requester failed; retry with hear()
    event Verdict(uint256 indexed briefId, uint256 indexed caseId, BriefStatus outcome, uint256 precedent, uint16 agreed);
    event Unheard(uint256 indexed briefId, uint256 indexed caseId, uint256 refunded);
    event MistrialRefund(uint256 indexed briefId, uint256 indexed caseId, uint256 refunded);
    event CaseSettled(uint256 indexed caseId, address indexed winner, uint256 precedent, uint256 prize);
    event CreatorClaimed(address indexed creator, uint256 indexed caseId, uint256 amount);
    event PlatformWithdrawn(uint256 toTreasury, uint256 toRewards);
    event ParamsSet(Params p);
    event TreasurySet(address treasury);
    event Paused(bool paused);
    event CaseOracleMoved(uint256 indexed caseId, uint256 oracleId);
    event SinkProposed(address sink, uint16 bps, uint256 readyAt);
    event SinkChanged(address sink, uint16 bps);
    event SinkCancelled();
    event HolderTokenSet(address token);

    // ---------------------------------------------------------------- errors

    error BadText();
    error BadDuration();
    error SeedTooSmall();
    error FeeTooSmall();
    error IsPaused();
    error NotOpen();
    error EntriesClosed();
    error WrongStatus();
    error TooEarly();
    error NotCreator();
    error NothingToClaim();
    error BadParams();
    error OutOfGas();
    error NotHolder();

    // ---------------------------------------------------------------- constructor

    constructor(IERC20 imd_, BriefsText text_, BriefsJury jury_, address treasury_, Params memory p)
        Ownable(msg.sender)
    {
        if (
            address(imd_) == address(0) || address(text_) == address(0) || address(jury_) == address(0)
                || treasury_ == address(0)
        ) revert BadParams();
        imd = imd_;
        text = text_;
        jury = jury_;
        treasury = treasury_;
        _setParams(p);
        jury_.bind(text_); // the jury serves this contract only
    }

    // ---------------------------------------------------------------- owner

    function setParams(Params calldata p) external onlyOwner {
        _setParams(p);
    }

    function setTreasury(address t) external onlyOwner {
        if (t == address(0)) revert BadParams();
        treasury = t;
        emit TreasurySet(t);
    }

    /// @notice The token holders-only cases check. Applies to cases opened after the change; address(0) stops new
    ///         holders-only cases. Running cases keep the token they opened with.
    function setHolderToken(IERC20 t) external onlyOwner {
        holderToken = t;
        emit HolderTokenSet(address(t));
    }

    /// @notice Stop new cases. Entries to open cases, hearings, payouts and claims are never paused: a running
    ///         case keeps its deadline, so pausing its entries would hand the pot to whoever leads.
    function setPaused(bool p) external onlyOwner {
        paused = p;
        emit Paused(p);
    }

    /// @notice A creator moves their case to the newest oracle setup, while nothing is waiting. Nobody else can.
    function useLatestOracle(uint256 caseId) external {
        Case storage c = cases[caseId];
        if (msg.sender != c.creator) revert NotCreator();
        // only before the first entry: players join a case on the jury it names, and that never changes under them
        if (docketOf[caseId].length != 0) revert WrongStatus();
        c.oracleId = uint32(jury.latest());
        emit CaseOracleMoved(caseId, c.oracleId);
    }

    /// @notice Plan where part of the platform's share goes later (e.g. a rewards contract). Takes effect after
    ///         CONFIG_DELAY via applySink(); bps ≤ MAX_REWARDS_BPS. (address(0), 0) plans to stop routing.
    function proposeSink(IRewardsSink sink, uint16 bps) external onlyOwner {
        if (bps > MAX_REWARDS_BPS || (address(sink) == address(0)) != (bps == 0)) revert BadParams();
        pendingSink = sink;
        pendingRewardsBps = bps;
        sinkReadyAt = block.timestamp + CONFIG_DELAY;
        emit SinkProposed(address(sink), bps, sinkReadyAt);
    }

    /// @notice Anyone applies a planned sink once the delay is over. Everything accrued before is first paid out
    ///         under the old routing, so a change never reaches back.
    function applySink() external nonReentrant {
        if (sinkReadyAt == 0 || block.timestamp < sinkReadyAt) revert TooEarly();
        _withdrawPlatform();
        rewardsSink = pendingSink;
        rewardsBps = pendingRewardsBps;
        delete pendingSink;
        delete pendingRewardsBps;
        sinkReadyAt = 0;
        emit SinkChanged(address(rewardsSink), rewardsBps);
    }

    function cancelSink() external onlyOwner {
        delete pendingSink;
        delete pendingRewardsBps;
        sinkReadyAt = 0;
        emit SinkCancelled();
    }

    /// @notice Pay out the platform's share: rewardsBps of it to the sink (none at launch), the rest to the treasury.
    function withdrawPlatform() external nonReentrant {
        if (platformOwed == 0) revert NothingToClaim();
        _withdrawPlatform();
    }

    // ---------------------------------------------------------------- cases

    struct CaseInput {
        string title; // display name, 3–48 characters; never sent to the jury
        string task; // what players should write, 10–240 bytes
        string standard; // how two answers are compared ("The funnier brief wins."), 5–160 bytes
        string opening; // the creator's own answer, 1–maxBrief bytes: the first precedent
        uint8 avatar; // the face the site shows for the case (any of 256; the site falls back for unknown ones)
        uint256 seed; // the starting pot in IMD; it all goes to the winner
        uint256 fee; // the entry fee in IMD, fixed for the case's life
        uint64 endsAt; // entries close at this unix time, within minDuration..maxDuration from now
        uint256 minHold; // 0: anyone may file. Otherwise (owner only) only holders of at least this much holderToken
    }

    /// @notice Open a case. The creator's opening brief is the first precedent; the seed is the starting pot.
    function openCase(CaseInput calldata x) external nonReentrant returns (uint256 id) {
        if (paused) revert IsPaused();
        text.check(bytes(x.title), MIN_TITLE, MAX_TITLE, MAX_TITLE * 4);
        text.check(bytes(x.task), MIN_TASK, MAX_TASK, MAX_TASK);
        text.check(bytes(x.standard), MIN_STANDARD, MAX_STANDARD, MAX_STANDARD);
        text.check(bytes(x.opening), MIN_BRIEF, params.maxBrief, params.maxBrief);
        id = _newCase(x);
        uint256 openingId = cases[id].precedent;
        titleOf[id] = x.title;
        taskOf[id] = x.task;
        standardOf[id] = x.standard;
        briefText[openingId] = x.opening;
        emit CaseOpened(id, msg.sender, openingId, x.title, x.task, x.standard);
        emit BriefFiled(openingId, id, msg.sender, 0, x.opening);
    }

    /// @notice File a brief: pay the entry fee and join the end of the docket. If nothing is being heard, the
    ///         hearing opens right away.
    function fileBrief(uint256 caseId, string calldata words) external nonReentrant returns (uint256 id) {
        Case storage c = cases[caseId];
        if (c.status != CaseStatus.Open) revert NotOpen();
        if (block.timestamp >= c.endsAt) revert EntriesClosed();
        text.check(bytes(words), MIN_BRIEF, c.maxBrief, c.maxBrief);
        if (!holds(caseId, msg.sender)) revert NotHolder();

        // no oracle call here: filing never depends on the oracle (a hearing checks the price when it opens)
        uint256 fee = c.fee;
        uint96 reserve = c.reserve;

        id = ++briefCount;
        Brief storage b = briefs[id];
        b.author = msg.sender;
        b.caseId = uint64(caseId);
        b.status = BriefStatus.Queued;
        b.filedAt = uint64(block.timestamp);
        b.oracleReserve = reserve;
        briefText[id] = words;
        docketOf[caseId].push(id);

        // the fee waits in escrow until the verdict: only then is it split, and an unheard brief gets it all back
        imd.safeTransferFrom(msg.sender, address(this), fee);
        emit BriefFiled(id, caseId, msg.sender, docketOf[caseId].length - cases[caseId].head, words);
        _hearNext(caseId);
    }

    /// @notice The creator claims their earnings from the listed cases (any time, open or settled).
    function claimCreator(uint256[] calldata caseIds) external nonReentrant returns (uint256 total) {
        for (uint256 i; i < caseIds.length; i++) {
            Case storage c = cases[caseIds[i]];
            if (c.creator != msg.sender) revert NotCreator();
            uint256 owed = c.creatorOwed;
            if (owed == 0) continue;
            c.creatorOwed = 0;
            c.creatorClaimed += owed;
            total += owed;
            emit CreatorClaimed(msg.sender, caseIds[i], owed);
        }
        if (total == 0) revert NothingToClaim();
        imd.safeTransfer(msg.sender, total);
    }

    // ---------------------------------------------------------------- hearings

    /// @notice Open the next hearing if none is running (after a requester failure, say). Anyone may call it.
    function hear(uint256 caseId) external nonReentrant {
        if (cases[caseId].hearing != 0) revert WrongStatus();
        _hearNext(caseId);
        _maybeSettle(caseId);
    }

    /// @notice Bring the jury's signed answer for the hearing of `briefId`. Anyone may call it (a keeper, the author).
    ///         BriefsJury checks it (window, panel, the hearing's question, delivery by IMD's Intake, signature).
    function fulfill(uint256 briefId, ImdOracle.AttestationV2 calldata att, bytes calldata signature)
        external
        nonReentrant
    {
        Brief storage b = briefs[briefId];
        if (b.status != BriefStatus.Hearing) revert WrongStatus();
        bool better = jury.verdict(briefId, att, signature);

        uint256 caseId = b.caseId;
        Case storage c = cases[caseId];
        _split(c, uint256(c.fee) - b.oracleReserve); // a verdict at last: the fee less the jury's price is split now
        if (better) {
            b.status = BriefStatus.Overruled;
            c.precedent = uint64(briefId);
            c.streak = 0;
        } else {
            b.status = BriefStatus.Sustained;
            c.streak += 1;
        }
        c.hearing = 0;
        emit Verdict(briefId, caseId, b.status, c.precedent, att.agreed);
        _hearNext(caseId);
        _maybeSettle(caseId);
    }

    /// @notice No answer within the hearing's answerTimeout (the panel could not agree, or nobody delivered):
    ///         a mistrial, the precedent stands, the docket moves on, and the author gets the fee back less the
    ///         jury's price (nothing goes to the pot, so a failing jury never feeds the leader's prize). Anyone may
    ///         call it, MISTRIAL_GRACE after the timeout, so an answer issued in time but still on its way cannot be raced;
    ///         DELIVERED_GRACE once IMD's Intake has delivered an answer, so nobody who dislikes it can race the keeper.
    function mistrial(uint256 caseId) external nonReentrant {
        Case storage c = cases[caseId];
        uint256 briefId = c.hearing;
        if (briefId == 0) revert WrongStatus();
        Brief storage b = briefs[briefId];
        uint256 grace = jury.wasDelivered(briefId) ? DELIVERED_GRACE : MISTRIAL_GRACE;
        if (block.timestamp <= uint256(b.heardAt) + b.answerTimeout + grace) revert TooEarly();
        b.status = BriefStatus.Mistrial;
        c.hearing = 0;
        uint256 back = uint256(c.fee) - b.oracleReserve;
        imd.safeTransfer(b.author, back);
        emit Verdict(briefId, caseId, BriefStatus.Mistrial, c.precedent, 0);
        emit MistrialRefund(briefId, caseId, back);
        _hearNext(caseId);
        _maybeSettle(caseId);
    }

    /// @notice Escape hatch for a brief whose hearing keeps failing to open (the oracle is down, or this one request
    ///         fails): with no hearing running, the brief at the head of the docket is skipped and its whole fee
    ///         returned, so the docket moves on and the case can still be settled. Allowed STALL_WAIT after the head
    ///         first failed to open (stalledSince, started by any hear() that stalls), or STALL_GRACE after entries
    ///         closed. Anyone may call it, once per brief.
    function skipStalled(uint256 caseId) external nonReentrant {
        Case storage c = cases[caseId];
        uint256[] storage ids = docketOf[caseId];
        if (c.status != CaseStatus.Open || c.hearing != 0 || c.head >= ids.length) revert WrongStatus();
        uint256 since = c.stalledSince;
        if (block.timestamp < uint256(c.endsAt) + STALL_GRACE && (since == 0 || block.timestamp < since + STALL_WAIT)) {
            revert TooEarly();
        }
        // the oracle must be failing right now, in this very call: if a hearing can open, it opens instead
        if (!_hearNext(caseId)) {
            if (c.hearing != 0) return;
            revert WrongStatus();
        }
        _skip(caseId, c, ids[c.head]);
        _maybeSettle(caseId);
    }

    /// @notice Pay the pot to the standing precedent once entries are closed and the docket is fully heard.
    ///         Hearings call this by themselves; anyone may call it too.
    function settle(uint256 caseId) external nonReentrant {
        if (!_maybeSettle(caseId)) revert TooEarly();
    }

    // ---------------------------------------------------------------- views

    function getParams() external view returns (Params memory) {
        return params;
    }

    function getCase(uint256 id) external view returns (Case memory) {
        return cases[id];
    }

    function getBrief(uint256 id) external view returns (Brief memory) {
        return briefs[id];
    }

    /// @notice Whether `who` may file in a case today: always for an open-to-all case, otherwise only while holding
    ///         at least the case's minHold of its token. Checked when filing only, not when the pot is paid.
    function holds(uint256 caseId, address who) public view returns (bool) {
        Case storage c = cases[caseId];
        if (c.minHold == 0) return true;
        (bool ok, bytes memory r) = c.holdToken.staticcall{gas: HOLD_GAS}(abi.encodeCall(IERC20.balanceOf, (who)));
        return ok && r.length >= 32 && abi.decode(r, (uint256)) >= c.minHold;
    }

    /// @notice Briefs still waiting on a case's docket, the one being heard first.
    function waiting(uint256 caseId) external view returns (uint256) {
        Case storage c = cases[caseId];
        return docketOf[caseId].length - c.head + (c.hearing != 0 ? 1 : 0);
    }

    /// @notice A case's brief ids in docket order, from `from` (at most `max`). The opening brief is not included.
    function docket(uint256 caseId, uint256 from, uint256 max) external view returns (uint256[] memory out) {
        uint256[] storage ids = docketOf[caseId];
        uint256 n = from >= ids.length ? 0 : ids.length - from;
        if (n > max) n = max;
        out = new uint256[](n);
        for (uint256 i; i < n; i++) out[i] = ids[from + i];
    }

    /// @notice Whether settle(caseId) would pay now.
    function canSettle(uint256 caseId) public view returns (bool) {
        Case storage c = cases[caseId];
        return c.status == CaseStatus.Open && block.timestamp >= c.endsAt && c.hearing == 0
            && c.head == docketOf[caseId].length;
    }

    // ---------------------------------------------------------------- internal

    /// @dev A fee after the jury's price: creatorBps to the creator (claimable), platformBps to the platform,
    ///      the rest (with rounding dust) into the pot.
    function _split(Case storage c, uint256 rest) private {
        uint256 toCreator = (rest * c.creatorBps) / BPS;
        uint256 toPlatform = (rest * c.platformBps) / BPS;
        c.creatorOwed += toCreator;
        platformOwed += toPlatform;
        c.pot += rest - toCreator - toPlatform;
    }

    function _newCase(CaseInput calldata x) private returns (uint256 id) {
        Params storage p = params;
        (uint256 seed, uint256 fee, uint64 endsAt) = (x.seed, x.fee, x.endsAt);
        if (endsAt < block.timestamp + p.minDuration || endsAt > block.timestamp + p.maxDuration) revert BadDuration();
        if (x.minHold != 0) {
            _checkOwner(); // holders-only cases are the owner's to open
            if (address(holderToken) == address(0)) revert BadParams();
        }
        if (seed < p.minSeed || seed == 0) revert SeedTooSmall();
        // fee ≥ minFee > maxOracleFee (setParams), so a hearing always leaves part of the fee after the jury
        if (p.caseFee != 0) imd.safeTransferFrom(msg.sender, treasury, p.caseFee);
        if (fee < p.minFee) revert FeeTooSmall();
        if (fee > type(uint128).max || seed > type(uint128).max) revert BadParams();

        id = ++caseCount;
        uint256 openingId = ++briefCount;
        Case storage c = cases[id];
        c.creator = msg.sender;
        c.createdAt = uint64(block.timestamp);
        c.oracleId = uint32(jury.latest());
        c.endsAt = endsAt;
        c.status = CaseStatus.Open;
        c.creatorBps = p.creatorBps;
        c.platformBps = p.platformBps;
        c.precedent = uint64(openingId);
        c.panelSize = p.panelSize;
        c.quorum = p.quorum;
        c.answerTimeout = p.answerTimeout;
        c.fee = uint128(fee);
        c.seed = uint128(seed);
        c.pot = seed;
        c.maxBrief = p.maxBrief;
        c.reserve = uint96(p.maxOracleFee);
        if (x.minHold != 0) {
            c.holdToken = address(holderToken);
            c.minHold = x.minHold;
        }
        avatarOf[id] = x.avatar;

        Brief storage b = briefs[openingId];
        b.author = msg.sender;
        b.caseId = uint64(id);
        b.status = BriefStatus.Opening;
        b.filedAt = uint64(block.timestamp);

        imd.safeTransferFrom(msg.sender, address(this), seed);
    }

    function _skip(uint256 caseId, Case storage c, uint256 briefId) private {
        Brief storage b = briefs[briefId];
        c.head += 1;
        c.stalledSince = 0; // the next brief gets its own wait
        b.status = BriefStatus.Unheard;
        uint256 back = c.fee; // never heard, so nothing was split: the whole entry fee goes back
        b.oracleReserve = 0;
        imd.safeTransfer(b.author, back);
        emit Unheard(briefId, caseId, back);
    }

    /// @dev Open the next hearing on the docket, if none is running. A failing requester leaves the brief at the
    ///      head of the docket (HearingStalled) for a later hear(); it never blocks the answer that called this.
    function _hearNext(uint256 caseId) private returns (bool stalled) {
        Case storage c = cases[caseId];
        if (c.hearing != 0 || c.status != CaseStatus.Open) return false;
        uint256[] storage ids = docketOf[caseId];
        BriefsJury.Oracle memory o = jury.get(c.oracleId);
        for (uint256 steps; steps < STEPS && c.head < ids.length; steps++) {
            uint256 briefId = ids[c.head];
            Brief storage b = briefs[briefId];
            (bool quoted, uint256 price) = _tryQuote(o.requester);
            if (!quoted) return _stalled(c, caseId, briefId);
            if (price > b.oracleReserve) {
                _skip(caseId, c, briefId); // the oracle got dearer than this brief reserved: hand the fee back
                continue;
            }
            // the question is built out here; hearingGas covers openHearing as a whole (the requester and the
            // bookkeeping around it: about 265k on IMD's Intake)
            string memory input = jury.requestInput(c.oracleId, caseId, briefId, c.precedent, c.panelSize, c.quorum);
            // a caller must not fake a stall by sending too little gas: checked after the build, so the hearing
            // always gets the full hearingGas
            if (gasleft() < uint256(o.hearingGas) * 64 / 63 + RESERVE_GAS) revert OutOfGas();
            try this.openHearing{gas: o.hearingGas}(caseId, briefId, price, o.requester, input) {}
            catch {
                return _stalled(c, caseId, briefId);
            }
            return false;
        }
    }

    function _stalled(Case storage c, uint256 caseId, uint256 briefId) private returns (bool) {
        if (c.stalledSince == 0) c.stalledSince = uint64(block.timestamp);
        emit HearingStalled(caseId, briefId);
        return true;
    }

    /// @notice Internal step, external only so a failing requester rolls back cleanly. Callable by this contract only.
    function openHearing(uint256 caseId, uint256 briefId, uint256 price, IImdRequester r, string calldata input)
        external
    {
        if (msg.sender != address(this)) revert NotCreator();
        Case storage c = cases[caseId];
        Brief storage b = briefs[briefId];
        uint256 precedentId = c.precedent;
        imd.forceApprove(address(r), price);
        uint256 before = imd.balanceOf(address(this));
        bytes32 requestId = r.request(input, address(jury)); // the jury takes the answer
        // the requester must take exactly what it quoted and return a fresh id; otherwise everything rolls back
        if (before - imd.balanceOf(address(this)) != price || requestId == bytes32(0) || briefOfRequest[requestId] != 0) {
            revert BadParams();
        }
        imd.forceApprove(address(r), 0);
        c.head += 1;
        c.hearing = uint64(briefId);
        b.status = BriefStatus.Hearing;
        b.heardAt = uint64(block.timestamp);
        b.answerTimeout = c.answerTimeout;
        b.panelSize = c.panelSize;
        b.quorum = c.quorum;
        b.oracleId = c.oracleId;
        b.against = uint64(precedentId);
        b.requestId = requestId;
        briefOfRequest[requestId] = briefId;
        c.stalledSince = 0;
        b.oracleReserve = uint96(price); // the fee less this is split on the verdict, or handed back on a mistrial
        emit HearingOpened(briefId, caseId, precedentId, requestId);
    }

    function _maybeSettle(uint256 caseId) private returns (bool) {
        if (!canSettle(caseId)) return false;
        Case storage c = cases[caseId];
        address winner = briefs[c.precedent].author;
        uint256 prize = c.pot;
        c.status = CaseStatus.Settled;
        c.winner = winner;
        c.pot = 0;
        imd.safeTransfer(winner, prize);
        emit CaseSettled(caseId, winner, c.precedent, prize);
        return true;
    }

    function _withdrawPlatform() private {
        uint256 amount = platformOwed;
        if (amount == 0) return;
        platformOwed = 0;
        uint256 toRewards = address(rewardsSink) == address(0) ? 0 : (amount * rewardsBps) / BPS;
        if (toRewards != 0) {
            // the sink pulls its part inside notifyReward; whatever it does not take (it reverts, it is broken)
            // goes to the treasury, so a bad sink can never lock the platform's share or block its own replacement
            IRewardsSink sink = rewardsSink;
            imd.forceApprove(address(sink), toRewards);
            uint256 before = imd.balanceOf(address(this));
            if (gasleft() < SINK_GAS + SINK_GAS / 63 + RESERVE_GAS) revert OutOfGas();
            try sink.notifyReward{gas: SINK_GAS}(toRewards) {} catch {}
            imd.forceApprove(address(sink), 0);
            uint256 left = imd.balanceOf(address(this));
            uint256 pulled = left < before ? before - left : 0;
            toRewards = pulled < toRewards ? pulled : toRewards;
        }
        imd.safeTransfer(treasury, amount - toRewards);
        emit PlatformWithdrawn(amount - toRewards, toRewards);
    }

    function _tryQuote(IImdRequester r) private view returns (bool, uint256) {
        if (gasleft() < QUOTE_GAS + QUOTE_GAS / 63 + RESERVE_GAS) revert OutOfGas();
        try r.fee{gas: QUOTE_GAS}() returns (uint256 price) {
            return (true, price);
        } catch {
            return (false, 0);
        }
    }

    function _setParams(Params memory p) private {
        if (
            uint256(p.creatorBps) + p.platformBps > 3_000 || p.minFee <= p.maxOracleFee || p.maxOracleFee > 5 ether
                || p.maxOracleFee > type(uint96).max || p.quorum < 2 || p.quorum > p.panelSize
                || uint256(p.quorum) * 2 <= p.panelSize || p.panelSize > 100 || p.answerTimeout < 3 minutes
                || p.answerTimeout > 2 hours || p.caseFee > CASE_FEE_CAP || p.minDuration < DURATION_FLOOR
                || p.maxDuration > DURATION_CAP || p.minDuration >= p.maxDuration || p.maxBrief < BRIEF_FLOOR
                || p.maxBrief > BRIEF_CAP
        ) revert BadParams();
        params = p;
        emit ParamsSet(p);
    }

    /// @dev Ownership can be handed over (two-step) but never dropped: an ownerless contract could not be maintained.
    function renounceOwnership() public view override onlyOwner {
        revert BadParams();
    }
}
