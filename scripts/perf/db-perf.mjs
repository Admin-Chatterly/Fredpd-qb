#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-only
// Task 8.1: DB query timings for docs/perf.md. Creates a throw-away database, applies db/migrations + seeds with
// scripts/migrate.mjs, fills it with a synthetic server's worth of data and times the hot read paths with the same
// SQL shapes the Lua resources send (copied from fredpd_records/server/search.lua, cases.lua, lookupflag.lua and
// fredpd_dispatch/server/alert_store.lua; keep them in step when those change). Prints EXPLAIN and
// min/median/p95/max per query as Markdown (or JSON with --json).
//
//   node scripts/perf/db-perf.mjs [--url mysql://user:pass@host:3306/any] [--db fredpd_test_perf] [--runs 200]
//                                 [--persons 5000] [--audit 20000] [--cases 2000] [--keep] [--json]
//
// --url defaults to FREDPD_TEST_DB_URL (the test DB of README "Development"); only host/port/credentials are used:
// the script always works in its own database (default fredpd_test_perf, dropped first and, unless --keep, after).
// It never touches the database named in the URL. Data is deterministic (fixed PRNG seed), so runs are comparable.
import { performance } from 'node:perf_hooks';
import { connect, migrate } from '../migrate.mjs';

const args = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] !== undefined ? args[i + 1] : fallback;
};
const flag = (name) => args.includes(`--${name}`);

const BASE_URL = opt('url', process.env.FREDPD_TEST_DB_URL ?? 'mysql://fredpd:fredpd@127.0.0.1:3306/fredpd_test');
const DB = opt('db', 'fredpd_test_perf');
const RUNS = Number(opt('runs', 200));
const N_PERSONS = Number(opt('persons', 5000));
const N_AUDIT = Number(opt('audit', 20000));
const N_CASES = Number(opt('cases', 2000));
const N_VEHICLES = Math.round(N_PERSONS * 1.2);
const N_ALERTS = 3000;
const N_OFFICERS = 60;

if (!/^fredpd_test_[a-z0-9_]+$/.test(DB)) throw new Error(`--db must match fredpd_test_* (got ${DB})`);

// ---------------------------------------------------------------------------------------------------------------
// Deterministic data

let seed = 0x5eed2026;
const rnd = () => {
  // mulberry32
  seed = (seed + 0x6d2b79f5) | 0;
  let t = seed;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
};
const pick = (a) => a[Math.floor(rnd() * a.length)];
const int = (lo, hi) => lo + Math.floor(rnd() * (hi - lo + 1));

const FIRST = ['Anna', 'Erik', 'Lars', 'Karin', 'Maria', 'Johan', 'Anders', 'Eva', 'Per', 'Lena', 'Nils', 'Sara', 'Oskar',
  'Elin', 'Omar', 'Fatima', 'Mikael', 'Emma', 'Ali', 'Sofia', 'Björn', 'Åsa', 'Göran', 'Linnéa', 'Bo', 'Li', 'Hugo',
  'Ida', 'Ahmed', 'Maja', 'Viktor', 'Wilma', 'Leo', 'Alva', 'Elias', 'Ebba', 'Noah', 'Astrid', 'Liam', 'Saga'];
const LAST = ['Andersson', 'Johansson', 'Karlsson', 'Nilsson', 'Eriksson', 'Larsson', 'Olsson', 'Persson', 'Svensson',
  'Gustafsson', 'Pettersson', 'Jonsson', 'Jansson', 'Hansson', 'Bengtsson', 'Jönsson', 'Lindberg', 'Jakobsson',
  'Magnusson', 'Olofsson', 'Lindström', 'Lindqvist', 'Lindgren', 'Berg', 'Axelsson', 'Bergström', 'Lundberg',
  'Lind', 'Lundgren', 'Lundqvist', 'Mattsson', 'Berglund', 'Fredriksson', 'Sandberg', 'Henriksson', 'Ali',
  'Mohammed', 'Hussein', 'Öberg', 'Åberg', 'Ek', 'Holm', 'Nyström', 'Sjöberg', 'Wallin', 'Engström', 'Danielsson'];
