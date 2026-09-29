// SPDX-License-Identifier: GPL-3.0-only
// Underrättelser → Objekt (task 5b.2): entity search (searchEntities) and the list-first entity page (getEntity):
// visible links newest first, the number of hidden links as a plain count (never described), the reports behind the
// visible links (meta only), and a kontaktnotis per insats the viewer may not see. Tabs: Kopplingar | Nätverk (the
// graph, lazy). Add a link in three clicks: "Lägg till koppling" → pick the other entity (or create it) → pick the
// link type, which sends addLink.
import { Suspense, lazy, useState } from 'react';
import { Link, useParams } from 'react-router';
import type { Entity } from '@fredpd/types/intel';
import type { Level } from '@fredpd/types/mdt';
import { Badge, Button, Card, EmptyState, IconPlus, Label, Notice, PageHeader, SearchInput, Tabs, fieldClass, useI18n } from '@fredpd/ui';
import { useMdtMutation, useMdtQuery } from '../../api/hooks';
import { parseId } from '../../cases';
import { Callout, PageSpinner, QueryView } from '../../components/Common';
import { LevelSelect, MutationError } from '../../components/Fields';
import { fmtDateTime, noticeOwner, officerLabel } from '../../format';
import { ENTITY_TYPE_KEYS, LINK_TYPES, entityPath, intelReportPath, linkTypeLabel } from '../../intel';
import { PERMS, usePerm } from '../../perms';
import { useSession } from '../../tablet/TabletContext';

const GraphView = lazy(() => import('./GraphView'));

const FREE_ENTITY_TYPES = ['group', 'location'] as const;

function EntityLabel({ entity }: { entity: Entity }) {
  const { t } = useI18n();
  return (
    <span className="flex min-w-0 items-center gap-2">
      <span className="shrink-0 text-xs text-muted">{t(ENTITY_TYPE_KEYS[entity.type])}</span>
      <span className="truncate">{entity.label}</span>
    </span>
  );
}

/** Search box + results; `onPick` makes rows buttons, otherwise they link to the entity page. */
export function EntitySearch({ onPick, autoFocus = false }: { onPick?: (e: Entity) => void; autoFocus?: boolean }) {
  const { t, tx } = useI18n();
  const [text, setText] = useState('');
  const [query, setQuery] = useState('');
  const results = useMdtQuery('searchEntities', { query }, { enabled: query.length >= 2 });
  return (
    <div className="flex flex-col gap-2">
      <SearchInput
        value={text}
        autoFocus={autoFocus}
        onValueChange={setText}
        onSubmit={(q) => setQuery(q.trim().slice(0, 64))}
        placeholder={tx('intel.entity.search')}
        aria-label={tx('intel.entity.search')}
      />
      {query.length >= 2 && (
        <QueryView query={results}>
          {(data) =>
            data.items.length === 0 ? (
              <p className="text-sm text-muted">{t('mdt.search.noResults', { query })}</p>
            ) : (
              <ul className="flex max-h-72 flex-col overflow-y-auto rounded-md border border-line" data-entity-results>
                {data.items.map((e) => (
                  <li key={e.id}>
                    {onPick ? (
                      <button type="button" data-entity={e.id} className="flex w-full px-3 py-2 text-left text-sm hover:bg-raised" onClick={() => onPick(e)}>
                        <EntityLabel entity={e} />
                      </button>
                    ) : (
                      <Link to={entityPath(e.id)} className="flex px-3 py-2 text-sm hover:bg-raised">
                        <EntityLabel entity={e} />
                      </Link>
                    )}
                  </li>
                ))}
              </ul>
            )
          }
        </QueryView>
      )}
    </div>
  );
}

export function EntitiesPage() {
  const { t } = useI18n();
  return (
    <Card title={t('intel.section.entities')}>
      <EntitySearch />
    </Card>
  );
}

type LinkTarget = { id: number; label: string } | { type: Entity['type']; label: string };

