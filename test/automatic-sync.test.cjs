const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const ts = require(path.join(process.env.DEVECO_SDK_HOME,
  'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets');
function load(file, mocks = {}) {
  const source = fs.readFileSync(path.join(root, file), 'utf8').replace(/^import .*;\r?\n/gm, '');
  const compiled = ts.transpileModule(source, { compilerOptions: {
    target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS,
  } }).outputText;
  const sandbox = { exports: {}, console: { info() {}, error() {} }, Error, ...mocks };
  vm.runInNewContext(compiled, sandbox, { filename: file });
  return sandbox.exports;
}
const hash = text => crypto.createHash('sha256').update(text).digest('hex').toUpperCase();
const { SyncDecision } = load('services/SyncDecision.ets');

test('freshness arbitration rejects equal/missing/overlapping times, permits one-sided changes', () => {
  const base = { equal: false, hasBaseline: false, localChanged: true, remoteChanged: true,
    localTime: 2000, remoteTime: 1000, uncertainty: 100, clockStable: true };
  assert.equal(SyncDecision.decide(base), 'local');
  assert.equal(SyncDecision.decide({ ...base, localTime: 500 }), 'remote');
  for (const change of [{ localTime: NaN }, { remoteTime: NaN }, { uncertainty: Infinity },
    { localTime: 1000 }, { localTime: 1100 }, { clockStable: false }]) {
    assert.equal(SyncDecision.decide({ ...base, ...change }), 'pause');
  }
  assert.equal(SyncDecision.decide({ ...base, equal: true, localTime: NaN }), 'none');
  assert.equal(SyncDecision.decide({ ...base, hasBaseline: true, localChanged: false }), 'remote');
  assert.equal(SyncDecision.decide({ ...base, hasBaseline: true, remoteChanged: false }), 'local');
  assert.equal(SyncDecision.decide({ ...base, hasBaseline: true,
    localChanged: false, remoteChanged: false }), 'none');
});

function fixture(options = {}) {
  const storage = new Map([['isPollingEnabled', true], ['appForeground', true], ['abilityContext', {}]]);
  const AppStorage = { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value),
    delete: key => storage.delete(key) };
  let account = { id: 'A', url: 'server-A' };
  const now = Date.now();
  let local = { kind: 'Text', text: 'same', fingerprint: `Text-${hash('same')}`,
    changeCount: 1, time: now - 1000, bootEpoch: 12345, imagePath: '' };
  let remote = { type: 'Text', text: 'same', hash: hash('same'), hasData: false,
    lastAccessed: new Date(now - 1000).toISOString() };
  const calls = { uploads: [], writes: [], files: [], releases: 0, removed: [], probes: 0, stopped: 0,
    notices: [], persisted: [], clockReads: 0 };
  let captureError;
  let readError;
  let beforeGuard;
  let duringDownload;
  const config = {
    getActiveServer: () => account,
    async setSyncPaused(reason) { calls.persisted.push(reason); storage.set('syncPausedReason', reason); },
  };
  const ClipboardSnapshotUtil = {
    async capture() { if (captureError) throw new Error(captureError); return { ...local }; },
    changeCount: () => local.changeCount,
    bootEpoch: () => options.clockJump ? 99999 : local.bootEpoch,
    tempPath: () => '/cache/temp-' + Math.random(),
    async remove(p) { if (p) calls.removed.push(p); },
    async packImage(pixelMap) { return pixelMap.contentHash; },
  };
  const ClipboardUtil = {
    resetReadPermission() {},
    async setClipboardText(text) {
      calls.writes.push(text);
      local = { ...local, kind: 'Text', text, fingerprint: `Text-${hash(text)}`,
        changeCount: local.changeCount + 1, time: Date.now() };
    },
    async setClipboardImage(map) {
      calls.writes.push('image:' + map.contentHash);
      local = { ...local, kind: 'Image', fingerprint: 'Image-' + map.contentHash,
        imagePath: '/cache/local.png', changeCount: local.changeCount + 1, time: Date.now() };
    },
  };
  function currentRecord() {
    return { type: remote.type, hash: remote.hash, text: remote.text, hasData: remote.hasData,
      lastAccessed: remote.lastAccessed, isDeleted: false };
  }
  class SyncClipboardService {
    async getProfile() { if (readError) throw new Error(readError); return { ...remote }; }
    async getHistoryRecord() { return currentRecord(); }
    async getServerTime() {
      calls.clockReads++;
      if (options.noClock) throw new Error('HTTP 404');
      return new Date(Date.now() + (options.serverOffset || 0)).toISOString();
    }
    async uploadTextContentExclusive(text, guard) {
      if (beforeGuard) { const fn = beforeGuard; beforeGuard = undefined; fn(); }
      await guard();
      calls.uploads.push(text);
      remote = { type: 'Text', text, hash: hash(text), hasData: false,
        lastAccessed: new Date().toISOString() };
    }
    async downloadTextFromProfile(profile) { return profile.text; }
    async downloadHistoryFileToPath(id, path, progress, cancellation) {
      calls.files.push(id); progress(100, 100);
      if (duringDownload) await duringDownload(cancellation);
      if (cancellation.canceled) throw new Error('Download canceled');
      if (options.downloadError) throw new Error('Network failed');
    }
  }
  class FileUploadTask {
    cancel() { this.canceled = true; }
    async uploadExclusive(files, server, context, progress, guard) {
      if (beforeGuard) { const fn = beforeGuard; beforeGuard = undefined; fn(); }
      await guard();
      calls.uploads.push(files[0].name);
      const imageHash = local.fingerprint.slice(6);
      remote = { type: 'Image', text: files[0].name, dataName: files[0].name,
        hash: hash(`${files[0].name}|${imageHash}`), pixelHash: imageHash, hasData: true,
        lastAccessed: new Date().toISOString() };
    }
  }
  const { SyncOperationQueue } = load('services/SyncOperationQueue.ets');
  const { SyncCoordinator } = load('services/SyncCoordinator.ets', {
    AppStorage, ClipboardSnapshotUtil, ClipboardUtil, SyncDecision, SyncOperationQueue,
    fs: { readTextSync: () => remote.text },
    RecordCacheService: { getInstance: () => ({ async acquire(record, account, service, progress, cancellation) {
      if (record.type === 'Image') {
        await service.downloadHistoryFileToPath(`Image-${record.hash}`, '/persistent/image', progress, cancellation);
      }
      return { response: { path: '/persistent/payload', size: 100 }, release() {} };
    } }) },
    ConfigService: { getInstance: () => config }, SyncClipboardService, FileUploadTask,
    HashUtil: { calculateTextHash: async text => hash(text) },
    HistoryStorageService: { getInstance: () => ({ async upsertRecord() {} }) },
    ServerManager: { getInstance: () => ({ async ensureAvailable() { calls.probes++; } }) },
    PollingController: { stopAll() { calls.stopped++; } },
    DownloadCancellation: class { cancel() { this.canceled = true; } },
    DownloadNoticeService: { begin: () => 1, progress() {}, finish: (...args) => calls.notices.push(args) },
    ImageUtil: { async createPixelMapFromPath() {
      if (options.decodeError) throw new Error('Decode failed');
      return { contentHash: remote.pixelHash, async release() { calls.releases++; } };
    } },
  });
  const coordinator = SyncCoordinator.getInstance();
  return { coordinator, calls, storage, now,
    local: changes => { local = { ...local, ...changes, changeCount: local.changeCount + 1 }; },
    localText: (text, time = Date.now()) => {
      local = { ...local, kind: 'Text', text, fingerprint: `Text-${hash(text)}`,
        changeCount: local.changeCount + 1, time };
    },
    remote: changes => { remote = { ...remote, ...changes }; },
    remoteText: (text, time = Date.now()) => {
      remote = { type: 'Text', text, hash: hash(text), hasData: false, lastAccessed: new Date(time).toISOString() };
    },
    account: id => { account = { id, url: 'server-' + id }; coordinator.invalidate(true); },
    failCapture: value => { captureError = value; }, failRead: value => { readError = value; },
    beforeGuard: fn => { beforeGuard = fn; }, duringDownload: fn => { duringDownload = fn; },
  };
}

