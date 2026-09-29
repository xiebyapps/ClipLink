const { cacheFixture, createDisk } = require('./cache-harness.cjs');
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(path.join(process.env.DEVECO_SDK_HOME,
  'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets');

function load(relative, mocks) {
  const source = fs.readFileSync(path.join(root, relative), 'utf8').replace(/^import .*;\r?\n/gm, '');
  const compiled = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS },
  }).outputText;
  const sandbox = { exports: {}, console, Error, ...mocks };
  vm.runInNewContext(compiled, sandbox, { filename: relative });
  return sandbox.exports;
}

function harness({ supported = true, download, capability = true, openError, decodeError } = {}) {
  const files = new Map();
  const timers = new Map();
  const calls = [];
  const config = { activeServerId: 'A', server: { url: 'https://a.invalid' } };
  let displayed = false;
  let sequence = 0;
  let mapReleased = 0;
  const disk = createDisk(files);
  config.servers = [{ id: 'A', url: config.server.url }, { id: 'B', url: 'https://b.invalid' }];
  config.cacheCapacityGB = 2;
  const persistent = cacheFixture({ disk, config });
  const { DownloadCancellation } = load('services/HttpClient.ets', {});
  class SyncClipboardService {
    constructor(url) { this.url = url; }
    async downloadHistoryFileToPath(id, target, progress, cancellation) {
      calls.push(['download', this.url, id]);
      if (download) return download({ target, progress, cancellation, files });
      files.set(target, 'original'); disk.sizes.set(target, 8);
      progress(8, 8);
      return { path: target, size: 8, prefix: new ArrayBuffer(0), fileName: 'photo.png', contentType: 'image/png' };
    }
  }
  const mocks = {
    fs: disk, fileUri: { getUriFromPath: p => `file://${p}` },
    filePreview: {
      canPreview: async (_, uri) => { calls.push(['canPreview', uri]); return supported; },
      openPreview: async (_, info) => {
        calls.push(['open', info]); if (openError) throw new Error(openError); displayed = true;
      },
      hasDisplayed: async () => displayed,
    },
    ConfigService: { getInstance: () => ({ getConfig: () => config }) },
    AppStorage: { get: () => ({ cacheDir: '/cache' }) },
    canIUse: () => capability, SyncClipboardService, DownloadCancellation,
    RecordCacheService: persistent.RecordCacheService,
    DownloadNoticeService: { begin: () => 1, progress() {}, status() {}, finish: (...args) => calls.push(['noticeFinished', ...args]) },
    UserFileSaveUtil: {
      savedMessage: saved => `Saved to Download/package/${saved.category}`,
      fileName: (s, fallback) => s && /\.[a-z]+$/.test(s) ? path.basename(s) : fallback,
      isLikelyImage: (type, name) => type === 'Image' || /\.png$/.test(name || ''),
      suggestedFileName: (r, n, _, fallback) => r.fileName || n || fallback,
      category: (type, name, mime) => type === 'Group' ? 'Other' :
        type === 'Image' || mime?.startsWith('image/') ? 'Image' : 'Other',
      removeTemporaryDownload: p => { calls.push(['remove', p]); files.delete(p); },
      saveToGallery: async r => { assert.ok(files.has(r.path)); calls.push(['gallery', r.path]); },
      saveAs: async r => { assert.ok(files.has(r.path)); calls.push(['saveAs', r.path]); return 'public://file'; },
      saveAutomatically: async r => { assert.ok(files.has(r.path)); calls.push(['save', r.path]); return { category: 'Other' }; },
    },
    ImageUtil: {
      guessImageExtension: () => '.png',
      createPixelMapFromPath: async p => {
        assert.ok(files.has(p));
        if (decodeError) throw new Error(decodeError);
        return { release: async () => { mapReleased++; } };
      },
    },
    ClipboardUtil: {
      setClipboardText: async text => calls.push(['copyText', text]),
      setClipboardImage: async () => calls.push(['copyImage']),
    },
    setTimeout: fn => { timers.set(++sequence, fn); return sequence; },
    clearTimeout: id => timers.delete(id),
  };
  const { RecordPreviewSession } = load('services/RecordPreviewSession.ets', mocks);
  return { RecordPreviewSession, config, files, calls, timers, disk, cache: persistent.cache, clock: persistent.clock,
    payloads: persistent.payloads,
    stopSystem: () => { displayed = false; }, released: () => mapReleased,
    async tick() { const pending = [...timers.values()]; timers.clear(); pending.forEach(fn => fn());
      await new Promise(resolve => setImmediate(resolve)); } };
}

