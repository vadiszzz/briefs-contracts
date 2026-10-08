// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ImdOracle} from "./ImdOracle.sol";
import {IImdRequester} from "./interfaces/IImdRequester.sol";
import {BriefsText} from "./BriefsText.sol";

/// @notice What the jury reads from its Briefs contract. BriefView mirrors Briefs.Brief field for field (the enum is a
///         uint8), so the jury can read a hearing without importing Briefs.
interface IBriefsCourt {
    struct BriefView {
        address author;
        uint64 caseId;
        uint8 status;
        uint16 panelSize;
        uint16 quorum;
        uint64 filedAt;
        uint64 heardAt;
        uint32 answerTimeout;
        uint32 oracleId;
        uint64 against;
        uint96 oracleReserve;
        bytes32 requestId;
    }

    function getBrief(uint256 id) external view returns (BriefView memory);
    function taskOf(uint256 caseId) external view returns (string memory);
    function standardOf(uint256 caseId) external view returns (string memory);
    function briefText(uint256 briefId) external view returns (string memory);
}

/// @title BriefsJury — everything Briefs says to and hears from the IMD oracle
/// @notice Briefs keeps the money and the docket; the jury keeps the oracle side, so IMD's formats never touch the
///         contract holding the pots. Holds no funds. It
///         - keeps the oracle setups (append-only; a new one applies after a public ORACLE_DELAY, and old ones stay
///           valid for the cases that use them),
///         - writes each hearing's request (the question quotes both briefs and names this contract and the brief),
///         - takes IMD's on-chain answers: its Intake calls onImdAnswer, and only the answer it delivered for a
///           hearing's request counts,
///         - checks an answer for a hearing (window, panel, questionHash, delivery, signature) and returns the verdict.
///         Requests name this contract as their EIP-712 consumer and callback, so IMD signs answers for its domain.
///         One jury serves one Briefs: Briefs binds itself when it is deployed, and only the address named at
///         deployment may (its address is known in advance), so nobody can bind first.
contract BriefsJury is Ownable2Step {
    uint256 public constant ORACLE_DELAY = 7 days;
    uint256 public constant ORACLE_WINDOW = 7 days; // a proposal not applied this long after it is ready lapses

    struct Oracle {
        address signer; // the IMD attester
        IImdRequester requester; // opens requests on chain
        bytes32 domain; // EIP-712 domain of the attestations (0: IMD's v2 domain addressed to the consumer)
        uint64 chainId; // the chain id IMD's requests carry and its attestations sign
        uint32 hearingGas; // gas every hearing gets for opening (the request and its bookkeeping); callers bring more
    }

    Oracle[] internal oracles;
    Oracle public pending;
    uint256 public readyAt;

    IBriefsCourt public court; // the Briefs contract this jury serves, bound once
    address public immutable expectedCourt; // when set at deployment, only it may bind (0: the first caller)
    BriefsText public text;
    /// @notice answers delivered on chain: source (IMD's Intake) => its request id => hash of the attestation
    mapping(address => mapping(bytes32 => bytes32)) public delivered;

    uint8 internal constant HEARING = 3; // Briefs.BriefStatus.Hearing

    event OracleProposed(Oracle o, uint256 readyAt);
    event OracleAdded(uint256 oracleId, Oracle o);
    event OracleCancelled();
    event Bound(address court);
    event AnswerDelivered(address indexed source, bytes32 indexed requestId);

    error BadOracle();
    error TooEarly();
    error WrongChain();
    error NotBool();
    error BadSignature();
    error AlreadyBound();
    error NotHearing();
    error AnsweredBeforeAsked();
    error Expired();
    error WrongPanel();
    error WrongQuestion();
    error NotDelivered();
    error Lapsed();
    error WrongCourt();

    constructor(Oracle memory first, address owner_, address court_) Ownable(owner_) {
        _check(first);
        oracles.push(first);
        expectedCourt = court_;
        emit OracleAdded(0, first);
    }

    /// @notice Briefs calls this from its constructor: the jury serves that one contract from then on.
    function bind(BriefsText text_) external {
        if (address(court) != address(0)) revert AlreadyBound();
        if (expectedCourt != address(0) && msg.sender != expectedCourt) revert WrongCourt();
        court = IBriefsCourt(msg.sender);
        text = text_;
        emit Bound(msg.sender);
    }

    function proposeOracle(Oracle calldata o) external onlyOwner {
        _check(o);
        pending = o;
        readyAt = block.timestamp + ORACLE_DELAY;
        emit OracleProposed(o, readyAt);
    }

    /// @notice Anyone adds the proposed setup once the delay is over, within ORACLE_WINDOW after (an old proposal
    ///         nobody applied must not surprise players later; propose it again).
    function applyOracle() external {
        if (pending.signer == address(0) || block.timestamp < readyAt) revert TooEarly();
        if (block.timestamp > readyAt + ORACLE_WINDOW) revert Lapsed();
        oracles.push(pending);
        delete pending;
        readyAt = 0;
        emit OracleAdded(oracles.length - 1, oracles[oracles.length - 1]);
    }

    function cancelOracle() external onlyOwner {
        delete pending;
        readyAt = 0;
        emit OracleCancelled();
    }

    function count() external view returns (uint256) {
        return oracles.length;
    }

    function latest() external view returns (uint256) {
        return oracles.length - 1;
    }

    function get(uint256 oracleId) external view returns (Oracle memory) {
        return oracles[oracleId];
    }

    // ---------------------------------------------------------------- hearings

    /// @notice The JSON body of the IMD request for the hearing of `briefId` against `precedentId`, under setup
    ///         `oracleId` with the case's panel. It names this contract as consumer (unless the setup pins a domain).
    function requestInput(uint256 oracleId, uint256 caseId, uint256 briefId, uint256 precedentId, uint16 panelSize, uint16 quorum)
        external
        view
        returns (string memory)
    {
        Oracle storage o = oracles[oracleId];
        uint256 packed = uint256(panelSize) << 128 | uint256(quorum) << 64 | o.chainId | (o.domain == bytes32(0) ? 1 << 255 : 0);
        return _inputFor(caseId, precedentId, briefId, packed);
    }

    /// @notice The request a heard brief's hearing opened (its precedent, setup and panel as they were then).
    function requestOf(uint256 briefId) external view returns (string memory) {
        IBriefsCourt.BriefView memory b = court.getBrief(briefId);
        return this.requestInput(b.oracleId, b.caseId, briefId, b.against, b.panelSize, b.quorum);
    }

    function _inputFor(uint256 caseId, uint256 precedentId, uint256 briefId, uint256 packed) private view returns (string memory) {
        return text.requestInput(
            court.taskOf(caseId),
            court.standardOf(caseId),
            court.briefText(precedentId),
            court.briefText(briefId),
            address(this),
            briefId,
            packed
        );
    }

    /// @notice The exact question for the hearing of `briefId` against `precedentId`.
    function question(uint256 briefId, uint256 precedentId) external view returns (string memory) {
        uint256 caseId = court.getBrief(briefId).caseId;
        return text.question(
            court.taskOf(caseId), court.standardOf(caseId), court.briefText(precedentId), court.briefText(briefId), address(this), briefId
        );
    }

    /// @notice The questionHash IMD signs for the hearing of `briefId` (against the precedent it was heard against),
    ///         given the block window the attestation pinned.
    function questionHashOf(uint256 briefId, uint64 fromBlock, uint64 toBlock) public view returns (bytes32) {
        IBriefsCourt.BriefView memory b = court.getBrief(briefId);
        return _questionHash(b, briefId, fromBlock, toBlock);
    }

    /// @notice IMD's Intake calls this with each answer (the callback every request names). It only records which
    ///         answer the caller delivered for which request: anyone may call it, but verdict() only looks at what
    ///         the hearing's own setup source (the Intake) delivered.
    function onImdAnswer(bytes32 requestId, ImdOracle.AttestationV2 calldata att, bytes calldata) external {
        delivered[msg.sender][requestId] = keccak256(abi.encode(att));
        emit AnswerDelivered(msg.sender, requestId);
    }

    /// @notice Whether IMD's Intake has delivered an answer for the running hearing of `briefId` (Briefs then waits
    ///         longer before a mistrial, so the keeper can land it).
    function wasDelivered(uint256 briefId) external view returns (bool) {
        IBriefsCourt.BriefView memory b = court.getBrief(briefId);
        address source = oracles[b.oracleId].requester.answerSource();
        return source != address(0) && delivered[source][b.requestId] != bytes32(0);
    }

    /// @notice The verdict an attestation gives for the running hearing of `briefId`, after every check: issued
    ///         within the hearing's window, the panel it ordered, the hearing's own question, delivered by the setup's
    ///         Intake (when it has one), signed by the setup's attester. Reverts on any mismatch.
    function verdict(uint256 briefId, ImdOracle.AttestationV2 calldata att, bytes calldata signature)
        external
        view
        returns (bool better)
    {
        IBriefsCourt.BriefView memory b = court.getBrief(briefId);
        if (b.status != HEARING) revert NotHearing();
        if (att.questionHash != _questionHash(b, briefId, att.fromBlock, att.toBlock)) revert WrongQuestion();
        address source = oracles[b.oracleId].requester.answerSource();
        if (source != address(0) && delivered[source][b.requestId] != keccak256(abi.encode(att))) revert NotDelivered();
        if (att.issuedAt < b.heardAt) revert AnsweredBeforeAsked();
        if (att.issuedAt > uint256(b.heardAt) + b.answerTimeout) revert Expired();
        if (block.timestamp > att.expiresAt) revert Expired();
        if (att.panelSize != b.panelSize || att.quorum != b.quorum || att.agreed < att.quorum) revert WrongPanel();
        return verify(b.oracleId, address(this), att, signature);
    }

    function _questionHash(IBriefsCourt.BriefView memory b, uint256 briefId, uint64 fromBlock, uint64 toBlock)
        private
        view
        returns (bytes32)
    {
        uint256 chainFromTo = uint256(oracles[b.oracleId].chainId) << 128 | uint256(fromBlock) << 64 | toBlock;
        return _hashFor(b.caseId, b.against, briefId, chainFromTo);
    }

    function _hashFor(uint256 caseId, uint256 against, uint256 briefId, uint256 chainFromTo) private view returns (bytes32) {
        return text.questionHash(
            court.taskOf(caseId),
            court.standardOf(caseId),
            court.briefText(against),
            court.briefText(briefId),
            address(this),
            briefId,
            chainFromTo
        );
    }

    /// @notice Check an attestation against setup `oracleId`: chain, bool answer and the attester's signature
    ///         (domain addressed to `consumer` unless the setup pins one). Returns the answer.
    ///         Timing, panel and question are checked by verdict(), which knows the hearing.
    function verify(uint256 oracleId, address consumer, ImdOracle.AttestationV2 calldata att, bytes calldata signature)
        public
        view
        returns (bool answer)
    {
        Oracle storage o = oracles[oracleId];
        if (att.chainId != o.chainId) revert WrongChain();
        if (att.answerType != ImdOracle.ANSWER_TYPE_BOOL) revert NotBool();
        bytes32 domain = o.domain != bytes32(0) ? o.domain : ImdOracle.domainSeparatorV("2", block.chainid, consumer);
        if (ECDSA.recover(ImdOracle.digestV2(domain, att), signature) != o.signer) revert BadSignature();
        bool ok;
        (ok, answer) = ImdOracle.decodeBool(att.answer);
        if (!ok) revert NotBool();
    }

    function _check(Oracle memory o) private view {
        if (
            o.signer == address(0) || address(o.requester) == address(0) || o.chainId == 0 || o.hearingGas < 200_000
                || o.hearingGas > 10_000_000
        ) revert BadOracle();
        // verdict() asks the requester for its answer source on every answer: it must answer (zero is fine).
        // An on-chain source (IMD's Intake) signs for the callback's domain, so a pinned domain can't go with it.
        if (o.requester.answerSource() != address(0) && o.domain != bytes32(0)) revert BadOracle();
    }

    /// @dev Ownership can be handed over (two-step) but never dropped: an ownerless contract could not be maintained.
    function renounceOwnership() public view override onlyOwner {
        revert BadOracle();
    }
}
