// SPDX-License-Identifier: GPL-3.0-only
// GET /avatar/:discordId — cached Discord avatar (IMPLEMENTATION.md §4.9), public like the CDN it mirrors. The
// tablet (NUI origin https://cfx-nui-…) loads it as an <img>, so the response is marked cross-origin readable.
import type { FastifyInstance } from 'fastify';
import type { AppContext } from '../context';
import { avatarRef } from '../discord/sync';
import { HttpError } from '../http/errors';

const ID_RE = /^\d{1,20}$/;

export function registerAvatarRoutes(app: FastifyInstance, ctx: AppContext): void {
  const { config } = ctx;
  // A roster shows many avatars at once; the files are small and cached, so allow more than the API default.
  app.get('/avatar/:discordId', { config: { rateLimit: { max: 300, timeWindow: '1 minute' } } }, async (request, reply) => {
    const { discordId } = request.params as { discordId: string };
    const { v } = request.query as { v?: string };
    if (!ID_RE.test(discordId)) throw new HttpError(404, 'not_found');
    const member = ctx.gateway.isReady() ? ctx.gateway.getMember(discordId) : null;
    const ref = member ? avatarRef(member, config.DISCORD_GUILD_ID, config.OFFICER_NAME_SOURCE) : null;
    const png = await ctx.avatars.get(discordId, ref);
    if (!png) throw new HttpError(404, 'not_found');
    // ?v=<key> names one immutable image; without it (or for an outdated key) revalidate soon.
    const current = ref !== null && v === ref.key;
    return reply
      .type('image/png')
      .header('cache-control', current ? 'public, max-age=86400' : 'public, max-age=300')
      .header('cross-origin-resource-policy', 'cross-origin')
      .send(png);
  });
}
