# briefs.fun contracts

The on-chain court behind [briefs.fun](https://briefs.fun), live on Robinhood Chain (chain id 4663). Players pay IMD to file short answers ("briefs") to a task; each brief is judged against the current leader by the IdentityMD (IMD) oracle swarm; the last leader standing takes the whole pot.

## Deployed (Robinhood Chain, 8 Oct 2026, from block 83504137)

| Contract | Address |
|---|---|
| `Briefs` | `0x85737d04bde718f42f90e31564540408cbbe6e4b` |
| `BriefsJury` | `0x265c541aa5c5f202e1e3024570cb7d8b278ca691` |
| `BriefsText` | `0x244b19349e5bb32338960353bb6c3a05f4157fa4` |
| `ImdGatewayRequester` | `0xbaee00b30d6f585218e257d84c70cf4181229592` |
| IMD's Intake (IMD's contract) | `0x1397434cd35e8a9c8ac312a61d3a285eb31dea56` |
| IMD token | `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127` |

## Contracts

| Contract | Role |
|---|---|
| `Briefs` | Cases, the docket, hearings, escrow, the fee split, pots, payouts and settings. Holds every IMD. |
| `BriefsJury` | Everything said to and heard from IMD: oracle setups (append-only, 7-day delay), the request JSON and question, the Intake callback (`onImdAnswer`) and `verdict`, which checks an answer against its hearing. Holds no funds. |
| `BriefsText` | Text rules and the exact question and request JSON. Stateless. |
| `ImdGatewayRequester` | Pays IMD's Intake for each hearing and names `BriefsJury.onImdAnswer` as the callback. `Briefs` is its only client. |
| `ImdOracle` | EIP-712 digest of IMD's v2 attestations. |

## A case

1. **Open** (`openCase`): a title, a task, a standard (how two answers are compared), an opening brief (the first leader), a seed pot in IMD, a fixed entry fee and a deadline. Opening costs a flat `caseFee` paid to the treasury, separate from the seed.
2. **File** (`fileBrief`): pay the fee and join a public FIFO docket. The fee waits in escrow.
3. **Hearings**, one at a time, in docket order: each asks IMD whether the brief is better than the leader standing at that moment, judged by the standard (a tie or a reworded copy keeps the leader). The request names `BriefsJury` as its EIP-712 consumer and as the Intake callback, so IMD signs the answer for that contract only.
4. **Verdicts** (`fulfill`, by anyone): the jury rebuilds the hearing's `questionHash` on chain, requires that IMD's Intake delivered exactly this attestation for the hearing's request, checks the answer window, the panel and the signature.
   - Better: the brief becomes the leader. Not better: the leader stays.
   - No answer in time (`mistrial`, by anyone after a grace): the leader stays and the author gets the fee back less the jury's price.
5. **Settle**: entries close at the deadline, every on-time brief is still heard, then the last leader gets 100% of the pot (`settle`, by anyone; the pot always goes to the leader).

## Money

On a verdict, a brief's fee less the jury's price (IMD's flat price, capped per case by its reserve) splits 80% pot, 15% creator, 5% platform (settable within bounds for new cases). Creator earnings are claimed with `claimCreator`; the platform share is paid to the treasury by `withdrawPlatform`. A brief that is never heard (the jury got dearer than the case's reserve, or its hearing kept failing) gets its whole fee back. The pot never pays the jury. The contract's IMD balance equals open pots + creator earnings + the platform share + escrowed fees, to the wei (tested as an invariant).

## Owner

`setParams` (within hard bounds, new cases only), `setPaused` (new cases only; entries, hearings, payouts and claims never pause), `setTreasury`, `setHolderToken`, oracle setups behind a 7-day delay, a rewards sink for at most half of the platform share behind a 2-day delay. The owner can't touch pots, escrow or creator earnings, or change a running case.

## Build and test

```sh
forge build
forge test          # 119 tests, including PoCs and regressions in test/audit and a solvency invariant
```

Foundry with solc 0.8.30 (optimizer, 200 runs). `lib/` holds OpenZeppelin Contracts v5.4.0 and forge-std.

## Reviews

`docs/audit-internal-2026-10.md`: our own reviews (two rounds, every finding with a Foundry PoC in `test/audit/`). Not an external audit.
