// SPDX-License-Identifier: GPL-3.0-only
// fredpd_core HTTP bridge (FiveM server JS runtime, CommonJS script).
//
// Inbound: SetHttpHandler routes reached at http://127.0.0.1:30120/fredpd_core/<path> (docs/contracts.md §C6), every
// request HMAC-signed per §C5. Outbound: export signedFetch(method, path, body, cb) that Lua wraps as Core.fetch.
//
// The HMAC algorithm is a copy of packages/types/src/hmac.ts (this file cannot import TS); both are checked against
// packages/types/test/fixtures/hmac.fixtures.json (see ../test/http.test.ts).
//
// Structure: everything below `createBridge` is pure and takes its FiveM dependencies as arguments, so the test can
// run it with mocks. The bottom of the file wires it to the real globals (SetHttpHandler, GetConvar, exports).
//
// Lua exports called from here (applyGrants, recomputeGrants, setOfficerIdentity) never yield: they update memory
// and return a number synchronously, and start any DB/network work in their own Lua thread. POST /rules only emits
// the server-local event `fredpd:rulesChanged` (server/canview.lua reloads the rules in its own thread; other
// resources may listen too). A local emit reaches Lua with source '' (never a player id).
'use strict';

const nodeCrypto = require('crypto');

const MAX_BODY_BYTES = 64 * 1024;
const MAX_SKEW_SECONDS = 60;
const MIN_SECRET_LENGTH = 32;
const FETCH_TIMEOUT_MS = 3000;
const MAX_RESPONSE_BYTES = 1024 * 1024; // signedFetch never buffers more than this from the service
// signedFetch only reaches the service's FXServer-facing routes (§C6), and only for FredPD resources.
const FETCH_PATH_RE = /^\/(?:internal\/[A-Za-z0-9._~%/-]*|upload)(?:\?[^#\s]*)?$/;
const FETCH_CALLER_RE = /^fredpd_[a-z0-9_]+$/;
const TS_HEADER = 'x-fredpd-ts';
const SIG_HEADER = 'x-fredpd-sig';
const DISCORD_ID_RE = /^\d{1,20}$/;
const GRANT_RE = /^[a-z_]+:[^\s]{1,120}$/;
const UNIT_RE = /^[A-Za-z0-9_-]{1,32}$/;
const MAX_LIST = 2000;
const MAX_NAME_CHARS = 100; // fredpd_officers.display_name VARCHAR(100) utf8mb4: characters, not UTF-16 units
const RULES_CHANGED_EVENT = 'fredpd:rulesChanged';
// Placeholder secrets from examples/docs. Long enough to pass the length check, but public: refuse them.
const PLACEHOLDER_SECRET_RE = /change[_\s-]?me|placeholder|your[_\s-]?secret|^(.)\1+$/i;
const REJECT_LOG_INTERVAL_S = 10; // at most one "rejected" log line per interval (the routes are on the public port)

// ---------------------------------------------------------------------------------------------------------------
// HMAC (§C5), same semantics as packages/types/src/hmac.ts

/** hex(hmac_sha256(secret, ts + "." + rawBody)) */
function signBody(secret, ts, rawBody) {
  return nodeCrypto.createHmac('sha256', secret).update(`${ts}.${rawBody}`, 'utf8').digest('hex');
}

/**
 * @returns {{ ok: true } | { ok: false, reason: 'missing' | 'skew' | 'signature' }}
 */
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

/**
 * Secrets shorter than 32 characters (or missing) disable the bridge (§C5). So does a known placeholder such as the
 * server.cfg.example value: the /fredpd_core/* routes share the public game port, and a secret that is published
 * in the repository would let anyone sign a /grants push.
 */
function secretProblem(secret) {
  if (typeof secret !== 'string' || secret.length === 0) return 'convar fredpd_hmac_secret is not set';
  if (secret.length < MIN_SECRET_LENGTH) return `convar fredpd_hmac_secret is shorter than ${MIN_SECRET_LENGTH} characters`;
  if (PLACEHOLDER_SECRET_RE.test(secret)) return 'convar fredpd_hmac_secret is still a placeholder value';
  return null;
}

// ---------------------------------------------------------------------------------------------------------------
// Body validation (defence in depth: Lua validates again)

function isStringList(v, re) {
  return Array.isArray(v) && v.length <= MAX_LIST && v.every((s) => typeof s === 'string' && re.test(s));
}

/** Shape check of a GrantSet (§C2). Returns an error string or null. */
function grantSetProblem(set) {
  if (!set || typeof set !== 'object' || Array.isArray(set)) return 'grants must be an object';
  if (!isStringList(set.grants, GRANT_RE)) return 'grants.grants must be a list of "type:key"';
  if (!isStringList(set.denied, GRANT_RE)) return 'grants.denied must be a list of "type:key"';
  if (!Number.isInteger(set.tier) || set.tier < 0 || set.tier > 2) return 'grants.tier must be 0, 1 or 2';
  if (!isStringList(set.units, UNIT_RE)) return 'grants.units must be a list of unit codes';
  if (set.rank !== undefined && set.rank !== null) {
    const r = set.rank;
    if (typeof r !== 'object' || typeof r.roleId !== 'string' || typeof r.key !== 'string') return 'grants.rank is invalid';
  }
  if (set.computedAt !== undefined && typeof set.computedAt !== 'string') return 'grants.computedAt must be a string';
  return null;
}

function isDiscordId(v) {
  return typeof v === 'string' && DISCORD_ID_RE.test(v);
}

// ---------------------------------------------------------------------------------------------------------------
// Inbound handler

/** Header lookup that does not depend on the casing FXServer hands us. */
function lowerHeaders(headers) {
  const out = {};
  if (!headers || typeof headers !== 'object') return out;
  for (const [k, v] of Object.entries(headers)) out[String(k).toLowerCase()] = Array.isArray(v) ? v.join(',') : String(v);
  return out;
}

/**
 * The peer of an FXServer HTTP request ("ip:port", "[v6]:port" or a bare address). The service reaches these routes
 * at 127.0.0.1 (§C6), so anything that is clearly not loopback is refused (same rule as fredpd_mdt/server/http.js).
 * An address we cannot parse is let through: the HMAC check stays the authoritative one.
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

/** The first key of `body` that is not in `allowed` (§C5 signs only ts + body: a body signed for another route must
 * not pass here), or undefined. */
function unknownKey(body, allowed) {
  return Object.keys(body).find((k) => !allowed.includes(k));
}

function sendJson(res, status, obj, extraHeaders) {
  res.writeHead(status, Object.assign({ 'Content-Type': 'application/json; charset=utf-8' }, extraHeaders || {}));
  res.send(JSON.stringify(obj));
}

/**
 * Route table (§C6). `run(body, deps)` returns [status, responseObject]. Everything except /ping is POST, and every
 * POST needs a JSON object body. `memo: true` marks the routes that carry state (see the duplicate memo in
 * createHandler): an identical signed request is answered from memory instead of being applied again.
 */
const ROUTES = {
  '/ping': {
    method: 'GET',
    memo: false,
    run(_body, deps) {
      return [200, { ok: true, players: deps.playerCount() }];
    },
  },
  '/grants': {
    method: 'POST',
    memo: true,
    run(body, deps) {
      // Only the §C6 keys, so a captured signed POST /fredpd_mdt/portal body ({ requestId, discordId, citizenid,
      // grants, ... }) cannot be replayed here to re-apply an older grant set (8.3 review).
      const unknown = unknownKey(body, ['discordId', 'grants']);
      if (unknown !== undefined) return [400, { error: 'invalid_body', detail: `unknown key ${unknown.slice(0, 32)}` }];
      if (!isDiscordId(body.discordId)) return [400, { error: 'invalid_body', detail: 'discordId' }];
      const problem = grantSetProblem(body.grants);
      if (problem) return [400, { error: 'invalid_body', detail: problem }];
      const applied = deps.callLua('applyGrants', body.discordId, body.grants);
      if (applied === false || applied === null || applied === undefined) return [400, { error: 'invalid_body', detail: 'rejected by applyGrants' }];
      // One line per accepted push (role changes are rare): the Phase 1 checklist times Discord -> game with it.
      deps.log('info', `grants pushed for discord ${body.discordId}: ${body.grants.grants.length} grant(s), applied to ${Number(applied) || 0} player(s)`);
      return [200, { ok: true, applied: Number(applied) || 0 }];
    },
  },
  '/recompute': {
    method: 'POST',
    // Not memoised: it carries no state, it only says "re-read". Two recomputes in the same second (two permission
    // saves) sign identically, and the second must still run because the first may have read the service's state
    // before the second change was committed. A replay within the skew window only forces an extra reload.
    memo: false,
    run(body, deps) {
      // Only the §C6 key. With §C5 signing just ts + body, this stops a captured /grants or /officer body (and,
      // with the body requirement in the handler, a captured GET /ping signature) from being reused here.
      const unknown = Object.keys(body).find((k) => k !== 'discordIds');
      if (unknown !== undefined) return [400, { error: 'invalid_body', detail: `unknown key ${unknown.slice(0, 32)}` }];
      let ids = null;
      if (body.discordIds !== undefined && body.discordIds !== null) {
        if (!isStringList(body.discordIds, DISCORD_ID_RE)) return [400, { error: 'invalid_body', detail: 'discordIds' }];
        ids = body.discordIds;
      }
      const scheduled = Number(deps.callLua('recomputeGrants', ids)) || 0;
      deps.log('info', `grant recompute for ${ids ? `${ids.length} discord id(s)` : 'everyone online'}: ${scheduled} player(s) re-fetching`);
      return [200, { ok: true, scheduled }];
    },
  },
  '/officer': {
    method: 'POST',
    memo: true,
    run(body, deps) {
      const unknown = unknownKey(body, ['discordId', 'displayName', 'avatarUrl']);
      if (unknown !== undefined) return [400, { error: 'invalid_body', detail: `unknown key ${unknown.slice(0, 32)}` }];
      if (!isDiscordId(body.discordId)) return [400, { error: 'invalid_body', detail: 'discordId' }];
      const name = typeof body.displayName === 'string' ? body.displayName.trim() : '';
      // Count code points like utf8.len in Lua and VARCHAR(100) utf8mb4 (String#length counts UTF-16 units).
      if (name.length === 0 || [...name].length > MAX_NAME_CHARS) {
        return [400, { error: 'invalid_body', detail: 'displayName' }];
      }
      const avatar = body.avatarUrl ?? null;
      if (avatar !== null && (typeof avatar !== 'string' || avatar.length > 255)) {
        return [400, { error: 'invalid_body', detail: 'avatarUrl' }];
      }
      const updated = deps.callLua('setOfficerIdentity', body.discordId, name, avatar);
      if (updated === false || updated === null || updated === undefined) {
        return [400, { error: 'invalid_body', detail: 'rejected by setOfficerIdentity' }];
      }
      deps.log('info', `officer name for discord ${body.discordId} is now ${JSON.stringify(name)} (${Number(updated) || 0} officer character(s))`);
      return [200, { ok: true, updated: Number(updated) || 0 }];
    },
  },
  '/rules': {
    method: 'POST',
    // Not memoised, like /recompute: it carries no state, it only says "re-read fredpd_visibility_rules". Two rule
    // edits in the same second sign identically and the second reload must still run. A replay within the skew
    // window (or a captured `/recompute {}`, which signs the same body) only forces an extra reload.
    memo: false,
    run(body, deps) {
      // Exactly {} (§C6). An empty body is already 400 bad_json in the handler, so a GET signature is refused, and
      // any key is refused so a captured /grants, /officer or `/recompute { discordIds }` body cannot be reused here.
      const unknown = Object.keys(body)[0];
      if (unknown !== undefined) return [400, { error: 'invalid_body', detail: `unknown key ${unknown.slice(0, 32)}` }];
      deps.emitEvent(RULES_CHANGED_EVENT);
      deps.log('info', 'visibility rules changed: reloading');
      return [200, { ok: true }];
    },
  },
};

/**
 * Builds the request handler. deps:
 *   secret           HMAC secret; null/'' when the bridge is disabled (every request then gets 503)
 *   now()            unix seconds
 *   callLua(name, ...args)  calls a Lua export of this resource and returns its result
 *   emitEvent(name, ...args)  fires a server-local event (FiveM `emit`, i.e. TriggerEvent)
 *   playerCount()    online players
 *   log(level, msg)
 * Order of checks: route (404/405) -> peer (404, not loopback) -> size (413) -> signature (401) -> duplicate of a memo route (cached answer) ->
 * JSON (400) -> body shape (400) -> Lua.
 */
function createHandler(deps) {
  // Duplicate suppression for the state-carrying routes (/grants, /officer). §C5 signs only ts + body, with 1 s
  // resolution, so an identical request in the same second (a retried POST that reuses its headers) carries the same
  // signature. It must not get 401 (which in §C5 means skew or a bad signature). Instead the first answer is
  // remembered for the skew window and a repeat of the same method + path + signature gets that answer again without
  // calling Lua, so a captured /grants push cannot be re-applied later to roll back a newer one. An identical body
  // means an identical state, so nothing is lost. /ping, /recompute and /rules carry no state and always run. Only
  // verified requests are stored; 5xx answers are not, so a retry after an internal error runs again. Pruned on
  // insert.
  const answered = new Map(); // key -> { expires, status, obj }
  function remembered(key, nowSeconds) {
    const hit = answered.get(key);
    if (hit && hit.expires >= nowSeconds) return hit;
    return null;
  }
  function remember(key, nowSeconds, status, obj) {
    if (status >= 500) return;
    for (const [k, v] of answered) if (v.expires < nowSeconds) answered.delete(k);
    answered.set(key, { expires: nowSeconds + 2 * MAX_SKEW_SECONDS, status, obj });
  }

  // Rejections come from anyone who can reach the game port: log at most one line per interval and count the rest.
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
    const reply = (status, obj, extra) => {
      if (finished) return;
      finished = true;
      try {
        sendJson(res, status, obj, extra);
      } catch (err) {
        deps.log('error', `failed to send HTTP response: ${err && err.message}`);
      }
    };

    const path = String(req.path || '/').split('?')[0].replace(/\/+$/, '') || '/';
    const method = String(req.method || 'GET').toUpperCase();
    const route = Object.prototype.hasOwnProperty.call(ROUTES, path) ? ROUTES[path] : null;
    if (!route) return reply(404, { error: 'not_found' });
    if (method !== route.method) return reply(405, { error: 'method_not_allowed' }, { Allow: route.method });
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
        logRejection(now, `rejected ${method} ${path} from ${req.address || '?'}: ${check.reason}`);
        return reply(401, { error: 'unauthorized' });
      }

      let answer = reply;
      if (route.memo) {
        const key = `${method} ${path} ${headers[SIG_HEADER].toLowerCase()}`;
        const earlier = remembered(key, now);
        if (earlier) return reply(earlier.status, earlier.obj, { 'X-FredPD-Duplicate': '1' });
        answer = (status, obj) => {
          remember(key, now, status, obj);
          return reply(status, obj);
        };
      }

      // Every POST body must be a JSON object: an empty body (the signature of a GET) is bad JSON.
      let body = {};
      if (method !== 'GET') {
        try {
          body = JSON.parse(rawBody);
        } catch {
          return answer(400, { error: 'bad_json' });
        }
      }
      if (body === null || typeof body !== 'object' || Array.isArray(body)) return answer(400, { error: 'bad_json' });

      try {
        const [status, obj] = route.run(body, deps);
        return answer(status, obj);
      } catch (err) {
        deps.log('error', `${method} ${path} failed: ${err && err.stack ? err.stack : err}`);
        return answer(500, { error: 'internal' });
      }
    };

    // A GET is signed with an empty body (§C5) and is answered without waiting for one.
    if (method === 'GET') return handleBody('');
    if (typeof req.setCancelHandler === 'function') req.setCancelHandler(() => { finished = true; });
    req.setDataHandler(handleBody);
  };
}

