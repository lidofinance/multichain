# wstETH token

Locally maintained non-rebasing L2 wstETH implementation and ossifiable proxy.
This directory is an ordinary package in this repository, not a Git submodule.

`ERC20BridgedPermit` combines the imported permit-enabled ERC20 base with
revocable MINTER_ROLE and BURNER_ROLE authorization. Initialize metadata, domain,
version and DEFAULT_ADMIN_ROLE atomically through the proxy constructor. The
proxy administrator controls upgrades and can permanently ossify the proxy.

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

Run `just wsteth-token-test` from the repository root. The build preserves Solidity
0.8.10, London, optimizer 200, OpenZeppelin contracts 4.8.3 and the existing pinned
upgradeable dependency. Both OpenZeppelin dependencies are public, pinned submodules;
the token build does not require CCIP access or pnpm. Initialize only its dependencies:

```sh
git submodule update --init libs/forge-std components/openzeppelin-contracts-4x components/openzeppelin-contracts-upgradeable-4x
just wsteth-token-test
```

Deployment and verification procedures remain in `orchestration/wsteth-ccip`;
network inputs and integration scenarios remain in `targets/`. This package has
no RPC or deployment configuration. Future bridge implementations have their own
scope and are not included here.

See `provenance.json` for the upstream commit and original source hashes. Preserve
upstream copyright/SPDX notices and LICENSE. The former MIT-licensed mint/burn extension is incorporated into
ERC20BridgedPermit; imported sources retain their GPL-3.0 headers.

The Foundry suite adapts upstream metadata, permit, initialization and proxy
behavior checks, and adds role authorization checks for the maintained token.
Migration verification compares ABI, storage layout and executable bytecode;
source-path changes can alter Solidity metadata hashes.
