# Dashboard FPF review

Historical review imported from `wsteth-ccip/docs/explainers`; the checks below
refer to that review, not a new validation of the migration or deployments.

Reviewed 2026-09-15. Scope: `index.html`, including Live, Dev (testnet), data provenance, balance comparisons, and navigation. This is a source-code review with local behavior checks, not an assessment of bridge safety or current deployments.

## Governing patterns

- **E.17, CC-MVPK-1, CC-MVPK-3, CC-MVPK-4, CC-MVPK-4j, CC-MVPK-5:** readers must see scope, source references, material numeric context, and no claims added by presentation.
- **A.10, §6 checklist items 1, 3, 6, 8:** identify the claim and source, keep observations distinct from conclusions, and expose the time of evidence.
- G.12 was considered but does not govern this dashboard: it concerns discipline-health coordinate series, which this dashboard does not publish.

## Findings and implemented fixes

| Finding | Fix | Governing check |
| --- | --- | --- |
| Partial supply was described as “bridged, all networks.” | Label partial reads explicitly and restrict completed totals to listed networks. Incomplete supply or backing reads keep the overview status amber. | E.17 CC-MVPK-3, CC-MVPK-4j |
| Positive balance differences were labeled “in flight,” asserting a cause without transfer evidence. | Report the numerical difference and explain that asynchronous reads do not establish its cause. | A.10 §6 items 1, 6 |
| “Matches” concealed a tolerance, and integer truncation effectively enlarged it. | Show the 0.1% tolerance and compare exact integer products at the boundary. | E.17 CC-MVPK-4 |
| Pool mismatch was attributed to failed reads, while a missing silo balance could be treated as zero. | Require every listed silo balance before reconciliation; distinguish incomplete reads from a measured mismatch. Limit the statement to listed silos. | A.10 §6 items 1, 6 |
| Provenance text claimed fresh chain reads despite cache and baked-snapshot paths. | Explain those paths, show per-cell UTC read times, and label the header as the oldest read. | A.10 §6 items 3, 8 |
| Dev deployment labels said “live v3”; the token column called all networks L2s. | Use “testnet v3” and “network token.” | E.17 CC-MVPK-1, CC-MVPK-3 |
| A tab click during loading could be lost; background overview reads could update another view's timestamp. | Queue the latest navigation and invalidate old overview callbacks when a new run begins. | E.17 CC-MVPK-4j |
| Status dots had no accessible explanation of their scope. | Add accessible labels and tooltips describing displayed checks. | E.17 CC-MVPK-1 |

## Validation and limits

Passed inline JavaScript syntax checks and Node VM behavior checks for exact/just-above tolerance boundaries, non-causal difference labels, partial totals/status, queued navigation, and mainnet/testnet routing. `git diff --check` passed.

Browser layout and external RPC responses were not verified. Reads remain at independent latest blocks; timestamps identify local read completion rather than block time. Curated groupings retain their existing dated source references and were not externally revalidated. USD estimates still use the existing oracle-answer method without checking the oracle update timestamp. Reconciliation covers the registry's listed lanes and is not a proof of full backing.
