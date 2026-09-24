import { readdir, stat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const cache = path.join(root, '.zig-cache');
const limitBytes = 512 * 1024 * 1024;

async function measure(directory) {
  let entries;
  try {
    entries = await readdir(directory, { withFileTypes: true });
  } catch (error) {
    if (error.code === 'ENOENT') return { bytes: 0, files: 0 };
    throw error;
  }

  const result = { bytes: 0, files: 0 };
  for (const entry of entries) {
    const child = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      const nested = await measure(child);
      result.bytes += nested.bytes;
      result.files += nested.files;
    } else if (entry.isFile()) {
      result.bytes += (await stat(child)).size;
      result.files += 1;
    }
  }
  return result;
}

const usage = await measure(cache);
const report = {
  path: '.zig-cache',
  bytes: usage.bytes,
  files: usage.files,
  limitBytes,
  overLimit: usage.bytes > limitBytes,
};

if (process.argv.includes('--json')) {
  process.stdout.write(`${JSON.stringify(report)}\n`);
} else {
  process.stdout.write(`${report.path}: ${report.bytes} bytes in ${report.files} files; maintenance threshold ${limitBytes} bytes\n`);
}

if (process.argv.includes('--check') && report.overLimit) process.exitCode = 1;
