import { randomUUID } from 'node:crypto';
import { readFile, rename, rm, stat, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import path from 'node:path';
import { promisify } from 'node:util';
import { brotliCompress, constants as zlib } from 'node:zlib';
import { fileURLToPath } from 'node:url';

const compress = promisify(brotliCompress);
const projectRoot = fileURLToPath(new URL('../', import.meta.url));
const showcaseRoot = path.join(projectRoot, 'showcase');
const webRoot = path.join(projectRoot, 'web');
const rawWasm = path.join(projectRoot, 'zig-out', 'peony.wasm');
const compressedWasm = path.join(webRoot, 'peony.wasm.br');
const types = new Map([
  ['.html', 'text/html; charset=utf-8'],
  ['.css', 'text/css; charset=utf-8'],
  ['.mjs', 'text/javascript; charset=utf-8'],
]);

let compressionTask;

async function ensureCompressedWasm() {
  if (compressionTask) return compressionTask;
  compressionTask = (async () => {
    let compressedInfo;
    let rawInfo;
    try { compressedInfo = await stat(compressedWasm); } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    try { rawInfo = await stat(rawWasm); } catch (error) {
      if (error.code !== 'ENOENT' || !compressedInfo) throw error;
    }
    if (compressedInfo && (!rawInfo || (compressedInfo.size > 0 && compressedInfo.mtimeMs >= rawInfo.mtimeMs))) return;

    const source = await readFile(rawWasm);
    const encoded = await compress(source, {
      params: {
        [zlib.BROTLI_PARAM_QUALITY]: 6,
        [zlib.BROTLI_PARAM_SIZE_HINT]: source.length,
      },
    });
    const temporary = `${compressedWasm}.${process.pid}.${randomUUID()}.tmp`;
    try {
      await writeFile(temporary, encoded, { flag: 'wx' });
      await rename(temporary, compressedWasm);
    } finally {
      await rm(temporary, { force: true });
    }
  })().finally(() => { compressionTask = undefined; });
  return compressionTask;
}

function localFile(root, pathname) {
  const relative = decodeURIComponent(pathname);
  if (relative.includes('\\') || relative.includes('\0')) throw new Error('invalid path');
  const file = path.resolve(root, `.${relative}`);
  const within = path.relative(root, file);
  if (within.startsWith('..') || path.isAbsolute(within)) throw new Error('outside root');
  return file;
}

export async function startShowcaseServer({ port = 0, host = '127.0.0.1' } = {}) {
  await ensureCompressedWasm();
  const server = createServer(async (request, response) => {
    try {
      if (request.method !== 'GET' && request.method !== 'HEAD') {
        response.writeHead(405, { Allow: 'GET, HEAD' }).end();
        return;
      }

      const pathname = new URL(request.url, `http://${host}`).pathname;
      let file;
      let contentType;
      let contentEncoding;
      if (pathname === '/web/peony.mjs') {
        file = path.join(webRoot, 'peony.mjs');
      } else if (pathname === '/web/peony.wasm.br') {
        await ensureCompressedWasm();
        file = compressedWasm;
        contentType = 'application/wasm';
        contentEncoding = 'br';
      } else {
        const relative = pathname === '/' || pathname === '/showcase/'
          ? '/index.html'
          : pathname.startsWith('/showcase/') ? pathname.slice('/showcase'.length) : pathname;
        file = localFile(showcaseRoot, relative);
      }

      const bytes = await readFile(file);
      response.writeHead(200, {
        'Content-Type': contentType ?? types.get(path.extname(file)) ?? 'application/octet-stream',
        'Content-Length': bytes.length,
        ...(contentEncoding ? { 'Content-Encoding': contentEncoding, Vary: 'Accept-Encoding' } : {}),
        'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff',
      });
      response.end(request.method === 'HEAD' ? undefined : bytes);
    } catch (error) {
      const missing = error?.code === 'ENOENT';
      response.writeHead(missing ? 404 : 500, { 'Content-Type': 'text/plain; charset=utf-8' })
        .end(missing ? 'Not found' : 'Showcase server error');
    }
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, host, resolve);
  });
  return { server, url: `http://${host}:${server.address().port}/showcase/` };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const port = process.env.PORT ? Number(process.env.PORT) : 4173;
  const { url } = await startShowcaseServer({ port });
  process.stdout.write(`Peony showcase: ${url}\n`);
}
