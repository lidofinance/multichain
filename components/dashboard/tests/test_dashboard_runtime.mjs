// Exercise the dashboard's actual functions without registry or RPC network access.
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import vm from 'node:vm';
import test from 'node:test';

const html = readFileSync(new URL('../templates/index.html', import.meta.url), 'utf8');
const script = html.split('<script>\n')[1].split('</script>')[0];
const refreshStart = script.indexOf('// 8. Refresh cycle and events');
const eventsStart = script.indexOf('// delegation: tabs');
assert.ok(refreshStart > 0 && eventsStart > refreshStart, 'runtime harness section markers must exist in order');
const source = script.slice(0, refreshStart);
const address = n => '0x' + n.toString(16).padStart(40, '0');
const ldoMetadata = JSON.parse(readFileSync(new URL('../config/ldo-networks.json', import.meta.url), 'utf8'));
const stethMetadata = JSON.parse(readFileSync(new URL('../config/steth-networks.json', import.meta.url), 'utf8'));
const build = { identity: 'test', networks: [], provenance: {}, l1Token: address(1),
  ledger: JSON.parse(readFileSync(new URL('../../../ledger.json', import.meta.url), 'utf8')),
  ldo: ldoMetadata,
  steth: { l1Token: address(4), priceFeed: stethMetadata.priceFeed, networks: [{ chainId: 10, name: 'Optimism',
    token: address(10), oracle: address(11), decimals: 18, rateDecimals: 27 }] },
  live: { lane: [2, 3], env: 'testnet', tokens: {}, seeds: {} } };
function page(snapshot = null) {
  const store = new Map();
  const views = { innerHTML: '', childNodes: [], replaceChildren(...nodes) { this.childNodes = nodes; },
    querySelectorAll: () => [], querySelector: () => null };
  const ctx = vm.createContext({ console, performance, setTimeout, clearTimeout, URL, tickStamp: () => {},
    location: { hash: '#token' },
    fetch: async () => { throw Error('Unexpected network'); },
    localStorage: { getItem: k => store.get(k) ?? null,
      setItem: (k, v) => store.set(k, v), removeItem: k => store.delete(k) },
    document: { getElementById: id => id === 'dashboard-data'
      ? { textContent: JSON.stringify({...build, ledger: undefined}) } : id === 'ledger-data' ? { textContent: JSON.stringify(build.ledger) } : id === 'snapshot' ? { textContent: JSON.stringify(snapshot) } : id === 'views' ? views : {},
      querySelector: () => null, querySelectorAll: () => [] } });
  vm.runInContext(source, ctx);
  vm.runInContext('renderTabs = () => {};', ctx);
  return { ctx, store, views, run: s => vm.runInContext(s, ctx) };
}

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

test('ledger search covers every deployment and its nested evidence, with network-scoped identity', () => {
  const p = page();
  assert.equal(p.run('ledgerEntries'), null, 'ledger indexing is deferred until needed');
  p.run('indexLedger()');
  assert.equal(p.run('ledgerEntries.length'), build.ledger.deployments.length);
  const entry = build.ledger.deployments.find(d => d.auditReportRefs.length && d.source?.commit);
  p.ctx.entry = entry;
  for (const query of [entry.address.toUpperCase(), entry.contractId, entry.source.commit,
    entry.auditReportRefs[0], `${entry.contractName} ${build.ledger.networks[entry.networkId].networkName}`]) {
    p.ctx.query = query;
    assert.equal(p.run('ledgerEntries.filter(x => ledgerMatches(x, query, entry.networkId)).some(x => x.entry.deploymentId === entry.deploymentId)'), true);
  }
  p.ctx.query = entry.address;
  assert.equal(p.run('ledgerEntries.filter(x => ledgerMatches(x, query, "nonexistent-network")).length'), 0);
  assert.equal(p.run('ledgerEntries.filter(x => ledgerMatches(x, "no-such-deployment")).length'), 0);
  assert.equal(p.run('ledgerEntries.filter(x => ledgerMatches(x, "  ")).length'), build.ledger.deployments.length);
});

test('ledger details preserve nested fields, missing evidence, safe links, and proxy targets', () => {
  const p = page();
  p.ctx.entry = build.ledger.deployments.find(d => d.proxy?.implementationDeploymentId);
  p.run('indexLedger()');
  const details = p.run('ledgerDetails(entry)');
  assert.match(details, /Audit reports/);
  assert.match(details, /Public posts &amp; references/);
  assert.match(details, /data-ledger-target=/);
  assert.match(details, /Entry JSON/);
  assert.match(p.run('ledgerValue(null)'), /Not recorded/);
  assert.match(p.run('ledgerValue([])'), /None recorded/);
  p.ctx.evidence = { evidence: [{ note: '<script>alert(1)</script>', url: 'javascript:alert(1)' }], publicRefs: ['https://example.org/post?a=1&b=2'] };
  const rendered = p.run('ledgerValue(evidence)');
  assert.ok(!rendered.includes('<script>'));
  assert.ok(!rendered.includes('href="javascript:'));
  assert.match(rendered, /href="https:\/\/example.org\/post\?a=1&amp;b=2"/);
});

function routedPage(snapshot) {
  const p = page(snapshot);
  const handlers = new Map();
  const eventNode = id => ({ addEventListener(type, listener) { handlers.set(`${id}:${type}`, listener); } });
  const elements = { refresh: eventNode('refresh'), stamp: {}, tabs: eventNode('tabs'), settings: eventNode('settings') };
  p.views.addEventListener = eventNode('views').addEventListener;
  p.ctx.window = eventNode('window');
  const getElement = p.ctx.document.getElementById;
  p.ctx.document.getElementById = id => elements[id] || getElement(id);
  p.views.querySelector = selector => selector === '[data-read-error]' && p.views.innerHTML.includes('data-read-error')
    ? {remove() { p.views.innerHTML = p.views.innerHTML.replace(/<div[^>]*data-read-error[^>]*>.*?<\/div>/, ''); }} : null;
  p.views.insertAdjacentHTML = (_where, html) => { p.views.innerHTML = html + p.views.innerHTML; };
  const pollingStart = script.indexOf('// No RPC polling:', eventsStart);
  assert.ok(pollingStart > eventsStart);
  p.run(script.slice(refreshStart, pollingStart));
  p.emit = (id, type, target = {}) => handlers.get(`${id}:${type}`)({target});
  p.navigate = hash => { p.ctx.location.hash = `#${hash}`; return p.run('run()'); };
  p.elements = elements;
  return p;
}

for (const fail of [false, true]) test(`navigation leaves a pending Dev registry; late ${fail ? 'failure' : 'success'} cannot overwrite Live`, async () => {
  const p = routedPage(), registryRead = deferred();
  let crawls = 0;
  p.ctx.loadRegistry = () => registryRead.promise;
  p.ctx.crawl = async () => { crawls++; };
  p.ctx.viewOverview = async () => { p.views.innerHTML = 'Live results'; };
  const dev = p.navigate('lane-2-3');
  assert.match(p.views.innerHTML, /Loading/);
  assert.equal(p.run('state.view'), 'lane-2-3');
  await p.navigate('overview');
  assert.equal(p.views.innerHTML, 'Live results');
  assert.equal(p.elements.refresh.disabled, false);
  if (fail) registryRead.reject(Error('late registry failure'));
  else registryRead.resolve();
  await dev;
  assert.equal(crawls, 0, 'abandoned registry load must not start a crawl');
  assert.equal(p.views.innerHTML, 'Live results');
  assert.equal(p.run('state.env'), 'mainnet');
});

test('separate Dev run generations reject earlier RPC results', async () => {
  const p = routedPage(), firstRead = deferred(), secondRead = deferred();
  let calls = 0;
  p.ctx.loadRegistry = async () => {};
  p.ctx.crawl = env => {
    assert.equal(env, 'testnet');
    return (++calls <= 2 ? firstRead : secondRead).promise;
  };
  p.run('laneSummary = (env, a, b, ra) => `${env}: ${ra.label}`; sidePanel = () => "";');
  const first = p.navigate('lane-2-3');
  await new Promise(setImmediate);
  await p.navigate('settings');
  assert.match(p.views.innerHTML, /RPC/);
  assert.equal(p.elements.refresh.disabled, false);
  const second = p.navigate('lane-2-3');
  await new Promise(setImmediate);
  await p.run('run()');
  assert.equal(calls, 4, 'duplicate route events do not start extra crawls');
  firstRead.resolve({ label: 'old', liveAt: 1, checks: [{s: 'bad'}] });
  await first;
  assert.match(p.views.innerHTML, /Loading/);
  assert.equal(p.run('dataAt'), null);
  assert.equal(p.run('tabStatus.has("lane-2-3")'), false);
  assert.equal(p.elements.refresh.disabled, true, 'stale completion must not clear the active loading state');
  secondRead.resolve({ label: 'new', liveAt: 2000, checks: [] });
  await second;
  assert.match(p.views.innerHTML, /testnet: new/);
  assert.equal(p.run('dataAt'), 2000);
  assert.equal(p.run('tabStatus.get("lane-2-3")'), 'ok');
  assert.equal(p.elements.refresh.disabled, false);
});

