# Lido Multichain Deployment Ledger

This repository maintains a machine-readable ledger of Lido-related contracts deployed across supported blockchain networks. Its purpose is to make deployed addresses, architectural kinds, and source-code provenance queryable without presenting the ledger itself as the authority that creates those facts.

The current ledger is [ledger.json](./ledger.json). Its data model is defined by [ledger.schema.json](./ledger.schema.json).

## Purpose

The ledger is intended to support:

- discovering the concrete addresses associated with a Lido multichain integration;
- distinguishing proxies, implementations, proxy administrators, libraries, and standalone contracts;
- resolving relationships between separately listed proxy, implementation, and administration deployments;
- recording source repositories, revisions, and paths when they can be established; and
- validating the resulting data mechanically with JSON Schema and cross-entry integrity checks.

It is a deployment catalogue with per-entry source pointers, not an on-chain registry or a truth-producing database. Consumers should follow the cited repository revision, artifact, or other primary evidence when a decision requires it.

## Record unit

One item in `deployments` represents one deployed address on one concrete network:

```text
one deployment entry = one network + one address
```

This is why a proxy and its implementation are separate entries even when they jointly fulfil one protocol role. Likewise, the same hexadecimal address on two networks represents two deployments and receives two different `deploymentId` values.

`deployments` stays a flat array (not a map keyed by `deploymentId`) so each address remains independently ordered and addressable. Relationships use stable identifiers instead of nesting; uniqueness and reference integrity are enforced by validation tooling rather than object-key identity.

## Identity model

The ledger separates deployment identity, protocol-role identity, and source identity.

### `deploymentId`

`deploymentId` identifies one concrete deployed address instance. For EVM deployments it has a CAIP-10-shaped form:

```text
eip155:<chain-id>:<address>
```

Example:

```text
eip155:42161:0x5979D7b546E38E414F7E9822514be443A4800529
```

Use `deploymentId` for references to a particular address on a particular network. It names the address instance, not a bytecode hash: the bytecode at that address may change on upgrade. `deploymentId` values are unique within a ledger snapshot and must equal `networkId` + `:` + `address`.

### `contractId`

`contractId` is a source-independent identifier for the protocol or integration role fulfilled by a deployment. Related proxy and implementation entries normally share a `contractId` even though they have different `deploymentId` values and often different `source` paths.

Use `contractId` to group deployed instances that jointly represent the same logical contract role. Do not use it as a substitute for an address-level identity, and do not encode repository commits or source hashes into it. Unique source identity belongs in `source`.

When two deployments on the same network would otherwise share a role id because one is superseded or retained only for history, give the historical entry an `-archive` `contractId` suffix (for example `…-token-rate-notifier-archive`).

### Labels and architectural kinds

`contractName` is the Solidity contract name of the bytecode at the deployed address (for example `OssifiableProxy` for a proxy address and `ERC20Bridged` for its implementation). It is not a documentation prose label.

`deploymentKind` and `proxyKind` use the enums defined in [ledger.schema.json](./ledger.schema.json). `standalone` means a non-proxy, non-implementation, non-admin, non-beacon, non-library address. Linked Solidity libraries use `library`.

For a proxy, the `proxy` object links to separately listed deployments on the **same network**. Which link is required depends on `proxyKind`:

- `beacon` requires `beaconDeploymentId`, and does not require `implementationDeploymentId` — a beacon proxy resolves through the beacon, so an inlined implementation address would go stale on the next beacon upgrade;
- `diamond` requires neither, because a diamond's facet set is not representable in this model;
- every other `proxyKind` requires `implementationDeploymentId`.

`adminDeploymentId` is always optional. A `deploymentKind: "beacon"` entry (an `UpgradeableBeacon`) may itself carry a `proxy` object to record the implementation it points at; every other non-proxy kind may not.

`proxyKind: "unknown"` means the selected evidence did not establish the proxy architecture; it does not mean that the deployed contract has no identifiable proxy type.

## Network model

Network identity and operational metadata are separated:

- `networkId` on each deployment is the globally scoped network identifier, such as `eip155:1`;
- the document-level `networks` map, keyed by `networkId`, holds `networkName`, `chainFamily`, and `environment` once per network so metadata cannot diverge across entries.

`chainFamily` groups related blockchain or rollup technology (for example `op-stack` for Optimism, Base, Unichain, and other OP-Stack chains). It is not a 1:1 copy of `networkId`.

Absence of a network or environment from `networks` / `deployments` is not proof that no deployment exists. Optional document-level `coverage` and `knownGaps` may record what was checked or what is known to be missing.

## Evidence and source

`source` records repository-relative source-code provenance for that deployment when collected (`repositoryUrl`, optional `commit`, optional `path`). `null` means no source repository has yet been established for the entry.

