// Public API. WASM bytes and execution are confined to peony.worker.mjs.
const VERSION = 1;
const MAX_HTTP_BYTES = 1024 * 1024;

export const Peony = Object.freeze({
  async load(source) {
    const wasm = await normalizeSource(source);
    const workerUrl = new URL('./peony.worker.mjs', import.meta.url);
    const worker = typeof Worker === 'function'
      ? new Worker(workerUrl, { type: 'module' })
      : new (await import('node:worker_threads')).Worker(workerUrl, { type: 'module' });
    const module = new PeonyModule(worker);
    try {
      await module.request(0, 'load', { source: wasm });
      return module;
    } catch (error) {
      await module.terminate();
      throw error;
    }
  },
});

async function normalizeSource(source) {
  if (source instanceof URL) return { url: source.href };
  if (typeof source === 'string') return { url: new URL(source, globalThis.location?.href ?? import.meta.url).href };
  if (typeof Response !== 'undefined' && source instanceof Response) {
    if (!source.ok) throw new Error(`failed to load Peony WASM: ${source.status}`);
    return { bytes: new Uint8Array(await source.arrayBuffer()) };
  }
  if (source instanceof ArrayBuffer) return { bytes: new Uint8Array(source.slice(0)) };
  if (ArrayBuffer.isView(source)) return { bytes: new Uint8Array(source.buffer.slice(source.byteOffset, source.byteOffset + source.byteLength)) };
  throw new TypeError('Peony.load expects a URL string, URL, Response, ArrayBuffer, or typed array');
}

class PeonyModule {
  constructor(worker) {
    this.worker = worker;
    this.pending = new Map();
    this.sessions = new Map();
    this.nextRequest = 1;
    this.nextSession = 1;
    this.closed = false;
    if (typeof worker.addEventListener === 'function') {
      worker.addEventListener('message', event => this.receive(event.data));
      worker.addEventListener('error', event => this.fail(new Error(event.message || 'Peony Worker failed')));
      worker.addEventListener('messageerror', () => this.fail(new Error('Peony Worker sent an invalid message')));
    } else {
      worker.on('message', data => this.receive(data));
      worker.on('error', error => this.fail(error));
      worker.on('exit', code => this.fail(new Error(`Peony Worker exited (${code})`)));
      worker.unref();
    }
  }

  createSession(options = {}) {
    if (this.closed) throw new Error('Peony Worker is terminated');
    const checked = validateOptions(options);
    const session = new PeonySession(this, this.nextSession++, options);
    this.sessions.set(session.id, session);
    session.ready = this.request(session.id, 'create', { options: checked }).catch(error => {
      this.sessions.delete(session.id);
      throw error;
    });
    return session;
  }

  request(session, op, args = {}, run = 0) {
    if (this.closed) return Promise.reject(new Error('Peony Worker is terminated'));
    const id = this.nextRequest++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject, session, run });
      this.worker.ref?.();
      try { this.worker.postMessage({ v: VERSION, type: 'request', id, session, run, op, args }); }
      catch (error) { this.pending.delete(id); if (this.pending.size === 0) this.worker.unref?.(); reject(error); }
    });
  }

  receive(message) {
    if (this.closed || !message || message.v !== VERSION || !Number.isSafeInteger(message.id)) {
      this.fail(new Error('invalid Peony Worker message'));
      return;
    }
    if (message.type === 'response') {
      const pending = this.pending.get(message.id);
      if (!pending || pending.session !== message.session || pending.run !== message.run) {
        this.fail(new Error('Peony Worker response did not match a request'));
        return;
      }
      this.pending.delete(message.id);
      if (this.pending.size === 0) this.worker.unref?.();
      if (message.ok) pending.resolve(message.value);
      else {
        const detail = message.error;
        const constructors = { TypeError, RangeError, SyntaxError, ReferenceError };
        const structured = detail !== null && typeof detail === 'object';
        const constructor = structured && Object.hasOwn(constructors, detail.name) ? constructors[detail.name] : Error;
        pending.reject(new constructor(structured ? detail.message : detail || 'Peony Worker request failed'));
      }
      return;
    }
    if (message.type === 'host') {
      const session = this.sessions.get(message.session);
      if (!session || !session.running || message.run !== session.runId) return;
      void session.handleHost(message);
      return;
    }
    if (message.type === 'hostAbort') {
      const session = this.sessions.get(message.session);
      session?.activeHost.get(message.id)?.controller.abort();
      return;
    }
    this.fail(new Error('unknown Peony Worker message'));
  }

  fail(error) {
    if (this.closed) return;
    this.closed = true;
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
    for (const session of this.sessions.values()) session.abortHost();
    this.sessions.clear();
    void this.worker.terminate();
  }

  async terminate() {
    if (!this.closed) this.fail(new Error('Peony Worker terminated'));
    await this.worker.terminate();
  }
}

