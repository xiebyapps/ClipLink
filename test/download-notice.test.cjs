const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(path.join(process.env.DEVECO_SDK_HOME,
  'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));

function harness() {
  const values = new Map();
  const timers = new Map();
  let now = 1000; let timerId = 0;
  const source = fs.readFileSync(path.resolve(__dirname,
    '../entry/src/main/ets/services/DownloadNoticeService.ets'), 'utf8');
  const compiled = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS },
  }).outputText;
  const sandbox = { exports: {}, AppStorage: { get: k => values.get(k), setOrCreate: (k, v) => values.set(k, v) },
    Date: { now: () => now },
    setTimeout: (callback, delay) => { timers.set(++timerId, { callback, due: now + delay, delay }); return timerId; },
    clearTimeout: id => timers.delete(id) };
  vm.runInNewContext(compiled, sandbox);
  return { service: sandbox.exports.DownloadNoticeService, timers,
    advance(ms) {
      now += ms;
      for (const [id, timer] of timers) if (timer.due <= now) { timers.delete(id); timer.callback(); }
    } };
}

test('download stays resident, reports bytes and speed, and closes exactly two seconds after finish', () => {
  const h = harness();
  const id = h.service.begin('music.mp3', 10000);
  h.advance(10000);
  assert.equal(h.service.snapshot().visible, true);
  assert.equal(h.timers.size, 0, 'no timeout while downloading');
  h.service.progress(id, 5000, 10000);
  assert.equal(h.service.snapshot().received, 5000);
  assert.equal(h.service.snapshot().speed, 500);
  h.service.status(id, 'Saving...');
  h.advance(5000);
  assert.equal(h.service.snapshot().visible, true);
  h.service.progress(id, 10000, 10000);
  h.service.finish(id, 'Saved to selected folder');
  assert.equal(h.service.snapshot().finished, true);
  assert.equal([...h.timers.values()][0].delay, 2000);
  h.advance(1999); assert.equal(h.service.snapshot().visible, true);
  h.advance(1); assert.equal(h.service.snapshot().visible, false);
});

test('starting a new transfer invalidates the previous completion timer', () => {
  const h = harness();
  const first = h.service.begin('one.pdf');
  h.service.finish(first);
  const oldTimer = [...h.timers.values()][0].callback;
  h.advance(1000);
  const second = h.service.begin('two.pdf');
  oldTimer();
  h.advance(5000);
  assert.equal(h.service.snapshot().name, 'two.pdf');
  assert.equal(h.service.snapshot().visible, true);
  assert.equal(h.service.snapshot().finished, false);
  h.service.finish(second); h.advance(2000);
  assert.equal(h.service.snapshot().visible, false);
});

test('completion of one concurrent download cannot hide another active transfer', () => {
  const h = harness();
  const first = h.service.begin('one.zip');
  const second = h.service.begin('two.zip');
  h.service.finish(second);
  assert.equal(h.service.snapshot().name, 'one.zip');
  assert.equal(h.timers.size, 0);
  h.advance(5000); assert.equal(h.service.snapshot().visible, true);
  h.service.finish(first); h.advance(2000);
  assert.equal(h.service.snapshot().visible, false);
});

test('failed and canceled downloads close after feedback; late events cannot resurrect them', () => {
  for (const status of ['Download failed', 'Download canceled']) {
    const h = harness();
    const id = h.service.begin('unknown.bin');
    h.service.finish(id, status, status === 'Download failed');
    assert.equal(h.service.snapshot().status, status);
    h.advance(2000);
    h.service.progress(id, 100, 100); h.service.finish(id);
    assert.equal(h.service.snapshot().visible, false);
    assert.equal(h.timers.size, 0);
  }
});