A URL is a pointer to evidence, not proof of every fact associated with the target. For example, a repository containing a same-named Solidity contract establishes less than an artifact manifest that maps a concrete deployed address to a source path.

### Audit report refs

`auditReportRefs` is an array of pointers to audit-report carriers. Each pointer must be a URI, so a truncated paste or a broken percent-encoding fails validation rather than degrading the evidence link silently. An empty array means no reports are recorded for the entry; it does not prove that no audit exists. Presence of a pointer does not establish deployment-current bytecode equivalence or release assurance.

### Public refs

`publicRefs` is an optional array of pointers to public official or near-official publication carriers (for example research.lido.fi forum posts, Snapshot or Aragon votes, or docs.lido.fi pages) that an external reader can use to cross-check the entry's address. Each pointer must be a URI. Omit the field or use an empty array when none are recorded. Presence of a pointer does not establish address correctness, completeness, DAO approval force, or assurance. `publicRefs` does not replace `source`.

## Snapshot metadata

The top-level fields describe the ledger snapshot: `schemaVersion` versions the data model independently of the JSON Schema specification version, and `updatedAt` records when the snapshot was last changed.

`schemaVersion` is pinned by `const` in the schema, so a document written for an older data model cannot validate silently against a newer schema. Changing the data model means bumping both the `const` and the ledger in the same change.

## Updating the ledger

When adding or refreshing a deployment:

1. Confirm that the entry represents one concrete network/address pair.
2. Ensure the network exists under `networks` (or add it once with `networkName`, `chainFamily`, and `environment`).
3. Construct `deploymentId` from the concrete network and address.
4. Reuse or introduce a `contractId` according to the logical protocol role, independently of the source repository, commit, or artifact name. Use an `-archive` suffix for superseded role instances that remain listed.
5. Set `contractName` to the Solidity contract name of the bytecode at that address.
6. Record the architectural `deploymentKind` and add identifier-based proxy relationships where applicable.
7. Add the narrowest source provenance supported by the evidence (`source` may be `null` when none is established).
8. Update `updatedAt` and validate the complete snapshot.
9. Run `uv run python scripts/format_ledger.py format` so object keys follow schema `properties` order.

Prefer exact network-and-address matches in deployment artifacts or configuration files. A contract-name match can support partial source provenance, but should not be represented as deployment-verified source provenance without an address mapping, verified bytecode, or equivalent evidence.

## Tooling

Python tooling is managed with [uv](https://docs.astral.sh/uv/). Sync locally, then point this clone at the repo-managed git hooks once:

```sh
uv sync
git config core.hooksPath githooks
```

## Key order

Object key order in `ledger.json` is derived from schema `properties` order (document root and `$defs` object schemas). Optional keys are omitted when absent; array element order is not rewritten. Keys under `networks` keep their existing order; nested network objects are reordered.

```sh
uv run python scripts/format_ledger.py format
uv run python scripts/format_ledger.py check
```

`githooks/pre-commit` runs the formatting check (non-mutating) and ledger validation against the **staged** content, not the working tree — `git add -p` can stage a subset of hunks, so a working-tree check can pass on a commit whose recorded content is invalid. Reformat locally with `format` and re-stage if formatting drifted.

## Validation

```sh
uv run python scripts/validate_ledger.py
```

Integrity checks (after schema validation succeeds) enforce:

- `deploymentId` equals `networkId` + `:` + `address` (exact spelling, including address casing);
- `deploymentId` uniqueness within the snapshot;
- address uniqueness within a network, comparing EVM addresses case-insensitively, so one address cannot be listed twice as a checksummed and an all-lowercase entry;
- one live entry per `(contractId, networkId, deploymentKind)`, which is what makes the `-archive` suffix rule enforceable;
- each deployment `networkId` exists as a key in `networks`;
- proxy relation fields declared with `x-refDeploymentKind` resolve to entries of that `deploymentKind`, **on the same network** as the referring deployment.

## Tests

```sh
uv run pytest
```

`tests/` mutates a well-formed ledger one way at a time and asserts the matching rule fires. Without it, CI would only ever run the validators against a known-good `ledger.json`, so a validator that had silently stopped validating would still pass.

CI (`.github/workflows/ledger.yml`) runs the formatting check, the validators, and the tests on pull requests and on pushes to `main` and `develop`. It carries no paths filter: a filtered workflow never produces a status for PRs that touch other files, and would never exercise `githooks/**`.

## Non-goals

The ledger does not, by itself:

- prove that documentation is current or complete;
- prove that deployed bytecode matches a source revision unless the recorded evidence establishes that link;
- infer deployment transactions, compiler settings, proxy standards, or implementation history;
- assert that an undocumented testnet or contract does not exist;
- establish security, audit coverage, governance approval, or operational readiness; or
- replace on-chain inspection and primary-source verification for consequential use.
