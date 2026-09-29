// SPDX-License-Identifier: GPL-3.0-only
// POST /upload (docs/contracts.md §C6, IMPLEMENTATION.md §4.6): images only (png/jpeg/webp, sniffed from the bytes,
// never trusted from the name or Content-Type), at most 5 MB -> 413, anything else -> 415.
//   portal: session cookie + x-csrf-token of a user with at least one allowed grant, multipart/form-data with one
//           file field
//   game:   HMAC-signed JSON { data: base64 | data URI, citizenid?, discordId? } (§C5 signs a text body)
// Files are written to UPLOAD_DIR as <random 32 hex>.<ext> and recorded in fredpd_uploads (+ audit upload.create).
import { createHash, randomBytes } from 'node:crypto';
import { mkdir, unlink, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { fileTypeFromBuffer } from 'file-type';
import { InternalUploadBodySchema, UPLOAD_MAX_BYTES, UPLOAD_MIME_TYPES } from '@fredpd/types/actions';
import type { UploadMime, UploadResponse } from '@fredpd/types/actions';
import type { AppContext } from '../context';
import { insertUpload } from '../db/repo';
import { HttpError, parseOr400 } from '../http/errors';
import { checkCsrf, hasHmacHeaders, isDirectLoopback, precheckHmacHeaders, requireHmac, sessionGrants } from '../http/guards';

const EXT: Record<UploadMime, string> = { 'image/png': 'png', 'image/jpeg': 'jpg', 'image/webp': 'webp' };
/** Base64 of 5 MB plus JSON overhead; the decoded size is checked exactly afterwards. */
const JSON_BODY_LIMIT = Math.ceil((UPLOAD_MAX_BYTES * 4) / 3) + 64 * 1024;
const DATA_URI_RE = /^data:[\w.+/-]+;base64,/;
const BASE64_RE = /^[A-Za-z0-9+/]*={0,2}$/;

function decodeBase64(data: string): Buffer {
  const b64 = data.replace(DATA_URI_RE, '').replace(/\s+/g, '');
  if (!BASE64_RE.test(b64) || b64.length % 4 === 1) throw new HttpError(400, 'invalid_body', 'data: not base64');
  // Exact decoded length before allocating: 3 bytes per 4 characters minus padding.
  const padding = b64.endsWith('==') ? 2 : b64.endsWith('=') ? 1 : 0;
  if (Math.floor((b64.length * 3) / 4) - padding > UPLOAD_MAX_BYTES) throw new HttpError(413, 'too_large');
  return Buffer.from(b64, 'base64');
}

async function readMultipartFile(request: FastifyRequest): Promise<Buffer> {
  if (!request.isMultipart()) throw new HttpError(415, 'unsupported_type', 'multipart/form-data expected');
  const part = await request.file();
  if (!part) throw new HttpError(400, 'invalid_body', 'file missing');
  // toBuffer() throws RequestFileTooLargeError (413) once the stream passes limits.fileSize.
  return part.toBuffer();
}

export function registerUploadRoutes(app: FastifyInstance, ctx: AppContext): void {
  const hmac = requireHmac(ctx);
  const dir = resolve(ctx.config.UPLOAD_DIR);

  app.post(
    '/upload',
    {
      bodyLimit: JSON_BODY_LIMIT,
      // Before any body (up to ~7 MB of JSON) is read, and before the rate limiter's hook: only checks that need
      // no I/O. No session and no signature -> 401; malformed or stale HMAC headers -> 401; a portal upload that
      // is not multipart -> 415.
      onRequest: async (request) => {
        // The session row is loaded later (preParsing, after the rate limiter): here a validly signed session
        // cookie decides the portal path.
        if (request.sessionToken) {
          if (!String(request.headers['content-type'] ?? '').toLowerCase().startsWith('multipart/form-data')) {
            throw new HttpError(415, 'unsupported_type', 'multipart/form-data expected');
          }
          return;
        }
        if (!hasHmacHeaders(request)) throw new HttpError(401, 'unauthenticated');
        // The game variant comes from FXServer on this host only, like /internal/* (§C6).
        if (!isDirectLoopback(request)) throw new HttpError(401, 'unauthenticated');
        precheckHmacHeaders(ctx, request);
      },
      // After the rate limiter; the multipart stream is still unread here (the handler reads it).
      preHandler: async (request, reply) => {
        const session = request.portalSession;
        if (!session) {
          await hmac(request, reply);
          return;
        }
        checkCsrf(request, session);
        // Officers only (like /ws): any guild member could otherwise fill the disk.
        const { member, grants } = await sessionGrants(ctx, session);
        if (!member || grants.grants.length === 0) throw new HttpError(403, 'forbidden');
      },
    },
    async (request): Promise<UploadResponse> => {
      const session = request.portalSession;
      let buf: Buffer;
      let uploaderDiscord: string | null;
      let uploaderCitizenid: string | null;
      if (session) {
        buf = await readMultipartFile(request);
        uploaderDiscord = session.discordId;
        uploaderCitizenid = session.citizenid;
      } else {
        const body = parseOr400(InternalUploadBodySchema, request.body);
        buf = decodeBase64(body.data);
        uploaderDiscord = body.discordId ?? null;
        uploaderCitizenid = body.citizenid ?? null;
      }
      if (buf.length > UPLOAD_MAX_BYTES) throw new HttpError(413, 'too_large');
      if (buf.length === 0) throw new HttpError(400, 'invalid_body', 'empty file');

      const type = await fileTypeFromBuffer(buf);
      const mime = UPLOAD_MIME_TYPES.find((m) => m === type?.mime);
      if (!mime) throw new HttpError(415, 'unsupported_type');

      const id = randomBytes(16).toString('hex');
      const fileName = `${id}.${EXT[mime]}`;
      const path = join(dir, fileName);
      await mkdir(dir, { recursive: true });
      await writeFile(path, buf, { flag: 'wx' });
      try {
        await insertUpload(ctx.db, {
          id,
          fileName,
          mime,
          sizeBytes: buf.length,
          sha256: createHash('sha256').update(buf).digest('hex'),
          source: session ? 'portal' : 'game',
          uploaderDiscord,
          uploaderCitizenid,
        });
      } catch (err) {
        await unlink(path).catch(() => {});
        throw err;
      }
      return { ok: true, id, fileName, mime, size: buf.length };
    },
  );
}
