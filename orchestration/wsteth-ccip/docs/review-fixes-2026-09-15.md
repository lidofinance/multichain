# Verification of the uncommitted-change review — 2026-09-15

Source: the 2026-09-15 uncommitted deployment review; findings and dispositions are recorded below.
Scope: the current uncommitted deployment changes; no commits or public transactions.

## FPF assurance scope

**Target claim:** the seven reported issues warrant the dispositions below, and the implemented changes handle their stated conditions in this checkout.
**Use:** assess these fixes before another deployment rehearsal.
**Governing pattern:** B.3, specifically CC-B3-1 (exact target/use), CC-B3-2 (basis, disposition and limits), CC-B3-6 (separate source and run evidence), and CC-B3-12 (unsupported uses and reopen conditions).

The source findings, fixture results, script simulations, and deployed-state checks are separate evidence. These results support the bounded claim above; they do not establish public deployment readiness, live DON delivery, or compatibility with arbitrary future upstream constructors. Reopen the conclusion when upstream contracts, artifact schemas, orchestration, state-mate, or deployment records change.

## Findings and disposition

| # | Verified condition | Resolution |
| --- | --- | --- |
| 1 | `all` put the patch-required preflight before patch application. | Confirmed. `patch-submodules` now precedes `preflight`; standalone preflight remains strict. |
| 2 | Missing legacy POM pins or L1 state caused raw `jq` failure. | Confirmed. Validate both state files and nonzero address fields, then explain how to restore trusted deployment pins. Older records still require migration; on-chain observations do not become expected values. |
| 3 | An idempotent step 04 could require a missing local broadcast. | Confirmed. Step 04 explicitly identifies skipped chains. Only those chains may warn and continue when their broadcast is absent; fresh deployments remain strict. Recorder errors have actionable diagnostics. Step 08 still requires independent pins. |
| 4 | Successful restoration left a temporary backup directory. | Confirmed in part. Remove that directory only after all restoration copies succeed. Keep original DG artifacts: their preservation is intentional. Do not add a blanket `clean` deletion of backup directories, because a failed restoration can leave the only recoverable copy there. |
| 5 | ABI generation ignored `STATE_MATE_DIR`. | Confirmed. Resolve YAML using that installation; verification passes its selected directory explicitly. |
| 6 | Artifact deployment loses compile-time constructor type checking. | Valid residual risk, not a current encoding defect. Assert all seven governance constructor values via getters, plus token proxy implementation/admin, metadata, decimals, contract version and token admin immediately after deployment simulation. Existing token EIP-712 checks remain in step 03. These assertions do not restore compile-time checking. |
| 7 | Proxy ABI lookup would fail if `proxyChecks` were used. | Confirmed latent gap. Bind implementation and proxy ABIs separately. Move token proxy checks to `proxyChecks`; retain their assertions. `ERC1967Proxy` has an empty maintained callable ABI because it exposes no view methods of its own. |

Also include `out-token` and `cache-token` in `just clean` for build-output symmetry.

## Validation

- `forge build`: passed.
- Governance and token deployment scripts: successful local EVM simulations, without RPC or broadcast, exercising the new getter assertions.
- `just test-leaf` on the existing isolated Sepolia/Mantle forks, with `CCV_LANE_REQUIRED=1`: **431 state checks; 28 scenario tests; zero failures or skips**. Includes the migrated proxy checks and independent UUPS checks.
- Temporary fixture checks: skipped/missing broadcasts, strict fresh-deploy failure, CREATE-derived pins, recorder idempotency, missing/legacy state diagnostics, external state-mate dependency resolution, separate proxy bindings, preservation and cleanup after simulated upstream artifact pruning.
- Configuration lint, changed shell/Node syntax, Solidity formatting, dependency-order inspection, and `git diff --check`: passed.

The build, simulation and temporary-fixture results above are historical run
summaries; their transient logs and fixture script are not repository artifacts.

Retained evidence:

- State-verification archive: `deployments/forks/sepolia-mantle_sepolia/2026-09-15_19-33-review/`

No full fresh deployment was repeated for this review pass. The earlier fresh rehearsal remains separate evidence; this pass exercised modified deployment scripts through local simulations and rechecked the existing fork deployment.