const MODELS = ['volvo240', 'v60', 'xc90', 'golf', 'passat', 'tesla', 'sultan', 'kuruma', 'buffalo', 'blista'];
const UNITS = ['igv', 'span', 'utredning', 'tekniker', 'ledning'];
const LETTERS = 'ABCDEFGHJKLMNPRSTUWXYZ';
const pad = (n, w) => String(n).padStart(w, '0');
const dt = (daysAgo, secs = 0) => new Date(Date.UTC(2026, 8, 29, 12) - daysAgo * 86400000 - secs * 1000)
  .toISOString().slice(0, 19).replace('T', ' ');

function persons() {
  const rows = [];
  for (let i = 1; i <= N_PERSONS; i++) {
    const y = int(1950, 2006);
    const birth = `${y}-${pad(int(1, 12), 2)}-${pad(int(1, 28), 2)}`;
    rows.push([`PRF${pad(i, 5)}`, pick(FIRST), pick(LAST), birth, `${birth.slice(2).replaceAll('-', '')}-${pad(int(0, 9999), 4)}`,
      int(0, 1), `07${pad(int(0, 99999999), 8)}`, `license:${pad(i, 8)}`]);
  }
  return rows;
}

function plate(i) {
  return `${LETTERS[i % 22]}${LETTERS[Math.floor(i / 22) % 22]}${LETTERS[Math.floor(i / 484) % 22]}${pad(i % 100, 2)}${LETTERS[(i * 7) % 22]}`;
}

// ---------------------------------------------------------------------------------------------------------------
// Load

async function insertMany(conn, table, cols, rows, chunk = 1000) {
  for (let i = 0; i < rows.length; i += chunk) {
    const part = rows.slice(i, i + chunk);
    await conn.query(`INSERT INTO ${table} (${cols.join(', ')}) VALUES ?`, [part]);
  }
}

