"""Offline tests for the in-flight report: real mainnet records, replayed through stub endpoints."""
import json
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import inflight as f  # noqa: E402

FIXTURE = json.loads((Path(__file__).parent / 'fixtures/base-mainnet.json').read_text())
PORTAL = FIXTURE['portal']
REGISTRY = '0x909f6cf47ed12f010A796527f562bFc26C7F4E72'
FACTORY = '0x43edB88C4B80fDD2AdFF2412A7BebF9dF42cB40e'
GAME = '0x5a2FA953a6e6255f74b701719A39C8AFBB563f10'
SUBMITTER = '0x99Cac20b77F4877108E78538C68CD08393a33362'
CFG = {'l1': {'name': 'ethereum', 'bridge': FIXTURE['l1Bridge'], 'messenger': FIXTURE['l1Messenger']},
       'l2': {'name': 'base', 'bridge': FIXTURE['l2Bridge'], 'messenger': FIXTURE['l2Messenger']}}
NOW = 1_800_000_000
MATURITY = 86_400


def hexword(value) -> str:
    return f.tohex(f.word(int(value, 16) if isinstance(value, str) else int(value)))


class StubRpc(f.Rpc):
    """Answers from tables: eth_call by (contract, signature), other methods by name."""

    def __init__(self, views=None, methods=None):
        super().__init__('stub', 'http://unused.invalid')
        self.views_table = {(to.lower(), f.tohex(f.selector(sig))): answer for (to, sig), answer in (views or {}).items()}
        self.methods = methods or {}

    def batch(self, calls):
        out = []
        for method, params in calls:
            if method == 'eth_call':
                data = params[0]['data']
                answer = self.views_table.get((params[0]['to'].lower(), data[:10]))
                if answer is None:
                    out.append(f.Reverted({'code': 3, 'message': 'execution reverted', 'data': '0x'}))
                else:
                    out.append(answer(f.unhex(data)[4:]) if callable(answer) else answer)
            else:
                out.append(self.methods[method](*params))
        return out


def chain(name, rpc, block=1_000, final=900):
    return SimpleNamespace(name=name, rpc=rpc, block=block, final=final, timestamp=NOW, fork=False,
                           read=lambda to, sig, *args, block=None: rpc.call(
                               to, f.selector(sig) + b''.join(f.word(a) for a in args), 0))


def reverted(name):
    return f.Reverted({'code': 3, 'message': 'execution reverted', 'data': f.tohex(f.selector(name + '()'))})


# ── primitives ────────────────────────────────────────────────────────────────────────────────
def test_keccak_matches_published_vectors():
    assert f.keccak256(b'').hex() == 'c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470'
    assert f.keccak256(b'abc').hex() == '4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45'
    # one byte short of the rate, exactly the rate, one byte over: the padding edge cases
    assert f.keccak256(bytes(136)).hex() == '3a5912a7c5faa06ee4fe906253e339467a9ce87d533c65be3c15cb231cdb25f9'
    assert len({f.keccak256(bytes(n)) for n in (135, 136, 137)}) == 3


def test_signatures_match_the_deployed_contracts():
    assert f.SENT_MESSAGE == '0xcb0f7ffd78f9aee47a248fae8db181db6eee833039123e026dcbff529522e52a'
    assert f.tohex(f.selector('checkWithdrawal(bytes32,address)')) == '0x71c1566e'
    assert f.PORTAL_ERRORS['0xcca6afda'] == 'OptimismPortal_Unproven'  # as the live portal returned it


def test_address_is_checksummed_in_full():
    assert f.address('0x9de443adc5a411e83f1878ef24c3f52c61571e72') == '0x9de443AdC5A411E83F1878Ef24C3F52C61571e72'
    assert f.address('0x' + '00' * 12 + 'ac9d11cd4d7ef6e54f14643a393f68ca014287ab') == FIXTURE['l2Bridge']


