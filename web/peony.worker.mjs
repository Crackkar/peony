import { Peony } from './peony-core.mjs';

const VERSION = 1;
const sessions = new Map();
const hostCalls = new Map();
let nextHostCall = 1;
let module = null;
let send;

if (typeof self !== 'undefined' && typeof self.postMessage === 'function') {
  send = message => self.postMessage(message);
  self.addEventListener('message', event => { void receive(event.data); });
} else {
  const { parentPort } = await import('node:worker_threads');
  if (!parentPort) throw new Error('Peony engine must run in a Worker');
  send = message => parentPort.postMessage(message);
  parentPort.on('message', message => { void receive(message); });
}

async function receive(message) {
  if (!message || message.v !== VERSION || !Number.isSafeInteger(message.id) || !Number.isSafeInteger(message.session) || !Number.isSafeInteger(message.run)) return;
  if (message.type === 'hostResult') {
    const call = hostCalls.get(message.id);
    if (!call || call.session !== message.session || call.run !== message.run) return;
    hostCalls.delete(message.id);
    if (message.ok) call.resolve(message.value);
    else call.reject(new Error(message.error || 'Peony host service failed'));
    return;
  }
  if (message.type !== 'request') return;
  try {
    const value = await dispatch(message);
    send({ v: VERSION, type: 'response', id: message.id, session: message.session, run: message.run, ok: true, value });
  } catch (error) {
    send({ v: VERSION, type: 'response', id: message.id, session: message.session, run: message.run, ok: false,
      error: { name: error instanceof Error ? error.name : 'Error', message: error instanceof Error ? error.message : String(error) } });
  }
}

async function dispatch({ session: id, run, op, args }) {
  if (op === 'load') {
    if (module) throw new Error('Peony WASM is already loaded');
    const source = args.source;
    if (source.url?.startsWith('file:') && typeof process !== 'undefined') {
      const { readFile } = await import('node:fs/promises');
      module = await Peony.load(new Uint8Array(await readFile(new URL(source.url))));
    } else {
      module = await Peony.load(source.url ?? source.bytes);
    }
    return true;
  }
  if (!module) throw new Error('Peony WASM has not loaded');
  if (op === 'create') {
    if (sessions.has(id)) throw new Error('duplicate Peony session ID');
    const record = { id, run: 0, runTask: null, session: null };
    record.session = module.createSession({
      ...args.options,
      stdout: text => host(record, 'stdout', { text }),
      stderr: text => host(record, 'stderr', { text }),
      input: prompt => host(record, 'input', { prompt }),
      fetch: async (url, init) => {
        const response = await host(record, 'fetch', {
          url,
          init: {
            method: init.method,
            headers: [...init.headers],
            body: init.body ? new Uint8Array(init.body) : null,
            credentials: init.credentials,
            redirect: init.redirect,
          },
        }, init.signal);
        return new Response(response.body.length ? response.body : null, {
          status: response.status,
          statusText: response.statusText,
          headers: response.headers,
        });
      },
      allowUrl: url => host(record, 'allowUrl', { url }),
      wallClock: () => host(record, 'wallClock', {}),
      monotonicClock: () => host(record, 'monotonicClock', {}),
      sleep: (seconds, signal) => host(record, 'sleep', { seconds }, signal),
    });
    sessions.set(id, record);
    return true;
  }
  const record = sessions.get(id);
  if (!record) throw new Error('unknown Peony session ID');
  if (op === 'run') {
    if (record.runTask) throw new Error('Peony session is already running');
    record.run = run;
    const task = record.session.run(args.source, args.options);
    record.runTask = task;
    try { return await task; }
    finally {
      record.runTask = null;
      clearHostCalls(id, run);
    }
  }
  if (op === 'cancel') {
    if (run !== record.run) return false;
    record.session.cancel();
    return true;
  }
  if (op === 'reset') return record.session.reset();
  if (record.runTask) await record.runTask.catch(() => {});
  switch (op) {
    case 'mount': return record.session.mount(args.files, args.options);
    case 'readFile': return record.session.readFile(args.path);
    case 'writeFile': return record.session.writeFile(args.path, args.content);
    case 'listFiles': return record.session.listFiles(args.path);
    case 'listDirectories': return record.session.listDirectories(args.path);
    case 'vfsMkdir': return record.session.vfsMkdir(args.path);
    case 'stats': return record.session.stats();
    case 'collectGarbage': return record.session.collectGarbage();
    case 'destroy': {
      const value = record.session.destroy();
      sessions.delete(id);
      return value;
    }
    default: throw new Error(`unknown Peony Worker operation ${op}`);
  }
}

function host(record, kind, args, signal) {
  const id = nextHostCall++;
  const run = record.run;
  return new Promise((resolve, reject) => {
    const clear = () => signal?.removeEventListener('abort', abort);
    const abort = () => {
      hostCalls.delete(id);
      send({ v: VERSION, type: 'hostAbort', id, session: record.id, run });
      reject(new Error('host request aborted'));
    };
    if (signal?.aborted) { reject(new Error('host request aborted')); return; }
    signal?.addEventListener('abort', abort, { once: true });
    hostCalls.set(id, {
      resolve: value => { clear(); resolve(value); },
      reject: error => { clear(); reject(error); },
      session: record.id, run,
    });
    send({ v: VERSION, type: 'host', id, session: record.id, run, kind, args });
  });
}

function clearHostCalls(session, run) {
  for (const [id, call] of hostCalls) {
    if (call.session !== session || call.run !== run) continue;
    hostCalls.delete(id);
    call.reject(new Error('Peony run was cancelled'));
  }
}