test('local text uploads, unchanged content and repeated copies do not transfer', async () => {
  const f = fixture(); await f.coordinator.request();
  f.localText('new'); await f.coordinator.request(); await f.coordinator.request();
  f.localText('new'); await f.coordinator.request();
  assert.deepEqual(f.calls.uploads, ['new']); assert.deepEqual(f.calls.writes, []);
});

test('remote text downloads once and own clipboard events do not bounce back', async () => {
  const f = fixture(); await f.coordinator.request();
  f.remoteText('remote'); await f.coordinator.request(); await f.coordinator.request();
  assert.deepEqual(f.calls.writes, ['remote']); assert.deepEqual(f.calls.uploads, []);
  assert.equal(f.storage.get('currentRemoteRecord').text, 'remote');
});

test('URI and empty clipboard never upload; remote File/Group never replace clipboard', async () => {
  for (const type of ['File', 'Group']) {
    const f = fixture(); await f.coordinator.request();
    f.local({ kind: 'Unsupported', fingerprint: 'URI-2', text: 'file://picture.png' });
    await f.coordinator.request();
    f.remote({ type, hash: 'FILE', dataName: 'photo.png', hasData: true, text: 'photo.png' });
    await f.coordinator.request();
    assert.deepEqual(f.calls.uploads, []); assert.deepEqual(f.calls.writes, []);
    assert.equal(f.storage.get('currentRemoteRecord').type, type);
  }
  const f = fixture(); await f.coordinator.request();
  f.local({ kind: 'Empty', fingerprint: 'Empty', time: NaN }); await f.coordinator.request();
  assert.deepEqual(f.calls.uploads, []);
});

