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
- **`caseFee` can change instantly (Low).** A malicious owner could raise it in front of a pending `openCase` if the creator's allowance covers it. Bounded by `setParams`; consider a delay or a `maxCaseFee` argument.
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
| 1 | Low | `raiseReserve` did not reach briefs already queued: each kept the reserve copied at filing, so after a raise they were still handed back unheard | `_hearNext` compares IMD's price with the case's reserve, which only goes up. *Test: `test_Own_ARaisedReserveReachesQueuedBriefs`* |
| 2 | Low | `skipStalled` could skip the next brief at its very first failure when the head was handed back for its price in the same call | Gone with fix 1 (one quote per call, one reserve per case); a guard also returns before skipping when the head moved in that call before `endsAt + STALL_GRACE` |
| 3 | Info | A setup could give a hearing up to 10M gas, more than the gas the site and keeper send leaves room for | `hearingGas` is capped at 4M; the site and the keeper send 7M (the longest filing needs about 4.9M, plus the L1 data cost on Robinhood Chain). *Test: `test_Own_HearingGasIsCappedForTheGasTheSiteSends`* |
| 4 | Info | `landable` didn't check the signature or `expiresAt`, so a delivered answer that could never land still held the docket 6 h | `_landable` also requires `expiresAt` to outlast the 6 h grace and checks the attester's signature (about 10k gas; the whole callback stays under 110k of the Intake's 200k). The questionHash is not rebuilt there (about 157k gas); IMD hashes the text we send, matched live and against a JS canonical serializer. *Tests: `test_OnlyALandableDeliveryHoldsTheMistrial`, `test_TheCallbackFitsTheIntakesGas`* |
| 5 | Info | The site checked minimum lengths in bytes, the contract in characters ("Шутка?" passed the site, then failed on chain) | The site counts minimums in characters too |
| 6 | Info | Text that NFC normalization changes was accepted; a server that normalizes would hash a different question | The site sends NFC (normalized before and after its clean-up) and refuses lone surrogates |
| 7 | Low | A treasury on IMD's block list stops new cases and the platform payout | Accepted: running cases are unaffected and `setTreasury` fixes it in one transaction |

