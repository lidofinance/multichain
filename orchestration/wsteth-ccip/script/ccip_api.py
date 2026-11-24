#!/usr/bin/env python3
"""Capture and replay the four CCIP discovery responses without patching upstream FFI."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.request

URLS = {
    f'https://docs.chain.link/api/ccip/v1/chains?environment={environment}&outputKey={key}':
    f'{environment}-{key}.json'
    for environment in ('mainnet', 'testnet') for key in ('chainId', 'selector')
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def capture(directory):
    directory.mkdir(parents=True, exist_ok=False)
    manifest = {}
    for url, name in URLS.items():
        request = urllib.request.Request(url, headers={'User-Agent': 'curl/8.7.1'})
        with urllib.request.urlopen(request, timeout=60) as response:
            data = response.read()
        if not isinstance(json.loads(data)['data']['evm'], dict):
            raise ValueError('Invalid CCIP response: ' + name)
        (directory / name).write_bytes(data)
        manifest[url] = {'file': name, 'sha256': digest(data)}
    (directory / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')


def verify(directory):
    manifest = json.loads((directory / 'manifest.json').read_text())
    if set(manifest) != set(URLS):
        raise ValueError('CCIP API snapshot must contain all four discovery responses')
    for url, name in URLS.items():
        entry = manifest[url]
        if entry['file'] != name or digest((directory / name).read_bytes()) != entry['sha256']:
            raise ValueError('CCIP API snapshot changed: ' + name)
    return manifest


def replay(args):
    """A narrowly scoped curl adapter. Other URLs still use the real curl."""
    urls = [arg for arg in args if arg.startswith(('https://', 'http://'))]
    if not any(url.startswith('https://docs.chain.link/api/ccip/') for url in urls):
        return subprocess.call([os.environ['WSTETH_REAL_CURL'], *args])
    if len(urls) != 1 or urls[0] not in URLS:
        raise ValueError('Uncaptured CCIP discovery URL; live fallback is forbidden')
    directory = Path(os.environ['WSTETH_CCIP_API_DIR'])
    verify(directory)
    data = (directory / URLS[urls[0]]).read_bytes()
    remaining = [arg for arg in args if arg != urls[0]]
    output = None
    while remaining:
        option = remaining.pop(0)
        if option in ('-o', '--output') and remaining:
            output = remaining.pop(0)
        elif option not in ('-s', '-fsS', '-sS', '-f', '--silent', '--fail', '--show-error'):
            raise ValueError('Unsupported captured curl option: ' + option)
    if output:
        Path(output).write_bytes(data)
    else:
        sys.stdout.buffer.write(data)
    return 0


if __name__ == '__main__':
    try:
        if Path(sys.argv[0]).name == 'curl':
            sys.exit(replay(sys.argv[1:]))
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('action', choices=['capture', 'verify'])
        parser.add_argument('directory', type=Path)
        args = parser.parse_args()
        (capture if args.action == 'capture' else verify)(args.directory)
    except (ValueError, KeyError, OSError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
