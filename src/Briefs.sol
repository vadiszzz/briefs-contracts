// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ImdOracle} from "./ImdOracle.sol";
import {IImdRequester} from "./interfaces/IImdRequester.sol";
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
///         pays the jury (at most the case's reserve: maxOracleFee when the case opens, which raiseReserve can
///         only lift). On a verdict, of the rest,
///         creatorBps to the case creator (accrues on the case, claimed by the creator), platformBps to the
///         platform, the rest into the pot. A mistrial hands the rest back to the brief's author; a brief that is
///         never heard gets its whole fee back. The pot is never used to pay the jury.
///
///         Platform share: kept in the contract and withdrawn to the treasury by anyone. The owner can't touch pots,
///         escrowed fees, creator earnings or shares for time as the leader.
///
///         The owner tunes numbers within hard bounds (new cases only: a case fixes its split, jury, panel,
///         answer window and brief length when it opens; its jury reserve can only be lifted, see raiseReserve), pauses new cases (entries, hearings and payouts keep
///         running). Opening a case costs a flat caseFee, paid to the treasury.
///
///         The owner can open holders-only cases (minHold > 0): only addresses holding at least that much of
///         holderToken may file briefs in them. Token and amount are fixed when the case opens.
///         Oracle setups and answer checks live in BriefsJury (new setups only after a public delay).
///
///         The pot: reignBps of it is shared by time as the leader (from when the first winning challenger was filed
///         until the deadline; each leader counts from its own filing, so the queue moves nobody's time), the rest
///         goes to the final leader. A new leader late in a case pushes its deadline
///         (overtime), up to a final limit when the case has one. The owner sets the share and the limit, or lets
///         each creator pick them; either way a case fixes them when it opens.
///
///         Anyone may file a brief for its author with the author's signature (fileBriefFor), paying the fee: so a
///         relayer can take the payment somewhere else (IMD on Ethereum, say) and file here for the player.
contract Briefs is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- constants

    uint256 public constant BPS = 10_000;
    // the title, task and standard limits are in BriefsText (MIN_TITLE … MAX_STANDARD). The briefs go to the jury, so
    // their limit counts UTF-8 bytes: IMD takes questions up to 2,000 characters, and a byte is never less than a
    // character however IMD counts them (code points, UTF-16 units or bytes). A question carries the task, the
    // standard, two briefs and under 400 bytes of wording, so a brief can never be longer than 600 bytes.
    uint256 public constant BRIEF_CAP = 600;
    uint256 public constant BRIEF_FLOOR = 100;
    uint256 public constant DURATION_FLOOR = 5 minutes;
    uint256 public constant DURATION_CAP = 365 days;
    uint256 public constant CASE_FEE_CAP = 1_000 ether;
    uint256 public constant REIGN_CAP_BPS = 9_000; // the final leader always keeps at least 10% of the pot
    uint256 public constant OVERTIME_CAP = 1 hours;
    uint256 public constant STALL_GRACE = 3 days; // see skipStalled
    uint256 public constant STALL_WAIT = 6 hours; // see skipStalled
    uint256 public constant MISTRIAL_GRACE = 2 minutes; // a timely answer can still land this long after the timeout
    // the same, once IMD's Intake has delivered an answer on chain: long enough to outlast a keeper outage (anyone can
    // relay the answer; IMD's answers stay valid for 24 h), short enough that an unusable delivery doesn't hold the docket
    uint256 public constant DELIVERED_GRACE = 6 hours;
    uint256 internal constant STEPS = 16; // briefs skipped at most per call while looking for the next hearing
    uint256 internal constant QUOTE_GAS = 100_000; // gas the requester's fee() gets
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
        uint16 reignBps; // share of the pot paid for time as the leader (the rest goes to the final leader)
        uint32 overtime; // a new leader in a case's last `overtime` seconds pushes its deadline to now + overtime
        uint32 finalCap; // overtime never runs a case more than this past its first deadline (0: no limit)
        bool creatorSetsReign; // case creators pick their own reignBps (up to REIGN_CAP_BPS) instead of the one above
        bool creatorSetsCap; // case creators pick their own finalCap (0 included) instead of the one above
    }

    IERC20 public immutable imd;
    BriefsText public immutable text;
    BriefsJury public immutable jury;

    Params internal params;

    bool public paused; // no new cases; entries, hearings, payouts and claims continue
    address public treasury;
    uint256 public platformOwed; // the platform's share, not yet withdrawn
    // payments the token refused (a blocked address, say): kept here for the payee to pull, so no single payee can
    // stop a docket or a settlement
    mapping(address => uint256) public unpaid;
    uint256 public unpaidTotal;
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
        uint16 maxBrief; // longest brief, in UTF-8 bytes (in an English case, also in characters)
        uint256 minHold; // holders only: the balance of holdToken a brief's author must hold when filing
        uint96 reserve; // the most a hearing may pay the jury: params.maxOracleFee at creation (raiseReserve may lift it)
        uint64 stalledSince; // when the brief at the head of the docket first failed to open (0: not stalled)
        // time as the leader: only challengers who took the lead (COOKED) earn it, until the deadline
        uint16 reignBps; // share of the pot for time as the leader, fixed at creation
        uint32 overtime; // fixed at creation
        uint64 reignStart; // when the standing leader took the lead (0: the opening brief leads, nobody's time)
        uint64 firstReign; // when the first challenger took the lead before the deadline (0: never)
        uint64 reignTotal; // settled: seconds from firstReign to the deadline (every leader's seconds add up to it)
        uint256 reignPool; // settled: the part of the pot paid for time as the leader
        uint256 reignPaid; // of reignPool, paid so far
        uint64 finalEnd; // overtime never pushes the deadline past this (0: no limit), fixed at creation
        uint64 reignEnd; // time as the leader counts until here: the first deadline (overtime only decides the final leader)
        uint256 overtimePot; // of pot, what briefs filed in overtime added: it goes to the final leader alone
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
    /// @notice the language a case's briefs must be in (0: any; see BriefsText.LANG_*)
    mapping(uint256 => uint8) public langOf;
    mapping(uint256 => uint8) public avatarOf;
    /// @notice the brief's words (stored: each hearing quotes the standing precedent)
    mapping(uint256 => string) public briefText;
    /// @notice every filed brief id of a case, in docket order (the opening brief is not included): docketOf(case, i)
    mapping(uint256 => uint256[]) public docketOf;
    mapping(bytes32 => uint256) public briefOfRequest;
    /// @notice seconds an author led a case before its first deadline (as a challenger who took the lead); 0 once
    ///         their share is paid (claimReign; the ReignPaid event keeps the seconds)
    mapping(uint256 => mapping(address => uint256)) public reignOf;

    // ---------------------------------------------------------------- events

    /// @notice deadline, seed and fee are in getCase(caseId); the face in avatarOf(caseId), the language in langOf(caseId)
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
    event HolderTokenSet(address token);
    event PaymentHeld(address indexed to, uint256 amount); // the token refused a payment: claimUnpaid() pulls it later
    event UnpaidClaimed(address indexed to, uint256 amount);
    event ReserveRaised(uint256 indexed caseId, uint256 reserve);
    event Overtime(uint256 indexed caseId, uint256 endsAt); // a new leader late in the case pushed the deadline
    event ReignPaid(uint256 indexed caseId, address indexed leader, uint256 seconds_, uint256 amount);

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
    error WrongOracle();
    error OracleTooExpensive();
    error SettingsChanged();

    // ---------------------------------------------------------------- constructor

    constructor(IERC20 imd_, BriefsText text_, BriefsJury jury_, address treasury_, Params memory p)
        Ownable(msg.sender)
    {
        if (address(imd_) == address(0) || address(text_) == address(0) || address(jury_) == address(0)) revert BadParams();
        imd = imd_;
        text = text_;
        jury = jury_;
        _checkTreasury(treasury_);
        treasury = treasury_;
        _setParams(p);
        jury_.bind(text_); // the jury serves this contract only
    }

    // ---------------------------------------------------------------- owner

    function setParams(Params calldata p) external onlyOwner {
        _setParams(p);
    }

    function setTreasury(address t) external onlyOwner {
        _checkTreasury(t);
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

    /// @notice Pay the platform's share to the treasury (a rewards splitter, later, is just another treasury).
    function withdrawPlatform() external nonReentrant {
        if (platformOwed == 0) revert NothingToClaim();
        _withdrawPlatform();
    }

    // ---------------------------------------------------------------- cases

    struct CaseInput {
        string title; // display name, 3–48 characters; never sent to the jury
        string task; // what players should write, at least 10 characters and at most 240 bytes
        string standard; // how two answers are compared ("The funnier brief wins."), at least 5 characters, at most 160 bytes
        string opening; // the creator's own answer, at least 1 character, at most maxBrief bytes: the first precedent
        uint8 avatar; // the face the site shows for the case (any of 256; the site falls back for unknown ones)
        uint256 seed; // the starting pot in IMD; it all goes to the winner
        uint256 fee; // the entry fee in IMD, fixed for the case's life
        uint64 endsAt; // entries close at this unix time, within minDuration..maxDuration from now
        uint256 minHold; // 0: anyone may file. Otherwise (owner only) only holders of at least this much holderToken
        uint32 oracleId; // the jury setup the creator saw (jury.latest()): the case is judged by it for life, or not opened
        // the creator's pick when the owner lets creators set it, otherwise the current setting (what the creator saw):
        uint16 reignBps; // share of the pot for time as the leader
        uint32 finalCap; // the most overtime may add past endsAt, in seconds (0: no limit)
        uint32 overtime; // the current setting, as the creator saw it (only the owner sets it)
        // the language briefs must be in (BriefsText: 0 any, 1 English) and, with a language only, a shorter limit for
        // them (0: the court's maxBrief). In English a byte is a character, so it is a limit in characters
        uint8 lang;
        uint16 maxBrief;
        // what opening costs and how fees split, as the creator saw them (the owner may change them for new cases)
        uint256 caseFee;
        uint16 creatorBps;
        uint16 platformBps;
    }

    /// @notice Open a case. The creator's opening brief is the first precedent; the seed is the starting pot.
    function openCase(CaseInput calldata x) external nonReentrant returns (uint256 id) {
        if (paused) revert IsPaused();
        id = _newCase(x);
        // the texts, the language and the brief limit (a shorter one comes with a language only), by BriefsText
        cases[id].maxBrief = uint16(
            text.checkCase(x.title, x.task, x.standard, x.opening, uint256(x.lang) | uint256(x.maxBrief) << 8 | uint256(params.maxBrief) << 32)
        );
        langOf[id] = x.lang;
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
    function fileBrief(uint256 caseId, string calldata words) external nonReentrant returns (uint256) {
        return _file(caseId, words, msg.sender);
    }

    /// @notice File a brief for `author`, who signed it (jury.relayMessage, personal_sign, until `deadline`); the
    ///         caller pays the entry fee. The brief is the author's in every way: the lead, the pot, time as the leader
    ///         and any refund go to the author. Lets players pay somewhere else (on another chain, say) and have a
    ///         relayer file for them; a signature files one brief, once.
    function fileBriefFor(uint256 caseId, string calldata words, address author, uint256 deadline, bytes calldata sig)
        external
        nonReentrant
        returns (uint256)
    {
        jury.useRelay(caseId, words, author, deadline, sig);
        return _file(caseId, words, author);
    }

    function _file(uint256 caseId, string calldata words, address author) private returns (uint256 id) {
        Case storage c = cases[caseId];
        if (c.status != CaseStatus.Open) revert NotOpen();
        if (block.timestamp >= c.endsAt) revert EntriesClosed();
        text.checkBrief(bytes(words), c.maxBrief, langOf[caseId]);
        if (!holds(caseId, author)) revert NotHolder();

        // filing never depends on the oracle working: a failing or silent requester never stops it (see below)
        uint256 fee = c.fee;
        uint96 reserve = c.reserve;

        id = ++briefCount;
        Brief storage b = briefs[id];
        b.author = author;
        b.caseId = uint64(caseId);
        b.status = BriefStatus.Queued;
        b.filedAt = uint64(block.timestamp);
        b.oracleReserve = reserve;
        briefText[id] = words;
        docketOf[caseId].push(id);
        // nothing being heard and the new brief within reach of this call's skips: if the jury's price is known and
        // above what this brief reserves, say so now instead of taking the fee and handing it back (an unknown price
        // never stops a filing)
        if (c.hearing == 0 && docketOf[caseId].length - c.head <= STEPS) {
            (bool quoted, uint256 price) = _tryQuote(jury.get(c.oracleId).requester);
            if (quoted && price > reserve) revert OracleTooExpensive();
        }

        // the fee waits in escrow until the verdict: only then is it split, and an unheard brief gets it all back
        imd.safeTransferFrom(msg.sender, address(this), fee);
        emit BriefFiled(id, caseId, author, docketOf[caseId].length - cases[caseId].head, words);
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

    /// @notice Pay `who` their part of a settled case's pool for time as the leader: reignPool × their seconds / all
    ///         seconds. Anyone may call it (the keeper pays everyone out after settlement); once per leader.
    function claimReign(uint256 caseId, address who) external nonReentrant {
        Case storage c = cases[caseId];
        uint256 secs = reignOf[caseId][who];
        if (c.status != CaseStatus.Settled || secs == 0) revert NothingToClaim();
        reignOf[caseId][who] = 0; // paid: the seconds stay in the ReignPaid event
        uint256 amount = (c.reignPool * secs) / c.reignTotal;
        c.reignPaid += amount;
        _pay(who, amount);
        emit ReignPaid(caseId, who, secs, amount);
    }

    /// @notice Pull a payment the token refused earlier (a pot, a refund): only to the payee, once the token lets it.
    function claimUnpaid() external nonReentrant {
        uint256 amount = unpaid[msg.sender];
        if (amount == 0) revert NothingToClaim();
        unpaid[msg.sender] = 0;
        unpaidTotal -= amount;
        imd.safeTransfer(msg.sender, amount);
        emit UnpaidClaimed(msg.sender, amount);
    }

    /// @notice If IMD's price rose above what a case reserves for a hearing and the owner has since raised
    ///         maxOracleFee, anyone may lift the case's reserve to it (up, never down, always below the case's fee),
    ///         so new entries can be heard again. It applies to briefs filed after the raise: a brief already queued
    ///         never pays the jury more than it reserved when filed (above that it is handed back with its whole fee).
    ///         Each hearing pays IMD's actual price and splits the rest.
    function raiseReserve(uint256 caseId) external nonReentrant {
        Case storage c = cases[caseId];
        uint256 r = params.maxOracleFee;
        if (c.status != CaseStatus.Open || r <= c.reserve || r >= c.fee) revert BadParams();
        c.reserve = uint96(r);
        emit ReserveRaised(caseId, r);
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
        // a verdict at last: the fee less the jury's price is split now; a brief filed in overtime pays the final leader only
        uint256 toPot = _split(c, uint256(c.fee) - b.oracleReserve);
        if (b.filedAt >= c.reignEnd) c.overtimePot += toPot;
        if (better) {
            b.status = BriefStatus.Overruled;
            _newLeader(caseId, c, b.filedAt); // its seconds are credited when it is replaced or at settlement
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
        _pay(b.author, back);
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
        uint256 head = c.head;
        if (!_hearNext(caseId)) {
            // a hearing opened, or briefs were already handed back because the jury got dearer: keep that progress
            if (c.hearing != 0 || c.head != head) {
                _maybeSettle(caseId);
                return;
            }
            revert WrongStatus();
        }
        // the head was handed back for its price and the next brief failed in this same call: it gets its own wait
        if (c.head != head && block.timestamp < uint256(c.endsAt) + STALL_GRACE) {
            _maybeSettle(caseId);
            return;
        }
        _skip(caseId, c, ids[c.head]);
        // the oracle was just seen failing: the next brief's wait starts now, not at some later hear()
        if (c.head < ids.length) c.stalledSince = uint64(block.timestamp);
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

    /// @notice Whether settle(caseId) would pay now.
    function canSettle(uint256 caseId) public view returns (bool) {
        Case storage c = cases[caseId];
        return c.status == CaseStatus.Open && block.timestamp >= c.endsAt && c.hearing == 0
            && c.head == docketOf[caseId].length;
    }

    // ---------------------------------------------------------------- internal

    /// @dev A fee after the jury's price: creatorBps to the creator (claimable), platformBps to the platform,
    ///      the rest (with rounding dust) into the pot.
    function _split(Case storage c, uint256 rest) private returns (uint256 toPot) {
        uint256 toCreator = (rest * c.creatorBps) / BPS;
        uint256 toPlatform = (rest * c.platformBps) / BPS;
        c.creatorOwed += toCreator;
        platformOwed += toPlatform;
        toPot = rest - toCreator - toPlatform;
        c.pot += toPot;
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
        // the setup the creator agreed to, never one applied in the meantime; it never changes for this case
        if (jury.latest() != x.oracleId) revert WrongOracle();
        c.oracleId = x.oracleId;
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
        c.reserve = uint96(p.maxOracleFee);
        // a setting the creator can't pick must be the one they saw: the owner may have changed it since
        if (p.creatorSetsReign ? x.reignBps > REIGN_CAP_BPS : x.reignBps != p.reignBps) revert SettingsChanged();
        if (p.creatorSetsCap ? x.finalCap > DURATION_CAP : x.finalCap != p.finalCap) revert SettingsChanged();
        if (x.overtime != p.overtime || x.caseFee != p.caseFee || x.creatorBps != p.creatorBps || x.platformBps != p.platformBps) {
            revert SettingsChanged();
        }
        c.reignBps = x.reignBps;
        c.overtime = x.overtime;
        if (x.finalCap != 0) c.finalEnd = endsAt + x.finalCap;
        c.reignEnd = endsAt;
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
        _pay(b.author, back);
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
            // never more than the brief reserved when it was filed (a later raiseReserve applies to later briefs)
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

    /// @dev A challenger just took the lead (COOKED). Its time counts from when it was **filed**: it was better from
    ///      then on, and the queue (FIFO, one hearing at a time) only decided when that came to light, so nobody gains
    ///      time by filling the queue ahead of a challenger, or by a slow jury or relay. The leader it replaces is
    ///      credited until that moment, never past the case's first deadline (reignEnd): overtime decides the final
    ///      leader but earns nobody time. The opening brief earns none. A new leader in the case's last `overtime`
    ///      seconds, before the deadline, pushes the deadline to now + overtime, never past finalEnd.
    function _newLeader(uint256 caseId, Case storage c, uint256 filedAt) private {
        uint256 t = block.timestamp;
        uint256 end = c.endsAt;
        uint256 stop = c.reignEnd;
        uint256 start = c.reignStart; // always before stop when set, and never after a later brief's filing (FIFO)
        uint256 from = filedAt > start ? filedAt : start;
        if (start != 0) reignOf[caseId][briefs[c.precedent].author] += (from < stop ? from : stop) - start;
        c.reignStart = 0; // filed at or after the first deadline: no time to earn
        if (from < stop) {
            if (c.firstReign == 0) c.firstReign = uint64(from);
            c.reignStart = uint64(from);
        }
        if (t < end) {
            uint256 later = t + c.overtime;
            uint256 cap = c.finalEnd;
            if (cap != 0 && later > cap) later = cap;
            if (later > end) {
                c.endsAt = uint64(later);
                emit Overtime(caseId, later);
            }
        }
    }

    function _maybeSettle(uint256 caseId) private returns (bool) {
        if (!canSettle(caseId)) return false;
        Case storage c = cases[caseId];
        address winner = briefs[c.precedent].author;
        uint256 stop = c.reignEnd;
        // the last leader's time, then the part of the pot for time as the leader: reignBps of it, scaled by the share
        // of the case's life (until its first deadline) that had a challenger in the lead (the time before the first
        // COOKED is nobody's). What briefs filed in overtime added is left out: it goes to the final leader alone
        if (c.reignStart != 0) reignOf[caseId][winner] += stop - c.reignStart;
        uint256 total = c.firstReign == 0 ? 0 : stop - c.firstReign;
        uint256 pool = ((c.pot - c.overtimePot) * c.reignBps * total) / (BPS * (stop - c.createdAt));
        uint256 prize = c.pot - pool;
        c.reignTotal = uint64(total);
        c.reignPool = pool;
        c.status = CaseStatus.Settled;
        c.winner = winner;
        c.pot = 0;
        _pay(winner, prize);
        emit CaseSettled(caseId, winner, c.precedent, prize);
        return true;
    }

    function _withdrawPlatform() private {
        uint256 amount = platformOwed;
        if (amount == 0) return;
        platformOwed = 0;
        imd.safeTransfer(treasury, amount);
        emit PlatformWithdrawn(amount, 0);
    }

    /// @dev Push a payment; if the token refuses it (the payee is blocked, say), keep it for claimUnpaid instead, so the
    ///      docket and the settlement never depend on one payee.
    function _pay(address to, uint256 amount) private {
        (bool ok, bytes memory ret) = address(imd).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (ok && (ret.length == 0 ? address(imd).code.length != 0 : ret.length >= 32 && abi.decode(ret, (uint256)) == 1)) {
            return;
        }
        unpaid[to] += amount;
        unpaidTotal += amount;
        emit PaymentHeld(to, amount);
    }

    /// @dev A requester that reverts, has no code or answers with anything but a uint256 is a failed quote (a stall),
    ///      never a revert of the caller: a low-level call, so even a malformed reply can't freeze a case.
    function _tryQuote(IImdRequester r) private view returns (bool, uint256) {
        if (gasleft() < QUOTE_GAS + QUOTE_GAS / 63 + RESERVE_GAS) revert OutOfGas();
        (bool ok, bytes memory ret) = address(r).staticcall{gas: QUOTE_GAS}(abi.encodeCall(IImdRequester.fee, ()));
        if (!ok || ret.length < 32) return (false, 0);
        return (true, abi.decode(ret, (uint256)));
    }

    /// @dev Never Briefs itself, its jury, the jury's requester, the IMD token or the text contract: IMD sent there would
    ///      sit behind no liability.
    function _checkTreasury(address t) private view {
        if (t == address(0) || t == address(this) || t == address(jury) || t == address(imd) || t == address(text)) {
            revert BadParams();
        }
        if (t == address(jury.get(jury.latest()).requester)) revert BadParams();
    }

    function _setParams(Params memory p) private {
        if (
            uint256(p.creatorBps) + p.platformBps > 3_000 || p.minFee <= p.maxOracleFee || p.maxOracleFee > 5 ether
                || p.maxOracleFee > type(uint96).max || p.quorum < 2 || p.quorum > p.panelSize
                || uint256(p.quorum) * 2 <= p.panelSize || p.panelSize > 100 || p.answerTimeout < 3 minutes
                || p.answerTimeout > 2 hours || p.caseFee > CASE_FEE_CAP || p.minDuration < DURATION_FLOOR
                || p.maxDuration > DURATION_CAP || p.minDuration >= p.maxDuration || p.maxBrief < BRIEF_FLOOR
                || p.maxBrief > BRIEF_CAP || p.reignBps > REIGN_CAP_BPS || p.overtime > OVERTIME_CAP
                || p.finalCap > DURATION_CAP
        ) revert BadParams();
        params = p;
        emit ParamsSet(p);
    }

    /// @dev Ownership can be handed over (two-step) but never dropped: an ownerless contract could not be maintained.
    function renounceOwnership() public view override onlyOwner {
        revert BadParams();
    }
}
