# Deployment configs

Current public record: [`chains.live-mantle-2026-09-15`](chains.live-mantle-2026-09-15/).
[Addresses and evidence](../docs/deployment-2026-09-15.md) ·
[Current roles, selectors and operations](../docs/CURRENT-DEPLOYMENT.md).

## Templates and records

`chains/*.json` are pristine deployment templates, validated by `just lint-config`.
Keep tokens empty, DAO holders zero, and generated `deployed` / `ccv` blocks absent in HEAD.
The pipeline populates these templates and mirrors them into the CCIP submodule during deployment.
`just clean` restores templates from HEAD; it is not an inspection command.

Public addresses and associated core/governance state live together in the dated record directory.
`chains.live-mantle` and `chains.live-mantle-v3` are historical deployments, not aliases for the current one.
Existing scripts default to `config/chains`; select `RECORD_DIR` explicitly for public operations.

```sh
RECORD_DIR=config/chains.live-mantle-2026-09-15 just addrs
```

For RPC-backed checks, also select public RPC endpoints as described in the current guide.
Do not combine a public record with the default local scratch forks.

## Authored configuration

`default_config.json` is the L1 hub policy; `default_config.non_l1.json` is the spoke policy.
The pipeline injects the appropriate file through `DEFAULT_CONFIG`. They differ only in blocking
`unpauseCrossChainTransfers()` (`0xa6cc6ef9`) on L1. `just lint-config` checks this relationship.
The current API uses `setSelectorBlocked` / `isSelectorBlocked`, with no proposal modes or veto.
The default delay is 3 days, expiry is 30 days from creation, and six selector overrides are 14 days.

`governance_addresses.emergency_brakes` and `.chainlink_mcms` are distinct testnet EOAs.
`.guardian` is a legacy schema field and grants no POM role. The generated `.lido_dao_agent`
is the L1 Agent or L2 OpExec. The deployer is removed from POM roles at handover.

## Verification inputs

`state-mate/wsteth.yaml` defines checks; `wsteth.inputs.yaml` carries authored roles and external
Chainlink facts. `wsteth.deployed.yaml` is the generated address book for the selected record.
POM implementation pins in the record state are independent deployment evidence, not values
learned from whichever implementation is currently installed.

The September run passed 431 live checks. That result is dated and scoped to these assertions;
see the report for source-verification and live-delivery limits.
