# Nethermind CCV switch on the public testnets

Governance ran on 18 November 2026 from 14:18 to 14:35 UTC across Sepolia (11155111), Mantle Sepolia (5003) and Base Sepolia (84532).

## Outcome

One DAO vote replaced the local test resolver with the Nethermind resolver in both directions of each wstETH lane. The hooks continued to require Chainlink. The change covered the resolver lists in `PausableAdvancedPoolHooks` and left the pools, tokens, lockboxes and resolver contracts in place.

Chainlink executors subsequently delivered four transfers with attestations from both providers. The deposit and withdrawal tables identify each message and the recipient’s balance increase.

## Required resolvers by lane

| Network | Hooks | Remote chain selector | Previous outbound and inbound lists | New outbound and inbound lists |
| --- | --- | --- | --- | --- |
| Sepolia | `0x93d9772F228F7c6C677A3Aca76CFec5636648dE9` | `8236463271206331221` (Mantle Sepolia) | `0xac4684527386209f289434E84879499dE45B71b9`, `0x8f3ee3c77D2B27c32306a89D367654F959Db223D` | `0x28ceF597339bb0B351ae4e62f73d762c9cC51D5c`, `0x8f3ee3c77D2B27c32306a89D367654F959Db223D` |
| Sepolia | `0x93d9772F228F7c6C677A3Aca76CFec5636648dE9` | `10344971235874465080` (Base Sepolia) | `0xac4684527386209f289434E84879499dE45B71b9`, `0x8f3ee3c77D2B27c32306a89D367654F959Db223D` | `0x28ceF597339bb0B351ae4e62f73d762c9cC51D5c`, `0x8f3ee3c77D2B27c32306a89D367654F959Db223D` |
| Mantle Sepolia | `0x174F4240C8605f2CCf5D9979F75595Cc7e6510a0` | `16015286601757825753` (Sepolia) | `0x1Ac7265B69402AFf447A1397D608f687C3F1b11F`, `0x8f3ee3c77D2B27c32306a89D367654F959Db223D` | `0x28ceF597339bb0B351ae4e62f73d762c9cC51D5c`, `0x8f3ee3c77D2B27c32306a89D367654F959Db223D` |
| Base Sepolia | `0x1fbb35e57c6937dd7EADD3f0749D494E53666D12` | `16015286601757825753` (Sepolia) | `0xAAC40536b69c72db395859248Afe30e74c447670`, `0x8f3ee3c77D2B27c32306a89D367654F959Db223D` | `0x28ceF597339bb0B351ae4e62f73d762c9cC51D5c`, `0x8f3ee3c77D2B27c32306a89D367654F959Db223D` |

Both threshold lists (`thresholdOutboundCCVs` and `thresholdInboundCCVs`) were empty before and after the switch. The operator read the new lists with `hooks.getAllCCVConfigs()` at Sepolia block 12162091, Mantle Sepolia block 46734026 and Base Sepolia block 60454286.

## Governance identifiers

| Item | Value |
| --- | --- |
| Aragon `voteId` | 3 |
| Dual Governance `proposalId` | 4 |
| `actionsSetId` in `OptimismBridgeExecutor` Mantle Sepolia | 1 |
| `actionsSetId` in `OptimismBridgeExecutor` Base Sepolia | 1 |
| Operation plan hash (`planHash`) | `0xf3917dff632109546990d89bea4e3018543a2010d703ccbbc24098c012813c1d` |
| Vote and proposal description | `Replace required CCVs: ccv-switch` |

## Governance transactions

The LDO holder `0x895B7d7020C2205FfA957385541616458Fe7911a` created the vote and voted. The deployer `0xE528a15071E6C5aF0C1ed8e6Ec647Ce9EC510597` signed the remaining five transactions. All seven succeeded.

