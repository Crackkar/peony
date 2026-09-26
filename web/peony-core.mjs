import { createFsHost } from './fs-host.mjs';

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
const MAX_PACKET_BYTES = 1024 * 1024;
const utf8Encoder = new TextEncoder();
const utf8Decoder = new TextDecoder('utf-8', { fatal: true });

export const Peony = Object.freeze({
  async load(source) {
    await assertWorkerContext();
    const filesystem = createFsHost();
    let input;
    if (source instanceof URL || typeof source === 'string') {
      const response = await fetch(source);
      if (!response.ok) throw new Error(`failed to load Peony WASM: ${response.status}`);
      input = await response.arrayBuffer();
    } else if (typeof Response !== 'undefined' && source instanceof Response) {
      const response = source.clone();
      if (typeof WebAssembly.instantiateStreaming === 'function') {
        try {
          const { instance } = await WebAssembly.instantiateStreaming(response, filesystem.imports);
          filesystem.bind(instance.exports);
          return new PeonyModule(instance.exports, filesystem);
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
    const { instance } = await WebAssembly.instantiate(input, filesystem.imports);
    filesystem.bind(instance.exports);
    return new PeonyModule(instance.exports, filesystem);
  },
});

class PeonyModule {
  constructor(exports, filesystem) {
    if (!(exports.memory instanceof WebAssembly.Memory) || exports.peony_abi_version() !== 1) {
      throw new Error('incompatible Peony WASM ABI');
    }
    this.exports = exports;
    this.filesystem = filesystem;
  }

  createSession(options = {}) {
    return new PeonySession(this.exports, this.filesystem, options);
  }
}

class PeonySession {
  constructor(api, filesystem, options) {
    this.api = api;
    this.filesystem = filesystem;
    this.savedFilesHandle = 0;
    this.options = {
      stdout: options.stdout,
      stderr: options.stderr,
      input: options.input,
      fetch: options.fetch ?? globalThis.fetch,
      allowUrl: options.allowUrl,
      maxHttpResponseBytes: options.maxHttpResponseBytes ?? MAX_PACKET_BYTES - 16 * 1024,
      wallClock: options.wallClock ?? (() => Date.now() / 1000),
      monotonicClock: options.monotonicClock ?? (() => performance.now() / 1000),
      sleep: options.sleep ?? defaultSleep,
      quantum: options.quantum ?? 50_000,
      maxMemoryBytes: options.maxMemoryBytes ?? 64 * 1024 * 1024,
      maxInstructions: options.maxInstructions ?? 50_000_000,
      maxVfsBytes: options.maxVfsBytes ?? 8 * 1024 * 1024,
      maxFileBytes: options.maxFileBytes ?? 2 * 1024 * 1024,
      seed: options.seed ?? new Uint8Array(),
    };
    this.config = encodeConfig(this.options);
    if (!Number.isSafeInteger(this.options.maxHttpResponseBytes) || this.options.maxHttpResponseBytes < 0 || this.options.maxHttpResponseBytes > MAX_PACKET_BYTES) {
      throw new RangeError('maxHttpResponseBytes must be between 0 and 1 MiB');
    }
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
      const argv = encodeArgv(options.argv ?? []);
      const sourceTransfer = this.writeTransfer(utf8Encoder.encode(source));
      let filenameTransfer = null;
      let argvTransfer = null;
      let compileStatus;
      try {
        filenameTransfer = this.writeTransfer(utf8Encoder.encode(filename));
        if (argv === null) {
          compileStatus = this.api.peony_compile_and_start(
            this.handle, sourceTransfer.pointer, sourceTransfer.length,
            filenameTransfer.pointer, filenameTransfer.length,
          );
        } else {
          if (typeof this.api.peony_compile_and_start_argv !== 'function') throw new Error('Peony WASM lacks argv transfer support');
          argvTransfer = this.writeTransfer(argv);
          compileStatus = this.api.peony_compile_and_start_argv(
            this.handle, sourceTransfer.pointer, sourceTransfer.length,
            filenameTransfer.pointer, filenameTransfer.length,
            argvTransfer.pointer, argvTransfer.length,
          );
        }
      } finally {
        this.freeTransfer(sourceTransfer);
        if (filenameTransfer !== null) this.freeTransfer(filenameTransfer);
        if (argvTransfer !== null) this.freeTransfer(argvTransfer);
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
          await this.drainOutput();
          let response;
          if (event.kind === PACKET.input) {
            if (event.sections.length !== 1 || event.sections[0].type !== 1) throw new Error('Peony returned a malformed input request');
            response = await this.waitForInput(utf8Decoder.decode(event.sections[0].bytes));
          } else {
            response = await this.waitForService(event);
          }
          if (response === cancelSentinel) continue;
          const packet = event.kind === PACKET.input
            ? response.error !== undefined
              ? encodePacket({ kind: event.kind, requestId: event.requestId, statusCode: 2, text: response.error })
              : response.value === null
                ? encodePacket({ kind: event.kind, requestId: event.requestId, statusCode: 1 })
                : encodePacket({ kind: event.kind, requestId: event.requestId, statusCode: 0, text: String(response.value) })
            : encodePacket({ kind: event.kind, requestId: event.requestId, statusCode: response.statusCode, sections: response.sections });
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
    if (files === null || typeof files !== 'object') throw new TypeError('mount expects a mapping of /assets paths to bytes');
    if (options === null || typeof options !== 'object' || Array.isArray(options)) throw new TypeError('mount options must be an object');
    for (const key of Reflect.ownKeys(options)) if (key !== 'root') throw new TypeError(`unsupported mount option: ${String(key)}`);
    const root = Object.hasOwn(options, 'root') ? options.root : '/assets';
    if (typeof root !== 'string' || !root.startsWith('/assets')) throw new TypeError('mount root must be inside /assets');
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
    return this.vfsList('peony_vfs_list', path);
  }

  listDirectories(path = '/') {
    return this.vfsList('peony_vfs_dirs', path);
  }

  vfsList(exportName, path) {
    checkedVfsPath(path);
    const pathBlock = this.writeTransfer(utf8Encoder.encode(path));
    let result;
    try {
      result = this.api[exportName](this.handle, pathBlock.pointer, pathBlock.length);
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

  vfsMkdir(path) {
    checkedVfsPath(path);
    const pathBlock = this.writeTransfer(utf8Encoder.encode(path));
    try {
      this.checkVfsStatus(this.api.peony_vfs_mkdir(this.handle, pathBlock.pointer, pathBlock.length), 'mkdir');
    } finally {
      this.freeTransfer(pathBlock);
    }
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
    if (operation === 'mount') throw new Error(`Peony read-only mount rejected: invalid path, duplicate, or permission denied (${result})`);
    throw new Error(`Peony VFS ${operation} rejected: invalid path or permission denied (${result})`);
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
    if (this.handle === 0) {
      if (this.savedFilesHandle !== 0) this.filesystem.release(this.savedFilesHandle);
      this.savedFilesHandle = 0;
      return true;
    }
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

  stats() {
    if (this.handle === 0) throw new Error('Peony session is destroyed');
    return {
      instructions: Number(this.api.peony_instruction_count(this.handle)),
      work: Number(this.api.peony_work_count(this.handle)),
      liveSessionBytes: Number(this.api.peony_session_live_bytes(this.handle)),
      peakSessionBytes: Number(this.api.peony_session_peak_bytes(this.handle)),
      gcObjects: Number(this.api.peony_gc_object_count(this.handle)),
      gcCollections: Number(this.api.peony_gc_collection_count(this.handle)),
      vfsBytes: Number(this.api.peony_vfs_total_bytes(this.handle)),
    };
  }

  collectGarbage() {
    if (this.handle === 0) throw new Error('Peony session is destroyed');
    if (this.running) throw new Error('cannot collect garbage while Peony is running');
    const status = this.api.peony_collect_garbage(this.handle);
    if (status !== STATUS.ok) throw new Error(`Peony garbage collection failed (${status})`);
    return this.stats();
  }

  async waitForService(event) {
    if (this.cancelled) return cancelSentinel;
    const controller = new AbortController();
    let resolveRace;
    const cancelled = new Promise((resolve) => { resolveRace = resolve; });
    this.resolveCancel = () => { controller.abort(); resolveRace(cancelSentinel); };
    try {
      return await Promise.race([this.serviceHostEvent(event, controller), cancelled]);
    } finally {
      if (this.resolveCancel !== null) this.resolveCancel = null;
    }
  }

  async serviceHostEvent(event, controller) {
    if (event.kind === PACKET.http) return this.serviceHttp(event, controller);
    if (event.kind === PACKET.clock) {
      if (event.sections.length !== 1 || event.sections[0].type !== 1) throw new Error('Peony returned a malformed CLOCK request');
      const clock = utf8Decoder.decode(event.sections[0].bytes);
      if (clock !== 'wall' && clock !== 'monotonic') throw new Error('Peony returned an unknown clock request');
      try {
        const seconds = await (clock === 'wall' ? this.options.wallClock() : this.options.monotonicClock());
        if (typeof seconds !== 'number' || !Number.isFinite(seconds)) throw new Error('host clock did not return a finite number');
        const bytes = new Uint8Array(8);
        new DataView(bytes.buffer).setFloat64(0, seconds, true);
        return { statusCode: 0, sections: [{ type: 2, bytes }] };
      } catch (error) {
        return serviceError('clock', error);
      }
    }
    if (event.kind === PACKET.sleep) {
      if (event.sections.length !== 1 || event.sections[0].type !== 2 || event.sections[0].bytes.length !== 8) throw new Error('Peony returned a malformed SLEEP request');
      const bytes = event.sections[0].bytes;
      const seconds = new DataView(bytes.buffer, bytes.byteOffset, 8).getFloat64(0, true);
      if (!Number.isFinite(seconds) || seconds < 0) throw new Error('Peony returned an invalid sleep duration');
      try {
        await this.options.sleep(seconds, controller.signal);
        return { statusCode: 0, sections: [] };
      } catch (error) {
        return serviceError('sleep', error);
      }
    }
    throw new Error(`Peony returned an unsupported host request kind ${event.kind}`);
  }

  async serviceHttp(event, controller) {
    const sections = event.sections;
    if ((sections.length !== 4 && sections.length !== 5) || sections[0].type !== 1 || sections[1].type !== 1 || sections[2].type !== 1 || sections[3].type !== 2 || (sections.length === 5 && (sections[4].type !== 2 || sections[4].bytes.length !== 8))) {
      throw new Error('Peony returned a malformed HTTP request');
    }
    const method = utf8Decoder.decode(sections[0].bytes);
    const url = utf8Decoder.decode(sections[1].bytes);
    const headerBlock = utf8Decoder.decode(sections[2].bytes);
    const headers = parseHeaderBlock(headerBlock);
    const timeout = sections.length === 5 ? new DataView(sections[4].bytes.buffer, sections[4].bytes.byteOffset, 8).getFloat64(0, true) : null;
    if (timeout !== null && (!Number.isFinite(timeout) || timeout < 0)) throw new Error('Peony returned an invalid HTTP timeout');
    if (typeof this.options.fetch !== 'function') return serviceError('connection', new Error('fetch is unavailable'));
    let timedOut = false;
    const timer = timeout === null ? null : setTimeout(() => { timedOut = true; controller.abort(); }, Math.min(timeout * 1000, 0x7fff_ffff));
    try {
      if (this.options.allowUrl) {
        const allowed = await awaitAbortable(this.options.allowUrl(url), controller.signal);
        if (controller.signal.aborted) return serviceError(timedOut ? 'timeout' : 'connection', new Error('request aborted'));
        if (!allowed) return serviceError('policy', new Error('URL denied by host policy'));
      }
      if (controller.signal.aborted) return serviceError(timedOut ? 'timeout' : 'connection', new Error('request aborted'));
      const response = await this.options.fetch(url, {
        method,
        headers,
        body: sections[3].bytes.length ? sections[3].bytes : undefined,
        credentials: 'omit',
        redirect: 'error',
        signal: controller.signal,
      });
      if (!(response instanceof Response)) throw new Error('fetch did not return a Response');
      const body = await readHttpBody(response, this.options.maxHttpResponseBytes, controller);
      const status = new Uint8Array(2);
      new DataView(status.buffer).setUint16(0, response.status, true);
      const responseHeaders = [];
      for (const [name, value] of response.headers) responseHeaders.push(`${name}: ${value}\r\n`);
      const headerBytes = utf8Encoder.encode(responseHeaders.join(''));
      if (24 + 3 * 12 + status.length + headerBytes.length + body.length > MAX_PACKET_BYTES) {
        controller.abort();
        throw new Error('HTTP response exceeds the packet limit');
      }
      return { statusCode: 0, sections: [
        { type: 2, bytes: status },
        { type: 1, bytes: headerBytes },
        { type: 2, bytes: body },
      ] };
    } catch (error) {
      return serviceError(timedOut ? 'timeout' : 'connection', error);
    } finally {
      if (timer !== null) clearTimeout(timer);
    }
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
    if (this.handle !== 0) {
      this.filesystem.retain(this.handle);
      const destroyed = this.api.peony_session_destroy(this.handle);
      if (destroyed !== STATUS.ok) {
        this.filesystem.unretain(this.handle);
        throw new Error(`Peony session destroy failed (${destroyed})`);
      }
      this.savedFilesHandle = this.handle;
      this.handle = 0;
    }
    const next = this.createRawSession();
    if (this.savedFilesHandle !== 0) {
      this.filesystem.move(this.savedFilesHandle, next);
      this.savedFilesHandle = 0;
    }
    this.handle = next;
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

function serviceError(classification, error) {
  const message = error instanceof Error ? error.message : String(error);
  return { statusCode: 2, sections: [
    { type: 1, bytes: utf8Encoder.encode(classification) },
    { type: 1, bytes: utf8Encoder.encode(message.slice(0, 2048)) },
  ] };
}

async function assertWorkerContext() {
  if (typeof WorkerGlobalScope !== 'undefined' && self instanceof WorkerGlobalScope) return;
  if (typeof process !== 'undefined' && process.versions?.node) {
    const { isMainThread } = await import('node:worker_threads');
    if (!isMainThread) return;
  }
  throw new Error('Peony WASM may only be loaded inside a Worker');
}

function parseHeaderBlock(block) {
  const headers = new Headers();
  if (block === '') return headers;
  if (!block.endsWith('\r\n')) throw new Error('Peony HTTP request headers are malformed');
  for (const line of block.slice(0, -2).split('\r\n')) {
    const colon = line.indexOf(':');
    if (colon <= 0 || !/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(line.slice(0, colon))) throw new Error('Peony HTTP request header name is invalid');
    const value = line.slice(colon + 1).trim();
    if (/[\x00-\x08\x0a-\x1f\x7f]/.test(value)) throw new Error('Peony HTTP request header value is invalid');
    headers.append(line.slice(0, colon), value);
  }
  return headers;
}

async function readHttpBody(response, limit, controller) {
  if (!response.body) return new Uint8Array();
  const reader = response.body.getReader();
  const chunks = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!(value instanceof Uint8Array)) throw new Error('HTTP body stream returned non-byte content');
      total += value.length;
      if (total > limit) {
        try { await reader.cancel(); } catch { /* the request is aborted below */ }
        controller.abort();
        throw new Error('HTTP response exceeds maxHttpResponseBytes');
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const body = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) { body.set(chunk, offset); offset += chunk.length; }
  return body;
}

function defaultSleep(seconds, signal) {
  return new Promise((resolve, reject) => {
    if (signal.aborted) { reject(new Error('sleep aborted')); return; }
    const timer = setTimeout(() => { signal.removeEventListener('abort', abort); resolve(); }, Math.min(seconds * 1000, 0x7fff_ffff));
    const abort = () => { clearTimeout(timer); reject(new Error('sleep aborted')); };
    signal.addEventListener('abort', abort, { once: true });
  });
}

function encodeArgv(argv) {
  if (!Array.isArray(argv)) throw new TypeError('run argv must be an array of strings');
  if (argv.length > 256) throw new RangeError('run argv exceeds 256 arguments');
  if (argv.length === 0) return null;
  const encoded = [];
  let total = 2;
  for (const argument of argv) {
    if (typeof argument !== 'string' || argument.includes('\0')) throw new TypeError('run argv entries must be strings without NUL');
    const bytes = utf8Encoder.encode(argument);
    total += 4 + bytes.length;
    if (total > 64 * 1024) throw new RangeError('run argv exceeds 64 KiB');
    encoded.push(bytes);
  }
  const blob = new Uint8Array(total);
  const view = new DataView(blob.buffer);
  view.setUint16(0, encoded.length, true);
  let cursor = 2;
  for (const bytes of encoded) {
    view.setUint32(cursor, bytes.length, true);
    cursor += 4;
    blob.set(bytes, cursor);
    cursor += bytes.length;
  }
  return blob;
}

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

function awaitAbortable(value, signal) {
  if (signal.aborted) return Promise.resolve(false);
  let onAbort;
  const aborted = new Promise(resolve => {
    onAbort = () => resolve(false);
    signal.addEventListener('abort', onAbort, { once: true });
  });
  return Promise.race([Promise.resolve(value), aborted]).finally(() => signal.removeEventListener('abort', onAbort));
}

function encodePacket({ kind, requestId, statusCode = 0, text, sections }) {
  const items = sections ?? (text === undefined ? [] : [{ type: 1, bytes: utf8Encoder.encode(text) }]);
  if (items.length > 64) throw new Error('Peony host response has too many sections');
  const descriptorBytes = items.length * 12;
  let total = 24 + descriptorBytes;
  for (const item of items) {
    if ((item.type !== 1 && item.type !== 2) || !(item.bytes instanceof Uint8Array)) throw new Error('Peony host response has an invalid section');
    total += item.bytes.length;
    if (total > MAX_PACKET_BYTES) throw new Error('Peony host response exceeds the packet limit');
  }
  const packet = new Uint8Array(total);
  const view = new DataView(packet.buffer);
  packet.set([0x50, 0x45, 0x4f, 0x4e]);
  view.setUint16(4, 1, true);
  view.setUint16(6, kind, true);
  view.setUint32(8, requestId, true);
  view.setUint16(12, statusCode, true);
  view.setUint16(16, items.length, true);
  view.setUint32(20, packet.length, true);
  let offset = 24 + descriptorBytes;
  for (let index = 0; index < items.length; index += 1) {
    const item = items[index];
    const descriptor = 24 + index * 12;
    view.setUint16(descriptor, item.type, true);
    view.setUint32(descriptor + 4, offset, true);
    view.setUint32(descriptor + 8, item.bytes.length, true);
    packet.set(item.bytes, offset);
    offset += item.bytes.length;
  }
  return packet;
}

function decodePacket(packet) {
  if (packet.length < 24 || packet.length > MAX_PACKET_BYTES || packet[0] !== 0x50 || packet[1] !== 0x45 || packet[2] !== 0x4f || packet[3] !== 0x4e) {
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
