#!/usr/bin/env python3
"""Build the dashboard from this checkout's ledger, catalogues and dated testnet snapshot.

The build performs no network requests and requires no submodules or read token.
Registry and RPC observations are fetched separately by the visitor's browser.
"""
from __future__ import annotations

import argparse
import hashlib
import html
from datetime import date
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from html.parser import HTMLParser
import json
import re
import subprocess
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[3]  # repository root
ADDRESS = re.compile(r"0x[0-9a-fA-F]{40}\Z")
REQUIRED_TESTNET_ROLES = ('ours:POM', 'ours:pool', 'ours:hooks', 'ours:token', 'ours:verifier', 'ours:resolver')
DEPLOYMENT_REPORT = 'orchestration/wsteth-ccip/docs/deployment-2026-09-15.md'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def address(value):
    if not isinstance(value, str) or not ADDRESS.fullmatch(value) or int(value, 16) == 0:
        raise ValueError(f"Missing or invalid deployed address: {value!r}")
    return value


def iso_day(value):
    """A real calendar date written YYYY-MM-DD; the pattern alone admits 2026-02-31."""
    if not isinstance(value, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}', value):
        return False
    try:
        date.fromisoformat(value)
    except ValueError:
        return False
    return True


def https_source(value, label):
    parsed = urlsplit(value)
    if parsed.scheme != 'https' or not parsed.netloc:
        raise ValueError(f'{label} sources must be HTTPS URLs')


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


def steth_metadata(ledger, metadata):
    """Project stETH tokens from the ledger with separately sourced rate oracles."""
    source = partial(https_source, label='stETH')
    source(metadata['docsUrl'])
    source(metadata['rateSource'])
    if not iso_day(metadata['takenAt']):
        raise ValueError('Invalid stETH metadata date')
    feed = metadata['priceFeed']
    address(feed['address'])
    source(feed['source'])
    if (feed['pair'] != 'stETH / USD' or type(feed['decimals']) is not int or
            not 0 <= feed['decimals'] <= 36 or type(feed['maxAgeSeconds']) is not int or
            feed['maxAgeSeconds'] <= 0):
        raise ValueError('Invalid stETH price feed scale or heartbeat')
    rows, seen = [], set()
    for d in ledger['deployments']:
        network, contract = d['networkId'], d['contractId']
        if (not contract.endswith('-steth-token') or network == 'eip155:1' or
                d['deploymentKind'] not in ('proxy', 'standalone') or
                ledger['networks'][network]['environment'] != 'mainnet'):
            continue
        if not re.fullmatch(r'eip155:[1-9][0-9]*', network):
            raise ValueError(f'Unsupported stETH network: {network}')
        key = (network, contract)
        if key in seen:
            raise ValueError(f'Ambiguous stETH token role: {key}')
        seen.add(key)
        m = metadata['networks'].get(contract, {})
        oracle = (deployed(ledger, network, m['oracleContractId'])
                  if 'oracleContractId' in m else m.get('oracleFromDocs'))
        if oracle:
            address(oracle)
        pusher = (deployed(ledger, 'eip155:1', m['pusherContractId'])
                  if 'pusherContractId' in m else m.get('pusherFromDocs'))
        if pusher:
            address(pusher)
        for field in ('decimals', 'rateDecimals'):
            scale = m.get(field, 18 if field == 'decimals' else 27)
            if type(scale) is not int or not 0 <= scale <= 36:
                raise ValueError(f'Invalid stETH {field}')
        source(m.get('source', metadata['docsUrl']))
        rows.append(dict(chainId=int(network.split(':')[1]),
                         name=m.get('name', ledger['networks'][network]['networkName']),
                         bridge=m.get('bridge', 'Bridge not classified'),
                         token=address(d['address']), decimals=m.get('decimals', 18),
                         oracle=oracle, rateDecimals=m.get('rateDecimals', 27), pusher=pusher,
                         source=m.get('source', metadata['docsUrl']),
                         oracleSource='ledger' if 'oracleContractId' in m else 'docs' if oracle else None))
    unused = set(metadata['networks']) - {contract for _, contract in seen}
    if unused:
        raise ValueError('Unused stETH metadata contract IDs: ' + ', '.join(sorted(unused)))
    return dict(takenAt=metadata['takenAt'], docsUrl=metadata['docsUrl'], rateSource=metadata['rateSource'], priceFeed=feed,
                l1Token=deployed(ledger, 'eip155:1', 'ethereum-ethereum-steth-token'), networks=rows)