for (const stage of ['registry', 'L1']) test(`leaving Live during ${stage} reads cannot overwrite the next view`, async () => {
  const p = routedPage(), pending = deferred();
  p.ctx.loadRegistry = () => stage === 'registry' && p.run('state.view') === 'overview' ? pending.promise : Promise.resolve();
  p.ctx.overviewL1 = () => pending.promise;
  const live = p.navigate('overview');
  await new Promise(setImmediate);
  await p.navigate('settings');
  const settings = p.views.innerHTML;
  pending.resolve({ at: 1 });
  await live;
  assert.equal(p.views.innerHTML, settings);
  assert.equal(p.run('ov.l1'), null);
  assert.equal(p.run('dataAt'), null);
  assert.equal(p.elements.refresh.disabled, false);
});

test('Settings loads registry on direct entry, preserves drafts, and refresh bypasses cache', async () => {
  const p = routedPage(), pending = deferred();
  let count = 0;
  p.ctx.fetch = async url => {
    count++;
    await pending.promise;
    return {ok: true, json: async () => ({data: url.includes('/chains?')
      ? {evm: {'777': {displayName: 'Registry Chain'}, '888': {displayName: 'Peer Chain'}}}
      : url.includes('/tokens?') ? {wstETH: {'777': {}}} : {}})};
  };
  const settings = p.navigate('settings');
  assert.match(p.views.innerHTML, /RPC/);
  assert.ok(!p.views.innerHTML.includes('Registry Chain'));
  const draft = {dataset: {rpc: '1'}, value: 'https://unfinished.example', selectionStart: 5, selectionEnd: 8,
    closest(selector) { return selector === '[data-rpc]' ? this : null; }};
  p.emit('views', 'input', draft);
  const replacement = {focus() { this.focused = true; }, setSelectionRange(start, end) { this.range = [start, end]; }};
  p.ctx.document.activeElement = draft;
  p.views.querySelectorAll = () => [draft];
  p.views.querySelector = () => replacement;
  pending.resolve();
  await settings;
  assert.match(p.views.innerHTML, /value="777">Registry Chain/);
  assert.match(p.views.innerHTML, /data-rpc="777"/);
  assert.equal(replacement.value, draft.value);
  assert.equal(replacement.focused, true);
  assert.deepEqual(replacement.range, [5, 8]);
  assert.equal(p.run('state.rpc[1]'), undefined, 'draft must not activate an unfinished endpoint');
  p.run('renderingSettings = true');
  p.emit('views', 'focusout', draft);
  p.run('renderingSettings = false');
  assert.equal(p.run('state.rpc[1]'), undefined, 'programmatic replacement must not commit drafts');
  p.emit('views', 'focusout', draft);
  assert.equal(p.run('state.rpc[1]'), draft.value, 'blur commits the draft even after replacement reset the change baseline');
  assert.ok([...p.store.values()].some(value => value.includes(draft.value)), 'draft is persisted');
  assert.equal(count, 3);
  await p.run('run()');
  assert.equal(count, 3);
  await p.run('forceNext = true; run()');
  assert.equal(count, 6);
});

test('Settings joins a pending Live registry and cannot repaint after navigation', async () => {
  const p = routedPage(), pending = deferred();
  let count = 0;
  p.ctx.fetch = async url => {
    count++;
    await pending.promise;
    return {ok: true, json: async () => ({data: url.includes('/chains?')
      ? {evm: {'777': {displayName: 'Registry Chain'}}} : {}})};
  };
  const live = p.navigate('overview');
  const settings = p.navigate('settings');
  await new Promise(setImmediate);
  assert.equal(count, 3);
  p.ctx.viewLedger = () => { p.views.innerHTML = 'Ledger'; };
  await p.navigate('ledger');
  pending.resolve();
  await Promise.all([live, settings]);
  assert.equal(p.views.innerHTML, 'Ledger');
});

test('Settings registry failure retains usable controls and a later refresh recovers', async () => {
  const p = routedPage();
  await p.navigate('settings');
  assert.match(p.views.innerHTML, /Registry unavailable/);
  assert.match(p.views.innerHTML, /data-rpc="1"/);
  assert.equal(p.elements.refresh.disabled, false);
  p.ctx.fetch = async () => ({ok: true, json: async () => ({data: {evm: {}}})});
  await p.run('forceNext = true; run()');
  assert.ok(!p.views.innerHTML.includes('Registry unavailable'));
});

test('abandoned snapshot fallback cannot mark Live offline; fallback revisit and recovery are explicit', async () => {
  const snapshot = {identity: 'test', registry: {testnet: {chains: {}, tokens: {}, lanes: {}}}};
  const p = routedPage(snapshot), pending = deferred();
  p.ctx.fetch = async url => {
    if (url.includes('testnet')) await pending.promise;
    return {ok: true, json: async () => ({data: {evm: {}}})};
  };
  p.ctx.viewOverview = async (_force, context) => context.publish(() => { p.views.innerHTML = 'Live'; });
  p.ctx.crawl = async () => ({checks: [], liveAt: 1000});
  p.run('laneSummary = () => "Dev"; sidePanel = () => ""; forceNext = true;');
  const dev = p.navigate('lane-2-3');
  await new Promise(setImmediate);
  await p.navigate('overview');
  pending.reject(Error('offline'));
  await dev;
  p.run('tickStamp()');
  assert.equal(p.run('offline'), false);
  assert.ok(!p.elements.stamp.textContent.includes('offline copy'));
  await p.navigate('lane-2-3');
  assert.match(p.elements.stamp.textContent, /offline copy/);
  p.ctx.fetch = async () => ({ok: true, json: async () => ({data: {evm: {}}})});
  await p.run('forceNext = true; run()');
  assert.ok(!p.elements.stamp.textContent.includes('offline copy'));
});

test('same-view refresh retains displayed data until replacement is ready', async () => {
  const p = routedPage(), pending = deferred();
  p.ctx.loadRegistry = async () => {};
  p.ctx.crawl = async () => ({checks: [], liveAt: 1000});
  p.run('laneSummary = () => "Existing data"; sidePanel = () => "";');
  await p.navigate('lane-2-3');
  const displayed = p.views.innerHTML;
  p.ctx.crawl = () => pending.promise;
  const refresh = p.run('forceNext = true; run()');
  await new Promise(setImmediate);
  assert.equal(p.views.innerHTML, displayed);
  assert.equal(p.run('dataAt'), 1000);
  assert.equal(p.elements.stamp.textContent, 'reading…');
  pending.resolve({checks: [], liveAt: 2000});
  await refresh;
  assert.equal(p.run('dataAt'), 2000);
});

test('Dev revisit shares in-flight crawls, including refresh, without merging different endpoints', async () => {
  const p = routedPage(), pending = deferred();
  let structures = 0, probes = 0;
  p.run('registry.testnet = {chains: {}, lanes: {}, tokens: {}}; registry.mainnet = {chains: {}, tokens: {}}; laneSummary = () => "Dev"; sidePanel = () => ""; buildChecks = () => [];');
  p.ctx.crawlStructure = async () => { structures++; await pending.promise;
    return {ms: 1, at: 1, rows: [{type: 'Router'}], ramps: [], nocode: []}; };
  p.ctx.probeLive = async () => { probes++; return {ms: 1}; };
  const first = p.navigate('lane-2-3');
  await new Promise(setImmediate);
  await p.navigate('settings');
  const second = p.navigate('lane-2-3');
  const refresh = p.run('forceNext = true; run()');
  await new Promise(setImmediate);
  assert.equal(structures, 2);
  p.run('state.rpc[2] = "https://other.example"');
  const otherEndpoint = p.run('crawl("testnet", 2, 3, true)');
  await new Promise(setImmediate);
  assert.equal(structures, 3);
  pending.resolve();
  await Promise.all([first, second, refresh, otherEndpoint]);
  assert.equal(probes, 3);
  assert.match(p.views.innerHTML, /Dev/);
  assert.equal(p.elements.refresh.disabled, false);
});

