# Local patches on vendored submodules

`lib/core` and `lib/ccip` are pinned to upstream commits, but this pipeline needs a small core-only
change on top. It lives here as patch files rather than as uncommitted edits
inside the submodules, so that:

- a fresh `git clone --recursive` reproduces the same deploy (before this, the edits existed only in
  one working copy — the Sepolia deployment was not reproducible anywhere else);
- the diff is visible in *this* repo's history and review, instead of being invisible behind a
  clean gitlink;
- `git submodule update` / branch switches inside a submodule cannot silently drop them;
- the testnet-only hack stays labelled as such rather than being upstreamed.

## Layout

```
patches/<name>/*.patch      applied to lib/<name>, in lexical order
```

Each patch carries its own header: `Subject:`, the `Base:` commit it was cut against, the files it
touches, and a `WHY` block. Read the header before touching the patch.

| Patch | Touches | Consequence |
|---|---|---|
| `core/0001-wsteth-getccipadmin.patch` | `contracts/0.6.12/WstETH.sol` | **Changes deployed bytecode.** Testnet-only. |
| `core/0002-hardhat-live-rpc.patch` | `hardhat.config.ts` | Deploy mechanics over a public RPC. |

Keep this set as small as it can be. Three things do **not** belong in a patch:

*Anything a deploy step already rewrites at run time.* `aragonTokenManager.totalSupply` is the
worked example — `script/01_l1_core_dg.sh` computes it from the vesting params it actually deploys
with, so pinning it here would duplicate that and go stale the moment the params change.

*Anything expressible as an assertion on our own side.* There used to be a third patch adding
`getCCIPAdmin: null` to core's `scratch.yaml`, so that a missing `0001` surfaced in core's own state
check. That check turned out to be the wrong host — it is core's verification of core, it is
currently disabled (see `01_l1_core_dg.sh`, `STATE_MATE_CHECK`), and it made our assertion hostage
to upstream drift. Step 01 now `cast call`s `getCCIPAdmin()` on the freshly deployed wstETH
directly, which is stricter (it checks the value, not just presence) and costs no patch at all.

*Anything upstream has absorbed.* Two retired examples:

- `ccip/0001-unseat-guardian.patch` stopped seating `GUARDIAN_ROLE`. On **2026-09-02** the
  `lido-proposals` branch removed the role, its initializer field, and its deployment grant entirely,
  so the patch was deleted. The current POM base is both simpler and stronger: there is no dormant
  role that a later grant can reactivate.
- `lido-l2-with-steth/0001-drop-bridge-mint-burn.patch` removed the
legacy `bridge` mint/burn authority from `ERC20Bridged`, so the L2 wstETH mints and burns only through
`MINTER_ROLE`/`BURNER_ROLE`. On **2026-09-02** that change landed upstream and `lib/lido-l2-with-steth`
was re-pinned from `main` to **`feat/token-upgrade`**, which carries it — plus the follow-through the
patch could not do from outside: the submodule's own stubs, unit tests and `utils/optimism/deploy*.ts`
stop passing a `bridge_`, so the base is internally consistent rather than merely compiling for the two
files we import. The patch was **deleted, not re-cut**.

What replaced it is a *pin*, not a patch, so the property is enforced differently — and the patch
driver can no longer report it. Three layers, deliberately ordered cheapest-first:

1. `script/00_preflight.sh` greps the two base files our token inherits for the authority in any of
   its three spellings (a `bridge` immutable *or* state variable, an `onlyBridge` modifier, or
   `ERC20Bridged` inheriting `IERC20Bridged`). A source tripwire — preflight has to run before any
   build. Scoped to those two files on purpose: `ERC20RebasableBridged.sol` keeps its own
   `onlyBridge` legitimately, so a `contracts/token/`-wide grep false-positives.
2. `script/03_l2_token.sh` asserts the **compiled ABI** carries no `bridge*` selector, before it
   deploys. This is the authoritative pre-deploy check, and unlike a grep it is spelling-independent:
   storage instead of immutable, or a renamed modifier, still shows up as a selector.
3. Step 03 then asserts `bridge()` is absent **on the deployed token** — the only check that speaks
   about the bytecode that actually reached the chain.