def ldo_metadata(metadata):
    """Validate the separately sourced LDO catalogue; absence is not a negative claim."""
    address(metadata['l1Token'])
    source = partial(https_source, label='LDO')
    source(metadata['l1Source'])
    if not iso_day(metadata['takenAt']):
        raise ValueError('Invalid LDO metadata date')
    seen = set()
    for row in metadata['networks']:
        chain = row['chainId']
        if type(chain) is not int or chain <= 1:
            raise ValueError('LDO destinations must have positive non-Ethereum chain IDs')
        token = address(row['token'])
        key = (chain, token.lower())
        if key in seen:
            raise ValueError('Duplicate LDO deployment')
        seen.add(key)
        if type(row['decimals']) is not int or not 0 <= row['decimals'] <= 36:
            raise ValueError('Invalid LDO decimals')
        if not row['name'] or not row['bridge']:
            raise ValueError('LDO network name and bridge are required')
        source(row['source'])
    if [f['pair'] for f in metadata['priceFeeds']] != ['LDO / ETH', 'ETH / USD']:
        raise ValueError('Expected LDO / ETH and ETH / USD price feeds in order')
    for feed in metadata['priceFeeds']:
        address(feed['address'])
        source(feed['source'])
        if (type(feed['decimals']) is not int or not 0 <= feed['decimals'] <= 36 or
                type(feed['maxAgeSeconds']) is not int or feed['maxAgeSeconds'] <= 0):
            raise ValueError('Invalid LDO price feed scale or heartbeat')
    return metadata


NETWORK_TYPE_FIELDS = {'chainId', 'name', 'type', 'source', 'category', 'archived', 'qualifier', 'note'}
L2BEAT_CATEGORIES = {'Optimistic Rollup', 'ZK Rollup', 'Optimium', 'Validium', 'Other'}
L2BEAT_PROJECT_PATH = re.compile(r'/(?:layer2s|scaling)/projects/[a-z0-9-]+/?')


def network_types_metadata(metadata):
    """Validate the sourced L2 / alt-L1 labels; a missing chain stays unclassified."""
    text = lambda value: isinstance(value, str) and value.strip() == value and bool(value)
    if not isinstance(metadata, dict) or set(metadata) != {'takenAt', 'types', 'networks'}:
        raise ValueError('Network type metadata must have takenAt, types and networks')
    if not iso_day(metadata['takenAt']):
        raise ValueError('Invalid network type metadata date')
    types = metadata['types']
    if (not isinstance(types, dict) or set(types) != {'L2', 'alt-L1'} or
            not all(text(v) for v in types.values())):
        raise ValueError('Network types must define exactly L2 and alt-L1')
    if not isinstance(metadata['networks'], list):
        raise ValueError('Network types must list networks')
    seen = set()
    for row in metadata['networks']:
        chain = row.get('chainId') if isinstance(row, dict) else None
        if type(chain) is not int or chain <= 1:
            raise ValueError('Network types must have positive non-Ethereum chain IDs')
        if chain in seen:
            raise ValueError(f'Duplicate network type for chain {chain}')
        seen.add(chain)
        invalid = lambda: ValueError(f'Invalid network type for chain {chain}')
        if not {'name', 'type', 'source'} <= set(row) <= NETWORK_TYPE_FIELDS:
            raise invalid()
        if not text(row['name']) or not isinstance(row['type'], str) or row['type'] not in types:
            raise invalid()
        if not all(text(row[k]) for k in ('qualifier', 'note') if k in row):
            raise invalid()
        # The page ends the tooltip's note sentence itself.
        if row.get('note', '').endswith('.'):
            raise invalid()
        if not isinstance(row['source'], str):
            raise invalid()
        https_source(row['source'], label='Network type')
        # An L2 claim is L2BEAT's, so it cites an L2BEAT project page and carries L2BEAT's category
        # and archive date. The path check cannot tie the page to this chain; review does that.
        # A qualifier marks where a non-L2BEAT source's own term differs from the label; on an L2 row
        # it would only be a free-text route for the stage or maturity claims the label does not make.
        if row['type'] == 'L2':
            url = urlsplit(row['source'])
            if (url.netloc != 'l2beat.com' or url.query or url.fragment or
                    not L2BEAT_PROJECT_PATH.fullmatch(url.path) or 'qualifier' in row or
                    not isinstance(row.get('category'), str) or row['category'] not in L2BEAT_CATEGORIES or
                    ('archived' in row and not iso_day(row['archived']))):
                raise invalid()
        elif 'category' in row or 'archived' in row:
            raise invalid()
    return metadata


