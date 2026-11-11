"""Required scenario names: an empty or reduced Forge selection cannot pass a full rehearsal."""
import json
import re

HUB = {
    'test_admin_accepted_by_mcms_and_deployer_cannot_bypass',
    'test_cutover_batch_cannot_be_executed_again', 'test_cutover_end_state',
    'test_imported_lanes_lock_into_their_lockboxes', 'test_imported_lanes_release_from_their_lockboxes',
    'test_lane_connection_batch_cannot_be_executed_again', 'test_no_required_ccvs_on_imported_lanes',
    'test_old_pool_outbound_paused_on_every_lane', 'test_siloed_lanes_cannot_draw_from_the_shared_lockbox',
    'test_the_base_lane_is_isolated_from_the_imported_lanes',
    'test_the_base_lane_was_connected_by_a_lido_timelock_proposal',
    'test_the_cutover_bound_a_hub_that_mirrored_the_old_pool',
}
BASE = {'test_levers_pause_halt_bypass_blocked', 'test_runbook_one_vote',
        'test_base_outbound_waits_for_l1_confirmation_and_activation'}
CCV = {'test_bridge_roundtrip', 'test_gov_roundtrip_reconfigures_ccv',
       'test_over_cap_inbound_rate_limit_does_not_mint', 'test_over_cap_rate_limit_reverts',
       'test_paused_hook_blocks_send', 'test_quorum_1of2_does_not_mint'}
BOOTSTRAP = {'test_base_starts_on_legacy_bridge_with_backing', 'test_full_lido_and_pristine_backed_token',
             'test_official_registry_and_legacy_pool_authority', 'test_two_reciprocal_existing_lanes_and_custody'}
PRE_BASE_SKIPS = {'test_lane_connection_batch_cannot_be_executed_again',
                  'test_the_base_lane_is_isolated_from_the_imported_lanes',
                  'test_the_base_lane_was_connected_by_a_lido_timelock_proposal'}


def forge_checks(path, required, skips=frozenset()):
    found = re.findall(r'^\[(PASS|SKIP|FAIL[^]]*)\]\s+(test_\w+)\(', path.read_text(), re.M)
    statuses = dict((name, status) for status, name in found)
    if set(statuses) != required or len(found) != len(required):
        raise ValueError(f'{path.name}: missing/duplicate/unexpected scenarios; missing {sorted(required - set(statuses))}')
    if {name for name, status in statuses.items() if status == 'SKIP'} != set(skips):
        raise ValueError(path.name + ': unexpected scenario skips')
    if any(status != ('SKIP' if name in skips else 'PASS') for name, status in statuses.items()):
        raise ValueError(path.name + ': required scenario failed')
    return {'passed': len(required - set(skips)), 'skipped': sorted(skips)}


def check_full(run, line):
    state = run / 'state'
    spoke = 'base' if line == 'mainnet' else 'base_sepolia'
    result = {'hubCheckpoint': forge_checks(state / 'forge-hub-checkpoint.log', HUB, PRE_BASE_SKIPS),
              'scenarios': forge_checks(state / f'forge-scenarios.{spoke}.log', HUB | BASE | (CCV if line == 'sepolia' else set()))}
    log = (state / f'state-mate.{spoke}.log').read_text()
    totals = re.findall(r'Total: (\d+) checks passed, (\d+) skipped', log)
    tables = re.findall(r'✓ \w+: (get\w+) \(\d+ rows; enumeration order ignored\)', log)
    if len(totals) != 1 or int(totals[0][0]) == 0 or totals[0][1] != '9' or len(tables) != 9:
        raise ValueError('Missing state-mate result or one of the nine delegated table checks')
    result['stateMate'] = {'passed': int(totals[0][0]), 'delegatedChecksPassed': len(tables)}
    if line == 'sepolia':
        result['bootstrap'] = forge_checks(state / 'forge-bootstrap.log', BOOTSTRAP)
        lanes = json.loads((state / 'existing-lane-tests.json').read_text())['checks']
        if {c['lane'] for c in lanes} != {'monad', 'sepolia_optimism'} or any(c['result'] != 'passed' for c in lanes):
            raise ValueError('Missing Monad/OP Sepolia round-trip checks')
        result['existingLanes'] = lanes
    return result


if __name__ == '__main__':
    import sys
    from pathlib import Path
    print(json.dumps(forge_checks(Path(sys.argv[1]), HUB, PRE_BASE_SKIPS), indent=2))
