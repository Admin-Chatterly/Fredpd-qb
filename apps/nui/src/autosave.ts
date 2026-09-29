// SPDX-License-Identifier: GPL-3.0-only
// Report draft autosave (IMPLEMENTATION.md §5.3, docs/contracts.md §C14): a draft is written ≥ AUTOSAVE_DELAY_MS after
// the LAST keystroke, and only if the editor still has focus and has unsaved input at that moment. It is a debounce:
// every input replaces the one pending timeout; there is no interval and nothing runs while the editor is idle,
// unfocused or clean (§4.7 "no setInterval"). Unmount cancels the pending timeout.
import { useCallback, useEffect, useRef } from 'react';

export const AUTOSAVE_DELAY_MS = 10_000;

export interface DraftAutosave {
  /** Call on every edit (keystroke, toolbar action). */
  onInput: () => void;
  /** Focus entered / left the editor (focus events bubble in React, so put them on the editor's wrapper). */
  onFocus: () => void;
  onBlur: () => void;
  /** The content was saved another way (Spara): nothing is dirty and the pending timeout is dropped. */
  markClean: () => void;
}

/**
 * `save` is called at most once per idle period; while it runs, new input marks the editor dirty again and starts a
 * new debounce. A failed save leaves the editor dirty (the next keystroke retries after the delay).
 */
export function useDraftAutosave(save: () => Promise<unknown> | void, delayMs: number = AUTOSAVE_DELAY_MS): DraftAutosave {
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const focused = useRef(false);
  const dirty = useRef(false);
  const saveRef = useRef(save);
  useEffect(() => {
    saveRef.current = save;
  });

  const clear = useCallback(() => {
    if (timer.current !== null) clearTimeout(timer.current);
    timer.current = null;
  }, []);

  const fire = useCallback(() => {
    timer.current = null;
    if (!focused.current || !dirty.current) return;
    dirty.current = false;
    const failed = () => {
      dirty.current = true;
    };
    try {
      const result = saveRef.current();
      if (result instanceof Promise) result.catch(failed);
    } catch {
      failed();
    }
  }, []);

  const onInput = useCallback(() => {
    dirty.current = true;
    clear();
    timer.current = setTimeout(fire, delayMs);
  }, [clear, delayMs, fire]);

  const onFocus = useCallback(() => {
    focused.current = true;
  }, []);
  const onBlur = useCallback(() => {
    focused.current = false;
  }, []);
  const markClean = useCallback(() => {
    dirty.current = false;
    clear();
  }, [clear]);

  useEffect(() => clear, [clear]);

  return { onInput, onFocus, onBlur, markClean };
}
