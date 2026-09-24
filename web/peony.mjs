const STATUS = Object.freeze({
  ok: 0,
  invalidHandle: 2,
  invalidArgument: 3,
  outOfMemory: 4,
  completed: 5,
  pythonException: 6,
  timeslice: 7,
  cancelled: 8,
  internalError: 9,
  hostRequest: 10,
  outputEvent: 11,
  limit: 12,
});

const PACKET = Object.freeze({ input: 1, http: 2, sleep: 3, clock: 4, output: 5 });
const utf8Encoder = new TextEncoder();
const utf8Decoder = new TextDecoder('utf-8', { fatal: true });

export const Peony = Object.freeze({
  async load(source) {
    let input;
    if (source instanceof URL || typeof source === 'string') {
      const response = await fetch(source);
      if (!response.ok) throw new Error(`failed to load Peony WASM: ${response.status}`);
      input = await response.arrayBuffer();
    } else if (typeof Response !== 'undefined' && source instanceof Response) {
      const response = source.clone();
      if (typeof WebAssembly.instantiateStreaming === 'function') {
        try {
          const { instance } = await WebAssembly.instantiateStreaming(response, {});
          return new PeonyModule(instance.exports);
        } catch {
          // Servers sometimes send WASM with the wrong MIME type; byte instantiation works there.
        }
      }
      input = await source.arrayBuffer();
    } else if (source instanceof ArrayBuffer) {
      input = source;
    } else if (ArrayBuffer.isView(source)) {
      input = source.buffer.slice(source.byteOffset, source.byteOffset + source.byteLength);
    } else {
      throw new TypeError('Peony.load expects a URL string, URL, Response, ArrayBuffer, or typed array');
    }
    const { instance } = await WebAssembly.instantiate(input, {});
    return new PeonyModule(instance.exports);
  },
});

class PeonyModule {
  constructor(exports) {
    if (!(exports.memory instanceof WebAssembly.Memory) || exports.peony_abi_version() !== 1) {
      throw new Error('incompatible Peony WASM ABI');
    }
    this.exports = exports;
  }

  createSession(options = {}) {
    return new PeonySession(this.exports, options);
  }
}

class PeonySession {
  constructor(api, options) {
    this.api = api;
    this.options = {
      stdout: options.stdout,
      stderr: options.stderr,
      input: options.input,
      quantum: options.quantum ?? 50_000,
      maxMemoryBytes: options.maxMemoryBytes ?? 64 * 1024 * 1024,
      maxInstructions: options.maxInstructions ?? 50_000_000,
      maxVfsBytes: options.maxVfsBytes ?? 8 * 1024 * 1024,
      maxFileBytes: options.maxFileBytes ?? 2 * 1024 * 1024,
      seed: options.seed ?? new Uint8Array(),
    };
    this.config = encodeConfig(this.options);
    this.handle = this.createRawSession();
    this.running = false;
    this.cancelled = false;
    this.resolveCancel = null;
    this.outputDecoder = new TextDecoder();
    this.hasRun = false;
    this.resetRequested = false;
    this.resetWaiters = [];
  }