| No. | Network | UTC | Block | Sender, nonce | Call | Hash | Gas |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Sepolia | 14:18:48 | 12161995 | `0x895B7d7020C2205FfA957385541616458Fe7911a`, 6 | TokenManager `0x074DCcD888C21246F2645Fb0FD999655c3143DD0` `.forward` → `Voting.newVote` | `0x1180e9d581765b1b4031f4a00a4c764af9f34c4f16808ecbbc983d245ec3174f` | 14742366 |
| 2 | Sepolia | 14:19:00 | 12161996 | `0x895B7d7020C2205FfA957385541616458Fe7911a`, 7 | Voting `0xD9081AF5eaCE7345F5620Bf423F70e0D73621DB5` `.vote(3, true, false)` | `0xb86992860ff2fb2901257bcbcbc904488e991bae58e41e2acfda6a938c330dde` | 286949 |
| 3 | Sepolia | 14:24:12 | 12162022 | `0xE528a15071E6C5aF0C1ed8e6Ec647Ce9EC510597`, 2095 | Voting `0xD9081AF5eaCE7345F5620Bf423F70e0D73621DB5` `.executeVote(3)` → `DualGovernance.submitProposal` | `0xaad6be376a03412302bf4430354bb5cf9f09ed58889064b58fd442e5047d60da` | 13885131 |
| 4 | Sepolia | 14:26:36 | 12162034 | `0xE528a15071E6C5aF0C1ed8e6Ec647Ce9EC510597`, 2096 | DualGovernance `0xB12Ca69a9B2a294463B51c6D562Bc3a431c4E4A5` `.scheduleProposal(4)` | `0x3b18c638ca391bd69ccc72d14e72489fb18f0d5f67f4b3af1ccfb3ff4d7f92a7` | 103373 |
| 5 | Sepolia | 14:29:12 | 12162047 | `0xE528a15071E6C5aF0C1ed8e6Ec647Ce9EC510597`, 2097 | EmergencyProtectedTimelock `0xD616e60431dC32DfC6b82F4C15ed38BC3DE4919C` `.execute(4)` | `0x6c949e471ce2af8a2b5225c9cdc240ae926a88b4b3e293d81cd963123ca2fc69` | 12080774 |
| 6 | Mantle Sepolia | 14:30:01 | 46733764 | `0xE528a15071E6C5aF0C1ed8e6Ec647Ce9EC510597`, 279 | OptimismBridgeExecutor `0x89968fe8cceA229F5564A83431f89ffaBbE62Df5` `.execute(1)` | `0x4e055ed78e46a66c8eb8effd9a440e0d53787b84d798836157cc2f7772e15e5f` | 192652 |
| 7 | Base Sepolia | 14:34:54 | 60453126 | `0xE528a15071E6C5aF0C1ed8e6Ec647Ce9EC510597`, 92 | OptimismBridgeExecutor `0x95b032D4F90a79E9eeCDdDAEcfb3E58a19cC9480` `.execute(1)` | `0x3da6b671a7ce287f57b1e68881f5037e3fa54934d261f7a89914744ea6de2409` | 192652 |

Transaction 5 updated the Sepolia hooks and sent one governance message to each L2. Transactions 6 and 7 executed the queued updates on Mantle Sepolia and Base Sepolia respectively.

## Governance message delivery

In transaction 5 the Agent `0x25C9d019102BB4b79F1D12D79309E6eE3145f528` sent both messages through the canonical OP Stack bridges with `minGasLimit` set to 5000000. The networks relayed them to the L2 executors.

| | Mantle Sepolia | Base Sepolia |
| --- | --- | --- |
| `L1CrossDomainMessenger` on Sepolia | `0x37dAC5312e31Adb8BB0802Fc72Ca84DA5cDfcb4c` | `0xC34855F4De64F1840e5686e64278da901e261f20` |
| `L2CrossDomainMessenger` | `0x4200000000000000000000000000000000000007` | `0x4200000000000000000000000000000000000007` |
| Recipient (`OptimismBridgeExecutor`) | `0x89968fe8cceA229F5564A83431f89ffaBbE62Df5` | `0x95b032D4F90a79E9eeCDdDAEcfb3E58a19cC9480` |
| Message hash in `successfulMessages` | `0x903e1ee1d8cb1f5b76a2bac103eaab54e336b42724c607c644ae5e7e8d6cf98f` | `0xc94198d7cf74f122a7e32c154dc395515962acb4d2857987ed5d5f749f8b82df` |
| Relay transaction (`ActionsSetQueued`, id 1) | `0xd656427998fb47dbf04aefc91a19d0e2d016e1636984a6df2ac53b21950fe6ef` | `0x13a11e3401e6a480d6d7a1e047cb2a139cc07b7fe0eb32fbfbe0c3b65cbfd86c` |
| Relay block and time (UTC) | 46733761, 14:29:55 | 60452996, 14:34:28 |
| Relay time | 43 s | 5 min 16 s |
| Execution transaction (`ActionsSetExecuted`, id 1) | № 6 | № 7 |

## Hooks updates

The Sepolia Agent `0x25C9d019102BB4b79F1D12D79309E6eE3145f528` and each L2’s `OptimismBridgeExecutor` called their local timelocks.

