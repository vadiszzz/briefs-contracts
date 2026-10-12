# Internal audit, October 2026

This is our own review of `Briefs`, `BriefsJury`, `BriefsText` and `ImdOracle` before mainnet. It is not a substitute for an external audit. Three independent reviews ran in parallel (funds and accounting; oracle integrity and verdicts; liveness, griefing and admin powers), and every finding was checked with a Foundry PoC in `test/audit/`.

**Result:** no Critical or High issue. Several Medium issues were fixed; the rest are listed below as known, each with a passing `test_Known_*` test that documents the behaviour.

Test suite after the fixes: 83 tests, all passing, including an exact solvency invariant (contract balance equals the sum of open pots, creator earnings owed, the platform share and queued escrow) and a fuzz test that a fully settled case leaves nothing behind.

## Fixed

| # | Severity | Issue | Fix |
|---|---|---|---|
| 1 | Medium | The owner could pause entries (or lower `maxOracleFee`) while a case's deadline kept running, locking in whoever led | Pause now stops new cases only. Entries no longer check `maxOracleFee` |
| 2 | Medium | The owner and a case's creator together could move a live, funded case to a jury they control | `useLatestOracle` works only before the first entry |
| 3 | Medium | A brief that was never heard (oracle price rose, or the oracle died) got back only its 0.5 IMD jury reserve; the rest stayed with the leader, creator and platform. A leader could profit from a stalled docket | Entry fees now wait in escrow and are split only when the brief's hearing opens. An unheard brief gets its whole fee back |
| 4 | Medium | The request JSON was built inside the gas-capped hearing call, so one max-size brief could stall the docket when `hearingGas` was tight | The JSON is built before the capped call; `hearingGas` covers only the requester |
| 5 | Low | After fix 4, a caller could again fake a stall by sending just enough gas for the check but not for the build | The gas check now runs after the JSON is built (regression test included) |
| 6 | Low / Medium | Invisible Unicode (tag characters, variation selectors, fillers, U+2028/2029) could hide instructions the site never shows | Rejected by `BriefsText`; the site strips or rejects them before paying |
| 7 | Low | Look-alike delimiters (≪ ≫ ⟪ ⟫ ⪡ ⪢) could fake the end of a quoted brief | Rejected by `BriefsText`; the site turns them into plain quotes |
| 8 | Low | `renounceOwnership` would leave the contracts unmaintainable | It now reverts on both `Briefs` and `BriefsJury` |
| 9 | Info | The oracle price could exceed `uint96` and be truncated silently | Entries revert instead |

## Known, not fixed

**Must resolve before mainnet**

- ~~**`questionHash` is not checked against the hearing.**~~ Fixed after the review: `fulfill(briefId, …)` rebuilds the hearing's canonical request and requires the signed `questionHash` to match (formula matched on two live attestations). *Tests: `test_Fixed_F1_*`, `test_Fixed_F1b_*`, `test_QuestionHash_*`.* Originally: The verdict is tied to the hearing only by `requestId`. That is safe with an honest on-chain IMD requester. Under any relay design (plan B), whoever binds the request id could bind an answer to a different question. Fix: rebuild the canonical question in `fulfill` and require it to equal `att.questionHash`. This needs IMD's exact v2 key set, so it must be pinned against one live consumer-bound attestation first. *Tests: `test_Known_F1_*`, `test_Known_F1b_*`.*
- **The consumer-bound EIP-712 domain has only been checked with self-signed data.** If IMD's domain differs in any detail, every hearing ends in a mistrial and reserves are still spent. Confirm with one paid request naming a test consumer.
- **Gas sizing.** Measure the real requester and set `hearingGas` above its worst case with max-size input. The capped call no longer pays for building the question.

**Accepted for now**

- **Fee-on-transfer token (Low).** The contract assumes IMD is a plain ERC20. Confirm the Robinhood Chain IMD before deploying.
- **Surplus IMD is locked (Low).** IMD sent outside the accounting (including any refund IMD might send for unanswered requests) can't leave the contract. Ask IMD whether unanswered requests are refunded; if so, add a sweep of anything above liabilities to the treasury.
- **`caseFee` can change instantly (Low).** A malicious owner could raise it in front of a pending `openCase` if the creator's allowance covers it. Bounded by `setParams`; consider a delay or a `maxCaseFee` argument. (Fixed in v2: `openCase` names the fee and split it agreed to; see the eighth review.)
- ~~**Push payments (Low).**~~ Fixed in the fourth review: the IMD token on Robinhood Chain *can* block addresses, so a refused payment is now held for its payee instead.
- **Late answer race (Low).** After the 4-minute window plus 2-minute grace, anyone (usually the leader) can call `mistrial` ahead of a COOKED answer that was issued on time but not yet delivered. Our keeper delivers within seconds.
- **Attester rotation doesn't reach running cases (Info).** A compromised IMD key can't be revoked for cases already using it.
- **Spam delays settlement, at a price (Info).** Unanswerable briefs take about 6 minutes each; at the 1 IMD minimum, about 1,000 IMD buys about 4 days of delay.
- **Deadline sniping (Info).** Being last before the deadline is an advantage by design.
- **Stale sink proposal (Info).** A ready rewards-sink proposal never expires.

