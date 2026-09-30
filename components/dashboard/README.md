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

## Upstream publishing prerequisite

The active deployment record, its report, and `docs/CURRENT-DEPLOYMENT.md` must
be published on `wsteth-ccip/main` before the default GitHub build can consume
them. Local directory builds may use unpublished inputs.
A remote build deliberately fails if the selected record is missing; it never
falls back to an older deployment or copies the old dashboard's embedded data.
No commits or remote publishing are performed by the local builder.

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
