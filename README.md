# Lido Multichain Deployment Ledger

This repository maintains a machine-readable ledger of Lido-related contracts deployed across supported blockchain networks. Its purpose is to make deployed addresses, architectural kinds, and source-code provenance queryable without presenting the ledger itself as the authority that creates those facts.

The current ledger is [ledger.json](./ledger.json). Its data model is defined by [ledger.schema.json](./ledger.schema.json).

## Purpose

The ledger is intended to support:

- discovering the concrete addresses associated with a Lido multichain integration;
- distinguishing proxies, implementations, proxy administrators, and standalone contracts;
- resolving relationships between separately listed proxy, implementation, and administration deployments;
- recording source repositories, revisions, and paths when they can be established; and
- validating the resulting data mechanically with JSON Schema.

It is a deployment catalogue with per-entry source pointers, not an on-chain registry or a truth-producing database. Consumers should follow the cited repository revision, artifact, or other primary evidence when a decision requires it.

## Record unit

One item in `deployments` represents one deployed address on one concrete network:

```text
one deployment entry = one network + one address
```

This is why a proxy and its implementation are separate entries even when they jointly fulfil one protocol role. Likewise, the same hexadecimal address on two networks represents two deployments and receives two different `deploymentId` values.

The ledger uses a flat deployment collection. Relationships are expressed through stable identifiers instead of nesting implementation or administrator records inside a proxy. This keeps every deployed address independently addressable and avoids duplicating shared records.

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

Use `deploymentId` for references to a particular address on a particular network. It names the address instance, not a bytecode hash: the bytecode at that address may change on upgrade.

### `contractId`

`contractId` is a source-independent identifier for the protocol or integration role fulfilled by a deployment. Related proxy and implementation entries normally share a `contractId` even though they have different `deploymentId` values and often different `source` paths.

Use `contractId` to group deployed instances that jointly represent the same logical contract role. Do not use it as a substitute for an address-level identity, and do not encode repository commits or source hashes into it. Unique source identity belongs in `source`.

### Labels and architectural kinds

`contractName` is the Solidity contract name of the bytecode at the deployed address (for example `OssifiableProxy` for a proxy address and `ERC20Bridged` for its implementation). It is not a documentation prose label.

`deploymentKind` states the architectural kind of the deployed address:

- `standalone`
- `proxy`
- `implementation`
- `proxy-admin`
- `beacon`
- `library`

`standalone` means a non-proxy, non-implementation, non-admin, non-beacon, non-library address.

For a proxy, the `proxy` object links to separately listed deployments through `implementationDeploymentId`, and optionally `adminDeploymentId` or `beaconDeploymentId`. `proxyKind` classifies the upgrade/admin architecture (`transparent`, `erc1967`, `ossifiable`, `uups`, `beacon`, `diamond`, `custom`, `unknown`). `proxyKind: "unknown"` means the selected evidence did not establish the proxy architecture; it does not mean that the deployed contract has no identifiable proxy type.

## Network model

Network identity and operational environment are separate fields:

- `networkId` is the globally scoped network identifier, such as `eip155:1`;
- `networkName` is its human-readable canonical name;
- `chainFamily` groups related blockchain or rollup technology;
- `environment` classifies the network as `mainnet`, `testnet`, `devnet`, or `local`.

Absence of a network or environment from `deployments` is not proof that no deployment exists.

## Evidence and source

`source` records repository-relative source-code provenance for that deployment when collected (`repositoryUrl`, optional `commit`, optional `path`). `null` means no source repository has yet been established for the entry.

A URL is a pointer to evidence, not proof of every fact associated with the target. For example, a repository containing a same-named Solidity contract establishes less than an artifact manifest that maps a concrete deployed address to a source path.

### Audit report refs

`auditReportRefs` is an array of pointers to audit-report carriers (free-form strings, typically URLs). An empty array means no reports are recorded for the entry; it does not prove that no audit exists. Presence of a pointer does not establish deployment-current bytecode equivalence or release assurance.

## Snapshot metadata

The top-level fields describe the ledger snapshot:

- `schemaVersion` versions the ledger data model independently of the JSON Schema specification version; and
- `updatedAt` records the calendar date on which the snapshot was last changed.

## Updating the ledger

When adding or refreshing a deployment:

1. Confirm that the entry represents one concrete network/address pair.
2. Construct `deploymentId` from the concrete network and address.
3. Reuse or introduce a `contractId` according to the logical protocol role, independently of the source repository, commit, or artifact name.
4. Set `contractName` to the Solidity contract name of the bytecode at that address.
5. Record the architectural `deploymentKind` and add identifier-based proxy relationships where applicable.
6. Add the narrowest source provenance supported by the evidence (`source` may be `null` when none is established).
7. Update `updatedAt` and validate the complete snapshot.
8. Run `uv run python scripts/format_ledger.py format` so object keys follow schema `properties` order.

Prefer exact network-and-address matches in deployment artifacts or configuration files. A contract-name match can support partial source provenance, but should not be represented as deployment-verified source provenance without an address mapping, verified bytecode, or equivalent evidence.

## Tooling

Python tooling is managed with [uv](https://docs.astral.sh/uv/). Sync locally, then point this clone at the repo-managed git hooks once:

```sh
uv sync
git config core.hooksPath githooks
```

## Key order

Object key order in `ledger.json` is strict and follows the order of keys under each `properties` object in `ledger.schema.json` (document root, `deploymentEntry`, `source`, `proxy`). Optional keys are omitted when absent; array element order is not rewritten.

Rewrite or check:

```sh
uv run python scripts/format_ledger.py format
uv run python scripts/format_ledger.py check
```

The `githooks/pre-commit` hook runs key-order formatting and ledger validation (JSON Schema plus integrity checks) when `ledger.json` or `ledger.schema.json` is staged. If the hook reformats the ledger, stage the updated file and commit again.

## Validation

Basic JSON syntax checks:

```sh
uv run python -m json.tool ledger.json >/dev/null
uv run python -m json.tool ledger.schema.json >/dev/null
```

JSON Schema validation (draft 2020-12, including `format` checks) plus cross-field integrity rules:

```sh
uv run python scripts/validate_ledger.py
```

Integrity checks currently enforce:

- `deploymentId` equals `networkId` + `:` + `address` (exact spelling, including address casing).

Key-order check:

```sh
uv run python scripts/format_ledger.py check
```

Repository whitespace checks:

```sh
git diff --check
```

The schema validates record shape and selected conditional rules, such as requiring a `proxy` relation object for entries whose `deploymentKind` is `proxy`. Additional cross-entry integrity—uniqueness of `deploymentId` and resolution of referenced implementation/admin/beacon IDs—should also be checked by ledger maintenance tooling or review.

## Non-goals

The ledger does not, by itself:

- prove that documentation is current or complete;
- prove that deployed bytecode matches a source revision unless the recorded evidence establishes that link;
- infer deployment transactions, compiler settings, proxy standards, or implementation history;
- assert that an undocumented testnet or contract does not exist;
- establish security, audit coverage, governance approval, or operational readiness; or
- replace on-chain inspection and primary-source verification for consequential use.
