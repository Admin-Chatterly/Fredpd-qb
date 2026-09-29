// SPDX-License-Identifier: GPL-3.0-only
// "Behörigheter" (task 1.8, docs/contracts.md §C10): Discord role × grant matrix. Clicking a cell cycles
// none -> allow -> deny; each role is saved on its own (PUT replaces the role's rows). The save is optimistic: the
// cached rows are replaced at once; if the service refuses, the rows and the admin's unsaved edits come back (and a
// csrf refusal re-reads the session for a fresh token). The page refetches either way.
import { useId, useMemo, useState } from 'react';
import type { FormEvent } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { AdminRoleGrantsPutResponseSchema, AdminRolesResponseSchema } from '@fredpd/types/actions';
import type { AdminRoleGrantsPutBody, AdminRoleGrantsPutResponse, AdminRolesResponse } from '@fredpd/types/actions';
import type { GrantType, RoleGrantRow } from '@fredpd/types/grants';
import {
  Button,
  Card,
  EmptyState,
  IconBan,
  IconButton,
  IconCheck,
  IconClose,
  IconMinus,
  IconPlus,
  Input,
  LEVEL_LOCALE_KEYS,
  MDT_PAGE_LABEL_KEYS,
  PageHeader,
  Spinner,
  cn,
  fieldClass,
  isMdtPageKey,
  useI18n,
} from '@fredpd/ui';
import type { I18n } from '@fredpd/ui';
import { ApiRequestError, apiFetch, errorLocaleKey } from '../api';
import { SESSION_QUERY_KEY, useSession } from '../session';
import {
  NEW_KEY_KINDS,
  RANK_PREFIX,
  buildColumns,
  buildPutBody,
  changeCount,
  cellId,
  cycleCell,
  effectiveEffect,
  parseNewKey,
  replaceRoleRows,
  savedEffects,
  sortRoles,
  withoutRole,
} from '../permissions/matrix';
import type { CellEffect, CellId, ColumnGroup, Drafts, NewKeyKind, RoleEffects } from '../permissions/matrix';

export const ADMIN_ROLES_QUERY_KEY = ['admin', 'roles'] as const;

type AdminRole = AdminRolesResponse['roles'][number];
/** `draft`: the role's unsaved edits being saved, given back to the admin if the save fails. */
type SaveVars = { roleId: string; body: AdminRoleGrantsPutBody; draft: Drafts[string] | undefined };
type SaveContext = { previousRows: RoleGrantRow[] };
type Feedback = { roleId: string; kind: 'saved' | 'error'; text: string };

/** Human label of a grant key (the raw key is always in the cell's title). */
function keyLabel({ t, tx }: I18n, type: GrantType, key: string): string {
  if (key === '*') return t('perms.wildcard');
  switch (type) {
    case 'intel_tier':
      return key === '0' || key === '1' || key === '2' ? t(LEVEL_LOCALE_KEYS[key]) : key;
    case 'unit':
      return tx(`unit.${key}`, undefined, key);
    case 'perm':
      return key.startsWith(RANK_PREFIX) ? `${t('perms.rank')} · ${key.slice(RANK_PREFIX.length)}` : tx(`perms.perm.${key}`, undefined, key);
    case 'tool':
      return tx(`perms.tool.${key}`, undefined, key);
    case 'mdt_page':
      return isMdtPageKey(key) ? t(MDT_PAGE_LABEL_KEYS[key]) : key;
    default:
      return key;
  }
}

const typeLabel = ({ tx }: I18n, type: GrantType) => tx(`perms.type.${type}`, undefined, type);

const EFFECT_LABEL = { none: 'perms.effect.unset', allow: 'perms.effect.allow', deny: 'perms.effect.deny' } as const;

const hexColour = (colour: number) => (colour === 0 ? 'var(--color-line-strong)' : `#${colour.toString(16).padStart(6, '0')}`);