A `git submodule update` that snaps the base back to `main`, or a re-pin onto any branch without the
removal, trips all three. None of them is pinned to a commit SHA, so a legitimate re-pin does not.

## Usage

```bash
just patch-submodules          # apply (idempotent — safe to re-run)
just patch-submodules-check    # read-only; exits 1 if any patch is missing
just patch-submodules-revert   # restore pristine upstream submodules
```

Applied automatically by `just init`, `just init-thirdparty`, and by step 01, whose build bakes a
patch into what it deploys (`script/01_l1_core_dg.sh`, `core/0001` → wstETH bytecode). The set is
also *verified* read-only by
step 00 (`script/00_preflight.sh`), which fails the go/no-go if a patch is missing. Step 03 no longer
applies patches — the L2 token base needs none — but it does assert the pin's effect (above).

The deploy steps also assert these effects ON-CHAIN after the deploy, which is the check that actually
matters: applying a patch to a working tree — or pinning a submodule branch — proves nothing about the
bytecode that reached the chain. Step 01 reads `getCCIPAdmin()` off the deployed wstETH; step 03
requires `bridge()` to be absent and `getContractVersion() == 2` on the deployed L2 token; Claim A and
the fork upgrade rehearsal check the current POM role model and UUPS implementation.

Idempotency works by probing both directions with `git apply --check`: a patch that reverse-applies
cleanly is already present. `apply` and `revert` are all-or-nothing: every patch is classified before
the tree is touched, so one stale patch cannot leave the earlier ones applied behind it. Nothing is
ever force-applied — a patch that neither applies nor is
already applied aborts loudly — the signal that the submodule moved off the commit named in the
patch's `Base:` line.

## Updating a pinned submodule

The patches make the submodule working tree dirty, so git refuses to move it. Revert first:

```bash
just patch-submodules-revert
git -C lib/<name> fetch <remote> <branch>          # https:// works for public repos without a key
git -C lib/<name> merge --ff-only FETCH_HEAD
just patch-submodules                              # tells you which patches went stale
```

The last step is the point of the whole mechanism: a patch upstream has absorbed, or whose context
moved, fails loudly with its `Base:` line against the new HEAD, and nothing is applied. Re-cut those
(below), then re-run. Check every failure for whether upstream now solves it *better* — several
patches have been deleted rather than re-cut for exactly that reason.

If the merge still refuses after a revert, something outside the patches dirtied the tree — most
likely a deploy step that writes into the submodule. Find it and make it restore what it touched;
do not paper over it by pinning the value in a patch.

## Regenerating after editing a submodule by hand

```bash
git -C lib/<name> diff -- <paths for that patch> > /tmp/new.diff
# keep the existing header block, replace the diff body below it
```

Then confirm the patch still describes the tree exactly:

```bash
git -C lib/<name> apply --check -R "$PWD/patches/<name>/<patch>.patch"   # must succeed
```

If a submodule gets re-pinned to a newer upstream commit, re-cut its patches against it and update
each `Base:` line.

## 0001 is not a mainnet solution

`0001` exists because CCIP's `TokenAdminRegistry` can only be self-registered into through one of
the conventions `RegistryModuleOwnerCustom` recognises — `getCCIPAdmin()`, `owner()`, or
AccessControl's `DEFAULT_ADMIN_ROLE` — and the canonical `WstETH` exposes none of them. Adding the
hook to the throwaway testnet core lets step 07 register against the real Chainlink TAR with no
impersonation and no Chainlink involvement.

Canonical mainnet wstETH is immutable and cannot gain this hook. There, seating the first TAR
administrator requires the TAR owner (Chainlink) to call `proposeAdministrator` directly — an
external organisational dependency of mainnet onboarding, which this patch conceals on testnet
rather than removes. See `docs/LIVE_DEPLOY_CONCERNS.md` §1 and §5.

`Base:` identifies the original patch edition, not a required current checkout.
The imported core patches were cut at `fe5aa4956`; they also reverse-apply cleanly
at the current `f36c1b632` checkout with patches present. The driver checks patch
applicability; run manifests capture the actual revision and local tracked diff.
CCIP uses the superproject index gitlink as its current pin.