async function load(conn) {
  const t0 = performance.now();
  const people = persons();
  await insertMany(conn, 'fredpd_persons', ['citizenid', 'firstname', 'lastname', 'birthdate', 'personnummer', 'gender', 'phone', 'license'], people);

  const vehicles = [];
  for (let i = 0; i < N_VEHICLES; i++) vehicles.push([plate(i), i % 10 === 0 ? null : people[int(0, people.length - 1)][0], pick(MODELS)]);
  await insertMany(conn, 'fredpd_vehicles_idx', ['plate', 'citizenid', 'model'], vehicles);

  const officers = [];
  for (let i = 1; i <= N_OFFICERS; i++) {
    officers.push([`OFF${pad(i, 5)}`, String(100000000000000000n + BigInt(i)), `Officer ${i}`, UNITS[i % UNITS.length], `${UNITS[i % UNITS.length].toUpperCase().slice(0, 3)}-${pad(i, 2)}`]);
  }
  await insertMany(conn, 'fredpd_officers', ['citizenid', 'discord_id', 'display_name', 'unit', 'callsign'], officers);
  const officer = () => officers[int(0, officers.length - 1)][0];

  const cases = [];
  for (let i = 1; i <= N_CASES; i++) {
    const days = int(0, 365);
    const open = rnd() < 0.3;
    cases.push([i, `K-${i}-26`, `Ärende ${i}: ${pick(['stöld', 'misshandel', 'rån', 'narkotikabrott', 'trafikbrott', 'bedrägeri'])}`,
      open ? 'open' : 'closed', rnd() < 0.8 ? 0 : int(1, 2), pick(UNITS), officer(), dt(days - 1), dt(days)]);
  }
  await insertMany(conn, 'fredpd_cases', ['id', 'case_number', 'title', 'status', 'level', 'unit', 'owner_citizenid', 'updated_at', 'created_at'], cases);

  const assignees = new Map();
  for (const c of cases) for (let k = int(0, 2); k > 0; k--) assignees.set(`${c[0]}:${officer()}`, [c[0], null, 'member']);
  await insertMany(conn, 'fredpd_case_assignees', ['case_id', 'citizenid', 'role'],
    [...assignees.entries()].map(([k, v]) => [v[0], k.split(':')[1], v[2]]));

  const subjects = new Map();
  for (const c of cases) for (let k = int(1, 3); k > 0; k--) subjects.set(`${c[0]}:${people[int(0, people.length - 1)][0]}`, c[0]);
  await insertMany(conn, 'fredpd_case_subjects', ['case_id', 'subject_type', 'subject_id', 'role'],
    [...subjects.keys()].map((k) => [Number(k.split(':')[0]), 'person', k.split(':')[1], pick(['suspect', 'victim', 'witness'])]));

  const reports = [];
  let rid = 0;
  for (const c of cases) {
    const count = int(1, 3);
    for (let n = 1; n <= count; n++) {
      rid += 1;
      reports.push([rid, c[0], n, `${c[1]}/${n}`, `Rapport ${n}`, '# Händelse\n- text', 0, c[6], c[7], c[8]]);
    }
  }
  await insertMany(conn, 'fredpd_reports', ['id', 'case_id', 'n', 'report_number', 'title', 'body', 'level', 'author_citizenid', 'updated_at', 'created_at'], reports);

  // Audit: case/report/person/bolo targets, a realistic mix; lookup.person rows within the last hour for OFF00001.
  const audit = [];
  const actions = [['case', 'case.update'], ['case', 'case.assign'], ['report', 'report.save'], ['person', 'lookup.person'],
    ['person', 'lookup.person'], ['vehicle', 'lookup.vehicle'], ['bolo', 'bolo.create'], ['alert', 'alert.assign']];
  for (let i = 0; i < N_AUDIT; i++) {
    const [type, action] = pick(actions);
    const target = type === 'case' ? String(int(1, N_CASES)) : type === 'report' ? String(int(1, rid))
      : type === 'person' ? people[int(0, people.length - 1)][0] : type === 'vehicle' ? plate(int(0, N_VEHICLES - 1)) : String(int(1, 500));
    const recent = i % 200 === 0;
    audit.push([recent ? 'OFF00001' : officer(), action, type, target, JSON.stringify({ label: `x${i}` }), recent ? dt(0, int(0, 3000)) : dt(int(0, 90), int(0, 86399))]);
  }
  await insertMany(conn, 'fredpd_audit', ['actor_citizenid', 'action', 'target_type', 'target_id', 'meta', 'created_at'], audit);

  const alerts = [];
  for (let i = 1; i <= N_ALERTS; i++) {
    const status = i > N_ALERTS - 40 ? pick(['open', 'assigned']) : 'closed';
    alerts.push([i, '10-71', `Larm ${i}`, 'Skottlossning', JSON.stringify({ x: 1, y: 2, z: 3 }), 'Grove Street', int(1, 3), status, dt((N_ALERTS - i) / 20)]);
  }
  await insertMany(conn, 'fredpd_alerts', ['id', 'code', 'title', 'description', 'coords', 'street', 'priority', 'status', 'created_at'], alerts);
  const units = [];
  for (const a of alerts) if (a[7] !== 'open') units.push([a[0], officer(), 'IGV-01']);
  const seen = new Set();
  await insertMany(conn, 'fredpd_alert_units', ['alert_id', 'citizenid', 'callsign'],
    units.filter((u) => (seen.has(`${u[0]}:${u[1]}`) ? false : seen.add(`${u[0]}:${u[1]}`))));

  await conn.query('ANALYZE TABLE fredpd_persons, fredpd_vehicles_idx, fredpd_cases, fredpd_case_assignees, fredpd_case_subjects, fredpd_reports, fredpd_audit, fredpd_alerts, fredpd_alert_units');
  // A heavy-case timeline target: case 1 with many rows.
  const heavy = [];
  for (let i = 0; i < 150; i++) heavy.push([officer(), 'case.update', 'case', '1', JSON.stringify({ label: 'K-1-26' }), dt(0, i * 60)]);
  await insertMany(conn, 'fredpd_audit', ['actor_citizenid', 'action', 'target_type', 'target_id', 'meta', 'created_at'], heavy);
  return { ms: performance.now() - t0, reports: rid, vehicles: N_VEHICLES, alerts: N_ALERTS, subjects: subjects.size, assignees: assignees.size };
}

