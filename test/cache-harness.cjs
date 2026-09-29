const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const ts = require(path.join(process.env.DEVECO_SDK_HOME,
  'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets');
function load(file, mocks = {}) {
  const source = fs.readFileSync(path.join(root, file), 'utf8').replace(/^import .*;\r?\n/gm, '');
  const output = ts.transpileModule(source, { compilerOptions: {
    target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS,
  } }).outputText;
  const sandbox = { exports: {}, Error, console: { info() {}, error() {} }, ...mocks };
  vm.runInNewContext(output, sandbox, { filename: file });
  return sandbox.exports;
}
function createDisk(files = new Map(), sizes = new Map()) {
  files.set('/files', null);
  const disk = {
    files, sizes,
    OpenMode: { CREATE: 1, READ_WRITE: 2, TRUNC: 4, READ_ONLY: 8 },
    accessSync: p => files.has(p), mkdirSync: p => files.set(p, null),
    openSync(p, mode) { if ((mode & 1) && !files.has(p) || (mode & 4)) files.set(p, '');
      if (!files.has(p)) throw new Error('ENOENT'); return { fd: p }; },
    writeSync(p, data) { files.set(p, String(data)); return Buffer.byteLength(String(data)); }, closeSync() {},
    statSync(p) { if (!files.has(p)) throw new Error('ENOENT'); return {
      size: sizes.get(p) ?? Buffer.byteLength(files.get(p) || ''), isDirectory: () => files.get(p) === null,
    }; },
    readTextSync(p) { if (!files.has(p)) throw new Error('ENOENT'); return files.get(p); },
    readSync(p, dst) { const data = Buffer.from(files.get(p) || ''); const count = Math.min(dst.byteLength, data.length);
      new Uint8Array(dst).set(data.subarray(0, count)); return count; },
    renameSync(a, b) { if (!files.has(a)) throw new Error('ENOENT'); files.set(b, files.get(a)); files.delete(a);
      if (sizes.has(a)) { sizes.set(b, sizes.get(a)); sizes.delete(a); } },
    unlinkSync(p) { files.delete(p); sizes.delete(p); },
    rmdirSync(p) { if ([...files.keys()].some(k => k.startsWith(p + '/'))) throw new Error('ENOTEMPTY'); files.delete(p); },
    listFileSync(p) { return [...new Set([...files.keys()].filter(k => k.startsWith(p + '/'))
      .map(k => k.slice(p.length + 1).split('/')[0]))]; },
  };
  return disk;
}
function cacheFixture(options = {}) {
  const disk = options.disk || createDisk();
  const config = options.config || { activeServerId: 'A', server: { id: 'A', url: 'a' },
    servers: [{ id: 'A', url: 'a' }, { id: 'B', url: 'b' }], maxHistorySize: 100, cacheCapacityGB: 2 };
  const runtime = options.runtime || new Map();
  const AppStorage = { get: key => key === 'abilityContext' ? { filesDir: '/files', cacheDir: '/cache' } : runtime.get(key),
    setOrCreate: (key, value) => runtime.set(key, value) };
  const clock = options.clock || { now: Date.now() };
  const timers = new Map(); let timerId = 0;
  const HashUtil = { calculateTextHash: async text => crypto.createHash('sha256').update(text).digest('hex').toUpperCase() };
  const { DownloadCancellation } = load('services/HttpClient.ets');
  const saves = {
    suggestedFileName: (response, name, _, fallback) => response.fileName || (name && !name.includes('\n') ? path.basename(name) : fallback),
  };
  const mocks = {
    fs: disk, AppStorage, HashUtil, DownloadCancellation,
    Date: class extends Date { static now() { return clock.now; } },
    ConfigService: { getInstance: () => ({ getConfig: () => config }) },
    UserFileSaveUtil: saves, ImageUtil: { guessImageExtension: () => '.png' },
    SyncClipboardService: class {},
    setInterval: fn => { timers.set(++timerId, fn); return timerId; }, clearInterval: id => timers.delete(id),
  };
  const { RecordCacheService } = load('services/RecordCacheService.ets', mocks);
  const cache = RecordCacheService.getInstance();
  const calls = [];
  const service = {
    async getHistoryRecord(id) { calls.push(['metadata', id]); return { type: 'Text', hash: id.slice(5), text: 'complete正文' }; },
    async downloadHistoryFileToPath(id, target, progress, cancellation) {
      calls.push(['download', id]);
      if (options.download) return options.download({ id, target, progress, cancellation, disk, calls });
      disk.files.set(target, 'payload');
      disk.sizes.set(target, options.size ?? 7);
      progress?.(options.size ?? 7, options.size ?? 7);
      return { path: target, size: options.size ?? 7, prefix: new ArrayBuffer(0), fileName: 'test.pdf', contentType: 'application/pdf' };
    },
  };
  return { cache, RecordCacheService, DownloadCancellation, disk, config, runtime, AppStorage, clock, calls, service, timers, mocks,
    payloads: () => [...disk.files.keys()].filter(p => /\/payload\/[^/]+$/.test(p)),
    restore() { return cacheFixture({ disk, config, runtime, clock }); } };
}
function record(hash, type = 'File', time = 0) {
  return { type, hash, text: type === 'Text' ? 'full正文' : 'test.pdf', hasData: type !== 'Text',
    lastAccessed: new Date(time).toISOString() };
}
module.exports = { load, createDisk, cacheFixture, record };
