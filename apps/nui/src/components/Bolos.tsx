// SPDX-License-Identifier: GPL-3.0-only
// BOLO (efterlysning) UI shared by the person, vehicle, Hem and Efterlysningar pages: the list, the create dialog
// (kind, subject picked through the search action, reason, level, expiry) and the resolve dialog. The create and
// resolve buttons are shown only with perm bolo.create / bolo.resolve (a hint; fredpd_mdt checks every call).
// A BOLO shown as kontaktnotis arrives with its notice text as `reason` and without officers, so absent fields are
// simply not rendered.
import { useState } from 'react';
import type { ReactNode } from 'react';
import { Link } from 'react-router';
import type { Bolo, Level } from '@fredpd/types/mdt';
import type { LocaleKey } from '@fredpd/types/locale-keys';
import { Badge, Button, Dialog, EmptyState, LEVEL_LOCALE_KEYS, Label, SearchInput, Textarea, cn, fieldClass, useI18n } from '@fredpd/ui';
import { useMdtMutation, useMdtQuery } from '../api/hooks';
import { useErrorText } from '../api/errors';
import type { MdtClientError } from '../api/errors';
import {
  BOLO_EXPIRY_HOURS,
  BOLO_NOTE_MAX,
  BOLO_REASON_MAX,
  BOLO_REASON_MIN,
  BOLO_STATUS_KEYS,
  LEVELS,
  boloStatus,
  boloSubjectPath,
  checkBoloForm,
  initialBoloForm,
} from '../bolo';
import type { BoloForm, BoloFormIssue, BoloKind, BoloSubject } from '../bolo';
import { fmtDateTime, fmtHours, officerLabel } from '../format';
import { LEVEL_HINT_KEYS } from '../levels';
import { SEARCH_MIN_LENGTH, cleanQuery } from '../search';
import { Callout } from './Common';

// ---------------------------------------------------------------------------------------------------------------
// List
// ---------------------------------------------------------------------------------------------------------------

function Meta({ label, children }: { label: string; children: ReactNode }) {
  return (
    <span className="whitespace-nowrap">
      <span className="text-subtle">{label}</span> {children}
    </span>
  );
}

export interface BoloListProps {
  bolos: readonly Bolo[];
  /** Show the subject (with a link to its page); off on the subject's own page. */
  showSubject?: boolean;
  /** Called by the resolve button (shown only for live BOLOs when given). */
  onResolve?: (bolo: Bolo) => void;
  empty?: string;
}

export function BoloList({ bolos, showSubject = false, onResolve, empty }: BoloListProps) {
  const i18n = useI18n();
  const { t } = i18n;
  if (bolos.length === 0) return <EmptyState title={empty ?? t('bolo.none')} />;
  return (
    <ul className="flex flex-col divide-y divide-line">
      {bolos.map((bolo) => {
        const status = boloStatus(bolo);
        const path = showSubject ? boloSubjectPath(bolo) : null;
        return (
          <li key={bolo.id} data-bolo-id={bolo.id} className="flex flex-col gap-1 px-4 py-2.5">
            <div className="flex flex-wrap items-center gap-2">
              {showSubject &&
                (path ? (
                  <Link to={path} className="font-medium text-accent-text hover:underline">
                    {bolo.subject}
                  </Link>
                ) : (
                  <span className="font-medium">{bolo.subject}</span>
                ))}
              <Badge tone={status === 'active' ? 'danger' : 'neutral'}>{t(BOLO_STATUS_KEYS[status])}</Badge>
              {bolo.level > 0 && <Badge level={bolo.level} />}
              <span className="flex-1" />
              {onResolve && bolo.active && (
                <Button size="sm" variant="ghost" onClick={() => onResolve(bolo)}>
                  {t('bolo.resolve.button')}
                </Button>
              )}
            </div>
            <p className="text-sm text-fg">{bolo.reason}</p>
            <p className="flex flex-wrap gap-x-4 gap-y-0.5 text-xs text-muted">
              {bolo.issuedBy && <Meta label={t('bolo.field.issuedBy')}>{officerLabel(bolo.issuedBy)}</Meta>}
              <Meta label={t('common.createdAt')}>{fmtDateTime(i18n, bolo.createdAt)}</Meta>
              {bolo.expiresAt && <Meta label={t('bolo.field.expiresAt')}>{fmtDateTime(i18n, bolo.expiresAt)}</Meta>}
              {bolo.resolvedBy && <Meta label={t('bolo.field.resolvedBy')}>{officerLabel(bolo.resolvedBy)}</Meta>}
              {bolo.resolvedAt && <Meta label={t('bolo.status.resolved')}>{fmtDateTime(i18n, bolo.resolvedAt)}</Meta>}
            </p>
            {bolo.resolveNote && <p className="text-xs text-muted">{bolo.resolveNote}</p>}
          </li>
        );
      })}
    </ul>
  );
}

// ---------------------------------------------------------------------------------------------------------------
// Create
// ---------------------------------------------------------------------------------------------------------------

