// SPDX-License-Identifier: GPL-3.0-only
// Actions the portal needs that are not in packages/types' registries yet: POI sheet, release requests
// (Utlämningskö, the public "Begär ut allmän handling" form) and the share view. Their wire shapes are the ones
// fredpd_records already answers (docs/modules/records.md "POI", "Share links", "Release requests"; proposed zod in
// resources/[fredpd]/fredpd_records/test/proposed.ts). Integration request (docs/modules/portal.md): once
// packages/types carries them, these readers give way to the zod schemas and TABLET_ACTIONS' typed hooks.
//
// The readers accept Lua's wire (absent = null, `{}` for an empty list) and return null when the answer does not
// have the shape; they copy only the fields listed here, so an unexpected extra field never reaches the DOM.
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import type { UseMutationResult, UseQueryResult } from '@tanstack/react-query';
import type { MdtTransport } from '@fredpd/ui';
import type { IntelTier } from '@fredpd/types/grants';
import { MdtClientError, isRetryable, readErrorResponse, toMdtClientError, useTransport } from './shared';

// ---------------------------------------------------------------------------------------------------------------
// Small readers

type Rec = Record<string, unknown>;
const isRec = (v: unknown): v is Rec => typeof v === 'object' && v !== null && !Array.isArray(v);
const str = (v: unknown): string | undefined => (typeof v === 'string' ? v : undefined);
const nstr = (v: unknown): string | null | undefined => (v === undefined || v === null ? null : typeof v === 'string' ? v : undefined);

/** The service's upload path (fredpd_records' photoInput stores only files under it). */
export const UPLOAD_PATH = '/upload/';

/**
 * A POI photo is shown only as one of our own uploads, loaded from the portal's own origin: a path under /upload/,
 * or an http(s) URL whose path is under /upload/ (fredpd_records stores the service base, which may be a loopback
 * or other host; only its /upload/<file> path is kept). Anything else becomes null and no <img> is rendered, so an
 * anonymous share viewer's browser never contacts a third-party host (which would learn its IP and viewing time).
 */
export function safePhotoUrl(v: string | null): string | null {
  if (!v) return null;
  let path: string;
  if (v.startsWith(UPLOAD_PATH)) {
    path = v;
  } else {
    let u: URL;
    try {
      u = new URL(v);
    } catch {
      return null;
    }
    if (u.protocol !== 'https:' && u.protocol !== 'http:') return null;
    path = u.pathname;
  }
  const file = path.slice(UPLOAD_PATH.length);
  return path.startsWith(UPLOAD_PATH) && /^[A-Za-z0-9_-]+\.[A-Za-z0-9]+$/.test(file) ? UPLOAD_PATH + file : null;
}
const int = (v: unknown): number | undefined => (typeof v === 'number' && Number.isInteger(v) ? v : undefined);
const level = (v: unknown): IntelTier | undefined => (v === 0 || v === 1 || v === 2 ? v : undefined);
/** A list; Lua sends an empty one as `{}`. */
const list = (v: unknown): unknown[] | undefined => (Array.isArray(v) ? v : v === undefined || v === null || (isRec(v) && Object.keys(v).length === 0) ? [] : undefined);
const oneOf = <T extends string>(v: unknown, values: readonly T[]): T | undefined => (values.includes(v as T) ? (v as T) : undefined);

export interface OfficerLabelRef {
  displayName: string;
  callsign: string | null;
}

function officer(v: unknown): OfficerLabelRef | null | undefined {
  if (v === undefined || v === null) return null;
  if (!isRec(v)) return undefined;
  const displayName = str(v.displayName);
  const callsign = nstr(v.callsign);
  if (displayName === undefined || callsign === undefined) return undefined;
  return { displayName, callsign };
}

// ---------------------------------------------------------------------------------------------------------------
// POI (getPoi)

export interface PoiContent {
  visibility: 'full' | 'masked';
  level: IntelTier;
  status: 'open' | 'closed';
  summary: string | null;
  warnings: string[];
  photoUrl: string | null;
  owner: OfficerLabelRef | null;
  updatedAt: string | null;
}
export type PoiSheetView = PoiContent | { visibility: 'notice'; contact: { displayName: string | null; unit: string | null } };
export interface PoiView {
  citizenid: string;
  name: string;
  poi: PoiSheetView | null;
}

