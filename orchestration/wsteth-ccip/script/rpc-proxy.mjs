// Resilient localhost JSON-RPC pass-through proxy (dependency-free: Node built-ins only).
//
// Purpose: insulate long, non-resumable deploys (core's hardhat scratch deploy) from an upstream
// endpoint that closes idle keep-alive connections during multi-second receipt polls on heavy txs
// (observed: `SocketError: other side closed` while waiting for ENSFactory.newENS to mine). hardhat
// talks to a stable localhost socket here; this proxy forwards to the upstream with a FRESH
// connection per request (agent:false → no keep-alive to poison) and RETRIES transport failures
// with backoff.
//
// Retry safety: the dominant failure is during receipt POLLING (eth_getTransactionReceipt — a read),
// which is idempotent. eth_sendRawTransaction is also safe to retry on a pre-response transport
// error: the nonce makes a double-submit a no-op ("already known"/"nonce too low"), never a double
// execution. We retry only on transport errors (no HTTP response), never on a 200 + JSON-RPC error.
//
// Usage: UPSTREAM=<url> PORT=8546 node script/rpc-proxy.mjs
import http from "node:http";
import https from "node:https";
import { URL } from "node:url";

const UPSTREAM = process.env.UPSTREAM;
const PORT = Number(process.env.PORT || 8546);
const MAX_RETRIES = Number(process.env.MAX_RETRIES || 12);
if (!UPSTREAM) {
  console.error("rpc-proxy: set UPSTREAM=<url>");
  process.exit(1);
}
const u = new URL(UPSTREAM);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// STICKY upstream connection: a single keep-alive socket funnels every request to the SAME LB
// backend, so a contract deployed in one tx is visible to the immediately-following preflight
// (eth_call/estimateGas/getCode). A fresh connection per request would round-robin drpc's backends,
// which lag on recent state → "ERC1967: new implementation is not a contract" / estimateGas
// under-estimates. maxSockets:1 also serializes, keeping the backend consistent across the deploy
// sequence. If the idle socket is dropped (during receipt polls), the next request errors and the
// retry loop reconnects (a new backend, but reads only need correct block height, which is consistent).
const keepAliveAgent = new https.Agent({ keepAlive: true, maxSockets: 1, maxFreeSockets: 1, keepAliveMsecs: 30_000, timeout: 600_000 });

function forwardOnce(body) {
  return new Promise((resolve, reject) => {
    const req = https.request(
      {
        protocol: u.protocol,
        hostname: u.hostname,
        port: u.port || 443,
        path: u.pathname + u.search,
        method: "POST",
        headers: { "content-type": "application/json", "content-length": Buffer.byteLength(body) },
        agent: keepAliveAgent, // sticky backend via a persistent connection
        timeout: 600_000,
      },
      (r) => {
        const parts = [];
        r.on("data", (c) => parts.push(c));
        r.on("end", () => resolve({ status: r.statusCode, text: Buffer.concat(parts).toString() }));
        // A drop MID-BODY surfaces only on the response stream ('error'/'aborted'), never on req —
        // without these the promise never settles and the deploy hangs instead of retrying.
        r.on("error", reject);
        r.on("aborted", () => reject(new Error("upstream connection dropped mid-response")));
      },
    );
    req.on("error", reject);
    req.on("timeout", () => req.destroy(new Error("upstream timeout")));
    req.end(body);
  });
}

// A request is safe to retry on a transport error only if NONE of its JSON-RPC calls submit a
// transaction. Retrying a send after a mid-flight drop can make the client record a "success" that
// didn't actually persist on-chain state (observed: deployLidoAPM "succeeds" but the template's
// registry is unset → createRepos reverts TMPL_REGISTRY_NOT_DEPLOYED). Reads (receipt polling,
// eth_call, estimateGas, getCode, getLogs…) — where the drops actually happen — stay retryable.
const NON_RETRYABLE = new Set(["eth_sendRawTransaction", "eth_sendTransaction"]);
// Parse the JSON-RPC call(s) once per request; null = unparseable (→ don't retry).
function parseCalls(body) {
  try {
    const j = JSON.parse(body.toString());
    return Array.isArray(j) ? j : [j];
  } catch {
    return null;
  }
}

// drpc's LB backends are eventually-consistent: right after a state-changing tx, a preflight
// eth_estimateGas/eth_call routed to a lagging backend can revert ("execution reverted" /
// "is not a contract") even though the canonical chain is fine — especially right after an idle
// reconnect bounces us to a fresh backend. Such a lag-revert clears once that backend syncs (sub-
// second). A GENUINE revert keeps reverting, so after a few short retries we return it unchanged.
// Bounded + only for these read preflights → genuine reverts cost a few hundred ms, never masked.
const LAG_RETRY_METHODS = new Set(["eth_estimateGas", "eth_call"]);
// Lag windows have been observed to outlast a flat 6×400ms budget (a backend stale for seconds,
// e.g. VEBO.resume() estimating "missing role" AFTER grantRole confirmed). Budget: 12 retries with
// growing backoff, and every 3rd retry DROP the sticky socket — the reconnect re-routes through
// drpc's LB, usually landing on a synced backend instead of waiting out the stale one.
const LAG_MAX = 12;
const lagBackoff = (n) => Math.min(400 * 1.5 ** (n - 1), 3000);
function lagPause(methods, lagRetries, why) {
  if (lagRetries % 3 === 0) {
    keepAliveAgent.destroy(); // force a fresh upstream connection → likely a different LB backend
    console.error(`rpc-proxy: [${methods}] ${why}, retry ${lagRetries}/${LAG_MAX} — dropping sticky socket to hop backend`);
  } else {
    console.error(`rpc-proxy: [${methods}] ${why}, retry ${lagRetries}/${LAG_MAX} in ${Math.round(lagBackoff(lagRetries))}ms`);
  }
  return sleep(lagBackoff(lagRetries));
}
function lagRevert(calls, text) {
  try {
    if (!calls || !LAG_RETRY_METHODS.has(calls[0] && calls[0].method)) return false;
    if (!text.includes('"error"')) return false; // cheap gate before parsing the full response
    const resp = JSON.parse(text);
    const err = (Array.isArray(resp) ? resp[0] : resp).error;
    if (!err) return false;
    const msg = (err.message || "").toLowerCase();
    return msg.includes("revert") || msg.includes("is not a contract") || msg.includes("no contract code");
  } catch {
    return false;
  }
}

