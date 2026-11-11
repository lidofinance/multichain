# Retired: PoolOperationManager-era documents

These documents describe the governance model this orchestration deployed before 2026-10-22, when
every CCIP contract was owned by a `PoolOperationManager` proxy with its own proposal queue, veto
and pause roles. That model is retired: `components/ccip` branch `lido-2.0-expiry` hands the pool,
hooks, lockboxes and CCV stack to a `LidoTimelock` (Chainlink's `RBACTimelock` plus a
proposal-queue halt) with a `CallProxy` executor, and the hooks carry their own pause roles.

Nothing in this directory is maintained. Where a statement here conflicts with the component's
`config/README.md`, its `script/deployment/README.md`, this orchestration's `README.md` or the
state-mate wiring under `targets/*/config/state-mate`, the current documents win. The files are kept
as the record of the review and rehearsal work done against the earlier model (the dated reports in
`../` cite them).

Historical supporting records:

- [Chainlink standard timelock proposal](chainlink-standard-timelock-proposal.md), the source proposal behind the manager retirement; preserved as received.
- [Pause and in-flight transfer analysis, 2026-10-14](2026-10-14-pause-if-in-flight.md), scoped to the manager-era deployment.
- [Public testnet role holders, 2026-10-08](../../../../runs/wsteth-2.0/history/2026-10-08-role-holders.md).
- Live dust round-trip, 2026-08-19: [deposit evidence](../../../../runs/wsteth-2.0/history/deployments/chains.live-mantle/sepolia-mantle_sepolia/transfers/2026-08-19_deposit-leg/carriers.md) and [return evidence](../../../../runs/wsteth-2.0/history/deployments/chains.live-mantle/sepolia-mantle_sepolia/transfers/2026-08-19_return-leg/carriers.md). The obsolete procedure has been removed; these records retain the actual transactions and results.
