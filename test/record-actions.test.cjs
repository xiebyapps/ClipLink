// Run with DEVECO_SDK_HOME pointing at the SDK directory in DevEco Studio.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.ARKTS_TYPESCRIPT_PATH || path.join(
  process.env.DEVECO_SDK_HOME, 'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const sourceRoot = path.resolve(__dirname, '../entry/src/main/ets');

function load(relative, mocks = {}) {
  const source = fs.readFileSync(path.join(sourceRoot, relative), 'utf8').replace(/^import .*;\r?\n/gm, '');
  const compiled = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS },
  }).outputText;
  const sandbox = { exports: {}, console: { info() {}, error() {} }, Error, ...mocks };
  vm.runInNewContext(compiled, sandbox, { filename: relative });
  return sandbox.exports;
}

test('favorite toggles only the server starred field and reads authoritative metadata', async () => {
  const calls = [];
  const serverRecord = { type: 'Image', hash: 'ABC', starred: true, pinned: true, version: 10 };
  class HttpClient {
    async patch(route, body) { calls.push([route, JSON.stringify(body)]); }
    async get(route) { calls.push([route]); return serverRecord; }
  }
  const { SyncClipboardService } = load('services/SyncClipboardService.ets', { HttpClient });
  const service = new SyncClipboardService('https://example.invalid');
  const record = { type: 'Image', hash: 'ABC', starred: false, pinned: true, version: 9 };
  assert.equal(await service.setHistoryStarred(record, true), serverRecord);
  assert.deepEqual(calls, [['/api/history/Image/ABC', '{"starred":true}'], ['/api/history/Image-ABC']]);
  assert.equal(record.starred, false, 'input remains unchanged until the caller accepts the result');
  serverRecord.starred = false;
  await service.setHistoryStarred(record, false);
  assert.equal(calls[2][1], '{"starred":false}');
});

test('favorite requests propagate rejection and never confirm an unchanged server record', async () => {
  for (const status of [401, 405, 409]) {
    let gets = 0;
    class HttpClient {
      async patch() { throw new Error(`HTTP ${status}`); }
      async get() { gets++; }
    }
    const { SyncClipboardService } = load('services/SyncClipboardService.ets', { HttpClient });
    await assert.rejects(new SyncClipboardService('https://example.invalid')
      .setHistoryStarred({ type: 'File', hash: 'ABC' }, true), new RegExp(`HTTP ${status}`));
    assert.equal(gets, 0);
  }
  class HttpClient {
    async patch() {}
    async get() { return { type: 'File', hash: 'ABC', starred: false }; }
  }
  const { SyncClipboardService } = load('services/SyncClipboardService.ets', { HttpClient });
  await assert.rejects(new SyncClipboardService('https://example.invalid')
    .setHistoryStarred({ type: 'File', hash: 'ABC' }, true), /not confirmed/);
});

test('RCP PATCH carries authentication and closes its session on every outcome', async () => {
  for (const outcome of ['ok', 'http', 'network']) {
    let closed = 0;
    let request;
    const rcp = {
      Request: class { constructor(url, method, headers, body) { Object.assign(this, { url, method, headers, body }); } },
      createSession() {
        return {
          async fetch(value) {
            request = value;
            if (outcome === 'network') throw { code: 123 };
            return { statusCode: outcome === 'ok' ? 200 : 401, toString: () => 'rejected' };
          },
          close() { closed++; },
        };
      },
    };
    const { HttpClient } = load('services/HttpClient.ets', { rcp });
    const operation = new HttpClient('https://example.invalid/', 'user', 'password')
      .patch('/api/history/Image/ABC', { starred: true });
    if (outcome === 'ok') await operation;
    else await assert.rejects(operation, outcome === 'http' ? /HTTP 401/ : /REQUEST_123/);
    assert.equal(request.url, 'https://example.invalid/api/history/Image/ABC');
    assert.equal(request.method, 'PATCH');
    assert.equal(request.headers['Content-Type'], 'application/json');
    assert.equal(Buffer.from(request.headers.Authorization.slice(6), 'base64').toString(), 'user:password');
    assert.equal(request.body, '{"starred":true}');
    assert.equal(closed, 1);
  }
});

