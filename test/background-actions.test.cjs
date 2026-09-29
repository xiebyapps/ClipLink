const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(path.join(process.env.DEVECO_SDK_HOME, 'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function load(file, mocks, transform = source => source) {
  const source = transform(fs.readFileSync(path.join(__dirname, '../entry/src/main/ets', file), 'utf8')).replace(/^import .*;\r?\n/gm, '');
  const output = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText;
  const sandbox = { exports: {}, console: { error() {}, warn() {} }, Error, Date, ...mocks };
  vm.runInNewContext(output, sandbox, { filename: file }); return sandbox.exports;
}
const flush = () => new Promise(r => setImmediate(r));
function fixture({ type = 'Text', failure, denied = false, promotionFailure = false } = {}) {
  const calls = { lease: [], uploads: [], pulls: [], previews: [], reads: [], statuses: [], feedback: [], promotes: [], idle: 0, auth: 0 };
  const storage = new Map([['isPollingEnabled', false], ['syncPausedReason', 'ambiguous']]);
  let account = { id: 'A', url: 'https://server.invalid', username: 'user', password: 'secret' }, observer;
  let savedPanel;
  let pending, fail = failure; const owner = { cacheDir: '/own/cache', abilityInfo: { bundleName: 'bundle' } };
  class Cancellation { canceled = false; cancel() { this.canceled = true; } }
  class Lease { constructor(ctx, id, expire) { assert.equal(ctx, owner); this.expire = expire; calls.lease.push(this); }
    start(mode) { this.started = true; this.mode = mode; } foreground() { this.mode = 'foreground'; } background() { this.mode = 'background'; } async stop() { this.stopped = true; } async progress() {} }
  class Session { constructor(record, automatic, context) { calls.previews.push({ record, automatic, context }); }
    isActive() { return !this.closed; } close() { this.closed = true; } }
  const { ClipboardBackgroundActionService } = load('services/ClipboardBackgroundActionService.ets', {
    AppStorage: { get: k => storage.get(k), setOrCreate: (k, v) => storage.set(k, v) },
    ConfigService: { getInstance: () => ({ setContext() {}, loadConfig: async () => {}, getActiveServer: () => account,
      observeAccount(fn) { observer = fn; }, unobserveAccount() {} }) },
    DesktopPanelStore: { save: async (ctx, request, record) => { savedPanel = { request, record, accountId: account.id }; },
      restore: async (ctx, id) => { if (!savedPanel || savedPanel.request.id !== id) return undefined;
        if (savedPanel.accountId !== account.id) throw new Error('Server changed during operation'); return savedPanel; },
      clear: async () => { savedPanel = undefined; } },
    ClipboardSnapshotUtil: { cleanupAbandoned: async () => {} },
    ClipboardTaskLease: Lease, DownloadCancellation: Cancellation, RecordPreviewSession: Session,
    RecordCacheService: { getInstance: () => ({ initialize: ctx => assert.equal(ctx, owner) }) },
    ClipboardWidgetService: { completeRequest: async () => {}, validateForm: async id => assert.equal(id, 'F'),
      actionStatus: async (...args) => calls.statuses.push(args), resetAll: async () => {},
      revealLatest: async (...args) => { calls.reads.push(args); if (fail) throw new Error(fail); } },
    ClipboardActionFeedback: { show: async message => calls.feedback.push(message), authorize: async () => {} },
    ClipboardUtil: { ensureReadPermission: async () => { calls.auth++; return !denied; } },
    SyncCoordinator: { getInstance: () => ({
      async uploadClipboard(progress, options) { calls.uploads.push(options); if (pending) await pending;
        if (options.cancellation.canceled) throw new Error('Sync state changed'); if (fail) throw new Error(fail); },
      async pullNow(options) { calls.pulls.push(options); if (pending) await pending;
        if (options.cancellation.canceled) throw new Error('Sync state changed'); if (fail) throw new Error(fail);
        return { type, hash: 'HASH', text: 'payload' }; },
    }) },
  });
  const service = ClipboardBackgroundActionService.getInstance();
  service.bind(owner, async id => { calls.promotes.push(id); if (promotionFailure) throw new Error('OS denied'); }, () => calls.idle++);
  return { service, calls, storage, owner,
    request: (action = 'upload', id = 'R') => ({ action, id, formId: 'F', token: '' }),
    failure: value => { fail = value; }, wait: promise => { pending = promise; },
    switchAccount() { account = { ...account, id: 'B' }; storage.set('serverRevision', 1); observer(); },
  };
}

test('cold card upload runs with its own context and never enables foreground polling', async () => {
  const h = fixture(); await h.service.accept(h.request());
  assert.equal(h.calls.uploads.length, 1); assert.equal(h.calls.uploads[0].context, h.owner);
  assert.equal(h.calls.uploads[0].allowPrompt, false); assert.equal(h.calls.promotes.length, 0);
  assert.equal(h.calls.idle, 1); assert.ok(h.calls.lease[0].stopped);
  assert.equal(h.storage.get('isPollingEnabled'), false); assert.equal(h.storage.get('syncPausedReason'), 'ambiguous');
  assert.equal(h.storage.has('abilityContext'), false); assert.equal(h.storage.has('appForeground'), false);
  assert.ok(!JSON.stringify(h.calls.feedback).includes('secret'));
});

test('card request IDs execute once and rapid taps do not enqueue duplicate transfers', async () => {
  const h = fixture(); let release; h.wait(new Promise(r => { release = r; }));
  const run = h.service.accept(h.request()); await flush();
  await h.service.accept(h.request()); await h.service.accept(h.request('upload', 'second'));
  assert.equal(h.calls.uploads.length, 1); release(); await run;
  await h.service.accept(h.request()); assert.equal(h.calls.uploads.length, 1);
});

test('Text sync stays in background; attachments open a pinned sheet with automatic system preview disabled', async () => {
  for (const type of ['Text', 'Image', 'File', 'Group']) {
    const h = fixture({ type }); await h.service.accept(h.request('sync'));
    assert.equal(h.calls.pulls.length, 1);
    assert.equal(h.calls.previews.length, type === 'Text' ? 0 : 1);
    if (type === 'Text') { assert.deepEqual(h.calls.promotes, []); assert.equal(h.calls.idle, 1); }
    else { assert.equal(h.calls.previews[0].automatic, false); assert.equal(h.calls.previews[0].context, h.owner);
      assert.deepEqual(h.calls.promotes, []); assert.equal(h.calls.statuses.at(-1)[2], 'R'); assert.equal(h.service.mode, 'panel'); }
  }
});

test('permission fallback continues the original action once; denial never submits or opens Home', async () => {
  for (const denied of [false, true]) {
    const h = fixture({ failure: 'Clipboard permission denied', denied }); await h.service.accept(h.request());
    assert.equal(h.service.mode, 'authorize'); assert.deepEqual(h.calls.promotes, ['R']);
    h.failure(); await h.service.foreground('R', {}); await h.service.foreground('R', {});
    assert.equal(h.calls.auth, 1); assert.equal(h.calls.uploads.length, denied ? 1 : 2);
    assert.equal(h.service.mode, 'result'); assert.equal(h.calls.promotes.length, 1);
    if (denied) assert.equal(h.service.status, 'Clipboard permission denied');
  }
});

test('network failure reports on the card without requesting foreground authorization', async () => {
  const h = fixture({ failure: 'Network failed' }); await h.service.accept(h.request('sync'));
  assert.equal(h.calls.auth, 0); assert.deepEqual(h.calls.promotes, []);
  assert.equal(h.service.status, 'Network failed'); assert.equal(h.calls.statuses.at(-1)[1], 'Network failed');
});

test('OS foreground denial preserves an explicit card open-panel entry', async () => {
  const h = fixture({ type: 'File', promotionFailure: true }); await h.service.accept(h.request('sync'));
  assert.equal(h.service.mode, 'panel'); assert.equal(h.calls.statuses.at(-1)[2], 'R');
  await h.service.foreground('R', {}); assert.equal(h.calls.pulls.length, 1);
});

test('account change or real task expiration cancels work and suppresses late success', async () => {
  for (const cause of ['account', 'timeout']) {
    const h = fixture(); let release; h.wait(new Promise(r => { release = r; }));
    const run = h.service.accept(h.request()); await flush();
    if (cause === 'account') h.switchAccount(); else h.calls.lease[0].expire();
    assert.equal(h.calls.uploads[0].cancellation.canceled, true); release(); await run;
    assert.ok(!h.calls.feedback.includes('Clipboard uploaded')); assert.ok(h.calls.lease[0].stopped);
  }
});

test('closing a sheet clears the open-panel card entry and cancels its session', async () => {
  const h = fixture({ type: 'Image' }); await h.service.accept(h.request('sync'));
  const session = h.service.session; await h.service.dismiss();
  assert.ok(session.closed); assert.equal(h.service.session, undefined); assert.equal(h.service.mode, '');
  assert.equal(h.calls.statuses.at(-1)[1], ''); assert.equal(h.calls.statuses.at(-1).length, 2);
});

function leases(quota = 2400, denyTransient = false) {
  const timers = new Map(); let sequence = 0, cancelHandler, suspended, startResolve;
  const calls = { suspendRequests: 0, cancelled: [], stops: 0, transfers: 0, expired: 0, notifications: [] };
  const manager = {
    requestSuspendDelay(reason, cb) { calls.suspendRequests++; if (denyTransient) throw Object.assign(new Error('9900002'), { code: 9900002 }); suspended = cb; return { requestId: 9, actualDelayTime: quota }; },
    cancelSuspendDelay(id) { calls.cancelled.push(id); },
    startBackgroundRunning: async () => { calls.transfers++; if (startResolve) await startResolve.promise;
      return { notificationId: 42, continuousTaskId: 5, contentType: 6, slotType: 4 }; },
    stopBackgroundRunning: async () => { calls.stops++; },
    on: (type, fn) => { cancelHandler = fn; }, off: () => { cancelHandler = undefined; },
  };
  const { ClipboardTaskLease } = load('services/ClipboardTaskLease.ets', {
    backgroundTaskManager: manager,
    wantAgent: { getWantAgent: async () => ({}), OperationType: { START_ABILITY: 1 }, WantAgentFlags: { UPDATE_PRESENT_FLAG: 1 } },
    notificationManager: { publish: async data => calls.notifications.push(data) },
    ConfigService: { getInstance: () => ({ getConfig: () => ({ language: 'en-US' }) }) },
    LocalizationUtil: { text: v => v, systemLanguage: () => 'en-US', formatBytes: v => String(v) },
    setTimeout: (fn, ms) => { const id = ++sequence; timers.set(id, { fn, ms }); return id; },
    clearTimeout: id => timers.delete(id),
  });
  const lease = new ClipboardTaskLease({ abilityInfo: { bundleName: 'app' } }, 'R', () => calls.expired++);
  return { lease, calls, timers, suspend: () => suspended(), cancel: id => cancelHandler({ id }),
    blockStart() { let resolve; startResolve = { promise: new Promise(r => { resolve = r; }) }; return resolve; } };
}

test('transient lease uses actualDelayTime and cancels every timer and system delay on expiry', async () => {
  const h = leases(2400); h.lease.start(); assert.ok([...h.timers.values()].some(t => t.ms === 2400));
  [...h.timers.values()].find(t => t.ms === 2400).fn(); await flush();
  assert.equal(h.calls.expired, 1); assert.equal(h.timers.size, 0); assert.deepEqual(h.calls.cancelled, [9]);
  h.suspend(); assert.equal(h.calls.expired, 1);
});

test('continuous transfer starts once, reports system progress and stops when the system cancels it', async () => {
  const h = leases(); h.lease.start(); await Promise.all([h.lease.ensureTransfer(), h.lease.ensureTransfer()]);
  assert.equal(h.calls.transfers, 1); assert.equal(h.timers.size, 0);
  assert.equal(h.calls.notifications[0].id, 42); assert.equal(h.calls.notifications[0].template.name, 'downloadTemplate');
  h.cancel(999); assert.equal(h.calls.expired, 0); h.cancel(5); await flush();
  assert.equal(h.calls.expired, 1); assert.equal(h.calls.stops, 1);
});

test('closing during a pending continuous-task grant cleans up a late grant', async () => {
  const h = leases(); h.lease.start(); const unblock = h.blockStart();
  const start = h.lease.ensureTransfer(); await flush(); const stop = h.lease.stop(); unblock(); await start; await stop;
  assert.equal(h.calls.stops, 1); assert.equal(h.timers.size, 0);
});

test('a cold card callee registers synchronously and does not load any page for an ordinary call', async () => {
  const calls = []; let handler, promote; const context = { abilityInfo: { bundleName: 'app' },
    async startAbility(want) { calls.push(want); }, async terminateSelf() {} };
  class UIAbility { context = context; callee = { on(method, fn) { assert.equal(method, 'perform'); handler = fn; }, off() {} }; }
  const { default: Ability } = load('entryability/ClipboardActionAbility.ets', { UIAbility,
    ClipboardBackgroundActionService: { getInstance: () => ({ bind(ctx, fn) { promote = fn; }, accept: async r => calls.push(r) }) } });
  const ability = new Ability(); ability.onCreate({ parameters: {} }, {});
  const ack = handler({ readString: () => JSON.stringify({ desktopAction: 'upload', formId: 'F', requestId: 'R' }) });
  assert.equal(calls.length, 1); assert.equal(calls[0].action, 'upload'); assert.equal(typeof ack.marshalling, 'function');
  await promote('R'); assert.equal(calls[1].abilityName, 'ClipboardActionAbility'); assert.equal(calls[1].parameters.actionWindow, 'panel');
});


test('closing during a transfer prevents late completion from changing a newer request', async () => {
  const h = fixture(); let release; h.wait(new Promise(r => { release = r; }));
  const old = h.service.accept(h.request()); await flush();
  h.service.close(); h.wait();
  await h.service.accept(h.request('upload', 'NEW'));
  const feedbackCount = h.calls.feedback.length, idleCount = h.calls.idle;
  release(); await old;
  assert.equal(h.calls.feedback.length, feedbackCount); assert.equal(h.calls.idle, idleCount);
  assert.equal(h.service.status, 'Clipboard uploaded');
});

test('clipboard permission checks use the owning ability, avoid background dialogs, and detect revocation', async () => {
  const owner = { applicationInfo: { accessTokenId: 11 } }; let granted = true, prompts = 0;
  const { ClipboardUtil } = load('utils/ClipboardUtil.ets', {
    AppStorage: { get() { throw new Error('Home context must not be accessed'); } },
    abilityAccessCtrl: { GrantStatus: { PERMISSION_GRANTED: 0 }, createAtManager: () => ({
      async checkAccessToken(id, permission) { assert.equal(id, 11); assert.equal(permission, 'ohos.permission.READ_PASTEBOARD');
        return granted ? 0 : -1; },
      async requestPermissionsFromUser(context) { assert.equal(context, owner); prompts++; return { authResults: [-1] }; },
    }) },
  });
  assert.equal(await ClipboardUtil.ensureReadPermission(owner, false), true); assert.equal(prompts, 0);
  granted = false;
  assert.equal(await ClipboardUtil.ensureReadPermission(owner, false), false); assert.equal(prompts, 0);
  assert.equal(await ClipboardUtil.ensureReadPermission(owner, true), false); assert.equal(prompts, 1);
});

test('startup cleanup removes only recognized abandoned files once, preserving other live ability work', async () => {
  const removed = []; const { ClipboardSnapshotUtil } = load('utils/ClipboardSnapshotUtil.ets', {
    fs: { listFileSync: () => ['auto-sync-100-abc.png', 'upload-200-abc', 'user.png', 'upload-not-ours'],
      lstatSync: p => ({ isFile: () => p.endsWith('.png'), isDirectory: () => !p.endsWith('.png') }),
      unlink: async p => removed.push(p), rmdir: async p => removed.push(p) },
  });
  await ClipboardSnapshotUtil.cleanupAbandoned({ cacheDir: '/cache' });
  await ClipboardSnapshotUtil.cleanupAbandoned({ cacheDir: '/cache' });
  assert.deepEqual(removed, ['/cache/auto-sync-100-abc.png', '/cache/upload-200-abc']);
});


test('expiration during file preparation exits the loading panel and cancels its session', async () => {
  const h = fixture({ type: 'File' }); await h.service.accept(h.request('sync'));
  const session = h.service.session; h.service.previewExpired(); await flush();
  assert.ok(session.closed); assert.equal(h.service.session, undefined);
  assert.equal(h.service.mode, 'result'); assert.equal(h.service.status, 'Background task time expired');
  assert.equal(h.calls.statuses.at(-1)[1], 'Background task time expired');
});


test('empty card identity is rejected explicitly and repairs published cards instead of silently accepting', async () => {
  let handler; const events = []; class UIAbility {
    context = { terminateSelf: async () => events.push('terminated') };
    callee = { on(method, fn) { handler = fn; }, off() {} };
  }
  const { default: Ability } = load('entryability/ClipboardActionAbility.ets', { UIAbility,
    ClipboardBackgroundActionService: { getInstance: () => ({ bind() {}, accept: async () => events.push('operation') }) },
    ConfigService: { getInstance: () => ({ setContext() {}, loadConfig: async () => {} }) },
    ClipboardWidgetService: { resetAll: async () => events.push('repair') },
    ClipboardActionFeedback: { show: async message => events.push(message) },
  });
  new Ability().onCreate({ parameters: {} }, {});
  const ack = handler({ readString: () => JSON.stringify({ formId: '', requestId: 'R', desktopAction: 'sync' }) });
  let status; ack.marshalling({ writeString: value => { status = value; } });
  await flush(); assert.equal(status, 'rejected'); assert.ok(events.includes('repair'));
  assert.ok(events.includes('Widget refreshed. Tap again')); assert.ok(!events.includes('operation'));
});


test('card execution avoids forbidden late suspend requests and foreground downloads need no transient task', async () => {
  for (const mode of ['call', 'foreground']) {
    const h = leases(2400, true); h.lease.start(mode);
    assert.equal(h.calls.suspendRequests, 0); assert.equal(h.calls.expired, 0);
    await h.lease.stop(); assert.equal(h.timers.size, 0);
  }
  const h = fixture(); await h.service.accept(h.request('sync'));
  assert.equal(h.calls.lease[0].mode, 'call');
});

test('a delayed card open after sheet closure restores its attachment instead of reporting expired', async () => {
  const h = fixture({ type: 'File' }); await h.service.accept(h.request('sync'));
  const first = h.service.session; await h.service.dismiss();
  await h.service.foreground('R', {});
  assert.equal(h.service.mode, 'panel'); assert.equal(h.calls.pulls.length, 1);
  assert.equal(h.calls.previews.length, 2); assert.notEqual(h.service.session, first);
  assert.equal(h.calls.previews[1].record.hash, 'HASH');
});

test('simultaneous window lifecycle callbacks restore exactly one new session', async () => {
  const h = fixture({ type: 'Image' }); await h.service.accept(h.request('sync')); await h.service.dismiss();
  await Promise.all([h.service.restorePanel('R'), h.service.restorePanel('R')]);
  assert.equal(h.calls.previews.length, 2); assert.equal(h.calls.pulls.length, 1);
});

function panelStoreFixture(storage = new Map()) {
  let account = { id: 'A', url: 'server', username: 'u', password: 'secret' };
  const store = { get: async (key, fallback) => storage.get(key) ?? fallback,
    put: async (key, value) => storage.set(key, value), delete: async key => storage.delete(key), flush: async () => {} };
  const { DesktopPanelStore } = load('services/DesktopPanelStore.ets', {
    preferences: { getPreferences: async () => store },
    ConfigService: { getInstance: () => ({ getActiveServer: () => account, getConfig: () => ({ activeServerId: account.id }) }) },
    HashUtil: { calculateTextHash: async value => require('node:crypto').createHash('sha256').update(value).digest('hex') },
  });
  return { store: DesktopPanelStore, storage, change: changes => { account = { ...account, ...changes }; } };
}

test('attachment descriptors survive process recreation and pin the original account and file', async () => {
  const first = panelStoreFixture(); const request = { id: 'R', action: 'sync', formId: 'F', token: '' };
  await first.store.save({}, request, { type: 'File', hash: 'OLD', text: 'report.pdf', size: 100 });
  const next = panelStoreFixture(first.storage); const saved = await next.store.restore({}, 'R', 'F');
  assert.equal(saved.record.hash, 'OLD'); assert.equal(saved.record.text, 'report.pdf');
  assert.ok(!first.storage.get('panel').includes('secret'));
  assert.equal(await next.store.restore({}, 'OTHER', 'F'), undefined);
  assert.equal(await next.store.restore({}, 'R', 'OTHER'), undefined);
  next.change({ password: 'edited' }); await assert.rejects(next.store.restore({}, 'R'), /Server changed/);
});

test('resumption rejects text, uploads, expired descriptors and cannot clear a newer request', async () => {
  const h = panelStoreFixture(); const request = { id: 'R', action: 'sync', formId: 'F', token: '' };
  await assert.rejects(h.store.save({}, { ...request, action: 'upload' }, { type: 'Image', hash: 'X' }), /Invalid/);
  await assert.rejects(h.store.save({}, request, { type: 'Text', hash: 'X', text: 'private clipboard body' }), /Invalid/);
  await h.store.save({}, request, { type: 'Image', hash: 'X' });
  const expired = JSON.parse(h.storage.get('panel')); expired.expiresAt = Date.now() - 1;
  h.storage.set('panel', JSON.stringify(expired)); assert.equal(await h.store.restore({}, 'R'), undefined);
  await h.store.save({}, { ...request, id: 'NEW' }, { type: 'Group', hash: 'Y' });
  await h.store.clear({}, 'R'); assert.ok(await h.store.restore({}, 'NEW'));
  await h.store.clear({}, 'NEW'); assert.equal(await h.store.restore({}, 'NEW'), undefined);
});

test('string-valued router flags retain the request identity for foreground preparation', () => {
  const values = new Map(); class UIAbility { context = {} ; callee = { on() {}, off() {} }; }
  const { default: Ability } = load('entryability/ClipboardActionAbility.ets', { UIAbility,
    AppStorage: { get: key => values.get(key), setOrCreate: (key, value) => values.set(key, value) },
    ClipboardBackgroundActionService: { getInstance: () => ({ bind() {} }) },
  });
  for (const marker of ['panel', 'true', true]) {
    new Ability().onCreate({ parameters: { actionWindow: marker, requestId: 'R', formId: 'F' } }, {});
    assert.equal(values.get('clipboardActionRequestId'), 'R'); assert.equal(values.get('clipboardActionFormId'), 'F');
  }
});


test('the next card operation is accepted after a completed result instead of remaining blocked by its panel', async () => {
  const h = fixture({ failure: 'Clipboard permission denied' }); await h.service.accept(h.request());
  h.failure(); await h.service.foreground('R', {}); assert.equal(h.service.mode, 'result');
  h.service.windowBackground(); await h.service.accept(h.request('upload', 'NEXT'));
  assert.equal(h.calls.uploads.length, 3); assert.equal(h.calls.lease.at(-1).mode, 'call');
  assert.equal(h.service.mode, '');
});

test('a background call Want cannot accidentally mark an existing operation window foreground', () => {
  const events = []; class UIAbility { context = {}; callee = { on() {}, off() {} }; }
  const { default: Ability } = load('entryability/ClipboardActionAbility.ets', { UIAbility,
    AppStorage: { setOrCreate: (key, value) => events.push([key, value]) },
    ClipboardBackgroundActionService: { getInstance: () => ({ bind() {} }) },
  });
  const ability = new Ability(); ability.onCreate({ parameters: {} }, {});
  ability.onNewWant({ parameters: { desktopAction: 'upload', requestId: 'R' } }, {});
  assert.equal(events.length, 0);
});


test('a late transient expiry callback cannot cancel work after its window returns to foreground', async () => {
  const h = leases(); h.lease.start(); h.lease.foreground(); h.suspend(); await flush();
  assert.equal(h.calls.expired, 0); assert.deepEqual(h.calls.cancelled, [9]);
  await h.lease.stop();
});


test('attachment sync publishes its pinned request for the originating card to open exactly once', async () => {
  const h = fixture({ type: 'File' }); await h.service.accept(h.request('sync'));
  assert.deepEqual(h.calls.promotes, []);
  assert.equal(h.calls.statuses.at(-1)[2], 'R');
  await h.service.foreground('R', {});
  assert.equal(h.calls.pulls.length, 1);
  assert.equal(h.calls.statuses.at(-1)[2], undefined);
});

test('a denied window launch exposes only a retry link and removes it after the window opens', async () => {
  const h = fixture({ type: 'Image', promotionFailure: true }); await h.service.accept(h.request('sync'));
  assert.equal(h.calls.statuses.at(-1)[2], 'R');
  await h.service.foreground('R', {});
  assert.equal(h.calls.statuses.at(-1)[2], undefined);
  assert.equal(h.calls.pulls.length, 1);
});

function actionPageFixture({ slowCard = false, terminationFailure = false } = {}) {
  const calls = { dismiss: 0, terminate: 0, background: 0, sheetDismiss: 0 };
  let resolveCard;
  const cardUpdate = slowCard ? new Promise(resolve => { resolveCard = resolve; }) : Promise.resolve();
  const service = { mode: '', status: '', dismiss: () => { calls.dismiss++; return cardUpdate; } };
  const owner = {
    terminateSelf: async () => { calls.terminate++; if (terminationFailure) throw new Error('Window busy'); },
    moveAbilityToBackground: async () => { calls.background++; },
  };
  const { ClipboardActionPage } = load('pages/ClipboardActionPage.ets', {
    ConfigurationConstant: { ColorMode: { COLOR_MODE_NOT_SET: 0 } },
    DialogAlignment: { Bottom: 0 }, DownloadProgressSnackBar: () => {},
    CustomDialogController: class { close() {} },
    ClipboardBackgroundActionService: { getInstance: () => service },
  }, source => (source.split('  @Builder')[0] + '}')
    .replace(/@(StorageLink|Watch)\('[^']*'\)\s*/g, '')
    .replace(/@(Entry|Component|State)\s*/g, '')
    .replace('struct ClipboardActionPage', 'export class ClipboardActionPage'));
  const page = new ClipboardActionPage(); page.getUIContext = () => ({ getHostContext: () => owner });
  page.visible = true;
  return { page, calls, complete: () => { service.mode = 'complete'; }, finish: () => resolveCard?.(),
    dismissNative: () => page.sheetWillDismiss({ dismiss: () => calls.sheetDismiss++ }) };
}

test('native sheet dismissal exits the transparent ability even while card cleanup is waiting', async () => {
  const h = actionPageFixture({ slowCard: true }); h.dismissNative();
  assert.equal(h.page.visible, false); assert.equal(h.calls.sheetDismiss, 1);
  assert.equal(h.calls.dismiss, 1); assert.equal(h.calls.terminate, 1);
  h.page.close(); assert.equal(h.calls.terminate, 1);
  h.finish(); await flush();
});

test('back closes the whole action window once; system preview lifecycle alone does not dismiss the session', async () => {
  const h = actionPageFixture(); h.page.aboutToDisappear();
  assert.equal(h.calls.dismiss, 0); assert.equal(h.calls.terminate, 0);
  assert.equal(h.page.onBackPress(), true);
  assert.equal(h.calls.dismiss, 1); assert.equal(h.calls.terminate, 1);
  h.dismissNative(); assert.equal(h.calls.terminate, 1);
});

test('a failed termination still returns to the previous screen instead of leaving a transparent foreground', async () => {
  const h = actionPageFixture({ terminationFailure: true }); h.dismissNative(); await flush();
  assert.equal(h.calls.terminate, 1); assert.equal(h.calls.background, 1);
});


test('direct card router sync executes once in its visible window without another window launch', async () => {
  for (const type of ['Text', 'Image', 'File', 'Group']) {
    const h = fixture({ type }); let release; h.wait(new Promise(resolve => { release = resolve; }));
    const operation = h.service.foreground('R', {}, 'F', 'sync'); await flush();
    assert.equal(h.service.mode, 'running');
    await h.service.foreground('R', {}, 'F', 'sync');
    assert.equal(h.calls.pulls.length, 1); release(); await operation;
    assert.equal(h.calls.pulls[0].allowPrompt, true);
    assert.equal(h.calls.lease[0].mode, 'foreground');
    assert.equal(h.calls.promotes.length, 0);
    assert.equal(h.service.mode, type === 'Text' ? 'complete' : 'panel');
    await h.service.foreground('R', {}, 'F', 'sync'); assert.equal(h.calls.pulls.length, 1);
  }
});

test('a fresh router request replaces a completed attachment and checks account invalidation during sync', async () => {
  const h = fixture({ type: 'File' }); await h.service.foreground('R', {}, 'F', 'sync');
  const oldSession = h.service.session;
  await h.service.foreground('NEXT', {}, 'F', 'sync');
  assert.equal(h.calls.pulls.length, 2); assert.ok(oldSession.closed);
  let release; h.wait(new Promise(resolve => { release = resolve; }));
  const operation = h.service.foreground('THIRD', {}, 'F', 'sync'); await flush(); h.switchAccount();
  release(); await operation;
  assert.equal(h.service.session, undefined); assert.equal(h.service.mode, 'result');
  assert.equal(h.calls.promotes.length, 0);
});

test('router sync parameters select direct execution while opening an existing panel does not replay it', () => {
  const values = new Map(); class UIAbility { context = {}; callee = { on() {}, off() {} }; }
  const { default: Ability } = load('entryability/ClipboardActionAbility.ets', { UIAbility,
    AppStorage: { get: key => values.get(key), setOrCreate: (key, value) => values.set(key, value) },
    ClipboardBackgroundActionService: { getInstance: () => ({ bind() {} }) },
  });
  const ability = new Ability();
  ability.onCreate({ parameters: { actionWindow: 'panel', desktopAction: 'sync', requestId: 'R', formId: 'F' } }, {});
  assert.equal(values.get('clipboardActionDirectAction'), 'sync');
  ability.onNewWant({ parameters: { actionWindow: 'panel', requestId: 'R', formId: 'F' } }, {});
  assert.equal(values.get('clipboardActionDirectAction'), '');
});

test('completed Text synchronization exits its host without requiring a Close tap', () => {
  const h = actionPageFixture();
  // refresh reads the same service used by the compiled page. Inject completion through its fixture.
  h.complete(); h.page.refresh();
  assert.equal(h.calls.dismiss, 1); assert.equal(h.calls.terminate, 1);
});
