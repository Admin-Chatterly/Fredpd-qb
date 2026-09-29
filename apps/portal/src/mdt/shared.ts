// SPDX-License-Identifier: GPL-3.0-only
// The one place the portal reaches into the tablet app's shared MDT layer (apps/nui/src: typed client over the
// host's transport, errors, formatting, nav model, page building blocks). The page components themselves are
// lazy-imported in ./pages.tsx so each stays its own chunk. Why the pages live in apps/nui and not in packages/ui:
// docs/modules/portal.md "Shared pages" (packages/ui cannot resolve react-query/react-router/cytoscape without a
// dependency change + install).
export { MdtClientError, errorLocaleKey as mdtErrorLocaleKey, isRetryable, readErrorResponse, toMdtClientError, useErrorText } from '../../../nui/src/api/errors';
export { mdtQueryOptions, useMdtMutation, useMdtQuery, useTransport } from '../../../nui/src/api/hooks';
export { callMdt } from '../../../nui/src/api/client';
export { fmtDate, fmtDateTime, fmtTime, noticeOwner, officerLabel, unitLabel } from '../../../nui/src/format';
export { NAV_ENTRIES, allowedNavEntries, activeNavId, canSeePage } from '../../../nui/src/nav';
export type { NavEntry } from '../../../nui/src/nav';
export { PERMS, hasPerm as hasMdtPerm, usePerm } from '../../../nui/src/perms';
export { useSession as useMdtSession } from '../../../nui/src/session';
export { Callout, ErrorState, Facts, PageSpinner, QueryView } from '../../../nui/src/components/Common';
export { MutationError } from '../../../nui/src/components/Fields';
export { RequirePage } from '../../../nui/src/components/RequirePage';
export { HeaderSearch } from '../../../nui/src/components/HeaderSearch';
export { personPath } from '../../../nui/src/search';
