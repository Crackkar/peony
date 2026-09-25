#!/usr/bin/env node
// Build Peony's Unicode 15 table directly from pinned official UCD files.
import { createHash } from 'node:crypto';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const ucd = path.join(root, 'data', 'ucd-15.0.0');
const expectedFiles = {
  'CaseFolding.txt': 'cdd49e55eae3bbf1f0a3f6580c974a0263cb86a6a08daa10fbf705b4808a56f7',
  'DerivedCoreProperties.txt': 'd367290bc0867e6b484c68370530bdd1a08b6b32404601b8c7accaf83e05628d',
  'SpecialCasing.txt': '78b29c64b5840d25c11a9f31b665ee551b8a499eca6c70d770fcad7dd710f494',
  'UnicodeData.txt': '806e9aed65037197f1ec85e12be6e8cd870fc5608b4de0fffd990f689f376a73',
  'Unihan_NumericValues.txt': '42289ff99564cf17c3c95938744c2f690452b704a6d076d5372c4571c3cb14f6',
};
const expectedProjection = '4823dcf0e05d64d5c2fa3e4de8f23935959b9c86fd4d89f41a7461280ffed10b';
const expectedBlob = '10a4fd50df393d992424d2102e48e39c58dc6449a7a9cae0dcc5708683848019';
const args = process.argv.slice(2);
let check = false;
let output = path.join(root, 'data', 'unicode-15.0.bin');
for (let index = 0; index < args.length; index++) {
  if (args[index] === '--check') check = true;
  else if (args[index] === '--output' && args[index + 1]) output = path.resolve(args[++index]);
  else throw new Error('usage: node tools/gen_unicode.mjs [--check] [--output FILE]');
}
const sha = (bytes) => createHash('sha256').update(bytes).digest('hex');
const sources = {};
for (const [name, expected] of Object.entries(expectedFiles)) {
  const bytes = await readFile(path.join(ucd, name));
  if (sha(bytes) !== expected) throw new Error(`pinned official UCD hash mismatch: ${name}`);
  sources[name] = bytes.toString('utf8');
}
const SIZE = 0x110000;
const category = Array(SIZE).fill('Cn');
const bidi = Array(SIZE).fill('');
const decimal = new Uint8Array(SIZE);
const digit = new Uint8Array(SIZE);
const numeric = new Uint8Array(SIZE);
const alpha = new Uint8Array(SIZE);
const lowerProperty = new Uint8Array(SIZE);
const upperProperty = new Uint8Array(SIZE);
const simple = new Map();
function scalar(text) { return Number.parseInt(text, 16); }
function codepoints(text) { return text.trim() ? text.trim().split(/\s+/).map(scalar) : []; }
function range(text) {
  const endpoints = text.trim().split('..');
  const first = scalar(endpoints[0]);
  return [first, endpoints[1] ? scalar(endpoints[1]) : first];
}
let firstRange = null;
for (const raw of sources['UnicodeData.txt'].trimEnd().split(/\r?\n/)) {
  const fields = raw.split(';');
  const cp = scalar(fields[0]);
  const name = fields[1];
  if (name.endsWith(', First>')) { firstRange = { cp, fields }; continue; }
  const start = name.endsWith(', Last>') ? firstRange.cp : cp;
  if (name.endsWith(', Last>') && (!firstRange || firstRange.fields[2] !== fields[2])) throw new Error('bad UCD First/Last range');
  for (let target = start; target <= cp; target++) {
    category[target] = fields[2];
    bidi[target] = fields[4];
    decimal[target] = fields[6] ? 1 : 0;
    digit[target] = fields[7] ? 1 : 0;
    numeric[target] = fields[8] ? 1 : 0;
  }
  if (name.endsWith(', Last>')) { firstRange = null; continue; }
  simple.set(cp, {
    upper: fields[12] ? [scalar(fields[12])] : [],
    lower: fields[13] ? [scalar(fields[13])] : [],
    title: fields[14] ? [scalar(fields[14])] : [],
  });
}
if (firstRange) throw new Error('unterminated UCD First/Last range');
for (const raw of sources['Unihan_NumericValues.txt'].split(/\r?\n/)) {
  const content = raw.split('#', 1)[0].trim();
  if (!content) continue;
  const fields = content.split('\t');
  if (fields.length !== 3 || !fields[0].startsWith('U+')) throw new Error('invalid Unihan numeric row');
  numeric[scalar(fields[0].slice(2))] = 1;
}
for (const raw of sources['DerivedCoreProperties.txt'].split(/\r?\n/)) {
  const content = raw.split('#', 1)[0].trim();
  if (!content) continue;
  const [rangeText, propertyText] = content.split(';');
  const property = propertyText.trim();
  const target = property === 'Alphabetic' ? alpha : property === 'Lowercase' ? lowerProperty : property === 'Uppercase' ? upperProperty : null;
  if (!target) continue;
  const [first, last] = range(rangeText);
  target.fill(1, first, last + 1);
}
const special = new Map();
for (const raw of sources['SpecialCasing.txt'].split(/\r?\n/)) {
  const content = raw.split('#', 1)[0].trim();
  if (!content) continue;
  const fields = content.split(';').map((field) => field.trim());
  if (fields[4]) continue; // locale/context rules do not affect one-scalar projection
  special.set(scalar(fields[0]), {
    lower: codepoints(fields[1]),
    title: codepoints(fields[2]),
    upper: codepoints(fields[3]),
  });
}
const folds = new Map();
for (const raw of sources['CaseFolding.txt'].split(/\r?\n/)) {
  const content = raw.split('#', 1)[0].trim();
  if (!content) continue;
  const fields = content.split(';').map((field) => field.trim());
  if (fields[1] !== 'C' && fields[1] !== 'F') continue;
  const cp = scalar(fields[0]);
  const previous = folds.get(cp);
  if (!previous || fields[1] === 'F') folds.set(cp, { status: fields[1], mapping: codepoints(fields[2]) });
}
const ignoredCategories = new Set(['Mn', 'Me', 'Cf', 'Lm', 'Sk']);
const breakIgnorable = new Set([0x27, 0xad, 0xb7, 0x387, 0x5f4, 0x2019, 0x2027, 0xfe13, 0xfe55, 0xff07, 0xff1a, 0xff65]);
const whitespaceBidi = new Set(['WS', 'B', 'S']);
const ranges = [];
const mappings = [];
const digest = createHash('sha256');
const fingerprintRow = Buffer.alloc(74);
let rangeStart = -1;
let previous = -1;
let previousFlags = 0;
function pushRange() {
  if (rangeStart < 0) return;
  const record = Buffer.alloc(10);
  record.writeUInt32LE(rangeStart, 0);
  record.writeUInt32LE(previous, 4);
  record.writeUInt16LE(previousFlags, 8);
  ranges.push(record);
}
for (let cp = 0; cp < SIZE; cp++) {
  const cat = category[cp];
  const lower = !!lowerProperty[cp];
  const upper = !!upperProperty[cp];
  const title = upper || cat === 'Lt';
  const alphabetic = cat.startsWith('L');
  const isNumeric = !!numeric[cp];
  const ignored = ignoredCategories.has(cat);
  let flags = 0;
  if (alphabetic) flags |= 1;
  if (alphabetic || isNumeric) flags |= 2;
  if (decimal[cp]) flags |= 4;
  if (digit[cp]) flags |= 8;
  if (isNumeric) flags |= 16;
  if (cat === 'Zs' || whitespaceBidi.has(bidi[cp])) flags |= 32;
  if (lower) flags |= 64;
  if (upper) flags |= 128;
  if (title) flags |= 256;
  if (lower || upper || title) flags |= 512;
  if (ignored || breakIgnorable.has(cp)) flags |= 1024;
  if (ignored) flags |= 2048;

  const simpleCase = simple.get(cp);
  const specialCase = special.get(cp);
  const fold = folds.get(cp);
  const full = [
    specialCase?.lower ?? simpleCase?.lower ?? [],
    specialCase?.upper ?? simpleCase?.upper ?? [],
    specialCase?.title ?? simpleCase?.title ?? [],
    fold?.mapping ?? [],
  ].map((mapping) => mapping.length === 1 && mapping[0] === cp ? [] : mapping);
  const single = [
    full[0].length === 1 ? full[0][0] : cp === 0x130 ? 0x69 : cp,
    full[1].length === 1 ? full[1][0] : cp,
    full[2].length === 1 ? full[2][0] : cp,
    full[3].length === 1 ? full[3][0] : full[0].length === 1 ? full[0][0] : cp,
  ];
  fingerprintRow.writeUInt32LE(cp, 0);
  fingerprintRow.writeUInt16LE(flags, 4);
  for (let operation = 0; operation < 4; operation++) {
    const offset = 6 + operation * 17;
    fingerprintRow.writeUInt8(full[operation].length, offset);
    for (let scalarIndex = 0; scalarIndex < 3; scalarIndex++) fingerprintRow.writeUInt32LE(full[operation][scalarIndex] ?? 0, offset + 1 + scalarIndex * 4);
    fingerprintRow.writeUInt32LE(single[operation], offset + 13);
  }
  digest.update(fingerprintRow);
  if (flags && rangeStart >= 0 && flags === previousFlags && cp === previous + 1) previous = cp;
  else {
    pushRange();
    rangeStart = flags ? cp : -1;
    previous = cp;
    previousFlags = flags;
  }
  if (full.some((mapping) => mapping.length) || single.some((mapping) => mapping !== cp)) {
    const record = Buffer.alloc(72);
    record.writeUInt32LE(cp, 0);
    fingerprintRow.copy(record, 4, 6, 74);
    mappings.push(record);
  }
}
pushRange();
const fingerprint = digest.digest('hex');
const header = Buffer.alloc(54);
header.write('PEONYU15', 0, 'ascii');
header.write('15.0.0', 8, 'ascii');
header.writeUInt32LE(ranges.length, 14);
header.writeUInt32LE(mappings.length, 18);
Buffer.from(fingerprint, 'hex').copy(header, 22);
const blob = Buffer.concat([header, ...ranges, ...mappings]);
const blobHash = sha(blob);
if (fingerprint !== expectedProjection || blobHash !== expectedBlob) {
  throw new Error(`Unicode 15 projection differs: projection=${fingerprint}, blob=${blobHash}, ranges=${ranges.length}, mappings=${mappings.length}`);
}
if (check) {
  const existing = await readFile(output);
  if (!existing.equals(blob)) throw new Error(`Unicode blob does not match official UCD projection: ${output}`);
  process.stdout.write(`match: ${output} (Unicode 15.0.0; projection-sha256=${fingerprint}; blob-sha256=${blobHash}; bytes=${blob.length})\n`);
} else {
  await mkdir(path.dirname(output), { recursive: true });
  await writeFile(output, blob);
  process.stdout.write(`wrote: ${output} (Unicode 15.0.0; projection-sha256=${fingerprint}; blob-sha256=${blobHash}; bytes=${blob.length})\n`);
}
