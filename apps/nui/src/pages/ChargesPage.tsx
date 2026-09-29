// SPDX-License-Identifier: GPL-3.0-only
// Brottskatalog (/brottskatalog, task 5.4): the read-only catalogue from one listCharges call (it is small and
// cached for the session's staleTime), searched as you type on the client (code, title, lagrum; every word must
// match) and filtered by påföljd, in a virtualised list so the whole catalogue costs a screenful of rows.
import { useMemo, useState } from 'react';
import type { Charge } from '@fredpd/types/records';
import { Badge, Card, EmptyState, PageHeader, SearchInput, Tabs, VirtualList, useI18n } from '@fredpd/ui';
import { useMdtQuery } from '../api/hooks';
import { CHARGE_CLASSES, CHARGE_CLASS_KEYS, CHARGE_CLASS_TONES, categoryLabel, filterCharges } from '../charges';
import type { ChargeClass } from '../charges';
import { QueryView } from '../components/Common';
import { fmtCurrency } from '../format';

export const CHARGE_ROW_HEIGHT = 56;

function ChargeRow({ charge }: { charge: Charge }) {
  const i18n = useI18n();
  const { t } = i18n;
  return (
    <div data-charge={charge.code} className="flex h-14 items-center gap-3 border-b border-line px-4 text-sm">
      <span className="w-20 shrink-0 font-mono text-xs text-muted">{charge.code}</span>
      <span className="min-w-0 flex-1">
        <span className="block truncate text-fg">{charge.title}</span>
        <span className="block truncate text-xs text-muted">
          {charge.lawRef} · {categoryLabel(i18n, charge.category)}
        </span>
      </span>
      <Badge tone={CHARGE_CLASS_TONES[charge.class]}>{t(CHARGE_CLASS_KEYS[charge.class])}</Badge>
      <span className="w-24 shrink-0 text-right">{charge.fine > 0 ? fmtCurrency(charge.fine) : null}</span>
      <span className="w-20 shrink-0 text-right text-muted">{charge.jailMinutes > 0 ? t('time.duration.minutes', { count: charge.jailMinutes }) : null}</span>
    </div>
  );
}

export function ChargesPage() {
  const { t } = useI18n();
  const [query, setQuery] = useState('');
  const [cls, setCls] = useState<ChargeClass | 'all'>('all');
  const list = useMdtQuery('listCharges', {});
  const items = list.data?.items;
  const shown = useMemo(() => filterCharges(items ?? [], query, cls === 'all' ? null : cls), [items, query, cls]);
  const getKey = useMemo(() => (c: Charge) => c.code, []);

  return (
    <>
      <PageHeader title={t('charge.title')} subtitle={items ? t('common.results', { count: shown.length }) : undefined} />
      <div className="mb-3 flex flex-wrap items-center gap-3">
        <SearchInput className="w-80" value={query} onValueChange={setQuery} onSubmit={setQuery} placeholder={t('charge.search')} aria-label={t('charge.search')} />
        <Tabs
          label={t('charge.field.class')}
          value={cls}
          onChange={setCls}
          items={[{ id: 'all' as const, label: t('common.all') }, ...CHARGE_CLASSES.map((c) => ({ id: c, label: t(CHARGE_CLASS_KEYS[c]) }))]}
        />
      </div>
      <Card padded={false}>
        <QueryView query={list}>
          {() =>
            shown.length === 0 ? (
              <EmptyState title={query.trim() ? t('charge.noResults', { query: query.trim() }) : t('common.empty')} />
            ) : (
              <VirtualList items={shown} estimateSize={CHARGE_ROW_HEIGHT} getKey={getKey} renderItem={(c) => <ChargeRow charge={c} />} label={t('charge.title')} className="h-[62vh]" />
            )
          }
        </QueryView>
      </Card>
    </>
  );
}