export function PermissionsPage() {
  const i18n = useI18n();
  const { t } = i18n;
  const { csrfToken } = useSession();
  const queryClient = useQueryClient();
  const [drafts, setDrafts] = useState<Drafts>({});
  const [filter, setFilter] = useState('');
  const [pending, setPending] = useState<ReadonlySet<string>>(new Set());
  const [feedback, setFeedback] = useState<Feedback | null>(null);
  // Columns the admin added in this visit; a column stays once a role has a saved row in it.
  const [addedKeys, setAddedKeys] = useState<readonly CellId[]>([]);

  const query = useQuery({
    queryKey: ADMIN_ROLES_QUERY_KEY,
    queryFn: () => apiFetch('/api/admin/roles', { schema: AdminRolesResponseSchema }),
  });

  const save = useMutation<AdminRoleGrantsPutResponse, unknown, SaveVars, SaveContext>({
    mutationFn: ({ roleId, body }) =>
      apiFetch(`/api/admin/roles/${encodeURIComponent(roleId)}/grants`, {
        method: 'PUT',
        body,
        csrfToken,
        schema: AdminRoleGrantsPutResponseSchema,
      }),
    onMutate: async ({ roleId, body }) => {
      setPending((p) => new Set(p).add(roleId));
      setFeedback(null);
      // An in-flight refetch must not overwrite the optimistic rows.
      await queryClient.cancelQueries({ queryKey: ADMIN_ROLES_QUERY_KEY });
      const previous = queryClient.getQueryData<AdminRolesResponse>(ADMIN_ROLES_QUERY_KEY);
      const previousRows = previous?.grants.filter((g) => g.discordRoleId === roleId) ?? [];
      queryClient.setQueryData<AdminRolesResponse>(ADMIN_ROLES_QUERY_KEY, (old) => old && replaceRoleRows(old, roleId, body.grants));
      setDrafts((d) => withoutRole(d, roleId));
      return { previousRows };
    },
    onError: (error, { roleId, draft }, context) => {
      // Rollback: the role's rows as they were before the save, and the unsaved edits on top of them again, so the
      // admin can retry instead of redoing every click (cells are locked while saving, so nothing newer is lost).
      queryClient.setQueryData<AdminRolesResponse>(ADMIN_ROLES_QUERY_KEY, (old) => old && replaceRoleRows(old, roleId, context?.previousRows ?? []));
      if (draft) setDrafts((d) => ({ ...d, [roleId]: draft }));
      // A stale CSRF token would fail every retry: re-read the session, which brings a fresh one. errors.csrf says
      // to reload the page (which would drop the restored edits), so this case says to save again instead.
      const csrf = error instanceof ApiRequestError && error.code === 'csrf';
      if (csrf) void queryClient.invalidateQueries({ queryKey: SESSION_QUERY_KEY });
      const text = csrf ? t('perms.csrfRetry') : t(errorLocaleKey(error));
      setFeedback({ roleId, kind: 'error', text });
    },
    onSuccess: (result, { roleId }) => {
      setFeedback({ roleId, kind: 'saved', text: t('perms.saved', { count: result.recomputed }) });
    },
    onSettled: (_data, _error, { roleId }) => {
      setPending((p) => {
        const next = new Set(p);
        next.delete(roleId);
        return next;
      });
      void queryClient.invalidateQueries({ queryKey: ADMIN_ROLES_QUERY_KEY });
    },
  });

  const data = query.data;
  const columns = useMemo(() => (data ? buildColumns(data.catalog, data.grants, addedKeys) : []), [data, addedKeys]);
  const roles = useMemo(() => {
    if (!data) return [];
    const needle = filter.trim().toLocaleLowerCase('sv');
    return sortRoles(data.roles).filter((r) => needle === '' || r.name.toLocaleLowerCase('sv').includes(needle));
  }, [data, filter]);

  if (query.isPending) {
    return (
      <div className="flex justify-center p-10">
        <Spinner size="lg" />
      </div>
    );
  }
  if (!data) {
    return (
      <EmptyState
        title={t(errorLocaleKey(query.error))}
        action={
          <Button onClick={() => void query.refetch()}>{t('common.retry')}</Button>
        }
      />
    );
  }

  const feedbackRole = feedback ? data.roles.find((r) => r.discordRoleId === feedback.roleId) : undefined;

  return (
    <div className="flex min-h-0 flex-col">
      <PageHeader title={t('perms.title')} subtitle={t('perms.intro')} />
      <div className="mb-3 flex flex-wrap items-center gap-3">
        <Input
          className="max-w-xs"
          type="search"
          value={filter}
          onChange={(e) => setFilter(e.target.value)}
          placeholder={t('perms.filter')}
          aria-label={t('perms.filter')}
        />
        <AddKeyForm i18n={i18n} onAdd={(id) => setAddedKeys((keys) => (keys.includes(id) ? keys : [...keys, id]))} />
        <p role="status" aria-live="polite" className={cn('text-sm', feedback?.kind === 'error' ? 'text-danger' : 'text-success')}>
          {feedback && feedbackRole ? `${feedbackRole.name} · ${feedback.text}` : null}
        </p>
      </div>
      {data.roles.length === 0 ? (
        <Card padded={false}>
          <EmptyState title={t('perms.noRoles')} />
        </Card>
      ) : (
        <Card padded={false} className="min-h-0">
          <Matrix
            i18n={i18n}
            roles={roles}
            columns={columns}
            grants={data.grants}
            drafts={drafts}
            pending={pending}
            onCycle={(roleId, id, saved) => setDrafts((d) => cycleCell(d, roleId, id, saved))}
            onDiscard={(roleId) => setDrafts((d) => withoutRole(d, roleId))}
            onSave={(roleId, saved) => save.mutate({ roleId, body: buildPutBody(saved, drafts[roleId]), draft: drafts[roleId] })}
          />
        </Card>
      )}
    </div>
  );
}