export function readPoiView(v: unknown): PoiView | null {
  if (!isRec(v)) return null;
  const citizenid = str(v.citizenid);
  const name = str(v.name);
  if (citizenid === undefined || name === undefined) return null;
  if (v.poi === undefined || v.poi === null) return { citizenid, name, poi: null };
  const p = v.poi;
  if (!isRec(p)) return null;
  if (p.visibility === 'notice') {
    const c = isRec(p.contact) ? p.contact : {};
    const displayName = nstr(c.displayName);
    const unit = nstr(c.unit);
    if (displayName === undefined || unit === undefined) return null;
    return { citizenid, name, poi: { visibility: 'notice', contact: { displayName, unit } } };
  }
  const visibility = oneOf(p.visibility, ['full', 'masked'] as const);
  const lvl = level(p.level);
  const status = oneOf(p.status, ['open', 'closed'] as const);
  const summary = nstr(p.summary);
  const warnings = list(p.warnings)?.filter((w): w is string => typeof w === 'string');
  const rawPhoto = nstr(p.photoUrl);
  const photoUrl = rawPhoto === undefined ? undefined : safePhotoUrl(rawPhoto);
  const owner = officer(p.owner);
  const updatedAt = nstr(p.updatedAt);
  if (!visibility || lvl === undefined || !status || summary === undefined || !warnings || photoUrl === undefined || owner === undefined || updatedAt === undefined) return null;
  return { citizenid, name, poi: { visibility, level: lvl, status, summary, warnings, photoUrl, owner, updatedAt } };
}

// ---------------------------------------------------------------------------------------------------------------
// Released / shared content

export interface ReleasedReport {
  reportNumber: string;
  title: string;
  body: string;
  createdAt: string;
}
export type ReleasedContent =
  | { type: 'case'; caseNumber: string; status: 'open' | 'closed'; title: string; summary: string | null; createdAt: string; closedAt: string | null; reports: ReleasedReport[] }
  | { type: 'report'; caseNumber: string; reportNumber: string; title: string; body: string; createdAt: string };

function readReport(v: unknown): ReleasedReport | null {
  if (!isRec(v)) return null;
  const reportNumber = str(v.reportNumber);
  const title = str(v.title);
  const body = str(v.body);
  const createdAt = str(v.createdAt);
  return reportNumber !== undefined && title !== undefined && body !== undefined && createdAt !== undefined ? { reportNumber, title, body, createdAt } : null;
}

export function readReleasedContent(v: unknown): ReleasedContent | null {
  if (!isRec(v)) return null;
  const caseNumber = str(v.caseNumber);
  const title = str(v.title);
  const createdAt = str(v.createdAt);
  if (caseNumber === undefined || title === undefined || createdAt === undefined) return null;
  if (v.type === 'case') {
    const status = oneOf(v.status, ['open', 'closed'] as const);
    const summary = nstr(v.summary);
    const closedAt = nstr(v.closedAt);
    const reports = list(v.reports)?.map(readReport);
    if (!status || summary === undefined || closedAt === undefined || !reports || reports.some((r) => r === null)) return null;
    return { type: 'case', caseNumber, status, title, summary, createdAt, closedAt, reports: reports as ReleasedReport[] };
  }
  if (v.type === 'report') {
    const reportNumber = str(v.reportNumber);
    const body = str(v.body);
    if (reportNumber === undefined || body === undefined) return null;
    return { type: 'report', caseNumber, reportNumber, title, body, createdAt };
  }
  return null;
}

/** POI content of a share link (server/shares.lua `content`): no citizenid, no officers. */
export interface SharedPoi {
  type: 'poi';
  name: string;
  level: IntelTier;
  status: 'open' | 'closed';
  summary: string | null;
  warnings: string[];
  photoUrl: string | null;
  updatedAt: string | null;
}

export interface ShareView {
  targetType: 'poi' | 'case' | 'report';
  expiresAt: string;
  /** null: the target is above the link's level now (or gone). */
  content: SharedPoi | ReleasedContent | null;
}

function readSharedPoi(v: Rec): SharedPoi | null {
  const name = str(v.name);
  const lvl = level(v.level);
  const status = oneOf(v.status, ['open', 'closed'] as const);
  const summary = nstr(v.summary);
  const warnings = list(v.warnings)?.filter((w): w is string => typeof w === 'string');
  const rawPhoto = nstr(v.photoUrl);
  const photoUrl = rawPhoto === undefined ? undefined : safePhotoUrl(rawPhoto);
  const updatedAt = nstr(v.updatedAt);
  if (name === undefined || lvl === undefined || !status || summary === undefined || !warnings || photoUrl === undefined || updatedAt === undefined) return null;
  return { type: 'poi', name, level: lvl, status, summary, warnings, photoUrl, updatedAt };
}

export function readShareView(v: unknown): ShareView | null {
  if (!isRec(v)) return null;
  const targetType = oneOf(v.targetType, ['poi', 'case', 'report'] as const);
  const expiresAt = str(v.expiresAt);
  if (!targetType || expiresAt === undefined) return null;
  if (v.content === undefined || v.content === null) return { targetType, expiresAt, content: null };
  if (!isRec(v.content)) return null;
  const content = v.content.type === 'poi' ? readSharedPoi(v.content) : readReleasedContent(v.content);
  return content ? { targetType, expiresAt, content } : null;
}

// ---------------------------------------------------------------------------------------------------------------
// Release requests (listReleaseRequests / decideReleaseRequest / createReleaseRequest)

export const RELEASE_STATUSES = ['pending', 'approved', 'partial', 'denied'] as const;
export type ReleaseStatus = (typeof RELEASE_STATUSES)[number];