test('failed shared crawls are evicted so a revisit can retry', async () => {
  const p = page(), pending = deferred();
  p.run('registry.testnet = {chains: {}, tokens: {}};');
  let calls = 0;
  p.ctx.crawlStructure = async () => { calls++; await pending.promise; throw Error('failed crawl'); };
  const first = p.run('crawl("testnet", 2, 3, false)'), second = p.run('crawl("testnet", 2, 3, true)');
  const checked = Promise.all([assert.rejects(first, /failed crawl/), assert.rejects(second, /failed crawl/)]);
  pending.resolve();
  await checked;
  assert.equal(calls, 1);
  await assert.rejects(p.run('crawl("testnet", 2, 3, false)'), /failed crawl/);
  assert.equal(calls, 2);
});

test('abandoned overview supply callbacks cannot modify a revisited overview', async () => {
  const p = routedPage(), oldRead = deferred(), newRead = deferred();
  p.run(`loadRegistry = async () => {}; overviewRows = () => []; ldoRows = () => [];
    overviewL1 = async () => ({at: 5000, err: null, escrow: {}, silo: {}, pool: {addr: null, held: null, unsiloed: null}});`);
  let calls = 0;
  p.ctx.destinationSupply = () => (++calls === 1 ? oldRead : newRead).promise;
  p.ctx.stethRate = async () => ({err: 'unavailable', at: null});
  await p.navigate('overview');
  await p.navigate('settings');
  await p.navigate('overview');
  const displayed = p.views.innerHTML;
  oldRead.resolve({v: 1n, at: 1});
  await new Promise(setImmediate);
  assert.equal(p.views.innerHTML, displayed);
  assert.equal(p.run('steth.supply.size'), 0);
  assert.equal(p.run('dataAt'), 5000);
  newRead.resolve({v: 2n, at: 2000});
  await new Promise(setImmediate);
  assert.equal(p.run('steth.supply.get(steth.rows[0].key).v'), 2n);
  assert.equal(p.run('dataAt'), 2000);
});

test('ledger search indexes values without matching schema keys', () => {
  const p = page();
  p.run('indexLedger()');
  p.ctx.entry = {networkId: 'unknown', contractId: 'widget', contractName: 'Widget', auditReportRefs: [], source: null};
  for (const term of ['audit', 'contract', 'network', 'source', 'deployment']) {
    p.ctx.term = term;
    assert.equal(p.run('ledgerMatches({entry, search: ledgerSearchValues(entry).toLowerCase()}, term)'), false);
  }
  assert.ok(p.run('ledgerEntries.filter(x => ledgerMatches(x, "audit")).length') < build.ledger.deployments.length);
});

test('ledger details distinguish unrecorded from explicitly empty public references', () => {
  const p = page();
  p.ctx.entry = {...build.ledger.deployments[0], publicRefs: null};
  assert.match(p.run('ledgerDetails(entry)'), /Public posts &amp; references<\/dt><dd><span class="muted">Not recorded/);
  p.ctx.entry.publicRefs = [];
  assert.match(p.run('ledgerDetails(entry)'), /Public posts &amp; references<\/dt><dd><span class="muted">None recorded/);
});

test('same-chain escrow rows retain distinct balances through cache and rendering', async () => {
  const p = page();
  p.ctx.rows = [10, 20].map(n => ({ chainId: '5000', token: address(n),
    escrow: address(n + 1), group: 'supported', key: `5000:${address(n)}` }));
  p.ctx.response = [abi(1), abi(2), abi(10), abi(20), '0x1', abi(18), abi(100)];
  p.run('rpcRead = async () => response');
  await p.run('overviewL1(rows, true).then(result => { ov.l1 = result; })');
  assert.equal(p.run('ovBacking(rows[0]).v'), 10n);
  assert.equal(p.run('ovBacking(rows[1]).v'), 20n);
  p.run('rpcRead = async () => { throw Error("Cache should answer"); }');
  await p.run('overviewL1(rows, false).then(result => { ov.l1 = result; })');
  assert.equal(p.run('ovBacking(rows[1]).v'), 20n);
});

const abi = n => '0x' + BigInt.asUintN(256, BigInt(n)).toString(16).padStart(64, '0');
const round = (answer, updatedAt = Math.floor(Date.now() / 1000), id = 2, answered = id) =>
  '0x' + [id, answer, updatedAt, updatedAt, answered].map(n => abi(n).slice(2)).join('');

test('summary keeps token units separate and counts unique networks within overlapping groups', () => {
  const p = page(), total = {innerHTML: ''}, counts = {innerHTML: ''};
  p.ctx.document.querySelector = s => s === '[data-ov-total]' ? total : s === '[data-ov-networks]' ? counts : null;
  p.ctx.rows = [
    {chainId: '10', token: address(10), key: 'a', group: 'supported'},
    {chainId: '10', token: address(11), key: 'b', group: 'ccip'},
    {chainId: '20', token: address(20), key: 'c', group: 'legacy'},
  ];
  p.run(`ov.rows = rows; registry.mainnet = {}; ov.l1 = {supply: 1000n * 10n ** 18n, stethSupply: 2000n * 10n ** 18n, rate: null, escrow: {}};
    for (const r of rows) ov.supply.set(r.key, {v: 10n * 10n ** 18n});
    steth.rows = [rows[0]]; steth.supply.set('a', {v: 5n * 10n ** 18n});
    ldo.rows = [rows[2]]; ldo.supply.set('c', {v: 7n * 10n ** 18n}); ovPaintSummary();`);
  assert.match(total.innerHTML, /wstETH <b>30<\/b> · 3.00%/);
  assert.match(total.innerHTML, /stETH <b>5<\/b> · 0.25%/);
  assert.match(total.innerHTML, /LDO <b>7<\/b>/);
  assert.match(counts.innerHTML, /<b>2<\/b> networks/);
  assert.match(counts.innerHTML, /Total stETH <b>2,000<\/b>/);
  for (const label of ['endorsed', 'deendorsed', 'CCIP']) assert.ok(counts.innerHTML.includes(`<b>1</b> ${label}`));
  p.run('ov.rows.push(rows[0]); ovPaintSummary();');
  assert.match(total.innerHTML, /wstETH <b>30<\/b> · 3.00%/);
  p.run("steth.supply.set('a', {v: 8n * 10n ** 18n}); stethPaintNumbers();");
  assert.match(total.innerHTML, /stETH <b>8<\/b> · 0.40%/);
  p.run("ldo.supply.set('c', {v: 9n * 10n ** 18n}); ldoPaintNumbers();");
  assert.match(total.innerHTML, /LDO <b>9<\/b>/);
});

test('summary USD rounds upward with k and kk suffixes, including unit boundaries', () => {
  const p = page();
  for (const [cents, expected] of [
    [0n, '$0'], [1n, '$1'], [99900n, '$999'], [99901n, '$1k'],
    [100000n, '$1k'], [123401n, '$1.3k'], [99990000n, '$999.9k'],
    [99990001n, '$1kk'], [100000000n, '$1kk'], [45454558800n, '$454.6kk'],
  ]) {
    p.ctx.value = cents * 10n ** 16n;
    assert.equal(p.run('summaryUsd(value)'), expected);
  }
});

test('summary shows USD for wstETH and LDO and retains supply when prices expire', () => {
  const p = page(), total = {innerHTML: ''};
  p.ctx.document.querySelector = s => s === '[data-ov-total]' ? total : null;
  p.ctx.row = {chainId: 10, token: address(10), key: 'a'};
  p.run(`ov.rows = [row]; ldo.rows = [row];
    ov.supply.set('a', {v: 1000n * 10n ** 18n}); ldo.supply.set('a', {v: 1000n * 10n ** 18n});
    ov.l1 = {supply: 10000n * 10n ** 18n, rate: 12n * 10n ** 17n};
    steth.quote = {rounds: [{answer: String(2500n * 10n ** 8n), updatedAt: Date.now()}]};
    ldo.quote = {rounds: [{answer: String(2n * 10n ** 14n), updatedAt: Date.now()},
      {answer: String(2500n * 10n ** 8n), updatedAt: Date.now()}]}; ovPaintSummary();`);
  assert.match(total.innerHTML, /wstETH <b>1,000<\/b> · 10.00% · ≈ \$3kk/);
  assert.match(total.innerHTML, /LDO <b>1,000<\/b> · ≈ \$500/);
  p.run('steth.quote.rounds[0].updatedAt -= 3601000; ldo.quote.rounds[1].updatedAt -= 3601000; ovPaintSummary();');
  assert.match(total.innerHTML, /wstETH <b>1,000<\/b> · 10.00% · USD unavailable/);
  assert.match(total.innerHTML, /LDO <b>1,000<\/b> · USD unavailable/);
});

