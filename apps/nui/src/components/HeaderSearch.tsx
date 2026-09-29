// SPDX-License-Identifier: GPL-3.0-only
// Header search (task 2.3, IMPLEMENTATION.md §5.2): a chip shows the type detected from config/formats.json while
// typing; Enter runs the search and opens the top hit directly (person → /person/:cid, vehicle → /fordon/:plate,
// case → /arende/:id). With no openable top hit (no hits, a kontaktnotis, an error, a too-short query) Enter shows
// the results page instead. Shift+Enter and "Visa alla" always show the results page (/sok, keyboard navigable).
// The results page asks with the same input, so opening it after Enter reuses the cached answer.
import { useState } from 'react';
import type { KeyboardEvent } from 'react';
import { useNavigate } from 'react-router';
import { useQueryClient } from '@tanstack/react-query';
import { Badge, Button, SearchInput, Spinner, useI18n } from '@fredpd/ui';
import { mdtQueryOptions } from '../api/hooks';
import { SEARCH_MIN_LENGTH, SEARCH_TYPE_KEYS, cleanQuery, detectQueryType, hitPath, searchInput, searchPath } from '../search';

export function HeaderSearch() {
  const { t } = useI18n();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const [query, setQuery] = useState('');
  const [pending, setPending] = useState(false);
  const detected = detectQueryType(query);

  const showResults = (q: string) => void navigate(searchPath(q));

  const openTopHit = async (raw: string) => {
    const q = cleanQuery(raw);
    if (q.length < SEARCH_MIN_LENGTH) {
      showResults(q);
      return;
    }
    const input = searchInput(q);
    setPending(true);
    try {
      const result = await queryClient.fetchQuery(mdtQueryOptions('search', input));
      const top = result.hits[0];
      const path = top ? hitPath(top) : null;
      void navigate(path ?? searchPath(q));
    } catch {
      // The results page shows the error (and can retry).
      showResults(q);
    } finally {
      setPending(false);
    }
  };

  const onKeyDown = (e: KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter' && e.shiftKey && query.trim() !== '') {
      e.preventDefault();
      showResults(query);
    }
  };

  return (
    <div className="flex w-full max-w-2xl min-w-0 items-center gap-2">
      <SearchInput
        className="min-w-0 flex-1"
        value={query}
        onValueChange={setQuery}
        onSubmit={(q) => void openTopHit(q)}
        onKeyDown={onKeyDown}
        placeholder={t('mdt.search.placeholder')}
        aria-label={t('common.search')}
        aria-busy={pending || undefined}
        title={t('mdt.search.hint')}
      />
      {pending && <Spinner size="sm" label={t('mdt.search.searching')} />}
      {detected && (
        <span data-search-type={detected} title={t('mdt.search.detected', { type: t(SEARCH_TYPE_KEYS[detected]) })}>
          <Badge tone="accent">{t(SEARCH_TYPE_KEYS[detected])}</Badge>
        </span>
      )}
      {query.trim() !== '' && (
        <Button size="sm" variant="ghost" onClick={() => showResults(query)}>
          {t('common.showAll')}
        </Button>
      )}
    </div>
  );
}
