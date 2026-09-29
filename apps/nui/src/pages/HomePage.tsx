// SPDX-License-Identifier: GPL-3.0-only
// Hem (task 2.7): one getHome call (HomeOutput). The layout depends on the variant: the primary unit's
// config/units.json `home` (known at once, so the page does not jump), else the server's `variant`, else
// `default`. Each variant orders the count cards (the first one is emphasised) and the blocks differently;
// Ledning also gets the roster. Cards and blocks are shown only with their mdt_page grant. Hem is not lazy: it is
// the first paint after open (§5.2 acceptance, < 300 ms).
import { Link } from 'react-router';
import type { HomeOutput } from '@fredpd/types/mdt';
import type { GrantLists } from '@fredpd/types/grants';
import type { LocaleKey } from '@fredpd/types/locale-keys';
import { Badge, Card, EmptyState, PageHeader, Spinner, Table, cn, useI18n } from '@fredpd/ui';
import type { MdtPageKey, TableColumn } from '@fredpd/ui';
import { useMdtQuery } from '../api/hooks';
import { BoloList } from '../components/Bolos';
import { CaseRefList } from '../components/CaseRefs';
import { ErrorState } from '../components/Common';
import { unitLabel } from '../format';
import { canSeePage } from '../nav';
import { useSession } from '../tablet/TabletContext';
import { homeVariantFor } from '../units';
import type { HomeVariant } from '../units';

export type HomeStat = 'activeBolos' | 'myOpenCases' | 'onDuty';
export type HomeBlock = 'recentBolos' | 'myCases' | 'roster';

export interface HomeLayout {
  /** Count cards in order; the first is emphasised. */
  stats: readonly HomeStat[];
  blocks: readonly HomeBlock[];
}

export const HOME_LAYOUTS: Readonly<Record<HomeVariant, HomeLayout>> = {
  igv: { stats: ['activeBolos', 'onDuty', 'myOpenCases'], blocks: ['recentBolos', 'myCases'] },
  span: { stats: ['activeBolos', 'myOpenCases', 'onDuty'], blocks: ['recentBolos', 'myCases'] },
  utredning: { stats: ['myOpenCases', 'activeBolos', 'onDuty'], blocks: ['myCases', 'recentBolos'] },
  tekniker: { stats: ['myOpenCases', 'onDuty', 'activeBolos'], blocks: ['myCases', 'recentBolos'] },
  ledning: { stats: ['onDuty', 'activeBolos', 'myOpenCases'], blocks: ['roster', 'recentBolos', 'myCases'] },
  default: { stats: ['activeBolos', 'myOpenCases', 'onDuty'], blocks: ['recentBolos', 'myCases'] },
};

/** Grant each card/block needs (null = always). */
const STAT_PAGES: Readonly<Record<HomeStat, MdtPageKey | null>> = { activeBolos: 'bolos', myOpenCases: 'cases', onDuty: null };
const BLOCK_PAGES: Readonly<Record<HomeBlock, MdtPageKey>> = { recentBolos: 'bolos', myCases: 'cases', roster: 'roster' };
/** Where a count card leads, and the page that route needs. */
const STAT_LINKS: Readonly<Record<HomeStat, { to: string; page: MdtPageKey }>> = {
  activeBolos: { to: '/efterlysning', page: 'bolos' },
  myOpenCases: { to: '/arenden', page: 'cases' },
  onDuty: { to: '/register', page: 'roster' },
};

const STAT_LABELS: Readonly<Record<HomeStat, LocaleKey>> = {
  activeBolos: 'home.activeBolos',
  myOpenCases: 'home.myOpenCases',
  onDuty: 'officer.onDuty',
};

const BLOCK_TITLES: Readonly<Record<HomeBlock, LocaleKey>> = {
  recentBolos: 'home.activeBolos',
  myCases: 'home.myCases',
  roster: 'officer.roster',
};

/** Unit variant first (instant, follows a grants push), then what the server chose, then `default`. */
export function selectHomeVariant(unit: string | null | undefined, serverVariant?: HomeOutput['variant'] | null): HomeVariant {
  const fromUnit = homeVariantFor(unit);
  if (fromUnit !== 'default') return fromUnit;
  return serverVariant ?? 'default';
}

/** The variant's layout without the cards and blocks the grants do not allow. */
export function homeLayoutFor(variant: HomeVariant, grants: GrantLists | null | undefined): HomeLayout {
  const layout = HOME_LAYOUTS[variant];
  return {
    stats: layout.stats.filter((s) => canSeePage(grants, STAT_PAGES[s])),
    blocks: layout.blocks.filter((b) => canSeePage(grants, BLOCK_PAGES[b])),
  };
}

