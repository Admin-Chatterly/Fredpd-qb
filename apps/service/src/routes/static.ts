// SPDX-License-Identifier: GPL-3.0-only
// Portal hosting (docs/modules/portal-api.md "Hosting"; closes service open question 8): the built SPA
// (apps/portal/dist, PORTAL_DIR) is served by the service, so a Cloudflare Tunnel can point straight at
// 127.0.0.1:3000. Hashed files under /assets/ are immutable; index.html is never cached. Any other GET that is not a
// service route and asks for HTML gets index.html (client-side routes such as /share/:token, /cases/12); the service
// prefixes (/api, /auth, /avatar, /ws, /upload, /internal) keep their JSON 404.
import { existsSync, statSync } from 'node:fs';
import { resolve } from 'node:path';
import fastifyStatic from '@fastify/static';
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import type { AppContext } from '../context';

const SERVICE_PREFIXES = ['/api/', '/auth/', '/avatar/', '/ws', '/upload', '/internal/'];

export function portalDir(ctx: AppContext): string {
  return resolve(ctx.config.PORTAL_DIR);
}

function hasIndex(dir: string): boolean {
  try {
    return statSync(resolve(dir, 'index.html')).isFile();
  } catch {
    return false;
  }
}

/** index.html of the portal (no-cache), or a JSON 404 when the portal is not built. */
export function sendPortalIndex(ctx: AppContext, reply: FastifyReply): FastifyReply {
  const dir = portalDir(ctx);
  if (!hasIndex(dir)) return reply.code(404).send({ error: 'not_found' });
  reply.header('cache-control', 'no-cache');
  return reply.sendFile('index.html', dir);
}

/** GET/HEAD for an HTML page outside the service's own routes. */
export function isSpaRequest(request: FastifyRequest): boolean {
  if (request.method !== 'GET' && request.method !== 'HEAD') return false;
  const path = request.url.split('?')[0] ?? '/';
  if (SERVICE_PREFIXES.some((p) => path === p.replace(/\/$/, '') || path.startsWith(p))) return false;
  return String(request.headers.accept ?? '').toLowerCase().includes('text/html');
}

export async function registerPortalStatic(app: FastifyInstance, ctx: AppContext): Promise<void> {
  const dir = portalDir(ctx);
  if (!existsSync(dir)) {
    ctx.log.warn({ dir }, 'portal build not found (run pnpm build): only the API is served');
  }
  await app.register(fastifyStatic, {
    root: dir,
    prefix: '/',
    // `/` is the SPA's start page; other client-side routes come through the not-found handler (app.ts).
    index: ['index.html'],
    wildcard: true,
    // Only files of the build: no directory listings, no dotfiles.
    list: false,
    dotfiles: 'deny',
    cacheControl: false,
    setHeaders: (reply, path) => {
      reply.header('cache-control', /[\\/]assets[\\/]/.test(path) ? 'public, max-age=31536000, immutable' : 'no-cache');
    },
  });
}
