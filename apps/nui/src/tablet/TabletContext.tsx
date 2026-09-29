// SPDX-License-Identifier: GPL-3.0-only
// Tablet session state driven by Lua messages (see messages.ts):
// - open: store the payload, show the root, tell TanStack Query the "window" is focused (refetches stale data);
// - close: hide the root, unfocus;
// - push: invalidate queries whose key starts with the topic and notify subscribers (no polling anywhere). While
//   closed the queries are only marked stale (no fetch); the focus on the next open refetches them (§4.7);
// - Esc (while open) and requestClose(): hide at once and call fetchNui('close') so Lua releases NUI focus.
import { createContext, useCallback, useContext, useEffect, useEffectEvent, useMemo, useRef, useState } from 'react';
import type { ReactNode } from 'react';
import { focusManager } from '@tanstack/react-query';
import type { QueryClient } from '@tanstack/react-query';
import { UnitCodeSchema } from '@fredpd/types/actions';
import type { MdtOpenPayload } from '@fredpd/types/actions';
import type { GrantSet } from '@fredpd/types/grants';
import { fetchNui } from '../utils/fetchNui';
import { parseNuiMessage } from './messages';

export type PushListener = (payload: unknown) => void;

export interface TabletState {
  visible: boolean;
  /** Last valid open payload; null before the first open or after an invalid one. */
  session: MdtOpenPayload | null;
  /** The last open message could not be read (the tablet shows an error and can be closed). */
  invalidOpen: boolean;
  /** performance.now() when the last open message arrived (first-paint measurement). */
  openedAt: number | null;
}

export interface TabletContextValue extends TabletState {
  requestClose: () => void;
  /** Live updates for a push topic; returns the unsubscribe function. */
  subscribe: (topic: string, listener: PushListener) => () => void;
}

const TabletContext = createContext<TabletContextValue | null>(null);

const INITIAL: TabletState = { visible: false, session: null, invalidOpen: false, openedAt: null };

/**
 * MdtOpenPayload.unit is the first held unit in config/units.json order, which is GrantSet.units[0] (§C2 orders
 * `units` by unitOrder). A grants push recomputes it so nav priority, the Hem variant and the unit label follow.
 */
export function primaryUnit(grants: GrantSet): string | null {
  const first = grants.units[0];
  return first !== undefined && UnitCodeSchema.safeParse(first).success ? first : null;
}

export interface TabletProviderProps {
  queryClient: QueryClient;
  /**
   * Called once the window "message" listener is attached (after each attach under StrictMode). Browser dev mode
   * sends its mock `open` from here: a message dispatched before this point is lost.
   */
  onReady?: () => void;
  children: ReactNode;
}

export function TabletProvider({ queryClient, onReady, children }: TabletProviderProps) {
  const [state, setState] = useState<TabletState>(INITIAL);
  const [listeners] = useState(() => new Map<string, Set<PushListener>>());
  // Visibility as of the last message, updated synchronously: a push can arrive right after a close, before React
  // has rendered the new state, and must already see the tablet as closed.
  const visibleRef = useRef(false);

  // Hidden and unfocused go together: TanStack Query refetches stale queries when focus returns on open.
  const setShown = useCallback((visible: boolean) => {
    visibleRef.current = visible;
    focusManager.setFocused(visible);
  }, []);

  const requestClose = useCallback(() => {
    setState((s) => ({ ...s, visible: false }));
    setShown(false);
    fetchNui('close').catch((err: unknown) => console.error('[fredpd] close callback failed', err));
  }, [setShown]);

  const subscribe = useCallback(
    (topic: string, listener: PushListener) => {
      const set = listeners.get(topic) ?? new Set<PushListener>();
      set.add(listener);
      listeners.set(topic, set);
      return () => {
        set.delete(listener);
      };
    },
    [listeners],
  );

  const onMessage = useEffectEvent((event: MessageEvent) => {
    const message = parseNuiMessage(event.data);
    if (!message) return;
    switch (message.action) {
      case 'open': {
        const payload = message.payload;
        if (!payload) console.error('[fredpd] invalid open payload', event.data);
        // Another character on the same client must not see the previous one's cached records.
        if (payload && state.session && payload.me.citizenid !== state.session.me.citizenid) queryClient.clear();
        setState((s) => ({
          visible: true,
          session: payload ?? s.session,
          invalidOpen: payload === null,
          openedAt: performance.now(),
        }));
        setShown(true);
        break;
      }
      case 'close':
        setState((s) => ({ ...s, visible: false }));
        setShown(false);
        break;
      case 'grants':
        setState((s) => (s.session ? { ...s, session: { ...s.session, grants: message.grants, unit: primaryUnit(message.grants) } } : s));
        break;
      case 'push':
        // Closed: mark stale only, so a push in flight across a close does not fetch through Lua; open refetches.
        void queryClient.invalidateQueries({ queryKey: [message.topic], refetchType: visibleRef.current ? 'active' : 'none' });
        listeners.get(message.topic)?.forEach((listener) => listener(message.payload));
        break;
    }
  });

  const notifyReady = useEffectEvent(() => onReady?.());

  useEffect(() => {
    const handler = (event: MessageEvent) => onMessage(event);
    window.addEventListener('message', handler);
    notifyReady();
    return () => window.removeEventListener('message', handler);
  }, []);

  // Esc always closes the tablet (IMPLEMENTATION.md §5.2), whatever has focus inside it.
  useEffect(() => {
    if (!state.visible) return;
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return;
      event.preventDefault();
      requestClose();
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [state.visible, requestClose]);

  const value = useMemo<TabletContextValue>(() => ({ ...state, requestClose, subscribe }), [state, requestClose, subscribe]);

  return <TabletContext value={value}>{children}</TabletContext>;
}

export function useTablet(): TabletContextValue {
  const ctx = useContext(TabletContext);
  if (!ctx) throw new Error('useTablet() outside <TabletProvider>');
  return ctx;
}

/** The open session; only valid below a component that renders when `session` is set (TabletRoutes). */
export function useSession(): MdtOpenPayload {
  const { session } = useTablet();
  if (!session) throw new Error('useSession() before the tablet was opened');
  return session;
}

/** Subscribes to a push topic for the lifetime of the calling component. */
export function usePush(topic: string, listener: PushListener): void {
  const { subscribe } = useTablet();
  const onPush = useEffectEvent(listener);
  useEffect(() => subscribe(topic, (payload) => onPush(payload)), [subscribe, topic]);
}