// ---------------------------------------------------------------------------------------------------------------
// Hot queries (SQL shapes from the Lua resources)

const PERSON_COLS = "p.citizenid, p.firstname, p.lastname, DATE_FORMAT(p.birthdate, '%Y-%m-%d') AS birthdate, p.personnummer";
const PERSON_ORDER = ' ORDER BY p.lastname, p.firstname, p.citizenid';
const iso = (col, alias) => `DATE_FORMAT(${col}, '%Y-%m-%dT%H:%i:%sZ') AS ${alias}`;
const CASE_COLS = 'c.id, c.case_number, c.title, c.status, c.level, c.unit, c.owner_citizenid';
const CASE_ORDER = " ORDER BY (c.status = 'open') DESC, c.updated_at DESC, c.id DESC";
const TIMELINE_EXCLUDE = " AND a.action NOT LIKE 'lookup.%' AND a.action NOT IN ('search', 'share.view', 'report.read')";

function queries(ctx) {
  return [
    { id: 'person.fulltext', label: 'Personsök, namn (FULLTEXT ft_name, "+lars* +nils*")', where: 'fredpd_records search.lua personPage',
      sql: `SELECT ${PERSON_COLS}, COUNT(*) OVER () AS total FROM fredpd_persons p WHERE MATCH (p.firstname, p.lastname) AGAINST (? IN BOOLEAN MODE)${PERSON_ORDER} LIMIT 50 OFFSET 0`,
      params: ['+lars* +nils*'] },
    { id: 'person.fulltext.broad', label: 'Personsök, namn, bred träff ("+and*")', where: 'search.lua personPage',
      sql: `SELECT ${PERSON_COLS}, COUNT(*) OVER () AS total FROM fredpd_persons p WHERE MATCH (p.firstname, p.lastname) AGAINST (? IN BOOLEAN MODE)${PERSON_ORDER} LIMIT 50 OFFSET 0`,
      params: ['+and*'] },
    { id: 'person.shortterm', label: 'Personsök, kort term ("Bo", REGEXP-skanning; värsta fallet)', where: 'search.lua nameWhere (needsLike)',
      sql: `SELECT ${PERSON_COLS}, COUNT(*) OVER () AS total FROM fredpd_persons p WHERE CONCAT_WS(' ', p.firstname, p.lastname) REGEXP ?${PERSON_ORDER} LIMIT 50 OFFSET 0`,
      params: ['(^|[^[:alnum:]])bo'] },
    { id: 'person.personnummer', label: 'Personsök, personnummer', where: 'search.lua searchPersonId',
      sql: `SELECT ${PERSON_COLS}, COUNT(*) OVER () AS total FROM fredpd_persons p WHERE p.personnummer IN (?, ?, ?)${PERSON_ORDER} LIMIT 50 OFFSET 0`,
      params: [ctx.pnr, `19${ctx.pnr}`, `20${ctx.pnr}`] },
    { id: 'vehicle.plate', label: 'Registreringsnummer (fredpd_vehicles_idx PK)', where: 'search.lua VEHICLE_SQL',
      sql: 'SELECT v.plate, v.model, v.citizenid, p.firstname, p.lastname FROM fredpd_vehicles_idx v LEFT JOIN fredpd_persons p ON p.citizenid = v.citizenid WHERE v.plate = ?',
      params: [ctx.plate] },
    { id: 'cases.mine', label: 'Ärendelista "Mina" (ägare ∪ tilldelad)', where: 'cases.lua listCases',
      sql: `SELECT ${CASE_COLS} FROM fredpd_cases c JOIN (SELECT id AS case_id FROM fredpd_cases WHERE owner_citizenid = ? UNION SELECT case_id FROM fredpd_case_assignees WHERE citizenid = ?) m ON m.case_id = c.id${CASE_ORDER} LIMIT 500`,
      params: ['OFF00001', 'OFF00001'] },
    { id: 'cases.open', label: 'Ärendelista "Öppna"', where: 'cases.lua listCases',
      sql: `SELECT ${CASE_COLS} FROM fredpd_cases c WHERE c.status = ?${CASE_ORDER} LIMIT 500`, params: ['open'] },
    { id: 'cases.all.query', label: 'Ärendelista "Alla" + fritext ("stöld")', where: 'cases.lua listCases',
      sql: `SELECT ${CASE_COLS} FROM fredpd_cases c WHERE (c.case_number LIKE ? OR c.title LIKE ?)${CASE_ORDER} LIMIT 500`, params: ['%STÖLD%', '%stöld%'] },
    { id: 'person.cases', label: 'Personsida: ärenden där personen är inblandad', where: 'caserefs (idx_subject)',
      sql: `SELECT ${CASE_COLS}, s.role FROM fredpd_case_subjects s JOIN fredpd_cases c ON c.id = s.case_id WHERE s.subject_type = 'person' AND s.subject_id = ? ORDER BY c.updated_at DESC LIMIT 50`,
      params: [ctx.subject] },
    { id: 'audit.timeline', label: 'Ärendets händelser (audit per target, fall med 150+ rader)', where: 'cases.lua timeline',
      sql: `SELECT a.action, a.actor_citizenid, COALESCE(JSON_VALUE(a.meta, '$.label'), JSON_VALUE(a.meta, '$.tag')) AS label, ${iso('a.created_at', 'at')} FROM fredpd_audit a WHERE ((a.target_type = 'case' AND a.target_id = ?) OR (a.target_type = 'report' AND a.target_id IN (?, ?, ?)))${TIMELINE_EXCLUDE} ORDER BY a.created_at DESC, a.id DESC LIMIT 100`,
      params: ['1', '1', '2', '3'] },
    { id: 'audit.lookupflag', label: 'Obehörig sökning: senaste uppslag (varje personuppslag)', where: 'lookupflag.lua RECENT_SQL',
      sql: "SELECT DISTINCT a.target_id FROM fredpd_audit a WHERE a.actor_citizenid = ? AND a.action = 'lookup.person' AND a.target_type = 'person' AND a.created_at >= ? - INTERVAL ? MINUTE AND NOT EXISTS (SELECT 1 FROM fredpd_case_subjects s JOIN fredpd_cases c ON c.id = s.case_id WHERE s.subject_type = 'person' AND s.subject_id = a.target_id AND (c.owner_citizenid = ? OR EXISTS (SELECT 1 FROM fredpd_case_assignees ca WHERE ca.case_id = c.id AND ca.citizenid = ?))) LIMIT 200",
      params: ['OFF00001', '2026-09-29 12:00:00', 60, 'OFF00001', 'OFF00001'] },
    { id: 'alerts.open.count', label: 'Larm, öppna: antal', where: 'alert_store.lua list',
      sql: "SELECT COUNT(*) FROM fredpd_alerts a WHERE a.status IN ('open', 'assigned')", params: [] },
    { id: 'alerts.open.page', label: 'Larm, öppna: sida 1 (id DESC)', where: 'alert_store.lua list',
      sql: "SELECT a.id FROM fredpd_alerts a WHERE a.status IN ('open', 'assigned') ORDER BY a.id DESC LIMIT 50 OFFSET 0", params: [] },
    { id: 'alerts.mine', label: 'Larm, mina (join alert_units)', where: 'alert_store.lua list',
      sql: "SELECT a.id FROM fredpd_alerts a JOIN fredpd_alert_units u ON u.alert_id = a.id AND u.citizenid = ? WHERE a.status <> 'closed' ORDER BY a.id DESC LIMIT 50 OFFSET 0",
      params: ['OFF00001'] },
  ];
}

