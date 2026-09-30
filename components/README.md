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
| `wsteth-token/` | Locally maintained non-rebasing token, proxy, and unit tests |
| `governance-crosschain-bridges/` | Governance executor sources used by the imported Mantle procedure |
| `openzeppelin-contracts-4x/` | Public OpenZeppelin 4.8.3 token dependency |
| `openzeppelin-contracts-upgradeable-4x/` | Token-profile upgradeable dependency |

OpenZeppelin remains here for now as an explicit layout exception: it is a
supporting contract library, not a separately selected domain subsystem.

For upstream repositories, Git pointers pin exact revisions. Nested dependencies retain their own pins.
The CCIP repository requires access to its private upstream. Local edits from the
source checkout have been preserved, including the two core patches and generated
CCIP inputs. Patch files are owned by [orchestration](../orchestration/wsteth-ccip/patches/README.md).

The complete imported revision inventory is in
[migration-source.json](../orchestration/wsteth-ccip/migration-source.json).
No dependency checkout or Git object store points back to the original repository.