test('opening only previews; explicit copy and both saves reuse one streamed file', async () => {
  const h = harness();
  const record = { type: 'Image', hash: 'ABC', hasData: true, text: 'photo.png' };
  const session = new h.RecordPreviewSession(record);
  await session.prepare();
  assert.equal(h.calls.filter(c => c[0] === 'download').length, 1);
  assert.equal(h.calls.filter(c => c[0].startsWith('copy')).length, 0);
  assert.equal(h.calls.filter(c => c[0] === 'gallery').length, 0);
  assert.match(h.calls.find(c => c[0] === 'open')[1].uri, /photo\.png$/);
  assert.equal(h.RecordPreviewSession.cached(record), session);
  await session.copy();
  assert.equal(h.released(), 1);
  assert.equal(await session.save(false), 'Tap Save to Gallery');
  await session.save(false, true);
  await session.save(true);
  assert.equal(h.calls.filter(c => c[0] === 'download').length, 1);
  session.close();
  h.cache.removeRecords('A', ['Image-ABC']);
  assert.ok([...h.files.keys()].some(p => p.endsWith('photo.png')), 'system reader owns its file until closed');
  h.stopSystem();
  await h.tick();
  assert.equal(h.payloads().length, 0);
  assert.equal(h.timers.size, 0);
});

test('text previews in the app even without Preview Kit and copies only on explicit action', async () => {
  const h = harness({ capability: false });
  const session = new h.RecordPreviewSession({ type: 'Text', hash: 'ABC', text: '中文\nhello' });
  await session.prepare();
  assert.equal(session.state.fullText, '中文\nhello');
  assert.equal(h.calls.filter(c => c[0] === 'open' || c[0] === 'canPreview').length, 0);
  await session.openPreview();
  assert.equal(h.calls.filter(c => c[0] === 'open').length, 0);
  assert.equal(h.calls.filter(c => c[0] === 'download').length, 0);
  assert.equal(h.calls.filter(c => c[0] === 'copyText').length, 0);
  await session.copy();
  assert.equal(h.calls.find(c => c[0] === 'copyText')[1], '中文\nhello');
  h.stopSystem(); await h.tick(); session.close();
  assert.equal(h.payloads().length, 1);
});

test('server-backed text shows the entire payload rather than the record excerpt', async () => {
  const fullText = Array.from({ length: 100 }, (_, index) => `第 ${index + 1} 行：完整文本内容`).join('\n');
  const h = harness({ download: async ({ target, files }) => {
    files.set(target, fullText);
    return { path: target, size: Buffer.byteLength(fullText), prefix: new ArrayBuffer(0), contentType: 'text/plain' };
  } });
  const session = new h.RecordPreviewSession({ type: 'Text', hash: 'ABC', text: '摘要', hasData: true });
  await session.prepare();
  assert.equal(session.state.fullText, fullText);
  assert.equal(h.calls.filter(c => c[0] === 'open').length, 0);
  await session.copy();
  assert.equal(h.calls.find(c => c[0] === 'copyText')[1], fullText);
  session.close(); assert.equal(h.payloads().length, 1);
});

test('TXT files continue opening system preview and keep file saving behavior', async () => {
  const h = harness({ download: async ({ target, files }) => {
    files.set(target, 'TXT file');
    return { path: target, size: 8, prefix: new ArrayBuffer(0), fileName: 'note.txt', contentType: 'text/plain' };
  } });
  const session = new h.RecordPreviewSession({ type: 'File', hash: 'ABC', text: 'note.txt', hasData: true });
  await session.prepare();
  assert.equal(h.calls.filter(c => c[0] === 'open').length, 1);
  assert.equal(session.state.fullText, '');
  await session.save(false);
  assert.equal(h.calls.filter(c => c[0] === 'save').length, 1);
  h.stopSystem(); await h.tick(); session.close();
});

