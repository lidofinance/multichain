#!/usr/bin/env node
// Bakes RPC observations into an already-built dashboard. Run just dashboard-build first.
//
// The page reads everything it shows from Chainlink's registry API and from a public RPC per
// chain. Published to an artifact host those requests are blocked by CSP, so the page renders its
// shell and nothing else. This script fills the #snapshot block with the caches the page would
// have filled itself, by running the page's OWN code — sections 1 to 7 of its script are lifted
// out verbatim and evaluated here — so there is no second implementation of the crawl to drift.
//
//   node scripts/build-lane-watch-snapshot.mjs                       # write index.snapshot.json
//   node scripts/build-lane-watch-snapshot.mjs --inline out.html     # + a self-contained copy
//
// The snapshot is dated the moment it is taken, and every figure inside it keeps the timestamp of
// the read that produced it: the page's header stamp reports that age rather than passing the
// numbers off as current.

import { readFileSync, writeFileSync } from "node:fs";
import vm from "node:vm";
import path from "node:path";

const ROOT = path.resolve(import.meta.dirname, "..");
const siteArg = process.argv.indexOf("--site");
if (siteArg !== -1 && !process.argv[siteArg + 1]) throw new Error("--site requires a directory");
const SITE = siteArg === -1 ? path.join(ROOT, "temp/dashboard-site") : path.resolve(process.argv[siteArg + 1]);
const PAGE = path.join(SITE, "index.html");
const OUT = path.join(SITE, "index.snapshot.json");

const html = readFileSync(PAGE, "utf8");
const buildData = html.match(/<script type="application\/json" id="dashboard-data">([\s\S]*?)<\/script>/)?.[1];
if (!buildData || !JSON.parse(buildData).identity) throw new Error("Missing build data; run just dashboard-build first");

// ── lift the page's own script, sections 1..7 ────────────────────────────────
const start = html.indexOf('<script>\n"use strict";');
if (start < 0) throw new Error("script opening marker not found — has the page been restructured?");
const body = html.slice(start + "<script>\n".length);
const cut = body.indexOf("// 8. Refresh cycle and events");
if (cut < 0) throw new Error("section 8 marker not found — has the page been restructured?");
// back up over the rule line that opens the section comment
const rule = body.lastIndexOf("\n", cut - 2) + 1;
if (!body.slice(rule, cut).trim().startsWith("// ─"))
  throw new Error("section 8 rule marker not found — has the page been restructured?");
const src = body.slice(0, rule);

// ── the shims the lifted code needs ─────────────────────────────────────────
// It touches localStorage at load time and the DOM only through element handles it never reads
// back, so a Map and a stub are enough. Nothing here fakes a network: fetch is the real one.
const store = new Map();
const localStorage = {
  getItem: (k) => (store.has(k) ? store.get(k) : null),
  setItem: (k, v) => store.set(k, String(v)),
  removeItem: (k) => store.delete(k),
};
const stubEl = new Proxy({}, {
  get: (t, p) => (p === "textContent" || p === "value" ? "" : p in t ? t[p] : () => stubEl),
  set: () => true,
});
const document = {
  getElementById: (id) => id === "dashboard-data" ? { textContent: buildData } : stubEl,
  querySelector: () => null,
  querySelectorAll: () => [],
  addEventListener: () => {},
  createElement: () => stubEl,
};

const ctx = vm.createContext({
  fetch, console, setTimeout, clearTimeout, setInterval: () => 0, clearInterval: () => {},
  localStorage, document, navigator: { onLine: true }, performance,
  location: { hash: "", replace: () => {} },
  window: { addEventListener: () => {} },
  URL, TextDecoder, JSON, Math, Date, BigInt, Promise, Object, Array, Number, String, Set, Map,
});
ctx.globalThis = ctx;
ctx.window.addEventListener = () => {};

vm.runInContext(`${src}\nglobalThis.__page = { loadRegistry, crawl, overviewRows, overviewL1, overviewSupply, LIVE, state, BUILD, CACHE_KEY };`,
  ctx, { filename: "index.html#script" });

const P = ctx.__page;
const say = (...a) => console.error("·", ...a);

// ── drive every tab the page can open, so each one has something to render ───
async function main() {
  say("registry: testnet");
  await P.loadRegistry("testnet", true);
  say("registry: mainnet");
  await P.loadRegistry("mainnet", true);

  const [a, b] = P.LIVE.lane;
  for (const [x, y] of [[a, b], [b, a]]) {
    say(`crawl ${x} -> ${y}`);
    try { await P.crawl(P.LIVE.env, x, y, true); } catch (e) { say("  failed:", e.message); }
  }
  for (const [x, y] of P.state.lanes.mainnet || []) {
    say(`crawl ${x} -> ${y} (mainnet)`);
    try { await P.crawl("mainnet", x, y, true); } catch (e) { say("  failed:", e.message); }
  }

  say("overview: L1");
  const rows = P.overviewRows();
  try { await P.overviewL1(rows, true); } catch (e) { say("  failed:", e.message); }
  // One chain at a time: these are 25 different public endpoints and a burst gets throttled.
  for (const r of rows) {
    const res = await P.overviewSupply(r, true).catch((e) => ({ err: e.message }));
    say(`overview: ${r.name}${res.err ? ` — ${res.err}` : ""}`);
  }

  const snapshot = {
    at: Date.now(),
    record: P.LIVE.record,
    identity: P.BUILD.identity,
    registry: JSON.parse(store.get("ccip-lane-watch/registry/v1") || "{}"),
    cache: JSON.parse(store.get(P.CACHE_KEY) || "{}"),
  };
  const n = (o) => Object.keys(o || {}).length;
  say(`snapshot: ${n(snapshot.registry)} registries, ${n(snapshot.cache.struct)} crawls, ${n(snapshot.cache.meta)} reads`);
  writeFileSync(OUT, JSON.stringify(snapshot));
  say(`wrote ${path.relative(ROOT, OUT)} (${(readFileSync(OUT).length / 1e6).toFixed(2)} MB)`);

  const i = process.argv.indexOf("--inline");
  if (i > -1 && process.argv[i + 1]) {
    const tag = '<script type="application/json" id="snapshot"></script>';
    if (!html.includes(tag)) throw new Error("snapshot placeholder not found in the page");
    // </script> inside the payload would close the block early; nothing else needs escaping.
    const payload = JSON.stringify(snapshot).replaceAll("</", "<\\/");
    const out = path.resolve(process.argv[i + 1]);
    writeFileSync(out, html.replace(tag, tag.replace("></", `>${payload}</`)));
    say(`wrote ${out}`);
  }
}
main().catch((e) => { console.error(e); process.exit(1); });
