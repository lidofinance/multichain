# Report structure

Write to `reports/ledger-validation-<YYYY-MM-DD-HHMMSSZ>.md` (UTC). Follow this
section order so successive reports diff cleanly against each other.

"Concise yet full" resolves as: **every finding appears individually; passes
appear as counts.** A reader must be able to act on this document without opening
the JSON artifacts, and must not have to scroll past 130 rows of "fine" to reach
the three that are not. Long identifier lists go in a `<details>` block — present
but collapsed. If a section has nothing to report, write one line saying so; do
not pad it and do not drop the heading.

Length is a symptom, not a target. Before publishing, check the thing a line
count was ever standing in for: does every non-clean entry appear individually,
and does every clean one appear only inside a count or a collapsed list? A
section that is long because there are many findings is the right length. A
section that is long because passes are listed inline is not, and the repair is
to move the passes into a count — never to trim a finding to hit a number.

---

```markdown
# Ledger validation report — <YYYY-MM-DD HH:MM:SSZ>

## Verdict

<Two to four sentences. The bounded disposition per use, what set the bound, and
the one thing a reader should do next. No score, no percentage-as-grade.>

| Bounded use | Disposition | What set the bound |
| --- | --- | --- |
| U1 — public cross-check | `<disposition>` | <the entries that bound it> |
| U2 — source provenance | `<disposition>` | <the entries that bound it> |
| U3 — structural navigation | `<disposition>` | <validator result> |
| U4 — role fulfilment | `evidence-needed` | nothing in this workflow tests it |

Governing pattern: `A.10` (evidence-provenance path, bounded reliance).
Dispositions are `A.10:4.5` members and are not gate decisions, approvals, or
assurance results.

**Admissible use of this report.** <One dated observation of the snapshot below,
by the method edition below. Use it to decide which entries to investigate next
and to see which of U1–U4 currently has evidence behind it. It is not approval,
not an audit result, not an assurance claim, and not grounds for a consequential
action — those route to `B.3`. Nothing in it survives a change to `ledger.json`.>

## Snapshot under validation

| Field | Value |
| --- | --- |
| `ledger.json` sha256, before | `<hash>` |
| `ledger.json` sha256, after | `<hash>` (equal — this run changed nothing) |
| `updatedAt` | <date> (<N> days before this run) |
| git HEAD | `<sha>` (<branch>), worktree <clean|dirty: files> |
| deployments / networks | <N> / <N> |
| skill edition | `SKILL.md` `<sha256[:12]>`, `collect_diffyscan.py` `<sha256[:12]>`, `check_public_refs.py` `<sha256[:12]>`, `known-blockers.json` `<sha256[:12]>` |
| diffyscan | <version>, `--skip-binary-comparison` |
| sweep window | <start>Z → <end>Z (<duration>), <completed|truncated at the ceiling> |
| carriers fetched | <timestamp>Z |

## Run

<The call plan's budget and stop conditions, and what actually happened against
them: routes that completed, routes cut short, budget burned. One short table or
four lines. A truncated route stated here is a finding about the run; a truncated
route left unstated turns into a finding about the ledger.>

<Then the failure clusters from both scripts, and for each, the judgement:
one common-mode cause, or that many independent findings, and what decided it.
One line saying "no clusters" when there are none.>

## 1. Structure and integrity — U3

<Result of the formatting check, schema validation, integrity checks, and
projection coverage. One line each when they pass. Full error text when they do
not — a schema error is the one finding a reader cannot reconstruct.>

## 2. Source provenance — U2

### 2.1 Coverage

<Counts by outcome, and by network if it clarifies. State plainly what the
`source-match` count does and does not establish, once.>

### 2.2 Findings

<One block per non-clean deployment, grouped by cause so a shared root cause is
fixed once rather than read five times.>

#### `<outcome>` — <cause in a few words>

- `<deploymentId>` — `<contractName>` (`<contractId>`)
  - cohort: `<cohortId>`, pin: `<repo>@<commit>`
  - evidence: `<logPath>`<, digest diff paths when a file diff>
  - <what the log actually says, in one sentence>
  - disposition: `<member>` for U2 — <why>

### 2.3 Outside the sweep

<Deployments Diffyscan was never asked about, split by what that means, because
the three do not mean the same thing:>

- **`no-source-claim`** — the ledger records no source. There is no U2 claim to
  verify; report this as a completeness figure, not as a failed check.
- **`unpinned-source-claim`** — a repository but no commit, so the pinned-revision
  claim U2 quantifies over is never made. `abstain`.
- **`not-projected`** — a full claim exists and no cohort could be built for it.
  A tooling gap: `evidence-needed`, with the collector's reason quoted.

<A green sweep says nothing about any of them, and that sentence belongs here.>

### 2.4 Known blockers

<Each documented blocker: whether this run exercised it, whether its signature
matched, how old the claim now is, and any failing cohort on its networks that it
does not explain. A blocker not exercised by this run is an untested claim, and
saying so is the point of the section. One line if the registry is empty.>

## 3. Public reference claims — U1

### 3.1 Carriers

| Carrier | Via | Status | Addresses named | Fetched |
| --- | --- | --- | --- | --- |

<Then the carrier failure clusters and the judgement made about them, unless the
Run section already covered them.>

### 3.2 Findings

<Same block shape as 2.2. For an absent address, quote what the carrier names
instead — that is what makes the finding actionable rather than a complaint.>

### 3.3 Fragment resolution

<Cited `#anchor` targets that no longer exist. Navigation defect, reported
separately from any address verdict. One line if none.>

