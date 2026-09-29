// SPDX-License-Identifier: GPL-3.0-only
// fredpd_mdt HTTP route for the portal (docs/modules/portal-api.md; FiveM server JS runtime, CommonJS script).
//
//   POST http://127.0.0.1:30120/fredpd_mdt/portal   HMAC-signed by fredpd_service (docs/contracts.md §C5)
//   body { requestId, discordId, citizenid, grants, action, input }  or  { requestId, action: 'viewShare', input }
//   200 { ok: true, data } | { ok: false, error, reason? }   (the action's answer, server/portal.lua)
//   400 bad_json / invalid_body, 401 unauthorized, 404 not_found, 405, 409 duplicate, 413, 503 bridge_disabled,
//   504 timeout
//
// Why a handler of its own: SetHttpHandler routes are per resource (/<resource>/<path>), so fredpd_core's handler
// cannot answer /fredpd_mdt/*; and the portal work (MySQL awaits in the routed exports) must run in a Lua thread of
// this resource, which the export portalRequest(body, cb) starts, answering through cb. The HMAC helpers are a copy of
// fredpd_core/server/http.js (itself a copy of packages/types/src/hmac.ts; requiring that file here would run its
// FiveM wiring a second time). ../test/http.test.ts checks them against packages/types/test/fixtures/hmac.fixtures.json.
//
// Replay: §C5 signs ts + body, so a captured request stays valid for 60 s. Every portal body carries a random
// requestId; one already seen within 2 x the skew window is refused (409), so a write cannot be replayed.
'use strict';

const nodeCrypto = require('crypto');

const PORTAL_PATH = '/portal';
// A report body is up to 100 000 code points (<= 400 KB of UTF-8) plus JSON overhead.
const MAX_BODY_BYTES = 512 * 1024;
const MAX_SKEW_SECONDS = 60;
const MIN_SECRET_LENGTH = 32;
const LUA_TIMEOUT_MS = 15000;
const MAX_REMEMBERED = 20000;
const TS_HEADER = 'x-fredpd-ts';
const SIG_HEADER = 'x-fredpd-sig';
const REQUEST_ID_RE = /^[0-9a-f]{32}$/;
const PLACEHOLDER_SECRET_RE = /change[_\s-]?me|placeholder|your[_\s-]?secret|^(.)\1+$/i;
const REJECT_LOG_INTERVAL_S = 10;

// ---------------------------------------------------------------------------------------------------------------
// HMAC (§C5), same semantics as packages/types/src/hmac.ts and fredpd_core/server/http.js

function signBody(secret, ts, rawBody) {
  return nodeCrypto.createHmac('sha256', secret).update(`${ts}.${rawBody}`, 'utf8').digest('hex');
}

/** @returns {{ ok: true } | { ok: false, reason: 'missing' | 'skew' | 'signature' }} */
function verifySignature({ secret, ts, sig, rawBody, nowSeconds, maxSkewSeconds }) {
  if (!ts || !sig || !/^\d{1,12}$/.test(ts) || !/^[0-9a-f]{64}$/i.test(sig)) return { ok: false, reason: 'missing' };
  const now = nowSeconds ?? Math.floor(Date.now() / 1000);
  if (Math.abs(now - Number(ts)) > (maxSkewSeconds ?? MAX_SKEW_SECONDS)) return { ok: false, reason: 'skew' };
  const expected = Buffer.from(signBody(secret, ts, rawBody), 'hex');
  const given = Buffer.from(sig.toLowerCase(), 'hex');
  if (given.length !== expected.length || !nodeCrypto.timingSafeEqual(given, expected)) {
    return { ok: false, reason: 'signature' };
  }
  return { ok: true };
}

function secretProblem(secret) {
  if (typeof secret !== 'string' || secret.length === 0) return 'convar fredpd_hmac_secret is not set';
  if (secret.length < MIN_SECRET_LENGTH) return `convar fredpd_hmac_secret is shorter than ${MIN_SECRET_LENGTH} characters`;
  if (PLACEHOLDER_SECRET_RE.test(secret)) return 'convar fredpd_hmac_secret is still a placeholder value';
  return null;
}

