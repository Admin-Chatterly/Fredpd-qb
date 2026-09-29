// SPDX-License-Identifier: GPL-3.0-only
// Request/response shapes shared by fredpd_service (/api, /internal, /upload, /ws), the portal and the NUI
// (IMPLEMENTATION.md §4.3: "actions listed in packages/types/src/actions.ts, zod-validated on both ends").
// docs/contracts.md §C6 (endpoints) and §C10 (permissions admin API); service decisions in docs/modules/service.md.
// Add the schemas of new actions here, next to the ones they resemble.
import { z } from 'zod';
import { GrantKeySchema, GrantSetSchema, GrantTypeSchema, GrantEffectSchema, RoleGrantRowSchema, RoleRowSchema } from './grants';
import type { LocaleKey } from './locale-keys';

// ---------------------------------------------------------------------------------------------------------------
// Identifiers

/** Discord snowflake as FXServer validates it (fredpd_core/server/http.js): 1–20 digits. */
export const DiscordIdSchema = z.string().regex(/^\d{1,20}$/);
/** qbx_core citizenid (players.citizenid VARCHAR(50)). */
export const CitizenIdSchema = z.string().regex(/^[A-Za-z0-9_-]{1,50}$/);

// ---------------------------------------------------------------------------------------------------------------
// Errors

/**
 * Every non-2xx JSON answer of fredpd_service is `{ error: <code> }` (plus optional details). The portal shows the
 * mapped locale key. `unauthorized` is the HMAC failure of §C5 (FXServer, never shown to a player).
 */
export const API_ERROR_CODES = [
  'unauthenticated', 'unauthorized', 'forbidden', 'csrf', 'not_found', 'invalid_body', 'too_large',
  'unsupported_type', 'rate_limited', 'unavailable', 'internal',
] as const;
export const ApiErrorCodeSchema = z.enum(API_ERROR_CODES);
export type ApiErrorCode = z.infer<typeof ApiErrorCodeSchema>;

export const ApiErrorSchema = z.object({ error: z.string(), detail: z.string().optional() });
export type ApiError = z.infer<typeof ApiErrorSchema>;

export const API_ERROR_LOCALE_KEYS = {
  unauthenticated: 'errors.unauthenticated',
  unauthorized: 'errors.unauthorized',
  forbidden: 'errors.unauthorized',
  csrf: 'errors.csrf',
  not_found: 'errors.notFound',
  invalid_body: 'errors.validation',
  too_large: 'errors.uploadTooLarge',
  unsupported_type: 'errors.uploadType',
  rate_limited: 'errors.rateLimited',
  unavailable: 'errors.serviceUnavailable',
  internal: 'errors.unknown',
} as const satisfies Record<ApiErrorCode, LocaleKey>;

/**
 * The OAuth callback redirects to `PUBLIC_URL/` on success and to `PUBLIC_URL/?loginError=<code>` on failure
 * (a redirect cannot carry a JSON body).
 */
export const LOGIN_ERROR_CODES = ['failed', 'notMember', 'unavailable'] as const;
export const LoginErrorCodeSchema = z.enum(LOGIN_ERROR_CODES);
export type LoginErrorCode = z.infer<typeof LoginErrorCodeSchema>;
export const LOGIN_ERROR_LOCALE_KEYS = {
  failed: 'portal.login.failed',
  notMember: 'portal.login.notMember',
  unavailable: 'errors.serviceUnavailable',
} as const satisfies Record<LoginErrorCode, LocaleKey>;

// ---------------------------------------------------------------------------------------------------------------
// Session (GET /api/session)

export const SessionUserSchema = z.object({
  discordId: DiscordIdSchema,
  /** Resolved like an officer name (OFFICER_NAME_SOURCE; IMPLEMENTATION.md §4.9). */
  displayName: z.string(),
  /** Service-relative avatar URL (`/avatar/:discordId?v=…`), never the Discord CDN. */
  avatarUrl: z.string().nullable(),
  /** Character picked for this session, null until one is chosen. */
  citizenid: CitizenIdSchema.nullable(),
  /** Client copy of the user's grants, for building menus only; the server checks again on every call. */
  grants: GrantSetSchema,
});
export type SessionUser = z.infer<typeof SessionUserSchema>;

/** Logged out: `{ user: null, csrfToken: null }` (200, so the portal can boot without an error). */
export const SessionResponseSchema = z.object({
  user: SessionUserSchema.nullable(),
  /** Send as the `x-csrf-token` header on every POST/PUT/PATCH/DELETE (docs/contracts.md §C10). */
  csrfToken: z.string().nullable(),
});
export type SessionResponse = z.infer<typeof SessionResponseSchema>;

export const CSRF_HEADER = 'x-csrf-token';

// ---------------------------------------------------------------------------------------------------------------
// Permissions admin (docs/contracts.md §C10, portal "Behörigheter")

export const GrantCatalogEntrySchema = z.object({ type: GrantTypeSchema, keys: z.array(z.string()) });
export type GrantCatalogEntry = z.infer<typeof GrantCatalogEntrySchema>;

/** GET /api/admin/roles. Roles include deleted ones (flagged) so their stored grants stay visible. */
export const AdminRolesResponseSchema = z.object({
  roles: z.array(RoleRowSchema.extend({ colour: z.number().int().nonnegative() })),
  grants: z.array(RoleGrantRowSchema),
  catalog: z.array(GrantCatalogEntrySchema),
});
export type AdminRolesResponse = z.infer<typeof AdminRolesResponseSchema>;

/**
 * A unit code as fredpd_core accepts it inside a GrantSet (http.js UNIT_RE, perms.lua UNIT_PATTERN + 32 bytes).
 * GRANT_KEY_PATTERN is wider (`.`, `:`, 64 chars): a unit key outside this one would make FXServer reject the
 * holder's whole resolved set, leaving the officer with no grants in game.
 */
