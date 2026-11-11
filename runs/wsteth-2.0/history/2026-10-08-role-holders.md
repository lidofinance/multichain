# Fresh deployment role holders

> Historical manager-era deployment record, relocated on 2026-10-30. Absolute links below identify the original operator-local evidence, which is not included here; the target files have since changed. These observations do not state the current timelock deployment or current on-chain roles.

Prepared on 2026-10-08 for Sepolia, Base Sepolia, and Mantle Sepolia.

Public run: `public-node24-sepolia-base-mantle-20261008-v1`.
Rehearsal run: `rehearsal-node24-sepolia-base-mantle-20261008-v1`.

Live deployment and handover completed on 2026-10-08. Both pairs passed 34 post-deployment fork scenarios, 425 live state checks, and nine companion table checks each. The addresses below are from this public deployment. Explorer verification is complete: all 130 inventoried contract addresses have verified source (110 Sepolia, 10 Base Sepolia, 10 Mantle Sepolia).

## Live contract addresses

| Contract | Sepolia | Base Sepolia | Mantle Sepolia |
|---|---|---|---|
| DAO Agent / L2 governance executor | `0x689896d6cF38Fb2792b7378101cC92ac28555318` | `0xcC05f2eb27f592D3FFF3BCF40A1E86c015CDc7aB` | `0x5985CEafE043fcedD223dAEc66898315045DbcD8` |
| wstETH | `0xe896E220dc215b189812e222f9051ab4d77b8b97` | `0xcc5Ba15FA275e5407d328861C56DDCedEd1250c8` | `0x60153979cCFE02e4b2A0568561783702d6B4E2f3` |
| PoolOperationManager | `0xFAeeFed52Ea3Fc0E84D38Dfe72dD48D2eAA7E1AD` | `0x535618bb310546ca854f65D78332caf63cc8B124` | `0x76838dC712e32A665e50b80935E2f81F16C989bf` |
| Token pool | `0xAdc325d783816f3D3D5a5E5D633D415fc3C34e5B` | `0xeC7Cb3964EdcCa7B7925A7D159e033D1fC1DD0AB` | `0x6F9fA4514F4510e890b418eFE0Bc342C90f85348` |
| Advanced pool hooks | `0x4b457b56B682100a97B08D4311250082cA05B943` | `0x3bE031BAC33897d92076cD02f1643a717EdF60A6` | `0xB29850749398cd4430037FbD73d6b80C02592b0E` |
| CCV verifier | `0x1E9725A862e795D2DfdF3E5afc61De96AadBCDB6` | `0xfbAE3675db48b700dd7b0c9c21A147096780E862` | `0xF51b20576003F341C43387A36DE6Cb70242aaa48` |
| CCV resolver | `0x44760e792dbE3c9406C7d6754e88F64c9abc533F` | `0xBEcd653Bd319A0E3F3C23A19A67c3d3747D286ea` | `0xAAadb816fd56Fbb3E1248DF4B14DCFEB8C9BA8B6` |
| Token ProxyAdmin | — | `0x78Af344BF13669207327376dA47716CEb6908aB0` | `0xde42941C929b45E12293BD9847efa8c4c070Df26` |

Sepolia lockboxes:

- mantle_sepolia: `0x1780Fbd38abC622Fb0c6F8336649d1cC21A33C9a`
- base_sepolia: `0x1C0cB575181992F20Fbd1594818620426dED2Ca9`

Sepolia governance contracts:

- Voting: `0x42B5ffB062B17cDB79D8786E1bd04a363448Cd10`
- dualGovernance: `0x08Fb983152bBdfFf96dA3500D86e1F00E8a252c6`
- adminExecutor: `0xBB441F11EF5FC10Dd4e1a032fD712e6507faad3b`
- timelock: `0xf63C41a44b5BB2698e5EDE8925f641BA88a5Ad5a`
- resealManager: `0x5A61659246C2695F0f061fC29B8039ED38ebB167`

## Operational accounts and roles

The same operational accounts are configured on all three networks. POM means PoolOperationManager.

| Role / authority | Network | Address |
|---|---|---|
| Deployer | All three | `0xE528a15071E6C5aF0C1ed8e6Ec647Ce9EC510597` |
| POM proposer — configured as `chainlink_mcms` | All three | `0x1D72FbCcfC86C88E23771d6D58a8F1Cb77186d1d` |
| Emergency brakes: halt proposal queue and pause transfers | All three | `0x608056b8d596da5816146014E88DFfDECAF59DcD` |
| Additional holder of both halt/pause roles | All three | `0x1D72FbCcfC86C88E23771d6D58a8F1Cb77186d1d` |
| CCV verifier `allowlistAdmin` — retained after handover | All three | Deployer: `0xE528a15071E6C5aF0C1ed8e6Ec647Ce9EC510597` |
| Governance executor guardian — can cancel queued action sets | Base Sepolia + Mantle Sepolia | Deployer: `0xE528a15071E6C5aF0C1ed8e6Ec647Ce9EC510597` |
| POM `EXECUTOR_ROLE` | All three | No holders; execution of eligible proposals is permissionless |
| POM `PROPOSAL_QUEUE_RESTART_ROLE` / `CROSS_CHAIN_TRANSFERS_UNPAUSE_ROLE` | All three | No holders; DAO admin retains restart/unpause authority |
| Pool `rateLimitAdmin` / `feeAdmin` | All three | `0x0000000000000000000000000000000000000000` |

