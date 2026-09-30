"""Exercise registration selection without RPC access or transaction signing."""
from pathlib import Path
import subprocess

import pytest

SCRIPT = Path(__file__).parents[1] / 'script/07_set_pool_gov.sh'


@pytest.mark.parametrize('state,role,expected', [
    ('empty', 'true', 'registered'),
    ('empty', 'false', 'rejected'),
    ('empty', 'unavailable', 'rejected'),
    ('pending', 'false', 'skip'),
    ('administered', 'false', 'skip'),
])
def test_l2_requires_acl_without_fallback(state, role, expected):
    source = SCRIPT.read_text()
    functions = source[source.index('propose_tar_admin() {'):source.index('\necho ""', source.index('propose_tar_admin() {'))]
    # Stub only the external boundary. Any fallback probe or impersonation is a
    # failure, even if the script would otherwise swallow its error.
    harness = r'''
set -euo pipefail
ZERO=zero
DEPLOYER=deployer
eq() { [ "$1" = "$2" ]; }
read_tar_config() {
    TAR_ADMIN=zero; TAR_PENDING=zero
    if [ "$STATE" = administered ]; then TAR_ADMIN=governance; fi
    if [ "$STATE" = pending ]; then TAR_PENDING=deployer; fi
    return 0
}
cast() {
    case "$3" in
      'DEFAULT_ADMIN_ROLE()(bytes32)')
        if [ "$ROLE" = unavailable ]; then return 1; fi
        echo role ;;
      'hasRole(bytes32,address)(bool)') echo "$ROLE" ;;
      *) echo FORBIDDEN_FALLBACK; return 99 ;;
    esac
}
is_anvil() { echo FORBIDDEN_FALLBACK; return 99; }
register_via_module() {
    [ "$3" = 'registerAccessControlDefaultAdmin(address)' ]
    echo ACL_REGISTERED
}
'''
    result = subprocess.run(['bash', '-c', harness + functions + '\npropose_tar_admin mantle tar module token rpc true',
                             'registration-test'], env={'STATE': state, 'ROLE': role}, text=True, capture_output=True)
    assert 'FORBIDDEN_FALLBACK' not in result.stdout + result.stderr
    if expected == 'rejected':
        assert result.returncode != 0
        assert 'ACL registration requires' in result.stdout
        assert 'ACL_REGISTERED' not in result.stdout
    else:
        assert result.returncode == 0, result.stderr
        assert ('ACL_REGISTERED' in result.stdout) == (expected == 'registered')
