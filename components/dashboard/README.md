# Dashboard

This directory owns the dashboard: templates, build script, network metadata,
and tests. Commands run from the repository root.

## Build and publishing

The dashboard is built from this checkout's `ledger.json` and the current `main`
branch of `lidofinance/wsteth-ccip` by default, or an explicitly supplied local
source directory. The generated static site goes to
`docs/` and is intended to be committed for branch-based GitHub Pages. Editable
templates live in `components/dashboard/templates/`; edit those and rebuild, rather than
editing generated HTML. Builds preserve the other documentation in `docs/`.

## Local preview

```sh
just dashboard
```

By default, each build resolves `main` through the GitHub API, then downloads
only the required files over HTTPS at that commit. No upstream cloning or
automatic local fallback is used. Python 3.9+ is required.
For a build without a server, use `just dashboard-build`. Both commands accept
`--output PATH`; preview serves that same output directory. The recipes use the
repository's locked Python environment through `uv`.

For private-repository access, set `WSTETH_CCIP_READ_TOKEN` in the environment.
`GH_TOKEN` and `GITHUB_TOKEN` are also accepted, in that order of precedence.
The token is used only for API requests and is never embedded in the site.
The API uses [commit resolution](https://docs.github.com/en/rest/commits/commits#get-a-commit)
and [repository contents at that revision](https://docs.github.com/en/rest/repos/contents#get-repository-content).

To use a local source directory explicitly:

```sh
just dashboard --upstream /path/to/wsteth-ccip
# Build only:
just dashboard-build --upstream /path/to/wsteth-ccip
```

This reads the supplied directory without contacting GitHub or requiring Git.
Uncommitted and untracked inputs are included; no additional flag is required.
The site is marked **LOCAL DIRECTORY**, records input hashes rather than claiming
a GitHub commit, and bundles the consumed source files under `upstream/` for
provenance links. Host filesystem paths are not published. A missing local input
fails the build; it does not switch to GitHub. Pages continues using GitHub by default.

## Data inputs

- **Mainnet tokens:** every mainnet EVM `*-wsteth-token` role in `ledger.json`,
  selecting `proxy` or `standalone`, excluding Ethereum from destination rows.
  Ethereum's own token address is also resolved from the ledger.
- **Escrows:** resolve the contract roles in `components/dashboard/config/dashboard-networks.json`
  against the ledger. Nine legacy escrows still come from the dated docs mapping
  because the ledger has no corresponding entries.
- **Support labels and bridge descriptions:** the same dated mapping; ledger
  membership does not imply endorsement. New token roles appear as unclassified
  until their metadata is supplied. Missing or ambiguous required ledger roles
  fail the build instead of retaining old addresses.
- **Testnet:** `docs/CURRENT-DEPLOYMENT.md` in upstream identifies exactly one
  dated `config/chains.live-YYYY-MM-DD` record (names may include a lane suffix).
  Its two chain JSON files supply tokens, pools, POMs, hooks, lockboxes,
  verifiers, resolvers, and governance holders. The builder checks the lane and
  required addresses. Other pool types or more than two chains require updating
  this adapter explicitly.
- **Companion pages:** the `Evidence and limits`, `Current POM permissions`, and
  `CCV configuration` sections of the same upstream current-deployment document.
  The corresponding `docs/deployment-YYYY-MM-DD.md` must also exist. These are
  dated source statements, not new verification results. Source HTML is escaped.
- **Observations:** Chainlink registry and public RPCs are still queried in the
  visitor's browser. Building does not query balances or prove current chain state.
- **stETH:** `config/steth-networks.json` supplements the ledger's stETH
  deployments on Optimism, Unichain, and Soneium with rate oracle metadata.
  Optimism and Unichain oracle addresses come from the ledger; Soneium's oracle
  and L1 pusher are sourced from Lido's legacy deployment docs. Token addresses
  always come from the ledger. The table appears immediately before LDO and
  sorts by descending supply, with unread amounts last. It shows stETH amounts
  and USD equivalents together, rounding USD to the nearest dollar. Descriptions
  are collapsed under **Details**, and unidentified networks appear below the table.
  Supply reads validate chain ID and decimals. USD uses Chainlink stETH/USD
  directly with its 8-decimal scale and 1-hour heartbeat; destination `totalSupply()`
  already converts shares using the stored rate, so no extra wstETH conversion
  is applied. These totals exclude Ethereum and are separate from wstETH totals.
  Rate reads independently verify the token's `TOKEN_RATE_ORACLE()` address and
  the oracle's 27-decimal scale. The table shows stETH per wstETH, the L1 rate
  measurement timestamp (`startedAt`), and the L2 receipt timestamp (`updatedAt`),
  with exact UTC datetimes and ages calculated from the visitor's clock.
  The outdated indication uses `TOKEN_RATE_OUTDATED_DELAY()` and the L2 receipt
  time; the pause indication uses `isTokenRateUpdatesPaused()`. Missing status
  reads remain unavailable. Rate failures preserve supply and USD figures;
  expired price feeds preserve stETH amounts. RPC samples are cached per endpoint
  and build identity. Snapshot generation includes stETH supply, rates, and price.
- **LDO:** `config/ldo-networks.json` is a separate, dated catalogue of sourced
  EVM bridge representations, with links to bridge token lists or verified token
  contracts. It currently covers Arbitrum One, Optimism, Polygon PoS, BNB Chain,
  Unichain, and Celo. Networks from the wstETH overview without a sourced LDO
  deployment are listed in a sentence below the table, without claiming no bridge
  exists. LDO coverage and bridge descriptions do not inherit wstETH endorsement.
  Browser reads check the RPC chain ID and token decimals before displaying
  `totalSupply()` as outstanding LDO on the destination. Zero supply, unread
  supply, and unknown deployment are distinct. Token amounts retain integer
  precision through aggregation; USD estimates use Chainlink LDO/ETH × ETH/USD
  on Ethereum, checking feed decimals, signed positive answers, round completeness,
  and oracle timestamps against the configured heartbeats (24 hours and 1 hour).
  The LDO table appears at the bottom of the overview, sorts by descending LDO
  amount as supplies arrive (unread amounts last), and shows token amounts
  alongside their USD estimates, rounded to the nearest dollar.
  Coverage notes, source dates, and pricing details are collapsed under **Details**.
  Supply remains visible if pricing fails. Totals cover only the listed destination
  tokens and identify partial reads; they exclude Ethereum's native LDO supply.
  USD estimates assume one destination token is worth one Ethereum LDO; they do
  not measure bridge backing, local market liquidity, or cumulative transfers.
  Non-EVM networks and other bridge representations are outside this catalogue.

Every build links to `ledger.json` on GitHub at this checkout's exact HEAD commit
and writes `dashboard-build.json` with the ledger commit, upstream commit, input
hashes, derived data, and
build identity. The working ledger must match HEAD; commit ledger edits before
building so the link identifies the exact input. The move to root `ledger.json`
must also be committed before a production build can pin that path. Tests use
controlled Git responses and temporary output directories. No ledger copy is published.
GitHub builds link to that commit; local builds link to their
bundled source inputs and record a null upstream commit. The identity
namespaces observation caches and optional offline snapshots, preventing reuse
when ledger, deployment, or metadata inputs change.

`components/dashboard/docs/FPF-REVIEW.md` remains a historical review of the original dashboard; it does not
claim to verify this build pipeline.

## FPF reasoning for the LDO extension

- **A.10, checklist items 1, 3, 6, and 8:** a sourced bridge representation,
  an observed supply, and a USD estimate are separate claims. Source links and
  the catalogue date identify the address evidence; RPC read times and oracle
  update times identify observations. Absence of an address source cannot support
  a negative bridge claim, and read failure cannot support a zero amount.
- **C.16, checklist items 1–3 and 7–9:** the measured quantity is outstanding
  `totalSupply()` of one identified destination token, with declared decimals,
  chain ID, unit, and read time. USD = LDO amount × LDO/ETH × ETH/USD, with both
  feed scales preserved. The estimate assumes parity with Ethereum LDO and has
  asynchronous observation times; it provides no backing or redemption assurance.
- **E.17, CC-MVPK-1, CC-MVPK-3, CC-MVPK-4, and CC-MVPK-5:** both unit displays
  derive from the same supply observation, retain the underlying LDO amount,
  expose source links and applicable time/scale information, and state the
  catalogue's coverage limits. Failed reads stay unavailable. Cache identity
  includes the LDO metadata hash, so changing the catalogue invalidates snapshots
  and observation caches from the previous build.

## FPF reasoning for stETH rate publication

- **A.10, checklist items 1, 3, 6, and 8:** ledger deployment addresses,
  destination rate state, and an L1 push are separate claims. The read-only
  `steth-rate/push-token-rates.sh` reporting logic guided the two timestamp
  columns; timestamp semantics were checked against the pinned
  [TokenRateOracle source](https://github.com/lidofinance/lido-l2-with-steth/blob/8f19e1101a211c8f3d42af7ffcb87ab0ebcf750c/contracts/optimism/TokenRateOracle.sol).
  The table describes the rate stored on L2 and does not infer a pending push's
  delivery from an L1 transaction. Oracle mapping failures remain unavailable.
- **C.16, checklist items 1–3 and 7–9:** stETH supply, stETH per wstETH,
  L1 measurement time, L2 receipt time, browser observation time, and USD price
  update time retain their separate units and meanings. Rate has 27 decimals;
  token amount has 18; USD price has 8. USD is supply × stETH/USD, assuming
  parity with Ethereum stETH. Integer arithmetic preserves the declared scales.
- **E.17, CC-MVPK-1, CC-MVPK-4, CC-MVPK-4d, and CC-MVPK-5:** the table
  retains source links, exposes both rate timestamps, and uses descending raw
  stETH supply for its ordering. Unread amounts follow observed amounts.
  No health threshold is invented: rate age is judged against the oracle's
  configured delay and price age against the feed heartbeat. The stETH metadata
  hash participates in build identity and cache invalidation.

## Upstream publishing prerequisite

The active deployment record, its report, and `docs/CURRENT-DEPLOYMENT.md` must
be published on `wsteth-ccip/main` before the default GitHub build can consume
them. Local directory builds may use unpublished inputs.
A remote build deliberately fails if the selected record is missing; it never
falls back to an older deployment or copies the old dashboard's embedded data.
No commits or remote publishing are performed by the local builder.

The current `docs/index.html` explicitly reuses the previous dated testnet
projection because upstream was unavailable. Reproduce it with:

```sh
.venv/bin/python components/dashboard/scripts/build_dashboard.py --reuse-build docs/upstream/dashboard-build.json
```

`--reuse-build` verifies the saved manifest identity and regenerates the overview
and manifest from the current ledger, wstETH metadata, LDO catalogue, stETH
catalogue, and template. It preserves the saved upstream projection and source
hashes, publishes its carrier and SHA-256, and marks the footer **REUSED BUILD
DATA**. This mode cannot be combined with `--upstream` and is never selected
automatically. Companion `roles.html` and `ccv.html` retain their original build
provenance; the saved projection does not contain the source text needed to
rebuild those pages. A full source build regenerates all three pages.

## Review validation (2026-10-01)

The nine candidates in `/tmp/review-dashboard-ldo-steth-2026-10-01.md` were
checked against the source and reproducible local cases. Findings 1–7 describe
reachable failures and are corrected. Finding 8 establishes redundant concurrent
request batches; live throttling remains a possible consequence, not an observed
result. Finding 9 is a maintenance improvement, supported by the duplicated
price validation and rendering paths rather than a separate user-visible failure.

| Candidate | Implemented improvement | Verification |
| --- | --- | --- |
| 1: registry failure masked | Registry errors and absent mainnet registry prevent green overview status. | Complete token observations with failed registry remain warning. |
| 2: future timestamp error persists | Temporal validity is derived from raw quote timestamps each time; two minutes of future device-clock skew are allowed without extending heartbeats. | Clock moves behind, catches up, then exceeds heartbeat with one RPC read. |
| 3: different stETH prices | wstETH and stETH use one checked stETH/USD quote from configured metadata. | One latestRoundData read; both estimates disappear when it becomes stale. |
| 4: unused curated mappings | Unmatched stETH contract IDs fail the build; new unclassified ledger tokens remain supported. | Misspelled curated ID rejected, new ledger token projected. |
| 5: unreproducible reuse | Explicit `--reuse-build` mode retains saved identity/hash and current input hashes. | Identical outputs from two builds; no upstream fetch; tampered payload rejected before writes. |
| 6: timer destroys focus | Unchanged tabs retain their DOM; changed tab status restores focus. Minute ticks update ages and rate-status spans only; ticks skip in-flight refreshes. | Browser focus, DOM identity, and busy-refresh checks. |
| 7: loading appears failed | Pending USD prices and pending totals use neutral loading states. | Amount retained through loading and completed price failure. |
| 8: redundant batches | Same-turn reads to one endpoint coalesce, deduplicating identical calls; snapshot uses the same batching. | One Ethereum batch and one destination batch; failed supply subcall retains valid rate. |
| 9: duplicated helpers | Shared quote reader, strict word/round decoding, amount/total renderer, and HTTPS source validator. | Existing token, rate, price, sort, and cache regressions remain covered. |

**FPF A.10** (checklist items 1, 3, 6, 8) governs evidence recovery and provenance:
code paths and controlled observations support each bounded finding; saved source
availability is separate from currentness. **C.16** (items 2, 3, 7–9) keeps oracle
time, device time, observation time, scales, and price validity distinct. The
two-minute allowance is an explicit dashboard policy, not a feed heartbeat or
an oracle guarantee. **E.17 CC-MVPK-1, CC-MVPK-4, CC-MVPK-5** govern publication:
the same price evidence has the same validity in both tables, omissions affect
status, and the generated page retains a recoverable source carrier. Tests use
controlled RPC responses; they establish dashboard behavior, not current on-chain
balances or public endpoint reliability.

## GitHub Pages

### Publish the committed build

Build locally with `just dashboard-build` (or explicitly pass `--upstream PATH`).
Review and commit the generated `docs/index.html`, `docs/roles.html`,
`docs/ccv.html`, and `docs/dashboard-build.json`, plus
`docs/upstream/` when using local inputs. Local-source builds publish those
consumed inputs, including any unpublished changes; their provenance is marked
in the pages. The builder never commits or pushes.

Set **Settings → Pages → Source** to **Deploy from a branch**, select the branch
containing your build, and choose **/docs**. Push your commit to that branch to
publish it. No build on GitHub is needed in this mode.

### Build and deploy with Actions instead


Expected site URL after deployment: <https://lidofinance.github.io/multichain/>.

1. Set this repository's **Settings → Pages → Source** to **GitHub Actions**.
2. If upstream is private, configure the `WSTETH_CCIP_READ_TOKEN` Actions secret
   with read-only Contents access to `lidofinance/wsteth-ccip` (and any required
   organization authorization). The default repository token generally cannot
   read another private repository. Public upstream needs no custom token.
3. Publish these changes and the required upstream inputs, then run
   **Deploy dashboard to Pages** manually.

The workflow checks out this multichain repository, runs the builder tests,
fetches upstream inputs directly from GitHub at one resolved main revision, and
uploads only the generated site. It executes no upstream scripts. Credentials are not persisted or included
in the artifact. Pushes alone do not deploy; rerun the workflow to incorporate
ledger edits or a newer upstream deployment. A failed download/build prevents
upload and deployment, leaving the previously published site intact.

## Optional offline observations

After building, with Node.js 22 or later:

```sh
node components/dashboard/scripts/build-lane-watch-snapshot.mjs --inline /tmp/wsteth-dashboard.html
```

Use `--site PATH` for a nondefault build directory. The generator writes
`index.snapshot.json` beside the built page and optionally a standalone HTML copy.
The JSON file alone is not loaded by the dashboard; use the `--inline` HTML copy
to view baked observations. Normal builds do not create an empty snapshot file.
It records the build identity and per-read timestamps. Normal Pages builds do not
refresh or embed RPC snapshots.
