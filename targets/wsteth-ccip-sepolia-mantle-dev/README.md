# wstETH CCIP Sepolia–Mantle development target

Development configuration for Lido core and Dual Governance on Sepolia
(chain ID 11155111) and a CCIP wstETH leaf on Mantle Sepolia (chain ID 5003).
The governance route uses the imported OptimismBridgeExecutor procedure.
The `dev` designation describes intended use and confers no governance endorsement.

This target owns:

- `config/chains/`: pristine chain templates, external contract addresses,
  governance holders, and lane bindings.
- `config/default_config*.json`: hub/spoke policy inputs.
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