function lowerHeaders(headers) {
  const out = {};
  if (!headers || typeof headers !== 'object') return out;
  for (const [k, v] of Object.entries(headers)) out[String(k).toLowerCase()] = Array.isArray(v) ? v.join(',') : String(v);
  return out;
}

/**
 * The peer of an FXServer HTTP request ("ip:port", "[v6]:port" or a bare address). The service runs on the same host
 * (§C6), so anything that is clearly not loopback is refused. An address we cannot parse is let through: the HMAC
 * check stays the authoritative one.
 */
function isRemotePeer(address) {
  if (typeof address !== 'string' || address === '') return false;
  let host = address.trim();
  const v6 = /^\[([^\]]+)\](?::\d+)?$/.exec(host);
  if (v6) host = v6[1];
  else if (/^[\d.]+:\d+$/.test(host)) host = host.slice(0, host.lastIndexOf(':'));
  if (/^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(host) || host === '::1' || /^::ffff:127\./i.test(host)) return false;
  if (/^[\d.]+$/.test(host) || /^[0-9a-f:]+$/i.test(host) || /^::ffff:/i.test(host)) return true;
  return false;
}

// ---------------------------------------------------------------------------------------------------------------
// Handler

/**
 * deps: secret (null = disabled), now() unix seconds, nowMs() for the Lua deadline, callLua(body, cb) -> boolean
 * (the portalRequest export), setTimer(fn, ms) / clearTimer(handle), log(level, msg).
 * Order: route (404/405) -> peer (404) -> size (413) -> signature (401) -> JSON (400) -> requestId (400/409) -> Lua.
 */
