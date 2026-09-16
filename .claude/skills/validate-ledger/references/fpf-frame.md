# FPF frame for ledger validation

Read this after invoking the `fpf` skill and before writing any verdict.

## Why the framework earns its place here

Every check in this workflow produces a *carrier observation*, not a fact about a
deployed contract. Diffyscan says "the explorer's verified source for this
address equals this repo tree". A `publicRefs` hit says "this page names this
address". Neither says the address is right, current, or approved — and the
ledger's own README says so in its non-goals.

The failure mode this report exists to prevent is the one A.10 names directly:
carrier presence becoming truth, provenance becoming approval, and a green run
becoming assurance. So the report's job is not to stamp PASS/FAIL. It is to
publish, per claim, *what was relied on, for which bounded use, and what remains
unestablished*.

## Routing

| The live question | Pattern | What to read |
| --- | --- | --- |
| Governing pattern for every finding in the report | `A.10` | `:1`, `:4.1`–`:4.6`, `:6` (the Conformance Checklist; `:7` is Consequences) |
| Which distinctions must not collapse | `A.7` | `:1`, `CC-A7.3`, `CC-A7.6`, `CC-A7.13` |
| How per-entry findings compose into one snapshot verdict | `C.2` | `:4.1`, `:4.3`, `:4.4`, `:6` |
| First evidence-use classification only (a quick single entry) | `A.2.4` | `:1`, `:4` |
| Staleness of the snapshot or of a carrier | `A.10:4.6`, `G.11` | `A.10:4.6`; `G.11:0` |
| An assurance claim is being made or material reliance is at stake | `B.3` | `:1` — then stop and route, do not issue the result |
| The run's own budget, stop conditions and truncation | `C.24` | `:0.4`, `ATC-3`, checklist items 3 and 8 |

`A.10` is the governing pattern (`E.11`: one claim, one governing pattern). `A.7`
and `C.2` are used for their specific checks, not restated. Cite the `CC-*` items
you actually relied on, and do not invent FPF semantics the patterns do not
carry.

## The four bounded uses this report judges

A disposition is meaningless without a named use (`A.10:4.5` — `pass` supports
only the exact bounded use). Judge every entry against these, and name them in
the report so a reader knows what was and was not tested:

- **U1 — public cross-check.** Relying on this entry's `publicRefs` as a working
  cross-check: the publication the ledger points at, as fetched now, names this
  `address`.
- **U2 — source provenance.** Relying on `source.repositoryUrl` + `commit` +
  `path` as the revision the bytecode at that address was built from.
- **U3 — structural navigation.** Relying on `deploymentId`, `proxy.*` links, and
  `networks` metadata to resolve relationships inside the snapshot.
- **U4 — role fulfilment.** Relying on this entry's `address` as the deployment
  that actually fulfils its `contractId` on its `networkId`.

U3 is settled by the repo's own validators. U1 and U2 are what the network checks
address.

**U4 is `evidence-needed` for every entry, in every run this workflow produces.**
Nothing here tests it: a carrier naming an address establishes that the carrier
names it, and a source match establishes what the explorer's verified source
equals — neither reaches the question of whether this is the right contract for
this role. U4 exists in the table precisely because it is the use most readers
have in mind. Leaving it unnamed lets a `pass` on U1 or U2 be read as the answer
to it. State U4 once in the verdict table, with its one bound, and do not repeat
it per entry.

An earlier edition of this frame folded U4's wording into U1 and then assigned
`pass` on carrier presence. That is the `A.10:4.5` failure directly: `pass`
supports the exact bounded use and no wider one.

## Default outcome → disposition

Use the canonical `RelianceDisposition` member set from `A.10:4.5` verbatim —
`pass`, `degrade`, `abstain`, `reopen`, `evidence-needed`, `assurance-needed`,
`blocked-current-use`. Do not coin new names, and do not relabel these as
scores, grades, or gate decisions.

These are defaults, not a lookup table. Deviate when an entry's specifics warrant
it, and say why in the report — that sentence is the valuable part.

**U2, from `collect_diffyscan.py` outcomes:**