// ---------------------------------------------------------------------------------------------------------------
// Measure

const pct = (sorted, p) => sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))];
const r2 = (n) => Math.round(n * 100) / 100;

async function measure(conn, q) {
  const [plan] = await conn.query(`EXPLAIN ${q.sql}`, q.params);
  let rows = 0;
  for (let i = 0; i < 5; i++) rows = (await conn.query(q.sql, q.params))[0].length; // warm-up
  const times = [];
  for (let i = 0; i < RUNS; i++) {
    const t = performance.now();
    await conn.query(q.sql, q.params);
    times.push(performance.now() - t);
  }
  times.sort((a, b) => a - b);
  return {
    id: q.id, label: q.label, where: q.where, rows,
    min: r2(times[0]), median: r2(pct(times, 50)), p95: r2(pct(times, 95)), max: r2(times[times.length - 1]),
    plan: plan.map((p) => ({ table: p.table, type: p.type, key: p.key, rows: p.rows, extra: p.Extra })),
  };
}

function markdown(meta, results) {
  const out = [];
  out.push(`MariaDB ${meta.version}, ${meta.persons} persons, ${meta.vehicles} vehicles, ${meta.cases} cases (${meta.reports} reports, ${meta.subjects} subjects, ${meta.assignees} assignees), ${meta.audit} audit rows, ${meta.alerts} alerts; ${RUNS} runs per query after 5 warm-up runs; client-side round trip over TCP in ms.`, '');
  out.push('| Query | Rows | min | median | p95 | max | Plan (table: type/key) |', '|---|---:|---:|---:|---:|---:|---|');
  for (const r of results) {
    const plan = r.plan.map((p) => `${p.table}: ${p.type}${p.key ? `/${p.key}` : ''}${p.extra ? ` (${p.extra})` : ''}`).join('; ');
    out.push(`| ${r.label} | ${r.rows} | ${r.min} | ${r.median} | ${r.p95} | ${r.max} | ${plan} |`);
  }
  return out.join('\n');
}

