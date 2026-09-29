// SPDX-License-Identifier: GPL-3.0-only
import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { BrowserRouter } from 'react-router';
import { QueryClientProvider } from '@tanstack/react-query';
import { I18nProvider } from '@fredpd/ui';
import './index.css';
import { App } from './App';
import { i18n } from './i18n';
import { createPortalQueryClient } from './queryClient';
import { SessionProvider } from './session';

const queryClient = createPortalQueryClient();
// The browser tab is player-facing text too: localised here, index.html only has a neutral placeholder.
document.title = i18n.t('portal.title');

const container = document.getElementById('root');
if (container) {
  createRoot(container).render(
    <StrictMode>
      <I18nProvider i18n={i18n}>
        <QueryClientProvider client={queryClient}>
          <BrowserRouter>
            <SessionProvider>
              <App />
            </SessionProvider>
          </BrowserRouter>
        </QueryClientProvider>
      </I18nProvider>
    </StrictMode>,
  );
}
