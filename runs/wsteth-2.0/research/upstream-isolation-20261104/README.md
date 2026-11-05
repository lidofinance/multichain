# Historical upstream-isolation evidence

The records in this directory describe the 2026-11-04 rehearsals. They are not
evidence for later contract or orchestration changes.

On 2026-11-05, ten build-provenance JSON files under
`record-consumers/{new-mainnet,new-sepolia}/state/` were sanitized. Their Forge
settings now contain compiler settings only; explorer credentials and other
non-compiler configuration were removed. Each sanitized record carries a
`provenanceSanitization` note. Solidity source and artifact hashes were retained.

Historical `buildProvenanceSha256` references describe the original records and
do not authenticate the sanitized bytes. They were not rewritten to imply an
unchanged historical record. New builds use the compiler-settings allowlist in
`orchestration/wsteth-ccip/script/ccip_build.py` before archiving provenance.