test('summary distinguishes pending, failed, partial, zero and missing denominators', () => {
  const p = page();
  p.ctx.rows = [1, 2].map(n => ({chainId: n, token: address(n), key: String(n)}));
  p.run('steth.rows = rows;');
  const chip = () => p.run("summaryToken('stETH', steth, ov.l1?.stethSupply ?? null)");
  assert.match(chip(), /loading/);
  assert.ok(!chip().includes('<b>0</b>'));
  p.run("steth.supply.set('1', {v: 1n});");
  assert.match(chip(), /&lt;0.01.*% unavailable.*partial 1\/2/);
  p.run('ov.l1 = {stethSupply: 10n ** 18n}');
  assert.match(chip(), /&lt;0.01%/);
  p.run("steth.supply.set('1', {v: 0n}); steth.supply.set('2', {v: 0n});");
  assert.match(chip(), /<b>0<\/b> · 0.00%/);
  p.run("steth.supply.set('1', {v: null}); steth.supply.set('2', {v: null});");
  assert.match(chip(), /unavailable/);
  assert.ok(!chip().includes('<b>0</b>'));
  p.run('steth.rows = [];');
  assert.match(chip(), /chip c-mute/);
  assert.match(chip(), /unavailable/);
});

test('stETH denominator rejects wrong chain, decimals and malformed supply without hiding wstETH', async () => {
  const p = page();
  for (const tail of [['0xa', abi(18), abi(100)], ['0x1', abi(8), abi(100)], ['0x1', abi(18), '0x1'],
    [null, abi(18), abi(100)], ['0x1', null, abi(100)], ['0x1', abi(18), null]]) {
    p.ctx.response = [abi(20), abi(1), ...tail];
    p.run('rpcRead = async () => response');
    const result = await p.run('overviewL1([], true)');
    assert.equal(result.supply, 20n);
    assert.equal(result.stethSupply, null);
    assert.match(result.stethSupplyError, /Ethereum|decimals|supply/);
    assert.equal(p.run('metaCache.has(OV_KEY)'), false);
  }
});

test('failed stETH denominator retries on ordinary loads and bypasses old incomplete caches', async () => {
  const p = page();
  let reads = 0;
  p.ctx.rpcRead = async (_url, calls) => {
    if (!calls.some(c => c.params[0]?.data === '0x18160ddd')) return [];
    reads++;
    return [abi(20), abi(1), '0x1', abi(18), reads === 1 ? null : abi(100)];
  };
  p.ctx.failed = await p.run('overviewL1([], false)');
  assert.equal(p.ctx.failed.stethSupply, null);
  assert.equal(p.run('metaCache.has(OV_KEY)'), false);
  const recovered = await p.run('overviewL1([], false)');
  assert.equal(reads, 2);
  assert.equal(recovered.stethSupply, 100n);
  assert.equal(recovered.stethSupplyError, null);
  await p.run('overviewL1([], false)');
  assert.equal(reads, 2, 'successful reads stay cached');
  p.run('metaCache.get(OV_KEY).stethSupply = null; saveCache();');
  await p.run('overviewL1([], false)');
  assert.equal(reads, 3, 'old incomplete entries must not freeze the missing denominator');

  const total = {innerHTML: ''};
  p.ctx.document.querySelector = s => s === '[data-ov-total]' ? total : null;
  p.run('ov.l1 = failed; steth.rows = [{chainId: 10, token: STETH.l1Token, key: "a"}]; steth.supply.set("a", {v: 1n}); ovPaintSummary();');
  assert.match(total.innerHTML, /title="[^"]*stETH supply unavailable/);
  assert.match(total.innerHTML, /% unavailable/);
});

test('LDO rows deduplicate wstETH deployments and include LDO-only networks', () => {
  const p = page();
  p.ctx.networks = [{ chainId: 10, name: 'Optimism', token: address(1) },
    { chainId: 10, name: 'Optimism', token: address(2) },
    { chainId: 999, name: 'Unknown', token: address(3) },
    { chainId: 999, name: 'Unknown', token: address(4) }];
  assert.equal(p.run('ldoRows(networks).filter(r => r.chainId === "10").length'), 1);
  assert.equal(p.run('ldoRows(networks).filter(r => r.chainId === "999").length'), 1);
  assert.ok(p.run('ldoRows(networks).some(r => r.chainId === "42220" && r.token)'));
  assert.ok(p.run('bridgeSupplyStatus(ldoRows(networks).find(r => !r.token))').includes('Not identified'));
});

test('LDO supply distinguishes zero, failures and wrong-chain endpoints; cache follows RPC', async () => {
  const p = page();
  p.ctx.row = { chainId: '10', token: address(10), decimals: 18, key: `10:${address(10)}` };
  p.ctx.rpc = async () => ['0xa', abi(18), abi(0)];
  const zero = await p.run('ldoSupply(row, true)');
  assert.equal(zero.v, 0n);
  p.ctx.observation = zero;
  assert.ok(p.run('bridgeSupplyStatus(row, observation)').includes('No outstanding supply'));
  p.ctx.rpc = async () => { throw Error('must use cache'); };
  assert.equal((await p.run('ldoSupply(row, false)')).v, 0n);
  p.run('state.rpc[10] = "https://new-rpc.example"');
  assert.equal((await p.run('ldoSupply(row, false)')).v, null);
  p.ctx.rpc = async () => ['0x1', abi(18), abi(99)];
  assert.match((await p.run('ldoSupply(row, true)')).err, /chain/);
  p.ctx.rpc = async () => ['0xa', abi(8), abi(99)];
  assert.match((await p.run('ldoSupply(row, true)')).err, /decimals/);
  p.ctx.rpc = async () => ['0xa', abi(18), null];
  assert.equal((await p.run('ldoSupply(row, true)')).v, null);
  p.ctx.observation = { v: null, err: 'offline' };
  assert.ok(p.run('bridgeSupplyStatus(row, observation)').includes('Supply unread'));
});

test('LDO USD uses both feed scales and refuses stale, negative, incomplete or future prices', async () => {
  const p = page();
  p.ctx.rpc = async () => ['0x1', abi(18), round(2n * 10n ** 14n), abi(8), round(2500n * 10n ** 8n)];
  p.run('ldo.quote = null');
  p.ctx.quote = await p.run('ldoPrice(true)');
  p.run('ldo.quote = quote');
  assert.equal(p.run('ldoUsd(3n * 10n ** 18n)'), 15n * 10n ** 17n); // 3 × .0002 × 2500 = $1.50
  p.ctx.observation = { v: 3n * 10n ** 18n, at: Date.now() };
  assert.match(p.run('ldoAmount(observation)'), /≈ \$2/);
  assert.match(p.run('ldoAmount(observation)'), /3 LDO/);
  p.ctx.rpc = async () => { throw Error('cache should answer'); };
  assert.equal((await p.run('ldoPrice(false)')).err, null);
  const now = Math.floor(Date.now() / 1000);
  for (const [bad, error] of [[round(-1), /invalid oracle/], [round(0), /invalid oracle/],
    [round(1, now, 2, 1), /invalid oracle/], [round(1, 0), /invalid oracle/],
    [round(1, now - 86401), /stale/], [round(1, now + 121), /timestamp/], [null, /unavailable/]]) {
    p.ctx.rpc = async () => ['0x1', abi(18), bad, abi(8), round(2500n * 10n ** 8n)];
    const quote = await p.run('ldoPrice(true)');
    p.ctx.quote = quote;
    assert.match(p.run("ldoPriceError(quote)"), error);
    p.ctx.quote = quote; p.run('ldo.quote = quote');
    assert.equal(p.run('ldoUsd(1n)'), null);
    assert.match(p.run('ldoAmount(observation)'), /3 LDO.*USD unavailable/s);
  }
  p.ctx.rpc = async () => ['0x1', abi(18), round(1), abi(8), round(1, now - 3601)];
  p.ctx.quote = await p.run('ldoPrice(true)');
  assert.match(p.run('ldoPriceError(quote)'), /ETH \/ USD: stale/);
  p.ctx.rpc = async () => ['0x1', abi(8), round(1), abi(8), round(1)];
  assert.match((await p.run('ldoPrice(true)')).err, /decimals/);
  p.ctx.rpc = async () => ['0xa', abi(18), round(1), abi(8), round(1)];
  assert.match((await p.run('ldoPrice(true)')).err, /mainnet/);
});