/** Search-based subject picker: person (name or personnummer) or vehicle (plate). Enter searches. */
function SubjectPicker({ kind, onPick }: { kind: BoloKind; onPick: (subject: BoloSubject) => void }) {
  const { t } = useI18n();
  const [query, setQuery] = useState('');
  const [submitted, setSubmitted] = useState('');
  const enabled = submitted.length >= SEARCH_MIN_LENGTH;
  const search = useMdtQuery('search', { query: submitted, type: kind, page: 1 }, { enabled });
  const errorText = useErrorText();

  const subjects: BoloSubject[] = (search.data?.hits ?? []).flatMap((hit): BoloSubject[] => {
    if (kind === 'person' && hit.kind === 'person') {
      return [{ kind: 'person', citizenid: hit.citizenid, label: hit.personnummer ? `${hit.name} (${hit.personnummer})` : hit.name }];
    }
    if (kind === 'vehicle' && hit.kind === 'vehicle') {
      return [{ kind: 'vehicle', plate: hit.plate, label: hit.model ? `${hit.plate} · ${hit.model}` : hit.plate }];
    }
    return [];
  });

  const placeholder = t(kind === 'person' ? 'bolo.create.searchPerson' : 'bolo.create.searchVehicle');
  return (
    <div className="flex flex-col gap-2">
      <SearchInput
        value={query}
        onValueChange={setQuery}
        onSubmit={(q) => setSubmitted(cleanQuery(q))}
        placeholder={placeholder}
        aria-label={placeholder}
      />
      {enabled && search.isFetching && <p className="text-sm text-muted">{t('mdt.search.searching')}</p>}
      {enabled && search.isError && <p className="text-sm text-danger">{errorText(search.error)}</p>}
      {enabled && search.isSuccess && subjects.length === 0 && <p className="text-sm text-muted">{t('mdt.search.noResults', { query: submitted })}</p>}
      {subjects.length > 0 && (
        <ul className="flex max-h-48 flex-col overflow-y-auto rounded-md border border-line">
          {subjects.slice(0, 8).map((subject) => (
            <li key={subject.kind === 'person' ? subject.citizenid : subject.plate}>
              <button
                type="button"
                className="w-full px-3 py-2 text-left text-sm hover:bg-raised focus-visible:bg-raised"
                onClick={() => onPick(subject)}
              >
                {subject.label}
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

function createErrorText(err: MdtClientError, subject: string, i18n: ReturnType<typeof useI18n>, errorText: (e: unknown) => string): string {
  if (err.reason === 'duplicate') return i18n.t('bolo.create.duplicate', { subject });
  if (err.reason === 'level') return i18n.t('bolo.create.levelTooHigh');
  if (err.code === 'not_found') return i18n.t('bolo.create.subjectNotFound');
  return errorText(err);
}

const ISSUE_KEYS: Readonly<Record<BoloFormIssue, LocaleKey>> = {
  subject: 'bolo.create.subjectRequired',
  reason: 'errors.field.tooShort',
  level: 'bolo.create.levelTooHigh',
  expiresInHours: 'errors.validation',
};

export interface BoloCreateDialogProps {
  onClose: () => void;
  /** Kind to start with (default person). */
  kind?: BoloKind;
  /** Prefilled subject (person/vehicle page). */
  subject?: BoloSubject | null;
  /** The viewer's intel tier: levels above it cannot be chosen. */
  tier: Level;
  onCreated?: (bolo: Bolo) => void;
}

/** Mount it to open it (each mount starts from a fresh form). */
export function BoloCreateDialog({ onClose, kind: initialKind, subject: initialSubject = null, tier, onCreated }: BoloCreateDialogProps) {
  const i18n = useI18n();
  const { t } = i18n;
  const errorText = useErrorText();
  const [form, setForm] = useState<BoloForm>(() => initialBoloForm(initialKind ?? initialSubject?.kind ?? 'person', initialSubject));
  const [issues, setIssues] = useState<BoloFormIssue[]>([]);
  const create = useMdtMutation('createBolo', { onSuccess: (bolo) => onCreated?.(bolo) });

  const update = (patch: Partial<BoloForm>) => {
    setForm((f) => ({ ...f, ...patch }));
    setIssues([]);
  };
  const setKind = (kind: BoloKind) => update({ kind, subject: form.subject?.kind === kind ? form.subject : null });

  const submit = () => {
    const check = checkBoloForm(form, tier);
    if (!check.ok) {
      setIssues(check.issues);
      return;
    }
    create.mutate(check.input);
  };

  const issueText = (issue: BoloFormIssue) =>
    issue === 'reason' ? t('errors.field.tooShort', { min: BOLO_REASON_MIN }) : t(ISSUE_KEYS[issue]);
  const has = (issue: BoloFormIssue) => issues.includes(issue);

  return (
    <Dialog
      open
      dismissOnBackdrop={false}
      title={t('bolo.create.title')}
      onClose={onClose}
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            {t('common.cancel')}
          </Button>
          <Button variant="primary" loading={create.isPending} onClick={submit} data-testid="bolo-create-submit">
            {t('bolo.create.submit')}
          </Button>
        </>
      }
    >
      <div className="flex flex-col gap-4">
        <div role="radiogroup" aria-label={t('bolo.field.kind')} className="flex gap-2">
          {(['person', 'vehicle'] as const).map((kind) => (
            <button
              key={kind}
              type="button"
              role="radio"
              aria-checked={form.kind === kind}
              onClick={() => setKind(kind)}
              className={cn(
                'h-8 rounded-md border px-3 text-sm',
                form.kind === kind ? 'border-accent bg-accent-soft text-accent-text' : 'border-line text-muted hover:text-fg',
              )}
            >
              {t(kind === 'person' ? 'bolo.kind.person' : 'bolo.kind.vehicle')}
            </button>
          ))}
        </div>

        <div className="flex flex-col gap-1.5 text-sm text-muted">
          <span>{t(form.kind === 'person' ? 'bolo.field.person' : 'bolo.field.plate')}</span>
          {form.subject ? (
            <div className="flex items-center gap-2">
              <span data-bolo-subject className="min-w-0 flex-1 truncate rounded-md border border-line bg-canvas px-3 py-2 text-fg">
                {form.subject.label}
              </span>
              <Button size="sm" variant="ghost" onClick={() => update({ subject: null })}>
                {t('bolo.create.changeSubject')}
              </Button>
            </div>
          ) : (
            <SubjectPicker kind={form.kind} onPick={(subject) => update({ subject })} />
          )}
          {has('subject') && <span className="text-danger">{issueText('subject')}</span>}
        </div>

        <Label>
          {t('bolo.field.reason')}
          <Textarea
            value={form.reason}
            maxLength={BOLO_REASON_MAX}
            invalid={has('reason')}
            onChange={(e) => update({ reason: e.target.value })}
          />
          {has('reason') && <span className="text-danger">{issueText('reason')}</span>}
        </Label>

        <div className="grid grid-cols-2 gap-3">
          <Label hint={t(LEVEL_HINT_KEYS[form.level])}>
            {t('bolo.field.level')}
            <select
              className={fieldClass}
              value={form.level}
              aria-invalid={has('level') || undefined}
              onChange={(e) => update({ level: Number(e.target.value) as Level })}
            >
              {LEVELS.map((level) => (
                <option key={level} value={level} disabled={level > tier}>
                  {t(LEVEL_LOCALE_KEYS[level])}
                </option>
              ))}
            </select>
          </Label>
          <Label>
            {t('bolo.field.duration')}
            <select
              className={fieldClass}
              value={form.expiresInHours ?? ''}
              onChange={(e) => update({ expiresInHours: e.target.value === '' ? null : Number(e.target.value) })}
            >
              <option value="">{t('bolo.expiry.none')}</option>
              {BOLO_EXPIRY_HOURS.map((hours) => (
                <option key={hours} value={hours}>
                  {fmtHours(i18n, hours)}
                </option>
              ))}
            </select>
          </Label>
        </div>
        {has('level') && <span className="text-sm text-danger">{issueText('level')}</span>}

        {create.isError && (
          <Callout tone="danger">{createErrorText(create.error, form.subject?.label ?? '', i18n, errorText)}</Callout>
        )}
      </div>
    </Dialog>
  );
}

// ---------------------------------------------------------------------------------------------------------------
// Resolve
// ---------------------------------------------------------------------------------------------------------------

export interface BoloResolveDialogProps {
  bolo: Bolo;
  onClose: () => void;
  onResolved?: (bolo: Bolo) => void;
}

export function BoloResolveDialog({ bolo, onClose, onResolved }: BoloResolveDialogProps) {
  const { t } = useI18n();
  const errorText = useErrorText();
  const [note, setNote] = useState('');
  const resolve = useMdtMutation('resolveBolo', { onSuccess: (data) => onResolved?.(data) });
  return (
    <Dialog
      open
      dismissOnBackdrop={false}
      title={t('bolo.resolve.button')}
      onClose={onClose}
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            {t('common.cancel')}
          </Button>
          <Button variant="danger" loading={resolve.isPending} onClick={() => resolve.mutate({ id: bolo.id, note: note.trim() })}>
            {t('bolo.resolve.button')}
          </Button>
        </>
      }
    >
      <div className="flex flex-col gap-4">
        <p className="text-sm text-fg">{t('bolo.resolve.confirm', { subject: bolo.subject })}</p>
        <Label>
          {t('bolo.resolve.note')}
          <Textarea value={note} maxLength={BOLO_NOTE_MAX} onChange={(e) => setNote(e.target.value)} />
        </Label>
        {resolve.isError && <Callout tone="danger">{errorText(resolve.error)}</Callout>}
      </div>
    </Dialog>
  );
}