def testnet_metadata(data):
    """Validate JSON structure before it supplies browser crawl seeds or HTML."""
    if not isinstance(data, dict) or not isinstance(data.get('live'), dict):
        raise ValueError('Testnet snapshot and live record must be objects')
    live = data['live']
    lane = live.get('lane')
    if (live.get('env') != 'testnet' or not iso_day(live.get('deployedAt')) or
            not isinstance(live.get('record'), str) or not live['record'].strip() or
            not isinstance(lane, list) or len(lane) != 2 or
            any(type(chain) is not int or chain <= 0 for chain in lane) or len(set(lane)) != 2):
        raise ValueError('Invalid testnet deployment record')
    chains = set(map(str, lane))
    if any(not isinstance(mapping, dict) or set(mapping) != chains
           for mapping in (live.get('tokens'), live.get('seeds'), data.get('governanceHolders'))):
        raise ValueError('Testnet chains must match the recorded lane')
    for chain in map(str, lane):
        token = live['tokens'][chain]
        if (not isinstance(token, dict) or token.get('chainId') != chain or
                not isinstance(token.get('chainName'), str) or not token['chainName'].strip() or
                type(token.get('decimals')) is not int or token['decimals'] != 18):
            raise ValueError('Invalid testnet token metadata')
        address(token.get('tokenAddress'))
        address(token.get('poolAddress'))
        address(data['governanceHolders'][chain])
        seeds = live['seeds'][chain]
        if (not isinstance(seeds, list) or
                any(not isinstance(seed, list) or len(seed) != 2 or not isinstance(seed[1], str)
                    for seed in seeds)):
            raise ValueError('Testnet seeds must be [address, role] pairs')
        tags = [tag for _, tag in seeds]
        for tag in REQUIRED_TESTNET_ROLES:
            if tags.count(tag) != 1:
                raise ValueError(f'Expected exactly one testnet seed: {tag}')
        seen_addresses = set()
        for value, tag in seeds:
            address(value)
            if tag not in (*REQUIRED_TESTNET_ROLES, 'ours:lockbox'):
                raise ValueError('Unknown testnet seed role')
            if value.lower() in seen_addresses:
                raise ValueError(f'Duplicate testnet seed address on chain {chain}: {value}')
            seen_addresses.add(value.lower())
        by_role = {tag: value for value, tag in seeds}
        if (by_role['ours:token'].lower() != token['tokenAddress'].lower() or
                by_role['ours:pool'].lower() != token['poolAddress'].lower()):
            raise ValueError('Testnet seeds disagree with token or pool addresses')
    if [live['tokens'][str(chain)].get('poolType') for chain in lane] != ['lockRelease', 'burnMint']:
        raise ValueError('Expected one lockRelease hub and one burnMint spoke')
    origin = data.get('origin')
    if (not isinstance(origin, dict) or not isinstance(origin.get('archiveCommit'), str) or
            not re.fullmatch(r'[0-9a-f]{40}', origin['archiveCommit']) or
            origin.get('sourceMode') != 'local' or 'sourceCommit' not in origin or origin['sourceCommit'] is not None):
        raise ValueError('Testnet origin must retain its archive commit and unpinned local source mode')
    for field in ('archivedFilesSha256', 'sourceFilesSha256'):
        hashes = origin.get(field)
        if (not isinstance(hashes, dict) or not hashes or
                any(not isinstance(value, str) or not re.fullmatch(r'[0-9a-f]{64}', value)
                    for value in hashes.values())):
            raise ValueError(f'Invalid testnet origin {field}')
    return data


def testnet_table(snapshot, fields):
    live = snapshot['live']
    chains = list(map(str, live['lane']))
    headings = ''.join('<th>' + html.escape(live['tokens'][chain]['chainName']) + '</th>' for chain in chains)
    seeds = {chain: {tag: value for value, tag in live['seeds'][chain]} for chain in chains}
    rows = []
    for label, role in fields:
        values = []
        for chain in chains:
            value = snapshot['governanceHolders'][chain] if role == 'governance' else seeds[chain][role]
            values.append('<td><code>' + html.escape(value) + '</code></td>')
        rows.append('<tr><th>' + label + '</th>' + ''.join(values) + '</tr>')
    return '<div class="table"><table><tr><th>Contract</th>' + headings + '</tr>' + ''.join(rows) + '</table></div>'


