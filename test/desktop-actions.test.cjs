const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(path.join(process.env.DEVECO_SDK_HOME, 'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets');
function load(file, mocks, transform = source => source) {
  const source = transform(fs.readFileSync(path.join(root, file), 'utf8')).replace(/^import .*;\r?\n/gm, '');
  const compiled = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText;
  const sandbox = { exports: {}, console: { error() {} }, Date, Math, Error, ...mocks };
  vm.runInNewContext(compiled, sandbox, { filename: file }); return sandbox.exports;
}
const flush = () => new Promise(resolve => setImmediate(resolve));
function actions() {
  const values = new Map();
  const { DesktopActionService } = load('services/DesktopActionService.ets', {
    AppStorage: { get: key => values.get(key), setOrCreate: (key, value) => values.set(key, value) },
  });
  return { service: DesktopActionService, values };
}

test('cold shortcut waits for config, foreground and home, then runs exactly once', async () => {
  const { service, values } = actions(); const seen = [];
  service.accept('sync', '', '', 'launch-1');
  assert.equal(values.get('desktopActionRevision'), 1);
  service.attach(async request => seen.push(request.action)); await flush(); assert.deepEqual(seen, []);
  service.configure(); await flush(); assert.deepEqual(seen, []);
  service.setForeground(true); await flush(); assert.deepEqual(seen, ['sync']);
  service.accept('sync', '', '', 'launch-1'); await flush(); assert.deepEqual(seen, ['sync']);
});

test('rapid taps are coalesced during execution and a failed action does not poison later actions', async () => {
  const { service } = actions(); const seen = []; let finish;
  service.configure(); service.setForeground(true);
  service.attach(request => { seen.push(request.id); return new Promise((resolve, reject) => { finish = () => reject(new Error('network')); }); });
  service.accept('upload', '', '', 'first'); service.accept('upload', '', '', 'second');
  assert.deepEqual(seen, ['first']); finish(); await flush();
  service.attach(async request => seen.push(request.id)); service.accept('sync', '', '', 'third'); await flush();
  assert.deepEqual(seen, ['first', 'third']);
});

test('unknown launch parameters do nothing and background requests wait for foreground', async () => {
  const { service } = actions(); const seen = [];
  service.configure(); service.attach(async request => seen.push(request));
  service.accept('deleteAccount'); service.accept('showLocal', 'form', 'read-token', 'read');
  await flush(); assert.equal(seen.length, 0);
  service.setForeground(true); await flush();
  assert.equal(seen.length, 1); assert.equal(seen[0].formId, 'form'); assert.equal(seen[0].token, 'read-token');
});

function widgets(clock = Date) {
  const updates = []; let readError; let remoteError; let clipboardReads = 0; let profileReads = 0; let pendingRead;
  const account = { id: 'A', url: 'https://a.invalid', username: 'user', password: 'secret' };
  const config = { language: 'en-US', theme: 'auto', preferPureBlackInDark: false };
  let current = account;
  let data = { getRecordCount: () => 1, getPrimaryMimeType: () => 'text/plain', getPrimaryText: () => 'fresh local text' };
  const profiles = { type: 'File', dataName: 'report.pdf', hasData: true };
  class HttpClient {
    setTimeout() {}
    async get(route) { assert.equal(route, '/SyncClipboard.json'); profileReads++; if (remoteError) throw new Error(remoteError); return profiles; }
  }
  const { ClipboardWidgetService } = load('services/ClipboardWidgetService.ets', {
    Date: clock,
    formProvider: {
      getPublishedRunningFormInfos: async () => [{ formId: 'F', formName: 'ClipboardActions', dimension: 3 }],
      getPublishedRunningFormInfoById: async id => ({ formId: id, formName: 'ClipboardActions', dimension: 3 }),
      async updateForm(id, data) { updates.push({ id, data: JSON.parse(JSON.stringify(data)) }); },
    },
    formBindingData: { createFormBindingData: data => data },
    ConfigService: { getInstance: () => ({ getConfig: () => config, getActiveServer: () => current, setContext() {} }) },
    ClipboardUtil: { ensureReadPermission: async () => true },
    LocalizationUtil: { systemLanguage: () => 'en-US', text: text => text }, HttpClient,
    pasteboard: {
      MIMETYPE_TEXT_PLAIN: 'text/plain', MIMETYPE_PIXELMAP: 'image/pixelmap', MIMETYPE_TEXT_URI: 'text/uri',
      getSystemPasteboard: () => ({ getChangeCount: () => 1,
        async getData() { clipboardReads++; if (pendingRead) await pendingRead;
          if (readError) throw new Error(readError); return data; },
      }),
    },
  });
  const service = ClipboardWidgetService;
  return { service, updates, config, account,
    failRead: value => { readError = value; }, failRemote: value => { remoteError = value; },
    setData: value => { data = value; }, switchAccount: () => { current = { ...account, id: 'B' }; },
    waitRead: promise => { pendingRead = promise; },
    counts: () => ({ clipboardReads, profileReads }), last: () => updates.at(-1).data,
  };
}

test('cards start hidden, read latest on reveal and remove every content field on hide', async () => {
  const h = widgets(); const initial = h.service.add('F');
  assert.equal(initial.localVisible, false); assert.equal(initial.remoteContent, '');
  await h.service.toggle('F', 'local'); assert.equal(h.last().localContent, 'fresh local text');
  assert.match(h.last().localTime, /Updated/);
  await h.service.toggle('F', 'local', true);
  assert.equal(h.last().localVisible, false); assert.equal(h.last().localContent, ''); assert.equal(h.last().localTime, '');
  assert.equal(h.counts().clipboardReads, 1);
  assert.ok(!JSON.stringify(h.updates).includes('secret'));
});

test('permission failure requests foreground once and foreground read updates the same card', async () => {
  const h = widgets(); h.failRead('Clipboard permission denied'); h.service.add('F');
  await h.service.toggle('F', 'local'); const token = h.last().fallbackToken;
  assert.equal(h.last().fallbackSide, 'local'); assert.ok(token);
  h.failRead(); await h.service.revealInApp('F', 'local', token);
  assert.equal(h.last().localContent, 'fresh local text'); assert.equal(h.last().fallbackToken, '');
});

test('server reveal requests only the current profile and never downloads attachment data', async () => {
  const h = widgets(); h.service.add('F'); await h.service.toggle('F', 'remote');
  assert.equal(h.last().remoteContent, 'File · report.pdf');
  assert.deepEqual(h.counts(), { clipboardReads: 0, profileReads: 1 });
});

test('hiding while a read is pending suppresses the late payload', async () => {
  const h = widgets(); let release; h.waitRead(new Promise(resolve => { release = resolve; }));
  h.service.add('F'); const read = h.service.toggle('F', 'local'); await flush();
  await h.service.toggle('F', 'local', true); release(); await read;
  assert.equal(h.last().localVisible, false); assert.equal(h.last().localContent, '');
});

test('reset or account change suppresses late reads and clears both displayed areas', async () => {
  for (const reset of [true, false]) {
    const h = widgets(); let release; h.waitRead(new Promise(resolve => { release = resolve; }));
    h.service.add('F'); const read = h.service.toggle('F', 'local'); await flush();
    if (reset) await h.service.resetAll(); else { h.switchAccount(); await h.service.resetAll(); }
    release(); await read;
    assert.equal(h.last().localVisible, false); assert.equal(h.last().localContent, '');
    assert.equal(h.last().remoteVisible, false); assert.equal(h.last().remoteContent, '');
  }
});

test('foreground retry can recover after provider recreation, but cannot revive a user-hidden request', async () => {
  const h = widgets(); h.service.add('F');
  await h.service.revealInApp('F', 'local', 'cold-token'); assert.equal(h.last().localContent, 'fresh local text');
  const token = h.last().localToken; await h.service.toggle('F', 'local', true);
  await h.service.revealInApp('F', 'local', token); assert.equal(h.last().localContent, '');
});

test('failed fresh server read clears old text and uses no old timestamp', async () => {
  const h = widgets(); h.service.add('F'); await h.service.toggle('F', 'remote');
  await h.service.toggle('F', 'remote', true); h.failRemote('Network failed');
  await h.service.toggle('F', 'remote'); assert.equal(h.last().remoteContent, 'Network failed');
  assert.equal(h.last().remoteTime, ''); assert.equal(h.last().fallbackSide, '');
  assert.equal(h.last().fallbackToken, '');
});


test('account reset rejects an earlier foreground read request, but startup preserves the active launch token', async () => {
  const h = widgets(); h.failRead('Clipboard permission denied'); h.service.add('F');
  await h.service.toggle('F', 'local'); const oldToken = h.last().fallbackToken;
  await h.service.resetAll(); h.failRead();
  await assert.rejects(h.service.revealInApp('F', 'local', oldToken), /Server changed/);
  assert.equal(h.last().localContent, '');
  h.failRead('Clipboard permission denied'); await h.service.toggle('F', 'local');
  const currentToken = h.last().fallbackToken;
  await h.service.resetAll(undefined, currentToken); h.failRead();
  await h.service.revealInApp('F', 'local', currentToken);
  assert.equal(h.last().localContent, 'fresh local text');
});

test('an account change can cancel a launch waiting for UI initialization', async () => {
  const { service } = actions(); const seen = [];
  service.accept('upload'); service.cancelPending(); service.configure(); service.setForeground(true);
  service.attach(async request => seen.push(request)); await flush(); assert.equal(seen.length, 0);
});


test('binding data includes the host form ID and retains dimension through updates and account resets', async () => {
  const h = widgets(); const first = h.service.add('F', 3);
  assert.equal(first.formId, 'F'); assert.equal(first.formDimension, 3);
  await h.service.actionStatus('F', 'Working...');
  assert.equal(h.last().formId, 'F'); assert.equal(h.last().formDimension, 3);
  await h.service.resetAll();
  assert.equal(h.last().formId, 'F'); assert.equal(h.last().formDimension, 3);
  assert.equal(h.last().localVisible, false);
});

test('a cold backend form lookup restores both ID and host dimension before publishing task status', async () => {
  const h = widgets(); await h.service.validateForm('F'); await h.service.actionStatus('F', 'Working...');
  assert.equal(h.last().formId, 'F'); assert.equal(h.last().formDimension, 3);
});

test('form creation supplies identity to the actual callee for all three dimensions', async () => {
  for (const dimension of [1, 2, 3]) {
    const h = widgets(); const updates = []; const id = '12400633174999288';
    const config = { setContext() {}, loadConfig: async () => {}, getConfig: () => h.config };
    class FormExtensionAbility { context = {}; }
    const { default: Form } = load('entryability/ClipboardFormAbility.ets', { FormExtensionAbility,
      ConfigService: { getInstance: () => config }, ClipboardWidgetService: h.service,
      formInfo: { FormParam: { IDENTITY_KEY: 'ohos.extra.param.key.form_identity', DIMENSION_KEY: 'ohos.extra.param.key.form_dimension' } },
      formBindingData: { createFormBindingData: data => data },
      formProvider: { getPublishedRunningFormInfoById: async () => ({ formId: id, dimension }),
        updateForm: async (formId, data) => updates.push({ formId, data }) },
      LocalizationUtil: { text: value => value, systemLanguage: () => 'en-US' },
    });
    const provider = new Form(); const data = provider.onAddForm({ parameters: {
      'ohos.extra.param.key.form_identity': id, 'ohos.extra.param.key.form_dimension': dimension,
    } });
    assert.equal(data.formId, id); assert.equal(data.formDimension, dimension);
    await flush(); assert.equal(updates.at(-1).data.formId, id); assert.equal(updates.at(-1).data.formDimension, dimension);
    let handler; const accepted = [];
    class UIAbility { context = { abilityInfo: { bundleName: 'app' } };
      callee = { on(method, fn) { handler = fn; }, off() {} }; }
    const { default: ActionAbility } = load('entryability/ClipboardActionAbility.ets', { UIAbility,
      ClipboardBackgroundActionService: { getInstance: () => ({ bind() {}, accept: async request => accepted.push(request) }) } });
    new ActionAbility().onCreate({ parameters: {} }, {});
    handler({ readString: () => JSON.stringify({ formId: data.formId, requestId: 'tap', desktopAction: 'sync' }) });
    assert.equal(accepted.length, 1); assert.equal(accepted[0].formId, id); assert.equal(accepted[0].action, 'sync');
  }
});

test('an old card can repair missing binding data using the host ID from a message event', async () => {
  const h = widgets(); const updates = []; const id = '12400633174999288';
  class FormExtensionAbility { context = {}; }
  const { default: Form } = load('entryability/ClipboardFormAbility.ets', { FormExtensionAbility,
    ClipboardWidgetService: h.service,
    ConfigService: { getInstance: () => ({ setContext() {}, loadConfig: async () => {}, getConfig: () => h.config }) },
    formProvider: { getPublishedRunningFormInfoById: async () => ({ formId: id, dimension: 3 }),
      updateForm: async (formId, data) => updates.push({ formId, data }) },
    formBindingData: { createFormBindingData: data => data },
    LocalizationUtil: { text: value => value, systemLanguage: () => 'en-US' },
  });
  new Form().onFormEvent(id, JSON.stringify({ refresh: true })); await flush();
  assert.equal(updates.length, 1); assert.equal(updates[0].data.formId, id);
  assert.equal(updates[0].data.formDimension, 3);
  assert.equal(updates[0].data.actionStatus, 'Widget refreshed. Tap again');
});


function card() {
  let now = 100000;
  const events = [];
  class Clock extends Date { static now() { return now; } }
  const { ClipboardCard } = load('widget/ClipboardCard.ets', {
    Date: Clock, postCardAction: (_, action) => events.push(action),
    TextTimerController: class { start() {} pause() {} },
  }, source => (source.split('  @Builder')[0] + '}')
    .replace(/@LocalStorageProp\('[^']+'\)\s*/g, '').replace(/@Watch\('[^']+'\)\s*/g, '')
    .replace(/@State\s*/g, '').replace('@Entry', '').replace('@Component', '')
    .replace('struct ClipboardCard', 'export class ClipboardCard'));
  const instance = new ClipboardCard(); instance.formId = 'F';
  return { instance, events, Clock, advance(ms) { now += ms; instance.expiryTick(); } };
}

test('a sync click uses a background call, and only its attachment result routes once', () => {
  const h = card(); h.instance.call('sync');
  assert.equal(h.events[0].action, 'call'); assert.equal(h.events[0].params.desktopAction, 'sync');
  const id = h.events[0].params.requestId;
  h.instance.openRequestId = 'old'; h.instance.openRequestUpdated(); assert.equal(h.events.length, 1);
  h.instance.openRequestId = id; h.instance.openRequestUpdated(); h.instance.openRequestUpdated();
  assert.equal(h.events.length, 2); assert.equal(h.events[1].action, 'router');
  assert.equal(h.events[1].params.requestId, id); assert.equal(h.events[1].params.desktopAction, undefined);
});

test('Text completion, expired results and an offscreen card do not open any window', () => {
  for (const outcome of ['text', 'expired', 'offscreen']) {
    const h = card(); h.instance.call('sync'); const id = h.events[0].params.requestId;
    if (outcome === 'expired') h.advance(30001);
    if (outcome === 'offscreen') h.instance.aboutToDisappear();
    h.instance.openRequestId = outcome === 'text' ? '' : id; h.instance.openRequestUpdated();
    assert.equal(h.events.length, 1);
  }
});

test('native card timer callbacks hide each content area after 20 seconds and send its token for payload cleanup', () => {
  const h = card(), c = h.instance;
  c.localToken = 'L'; c.localVisible = true; c.localExpiresAt = h.Clock.now() + 20000;
  c.visibilityUpdated(); h.advance(10000);
  c.remoteToken = 'R'; c.remoteVisible = true; c.remoteExpiresAt = h.Clock.now() + 20000;
  c.visibilityUpdated(); h.advance(9999); assert.equal(c.isShown(true), true);
  h.advance(1); assert.equal(c.isShown(true), false); assert.equal(c.isShown(false), true);
  assert.equal(h.events[0].params.token, 'L'); h.advance(10000);
  assert.equal(c.isShown(false), false); assert.equal(h.events[1].params.token, 'R');
  c.aboutToDisappear();
});

test('expiry removes plaintext and timestamps, and an earlier token cannot hide a newer read', async () => {
  const host = card(), h = widgets(host.Clock); h.service.add('F', 3);
  await h.service.toggle('F', 'local'); const token = h.last().localToken;
  assert.equal(h.last().localExpiresAt, host.Clock.now() + 20000);
  await h.service.hideExpired('F', 'local', token); assert.equal(h.last().localVisible, true);
  host.advance(20000); await h.service.hideExpired('F', 'local', token);
  assert.equal(h.last().localVisible, false); assert.equal(h.last().localContent, '');
  assert.equal(h.last().localTime, ''); assert.equal(h.last().localExpiresAt, 0);
  await h.service.toggle('F', 'local'); await h.service.hideExpired('F', 'local', token);
  assert.equal(h.last().localVisible, true); assert.equal(h.last().localContent, 'fresh local text');
});


test('rapid sync taps retain the first request; Text completion enables the next fresh click', () => {
  const h = card(); h.instance.call('sync'); h.instance.call('sync');
  assert.equal(h.events.length, 1);
  h.instance.completedRequestId = h.events[0].params.requestId; h.instance.requestCompleted();
  h.instance.call('sync'); assert.equal(h.events.length, 2); assert.equal(h.events[1].action, 'call');
});