def test_message_hash_is_the_key_base_recorded_for_a_real_deposit():
    sent = FIXTURE['deposit']['sentMessage']
    calldata = f.relay_calldata(int(sent['nonce']), FIXTURE['l1Bridge'], FIXTURE['l2Bridge'],
                                sent['gasLimit'], f.unhex(sent['message']))
    assert f.tohex(f.keccak256(calldata)) == sent['hash']


def test_base_transaction_hash_is_derived_from_the_ethereum_log():
    assert f.deposit_transaction_hash(FIXTURE['deposit']['transactionDeposited']) == FIXTURE['deposit']['l2TransactionHash']


def test_describe_reads_the_transfer_and_flags_other_messages():
    sent = FIXTURE['withdrawal']['sentMessage']
    item = f.describe(sent, 'withdrawal')
    assert (item['kind'], item['from'], item['to'], item['amount']) == (
        'transfer', FIXTURE['withdrawal']['from'], FIXTURE['withdrawal']['to'], FIXTURE['withdrawal']['amount'])
    control = f.describe(dict(sent, message=f.tohex(f.selector('confirmL1Activation()'))), 'deposit')
    assert control['kind'] == 'control' and 'amount' not in control


def test_amounts_and_times_are_exact():
    assert f.amount('389785863645693893969') == '389.785863645693893969'
    assert f.amount(10 ** 18) == '1' and f.amount(0) == '0' and f.amount(-5 * 10 ** 11) == '-0.0000005'
    assert f.stamp(0) == '1970-01-01 00:00:00Z' and f.age(86_400 + 7_200) == '1d 2h'


# ── finding and settling messages ─────────────────────────────────────────────────────────────
def sent_log(block, nonce, sender, message='0x'):
    raw = f.unhex(message)
    data = f.word(int(sender, 16)) + f.word(128) + f.word(nonce) + f.word(200_000) + f.word(len(raw)) + raw
    return {'transactionHash': hexword(block * 1000 + nonce), 'blockNumber': hex(block), 'logIndex': '0x1',
            'data': f.tohex(data + bytes(-len(data) % 32))}


def test_collect_keeps_final_messages_and_rereads_the_rest(monkeypatch):
    logs = [sent_log(100, 1, FIXTURE['l1Bridge']), sent_log(850, 2, '0x' + '11' * 20),
            sent_log(950, 3, FIXTURE['l1Bridge'])]
    asked = []
    rpc = StubRpc()
    monkeypatch.setattr(rpc, 'logs', lambda contract, topics, start, end, label='': (
        asked.append((start, end)), [log for log in logs if start <= int(log['blockNumber'], 16) <= end])[1])
    source = chain('ethereum', rpc)
    first = f.collect(source, FIXTURE['l1Messenger'], FIXTURE['l1Bridge'], FIXTURE['l2Bridge'], None, 50, '')
    assert [m['nonce'] for m in first['messages']] == ['1', '3']
    assert first['foreign'] == 1  # a message from another sender is not the bridge's transfer
    assert [m['nonce'] for m in first['state']['messages']] == ['1'] and first['state']['scannedTo'] == 900
    assert first['messages'][1]['sourceFinal'] is False

    source.block, source.final = 1_100, 1_000
    second = f.collect(source, FIXTURE['l1Messenger'], FIXTURE['l1Bridge'], FIXTURE['l2Bridge'], first['state'], None, '')
    assert asked == [(50, 1_000), (901, 1_100)]
    assert [m['nonce'] for m in second['state']['messages']] == ['1', '3'] and second['state']['scannedTo'] == 1_000


