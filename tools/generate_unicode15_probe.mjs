#!/usr/bin/env node
// Recreate the historical size probe from the pinned Unicode 15 projection.
import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const sourcePath = path.join(root, 'data', 'unicode-15.0.bin');
const expectedSource = '10a4fd50df393d992424d2102e48e39c58dc6449a7a9cae0dcc5708683848019';
const expectedProbe = '640d478bbf25f4fb8de694eb3faf4532659400d4f173324cdb4247dbb6bc4db4';
const output = path.resolve(process.argv[2] ?? '.zig-cache/size-probes/unicode15-property-prototype.bin');
if (process.argv.length > 3) throw new Error('usage: node tools/generate_unicode15_probe.mjs [output]');
const hash = (bytes) => createHash('sha256').update(bytes).digest('hex');
const source = await readFile(sourcePath);
if (hash(source) !== expectedSource) throw new Error('pinned Unicode 15 source blob hash mismatch');
const rangeCount = source.readUInt32LE(14);
const mappingCount = source.readUInt32LE(18);
const mappingOffset = 54 + rangeCount * 10;
if (mappingOffset + mappingCount * 72 !== source.length) throw new Error('Unicode table dimensions mismatch');

function probeFlags(sourceFlags) {
  let flags = 0;
  for (let index = 0; index < 8; index++) {
    const mainBit = [0, 2, 3, 4, 5, 6, 7, 8][index];
    if (sourceFlags & (1 << mainBit)) flags |= 1 << index;
  }
  return flags;
}
const ranges = [];
let currentStart = -1;
let currentEnd = -1;
let currentFlags = 0;
function flush() {
  if (currentStart < 0) return;
  const row = Buffer.alloc(9);
  row.writeUInt32LE(currentStart, 0);
  row.writeUInt32LE(currentEnd, 4);
  row.writeUInt8(currentFlags, 8);
  ranges.push(row);
}
let sourceRange = 0;
let rangeFirst = -1;
let rangeLast = -1;
let rangeFlags = 0;
for (let cp = 0; cp <= 0x10ffff; cp++) {
  if (cp > rangeLast && sourceRange < rangeCount) {
    const offset = 54 + sourceRange * 10;
    rangeFirst = source.readUInt32LE(offset);
    rangeLast = source.readUInt32LE(offset + 4);
    rangeFlags = probeFlags(source.readUInt16LE(offset + 8));
    sourceRange++;
  }
  const flags = cp >= rangeFirst && cp <= rangeLast ? rangeFlags : 0;
  if (flags !== 0 && flags === currentFlags && cp === currentEnd + 1) {
    currentEnd = cp;
  } else {
    flush();
    currentStart = flags === 0 ? -1 : cp;
    currentEnd = cp;
    currentFlags = flags;
  }
}
flush();

const mappings = [];
for (let index = 0; index < mappingCount; index++) {
  const offset = mappingOffset + index * 72;
  const cp = source.readUInt32LE(offset);
  const original = Buffer.from(String.fromCodePoint(cp), 'utf8');
  const operations = [];
  for (let operation = 0; operation < 2; operation++) {
    const entry = offset + 4 + operation * 17;
    const count = source.readUInt8(entry);
    const scalars = [];
    for (let scalar = 0; scalar < count; scalar++) scalars.push(source.readUInt32LE(entry + 1 + scalar * 4));
    operations.push(count === 0 ? original : Buffer.from(String.fromCodePoint(...scalars), 'utf8'));
  }
  const [lower, upper] = operations;
  if (lower.equals(original) && upper.equals(original)) continue;
  if (lower.length > 255 || upper.length > 255) throw new Error('Unicode size-probe mapping exceeds one byte');
  const row = Buffer.alloc(6);
  row.writeUInt32LE(cp, 0);
  row.writeUInt8(lower.length, 4);
  row.writeUInt8(upper.length, 5);
  mappings.push(row, lower, upper);
}
const header = Buffer.alloc(17);
header.write('PEONY-U15', 0, 'ascii');
header.writeUInt32LE(ranges.length, 9);
header.writeUInt32LE(mappings.length / 3, 13);
const probe = Buffer.concat([header, ...ranges, ...mappings]);
if (hash(probe) !== expectedProbe) throw new Error(`Unicode size-probe output changed: ${hash(probe)}`);
await mkdir(path.dirname(output), { recursive: true });
await writeFile(output, probe);
process.stdout.write(`Unicode 15.0.0 prototype: ${probe.length} bytes\n`);