// ---------------------------------------------------------------------------------------------------------------
// Outbound: signedFetch

/**
 * Minimal fetch replacement on node:http(s) for FXServer builds whose Node has no global fetch. The deadline is the
 * caller's overall timer (it aborts `signal`), not a socket idle timeout, so a peer that trickles bytes cannot keep
 * the request open past it.
 */
function nodeFetch(url, { method, headers, body, signal }) {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const lib = target.protocol === 'https:' ? require('https') : require('http');
    const req = lib.request(target, { method, headers }, (res) => {
      const declared = Number(res.headers && res.headers['content-length']);
      if (declared > MAX_RESPONSE_BYTES) {
        req.destroy();
        reject(Object.assign(new Error('response too large'), { code: 'too_large' }));
        return;
      }
      const chunks = [];
      let size = 0;
      res.on('data', (c) => {
        size += c.length;
        if (size > MAX_RESPONSE_BYTES) {
          req.destroy();
          reject(Object.assign(new Error('response too large'), { code: 'too_large' }));
          return;
        }
        chunks.push(c);
      });
      res.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        resolve({ status: res.statusCode || 0, text: async () => text });
      });
      res.on('error', reject);
      res.on('aborted', () => reject(new Error('aborted')));
    });
    req.on('error', reject);
    if (signal) {
      const abort = () => req.destroy(Object.assign(new Error('timeout'), { name: 'AbortError' }));
      if (signal.aborted) abort();
      else signal.addEventListener('abort', abort, { once: true });
    }
    if (body !== undefined) req.write(body);
    req.end();
  });
}