test('direct PixelMap uploads with stable filename; identical image recopy is ignored', async () => {
  const f = fixture(); await f.coordinator.request();
  f.local({ kind: 'Image', fingerprint: 'Image-ABC', imagePath: '/cache/image.png' });
  await f.coordinator.request();
  f.local({ kind: 'Image', fingerprint: 'Image-ABC' }); await f.coordinator.request();
  assert.deepEqual(f.calls.uploads, ['Clipboard-ABC.png']); assert.deepEqual(f.calls.writes, []);
  assert.equal(f.calls.files.length, 0); assert.ok(f.calls.removed.includes('/cache/image.png'));
});

test('remote Image streams, decodes, copies and releases without a sync loop', async () => {
  const f = fixture(); await f.coordinator.request();
  f.remote({ type: 'Image', hash: 'SERVER', pixelHash: 'PIXELS', hasData: true, dataName: 'photo.jpg' });
  await f.coordinator.request(); await f.coordinator.request();
  f.local({ kind: 'Image', fingerprint: 'Image-PIXELS' }); await f.coordinator.request();
  assert.deepEqual(f.calls.writes, ['image:PIXELS']); assert.deepEqual(f.calls.files, ['Image-SERVER']);
  assert.equal(f.calls.releases, 1); assert.deepEqual(f.calls.uploads, []);
});

test('image equality inspection and a subsequent server pull reuse the same download', async () => {
  const f = fixture(); await f.coordinator.request();
  f.local({ kind: 'Image', fingerprint: 'Image-LOCAL', imagePath: '/cache/local.png' });
  await f.coordinator.request();
  f.remote({ hash: 'NEW', pixelHash: 'REMOTE', lastAccessed: new Date().toISOString() });
  await f.coordinator.request();
  assert.deepEqual(f.calls.files, ['Image-NEW']);
  assert.deepEqual(f.calls.writes, ['image:REMOTE']);
  assert.equal(f.calls.releases, 2);
});

