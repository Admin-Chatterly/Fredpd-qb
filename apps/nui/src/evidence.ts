// SPDX-License-Identifier: GPL-3.0-only
// Bevis helpers (docs/contracts.md §C16, docs/modules/forensics.md): type labels, the chain-of-custody line of each
// entry, and the analysis result fields the page shows. `result` is whatever fredpd_forensics' whitelist let
// through; a person match is present only when the viewer may see it (full view of the linked case).
import type { CustodyEntry, EvidenceItem } from '@fredpd/types/evidence';
import type { I18n } from '@fredpd/ui';
import { officerLabel } from './format';

export function evidenceTypeLabel(i18n: Pick<I18n, 'tx'>, type: string): string {
  return i18n.tx(`evidence.type.${type}`, undefined, type);
}

/**
 * One chain entry as text (evidence.chain.*). A `transfer` without a location is a hand-over between officers
 * (forensics.md request 10); `link` names the case number when known.
 */
export function custodyText(i18n: Pick<I18n, 't' | 'tx'>, entry: CustodyEntry, item: Pick<EvidenceItem, 'caseNumber'>): string {
  const name = entry.actor ? officerLabel(entry.actor) : i18n.t('common.unknown');
  const location = entry.location ?? '';
  switch (entry.action) {
    case 'collect':
      return i18n.t('evidence.chain.collected', { name });
    case 'handin':
      return i18n.t('evidence.chain.handedIn', { name });
    case 'analyse':
      return i18n.t('evidence.chain.analysed', { name });
    case 'link':
      return i18n.t('evidence.chain.linked', { name, number: item.caseNumber ?? '' });
    case 'checkout':
      return i18n.t('evidence.chain.checkedOut', { name, location });
    case 'return':
      return i18n.t('evidence.chain.returned', { name, location });
    case 'transfer':
      return entry.location ? i18n.t('evidence.chain.transferred', { name, location }) : i18n.t('evidence.chain.handedOver', { name });
  }
}

/** The person match of an analysis result, when the server included one. */
export function resultMatch(result: EvidenceItem['result']): { citizenid: string; name: string } | null {
  const match = result?.match;
  if (typeof match !== 'object' || match === null) return null;
  const { citizenid, name } = match as Record<string, unknown>;
  return typeof citizenid === 'string' && typeof name === 'string' ? { citizenid, name } : null;
}

/** Plain result fields to list (strings and numbers; match and nested values are shown separately or not at all). */
export function resultFields(result: EvidenceItem['result']): [string, string][] {
  if (!result) return [];
  return Object.entries(result)
    .filter(([key, v]) => key !== 'match' && (typeof v === 'string' || typeof v === 'number') && v !== '')
    .map(([key, v]) => [key, String(v)]);
}

export const isAnalysed = (item: EvidenceItem) => item.result !== null || item.chain.some((c) => c.action === 'analyse');
