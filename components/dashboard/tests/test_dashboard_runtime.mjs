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
const source = script.slice(0, script.indexOf('// 8. Refresh cycle and events'));
const address = n => '0x' + n.toString(16).padStart(40, '0');
const ldoMetadata = JSON.parse(readFileSync(new URL('../config/ldo-networks.json', import.meta.url), 'utf8'));
const stethMetadata = JSON.parse(readFileSync(new URL('../config/steth-networks.json', import.meta.url), 'utf8'));
const build = { identity: 'test', networks: [], provenance: {}, l1Token: address(1),
  ldo: ldoMetadata,
  steth: { priceFeed: stethMetadata.priceFeed, networks: [{ chainId: 10, name: 'Optimism',
    token: address(10), oracle: address(11), decimals: 18, rateDecimals: 27 }] },
  live: { lane: [2, 3], env: 'testnet', tokens: {}, seeds: {} } };
function page() {
  const store = new Map();
  const views = { innerHTML: '' };
  const ctx = vm.createContext({ console, performance, setTimeout, clearTimeout, URL, tickStamp: () => {},
    location: { hash: '#token' },
    fetch: async () => { throw Error('Unexpected network'); },
    localStorage: { getItem: k => store.get(k) ?? null,
      setItem: (k, v) => store.set(k, v), removeItem: k => store.delete(k) },
    document: { getElementById: id => id === 'dashboard-data'
      ? { textContent: JSON.stringify(build) } : id === 'views' ? views : {},
      querySelector: () => null, querySelectorAll: () => [] } });
  vm.runInContext(source, ctx);
  vm.runInContext('renderTabs = () => {};', ctx);
  return { ctx, store, views, run: s => vm.runInContext(s, ctx) };
}

test('same-chain escrow rows retain distinct balances through cache and rendering', async () => {
  const p = page();
  p.ctx.rows = [10, 20].map(n => ({ chainId: '5000', token: address(n),
    escrow: address(n + 1), group: 'supported', key: `5000:${address(n)}` }));
  p.run('rpcRead = async () => [1n, 2n, 10n, 20n].map(n => "0x" + n.toString(16).padStart(64, "0"))');
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
  await p.run('viewOverview(false)');
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

test('registry failure prevents a green overview even when all token observations pass', () => {
  const p = page(), now = Math.floor(Date.now() / 1000);
  p.ctx.now = now;
  p.run(`registry.mainnet = {chains: {}, tokens: {}};
    ov.rows = []; ov.l1 = {err: null}; ldo.rows = []; steth.rows = [];
    ldo.quote = {rounds: LDO.priceFeeds.map(() => ({updatedAt: now * 1000}))};
    steth.quote = {rounds: [{updatedAt: now * 1000}]};
    ovUpdateStatus();`);
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
      if (data === '0x313ce567') return abi(to.toLowerCase() === ldoMetadata.priceFeeds[0].address.toLowerCase() ? 18 : 8);
      if (data === '0xfeaf968c') return round(to.toLowerCase() === ldoMetadata.priceFeeds[0].address.toLowerCase() ? 2n * 10n ** 14n : 2500n * 10n ** 8n);
      if (data === '0x035faf82') return abi(12n * 10n ** 17n);
      return abi(10n ** 18n);
    });
  };
  p.ctx.result = await p.run('overviewL1([], true)');
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