/** The 3-click flow: (1) open, (2) pick or create the other end, (3) pick the type → addLink. */
function AddLinkFlow({ from, onDone }: { from: Entity; onDone: () => void }) {
  const { t, tx } = useI18n();
  const i18n = useI18n();
  const { grants } = useSession();
  const [target, setTarget] = useState<LinkTarget | null>(null);
  // Keyed entities (person, vehicle, case) are found by search; free-text ones can be created here.
  const [newType, setNewType] = useState<'group' | 'location'>('group');
  const [newLabel, setNewLabel] = useState('');
  const [confidence, setConfidence] = useState(50);
  const [level, setLevel] = useState<Level>(Math.min(1, grants.tier) as Level);
  const add = useMdtMutation('addLink', { onSuccess: onDone });

  const send = (type: string) => {
    if (!target) return;
    add.mutate({
      fromId: from.id,
      to: 'id' in target ? { id: target.id } : { type: target.type, label: target.label },
      type,
      confidence,
      level,
    });
  };

  return (
    <div className="flex flex-col gap-3" data-add-link>
      <p className="text-sm">
        <span className="text-muted">{t('intel.link.from')}:</span> {from.label}
      </p>
      {!target ? (
        <>
          <p className="text-sm text-muted">{t('intel.link.to')}</p>
          <EntitySearch autoFocus onPick={(e) => (e.id === from.id ? undefined : setTarget({ id: e.id, label: e.label }))} />
          <div className="flex flex-wrap items-end gap-2 border-t border-line pt-3">
            <Label className="w-36">
              {t('common.type')}
              <select className={fieldClass} value={newType} onChange={(e) => setNewType(e.target.value as 'group' | 'location')}>
                {FREE_ENTITY_TYPES.map((x) => (
                  <option key={x} value={x}>
                    {t(ENTITY_TYPE_KEYS[x])}
                  </option>
                ))}
              </select>
            </Label>
            <Label className="min-w-40 flex-1">
              {t('common.name')}
              <input className={fieldClass} value={newLabel} maxLength={128} onChange={(e) => setNewLabel(e.target.value)} />
            </Label>
            <Button size="sm" disabled={newLabel.trim().length === 0} onClick={() => setTarget({ type: newType, label: newLabel.trim() })}>
              {tx('intel.entity.create')}
            </Button>
          </div>
        </>
      ) : (
        <>
          <p className="text-sm">
            <span className="text-muted">{t('intel.link.to')}:</span> {target.label}{' '}
            <button type="button" className="text-accent-text hover:underline" onClick={() => setTarget(null)}>
              {t('common.edit')}
            </button>
          </p>
          <div className="grid grid-cols-2 gap-3">
            <Label>
              {t('intel.link.confidence')} ({confidence} %)
              <input type="range" min={0} max={100} step={5} value={confidence} onChange={(e) => setConfidence(Number(e.target.value))} />
            </Label>
            <LevelSelect value={level} onChange={setLevel} tier={grants.tier} />
          </div>
          <p className="text-sm text-muted">{t('intel.link.typeLabel')}</p>
          <div className="flex flex-wrap gap-2" data-link-types>
            {LINK_TYPES.map((type) => (
              <Button key={type} size="sm" data-link-type={type} disabled={add.isPending} onClick={() => send(type)}>
                {linkTypeLabel(i18n, type)}
              </Button>
            ))}
          </div>
        </>
      )}
      <MutationError error={add.error} />
    </div>
  );
}

type EntityTab = 'links' | 'graph';