  async run(source, options = {}) {
    if (this.running) throw new Error('Peony session is already running');
    if (this.hasRun) this.replaceRawSession();
    this.hasRun = true;
    this.running = true;
    this.cancelled = false;
    try {
      const filename = options.filename ?? '<string>';
      const sourceTransfer = this.writeTransfer(utf8Encoder.encode(source));
      let filenameTransfer = null;
      let compileStatus;
      try {
        filenameTransfer = this.writeTransfer(utf8Encoder.encode(filename));
        compileStatus = this.api.peony_compile_and_start(
          this.handle,
          sourceTransfer.pointer,
          sourceTransfer.length,
          filenameTransfer.pointer,
          filenameTransfer.length,
        );
      } finally {
        this.freeTransfer(sourceTransfer);
        if (filenameTransfer !== null) this.freeTransfer(filenameTransfer);
      }
      if (compileStatus !== STATUS.ok) return await this.failureResult(compileStatus);

      while (true) {
        if (this.cancelled) this.api.peony_cancel(this.handle);
        const result = this.api.peony_run(this.handle, this.options.quantum);
        if (result === STATUS.timeslice) {
          await this.drainOutput();
          await yieldToHostTask();
          continue;
        }
        if (result === STATUS.outputEvent) {
          const event = this.copyEvent();
          await this.drainOutput();
          if (event.kind !== PACKET.output) throw new Error('Peony returned a malformed output event');
          continue;
        }
        if (result === STATUS.hostRequest) {
          const event = this.copyEvent();
          if (event.kind !== PACKET.input || event.sections.length !== 1) throw new Error('Peony returned a malformed input request');
          const prompt = utf8Decoder.decode(event.sections[0].bytes);
          await this.drainOutput();
          const response = await this.waitForInput(prompt);
          if (response === cancelSentinel) continue;
          const packet = response.error !== undefined
            ? encodePacket({ kind: event.kind, requestId: event.requestId, statusCode: 2, text: response.error })
            : response.value === null
              ? encodePacket({ kind: event.kind, requestId: event.requestId, statusCode: 1 })
              : encodePacket({ kind: event.kind, requestId: event.requestId, statusCode: 0, text: String(response.value) });
          const transfer = this.writeTransfer(packet);
          let resumed;
          try {
            resumed = this.api.peony_resume(this.handle, transfer.pointer, transfer.length);
          } finally {
            this.freeTransfer(transfer);
          }
          if (resumed !== STATUS.ok) throw new Error(`Peony rejected a host response (${resumed})`);
          continue;
        }
        if (result === STATUS.completed) {
          await this.drainOutput();
          return this.result('completed');
        }
        if (result === STATUS.cancelled) {
          await this.drainOutput();
          return this.result('cancelled');
        }
        if (result === STATUS.limit) {
          await this.drainOutput();
          return this.result('limit');
        }
        if (result === STATUS.pythonException || result === STATUS.internalError) {
          await this.drainOutput();
          return await this.failureResult(result);
        }
        throw new Error(`unexpected Peony execution status ${result}`);
      }
    } finally {
      this.running = false;
      this.resolveCancel = null;
      if (this.resetRequested) {
        this.resetRequested = false;
        const waiters = this.resetWaiters.splice(0);
        try {
          this.replaceRawSession();
          this.hasRun = false;
          for (const [resolve] of waiters) resolve();
        } catch (error) {
          for (const [, reject] of waiters) reject(error);
          throw error;
        }
      }
    }
  }

  cancel() {
    this.cancelled = true;
    this.api.peony_cancel(this.handle);
    if (this.resolveCancel) this.resolveCancel(cancelSentinel);
  }

  mount(files, options = {}) {
    if (files === null || typeof files !== 'object') throw new TypeError('mount expects a mapping of course paths to bytes');
    if (options === null || typeof options !== 'object' || Array.isArray(options)) throw new TypeError('mount options must be an object');
    for (const key of Reflect.ownKeys(options)) if (key !== 'root') throw new TypeError(`unsupported mount option: ${String(key)}`);
    const root = Object.hasOwn(options, 'root') ? options.root : '/course';
    if (typeof root !== 'string' || !root.startsWith('/course')) throw new TypeError('mount root must be inside /course');
    if (!(files instanceof Map) && Object.getOwnPropertySymbols(files).some((key) => Object.prototype.propertyIsEnumerable.call(files, key))) {
      throw new TypeError('mount paths must be strings');
    }
    for (const [path, content] of Object.entries(files)) {
      checkedVfsPath(path, 'mount path');
      const bytes = fileBytes(content);
      const mountPath = path.startsWith('/') ? path : `${root.replace(/\/$/, '')}/${path}`;
      this.vfsWrite('peony_vfs_mount', mountPath, bytes);
    }
  }

  readFile(path) {
    checkedVfsPath(path);
    const pathBlock = this.writeTransfer(utf8Encoder.encode(path));
    let result;
    try {
      result = this.api.peony_vfs_read(this.handle, pathBlock.pointer, pathBlock.length);
    } finally {
      this.freeTransfer(pathBlock);
    }
    this.checkVfsStatus(result, 'read');
    const length = this.api.peony_vfs_data_len(this.handle);
    const pointer = this.api.peony_vfs_data_ptr(this.handle);
    return length === 0 ? new Uint8Array() : new Uint8Array(this.api.memory.buffer, pointer, length).slice();
  }

  writeFile(path, content) {
    checkedVfsPath(path);
    this.vfsWrite('peony_vfs_write', path, fileBytes(content));
  }

  listFiles(path = '/') {
    checkedVfsPath(path);
    const pathBlock = this.writeTransfer(utf8Encoder.encode(path));
    let result;
    try {
      result = this.api.peony_vfs_list(this.handle, pathBlock.pointer, pathBlock.length);
    } finally {
      this.freeTransfer(pathBlock);
    }
    this.checkVfsStatus(result, 'list');
    const length = this.api.peony_vfs_data_len(this.handle);
    if (length === 0) return [];
    const pointer = this.api.peony_vfs_data_ptr(this.handle);
    const borrowed = new Uint8Array(this.api.memory.buffer, pointer, length);
    return utf8Decoder.decode(borrowed).split('\0').filter((entry) => entry.length !== 0);
  }