test('first enable and simultaneous changes use calibrated server time', async () => {
  const f = fixture({ serverOffset: 3600000 });
  f.localText('local', f.now - 1000);
  f.remoteText('remote', f.now + 3600000 - 5000);
  await f.coordinator.request(); assert.deepEqual(f.calls.uploads, ['local']);
  f.localText('local2', f.now - 10000);
  f.remoteText('remote2', f.now + 3600000 - 5000);
  await f.coordinator.request(); assert.deepEqual(f.calls.writes, ['remote2']);
});

test('ambiguous/missing times pause every automatic action until explicit re-enable', async () => {
  for (const options of [{}, { noClock: true }, { clockJump: true }]) {
    const f = fixture(options); await f.coordinator.request();
    f.localText('local', f.now - 20000); f.remoteText('remote', f.now - 20000);
    await f.coordinator.request();
    assert.equal(f.storage.get('isPollingEnabled'), false);
    assert.ok(f.storage.get('syncPausedReason')); assert.equal(f.calls.stopped, 1);
    f.account('B'); f.remoteText('remote-new', f.now - 5000); await f.coordinator.request();
    assert.deepEqual(f.calls.uploads, []); assert.deepEqual(f.calls.writes, []);
    assert.equal(f.calls.probes, 0);
    if (!options.noClock && !options.clockJump) {
      await f.coordinator.enable(); await f.coordinator.request();
      assert.equal(f.storage.get('syncPausedReason'), '');
      assert.deepEqual(f.calls.writes, ['remote-new']);
    }
  }
  const f = fixture(); f.localText('local'); f.remote({ lastAccessed: undefined });
  await f.coordinator.request(); assert.ok(f.storage.get('syncPausedReason'));
});

test('a detected server clock jump pauses competing updates rather than applying the new offset blindly', async () => {
  const options = { serverOffset: 0 }; const f = fixture(options);
  await f.coordinator.request(); options.serverOffset = 3600000;
  f.localText('local', f.now - 10000); f.remoteText('remote', f.now + 3600000 - 5000);
  await f.coordinator.request();
  assert.ok(f.storage.get('syncPausedReason')); assert.deepEqual(f.calls.writes, []);
  assert.deepEqual(f.calls.uploads, []);
});

test('permission/read failure pauses; network failure preserves clipboard and retries', async () => {
  const f = fixture(); f.failCapture('Clipboard permission denied'); await f.coordinator.request();
  assert.ok(f.storage.get('syncPausedReason')); assert.deepEqual(f.calls.writes, []);
  const n = fixture(); await n.coordinator.request(); n.failRead('Network unavailable');
  n.localText('local'); await n.coordinator.request();
  assert.equal(n.storage.get('isPollingEnabled'), true); assert.equal(n.calls.probes, 1);
  assert.deepEqual(n.calls.uploads, []); n.failRead(undefined); await n.coordinator.request();
  assert.deepEqual(n.calls.uploads, ['local']);
});

test('a new local copy before upload commit cancels the stale value and re-arbitrates', async () => {
  const f = fixture(); await f.coordinator.request(); f.localText('stale');
  f.beforeGuard(() => f.localText('newest')); await f.coordinator.request();
  assert.deepEqual(f.calls.uploads, ['newest']); assert.deepEqual(f.calls.writes, []);
});

test('account switch or backgrounding during image download cancels writes and cleans cache', async () => {
  for (const mode of ['account', 'background', 'network', 'decode']) {
    const f = fixture({ downloadError: mode === 'network', decodeError: mode === 'decode' });
    await f.coordinator.request();
    f.remote({ type: 'Image', hash: 'SERVER', pixelHash: 'PIXELS', hasData: true });
    if (mode === 'account' || mode === 'background') f.duringDownload(async () => {
      if (mode === 'account') f.account('B');
      else { f.storage.set('appForeground', false); f.coordinator.invalidate(); }
    });
    await f.coordinator.request(); assert.deepEqual(f.calls.writes, []);
    assert.equal(f.calls.removed.length, 1); assert.equal(f.calls.notices[0][2], true);
  }
});

