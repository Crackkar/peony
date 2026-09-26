import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const projectRoot = fileURLToPath(new URL('../', import.meta.url));
const webRoot = path.join(projectRoot, 'web');
const wasmFile = path.join(projectRoot, 'zig-out', 'peony.wasm');
const types = new Map([
  ['.html', 'text/html; charset=utf-8'],
  ['.css', 'text/css; charset=utf-8'],
  ['.mjs', 'text/javascript; charset=utf-8'],
  ['.wasm', 'application/wasm'],
]);

export async function startShowcaseServer({ port = 0, host = '127.0.0.1' } = {}) {
  const server = createServer(async (request, response) => {
    try {
      if (request.method !== 'GET' && request.method !== 'HEAD') {
        response.writeHead(405, { Allow: 'GET, HEAD' }).end();
        return;
      }
      const pathname = new URL(request.url, `http://${host}`).pathname;
      let file;
      if (pathname === '/zig-out/peony.wasm') {
        file = wasmFile;
      } else {
        const relative = decodeURIComponent(pathname === '/' ? '/index.html' : pathname);
        if (relative.includes('\\') || relative.includes('\0')) throw new Error('invalid path');
        file = path.resolve(webRoot, `.${relative}`);
        const within = path.relative(webRoot, file);
        if (within.startsWith('..') || path.isAbsolute(within)) throw new Error('outside web root');
      }
      const bytes = await readFile(file);
      response.writeHead(200, {
        'Content-Type': types.get(path.extname(file)) ?? 'application/octet-stream',
        'Content-Length': bytes.length,
        'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff',
      });
      response.end(request.method === 'HEAD' ? undefined : bytes);
    } catch {
      response.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' }).end('Not found');
    }
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, host, resolve);
  });
  return { server, url: `http://${host}:${server.address().port}/` };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const port = process.env.PORT ? Number(process.env.PORT) : 4173;
  const { url } = await startShowcaseServer({ port });
  process.stdout.write(`Peony showcase: ${url}\n`);
}
