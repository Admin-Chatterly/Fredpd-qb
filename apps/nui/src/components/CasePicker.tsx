// SPDX-License-Identifier: GPL-3.0-only
// Case picker: search listCases (number or title, Enter searches) and pick a case the viewer sees (full or masked;
// kontaktnotis rows cannot be picked and show only the Notice). Used to link evidence and to filter the Bevis list.
import { useState } from 'react';
import type { CaseRef } from '@fredpd/types/mdt';
import { SearchInput, useI18n } from '@fredpd/ui';
import { useMdtQuery } from '../api/hooks';
import { useErrorText } from '../api/errors';
import { CaseNotice, CaseRefSummary } from './CaseRefs';

export type PickedCase = Exclude<CaseRef, { visibility: 'notice' }>;

export function CasePicker({ onPick, onlyOpen = false, label }: { onPick: (c: PickedCase) => void; onlyOpen?: boolean; label?: string }) {
  const { t, tx } = useI18n();
  const errorText = useErrorText();
  const [text, setText] = useState('');
  const [query, setQuery] = useState('');
  const list = useMdtQuery('listCases', { filter: onlyOpen ? 'open' : 'all', query, page: 1 }, { enabled: query.length >= 2 });
  const placeholder = label ?? tx('case.search');
  return (
    <div className="flex flex-col gap-2" data-case-picker>
      <SearchInput value={text} onValueChange={setText} onSubmit={(q) => setQuery(q.trim().slice(0, 64))} placeholder={placeholder} aria-label={placeholder} />
      {list.isFetching && <p className="text-sm text-muted">{t('mdt.search.searching')}</p>}
      {list.isError && <p className="text-sm text-danger">{errorText(list.error)}</p>}
      {list.isSuccess && list.data.items.length === 0 && <p className="text-sm text-muted">{t('mdt.search.noResults', { query })}</p>}
      {list.isSuccess && list.data.items.length > 0 && (
        <ul className="flex max-h-56 flex-col overflow-y-auto rounded-md border border-line">
          {list.data.items.slice(0, 10).map((ref, i) =>
            ref.visibility === 'notice' ? (
              <li key={`notice-${i}`} className="p-1">
                <CaseNotice contact={ref.contact} subject={t('case.notice.subject')} />
              </li>
            ) : (
              <li key={ref.id}>
                <button type="button" className="flex w-full px-3 py-2 text-left hover:bg-raised focus-visible:bg-raised" onClick={() => onPick(ref)}>
                  <CaseRefSummary caseRef={ref} />
                </button>
              </li>
            ),
          )}
        </ul>
      )}
    </div>
  );
}