  vfsWrite(exportName, path, bytes) {
    checkedVfsPath(path);
    let pathBlock = null;
    let dataBlock = null;
    try {
      pathBlock = this.writeTransfer(utf8Encoder.encode(path));
      dataBlock = this.writeTransfer(bytes);
      const result = this.api[exportName](this.handle, pathBlock.pointer, pathBlock.length, dataBlock.pointer, dataBlock.length);
      this.checkVfsStatus(result, exportName === 'peony_vfs_mount' ? 'mount' : 'write');
    } finally {
      if (dataBlock !== null) this.freeTransfer(dataBlock);
      if (pathBlock !== null) this.freeTransfer(pathBlock);
    }
  }

  checkVfsStatus(result, operation) {
    if (result === STATUS.ok) return;
    if (result === STATUS.invalidHandle) throw new Error(`Peony VFS ${operation} used an invalid session`);
    if (result === STATUS.outOfMemory) throw new Error(`Peony VFS ${operation} exceeded its memory limit`);
    if (operation === 'read') throw new Error(`Peony file not found, invalid path, or permission denied: ${result}`);
    if (operation === 'mount') throw new Error(`Peony course mount rejected: invalid path, duplicate, or permission denied (${result})`);
    throw new Error(`Peony VFS ${operation} rejected: invalid path or permission denied (${result})`);
  }

  snapshotPersistentVfs() {
    const files = [];
    for (const root of ['/course', '/home']) {
      for (const path of this.listFiles(root)) files.push([path, this.readFile(path)]);
    }
    return files;
  }

  restorePersistentVfs(files) {
    for (const [path, bytes] of files) {
      this.vfsWrite(path.startsWith('/course/') ? 'peony_vfs_mount' : 'peony_vfs_write', path, bytes);
    }
  }

  reset() {
    if (this.running) {
      this.resetRequested = true;
      this.cancel();
      return new Promise((resolve, reject) => this.resetWaiters.push([resolve, reject]));
    }
    this.replaceRawSession();
    this.hasRun = false;
    this.cancelled = false;
  }

  destroy() {
    if (this.running) throw new Error('cannot destroy a running Peony session');
    const result = this.api.peony_session_destroy(this.handle);
    this.handle = 0;
    return result === STATUS.ok;
  }

  async waitForInput(prompt) {
    if (this.cancelled) return cancelSentinel;
    if (typeof this.options.input !== 'function') return { error: 'input callback is not configured' };
    let resolveRace;
    const cancelled = new Promise((resolve) => { resolveRace = resolve; });
    this.resolveCancel = resolveRace;
    let hostResult;
    try {
      const pending = Promise.resolve().then(() => this.options.input(prompt)).then(
        (value) => ({ value }),
        (error) => ({ error: error instanceof Error ? error.message : String(error) }),
      );
      hostResult = await Promise.race([pending, cancelled]);
    } finally {
      if (this.resolveCancel === resolveRace) this.resolveCancel = null;
    }
    return hostResult;
  }

  async drainOutput() {
    const output = this.copyAndConsume(this.api.peony_stdout_ptr, this.api.peony_stdout_len, this.api.peony_stdout_consume);
    if (output.length !== 0 && typeof this.options.stdout === 'function') {
      await this.options.stdout(this.outputDecoder.decode(output, { stream: true }));
    }
    const stderr = this.copyAndConsume(this.api.peony_stderr_ptr, this.api.peony_stderr_len, this.api.peony_stderr_consume);
    if (stderr.length !== 0 && typeof this.options.stderr === 'function') {
      await this.options.stderr(new TextDecoder().decode(stderr));
    }
  }

  copyAndConsume(pointerExport, lengthExport, consumeExport) {
    const length = lengthExport(this.handle);
    if (length === 0) return new Uint8Array();
    const pointer = pointerExport(this.handle);
    const copy = new Uint8Array(this.api.memory.buffer, pointer, length).slice();
    const consumed = consumeExport(this.handle, length);
    if (consumed !== STATUS.ok) throw new Error(`Peony output consume failed (${consumed})`);
    return copy;
  }

  copyEvent() {
    const length = this.api.peony_event_len(this.handle);
    if (length === 0) throw new Error('Peony event packet is empty');
    const pointer = this.api.peony_event_ptr(this.handle);
    const bytes = new Uint8Array(this.api.memory.buffer, pointer, length).slice();
    return decodePacket(bytes);
  }

