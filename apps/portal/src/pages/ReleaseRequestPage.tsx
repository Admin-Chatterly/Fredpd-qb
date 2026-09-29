// SPDX-License-Identifier: GPL-3.0-only
// "Begär ut allmän handling" (/begar-ut; IMPLEMENTATION.md §5.3 "portal form"): any logged-in player with a picked
// character, no grant needed. Sends `createReleaseRequest { description (3-2000), reference? (≤ 48) }` through the
// portal transport; in portal mode fredpd_mdt routes it to fredpd_records' createReleaseRequestPortal with the
// session's Discord id and character (integration request, docs/modules/portal.md). The requester learns nothing
// about the referenced case: the answer is only "received".
import { useState } from 'react';
import { Button, Card, Input, Label, PageHeader, Textarea, useI18n } from '@fredpd/ui';
import { readReceived, useExtraMutation } from '../mdt/extra';
import { Callout, useErrorText } from '../mdt/shared';
import { NotAvailableYet, isActionMissing } from '../components/NotAvailableYet';

export const RELEASE_DESCRIPTION_MIN = 3;
export const RELEASE_DESCRIPTION_MAX = 2000;
export const RELEASE_REFERENCE_MAX = 48;

export function ReleaseRequestPage() {
  const { t } = useI18n();
  const errorText = useErrorText();
  const [description, setDescription] = useState('');
  const [reference, setReference] = useState('');
  const send = useExtraMutation<{ description: string; reference?: string }, { ok: true }>('createReleaseRequest', readReceived, {
    onSuccess: () => {
      setDescription('');
      setReference('');
    },
  });
  const text = description.trim();
  const valid = [...text].length >= RELEASE_DESCRIPTION_MIN && [...text].length <= RELEASE_DESCRIPTION_MAX && [...reference.trim()].length <= RELEASE_REFERENCE_MAX;

  if (send.isError && isActionMissing(send.error))
    return (
      <div className="mx-auto flex max-w-2xl flex-col gap-4">
        <PageHeader title={t('release.title')} />
        <Card padded={false}>
          <NotAvailableYet />
        </Card>
      </div>
    );
  return (
    <div className="mx-auto flex max-w-2xl flex-col gap-4">
      <PageHeader title={t('release.title')} subtitle={t('release.intro')} />
      {send.isSuccess && <Callout tone="success">{t('release.submitted')}</Callout>}
      {send.isError && <Callout tone="danger">{errorText(send.error)}</Callout>}
      <Card>
        <form
          className="flex flex-col gap-3"
          data-release-form
          onSubmit={(e) => {
            e.preventDefault();
            if (!valid) return;
            const ref = reference.trim();
            send.mutate(ref ? { description: text, reference: ref } : { description: text });
          }}
        >
          <Label>
            {t('release.field.description')}
            <Textarea value={description} maxLength={RELEASE_DESCRIPTION_MAX} rows={5} required onChange={(e) => setDescription(e.target.value)} />
          </Label>
          <Label>
            {t('release.field.reference')}
            <Input value={reference} maxLength={RELEASE_REFERENCE_MAX} onChange={(e) => setReference(e.target.value)} />
          </Label>
          <div>
            <Button type="submit" variant="primary" loading={send.isPending} disabled={!valid}>
              {t('release.submit')}
            </Button>
          </div>
        </form>
      </Card>
    </div>
  );
}