const newKindLabel = (i18n: I18n, kind: NewKeyKind) => (kind === 'rank' ? i18n.t('perms.rank') : typeLabel(i18n, kind));

/**
 * Adds a column the catalog does not list (a weapon, vehicle or armory item, a rank, a new unit…). The column is
 * local until a role is saved with Tillåt or Neka in it; the key is checked like the service checks the PUT body.
 */
function AddKeyForm({ i18n, onAdd }: { i18n: I18n; onAdd: (id: CellId) => void }) {
  const { t } = i18n;
  const errorId = useId();
  const [kind, setKind] = useState<NewKeyKind>('weapon');
  const [value, setValue] = useState('');
  const [invalid, setInvalid] = useState(false);

  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const id = parseNewKey(kind, value);
    setInvalid(id === null);
    if (id === null) return;
    onAdd(id);
    setValue('');
  };

  return (
    <form data-add-key="" onSubmit={submit} aria-label={t('perms.addKey')} className="flex flex-wrap items-center gap-2">
      <select
        aria-label={t('common.type')}
        value={kind}
        onChange={(e) => setKind(e.target.value as NewKeyKind)}
        className={fieldClass}
      >
        {NEW_KEY_KINDS.map((k) => (
          <option key={k} value={k}>
            {newKindLabel(i18n, k)}
          </option>
        ))}
      </select>
      <Input
        className="max-w-52"
        value={value}
        invalid={invalid}
        aria-describedby={invalid ? errorId : undefined}
        onChange={(e) => {
          setValue(e.target.value);
          setInvalid(false);
        }}
        placeholder={t('perms.newKey')}
        aria-label={t('perms.newKey')}
        spellCheck={false}
        autoComplete="off"
      />
      <Button type="submit" icon={<IconPlus />}>
        {t('common.add')}
      </Button>
      {invalid && (
        <p id={errorId} className="text-sm text-danger">
          {t('errors.validation')}
        </p>
      )}
    </form>
  );
}

interface MatrixProps {
  i18n: I18n;
  roles: AdminRole[];
  columns: ColumnGroup[];
  grants: RoleGrantRow[];
  drafts: Drafts;
  pending: ReadonlySet<string>;
  onCycle: (roleId: string, id: CellId, saved: RoleEffects) => void;
  onDiscard: (roleId: string) => void;
  onSave: (roleId: string, saved: RoleEffects) => void;
}

const CELL_STYLE: Record<CellEffect, string> = {
  none: 'text-subtle hover:bg-raised',
  allow: 'bg-success/15 text-success hover:bg-success/25',
  deny: 'bg-danger/15 text-danger hover:bg-danger/25',
};

const CELL_ICON: Record<CellEffect, typeof IconCheck> = { none: IconMinus, allow: IconCheck, deny: IconBan };