class PeonySession {
  constructor(module, id, options) {
    this.module = module;
    this.id = id;
    this.options = options;
    this.ready = null;
    this.running = false;
    this.runId = 0;
    this.runPosted = false;
    this.cancelRequested = false;
    this.cancelSent = false;
    this.destroyed = false;
    this.activeHost = new Map();
  }

  async call(op, args = {}) {
    if (this.destroyed) throw new Error('Peony session is destroyed');
    await this.ready;
    return this.module.request(this.id, op, args);
  }

  async run(source, options = {}) {
    if (this.running) throw new Error('Peony session is already running');
    if (this.destroyed) throw new Error('Peony session is destroyed');
    if (typeof source !== 'string') throw new TypeError('run source must be a string');
    this.running = true;
    const run = ++this.runId;
    this.runPosted = false;
    this.cancelRequested = false;
    this.cancelSent = false;
    try {
      await this.ready;
      const request = this.module.request(this.id, 'run', { source, options }, run);
      this.runPosted = true;
      if (this.cancelRequested) this.sendCancel(run);
      return await request;
    } finally {
      this.running = false;
      this.runPosted = false;
      this.cancelRequested = false;
      this.cancelSent = false;
      this.abortHost();
    }
  }

  cancel() {
    if (!this.running || this.destroyed || this.module.closed) return;
    this.abortHost(false);
    this.cancelRequested = true;
    if (this.runPosted) this.sendCancel(this.runId);
  }

  sendCancel(run) {
    if (this.cancelSent) return;
    this.cancelSent = true;
    void this.module.request(this.id, 'cancel', {}, run).catch(() => {});
  }

  async reset() {
    this.cancel();
    return this.call('reset');
  }

  async mount(files, options = {}) {
    if (!files || typeof files !== 'object') throw new TypeError('mount expects a mapping of course paths to bytes');
    if (!options || typeof options !== 'object' || Array.isArray(options)) throw new TypeError('mount options must be an object');
    for (const key of Reflect.ownKeys(options)) if (key !== 'root') throw new TypeError(`unsupported mount option: ${String(key)}`);
    const root = Object.hasOwn(options, 'root') ? options.root : '/course';
    if (typeof root !== 'string' || !root.startsWith('/course')) throw new TypeError('mount root must be inside /course');
    if (Object.getOwnPropertySymbols(files).some(key => Object.prototype.propertyIsEnumerable.call(files, key))) throw new TypeError('mount paths must be strings');
    const copy = {};
    for (const [path, value] of Object.entries(files)) { checkedPath(path); copy[path] = copyBytes(value); }
    return this.call('mount', { files: copy, options: { root } });
  }

  readFile(path) { checkedPath(path); return this.call('readFile', { path }); }
  writeFile(path, content) { checkedPath(path); return this.call('writeFile', { path, content: copyBytes(content) }); }
  listFiles(path = '/') { checkedPath(path); return this.call('listFiles', { path }); }
  listDirectories(path = '/') { checkedPath(path); return this.call('listDirectories', { path }); }
  vfsMkdir(path) { checkedPath(path); return this.call('vfsMkdir', { path }); }
  stats() { return this.call('stats'); }
  collectGarbage() { return this.call('collectGarbage'); }

  async destroy() {
    if (this.running) throw new Error('cannot destroy a running Peony session');
    const result = await this.call('destroy');
    this.destroyed = true;
    this.module.sessions.delete(this.id);
    return result;
  }

  abortHost(includeOutput = true) {
    for (const [id, call] of this.activeHost) {
      if (!includeOutput && (call.kind === 'stdout' || call.kind === 'stderr')) continue;
      call.controller.abort();
      this.activeHost.delete(id);
    }
  }

  async handleHost(message) {
    const controller = new AbortController();
    this.activeHost.set(message.id, { controller, kind: message.kind });
    let reply;
    try { reply = { ok: true, value: await this.invokeHost(message.kind, message.args, controller.signal) }; }
    catch (error) { reply = { ok: false, error: error instanceof Error ? error.message : String(error) }; }
    this.activeHost.delete(message.id);
    if (this.module.closed || !this.running || this.runId !== message.run || controller.signal.aborted) return;
    this.module.worker.postMessage({ v: VERSION, type: 'hostResult', id: message.id, session: this.id, run: message.run, ...reply });
  }