test('manual pull works while paused and never clears the suspension flag', async () => {
  const f = fixture(); f.storage.set('syncPausedReason', 'ambiguous');
  f.storage.set('isPollingEnabled', false); f.remoteText('manual');
  await f.coordinator.pullNow(); assert.deepEqual(f.calls.writes, ['manual']);
  assert.equal(f.storage.get('syncPausedReason'), 'ambiguous');
});

test('operation queue serializes transfers and recovers after a rejected operation', async () => {
  const { SyncOperationQueue } = load('services/SyncOperationQueue.ets');
  let resolve; const gate = new Promise(r => { resolve = r; }); const events = [];
  const first = SyncOperationQueue.run(async () => { events.push('first'); await gate; throw new Error('failed'); });
  const failed = assert.rejects(first, /failed/);
  const second = SyncOperationQueue.run(async () => events.push('second'));
  await Promise.resolve(); assert.deepEqual(events, ['first']); resolve();
  await failed; await second; assert.deepEqual(events, ['first', 'second']);
});

test('pause reason is persisted across config reloads and prevents automatic account failover', async () => {
  const saved = new Map(); const runtime = new Map([['abilityContext', {}]]);
  const AppStorage = { get: k => runtime.get(k), setOrCreate: (k, v) => runtime.set(k, v) };
  const preferences = { async get(k, d) { return saved.has(k) ? saved.get(k) : d; },
    async put(k, v) { saved.set(k, v); }, async flush() {} };
  const { SettingsPolicy } = load('utils/SettingsPolicy.ets');
  const mocks = { AppStorage, SettingsPolicy, dataPreferences: { async getPreferences() { return preferences; } } };
  const { ConfigService } = load('services/ConfigService.ets', mocks);
  const config = ConfigService.getInstance(); await config.setSyncPaused('ambiguous');
  runtime.clear(); runtime.set('abilityContext', {});
  const { ConfigService: Reloaded } = load('services/ConfigService.ets', mocks);
  await Reloaded.getInstance().loadConfig(); assert.equal(runtime.get('syncPausedReason'), 'ambiguous');
  assert.equal(runtime.get('isPollingEnabled'), false);
  let probes = 0;
  const { ServerManager } = load('services/ServerManager.ets', {
    AppStorage, ConfigService: Reloaded, connection: {},
    SyncClipboardService: class { async probe() { probes++; } },
  });
  await ServerManager.getInstance().ensureAvailable(); assert.equal(probes, 0);
  await Reloaded.getInstance().setSyncPaused(''); assert.equal(saved.get('sync_paused_reason'), '');
});

test('real clipboard snapshots convert boot nanoseconds and do not coerce URIs into text', async () => {
  const board = {
    count: 7, mime: 'text', has: true,
    getChangeCount() { return this.count; }, async hasData() { return this.has; },
    async getData() { return {
      getProperty: () => ({ timestamp: 2500000000 }), getPrimaryMimeType: () => this.mime,
      getPrimaryText: () => 'hello', getPrimaryUri: () => 'file://photo.png',
    }; },
  };
  const { ClipboardSnapshotUtil } = load('utils/ClipboardSnapshotUtil.ets', {
    pasteboard: { getSystemPasteboard: () => board, MIMETYPE_TEXT_PLAIN: 'text', MIMETYPE_PIXELMAP: 'image' },
    systemDateTime: { getUptime: () => 5000, TimeType: { STARTUP: 0 } },
    ClipboardUtil: { ensureReadPermission: async () => true },
    HashUtil: { calculateTextHash: async text => hash(text) },
  });
  const before = Date.now(); const value = await ClipboardSnapshotUtil.capture(); const after = Date.now();
  assert.equal(value.fingerprint, `Text-${hash('hello')}`); assert.equal(value.changeCount, 7);
  assert.ok(value.time >= before - 2500 && value.time <= after - 2500);
  board.mime = 'uri'; const uri = await ClipboardSnapshotUtil.capture();
  assert.equal(uri.kind, 'Unsupported'); assert.equal(uri.text, '');
  board.has = false; assert.equal((await ClipboardSnapshotUtil.capture()).kind, 'Empty');
  board.has = true; board.mime = 'text';
  board.getData = async () => { board.count++; return {
    getProperty: () => ({ timestamp: 0 }), getPrimaryMimeType: () => 'text', getPrimaryText: () => 'race',
  }; };
  await assert.rejects(ClipboardSnapshotUtil.capture(), /Clipboard changed during read/);
});

