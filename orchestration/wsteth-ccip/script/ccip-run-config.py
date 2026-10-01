#!/usr/bin/env python3
"""Overlay upstream Foundry settings with run-local mutable paths."""
import json
import os
from pathlib import Path
import subprocess
import sys


def write_config(evm, run):
    evm, run = Path(evm).resolve(), Path(run).resolve()
    destination = run / 'state/ccip/foundry.toml'
    destination.parent.mkdir(parents=True, exist_ok=True)
    upstream = json.loads(subprocess.check_output(
        ['forge', 'config', '--root', str(evm), '--config-path', str(evm / 'foundry.toml'), '--json'],
        text=True, env=dict(os.environ, FOUNDRY_PROFILE='default')))
    # --config-path changes Foundry's path base even with --root. Preserve the
    # upstream source/import/build locations explicitly, rather than resolving
    # them relative to state/ccip. Mutable records and receipts stay in the run.
    overlay = '\n[profile.wsteth_run]\n'
    for key in ('src', 'script', 'test', 'out'):
        overlay += f'{key} = {json.dumps(str((evm / upstream[key]).resolve()))}\n'
    overlay += 'libs = ' + json.dumps([str((evm / p).resolve()) for p in upstream['libs']]) + '\n'
    remappings = []
    for remapping in upstream['remappings']:
        prefix, path = remapping.split('=', 1)
        remappings.append(prefix + '=' + str((evm / path).resolve()) + '/')
    overlay += 'auto_detect_remappings = false\nremappings = ' + json.dumps(remappings) + '\n'
    overlay += f'broadcast = {json.dumps(str(run / "broadcast/ccip"))}\n'
    overlay += f'cache_path = {json.dumps(str(run / "state/ccip/cache"))}\n'
    overlay += 'fs_permissions = [{ access = "read-write", path = '
    overlay += json.dumps(str(run / 'config')) + ' }]\n'
    destination.write_text((evm / 'foundry.toml').read_text() + overlay)
    return destination


if __name__ == '__main__':
    print(write_config(*sys.argv[1:]))
