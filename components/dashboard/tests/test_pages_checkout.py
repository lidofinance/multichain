"""Exercise automatic Pages checkout and developer opt-in using offline Git repos."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
CCIP = 'components/ccip'


class PagesCheckoutTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='pages-checkout-')
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
        self.env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1',
                        GIT_TERMINAL_PROMPT='0', GIT_ALLOW_PROTOCOL='file',
                        GIT_AUTHOR_NAME='Test', GIT_AUTHOR_EMAIL='test@example.invalid',
                        GIT_COMMITTER_NAME='Test', GIT_COMMITTER_EMAIL='test@example.invalid')
        self.source = self.base / 'source'
        self.source.mkdir()
        self.git(self.source, 'init', '-q')
        (self.source / 'input.txt').write_text('dependency input\n')
        self.git(self.source, 'add', 'input.txt')
        self.git(self.source, 'commit', '-qm', 'Fixture')
        self.sha = self.git(self.source, 'rev-parse', 'HEAD').stdout.strip()

        self.repo = self.base / 'checkout'
        self.repo.mkdir()
        self.git(self.repo, 'init', '-q')
        (self.repo / '.gitmodules').write_bytes((ROOT / '.gitmodules').read_bytes())
        entries = self.git(self.repo, 'config', '-f', '.gitmodules', '--get-regexp',
                           r'^submodule\..*\.path$').stdout.splitlines()
        self.paths = []
        for entry in entries:
            key, relative = entry.split(' ', 1)
            self.paths.append(relative)
            source = self.base / 'inaccessible-private-repository' if relative == CCIP else self.source
            self.git(self.repo, 'config', '-f', '.gitmodules', key[:-4] + 'url', source.as_uri())
            self.git(self.repo, 'update-index', '--add', '--cacheinfo', f'160000,{self.sha},{relative}')
        self.git(self.repo, 'add', '.gitmodules')

    def git(self, cwd, *args):
        return subprocess.run(['git', *args], cwd=cwd, env=self.env,
                              check=True, capture_output=True, text=True, timeout=20)

    def test_pages_checkout_skips_inaccessible_ccip_and_fetches_other_submodules(self):
        self.git(self.repo, 'submodule', 'sync', '--recursive')
        # actions/checkout uses --force, but does not override the update procedure.
        self.git(self.repo, '-c', 'protocol.version=2', 'submodule', 'update',
                 '--init', '--force', '--depth=1', '--recursive')
        self.assertFalse((self.repo / CCIP / '.git').exists())
        for relative in self.paths:
            if relative != CCIP:
                self.assertEqual((self.repo / relative / 'input.txt').read_text(), 'dependency input\n')
                self.assertEqual(self.git(self.repo / relative, 'rev-parse', 'HEAD').stdout.strip(), self.sha)

    def test_explicit_checkout_fetches_pinned_ccip_for_development(self):
        # Authorized access is represented by the readable local repository.
        self.git(self.repo, 'config', '-f', '.gitmodules', f'submodule.{CCIP}.url', self.source.as_uri())
        self.git(self.repo, 'submodule', 'update', '--init', '--checkout', CCIP)
        self.assertEqual((self.repo / CCIP / 'input.txt').read_text(), 'dependency input\n')
        self.assertEqual(self.git(self.repo / CCIP, 'rev-parse', 'HEAD').stdout.strip(), self.sha)


if __name__ == '__main__':
    unittest.main()