/**
 * Reads a WHATWG fetch Response body as UTF-8 text, failing with code 'too_large' past `max` bytes (declared by
 * Content-Length or counted while streaming), so a misbehaving service cannot fill the FXServer heap.
 */
async function readCapped(res, max) {
  const len = res.headers && typeof res.headers.get === 'function' ? Number(res.headers.get('content-length')) : NaN;
  const tooLarge = () => Object.assign(new Error('response too large'), { code: 'too_large' });
  if (len > max) throw tooLarge();
  if (!res.body || typeof res.body.getReader !== 'function') {
    const text = await res.text();
    if (Buffer.byteLength(text, 'utf8') > max) throw tooLarge();
    return text;
  }
  const reader = res.body.getReader();
  const chunks = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > max) {
      try { await reader.cancel(); } catch { /* already closed */ }
      throw tooLarge();
    }
    chunks.push(Buffer.from(value));
  }
  return Buffer.concat(chunks).toString('utf8');
}

/**
 * Builds signedFetch(method, path, body, cb). deps:
 *   secret, baseUrl, now() (unix seconds), fetch (global fetch or undefined), timeoutMs, log(level, msg),
 *   invoker() (optional: name of the calling resource; only fredpd_* resources may sign requests)
 * cb(status, bodyString) is called exactly once; status 0 means no HTTP response (bridge disabled, invalid call,
 * timeout, network error) and the body is then {"error": "..."}.
 */
