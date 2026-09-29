// SPDX-License-Identifier: GPL-3.0-only
// Dev builds log open -> first paint (IMPLEMENTATION.md §5.2 acceptance: < 300 ms on the host). The second
// animation frame callback runs after the frame that showed the tablet has been painted.
import { useEffect } from 'react';
import { IS_DEV_BUILD } from '../utils/env';

export function useFirstPaintLog(visible: boolean, openedAt: number | null): void {
  useEffect(() => {
    if (!IS_DEV_BUILD || !visible || openedAt === null) return;
    let second = 0;
    const first = requestAnimationFrame(() => {
      second = requestAnimationFrame(() => {
        console.info(`[fredpd] open -> first paint ${(performance.now() - openedAt).toFixed(1)} ms`);
      });
    });
    return () => {
      cancelAnimationFrame(first);
      cancelAnimationFrame(second);
    };
  }, [visible, openedAt]);
}