test('LDO cached price expires and rendering both amounts requires no network reads', async () => {
  const p = page();
  p.ctx.rpc = async () => ['0x1', abi(18), round(10n ** 15n), abi(8), round(2000n * 10n ** 8n)];
  p.ctx.quote = await p.run('ldoPrice(true)');
  p.run('ldo.quote = quote; quote.rounds[1].updatedAt = Date.now() - 3601000;');
  assert.equal(p.run('ldoUsd(10n ** 18n)'), null);
  let reads = 0;
  p.ctx.rpc = async () => { reads++; return ['0x1', abi(18), round(10n ** 15n), abi(8), round(2000n * 10n ** 8n)]; };
  p.ctx.quote = await p.run('ldoPrice(false)');
  assert.equal(reads, 1);
  p.run('ldo.quote = quote; ldoPaintNumbers();');
  assert.equal(reads, 1);
});

test('LDO totals label partial coverage and sort read supplies above unavailable ones', () => {
  const p = page(), total = { innerHTML: '' };
  p.ctx.document.querySelector = selector => selector === '[data-ldo-total]' ? total : null;
  p.ctx.rows = [{ token: address(1), key: 'a' }, { token: address(2), key: 'b' }, { token: null, key: 'unknown' }];
  p.run('ldo.rows = rows; ldo.supply.set("a", { v: 5n * 10n ** 18n }); ldo.supply.set("b", { v: null, err: "offline" }); ldoPaintNumbers();');
  assert.match(total.innerHTML, /Partial LDO supply/);
  assert.match(total.innerHTML, /5 LDO/);
  assert.match(total.innerHTML, /1\/2 deployments read/);
  assert.equal(p.run('sortedSupplyRows(ldo.rows, ldo.supply).map(r => r.key).join(",")'), 'a,b');
  p.run('ldo.supply.set("b", { v: 0n }); ldoPaintNumbers();');
  assert.match(total.innerHTML, /Supply on listed LDO networks/);
  assert.match(total.innerHTML, /2\/2 deployments read/);
  assert.equal(p.run('sortedSupplyRows(ldo.rows, ldo.supply).map(r => r.key).join(",")'), 'a,b');
  p.run('ldo.supply.set("b", { v: 5n * 10n ** 18n + 1n }); ldoPaintNumbers();');
  assert.equal(p.run('sortedSupplyRows(ldo.rows, ldo.supply).map(r => r.key).join(",")'), 'b,a');
  p.run('ldo.supply.set("a", { v: null, err: "offline" }); ldoPaintNumbers();');
  assert.equal(p.run('sortedSupplyRows(ldo.rows, ldo.supply).map(r => r.key).join(",")'), 'b,a');
  p.run('ldo.supply.clear(); ldoPaintNumbers();');
  assert.match(total.innerHTML, /LDO supply loading/);
  assert.ok(!total.innerHTML.includes('0 LDO'));
});

test('small positive LDO amounts are not displayed as zero', () => {
  const p = page();
  p.ctx.observation = { v: 1n };
  assert.match(p.run('ldoAmount(observation)'), /&lt;0.01 LDO/);
});

test('stETH rate separates L1 measurement and L2 receipt and verifies the token oracle', async () => {
  const p = page(), now = Math.floor(Date.now() / 1000), measured = now - 7200, updated = now - 600;
  p.run('steth.rows = stethRows();');
  const validRound = '0x' + [measured, 12n * 10n ** 26n, measured, updated, measured].map(n => abi(n).slice(2)).join('');
  const response = ['0xa', abi(11), abi(27), validRound, abi(3600), abi(0)];
  p.ctx.rpc = async () => response;
  p.ctx.rate = await p.run('stethRate(steth.rows[0], true)');
  assert.equal(p.ctx.rate.startedAt, measured * 1000);
  assert.equal(p.ctx.rate.updatedAt, updated * 1000);
  assert.equal(p.ctx.rate.answer, (12n * 10n ** 26n).toString());
  assert.equal(p.run('stethRateStatus(rate)'), ''); // Outdated limit is based on L2 receipt.
  p.ctx.rpc = async () => { throw Error('cache should answer'); };
  assert.equal((await p.run('stethRate(steth.rows[0], false)')).startedAt, measured * 1000);
  p.run('rate.paused = true');
  assert.match(p.run('stethRateStatus(rate)'), /Updates paused/);
  p.run('rate.paused = false; rate.updatedAt = Date.now() - 3601000');
  assert.match(p.run('stethRateStatus(rate)'), /Rate outdated/);
  p.run('state.rpc[10] = "https://another.example"');
  assert.match((await p.run('stethRate(steth.rows[0], false)')).err, /cache should answer/);
  for (const [index, value, error] of [[0, '0x1', /chain/], [1, abi(12), /oracle/],
    [2, abi(18), /decimals/], [3, round(-1), /Invalid rate/], [3, null, /Rate unavailable/]]) {
    const bad = [...response]; bad[index] = value;
    p.ctx.rpc = async () => bad;
    assert.match((await p.run('stethRate(steth.rows[0], true)')).err, error);
  }
});

test('stETH USD values use token supply directly and expire with the price heartbeat', async () => {
  const p = page();
  p.ctx.rpc = async () => ['0x1', abi(8), round(2500n * 10n ** 8n)];
  p.ctx.quote = await p.run('stethPrice(true)');
  p.run('steth.quote = quote');
  assert.equal(p.run('stethUsd(3n * 10n ** 18n)'), 7500n * 10n ** 18n);
  assert.match(p.run('bridgedAmount({v: 3n * 10n ** 18n}, "stETH", stethUsd(3n * 10n ** 18n))'), /3 stETH.*≈ \$7,500/s);
  p.ctx.rpc = async () => { throw Error('cache should answer'); };
  assert.equal((await p.run('stethPrice(false)')).err, null);
  p.run('quote.rounds[0].updatedAt = Date.now() - 3601000');
  assert.equal(p.run('stethUsd(3n * 10n ** 18n)'), null);
  for (const [value, error] of [[round(-1), /invalid oracle/],
    [round(1, Math.floor(Date.now() / 1000) - 3601), /stale/]]) {
    p.ctx.rpc = async () => ['0x1', abi(8), value];
    p.ctx.quote = await p.run('stethPrice(true)');
    assert.match(p.run('stethPriceError(quote)'), error);
  }
});

test('stETH supply cache is independent of LDO and unread supply preserves rate data', async () => {
  const p = page(), total = { innerHTML: '' }, amount = { innerHTML: '' }, rate = { innerHTML: '' };
  p.run('steth.rows = stethRows();');
  p.ctx.rpc = async () => ['0xa', abi(18), abi(3n * 10n ** 18n)];
  assert.equal((await p.run('stethSupply(steth.rows[0], true)')).v, 3n * 10n ** 18n);
  assert.equal(p.run('metaCache.has(`ldo-supply|${steth.rows[0].key}`)'), false);
  p.ctx.rpc = async () => { throw Error('offline'); };
  assert.equal((await p.run('stethSupply(steth.rows[0], false)')).v, 3n * 10n ** 18n);
  p.ctx.document.querySelector = selector => selector === '[data-steth-total]' ? total
    : selector.startsWith('[data-steth-amount=') ? amount : selector.startsWith('[data-steth-rate=') ? rate : null;
  p.run('steth.supply.set(steth.rows[0].key, {v: null, err: "offline"}); steth.rates.set(steth.rows[0].key, {answer: (12n * 10n ** 26n).toString(), updatedAt: Date.now(), outdatedDelay: 3600, paused: false}); stethPaintNumbers();');
  assert.match(total.innerHTML, /stETH supply unavailable/);
  assert.ok(!total.innerHTML.includes('0 stETH'));
  assert.match(amount.innerHTML, /Unavailable/);
  assert.match(rate.innerHTML, /1.2/);
});

test('silo observations remain addressable by row identity', async () => {
  const p = page();
  p.ctx.pool = address(99);
  p.ctx.rows = [10, 20].map(n => ({ chainId: String(n), token: address(n),
    selector: String(n), group: 'ccip', key: `${n}:${address(n)}` }));
  p.run('registry.mainnet = { tokens: { wstETH: { "1": { poolAddress: pool } } } }; rpcRead = async () => [1,2,30,0,1,10,1,20].map(n => "0x" + n.toString(16).padStart(64, "0"))');
  await p.run('overviewL1(rows, true).then(result => { ov.l1 = result; })');
  assert.equal(p.run('ovBacking(rows[0]).v'), 10n);
  assert.equal(p.run('ovBacking(rows[1]).v'), 20n);
});

