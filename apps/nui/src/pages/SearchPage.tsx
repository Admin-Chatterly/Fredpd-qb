// SPDX-License-Identifier: GPL-3.0-only
// Search results (/sok?q=…&page=…, task 2.3): the server's detected type, the hit count, and a virtualised,
// keyboard-navigable list (↑/↓ select, Enter opens, a click opens; Esc closes the tablet as everywhere). Persons
// and vehicles show the BOLO flag; a case the viewer may only know exists (kontaktnotis) is a notice row that
// opens nothing. 50 hits per page (PAGE_SIZE), server-side.
import { useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router';
import { PAGE_SIZE } from '@fredpd/types/mdt';
import type { SearchHit, SearchOutput } from '@fredpd/types/mdt';
import { Badge, Card, EmptyState, PageHeader, Pagination, VirtualListbox, cn, useI18n } from '@fredpd/ui';
import { useMdtQuery } from '../api/hooks';
import { QueryView } from '../components/Common';
import { CaseNotice, CaseRefSummary } from '../components/CaseRefs';
import { SEARCH_MIN_LENGTH, SEARCH_TYPE_KEYS, cleanQuery, hitPath, searchInput, searchPath } from '../search';

export const SEARCH_ROW_HEIGHT = 64;

function readPage(value: string | null): number {
  const n = Number(value);
  return Number.isInteger(n) && n >= 1 && n <= 10_000 ? n : 1;
}

function hitKey(hit: SearchHit, index: number): string {
  switch (hit.kind) {
    case 'person':
      return `p:${hit.citizenid}`;
    case 'vehicle':
      return `v:${hit.plate}`;
    case 'case':
      return hit.case.visibility === 'notice' ? `n:${index}` : `c:${hit.case.id}`;
  }
}

function HitRow({ hit, subject, active }: { hit: SearchHit; subject: string; active: boolean }) {
  const { t } = useI18n();
  const base = cn('flex h-full items-center gap-3 border-b border-line px-3', active ? 'bg-accent-soft' : 'hover:bg-raised');
  switch (hit.kind) {
    case 'person':
      return (
        <div className={cn(base, 'cursor-pointer')} data-hit="person">
          <div className="min-w-0 flex-1">
            <p className="truncate font-medium text-fg">{hit.name}</p>
            <p className="truncate font-mono text-xs text-muted">{hit.personnummer ?? hit.birthdate ?? ''}</p>
          </div>
          <span className="text-xs text-subtle">{t('bolo.kind.person')}</span>
          {hit.bolo && <Badge tone="danger">{t('person.wanted')}</Badge>}
        </div>
      );
    case 'vehicle':
      return (
        <div className={cn(base, 'cursor-pointer')} data-hit="vehicle">
          <div className="min-w-0 flex-1">
            <p className="truncate font-mono font-semibold text-fg">{hit.plate}</p>
            <p className="truncate text-xs text-muted">{[hit.model, hit.ownerName].filter(Boolean).join(' · ')}</p>
          </div>
          <span className="text-xs text-subtle">{t('bolo.kind.vehicle')}</span>
          {hit.bolo && <Badge tone="danger">{t('vehicle.wanted')}</Badge>}
        </div>
      );
    case 'case':
      // Kontaktnotis: only the Notice (subject = the case number searched for), never openable.
      if (hit.case.visibility === 'notice') {
        return (
          <div className={cn('flex h-full items-center border-b border-line px-3', active && 'bg-accent-soft')} data-hit="notice">
            <div className="w-full">
              <CaseNotice contact={hit.case.contact} subject={subject} />
            </div>
          </div>
        );
      }
      return (
        <div className={cn(base, 'cursor-pointer')} data-hit="case">
          <CaseRefSummary caseRef={hit.case} />
        </div>
      );
  }
}

export function SearchResults({ data, query, onOpen }: { data: SearchOutput; query: string; onOpen: (path: string) => void }) {
  const { t } = useI18n();
  const [active, setActive] = useState(0);
  if (data.hits.length === 0) return <EmptyState title={t('mdt.search.noResults', { query })} description={t('mdt.search.logged')} />;
  return (
    <VirtualListbox
      items={data.hits}
      rowHeight={SEARCH_ROW_HEIGHT}
      getKey={hitKey}
      label={t('mdt.search.title')}
      activeIndex={Math.min(active, data.hits.length - 1)}
      onActiveIndexChange={setActive}
      isDisabled={(hit) => hitPath(hit) === null}
      onActivate={(hit) => {
        const path = hitPath(hit);
        if (path) onOpen(path);
      }}
      autoFocus
      className="max-h-[32rem]"
      renderItem={(hit, _index, isActive) => <HitRow hit={hit} subject={data.normalized || query} active={isActive} />}
    />
  );
}

export function SearchPage() {
  const { t } = useI18n();
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const q = cleanQuery(params.get('q') ?? '');
  const page = readPage(params.get('page'));
  const valid = q.length >= SEARCH_MIN_LENGTH;
  const search = useMdtQuery('search', searchInput(q, page), { enabled: valid, keepPrevious: true });
  const data = search.data;

  const subtitle = data ? (
    <span className="flex flex-wrap items-center gap-2">
      <Badge tone="accent">{t(SEARCH_TYPE_KEYS[data.detected])}</Badge>
      <span>{t('common.results', { count: data.total })}</span>
      <span className="text-subtle">{t('mdt.search.keys')}</span>
    </span>
  ) : (
    q || t('mdt.search.hint')
  );

  return (
    <>
      <PageHeader title={t('mdt.search.title')} subtitle={subtitle} />
      <Card padded={false}>
        {!valid ? (
          <EmptyState title={t('mdt.search.tooShort', { min: SEARCH_MIN_LENGTH })} description={t('mdt.search.hint')} />
        ) : (
          <QueryView query={search}>
            {(result) => <SearchResults key={`${q}|${result.page}`} data={result} query={q} onOpen={(path) => void navigate(path)} />}
          </QueryView>
        )}
        {data && (
          <Pagination
            page={data.page}
            total={data.total}
            pageSize={PAGE_SIZE}
            disabled={search.isFetching}
            onPageChange={(next) => void navigate(searchPath(q, next))}
          />
        )}
      </Card>
      <p className="mt-2 text-xs text-subtle">{t('mdt.search.logged')}</p>
    </>
  );
}