function StatCard({ stat, value, emphasis, to }: { stat: HomeStat; value: number | null; emphasis: boolean; to: string | null }) {
  const { t } = useI18n();
  const body = (
    <>
      <span className={cn('text-3xl font-semibold tabular-nums', emphasis ? 'text-accent-text' : 'text-fg')}>{value === null ? <Spinner size="sm" /> : value}</span>
      <span className="text-sm text-muted">{t(STAT_LABELS[stat])}</span>
    </>
  );
  const className = cn(
    'flex flex-col gap-1 rounded-lg border px-4 py-3',
    emphasis ? 'border-accent/60 bg-accent-soft' : 'border-line bg-surface',
    to && 'hover:border-line-strong',
  );
  return to ? (
    <Link to={to} data-stat={stat} data-emphasis={emphasis || undefined} className={className}>
      {body}
    </Link>
  ) : (
    <div data-stat={stat} data-emphasis={emphasis || undefined} className={className}>
      {body}
    </div>
  );
}

type RosterRow = HomeOutput['roster'][number];

function Roster({ roster }: { roster: HomeOutput['roster'] }) {
  const i18n = useI18n();
  const { t } = i18n;
  const columns: TableColumn<RosterRow>[] = [
    { id: 'callsign', header: t('officer.callsign'), cell: (o) => (o.callsign ? <span className="font-mono">{o.callsign}</span> : null), className: 'whitespace-nowrap' },
    { id: 'name', header: t('officer.name'), cell: (o) => o.displayName },
    { id: 'unit', header: t('officer.unit'), cell: (o) => (o.unit ? unitLabel(i18n, o.unit) : null), className: 'text-muted' },
    {
      id: 'status',
      header: t('common.status'),
      cell: (o) => <Badge tone={o.onDuty ? 'success' : 'neutral'}>{t(o.onDuty ? 'officer.onDuty' : 'officer.offDuty')}</Badge>,
    },
  ];
  return <Table columns={columns} rows={roster} getRowKey={(o) => o.citizenid} empty={<EmptyState title={t('officer.none')} />} caption={t('officer.roster')} />;
}

function Block({ block, data }: { block: HomeBlock; data: HomeOutput | undefined }) {
  const { t } = useI18n();
  if (!data) {
    return (
      <div className="flex justify-center py-6">
        <Spinner />
      </div>
    );
  }
  switch (block) {
    case 'recentBolos':
      return <BoloList bolos={data.recentBolos} showSubject empty={t('bolo.none')} />;
    case 'myCases':
      return <CaseRefList refs={data.myCases} subject={t('case.notice.subject')} empty={t('case.none')} />;
    case 'roster':
      return <Roster roster={data.roster} />;
  }
}

export function HomePage() {
  const i18n = useI18n();
  const { t } = i18n;
  const { grants, unit, me } = useSession();
  const home = useMdtQuery('getHome', {});
  const data = home.data;
  const variant = selectHomeVariant(unit, data?.variant);
  const layout = homeLayoutFor(variant, grants);
  const unitName = unit ? unitLabel(i18n, unit) : t('unit.none');
  const subtitle = me.callsign ? t('home.onDutyAs', { callsign: me.callsign, unit: unitName }) : unitName;
  const counts = data?.counts;

  return (
    <div data-home-variant={variant}>
      <PageHeader title={t('home.greeting', { name: me.displayName })} subtitle={subtitle} />
      {home.isError && (
        <Card className="mb-4" padded={false}>
          <ErrorState error={home.error} onRetry={() => void home.refetch()} />
        </Card>
      )}
      {layout.stats.length > 0 && (
        <div className="mb-4 grid grid-cols-1 gap-3 sm:grid-cols-3">
          {layout.stats.map((stat, i) => (
            <StatCard
              key={stat}
              stat={stat}
              value={counts ? counts[stat] : home.isError ? 0 : null}
              emphasis={i === 0}
              to={canSeePage(grants, STAT_LINKS[stat].page) ? STAT_LINKS[stat].to : null}
            />
          ))}
        </div>
      )}
      {layout.blocks.length === 0 ? (
        <Card padded={false}>
          <EmptyState title={t('home.empty')} />
        </Card>
      ) : (
        <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
          {layout.blocks.map((block) => (
            <Card key={block} title={t(BLOCK_TITLES[block])} padded={false} className={block === 'roster' ? 'lg:col-span-2' : undefined}>
              {home.isError ? <EmptyState title={t('home.empty')} /> : <Block block={block} data={data} />}
            </Card>
          ))}
        </div>
      )}
    </div>
  );
}