test('unsupported archive and unavailable system capability keep public saving usable', async () => {
  for (const capability of [true, false]) {
    const h = harness({ supported: false, capability });
    const session = new h.RecordPreviewSession({ type: 'Group', hash: 'ABC', hasData: true });
    await session.prepare();
    assert.equal(session.state.supported, false);
    assert.equal(session.state.ready, true);
    assert.equal(h.calls.filter(c => c[0] === 'open').length, 0);
    await assert.rejects(session.copy(), /not supported/);
    await session.save(false);
    assert.equal(h.calls.filter(c => c[0] === 'save').length, 1);
    session.close(); assert.equal(h.payloads().length, 1);
  }
});

test('closing cancels a pending stream and suppresses late UI updates', async () => {
  let cancelToken;
  const h = harness({ download: ({ target, cancellation, files }) => new Promise((_, reject) => {
    files.set(target, 'partial'); cancelToken = cancellation;
    cancellation.subscribe(() => reject(new Error('Download canceled')));
  }) });
  const session = new h.RecordPreviewSession({ type: 'File', hash: 'ABC', hasData: true });
  let updates = 0;
  session.onChange = () => updates++;
  const pending = session.prepare();
  while (!cancelToken) await new Promise(resolve => setImmediate(resolve));
  session.close();
  const before = updates;
  await pending;
  assert.equal(cancelToken.canceled, true);
  assert.equal(updates, before);
  assert.equal(h.calls.filter(c => c[0] === 'open').length, 0);
  assert.equal(h.payloads().length, 0);
});

test('account change during download cannot open preview or copy the old server file', async () => {
  let finish;
  const h = harness({ download: ({ target, files }) => new Promise(resolve => {
    files.set(target, 'old'); finish = () => resolve({ path: target, size: 3, prefix: new ArrayBuffer(0) });
  }) });
  const session = new h.RecordPreviewSession({ type: 'File', hash: 'ABC', hasData: true });
  const pending = session.prepare();
  while (!finish) await new Promise(resolve => setImmediate(resolve));
  h.config.activeServerId = 'B';
  finish(); await pending;
  assert.equal(h.calls.filter(c => c[0] === 'open').length, 0);
  assert.equal(h.RecordPreviewSession.cached(session.record), undefined);
  await assert.rejects(session.copy(), /Server changed/);
  session.close(); assert.equal(h.payloads().length, 1);
});

test('network failure can retry and successful retry opens preview', async () => {
  let attempts = 0;
  const h = harness({ download: async ({ target, files }) => {
    files.set(target, 'data');
    if (++attempts === 1) throw new Error('REQUEST_2300023');
    return { path: target, size: 4, prefix: new ArrayBuffer(0), fileName: 'test.pdf' };
  } });
  const session = new h.RecordPreviewSession({ type: 'File', hash: 'ABC', hasData: true });
  await session.prepare();
  assert.equal(session.state.ready, false);
  assert.match(session.state.error, /2300023/);
  await session.prepare();
  assert.equal(session.state.ready, true);
  assert.equal(h.calls.filter(c => c[0] === 'open').length, 1);
  h.stopSystem(); await h.tick(); session.close();
});

test('system preview or image decode errors never remove a file needed for saving', async () => {
  for (const failure of [{ openError: 'permission denied' }, { decodeError: 'out of memory' }]) {
    const h = harness(failure);
    const session = new h.RecordPreviewSession({ type: 'Image', hash: 'ABC', hasData: true });
    await session.prepare();
    assert.equal(session.state.ready, true);
    if (failure.decodeError) await assert.rejects(session.copy(), /out of memory/);
    else assert.equal(session.state.error, 'permission denied');
    await session.save(false, true);
    assert.equal(h.calls.filter(c => c[0] === 'gallery').length, 1);
    h.stopSystem(); await h.tick(); session.close();
    assert.equal(h.payloads().length, 1);
  }
});

test('generic binary MIME lets system infer the original extension; large files remain streamed', async () => {
  const h = harness({ download: async ({ target, progress, files }) => {
    files.set(target, 'streamed'); h.disk.sizes.set(target, 104857600); progress(104857600, 104857600);
    return { path: target, size: 104857600, prefix: new ArrayBuffer(16),
      fileName: 'download.part', contentType: 'application/octet-stream' };
  } });
  const session = new h.RecordPreviewSession({ type: 'File', hash: 'ABC', hasData: true });
  await session.prepare();
  assert.equal(session.state.received, 104857600);
  assert.equal(h.calls.find(c => c[0] === 'open')[1].mimeType, '');
  assert.ok([...h.files.keys()].some(p => p.endsWith('/payload/download.part')));
  await session.save(false);
  h.stopSystem(); await h.tick(); session.close(); assert.equal(h.payloads().length, 1);
});

