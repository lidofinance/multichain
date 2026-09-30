---
name: validate-ledger
description: >-
  Validate this repository's ledger.json end-to-end and publish a timestamped
  evidence report under reports/. Runs the schema, integrity and formatting
  validators, sweeps every Diffyscan source cohort, tests every publicRefs
  pointer against the carrier it cites, warns about addresses with no evidence
  recorded, and reasons about the result with the First Principles Framework
  (FPF) so each finding is a bounded reliance claim rather than a pass/fail
  badge. Use this whenever the user asks to validate, verify, audit, check,
  re-check or review ledger.json — or the deployments, addresses, sources,
  source provenance, commits, public refs, or docs links in it — even when they
  name only one part ("check the sources with diffyscan", "are the docs links
  still right?", "which addresses have no evidence?", "what does the ledger
  actually establish?"), and whenever they ask for a ledger validation report or
  want to know what is currently unverified. Prefer this over running the
  validators or diffyscan ad hoc: the value is in the joined, dated report.
---

# Validate ledger.json

This skill produces one artifact: a dated markdown report in `reports/` saying
what this ledger snapshot currently establishes, what it does not, and which
entries bound the answer.

The work is read-only. **Never edit `ledger.json`, and never commit anything.**
Establishing a corrected commit or a new `publicRef` is separate work with its
own evidence rules (see the README's provenance section); this skill only
reports.

## What makes this report worth writing

Three checks answer three different questions, and the report's usefulness comes
from keeping them apart:

- the repo's validators answer *is this snapshot internally coherent*;
- Diffyscan answers *does the explorer-verified source at this address match the
  revision the ledger pins*;
- the `publicRefs` check answers *does the publication the ledger cites still
  name this address*.

None of them answers *is this address correct*. A report that blurs the three —
or that reports an unreachable explorer as a source mismatch — is worse than no
report, because it launders a tooling gap into a finding against a Lido
deployment. The FPF frame exists to keep that from happening.

## Step 0 — Preflight and stamp the run

Work from the repository root. Record, before anything else:

```sh
date -u +%Y-%m-%d-%H%M%SZ                 # the run stamp; reuse it everywhere
git rev-parse --short HEAD && git branch --show-current
git status --porcelain                     # a dirty ledger.json changes what you validated
shasum -a 256 ledger.json
uv run --locked python3 -c "import json;d=json.load(open('ledger.json'));print(d['schemaVersion'],d['updatedAt'],len(d['deployments']),len(d['networks']))"
command -v just uv diffyscan
shasum -a 256 .claude/skills/validate-ledger/SKILL.md \
              .claude/skills/validate-ledger/references/known-blockers.json \
              .claude/skills/validate-ledger/scripts/*.py
```

That last line is not bookkeeping. The report names the snapshot it read *and*
the method edition that read it, because a finding is a product of both: change
how a crash is classified and the same ledger yields a different report. Two
reports of one snapshot by different editions do not diff meaningfully, and this
template exists to be diffed. The JSON artifacts carry their own `method` block;
the report carries the skill's.

Then make the run directories: `mkdir -p reports .workspace/<stamp>`. Artifacts go in
`.workspace/` (gitignored); only the report lands in `reports/`.

Two preflight facts belong in the report:

- **Diffyscan is installed unpinned, but the revision is recoverable.**
  `uv tool list` reports `v0.0.0` and
  `~/.local/share/uv/tools/diffyscan/uv-receipt.toml` shows it was installed from
  `git+https://github.com/lidofinance/diffyscan` with no revision. The install
  itself records one — read it and put it in the report:

  ```sh
  uv run --locked python3 -c "import json,pathlib;m=sorted(pathlib.Path.home().glob('.local/share/uv/tools/diffyscan/lib/python3.*/site-packages/diffyscan-*.dist-info/direct_url.json'));print(json.loads(m[0].read_text())['vcs_info']['commit_id'] if m else 'direct_url.json not found')"
  ```

  The interpreter version and the dist-info version are globbed on purpose — a
  path pinned to one `python3.x` reports "not recoverable" for an install that
  merely used a different Python, which is the very defect this recovers from.
  Report the version as `v0.0.0` with that resolved commit, and say which file
  each came from. Only when the command prints `direct_url.json not found` (a
  different install layout) say the revision could not be recovered and that the
  sweep is therefore not reproducible from the report alone — do not pretend to
  a version you do not have.
- **Credentials.** `.env` must carry `ETHERSCAN_API_KEY` and
  `ETHERSCAN_EXPLORER_TOKEN`, and `GITHUB_API_TOKEN` must be in the environment —
  Diffyscan treats it as required and aborts without it, and an unauthenticated
  GitHub caps at 60 requests an hour, which a full sweep exhausts within its
  first minutes. Confirm all three exist (`env | grep -c GITHUB_API_TOKEN`; never
  print values). Missing credentials turn most cohorts into fetch failures, and a
  report that does not say so reads as if the sources were checked.

If `diffyscan` is missing, do not silently produce a docs-only report. Say the
sweep did not run, mark U2 `evidence-needed` for every projected deployment, and
finish the rest of the report.

## Step 0.1 — Write the call plan before burning a call

Write `.workspace/<stamp>/call-plan.md` and carry its budget and stop conditions into
the report's run section. If it cannot be written honestly, the run has not
started:

| Field | This run |
| --- | --- |
| Objective | what this run is meant to establish, and for which bounded uses |
| Routes, in order | sweep (background) → validators → publicRefs → collect |
| Budget envelope | per route, in wall-clock, with the ceiling you will actually enforce |
| Stop conditions | below |
| Replan triggers | below |
| Next planned action | one line |

For the sweep ceiling, use twice the duration the previous run recorded — the
collector writes `durationSeconds` per cohort, so `.workspace/*/diffyscan.json` from a
prior run is the source — and 45 minutes when there is no prior run. Do not
carry a number from this file; it was written against one snapshot and the
cohort count moves with the ledger.

**Stop conditions.** Each one ends a route rather than letting it run on:

- The sweep passes its ceiling. Stop the background job, collect what exists,
  and let the uncollected cohorts land as `not-run`. A truncated sweep honestly
  reported beats an unbounded wait.
- `collect_diffyscan.py` reports a failure cluster whose `rateLimited` flag is
  set, or one covering most failing cohorts. Stop treating the members as
  findings — see Step 3.
- `check_public_refs.py` reports a carrier failure cluster covering most
  carriers. That is this machine's network, not the carriers'. Abstain on U1 for
  the whole run and say so; do not publish N `carrier-unreachable` findings.
- A validator cannot run at all. Report that it did not run. Never infer its
  result from another validator's.

**Replan triggers.** Credentials missing or exhausted at preflight, `just` or
`uv` unavailable, or a ledger that changes under you mid-run (`shasum` at the end
disagrees with the start): fix the condition and restart the affected route
rather than reporting around it.

## Step 1 — Start the Diffyscan sweep first (background)

The sweep dominates the run — tens of minutes, scaling with the cohort count —
so start it before anything else and do the fast work while it runs:

```sh
just diffyscan-sources 2>&1 | tee .workspace/<stamp>/diffyscan-sweep.log
```

Run this **in the background** (`run_in_background: true`) — it exceeds the
foreground command timeout. Record its start and end times; the report states the
sweep window, and the ceiling from Step 0.1 applies to it.

Deliberately no `--cache-explorer --cache-github`: every run re-fetches from the
explorers and GitHub, so the report's observations are as fresh as its timestamp.
If you ever do pass `diffyscan_flags="--cache-explorer --cache-github"` (useful
while iterating), the report must disclose that carrier reads may be as old as
`.diffyscan_cache/` — otherwise the timestamp overstates the freshness.

The recipe re-renders configs first, so a stale config from a removed cohort
cannot be verified and counted as a pass. Exit 3 means "configs rendered, some
deployments did not project" — that is expected, not a failure.

## Step 2 — While the sweep runs: validators and public refs

Run the four validators **separately, not via `just test`**. `just test` stops at
the first failure, and a validation report wants every result — a formatting drift
must not hide a schema error:

```sh
uv run --locked python components/ledger/scripts/format_ledger.py check
uv run --locked python components/ledger/scripts/validate_ledger.py
uv run --locked python components/ledger/scripts/render_diffyscan_config.py --coverage
uv run --locked python -m pytest -q
```

`pytest` validates the validators (the tests mutate a good ledger and assert each
rule fires). A green ledger under broken validators is the failure mode it exists
to catch, so its result belongs in the report.

Then check the public reference claims — independent of the sweep, ~30 seconds:

```sh
uv run --locked python3 .claude/skills/validate-ledger/scripts/check_public_refs.py \
  --out .workspace/<stamp>/public-refs.json \
  --carrier-dir .workspace/<stamp>/carriers
```

It fetches each cited document once — many `publicRefs` are fragments of one
page, so citations far outnumber carriers — pulls forum topics through the
Discourse JSON API so posts beyond the first page are searched too, and reports
per citation whether the carrier names the deployment's address. Exit 3 means
something needs attention.

Read `carrierFailureClusters` in the output before reading the individual
verdicts. If one cluster covers most carriers, the run learned nothing about the
citations and the per-citation verdicts are noise around a single cause.

Read `--help` before assuming a flag. `--offline-dir` replays a previous
`--carrier-dir` without network access, which is how to re-examine a finding
without re-fetching.

## Step 3 — Collect the sweep into per-deployment outcomes

Once the sweep finishes — or once you stopped it at its ceiling, in which case
say so and let the uncollected cohorts land as `not-run`:

```sh
uv run --locked python3 .claude/skills/validate-ledger/scripts/collect_diffyscan.py \
  --out .workspace/<stamp>/diffyscan.json
```

This rebuilds cohort membership by importing the repo's own renderer, so it
cannot disagree with the configs that were verified, and it classifies each
cohort log into outcomes that mean different things:

- **compared:** `source-match` · `source-allowed-diff` · `source-diff`
- **not compared:** `source-missing-upstream` (the source host answered 404 for
  the pinned tree) · `upstream-unavailable` (the source host failed some other
  way — rate limit, auth, 5xx, network) · `explorer-unavailable` · `tool-error` ·
  `not-reached` (the cohort aborted before this address was requested) ·
  `not-run` (the cohort projected but left no log)
- **outside the sweep:** `no-source-claim` (the ledger records no source, so
  there is no revision claim to test) · `unpinned-source-claim` (a repository but
  no commit) · `not-projected` (a full claim exists, no cohort could be built)

The distinction between the first two "not compared" outcomes is the one that
costs a reader most if it is wrong, so the collector takes it from the HTTP
status and host, not from the exception class: Diffyscan raises one
`ExplorerError` for a GitHub 404, a GitHub rate limit *and* an explorer refusal.
A 404 impeaches the ledger's pin. A 403 means the check never ran.

**A crashed cohort is read address by address.** Diffyscan compares a cohort's
addresses in sequence, so a crash leaves three kinds of member: addresses it
already compared in full (their own outcome stands, with
`comparedBeforeCohortAborted` recorded), the address the crash interrupted (the
crash outcome), and addresses it never requested (`not-reached` — their pins are
neither confirmed nor impeached). Do not read a sibling's crash as a fact about
an address the log shows was already compared.

**Read the failing cohort logs yourself before writing any finding.** The
collector classifies; the log holds the sentence worth quoting.

**Failure clusters before individual findings.** `failureClusters` groups the
sweep's failures by outcome, host kind and status. Weakest-link composition
assumes findings are independent members; one exhausted token or one dropped
uplink breaks that assumption and produces one cause wearing N cohort failures.
Judge each cluster and say which way you judged it — a cluster covering two
cohorts out of sixty is two findings; one covering forty is one, and its finding
is about the run, not about the ledger. `rateLimited` on any cluster means the
GitHub token is missing or spent, and U2 is void for every cohort in it.

**Known blockers are claims, not rules.** `references/known-blockers.json`
records chains believed unsweepable, each with an `asOf` date and a
`logSignature`. A cohort only counts as blocked when its own log matches that
signature; an entry with a null signature can never absorb a failure, so an
unrecognised failure reaches you instead of vanishing into a known gap. Two
things in that output belong in the report: a blocker whose cohorts failed in a
way it does not explain (`unexplainedCohorts` — those are findings), and a
blocker `not exercised by this run`, which means the claim went untested and is
now that many days old. Read `notExercisedReason` with it: a blocker whose
networks project no cohort at all (`cohortsOnNetworks: 0`) cannot be exercised
by this snapshot however often the sweep is re-run, and stays untestable until
those entries carry a `source.commit`. That is a different report sentence from
"its cohorts passed" — and that second case (`cohortsOnNetworks` above zero, no
failures) is not an untested claim either: cohorts ran on those networks and
none produced the blocker's `expectedOutcome`, which impeaches the blocker.
Report it as a registry finding, not as a gap. When a blocker is confirmed
against a real log, add its
signature and evidence ref to the registry; that is how a hint becomes evidence.

## Step 4 — Reason with FPF, then write the report

Invoke the `fpf` skill, then read `references/fpf-frame.md` in this skill
directory. It carries the routing (`A.10` governs; `A.7` and `C.2` for their
specific checks), the four bounded uses the report judges (U1–U4), the default
outcome→disposition mapping, and the traps specific to this repository.

The short version, so you know what you are reaching for: findings are
**bounded reliance dispositions** drawn from `A.10:4.5`'s canonical set (`pass`,
`degrade`, `abstain`, `reopen`, `evidence-needed`, `assurance-needed`,
`blocked-current-use`) against a **named use**, never a truth claim about a
contract. Read `patterns/A.10.md` sections `:4.4`–`:4.5` for the path fields and
the member set before assigning any of them.

Read `knownGaps` in `ledger.json` before writing warnings. Several findings are
already recorded there; presenting an acknowledged gap as news costs the reader
attention that the new findings need.

Then write the report following `references/report-template.md`:

```
reports/ledger-validation-<stamp>.md
```

Every finding individually, passes as counts, long identifier lists collapsed in
`<details>`. Leave the file untracked — do not `git add`, do not commit, and do
not add `reports/` to `.gitignore` without asking.

## Finishing

Re-hash the ledger and put both hashes in the report:

```sh
shasum -a 256 ledger.json           # must equal the Step 0 hash
```

"Never edit `ledger.json`" is a promise this skill makes; a promise nobody checks
is not a finding, it is a wish. Two matching hashes make it something a reader
can adjudicate. If they differ, say so prominently — the run validated a snapshot
that no longer exists.

Tell the user the report path, the headline disposition per bounded use, and the
one or two findings worth their next hour. Do not restate the report in chat —
that is what the file is for.

If any step did not run, say so in that summary as well as in the report. An
omitted check that reads as a pass is the worst thing this workflow can produce.