function createHandler(deps) {
  const seen = new Map(); // requestId -> expiry (unix seconds)
  function rememberId(id, nowSeconds) {
    if (seen.size >= MAX_REMEMBERED || seen.size % 256 === 0) {
      for (const [k, exp] of seen) if (exp < nowSeconds) seen.delete(k);
    }
    if (seen.size >= MAX_REMEMBERED) return false; // flooded: refuse rather than forget
    seen.set(id, nowSeconds + 2 * MAX_SKEW_SECONDS);
    return true;
  }

  let lastRejectLog = -Infinity;
  let suppressed = 0;
  function logRejection(nowSeconds, line) {
    if (nowSeconds - lastRejectLog < REJECT_LOG_INTERVAL_S) {
      suppressed += 1;
      return;
    }
    const extra = suppressed > 0 ? ` (${suppressed} more rejected since the last report)` : '';
    lastRejectLog = nowSeconds;
    suppressed = 0;
    deps.log('warn', line + extra);
  }

  return function handle(req, res) {
    let finished = false;
    const reply = (status, payload, extraHeaders) => {
      if (finished) return;
      finished = true;
      try {
        res.writeHead(status, Object.assign({ 'Content-Type': 'application/json; charset=utf-8' }, extraHeaders || {}));
        res.send(typeof payload === 'string' ? payload : JSON.stringify(payload));
      } catch (err) {
        deps.log('error', `failed to send HTTP response: ${err && err.message}`);
      }
    };

    const path = String(req.path || '/').split('?')[0].replace(/\/+$/, '') || '/';
    const method = String(req.method || 'GET').toUpperCase();
    if (path !== PORTAL_PATH) return reply(404, { error: 'not_found' });
    if (method !== 'POST') return reply(405, { error: 'method_not_allowed' }, { Allow: 'POST' });
    if (isRemotePeer(req.address)) return reply(404, { error: 'not_found' });
    if (!deps.secret) return reply(503, { error: 'bridge_disabled' });

    const headers = lowerHeaders(req.headers);
    const declared = Number(headers['content-length']);
    if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) return reply(413, { error: 'payload_too_large' });

    const handleBody = (rawBody) => {
      if (finished) return;
      if (typeof rawBody !== 'string') rawBody = rawBody == null ? '' : Buffer.from(rawBody).toString('utf8');
      if (Buffer.byteLength(rawBody, 'utf8') > MAX_BODY_BYTES) return reply(413, { error: 'payload_too_large' });

      const now = deps.now();
      const check = verifySignature({ secret: deps.secret, ts: headers[TS_HEADER], sig: headers[SIG_HEADER], rawBody, nowSeconds: now });
      if (!check.ok) {
        logRejection(now, `rejected POST ${path} from ${req.address || '?'}: ${check.reason}`);
        return reply(401, { error: 'unauthorized' });
      }

      let body;
      try {
        body = JSON.parse(rawBody);
      } catch {
        return reply(400, { error: 'bad_json' });
      }
      if (body === null || typeof body !== 'object' || Array.isArray(body)) return reply(400, { error: 'bad_json' });
      if (typeof body.requestId !== 'string' || !REQUEST_ID_RE.test(body.requestId)) {
        return reply(400, { error: 'invalid_body', detail: 'requestId' });
      }
      if (seen.has(body.requestId) && seen.get(body.requestId) >= now) return reply(409, { error: 'duplicate' });
      if (!rememberId(body.requestId, now)) return reply(503, { error: 'busy' });

      const timer = deps.setTimer(() => {
        deps.log('warn', `portal action ${String(body.action).slice(0, 64)} did not answer within ${LUA_TIMEOUT_MS} ms`);
        reply(504, { error: 'timeout' });
      }, LUA_TIMEOUT_MS);
      let accepted = false;
      try {
        accepted = deps.callLua(body, (status, text) => {
          deps.clearTimer(timer);
          const code = Number(status);
          reply(Number.isInteger(code) && code >= 200 && code < 600 ? code : 500, typeof text === 'string' ? text : '{"error":"internal"}');
        });
      } catch (err) {
        deps.log('error', `portalRequest failed: ${err && err.stack ? err.stack : err}`);
      }
      if (accepted !== true) {
        deps.clearTimer(timer);
        reply(503, { error: 'unavailable' });
      }
    };

    if (typeof req.setCancelHandler === 'function') req.setCancelHandler(() => { finished = true; });
    req.setDataHandler(handleBody);
  };
}

/** Wires the handler to FiveM (`fivem` holds the globals; the test passes mocks). */
function createPortalBridge(fivem) {
  const resource = fivem.GetCurrentResourceName();
  const log = (level, msg) => {
    const out = level === 'error' ? fivem.console.error : level === 'warn' ? fivem.console.warn : fivem.console.log;
    out(`[${resource}:http] ${msg}`);
  };
  let secret = fivem.GetConvar('fredpd_hmac_secret', '');
  const problem = secretProblem(secret);
  if (problem) {
    log('error', `portal route DISABLED: ${problem}. Set it (>= ${MIN_SECRET_LENGTH} chars, same value as FREDPD_HMAC_SECRET) in server.cfg.`);
    secret = null;
  }
  const handle = createHandler({
    secret,
    now: () => Math.floor(Date.now() / 1000),
    log,
    setTimer: (fn, ms) => setTimeout(fn, ms),
    clearTimer: (h) => clearTimeout(h),
    callLua: (body, cb) => fivem.exports[resource].portalRequest(body, cb),
  });
  fivem.SetHttpHandler(handle);
  return { handle, enabled: secret !== null };
}

const api = {
  PORTAL_PATH, MAX_BODY_BYTES, MAX_SKEW_SECONDS, LUA_TIMEOUT_MS, REJECT_LOG_INTERVAL_S,
  signBody, verifySignature, secretProblem, isRemotePeer, createHandler, createPortalBridge,
};

if (typeof SetHttpHandler === 'function' && typeof GetConvar === 'function') {
  createPortalBridge({ SetHttpHandler, GetConvar, GetCurrentResourceName, exports, console });
}

if (typeof module === 'object' && module && module.exports) module.exports = api;