| Outcome | Disposition | Reasoning |
| --- | --- | --- |
| `source-match` | `pass` | Bounded: rests on the explorer's own source verification, and `--skip-binary-comparison` means no independent bytecode check ran. A record carrying `comparedBeforeCohortAborted` earns the same disposition on the same bound — its own comparison completed, and its cohort's later crash is evidence about a different address. Reading it as a fact about this one would establish a relation by shared cohort membership, which `A.10:6` item 7 (graph boundary) rejects. |
| `source-allowed-diff` | `degrade` | Reliance holds only within the allowlist rule's stated reason; name the rule. |
| `source-diff` | `reopen` | The pin and the explorer-verified source disagree; the provenance claim must be re-established, not merely flagged. |
| `source-missing-upstream` | `reopen` | The source host answered 404 for the pinned tree, so the pin itself is impeached. Check the failure clusters first: a 404 on one cohort is a pin problem, a 404 on every cohort of one repository is an auth problem wearing a 404. |
| `upstream-unavailable` | `evidence-needed` | The source host failed some other way — rate limit, auth, 5xx, network. Nothing was compared and the pin is **not** impeached. |
| `explorer-unavailable` | `evidence-needed` | Nothing was compared. This is the single most misread outcome — it is not a mismatch. |
| `not-reached` | `evidence-needed` | The cohort aborted before Diffyscan requested this address. Nothing about this entry was compared and its pin is **not** impeached; the crash is a fact about a sibling address. |
| `tool-error`, `not-run` | `evidence-needed` | The check did not complete. |
| `not-projected` | `evidence-needed` | A full source claim exists and no cohort could be built for it: a tooling gap. State the reason the collector gives. |
| `unpinned-source-claim` | `abstain` | A repository is recorded, no commit is. U2 as defined quantifies over a pinned revision, and this entry does not offer one — there is no claim of that shape to judge. Report it as a ledger completeness gap, not as a failed check. |
| `no-source-claim` | *not applicable* | The ledger records no source at all. Do not assign a U2 disposition: nothing was claimed, so nothing is unsupported. Count these separately and name the count — it is the sharpest completeness figure the sweep produces. |

**U1, from `check_public_refs.py` verdicts.** Read the carrier failure clusters
before any of these: if one cluster covers most carriers, the run learned nothing
and U1 is `abstain` for the whole snapshot.

| Verdict | Disposition | Reasoning |
| --- | --- | --- |
| `address-present` (any ref) | `pass` | Bounded to exactly U1: a public carrier, fetched at this timestamp, names this address. Role fulfilment is U4 and stays `evidence-needed`; currentness and approval are untested (`A.10:4.2`). |
| `address-present`, `occurrence: markup-only` | `degrade` | The address is in a link target but not in text a reader sees; the cross-check a human would perform does not actually work. |
| `address-absent` | `reopen` | The cited carrier does not support the citation it was cited for. Quote what the carrier names instead. |
| `carrier-unreachable` | `evidence-needed` | Distinguish this from absence explicitly. |
| no `publicRefs` recorded | `evidence-needed` | No cross-check is offered. Absence of a pointer is not evidence that no publication exists (`A.10:4.2`). |

`abstain` is available for an entry whose own fields are inconsistent enough that
judging U1/U2 would be guesswork; prefer it over a forced verdict.
`blocked-current-use` is for one named use you are actively withdrawing, not a
general grade.

## Composing one snapshot verdict

`C.2:4.3`: on a conjunctive path, reliability is the weakest link and formality
is the minimum. The snapshot's claim "these are the Lido multichain deployments,
with their sources" is conjunctive, so the headline verdict is bounded by its
weakest member, and the report must name the members that set the bound.

**Weakest-link composition assumes the members are independent.** They often are
not. An exhausted GitHub token, an expired explorer key or a dropped uplink is
one cause wearing N cohort failures, and composing it as N members produces a
verdict about the ledger from a fact about the machine. Both scripts publish
their failure clusters for exactly this judgement: `failureClusters` from the
collector, `carrierFailureClusters` from the refs check. Neither applies a
threshold, because a threshold here would be a hidden scalarization of a question
that has to be argued.

So, before composing: for each cluster, say whether it is one common-mode finding
or that many independent ones, and say what decided it. A cluster of two 404s on
one repository, while every other cohort reached the same host, is two findings
about two pins. A cluster covering forty cohorts across every repository is one
finding about the run, its disposition is `abstain` for the affected use, and the
right next action is to fix the cause and re-run rather than to publish forty
rows. Record the judgement in the report; it is the sentence a later reader will
need most and cannot recover from the JSON.