test('clear cache empties memory and storage, settings renders and registry refetches', async () => {
  const p = page();
  p.run('registry.mainnet = { chains: {}, tokens: {} }; structCache.set("x", {}); metaCache.set("x", {}); localStorage.setItem(REG_KEY, "{}"); localStorage.setItem(CACHE_KEY, "{}"); clearCache(); viewSettings();');
  assert.equal(p.run('Object.keys(registry).length + structCache.size + metaCache.size'), 0);
  assert.equal(p.store.size, 0);
  let requests = 0;
  p.ctx.fetch = async () => { requests++; return { ok: true, json: async () => ({ data: { evm: {} } }) }; };
  await p.run('loadRegistry("mainnet", false)');
  assert.equal(requests, 3);
});

test('duplicate crawl seeds issue one set of identification requests', async () => {
  const p = page();
  p.ctx.addr = address(99);
  p.run('registry.mainnet = { chains: { "1": { router: addr, rmn: addr } }, lanes: {}, tokens: {} };');
  let calls = 0;
  p.ctx.rpc = async (_url, batch) => { calls += batch.length; return batch.map(() => '0x'); };
  await p.run('crawl("mainnet", "1", "2", true)');
  assert.equal(calls, 3); // type, symbol, bytecode: one address even with two origins
});

test('overview pool link and copy use the address; token hash falls back to overview', async () => {
  const p = page();
  p.ctx.pool = address(99);
  p.run('loadRegistry = async () => {}; overviewRows = () => []; overviewL1 = async () => ({ at: 1, err: null, escrow: {}, silo: {}, pool: { addr: pool, held: null, unsiloed: null } }); ovUpdateTotals = () => {};');
  await p.run('viewOverview(false, viewContext("overview", "mainnet"))');
  assert.ok(p.views.innerHTML.includes(`https://etherscan.io/address/${p.ctx.pool}`));
  assert.ok(p.views.innerHTML.includes(`data-copy="${p.ctx.pool}"`));
  assert.ok(!p.views.innerHTML.includes('[object Object]'));
  assert.equal(p.run('currentView()'), 'overview');
  assert.equal(p.run('typeof tokenSnapshot'), 'undefined');
});

