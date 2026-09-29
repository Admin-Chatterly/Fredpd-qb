// SPDX-License-Identifier: GPL-3.0-only
// Small building blocks shared by the tablet pages: query states, status callouts, fact lists and the disabled
// "coming in phase 5" buttons.
import type { ReactNode } from 'react';
import type { UseQueryResult } from '@tanstack/react-query';
import { Button, EmptyState, Spinner, cn, useI18n } from '@fredpd/ui';
import type { ButtonProps } from '@fredpd/ui';
import { isRetryable, useErrorText } from '../api/errors';
import type { MdtClientError } from '../api/errors';

export function PageSpinner({ className }: { className?: string }) {
  return (
    <div className={cn('flex justify-center py-10', className)}>
      <Spinner size="lg" />
    </div>
  );
}

export function ErrorState({ error, onRetry, notFound, className }: { error: unknown; onRetry?: () => void; notFound?: string; className?: string }) {
  const { t } = useI18n();
  const errorText = useErrorText();
  const isNotFound = (error as MdtClientError | null)?.code === 'not_found';
  return (
    <EmptyState
      className={className}
      title={isNotFound && notFound ? notFound : errorText(error)}
      action={
        onRetry && isRetryable(error) ? (
          <Button size="sm" onClick={onRetry}>
            {t('common.retry')}
          </Button>
        ) : undefined
      }
    />
  );
}

export interface QueryViewProps<T> {
  query: UseQueryResult<T, MdtClientError>;
  children: (data: T) => ReactNode;
  /** Text for `not_found` (else errors.notFound). */
  notFound?: string;
  /** Shown while loading (default: a spinner). */
  loading?: ReactNode;
  className?: string;
}

/** Loading → spinner, error → localised message with retry, data → children. A disabled query renders nothing. */
export function QueryView<T>({ query, children, notFound, loading, className }: QueryViewProps<T>) {
  if (query.isPending) return query.fetchStatus === 'idle' ? null : (loading ?? <PageSpinner className={className} />);
  if (query.isError) return <ErrorState error={query.error} onRetry={() => void query.refetch()} notFound={notFound} className={className} />;
  return <>{children(query.data)}</>;
}

export type CalloutTone = 'neutral' | 'success' | 'warning' | 'danger';

const CALLOUT_TONES: Record<CalloutTone, string> = {
  neutral: 'border-line-strong bg-raised text-fg',
  success: 'border-success/40 bg-success/10 text-success',
  warning: 'border-warning/40 bg-warning/10 text-warning',
  danger: 'border-danger/40 bg-danger/10 text-danger',
};

/** Inline outcome of an action (role="status" so it is announced). */
export function Callout({ tone = 'neutral', title, children, className }: { tone?: CalloutTone; title?: ReactNode; children?: ReactNode; className?: string }) {
  return (
    <div role="status" data-tone={tone} className={cn('rounded-md border px-3 py-2 text-sm', CALLOUT_TONES[tone], className)}>
      {title && <p className="font-semibold">{title}</p>}
      {children && <div className={cn(title ? 'mt-0.5 text-fg' : undefined)}>{children}</div>}
    </div>
  );
}

export interface Fact {
  label: string;
  value: ReactNode;
}

/** Label/value pairs. Facts whose value is null/undefined/'' are left out (never render an absent field). */
export function Facts({ facts, className }: { facts: readonly (Fact | null | false)[]; className?: string }) {
  const shown = facts.filter((f): f is Fact => !!f && f.value !== null && f.value !== undefined && f.value !== '');
  if (shown.length === 0) return null;
  return (
    <dl className={cn('grid grid-cols-2 gap-x-6 gap-y-3 md:grid-cols-3', className)}>
      {shown.map((fact) => (
        <div key={fact.label} className="min-w-0">
          <dt className="text-xs text-muted">{fact.label}</dt>
          <dd className="truncate text-fg">{fact.value}</dd>
        </div>
      ))}
    </dl>
  );
}

/**
 * A button for a feature of a later phase: disabled, with the reason as tooltip. The tooltip sits on a wrapper
 * because disabled buttons get no pointer events (and so no native title tooltip).
 */
export function ComingSoonButton({ children, icon, variant = 'secondary' }: { children: ReactNode; icon?: ReactNode; variant?: ButtonProps['variant'] }) {
  const { t } = useI18n();
  const hint = t('common.comingPhase5');
  return (
    <span title={hint} data-coming-soon className="inline-flex">
      <Button variant={variant} icon={icon} disabled aria-description={hint}>
        {children}
      </Button>
    </span>
  );
}