test('favorite confirmation reads fresh HTTP metadata after a PATCH rather than a cached value', async () => {
  const oldRecord = { type: 'Image', hash: 'ABC', starred: false, pinned: true };
  const currentRecord = { ...oldRecord };
  const http = {
    RequestMethod: { GET: 'GET' }, HttpDataType: { STRING: 0 },
    createHttp: () => ({
      request(url, options, callback) {
        const record = options.usingCache === false ? currentRecord : oldRecord;
        callback(null, { responseCode: 200, result: JSON.stringify(record) });
      }, destroy() {},
    }),
  };
  const rcp = {
    Request: class { constructor(url, method, headers, body) { this.body = body; } },
    createSession: () => ({
      async fetch(request) {
        currentRecord.starred = JSON.parse(request.body).starred;
        return { statusCode: 200 };
      }, close() {},
    }),
  };
  const { HttpClient } = load('services/HttpClient.ets', { http, rcp });
  const { SyncClipboardService } = load('services/SyncClipboardService.ets', { HttpClient });
  const service = new SyncClipboardService('https://example.invalid');
  assert.equal((await service.setHistoryStarred(oldRecord, true)).starred, true);
  assert.equal((await service.setHistoryStarred(currentRecord, false)).starred, false);
  assert.equal(currentRecord.pinned, true);
});

test('record names preserve Unicode and extensions; icons classify without reading files', () => {
  const { UserFileSaveUtil } = load('utils/UserFileSaveUtil.ets');
  const { LocalizationUtil } = load('utils/LocalizationUtil.ets');
  const { FileRecordDisplayUtil } = load('utils/FileRecordDisplayUtil.ets', {
    UserFileSaveUtil, LocalizationUtil, $r: name => name,
  });
  const make = (type, text) => ({ type, text, hash: '123456789ABC' });
  assert.equal(FileRecordDisplayUtil.text(make('Image', 'C:\\图片\\照片.JPG'), 'zh-CN', 'zh'), '照片.JPG');
  assert.equal(FileRecordDisplayUtil.text(make('File', '/files/readme'), 'en-US', 'en'), 'readme');
  assert.equal(FileRecordDisplayUtil.text(make('Image', ''), 'zh-CN', 'zh'), '图片-12345678');
  assert.equal(FileRecordDisplayUtil.text(make('Image', ''), 'en-US', 'en'), 'Image-12345678');
  assert.equal(FileRecordDisplayUtil.text(make('Text', '/keep/original\ntext'), 'en-US', 'en'), '/keep/original\ntext');
  assert.equal(FileRecordDisplayUtil.text(make('Group', '/a/一.jpg\nC:\\b\\二.pdf'), 'zh-CN', 'zh'), '一.jpg\n二.pdf');
  for (const [type, name, icon] of [
    ['Text', '', 'text'], ['Image', '', 'image'], ['File', 'A.PNG', 'image'],
    ['File', 'A.MP3', 'audio'], ['File', 'A.PDF', 'document'], ['File', 'A.MP4', 'video'],
    ['File', 'A.ZIP', 'archive'], ['Group', 'a.jpg\nb.mp3', 'group'], ['File', 'unknown', 'file'],
  ]) assert.equal(FileRecordDisplayUtil.icon(make(type, name)), `app.media.record_${icon}`);
  assert.equal(FileRecordDisplayUtil.cardBackground({ starred: true }, false, '#FFFFFF'), '#FFF7D6');
  assert.equal(FileRecordDisplayUtil.cardBackground({ starred: false }, true, '#000000'), '#000000');
});

