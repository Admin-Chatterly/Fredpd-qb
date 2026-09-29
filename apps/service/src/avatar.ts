// SPDX-License-Identifier: GPL-3.0-only
// Avatar cache behind GET /avatar/:discordId (IMPLEMENTATION.md §4.9: the tablet never calls Discord). Each avatar
// is fetched from the Discord CDN once per avatar hash and kept on disk as <discordId>-<key>.png; an older file of
// the same user is removed when a new one lands. When the member is unknown to the gateway (bot down, member left)
// the last cached file is served; with no file at all the route answers 404.
import { mkdir, readdir, readFile, rename, stat, unlink, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { randomBytes } from 'node:crypto';
import { fileTypeFromBuffer } from 'file-type';
import type { AvatarRef } from './discord/sync';
import type { Logger } from './log';

export interface AvatarCacheOptions {
  dir: string;
  log: Logger;
  fetch?: typeof fetch;
  timeoutMs?: number;
  /** Discord serves 128 px PNGs of a few KB; anything far larger is not an avatar. */
  maxBytes?: number;
}

const ID_RE = /^\d{1,20}$/;
const KEY_RE = /^[a-z0-9_]{1,40}$/;
const DEFAULT_MAX_BYTES = 1024 * 1024;

/**
 * The response body, refusing more than `max` bytes: by Content-Length before reading, then by a running count while
 * streaming (the stream is cancelled at once), so the limit bounds memory and not only what is kept.
 */
export async function readCapped(res: Response, max: number): Promise<Buffer> {
  const declared = Number(res.headers.get('content-length'));
  if (Number.isFinite(declared) && declared > max) {
    await res.body?.cancel().catch(() => {});
    throw new Error(`unexpected size ${declared}`);
  }
  if (!res.body) return Buffer.alloc(0);
  const reader = res.body.getReader();
  const chunks: Buffer[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > max) {
      await reader.cancel().catch(() => {});
      throw new Error(`unexpected size > ${max}`);
    }
    chunks.push(Buffer.from(value));
  }
  return Buffer.concat(chunks, size);
}

export class AvatarCache {
  private readonly inflight = new Map<string, Promise<Buffer | null>>();
  private readonly doFetch: typeof fetch;

  constructor(private readonly opts: AvatarCacheOptions) {
    this.doFetch = opts.fetch ?? globalThis.fetch;
  }

  /** PNG bytes for the member's current avatar (downloaded on first use), the last cached one, or null. */
  async get(discordId: string, ref: AvatarRef | null): Promise<Buffer | null> {
    if (!ID_RE.test(discordId)) return null;
    if (ref && KEY_RE.test(ref.key)) {
      const name = `${discordId}-${ref.key}.png`;
      const cached = await readFile(join(this.opts.dir, name)).catch(() => null);
      if (cached) return cached;
      let pending = this.inflight.get(name);
      if (!pending) {
        pending = this.download(discordId, name, ref.cdnUrl).finally(() => this.inflight.delete(name));
        this.inflight.set(name, pending);
      }
      const fresh = await pending;
      if (fresh) return fresh;
    }
    return this.latest(discordId);
  }

  private async download(discordId: string, name: string, url: string): Promise<Buffer | null> {
    try {
      const res = await this.doFetch(url, { signal: AbortSignal.timeout(this.opts.timeoutMs ?? 5000) });
      if (!res.ok) throw new Error(`CDN answered ${res.status}`);
      const buf = await readCapped(res, this.opts.maxBytes ?? DEFAULT_MAX_BYTES);
      if (buf.length === 0) throw new Error('unexpected size 0');
      const type = await fileTypeFromBuffer(buf);
      if (type?.mime !== 'image/png') throw new Error(`not a PNG (${type?.mime ?? 'unknown'})`);
      await mkdir(this.opts.dir, { recursive: true });
      const tmp = join(this.opts.dir, `.${name}.${randomBytes(4).toString('hex')}.tmp`);
      await writeFile(tmp, buf);
      await rename(tmp, join(this.opts.dir, name));
      await this.removeOthers(discordId, name);
      return buf;
    } catch (err) {
      this.opts.log.warn({ component: 'avatar', discordId, detail: (err as Error).message }, 'avatar download failed');
      return null;
    }
  }

  private async files(discordId: string): Promise<string[]> {
    const names = await readdir(this.opts.dir).catch(() => [] as string[]);
    return names.filter((n) => n.startsWith(`${discordId}-`) && n.endsWith('.png'));
  }

  private async removeOthers(discordId: string, keep: string): Promise<void> {
    for (const n of await this.files(discordId)) {
      if (n !== keep) await unlink(join(this.opts.dir, n)).catch(() => {});
    }
  }

  private async latest(discordId: string): Promise<Buffer | null> {
    let best: { name: string; mtime: number } | null = null;
    for (const n of await this.files(discordId)) {
      const s = await stat(join(this.opts.dir, n)).catch(() => null);
      if (s && (!best || s.mtimeMs > best.mtime)) best = { name: n, mtime: s.mtimeMs };
    }
    return best ? readFile(join(this.opts.dir, best.name)).catch(() => null) : null;
  }
}