export function EntityPage() {
  const i18n = useI18n();
  const { t, tx } = i18n;
  const id = parseId(useParams().id);
  const canRead = usePerm(PERMS.intelRead);
  const [tab, setTab] = useState<EntityTab>('links');
  const [adding, setAdding] = useState(false);
  const [added, setAdded] = useState(false);
  const query = useMdtQuery('getEntity', { id: id ?? 0 }, { enabled: id !== null });
  if (id === null) return <EmptyState title={t('errors.notFound')} />;

  return (
    <QueryView query={query}>
      {(detail) => (
        <div data-entity-page={detail.entity.id}>
          <PageHeader
            title={detail.entity.label}
            subtitle={
              <span className="flex items-center gap-2">
                {t(ENTITY_TYPE_KEYS[detail.entity.type])}
                {detail.entity.ref && detail.entity.ref !== detail.entity.label && <span className="font-mono">{detail.entity.ref}</span>}
              </span>
            }
            actions={
              canRead && (
                <Button icon={<IconPlus size={16} />} onClick={() => setAdding((v) => !v)} aria-expanded={adding}>
                  {t('intel.link.add')}
                </Button>
              )
            }
          />
          {detail.notices.length > 0 && (
            <div className="mb-4 flex flex-col gap-2" data-entity-notices>
              {detail.notices.map((n, i) => (
                <Notice key={i} subject={detail.entity.label} owner={noticeOwner(i18n, n.contact)} />
              ))}
            </div>
          )}
          {added && (
            <Callout tone="success" className="mb-3">
              {t('intel.link.added')}
            </Callout>
          )}
          {adding && (
            <Card className="mb-4" title={t('intel.link.add')}>
              <AddLinkFlow
                from={detail.entity}
                onDone={() => {
                  setAdding(false);
                  setAdded(true);
                }}
              />
            </Card>
          )}
          <Tabs
            className="mb-3"
            label={t('intel.title')}
            value={tab}
            onChange={setTab}
            items={[
              { id: 'links', label: tx('intel.section.links'), count: detail.links.length },
              ...(canRead ? [{ id: 'graph' as const, label: t('intel.section.graph') }] : []),
            ]}
          />
          {tab === 'graph' && canRead ? (
            <Suspense fallback={<PageSpinner />}>
              <GraphView entityId={detail.entity.id} />
            </Suspense>
          ) : (
            <div className="grid gap-4 xl:grid-cols-[minmax(0,2fr)_minmax(0,1fr)]">
              <Card padded={false} title={tx('intel.section.links')}>
                {detail.hiddenLinks > 0 && (
                  <p className="border-b border-line px-4 py-2 text-sm text-muted" data-hidden-links={detail.hiddenLinks}>
                    {tx('intel.entity.hiddenLinks', { count: detail.hiddenLinks })}
                  </p>
                )}
                {detail.links.length === 0 ? (
                  <EmptyState title={t('common.empty')} />
                ) : (
                  <ul className="flex flex-col divide-y divide-line">
                    {detail.links.map((l) => {
                      const other = l.from.id === detail.entity.id ? l.to : l.from;
                      return (
                        <li key={l.id} data-link={l.id} className="flex flex-wrap items-center gap-2 px-4 py-2 text-sm">
                          <span className="text-muted">{linkTypeLabel(i18n, l.type)}</span>
                          <Link to={entityPath(other.id)} className="min-w-0 flex-1 text-accent-text hover:underline">
                            <EntityLabel entity={other} />
                          </Link>
                          <span className="text-xs text-muted">{l.confidence} %</span>
                          {l.level > 0 && <Badge level={l.level} />}
                          {l.reportId !== null && (
                            <Link to={intelReportPath(l.reportId)} className="text-xs text-accent-text hover:underline">
                              #{l.reportId}
                            </Link>
                          )}
                          <span className="w-full text-xs text-muted">
                            {l.createdBy ? `${officerLabel(l.createdBy)} · ` : ''}
                            {fmtDateTime(i18n, l.createdAt)}
                          </span>
                        </li>
                      );
                    })}
                  </ul>
                )}
              </Card>
              <Card padded={false} title={t('intel.section.reports')}>
                {detail.reports.length === 0 ? (
                  <EmptyState title={t('intel.none')} />
                ) : (
                  <ul className="flex flex-col divide-y divide-line">
                    {detail.reports.map((r) => (
                      <li key={r.id}>
                        <Link to={intelReportPath(r.id)} className="flex items-center gap-2 px-4 py-2 text-sm hover:bg-raised">
                          <span className="font-mono">#{r.id}</span>
                          {r.level > 0 && <Badge level={r.level} />}
                          <span className="flex-1 text-xs text-muted">{r.author ? officerLabel(r.author) : null}</span>
                          <span className="text-xs text-muted">{fmtDateTime(i18n, r.createdAt)}</span>
                        </Link>
                      </li>
                    ))}
                  </ul>
                )}
              </Card>
            </div>
          )}
        </div>
      )}
    </QueryView>
  );
}
