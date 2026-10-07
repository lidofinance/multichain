"""Regression checks for dashboard source projection; no network or Git writes."""
import copy
import hashlib
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

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from build_dashboard import ROOT, EvidenceHTML, build, ledger_networks, ldo_metadata, network_types_metadata, steth_metadata, testnet_metadata, main, ledger_source


def addr(n):
    return '0x' + format(n, '040x')


class DashboardBuildTests(unittest.TestCase):
    def setUp(self):
        self.ledger = json.loads((ROOT / 'ledger.json').read_text())
        self.metadata = json.loads((ROOT / 'components/dashboard/config/dashboard-networks.json').read_text())
        self.ldo = json.loads((ROOT / 'components/dashboard/config/ldo-networks.json').read_text())
        self.steth = json.loads((ROOT / 'components/dashboard/config/steth-networks.json').read_text())
        self.types = json.loads((ROOT / 'components/dashboard/config/network-types.json').read_text())

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

    def test_ldo_catalogue_rejects_duplicate_tokens_and_invalid_sources_or_scales(self):
        self.assertEqual(len(ldo_metadata(self.ldo)['networks']), 6)
        for field, value in [('token', addr(0)), ('chainId', 1), ('chainId', True),
                             ('decimals', -1), ('source', 'javascript:alert(1)')]:
            metadata = copy.deepcopy(self.ldo)
            metadata['networks'][0][field] = value
            with self.assertRaises(ValueError):
                ldo_metadata(metadata)
        for day in ('2026-02-31', '2026-13-01'):
            metadata = copy.deepcopy(self.ldo)
            metadata['takenAt'] = day
            with self.assertRaisesRegex(ValueError, 'Invalid LDO metadata date'):
                ldo_metadata(metadata)
        self.ldo['networks'].append(copy.deepcopy(self.ldo['networks'][0]))
        with self.assertRaisesRegex(ValueError, 'Duplicate LDO'):
            ldo_metadata(self.ldo)

    def test_network_types_classify_every_configured_mainnet_network(self):
        types = {row['chainId']: row['type'] for row in network_types_metadata(self.types)['networks']}
        configured = ({row['chainId'] for row in ledger_networks(self.ledger, self.metadata)} |
                      {row['chainId'] for row in steth_metadata(self.ledger, self.steth)['networks']} |
                      {row['chainId'] for row in ldo_metadata(self.ldo)['networks']})
        self.assertEqual(configured - set(types), set())
        self.assertEqual(types[42161], 'L2')
        self.assertEqual(types[56], 'alt-L1')
        # A catalogue name must agree with the configured name, so a mistyped chain ID shows up here.
        names = {}
        for row in (ledger_networks(self.ledger, self.metadata) + steth_metadata(self.ledger, self.steth)['networks'] +
                    ldo_metadata(self.ldo)['networks']):
            names.setdefault(row['chainId'], set()).add(row['name'])
        for row in self.types['networks']:
            if row['chainId'] in names:
                self.assertIn(row['name'], names[row['chainId']], row['chainId'])

    def test_network_types_reject_duplicates_unknown_labels_and_unsafe_sources(self):
        l2, alt = (next(i for i, r in enumerate(self.types['networks']) if r['type'] == t) for t in ('L2', 'alt-L1'))
        for row, field, value in [(l2, 'chainId', 1), (l2, 'chainId', True), (l2, 'type', 'L3'), (l2, 'type', ['L2']),
                                  (l2, 'name', ''), (l2, 'name', 5), (l2, 'source', 'javascript:alert(1)'), (l2, 'source', 5),
                                  (l2, 'note', 5), (l2, 'note', {}), (alt, 'qualifier', ''), (alt, 'qualifier', 5),
                                  (l2, 'stage', 'Stage 1'), (l2, 'qualifier', 'Stage 2'),
                                  (l2, 'source', 'https://example.com/x'), (l2, 'source', 'https://l2beat.com.example/x'),
                                  (l2, 'source', 'https://l2beat.com/'), (l2, 'source', 'https://l2beat.com/scaling/summary'),
                                  (l2, 'source', 'https://l2beat.com:8443/scaling/projects/base'),
                                  (l2, 'source', 'https://l2beat.com:443/scaling/projects/base'),
                                  (l2, 'source', 'https://x@l2beat.com/layer2s/projects/base'),
                                  (l2, 'source', 'https://:secret@l2beat.com/layer2s/projects/base'),
                                  (l2, 'source', 'https://l2beat.com/scaling/projects/base?stage=2'),
                                  (l2, 'source', 'https://l2beat.com/scaling/projects/base#Stage-2'),
                                  (l2, 'source', 'https://l2beat.com/scaling/projects/'), (alt, 'note', 'Own PoS validator set.'),
                                  (l2, 'category', 'Sidechain'), (l2, 'category', ['Other']), (l2, 'category', {}),
                                  (l2, 'archived', 'May 2026'), (l2, 'archived', '2026-02-30'), (l2, 'archived', 20260527),
                                  (alt, 'category', 'Other'), (alt, 'archived', '2026-05-27')]:
            metadata = copy.deepcopy(self.types)
            metadata['networks'][row][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                network_types_metadata(metadata)
        metadata = copy.deepcopy(self.types)
        metadata['networks'][l2]['source'] = 'https://l2beat.com/scaling/projects/arbitrum'
        network_types_metadata(metadata)  # L2BEAT's current project path is accepted beside /layer2s/.
        for row, field in [(l2, 'chainId'), (l2, 'name'), (l2, 'source'), (l2, 'category')]:
            metadata = copy.deepcopy(self.types)
            del metadata['networks'][row][field]
            with self.subTest(missing=field), self.assertRaises(ValueError):
                network_types_metadata(metadata)
        for mutate in [lambda m: m['types'].update({'L2': 5}), lambda m: m.update(networks={}),
                       lambda m: m.update(takenAt=20261007), lambda m: m.update(takenAt='2026-99-99'),
                       lambda m: m.update(takenAt='2026-02-31'), lambda m: m.pop('takenAt')]:
            metadata = copy.deepcopy(self.types)
            mutate(metadata)
            with self.subTest(mutate=mutate), self.assertRaises(ValueError):
                network_types_metadata(metadata)
        metadata = copy.deepcopy(self.types)
        metadata['types']['sidechain'] = 'not a supported label'
        with self.assertRaisesRegex(ValueError, 'exactly L2 and alt-L1'):
            network_types_metadata(metadata)
        self.types['networks'].append(copy.deepcopy(self.types['networks'][0]))
        with self.assertRaisesRegex(ValueError, 'Duplicate network type'):
            network_types_metadata(self.types)

    def test_ldo_prices_require_declared_pairs_and_positive_heartbeat(self):
        self.ldo['priceFeeds'][0]['maxAgeSeconds'] = 0
        with self.assertRaisesRegex(ValueError, 'heartbeat'):
            ldo_metadata(self.ldo)
        self.ldo['priceFeeds'].reverse()
        with self.assertRaisesRegex(ValueError, 'price feeds in order'):
            ldo_metadata(self.ldo)

    def test_ldo_catalogue_changes_invalidate_build_identity(self):
        with tempfile.TemporaryDirectory() as tmp, \
                patch('build_dashboard.subprocess.check_output', side_effect=[b'c' * 40, (ROOT / 'ledger.json').read_bytes()] * 2):
            root = Path(tmp) / 'repo'
            shutil.copytree(ROOT / 'components/dashboard', root / 'components/dashboard')
            shutil.copyfile(ROOT / 'ledger.json', root / 'ledger.json')
            output = Path(tmp) / 'site'
            before = build(root, output)
            metadata = root / 'components/dashboard/config/ldo-networks.json'
            self.ldo['networks'][0]['token'] = addr(777)
            metadata.write_text(json.dumps(self.ldo))
            after = build(root, output)
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
            result = {'networks': [], 'live': {'deployedAt': '2026-09-15'}, 'identity': 'test'}
            with patch('sys.argv', ['build_dashboard.py', '--serve', '--output', str(output)]), \
                    patch('build_dashboard.build', return_value=result) as builder, \
                    patch('build_dashboard.ThreadingHTTPServer') as server, \
                    contextlib.redirect_stdout(io.StringIO()):
                main()
            self.assertEqual(builder.call_args.args, (ROOT, output))
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


    def test_build_from_checkout_is_offline_complete_and_reproducible(self):
        # A clean Pages output must contain all pages without consulting old docs/ or any network.
        with tempfile.TemporaryDirectory() as tmp, \
                patch('socket.socket', side_effect=AssertionError('Network must not be used')):
            root = Path(tmp) / 'repo'
            shutil.copytree(ROOT / 'components/dashboard', root / 'components/dashboard')
            shutil.copyfile(ROOT / 'ledger.json', root / 'ledger.json')
            with patch('build_dashboard.subprocess.check_output', side_effect=[b'c' * 40, (ROOT / 'ledger.json').read_bytes()] * 2):
                first, second = Path(tmp) / 'first', Path(tmp) / 'second'
                before = build(root, first)
                again = build(root, second)
            self.assertEqual(before, again)
            self.assertEqual({p.name for p in first.iterdir()},
                             {'index.html', 'roles.html', 'ccv.html', 'dashboard-build.json', 'testnet-deployment.json'})
            for path in first.iterdir():
                self.assertEqual(path.read_bytes(), (second / path.name).read_bytes())
            page = (first / 'index.html').read_text()
            payload = json.loads(re.search(r'id="dashboard-data">(.*?)</script>', page).group(1))
            self.assertEqual(payload, before)
            self.assertEqual(payload['ldo'], self.ldo)
            self.assertEqual(payload['networkTypes'], self.types)
            self.assertEqual(payload['steth'], steth_metadata(self.ledger, self.steth))
            self.assertNotIn('ledger', payload)
            embedded = json.loads(re.search(r'id="ledger-data">(.*?)</script>', page).group(1))
            self.assertEqual(embedded, self.ledger)
            content_hash = hashlib.sha256(json.dumps(embedded, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
            self.assertEqual(payload['sources']['ledgerContentSha256'], content_hash)
            manifest = json.loads((first / 'dashboard-build.json').read_text())
            identity = manifest.pop('identity')
            self.assertEqual(identity, hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest())
            self.assertIn(before['provenance']['ledgerUrl'], page)
            snapshot = json.loads((first / 'testnet-deployment.json').read_text())
            self.assertEqual(snapshot['live'], before['live'])
            origin = snapshot['origin']
            self.assertEqual(origin['sourceMode'], 'local')
            self.assertIsNone(origin['sourceCommit'])
            self.assertEqual(origin['sourceFilesSha256']['docs/deployment-2026-09-15.md'],
                             'af91dad2dd610e96065e7b318fb3f69496536a7b9eae433f66ae1463acc53e76')
            self.assertEqual(len(origin['sourceFilesSha256']), 4)
            self.assertEqual(len(origin['archivedFilesSha256']), 3)
            for name in ('index', 'roles', 'ccv'):
                html = (first / f'{name}.html').read_text()
                self.assertIn('archived deployment snapshot', html)
                self.assertIn('LOCAL DIRECTORY · unpublished changes may be included', html)
                self.assertIn('testnet-deployment.json', html)
                self.assertNotIn('upstream/', html)
                self.assertNotIn('github.com/lidofinance/wsteth-ccip', html)
                self.assertNotIn('<!-- BUILD_', html)
                if name != 'index':
                    self.assertIn('https://github.com/lidofinance/multichain/blob/' + origin['archiveCommit'] +
                                  '/orchestration/wsteth-ccip/docs/deployment-2026-09-15.md', html)
                    self.assertIn('hashes alone do not verify its claims', html)
                    self.assertEqual(html.count('pre{white-space:pre-wrap;overflow-wrap:anywhere}'), 1)
            self.assertNotRegex((first / 'roles.html').read_text(), r'\]\(\.\./config/')
            self.assertIn('431 live state checks', (first / 'roles.html').read_text())
            self.assertIn('DummyMessageIdVerifier', (first / 'ccv.html').read_text())
            for chain in snapshot['live']['lane']:
                token = snapshot['live']['tokens'][str(chain)]
                self.assertIn(token['tokenAddress'], (first / 'ccv.html').read_text())
                self.assertIn(snapshot['governanceHolders'][str(chain)], (first / 'roles.html').read_text())

    def test_snapshot_updates_addresses_tables_and_identity(self):
        with tempfile.TemporaryDirectory() as tmp, \
                patch('build_dashboard.subprocess.check_output', side_effect=[b'c' * 40, (ROOT / 'ledger.json').read_bytes()] * 3):
            root = Path(tmp) / 'repo'
            shutil.copytree(ROOT / 'components/dashboard', root / 'components/dashboard')
            shutil.copyfile(ROOT / 'ledger.json', root / 'ledger.json')
            output = Path(tmp) / 'site'
            before = build(root, output)
            path = root / 'components/dashboard/config/testnet-deployment.json'
            snapshot = json.loads(path.read_text())
            chain = str(snapshot['live']['lane'][0])
            snapshot['live']['tokens'][chain]['tokenAddress'] = addr(999)
            next(seed for seed in snapshot['live']['seeds'][chain] if seed[1] == 'ours:token')[0] = addr(999)
            path.write_text(json.dumps(snapshot))
            after = build(root, output)
            self.assertNotEqual(before['identity'], after['identity'])
            self.assertNotEqual(before['sources']['testnetSnapshotSha256'], after['sources']['testnetSnapshotSha256'])
            self.assertEqual(after['live']['tokens'][chain]['tokenAddress'], addr(999))
            self.assertIn(addr(999), (output / 'ccv.html').read_text())
            evidence = root / 'components/dashboard/content/evidence.html'
            evidence.write_text('<p>Changed dated evidence</p>')
            updated = build(root, output)
            self.assertNotEqual(after['identity'], updated['identity'])
            self.assertIn('Changed dated evidence', (output / 'roles.html').read_text())

    def test_missing_snapshot_fails_before_writing(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / 'site'
            with self.assertRaises(FileNotFoundError):
                build(Path(tmp), output)
            self.assertFalse(output.exists())

    def test_invalid_testnet_snapshot_is_rejected(self):
        original = json.loads((ROOT / 'components/dashboard/config/testnet-deployment.json').read_text())
        for field, value in [('env', 'mainnet'), ('deployedAt', '2026-02-31'),
                             ('lane', [1, 1]), ('lane', [True, 5003]), ('lane', [1]), ('record', '')]:
            snapshot = copy.deepcopy(original)
            snapshot['live'][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                testnet_metadata(snapshot)
        chain = str(original['live']['lane'][0])
        for field in ('tokenAddress', 'poolAddress'):
            snapshot = copy.deepcopy(original)
            snapshot['live']['tokens'][chain][field] = addr(0)
            with self.assertRaises(ValueError):
                testnet_metadata(snapshot)
        snapshot = copy.deepcopy(original)
        snapshot['live']['seeds'][chain].pop(0)
        with self.assertRaisesRegex(ValueError, 'exactly one testnet seed'):
            testnet_metadata(snapshot)
        snapshot = copy.deepcopy(original)
        snapshot['live']['tokens'][chain]['tokenAddress'] = addr(777)
        with self.assertRaisesRegex(ValueError, 'disagree'):
            testnet_metadata(snapshot)

    def test_malformed_snapshot_types_fail_cleanly_through_cli(self):
        original = json.loads((ROOT / 'components/dashboard/config/testnet-deployment.json').read_text())
        chain = str(original['live']['lane'][0])
        cases = [
            ((), []), (('live',), []), (('live',), None),
            (('live', 'lane'), 5), (('live', 'lane'), {}), (('live', 'lane'), [[], 5003]),
            (('live', 'tokens'), []), (('live', 'seeds'), None), (('governanceHolders',), []),
            (('live', 'tokens', chain), []), (('live', 'tokens', chain, 'chainName'), 5),
            (('live', 'tokens', chain, 'chainName'), '  '),
            (('live', 'tokens', chain, 'decimals'), 18.0),
            (('live', 'tokens', chain, 'decimals'), True),
            (('live', 'seeds', chain), 5), (('live', 'seeds', chain), [None]),
            (('live', 'seeds', chain), [[addr(1)]]),
            (('live', 'seeds', chain), [[addr(1), []]]),
            (('origin',), None), (('origin', 'archiveCommit'), 5),
            (('origin', 'sourceFilesSha256'), []),
        ]
        with tempfile.TemporaryDirectory() as tmp:
            root, output = Path(tmp) / 'repo', Path(tmp) / 'site'
            source = root / 'components/dashboard/config/testnet-deployment.json'
            source.parent.mkdir(parents=True)
            for path, value in cases:
                snapshot = copy.deepcopy(original)
                if path:
                    target = snapshot
                    for key in path[:-1]:
                        target = target[key]
                    target[path[-1]] = value
                else:
                    snapshot = value
                source.write_text(json.dumps(snapshot))
                errors = io.StringIO()
                with self.subTest(path=path, value=value), patch('build_dashboard.ROOT', root), \
                        patch('sys.argv', ['build_dashboard.py', '--output', str(output)]), \
                        contextlib.redirect_stderr(errors), self.assertRaises(SystemExit) as raised:
                    main()
                self.assertEqual(raised.exception.code, 1)
                self.assertIn('Dashboard build failed:', errors.getvalue())
                self.assertNotIn('Traceback', errors.getvalue())
                self.assertFalse(output.exists())

    def test_conflicting_seed_addresses_are_rejected_case_insensitively(self):
        snapshot = json.loads((ROOT / 'components/dashboard/config/testnet-deployment.json').read_text())
        chain = str(snapshot['live']['lane'][0])
        pool = snapshot['live']['tokens'][chain]['poolAddress']
        snapshot['live']['seeds'][chain][0][0] = pool.lower()
        with self.assertRaisesRegex(ValueError, 'Duplicate testnet seed address'):
            testnet_metadata(snapshot)

    def test_evidence_rejects_active_or_unbalanced_html_before_writing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, output = Path(tmp) / 'repo', Path(tmp) / 'site'
            shutil.copytree(ROOT / 'components/dashboard', root / 'components/dashboard')
            evidence = root / 'components/dashboard/content/evidence.html'
            for fragment in ('<script>alert(1)</script>', '<STYLE>p{color:red}</STYLE>',
                             '<p onclick="alert(1)">text</p>', '<iframe src="x"></iframe>',
                             '<a href="javascript:alert(1)">link</a>', '<p><strong>x</p></strong>',
                             '<p>unfinished', '</style>', '<svg onload="alert(1)"/>',
                             '<img src=x onerror=alert(1)', '<!-- unfinished comment'):
                evidence.write_text(fragment)
                with self.subTest(fragment=fragment), self.assertRaisesRegex(ValueError, 'Invalid evidence HTML'):
                    build(root, output)
                self.assertFalse(output.exists())

    def test_evidence_parser_rejects_incomplete_markup_at_eof(self):
        for fragment in ('<img src=x onerror=alert(1)', '<!-- unfinished comment',
                         '<p', '<', '<p>closed</p><!-- trailing'):
            parser = EvidenceHTML('test fragment')
            with self.subTest(fragment=fragment), self.assertRaisesRegex(ValueError, 'Invalid evidence HTML'):
                parser.feed(fragment)
                parser.close()
        # Every split of valid markup must work, including inside entity refs
        # and attributes. Only EOF requires a complete fragment.
        source = '<div class="table"><p>Escaped &lt;img&gt;</p></div>'
        for split in range(len(source) + 1):
            with self.subTest(split=split):
                parser = EvidenceHTML('complete fragment')
                parser.feed(source[:split])
                parser.feed(source[split:])
                parser.close()

    def test_evidence_accepts_complete_markup_when_parser_defers_until_close(self):
        # A buffered '<' need not be incomplete. Simulate a parser that keeps
        # complete markup pending until close(), as seen in the CI failure.
        def defer(parser, data):
            parser.rawdata += data
        with patch('build_dashboard.HTMLParser.feed', new=defer):
            parser = EvidenceHTML('deferred complete fragment')
            for chunk in ('<p', '>Escaped &lt;img&gt;', '</p', '>'):
                parser.feed(chunk)
            parser.close()
            self.assertEqual(parser.stack, [])

    def test_legacy_output_is_rejected_without_modifying_existing_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / 'site'
            legacy = output / 'upstream/docs/report.md'
            legacy.parent.mkdir(parents=True)
            legacy.write_text('old generated report')
            page = output / 'index.html'
            page.write_text('previous site')
            with self.assertRaisesRegex(ValueError, 'Legacy generated inputs remain'):
                build(ROOT, output)
            self.assertEqual(page.read_text(), 'previous site')
            self.assertEqual(legacy.read_text(), 'old generated report')


if __name__ == '__main__':
    unittest.main()
