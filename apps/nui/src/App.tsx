// SPDX-License-Identifier: GPL-3.0-only
// Tablet root. The root element stays mounted while closed but has visibility:hidden (IMPLEMENTATION.md §4.7), so
// reopening repaints instead of re-mounting, and the router keeps the last page.
import { MemoryRouter } from 'react-router';
import { Button, EmptyState, IconButton, IconClose, useT } from '@fredpd/ui';
import { useTablet } from './tablet/TabletContext';
import { useFirstPaintLog } from './tablet/firstPaint';
import { TabletRoutes } from './routes';
import { isEnvBrowser } from './utils/env';
import { openMockTablet } from './mock/dev';

export function App() {
  const t = useT();
  const { visible, session, invalidOpen, openedAt, requestClose } = useTablet();
  useFirstPaintLog(visible, openedAt);

  return (
    <>
      <div
        id="fredpd-tablet"
        data-open={visible}
        style={{ visibility: visible ? 'visible' : 'hidden' }}
        className="fixed inset-0 flex items-center justify-center p-[3vh]"
      >
        <div className="relative h-full max-h-[900px] w-full max-w-[1440px] overflow-hidden rounded-2xl border-[10px] border-black bg-canvas text-fg">
          {invalidOpen || !session ? (
            <div className="flex h-full flex-col">
              <div className="flex justify-end p-2">
                <IconButton label={t('tablet.close')} icon={<IconClose />} onClick={requestClose} />
              </div>
              {invalidOpen && <EmptyState title={t('errors.unknown')} className="flex-1" />}
            </div>
          ) : (
            // A new character gets a fresh router (no page from the previous one).
            <MemoryRouter key={session.me.citizenid}>
              <TabletRoutes />
            </MemoryRouter>
          )}
        </div>
      </div>
      {import.meta.env.DEV && isEnvBrowser() && !visible && (
        <div className="fixed bottom-4 left-4">
          <Button variant="primary" onClick={() => openMockTablet()}>
            {t('tablet.open')}
          </Button>
        </div>
      )}
    </>
  );
}
