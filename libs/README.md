# Supporting libraries and tools

Pinned upstream dependencies used to implement, build, test, script, or verify
our target subsystems. Domain packages selected for targets live under
[components/](../components/README.md); orchestration owns our procedures and
targets own the configuration and checks those procedures consume.

| Repository | Use |
| --- | --- |
| `forge-std/` | Foundry script and test library |
| `state-mate/` | State verification tool |

`libs/` is a local umbrella for libraries and tools; state-mate remains a tool.
A library can contribute code to a deployed artifact without becoming a separately
selected domain component. Nested upstream dependencies retain their own layout
and pins. Run provenance records supporting dependencies alongside components.

Git submodule paths and registration names match the current `libs/` locations.
Historical run snapshots retain the paths used at the time.
Prepare a new run to capture the current layout rather than rewriting old inputs.
Both ledger and wstETH runners default to the pinned `libs/state-mate` checkout.
`STATE_MATE_DIR` remains an explicit ledger override; results from an override
need their own version and observation context before comparison.

FPF basis: A.1 CC-A1-7 separates collection membership from system composition;
CC-A1-9 prevents inferring containment from measuring or changing a system.
CC-A1-11 keeps source/configuration descriptions distinct from deployed systems.
These distinctions motivate this local layout; FPF does not prescribe its names.
