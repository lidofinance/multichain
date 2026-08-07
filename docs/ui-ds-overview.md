# Chainlink CCIP Direct Staking UI Overview

Last checked: 5 August 2026.

## Summary

| UI | Wallet transaction target | Instant path | Slow path | Verification | Public comms |
| --- | --- | --- | --- | --- | --- |
| Interport | Lido `CustomSender` | `fastStake` | `slowStake` | Verified in current frontend bundle | [Lido launch (2024)](https://blog.lido.fi/lido-staking-goes-cross-chain-via-chainlink-ccip/)<br>[Lido Linea launch (2025)](https://blog.lido.fi/direct-staking-on-linea-powered-by-chainlink/)<br>[Interport documentation](https://docs.interport.fi/products/bridge/direct-staking)<br>[Interport UI](https://app.interport.fi/direct-staking/lido/8453/ETH) |
| XSwap | Lido `CustomSender` | `fastStakeReferral` | `slowStake` | Verified in current frontend bundle | [Lido launch (2024)](https://blog.lido.fi/lido-staking-goes-cross-chain-via-chainlink-ccip/)<br>[Lido Linea launch (2025)](https://blog.lido.fi/direct-staking-on-linea-powered-by-chainlink/)<br>[XSwap documentation](https://docs.xswap.link/xswap/introduction/direct-staking)<br>[XSwap UI](https://xswap.link/direct-staking) |
| Jumper / LI.FI | LI.FI Diamond | Route-dependent exchange calls; sampled Base, Optimism, Arbitrum, and Linea routes used DEX liquidity | No direct slow-stake call observed | Announcement confirms the integration architecture; sampled calldata did not call `CustomSender` | [LI.FI announcement (2026)](https://li.fi/knowledge-hub/wsteth-is-now-one-click-away-heres-what-made-it-possible)<br>[Jumper UI](https://jumper.exchange/) |
| OpenOcean | Historically Lido `CustomSender` | Historically `fastStake` | Historically `slowStake` | Historical integration; absent from current frontend bundle | [Lido launch (2024)](https://blog.lido.fi/lido-staking-goes-cross-chain-via-chainlink-ccip/)<br>[Lido Linea launch (2025)](https://blog.lido.fi/direct-staking-on-linea-powered-by-chainlink/)<br>[OpenOcean staking documentation](https://docs.openocean.finance/products/ethereum-liquid-staking/get-started-with-eth-liquid-staking)<br>[OpenOcean UI](https://app.openocean.finance/staking) |

No fifth publicly identifiable UI was found. This conclusion is based on official announcements, searches for the deployed addresses and method signatures, inspection of published frontend bundles, and an on-chain caller audit described below.

## Direct Staking contracts

### CustomSender proxies

| Network | Chain ID | Address |
| --- | ---: | --- |
| Base | 8453 | [`0x328de900860816d29D1367F6903a24D8ed40C997`](https://basescan.org/address/0x328de900860816d29D1367F6903a24D8ed40C997) |
| Optimism | 10 | [`0x328de900860816d29D1367F6903a24D8ed40C997`](https://optimistic.etherscan.io/address/0x328de900860816d29D1367F6903a24D8ed40C997) |
| Arbitrum | 42161 | [`0x72229141D4B016682d3618ECe47c046f30Da4AD1`](https://arbiscan.io/address/0x72229141D4B016682d3618ECe47c046f30Da4AD1) |
| Linea | 59144 | [`0x328de900860816d29D1367F6903a24D8ed40C997`](https://lineascan.build/address/0x328de900860816d29D1367F6903a24D8ed40C997) |

The current Interport and XSwap bundles both map Linea to this `CustomSender`, the oracle pool `0x6F357d53d6bE3238180316BA5F8f11467e164588`, and the price oracle `0x301cBCDA894c932E9EDa3Cf8878f78304e69E367`. The current Chainlink quickstart documents Base, Optimism, and Arbitrum, but not Linea.

### Write methods

| Method | Selector |
| --- | --- |
| `fastStake(address,uint256,uint256)` | `0x4ac8cdf2` |
| `fastStakeReferral(address,uint256,uint256,address)` | `0xf380b676` |
| `slowStake(uint64,address,uint256,bytes,bytes)` | `0x04a8f1bb` |

For ERC-20 inputs, the UI first calls `approve(CustomSender, amount)`. For native ETH, the amount is supplied as `msg.value`. The slow path may add CCIP and return-bridge fees to `msg.value`.

### Fast-staking oracle pools

| Network | Address |
| --- | --- |
| Base / Optimism / Linea | `0x6F357d53d6bE3238180316BA5F8f11467e164588` |
| Arbitrum | `0x9c27c304cFdf0D9177002ff186A4aE0A5489Aace` |

The UI transaction targets `CustomSender`; the proxy interacts with the oracle pool internally. Frontends also use read-only calls such as CCIP router `getFee(...)` and oracle-pool getters when building quotes.

## UI-specific behavior

### Interport

- **Instant Staking:** calls `CustomSender.fastStake(...)`.
- **Regular Staking:** calls `CustomSender.slowStake(...)`.
- The arguments and execution calls are present in the current published application bundle.

### XSwap

- **Fast mode:** calls `CustomSender.fastStakeReferral(...)` for Lido routes.
- **Slow mode:** calls `CustomSender.slowStake(...)`.
- Its ABI contains plain `fastStake(...)`, but the current Lido execution branch uses the referral-aware method.

### Jumper / LI.FI

The wallet sends the sampled routes to the LI.FI Diamond deployed on that chain:

| Network | LI.FI Diamond |
| --- | --- |
| Base | `0x1231DEB6f5749EF6cE6943a275A1D3E7486F4EaE` |
| Optimism | `0x1231DEB6f5749EF6cE6943a275A1D3E7486F4EaE` |
| Arbitrum | `0x1231DEB6f5749EF6cE6943a275A1D3E7486F4EaE` |
| Linea | `0xde1e598b81620773454588b85d6b5d4eec32573e` |

A sampled Arbitrum ETH-to-wstETH quote used:

```solidity
swapTokensMultipleV3NativeToERC20(
    bytes32 transactionId,
    string integrator,
    string referrer,
    address receiver,
    uint256 minAmount,
    SwapData[] swaps
)
```

Selector: `0x736eac0b`.

The traced Arbitrum call path was LI.FI Diamond -> 1inch `swap(...)` -> WETH `deposit()` -> Uniswap V3 pool `swap(...)`. Samples at 0.01 ETH and 100 ETH did not call Lido `CustomSender`.

Fresh Base and Optimism quotes were checked at the same two amounts. All four returned the same top-level selector and were decoded as two-step LI.FI swaps: integrator-fee collection followed by an exchange call.

| Network | Amounts checked | Selected tool | Exchange `callTo` | Exchange `approveTo` | Direct Staking target present |
| --- | --- | --- | --- | --- | --- |
| Base | 0.01 ETH, 100 ETH | Fly | `0x20F6ee51340aDEed01A59B0e65cB3703f3dc860c` | Same as `callTo` | No |
| Optimism | 0.01 ETH, 100 ETH | OKX | `0xDd5E9B947c99Aa60bab00ca4631Dce63b49983E7` | `0x68D6B739D2020067D1e2F713b999dA97E4d54812` | No |

In each Base and Optimism sample, neither `CustomSender` `0x328de900860816d29D1367F6903a24D8ed40C997` nor oracle pool `0x6F357d53d6bE3238180316BA5F8f11467e164588` appeared in the returned calldata.

A current 0.01 ETH Linea quote used the same top-level selector on the Linea LI.FI Diamond. Its selected route tool was `nordstern`, and the embedded downstream call/approval target was `0x2fF506ed9729580EF8Bf04429614beB1baE5F76D`. Neither the returned calldata nor its decoded targets contained the Linea `CustomSender`.

The LI.FI announcement states that its Custom Quote API is built on the Chainlink Direct Staking suite and that Chainlink Automation rebalances Fast Staking pools. This is evidence of the published integration architecture, not evidence that every user route calls `CustomSender`. Pool rebalancing is separate infrastructure work and must not be inferred as an internal call of the sampled user transaction.

Therefore, Jumper supports wstETH acquisition through route selection, but whether an individual route targets `CustomSender` can be established only from that quote's returned calldata or transaction trace. The sampled Base, Optimism, Arbitrum, and Linea routes did not ultimately target it; this does not prove that no future LI.FI route can do so.

### OpenOcean

Lido's launch announcement named OpenOcean as a Direct Staking frontend. The historical integration was consistent with the then-available `fastStake(...)` and `slowStake(...)` entrypoints. The current OpenOcean application bundle contains neither these method names nor the `CustomSender` addresses, so this integration should be treated as historical unless reintroduced.

## Completeness audit

### Evidence and claim boundaries

The conclusions above use the following evidence boundaries:

| Evidence | Supports | Does not by itself prove |
| --- | --- | --- |
| Official announcements and documentation | A publicly described integration, intended architecture, and named UI availability at publication time | The target and downstream calls of a particular current transaction |
| Current frontend bundles | Configured chain addresses, ABIs, and execution branches present in that bundle | That every possible route executes that branch |
| Returned quote calldata and decoded call traces | The target, selector, and downstream calls of the sampled route | Universal behavior across amounts, times, chains, or future routing state |
| Indexed `CustomSender` calls | Calls observed by the named indexer within the audited networks and window | Complete attribution of every caller to a public UI |

Accordingly, claims of UI support, configured capability, sampled execution, and infrastructure rebalancing remain separate. A public communication is retained as provenance for the integration claim; it is not promoted into runtime-call evidence.

### On-chain caller audit

The audit paginated all indexed calls to the Base, Optimism, and Arbitrum proxies available from the public Blockscout APIs on 5 August 2026. It classified 318 staking calls:

| Method | Calls |
| --- | ---: |
| `fastStake` | 164 |
| `fastStakeReferral` | 117 |
| `slowStake` | 37 |
| **Total** | **318** |

The `fastStakeReferral` calls contained the following nonzero referral identifiers:

| Referral | Calls | Attribution |
| --- | ---: | --- |
| `0x8ebD04b2fbA00418Be00329146837dcE51F02c00` | 13 | Publicly labelled **XSwap: Deployer** |
| `0x7bad1B0fC06EEC11EaE08Ce0D3f143Bf52955066` | 98 | Active partner identifier; no reliable public label found |
| `0x2Ae947aDC044091EE1b8D4FB8262308C6A4F34E0` | 5 | Five tiny Base transactions over two days; sender equalled referral, indicating self-testing rather than evidence of a public UI |

One additional call used the zero address as its referral. The apparent contract callers were smart-wallet or account-abstraction accounts; none could be identified as an additional branded frontend router. Linea search results exposed launch/test calls, while Lido's Linea announcement names only XSwap, OpenOcean, and Interport.

## Sources

- [Chainlink CCIP Direct Staking integrator guide](https://docs.chain.link/quickstarts/ccip-direct-staking)
- [Lido announcement (2024): Lido Staking Goes Cross-Chain via Chainlink CCIP](https://blog.lido.fi/lido-staking-goes-cross-chain-via-chainlink-ccip/)
- [Lido announcement (2025): Direct Staking on Linea](https://blog.lido.fi/direct-staking-on-linea-powered-by-chainlink/)
- [LI.FI announcement (2026): wstETH Is Now One Click Away](https://li.fi/knowledge-hub/wsteth-is-now-one-click-away-heres-what-made-it-possible)
- [LI.FI quote API specification](https://docs.li.fi/agents/reference/endpoint-specs)
- [LI.FI smart-contract addresses](https://docs.li.fi/introduction/lifi-architecture/smart-contract-addresses)
- [Interport Direct Staking UI](https://app.interport.fi/direct-staking/lido/8453/ETH)
- [Interport Direct Staking documentation](https://docs.interport.fi/products/bridge/direct-staking)
- [XSwap Direct Staking documentation](https://docs.xswap.link/xswap/introduction/direct-staking)
- [OpenOcean liquid-staking documentation](https://docs.openocean.finance/products/ethereum-liquid-staking/get-started-with-eth-liquid-staking)
- [`CustomSender` transactions on Base](https://base.blockscout.com/address/0x328de900860816d29D1367F6903a24D8ed40C997?tab=txs)
- [`CustomSender` transactions on Optimism](https://optimistic.etherscan.io/txs?a=0x328de900860816d29d1367f6903a24d8ed40c997)
- [`CustomSender` transactions on Arbitrum](https://arbiscan.io/txs?a=0x72229141D4B016682d3618ECe47c046f30Da4AD1)
- [Linea `fastStake` transaction example](https://lineascan.build/tx/0x7a55e319463d16603ae9ec0203fbcdc4b4c2770f80bf342f8bcb974117d70d17)
- [XSwap referral-address label](https://etherscan.io/address/0x8ebd04b2fba00418be00329146837dce51f02c00)
