# Dashboard

This directory holds the dashboard's templates, build script, network metadata,
and tests. Run every command below from the repository root.

## Build inputs and output

The builder writes a static site to `docs/`, which is committed and served by
branch-based GitHub Pages. It reads:

- `ledger.json` from this checkout;
- `lidofinance/wsteth-ccip` at the current `main` commit, or a local source
  directory passed with `--upstream`.

To change a page, edit `components/dashboard/templates/` and rebuild; a build
regenerates the HTML in `docs/`. Other documentation in `docs/` is left intact.

## Commands

```sh
just dashboard          # build, then serve on localhost:8000
just dashboard-build    # build only
```

Both recipes run the builder in the repository's locked Python environment
through `uv` (Python 3.9+) and accept `--output PATH`; the preview serves that
directory.

By default the builder resolves `main` to a commit through the GitHub API and
downloads only the files it needs, over HTTPS, at that commit. It never clones
upstream, and if GitHub fails, the build fails; it does not fall back to a
local copy.

If upstream is private, set a read token in `WSTETH_CCIP_READ_TOKEN`, `GH_TOKEN`,
or `GITHUB_TOKEN` (checked in that order). The token is sent only with API
requests and is never embedded in the site. The builder uses GitHub's
[commit resolution](https://docs.github.com/en/rest/commits/commits#get-a-commit)
and [repository contents at a revision](https://docs.github.com/en/rest/repos/contents#get-repository-content)
endpoints.

Run the tests:

```sh
uv run --locked python -m unittest discover -s components/dashboard/tests
node --test components/dashboard/tests/test_dashboard_runtime.mjs
```

Build tests use controlled Git responses and temporary output directories.

## Building from a local source directory

```sh
just dashboard --upstream /path/to/wsteth-ccip
just dashboard-build --upstream /path/to/wsteth-ccip
```

The builder reads the directory as it is, including uncommitted and untracked
files, without Git or GitHub. A missing input fails the build; it does not
switch to GitHub. The resulting site:

- is marked **LOCAL DIRECTORY**;
- records input hashes and a null upstream commit;
- bundles the consumed source files under `upstream/` for provenance links,
  without host filesystem paths.

The Pages workflow always builds from GitHub.

## Build manifest and identity

Every page links to `ledger.json` on GitHub at this checkout's HEAD commit. The
build fails if the working `ledger.json` differs from HEAD, so commit ledger
edits before building. GitHub builds link to the upstream commit; local builds
link to their bundled inputs.

The build also writes `dashboard-build.json` with the ledger commit, upstream
commit, input hashes, derived data, and build identity. The full ledger is
embedded only in the Ledger explorer; no separate `ledger.json` copy is
published. The manifest pins it with:

- `ledgerCommit`;
- `ledgerSha256`: SHA-256 of the original file bytes;
- `ledgerContentSha256`: SHA-256 of the embedded JSON content. To verify it,
  parse the page's `ledger-data` payload and hash the UTF-8 bytes of
  `json.dumps(payload, sort_keys=True, separators=(",", ":"))` in Python
  (default ASCII escaping). Any value change alters this digest; source
  whitespace does not.

The build identity is a digest of the whole manifest, so it changes with the
ledger, the upstream deployment, and every metadata catalogue. Browser
observation caches and offline snapshots are keyed by it and are not reused
across builds with different inputs.

## Ledger explorer

The **Ledger** tab (`#ledger`) lists every deployment in the build's ledger
input, including implementations and proxy admins. It works from data embedded
at build time and makes no registry or RPC reads.

- **Search** matches recorded values in every entry field and in network
  metadata, including source revisions and reference URLs. Every
  whitespace-separated term must match.
- **Network filter** narrows the list.
- **Expanded row** shows all recorded fields, audit reports, public posts and
  references, source code, network metadata, and the entry JSON. A proxy
  relationship opens the related deployment. Empty references and unknown
  sources are shown as such.

Coverage notes and known gaps appear above the list. Filters and expanded rows
persist across tab switches. The tab links to the commit-pinned ledger and its
raw JSON, which remain the source of truth for tools; it displays recorded data
and draws no verification or audit conclusions.

## Data inputs

Paths under `config/` are relative to `components/dashboard/`.

### wstETH

- **Mainnet tokens:** every mainnet EVM `*-wsteth-token` role in `ledger.json`,
  using its `proxy` or `standalone` entry. Ethereum's own token address also
  comes from the ledger; Ethereum has no destination row.
- **Network mapping:** `config/dashboard-networks.json` is a dated snapshot
  (`takenAt`) of [Lido's deployed-contracts docs](https://docs.lido.fi/deployed-contracts/).
  It supplies support labels and bridge descriptions; a ledger entry alone
  implies no Lido endorsement. A new token role appears as unclassified until
  the mapping describes it.
- **Escrows:** contract roles named in the mapping, resolved against the ledger.
  Nine legacy escrows have no ledger entries, so their addresses still come
  from the mapping.
- A missing or ambiguous required ledger role fails the build; the build never
  keeps a previous address.

### Testnet and companion pages

- **Testnet:** upstream `docs/CURRENT-DEPLOYMENT.md` names exactly one dated
  `config/chains.live-YYYY-MM-DD` record (the name may carry a lane suffix). Its
  two chain JSON files supply tokens, pools, POMs, hooks, lockboxes, verifiers,
  resolvers, and governance holders. The builder checks the lane and the
  required addresses. Other pool types or more than two chains require changes
  to the builder's testnet adapter.
- **Companion pages** (`roles.html`, `ccv.html`): built from the
  `Evidence and limits`, `Current POM permissions`, and `CCV configuration`
  sections of the same document. The matching upstream
  `docs/deployment-YYYY-MM-DD.md` must also exist. The pages republish dated
  source statements and add no verification results; source HTML is escaped.

### Browser observations

The visitor's browser queries the Chainlink registry and public RPCs. The build
reads no balances and makes no claim about current chain state.

### stETH

`config/steth-networks.json` adds rate-oracle metadata to the ledger's stETH
deployments on Optimism, Unichain, and Soneium. Token addresses always come from
the ledger, as do the Optimism and Unichain oracle addresses. Soneium's oracle
and L1 pusher come from Lido's legacy deployment docs.

The table sits immediately above the LDO table. It sorts by stETH supply,
descending, with unread amounts last, and shows each amount with its USD value
rounded to the nearest dollar. Descriptions are collapsed under **Details**;
unidentified networks are listed below the table.

- **Supply:** reads validate chain ID and decimals. Destination `totalSupply()`
  already converts shares at the stored rate, so no further wstETH conversion
  is applied. These totals exclude Ethereum and are separate from wstETH totals.
- **USD:** supply × Chainlink stETH/USD, read directly at its 8-decimal scale
  with a 1-hour heartbeat.
- **Rate:** the browser confirms the token's `TOKEN_RATE_ORACLE()` address and
  the oracle's 27-decimal scale, then shows stETH per wstETH, the L1 measurement
  time (`startedAt`), and the L2 receipt time (`updatedAt`). Each time appears
  as an exact UTC datetime with an age computed from the visitor's clock. The
  outdated indicator compares the L2 receipt time with
  `TOKEN_RATE_OUTDATED_DELAY()`; the pause indicator reads
  `isTokenRateUpdatesPaused()`. A status that cannot be read stays unavailable.
- **Failures:** a failed rate read leaves supply and USD shown; an expired price
  feed leaves stETH amounts shown.

RPC samples are cached per endpoint and build identity. Offline snapshots
include stETH supply, rates, and price.

### LDO

`config/ldo-networks.json` is a separate dated catalogue of sourced EVM bridge
representations of LDO, each linked to a bridge token list or a verified token
contract. It covers Arbitrum One, Optimism, Polygon PoS, BNB Chain, Unichain,
and Celo; non-EVM networks and other bridge representations are out of scope.
wstETH-overview networks without a sourced LDO deployment are named in a
sentence below the table, which does not claim that no bridge exists. LDO
coverage and bridge descriptions do not inherit wstETH endorsement.

- **Supply:** the browser checks the RPC chain ID and token decimals, then shows
  destination `totalSupply()` as outstanding LDO. Zero supply, unread supply,
  and unknown deployment are shown as distinct states. Amounts keep integer
  precision through aggregation.
- **USD:** LDO amount × Chainlink LDO/ETH × ETH/USD on Ethereum. The browser
  checks feed decimals, signed positive answers, round completeness, and
  update times against the configured heartbeats (24 hours for LDO/ETH, 1 hour
  for ETH/USD). The estimate assumes one destination token is worth one Ethereum
  LDO; it does not measure bridge backing, local market liquidity, or cumulative
  transfers. Supply stays visible if pricing fails.
- **Display:** the table is at the bottom of the overview. It sorts by LDO
  amount, descending, as supplies arrive (unread amounts last), and shows each
  amount with its USD estimate rounded to the nearest dollar. Coverage notes,
  source dates, and pricing details are collapsed under **Details**.
- **Totals** cover only the listed destination tokens, flag partial reads, and
  exclude Ethereum's native LDO supply.

### Ethereum totals

The overview summary shows **Total stETH** and **Total LDO**, read on Ethereum.
Total LDO is Ethereum LDO `totalSupply()`, read after the chain ID and
`decimals()` checks; it is the denominator of the bridged LDO percentage. LDO
locked behind bridged representations is already part of it, so bridged LDO is
not additional supply.

Each total is its own cached observation, read with the same chain ID, decimals,
and supply checks as a destination supply. The totals share one RPC batch with
the overview's wstETH balances but are cached separately.

- The overview renders without waiting for the totals; each shows **loading…**
  until it arrives, and shows its own read time when that differs from the
  board's.
- A failed total shows as unavailable with its error in the tooltip and marks
  the overview incomplete. The next load retries that total alone; the other
  total and the overview balances stay cached.

### Partial overview batches

If an overview batch leaves any value unanswered (a supply, rate, escrow, hub
pool balance, or silo state), the batch is cached with its valid values, so
reloads and the offline snapshot keep them. The batch still counts as missing:
the next load, including Refresh, reads it again and keeps each cached value
whose replacement gets no answer.

- A partial response or failed retry shows a warning.
- A merged batch keeps its oldest observation time, so retained values do not
  look freshly read. A fully successful response replaces that time and clears
  the warning.
- Concurrent reads of the same destination supply or Ethereum total share one
  pending read.

### Network types

`config/network-types.json` is a dated catalogue (`takenAt`) that labels each
network by its relation to Ethereum. The label follows the chain ID in the
overview, stETH, and LDO tables and links to its source.

- **L2:** L2BEAT lists the network as a Layer 2 hosted on Ethereum. The row
  records L2BEAT's category (a rollup kind, Optimium, Validium, or Other) and,
  for an archived project, the archive date; both appear in the tooltip. Stage
  is not recorded, so the label makes no security or maturity claim. Polygon PoS
  is one of several L2s in L2BEAT's "Other" category; L2BEAT has archived Jovay
  and Swellchain.
- **alt-L1:** the network's own documentation describes independent consensus,
  or settlement on a chain other than Ethereum. Where the source's own term
  differs, a visible qualifier says so: Bitlayer shows **alt-L1 (Bitcoin L2)**.
- **type unclassified:** the network is absent from the catalogue, for example a
  newly registered CCIP network. No type is inferred.

The build rejects a catalogue containing:

- unknown fields, mistyped values, or impossible dates;
- an L2 source that is not an l2beat.com project page, or whose URL has
  credentials, an explicit port, a query, or a fragment;
- a qualifier on an L2 row (it would be a free-text route for stage claims);
- category or archive data on an alt-L1 row;
- a note ending in a period (the tooltip ends the sentence).

The URL check cannot tie a project page to its chain; review must do that. The
build test requires every ledger, stETH, and LDO network to be classified under
the name those configs use.

## FPF reasoning

These notes record which First Principles Framework patterns shaped the
behaviour described above.

### LDO extension

- **A.10, checklist items 1, 3, 6, and 8:** a sourced bridge representation, an
  observed supply, and a USD estimate are separate claims. Source links and the
  catalogue date carry the address evidence; RPC read times and oracle update
  times carry the observations. A missing address source cannot show that no
  bridge exists, and a failed read cannot show a zero amount.
- **C.16, checklist items 1–3 and 7–9:** the measured quantity is the
  outstanding `totalSupply()` of one identified destination token, with its
  decimals, chain ID, unit, and read time. USD = LDO amount × LDO/ETH × ETH/USD,
  preserving both feed scales. The estimate assumes parity with Ethereum LDO,
  combines observations taken at different times, and gives no backing or
  redemption assurance.
- **E.17, CC-MVPK-1, -3, -4, and -5:** both unit displays derive from the same
  supply observation and keep the underlying LDO amount, source links,
  applicable times and scales, and the catalogue's coverage limits visible.
  Failed reads stay unavailable. The LDO catalogue is part of build identity,
  so changing it invalidates earlier snapshots and observation caches.

### Total LDO and network types

- **A.6.P (precision restoration):** "L2" can mean a rollup, a checkpointed
  sidechain, or any scaling network. The dashboard fixes one relation, *listed
  by L2BEAT as hosted on Ethereum*, and keeps a two-value label. Each L2 claim
  carries its L2BEAT category in the tooltip; stage stays on the linked page.
  "alt-L1" is relative to Ethereum, so an L2 of another chain (Bitlayer on
  Bitcoin) is alt-L1 with a visible qualifier, and the cell agrees with the page
  it links to. The qualifier exists only for that mismatch; an L2 row's source
  term is the label itself, so it cannot carry one.
- **A.10, checklist items 1, 3, 6, and 8:** each type label is a separate dated
  claim with its own source and carries no wstETH endorsement or security
  conclusion. A network absent from the catalogue is unclassified. An L2 claim
  cites an L2BEAT project page, and only a real calendar date can date a claim.
  Total LDO is an RPC observation with chain ID and decimals checked; a failed
  read is unavailable, and "not yet read" is a separate state. Each Ethereum
  total has its own cache record, so an unavailable denominator does not delay,
  invalidate, or force a re-read of the wstETH observations. In an overview
  batch, an unanswered value is not an observation: valid values are kept, but
  the batch is read again on the next load. Retained answers keep the batch's
  older timestamp (A.10 §4.4 and checklist 8), because merged responses do not
  show that all calls succeeded together.
- **C.16, checklist items 1–3:** Total LDO is Ethereum LDO `totalSupply()` at
  18 decimals. Bridged percentage = bridged destination supply / Total LDO;
  both terms stay displayed and may come from different blocks.

### stETH rate publication

- **A.10, checklist items 1, 3, 6, and 8:** ledger deployment addresses,
  destination rate state, and an L1 push are separate claims. The meaning of the
  two timestamp columns comes from the pinned
  [TokenRateOracle source](https://github.com/lidofinance/lido-l2-with-steth/blob/8f19e1101a211c8f3d42af7ffcb87ab0ebcf750c/contracts/optimism/TokenRateOracle.sol).
  The table describes the rate stored on L2; an L1 transaction is not taken as
  proof that a pending push was delivered. Oracle mapping failures stay
  unavailable.
- **C.16, checklist items 1–3 and 7–9:** stETH supply, stETH per wstETH, L1
  measurement time, L2 receipt time, browser observation time, and USD price
  update time keep separate units and meanings. The rate has 27 decimals, token
  amounts 18, and the USD price 8; integer arithmetic preserves these scales.
  USD = supply × stETH/USD, assuming parity with Ethereum stETH.
- **E.17, CC-MVPK-1, -4, -4d, and -5:** the table keeps source links, shows both
  rate timestamps, and orders by raw stETH supply, descending, with unread
  amounts last. It sets no health threshold of its own: rate age is judged
  against the oracle's configured delay, and price age against the feed
  heartbeat. The stETH catalogue is part of build identity and cache
  invalidation.

## Upstream deployment record

The default GitHub build reads the active deployment record, its report, and
`docs/CURRENT-DEPLOYMENT.md` from `wsteth-ccip/main`, so publish them there
first; a local directory build can use unpublished inputs. If the selected
record is missing, a GitHub build fails; it never falls back to an older
deployment or copies data embedded in the previous dashboard. The builder never
commits or publishes anything.

### Reused build data

The published `docs/index.html` reuses the previous dated testnet projection
because upstream was unavailable when it was built. Reproduce it with:

```sh
.venv/bin/python components/dashboard/scripts/build_dashboard.py --reuse-build docs/upstream/dashboard-build.json
```

`--reuse-build` is never selected automatically and cannot be combined with
`--upstream`. It verifies the saved manifest's identity, keeps the saved
upstream projection and source hashes, and regenerates the overview and
manifest from the current ledger, wstETH metadata, LDO and stETH catalogues,
and template. The new manifest records the reused file and its SHA-256, and the
footer reads **REUSED BUILD DATA**.

`roles.html` and `ccv.html` keep their original build provenance, because the
saved projection lacks the source text needed to rebuild them. A full source
build regenerates all three pages.

## GitHub Pages

### Publish a committed build

1. Run `just dashboard-build` (add `--upstream PATH` for local inputs).
2. Review and commit `docs/index.html`, `docs/roles.html`, `docs/ccv.html`, and
   `docs/dashboard-build.json`, plus `docs/upstream/` for a local-source build.
   A local-source build publishes its consumed inputs, including unpublished
   changes, and the pages mark that provenance.
3. In **Settings → Pages → Source**, choose **Deploy from a branch**, select
   the branch with the build, and choose **/docs**.
4. Push the commit to that branch. GitHub runs no build in this mode.

GitHub's automatic Pages workflow checks out submodules even when it publishes
only `docs/`. The private `components/ccip` submodule therefore has
`update = none` in the root `.gitmodules`, so that checkout skips it; the
dashboard does not use it. Keep this setting on the publishing branch
(currently `gh-pages`) when merging source updates. For development, fetch CCIP
with authorized access using `--checkout`; see the
[orchestration setup](../../orchestration/wsteth-ccip/README.md#commands).
References: [Using submodules with GitHub Pages](https://docs.github.com/en/pages/getting-started-with-github-pages/using-submodules-with-github-pages)
and [git submodule](https://git-scm.com/docs/git-submodule) (`update = none`
and the `--checkout` override).

### Build and deploy with Actions instead

Expected site URL after deployment: <https://lidofinance.github.io/multichain/>.

1. Set this repository's **Settings → Pages → Source** to **GitHub Actions**.
2. If upstream is private, add a `WSTETH_CCIP_READ_TOKEN` Actions secret with
   read-only Contents access to `lidofinance/wsteth-ccip`, plus any required
   organization authorization. The default repository token generally cannot
   read another private repository; a public upstream needs no custom token.
3. Push this repository's changes, publish the required upstream inputs, then
   run **Deploy dashboard to Pages** manually.

The workflow checks out this repository, runs the builder tests, fetches the
upstream inputs from GitHub at one resolved `main` commit, and uploads only the
generated site. It runs no upstream scripts, and credentials are neither
persisted nor included in the uploaded site. Pushes do not trigger it; rerun it
after ledger edits or a new upstream deployment. A failed download or build
stops before upload, so the published site stays as it was.

## Asynchronous navigation

Navigation never waits for registry or RPC reads.

- A newly selected view shows a loading message. Settings opens immediately and
  fills registry-dependent names and lane options as they arrive, preserving
  drafts and focus.
- Refresh keeps the current view and its read time visible during reads and
  after a failure, with a single error banner that each new error replaces.
  Refresh in Settings reloads the registry.
- Results for an earlier view may fill observation caches but cannot replace
  the active view, its status, or its read time. One run context guards both
  initial rendering and background supply updates.
- Pending registry, lane, and overview phase-one reads with matching inputs are
  shared, including on Refresh; Refresh bypasses completed caches. Crawl reads
  match on the RPC endpoint too, and overview reads also on the Ethereum
  endpoint, hub pool, and row inputs. Failed reads can be retried.
- Shared reads continue in the background; navigation does not cancel them.
- Clearing the cache detaches pending work and discards its later rendering and
  cache writes. New reads can start immediately, and late responses cannot
  restore cleared data.
- The "offline copy" stamp means the displayed registry is a fallback after a
  network failure. Loading the baked registry at startup is not a network
  failure.

## Optional offline observations

After building, with Node.js 22 or later:

```sh
mkdir -p .workspace/dashboard
cp docs/index.html .workspace/dashboard/index.html
node components/dashboard/scripts/build-lane-watch-snapshot.mjs --site .workspace/dashboard --inline .workspace/dashboard/wsteth-dashboard.html
```

The generator writes `index.snapshot.json` beside the built page in `--site PATH`
(default `docs/`) and, with `--inline PATH`, a standalone HTML copy. The
dashboard does not load the JSON file by itself; open the `--inline` copy to
view baked observations. In the commands above, both files stay in the ignored
`.workspace/`, outside the Pages site. A snapshot records the build identity and
per-read timestamps. Normal builds, including Pages builds, create no snapshot
file and neither refresh nor embed RPC snapshots.