test('real clipboard reader propagates read errors and releases image resources on encode failure', async () => {
  for (const mode of ['denied', 'read', 'encode']) {
    let released = 0, packerReleased = 0, closed = 0, removed = 0;
    const { ClipboardSnapshotUtil } = load('utils/ClipboardSnapshotUtil.ets', {
      AppStorage: { get: () => ({ cacheDir: '/cache' }) },
      pasteboard: { MIMETYPE_PIXELMAP: 'image', getSystemPasteboard: () => ({
        getChangeCount: () => 1, async hasData() { if (mode === 'read') throw new Error('read failed'); return true; },
        async getData() { return {
          getProperty: () => ({ timestamp: 1000000 }), getPrimaryMimeType: () => 'image',
          getPrimaryPixelMap: () => ({ async release() { released++; } }),
        }; },
      }) },
      systemDateTime: { getUptime: () => 5000, TimeType: { STARTUP: 0 } },
      ClipboardUtil: { ensureReadPermission: async () => mode !== 'denied' },
      fs: { OpenMode: { CREATE: 1, WRITE_ONLY: 2 }, async open() { return { fd: 4 }; },
        async close() { closed++; }, async unlink() { removed++; } },
      image: { createImagePacker: () => ({ async packToFile() { throw new Error('encode failed'); },
        async release() { packerReleased++; } }) },
    });
    await assert.rejects(ClipboardSnapshotUtil.capture(),
      new RegExp(mode === 'denied' ? 'permission denied' : `${mode} failed`));
    assert.equal(released, mode === 'encode' ? 1 : 0);
    assert.equal(packerReleased, mode === 'encode' ? 1 : 0);
    assert.equal(closed, mode === 'encode' ? 1 : 0);
    assert.equal(removed, mode === 'encode' ? 1 : 0);
  }
});

test('real text upload checks guard immediately before PUT and verifies server confirmation', async () => {
  for (const mode of ['stale', 'ok', 'changed']) {
    const calls = []; let profile;
    class HttpClient {
      async get(route) {
        calls.push(route);
        return route === '/SyncClipboard.json' ? (mode === 'changed' ? { type: 'Text', hash: 'OTHER' } : profile) : {};
      }
      async put(route, body) { calls.push('PUT'); profile = body; }
    }
    const { SyncOperationQueue } = load('services/SyncOperationQueue.ets');
    const { SyncClipboardService } = load('services/SyncClipboardService.ets', {
      HttpClient, SyncOperationQueue, HashUtil: { calculateTextHash: async text => hash(text) },
    });
    const operation = new SyncClipboardService('server').uploadTextContentExclusive('hello', async () => {
      calls.push('guard'); if (mode === 'stale') throw new Error('Sync state changed');
    });
    if (mode === 'stale') await assert.rejects(operation, /Sync state changed/);
    else if (mode === 'changed') await assert.rejects(operation, /could be confirmed/);
    else await operation;
    assert.deepEqual(calls, mode === 'stale' ? [`/api/history/Text-${hash('hello')}`, 'guard'] :
      [`/api/history/Text-${hash('hello')}`, 'guard', 'PUT', '/SyncClipboard.json']);
  }
});


