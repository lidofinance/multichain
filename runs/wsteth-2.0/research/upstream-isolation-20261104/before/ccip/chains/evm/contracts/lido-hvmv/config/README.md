# Configuration Schema

This document describes the JSON configuration schema for the Lido HVMV (Hyperlane Validator Multi-Version) CCIP token pool deployment.

## Overview

The deployment system uses a **config-driven approach** where you define minimal JSON configuration files and the scripts:
1. Auto-fetch CCIP infrastructure addresses from the Chainlink API
2. Deploy all required contracts
3. Configure everything according to the config
4. Save deployed addresses back to the JSON file

The result is a complete deployment record that can be committed to version control.

## File Structure

```
config/
├── default_config.json       # Shared settings (governance, rate limits, etc.)
├── README.md                 # This file
└── chains/
    ├── _template_existing_token.json  # Template for a chain where the token already exists (migration)
    ├── _template_new_token.json       # Template for a new chain where 1_Deploy deploys the token
    ├── ethereum.json         # Ethereum Mainnet configuration
    ├── base.json             # Base Mainnet configuration
    ├── sepolia.json          # Sepolia testnet configuration
    └── base_sepolia.json     # Base Sepolia testnet configuration
```

## Configuration Loading

The deployment scripts load configuration via environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `DEFAULT_CONFIG` | Path to default config JSON | `./contracts/lido-hvmv/config/default_config.json` |
| `CHAIN_CONFIG` | Path to chain config JSON | **Required** |

The Solidity `ConfigParser.sol` loads shared governance and selector settings from the default config
and chain-specific deployment settings from the chain config.

---

## Default Configuration Schema (`default_config.json`)

The default configuration defines settings that apply across all chains.

### `governance`

Timelock settings for the LidoTimelock.

| Field | Type | Description |
|-------|------|-------------|
| `min_delay_seconds` | uint40 | Minimum seconds between scheduling a proposal and executing it |
| `expiry_period_seconds` | uint120 | Seconds after scheduling at which an unexecuted proposal expires; must exceed `min_delay_seconds` |

Proposals stay executable until they are executed, cancelled, expired or invalidated by a queue halt. A proposal
scheduled with a delay at or above the expiry period can never execute.

**Contract mapping:**
- Contract: `LidoTimelock.sol` (inherits `RBACTimelock.sol`)
- Constructor: `minDelay`, `expiryPeriod`; the admin changes them later with `updateDelay(uint256)` and
  `setExpiryPeriod(uint120)`

**Default values:**
```json
{
  "min_delay_seconds": 259200,
  "expiry_period_seconds": 1209600
}
```
- `min_delay_seconds`: 259200 = 3 days
- `expiry_period_seconds`: 1209600 = 14 days

---

### `blocked_selectors`

Function selectors that cannot be proposed. Blocking is checked when a proposal is scheduled, so it does not affect
already queued proposals or the DAO's `bypasserExecuteBatch` path. A selector is blocked across all targets.

| Field | Type | Description |
|-------|------|-------------|
| `function` | string | Human-readable function signature |
| `selector` | bytes4 | 4-byte function selector (hex) |
| `reason` | string | Documentation for why this is blocked |

**Contract mapping:**
- Contract: `LidoTimelock.sol` (inherits `RBACTimelock.sol`)
- Function: `blockFunctionSelector(bytes4 selector)`, called by `2_Configure` for each entry. The admin can unblock
  with `unblockFunctionSelector(selector)`.

**Example:**
```json
{
  "function": "transferOwnership(address)",
  "selector": "0xf2fde38b",
  "reason": "Ownership changes only by the Lido DAO through the timelock bypass"
}
```

The defaults block `transferOwnership(address)` (`0xf2fde38b`), `transferAdminRole(address,address)` (`0xddadfa8e`),
`upgradeToAndCall(address,bytes)` (`0x4f1ef286`),
`grantRole(bytes32,address)` (`0x2f2ff15d`) and `revokeRole(bytes32,address)` (`0xd547741f`), so proposals cannot move
ownership of the contracts the timelock owns, transfer its TAR administrator role, upgrade a proxy target, or change
roles such as the hooks' pause and unpause roles. The DAO makes those changes through `bypasserExecuteBatch`.

This enforces PRD requirement R3: DAO Retains Ultimate Control.

---

### `rate_limiter_defaults`