def test_settle_remembers_only_final_deliveries():
    messages = [{'hash': hexword(n), 'nonce': str(n)} for n in (1, 2, 3, 4)]
    delivered_final, delivered_head, failed = {hexword(1)}, {hexword(1), hexword(2)}, {hexword(3)}
    asked_blocks = []

    class Rpc(StubRpc):
        def batch(self, calls):
            out = []
            for _, (call, block) in calls:
                asked_blocks.append(int(block, 16))
                key, table = '0x' + call['data'][10:], None
                if call['data'][:10] == f.tohex(f.selector('failedMessages(bytes32)')):
                    table = failed
                else:
                    table = delivered_final if int(block, 16) == 900 else delivered_head
                out.append(hexword(key in table))
            return out

    undelivered = f.settle(messages, chain('base', Rpc()), FIXTURE['l2Messenger'])
    assert [(m['nonce'], m['relayFailed']) for m in undelivered] == [('3', True), ('4', False)]
    assert messages[0].get('delivered') is True and 'delivered' not in messages[1]
    assert messages[1]['deliveredAtHead'] is True
    assert set(asked_blocks) == {900, 1_000}


def test_log_scan_narrows_the_range_until_the_endpoint_accepts_it(monkeypatch):
    rpc = f.Rpc('stub', 'http://unused.invalid')
    seen = []

    def post(payload):
        query = payload['params'][0]
        start, end = int(query['fromBlock'], 16), int(query['toBlock'], 16)
        if end - start + 1 > 10_000:
            return {'error': {'code': -32602, 'message': 'block range too large'}}
        seen.append((start, end))
        return {'result': [{'blockNumber': hex(start)}]}

    monkeypatch.setattr(rpc, '_post', post)
    logs = rpc.logs('0x' + '00' * 20, [f.SENT_MESSAGE], 0, 99_999)
    assert seen[0][0] == 0 and seen[-1][1] == 99_999
    assert all(b[0] == a[1] + 1 for a, b in zip(seen, seen[1:]))  # no gap and no overlap
    assert len(logs) == len(seen)


# ── deposits ──────────────────────────────────────────────────────────────────────────────────
def deposit_item(relay_failed=False):
    sent = FIXTURE['deposit']['sentMessage']
    return f.describe({'tx': sent['tx'], 'block': 500, 'nonce': sent['nonce'], 'gasLimit': sent['gasLimit'],
                       'message': sent['message'], 'hash': sent['hash']}, 'deposit') | {'relayFailed': relay_failed}


@pytest.mark.parametrize('l2_receipt, status', [
    (None, 'AWAITING_L2_INCLUSION'), ({'status': '0x0'}, 'L2_TX_FAILED'), ({'status': '0x1'}, 'UNKNOWN')])
def test_undelivered_deposit_is_classified_by_its_base_transaction(l2_receipt, status):
    l1 = chain('ethereum', StubRpc(methods={
        'eth_getTransactionReceipt': lambda tx: {'logs': [FIXTURE['deposit']['transactionDeposited']]}}))
    asked = []
    l2 = chain('base', StubRpc(methods={'eth_getTransactionReceipt': lambda tx: (asked.append(tx), l2_receipt)[1]}))
    item = deposit_item()
    f.resolve_deposits([item], CFG, l1, l2, PORTAL)
    assert item['status'] == status and asked == [FIXTURE['deposit']['l2TransactionHash']]


def test_failed_deposit_carries_calldata_that_replays_it():
    item = deposit_item(relay_failed=True)
    f.resolve_deposits([item], CFG, chain('ethereum', StubRpc()), chain('base', StubRpc()), PORTAL)
    assert item['status'] == 'RELAY_FAILED' and item['relay']['to'] == FIXTURE['l2Messenger']
    assert f.tohex(f.keccak256(f.unhex(item['relay']['calldata']))) == item['messageHash']


# ── withdrawals ───────────────────────────────────────────────────────────────────────────────
def withdrawal_item(relay_failed=False):
    return f.describe(FIXTURE['withdrawal']['sentMessage'], 'withdrawal') | {'relayFailed': relay_failed}


def l2_with_receipt():
    return chain('base', StubRpc(methods={
        'eth_getTransactionReceipt': lambda tx: {'logs': [FIXTURE['withdrawal']['messagePassed']]}}))


