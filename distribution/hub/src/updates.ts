// GET /updates/<file> – Sparkle feed and archives, static from DATA_DIR/updates.
// Flat file names only, fixed extensions, no directory listing.

import { createReadStream, realpathSync, statSync } from 'node:fs';
import path from 'node:path';
import { Readable } from 'node:stream';

const TYPES: Record<string, string> = {
  xml: 'application/xml; charset=utf-8',
  zip: 'application/zip',
};

const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*\.(xml|zip)$/;

export interface UpdateFile {
  abs: string;
  size: number;
  mtime: Date;
  contentType: string;
}

/** Resolves an encoded file name below updatesDir, or null (-> 404). */
export function resolveUpdateFile(updatesDir: string, encodedName: string): UpdateFile | null {
  let name: string;
  try {
    name = decodeURIComponent(encodedName);
  } catch {
    return null;
  }
  const m = NAME_RE.exec(name);
  if (!m || name.includes('..')) return null;
  const ext = (m[1] ?? '').toLowerCase();
  try {
    const dirReal = realpathSync(updatesDir);
    const real = realpathSync(path.join(dirReal, name));
    // A symlink pointing out of the directory must not be followed.
    if (path.dirname(real) !== dirReal) return null;
    const st = statSync(real);
    if (!st.isFile()) return null;
    return { abs: real, size: st.size, mtime: st.mtime, contentType: TYPES[ext] ?? 'application/octet-stream' };
  } catch {
    return null;
  }
}

export function hasLatestZip(updatesDir: string): boolean {
  return resolveUpdateFile(updatesDir, 'latest.zip') !== null;
}

/** Streams a file without buffering it; HEAD gets headers only. */
export function streamFile(method: string, file: UpdateFile): Response {
  const headers = new Headers({
    'Content-Type': file.contentType,
    'Cache-Control': 'no-cache',
    'Last-Modified': file.mtime.toUTCString(),
    'Content-Length': String(file.size),
  });
  if (method === 'HEAD') return new Response(null, { status: 200, headers });
  return new Response(Readable.toWeb(createReadStream(file.abs)) as ReadableStream<Uint8Array>, { status: 200, headers });
}
