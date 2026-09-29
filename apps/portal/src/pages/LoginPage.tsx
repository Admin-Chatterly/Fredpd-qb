// SPDX-License-Identifier: GPL-3.0-only
// Login with Discord plus the GDPR privacy notice (IMPLEMENTATION.md §8.8). The OAuth callback comes back to
// `/?loginError=<code>` on failure (LOGIN_ERROR_CODES).
import { useLocation, useSearchParams } from 'react-router';
import { LOGIN_ERROR_LOCALE_KEYS, LoginErrorCodeSchema } from '@fredpd/types/actions';
import type { LocaleKey } from '@fredpd/types/locale-keys';
import { Card, IconShield, buttonClass, useT } from '@fredpd/ui';
import { AUDIT_RETENTION_DAYS } from '../i18n';
import { useSession } from '../session';

export function LoginPage() {
  const t = useT();
  const [params] = useSearchParams();
  const location = useLocation();
  const { expired } = useSession();

  const loginError = LoginErrorCodeSchema.safeParse(params.get('loginError'));
  const loggedOut = (location.state as { loggedOut?: boolean } | null)?.loggedOut === true;
  let message: { key: LocaleKey; tone: 'error' | 'info' } | null = null;
  if (loginError.success) message = { key: LOGIN_ERROR_LOCALE_KEYS[loginError.data], tone: 'error' };
  else if (expired) message = { key: 'portal.sessionExpired', tone: 'info' };
  else if (loggedOut) message = { key: 'portal.loggedOut', tone: 'info' };

  return (
    <div className="flex min-h-full items-center justify-center p-6">
      <div className="flex w-full max-w-md flex-col gap-4">
        <Card>
          <div className="flex flex-col gap-4">
            <div className="flex items-center gap-2 text-sm text-muted">
              <IconShield className="text-accent-text" />
              {t('portal.title')}
            </div>
            <h1 className="text-xl font-semibold">{t('portal.login.title')}</h1>
            {message && (
              <p
                role={message.tone === 'error' ? 'alert' : 'status'}
                className={
                  message.tone === 'error'
                    ? 'rounded-md border border-danger/40 bg-danger/10 px-3 py-2 text-sm text-danger'
                    : 'rounded-md border border-line-strong bg-raised px-3 py-2 text-sm text-muted'
                }
              >
                {t(message.key)}
              </p>
            )}
            {/* A full page load: /auth/discord redirects to Discord. */}
            <a href="/auth/discord" className={buttonClass('primary', 'md', 'w-full')}>
              {t('portal.login.discord')}
            </a>
          </div>
        </Card>
        <Card title={t('portal.privacy.title')}>
          <div id="privacy" className="flex flex-col gap-2 text-sm text-muted">
            <p>{t('portal.privacy.data')}</p>
            <p>{t('portal.privacy.retention', { days: AUDIT_RETENTION_DAYS })}</p>
            <p>{t('portal.privacy.rights')}</p>
          </div>
        </Card>
      </div>
    </div>
  );
}
