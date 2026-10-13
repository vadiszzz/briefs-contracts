# briefs.fun contracts

The on-chain court behind [briefs.fun](https://briefs.fun) on Robinhood Chain (chain id 4663). Players pay IMD to file short answers ("briefs") to a task; each brief is judged against the current leader by the IdentityMD (IMD) oracle swarm.

This branch is **v2, under review and not deployed**: part of the pot pays every leader for their time in the lead, overtime keeps a hot case open, a case can take English briefs only with its own shorter limit, and a relayer can file a brief its author signed and paid for elsewhere (IMD on Ethereum). The contracts live today are v1, tagged `v1-mainnet`.

## Deployed: v1 (Robinhood Chain, 9 Oct 2026, from block 83945523)

| Contract | Address |
|---|---|
| `Briefs` | `0x61bdfe5d291a98afda244b537c8f74e32a9beba3` |
| `BriefsJury` | `0xf75a871ea1cc09e55ff87e9c468b436a56bb93f2` |
| `BriefsText` | `0x15f61d8842847bebcda6999f9a9ec8072372a441` |
| `ImdGatewayRequester` | `0xaf3a708404b8e331d69162c0c41c3694a764e416` |
| IMD's Intake (IMD's contract) | `0x1397434cd35e8a9c8ac312a61d3a285eb31dea56` |
| IMD token | `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127` |

## Contracts

| Contract | Role |
|---|---|
| `Briefs` | Cases, the docket, hearings, escrow, the fee split, pots, time in the lead, payouts and settings. Holds every IMD. |
| `BriefsJury` | Everything said to and heard from IMD: oracle setups (append-only, 7-day delay), the request JSON and question, the Intake callback (`onImdAnswer`) and `verdict`. Also the relayed briefs: the message an author signs (`relayMessage`), its one-time use (`useRelay`, called by Briefs) and refunds (`refundRelay`). Holds no funds. |
| `BriefsText` | Text rules (a case's title, task and standard limits, its language and brief limit: `checkCase`, `checkBrief`) and the exact question and request JSON (an English case's question says so). Stateless. |
| `ImdGatewayRequester` | Pays IMD's Intake for each hearing and names `BriefsJury.onImdAnswer` as the callback. `Briefs` is its only client. |
| `ImdOracle` | EIP-712 digest of IMD's v2 attestations. |

## A case

1. **Open** (`openCase`): the jury setup it expects (`oracleId`, must be `jury.latest()`), a title, a task, a standard (how two answers are compared), an opening brief (the first leader), a seed pot in IMD, a fixed entry fee, a deadline, the language briefs must be in (any, or English only: plain ASCII, so a character is a byte; the check is on the script, not the language, and the case's own texts may be in any language) with, for a language only, a shorter brief limit (20 characters and up), and the settings the creator saw: the opening fee, the fee split, the jury and limits the case fixes for life (`terms`: panel, quorum, answer window, the court's brief limit, the jury reserve), the time-in-the-lead share, the overtime limit and overtime (they must equal the current settings unless the owner lets creators pick the share or the limit; `SettingsChanged` otherwise, so a change by the owner never charges a creator more than they agreed to). Opening costs a flat `caseFee` paid to the treasury, separate from the seed.
2. **File** (`fileBrief`): pay the fee and join a public FIFO docket. The fee waits in escrow. Or **file for someone** (`fileBriefFor`): the author signed the brief (`personal_sign` of `relayMessage`: the case, the author, the words and a deadline, valid once) and the caller pays the fee; the brief is the author's in every way.
3. **Hearings**, one at a time, in docket order: each asks IMD whether the brief is better than the leader standing at that moment, judged by the standard (a tie or a reworded copy keeps the leader). The request names `BriefsJury` as its EIP-712 consumer and as the Intake callback, so IMD signs the answer for that contract only.
4. **Verdicts** (`fulfill`, by anyone): the jury rebuilds the hearing's `questionHash` on chain, requires that IMD's Intake delivered exactly this attestation for the hearing's request, checks the answer window, the panel and the signature.
   - Better (COOKED): the brief becomes the leader. A new leader in the last `overtime` seconds before the deadline, or whose brief was filed in the last `overtime` seconds before the first deadline (or after it) however long the jury took, pushes the deadline to now + `overtime`, never past the case's `finalEnd` when it has a limit.
   - Not better: the leader stays.
   - No answer in time (`mistrial`, by anyone after a grace): the leader stays and the author gets the fee back less the jury's price.