function Matrix({ i18n, roles, columns, grants, drafts, pending, onCycle, onDiscard, onSave }: MatrixProps) {
  const { t } = i18n;
  return (
    <div className="max-h-[calc(100vh-14rem)] overflow-auto">
      <table className="border-separate border-spacing-0 text-sm">
        <thead className="sticky top-0 z-20 bg-surface">
          <tr>
            <th rowSpan={2} scope="col" className="sticky left-0 z-30 min-w-64 border-r border-b border-line bg-surface px-3 py-2 text-left font-medium text-muted">
              {t('perms.role')}
            </th>
            {columns.map((group) => (
              <th key={group.type} colSpan={group.keys.length} scope="colgroup" className="border-r border-b border-line px-2 py-1.5 text-left text-xs font-semibold whitespace-nowrap text-fg">
                {typeLabel(i18n, group.type)}
              </th>
            ))}
          </tr>
          <tr>
            {columns.flatMap((group) =>
              group.keys.map((key, i) => (
                <th
                  key={cellId(group.type, key)}
                  scope="col"
                  title={cellId(group.type, key)}
                  className={cn('h-28 border-b border-line px-1 align-bottom text-xs font-normal text-muted', i === group.keys.length - 1 && 'border-r')}
                >
                  <span className="inline-block max-h-26 truncate [writing-mode:vertical-rl] rotate-180">{keyLabel(i18n, group.type, key)}</span>
                </th>
              )),
            )}
          </tr>
        </thead>
        <tbody>
          {roles.map((role) => {
            const saved = savedEffects(grants, role.discordRoleId);
            const draft = drafts[role.discordRoleId];
            const changes = changeCount(drafts, role.discordRoleId);
            const busy = pending.has(role.discordRoleId);
            return (
              <tr key={role.discordRoleId} data-role={role.discordRoleId} className={cn(role.deleted && 'opacity-60')}>
                <th scope="row" className="sticky left-0 z-10 border-r border-b border-line bg-surface px-3 py-1.5 text-left font-normal">
                  <div className="flex items-center gap-2">
                    <span aria-hidden="true" className="size-2.5 shrink-0 rounded-full" style={{ background: hexColour(role.colour) }} />
                    <span className="min-w-0 flex-1 truncate font-medium text-fg" title={role.name}>
                      {role.name}
                    </span>
                    {busy && <Spinner size="sm" />}
                    {changes > 0 && !busy && (
                      <>
                        <Button size="sm" variant="primary" onClick={() => onSave(role.discordRoleId, saved)}>
                          {t('perms.save')}
                        </Button>
                        <IconButton size="sm" label={t('common.discardChanges')} icon={<IconClose size={14} />} onClick={() => onDiscard(role.discordRoleId)} />
                      </>
                    )}
                  </div>
                  {(changes > 0 || role.deleted) && (
                    <p className="mt-0.5 text-xs text-muted">{changes > 0 ? t('perms.unsaved', { count: changes }) : t('perms.roleDeleted')}</p>
                  )}
                </th>
                {columns.flatMap((group) =>
                  group.keys.map((key, i) => {
                    const id = cellId(group.type, key);
                    const effect = effectiveEffect(saved, draft, id);
                    const dirty = draft?.[id] !== undefined;
                    const Icon = CELL_ICON[effect];
                    const label = `${role.name} · ${typeLabel(i18n, group.type)} · ${keyLabel(i18n, group.type, key)} · ${t(EFFECT_LABEL[effect])}`;
                    return (
                      <td key={id} className={cn('border-b border-line p-0.5', i === group.keys.length - 1 && 'border-r')}>
                        <button
                          type="button"
                          data-cell={id}
                          data-effect={effect}
                          data-dirty={dirty || undefined}
                          aria-label={label}
                          title={label}
                          disabled={busy}
                          onClick={() => onCycle(role.discordRoleId, id, saved)}
                          className={cn(
                            'flex size-8 items-center justify-center rounded-sm disabled:opacity-50',
                            CELL_STYLE[effect],
                            dirty && 'ring-2 ring-accent-text ring-inset',
                          )}
                        >
                          <Icon size={15} />
                        </button>
                      </td>
                    );
                  }),
                )}
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
