# state-mate linkage checks

[state-mate](https://github.com/lidofinance/state-mate) calls view functions and
reads storage on a live chain and compares what comes back to a YAML
description. This directory projects `ledger.json` into such a description, so
the ledger's own claims about proxies get tested against the chains they
describe.

It sits beside the Diffyscan tooling in `diffyscan/`, and answers a different
question:

| Tool | Question | Carriers it depends on |
| --- | --- | --- |
| Diffyscan | does the explorer-verified **source** at this address match the revision the ledger pins? | block explorer + GitHub |
| state-mate | does the **live state** of this proxy match the links the ledger records? | an RPC endpoint |

Neither answers *is this address correct*. See "What one run establishes" below.

## Scope: linkage, and only linkage

A rendered config asserts three things per proxy, all of them already stated
somewhere in this repository rather than typed here:

1. the address in the proxy's implementation slot equals the address
   `proxy.implementationDeploymentId` resolves to;
2. the address in the proxy's admin slot equals the address
   `proxy.adminDeploymentId` resolves to, or the one `expectations.json`
   supplies when the ledger has no field for it;
3. for proxy kinds that expose admin views on the proxy contract itself, the
   same two facts read a second way — through a function call rather than a raw
   slot — plus ossification.

Nothing semantic is asserted: no token names, no role holders, no cross-chain
wiring, no balances. That restraint is what lets the whole set be **generated**:
every emitted value is ledger-derived or expectations-derived, so a rendered
config cannot drift away from the ledger the way a hand-written one does.

Reading a storage slot needs no block explorer, only an RPC endpoint. That is
why the ABIs shipped here are first-party fragments rather than explorer
downloads — and it is why linkage runs on chains Diffyscan cannot sweep at all
(zkSync Era, Swellchain and Zircuit are all recorded as explorer-blocked in the
`validate-ledger` skill's `known-blockers.json`, and all three check out here).

## What one run establishes — and what it does not

The governing pattern is FPF `A.10`; the disposition vocabulary below is its
canonical `RelianceDisposition` member set (`A.10:4.5`), used verbatim.

`A.7` (Strict Distinction) is the reason this section exists at all. Three
things are in play and must not collapse into each other:

- **Object** — the contract deployed at an address on a chain;
- **Description** — `ledger.json`, plus `expectations.json`;
- **Carrier** — the RPC endpoint that answered, the ABI fragment used to encode
  the call, and this repository's own slot constants.

state-mate compares a Description to an Object *through* Carriers. A pass
therefore says: *the endpoint we asked, at the block it chose to serve, returned
a value equal to the one the ledger records.* Every carrier in that sentence is
a party you are relying on.

### The bounded use

The `validate-ledger` skill judges four bounded uses, U1–U4. Linkage settles a
fifth, which none of those four covers:

> **U5 — proxy linkage.** Relying on `proxy.implementationDeploymentId` and
> `proxy.adminDeploymentId` (or the declared admin) as the addresses the
> deployed proxy actually resolves to, as observed through the named endpoint at
> the recorded block window.

U5 is genuinely new. **U3** (structural navigation) is settled by
`scripts/validate_ledger.py`, which only checks that the proxy graph is
*internally* coherent — that a link points at an entry of the right kind on the
right network. It never leaves the file. U5 is the first check in this
repository that asks a chain whether the graph is true.

U5 is also not U4. **U4 — role fulfilment** ("this address is the deployment
that actually fulfils its `contractId`") stays `evidence-needed` after every
linkage run, exactly as it does after every Diffyscan sweep. Knowing that a
proxy points at the implementation the ledger names says nothing about whether
either is the right contract for the role.

### Default dispositions

| Observation | Disposition | Bound |
| --- | --- | --- |
| every assertion for the proxy passed | `pass` | U5 only, at the observed block, through the named endpoint. Not U4, not approval, not assurance. |
| a slot or view disagreed with the ledger | `reopen` | The ledger's link and the chain disagree; one of them must be re-established. Read the trap section before writing this up. |
| the call failed without a value (see traps) | `evidence-needed` | Nothing was compared. This is not a mismatch. |
| the proxy did not project (unmapped `proxyKind`) | `evidence-needed` | No storage layout is known for the kind; `--coverage` names these. |
| the admin rests on a `chain-baseline` expectation | `degrade` | See below — the assertion detects change; it does not corroborate design. |
| the admin rests on a declared `adminAddress` | `degrade` | Same bound as its `basis`, narrowed once more: the address itself is maintained here rather than in the ledger, so it has no `publicRefs`, no `auditReportRefs` and no validator behind it. |

### The circularity that has to stay visible

`expectations.json` carries a required `basis` field for a reason. An
expectation with `basis: chain-baseline` was **seeded from the chain it is
checked against**. Its first run is circular by construction and corroborates
nothing.

What it is worth is continuity: from the moment it is recorded, an admin change
— an upgrade, a migration, a compromise — breaks the check. That is a real and
useful property, and it is a different property from "the design says the
bridge executor administers this proxy". Promoting an entry to
`published-design` or `governance-record`, with a citation in its `note`, is
what turns it into an independent check. `--coverage` reports the two counts
separately so the difference cannot be lost in a total.

### Composition

`C.2:4.3`: a conjunctive claim is bounded by its weakest member, and
weakest-link composition assumes the members are independent. One flaky
endpoint is a single cause wearing N failed checks — see the traps. Judge the
cluster before composing, and say which way you judged it.

Consequential reliance — configuring a production integration, moving value,
granting a role — crosses `B.3`'s material-reliance threshold. That routes to
`B.3`, not to a green run here.

## What owns what

| File | Owns | Never contains |
| --- | --- | --- |
| `../ledger.json` | every address, contract name, proxy link | tool settings |
| `networks.json` | the RPC env var name per network, plus a dated public endpoint as documentation | addresses |
| `proxy-kinds.json` | per `proxyKind`: storage slot layout, with the deployments the constants were verified against; per proxy contract name: a first-party view-only ABI | addresses |
| `expectations.json` | admin links the ledger's schema cannot express — by `deploymentId`, or as a literal `adminAddress` for an administrator the ledger does not list at all — each with a `basis` and a `note` | an address the ledger already holds |
| `generated/` | rendered configs, stub ABIs, and a `manifest.json` of projection facts | anything hand-edited |

`expectations.json` names `deploymentId`s wherever it can, so a corrected
address in the ledger propagates without a second edit. `adminAddress` is the
one escape hatch, for an administrator that has no ledger entry to cite — today
that means the Lido DAO Aragon Agent, which administers the four L1
`OssifiableProxy` bridges. Because two names for one address drift apart, the
renderer **rejects** an `adminAddress` the ledger already carries on that
network and tells you to use `adminDeploymentId`; a test asserts the same thing
about the shipped file. Every declared address is emitted under a named anchor
(`&lido-dao-agent`) and flagged in the config as `DECLARED … not in the ledger`,
and `--coverage` counts it apart from everything else.

A `proxyKind` absent from `proxy-kinds.json` **blocks** its proxies rather than
falling back to a plausible slot. Guessing a layout produces confident zeros,
and a zero that matches nothing is indistinguishable from a finding.

## The flow

```sh
# One-time: a state-mate checkout (it is a yarn project, not a CLI on PATH)
git clone https://github.com/lidofinance/state-mate
(cd state-mate && corepack enable && yarn install)
export STATE_MATE_DIR="$PWD/state-mate"

# Endpoints: the configs name env vars, so nothing is committed.
# networks.json records a public endpoint per network to start from.
export MODE_MAINNET_RPC_URL=https://mainnet.mode.network

just state-mate-coverage        # what projects, what does not, what is asserted
just state-mate-render          # write state-mate/generated/<network>/
just state-mate mode            # re-render, then check networks matching "mode"
just state-mate                 # every network
```

`just state-mate` stamps each log with the RPC env var used and the block height
before and after the run. state-mate itself reads `latest` and reports no block
number, so without that stamp two runs are not comparable observations and
neither can be dated to anything finer than a file mtime (`A.10:4.6`).

To check one contract or one section while iterating, state-mate's own filter
works on a generated config:

```sh
(cd "$STATE_MATE_DIR" && yarn start /path/to/generated/mode-mainnet/config.yaml \
    --only l1/mode-mode-wsteth-token/storage)
```

## Cases

Four networks worth running first, because each exercises a different part:

| Network | Why |
| --- | --- |
| `mode-mainnet` | One `OssifiableProxy`. Its admin is the bridge executor, which the ledger's schema cannot record, so it comes from `expectations.json`. The generated `proxyChecks` block can be diffed against the hand-written `configs/mode/mainnet.yaml` upstream — they agree. |
| `linea-mainnet` | Three `TransparentUpgradeableProxy` entries with real `ProxyAdmin` contracts, so all three admin links come from the ledger. No proxy views exist on this kind, so storage is the only evidence. |
| `zksync-era` | Diffyscan cannot read this chain's explorer at all; linkage still checks both proxies. Also the case where two proxies share one `ProxyAdmin`. |
| `bnb-smart-chain-mainnet` | Five `ERC1967Proxy` entries: implementation slot only, no admin concept, no views. The narrowest thing this tooling can honestly say. |

## Known traps

1. **A failed call is not a failed check, and state-mate does not distinguish
   them.** Both print as an error. The signature to look for is
   `REVERTED with: missing revert data (… data=null …)`: that is the endpoint
   returning nothing, not the contract disagreeing. On 2026-08-18,
   `https://mainnet.base.org` reproducibly produced exactly that for one call
   inside the batch ethers sends, while the same config against
   `https://base-rpc.publicnode.com` passed 18/18. Re-run against a second
   endpoint before writing up any failure. A real mismatch names both values:
   `Expected "0x…" but got "0x…"`.
2. **A cluster is one finding until shown otherwise.** Every check on a network
   goes through one endpoint. If a whole network fails, suspect the endpoint
   first; the disposition is `abstain` for that network, and the next action is
   a different endpoint, not a row per proxy.
3. **The ABI coverage figure is measured against stubs.** state-mate advertises
   that it verifies all non-mutable functions are covered. Here that is measured
   against the first-party fragments in `proxy-kinds.json`, so it says nothing
   about the deployed interface. Every generated config says so in its header.
   Do not run these configs with `--update-abi`: it overwrites the stubs with
   explorer downloads and silently changes what the run means.
4. **A public endpoint is an untrusted party.** `--public-rpc` exists for a
   first run and records itself in the config header. A run that matters should
   use an endpoint you control.
5. **`proxy__getAdmin` succeeding also tests `contractName`.** Those views live
   on the proxy contract itself and are not delegated, so a revert may mean the
   deployed proxy is not the contract the ledger names — not that the endpoint
   failed. Traps 1 and 5 look alike; the `data=null` signature separates them.

## Extension points

- **A collector.** Diffyscan has `collect_diffyscan.py`, which classifies each
  cohort's log into outcomes that mean different things and groups failures into
  clusters. Linkage has no equivalent yet, which is why trap 1 is currently a
  human's job. The manifests in `generated/*/manifest.json` exist so a collector
  can rebuild membership without re-deriving it.
- **Unmapped proxy kinds.** Four ledger proxies are `proxyKind: custom` — the
  Aragon `AppProxyUpgradeable` for stETH on mainnet and Hoodi, and Polygon's
  `UChildERC20Proxy`. Both were confirmed to hold zero in the EIP-1967 slots, so
  they need their own layouts before they can be projected.
- **Semantic state.** state-mate's `checks`, `implementationChecks`, `ozAcl` and
  `ozNonEnumerableAcl` sections are what the upstream hand-written configs use,
  and they are where role holders and cross-chain wiring would be asserted.
  They need explorer-verified ABIs and hand-authored expectations, which is a
  different evidence bound from linkage — a separate artifact, not a bigger
  version of this one.
- **The DAO Agent belongs in the ledger.** The four L1 `OssifiableProxy`
  bridges are administered by `0x3e40D7…`, the Lido DAO Aragon Agent. It has no
  `ledger.json` entry, so `expectations.json` declares the address literally and
  the checks do run — but that address now lives outside the ledger, with none
  of the evidence discipline the ledger applies to the other 175. Adding the
  Agent as a deployment would let the four expectations become `deploymentId`
  references and delete the only hardcoded address in this pipeline.
- **Seven proxies that linkage cannot reach.** The `ERC1967Proxy` entries on
  mainnet and BSC (the NTT manager, the transceivers, the BSC wstETH token) have
  no admin slot: a bare ERC1967 proxy keeps upgrade authority in the
  implementation's own storage. Asserting who may upgrade them needs the
  implementation's ABI and an `ozAcl`-style check — the semantic tier below, not
  a slot.