  result(status) {
    return {
      status,
      error: null,
      frames: [],
      counters: {
        instructions: Number(this.api.peony_instruction_count(this.handle)),
        work: Number(this.api.peony_work_count(this.handle)),
      },
    };
  }

  async failureResult(code) {
    const message = this.readText(this.api.peony_error_ptr, this.api.peony_error_len);
    const traceback = this.readText(this.api.peony_traceback_ptr, this.api.peony_traceback_len);
    let frames = [];
    try {
      if (traceback) frames = JSON.parse(traceback);
    } catch {
      frames = [];
    }
    return {
      status: 'error',
      error: { message: message || (code === STATUS.internalError ? 'Peony internal error' : 'Python exception') },
      frames,
      counters: {
        instructions: Number(this.api.peony_instruction_count(this.handle)),
        work: Number(this.api.peony_work_count(this.handle)),
      },
    };
  }

  readText(pointerExport, lengthExport) {
    const length = lengthExport(this.handle);
    if (length === 0) return '';
    const pointer = pointerExport(this.handle);
    const copy = new Uint8Array(this.api.memory.buffer, pointer, length).slice();
    return utf8Decoder.decode(copy);
  }

  writeTransfer(bytes) {
    const pointer = this.api.peony_transfer_alloc(bytes.length);
    if (bytes.length !== 0 && pointer === 0) throw new Error('Peony transfer allocation failed');
    if (bytes.length !== 0) new Uint8Array(this.api.memory.buffer, pointer, bytes.length).set(bytes);
    return { pointer, length: bytes.length };
  }

  freeTransfer(allocation) {
    if (allocation.length !== 0) this.api.peony_transfer_free(allocation.pointer, allocation.length);
  }

  createRawSession() {
    const allocation = this.writeTransfer(this.config);
    try {
      const handle = this.api.peony_session_new(allocation.pointer, allocation.length);
      if (handle === 0) throw new Error('could not create Peony session');
      return handle;
    } finally {
      this.freeTransfer(allocation);
    }
  }

  replaceRawSession() {
    const persistentFiles = this.handle === 0 ? [] : this.snapshotPersistentVfs();
    if (this.handle !== 0) {
      const destroyed = this.api.peony_session_destroy(this.handle);
      if (destroyed !== STATUS.ok) throw new Error(`Peony session destroy failed (${destroyed})`);
      this.handle = 0;
    }
    this.handle = this.createRawSession();
    this.restorePersistentVfs(persistentFiles);
    this.outputDecoder = new TextDecoder();
    this.cancelled = false;
  }
}

function fileBytes(content) {
  if (typeof content === 'string') return utf8Encoder.encode(content);
  if (content instanceof ArrayBuffer) return new Uint8Array(content);
  if (ArrayBuffer.isView(content)) return new Uint8Array(content.buffer, content.byteOffset, content.byteLength);
  throw new TypeError('VFS file contents must be a string or byte buffer');
}

function checkedVfsPath(path, label = 'VFS path') {
  if (typeof path !== 'string') throw new TypeError(`${label} must be a string`);
  return path;
}

const cancelSentinel = Symbol('cancelled input');

function encodeConfig(options) {
  const maxMemoryBytes = positiveUint32(options.maxMemoryBytes, 'maxMemoryBytes');
  const quantum = positiveUint32(options.quantum, 'quantum');
  const maxInstructions = positiveUint64(options.maxInstructions);
  const maxVfsBytes = positiveUint32(options.maxVfsBytes, 'maxVfsBytes');
  const maxFileBytes = positiveUint32(options.maxFileBytes, 'maxFileBytes');
  if (maxFileBytes > maxVfsBytes) throw new RangeError('maxFileBytes cannot exceed maxVfsBytes');
  let seed;
  if (typeof options.seed === 'string') {
    seed = utf8Encoder.encode(options.seed);
  } else if (options.seed instanceof ArrayBuffer) {
    seed = new Uint8Array(options.seed);
  } else if (ArrayBuffer.isView(options.seed)) {
    seed = new Uint8Array(options.seed.buffer, options.seed.byteOffset, options.seed.byteLength);
  } else {
    throw new TypeError('seed must be a string or byte buffer');
  }
  if (seed.length > 1024) throw new RangeError('Peony seed is too long');
  const hasVfsExtension = maxVfsBytes !== 8 * 1024 * 1024 || maxFileBytes !== 2 * 1024 * 1024;
  const extensionLength = hasVfsExtension ? 8 : 0;
  const packet = new Uint8Array(28 + seed.length + extensionLength);
  const view = new DataView(packet.buffer);
  packet.set([0x50, 0x43, 0x46, 0x47]);
  view.setUint16(4, 1, true);
  view.setUint16(6, seed.length === 0 ? 0 : 1, true);
  view.setUint32(8, maxMemoryBytes, true);
  view.setBigUint64(12, maxInstructions, true);
  view.setUint32(20, quantum, true);
  view.setUint16(24, seed.length, true);
  view.setUint16(26, extensionLength, true);
  packet.set(seed, 28);
  if (hasVfsExtension) {
    view.setUint32(28 + seed.length, maxVfsBytes, true);
    view.setUint32(32 + seed.length, maxFileBytes, true);
  }
  return packet;
}