The `chainlink_mcms` address is a mnemonic-derived development account; the name does not mean this deployment creates a Chainlink multisig.

## Contract ownership and administration

| Contract / role | Sepolia holder | Base Sepolia holder | Mantle Sepolia holder |
|---|---|---|---|
| POM `DEFAULT_ADMIN_ROLE`, including upgrade authority | Sepolia DAO Agent | Base governance executor | Mantle governance executor |
| Token pool owner | Sepolia POM | Base POM | Mantle POM |
| Advanced pool hooks owner | Sepolia POM | Base POM | Mantle POM |
| CCV verifier and resolver owners | Sepolia POM | Base POM | Mantle POM |
| Lockbox owners | Sepolia POM, for both lockboxes | — | — |
| TokenAdminRegistry per-token administrator | Sepolia POM | Base POM | Mantle POM |
| wstETH `getCCIPAdmin()` | Sepolia DAO Agent | — | — |
| Bridged wstETH `DEFAULT_ADMIN_ROLE` | — | Base governance executor | Mantle governance executor |
| Bridged wstETH `MINTER_ROLE` and `BURNER_ROLE` | — | Base token pool | Mantle token pool |
| Token ProxyAdmin owner | — | Base governance executor | Mantle governance executor |
| L2 executor’s trusted Ethereum governance executor | — | Sepolia DAO Agent | Sepolia DAO Agent |
| CCV verifier fee recipient (`feeAggregator`) | Sepolia DAO Agent | Base governance executor | Mantle governance executor |

Each contract holder resolves to the public address listed above. Live state verification confirms these ownership and administration assignments.

## Sepolia Dual Governance actors

| Dual Governance role | Address |
|---|---|
| Reseal committee | `0x56f61794A722a55Dfe248abFE3f8D1cB741e3Fd6` |
| Emergency governance proposer | `0x7596742254E4c9383280d4E8609E667F81f8bc86` |
| Emergency activation committee | `0x7B3C72102598A3b6027F56C1b920c4076f11CCA7` |
| Emergency execution committee | `0xc8bD77bb45136eD4B67870feF0Fd05DD4A174B3A` |
| Tiebreaker subcommittee 1 member | `0x5a09cccE4f017642C948C3CB4c432DCb839d873c` |
| Tiebreaker subcommittee 2 member | `0x81545fAAB0b3D13cd163Df300bB7c4aE3b6395C2` |
| Tiebreaker subcommittee 3 member | `0x427e84566d6530E0d036542D17f32E15e16ef516` |

These seven accounts derive from `ACTORS_MNEMONIC[4..10]`.

## Guardian distinction

The configured `guardian` address is the emergency-brakes account, but the actual L2 governance-executor guardian is the deployer under the current deployment script.

## Control boundaries

- The DAO Agent (Sepolia) or governance executor (L2) administers POM, can grant/revoke roles, authorize upgrades, and invoke `directCall` on POM-owned contracts. `directCall` bypasses POM queue restrictions; it still requires the DAO governance execution path.
- Empty restart/unpause roles do not remove recovery authority: POM admits its default admin for those actions.
- The deployer retains the CCV allowlist-admin role and L2 executor guardian role. The latter permits cancellation; changing it requires an executor self-call through governance.
- Operational and Dual Governance committee accounts remain distinct mnemonic-derived actors. Existing Chainlink infrastructure and cross-domain message delivery are outside this deployment's ownership.
- Core's full state-mate check remains off as agreed. Fork scenarios establish tested behavior on forks; automatic public message delivery and independent CCV operation are not established by them.

## Sources

- [Live Sepolia configuration](/Users/arwer/projects/lido/multichain/runs/wsteth-2.0/workspaces/public-node24-sepolia-base-mantle-20261008-v1/config/chains/sepolia.json)
- [Live Base Sepolia configuration](/Users/arwer/projects/lido/multichain/runs/wsteth-2.0/workspaces/public-node24-sepolia-base-mantle-20261008-v1/config/chains/base_sepolia.json)
- [Live Mantle Sepolia configuration](/Users/arwer/projects/lido/multichain/runs/wsteth-2.0/workspaces/public-node24-sepolia-base-mantle-20261008-v1/config/chains/mantle_sepolia.json)
- [Ownership and role assertions](/Users/arwer/projects/lido/multichain/targets/wsteth-ccip-sepolia-mantle-dev/config/state-mate/wsteth.yaml)
- [Rehearsed DG parameters](/Users/arwer/projects/lido/multichain/runs/wsteth-2.0/workspaces/rehearsal-node24-sepolia-base-mantle-20261008-v1/state/deploy-params-testnet.toml)

Run workspace evidence is local and may not be available in a fresh clone.

[Deployment report](/Users/arwer/projects/lido/multichain/runs/wsteth-2.0/workspaces/public-node24-sepolia-base-mantle-20261008-v1/DEPLOYMENT_REPORT.md) · [Final explorer audit](/Users/arwer/projects/lido/multichain/runs/wsteth-2.0/workspaces/public-node24-sepolia-base-mantle-20261008-v1/evidence/explorer-audit.json)

Live transfer validation: 0.001 wstETH deposited from Sepolia to each L2; both destination executions and exact lock/mint deltas passed. Delivery was manually executed under the existing dummy-verifier policy. See [live deposit report](/Users/arwer/projects/lido/multichain/runs/wsteth-2.0/workspaces/public-node24-sepolia-base-mantle-20261008-v1/LIVE_DEPOSIT_REPORT.md).