Token bucket rate limiter configurations for cross-chain transfers.

Defaults applied to every lane, pending per-chain values from the Lido rate limit framework
(`docs/rate_limit_framework.md`). Outbound is lower than inbound on purpose (see `inbound` below).

**Formula:** `rate = capacity / 86400` (tokens per second to refill in 24 hours)

#### `outbound`

Rate limiter for **outbound** transfers (this chain -> remote chain), consumed by the pool's `lockOrBurn`.

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | bool | Whether rate limiting is enabled |
| `capacity` | string | Maximum tokens in bucket (wei) - the hard cap |
| `rate` | string | Tokens per second refill rate (wei) |

Applied by `2_Configure` through `TokenPool.applyChainUpdates` (`outboundRateLimiterConfig`), same values for every lane.

**Default (330 wstETH):**
```json
{
  "enabled": true,
  "capacity": "330000000000000000000",
  "rate": "3819444444444444"
}
```

#### `inbound`

Rate limiter for **inbound** transfers (remote chain -> this chain), consumed by the pool's `releaseOrMint`.

Must be higher than the remote chain's outbound limit: messages sent over time can be executed in a burst (see the
rate-limiting note in Chainlink's `TokenPool.sol`). Applied through `applyChainUpdates` (`inboundRateLimiterConfig`).

**Default (500 wstETH):**
```json
{
  "enabled": true,
  "capacity": "500000000000000000000",
  "rate": "5787037037037037"
}
```

---

## Chain Configuration Schema (`chains/{chain_name}.json`)

Chain-specific configuration for each deployment target.

### `chain`

Basic chain identification.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `chain_id` | uint256 | **Yes** | EVM chain ID (used to fetch CCIP addresses) |
| `chain_name` | string | **Yes** | Name of this config file (`chains/<chain_name>.json`); remote lanes refer to it |
| `pool_type` | string | **Yes** | Pool type: `"BurnMint"` or `"SiloedLockRelease"` |

**Pool Types:**
- `BurnMint` - Burns tokens on source chain, mints on destination. No lock boxes.
- `SiloedLockRelease` - Locks tokens in chain-specific lock boxes, releases on destination.

---

### `addresses`

Contract addresses on this chain. CCIP infrastructure is fetched from the Chainlink API into `.ccip`.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `token` | address | **Yes** | The ERC20 token to bridge (e.g., wstETH). `address(0)` deploys a new token (BurnMint pools only), see `token_deployment` |

### `token_deployment`

Required only when `addresses.token` is `address(0)`. `1_Deploy` then deploys Lido's wstETH token (`ERC20BridgedPermit`) behind a
`TransparentUpgradeableProxy` and records `token`, `token_impl` and `token_proxy_admin` under `deployed`;
`addresses.token` stays `address(0)`. The token belongs to the Lido DAO, never the timelock: the DAO owns the ProxyAdmin
from deployment, `2_Configure` grants the pool mint/burn, and `3_SetPoolAndTransferOwnership` grants the DAO the
admin role, then the deployer renounces it.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | **Yes** | Token name |
| `symbol` | string | **Yes** | Token symbol |
| `decimals` | uint8 | **Yes** | Token decimals |
| `version` | string | **Yes** | EIP-712 signing domain version (`"2"`) |

---

### `governance_addresses`

Governance addresses `lido_dao_agent`, `emergency_brakes`, and `chainlink_mcms` must be nonzero, including on testnets; the config parser rejects zero values.

| Field | Type | Description |
|-------|------|-------------|
| `lido_dao_agent` | address | Lido DAO Agent - receives the timelock's ADMIN_ROLE |
| `emergency_brakes` | address | Emergency Brakes multisig - receives the timelock's CANCELLER_ROLE and PROPOSAL_QUEUE_HALT_ROLE, and the hooks' CROSS_CHAIN_TRANSFERS_PAUSE_ROLE |
| `chainlink_mcms` | address | Chainlink MCMS - receives PROPOSER_ROLE and CANCELLER_ROLE |

---

### `remote_lanes`

Array of remote chains this pool can bridge to/from. Each entry configures one lane. The remote chain's selector,
token and pool are read from its own config, `chains/<remote_chain_name>.json`, once it has been deployed.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `remote_chain_name` | string | **Yes** | `chain.chain_name` of the remote chain's config |
| `is_siloed` | bool | **Yes** | Whether this lane gets its own lock box (SiloedLockRelease only) |

