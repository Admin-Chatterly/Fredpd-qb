// SPDX-License-Identifier: GPL-3.0-only
// Charge picker on the report page (task 5.3, docs/contracts.md §C14): the person (a person subject of the case, or
// any person through the search picker), type-ahead over the brottskatalog (the cached listCharges answer, filtered
// locally), lines with quantities, live fine/jail sums (formatCurrency), "Registrera brott" (applyCharges, perm
// charges.apply) and "Utfärda ordningsbot" (issueFine, perm charges.fine; only when every line is an ordningsbot,
// which is all the server accepts). The perms are hints; fredpd_records checks them.
import { useMemo, useState } from 'react';
import type { Charge, CaseSubject } from '@fredpd/types/records';
import { Badge, Button, Dialog, IconButton, IconClose, Input, Label, SearchInput, fieldClass, useActionAvailable, useI18n } from '@fredpd/ui';
import { useMdtMutation, useMdtQuery } from '../api/hooks';
import { CHARGE_CLASS_KEYS, CHARGE_CLASS_TONES, QUANTITY_MAX, QUANTITY_MIN, addLine, canIssueFine, filterCharges, removeLine, setQuantity, sumLines } from '../charges';
import type { ChargeLine } from '../charges';
import { fmtCurrency } from '../format';
import { PERMS, usePerm } from '../perms';
import { SubjectPicker } from './Bolos';
import { Callout } from './Common';
import { MutationError } from './Fields';

interface PickedPerson {
  citizenid: string;
  name: string;
}

export interface ChargePickerProps {
  reportId: number;
  caseId: number;
  /** Person subjects of the case (offered first). */
  subjects: readonly CaseSubject[];
}

const SUGGESTIONS = 8;