| Network | `LidoTimelock.bypasserExecuteBatch` | → `hooks.applyCCVConfigUpdates` |
| --- | --- | --- |
| Sepolia | `0x898A55EB873eE5a3A8F675Da72A237Ea58179930` | `0x93d9772F228F7c6C677A3Aca76CFec5636648dE9`, two lanes |
| Mantle Sepolia | `0x5FC256aBed9C3c425C1AD281E3F8a1B7F88279d3` | `0x174F4240C8605f2CCf5D9979F75595Cc7e6510a0`, one lane |
| Base Sepolia | `0x0633DE68D5007A220E0201132FE16625B5cf60e2` | `0x1fbb35e57c6937dd7EADD3f0749D494E53666D12`, one lane |

The new outbound and inbound lists above give the resolver arguments for each lane.

## Nethermind deployment

Nethermind supplied the following deployment details.

| Item | Value |
| --- | --- |
| Resolver (`VersionedVerifierResolver`), same address on all three chains | `0x28ceF597339bb0B351ae4e62f73d762c9cC51D5c` |
| Verifier on Sepolia and Mantle Sepolia | `0x3FD15Ac39a06850c06563eAc511968229111635C` |
| Verifier on Base Sepolia | `0xF80D2Ccf5F7180F6D837B3EB774e5eC59a83Db32` |
| Version tag | `0x00010002` |
| Owner (EOA) | `0x36243b8B92b1a0F6C92a69a32aE1F8dC183788A5` |
| Committee, 2-of-2 | `0x2fb64e058fdf73da1b39063dc64f9f0863005b67`, `0xaee7d7e9748d8a2ee598a4642634b9ec97a64f53` |
| Storage locations | `https://lido-ccv-cell-0.aws.staging-nethermind.xyz`, `https://lido-ccv-cell-0.ovh.staging-nethermind.xyz` |

Before the vote, `precheck` read each resolver and confirmed that both the inbound tag `0x00010002` and each outbound lane selected the verifier listed above.

## Router fee quotes after execution

The operator called `router.getFee` for a probe transfer. Each value is in the smallest unit of the source chain’s native token.

| Route | wei |
| --- | --- |
| Sepolia → Mantle Sepolia | 206692236939481 |
| Sepolia → Base Sepolia | 340762877116440 |
| Mantle Sepolia → Sepolia | 928849748077887336 |
| Base Sepolia → Sepolia | 897815283601852 |

## Run artifacts

- The operator ran `just wsteth ccv-switch run` with one vote covering all three chains.
- Run `public-20261104-ccv-switch-20261118` used deployment record `runs/wsteth-2.0/deployments/public-20261104-maintenance-20261105/import-record`.
- Public RPC wrapper: `runs/wsteth-2.0/deployments/public-20261104-ccv-switch-20261118/operator.cjs`.
- Local journal with the plan, policy snapshots and report: `runs/wsteth-2.0/workspaces/public-20261104-ccv-switch-20261118/state/ccv-switch/ccv-switch/`.
- Desired policy: `targets/wsteth-ccip-sepolia-mantle-dev/config/ccv-policy.nethermind.json`.

The first run stopped after transaction 6 with `Expected one matching L2 action set` on Base Sepolia. The retry reused the journal and submitted only transaction 7. An RPC delay between reporting delivery and serving `ActionsSetQueued` could explain the interruption. The record does not establish its cause.

## Post-execution checks