Lanes that are not siloed share one lock box; every siloed lane gets its own. A lane whose remote side already exists
and is served by another pool today can be taken over instead of deployed: declare it in `imported_lanes`. A lane the
deployer must not configure — one the pool's owner connects later by a proposal — is listed in `deferred_lanes`.

---

### `imported_lanes`

Optional. Keyed by `remote_chain_name`; every key must also appear in `remote_lanes`. An imported lane is one the pool
takes over from an existing pool on this chain: the remote chain is not deployed by these scripts (its
`chains/<remote_chain_name>.json` carries only the fields `2_Configure` reads: `ccip`, `addresses.token`,
`deployed.token_pool`), and `2_Configure` configures the lane from this block instead of the defaults.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `remote_pools` | address[] | **Yes** | Every remote pool the replaced pool accepts for that chain; the remote record's `deployed.token_pool` must be among them |
| `rate_limits.outbound` | object | **Yes** | `enabled`, `capacity`, `rate` applied to the lane instead of `rate_limiter_defaults.outbound` |
| `rate_limits.inbound` | object | **Yes** | the same for the inbound direction |
| `required_ccvs` | string | **Yes** | Must be `"none"`: the hooks get no CCV entry for the lane and the placeholder verifier and resolver are not configured for it, so the lane keeps its default verification |

```json
"imported_lanes": {
  "ink": {
    "remote_pools": ["0x2dC99aF320bC317C567F24ee95811DcbD5983dFd"],
    "rate_limits": {
      "outbound": {"enabled": true, "capacity": "2", "rate": "1"},
      "inbound": {"enabled": true, "capacity": "264000000000000", "rate": "1"}
    },
    "required_ccvs": "none"
  }
}
```

---

### `deferred_lanes`

Optional. An array of `remote_chain_name`s, each also in `remote_lanes` and not in `imported_lanes`. A deferred lane
is deployed like any other — `1_Deploy` builds its lock box, `2_Configure` authorizes the pool on it and hands it to
the timelock — but `2_Configure` applies none of its configuration: no chain update, fee config or lock box binding on
the pool, no CCV entry in the hooks, no entries in the placeholder verifier and the resolver. The lane is connected
afterwards by the pool's owner, the `LidoTimelock`: `4_ConnectLane.s.sol` reads the same records and writes the batch
of owner-only calls (`applyChainUpdates`, `applyTokenTransferFeeConfigUpdates`, `configureLockBoxes` on a
SiloedLockRelease pool, `applyCCVConfigUpdates`, `applyRemoteChainConfigUpdates`, `applyOutboundImplementationUpdates`)
to the file named by `PROPOSAL_OUT` for a proposal of the timelock's proposer (Chainlink MCMS) or the admin's bypass;
it broadcasts nothing.

```sh
CHAIN_CONFIG=./contracts/lido-hvmv/config/chains/ethereum.json LANE=base \
PROPOSAL_OUT=./contracts/lido-hvmv/config/ethereum.lane-base.json \
forge script contracts/lido-hvmv/script/deployment/4_ConnectLane.s.sol:ConnectLaneScript --rpc-url $RPC
```

```json
"deferred_lanes": ["base"]
```

This is how a hub that takes over an existing pool is bound while it mirrors that pool exactly (every imported lane
configured, the new lane absent) and gains the new lane by a separate proposal once the pool is the registry's.

---

### `deployed`

Deployed contract addresses. **Automatically populated** by deployment scripts - do not edit manually.

| Field | Type | Description |
|-------|------|-------------|
| `token_pool` | address | Deployed TokenPool contract |
| `timelock` | address | Deployed LidoTimelock |
| `call_proxy` | address | Deployed CallProxy, the timelock's only executor |
| `advanced_pool_hooks` | address | Deployed PausableAdvancedPoolHooks |
| `lock_boxes` | object[] | `{lock_box, remote_chain_name}` per lane (SiloedLockRelease only) |
| `token`, `token_impl`, `token_proxy_admin` | address | Only when `1_Deploy` deployed the token (`addresses.token` is `address(0)`) |

---

## Auto-Hydration from Chainlink API

`1_Deploy` fetches these from the Chainlink CCIP API by `chain.chain_id` on every run and writes them under `.ccip`,
overwriting any existing values:

| Field | Source |
|-------|--------|
| `ccip.chain_selector` | Chainlink CCIP API |
| `ccip.router` | Chainlink CCIP API |
| `ccip.rmn_proxy` | Chainlink CCIP API |
| `ccip.token_admin_registry` | Chainlink CCIP API |
| `ccip.registry_module_owner` | Chainlink CCIP API |

---

## Creating a New Chain Config

1. **Copy the template that matches the chain:**

   | Template | Use when | Token |
   |----------|----------|-------|
   | `_template_existing_token.json` | Migration: the token is already deployed on the chain | Set `addresses.token`; any pool type |
   | `_template_new_token.json` | New chain: no token yet | `addresses.token` stays `address(0)`; `1_Deploy` deploys it from `token_deployment` (BurnMint only) |

   ```bash
   cp config/chains/_template_existing_token.json config/chains/mychain.json
   # or
   cp config/chains/_template_new_token.json config/chains/mychain.json
   ```

2. **Set required fields:**
   - `chain.chain_id` - The EVM chain ID
   - `chain.chain_name` - Chain name used in logs (other chains reference this config by its file name)
   - `chain.pool_type` - `"BurnMint"` or `"SiloedLockRelease"`
   - `addresses.token` - The token address to bridge (existing-token template only)
   - `token_deployment.name`, `token_deployment.symbol`, `token_deployment.decimals` (new-token template only)

3. **Add remote lanes:**
   - `remote_chain_name` - Name of the remote chain's config file (without `.json`)
   - `is_siloed` - Dedicated lockbox for this lane (SiloedLockRelease only)

4. **Set governance addresses** (required, including on testnets):
   - `governance_addresses.lido_dao_agent`
   - `governance_addresses.emergency_brakes`
   - `governance_addresses.chainlink_mcms`

5. **Run the deployment scripts** in order, see [`script/deployment/README.md`](../script/deployment/README.md).

---

## Field Reference Table

### Default Config Fields

| Path | Type | Default | Description |
|------|------|---------|-------------|
| `governance.min_delay_seconds` | uint40 | `259200` | 3 days |
| `governance.expiry_period_seconds` | uint120 | `1209600` | 14 days |
| `blocked_selectors[].function` | string | - | Function signature |
| `blocked_selectors[].selector` | bytes4 | - | Hex selector |
| `blocked_selectors[].reason` | string | - | Documentation |
| `rate_limiter_defaults.outbound.enabled` | bool | `true` | Enable outbound limiter |
| `rate_limiter_defaults.outbound.capacity` | string | `"330e18"` | Hard cap (wei) |
| `rate_limiter_defaults.outbound.rate` | string | - | Refill rate (wei/s) |
| `rate_limiter_defaults.inbound.enabled` | bool | `true` | Enable inbound limiter |
| `rate_limiter_defaults.inbound.capacity` | string | `"500e18"` | Hard cap (wei) |
| `rate_limiter_defaults.inbound.rate` | string | - | Refill rate (wei/s) |

### Chain Config Fields

| Path | Type | Required | Description |
|------|------|----------|-------------|
| `chain.chain_id` | uint256 | Yes | EVM chain ID |
| `chain.chain_name` | string | Yes | Config file name |
| `chain.pool_type` | string | Yes | `BurnMint` \| `SiloedLockRelease` |
| `addresses.token` | address | Yes | Token to bridge (`address(0)`: deploy one) |
| `token_deployment.*` | - | When `addresses.token` is `address(0)` | See `token_deployment` |
| `governance_addresses.lido_dao_agent` | address | Yes | DAO agent |
| `governance_addresses.emergency_brakes` | address | Yes | Canceller, halter, pauser |
| `governance_addresses.chainlink_mcms` | address | Yes | Proposer, canceller |
| `remote_lanes[].remote_chain_name` | string | Yes | Remote chain's `chain.chain_name` |
| `remote_lanes[].is_siloed` | bool | Yes | Own lock box for this lane |
| `imported_lanes.<name>.*` | object | No | Lane taken over from an existing pool: its remote pools and limits, no CCVs (see `imported_lanes`) |
| `deferred_lanes[]` | string | No | Lane `2_Configure` leaves to the owner; `4_ConnectLane` emits its batch (see `deferred_lanes`) |
| `deployed.*` | address | No | Auto-populated |
