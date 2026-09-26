const decoder = new TextDecoder('utf-8', { fatal: true });
const encoder = new TextEncoder();

const fail = (code) => { throw code; };
const childOf = (parent, path) => parent === '/' ? path.length > 1 && path.startsWith('/') : path.startsWith(`${parent}/`);
const parentOf = (path) => path.slice(0, path.lastIndexOf('/')) || '/';
const writable = (path) => path.startsWith('/home/') || path.startsWith('/tmp/');

class WorkerFiles {
  constructor(maxTotal, maxFile) {
    this.maxTotal = maxTotal;
    this.maxFile = maxFile;
    this.entries = new Map([
      ['/', { dir: true }],
      ['/assets', { dir: true }],
      ['/home', { dir: true }],
      ['/tmp', { dir: true }],
    ]);
    this.handles = new Map();
    this.nextHandle = 1;
    this.usedBytes = 0;
  }

  normalize(raw) {
    if (!raw || raw.includes('\0')) fail(-1);
    const parts = raw.startsWith('/') ? [] : ['home'];
    for (const part of raw.split('/')) {
      if (!part || part === '.') continue;
      if (part === '..') {
        if (!parts.length) fail(-1);
        parts.pop();
      } else parts.push(part);
    }
    return `/${parts.join('/')}`;
  }

  stat(path) {
    const entry = this.entries.get(this.normalize(path));
    return !entry ? 0 : entry.dir ? 2 : 1;
  }

  total() {
    return this.usedBytes;
  }

  unlinkNode(node) {
    node.linked = false;
    if (node.handleCount === 0) this.usedBytes -= node.bytes.length;
  }

  close(handle) {
    const node = this.handles.get(handle);
    if (!node) fail(-1);
    this.handles.delete(handle);
    node.handleCount -= 1;
    if (!node.linked && node.handleCount === 0) this.usedBytes -= node.bytes.length;
  }

  file(path) {
    const entry = this.entries.get(this.normalize(path));
    if (!entry) fail(-2);
    if (entry.dir) fail(-5);
    return entry.node;
  }

  replace(node, bytes) {
    if (node.readOnly) fail(-6);
    const nextTotal = this.usedBytes - node.bytes.length + bytes.length;
    if (bytes.length > this.maxFile || nextTotal > this.maxTotal) fail(-7);
    node.bytes = bytes.slice();
    this.usedBytes = nextTotal;
  }

  writeAt(node, offset, bytes) {
    if (node.readOnly) fail(-6);
    if (bytes.length === 0) return;
    const end = offset + bytes.length;
    if (!Number.isSafeInteger(end) || end > this.maxFile) fail(-7);
    if (end <= node.bytes.length) {
      node.bytes.set(bytes, offset);
      return;
    }
    const nextTotal = this.usedBytes - node.bytes.length + end;
    if (nextTotal > this.maxTotal) fail(-7);
    const next = new Uint8Array(end);
    next.set(node.bytes);
    next.set(bytes, offset);
    node.bytes = next;
    this.usedBytes = nextTotal;
  }

  truncate(node, length) {
    if (node.readOnly) fail(-6);
    const nextTotal = this.usedBytes - node.bytes.length + length;
    if (!Number.isSafeInteger(length) || length > this.maxFile || nextTotal > this.maxTotal) fail(-7);
    if (length === node.bytes.length) return;
    const next = new Uint8Array(length);
    next.set(node.bytes.subarray(0, length));
    node.bytes = next;
    this.usedBytes = nextTotal;
  }

  write(path, bytes, mode) {
    path = this.normalize(path);
    if (!writable(path)) fail(-6);
    const parent = this.entries.get(parentOf(path));
    if (!parent) fail(-2);
    if (!parent.dir) fail(-4);
    const existing = this.entries.get(path);
    if (existing) {
      if (existing.dir) fail(-5);
      if (mode === 2) fail(-3);
      if (mode === 1) this.writeAt(existing.node, existing.node.bytes.length, bytes);
      else this.replace(existing.node, bytes);
      return;
    }
    if (bytes.length > this.maxFile || this.usedBytes + bytes.length > this.maxTotal) fail(-7);
    this.entries.set(path, { dir: false, node: { bytes: bytes.slice(), readOnly: false, linked: true, handleCount: 0 } });
    this.usedBytes += bytes.length;
  }