test('image copying uses a cache lease and releases it on download/decode/copy failure or account switch', async () => {
  for (const outcome of ['ok', 'download', 'decode', 'copy', 'switch']) {
    let deleted = 0;
    let released = 0;
    let decoded = 0;
    let copied = 0;
    const { HistoryRecordActionService } = load('services/HistoryRecordActionService.ets', {
      ConfigService: { getInstance: () => ({ getConfig: () => ({ activeServerId: 'A' }) }) },
      RecordCacheService: { getInstance: () => ({ async acquire(record, account, service, progress) {
        await service.downloadHistoryFileToPath(`${record.type}-${record.hash}`, '/cache/image.part', progress);
        return { response: { path: '/cache/image.part' }, release() { deleted++; } };
      } }) },
      UserFileSaveUtil: {
        temporaryDownloadPath: () => '/cache/image.part',
        removeTemporaryDownload: value => { assert.equal(value, '/cache/image.part'); deleted++; },
      },
      ImageUtil: { async createPixelMapFromPath(value) {
        assert.equal(value, '/cache/image.part'); decoded++;
        if (outcome === 'decode') throw new Error('decode failed');
        return { async release() { released++; } };
      } },
      ClipboardUtil: { async setClipboardImage() {
        if (outcome === 'copy') throw new Error('copy failed');
        copied++;
      } },
    });
    const service = { async downloadHistoryFileToPath(id, target, progress) {
      assert.equal(id, 'File-ABC');
      assert.equal(target, '/cache/image.part');
      if (outcome === 'download') throw new Error('download failed');
      progress(100, 100);
    } };
    const operation = HistoryRecordActionService.copyImage({ type: 'File', hash: 'ABC' }, service,
      () => {}, () => outcome !== 'switch');
    if (outcome === 'ok') await operation;
    else await assert.rejects(operation);
    assert.equal(deleted, outcome === 'download' ? 0 : 1);
    assert.equal(released, ['ok', 'copy'].includes(outcome) ? 1 : 0);
    assert.equal(copied, outcome === 'ok' ? 1 : 0);
    if (outcome === 'switch') assert.equal(decoded, 0);
  }
});

test('an older history response cannot undo a favorite, while recreated server records remain valid', async () => {
  const rows = new Map();
  class RdbPredicates {
    constructor() { this.filters = {}; }
    equalTo(key, value) { this.filters[key] = value; return this; }
    orderByDesc() { return this; }
  }
  const { HistoryStorageService } = load('services/HistoryStorageService.ets', {
    AppStorage: { get() {}, setOrCreate() {} },
    relationalStore: { RdbPredicates, ConflictResolution: { ON_CONFLICT_REPLACE: 1 } },
    ConfigService: { getInstance: () => ({ getConfig: () => ({ maxHistorySize: 100, servers: [{id: 'A'}, {id: 'B'}] }) }) },
    RecordCacheService: { getInstance: () => ({ initialize() {}, allowRecord() {}, retainRecords() {}, async storeInline() {} }) },
  });
  const storage = HistoryStorageService.getInstance();
  storage.store = {
    async query(predicates) {
      const selected = [...rows.values()].filter(row => row.serverId === predicates.filters.serverId &&
        (!predicates.filters.profileHash || row.profileHash === predicates.filters.profileHash));
      let position = 0;
      return {
        goToFirstRow: () => !!selected[0], getColumnIndex: key => key,
        goToNextRow: () => position++ < selected.length,
        getLong: key => selected[Math.max(0, position - 1)][key],
        getString: key => selected[Math.max(0, position - 1)][key], close() {},
      };
    },
    async insert(table, row) { rows.set(`${row.serverId}:${row.profileHash}`, row); },
  };
  const make = (version, lastModified, starred) => ({ type: 'Image', hash: 'ABC', version, lastModified, starred });
  await Promise.all([
    storage.upsertRecord(make(2, '2026-09-27T02:00:00Z', true), 'A'),
    storage.upsertRecord(make(1, '2026-09-27T01:00:00Z', false), 'A'),
    storage.upsertRecord(make(1, '2026-09-27T01:00:00Z', false), 'B'),
  ]);
  assert.equal(rows.get('A:Image-ABC').starred, 1);
  assert.equal(rows.get('B:Image-ABC').starred, 0);
  await storage.upsertRecord(make(0, '2026-09-28T01:00:00Z', false), 'A');
  assert.equal(rows.get('A:Image-ABC').starred, 0, 'a newer record after a server history reset is accepted');
});