export function ChargePicker({ reportId, caseId, subjects }: ChargePickerProps) {
  const i18n = useI18n();
  const { t, tx } = i18n;
  const canApply = usePerm(PERMS.chargesApply);
  // An ordningsbot is billed to a player standing next to the officer: tablet only (hidden in the portal).
  const fineAvailable = useActionAvailable('issueFine');
  const canFine = usePerm(PERMS.chargesFine) && fineAvailable;
  const catalogue = useMdtQuery('listCharges', {});
  const byCode = useMemo(() => new Map((catalogue.data?.items ?? []).map((c) => [c.code, c])), [catalogue.data]);
  const [person, setPerson] = useState<PickedPerson | null>(null);
  const [searching, setSearching] = useState(false);
  const [query, setQuery] = useState('');
  const [lines, setLines] = useState<ChargeLine[]>([]);
  const [confirmFine, setConfirmFine] = useState(false);
  const [done, setDone] = useState<string | null>(null);
  const persons = subjects.filter((s): s is Extract<CaseSubject, { type: 'person' }> => s.type === 'person');
  const suggestions = query.trim() ? filterCharges(catalogue.data?.items ?? [], query).slice(0, SUGGESTIONS) : [];
  const totals = sumLines(lines, byCode);
  const fineAllowed = canIssueFine(lines, byCode);

  const reset = (message: string) => {
    setLines([]);
    setQuery('');
    setDone(message);
  };
  const apply = useMdtMutation('applyCharges', { onSuccess: () => reset(tx('charge.applied')) });
  const fine = useMdtMutation('issueFine', {
    onSuccess: (data) => {
      setConfirmFine(false);
      reset(t('charge.ordningsbot.issued', { amount: fmtCurrency(data.totals.fine), name: person?.name ?? '' }));
    },
  });

  const add = (charge: Charge) => {
    setLines((l) => addLine(l, charge.code));
    setDone(null);
  };

  return (
    <div className="flex flex-col gap-3" data-charge-picker>
      <div className="flex flex-wrap items-end gap-2">
        <Label className="w-64">
          {tx('charge.person')}
          <select
            className={fieldClass}
            value={person && persons.some((p) => p.citizenid === person.citizenid) ? person.citizenid : ''}
            onChange={(e) => {
              const s = persons.find((p) => p.citizenid === e.target.value);
              setPerson(s ? { citizenid: s.citizenid, name: s.label } : null);
            }}
          >
            <option value="">{t('common.notSet')}</option>
            {persons.map((p) => (
              <option key={p.citizenid} value={p.citizenid}>
                {p.label}
              </option>
            ))}
          </select>
        </Label>
        <Button size="sm" variant="ghost" onClick={() => setSearching((v) => !v)} aria-expanded={searching}>
          {t('common.search')}
        </Button>
        {person && <span className="pb-2 text-sm text-fg" data-charge-person={person.citizenid}>{person.name}</span>}
      </div>
      {searching && (
        <SubjectPicker
          kind="person"
          onPick={(s) => {
            if (s.kind !== 'person') return;
            setPerson({ citizenid: s.citizenid, name: s.label });
            setSearching(false);
          }}
        />
      )}

      <div className="relative">
        <SearchInput value={query} onValueChange={setQuery} onSubmit={() => suggestions[0] && add(suggestions[0])} placeholder={t('charge.search')} aria-label={t('charge.search')} />
        {query.trim() && (
          <ul role="listbox" aria-label={t('charge.title')} className="mt-1 flex max-h-64 flex-col overflow-y-auto rounded-md border border-line bg-surface">
            {suggestions.length === 0 ? (
              <li className="px-3 py-2 text-sm text-muted">{t('charge.noResults', { query: query.trim() })}</li>
            ) : (
              suggestions.map((c) => (
                <li key={c.code} role="option" aria-selected={false}>
                  <button type="button" data-charge-code={c.code} className="flex w-full items-center gap-2 px-3 py-1.5 text-left text-sm hover:bg-raised" onClick={() => add(c)}>
                    <span className="w-16 shrink-0 font-mono text-xs text-muted">{c.code}</span>
                    <span className="min-w-0 flex-1 truncate">{c.title}</span>
                    <Badge tone={CHARGE_CLASS_TONES[c.class]}>{t(CHARGE_CLASS_KEYS[c.class])}</Badge>
                  </button>
                </li>
              ))
            )}
          </ul>
        )}
      </div>

      {lines.length === 0 ? (
        <p className="text-sm text-muted">{t('charge.none')}</p>
      ) : (
        <table className="w-full text-left text-sm" data-charge-lines>
          <thead>
            <tr className="border-b border-line text-xs text-muted">
              <th className="py-1 font-medium">{t('charge.field.title')}</th>
              <th className="py-1 font-medium">{t('charge.field.class')}</th>
              <th className="w-20 py-1 font-medium">{t('charge.field.count')}</th>
              <th className="py-1 text-right font-medium">{t('charge.field.fine')}</th>
              <th className="py-1 text-right font-medium">{t('charge.field.jail')}</th>
              <th className="w-8" />
            </tr>
          </thead>
          <tbody>
            {lines.map((line) => {
              const c = byCode.get(line.code);
              if (!c) return null;
              return (
                <tr key={line.code} data-line={line.code} className="border-b border-line last:border-b-0">
                  <td className="py-1.5">
                    <span className="font-mono text-xs text-muted">{c.code}</span> {c.title}
                  </td>
                  <td className="py-1.5">
                    <Badge tone={CHARGE_CLASS_TONES[c.class]}>{t(CHARGE_CLASS_KEYS[c.class])}</Badge>
                  </td>
                  <td className="py-1.5">
                    <Input
                      type="number"
                      min={QUANTITY_MIN}
                      max={QUANTITY_MAX}
                      value={line.quantity}
                      aria-label={t('charge.field.count')}
                      onChange={(e) => setLines((l) => setQuantity(l, line.code, Number(e.target.value)))}
                    />
                  </td>
                  <td className="py-1.5 text-right">{fmtCurrency(c.fine * line.quantity)}</td>
                  <td className="py-1.5 text-right">{c.jailMinutes > 0 ? t('time.duration.minutes', { count: c.jailMinutes * line.quantity }) : null}</td>
                  <td className="py-1.5">
                    <IconButton size="sm" label={t('common.remove')} icon={<IconClose size={14} />} onClick={() => setLines((l) => removeLine(l, line.code))} />
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}

      <div className="flex flex-wrap items-center gap-x-6 gap-y-1 text-sm" data-charge-totals>
        <span data-total-fine={totals.fine}>{t('charge.totalFine', { amount: fmtCurrency(totals.fine) })}</span>
        <span data-total-jail={totals.jailMinutes}>{tx('charge.totalJailMinutes', { count: totals.jailMinutes })}</span>
      </div>

      <div className="flex flex-wrap gap-2">
        {canApply && (
          <Button
            variant="primary"
            disabled={!person || lines.length === 0}
            loading={apply.isPending}
            onClick={() => person && apply.mutate({ reportId, citizenid: person.citizenid, lines })}
          >
            {tx('charge.apply')}
          </Button>
        )}
        {canFine && (
          <Button disabled={!person || !fineAllowed} onClick={() => setConfirmFine(true)} title={fineAllowed ? undefined : tx('charge.ordningsbot.onlyHint')}>
            {t('charge.ordningsbot.issue')}
          </Button>
        )}
      </div>
      <MutationError error={apply.error} />
      {done && <Callout tone="success">{done}</Callout>}

      {confirmFine && person && (
        <Dialog
          open
          title={t('charge.ordningsbot.issue')}
          onClose={() => setConfirmFine(false)}
          footer={
            <>
              <Button onClick={() => setConfirmFine(false)}>{t('common.cancel')}</Button>
              <Button variant="primary" loading={fine.isPending} onClick={() => fine.mutate({ citizenid: person.citizenid, lines, caseId })}>
                {t('common.confirm')}
              </Button>
            </>
          }
        >
          <p className="text-sm">{t('charge.ordningsbot.confirm', { amount: fmtCurrency(totals.fine), name: person.name })}</p>
          <MutationError error={fine.error} />
        </Dialog>
      )}
    </div>
  );
}