def l1_portal(finalized=False, submitters=0, proven_at=NOW - 2 * MATURITY, check='ok', game_status=2,
              retired=False, game_l2_block=10 ** 9):
    views = {
        (PORTAL, 'finalizedWithdrawals(bytes32)'): hexword(finalized),
        (PORTAL, 'numProofSubmitters(bytes32)'): hexword(submitters),
        (PORTAL, 'proofSubmitters(bytes32,uint256)'): hexword(SUBMITTER),
        (PORTAL, 'provenWithdrawals(bytes32,address)'): hexword(GAME) + hexword(proven_at)[2:],
        (PORTAL, 'checkWithdrawal(bytes32,address)'): '0x' if check == 'ok' else reverted(check),
        (PORTAL, 'anchorStateRegistry()'): hexword(REGISTRY),
        (PORTAL, 'disputeGameFactory()'): hexword(FACTORY),
        (PORTAL, 'respectedGameType()'): hexword(621),
        (FACTORY, 'gameCount()'): hexword(3),
        (FACTORY, 'gameAtIndex(uint256)'): lambda args: (
            hexword(621 if f.word_at(args, 0) == 1 else 0) + hexword(NOW)[2:] + hexword(GAME)[2:]),
        (GAME, 'l2SequenceNumber()'): hexword(game_l2_block),
        (GAME, 'status()'): hexword(game_status),
        (REGISTRY, 'isGameRegistered(address)'): hexword(True),
        (REGISTRY, 'isGameRetired(address)'): hexword(retired),
        (REGISTRY, 'isGameBlacklisted(address)'): hexword(False),
        (REGISTRY, 'isGameResolved(address)'): hexword(game_status != 0),
        (REGISTRY, 'isGameFinalized(address)'): hexword(game_status != 0),
        (REGISTRY, 'isGameClaimValid(address)'): hexword(game_status == 2 and not retired),
    }
    return chain('ethereum', StubRpc(views=views))


def classify(l1):
    item = withdrawal_item()
    game = f.resolve_withdrawals([item], CFG, l1, l2_with_receipt(), PORTAL, MATURITY)
    assert item['withdrawalHash'] == FIXTURE['withdrawal']['withdrawalHash']  # as Base emitted it
    return item, game


def test_unproven_withdrawal_is_provable_once_a_respected_game_covers_its_block():
    item, game = classify(l1_portal())
    assert item['status'] == 'READY_TO_PROVE'
    assert game == {'index': 1, 'game': GAME, 'gameType': 621, 'l2Block': 10 ** 9, 'createdAt': NOW}
    item, _ = classify(l1_portal(game_l2_block=FIXTURE['withdrawal']['sentMessage']['block'] - 1))
    assert item['status'] == 'WAITING_FOR_PROPOSAL'


def test_proven_withdrawal_follows_the_portal_check():
    item, _ = classify(l1_portal(submitters=1))
    assert item['status'] == 'READY_TO_FINALIZE' and SUBMITTER in item['next']

    item, _ = classify(l1_portal(submitters=1, proven_at=NOW - 60, check='OptimismPortal_ProofNotOldEnough', game_status=0))
    assert item['status'] == 'PROVEN_WAITING' and f.stamp(NOW - 60 + MATURITY) in item['next']
    assert item['proof']['check'] == 'OptimismPortal_ProofNotOldEnough'

    item, _ = classify(l1_portal(submitters=1, check='OptimismPortal_InvalidRootClaim', game_status=0))
    assert item['status'] == 'PROVEN_WAITING' and item['proof']['gameStatus'] == 'IN_PROGRESS'


@pytest.mark.parametrize('portal, reason', [
    (dict(retired=True), 'retired'), (dict(game_status=1), 'lost to the challenger')])
def test_proof_on_a_dead_game_must_be_made_again(portal, reason):
    item, _ = classify(l1_portal(submitters=1, check='OptimismPortal_InvalidRootClaim', **portal))
    assert item['status'] == 'PROOF_INVALIDATED' and reason in item['note']
    assert item['next'].startswith('prove again') and 'proveWithdrawalTransaction' in item['next']


def test_withdrawal_finalized_without_a_messenger_record_is_flagged():
    item, _ = classify(l1_portal(finalized=True))
    assert item['status'] == 'FINALIZED_NOT_RELAYED'