Do **not** report an average, a percentage-as-grade, or a composite score — that
is the "metric worship" bias `C.2:6` warns about, and it would hide exactly the
entries a reader needs. Percentages are fine as *coverage* facts ("133 of 175
entries reached `source-match`"); they are not a verdict.

If you want to state `[F, G, R]` explicitly, read `patterns/C.2.3.md` first for
the `F0…F9` ladder. Otherwise state the weakest-link reasoning in words and skip
the coordinates — an invented number is worse than none.

## Traps specific to this repository

1. **A crash is not a mismatch, and the status code is what says which.**
   Diffyscan raises one `ExplorerError` for a GitHub 404, a GitHub rate limit and
   an explorer refusal. Only the first says anything about the ledger. The
   collector reads the status and host out of the log and files them as
   `source-missing-upstream`, `upstream-unavailable` and `explorer-unavailable`
   respectively; carry that separation into the report, and quote the status when
   you write the finding. A report that turns a spent token into "the pin is
   impeached" has done the exact damage this workflow exists to prevent.
1. **A known blocker has to earn each failure it explains.**
   `references/known-blockers.json` records chains believed unsweepable — with an
   `asOf` date, and a `logSignature` that a cohort's own log must match before the
   blocker may absorb its failure. Entries carrying a null signature explain
   nothing by construction; they are hypotheses awaiting a log. Two outputs
   belong in the report: `unexplainedCohorts` (failures on a blocker's networks
   that it does not account for — findings, not gaps) and any blocker `not
   exercised by this run` (an untested claim, now that many days old). When a
   real log confirms a blocker, add its signature and `evidenceRef`; that is the
   only way a hint becomes evidence here, and until then the list must not be
   allowed to silence anything.
2. **Source match ≠ bytecode match.** `just diffyscan-sources` passes
   `--skip-binary-comparison`. The chain from source to deployed bytecode runs
   through the explorer's verification, so U2's `pass` inherits that dependency.
   Say so once, plainly, in the verdict section.
3. **`contractName` is not a documentation label.** The ledger records the
   Solidity contract name; docs pages use prose ("ProxyAdmin for X"). Do not
   treat a wording difference as a mismatch — that is why the checker captures
   `labelContext` instead of comparing names. Surface a snippet when it looks
   genuinely inconsistent and let a human judge.
4. **An unresolved `#fragment` is a navigation defect, not an address failure.**
   Report it separately from the address verdict.
5. **`knownGaps` already records some of what you will find.** Read it before
   writing warnings, and say when a finding is already acknowledged there —
   re-reporting an acknowledged gap as news wastes the reader's attention.

## Currentness and the assurance boundary

Record, per `A.10:4.6`: the ledger's `updatedAt`, its file hash, the git HEAD it
was read at, when each carrier was fetched, and when each Diffyscan log was
written. A finding is a claim about a moment.

Close the report with the `A.10:4.5` routing, not with reassurance: this report
is an evidence-provenance publication and carries no assurance result. If anyone
relies on these addresses for a consequential action — configuring a production
integration, moving value, granting a role — the `B.3` material-reliance
threshold is crossed, `assurance-needed` applies, and the decision routes to
`B.3` rather than to this document.

## Admissible use of the report itself

`E.17`: no publication face becomes evidence, a gate, a decision or work by being
presented. The verdict table is the part of this report most likely to travel on
its own — into a forum post, a PR description, a governance thread — and it
carries none of the bounds that make it readable. So the report states its own
admissible use on its face, in its own words, covering four points:

- what it is: one dated observation of one ledger snapshot by one method edition,
  both named in the report;
- what it may be used for: deciding which entries to investigate next, and
  telling a reader which of U1–U4 currently has evidence behind it;
- what it may not be used for: as approval, as an audit result, as an assurance
  claim, or as grounds for a consequential action — those route to `B.3`;
- how long it holds: nothing in it survives a change to `ledger.json`, and the
  carrier observations decay on their own schedule (`A.10:4.6`, `G.11`).

A verdict table lifted out of the report without that block is being used outside
its bounds, whoever lifted it.