## Verified as fine

- **EIP-712 v2 digest:** typehash, field order and encoding are correct. No replay across hearings, cases, contracts or chains. High-s and compact signatures are rejected. Answers decode as a strict bool.
- **JSON integrity:** checked text can never escape the request JSON. A fuzz test confirms `allowAmbiguous`, `quorum`, `panelSize`, `consumer` and `question` always survive.
- **Accounting:**
  - The fee split leaves rounding dust in the pot.
  - The opening fee goes straight to the treasury, and the seed enters the pot once.
  - The pot pays out once.
  - Creator claims can't be doubled.
  - The rewards sink is capped at 50%, sits behind a 2-day delay, and can't reach pots or creator earnings.
- **Liveness:** every function needed to finish a case is permissionless (`hear`, `fulfill`, `mistrial`, `skipStalled`, `settle`, `withdrawPlatform`), so a case finishes even without our keeper. The FIFO queue and all loops are bounded.
- **Owner powers:** two-step ownership and no rescue functions. The owner can't touch pots, creator earnings or escrow. Per-case terms are fixed at creation.

## Added after this review (not yet reviewed)

October 2026, after the review above. Covered by `test/Holders.t.sol`; an external audit should look at both.

- **Holders-only cases.** Opened by the owner only. `setHolderToken` (owner), a per-case `minHold` fixed at opening, and `holds(caseId, who)`, a `balanceOf` staticcall capped at 50,000 gas. A reverting or gas-hungry token only stops entries to its own cases; the case still settles. The check is at filing only: one balance can be moved between wallets, or borrowed for one transaction, to pass it.
- **More settings.** `minDuration`, `maxDuration` and `maxBrief` moved from constants into `Params`, with hard bounds (5 minutes to 365 days, 100 to 600 bytes). Each case stores its own `maxBrief`. 600 keeps the longest question inside IMD's 2,000-character limit (tested; see the second review on bytes).
- **Split: the jury owns the oracle side.** Request building, the question and questionHash, the Intake callback and every answer check moved from `Briefs` into `BriefsJury.verdict`; `Briefs.fulfill` keeps the status check and applies the verdict. The jury reads hearings through `IBriefsCourt.BriefView` (mirrors `Briefs.Brief`; tested). Requests name the jury as consumer and callback. One jury per Briefs: `bind` from the Briefs constructor, guarded against a bind in between the deploy transactions (since the second review: the jury's immutable `expectedCourt`, set in its constructor). A setup's requester must answer `answerSource()` when proposed.
- **IMD's Intake.** `ImdGatewayRequester` pays IMD's Intake on Robinhood Chain and names the jury as the callback. `onImdAnswer` is open to anyone but only records `delivered[caller][requestId]`; `verdict` reads the slot of the setup's own Intake. An independent review after the split found no way to land another answer or move funds (PoCs: front-run bind, reverting answerSource, gas sweep on fulfill, BriefView layout); its Low findings are fixed above.
- **Answer shopping: fixed by the callback (was Medium).** Only the answer the Intake delivered for our own request lands. *Tests: `test_AnAnswerBoughtElsewhereIsRefused`, `test_OnlyTheIntakesDeliveryCounts`.* Setups without an on-chain source (the testnet mock) still match by questionHash only.
- **Callback format: confirmed from the Intake's deployed bytecode.** `complete` calls the target with `abi.encodePacked(selector, args)` and `callbackGas`, only when `status == 0` and the target has code. `args` starting with the Intake's request id is IMD's writer's convention (seen in the first live delivery); if it ever differs, no answer is bound and hearings end in mistrials (the keeper logs it).


## Second review: deep audit before mainnet (October 2026)

Three independent reviews again (funds; oracle integrity; liveness and admin), then a fourth that re-checked the fixes without having written them. No Critical. Every fix has a test; suite: 119 Foundry tests, all passing, including the exact solvency invariant (now also counting the fee of the brief being heard).

| # | Severity | Issue | Fix |
|---|---|---|---|
| 1 | High / Medium | Text limits counted code points, but IMD may count UTF-16 units or bytes. Emoji or math-letter texts could push every question past IMD's 2,000 limit: each hearing refused, a mistrial, and the leader kept the lead while challengers' fees fed the pot | The task, the standard and briefs are capped in UTF-8 bytes (240, 160, `maxBrief` ≤ 600), which no way of counting exceeds. The longest possible question is 1,864 bytes (`test_Fixed_H_TheLongestQuestionFitsIMDsLimit`). Titles still count characters |
| 2 | Medium | A mistrial still split the fee, so a failing jury fed the leader's pot | The split moved from the hearing's opening to the verdict. A mistrial hands the author the fee back less the jury's price (`MistrialRefund`); the pot, creator and platform get nothing |
| 3 | Medium | A brief whose hearing kept failing to open held the whole docket until `endsAt + 3 days` | `Case.stalledSince` starts at the first failure; `skipStalled` is allowed `STALL_WAIT` (6 h) later (whole fee back), and the next brief gets its own clock. The old rule after the deadline stays |
| 4 | Low | `fileBrief` asked the oracle for its price live: a reverting or overpriced requester froze all entries | Each case fixes its jury reserve at creation (`maxOracleFee` then, always below the fee). Filing never calls the oracle; a hearing that would cost more than the reserve skips the brief with its whole fee back |
| 5 | Low | The jury could be bound by someone else between the two deploy transactions if `expectCourt` was not called | `expectedCourt` is an immutable constructor argument; the deploy script and the probe aim it at the next nonce |
| 6 | Low | A setup could pair an on-chain answer source with a pinned domain (never verifiable); a proposal nobody applied stayed applicable forever | `_check` refuses that pair; a proposal lapses 7 days after it is ready |
| 7 | Low | After the deferred split, a losing author (or the leader) could race the keeper with a mistrial once the 2-minute grace passed, even though IMD had already delivered the answer | Once the Intake has delivered an answer (`BriefsJury.wasDelivered`), a mistrial waits `DELIVERED_GRACE` (1 h) instead |
| 8 | Low | A price skip left the stall clock running, so a later brief could be skipped on its first failure | `_skip` resets `stalledSince` |
| 9 | Info | `ImdGatewayRequester.sweep(to)` could send stray IMD anywhere | `sweep()` sends to the platform treasury of its Briefs |
| 10 | Info | More invisible characters (U+180B–180F, FFF9–FFFB, 1D173–1D17A) and «» look-alikes (❮❯ ⟨⟩ 〈〉 ︽︾); runs of whitespace a server might tidy (a different questionHash) | Rejected by `BriefsText`; the site strips or converts them, and collapses whitespace runs |
| 11 | Info | Wallet and keeper gas estimates can follow a cheaper path (the oracle failing at estimate time) | The site and the keeper send calls that may open a hearing with at least 4M gas |

Still accepted: the late-answer race when IMD has not delivered on chain yet, an owner-set `caseFee` without delay, the holder check at filing only, and a broken holder token only stopping entries to its own cases.

## Third review: the IMD swarm audit (October 2026)

An external review by the IMD oracle swarm (`template: audit`, [job 21511e3a](https://explorer.imd.fun/jobs/21511e3a-2ed8-4813-b82c-70dcb61af7d4)) of commit `8f71463` of the public contracts repo: 1 Medium, 4 Low, 6 Info, no Critical or High. None lets an outsider take funds; most are owner mistakes or defence in depth. Everything below was fixed before relaunching on mainnet, each with a test (`test_Swarm*` in `test/Briefs.t.sol`, plus the invariant handler). Suite: 128 Foundry tests, all passing. A fresh reviewer then re-checked the fixes (and mutated them to confirm each test fails without its fix); its four small follow-ups are folded into the rows below.

| # | Severity | Issue | Fix |
|---|---|---|---|
| 1 | Medium | A rewards sink with no code (an EOA, a typo) made `withdrawPlatform` and `applySink` revert forever: Solidity's code-size check before the call ran outside the `try` | `proposeSink` refuses a sink without code, and `_withdrawPlatform` treats a sink that has lost its code as broken (all of the share goes to the treasury) |
| 2 | Low | A requester whose `fee()` returned fewer than 32 bytes made the ABI decode revert outside the `try`, freezing every case on that setup; `wasDelivered` called `answerSource()` unguarded | Both are low-level `staticcall`s now (gas-capped); a short or failed reply counts as a failed quote (the case stalls and can be skipped) or as nothing delivered |
| 3 | Low | The treasury could be set to `Briefs` itself (or its jury or requester), stranding every case fee and the platform share | The constructor and `setTreasury` refuse `Briefs`, its jury and the current setup's requester |
| 4 | Low | A case bound to `jury.latest()` at execution, and `useLatestOracle` could move a case before its first entry, so a creator or first entrant could be heard under a setup they never saw | `CaseInput.oracleId`: `openCase` reverts `WrongOracle` unless it names the live setup. `useLatestOracle` is gone: a case keeps its setup for life |
| 5 | Low | More look-alikes of «» passed `BriefsText` (❰❱ ❬❭ ⧼⧽ ⋘⋙ ﹤﹥ ＜＞ ˂˃), and so did ASCII `<<` `>>` | Rejected on chain, as is a pair of `<` or `>` with only combining marks or thin, wide or no-break spaces between them. The site turns them into quotes or plain `<` `>` and refuses what is left before paying |
| 6 | Info | `skipStalled` reverted after `_hearNext` had already handed back up to 16 briefs priced out of the reserve, discarding that progress | It keeps the progress (and settles if it can) instead of reverting |
| 7 | Info | A brief filed while the jury's price was above the case's reserve was taken, then skipped and refunded in the same transaction | When nothing is being heard and the new brief is within the 16 skips that same call would make (every brief of a case reserves the same amount), `fileBrief` reverts `OracleTooExpensive`; briefs already queued keep the skip-and-refund path |
| 8 | Info | Brief text is public before it is sequenced, so whoever is sequenced first with the same words owns them | Accepted: Robinhood Chain has no public mempool; commit-reveal would cost every player a second transaction |
| 9 | Info | Comments said `setParams` reaches new hearings; panel, quorum and answer window are fixed per case | Comments fixed (the safer behaviour stays) |
| 10 | Info | A setup the jury owner proposes decides verdicts of cases opened after it applies; one EOA owned everything | Trust assumption, documented. Setups need 7 days in public, a case names its setup (fix 4), and ownership of all three contracts goes to a multisig |
| 11 | Info | The solvency invariant never drove the owner paths | The handler now also owns `Briefs`: `setParams`, `setTreasury` (including the refused addresses), rewards sinks (honest, greedy, re-entering, losing their code) and holders-only cases. Balance still equals liabilities to the wei, and a new invariant checks that the platform share can always be withdrawn |

Still accepted after this review: commit-reveal (finding 8); `_checkTreasury` checks the requester of the setup that is live when the treasury is set, not of setups applied later (an owner mistake either way, visible for 7 days); the site reads the live setup with `jury.latest()` right before `openCase`, so a setup applied in between only costs the creator a reverted transaction.

## Fourth review: the IMD swarm re-audit (October 2026)

The IMD swarm audited the fixed code ([job 8e03ebfb](https://explorer.imd.fun/jobs/8e03ebfb-e610-4f68-8fe5-71ab8251a8d2), commit `54a47f7`): 1 Medium, 4 Low, 3 Info. All addressed below; a fresh reviewer then re-checked the fixes and its follow-ups are folded in. Suite: 135 Foundry tests, all passing.

| # | Severity | Issue | Fix |
|---|---|---|---|
| 1 | Medium | The IMD token on Robinhood Chain is a LayerZero OFT with an owner block list (`blocked(address)`), so our accepted "push payments" premise was wrong: one blocked leader, challenger or queued author made the pot payout, the mistrial refund or the skip refund revert, freezing the case and its pot | `_pay` tries the transfer and, if the token refuses, keeps the amount in `unpaid[payee]` (`PaymentHeld`); the payee pulls it with `claimUnpaid()` once the token lets them (to themselves only). Verdicts, mistrials, skips and settlement never depend on a payee. The solvency invariant counts `unpaidTotal`, and its handler now blocks and unblocks actors, claims held payments and raises reserves. *Tests: `test_Fixed_Blocked*` in `test/audit/Liveness.t.sol`* |
| 2 | Low | If IMD prices a hearing above a running case's reserve, the case refuses every entry until its deadline and the leader wins by default | `raiseReserve(caseId)`: once the owner raises `maxOracleFee`, anyone (the keeper does it) lifts a running case's reserve to it, never down and always below the case's fee. Each hearing still pays IMD's actual price. The keeper raises a case only when IMD's price is past its reserve and entries are open. Accepted: time lost while entries were refused is not given back, and a case whose fee is at or below the new `maxOracleFee` can't be raised |
| 3 | Low | An answer IMD delivered on chain could be voided by a mistrial if nobody relayed it within an hour | `DELIVERED_GRACE` is 6 hours (IMD's answers stay valid 24 h; anyone can relay); the keeper relays within seconds. Only an answer that passes the cheap checks on arrival (`BriefsJury.landable`: a true/false answer from the ordered panel, issued within the window) earns the long grace, so a delivery that could never land doesn't hold the docket |
| 4 | Low | `BriefsText.check` paid the whole forbidden list for every character: a 500-byte ASCII filing needed about 5.6M gas, above the 4M the site and keeper sent | ASCII takes a short path and other characters are looked up by range (600 ASCII bytes: about 0.2M gas, was 2.2M); the site and the keeper now send 7M for calls that may open a hearing (see the fifth review). *Test: `test_Reaudit_R4_*`* |
| 5 | Low | No tolerance for clock skew between IMD's signer and the sequencer: an answer stamped one second before its hearing could never land | `CLOCK_SKEW` of 2 minutes on the lower bound for setups with an on-chain answer source (the answer must still be the one the Intake delivered for this hearing, with its question); without one the bound stays strict |
| 6 | Info | More invisible format characters (U+206A–206F, U+1BCA0–1BCA3, U+FFF0–FFF8, the rest of the tag plane), «» look-alikes (⫷⫸ ⦑⦒ ⦕⦖ ︿﹀ ᐸᐳ), noncharacters and private use passed the text rules | Rejected on chain; the site drops or converts them first. The site's list was checked against the contract's over every code point |
| 7 | Info | An Intake that keeps charging but stops answering burns each challenger's jury price in a mistrial; a running case can't change its jury | Accepted (trust in IMD; a case's jury is fixed by design). Telegram alerts now warn when the last 3 hearings court-wide all ended in a JURY SPLIT |
| 8 | Info | Live ownership was a single EOA | The redeploy hands Briefs, BriefsJury and the adapter to a multisig (`NEW_OWNER`) |

## Fifth review: our own full audit before the redeploy (October 2026)

Run the way the IMD swarm runs: five independent auditors (funds and accounting; the oracle path; liveness and gas;
admin and economics; text rules and JSON), each with a Foundry PoC for every finding, then every finding reproduced
and judged. No Critical, High or Medium. The funds auditor's stronger invariant (a token with a block list and a
global switch, requesters that re-enter, overcharge, hand IMD back or burn gas, every sink behaviour, fuzzed gas on
every paying call, and per-player books rebuilt from brief statuses) held over 200,000 calls. Suite: 139 Foundry tests.

| # | Severity | Issue | Fix |
|---|---|---|---|
| 1 | Low | `raiseReserve` did not reach briefs already queued: each kept the reserve copied at filing, so after a raise they were still handed back unheard | First changed to compare with the case's reserve; reverted after the sixth review (a queued author must never pay more than they reserved when filing). A raise now applies to briefs filed after it |
| 2 | Low | `skipStalled` could skip the next brief at its very first failure when the head was handed back for its price in the same call | Gone with fix 1 (one quote per call, one reserve per case); a guard also returns before skipping when the head moved in that call before `endsAt + STALL_GRACE` |
| 3 | Info | A setup could give a hearing up to 10M gas, more than the gas the site and keeper send leaves room for | `hearingGas` is capped at 4M; the site and the keeper send 7M (the longest filing needs about 4.9M, plus the L1 data cost on Robinhood Chain). *Test: `test_Own_HearingGasIsCappedForTheGasTheSiteSends`* |
| 4 | Info | `landable` didn't check the signature or `expiresAt`, so a delivered answer that could never land still held the docket 6 h | `_landable` also requires `expiresAt` to outlast the 6 h grace and checks the attester's signature (about 10k gas; the whole callback stays under 110k of the Intake's 200k). The questionHash is not rebuilt there (about 157k gas); IMD hashes the text we send, matched live and against a JS canonical serializer. *Tests: `test_OnlyALandableDeliveryHoldsTheMistrial`, `test_TheCallbackFitsTheIntakesGas`* |
| 5 | Info | The site checked minimum lengths in bytes, the contract in characters ("Шутка?" passed the site, then failed on chain) | The site counts minimums in characters too |
| 6 | Info | Text that NFC normalization changes was accepted; a server that normalizes would hash a different question | The site sends NFC (normalized before and after its clean-up) and refuses lone surrogates |
| 7 | Low | A treasury on IMD's block list stops new cases and the platform payout | Accepted: running cases are unaffected and `setTreasury` fixes it in one transaction |

## Sixth review: the third IMD swarm audit (October 2026)

[Job 715e3900](https://explorer.imd.fun/jobs/715e3900-cecb-406e-ba02-6e58d5806d98), commit `7944a9d`: 3 Low, 3 Info, no Medium or above. Suite: 142 Foundry tests; the five self-audit suites re-run green on the result.

| # | Severity | Issue | Fix |
|---|---|---|---|
| 1 | Low | After `skipStalled` handed the head back, the next brief's stall clock stayed at zero until someone called `hear()` | `skipStalled` starts the next brief's wait at once (the oracle was just seen failing). *Test: `test_Own_SkipStalledStartsTheNextBriefsWait`* |
| 2 | Low | `raiseReserve` let a brief already queued pay the jury more than the reserve it filed under (up to its whole fee) | A queued brief never pays more than it reserved; above that it is handed back with its whole fee. A raise applies to briefs filed after it. *Test: `test_Own_ARaiseNeverChargesAQueuedBriefMoreThanItReserved`* |
| 3 | Low | Script-specific combining marks (Cyrillic titlo, Arabic fathatan, Devanagari virama, kana voiced mark, musical marks…) between two `<` or `>` passed the `<<`/`>>` rule | Only an ASCII character separates two `<` or `>`: anything non-ASCII between them is refused (the site does the same). *Test: `test_Own_NoMarkOfAnyScriptBetweenAngleBrackets`* |
| 4 | Info | The treasury could be the IMD token or the text contract | Refused too. *Test: `test_Own_TreasuryCannotBeTheTokenOrTheText`* |
| 5 | Info | A text made only of combining marks passes the minimum length | Accepted: no funds or JSON impact; the author pays for a brief the jury sees as empty |
| 6 | Info | An unused local in `_hearNext` | Used again by fix 2 |


## Seventh review: v2 (time in the lead, overtime, pay with IMD on Ethereum), October 2026

Scope: everything v2 changed since the audited mainnet code (`2f28e22`): time in the lead, overtime and its limit,
the owner and creator modes, `fileBriefFor` and the relay messages in BriefsJury, the backend relayer
(`server/src/relay.mjs`), the keeper, index and API changes, and the site's flows. Run as five independent audits
(money and economics; signatures and relayed filing; liveness and gas; the relayer and keeper; the site), each with
a PoC for every finding, then a sixth pass that re-checked every fix and found three more relayer issues, also fixed.
Suite after the fixes: 155 Foundry tests (including a 512-run fuzz of the time-in-the-lead books and the funds
invariant with relayed filings and refunds), 76 server tests (11 for the relayer on two chains), 46 site tests.

| # | Severity | Issue | Fix |
|---|---|---|---|
| 1 | Medium | Unlimited overtime let the final leader stretch a case and dilute what earlier leaders had earned for their time in the lead (a 24 h case: one honest leader's share fell from 57k to 29k IMD of a 100k pot, for about 1.4 IMD per extension) | Time in the lead and the pool's denominator stop at the case's first deadline (`Case.reignEnd`): overtime decides the final leader but earns nobody time. *Tests: `test_Reign_OvertimeEarnsNoTimeAndDilutesNobody`, `test_Reign_ALeadTakenInOvertimeEarnsNoTime`, `testFuzz_Reign_TheBooksAlwaysBalance`* |
| 2 | Medium | Relayer: a refund could be paid again (a receipt missed by a lagging RPC; a database restored from a copy taken before the refund), or matched to another refund of the same amount | Refunds go through the jury (`refundRelay`): it pays the author and adds to an on-chain `refunded` record in one step, and the relayer only pays what that record says is still owed. *Tests: relay "refunds follow the chain's record", `test_Relay_ARefundedSignatureCanNeverBeFiled`* |
| 3 | Medium | Relayer: a payment wasn't tied to a brief, so after a lost database an old payment (or any transfer to the pay-to address) could buy another brief or refund; one signature with two payments filed once and kept the second | The payment's calldata ends with the signed message's hash and must come from the author; jobs are unique by message; the jury's record (filed or refunded) is checked before anything is queued. *Test: relay "a payment counts only for the message it names"* |
| 4 | Medium | Relayer: a filing and a refund for the same payment were both possible (a receipt lost while the filing was pending, or someone filing the signed brief first) | Before any refund the jury's record is read: a filed message is never refunded. Our transactions are signed and saved before they are sent and replaced with the same nonce. *Tests: relay "someone else files the signed brief first", "a filing that doesn't get mined is replaced"* |
| 5 | Medium | A paid player could end up with no job: a sped-up payment (new hash), a closed tab, a late POST past the signature's deadline, or the wallet erroring after sending | A payment is found again by its message hash; the site keeps the signed brief before paying and hands it over until the relayer has it; a late deadline is accepted (the job then refunds); every payment to the pay-to address is listed and one with no job is alerted. *Tests: relay "a sped-up payment … still files", "a payment to the relay that never became a brief is listed"* |
| 6 | Medium | Site: once paid, an error re-enabled the button and invited a second payment | After paying, the site never asks for another payment while one for that case is pending; it shows the payment's status on the case page instead |
| 7 | Medium | Site: payout texts still said the winner takes 100% (claim button, cards, gate, docs), overtime wasn't explained when the share is 0, and the Ethereum section sat in the demo docs | Texts follow the case's numbers (the claim button shows the pot less the shares for time in the lead); overtime shows on its own; the section moved to the live wallet docs |
| 8 | Low | `overtime` wasn't pinned at `openCase` like the share and the limit | `CaseInput.overtime` must equal the current setting (`SettingsChanged`). *Test: `test_Settings_OvertimeIsWhatTheCreatorSaw`* |
| 9 | Low | A relay signature stayed usable after a failed relay, so anyone holding it could file the brief later | A refund marks the message refunded, so it can never be filed |
| 10 | Low | Relayer: a job that kept failing was parked as failed with the player's money, including while the relayer was short of IMD | Each state counts its own tries; a filing that can't go through is refunded; filing and refunding wait (without counting) while the relayer is short, and the alert says so |
| 11 | Low | Relayer: few Ethereum confirmations, no chain check, unbounded fee bumps, words visible before filing, signatures with v = 0/1 refused on chain | 12 confirmations by default and a chain id check; at most 5 replacements; words hidden until filed; v normalized; signatures recovered locally (ECDSA only, as the contract) |
| 12 | Low | Keeper retried `claimReign` forever for a leader whose time came to 0 seconds | It reads `reignOf`/`reignClaimed` first and skips those |
| 13 | Low | Site: the shown settings could differ from the ones sent to `openCase`; a decimal comma fell back to the default share | The settings the creator saw are sent; a comma is read as a decimal point; `SettingsChanged` has a friendly message |
| 14 | Low | Leaders were dated by when a COOKED was delivered, not when the jury answered (a slow relay gives the sitting leader a few extra seconds) | Accepted: the keeper delivers within seconds, and the time now stops at the first deadline |
| 15 | Info | Overtime is still unlimited by default (the owner's choice): someone who keeps winning in the last minutes can delay settlement, paying a fee each time, but no longer gains time in the lead | `finalCap` (owner or creator) bounds it when wanted |
| 16 | Info | Smart-contract wallets can't pay on Ethereum (personal_sign recovery is ECDSA only) | The site refuses them before signing; they can still file with IMD on Robinhood Chain |
| 17 | Info | `check-mainnet.mjs` left held payments out of what Briefs owes; a resumed deploy could reuse an older BriefsText | `unpaidTotal` is counted; the deploy replaces a BriefsText without `checkCase` |

Checked and fine, with tests: seconds add up to the total in every path (COOKED before and after the deadline,
mistrials and skips between, two COOKED in the same second, leading twice, settlement in the same transaction as the
last verdict); claims never exceed the pool and the contract holds exactly what it owes (fuzzed); no division by
zero or overflow; `SettingsChanged` in both modes; replay across chains, courts and juries; signature malleability;
the message can't be read two ways; holders-only checked on the author; `checkCase` limits equal the old ones
(differential fuzz); no stall can be faked on the new paths (gas swept around the threshold); worst cases measured
at about 5.35M for `fileBriefFor` and 6.47M for a skip-heavy `fulfill` at a 4M `hearingGas`, under the 7M the site
and keeper send. Briefs is 24,323 bytes, 253 under the limit; new code should go into BriefsJury or BriefsText.

### Added after the seventh review (not yet reviewed)

- **A case's brief language and limit.** `CaseInput.lang` (0 any, 1 English; `Briefs.langOf`) and `CaseInput.maxBrief`
  (0: the court's `maxBrief`; otherwise 20 up to it, and only with a language). English means plain ASCII, so a byte is a
  character and the limit is fair whatever the script. `BriefsText.checkCase` validates the language and the limit and
  returns the case's limit; `BriefsText.checkBrief` applies them to every brief, the opening one and relayed ones
  included (`NotEnglish`). The question tells the jury ("Answers must be written in English.") for an English case
  only; a case open to any language asks exactly the question v1 asked, so its questionHash is unchanged.
- To keep Briefs under 24 KB: `reignClaimed` is gone (`claimReign` sets `reignOf` to 0 once paid; `ReignPaid` keeps the
  seconds), and the optimizer runs 100 times instead of 200 (a little more gas per call, well under the 7M floor).
- Tests: `test_Lang_*` (4), and the e2e "an English case" on anvil (the jury's signed answer for the English question
  lands).

## Eighth review: English-only cases and a fresh full review of v2 (October 2026)

Three independent reviewers: one on the language change, one on all of v2 from scratch (contracts), one on the
server and site (relayer, keeper, views, the create and case pages). Everything below is fixed unless it says
otherwise; each contract fix has a test.

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | Medium | A leader could hold the lead longer by stuffing the queue: time was credited from the verdict, so its own briefs filed ahead of a challenger (or a slow hearing) kept the clock running for it | Time counts from when a brief was **filed** (`_newLeader(caseId, c, filedAt)`: from the later of the filing and the previous lead's start) until the next leader's filing, capped at the first deadline. A brief filed before the deadline and heard after it earns its time up to the deadline; one filed in overtime earns none. `test_Reign_StuffingTheQueueBuysTheLeaderNothing`, `test_Reign_ALeaderHeardAfterTheDeadline…` |
| 2 | Medium | Relayer: under a lagging RPC node, a landed refund could still read as owed and be paid a second time | Our own landed refunds are added up from their receipts (`refund_seen`, a floor); the chain's `refunded` is read at the receipt's block (or the block where the nonce was seen used) as well as at the latest one, and the most of all counts |
| 3 | Medium | Relayer: payments were recognised only as an exact 100-byte call to the token, so a smart account's batch (EIP-7702) or a wallet appending data was not found | A payment is a transaction from the signer whose calldata contains `transfer(payTo, amount)` immediately followed by the message hash, anywhere; what it paid comes from the token's `Transfer` logs. One transaction pays for one brief (a second job naming it fails) |
| 4 | Medium | `testnet-up.mjs` decided "older contracts" by `holderToken()`, which v1 has too, so a v1 testnet would not be redeployed for v2 | It probes `langOf`, which only v2 has |
| 5 | Low | `refundRelay` with amount 0 marked a message refunded for free, so anyone holding a signature could cancel the brief | `NothingToRefund` unless the refund pays more than 0 |
| 6 | Low | `caseFee` and the fee split were not pinned: an owner change landing before a pending `openCase` charged the new price (known as F-5 since v1) | `CaseInput` carries `caseFee`, `creatorBps` and `platformBps`; they must equal the settings (`SettingsChanged`). The site sends what it showed and names the change. `test_Fixed_F5_*` |
| 7 | Low | `CaseInput.lang` above the known languages reverted `NotEnglish` | `UnknownLanguage` |
| 8 | Low | Site: the brief limit field took values like `1e2`; counters counted the typed text, not the text sent after the English substitutes; a relaunch dropped the language and limit; the opening brief of an English case was checked only at sending | The limit is a whole number (text field, digits only); counters count the converted text; a relaunch copies the language and limit; `validateCase` checks the converted opening brief and the limit |
| 9 | Low | `/api/relay/message` trusted the player's clock for the signature's deadline | The server sets it (two hours ahead) and returns it; a named one is still accepted within a day |
| 10 | Low | Two multi-sentence notes on the create page lacked their final period; a case's limit was printed unescaped | Fixed |
| 11 | Info | The English check is on the script (ASCII), not the language: a brief in another Latin-script language passes, and the case's own title, task and standard may be in any language | Documented. The jury is told answers must be in English |
| 12 | Info | `MIN_BRIEF` was unused; `verify/standard-input.json` is v1's (200 runs) | Removed; the verify README says it must be rebuilt before v2 is deployed |
| 13 | Info | Shares for time in the lead leave a few wei of rounding in the pool | Accepted (bounded by the number of leaders, tested) |
| 14 | Info | The keeper picked leaders to pay by verdict time; the dev banner ignored `PORT` | It picks by filing time before the first deadline (the contract's rule); the banner uses `PORT` |

The site and API mirror the new rule (`views.reignOf`, unit-tested against the same cases as the contract).
Briefs is 24,400 bytes, 176 under the limit.
