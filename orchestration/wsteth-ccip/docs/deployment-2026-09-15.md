# Public Sepolia ↔ Mantle Sepolia deployment — 2026-09-15

Fresh deployment of the updated upstream stack, including Lido core and Dual Governance, L2 governance and token, CCIP pools/hooks/POMs, and verifier contracts. No commits were made by the deployment agent.

## Results

- Steps 01–07 completed on the **public** networks, including protocol activation and governance handover.
- **431 live state checks passed**, including independent POM implementation/selector checks.
- **28 scenario tests passed, zero failures or skips**, using forks of the new public deployment. `CCV_LANE_REQUIRED=1` was set.
- Explorer source verification: **113 of 114 unique named deployed contracts verified**, including the full DG family. **SRLib remains unverified on Etherscan** after a bytecode-mismatch response and repeated “Other Exception” responses. Its local artifact, linked to the deployed library, matches on-chain runtime including metadata after substituting the compiler-defined library self-address immutable. Step 10 therefore remains nonzero; source verification is explicitly incomplete.
- Live DON token delivery was not tested in this deployment run.

## Addresses

| Contract | Sepolia (11155111) | Mantle Sepolia (5003) |
| --- | --- | --- |
| wstETH | `0x03EA7F67bDE498c989b22628b5DFCeeeb4cA9434` | `0x964EC0899Aa702485A2e9FCC3C4832b320319d38` |
| Token pool | `0x60dF5C229afF442dbe94C0E1a87c40036FCca242` | `0x7C4A71b282d7483EcEB858517d608354286605f1` |
| PoolOperationManager | `0x058b56D4AAaAEb1Fe6Dd192425D7672a7584fa0B` | `0x7075aF66b3A71ddeA8cB0ac19e96eEB119F1e8DF` |
| Governance holder | Agent `0x9BCaad922B43Ba56829098f2ba99dBC83c4a207B` | OpExec `0x0e1B2C8de13ba0620010f527cc3ab30D9CbdE047` |

L1 Dual Governance: `0x6321f5509730E072A904B7baec1be3609a5A1803`.
L1 Timelock: `0x0d0CA187bd0E6aB29fC0c888eC0b14bb6AB7e2D9`.

Some public addresses equal the earlier isolated-fork rehearsal addresses because both runs started from the same deployer nonces. Public transaction receipts identify this run independently; address equality alone is not evidence of deployment.

## Records and reproduction

- Live record: [config/chains.live-mantle-2026-09-15](../config/chains.live-mantle-2026-09-15/).
- Evidence: [deployments/live/sepolia-mantle_sepolia/2026-09-15](../deployments/live/sepolia-mantle_sepolia/2026-09-15/).
- Pre-deployment rehearsal backup: `deployments/forks/before-live-20260915-154448/`.
- Source base: commit `52ff77c`; exact revision and submodule pins are in `deployment-manifest.json`.
- Dedicated public RPC guarding proxies: localhost ports **28612** (Sepolia) and **28613** (Mantle Sepolia). Existing fork processes and `.env` defaults were preserved.

While those proxies are running:

```sh
RPC_SEPOLIA=http://127.0.0.1:28612 \
RPC_MANTLE_SEPOLIA=http://127.0.0.1:28613 \
L2_CHAIN=mantle_sepolia \
RECORD_DIR=config/chains.live-mantle-2026-09-15 \
CCV_LANE_REQUIRED=1 just test-leaf
```

## Verification tooling adjustments

- Add the legacy OpExec and OssifiableProxy imports to the token profile's source graph, allowing Forge to construct verification input. All three legacy deployment bytecodes were checked unchanged.
- Current Forge requires `--broadcast` with `--resume`. DG verification checks the matching deployment's complete successful receipts, transaction hashes, and empty pending set before allowing that mode.
- SRLib's initial Hardhat submission failed bytecode matching. Further submissions used the original compiler input, restricted output selection, and separate linker parameters; Etherscan returned “Other Exception”. The archive carries requests/results and the independent bytecode comparison. No deployment was repeated for this explorer issue.

## FPF assurance

Governing pattern: **B.3**, checks **CC-B3-1, CC-B3-2, CC-B3-6, CC-B3-12**.

Target claim: the fresh public deployment instantiates the rehearsed configuration and completes the intended handover. Use: acceptance of this testnet deployment's configuration. Public receipts and live state checks support deployment and wiring; fork scenarios support the exercised behaviors under their test conditions. Explorer source verification is a separate result. None of those results establishes live DON delivery.

Core's own upstream state-mate suite remains disabled because of the previously documented upstream schema drift; the 431 checks are this repository's leaf verification, not a complete audit of all Lido core internals. Reopen the assurance conclusion after upgrades, configuration/role changes, upstream transport changes, or a failed live delivery.

The explorer audit counts unique named contracts from core state plus CREATE records and named additional creations, so its 114-entry scope includes DG committees omitted by step 10’s narrower 108-entry audit. The unnamed EIP-1167 signalling-escrow clone is recorded separately and its runtime was checked against the canonical clone bytecode. Deployer nonces remained 1497 (Sepolia) and 187 (Mantle) throughout source verification, confirming that the guarded DG resume sent no additional transactions.