test('HTTP stream cancellation destroys the request, closes descriptor once, and ignores late chunks', async () => {
  let destroyed = 0; let closed = 0; let writes = 0;
  const listeners = {};
  const http = { RequestMethod: { GET: 'GET' }, createHttp: () => ({
    on: (event, fn) => { listeners[event] = fn; },
    requestInStream: () => new Promise(() => {}), destroy: () => destroyed++,
  }) };
  const { HttpClient, DownloadCancellation } = load('services/HttpClient.ets', {
    http, fs: { OpenMode: { CREATE: 1, READ_WRITE: 2 }, openSync: () => ({ fd: 1 }),
      closeSync: () => closed++, writeSync: () => { writes++; return 1; } },
  });
  const cancellation = new DownloadCancellation();
  const pending = new HttpClient('https://example.invalid').getBinaryToFile('/data', '/tmp', undefined, cancellation);
  cancellation.cancel(); cancellation.cancel();
  await assert.rejects(pending, /Download canceled/);
  listeners.dataReceive(new ArrayBuffer(10)); listeners.dataEnd();
  assert.equal(destroyed, 1); assert.equal(closed, 1); assert.equal(writes, 0);
});

test('expired large preview waits for native close, then removes the file and re-downloads on next action', async () => {
  const h = harness({ download: async ({ target, files }) => {
    files.set(target, 'large'); h.disk.sizes.set(target, 501 * 1024 * 1024);
    return { path: target, size: 501 * 1024 * 1024, prefix: new ArrayBuffer(0), fileName: 'large.pdf' };
  } });
  const item = { type: 'File', hash: 'LARGE', hasData: true, lastAccessed: new Date().toISOString() };
  const session = new h.RecordPreviewSession(item); await session.prepare();
  const old = h.payloads()[0];
  h.clock.now += 2 * 60 * 60 * 1000; h.cache.enforceLimits();
  assert.equal(h.files.has(old), true, 'native window is still reading');
  assert.equal(h.RecordPreviewSession.cached(item), undefined);
  h.stopSystem(); await h.tick();
  assert.equal(h.files.has(old), false, 'closing native preview releases the expired payload while the panel stays');
  await session.openPreview();
  assert.equal(h.calls.filter(c => c[0] === 'download').length, 2);
  assert.notEqual(h.payloads()[0], old);
  await session.save(false); assert.equal(h.calls.filter(c => c[0] === 'download').length, 2);
  h.stopSystem(); await h.tick(); session.close();
});

test('failed re-download after expiry finishes the resident progress notice', async () => {
  let count = 0;
  const h = harness({ download: async ({ target, files, progress }) => {
    if (++count === 2) { progress(1, 500); throw new Error('network failed'); }
    files.set(target, 'large'); h.disk.sizes.set(target, 501 * 1024 * 1024);
    return { path: target, size: 501 * 1024 * 1024, prefix: new ArrayBuffer(0), fileName: 'large.pdf' };
  } });
  const session = new h.RecordPreviewSession({ type: 'File', hash: 'FAIL', hasData: true });
  await session.prepare(); h.clock.now += 2 * 60 * 60 * 1000; h.cache.enforceLimits();
  h.stopSystem(); await h.tick(); await session.openPreview();
  assert.equal(session.state.error, 'network failed');
  assert.ok(h.calls.some(c => c[0] === 'noticeFinished' && c[2] === 'Download failed'));
  session.close();
});


test('manual sync sheet prepares a file once and only opens system preview on explicit action', async () => {
  const h = harness();
  const session = new h.RecordPreviewSession({ type: 'Image', hash: 'MANUAL', hasData: true, text: 'photo.png' }, false);
  await session.prepare();
  assert.equal(session.state.ready, true); assert.equal(session.state.supported, true);
  assert.equal(h.calls.filter(c => c[0] === 'open').length, 0);
  assert.equal(h.calls.filter(c => c[0].startsWith('copy')).length, 0);
  await session.openPreview();
  assert.equal(h.calls.filter(c => c[0] === 'open').length, 1);
  assert.equal(h.calls.filter(c => c[0] === 'download').length, 1);
  session.close(); h.stopSystem(); await h.tick();
});
