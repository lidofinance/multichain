#!/usr/bin/env python3
"""Build static dashboard data from the local ledger and one wsteth-ccip revision.

By default, upstream inputs are fetched directly from GitHub at the current main
commit. --upstream PATH explicitly selects a local source directory instead.
No cloning or upstream code execution is performed.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import html
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import re
import os
import subprocess
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
from pathlib import Path
from urllib.parse import quote, urljoin, urlsplit

ROOT = Path(__file__).resolve().parents[3]  # repository root
UPSTREAM = "https://github.com/lidofinance/wsteth-ccip"
ACTIVE = "docs/CURRENT-DEPLOYMENT.md"
ADDRESS = re.compile(r"0x[0-9a-fA-F]{40}\Z")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def address(value):
    if not isinstance(value, str) or not ADDRESS.fullmatch(value) or int(value, 16) == 0:
        raise ValueError(f"Missing or invalid deployed address: {value!r}")
    return value


def deployed(ledger, network, contract):
    matches = [d for d in ledger['deployments'] if d['networkId'] == network
               and d['contractId'] == contract and d['deploymentKind'] in ('proxy', 'standalone')]
    if len(matches) != 1:
        raise ValueError(f"Expected one deployed {network}/{contract}, got {len(matches)}")
    return address(matches[0]['address'])


def ledger_networks(ledger, metadata):
    rows = []
    seen = set()
    for d in ledger['deployments']:
        network = d['networkId']
        if (not d['contractId'].endswith('-wsteth-token') or
                d['deploymentKind'] not in ('proxy', 'standalone') or network == 'eip155:1' or
                ledger['networks'][network]['environment'] != 'mainnet'):
            continue
        if not re.fullmatch(r'eip155:[1-9][0-9]*', network):
            raise ValueError(f"Unsupported wstETH network: {network}")
        key = (network, d['contractId'])
        if key in seen:
            raise ValueError(f"Ambiguous token role: {key}")
        seen.add(key)
        m = metadata['networks'].get(d['contractId'], {})
        escrow = (deployed(ledger, 'eip155:1', m['escrowContractId'])
                  if 'escrowContractId' in m else m.get('escrowFromDocs'))
        if escrow:
            address(escrow)
        group = m.get('group', 'unclassified')
        if group not in ('supported', 'legacy', 'unclassified'):
            raise ValueError(f"Unknown support group: {group}")
        rows.append(dict(chainId=int(network.split(':')[1]),
                         name=m.get('name', ledger['networks'][network]['networkName']),
                         group=group, bridge=m.get('bridge', 'Bridge not classified'),
                         token=address(d['address']), escrow=escrow,
                         escrowLabel=m.get('escrowLabel'),
                         src={'token': 'ledger', 'escrow': 'ledger' if 'escrowContractId' in m
                              else 'docs' if escrow else None}))
    if not rows:
        raise ValueError('Ledger contains no mainnet wstETH deployments')
    return rows


class GitHubSource:
    """Resolve main once; retrieve all source contents at that immutable commit."""
    API = 'https://api.github.com/repos/lidofinance/wsteth-ccip'

    def __init__(self):
        self.token = (os.environ.get('WSTETH_CCIP_READ_TOKEN') or
                      os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN'))
        self.sha = self.request('commits/main')['sha']
        if not isinstance(self.sha, str) or not re.fullmatch(r'[0-9a-f]{40}', self.sha):
            raise ValueError('GitHub returned an invalid main commit SHA')

    def request(self, endpoint):
        headers = {'Accept': 'application/vnd.github+json',
                   'User-Agent': 'multichain-dashboard-builder',
                   'X-GitHub-Api-Version': '2026-03-10',
                   'Cache-Control': 'no-cache'}
        if self.token:
            headers['Authorization'] = 'Bearer ' + self.token
        request = Request(self.API + '/' + endpoint, headers=headers)
        try:
            with urlopen(request, timeout=30) as response:
                return json.load(response)
        except HTTPError as exc:
            raise ValueError(f'GitHub HTTP {exc.code} for {endpoint}. Check repository read access '
                             '(WSTETH_CCIP_READ_TOKEN) and that the required inputs are published on main.') from None
        except URLError:
            raise ValueError(f'Could not reach GitHub for {endpoint}; no local fallback is used.') from None

    def contents(self, path):
        if not path or any(p in ('', '.', '..') for p in path.split('/')):
            raise ValueError(f'Invalid upstream path: {path}')
        return self.request('contents/' + quote(path, safe='/') + '?ref=' + self.sha)

    def read(self, path):
        data = self.contents(path)
        if not isinstance(data, dict) or data.get('type') != 'file' or data.get('encoding') != 'base64':
            raise ValueError(f'Expected a base64-encoded GitHub file: {path}')
        return base64.b64decode(''.join(data['content'].split()), validate=True)

    def json_paths(self, directory):
        entries = self.contents(directory)
        if not isinstance(entries, list):
            raise ValueError(f'Expected a GitHub directory: {directory}')
        paths = []
        for entry in entries:
            name = entry.get('name', '')
            if name.endswith('.json'):
                path = directory + '/' + name
                if '/' in name or entry.get('type') != 'file' or entry.get('path') != path:
                    raise ValueError(f'Invalid chain file entry in GitHub directory: {directory}')
                paths.append(path)
        return sorted(paths)


class LocalSource:
    """Read explicitly selected local inputs, including unpublished changes."""
    sha = None

    def __init__(self, root):
        self.root = Path(root).expanduser().resolve()
        if not self.root.is_dir():
            raise ValueError(f'Upstream directory does not exist: {self.root}')
        self.files = {}

    def path(self, relative):
        path = (self.root / relative).resolve()
        if not path.is_relative_to(self.root):
            raise ValueError(f'Upstream path escapes source directory: {relative}')
        return path

    def read(self, relative):
        if relative not in self.files:
            path = self.path(relative)
            if not path.is_file():
                raise ValueError(f'Missing local upstream input: {relative}')
            self.files[relative] = path.read_bytes()
        return self.files[relative]

    def json_paths(self, directory):
        path = self.path(directory)
        if not path.is_dir():
            raise ValueError(f'Missing local upstream directory: {directory}')
        return sorted(directory + '/' + p.name for p in path.glob('*.json'))


def read_upstream(source):
    """Use the active pointer, never directory sort order or old fallback records."""
    inputs = {}

    def read(relative):
        raw = source.read(relative)
        inputs[relative] = digest(raw)
        return raw.decode()

    current = read(ACTIVE)
    records = set(re.findall(r'config/chains\.live[-\w]*\d{4}-\d{2}-\d{2}', current))
    if len(records) != 1:
        raise ValueError(f"{ACTIVE} must identify exactly one dated config/chains.live record")
    record = records.pop()
    date = record[-10:]
    report_path = f'docs/deployment-{date}.md'
    report = read(report_path)
    paths = source.json_paths(record)
    if len(paths) != 2:
        raise ValueError(f"Expected two chain JSON files in {record}; publish the complete active lane")
    configs = [json.loads(read(p)) for p in paths]
    kinds = {'SiloedLockRelease': 'lockRelease', 'BurnMint': 'burnMint'}
    configs.sort(key=lambda c: c['chain']['pool_type'] != 'SiloedLockRelease')
    if [c['chain']['pool_type'] for c in configs] != ['SiloedLockRelease', 'BurnMint']:
        raise ValueError('Expected one SiloedLockRelease hub and one BurnMint spoke')
    tokens, seeds = {}, {}
    for c in configs:
        chain_id = c['chain']['chain_id']
        if not isinstance(chain_id, int) or chain_id <= 0 or str(chain_id) in tokens:
            raise ValueError('Chain IDs must be distinct positive integers')
        chain = str(chain_id)
        dep = c['deployed']
        token = address(c['addresses']['token'])
        pool = address(dep['token_pool'])
        tokens[chain] = dict(chainId=chain, chainName=c['chain']['chain_name'].replace('_', ' ').title(),
                             tokenAddress=token, poolAddress=pool,
                             poolType=kinds[c['chain']['pool_type']], decimals=18)
        seeds[chain] = [[address(dep['pool_operation_manager']), 'ours:POM'], [pool, 'ours:pool'],
                        [address(dep['advanced_pool_hooks']), 'ours:hooks'], [token, 'ours:token'],
                        [address(c['ccv']['message_id_verifier']), 'ours:verifier'],
                        [address(c['ccv']['verifier_resolver']), 'ours:resolver']]
        seeds[chain] += [[address(b['lock_box']), 'ours:lockbox'] for b in dep.get('lock_boxes', [])]
        address(c['governance_addresses']['lido_dao_agent'])
    for c, peer in ((configs[0], configs[1]), (configs[1], configs[0])):
        if peer['chain']['chain_name'] not in [r['remote_chain_name'] for r in c['remote_lanes']]:
            raise ValueError('Active chain records do not describe a reciprocal lane')
    live = dict(record=record, deployedAt=date, env='testnet',
                lane=[c['chain']['chain_id'] for c in configs], tokens=tokens, seeds=seeds)
    return live, configs, current, report_path, report, inputs


def section(markdown, title):
    match = re.search(r'^## ' + re.escape(title) + r'\n(.*?)(?=^## |\Z)', markdown, re.M | re.S)
    if not match:
        raise ValueError(f"Missing upstream documentation section: {title}")
    return match[1].strip()


def source_text(text, source_url=""):
    """Render the small Markdown subset used by deployment docs; escape all HTML.

    Relative source links resolve against the pinned source document. Never
    load scripts, images, or raw HTML from upstream.
    """
    def inline(value):
        tokens = re.split(r'(`[^`]+`|\*\*[^*]+\*\*|\[[^\]]+\]\([^)]+\))', value)
        rendered = []
        for token in tokens:
            link = re.fullmatch(r'\[([^\]]+)\]\(([^)]+)\)', token)
            if token.startswith('`'):
                rendered.append('<code>' + html.escape(token[1:-1]) + '</code>')
            elif token.startswith('**'):
                rendered.append('<strong>' + html.escape(token[2:-2]) + '</strong>')
            elif link and urlsplit(urljoin(source_url, link[2])).scheme == 'https':
                rendered.append('<a href="' + html.escape(urljoin(source_url, link[2]), quote=True) + '">' + html.escape(link[1]) + '</a>')
            else:
                rendered.append(html.escape(token))
        return ''.join(rendered)

    blocks, paragraph, table_rows = [], [], []
    code = None

    def flush():
        if paragraph:
            blocks.append('<p>' + inline(' '.join(paragraph)) + '</p>')
            paragraph.clear()
        if table_rows:
            rendered = []
            for i, row in enumerate(table_rows):
                tag = 'th' if i == 0 else 'td'
                rendered.append('<tr>' + ''.join(f'<{tag}>' + inline(cell) + f'</{tag}>' for cell in row) + '</tr>')
            blocks.append('<div class="table"><table>' + ''.join(rendered) + '</table></div>')
            table_rows.clear()

    for line in text.splitlines():
        if line.startswith('```'):
            flush()
            if code is None:
                code = []
            else:
                blocks.append('<pre>' + html.escape('\n'.join(code)) + '</pre>')
                code = None
        elif code is not None:
            code.append(line)
        elif line.startswith('|'):
            if paragraph:
                flush()
            cells = [c.strip() for c in line.strip('|').split('|')]
            if not all(re.fullmatch(r':?-+:?', c) for c in cells):
                table_rows.append(cells)
        elif line.startswith('#'):
            flush()
            blocks.append('<h3>' + inline(line.lstrip('#').strip()) + '</h3>')
        elif line.startswith('- '):
            flush()
            blocks.append('<p>• ' + inline(line[2:]) + '</p>')
        elif not line.strip():
            flush()
        else:
            if table_rows:
                flush()
            paragraph.append(line.strip())
    flush()
    if code is not None:
        raise ValueError('Unterminated code block in upstream documentation')
    return ''.join(blocks)


def table(configs, fields):
    headings = ''.join('<th>' + html.escape(c['chain']['chain_name'].replace('_', ' ').title()) + '</th>' for c in configs)
    rows = []
    for label, getter in fields:
        cells = ''.join('<td><code>' + html.escape(address(getter(c))) + '</code></td>' for c in configs)
        rows.append('<tr><th>' + label + '</th>' + cells + '</tr>')
    return '<div class="table"><table><tr><th>Contract</th>' + headings + '</tr>' + ''.join(rows) + '</table></div>'


def ledger_source(root, ledger_bytes):
    """Pin provenance only when the working ledger matches the selected commit."""
    try:
        commit = subprocess.check_output(
            ['git', '-C', str(root), 'rev-parse', 'HEAD'], stderr=subprocess.PIPE
        ).decode().strip()
        committed = subprocess.check_output(
            ['git', '-C', str(root), 'show', f'{commit}:ledger.json'], stderr=subprocess.PIPE
        )
    except subprocess.CalledProcessError as exc:
        raise ValueError('Cannot resolve ledger.json at HEAD; build from a Git checkout with the root ledger committed') from exc
    if committed != ledger_bytes:
        raise ValueError('ledger.json differs from HEAD; commit the ledger before building a commit-pinned dashboard')
    return commit, f'https://github.com/lidofinance/multichain/blob/{commit}/ledger.json'


def build(root, output, upstream_path=None):
    root, output = Path(root), Path(output).resolve()
    upstream = GitHubSource() if upstream_path is None else LocalSource(upstream_path)
    sha = upstream.sha
    live, configs, current, report_path, report, inputs = read_upstream(upstream)
    ledger_bytes = (root / 'ledger.json').read_bytes()
    ledger_commit, ledger_url = ledger_source(root, ledger_bytes)
    ledger = json.loads(ledger_bytes)
    metadata_bytes = (root / 'components/dashboard/config/dashboard-networks.json').read_bytes()
    metadata = json.loads(metadata_bytes)
    data = dict(live=live, networks=ledger_networks(ledger, metadata),
                l1Token=deployed(ledger, 'eip155:1', 'ethereum-ethereum-wsteth-token'),
                provenance=dict(takenAt=metadata['takenAt'], docsUrl=metadata['docsUrl'],
                                ledgerUpdatedAt=ledger['updatedAt'], ledgerUrl=ledger_url),
                sources=dict(upstreamRepository=UPSTREAM, upstreamCommit=sha,
                             upstreamMode="github" if sha else "local",
                             upstreamFiles=inputs,
                             ledgerCommit=ledger_commit, ledgerSha256=digest(ledger_bytes), metadataSha256=digest(metadata_bytes)))
    data['identity'] = digest(json.dumps(data, sort_keys=True).encode())
    base = f'{UPSTREAM}/blob/{sha}/' if sha else 'upstream/'
    source_label = sha[:12] if sha else 'LOCAL DIRECTORY · unpublished changes may be included'
    provenance = ('Ledger: <a href="' + ledger_url + '">build input</a> · updated ' + html.escape(ledger['updatedAt']) +
                  ' · SHA-256 ' + data['sources']['ledgerSha256'][:12] + '<br>Testnet source: <a href="' + base + ACTIVE + '">wsteth-ccip</a> · ' + source_label +
                  ' · record ' + html.escape(live['record']) +
                  '<br><a href="dashboard-build.json">Build provenance</a> · observations are read separately via RPC.')
    evidence = '<section><h2>Dated deployment evidence</h2>' + source_text(section(current, 'Evidence and limits'), base + ACTIVE) + '</section>'
    roles = table(configs, [('POM', lambda c: c['deployed']['pool_operation_manager']),
                            ('Governance holder', lambda c: c['governance_addresses']['lido_dao_agent'])])
    roles += evidence + '<section><h2>Current POM permissions</h2>' + source_text(section(current, 'Current POM permissions'), base + ACTIVE) + '</section>'
    ccv = table(configs, [('Token', lambda c: c['addresses']['token']), ('Pool', lambda c: c['deployed']['token_pool']),
                          ('Hooks', lambda c: c['deployed']['advanced_pool_hooks']),
                          ('Resolver', lambda c: c['ccv']['verifier_resolver']),
                          ('Message ID verifier', lambda c: c['ccv']['message_id_verifier'])])
    ccv += evidence + '<section><h2>CCV configuration</h2>' + source_text(section(current, 'CCV configuration'), base + ACTIVE) + '</section>'
    pages = {}
    for name in ('index', 'roles', 'ccv'):
        text = (root / f'components/dashboard/templates/{name}.html').read_text()
        text = text.replace('<!-- BUILD_PROVENANCE -->', provenance)
        if name == 'index':
            payload = json.dumps(data).replace('<', '\\u003c').replace('>', '\\u003e').replace('&', '\\u0026')
            marker = '<script type="application/json" id="dashboard-data">{}</script>'
            if text.count(marker) != 1:
                raise ValueError('Dashboard data placeholder missing or duplicated')
            text = text.replace(marker, '<script type="application/json" id="dashboard-data">' + payload + '</script>')
        else:
            content = roles if name == 'roles' else ccv
            content = ('<p class="stamp">Public testnet · record ' + html.escape(live['deployedAt']) +
                       '</p><p><a href="' + base + report_path + '">Deployment report</a> · <a href="' + base + ACTIVE + '">Current source documentation</a></p>' + content)
            text = text.replace('<!-- BUILD_CONTENT -->', content).replace('</style>', 'pre{white-space:pre-wrap;overflow-wrap:anywhere}code{overflow-wrap:anywhere}</style>')
        pages[name + '.html'] = text
    # Only write after all inputs pass validation; no stale fallback artifact.
    output.mkdir(parents=True, exist_ok=True)
    for name, text in pages.items():
        (output / name).write_text(text)
    if isinstance(upstream, LocalSource):
        for relative, raw in upstream.files.items():
            target = output / 'upstream' / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(raw)
    (output / 'dashboard-build.json').write_text(json.dumps(data, indent=2) + '\n')
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--upstream', type=Path, help='Use this local source directory instead of GitHub')
    parser.add_argument('--output', type=Path, default=ROOT / 'docs')
    parser.add_argument('--serve', action='store_true', help='Preview the built output on localhost:8000')
    args = parser.parse_args()
    try:
        data = build(ROOT, args.output, args.upstream)
        print(f"Built {args.output}: {len(data['networks'])} ledger networks, upstream {data['sources']['upstreamCommit'] or 'local directory'}, identity {data['identity'][:12]}")
        if args.serve:
            handler = partial(SimpleHTTPRequestHandler, directory=str(args.output.resolve()))
            with ThreadingHTTPServer(('127.0.0.1', 8000), handler) as server:
                print('Preview: http://127.0.0.1:8000', flush=True)
                try:
                    server.serve_forever()
                except KeyboardInterrupt:
                    pass
    except (ValueError, KeyError, OSError) as exc:
        parser.exit(1, f'Dashboard build failed: {exc}\n')


if __name__ == '__main__':
    main()
