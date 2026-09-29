// SPDX-License-Identifier: GPL-3.0-only
// Character picker (IMPLEMENTATION.md §5.9 "Character selection on login"; portal action contract, task 7.1).
// GET /api/characters → the logged-in Discord user's characters (the service reads fredpd_identities +
// fredpd_persons, only characters whose license matches the user's linked license rows); POST /api/session/character
// { citizenid } stores the pick in the server-side session. The MDT pages act as that character; the portal never
// sends a citizenid as the actor afterwards. A new pick drops every cached MDT answer of the previous one.
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Button, Card, EmptyState, IconUsers, PageHeader, Spinner, useI18n } from '@fredpd/ui';
import { CitizenIdSchema } from '@fredpd/types/actions';
import { apiFetch, errorLocaleKey } from './api';
import type { Parser } from './api';
import { SESSION_QUERY_KEY, useSession } from './session';
import type { PortalSession } from './session';
import { fmtDate } from './mdt/shared';

export interface Character {
  citizenid: string;
  name: string;
  /** Optional: when the character last played (ISO UTC), if the service sends it. */
  lastSeen: string | null;
}

export const CHARACTERS_QUERY_KEY = ['characters'] as const;

/** `[{ citizenid, name, lastSeen? }]`; entries that do not fit are dropped (never shown half). */
export const CharactersParser: Parser<Character[]> = {
  parse(data: unknown): Character[] {
    if (!Array.isArray(data)) throw new Error('characters: not a list');
    const out: Character[] = [];
    for (const row of data as unknown[]) {
      if (typeof row !== 'object' || row === null) continue;
      const { citizenid, name, lastSeen } = row as Record<string, unknown>;
      if (!CitizenIdSchema.safeParse(citizenid).success || typeof name !== 'string') continue;
      out.push({ citizenid: citizenid as string, name, lastSeen: typeof lastSeen === 'string' ? lastSeen : null });
    }
    return out;
  },
};

const AnyBody: Parser<unknown> = { parse: (d) => d };

export function useCharacters(enabled = true) {
  return useQuery({ queryKey: CHARACTERS_QUERY_KEY, queryFn: () => apiFetch('/api/characters', { schema: CharactersParser }), enabled });
}

export function useSelectCharacter(onDone?: () => void) {
  const queryClient = useQueryClient();
  const { csrfToken } = useSession();
  return useMutation({
    mutationFn: (citizenid: string) =>
      apiFetch('/api/session/character', { method: 'POST', body: { citizenid }, csrfToken, schema: AnyBody }).then(() => citizenid),
    onSuccess: (citizenid) => {
      // The previous character's records must not show under the new one.
      // Keep only the session and the character list; every other cache (MDT answers, the portal's live alert and
      // unit lists) belongs to the previous character.
      const keep = new Set<unknown>([SESSION_QUERY_KEY[0], CHARACTERS_QUERY_KEY[0]]);
      queryClient.removeQueries({ predicate: (q) => !keep.has(q.queryKey[0]) });
      queryClient.setQueryData<PortalSession>(SESSION_QUERY_KEY, (s) => (s?.user ? { ...s, user: { ...s.user, citizenid } } : s));
      void queryClient.invalidateQueries({ queryKey: SESSION_QUERY_KEY });
      onDone?.();
    },
    // A stale CSRF token: re-read the session so the next click carries a fresh one.
    onError: () => void queryClient.invalidateQueries({ queryKey: SESSION_QUERY_KEY }),
  });
}

export function CharacterPicker({ onDone }: { onDone?: () => void }) {
  const { t } = useI18n();
  const { user } = useSession();
  const characters = useCharacters();
  const select = useSelectCharacter(onDone);

  return (
    <div data-character-picker className="mx-auto flex max-w-xl flex-col gap-3">
      <PageHeader title={t('portal.character.title')} />
      {select.isError && (
        <p role="alert" className="rounded-md border border-danger/40 bg-danger/10 px-3 py-2 text-sm text-danger">
          {t(errorLocaleKey(select.error))}
        </p>
      )}
      <Card padded={false}>
        {characters.isPending ? (
          <div className="flex justify-center py-8">
            <Spinner size="lg" />
          </div>
        ) : characters.isError ? (
          <EmptyState
            title={t(errorLocaleKey(characters.error))}
            action={
              <Button size="sm" onClick={() => void characters.refetch()}>
                {t('common.retry')}
              </Button>
            }
          />
        ) : characters.data.length === 0 ? (
          <EmptyState icon={<IconUsers size={28} />} title={t('portal.character.none')} />
        ) : (
          <ul className="flex flex-col divide-y divide-line">
            {characters.data.map((c) => (
              <li key={c.citizenid} data-character={c.citizenid} className="flex items-center gap-3 px-4 py-3">
                <div className="min-w-0 flex-1">
                  <p className="truncate font-medium text-fg">{c.name}</p>
                  {c.lastSeen && (
                    <p className="text-xs text-muted">{t('portal.character.lastSeen', { date: fmtDate(c.lastSeen) })}</p>
                  )}
                </div>
                <Button
                  variant={user?.citizenid === c.citizenid ? 'secondary' : 'primary'}
                  size="sm"
                  loading={select.isPending && select.variables === c.citizenid}
                  disabled={select.isPending}
                  onClick={() => select.mutate(c.citizenid)}
                >
                  {t('portal.character.select', { name: c.name })}
                </Button>
              </li>
            ))}
          </ul>
        )}
      </Card>
    </div>
  );
}