## 4. Evidence gaps — warnings

| Gap | Count | Consequence for reliance |
| --- | --- | --- |
| No `publicRefs` | <N> | no public cross-check offered for the address |
| `source` is null | <N> | invisible to source verification |
| `source` without `commit` | <N> | no revision claimed, so U2 cannot be judged |
| No `auditReportRefs` | <N> | no audit-report pointer recorded |
| `publicRef` present but unverifiable | <N> | cited support does not currently hold |
| Neither `publicRefs` nor `source` | <N> | nothing a reader can follow at all |

<Then the sharpest slice — the entries with no evidence at all — listed in full,
because those are the ones worth a human's next hour. Bulk lists collapsed:>

<details>
<summary>All <N> deployments with no <code>publicRefs</code></summary>

<list>

</details>

Absence of a pointer is not evidence that no publication or audit exists; it is
evidence that this snapshot offers a reader no way to cross-check.

## 5. Already acknowledged in `knownGaps`

<Findings above that the ledger already records, with the `knownGaps` wording.
Keeps the new-information part of this report honest. One line if none.>

## 6. What this report does not establish

<Short, specific list. At minimum: bytecode equivalence (bytecode comparison was
skipped), correctness or currentness of any address, DAO approval, audit
coverage, and completeness of the snapshot. Close with the `A.10:4.5` routing:
for material reliance the `B.3` threshold applies and this document is not an
assurance result.>

## Replay

| Artifact | Path |
| --- | --- |
| Diffyscan collection | `<path>` |
| Public-ref check | `<path>` |
| Fetched carriers | `<path>` |
| Cohort logs | `diffyscan/logs/` |
| Diff renderings | `digest/` |

Commands, in order:

```sh
<the exact commands this run used>
```
```

---

## Writing notes

- **Name the deployment, not the row number.** `deploymentId` is the stable
  handle; a reader will paste it into a grep.
- **Quote the tool, don't paraphrase it.** "GitHub 404 for
  `ERC1967Proxy.sol?ref=eae15a0`" beats "source lookup failed".
- **One sentence of consequence per finding.** A finding without a "so what" gets
  skipped.
- **Say when a check did not run.** An omitted check that looks like a pass is
  the worst outcome this report can produce.
- **Do not recommend edits to `ledger.json` as if they were established.** A
  finding says the pin is impeached; establishing the right pin is separate work
  with its own evidence (see the repo README's provenance rules).
- **Quote the status, not the exception.** "GitHub 403, rate limit exceeded"
  and "GitHub 404 for `ERC1967Proxy.sol?ref=eae15a0`" are different findings and
  the log text alone will not keep them apart for a reader.
- **A cluster judged is worth more than a cluster listed.** Whether forty
  failures are forty findings or one is the judgement a later reader cannot
  recover from the JSON artifacts.
