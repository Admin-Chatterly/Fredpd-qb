// SPDX-License-Identifier: GPL-3.0-only
// Search helpers (task 2.3): client-side type detection for the header chip (the server detects again, §C4), the
// route of each hit and the search input shared by the header and the results page (same query key → one call).
import { detectSearchType } from '@fredpd/types/format';
import type { DetectedSearchType } from '@fredpd/types/format';
import type { LocaleKey } from '@fredpd/types/locale-keys';
import type { CaseRef, MdtInput, SearchHit } from '@fredpd/types/mdt';

/** SearchInputSchema: 2–64 characters after trimming. */
export const SEARCH_MIN_LENGTH = 2;
export const SEARCH_MAX_LENGTH = 64;

export const SEARCH_TYPE_KEYS: Readonly<Record<DetectedSearchType, LocaleKey>> = {
  plate: 'mdt.search.type.plate',
  caseNumber: 'mdt.search.type.caseNumber',
  personId: 'mdt.search.type.personId',
  name: 'mdt.search.type.name',
};

export function cleanQuery(query: string): string {
  return query.trim().slice(0, SEARCH_MAX_LENGTH).trim();
}

/** Detected type of a query (config/formats.json), or null while it is too short or cannot be classified. */
export function detectQueryType(query: string): DetectedSearchType | null {
  const q = cleanQuery(query);
  if (q.length < SEARCH_MIN_LENGTH) return null;
  try {
    return detectSearchType(q).type;
  } catch {
    return null;
  }
}

export function searchInput(query: string, page = 1): MdtInput<'search'> {
  return { query: cleanQuery(query), type: 'auto', page };
}

export function searchPath(query: string, page = 1): string {
  const params = new URLSearchParams({ q: cleanQuery(query) });
  if (page > 1) params.set('page', String(page));
  return `/sok?${params.toString()}`;
}

export const personPath = (citizenid: string) => `/person/${encodeURIComponent(citizenid)}`;
export const vehiclePath = (plate: string) => `/fordon/${encodeURIComponent(plate)}`;

/** Case page of a ref; a kontaktnotis has no id and opens nothing. */
export function caseRefPath(ref: CaseRef): string | null {
  return ref.visibility === 'notice' ? null : `/arende/${ref.id}`;
}

/** Route a hit opens: person → /person/:cid, vehicle → /fordon/:plate, case → /arende/:id (null for a notice). */
export function hitPath(hit: SearchHit): string | null {
  switch (hit.kind) {
    case 'person':
      return personPath(hit.citizenid);
    case 'vehicle':
      return vehiclePath(hit.plate);
    case 'case':
      return caseRefPath(hit.case);
  }
}