function createSignedFetch(deps) {
  const timeoutMs = deps.timeoutMs ?? FETCH_TIMEOUT_MS;
  return function signedFetch(method, path, body, cb) {
    let called = false;
    const done = (status, text) => {
      if (called) return;
      called = true;
      if (typeof cb !== 'function') return;
      try {
        cb(status, text);
      } catch (err) {
        deps.log('error', `signedFetch callback failed: ${err && err.message}`);
      }
    };
    const fail = (code) => done(0, JSON.stringify({ error: code }));

    if (!deps.secret) return fail('bridge_disabled');
    // Any server resource can call an export; only FredPD's own may make HMAC-signed service calls. An empty
    // invoker means a call from inside fredpd_core's own runtime.
    const caller = typeof deps.invoker === 'function' ? deps.invoker() : null;
    if (caller && !FETCH_CALLER_RE.test(String(caller))) {
      deps.log('warn', `signedFetch refused for resource ${String(caller).slice(0, 64)}`);
      return fail('forbidden');
    }
    const m = String(method || '').toUpperCase();
    if (!['GET', 'POST', 'PUT', 'PATCH', 'DELETE'].includes(m) || typeof path !== 'string' || !path.startsWith('/')) {
      return fail('invalid_request');
    }
    if (!FETCH_PATH_RE.test(path) || /(?:^|\/)\.\.?(?:\/|$|\?)|%2e|%2f/i.test(path)) return fail('forbidden');

    let rawBody = '';
    if (m !== 'GET' && body !== undefined && body !== null) {
      try {
        rawBody = JSON.stringify(body);
      } catch {
        return fail('invalid_body');
      }
    }
    const ts = String(deps.now());
    const headers = { [TS_HEADER]: ts, [SIG_HEADER]: signBody(deps.secret, ts, rawBody), Accept: 'application/json' };
    if (m !== 'GET') headers['Content-Type'] = 'application/json';
    const url = deps.baseUrl + path;

    // One overall deadline for both transports: the callback fires at the latest after timeoutMs, and the request
    // is aborted so it does not linger.
    const controller = typeof AbortController === 'function' ? new AbortController() : null;
    const signal = controller ? controller.signal : undefined;
    const timer = setTimeout(() => {
      if (controller) controller.abort();
      fail('timeout');
    }, timeoutMs);
    const init = { method: m, headers, body: m === 'GET' ? undefined : rawBody, signal };
    let request;
    try {
      request = typeof deps.fetch === 'function' ? deps.fetch(url, init) : nodeFetch(url, init);
    } catch (err) {
      request = Promise.reject(err); // e.g. an invalid fredpd_service_url
    }

    Promise.resolve(request)
      .then(async (res) => {
        const text = typeof deps.fetch === 'function' ? await readCapped(res, MAX_RESPONSE_BYTES) : await res.text();
        done(res.status, text);
      })
      .catch((err) => {
        const aborted = err && (err.name === 'AbortError' || err.message === 'timeout');
        const tooLarge = err && err.code === 'too_large';
        if (!aborted) deps.log('warn', `signedFetch ${m} ${path} failed: ${err && err.message}`);
        if (tooLarge && controller) controller.abort();
        fail(aborted ? 'timeout' : tooLarge ? 'too_large' : 'network');
      })
      .finally(() => {
        clearTimeout(timer);
      });
  };
}