  open(path, access) {
    path = this.normalize(path);
    if (access !== 0 && !writable(path)) fail(-6);
    const node = this.file(path);
    const handle = this.nextHandle++;
    this.handles.set(handle, node);
    node.handleCount += 1;
    return handle;
  }

  opened(handle) {
    const node = this.handles.get(handle);
    if (!node) fail(-1);
    return node;
  }

  mkdir(path, parents, existOk) {
    path = this.normalize(path);
    const existing = this.entries.get(path);
    if (existing) {
      if (existing.dir && existOk) return;
      fail(-3);
    }
    if (!writable(path)) fail(-6);
    const segments = path.split('/').slice(1);
    const pending = [];
    for (let index = 1; index <= segments.length; index += 1) {
      const part = `/${segments.slice(0, index).join('/')}`;
      const entry = this.entries.get(part);
      if (entry && !entry.dir) fail(-4);
      if (!entry) {
        if (!parents && index !== segments.length) fail(-2);
        pending.push(part);
      }
    }
    for (const part of pending) this.entries.set(part, { dir: true });
  }

  mount(path, bytes) {
    path = this.normalize(path);
    if (!path.startsWith('/assets/')) fail(-6);
    if (bytes.length > this.maxFile) fail(-7);
    const old = this.entries.get(path);
    if (old && (old.dir || !old.node.readOnly)) fail(-3);
    const oldLength = old ? old.node.bytes.length : 0;
    const nextTotal = this.usedBytes - oldLength + bytes.length;
    if (nextTotal > this.maxTotal) fail(-7);
    const segments = path.split('/').slice(1, -1);
    let prefix = '';
    for (const segment of segments) {
      prefix += `/${segment}`;
      const entry = this.entries.get(prefix);
      if (entry && !entry.dir) fail(-4);
      if (!entry) this.entries.set(prefix, { dir: true });
    }
    if (old) old.node.bytes = bytes.slice();
    else this.entries.set(path, { dir: false, node: { bytes: bytes.slice(), readOnly: true, linked: true, handleCount: 0 } });
    this.usedBytes = nextTotal;
  }

  remove(path, directory) {
    path = this.normalize(path);
    if (!writable(path)) fail(-6);
    const entry = this.entries.get(path);
    if (!entry) fail(-2);
    if (directory && !entry.dir) fail(-4);
    if (!directory && entry.dir) fail(-5);
    if (directory && [...this.entries.keys()].some(name => childOf(path, name))) fail(-3);
    this.entries.delete(path);
    if (!entry.dir) this.unlinkNode(entry.node);
  }

  rename(source, target, replace) {
    source = this.normalize(source);
    target = this.normalize(target);
    if (!writable(source) || !writable(target)) fail(-6);
    if (source === target) return;
    const entry = this.entries.get(source);
    if (!entry) fail(-2);
    if (entry.dir && childOf(source, target)) fail(-9);
    const parent = this.entries.get(parentOf(target));
    if (!parent) fail(-2);
    if (!parent.dir) fail(-4);
    const destination = this.entries.get(target);
    if (destination) {
      if (!replace) fail(-3);
      if (destination.dir !== entry.dir) fail(destination.dir ? -5 : -4);
      if (destination.dir && [...this.entries.keys()].some(name => childOf(target, name))) fail(-3);
    }
    const moving = [...this.entries].filter(([path]) => path === source || childOf(source, path));
    for (const [path] of moving) {
      const next = target + path.slice(source.length);
      if (next !== target && this.entries.has(next) && !childOf(source, next)) fail(-3);
    }
    if (destination) {
      this.entries.delete(target);
      if (!destination.dir) this.unlinkNode(destination.node);
    }
    for (const [path] of moving) this.entries.delete(path);
    for (const [path, value] of moving) this.entries.set(target + path.slice(source.length), value);
  }

  list(path, variant) {
    path = this.normalize(path);
    const entry = this.entries.get(path);
    if (!entry) fail(-2);
    if (!entry.dir) fail(-4);
    const selected = [];
    for (const [name, item] of this.entries) {
      if (!childOf(path, name)) continue;
      if (variant === 2) {
        const suffix = name.slice(path === '/' ? 1 : path.length + 1);
        if (!suffix.includes('/')) selected.push(suffix);
      } else if (item.dir === (variant === 1)) selected.push(name);
    }
    selected.sort();
    return encoder.encode(selected.map(name => `${name}\0`).join(''));
  }

