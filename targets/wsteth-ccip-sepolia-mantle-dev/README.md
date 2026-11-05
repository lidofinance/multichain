# wstETH CCIP Sepolia multispoke development target

Development configuration for Lido core and Dual Governance on Sepolia
(chain ID 11155111) and CCIP wstETH spokes on Mantle Sepolia (chain ID 5003)
and Base Sepolia (chain ID 84532), with distinct L1 lockboxes. The historical
target ID is retained. `networks.l2s` can contain one or more spokes.
The governance route uses the imported OptimismBridgeExecutor procedure.
The `dev` designation describes intended use and confers no governance endorsement.

This target owns:

- `config/chains/`: pristine chain templates, external contract addresses,
  governance holders, and lane bindings.
- CCIP policy starts from the component's own `config/default_config.json`. The controlled testnet `config/access-profile.json` overrides the delay (300 seconds) and proposal expiry (one day) in a generated run-local configuration; blocked selectors and rate limits stay upstream. Scratch spokes name the token `1_Deploy` deploys under `token_deployment`.
- `config/state-mate/`: verification wiring, expected values, and maintained ABIs.
- `test/scenario/`: fork-based integration and governance checks.
- `target.json`: network selection, required component repositories, operation,
  verification recipes, and references to historical records.

From the repository root:

```sh
just wsteth-prepare wsteth-ccip-sepolia-mantle-dev <run-id> fork
just wsteth lint-config
just wsteth preflight
```

Append `--spokes mantle_sepolia` or `--spokes base_sepolia` at preparation to
select a single spoke; the default selects both. `config/ccv-policy.json` starts
with Chainlink plus local dummy resolvers required in both directions and declares
the expected inbound/outbound routing. The owned post-configuration step installs
this policy before deployer handover, checking Chainlink's pinned mappings first.
See [multichain operations](../../orchestration/wsteth-ccip/docs/MULTICHAIN-OPERATIONS.md)
for later CCV configuration and the provider parameter checklist.

The [fresh deployment access guide](../../orchestration/wsteth-ccip/docs/SEPOLIA-FRESH-DEPLOY-ACTORS.md)
documents the 18 private actors, ERC-1271 DSM guardians, oracle committees and
signed governance commands. `all` configures core access and checks authority
before running the fork access rehearsal. Voting plus DG plus L2 executor wait
8 minutes in total; canonical network delivery is additional.

Preparation copies authored inputs into a new local run without deploying or
querying a network. Deployment scripts update that run's copies, leaving this
configuration unchanged. Select `testnet` instead of `fork` only for a public
testnet run, with matching RPC endpoints. See the
[orchestration guide](../../orchestration/wsteth-ccip/README.md) for the recipe
interface and resuming a run.

Historical deployments and private local records are under
[`runs/wsteth-2.0`](../../runs/wsteth-2.0/README.md). They remain evidence about
those dated operations, separate from this target's desired state. The local
September record can seed an inspection or rehearsal workspace via `--record`;
its network IDs are checked before copying. No upgrade configuration or new
verification result is inferred from an imported deployment record.

Chain records share the orchestration's [chain schema](../../orchestration/wsteth-ccip/script/chain.schema.json).
`lint-config` validates that format and the operation-specific rules for pristine templates.
