// SPDX-License-Identifier: GPL-3.0-only
// Public share page (/share/:token; IMPLEMENTATION.md §4.6 "Shares", §5.3): no login. The service serves index.html
// for /share/:token and the SPA reads the share as JSON from GET /api/share/:token (the service also answers
// /share/:token itself with JSON for `Accept: application/json`; the /api path needs no content negotiation, so no
// cache or proxy can mix the two). The service asks FXServer (fredpd_records viewShare: counted and audited on every view). Unknown, expired or revoked →
// 404 → "Länken har gått ut." The content is already cut at the link's level by the server; this page renders only
// the listed fields (POI: name, level, status, summary, warnings, photo, updated; never a citizenid or an officer).
import { useQuery } from '@tanstack/react-query';
import { useParams } from 'react-router';
import { Card, EmptyState, IconShield, PoiSheet, Spinner, useI18n } from '@fredpd/ui';
import { ReleasedContentView } from '../components/ReleasedContentView';
import { readShareView } from '../mdt/extra';
import type { ShareView } from '../mdt/extra';
import { fmtDateTime } from '../mdt/shared';

export const SHARE_TOKEN_RE = /^[A-Za-z0-9_-]{43}$/;
export const shareApiPath = (token: string) => `/api/share/${encodeURIComponent(token)}`;

export class ShareFetchError extends Error {
  constructor(readonly status: number) {
    super(`share ${status}`);
    this.name = 'ShareFetchError';
  }
}

async function fetchShare(token: string): Promise<ShareView> {
  let response: Response;
  try {
    response = await fetch(shareApiPath(token), { headers: { accept: 'application/json' }, credentials: 'omit' });
  } catch {
    throw new ShareFetchError(0);
  }
  if (!response.ok) throw new ShareFetchError(response.status);
  let body: unknown;
  try {
    body = JSON.parse(await response.text()) as unknown;
  } catch {
    throw new ShareFetchError(502);
  }
  const view = readShareView(body);
  if (!view) throw new ShareFetchError(502);
  return view;
}

function Body({ view }: { view: ShareView }) {
  const i18n = useI18n();
  const { t, tx } = i18n;
  const content = view.content;
  if (!content) return <EmptyState title={tx('portal.share.withheld')} />;
  if (content.type === 'poi') {
    // Copy only the sheet's public fields: nothing else from the answer can reach PoiSheet.
    return (
      <PoiSheet
        masked
        data={{
          name: content.name,
          level: content.level,
          status: content.status,
          summary: content.summary,
          warnings: content.warnings,
          photoUrl: content.photoUrl,
          updatedAt: content.updatedAt ? fmtDateTime(i18n, content.updatedAt) : null,
        }}
      />
    );
  }
  return (
    <Card>
      <p className="mb-2 text-xs text-muted">{t('release.masked')}</p>
      <ReleasedContentView content={content} />
    </Card>
  );
}

export function SharePage() {
  const i18n = useI18n();
  const { t } = i18n;
  const { token = '' } = useParams();
  const valid = SHARE_TOKEN_RE.test(token);
  const share = useQuery({
    queryKey: ['share', token],
    queryFn: () => fetchShare(token),
    enabled: valid,
    retry: false,
    // Each view is logged: never refetch behind the viewer's back.
    staleTime: Infinity,
    refetchOnWindowFocus: false,
  });

  let body;
  if (!valid || (share.error instanceof ShareFetchError && share.error.status === 404)) body = <EmptyState title={t('portal.share.expired')} />;
  else if (share.isPending) body = <div className="flex justify-center py-10"><Spinner size="lg" /></div>;
  else if (share.isError) body = <EmptyState title={t(share.error instanceof ShareFetchError && share.error.status === 0 ? 'errors.network' : 'errors.serviceUnavailable')} />;
  else body = <Body view={share.data} />;

  return (
    <div className="mx-auto flex min-h-full max-w-3xl flex-col gap-4 p-6" data-share-page>
      <p className="flex items-center gap-2 text-sm text-muted">
        <IconShield className="text-accent-text" />
        {t('portal.title')}
      </p>
      {body}
      {share.isSuccess && (
        <footer className="flex flex-col gap-1 text-xs text-muted">
          <p>{t('portal.share.expires', { date: fmtDateTime(i18n, share.data.expiresAt) })}</p>
          <p>{t('portal.share.logged')}</p>
        </footer>
      )}
    </div>
  );
}
