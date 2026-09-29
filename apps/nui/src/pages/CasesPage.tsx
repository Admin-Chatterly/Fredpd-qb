// SPDX-License-Identifier: GPL-3.0-only
// Ärenden (/arenden, task 5.2): listCases with the filters Mina / Enhetens / Öppna / Avslutade / Alla and a search
// (number or title, Enter searches), 50 per page. Rows are canView-shaped CaseRefs: a kontaktnotis row is only the
// Notice (components/CaseRefs.tsx). "Nytt ärende" (perm cases.create) creates and opens the case.
import { useState } from 'react';
import { useNavigate } from 'react-router';
import { PAGE_SIZE } from '@fredpd/types/mdt';
import type { Level } from '@fredpd/types/mdt';
import { Button, Card, Dialog, IconPlus, Input, Label, PageHeader, Pagination, SearchInput, Tabs, Textarea, useI18n } from '@fredpd/ui';
import { useMdtMutation, useMdtQuery } from '../api/hooks';
import { CASE_FILTERS, CASE_FILTER_KEYS, CASE_TITLE_MAX, CASE_TITLE_MIN, casePath } from '../cases';
import type { CaseFilter } from '../cases';
import { CaseRefList } from '../components/CaseRefs';
import { QueryView } from '../components/Common';
import { LevelSelect, MutationError } from '../components/Fields';
import { PERMS, usePerm } from '../perms';
import { useSession } from '../tablet/TabletContext';

function CaseCreateDialog({ onClose }: { onClose: () => void }) {
  const { t } = useI18n();
  const navigate = useNavigate();
  const { grants } = useSession();
  const [title, setTitle] = useState('');
  const [summary, setSummary] = useState('');
  const [level, setLevel] = useState<Level>(0);
  const create = useMdtMutation('createCase', {
    onSuccess: (data) => {
      onClose();
      if (data.visibility !== 'notice') void navigate(casePath(data.id));
    },
  });
  const valid = title.trim().length >= CASE_TITLE_MIN;
  const submit = () => {
    if (!valid) return;
    create.mutate({ title: title.trim(), level, ...(summary.trim() ? { summary: summary.trim() } : {}) });
  };
  return (
    <Dialog
      open
      title={t('case.create.title')}
      onClose={onClose}
      dismissOnBackdrop={false}
      footer={
        <>
          <Button onClick={onClose}>{t('common.cancel')}</Button>
          <Button variant="primary" onClick={submit} loading={create.isPending} disabled={!valid}>
            {t('common.create')}
          </Button>
        </>
      }
    >
      <div className="flex flex-col gap-3">
        <Label>
          {t('case.field.title')}
          <Input value={title} maxLength={CASE_TITLE_MAX} onChange={(e) => setTitle(e.target.value)} />
        </Label>
        <Label>
          {t('case.field.summary')}
          <Textarea value={summary} rows={4} maxLength={20_000} onChange={(e) => setSummary(e.target.value)} />
        </Label>
        <LevelSelect value={level} onChange={setLevel} tier={grants.tier} label={t('case.field.level')} />
        <MutationError error={create.error} />
      </div>
    </Dialog>
  );
}

export function CasesPage() {
  const { t, tx } = useI18n();
  const canCreate = usePerm(PERMS.casesCreate);
  const [filter, setFilter] = useState<CaseFilter>('mine');
  const [text, setText] = useState('');
  const [query, setQuery] = useState('');
  const [page, setPage] = useState(1);
  const [creating, setCreating] = useState(false);
  const list = useMdtQuery('listCases', { filter, page, ...(query ? { query } : {}) }, { keepPrevious: true });

  return (
    <>
      <PageHeader
        title={t('case.title')}
        actions={
          canCreate && (
            <Button variant="primary" icon={<IconPlus size={16} />} onClick={() => setCreating(true)}>
              {t('case.create.title')}
            </Button>
          )
        }
      />
      <div className="mb-3 flex flex-wrap items-center gap-3">
        <Tabs
          label={t('common.filter')}
          value={filter}
          onChange={(f) => {
            setFilter(f);
            setPage(1);
          }}
          items={CASE_FILTERS.map((f) => ({ id: f, label: tx(CASE_FILTER_KEYS[f]) }))}
        />
        <SearchInput
          className="ml-auto w-72"
          value={text}
          onValueChange={(v) => {
            setText(v);
            if (v === '') setQuery('');
          }}
          onSubmit={(q) => {
            setQuery(q.trim().slice(0, 64));
            setPage(1);
          }}
          placeholder={tx('case.search')}
          aria-label={tx('case.search')}
        />
      </div>
      <Card padded={false}>
        <QueryView query={list}>
          {(data) => (
            <>
              <CaseRefList refs={data.items} subject={t('case.notice.subject')} empty={t('case.none')} />
              <Pagination page={data.page} total={data.total} pageSize={PAGE_SIZE} disabled={list.isFetching} onPageChange={setPage} />
            </>
          )}
        </QueryView>
      </Card>
      {creating && <CaseCreateDialog onClose={() => setCreating(false)} />}
    </>
  );
}
