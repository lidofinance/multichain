// Exercise the dashboard's actual functions without registry or RPC network access.
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import vm from 'node:vm';
import test from 'node:test';

const html = readFileSync(new URL('../docs/index.html', import.meta.url), 'utf8');
const script = html.split('<script>\n')[1].split('</script>')[0];
const source = script.slice(0, script.indexOf('// 8. Refresh cycle and events'));
const address = n => '0x' + n.toString(16).padStart(40, '0');
const build = { identity: 'test', networks: [], provenance: {}, l1Token: address(1),
  live: { lane: [2, 3], env: 'testnet', tokens: {}, seeds: {} } };
function page() {
  const store = new Map();
  const views = { innerHTML: '' };
  const ctx = vm.createContext({ console, performance, setTimeout, clearTimeout,
    location: { hash: '#token' },
    fetch: async () => { throw Error('Unexpected network'); },
    localStorage: { getItem: k => store.get(k) ?? null,
      setItem: (k, v) => store.set(k, v), removeItem: k => store.delete(k) },
    document: { getElementById: id => id === 'dashboard-data'
      ? { textContent: JSON.stringify(build) } : id === 'views' ? views : {},
      querySelector: () => null, querySelectorAll: () => [] } });
  vm.runInContext(source, ctx);
  return { ctx, store, views, run: s => vm.runInContext(s, ctx) };
}

test('same-chain escrow rows retain distinct balances through cache and rendering', async () => {
  const p = page();
  p.ctx.rows = [10, 20].map(n => ({ chainId: '5000', token: address(n),
    escrow: address(n + 1), group: 'supported', key: `5000:${address(n)}` }));
  p.run('rpc = async () => [1n, 2n, 3n, 10n, 20n].map(n => "0x" + n.toString(16).padStart(64, "0"))');
  await p.run('overviewL1(rows, true).then(result => { ov.l1 = result; })');
  assert.equal(p.run('ovBacking(rows[0]).v'), 10n);
  assert.equal(p.run('ovBacking(rows[1]).v'), 20n);
  p.run('rpc = async () => { throw Error("Cache should answer"); }');
  await p.run('overviewL1(rows, false).then(result => { ov.l1 = result; })');
  assert.equal(p.run('ovBacking(rows[1]).v'), 20n);
});

test('silo observations remain addressable by row identity', async () => {
  const p = page();
  p.ctx.pool = address(99);
  p.ctx.rows = [10, 20].map(n => ({ chainId: String(n), token: address(n),
    selector: String(n), group: 'ccip', key: `${n}:${address(n)}` }));
  p.run('registry.mainnet = { tokens: { wstETH: { "1": { poolAddress: pool } } } }; rpc = async () => [1,2,3,30,0,1,10,1,20].map(n => "0x" + n.toString(16).padStart(64, "0"))');
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
      const result = spawnSync(process.execPath, ['scripts/build-lane-watch-snapshot.mjs', '--site', dir], { encoding: 'utf8' });
      assert.notEqual(result.status, 0);
      assert.ok(result.stderr.includes(expected), result.stderr);
    }
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
