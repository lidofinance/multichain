"""Regression checks for dashboard source projection; no network or Git writes."""
import copy
import hashlib
import base64
import io
import json
from pathlib import Path
import re
import sys
import subprocess
import shutil
import tempfile
import contextlib
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit, parse_qs, unquote

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from build_dashboard import ROOT, GitHubSource, LocalSource, build, ledger_networks, ldo_metadata, steth_metadata, read_upstream, source_text, main, ledger_source


def addr(n):
    return '0x' + format(n, '040x')


class DashboardBuildTests(unittest.TestCase):
    def setUp(self):
        self.ledger = json.loads((ROOT / 'ledger.json').read_text())
        self.metadata = json.loads((ROOT / 'components/dashboard/config/dashboard-networks.json').read_text())
        self.ldo = json.loads((ROOT / 'components/dashboard/config/ldo-networks.json').read_text())
        self.steth = json.loads((ROOT / 'components/dashboard/config/steth-networks.json').read_text())

    def test_steth_projects_ledger_tokens_and_sourced_rate_oracles(self):
        data = steth_metadata(self.ledger, self.steth)
        rows = {row['chainId']: row for row in data['networks']}
        self.assertEqual(set(rows), {10, 130, 1868})
        self.assertEqual(rows[10]['token'], '0x76A50b8c7349cCDDb7578c6627e79b5d99D24138')
        self.assertEqual(rows[10]['oracleSource'], 'ledger')
        self.assertEqual(rows[1868]['oracleSource'], 'docs')
        self.assertEqual(rows[1868]['oracle'], '0xDff6f372e8c16b2b9e95c55bDfe74C0bA3F90265')
        self.assertTrue(all(r['rateDecimals'] == 27 and r['decimals'] == 18 for r in rows.values()))
        for field, value in [('rateDecimals', -1), ('oracleFromDocs', addr(0)), ('source', 'http://example.com')]:
            metadata = copy.deepcopy(self.steth)
            metadata['networks']['soneium-soneium-steth-token'][field] = value
            with self.assertRaises(ValueError):
                steth_metadata(self.ledger, metadata)
        self.steth['priceFeed']['maxAgeSeconds'] = 0
        with self.assertRaisesRegex(ValueError, 'heartbeat'):
            steth_metadata(self.ledger, self.steth)

    def test_steth_rejects_unused_metadata_but_allows_new_unclassified_tokens(self):
        metadata = copy.deepcopy(self.steth)
        metadata['networks']['typo-steth-token'] = metadata['networks'].pop('soneium-soneium-steth-token')
        with self.assertRaisesRegex(ValueError, 'Unused stETH metadata.*typo-steth-token'):
            steth_metadata(self.ledger, metadata)
        self.ledger['networks']['eip155:999'] = dict(networkName='new-mainnet', environment='mainnet')
        self.ledger['deployments'].append(dict(contractId='new-new-steth-token', networkId='eip155:999',
                                               address=addr(200), deploymentKind='standalone'))
        row = steth_metadata(self.ledger, self.steth)['networks'][-1]
        self.assertEqual(row['bridge'], 'Bridge not classified')
        self.assertIsNone(row['oracle'])

    def test_explicit_reused_build_is_reproducible_and_does_not_fetch_upstream(self):
        saved = ROOT / 'docs/upstream/dashboard-build.json'
        with tempfile.TemporaryDirectory() as tmp, patch('build_dashboard.GitHubSource') as remote:
            first, second = Path(tmp) / 'first', Path(tmp) / 'second'
            first.mkdir()
            (first / 'roles.html').write_text('original companion evidence')
            data = build(ROOT, first, reuse_build=saved)
            again = build(ROOT, second, reuse_build=saved)
            remote.assert_not_called()
            self.assertEqual(data, again)
            for name in ('index.html', 'dashboard-build.json', 'upstream/dashboard-build.json'):
                self.assertEqual((first / name).read_bytes(), (second / name).read_bytes())
            self.assertEqual((first / 'roles.html').read_text(), 'original companion evidence')
            self.assertFalse((second / 'ccv.html').exists())
            self.assertEqual(data['sources']['upstreamMode'], 'reused-build')
            self.assertIn('REUSED BUILD DATA', (first / 'index.html').read_text())
            self.assertEqual(data['steth'], steth_metadata(self.ledger, self.steth))
            self.assertNotIn('ledger', data)
            with self.assertRaisesRegex(ValueError, 'mutually exclusive'):
                build(ROOT, second, upstream_path=Path(tmp), reuse_build=saved)
            bad = json.loads(saved.read_text())
            bad['live']['record'] = 'tampered'
            corrupt = Path(tmp) / 'corrupt.json'
            corrupt.write_text(json.dumps(bad))
            before = (first / 'index.html').read_bytes()
            with self.assertRaisesRegex(ValueError, 'identity'):
                build(ROOT, first, reuse_build=corrupt)
            self.assertEqual((first / 'index.html').read_bytes(), before)

    def test_ldo_catalogue_rejects_duplicate_tokens_and_invalid_sources_or_scales(self):
        self.assertEqual(len(ldo_metadata(self.ldo)['networks']), 6)
        for field, value in [('token', addr(0)), ('chainId', 1), ('chainId', True),
                             ('decimals', -1), ('source', 'javascript:alert(1)')]:
            metadata = copy.deepcopy(self.ldo)
            metadata['networks'][0][field] = value
            with self.assertRaises(ValueError):
                ldo_metadata(metadata)
        self.ldo['networks'].append(copy.deepcopy(self.ldo['networks'][0]))
        with self.assertRaisesRegex(ValueError, 'Duplicate LDO'):
            ldo_metadata(self.ldo)

    def test_ldo_prices_require_declared_pairs_and_positive_heartbeat(self):
        self.ldo['priceFeeds'][0]['maxAgeSeconds'] = 0
        with self.assertRaisesRegex(ValueError, 'heartbeat'):
            ldo_metadata(self.ldo)
        self.ldo['priceFeeds'].reverse()
        with self.assertRaisesRegex(ValueError, 'price feeds in order'):
            ldo_metadata(self.ldo)

    def test_ldo_catalogue_changes_invalidate_build_identity(self):
        self.upstream()
        with tempfile.TemporaryDirectory() as tmp, \
                patch('build_dashboard.subprocess.check_output', side_effect=[b'c' * 40, (ROOT / 'ledger.json').read_bytes()] * 2):
            root = Path(tmp) / 'repo'
            shutil.copytree(ROOT / 'components/dashboard', root / 'components/dashboard')
            shutil.copyfile(ROOT / 'ledger.json', root / 'ledger.json')
            local = Path(tmp) / 'upstream'
            for relative, text in self.files.items():
                path = local / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)
            output = Path(tmp) / 'site'
            before = build(root, output, upstream_path=local)
            metadata = root / 'components/dashboard/config/ldo-networks.json'
            self.ldo['networks'][0]['token'] = addr(777)
            metadata.write_text(json.dumps(self.ldo))
            after = build(root, output, upstream_path=local)
            self.assertNotEqual(before['identity'], after['identity'])
            self.assertNotEqual(before['sources']['ldoMetadataSha256'], after['sources']['ldoMetadataSha256'])
            self.assertEqual(after['ldo']['networks'][0]['token'], addr(777))

    def test_ledger_provenance_rejects_uncommitted_input(self):
        with patch('build_dashboard.subprocess.check_output', side_effect=[b'a' * 40, b'committed ledger']), \
                self.assertRaisesRegex(ValueError, 'ledger.json differs from HEAD'):
            ledger_source(ROOT, b'uncommitted ledger')

    def test_ledger_provenance_reads_root_catalogue(self):
        commit = 'c' * 40
        with patch('build_dashboard.subprocess.check_output', side_effect=[commit.encode(), b'ledger']) as git:
            revision, url = ledger_source(ROOT, b'ledger')
        self.assertEqual(revision, commit)
        self.assertEqual(git.call_args.args[0][-1], f'{commit}:ledger.json')
        self.assertEqual(url, f'https://github.com/lidofinance/multichain/blob/{commit}/ledger.json')

    def test_ledger_provenance_with_real_git(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            def git(*args):
                return subprocess.check_output(['git', '-C', str(root), *args], stderr=subprocess.PIPE)
            git('init', '-q')
            (root / 'ledger.json').write_bytes(b'{"root":true}\n')
            git('add', 'ledger.json')
            git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture')
            revision, url = ledger_source(root, (root / 'ledger.json').read_bytes())
            self.assertEqual(revision, git('rev-parse', 'HEAD').decode().strip())
            self.assertTrue(url.endswith(f'{revision}/ledger.json'))
            with self.assertRaisesRegex(ValueError, 'differs from HEAD'):
                ledger_source(root, b'changed')

    def test_preview_serves_selected_output_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / 'custom site'
            result = {'networks': [], 'sources': {'upstreamCommit': None, 'upstreamMode': 'local'}, 'identity': 'test'}
            with patch('sys.argv', ['build_dashboard.py', '--serve', '--output', str(output)]), \
                    patch('build_dashboard.build', return_value=result) as builder, \
                    patch('build_dashboard.ThreadingHTTPServer') as server, \
                    contextlib.redirect_stdout(io.StringIO()):
                main()
            self.assertEqual(builder.call_args.args, (ROOT, output, None))
            bind, handler = server.call_args.args
            self.assertEqual(bind, ('127.0.0.1', 8000))
            self.assertEqual(handler.keywords['directory'], str(output.resolve()))
            server.return_value.__enter__.return_value.serve_forever.assert_called_once()

    def test_ledger_address_changes_and_new_networks(self):
        for d in self.ledger['deployments']:
            if d['contractId'] == 'base-base-wsteth-token' and d['deploymentKind'] == 'proxy':
                d['address'] = addr(100)
            if d['contractId'] == 'base-ethereum-l1-token-bridge' and d['deploymentKind'] == 'proxy':
                d['address'] = addr(101)
        rows = ledger_networks(self.ledger, self.metadata)
        base = next(r for r in rows if r['chainId'] == 8453)
        self.assertEqual((base['token'], base['escrow']), (addr(100), addr(101)))
        self.assertEqual(len(rows), 15)  # Implementations, admins and testnets excluded.
        self.ledger['networks']['eip155:999'] = dict(networkName='new-mainnet', environment='mainnet')
        self.ledger['deployments'].append(dict(contractId='new-new-wsteth-token', networkId='eip155:999',
                                               address=addr(200), deploymentKind='standalone'))
        new = ledger_networks(self.ledger, self.metadata)[-1]
        self.assertEqual(new['group'], 'unclassified')
        self.assertIsNone(new['escrow'])

    def test_missing_or_ambiguous_ledger_role_fails(self):
        proxy = next(d for d in self.ledger['deployments'] if d['contractId'] == 'base-ethereum-l1-token-bridge' and d['deploymentKind'] == 'proxy')
        self.ledger['deployments'].append(copy.deepcopy(proxy))
        with self.assertRaisesRegex(ValueError, 'Expected one deployed'):
            ledger_networks(self.ledger, self.metadata)
        self.ledger['deployments'] = [d for d in self.ledger['deployments'] if d['contractId'] != proxy['contractId']]
        with self.assertRaisesRegex(ValueError, 'Expected one deployed'):
            ledger_networks(self.ledger, self.metadata)

    def upstream(self):
        record = 'config/chains.live-mantle-2026-09-15'
        self.sha = 'a' * 40
        self.requests = []
        self.files = {}
        self.files['docs/CURRENT-DEPLOYMENT.md'] = ('''# Current deployment
[record](../config/chains.live-mantle-2026-09-15/)
## Evidence and limits
New evidence; no live delivery claim.
## Current POM permissions
| Role | Holder |
| --- | --- |
| ADMIN | Agent |
### Queue rules
The delay is **3 days**.
## CCV configuration
One resolver; no delivery claim.
''')
        self.files['docs/deployment-2026-09-15.md'] = 'Dated report'
        for i, name, peer, kind in [(1, 'sepolia', 'mantle_sepolia', 'SiloedLockRelease'), (2, 'mantle_sepolia', 'sepolia', 'BurnMint')]:
            data = dict(chain=dict(chain_id=i, chain_name=name, pool_type=kind),
                        addresses=dict(token=addr(i * 10)),
                        deployed=dict(token_pool=addr(i * 10 + 1), pool_operation_manager=addr(i * 10 + 2),
                                      advanced_pool_hooks=addr(i * 10 + 3), lock_boxes=[]),
                        ccv=dict(message_id_verifier=addr(i * 10 + 4), verifier_resolver=addr(i * 10 + 5)),
                        governance_addresses=dict(lido_dao_agent=addr(i * 10 + 6)),
                        remote_lanes=[dict(remote_chain_name=peer)])
            self.files[record + '/' + name + '.json'] = json.dumps(data)
        return record

    def response(self, request, timeout):
        self.requests.append(request)
        self.assertEqual(timeout, 30)
        url = urlsplit(request.full_url)
        prefix = '/repos/lidofinance/wsteth-ccip/'
        self.assertEqual((url.scheme, url.netloc), ('https', 'api.github.com'))
        path = unquote(url.path.removeprefix(prefix))
        if path == 'commits/main':
            data = {'sha': self.sha}
        else:
            self.assertEqual(parse_qs(url.query), {'ref': [self.sha]})
            path = path.removeprefix('contents/')
            if path in self.files:
                data = dict(type='file', encoding='base64', content=base64.b64encode(self.files[path].encode()).decode())
            else:
                data = [dict(type='file', name=p.rsplit('/', 1)[1], path=p)
                        for p in self.files if p.rsplit('/', 1)[0] == path]
                if not data:
                    raise HTTPError(request.full_url, 404, 'missing', {}, None)
        return io.BytesIO(json.dumps(data).encode())

    def test_missing_record_never_falls_back(self):
        record = self.upstream()
        del self.files[record + '/sepolia.json']
        with patch('build_dashboard.urlopen', side_effect=self.response):
            with self.assertRaisesRegex(ValueError, 'Expected two chain JSON'):
                read_upstream(GitHubSource())
        del self.files['docs/CURRENT-DEPLOYMENT.md']
        with patch('build_dashboard.urlopen', side_effect=self.response):
            with self.assertRaisesRegex(ValueError, 'GitHub HTTP 404'):
                read_upstream(GitHubSource())

    def test_invalid_addresses_and_lane_fail(self):
        record = self.upstream()
        path = record + '/sepolia.json'
        data = json.loads(self.files[path])
        data['remote_lanes'] = []
        self.files[path] = json.dumps(data)
        with patch('build_dashboard.urlopen', side_effect=self.response):
            with self.assertRaisesRegex(ValueError, 'reciprocal lane'):
                read_upstream(GitHubSource())
            data['addresses']['token'] = addr(0)
            self.files[path] = json.dumps(data)
            with self.assertRaisesRegex(ValueError, 'invalid deployed address'):
                read_upstream(GitHubSource())

    def test_build_fetches_main_once_and_pins_files_and_cache(self):
        record = self.upstream()
        with tempfile.TemporaryDirectory() as tmp, patch('build_dashboard.urlopen', side_effect=self.response), \
                patch('build_dashboard.subprocess.check_output', side_effect=[b'c' * 40, (ROOT / 'ledger.json').read_bytes()] * 3):
            output = Path(tmp) / 'site'
            before = build(ROOT, output)
            self.assertFalse((output / 'ledger.json').exists())
            commit = before['sources']['ledgerCommit']
            url = f'https://github.com/lidofinance/multichain/blob/{commit}/ledger.json'
            self.assertEqual(before['provenance']['ledgerUrl'], url)
            self.assertIn(url, (output / 'index.html').read_text())
            page = (output / 'index.html').read_text()
            payload = json.loads(re.search(r'id="dashboard-data">(.*?)</script>', page).group(1))
            self.assertEqual(payload['identity'], before['identity'])
            self.assertEqual(payload['ldo'], self.ldo)
            self.assertIn('ldoMetadataSha256', payload['sources'])
            self.assertIn('stethMetadataSha256', payload['sources'])
            self.assertEqual(payload['steth'], steth_metadata(self.ledger, self.steth))
            self.assertNotIn('ledger', payload)
            embedded_ledger = json.loads(re.search(r'id="ledger-data">(.*?)</script>', page).group(1))
            self.assertEqual(embedded_ledger, self.ledger)
            content_hash = lambda value: hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
            self.assertEqual(payload['sources']['ledgerContentSha256'], content_hash(embedded_ledger))
            tampered = copy.deepcopy(embedded_ledger)
            tampered['deployments'][0]['address'] = '0x' + '0' * 40
            self.assertNotEqual(payload['sources']['ledgerContentSha256'], content_hash(tampered))
            manifest = json.loads((output / 'dashboard-build.json').read_text())
            self.assertNotIn('ledger', manifest)
            identity = manifest.pop('identity')
            self.assertEqual(identity, hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest())
            # A compact original manifest remains a valid source for explicit reuse.
            reused = build(ROOT, Path(tmp) / 'reused', reuse_build=output / 'dashboard-build.json')
            self.assertEqual(reused['live'], before['live'])
            self.assertIn(self.sha, (output / 'roles.html').read_text())
            self.assertIn('New evidence', (output / 'ccv.html').read_text())
            self.assertNotIn('431', (output / 'ccv.html').read_text())
            self.assertEqual(sum(r.full_url.endswith('/commits/main') for r in self.requests), 1)
            self.assertEqual(len(self.requests), 6)  # main, active doc, report, directory, two configs
            self.sha = 'b' * 40
            path = record + '/sepolia.json'
            data = json.loads(self.files[path]); data['addresses']['token'] = addr(999)
            self.files[path] = json.dumps(data)
            after = build(ROOT, output)
            self.assertNotEqual(before['identity'], after['identity'])
            self.assertFalse((output / 'index.snapshot.json').exists())
            self.assertEqual(after['live']['tokens']['1']['tokenAddress'], addr(999))
            self.assertEqual(after['sources']['upstreamCommit'], self.sha)
            self.assertEqual(sum(r.full_url.endswith('/commits/main') for r in self.requests), 2)

    def test_authentication_and_failures_without_local_fallback(self):
        self.upstream()
        with patch.dict('os.environ', {'WSTETH_CCIP_READ_TOKEN': 'test-secret'}), patch('build_dashboard.urlopen', side_effect=self.response):
            GitHubSource()
            self.assertEqual(self.requests[0].get_header('Authorization'), 'Bearer test-secret')
        for failure in (HTTPError('https://api.github.com/', 401, 'unauthorized', {}, None), URLError('offline')):
            with tempfile.TemporaryDirectory() as tmp, patch('build_dashboard.urlopen', side_effect=failure):
                output = Path(tmp) / 'site'
                with self.assertRaises(ValueError) as raised:
                    build(ROOT, output)
                self.assertNotIn('test-secret', str(raised.exception))
                self.assertFalse(output.exists())

    def test_explicit_local_directory_uses_working_files_without_network(self):
        record = self.upstream()
        with tempfile.TemporaryDirectory() as tmp, patch('build_dashboard.urlopen', side_effect=AssertionError('Network must not be used')), \
                patch('build_dashboard.subprocess.check_output', side_effect=[b'c' * 40, (ROOT / 'ledger.json').read_bytes()] * 3):
            local = Path(tmp) / 'local source'
            output = Path(tmp) / 'site'
            for relative, text in self.files.items():
                path = local / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)
            before = build(ROOT, output, upstream_path=local)
            self.assertEqual(before['sources']['upstreamMode'], 'local')
            self.assertIsNone(before['sources']['upstreamCommit'])
            self.assertIn('LOCAL DIRECTORY', (output / 'index.html').read_text())
            self.assertNotIn(str(local), (output / 'dashboard-build.json').read_text())
            for relative, text in self.files.items():
                self.assertEqual((output / 'upstream' / relative).read_text(), text)
            path = local / record / 'sepolia.json'
            data = json.loads(path.read_text()); data['addresses']['token'] = addr(888)
            path.write_text(json.dumps(data))
            after = build(ROOT, output, upstream_path=local)
            self.assertNotEqual(before['identity'], after['identity'])
            self.assertEqual(after['live']['tokens']['1']['tokenAddress'], addr(888))
            (local / 'docs/CURRENT-DEPLOYMENT.md').unlink()
            with self.assertRaisesRegex(ValueError, 'Missing local upstream input'):
                build(ROOT, output, upstream_path=local)

    def test_local_directory_must_exist_and_inputs_stay_inside_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with self.assertRaisesRegex(ValueError, 'directory does not exist'):
                LocalSource(root / 'missing')
            outside = root / 'outside.md'
            outside.write_text('outside')
            local = root / 'local'
            local.mkdir()
            (local / 'escape.md').symlink_to(outside)
            with self.assertRaisesRegex(ValueError, 'escapes source directory'):
                LocalSource(local).read('escape.md')

    def test_untrusted_source_is_escaped(self):
        rendered = source_text('<script>alert(1)</script>\n\n**bold** and `code`')
        self.assertNotIn('<script>', rendered)
        self.assertIn('&lt;script&gt;', rendered)
        self.assertIn('<strong>bold</strong>', rendered)
        links = source_text('[config](../config/input.json) [bad](javascript:alert)',
                            'https://github.com/owner/repo/blob/abc/docs/current.md')
        self.assertIn('href="https://github.com/owner/repo/blob/abc/config/input.json"', links)
        self.assertNotIn('href="javascript:', links)


if __name__ == '__main__':
    unittest.main()
