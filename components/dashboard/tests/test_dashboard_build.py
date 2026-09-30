"""Regression checks for dashboard source projection; no network or Git writes."""
import copy
import base64
import io
import json
from pathlib import Path
import re
import sys
import subprocess
import tempfile
import contextlib
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit, parse_qs, unquote

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from build_dashboard import ROOT, GitHubSource, LocalSource, build, ledger_networks, read_upstream, source_text, main, ledger_source


def addr(n):
    return '0x' + format(n, '040x')


class DashboardBuildTests(unittest.TestCase):
    def setUp(self):
        self.ledger = json.loads((ROOT / 'ledger.json').read_text())
        self.metadata = json.loads((ROOT / 'components/dashboard/config/dashboard-networks.json').read_text())


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
            result = {'networks': [], 'sources': {'upstreamCommit': None}, 'identity': 'test'}
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
                patch('build_dashboard.subprocess.check_output', side_effect=[b'c' * 40, (ROOT / 'ledger.json').read_bytes()] * 2):
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