/**
 * Wires the bridge to FiveM. `fivem` holds the globals (injected so the test can pass mocks):
 *   SetHttpHandler, GetConvar, GetCurrentResourceName, GetNumPlayerIndices, GetInvokingResource, exports, emit, fetch,
 *   console
 */
function createBridge(fivem) {
  const resource = fivem.GetCurrentResourceName();
  const log = (level, msg) => {
    const out = level === 'error' ? fivem.console.error : level === 'warn' ? fivem.console.warn : fivem.console.log;
    out(`[${resource}:http] ${msg}`);
  };

  let secret = fivem.GetConvar('fredpd_hmac_secret', '');
  const problem = secretProblem(secret);
  if (problem) {
    log('error', `HTTP bridge DISABLED: ${problem}. Set it (>= ${MIN_SECRET_LENGTH} chars, same value as FREDPD_HMAC_SECRET) in server.cfg.`);
    secret = null;
  }
  const baseUrl = String(fivem.GetConvar('fredpd_service_url', 'http://127.0.0.1:3000')).replace(/\/+$/, '');
  const now = () => Math.floor(Date.now() / 1000);

  const handle = createHandler({
    secret,
    now,
    log,
    callLua: (name, ...args) => fivem.exports[resource][name](...args),
    emitEvent: (name, ...args) => fivem.emit(name, ...args),
    playerCount: () => Number(fivem.GetNumPlayerIndices()) || 0,
  });
  fivem.SetHttpHandler(handle);

  const invoker = typeof fivem.GetInvokingResource === 'function' ? () => fivem.GetInvokingResource() : undefined;
  const signedFetch = createSignedFetch({ secret, baseUrl, now, fetch: fivem.fetch, log, invoker });
  fivem.exports('signedFetch', signedFetch);
  return { handle, signedFetch, enabled: secret !== null, baseUrl };
}

const api = {
  MAX_BODY_BYTES, MAX_RESPONSE_BYTES, MAX_SKEW_SECONDS, MIN_SECRET_LENGTH, FETCH_TIMEOUT_MS, REJECT_LOG_INTERVAL_S, RULES_CHANGED_EVENT,
  signBody, verifySignature, secretProblem, grantSetProblem, isRemotePeer, createHandler, createSignedFetch, createBridge,
};

// FiveM: the natives and `exports` are globals of the resource's JS context. Outside FiveM (tests) nothing is wired
// unless they are mocked. GetNumPlayerIndices and fetch are read from globalThis because they are optional here.
if (typeof SetHttpHandler === 'function' && typeof GetConvar === 'function') {
  createBridge({
    SetHttpHandler,
    GetConvar,
    GetCurrentResourceName,
    GetNumPlayerIndices: globalThis.GetNumPlayerIndices,
    GetInvokingResource: globalThis.GetInvokingResource,
    exports,
    emit: typeof emit === 'function' ? emit : globalThis.TriggerEvent,
    fetch: typeof globalThis.fetch === 'function' ? globalThis.fetch.bind(globalThis) : undefined,
    console,
  });
}

if (typeof module === 'object' && module && module.exports) module.exports = api;