  clearTemporary() {
    for (const [name, entry] of this.entries) if (childOf('/tmp', name)) {
      this.entries.delete(name);
      if (!entry.dir) this.unlinkNode(entry.node);
    }
  }
}

export function createFsHost() {
  let api;
  const sessions = new Map();
  const retained = new Set();
  const readMemory = (pointer, length) => {
    if (length === 0) return new Uint8Array();
    const memory = api.memory.buffer;
    if (pointer === 0 || pointer + length > memory.byteLength) fail(-1);
    return new Uint8Array(memory, pointer, length);
  };
  const readText = (pointer, length) => decoder.decode(readMemory(pointer, length));
  const transfer = (bytes, pointer, length) => {
    if (pointer === 0 && length === 0) return bytes.length;
    if (length < bytes.length) fail(-7);
    readMemory(pointer, bytes.length).set(bytes);
    return bytes.length;
  };
  const peony_fs_call = (session, operation, pathPointer, pathLength, dataPointer, dataLength, auxiliary, outputPointer, outputLength) => {
    try {
      if (operation === 16) {
        sessions.set(session, new WorkerFiles(dataLength, auxiliary));
        return 0;
      }
      if (operation === 17) {
        if (!retained.has(session)) sessions.delete(session);
        return 0;
      }
      const fs = sessions.get(session);
      if (!fs) fail(-1);
      if (operation === 13) { fs.clearTemporary(); return 0; }
      if (operation === 14) return fs.total();
      if (operation === 18) return fs.opened(auxiliary).bytes.length;
      if (operation === 19 || operation === 20 || operation === 21) {
        if (pathLength !== 8) fail(-1);
        const positionBytes = readMemory(pathPointer, 8);
        const value = Number(new DataView(positionBytes.buffer, positionBytes.byteOffset, 8).getBigUint64(0, true));
        if (!Number.isSafeInteger(value)) fail(-7);
        if (operation === 19) fs.writeAt(fs.opened(auxiliary), value, readMemory(dataPointer, dataLength));
        else if (operation === 20) fs.truncate(fs.opened(auxiliary), value);
        else {
          const bytes = fs.opened(auxiliary).bytes.subarray(value, value + outputLength);
          readMemory(outputPointer, bytes.length).set(bytes);
          return bytes.length;
        }
        return 0;
      }
      const path = pathLength ? readText(pathPointer, pathLength) : '';
      if (operation === 1) return fs.stat(path);
      if (operation === 2) return transfer(fs.file(path).bytes, outputPointer, outputLength);
      if (operation === 3) { fs.write(path, readMemory(dataPointer, dataLength), auxiliary); return 0; }
      if (operation === 4) return fs.open(path, auxiliary);
      if (operation === 5) return transfer(fs.opened(auxiliary).bytes, outputPointer, outputLength);
      if (operation === 6) { fs.replace(fs.opened(auxiliary), readMemory(dataPointer, dataLength)); return 0; }
      if (operation === 7) { fs.close(auxiliary); return 0; }
      if (operation === 8) { fs.mkdir(path, Boolean(auxiliary & 1), Boolean(auxiliary & 2)); return 0; }
      if (operation === 9) { fs.remove(path, auxiliary !== 0); return 0; }
      if (operation === 10) { fs.rename(path, readText(dataPointer, dataLength), auxiliary !== 0); return 0; }
      if (operation === 11) return transfer(fs.list(path, auxiliary), outputPointer, outputLength);
      if (operation === 12) { fs.mount(path, readMemory(dataPointer, dataLength)); return 0; }
      fail(-1);
    } catch (error) {
      return Number.isInteger(error) && error < 0 ? error : -10;
    }
  };
  return {
    imports: { env: { peony_fs_call } },
    bind(exports) { api = exports; },
    retain(handle) {
      if (!sessions.has(handle)) throw new Error('Peony filesystem session is missing');
      retained.add(handle);
    },
    move(from, to) {
      const files = sessions.get(from);
      if (!retained.has(from) || !files || !sessions.has(to)) throw new Error('Peony filesystem transfer failed');
      files.clearTemporary();
      sessions.set(to, files);
      sessions.delete(from);
      retained.delete(from);
    },
    unretain(handle) { retained.delete(handle); },
    release(handle) {
      sessions.delete(handle);
      retained.delete(handle);
    },
  };
}
