// SPDX-License-Identifier: GPL-3.0-only
// POI-blad (IMPLEMENTATION.md §5.3: one `PoiSheet` component for the NUI and the portal; the portal prints it with
// its print CSS and renders it on the public share page). Presentational only: it renders exactly the fields it is
// given, so a masked or shared sheet can only show what the caller (and before it the server) let through. Missing
// fields are left out, never shown as placeholders.
import type { ReactNode } from 'react';
import type { IntelTier } from '@fredpd/types/grants';
import { cn } from '../cn';
import { useI18n } from '../i18n';
import { Badge } from './Badge';

export const POI_WARNINGS = ['armed', 'violent', 'flight_risk', 'gang'] as const;
export type PoiWarning = (typeof POI_WARNINGS)[number];

export interface PoiSheetData {
  name: string;
  /** Left out on the share page (a link never carries the citizenid). */
  citizenid?: string | null;
  level: IntelTier;
  status: 'open' | 'closed';
  summary: string | null;
  warnings: readonly string[];
  photoUrl: string | null;
  /** "Handläggare": the owning officer's label; absent on masked/shared sheets. */
  handler?: string | null;
  /** Already formatted (the caller owns the date format). */
  updatedAt?: string | null;
}

export interface PoiSheetProps {
  data: PoiSheetData;
  /** Masked view: a banner says parts are hidden. */
  masked?: boolean;
  /** Print footer ("Utskrivet … av …"), rendered below the sheet. */
  footer?: ReactNode;
  className?: string;
}

/** Only the four known warning keys are rendered (anything else in the data is dropped). */
export const knownWarnings = (warnings: readonly string[]): PoiWarning[] =>
  POI_WARNINGS.filter((w) => warnings.includes(w));

export function PoiSheet({ data, masked = false, footer, className }: PoiSheetProps) {
  const { t } = useI18n();
  const warnings = knownWarnings(data.warnings);
  return (
    <article data-poi-sheet className={cn('poi-sheet flex flex-col gap-4 rounded-lg border border-line bg-surface p-5', className)}>
      <header className="flex flex-wrap items-start gap-4">
        {data.photoUrl && <img src={data.photoUrl} alt="" className="h-28 w-24 rounded-md border border-line object-cover" />}
        <div className="flex min-w-0 flex-1 flex-col gap-1">
          <p className="text-xs tracking-wide text-muted uppercase">{t('poi.title')}</p>
          <h2 data-poi-name className="text-xl font-semibold text-fg">
            {data.name}
          </h2>
          {data.citizenid && <p className="font-mono text-sm text-muted">{data.citizenid}</p>}
          <div className="flex flex-wrap items-center gap-2">
            <Badge level={data.level} />
            <Badge>{t(data.status === 'open' ? 'case.status.open' : 'case.status.closed')}</Badge>
          </div>
        </div>
        <p className="text-xs font-medium text-danger">{t('poi.confidential')}</p>
      </header>
      {masked && (
        <p data-poi-masked className="rounded-md border border-warning/40 bg-warning/10 px-3 py-2 text-sm text-warning">
          {t('visibility.masked.badge')}
        </p>
      )}
      {warnings.length > 0 && (
        <section>
          <h3 className="mb-1 text-sm font-semibold text-fg">{t('poi.section.officerSafety')}</h3>
          <ul className="flex flex-wrap gap-2">
            {warnings.map((w) => (
              <li key={w}>
                <Badge tone="danger">{t(`poi.warning.${w}`)}</Badge>
              </li>
            ))}
          </ul>
        </section>
      )}
      {data.summary && (
        <section>
          <h3 className="mb-1 text-sm font-semibold text-fg">{t('poi.section.summary')}</h3>
          <p data-poi-summary className="text-sm whitespace-pre-line text-fg">
            {data.summary}
          </p>
        </section>
      )}
      {(data.handler || data.updatedAt) && (
        <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
          {data.handler && (
            <>
              <dt className="text-muted">{t('poi.handler')}</dt>
              <dd className="text-fg">{data.handler}</dd>
            </>
          )}
          {data.updatedAt && (
            <>
              <dt className="text-muted">{t('common.updatedAt')}</dt>
              <dd className="text-fg">{data.updatedAt}</dd>
            </>
          )}
        </dl>
      )}
      {footer && <footer className="border-t border-line pt-2 text-xs text-muted">{footer}</footer>}
    </article>
  );
}