function positiveUint32(value, name) {
  if (typeof value !== 'number') throw new TypeError(`${name} must be a number`);
  if (!Number.isSafeInteger(value) || value <= 0 || value > 0xffff_ffff) {
    throw new RangeError(`${name} must be a positive u32 integer`);
  }
  return value;
}

function positiveUint64(value) {
  let integer;
  if (typeof value === 'bigint') {
    integer = value;
  } else if (typeof value === 'number') {
    if (!Number.isSafeInteger(value)) throw new RangeError('maxInstructions must be an exact positive u64 integer');
    integer = BigInt(value);
  } else {
    throw new TypeError('maxInstructions must be a number or bigint');
  }
  if (integer <= 0n || integer > 0xffff_ffff_ffff_ffffn) {
    throw new RangeError('maxInstructions must be a positive u64 integer');
  }
  return integer;
}

function yieldToHostTask() {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

function encodePacket({ kind, requestId, statusCode = 0, text }) {
  const payload = text === undefined ? null : utf8Encoder.encode(text);
  const descriptorBytes = payload === null ? 0 : 12;
  const payloadOffset = 24 + descriptorBytes;
  const packet = new Uint8Array(payloadOffset + (payload?.length ?? 0));
  const view = new DataView(packet.buffer);
  packet.set([0x50, 0x45, 0x4f, 0x4e]);
  view.setUint16(4, 1, true);
  view.setUint16(6, kind, true);
  view.setUint32(8, requestId, true);
  view.setUint16(12, statusCode, true);
  view.setUint16(16, payload === null ? 0 : 1, true);
  view.setUint32(20, packet.length, true);
  if (payload !== null) {
    view.setUint16(24, 1, true);
    view.setUint32(28, payloadOffset, true);
    view.setUint32(32, payload.length, true);
    packet.set(payload, payloadOffset);
  }
  return packet;
}

function decodePacket(packet) {
  if (packet.length < 24 || packet[0] !== 0x50 || packet[1] !== 0x45 || packet[2] !== 0x4f || packet[3] !== 0x4e) {
    throw new Error('Peony event has an invalid packet header');
  }
  const view = new DataView(packet.buffer, packet.byteOffset, packet.byteLength);
  const version = view.getUint16(4, true);
  const kind = view.getUint16(6, true);
  const requestId = view.getUint32(8, true);
  const statusCode = view.getUint16(12, true);
  const flags = view.getUint16(14, true);
  const count = view.getUint16(16, true);
  const reserved = view.getUint16(18, true);
  const total = view.getUint32(20, true);
  if (version !== 1 || !Object.values(PACKET).includes(kind) || requestId === 0 || flags !== 0 || reserved !== 0 || total !== packet.length || count > 64) {
    throw new Error('Peony event has an invalid packet envelope');
  }
  const descriptorEnd = 24 + count * 12;
  if (descriptorEnd > packet.length) throw new Error('Peony event has a truncated section table');
  const sections = [];
  const ranges = [];
  for (let index = 0; index < count; index += 1) {
    const offset = 24 + index * 12;
    const type = view.getUint16(offset, true);
    const sectionFlags = view.getUint16(offset + 2, true);
    const start = view.getUint32(offset + 4, true);
    const length = view.getUint32(offset + 8, true);
    const end = start + length;
    if ((type !== 1 && type !== 2) || sectionFlags !== 0 || start < descriptorEnd || end > packet.length) {
      throw new Error('Peony event has an invalid section');
    }
    for (const range of ranges) if (start < range.end && range.start < end) throw new Error('Peony event sections overlap');
    ranges.push({ start, end });
    const bytes = packet.slice(start, end);
    if (type === 1) utf8Decoder.decode(bytes);
    sections.push({ type, bytes });
  }
  return { kind, requestId, statusCode, sections };
}
