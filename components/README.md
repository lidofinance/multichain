# Components

Components own coherent domain responsibilities with explicit inputs, outputs,
and dependencies. They may be locally maintained packages or pinned upstream
repositories. Target manifests select only relevant packages; supporting dependencies are
classified separately under [libs/](../libs/README.md).
`wsteth-ccip` names the orchestration in this repository, not another component.

| Package | Use |
| --- | --- |
| `ledger/` | Schema, validation, formatting, and projections for root `ledger.json` |
| `dashboard/` | Presentation and rendering into root `docs/` |
| `core/` | Lido core and Dual Governance scratch deployment |
| `ccip/` | CCIP pools, hooks, POMs, verifiers, and upstream deployment scripts |
| `wsteth-token/` | Locally maintained non-rebasing token, its proxy artifact imports, and unit tests |
| `governance-crosschain-bridges/` | Governance executor sources used by the imported Mantle procedure |
| `openzeppelin-contracts-5.0.2/` | Public OpenZeppelin 5.0.2: token implementation interfaces and utilities |
| `openzeppelin-contracts-upgradeable-5.0.2/` | Public OpenZeppelin upgradeable 5.0.2: the token's `AccessControlEnumerableUpgradeable` base |
| `wsteth-token/lib/openzeppelin-contracts-5.3.0/` | Public OpenZeppelin 5.3.0: `TransparentUpgradeableProxy` + `ProxyAdmin` in front of the token (inside the token root so Foundry names its cyclic imports relatively) |

OpenZeppelin remains here for now as an explicit layout exception: it is a
supporting contract library, not a separately selected domain subsystem. The three
pins mirror the editions the CCIP token deployment (`BurnMintERC20Transparent`) is
built and deployed with, so the token and its proxy share one dependency baseline.
The 5.3.0 pin is nested in `wsteth-token/lib/` rather than placed beside the other two
because Foundry names the proxy's cyclic imports by absolute path when the checkout is
outside the compiling project's root (see `wsteth-token/foundry.toml`).

For upstream repositories, Git pointers pin exact revisions. Nested dependencies retain their own pins.
The CCIP repository requires access to its private upstream. Local edits from the
source checkout have been preserved, including the two core patches and generated
CCIP inputs. Patch files are owned by [orchestration](../orchestration/wsteth-ccip/patches/README.md).

The complete imported revision inventory is in
[migration-source.json](../orchestration/wsteth-ccip/migration-source.json).
No dependency checkout or Git object store points back to the original repository.