class EvidenceHTML(HTMLParser):
    """A small, inert HTML subset for maintained evidence, not a general sanitizer."""
    TAGS = {'p', 'strong', 'em', 'code', 'pre', 'h3', 'div', 'table', 'thead', 'tbody',
            'tr', 'th', 'td', 'ul', 'ol', 'li'}
    # Deliberately narrower than HTML: evidence only needs plain tags and the
    # table wrapper's class. Check completeness independently of HTMLParser's
    # version-dependent EOF recovery and incremental buffering.
    MARKUP = re.compile(r'''</?[a-zA-Z][a-zA-Z0-9]*(?:\s+class\s*=\s*(?:"table"|'table'))?\s*>''')

    def __init__(self, name):
        super().__init__(convert_charrefs=False)
        self.name, self.stack = name, []
        self.fragments = []

    def feed(self, data):
        self.fragments.append(data)

    def invalid(self):
        raise ValueError(f'Invalid evidence HTML in {self.name}: use balanced inert markup only')

    def handle_starttag(self, tag, attrs):
        if tag not in self.TAGS or any((key, value) != ('class', 'table') or tag != 'div' for key, value in attrs):
            self.invalid()
        self.stack.append(tag)

    def handle_endtag(self, tag):
        if not self.stack or self.stack.pop() != tag:
            self.invalid()

    def handle_decl(self, decl):
        self.invalid()

    def handle_pi(self, data):
        self.invalid()

    def handle_data(self, data):
        # Require literal '<' in prose to be entity-escaped.
        if '<' in data:
            self.invalid()

    def close(self):
        source = ''.join(self.fragments)
        for match in re.finditer('<', source):
            if not self.MARKUP.match(source, match.start()):
                self.invalid()
        super().feed(source)
        super().close()
        if self.stack:
            self.invalid()


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