test('snapshot extraction names missing opening and section rule markers', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'dashboard-marker-'));
  try {
    const built = html.replace('id="dashboard-data">{}', `id="dashboard-data">${JSON.stringify(build)}`);
    for (const [input, expected] of [
      [built.replace('<script>\n"use strict";', '<script>\n// moved'), 'script opening marker not found'],
      [built.replace(/\/\/ ─+\n(\/\/ 8\. Refresh)/, '$1'), 'section 8 rule marker not found'],
    ]) {
      writeFileSync(path.join(dir, 'index.html'), input);
      const result = spawnSync(process.execPath, [new URL('../scripts/build-lane-watch-snapshot.mjs', import.meta.url).pathname, '--site', dir], { encoding: 'utf8' });
      assert.notEqual(result.status, 0);
      assert.ok(result.stderr.includes(expected), result.stderr);
    }
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('missing stETH denominator or registry prevents a green overview', () => {
  const p = page(), now = Math.floor(Date.now() / 1000);
  p.ctx.now = now;
  p.run(`registry.mainnet = {chains: {}, tokens: {}};
    ov.rows = []; ov.l1 = {err: null, stethSupply: 100n}; ldo.rows = []; steth.rows = [];
    ldo.quote = {rounds: LDO.priceFeeds.map(() => ({updatedAt: now * 1000}))};
    steth.quote = {rounds: [{updatedAt: now * 1000}]};
    ovUpdateStatus();`);
  assert.equal(p.run('tabStatus.get("overview")'), 'ok');
  p.run('ov.l1.stethSupply = null; ovUpdateStatus();');
  assert.equal(p.run('tabStatus.get("overview")'), 'warn');
  p.run('ov.l1.stethSupply = 100n; ovUpdateStatus();');
  assert.equal(p.run('tabStatus.get("overview")'), 'ok');
  p.run('ov.registryError = "HTTP 503"; ovUpdateStatus();');
  assert.equal(p.run('tabStatus.get("overview")'), 'warn');
  p.run('ov.registryError = null; delete registry.mainnet; ovUpdateStatus();');
  assert.equal(p.run('tabStatus.get("overview")'), 'warn');
});

test('oracle clock skew is bounded and temporal errors recover without another RPC', async () => {
  const p = page();
  const now = Math.floor(Date.now() / 1000) * 1000;
  p.ctx.clock = now;
  p.run('Date.now = () => clock');
  let reads = 0;
  p.ctx.rpc = async () => { reads++; return ['0x1', abi(8), round(2500n * 10n ** 8n, now / 1000 + 90)]; };
  p.ctx.quote = await p.run('stethPrice(true)');
  p.run('steth.quote = quote; ov.l1 = {rate: 12n * 10n ** 17n};');
  assert.equal(p.run('stethPriceError(quote)'), null);
  assert.equal(p.run('ovUsd(10n ** 18n)'), 3000n * 10n ** 18n);
  p.ctx.clock = now - 40000;
  assert.match(p.run('stethPriceError(quote)'), /timestamp/);
  assert.equal(p.run('ovUsd(10n ** 18n)'), null);
  p.ctx.clock = now + 1000;
  assert.equal(p.run('stethPriceError(quote)'), null);
  assert.equal(p.run('stethUsd(10n ** 18n)'), 2500n * 10n ** 18n);
  p.ctx.clock = now + 3691000;
  assert.match(p.run('stethPriceError(quote)'), /stale/);
  assert.equal(p.run('ovUsd(10n ** 18n)'), null);
  assert.equal(reads, 1);
  assert.equal(p.ctx.quote.err, null);
});

test('USD loading is neutral, and a completed failed price retains the token amount', () => {
  const p = page();
  p.ctx.observation = {v: 3n * 10n ** 18n};
  const loading = p.run('ldoAmount(observation)');
  assert.match(loading, /3 LDO.*Loading USD price/s);
  assert.ok(!loading.includes('c-warn'));
  p.run('ldo.quote = {err: "offline"}');
  assert.match(p.run('ldoAmount(observation)'), /3 LDO.*USD unavailable/s);
});

test('Ethereum reads share one batch and one checked stETH quote across tables', async () => {
  const p = page(), batches = [];
  p.ctx.rpc = async (_url, calls) => {
    batches.push(calls);
    return calls.map(c => {
      if (c.method === 'eth_chainId') return '0x1';
      const {to, data} = c.params[0];
      if (data === '0x313ce567') return abi(to === build.steth.l1Token || to.toLowerCase() === ldoMetadata.priceFeeds[0].address.toLowerCase() ? 18 : 8);
      if (data === '0xfeaf968c') return round(to.toLowerCase() === ldoMetadata.priceFeeds[0].address.toLowerCase() ? 2n * 10n ** 14n : 2500n * 10n ** 8n);
      if (data === '0x035faf82') return abi(12n * 10n ** 17n);
      return abi(10n ** 18n);
    });
  };
  p.ctx.result = await p.run('overviewL1([], true)');
  assert.equal(p.ctx.result.stethSupply, 10n ** 18n);
  assert.equal(batches.length, 1);
  assert.equal(batches[0].filter(c => c.method === 'eth_chainId').length, 1);
  assert.equal(batches[0].filter(c => c.params[0]?.to.toLowerCase() === stethMetadata.priceFeed.address.toLowerCase()
    && c.params[0].data === '0xfeaf968c').length, 1);
  assert.ok(!batches[0].some(c => c.params[0]?.data === '0x50d25bcd'));
  p.run('ov.l1 = result; steth.quote = result.stethQuote;');
  assert.equal(p.run('ovUsd(10n ** 18n)'), 3000n * 10n ** 18n);
  assert.equal(p.run('stethUsd(10n ** 18n)'), 2500n * 10n ** 18n);
  p.run('rpc = async () => { throw Error("structural cache must remain usable"); }; result.stethQuote.rounds[0].updatedAt = Date.now() - 3601000;');
  p.ctx.cached = await p.run('overviewL1([], false)');
  assert.equal(p.ctx.cached.supply, 10n ** 18n);
  assert.equal(p.ctx.cached.stethSupply, 10n ** 18n);
  assert.match(p.ctx.cached.stethQuote.err, /structural cache/);
});

test('stETH supply and rate coalesce without coupling their subcall failures', async () => {
  const p = page(), now = Math.floor(Date.now() / 1000), batches = [];
  p.ctx.rpc = async (_url, calls) => {
    batches.push(calls);
    return calls.map(c => {
      if (c.method === 'eth_chainId') return '0xa';
      const {to, data} = c.params[0];
      if (data === '0x313ce567') return abi(to === address(10) ? 18 : 27);
      if (data === '0x18160ddd') return null; // A supply failure does not invalidate the rate.
      if (data === '0x45a8306f') return abi(11);
      if (data === '0x882bd77d') return abi(3600);
      if (data === '0x842170f7') return abi(0);
      if (data === '0xfeaf968c') return '0x' + [now - 7200, 12n * 10n ** 26n, now - 7200, now - 600, now - 7200].map(n => abi(n).slice(2)).join('');
      throw Error('Unexpected call');
    });
  };
  const [supply, rate] = await p.run('Promise.all([stethSupply(stethRows()[0], true), stethRate(stethRows()[0], true)])');
  assert.equal(batches.length, 1);
  assert.equal(batches[0].filter(c => c.method === 'eth_chainId').length, 1);
  assert.equal(supply.v, null);
  assert.equal(rate.err, null);
  assert.equal(rate.startedAt, (now - 7200) * 1000);
});

test('cache clear detaches pending registry reads and prevents late persistence or publication', async () => {
  const p = routedPage(), pending = deferred();
  p.ctx.fetch = async url => {
    await pending.promise;
    return {ok: true, json: async () => ({data: url.includes('/chains?') ? {evm: {'99': {displayName: 'Obsolete'}}} : {}})};
  };
  const first = p.navigate('settings');
  await new Promise(setImmediate);
  await p.emit('views', 'click', {id: 'cacheclear', closest: () => null});
  const clearedView = p.views.innerHTML;
  assert.equal(p.elements.refresh.disabled, false);
  pending.resolve();
  await first;
  assert.equal(p.views.innerHTML, clearedView);
  assert.equal(p.run('registry.mainnet'), undefined);
  assert.equal(p.store.has(p.run('REG_KEY')), false);
  let calls = 0;
  p.ctx.fetch = async () => { calls++; return {ok: true, json: async () => ({data: {evm: {}}})}; };
  await p.run('loadRegistry("mainnet", false)');
  assert.equal(calls, 3);
});

test('cleared crawl uses its captured registry without repopulating caches or deleting newer pending work', async () => {
  const p = page(), old = deferred(), fresh = deferred();
  let reads = 0;
  p.run('registry.testnet = {chains: {2: {}, 3: {selector: "123"}}}; buildChecks = () => [];');
  p.ctx.crawlStructure = async () => {
    await (++reads === 1 ? old : fresh).promise;
    return {ms: 0, at: 1, rows: [{type: 'Router'}], ramps: [], nocode: []};
  };
  p.ctx.probeLive = async (_url, _st, selector) => { assert.equal(selector, '123'); return {ms: 0}; };
  const first = p.run('crawl("testnet", 2, 3, true)');
  await new Promise(setImmediate);
  p.run('clearCache(); registry.testnet = {chains: {2: {}, 3: {selector: "123"}}};');
  const second = p.run('crawl("testnet", 2, 3, true)');
  await new Promise(setImmediate);
  old.resolve();
  await first;
  assert.equal(p.run('structCache.size'), 0);
  assert.equal(p.store.has(p.run('CACHE_KEY')), false);
  assert.equal(p.run('crawlReads.size'), 1);
  assert.equal(p.run('crawl("testnet", 2, 3, true)'), second);
  fresh.resolve();
  await second;
  assert.equal(p.run('structCache.size'), 1);
});

test('clear cache prevents outstanding overview supplies from restoring persisted observations', async () => {
  const p = page(), pending = deferred();
  p.ctx.rpcRead = () => pending.promise;
  const read = p.run('overviewSupply({chainId: 1, token: L1_WSTETH}, true)');
  p.run('clearCache()');
  pending.resolve([abi(100)]);
  assert.equal((await read).v, 100n);
  assert.equal(p.run('metaCache.size'), 0);
  assert.equal(p.store.has(p.run('CACHE_KEY')), false);
});

test('baked registry startup is not a network failure; failed refresh and recovery are distinguished', async () => {
  const p = routedPage({identity: 'test', registry: {mainnet: {chains: {}, tokens: {}, lanes: {}}}});
  let calls = 0;
  p.ctx.fetch = async () => { calls++; throw Error('offline'); };
  await p.navigate('settings');
  assert.equal(calls, 0);
  assert.equal(p.run('offline'), false);
  await p.run('forceNext = true; run()');
  assert.equal(p.run('offline'), true);
  p.run('clearCache()');
  await p.run('run()');
  assert.equal(p.run('offline'), false, 'a reused baked object must not retain earlier failure provenance');
  p.ctx.fetch = async () => ({ok: true, json: async () => ({data: {evm: {}}})});
  await p.run('forceNext = true; run()');
  assert.equal(p.run('offline'), false);
});

test('failed same-view refresh retains lane data and timestamp with one error, then recovers', async () => {
  const p = routedPage();
  p.ctx.loadRegistry = async () => {};
  p.ctx.crawl = async () => ({checks: [], liveAt: 1000});
  p.run('laneSummary = () => "Existing lane data"; sidePanel = () => "";');
  await p.navigate('lane-2-3');
  p.ctx.loadRegistry = async () => { throw Error('offline registry'); };
  for (let i = 0; i < 3; i++) await p.run('forceNext = true; run()');
  assert.match(p.views.innerHTML, /Existing lane data/);
  assert.equal(p.run('dataAt'), 1000);
  assert.equal((p.views.innerHTML.match(/data-read-error/g) || []).length, 1);
  p.ctx.loadRegistry = async () => {};
  await p.run('forceNext = true; run()');
  assert.ok(!p.views.innerHTML.includes('data-read-error'));
});

test('repeated Settings failures keep one banner; a warm Settings entry renders once', async () => {
  const p = routedPage();
  await p.navigate('settings');
  for (let i = 0; i < 3; i++) await p.run('forceNext = true; run()');
  assert.equal((p.views.innerHTML.match(/Registry unavailable/g) || []).length, 1);
  p.run('registry.mainnet = {chains: {}, tokens: {}};');
  await p.navigate('ledger');
  let renders = 0;
  p.ctx.viewSettings = () => { renders++; p.views.innerHTML = 'Settings'; };
  await p.navigate('settings');
  assert.equal(renders, 1);
});

test('Live revisit shares phase-one reads; changed endpoint and row inputs remain distinct', async () => {
  const p = routedPage(), pending = deferred();
  p.run('registry.mainnet = {chains: {}, tokens: {}}; overviewRows = () => []; renderOverview = () => { views.innerHTML = "Live"; };');
  let batches = 0;
  p.ctx.rpcRead = async (_url, calls) => { batches++; await pending.promise; return calls.map(() => null); };
  const first = p.navigate('overview');
  await new Promise(setImmediate);
  await p.navigate('ledger');
  const second = p.navigate('overview');
  const refresh = p.run('forceNext = true; run()');
  await new Promise(setImmediate);
  assert.equal(batches, 3, 'one L1 batch and two feed quote reads');
  p.run('state.rpc[1] = "https://other.example"');
  const changed = p.run('overviewL1([], true)');
  await new Promise(setImmediate);
  assert.equal(batches, 6);
  const rowsChanged = p.run('overviewL1([{key: "new", escrow: L1_WSTETH}], true)');
  await new Promise(setImmediate);
  assert.equal(batches, 7, 'new row inputs need their own L1 read, while matching quotes remain shared');
  pending.resolve();
  await Promise.all([first, second, refresh, changed, rowsChanged]);
  assert.equal(p.run('overviewReads.size'), 0);
});

test('ledger delegated interactions preserve filters on relationship navigation and clear explicitly', async () => {
  const p = routedPage();
  assert.equal(p.run('ledgerEntries'), null);
  // DOM fixture supplies browser node operations; actual registered handlers run unchanged.
  const input = {id: 'ledger-search', value: '', closest: () => null, focus() { this.focused = true; }};
  const network = {id: 'ledger-network', value: ''};
  Object.assign(p.elements, {'ledger-search': input, 'ledger-network': network, 'ledger-count': {}, 'ledger-empty': {}});
  const rows = [];
  const originalQuery = p.views.querySelector;
  p.views.querySelectorAll = selector => selector === '[data-ledger-entry]' ? rows : [];
  p.views.querySelector = selector => rows.find(row => selector === `[data-ledger-entry="${row.dataset.ledgerEntry}"]`) || originalQuery(selector);
  await p.navigate('ledger');
  const entries = p.run('ledgerEntries');
  for (let i = 0; i < entries.length; i++) {
    const detail = {dataset: {}, innerHTML: ''};
    const summary = {focus() { this.focused = true; }};
    rows.push({dataset: {ledgerEntry: String(i)}, hidden: false, open: false,
      matches: selector => selector === '[data-ledger-entry]',
      querySelector: selector => selector === '.ledger-detail' ? detail : summary,
      scrollIntoView() { this.scrolled = true; }});
  }
  input.value = 'no-match-for-this-query';
  p.emit('views', 'input', input);
  network.value = 'eip155:1';
  p.emit('views', 'change', network);
  assert.ok(rows.every(row => row.hidden));
  const proxyIndex = entries.findIndex(({entry}) => entry.proxy?.implementationDeploymentId);
  const proxyRow = rows[proxyIndex]; proxyRow.open = true;
  p.emit('views', 'toggle', proxyRow);
  const detail = proxyRow.querySelector('.ledger-detail');
  assert.equal(detail.dataset.loaded, 'true');
  const targetIndex = Number(detail.innerHTML.match(/data-ledger-target="(\d+)"/)[1]);
  await p.emit('views', 'click', {closest: selector => selector === '[data-ledger-target]' ? {dataset: {ledgerTarget: String(targetIndex)}} : null});
  assert.equal(input.value, 'no-match-for-this-query');
  assert.equal(network.value, 'eip155:1');
  assert.equal(rows[targetIndex].hidden, false);
  assert.equal(rows[targetIndex].open, true);
  assert.equal(rows[targetIndex].querySelector('summary').focused, true);
  assert.equal(rows[targetIndex].scrolled, true);
  assert.match(p.elements['ledger-count'].textContent, /0 of .* \+ 1 linked deployment outside filters/);
  assert.equal(p.elements['ledger-empty'].hidden, true);
  p.emit('views', 'input', input);
  assert.ok(rows.every(row => row.hidden), 'editing filters removes the relationship exception');
  await p.emit('views', 'click', {closest: selector => selector === '[data-ledger-target]' ? {dataset: {ledgerTarget: '-1'}} : null});
  await p.emit('views', 'click', {id: 'ledger-clear', closest: () => null});
  assert.equal(input.value, ''); assert.equal(network.value, '');
  assert.equal(p.run('ledgerQuery + ledgerNetwork'), '');
  assert.ok(rows.every(row => !row.hidden));
  assert.equal(input.focused, true);
});

test('price refresh joins a pending read and cache clear isolates old completions', async () => {
  const p = routedPage(), oldRead = deferred(), newRead = deferred();
  let calls = 0;
  p.ctx.rpcRead = async () => {
    await (++calls === 1 ? oldRead.promise : newRead.promise);
    return ['0x1', abi(18), round(2n * 10n ** 14n), abi(8), round(2500n * 10n ** 8n)];
  };
  const first = p.run('ldoPrice(false)'), refresh = p.run('ldoPrice(true)');
  await new Promise(setImmediate);
  assert.equal(calls, 1);
  p.run('clearCache()');
  const next = p.run('ldoPrice(true)');
  await new Promise(setImmediate);
  assert.equal(calls, 2);
  oldRead.resolve();
  await Promise.all([first, refresh]);
  assert.equal(p.run('priceReads.size'), 1, 'old completion cannot remove the new pending read');
  assert.equal(p.run('metaCache.size'), 0, 'old completion cannot repopulate the cache');
  newRead.resolve();
  await next;
  assert.equal(p.run('priceReads.size'), 0);
  assert.equal(p.run('metaCache.size'), 1);
});

test('overview reads retain the endpoint and hub used by their sharing key', async () => {
  const p = page();
  p.run(`registry.mainnet = {tokens: {wstETH: {1: {poolAddress: '${address(22)}'}}}};
    state.rpc[1] = 'https://first.example';`);
  let observedUrl;
  p.ctx.rpcRead = async (url, calls) => {
    if (calls[0].method === 'eth_call') observedUrl = url;
    return calls.map(() => null);
  };
  const read = p.run('overviewL1([], true)');
  p.run(`registry.mainnet.tokens.wstETH[1].poolAddress = '${address(33)}'; state.rpc[1] = 'https://second.example';`);
  const result = await read;
  assert.equal(observedUrl, 'https://first.example');
  assert.equal(result.pool.addr, address(22));
});

test('overview cache follows hub and row inputs even when the RPC stays the same', async () => {
  const p = page();
  p.ctx.rows = [{key: 'spoke', escrow: address(44), group: 'ccip', selector: '100'}];
  p.run(`registry.mainnet = {tokens: {wstETH: {1: {poolAddress: '${address(22)}'}}}};`);
  let reads = 0;
  p.ctx.rpcRead = async (_url, calls) => {
    if (calls[0].method !== 'eth_call') return [];
    reads++;
    return [...calls.slice(0, -3).map(() => abi(reads)), '0x1', abi(18), abi(100)];
  };
  assert.equal((await p.run('overviewL1(rows, false)')).pool.held, 1n);
  await p.run('overviewL1(rows, false)');
  assert.equal(reads, 1, 'identical inputs reuse completed observations');
  p.run(`registry.mainnet.tokens.wstETH[1].poolAddress = '${address(33)}';`);
  const changedHub = await p.run('overviewL1(rows, false)');
  assert.equal(changedHub.pool.addr, address(33));
  assert.equal(changedHub.pool.held, 2n, 'new pool must not inherit old pool balances');
  p.ctx.rows = [{...p.ctx.rows[0], escrow: address(55), selector: '200'}];
  assert.equal((await p.run('overviewL1(rows, false)')).escrow.spoke, 3n);
  p.run('delete metaCache.get(OV_KEY).inputs;');
  await p.run('overviewL1(rows, false)');
  assert.equal(reads, 4, 'older caches without input provenance are read again');
});

test('Refresh bypasses cached overview balances while an expired quote is pending', async () => {
  const p = page(), quote = deferred();
  let batches = 0, holdQuote = false;
  p.ctx.rpcRead = async (_url, calls) => {
    if (calls[0].method !== "eth_call") {
      if (holdQuote) await quote.promise;
      return [];
    }
    batches++;
    return [...calls.slice(0, -3).map(() => abi(batches)), '0x1', abi(18), abi(100)];
  };
  await p.run('overviewL1([], false)');
  holdQuote = true;
  const cached = p.run('overviewL1([], false)');
  await new Promise(setImmediate);
  const fresh = p.run('overviewL1([], true)');
  await new Promise(setImmediate);
  assert.equal(batches, 2, 'Refresh must start a new balance batch');
  quote.resolve(null);
  assert.equal((await cached).supply, 1n);
  assert.equal((await fresh).supply, 2n);
});

test('Refresh recrawls structure while a cached structure is awaiting its live probe', async () => {
  const p = page(), probe = deferred();
  p.run(`registry.testnet = {chains: {}, tokens: {}}; buildChecks = () => [];
    structCache.set('testnet|2|3', {url: rpcFor(2), ms: 0, at: 1,
      rows: [{type: 'Router'}], ramps: [], nocode: []});`);
  let structures = 0;
  p.ctx.crawlStructure = async () => { structures++; return {ms: 0, at: 2, rows: [{type: 'Router'}], ramps: [], nocode: []}; };
  let probes = 0;
  p.ctx.probeLive = () => ++probes === 1 ? probe.promise : Promise.resolve({ms: 0});
  const cached = p.run('crawl("testnet", 2, 3, false)');
  await new Promise(setImmediate);
  const fresh = p.run('crawl("testnet", 2, 3, true)');
  await new Promise(setImmediate);
  assert.equal(structures, 1);
  assert.equal((await fresh).structAt, 2);
  probe.resolve({ms: 0});
  assert.equal((await cached).structAt, 1);
  assert.equal(p.run('structCache.get("testnet|2|3").at'), 2, 'late cached probes cannot replace refreshed structure');
});

test('a read finishing between hash changes cannot leave its loading flag stuck', async () => {
  const p = routedPage(), pending = deferred();
  p.ctx.loadRegistry = () => pending.promise;
  p.ctx.crawl = async () => ({checks: [], liveAt: 1000});
  p.run('laneSummary = () => "Dev loaded"; sidePanel = () => "";');
  const first = p.navigate('lane-2-3');
  p.ctx.location.hash = '#overview'; // hashchange task has not run yet
  pending.resolve();
  await first;
  assert.equal(p.run('busy'), false);
  p.ctx.location.hash = '#lane-2-3';
  await p.run('run()');
  assert.match(p.views.innerHTML, /Dev loaded/);
  assert.equal(p.elements.refresh.disabled, false);
});

test('ledger parsing is lazy and a connected ledger is not reattached', () => {
  const p = page();
  assert.equal(p.run('LEDGER'), null);
  p.run('indexLedger()');
  assert.equal(p.run('LEDGER.deployments.length'), build.ledger.deployments.length);
  p.run('ledgerNodes = [{isConnected: true}];');
  p.views.replaceChildren = () => { throw Error('would detach the focused input'); };
  p.run('viewLedger()');
});