test('manual image and file pulls return records without downloading or writing the clipboard', async () => {
  for (const type of ['Image', 'File', 'Group']) {
    const f = fixture(); f.storage.set('isPollingEnabled', false);
    f.remote({ type, hash: 'attachment', text: 'attachment.bin', hasData: true });
    f.failCapture('Clipboard permission denied');
    const record = await f.coordinator.pullNow();
    assert.equal(record.type, type); assert.equal(record.hash, 'attachment');
    assert.deepEqual(f.calls.writes, []); assert.deepEqual(f.calls.files, []);
    assert.equal(f.storage.get('isPollingEnabled'), false);
  }
});

test('explicit clipboard upload works while paused and publishes the confirmed current record', async () => {
  const f = fixture(); f.storage.set('syncPausedReason', 'ambiguous');
  f.storage.set('isPollingEnabled', false); f.localText('manual upload');
  await f.coordinator.uploadClipboard();
  assert.deepEqual(f.calls.uploads, ['manual upload']);
  assert.equal(f.storage.get('currentRemoteRecord').text, 'manual upload');
  assert.equal(f.storage.get('syncPausedReason'), 'ambiguous');
  assert.deepEqual(f.calls.writes, []);
});

test('explicit image upload releases temporary PNG and does not write local clipboard', async () => {
  const f = fixture(); f.local({ kind: 'Image', imagePath: '/cache/copied.png', fingerprint: 'Image-PIXELS' });
  await f.coordinator.uploadClipboard();
  assert.deepEqual(f.calls.uploads, ['Clipboard-PIXELS.png']);
  assert.ok(f.calls.removed.includes('/cache/copied.png'));
  assert.deepEqual(f.calls.writes, []);
});

test('explicit empty and URI uploads fail clearly without submitting or changing sync state', async () => {
  for (const kind of ['Empty', 'Unsupported']) {
    const f = fixture(); f.local({ kind });
    await assert.rejects(f.coordinator.uploadClipboard(), kind === 'Empty' ? /Empty clipboard/ : /Only clipboard/);
    assert.deepEqual(f.calls.uploads, []); assert.deepEqual(f.calls.writes, []);
    assert.equal(f.storage.get('isPollingEnabled'), true);
  }
});

test('manual upload detects a changed account before commit and preserves local clipboard', async () => {
  const f = fixture(); f.localText('old account payload');
  f.beforeGuard(() => f.account('B'));
  await assert.rejects(f.coordinator.uploadClipboard(), /Sync state changed/);
  assert.deepEqual(f.calls.uploads, []); assert.deepEqual(f.calls.writes, []);
});


test('Home background invalidation does not cancel a queued explicit clipboard upload', async () => {
  const f = fixture(); f.localText('card upload');
  f.beforeGuard(() => { f.storage.set('appForeground', false); f.coordinator.invalidate(); });
  await f.coordinator.uploadClipboard();
  assert.deepEqual(f.calls.uploads, ['card upload']);
  assert.equal(f.storage.get('appForeground'), false);
});

test('manual cancellation before commit leaves both clipboard and server untouched', async () => {
  const f = fixture(); f.localText('do not upload'); const cancellation = { canceled: false };
  f.beforeGuard(() => { cancellation.canceled = true; });
  await assert.rejects(f.coordinator.uploadClipboard(() => {}, { cancellation }), /Sync state changed/);
  assert.deepEqual(f.calls.uploads, []); assert.deepEqual(f.calls.writes, []);
});

test('account revision change cancels an explicit operation even when selected account is unchanged', async () => {
  const f = fixture(); f.localText('outdated credentials');
  f.beforeGuard(() => { f.storage.set('serverRevision', 1); });
  await assert.rejects(f.coordinator.uploadClipboard(), /Sync state changed/);
  assert.deepEqual(f.calls.uploads, []);
});
