// SPDX-License-Identifier: GPL-3.0-only
// Form pieces shared by the Phase 3–5b pages: the sekretessnivå select (levels above the viewer's tier disabled,
// §C14 "never above the actor's tier"), the officer picker (case assignees, mission members) and a small
// mutation-error line.
import { useState } from 'react';
import type { Level } from '@fredpd/types/mdt';
import { CitizenIdSchema } from '@fredpd/types/actions';
import { Button, LEVEL_LOCALE_KEYS, Label, fieldClass, inputClass, useI18n } from '@fredpd/ui';
import { useMdtQuery } from '../api/hooks';
import { useErrorText } from '../api/errors';
import { LEVELS } from '../bolo';
import { officerLabel } from '../format';
import { LEVEL_HINT_KEYS } from '../levels';
import { canSeePage } from '../nav';
import { useSession } from '../tablet/TabletContext';

export function LevelSelect({ value, onChange, tier, label, min = 0 }: { value: Level; onChange: (level: Level) => void; tier: Level; label?: string; min?: Level }) {
  const { t } = useI18n();
  return (
    <Label hint={t(LEVEL_HINT_KEYS[value])}>
      {label ?? t('level.label')}
      <select className={fieldClass} value={value} onChange={(e) => onChange(Number(e.target.value) as Level)}>
        {LEVELS.map((level) => (
          <option key={level} value={level} disabled={level > tier || level < min}>
            {t(LEVEL_LOCALE_KEYS[level])}
          </option>
        ))}
      </select>
    </Label>
  );
}

/** A failed mutation, localised (reason first, then code). Renders nothing without an error. */
export function MutationError({ error }: { error: unknown }) {
  const errorText = useErrorText();
  if (!error) return null;
  return (
    <p role="alert" className="text-sm text-danger">
      {errorText(error)}
    </p>
  );
}

export interface OfficerChoice {
  citizenid: string;
  label: string;
}

/**
 * Officer picker. The on-duty roster comes from `getUnits` (needs mdt_page:alerts, which every patrol has); without
 * that grant, or for an officer who is off duty, the citizenid can be typed (checked with CitizenIdSchema, the
 * server checks that the officer exists). No officer search action exists yet (docs/modules/ui.md, requests).
 */
export function OfficerPicker({ onPick, exclude = [], busy = false, actionLabel }: { onPick: (choice: OfficerChoice) => void; exclude?: readonly string[]; busy?: boolean; actionLabel: string }) {
  const { t, tx } = useI18n();
  const { grants } = useSession();
  const hasRoster = canSeePage(grants, 'alerts');
  const units = useMdtQuery('getUnits', {}, { enabled: hasRoster });
  const [selected, setSelected] = useState('');
  const [typed, setTyped] = useState('');
  const options = (units.data?.units ?? []).filter((u) => u.onDuty && !exclude.includes(u.citizenid));
  const typedValid = CitizenIdSchema.safeParse(typed.trim()).success;

  const pick = () => {
    const fromRoster = options.find((o) => o.citizenid === selected);
    if (fromRoster) onPick({ citizenid: fromRoster.citizenid, label: officerLabel(fromRoster) });
    else if (typedValid) onPick({ citizenid: typed.trim(), label: typed.trim() });
  };

  return (
    <div className="flex flex-wrap items-end gap-2">
      {hasRoster && options.length > 0 && (
        <Label className="min-w-48 flex-1">
          {tx('officer.pick')}
          <select className={fieldClass} value={selected} onChange={(e) => setSelected(e.target.value)}>
            <option value="">{t('common.notSet')}</option>
            {options.map((o) => (
              <option key={o.citizenid} value={o.citizenid}>
                {officerLabel(o)}
              </option>
            ))}
          </select>
        </Label>
      )}
      <Label className="w-40">
        {tx('officer.citizenid')}
        <input className={inputClass} value={typed} maxLength={16} onChange={(e) => setTyped(e.target.value)} disabled={selected !== ''} />
      </Label>
      <Button size="sm" onClick={pick} loading={busy} disabled={!(selected !== '' || typedValid)}>
        {actionLabel}
      </Button>
    </div>
  );
}
