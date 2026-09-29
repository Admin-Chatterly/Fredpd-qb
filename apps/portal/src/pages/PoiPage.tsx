// SPDX-License-Identifier: GPL-3.0-only
// POI-blad (/person/:cid/poi; IMPLEMENTATION.md §5.3): getPoi, rendered with packages/ui's PoiSheet and printed with
// the portal's print CSS (index.css: sidebar, header and every [data-print-hide] are dropped, the sheet prints black
// on white). Full view: "Handläggare", Skriv ut and a share link (createShare, expiry mandatory, every view logged;
// the link shows at most the creator's tier). Masked: banner, no handler, no share. Kontaktnotis: only the Notice.
import { useState } from 'react';
import { Link, useParams } from 'react-router';
import { Button, Card, EmptyState, IconPrint, Label, Notice, PageHeader, PoiSheet, fieldClass, useI18n } from '@fredpd/ui';
import { readPoiView, readShareCreated, useExtraMutation, useExtraQuery } from '../mdt/extra';
import type { PoiContent, ShareCreated } from '../mdt/extra';
import { Callout, QueryView, fmtDateTime, noticeOwner, officerLabel, personPath, useErrorText, useMdtSession } from '../mdt/shared';
import { NotAvailableYet, isActionMissing } from '../components/NotAvailableYet';

export const SHARE_HOURS = [1, 4, 12, 24, 72, 168] as const;

function ShareBox({ citizenid }: { citizenid: string }) {
  const i18n = useI18n();
  const { t } = i18n;
  const errorText = useErrorText();
  const [hours, setHours] = useState<number>(24);
  const [copied, setCopied] = useState(false);
  const share = useExtraMutation<{ targetType: 'poi'; targetId: string; expiresInHours: number }, ShareCreated>('createShare', readShareCreated);
  const url = share.data ? `${window.location.origin}${share.data.path}` : null;
  return (
    <Card title={t('portal.share.create')} data-print-hide>
      <div className="flex flex-col gap-3">
        <div className="flex flex-wrap items-end gap-2">
          <Label className="w-48">
            {t('portal.share.duration')}
            <select className={fieldClass} value={hours} onChange={(e) => setHours(Number(e.target.value))}>
              {SHARE_HOURS.map((h) => (
                <option key={h} value={h}>
                  {h < 24 ? t('time.duration.hours', { count: h }) : t('time.duration.days', { count: h / 24 })}
                </option>
              ))}
            </select>
          </Label>
          <Button loading={share.isPending} onClick={() => share.mutate({ targetType: 'poi', targetId: citizenid, expiresInHours: hours })}>
            {t('portal.share.create')}
          </Button>
        </div>
        {share.isError && (isActionMissing(share.error) ? <NotAvailableYet /> : <Callout tone="danger">{errorText(share.error)}</Callout>)}
        {url && share.data && (
          <div className="flex flex-col gap-1 text-sm" data-share-url>
            <div className="flex items-center gap-2">
              <input readOnly value={url} className={`${fieldClass} flex-1 font-mono`} aria-label={t('common.share')} />
              <Button
                size="sm"
                onClick={() => {
                  void navigator.clipboard?.writeText(url).then(() => setCopied(true));
                }}
              >
                {t('common.copy')}
              </Button>
            </div>
            {copied && <p className="text-success">{t('portal.share.copied')}</p>}
            <p className="text-muted">{t('portal.share.expires', { date: fmtDateTime(i18n, share.data.expiresAt) })}</p>
            <p className="text-muted">{t('portal.share.logged')}</p>
          </div>
        )}
      </div>
    </Card>
  );
}

function Sheet({ name, citizenid, poi }: { name: string; citizenid: string; poi: PoiContent }) {
  const i18n = useI18n();
  const { me } = useMdtSession();
  const [printedAt] = useState(() => new Date().toISOString());
  const full = poi.visibility === 'full';
  return (
    <PoiSheet
      data={{
        name,
        citizenid,
        level: poi.level,
        status: poi.status,
        summary: poi.summary,
        warnings: poi.warnings,
        photoUrl: poi.photoUrl,
        handler: full && poi.owner ? officerLabel(poi.owner) : null,
        updatedAt: poi.updatedAt ? fmtDateTime(i18n, poi.updatedAt) : null,
      }}
      masked={!full}
      footer={i18n.t('poi.printedBy', { date: fmtDateTime(i18n, printedAt), name: me.displayName })}
    />
  );
}

export function PoiPage() {
  const i18n = useI18n();
  const { t, tx } = i18n;
  const { cid = '' } = useParams();
  const view = useExtraQuery('getPoi', { citizenid: cid }, readPoiView, cid !== '');
  return (
    <div className="flex flex-col gap-4" data-poi-page>
      <PageHeader
        title={t('poi.title')}
        actions={
          <span className="flex gap-2" data-print-hide>
            <Link to={personPath(cid)} className="text-sm text-accent-text hover:underline">
              {t('common.back')}
            </Link>
            {view.data?.poi && view.data.poi.visibility !== 'notice' && (
              <Button icon={<IconPrint size={16} />} onClick={() => window.print()} data-print-button>
                {t('common.print')}
              </Button>
            )}
          </span>
        }
      />
      {view.isError && isActionMissing(view.error) ? (
        <Card padded={false}>
          <NotAvailableYet />
        </Card>
      ) : (
        <QueryView query={view}>
          {(data) =>
            data.poi === null ? (
              <Card padded={false}>
                <EmptyState title={tx('poi.none', { name: data.name })} />
              </Card>
            ) : data.poi.visibility === 'notice' ? (
              <Notice subject={t('poi.title')} owner={noticeOwner(i18n, data.poi.contact)} />
            ) : (
              <>
                <Sheet name={data.name} citizenid={data.citizenid} poi={data.poi} />
                {data.poi.visibility === 'full' && <ShareBox citizenid={data.citizenid} />}
              </>
            )
          }
        </QueryView>
      )}
    </div>
  );
}
