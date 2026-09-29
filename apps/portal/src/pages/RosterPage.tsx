// SPDX-License-Identifier: GPL-3.0-only
// Ledning → Register (/register, mdt_page:roster): the officer roster from getHome (fredpd_officers, Discord names,
// on/off duty), on-duty officers first. The tablet shows the same table on Ledning's Hem. fredpd_mdt fills
// `roster` only for the Ledning variant (a ledning unit) and only with officers online on duty; a full register
// (off-duty officers too, any holder of mdt_page:roster) needs a roster action (docs/modules/portal.md, integration
// requests). Until then others see "Inga poliser i tjänst".
import { Card, PageHeader, useI18n } from '@fredpd/ui';
import { Roster } from '../mdt/shared-pages';
import { QueryView, useMdtQuery } from '../mdt/shared';

export function RosterPage() {
  const { t } = useI18n();
  const home = useMdtQuery('getHome', {});
  return (
    <>
      <PageHeader title={t('nav.roster')} />
      <Card padded={false}>
        <QueryView query={home}>
          {(data) => <Roster roster={[...data.roster].sort((a, b) => Number(b.onDuty) - Number(a.onDuty) || a.displayName.localeCompare(b.displayName, 'sv'))} />}
        </QueryView>
      </Card>
    </>
  );
}