export interface ReleaseRequest {
  id: number;
  status: ReleaseStatus;
  requesterName: string | null;
  description: string;
  target: { type: string; id: string; label: string | null } | null;
  createdAt: string;
  decidedAt: string | null;
  decidedBy: OfficerLabelRef | null;
  decisionNote: string | null;
  released: ReleasedContent | null;
}

export function readReleaseRequest(v: unknown): ReleaseRequest | null {
  if (!isRec(v)) return null;
  const id = int(v.id);
  const status = oneOf(v.status, RELEASE_STATUSES);
  const requesterName = nstr(v.requesterName);
  const description = str(v.description);
  const createdAt = str(v.createdAt);
  const decidedAt = nstr(v.decidedAt);
  const decidedBy = officer(v.decidedBy);
  const decisionNote = nstr(v.decisionNote);
  let target: ReleaseRequest['target'] | undefined = null;
  if (v.target !== undefined && v.target !== null) {
    const tt = isRec(v.target) ? v.target : {};
    const type = str(tt.type);
    const tid = typeof tt.id === 'number' ? String(tt.id) : str(tt.id);
    const label = nstr(tt.label);
    target = type !== undefined && tid !== undefined && label !== undefined ? { type, id: tid, label } : undefined;
  }
  const released = v.released === undefined || v.released === null ? null : readReleasedContent(v.released);
  if (id === undefined || !status || requesterName === undefined || description === undefined || createdAt === undefined || decidedAt === undefined) return null;
  if (decidedBy === undefined || decisionNote === undefined || target === undefined) return null;
  if (released === null && v.released !== undefined && v.released !== null) return null;
  return { id, status, requesterName, description, target, createdAt, decidedAt, decidedBy, decisionNote, released };
}

export interface ReleaseList {
  items: ReleaseRequest[];
  total: number;
  page: number;
}

export function readReleaseList(v: unknown): ReleaseList | null {
  if (!isRec(v)) return null;
  const items = list(v.items)?.map(readReleaseRequest);
  const total = int(v.total);
  const page = int(v.page);
  if (!items || items.some((i) => i === null) || total === undefined || page === undefined) return null;
  return { items: items as ReleaseRequest[], total, page };
}

/** createReleaseRequest answers the stored request id (records.md); anything object-shaped counts as received. */
export const readReceived = (v: unknown): { ok: true } | null => (isRec(v) ? { ok: true } : null);

// ---------------------------------------------------------------------------------------------------------------
// Calls

export type Reader<T> = (value: unknown) => T | null;

export const EXTRA_ACTIONS = ['getPoi', 'listReleaseRequests', 'decideReleaseRequest', 'createReleaseRequest', 'createShare'] as const;
export type ExtraAction = (typeof EXTRA_ACTIONS)[number];

/** Like callMdt: `{ error }` → MdtClientError, transport failures → network, a wrong shape → unknown/contract. */
export async function callExtra<T>(transport: MdtTransport, action: ExtraAction, input: unknown, read: Reader<T>): Promise<T> {
  let raw: unknown;
  try {
    raw = await transport.call(action, input ?? {});
  } catch (err) {
    throw toMdtClientError(action, err);
  }
  const error = readErrorResponse(action, raw);
  if (error) throw error;
  const value = read(raw);
  if (value === null) {
    console.error(`[fredpd] ${action}: the answer does not have the expected shape`, raw);
    throw new MdtClientError(action, 'unknown', 'contract');
  }
  return value;
}

export function useExtraQuery<T>(action: ExtraAction, input: unknown, read: Reader<T>, enabled = true): UseQueryResult<T, MdtClientError> {
  const transport = useTransport();
  return useQuery<T, MdtClientError>({
    queryKey: ['mdt', action, input],
    queryFn: () => callExtra(transport, action, input, read),
    enabled,
    retry: (count, error) => count < 1 && isRetryable(error),
    retryDelay: 600,
  });
}

export function useExtraMutation<I, T>(
  action: ExtraAction,
  read: Reader<T>,
  options: { invalidates?: readonly ExtraAction[]; onSuccess?: (data: T, input: I) => void } = {},
): UseMutationResult<T, MdtClientError, I> {
  const transport = useTransport();
  const queryClient = useQueryClient();
  return useMutation<T, MdtClientError, I>({
    mutationFn: (input) => callExtra(transport, action, input, read),
    onSuccess: (data, input) => {
      for (const a of options.invalidates ?? []) void queryClient.invalidateQueries({ queryKey: ['mdt', a] });
      options.onSuccess?.(data, input);
    },
  });
}

export interface ShareCreated {
  id: number;
  path: string;
  expiresAt: string;
}

/** createShare answer; the token itself is only used through `path` and never stored by the portal. */
export function readShareCreated(v: unknown): ShareCreated | null {
  if (!isRec(v)) return null;
  const id = int(v.id);
  const path = str(v.path);
  const expiresAt = str(v.expiresAt);
  return id !== undefined && path !== undefined && path.startsWith('/share/') && expiresAt !== undefined ? { id, path, expiresAt } : null;
}