The operator read the required resolvers on all three chains and matched them to the desired policy. The before and after reads also agreed on hooks and resolver ownership, the pool’s hooks and token, the registered pool, pause state, disabled lanes and threshold amount. Missing-proof rejection was tested separately on replay forks. [Fork results](NETHERMIND-CCV-FORK-TEST-PLAN.md#results-of-2026-11-18)

## Deposits from Sepolia

The deployer `0xE528a15071E6C5aF0C1ed8e6Ec647Ce9EC510597` sent 0.001 wstETH to its own address on each L2 using default finality (`FINALIZED`). Chainlink executor `0x66f9E0738a4a6fe54aE62DEd00Ca1F72bDecc092` delivered both messages.

| | Mantle Sepolia | Base Sepolia |
| --- | --- | --- |
| `messageId` | `0x9c2c261400585b2fd4d1270c4d82c997cbcc15c0993d45d76465ce544d064bed` | `0x3cd3382210db58904dec6a0b42a8446ad033663caed5716b4b37ddb085d38409` |
| Sequence number | 16 | 839 |
| `ccipSend` transaction on Sepolia | `0x9794aa9f6384ca176c3577d83a638bf20e325be6643749397d783d1fbeb2b9fb` | `0x5b668a17d34e16290e720067caacade6823dfc7bcf09e1070beec499474ccb70` |
| Source block and time (UTC) | 12162124, 14:45:12 | 12162125, 14:45:24 |
| Total fee, wei | 209837404367996 | 345948153147235 |
| Nethermind share, wei | 56712811991350 | 56712811991350 |
| OnRamp on Sepolia | `0x8dcf17f298c881A547D91ca4aA3C2AD7568C6777` | `0x8dcf17f298c881A547D91ca4aA3C2AD7568C6777` |
| OffRamp on destination | `0xeD8abf93091D3F1Bfb6Ce14E9413F02a358A83E3` | `0xa137536A3BFd81aD6f090981268b8C2818451d41` |
| Attestation Nethermind (tag `0x00010002`), time (UTC) | 15:04:02 | 15:04:02 |
| Attestation Chainlink (tag `0xe9a05a20`), time (UTC) | 15:04:03 | 15:04:03 |
| Execution transaction on destination | `0xa0bbd8db2e438eda96901f0e62ddbb0709a40d9bfb57d3fa3456d86831c1aca1` | `0xd595025aa406993b69401d8cbb4f96715f7bc02fb25a4827d9710938872de491` |
| Execution block and time (UTC) | 46734791, 15:04:15 | 60461885, 15:04:05 |
| Delivery time | 19 min 03 s | 18 min 41 s |
| `OffRamp.getExecutionState` | 2 (SUCCESS) | 2 (SUCCESS) |
| Recipient balance increase, wstETH base units | 1000000000000000 | 1000000000000000 |

Before sending, the deployer staked 0.002 ETH (`0x3468c1a6fd2797eae1955e63d05c4dff3692e8fa3ba4211b75a34fcdadb29610`) and approved the router (`0x396889073b0e1e7caa5ca91639da8c32596409e459522ded2db96fb2dce77231`).

The block and transaction details come from chain events and reads. Status and attestations come from the CCIP API at `api.ccip.chain.link`. The local observation log is `runs/wsteth-2.0/deployments/public-20261104-ccv-switch-20261118/deposits-01.json`.

## Withdrawals to Sepolia

The deployer `0xE528a15071E6C5aF0C1ed8e6Ec647Ce9EC510597` sent 0.0004 wstETH from each L2 to its own Sepolia address using default finality. Chainlink executors delivered both messages through Sepolia OffRamp `0xc6A246A9AcdAaE651708706494720F79C3E5d0A1`. The deployer’s remaining balance was 0.0016 wstETH on each L2.

| | Mantle Sepolia → Sepolia | Base Sepolia → Sepolia |
| --- | --- | --- |
| `messageId` | `0x9b02d36a549585d75191fcb29b188d2f781f02cc004e85fde281f834cf08bba8` | `0x9849c27fe23608724d670dc78c3b95cb7983bdea44bb88a68e44ca57493a5376` |
| Sequence number | 6 | 2109 |
| Router approval transaction | `0x6a0feda2d473896d178a3e4c576166502ec2231a8b964a99e1b860eda327ac15` | `0x293ee2ae5b7c255151318d901c3adb0f9e069b97bc2a6a8ede2b56e49064eea9` |
| `ccipSend` transaction | `0xd31a113f0528354d12da62a866a4e2ebd61d7b9119c49d92f5f5852c2c14320f` | `0xa591c4d05a00acd2b23fb72f0ef434c6a87e1fc562e94b69bab4572c613e6113` |
| Source block and time (UTC) | 46735535, 15:29:03 | 60469406, 15:29:10 |
| Total fee, wei | 928849748077887336 (MNT) | 904627722695186 (ETH) |
| Nethermind share, wei | 258013818910524260 | 56188057310260 |
| L2 OnRamp | `0xCAC5826F878b3BfEE32404619C762b33ae199c1b` | `0xA33b221A8427739c76f631a995ca60544bEdD632` |
| Attestation Nethermind (tag `0x00010002`), time (UTC) | 15:50:55 | 15:49:43 |
| Attestation Chainlink (tag `0xe9a05a20`), time (UTC) | 15:51:28 | 15:50:01 |
| Executor | `0x66f9E0738a4a6fe54aE62DEd00Ca1F72bDecc092` | `0x70462479B74d49Adf6443aA1B799768bE74496a4` |
| Execution transaction on Sepolia | `0x4c4aa9589e227a2bc76d089cb8feea08712fdd0c8053e47e9045c5fe21e7c42e` | `0xfc55ef482c7aeaacd974fadadd062625b66cc31b360946a246e02437803e9694` |
| Execution block and time (UTC) | 12162450, 15:51:36 | 12162443, 15:50:12 |
| Delivery time | 22 min 33 s | 21 min 02 s |
| `OffRamp.getExecutionState` | 2 (SUCCESS) | 2 (SUCCESS) |
| Recipient balance increase, wstETH base units | 400000000000000 | 400000000000000 |

Local observation log: `runs/wsteth-2.0/deployments/public-20261104-ccv-switch-20261118/withdrawals-01.json`.