  async invokeHost(kind, args, signal) {
    const options = this.options;
    if (kind === 'stdout' || kind === 'stderr') return options[kind]?.(args.text);
    if (kind === 'input') {
      if (typeof options.input !== 'function') throw new Error('input callback is not configured');
      return options.input(args.prompt);
    }
    if (kind === 'allowUrl') return options.allowUrl?.(args.url) ?? true;
    if (kind === 'wallClock') return (options.wallClock ?? (() => Date.now() / 1000))();
    if (kind === 'monotonicClock') return (options.monotonicClock ?? (() => performance.now() / 1000))();
    if (kind === 'sleep') return (options.sleep ?? defaultSleep)(args.seconds, signal);
    if (kind === 'fetch') {
      const fetcher = options.fetch ?? globalThis.fetch;
      if (typeof fetcher !== 'function') throw new Error('fetch is unavailable');
      const response = await fetcher(args.url, {
        ...args.init,
        headers: new Headers(args.init.headers),
        body: args.init.body?.length ? args.init.body : undefined,
        signal,
      });
      if (!(response instanceof Response)) throw new Error('fetch did not return a Response');
      const body = await readBody(response, options.maxHttpResponseBytes ?? MAX_HTTP_BYTES - 16 * 1024, signal);
      return { status: response.status, statusText: response.statusText, headers: [...response.headers], body };
    }
    throw new Error(`unknown Peony host service ${kind}`);
  }
}

function checkedPath(path) {
  if (typeof path !== 'string') throw new TypeError('VFS path must be a string');
}

function copyBytes(value) {
  if (typeof value === 'string') return new TextEncoder().encode(value);
  if (value instanceof ArrayBuffer) return new Uint8Array(value.slice(0));
  if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength));
  throw new TypeError('VFS file contents must be a string or byte buffer');
}

function validateOptions(options) {
  if (!options || typeof options !== 'object' || Array.isArray(options)) throw new TypeError('Peony session options must be an object');
  for (const key of ['quantum', 'maxMemoryBytes', 'maxVfsBytes', 'maxFileBytes']) {
    const value = options[key];
    if (value !== undefined && (!Number.isSafeInteger(value) || value <= 0 || value > 0xffff_ffff)) throw new RangeError(`${key} must be a positive u32 integer`);
  }
  if (options.maxFileBytes !== undefined && options.maxFileBytes > (options.maxVfsBytes ?? 8 * 1024 * 1024)) throw new RangeError('maxFileBytes cannot exceed maxVfsBytes');
  if (options.maxInstructions !== undefined) {
    const value = options.maxInstructions;
    if ((typeof value !== 'number' && typeof value !== 'bigint') || (typeof value === 'number' && !Number.isSafeInteger(value))) throw new RangeError('maxInstructions must be an exact positive u64 integer');
    const integer = BigInt(value);
    if (integer <= 0n || integer > 0xffff_ffff_ffff_ffffn) throw new RangeError('maxInstructions must be a positive u64 integer');
  }
  if (options.maxHttpResponseBytes !== undefined && (!Number.isSafeInteger(options.maxHttpResponseBytes) || options.maxHttpResponseBytes < 0 || options.maxHttpResponseBytes > MAX_HTTP_BYTES)) throw new RangeError('maxHttpResponseBytes must be between 0 and 1 MiB');
  return Object.fromEntries(['quantum', 'maxMemoryBytes', 'maxInstructions', 'maxVfsBytes', 'maxFileBytes', 'seed', 'maxHttpResponseBytes', 'followRedirects'].filter(key => options[key] !== undefined).map(key => [key, key === 'seed' && typeof options[key] !== 'string' ? copyBytes(options[key]) : options[key]]));
}

async function readBody(response, limit, signal) {
  if (!response.body) return new Uint8Array();
  const reader = response.body.getReader();
  const chunks = [];
  let total = 0;
  try {
    while (true) {
      if (signal.aborted) throw new Error('request aborted');
      const { done, value } = await reader.read();
      if (done) break;
      total += value.length;
      if (total > limit) { await reader.cancel(); throw new Error('HTTP response exceeds maxHttpResponseBytes'); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const result = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.length; }
  return result;
}

function defaultSleep(seconds, signal) {
  return new Promise((resolve, reject) => {
    if (signal.aborted) { reject(new Error('sleep aborted')); return; }
    const timer = setTimeout(() => { signal.removeEventListener('abort', abort); resolve(); }, Math.min(seconds * 1000, 0x7fff_ffff));
    const abort = () => { clearTimeout(timer); reject(new Error('sleep aborted')); };
    signal.addEventListener('abort', abort, { once: true });
  });
}
