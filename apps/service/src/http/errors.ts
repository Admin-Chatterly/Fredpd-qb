// SPDX-License-Identifier: GPL-3.0-only
// One error shape for every route: `{ error: <ApiErrorCode>, detail? }` (packages/types/src/actions.ts). The portal
// maps the code to a locale key (API_ERROR_LOCALE_KEYS); no player-facing text is produced here.
import type { FastifyError, FastifyReply, FastifyRequest } from 'fastify';
import type { ZodType } from 'zod';
import type { ApiErrorCode } from '@fredpd/types/actions';
import { GatewayNotReadyError } from '../grants';

export class HttpError extends Error {
  override name = 'HttpError';
  constructor(
    readonly statusCode: number,
    readonly code: ApiErrorCode,
    readonly detail?: string,
  ) {
    super(detail ? `${code}: ${detail}` : code);
  }
}

/** Parse with zod or throw a 400 invalid_body naming the first bad field. */
export function parseOr400<T>(schema: ZodType<T>, value: unknown): T {
  const r = schema.safeParse(value);
  if (r.success) return r.data;
  const first = r.error.issues[0];
  throw new HttpError(400, 'invalid_body', first ? `${first.path.join('.') || '(root)'}: ${first.message}` : undefined);
}

/** Map anything thrown in a route or hook to the shared shape. */
export function errorHandler(error: FastifyError | HttpError | Error, request: FastifyRequest, reply: FastifyReply): void {
  if (error instanceof HttpError) {
    void reply.code(error.statusCode).send(error.detail ? { error: error.code, detail: error.detail } : { error: error.code });
    return;
  }
  if (error instanceof GatewayNotReadyError) {
    void reply.code(503).send({ error: 'unavailable', detail: 'discord' });
    return;
  }
  const e = error as FastifyError;
  const status = typeof e.statusCode === 'number' ? e.statusCode : 500;
  let code: ApiErrorCode;
  if (status === 413) code = 'too_large';
  else if (status === 415) code = 'unsupported_type';
  else if (status === 429) code = 'rate_limited';
  else if (status === 404) code = 'not_found';
  else if (status >= 400 && status < 500) code = 'invalid_body';
  else code = 'internal';
  if (status >= 500) request.log.error({ err: error }, 'request failed');
  void reply.code(status >= 400 && status < 600 ? status : 500).send({ error: code });
}