// A lagging backend can also answer eth_estimateGas SUCCESSFULLY with a near-intrinsic value: it
// hasn't seen the just-deployed contract at `to`, so the call "does nothing" and estimates ~21k +
// calldata (observed: 22414/23707 on VaultHub.initialize right after its proxy deploy → on-chain
// OutOfGas at the real contract). Estimates that low for a tx CARRYING CALLDATA are suspect: give
// the backend the same lag-retry budget; if it still answers low, floor the result — an oversized
// gas LIMIT is free (only gasUsed is charged), an undersized one bricks a non-resumable deploy tx.
// Legit small calls (approve/transfer) get floored too, which is harmless for a deploy pipeline.
const LOW_EST = 60_000;
const EST_FLOOR = Number(process.env.EST_FLOOR || 10_000_000);
// Low estimates get a SMALL retry budget, not the full LAG_MAX: flooring to EST_FLOOR is safe
// whatever the true value (an oversized gas LIMIT is free; only gasUsed is charged), so retrying
// past a hop or two buys nothing but latency. A few retries still let a quick backend-hop surface
// the real (higher) estimate; after that we floor. Legit sub-60k calls (approve/grantRole ~46k)
// thus pay ~1-2 hops, not ~26s of the lag budget.
const LOW_EST_MAX = Number(process.env.LOW_EST_MAX || 3);
function lowEstimate(calls, text) {
  try {
    if (!calls || calls.length !== 1 || (calls[0] && calls[0].method) !== "eth_estimateGas") return null;
    const p = (calls[0].params && calls[0].params[0]) || {};
    const data = p.data || p.input || "0x";
    if (!p.to || typeof data !== "string" || data.length <= 2) return null; // creations / plain transfers: leave alone
    const resp = JSON.parse(text);
    const one = Array.isArray(resp) ? resp[0] : resp;
    if (!one || one.error || one.result == null) return null;
    return parseInt(one.result, 16) < LOW_EST ? one : null;
  } catch {
    return null;
  }
}

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", async () => {
    const body = Buffer.concat(chunks);
    const calls = parseCalls(body);
    const retryable = calls != null && !calls.some((c) => NON_RETRYABLE.has(c && c.method));
    const methods = calls ? calls.map((c) => c && c.method).join(",") : "?";
    const maxAttempts = retryable ? MAX_RETRIES : 1;
    let lastErr;
    let lagRetries = 0;
    let lowRetries = 0;
    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        const { status, text } = await forwardOnce(body);
        // Lag-revert on a read preflight → give the (sticky) backend a moment to sync, then retry.
        if (retryable && lagRetries < LAG_MAX && lagRevert(calls, text)) {
          lagRetries++;
          await lagPause(methods, lagRetries, "lag-revert");
          attempt--; // a lag retry doesn't consume the transport-retry budget
          continue;
        }
        // Suspiciously low estimate for a calldata-carrying tx: retry like a lag-revert; if the
        // backend still answers low after the budget, floor the result rather than pass it through.
        const low = lowEstimate(calls, text);
        if (low) {
          if (lowRetries < LOW_EST_MAX) {
            lowRetries++;
            await lagPause(methods, lowRetries, `low estimate ${low.result}`);
            attempt--;
            continue;
          }
          console.error(`rpc-proxy: [${methods}] still low after ${LOW_EST_MAX} retries — flooring estimate to ${EST_FLOOR}`);
          low.result = "0x" + EST_FLOOR.toString(16);
          res.writeHead(status, { "content-type": "application/json" });
          res.end(JSON.stringify(low));
          return;
        }
        res.writeHead(status, { "content-type": "application/json" });
        res.end(text);
        return;
      } catch (e) {
        lastErr = e;
        if (!retryable) break;
        const backoff = Math.min(250 * 2 ** attempt, 3000);
        console.error(`rpc-proxy: [${methods}] attempt ${attempt + 1} failed (${e.code || e.message}); retry in ${backoff}ms`);
        await sleep(backoff);
      }
    }
    if (!retryable && lastErr) console.error(`rpc-proxy: NON-RETRYABLE [${methods}] failed (${lastErr.code || lastErr.message}) — not retried (send safety)`);
    console.error(`rpc-proxy: giving up after ${MAX_RETRIES}: ${lastErr}`);
    res.writeHead(502, { "content-type": "application/json" });
    res.end(JSON.stringify({ jsonrpc: "2.0", id: null, error: { code: -32000, message: `proxy upstream failed: ${lastErr}` } }));
  });
});

server.keepAliveTimeout = 120_000;
server.headersTimeout = 125_000;
server.requestTimeout = 600_000;
server.listen(PORT, "127.0.0.1", () => console.error(`rpc-proxy: http://127.0.0.1:${PORT} -> ${UPSTREAM.replace(/\/[^/]+$/, "/<key>")}`));