5. **Settle**: entries close at the deadline, every on-time brief is still heard, then the pot is paid (`settle`, by anyone).

## Time in the lead

`reignBps` of the pot (scaled by the share of the case's life that had a challenger in the lead) is shared by how long each challenger held the lead, until the case's **first** deadline (`reignEnd`). A leader's time counts from when its brief was **filed**, not from its verdict, and ends when the next leader's brief was filed, so a slow hearing or a leader stuffing the queue with its own briefs moves nobody's time. Overtime decides the final leader but earns nobody time, so stretching a case can't dilute what earlier leaders earned. What briefs filed in overtime add to the pot (`overtimePot`) goes to the final leader alone. The time before the first winning brief is nobody's. The final leader takes the rest of the pot at settlement; each leader's share is paid by `claimReign(caseId, leader)` (anyone may call it, once per leader).

## Money

On a verdict, a brief's fee less the jury's price (IMD's flat price, capped per case by its reserve) splits 80% pot, 15% creator, 5% platform (settable within bounds for new cases). Creator earnings are claimed with `claimCreator`; the platform share is paid to the treasury by `withdrawPlatform`. A brief that is never heard gets its whole fee back. The pot never pays the jury. If the token refuses a payment (the IMD token on Robinhood Chain has a block list), Briefs keeps it for the payee (`unpaid`, `claimUnpaid`), so no payee can stop a case. The contract's IMD balance equals open pots + creator earnings + the platform share + escrowed fees + unpaid shares for time in the lead + held payments, to the wei (tested as an invariant and a fuzz).

**Relayed briefs.** A relayer that took an author's payment elsewhere files with `fileBriefFor`, or, when it can't, refunds with `BriefsJury.refundRelay`: the jury moves the IMD from the relayer to the author and records the amount on chain (the first refund of a message must pay at least the case's entry fee, so cancelling costs what filing would), and a refunded message can never be filed. Each signed message is filed or refunded, never both. The off-chain part (taking the payment on Ethereum) is trust-based and documented as such on the site.

## Owner

`setParams` (within hard bounds, new cases only: the split, durations, brief length, the time-in-the-lead share up to 90%, overtime up to 1 h, the overtime limit up to 365 days, and whether creators pick the share and the limit), `setPaused` (new cases only; entries, hearings, payouts and claims never pause), `setTreasury`, `setHolderToken`, oracle setups behind a 7-day delay (a running case keeps the setup it opened with). The owner can't touch pots, escrow, creator earnings or shares for time in the lead, or change a running case.

## Build and test

```sh
forge build
forge test          # 168 tests, including PoCs and regressions in test/audit, a solvency invariant and a fuzz of the time-in-the-lead books
```

Foundry with solc 0.8.30 (optimizer, 20 runs, to keep Briefs under 24 KB). `lib/` holds OpenZeppelin Contracts v5.4.0 and forge-std.

## Reviews

`docs/audit-internal-2026-10.md`: our own two reviews of v1 (every finding with a Foundry PoC in `test/audit/`), three IMD swarm audits of v1 ([first](https://explorer.imd.fun/jobs/21511e3a-2ed8-4813-b82c-70dcb61af7d4), [re-audit](https://explorer.imd.fun/jobs/8e03ebfb-e610-4f68-8fe5-71ab8251a8d2), [third](https://explorer.imd.fun/jobs/715e3900-cecb-406e-ba02-6e58d5806d98); all addressed) and our own five-auditor review before the redeploy, then the **seventh review**: v2 (time in the lead, overtime, relayed filing), five independent audits plus a re-check of the fixes, the **eighth**: English-only cases and a fresh full review of v2, the **ninth** on what came after, the **fourth IMD swarm audit**, of v2 ([job](https://explorer.imd.fun/jobs/0b0d0d84-c7e0-4dd4-b87e-d94e2e5150d9)), and the **fifth**, of its fixes ([job](https://explorer.imd.fun/jobs/a5960b3e-4ac1-4e65-8fc2-087178af730a)), all findings fixed or written down.