async function main() {
  const base = new URL(BASE_URL);
  const admin = await connect(BASE_URL);
  await admin.query(`DROP DATABASE IF EXISTS \`${DB}\``);
  await admin.query(`CREATE DATABASE \`${DB}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_swedish_ci`);
  const [[{ v }]] = await admin.query('SELECT VERSION() AS v');
  const url = new URL(base);
  url.pathname = `/${DB}`;
  try {
    await migrate({ url: url.toString(), seed: true, log: () => {} });
    const conn = await connect(url.toString());
    try {
      const loaded = await load(conn);
      const [[p]] = await conn.query('SELECT personnummer FROM fredpd_persons ORDER BY citizenid LIMIT 1 OFFSET 1234');
      const [[s]] = await conn.query("SELECT subject_id FROM fredpd_case_subjects WHERE subject_type = 'person' LIMIT 1 OFFSET 777");
      const ctx = { pnr: p.personnummer, plate: plate(4321), subject: s.subject_id };
      const results = [];
      for (const q of queries(ctx)) results.push(await measure(conn, q));
      const meta = { version: v, persons: N_PERSONS, vehicles: loaded.vehicles, cases: N_CASES, reports: loaded.reports, subjects: loaded.subjects,
        assignees: loaded.assignees, audit: N_AUDIT + 150, alerts: loaded.alerts, loadMs: Math.round(loaded.ms) };
      if (flag('json')) console.log(JSON.stringify({ meta, results }, null, 2));
      else console.log(markdown(meta, results));
    } finally {
      await conn.end();
    }
  } finally {
    if (!flag('keep')) await admin.query(`DROP DATABASE IF EXISTS \`${DB}\``);
    await admin.end();
  }
}

main().catch((err) => {
  console.error(`[db-perf] ${err.stack ?? err}`);
  process.exit(1);
});