export const UNIT_CODE_RE = /^[A-Za-z0-9_-]{1,32}$/;
export const UnitCodeSchema = z.string().regex(UNIT_CODE_RE);

export const AdminRoleGrantSchema = z
  .object({
    grantType: GrantTypeSchema,
    grantKey: GrantKeySchema,
    effect: GrantEffectSchema,
  })
  .check((ctx) => {
    const { grantType, grantKey } = ctx.value;
    if (grantType === 'unit' && grantKey !== '*' && !UNIT_CODE_RE.test(grantKey)) {
      ctx.issues.push({ code: 'custom', message: 'unit key must be * or a unit code ([A-Za-z0-9_-]{1,32})', input: grantKey, path: ['grantKey'] });
    }
  });
export type AdminRoleGrant = z.infer<typeof AdminRoleGrantSchema>;

/** Most rows one role may hold; a larger body is refused rather than written. */
export const MAX_GRANTS_PER_ROLE = 500;

/**
 * PUT /api/admin/roles/:discordRoleId/grants. Replaces the role's rows. A (grantType, grantKey) pair may appear
 * once: fredpd_role_grants has UNIQUE (discord_role_id, grant_type, grant_key), so one row either allows or denies.
 */
export const AdminRoleGrantsPutBodySchema = z
  .object({ grants: z.array(AdminRoleGrantSchema).max(MAX_GRANTS_PER_ROLE) })
  .check((ctx) => {
    const seen = new Set<string>();
    ctx.value.grants.forEach((g, i) => {
      const key = `${g.grantType}:${g.grantKey}`;
      if (seen.has(key)) ctx.issues.push({ code: 'custom', message: `duplicate grant ${key}`, input: g, path: ['grants', i] });
      seen.add(key);
    });
  });
export type AdminRoleGrantsPutBody = z.infer<typeof AdminRoleGrantsPutBodySchema>;

/** `recomputed` = online players FXServer re-fetched grants for (0 when FXServer is unreachable). */
export const AdminRoleGrantsPutResponseSchema = z.object({ ok: z.literal(true), recomputed: z.number().int().nonnegative() });
export type AdminRoleGrantsPutResponse = z.infer<typeof AdminRoleGrantsPutResponseSchema>;

export const DiscordRoleIdParamSchema = z.object({ discordRoleId: DiscordIdSchema });

// ---------------------------------------------------------------------------------------------------------------
// Internal (FXServer -> service, HMAC; docs/contracts.md §C5/§C6)

/** GET /internal/grants/:discordId. `member` = the user is in the Discord guild. */
export const GrantsResponseSchema = z.object({
  discordId: DiscordIdSchema,
  member: z.boolean(),
  grants: GrantSetSchema,
});
export type GrantsResponse = z.infer<typeof GrantsResponseSchema>;

export const INTERNAL_EVENT_TYPES = [
  'alertCreated', 'alertAssigned', 'alertClosed', 'unitsChanged', 'playerJoined', 'playerDropped',
] as const;
export const InternalEventTypeSchema = z.enum(INTERNAL_EVENT_TYPES);
export type InternalEventType = z.infer<typeof InternalEventTypeSchema>;

/**
 * POST /internal/events body, and exactly the message a /ws subscriber receives. The payload is passed through
 * untouched (the producing module owns its shape; tighten it here per type when that module is built).
 */
export const InternalEventSchema = z.strictObject({
  type: InternalEventTypeSchema,
  payload: z.unknown(),
});
export type InternalEvent = z.infer<typeof InternalEventSchema>;
export const WsMessageSchema = InternalEventSchema;
export type WsMessage = InternalEvent;

export const InternalEventResponseSchema = z.object({ ok: z.literal(true), delivered: z.number().int().nonnegative() });

// ---------------------------------------------------------------------------------------------------------------
// Uploads (POST /upload)

export const UPLOAD_MAX_BYTES = 5 * 1024 * 1024;
export const UPLOAD_MIME_TYPES = ['image/png', 'image/jpeg', 'image/webp'] as const;
export const UploadMimeSchema = z.enum(UPLOAD_MIME_TYPES);
export type UploadMime = z.infer<typeof UploadMimeSchema>;

/**
 * HMAC variant (FXServer, e.g. a screenshot-basic data URI): JSON instead of multipart, because §C5 signs a text
 * body. `data` is base64 or a `data:image/…;base64,` URI; the portal variant is multipart field `file`.
 */
export const InternalUploadBodySchema = z.strictObject({
  data: z.string().min(1),
  citizenid: CitizenIdSchema.optional(),
  discordId: DiscordIdSchema.optional(),
});
export type InternalUploadBody = z.infer<typeof InternalUploadBodySchema>;

export const UploadResponseSchema = z.object({
  ok: z.literal(true),
  id: z.string().regex(/^[0-9a-f]{32}$/),
  fileName: z.string(),
  mime: UploadMimeSchema,
  size: z.number().int().positive(),
});
export type UploadResponse = z.infer<typeof UploadResponseSchema>;

// ---------------------------------------------------------------------------------------------------------------
// NUI

/** Payload the tablet receives when it opens (fredpd_mdt). `grants` is the client copy (menus only). */
export const MdtOpenPayloadSchema = z.object({
  grants: GrantSetSchema,
  /** Primary unit code (first held unit in config/units.json order), null without a unit grant. */
  unit: UnitCodeSchema.nullable(),
  me: z.object({
    citizenid: CitizenIdSchema,
    displayName: z.string(),
    callsign: z.string().nullable(),
  }),
});
export type MdtOpenPayload = z.infer<typeof MdtOpenPayloadSchema>;
