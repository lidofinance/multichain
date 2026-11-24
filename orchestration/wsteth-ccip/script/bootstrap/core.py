"""Deploy full core with pristine wstETH, restoring the operator's checkout afterwards."""
import hashlib
import os
import subprocess
from rpc import OPS, ROOT, inputs, write


def main():
    inputs()  # Validate every fork before altering files or deploying.
    core = ROOT / 'components/core'
    token = core / 'contracts/0.6.12/WstETH.sol'
    record = core / 'deployed-local.json'
    upstream = subprocess.check_output(['git', '-C', str(core), 'show', 'HEAD:contracts/0.6.12/WstETH.sol'])
    original = token.read_bytes()
    previous_record = record.read_bytes() if record.exists() else None
    try:
        token.write_bytes(upstream)
        record.unlink(missing_ok=True)
        env = dict(os.environ, CORE_DIR=str(core), WSTETH_PRISTINE_TOKEN='1')
        subprocess.run(['bash', 'script/01_l1_core_dg.sh'], cwd=OPS, env=env, check=True)
        write(OPS / 'state/bootstrap-core.json', {
            'coreCommit': subprocess.check_output(['git', '-C', str(core), 'rev-parse', 'HEAD'], text=True).strip(),
            'wstETHSourceSha256': hashlib.sha256(upstream).hexdigest(),
            'wstETHSource': 'contracts/0.6.12/WstETH.sol', 'getCCIPAdminPatch': False})
    finally:
        token.write_bytes(original)
        if previous_record is None:
            record.unlink(missing_ok=True)
        else:
            record.write_bytes(previous_record)


if __name__ == '__main__':
    main()
