// SPDX-License-Identifier: GPL-3.0-only
// Hem: one layout per primary unit (config/units.json `home`), sections filtered by grant. Task 2.7 fills the
// sections with data from one callback; the shell shows their titles and empty states.
import { Card, EmptyState, PageHeader, useI18n } from '@fredpd/ui';
import type { MdtPageKey } from '@fredpd/ui';
import type { LocaleKey } from '@fredpd/types/locale-keys';
import { canSeePage } from '../nav';
import { useSession } from '../tablet/TabletContext';
import { homeVariantFor } from '../units';
import type { HomeVariant } from '../units';

interface HomeSection {
  title: LocaleKey;
  /** Section shown only with this mdt_page grant. */
  page: MdtPageKey;
}

const s = (title: LocaleKey, page: MdtPageKey): HomeSection => ({ title, page });

export const HOME_SECTIONS: Readonly<Record<HomeVariant, readonly HomeSection[]>> = {
  igv: [s('home.openAlerts', 'alerts'), s('home.activeBolos', 'bolos'), s('home.unitsOnDuty', 'roster'), s('home.recentLookups', 'search')],
  span: [s('home.activeBolos', 'bolos'), s('home.activeMissions', 'intel'), s('home.unitCases', 'cases'), s('home.recentLookups', 'search')],
  utredning: [s('home.myCases', 'cases'), s('home.unitCases', 'cases'), s('home.activeBolos', 'bolos'), s('home.recentLookups', 'search')],
  tekniker: [s('home.evidenceQueue', 'evidence'), s('home.myCases', 'cases'), s('home.unitCases', 'cases')],
  ledning: [s('home.unitsOnDuty', 'roster'), s('home.openAlerts', 'alerts'), s('home.releaseQueue', 'command'), s('home.flaggedSearches', 'command')],
  default: [s('home.openAlerts', 'alerts'), s('home.activeBolos', 'bolos'), s('home.myCases', 'cases')],
};

export function HomePage() {
  const { t, tx } = useI18n();
  const { grants, unit, me } = useSession();
  const variant = homeVariantFor(unit);
  const sections = HOME_SECTIONS[variant].filter((section) => canSeePage(grants, section.page));
  const unitLabel = unit ? tx(`unit.${unit}`, undefined, unit) : t('unit.none');
  const subtitle = me.callsign ? t('home.onDutyAs', { callsign: me.callsign, unit: unitLabel }) : unitLabel;

  return (
    <div data-home-variant={variant}>
      <PageHeader title={t('home.greeting', { name: me.displayName })} subtitle={subtitle} />
      {sections.length === 0 ? (
        <Card padded={false}>
          <EmptyState title={t('home.empty')} />
        </Card>
      ) : (
        <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
          {sections.map((section) => (
            <Card key={section.title} title={t(section.title)} padded={false}>
              <EmptyState title={t('home.empty')} />
            </Card>
          ))}
        </div>
      )}
    </div>
  );
}
