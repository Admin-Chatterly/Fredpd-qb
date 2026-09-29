// SPDX-License-Identifier: GPL-3.0-only
import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { QueryClientProvider, focusManager } from '@tanstack/react-query';
import { I18nProvider } from '@fredpd/ui';
import './index.css';
import { App } from './App';
import { i18n } from './i18n';
import { createQueryClient } from './queryClient';
import { TabletProvider } from './tablet/TabletContext';
import { isEnvBrowser } from './utils/env';
import { openMockTablet, registerDevMocks } from './mock/dev';

const queryClient = createQueryClient();
// The tablet starts closed: CEF reports the page as focused, but nothing should refetch until Lua opens it.
focusManager.setFocused(false);

const devBrowser = import.meta.env.DEV && isEnvBrowser();
if (devBrowser) {
  document.body.dataset.devBackdrop = 'true';
  registerDevMocks();
}

// Dev only: open the tablet with mock data once the message listener exists (StrictMode attaches it twice; one
// open is enough). Sent from TabletProvider's onReady because a message dispatched earlier would be lost.
let mockOpened = false;
const onReady = devBrowser
  ? () => {
      if (mockOpened) return;
      mockOpened = true;
      openMockTablet();
    }
  : undefined;

const container = document.getElementById('root');
if (container) {
  createRoot(container).render(
    <StrictMode>
      <I18nProvider i18n={i18n}>
        <QueryClientProvider client={queryClient}>
          <TabletProvider queryClient={queryClient} onReady={onReady}>
            <App />
          </TabletProvider>
        </QueryClientProvider>
      </I18nProvider>
    </StrictMode>,
  );
}