def test_failed_withdrawal_relay_is_replayable_on_ethereum():
    item = withdrawal_item(relay_failed=True)
    f.resolve_withdrawals([item], CFG, chain('ethereum', StubRpc()), chain('base', StubRpc()), PORTAL, MATURITY)
    assert item['status'] == 'RELAY_FAILED' and item['relay'] == {
        'chain': 'ethereum', 'to': FIXTURE['l1Messenger'],
        'calldata': f.tohex(f.relay_calldata(int(item['nonce']), FIXTURE['l2Bridge'], FIXTURE['l1Bridge'],
                                             item['gasLimit'], f.unhex(item['message'])))}


def test_withdrawal_without_its_message_passer_entry_is_not_guessed():
    item = withdrawal_item()
    l2 = chain('base', StubRpc(methods={'eth_getTransactionReceipt': lambda tx: {'logs': []}}))
    assert f.resolve_withdrawals([item], CFG, l1_portal(), l2, PORTAL, MATURITY) is None
    assert item['status'] == 'UNKNOWN'


# ── report ────────────────────────────────────────────────────────────────────────────────────
def test_blockers_name_what_stops_a_relay():
    open_ = {'depositsEnabled': True, 'withdrawalsEnabled': True, 'mode': 'MIGRATING'}
    state = {'l1Bridge': dict(open_), 'l2Bridge': dict(open_), 'portal': {'paused': False}}
    assert f.blockers(state, CFG) == {'deposits': [], 'withdrawals': []}
    state['l2Bridge']['mode'] = 'CCIP_ONLY'
    state['l1Bridge']['withdrawalsEnabled'] = False
    state['portal']['paused'] = True
    found = f.blockers(state, CFG)
    assert len(found['deposits']) == 1 and 'CCIP_ONLY' in found['deposits'][0]
    assert len(found['withdrawals']) == 2


def test_text_report_lists_transfers_with_full_identifiers():
    item, game = classify(l1_portal(submitters=1))
    item['sourceTimestamp'] = NOW - 3_600
    side = {'sent': 5, 'delivered': 4, 'deliveredAtHeadOnly': 0, 'foreignMessages': 0, 'fromBlock': 1,
            'toBlock': 1_000, 'inFlight': [item]}
    empty = dict(side, sent=3, delivered=3, inFlight=[])
    f.summarize(side)
    f.summarize(empty)
    bridge = {'depositsEnabled': True, 'withdrawalsEnabled': True, 'mode': 'LEGACY'}
    info = {'chainId': 1, 'block': 1_000, 'timestamp': NOW, 'finalBlock': 900, 'fork': False,
            'bridge': FIXTURE['l1Bridge'], 'messenger': FIXTURE['l1Messenger']}
    report = {
        'generatedAt': NOW, 'l1': dict(info, key='l1', name='ethereum'), 'l2': dict(info, key='l2', name='base'),
        'state': {'l1Bridge': bridge, 'l2Bridge': bridge, 'portal': {
            'address': PORTAL, 'version': '6.0.1', 'paused': False, 'proofMaturityDelaySeconds': MATURITY}},
        'blockers': {'deposits': [], 'withdrawals': []}, 'deposits': empty, 'withdrawals': side,
        'latestDisputeGame': game,
        'reconciliation': {'escrow': str(10 ** 20), 'lockBox': None, 'lockBoxBalance': '0', 'l2Supply': str(9 * 10 ** 19),
                           'inFlight': side['inFlightAmount'], 'unexplained': str(10 ** 19 - int(side['inFlightAmount']))},
    }
    text = f.render(report, None)
    assert 'in flight: none' in text and 'READY_TO_FINALIZE  0.0001 wstETH' in text
    for value in (item['sourceTx'], item['messageHash'], item['withdrawalHash'], item['from'], PORTAL):
        assert value in text
    assert '…' not in text.replace('… more', '')  # nothing abbreviated
    assert f.render(report, 0 or None) == text