def build(root, output):
    root, output = Path(root), Path(output).resolve()
    legacy = output / 'upstream'
    if legacy.is_symlink() or (legacy.exists() and
            (not legacy.is_dir() or any(p.is_file() or p.is_symlink() for p in legacy.rglob('*')))):
        raise ValueError(f'Legacy generated inputs remain in {legacy}; move them outside the publication directory or use a fresh --output')
    dashboard = root / 'components/dashboard'
    testnet_bytes = (dashboard / 'config/testnet-deployment.json').read_bytes()
    snapshot = testnet_metadata(json.loads(testnet_bytes))
    live = snapshot['live']
    content = {name: (dashboard / f'content/{name}.html').read_bytes()
               for name in ('evidence', 'permissions', 'ccv')}
    for name, raw in content.items():
        parser = EvidenceHTML(name)
        parser.feed(raw.decode())
        parser.close()
    templates = {name: (dashboard / f'templates/{name}.html').read_bytes()
                 for name in ('index', 'roles', 'ccv')}
    ledger_bytes = (root / 'ledger.json').read_bytes()
    ledger_commit, ledger_url = ledger_source(root, ledger_bytes)
    ledger = json.loads(ledger_bytes)
    metadata_bytes = (root / 'components/dashboard/config/dashboard-networks.json').read_bytes()
    metadata = json.loads(metadata_bytes)
    ldo_bytes = (root / 'components/dashboard/config/ldo-networks.json').read_bytes()
    steth_bytes = (root / 'components/dashboard/config/steth-networks.json').read_bytes()
    types_bytes = (root / 'components/dashboard/config/network-types.json').read_bytes()
    data = dict(live=live, networks=ledger_networks(ledger, metadata),
                ldo=ldo_metadata(json.loads(ldo_bytes)),
                steth=steth_metadata(ledger, json.loads(steth_bytes)),
                networkTypes=network_types_metadata(json.loads(types_bytes)),
                l1Token=deployed(ledger, 'eip155:1', 'ethereum-ethereum-wsteth-token'),
                provenance=dict(takenAt=metadata['takenAt'], docsUrl=metadata['docsUrl'],
                                ledgerUpdatedAt=ledger['updatedAt'], ledgerUrl=ledger_url),
                sources=dict(testnetSnapshotSha256=digest(testnet_bytes),
                             testnetContentSha256={name: digest(raw) for name, raw in content.items()},
                             templateSha256={name: digest(raw) for name, raw in templates.items()},
                             ledgerCommit=ledger_commit, ledgerSha256=digest(ledger_bytes),
                             ledgerContentSha256=digest(json.dumps(ledger, sort_keys=True, separators=(',', ':')).encode()),
                             metadataSha256=digest(metadata_bytes), ldoMetadataSha256=digest(ldo_bytes),
                             stethMetadataSha256=digest(steth_bytes),
                             networkTypesSha256=digest(types_bytes)))
    # Include every published source in the build identity used by browser caches.
    data['identity'] = digest(json.dumps(data, sort_keys=True).encode())
    archive_url = 'https://github.com/lidofinance/multichain/blob/' + snapshot['origin']['archiveCommit'] + '/'
    report_url = archive_url + DEPLOYMENT_REPORT
    source_caveat = 'Original source: LOCAL DIRECTORY · unpublished changes may be included; no source commit was recorded.'
    provenance = ('Ledger: <a href="' + ledger_url + '">build input</a> · updated ' + html.escape(ledger['updatedAt']) +
                  ' · SHA-256 ' + data['sources']['ledgerSha256'][:12] +
                  '<br>Testnet: <a href="testnet-deployment.json">archived deployment snapshot</a> · ' + html.escape(live['deployedAt']) +
                  '<br>' + source_caveat +
                  '<br><a href="dashboard-build.json">Build provenance</a> · observations are read separately via RPC.')
    evidence = '<section><h2>Dated deployment evidence</h2>' + content['evidence'].decode() + '</section>'
    roles = testnet_table(snapshot, [('POM', 'ours:POM'), ('Governance holder', 'governance')])
    roles += evidence + '<section><h2>Recorded POM permissions</h2>' + content['permissions'].decode() + '</section>'
    ccv = testnet_table(snapshot, [('Token', 'ours:token'), ('Pool', 'ours:pool'), ('Hooks', 'ours:hooks'),
                                   ('Resolver', 'ours:resolver'), ('Message ID verifier', 'ours:verifier')])
    ccv += evidence + '<section><h2>Recorded CCV configuration</h2>' + content['ccv'].decode() + '</section>'
    pages = {}
    for name in ('index', 'roles', 'ccv'):
        text = templates[name].decode()
        text = text.replace('<!-- BUILD_PROVENANCE -->', provenance)
        if name == 'index':
            for element_id, value in (("dashboard-data", data), ("ledger-data", ledger)):
                payload = json.dumps(value).replace('<', '\\u003c').replace('>', '\\u003e').replace('&', '\\u0026')
                marker = f'<script type="application/json" id="{element_id}">{{}}</script>'
                if text.count(marker) != 1:
                    raise ValueError(f'{element_id} placeholder missing or duplicated')
                text = text.replace(marker, f'<script type="application/json" id="{element_id}">' + payload + '</script>')
        else:
            page_content = roles if name == 'roles' else ccv
            page_content = ('<p class="stamp">Archived testnet snapshot · record ' + html.escape(live['deployedAt']) +
                            '</p><p>These statements describe the dated deployment; they are not refreshed by rebuilding this site. '
                            '<a href="testnet-deployment.json">Recorded addresses and original source hashes</a> · '
                            '<a href="' + report_url + '">Deployment report</a>. '
                            'Some raw records referenced by the report are unavailable; the hashes alone do not verify its claims.</p>' + page_content)
            text = text.replace('</style>', 'pre{white-space:pre-wrap;overflow-wrap:anywhere}code{overflow-wrap:anywhere}</style>', 1)
            text = text.replace('<!-- BUILD_CONTENT -->', page_content)
        pages[name + '.html'] = text
    # Only write after all inputs pass validation; no stale fallback artifact.
    output.mkdir(parents=True, exist_ok=True)
    for name, text in pages.items():
        (output / name).write_text(text)
    (output / 'testnet-deployment.json').write_bytes(testnet_bytes)
    (output / 'dashboard-build.json').write_text(json.dumps(data, indent=2) + '\n')
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'docs')
    parser.add_argument('--serve', action='store_true', help='Preview the built output on localhost:8000')
    args = parser.parse_args()
    try:
        data = build(ROOT, args.output)
        print(f"Built {args.output}: {len(data['networks'])} ledger networks, testnet snapshot {data['live']['deployedAt']}, identity {data['identity'][:12]}")
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
