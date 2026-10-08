# wstETH token

Locally maintained non-rebasing L2 wstETH implementation, deployed behind OpenZeppelin's
`TransparentUpgradeableProxy`. This directory is an ordinary package in this repository,
not a Git submodule.

`ERC20BridgedPermit` combines the imported permit-enabled ERC20 base with
revocable MINTER_ROLE and BURNER_ROLE authorization. Initialize metadata, domain,
version and DEFAULT_ADMIN_ROLE atomically through the proxy constructor's init data.
The proxy's `ProxyAdmin` (created by the proxy constructor, owned by the governance
executor from the first block) controls upgrades; renouncing its ownership freezes the
implementation permanently, the counterpart of the former `OssifiableProxy` ossification.

CCIP registration uses `RegistryModuleOwnerCustom.registerAccessControlDefaultAdmin`:
the caller must hold the token's `DEFAULT_ADMIN_ROLE`, managed through OpenZeppelin
`AccessControlEnumerableUpgradeable`. No `getCCIPAdmin`/`setCCIPAdmin` hook is exposed.
Registration proposes a CCIP registry administrator; accepting that appointment
and later transferring it are separate from transferring the token's roles.
The deployment initially registers through the deployer, then hands token admin
to the governance executor and revokes the deployer's role. L2 registration fails
if the required ACL authority is missing; it cannot fall back to impersonation.

Production sources exclude rebasing stETH, rate oracles and transport bridges.
The remaining legacy IERC20Bridged interface is retained verbatim from upstream;
the token does not implement its bridgeMint/bridgeBurn selectors.

## Dependencies and toolchain

The token mirrors the editions Chainlink's `BurnMintERC20Transparent` is built and deployed
with in the CCIP deployment scripts:

| Use | Edition | Pin |
| --- | --- | --- |
| Implementation: `IERC20`, `IERC2612`, `IERC5267`, `MessageHashUtils`, `SignatureChecker` | OpenZeppelin contracts 5.0.2 | `components/openzeppelin-contracts-5.0.2` (`dbb6104c`) |
| Implementation: `AccessControlEnumerableUpgradeable`, `Initializable` | OpenZeppelin contracts-upgradeable 5.0.2 | `components/openzeppelin-contracts-upgradeable-5.0.2` (`723f8cab`) |
| Proxy: `TransparentUpgradeableProxy`, `ProxyAdmin` | OpenZeppelin contracts 5.3.0 | `components/wsteth-token/lib/openzeppelin-contracts-5.3.0` (`e4f70216`) |

Compiler for the token, `TransparentUpgradeableProxy` and `ProxyAdmin`: Solidity 0.8.26,
EVM `paris`, via-IR, optimizer 80,000 runs, `bytecode_hash = "none"`.
The orchestration's `token` profile uses the same settings for the deployed implementation.
All three dependencies are public, pinned submodules; the token build does not require CCIP
access or pnpm. Remapping auto-detection is off in every build here, so the compiler metadata
depends only on the pinned sources and the listed remappings, not on which sibling packages
happen to be installed. The metadata hash is omitted from bytecode.

The deployable `TransparentUpgradeableProxy` and `ProxyAdmin` artifacts are built here too:

```sh
forge build --root components/wsteth-token \
    lib/openzeppelin-contracts-5.3.0/contracts/proxy/transparent/TransparentUpgradeableProxy.sol \
    lib/openzeppelin-contracts-5.3.0/contracts/proxy/transparent/ProxyAdmin.sol
# -> components/wsteth-token/out/{TransparentUpgradeableProxy,ProxyAdmin}.sol/
```

The 5.3.0 submodule sits inside this project (`lib/`) rather than beside the others on purpose. The
two files import each other, and Foundry resolves that cycle through canonical paths: for a checkout
outside the project root that is this machine's absolute path, which would land in the metadata and
explorer verification would publish local paths. Inside
the root the source names are `lib/openzeppelin-contracts-5.3.0/contracts/...` on every machine. The
unit tests instantiate the proxy from the same artifacts.

## Storage layout

The implementation keeps **no OpenZeppelin state in linear storage**. Linear slots 0–2 hold
`ERC20Core`'s `totalSupply`, `balanceOf` and `allowance`, exactly as the audited wstETH
implementations live on Optimism, Arbitrum and Base. Everything else lives at fixed keccak slots:

- OpenZeppelin 5.x ERC-7201 namespaces: `openzeppelin.storage.Initializable`,
  `openzeppelin.storage.AccessControl`, `openzeppelin.storage.AccessControlEnumerable`;
- Lido unstructured slots: `ERC20Metdata.dynamicMetadata`, `PermitExtension.NONCE_BY_ADDRESS_POSITION`,
  `PermitExtension.eip5267MetadataSlot`, `lido.Versioned.contractVersion`.

`PermitExtension` derives the EIP-712 domain from constructor immutables rather than inheriting
OpenZeppelin 5.x `EIP712`, whose two storage strings would otherwise occupy linear slots 3 and 4.
`storage-layout/ERC20BridgedPermit.json` is the committed snapshot; `just wsteth-token-layout-check`
fails when the compiled layout drifts from it, and the unit tests assert the namespace constants and
that slots 3–255 stay empty.

This component supports **fresh deployments**, not an in-place upgrade of the existing
Optimism/Arbitrum/Base fleet. Preserving ERC20 and Lido slots is necessary but does not migrate
bridge authority to roles. A fleet proxy already at `Versioned == 2` cannot use this build's
four-argument `initialize`: `_initializeContractVersionTo(2)` rejects its existing version,
and no `DEFAULT_ADMIN_ROLE` is seated. An upgrade would remove the old bridge authority without
establishing mint/burn roles. Such a migration requires a separately designed, authorized migration
initializer, atomic upgrade-and-initialization, and migration tests against the exact prior
implementation and state. These layout checks do not establish that migration's readiness.

Implementations built from the earlier OpenZeppelin 4.7.3 edition (linear `_initialized` at slot 3,
roles at 104/154) are **not** storage-compatible with this one; a proxy initialized with that build
must be redeployed, not upgraded.

Run `just wsteth-token-test` from the repository root. Initialize only its dependencies:

```sh
git submodule update --init libs/forge-std components/openzeppelin-contracts-5.0.2 components/openzeppelin-contracts-upgradeable-5.0.2 components/wsteth-token/lib/openzeppelin-contracts-5.3.0
just wsteth-token-test
```

Deployment and verification procedures remain in `orchestration/wsteth-ccip`;
see its `FOUNDRY_PROFILE=token` build and `script/03_l2_token.sh`.

## Provenance

The upstream import history is recorded in `provenance.json`. Imported sources carry their
upstream copyright/SPDX notices and LICENSE. The former MIT-licensed mint/burn extension is incorporated into
ERC20BridgedPermit; imported sources retain their GPL-3.0 headers.

The Foundry suite adapts upstream metadata, permit, initialization and proxy
behavior checks, and adds role authorization, upgrade and storage-layout checks for the
maintained token. Migration verification compares ABI, storage layout and executable bytecode;
source-path changes can alter Solidity metadata hashes.
