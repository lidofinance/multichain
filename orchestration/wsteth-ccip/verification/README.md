# Explorer verification with constructor checks

An available `SourceCode` response proves that the explorer can display source.
It does not prove Exact Match. Similar Match can display another deployment's
source while omitting this deployment's constructor arguments.

`exact-status.cjs` requires source availability, an empty `SimilarMatch` marker,
and byte-for-byte equality between the published and expected ABI-encoded
constructor arguments. An explicitly empty constructor payload is valid;
unknown constructor arguments remain unaudited. `Already Verified` from a
submission or poll is never accepted without this readback.

Use Node 24 and the existing `ETHERSCAN_API_KEY` environment. The CLI reads the
ordinary orchestration environment without printing credentials. It only uses
the explorer API: it does not sign transactions, deploy, upgrade or configure
contracts. New source submissions reject absolute paths.

```sh
node --test orchestration/wsteth-ccip/verification/exact-status.test.cjs

node orchestration/wsteth-ccip/verification/explorer.cjs audit \
  runs/wsteth-2.0/deployments/public-20261104-fresh-01/explorer-inventory-audit.final.json \
  runs/wsteth-2.0/deployments/public-20261104-fresh-01/verification-exact-20261105/all.jobs.json \
  runs/wsteth-2.0/deployments/public-20261104-fresh-01/verification-exact-20261105/full-audit.json
```

The 2026-11-05 token submissions returned `Already Verified`, retained Similar
Match, and did not publish the constructor arguments. The Mantlescan verification
form also states that additional verification is unavailable with the current
user credentials. [Etherscan documents account whitelisting for Similar Match
reverification](https://info.etherscan.com/update-on-similar-match-contract-verification/).
On 2026-11-05 the user accepted the existing Similar Match / constructor warnings
and declined contacting support. No further resubmission is pending for this
deployment. The prepared support draft is historical evidence only and must not
be sent under the current authorization.

For a future deployment, submit its original compiler input with relative source
paths and its exact creation-time constructor arguments, then read back the
result. Do not reuse the current run's token jobs for new addresses. The generic
submission command is:

```sh
node orchestration/wsteth-ccip/verification/explorer.cjs submit \
  <new-run-jobs.json> <new-empty-output-directory>
```

`submit` records each GUID and polls for up to 20 minutes. Resume polling with:

```sh
node orchestration/wsteth-ccip/verification/explorer.cjs poll \
  <submission-output-directory>
```

The command exits unsuccessfully if any match or constructor check remains
incomplete. Use the exact standard-JSON input and constructor-argument text
from the package when using the explorer web form instead. For proxies, these
are the **original creation arguments**, including original initialization
calldata; they must not be reconstructed from current governance roles.

Immediate submission after deployment is not a guarantee of Exact Match.
[Etherscan assigns Similar Match automatically when creation bytecode matches
an already verified contract](https://info.etherscan.com/types-of-contract-verification/),
without checking constructor arguments. A fresh address can therefore encounter
the same reverification restriction. Our CCIP release build inherits
`bytecode_hash = "none"` from the pinned component; a new address or new constructor
arguments do not by themselves make its compiled creation bytecode unique.
There is no confirmed standard CLI/API option that prevents automatic Similar
Match. Compiler settings and contract bytecode are not changed just to obtain
an explorer badge. If the explorer blocks the normal submission, retain the
actual status and evidence; do not count `Already Verified` as Exact Match or
automatically contact support.

The frozen deployment pipeline is preserved. These verification tools and their
evidence are maintained separately from its captured source inputs. The four
previously accepted DG absolute-path records remain an exception only for that
existing publication; new submissions still require relative paths.
