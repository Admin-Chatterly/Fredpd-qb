// SPDX-License-Identifier: GPL-3.0-only
// Vehicle page (/fordon/:plate, task 2.5) from getVehicle (VehicleSummary): owner link, BOLO flag, linked cases,
// "Kontrollera" (checkPlate: recorded server-side, a hit alerts other units) and the check history (last 20).
import { useState } from 'react';
import { Link, useParams } from 'react-router';
import type { Bolo, PlateCheckResult, VehicleSummary } from '@fredpd/types/mdt';
import { Badge, Button, Card, EmptyState, IconFlag, IconSearch, PageHeader, useActionAvailable, useI18n } from '@fredpd/ui';
import { useMdtMutation, useMdtQuery } from '../api/hooks';
import { useErrorText } from '../api/errors';
import { BoloCreateDialog, BoloList, BoloResolveDialog } from '../components/Bolos';
import { CaseRefList } from '../components/CaseRefs';
import { Callout, Facts, QueryView } from '../components/Common';
import { fmtDateTime, officerLabel } from '../format';
import { PERMS, usePerm } from '../perms';
import { personPath } from '../search';
import { useSession } from '../session';

function CheckResult({ result }: { result: PlateCheckResult }) {
  const i18n = useI18n();
  const { t } = i18n;
  const at = fmtDateTime(i18n, result.checkedAt);
  if (result.bolo) {
    return (
      <Callout tone="danger" title={t('bolo.hit.title')}>
        <p>{t('bolo.hit.plate', { plate: result.plate, reason: result.bolo.reason })}</p>
        <p className="text-xs text-muted">{at}</p>
      </Callout>
    );
  }
  if (!result.owner && !result.model) {
    return (
      <Callout tone="warning">
        {t('bolo.checkPlate.unregistered', { plate: result.plate })} <span className="text-xs text-muted">{at}</span>
      </Callout>
    );
  }
  return (
    <Callout tone="success">
      {t('bolo.checkPlate.clear', { plate: result.plate })} <span className="text-xs text-muted">{at}</span>
    </Callout>
  );
}

export function VehicleView({ data }: { data: VehicleSummary }) {
  const i18n = useI18n();
  const { t } = i18n;
  const errorText = useErrorText();
  const { grants } = useSession();
  const canCreate = usePerm(PERMS.boloCreate);
  const canResolve = usePerm(PERMS.boloResolve);
  const [creating, setCreating] = useState(false);
  const [resolving, setResolving] = useState<Bolo | null>(null);
  const [message, setMessage] = useState<string | null>(null);
  const check = useMdtMutation('checkPlate');
  // A plate check happens at the car (fredpd_bolo records it and alerts on a hit): tablet only, never in the portal.
  const canCheck = useActionAvailable('checkPlate');

  const { vehicle, owner } = data;
  const wanted = data.bolos.some((b) => b.active);
  const label = vehicle.model ? `${vehicle.plate} · ${vehicle.model}` : vehicle.plate;

  return (
    <div data-vehicle={vehicle.plate}>
      <PageHeader
        title={
          <span className="flex items-center gap-2">
            <span className="font-mono">{vehicle.plate}</span>
            {wanted && <Badge tone="danger">{t('vehicle.wanted')}</Badge>}
          </span>
        }
        subtitle={vehicle.model ?? undefined}
        actions={
          <>
            {canCheck && (
              <Button variant="primary" icon={<IconSearch size={16} />} loading={check.isPending} onClick={() => check.mutate({ plate: vehicle.plate })}>
                {t('vehicle.check')}
              </Button>
            )}
            {canCreate && (
              <span title={wanted ? t('bolo.create.duplicate', { subject: vehicle.plate }) : undefined} className="inline-flex">
                <Button variant="danger" icon={<IconFlag size={16} />} disabled={wanted} onClick={() => setCreating(true)}>
                  {t('bolo.create.submit')}
                </Button>
              </span>
            )}
          </>
        }
      />
      <div className="mb-4 flex flex-col gap-2">
        {check.isSuccess && <CheckResult result={check.data} />}
        {check.isError && <Callout tone="danger">{errorText(check.error)}</Callout>}
        {message && <Callout tone="success">{message}</Callout>}
      </div>
      <Card className="mb-4">
        <Facts
          facts={[
            { label: t('vehicle.field.plate'), value: <span className="font-mono">{vehicle.plate}</span> },
            { label: t('vehicle.field.model'), value: vehicle.model },
            {
              label: t('vehicle.field.owner'),
              value: owner ? (
                <Link to={personPath(owner.citizenid)} className="text-accent-text hover:underline">
                  {owner.name}
                </Link>
              ) : (
                <span className="text-muted">{t('vehicle.ownerUnknown')}</span>
              ),
            },
          ]}
        />
      </Card>
      <div className="grid grid-cols-1 gap-4 xl:grid-cols-2">
        <Card title={t('person.section.bolos')} padded={false}>
          <BoloList bolos={data.bolos} onResolve={canResolve ? setResolving : undefined} />
        </Card>
        <Card title={t('vehicle.section.cases')} padded={false}>
          <CaseRefList refs={data.cases} subject={vehicle.plate} empty={t('vehicle.noCases')} />
        </Card>
        <Card title={t('vehicle.checkHistory')} padded={false} className="xl:col-span-2">
          {data.checks.length === 0 ? (
            <EmptyState title={t('vehicle.noChecks')} />
          ) : (
            <ul className="flex flex-col divide-y divide-line" aria-label={t('vehicle.checkHistory')}>
              {data.checks.map((c, i) => (
                <li key={`${c.checkedAt}-${i}`} className="flex items-center gap-3 px-4 py-2 text-sm">
                  <span className="w-40 shrink-0 text-muted">{fmtDateTime(i18n, c.checkedAt)}</span>
                  <span className="min-w-0 flex-1 truncate text-fg">{c.officer ? t('vehicle.checkedBy', { name: officerLabel(c.officer) }) : null}</span>
                  <Badge tone={c.hit ? 'danger' : 'neutral'}>{t(c.hit ? 'vehicle.checkHit' : 'vehicle.checkClear')}</Badge>
                </li>
              ))}
            </ul>
          )}
        </Card>
      </div>
      {creating && (
        <BoloCreateDialog
          kind="vehicle"
          subject={{ kind: 'vehicle', plate: vehicle.plate, label }}
          tier={grants.tier}
          onClose={() => setCreating(false)}
          onCreated={() => {
            setCreating(false);
            setMessage(t('bolo.create.success'));
          }}
        />
      )}
      {resolving && (
        <BoloResolveDialog
          bolo={resolving}
          onClose={() => setResolving(null)}
          onResolved={() => {
            setResolving(null);
            setMessage(t('bolo.resolve.success'));
          }}
        />
      )}
    </div>
  );
}

export function VehiclePage() {
  const { t } = useI18n();
  const { plate = '' } = useParams();
  const vehicle = useMdtQuery('getVehicle', { plate });
  return (
    <QueryView query={vehicle} notFound={t('vehicle.notFound')}>
      {(data) => <VehicleView key={data.vehicle.plate} data={data} />}
    </QueryView>
  );
}
