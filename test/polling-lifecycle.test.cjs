const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadPureArkts } = require('./helpers/load-pure-arkts.cjs');

function fixture() {
  const timers = new Map();
  let nextId = 0;
  const errors = [];
  const Controller = loadPureArkts(
    'entry/src/main/ets/services/PollingController.ets', 'PollingController', {
      setInterval(callback) { timers.set(++nextId, callback); return nextId; },
      clearInterval(id) { timers.delete(id); },
      console: { info() {}, error(...args) { errors.push(args); } }
    }
  );
  return {
    Controller, timers, errors,
    async tick() { await Promise.all([...timers.values()].map(fn => fn())); }
  };
}

test('background pause and foreground resume preserve enabled intent', async () => {
  const f = fixture(); const c = new f.Controller(); let calls = 0;
  c.start(5, () => { calls++; });
  f.Controller.pauseAll();
  assert.equal(c.getIsRunning(), false);
  assert.equal(f.timers.size, 0);
  await f.tick(); assert.equal(calls, 0);
  f.Controller.resumeAll();
  await f.tick(); assert.equal(calls, 1);
  assert.equal(c.getIsRunning(), true);
});

test('foreground does not enable an inactive controller', async () => {
  const f = fixture(); const c = new f.Controller();
  f.Controller.pauseAll(); f.Controller.resumeAll();
  assert.equal(c.getIsRunning(), false);
  assert.equal(f.timers.size, 0);
});

test('explicit stop while paused cancels resume', () => {
  const f = fixture(); const c = new f.Controller();
  c.start(5, () => {}); f.Controller.pauseAll(); c.stop();
  f.Controller.resumeAll();
  assert.equal(c.getIsRunning(), false);
  assert.equal(f.timers.size, 0);
});

test('repeated lifecycle events keep one timer', () => {
  const f = fixture(); const c = new f.Controller();
  c.start(5, () => {});
  f.Controller.pauseAll(); f.Controller.pauseAll();
  f.Controller.resumeAll(); f.Controller.resumeAll();
  assert.equal(f.timers.size, 1);
});

test('an unfinished callback cannot overlap with a resumed tick', async () => {
  const f = fixture(); const c = new f.Controller();
  let calls = 0; let release;
  c.start(5, () => {
    calls++;
    return new Promise(resolve => { release = resolve; });
  });
  const first = f.tick(); assert.equal(calls, 1);
  f.Controller.pauseAll(); f.Controller.resumeAll();
  await f.tick(); assert.equal(calls, 1);
  release(); await first;
  const second = f.tick(); assert.equal(calls, 2);
  release(); await second;
});

test('callback rejection releases the guard for later ticks', async () => {
  const f = fixture(); const c = new f.Controller(); let calls = 0;
  c.start(5, () => { calls++; throw new Error('fixture failure'); });
  await f.tick(); await f.tick();
  assert.equal(calls, 2); assert.equal(f.errors.length, 2);
});

test('disposed instances are not resumed', () => {
  const f = fixture(); const c = new f.Controller();
  c.start(5, () => {}); f.Controller.pauseAll(); c.dispose();
  f.Controller.resumeAll();
  assert.equal(f.timers.size, 0);
});

test('ability lifecycle connects pause and resume without stopAll', () => {
  const source = fs.readFileSync(path.join(__dirname,
    '../entry/src/main/ets/entryability/EntryAbility.ets'), 'utf8');
  const foreground = source.match(/onForeground\(\): void \{([\s\S]*?)\n  \}/)[1];
  const background = source.match(/onBackground\(\): void \{([\s\S]*?)\n  \}/)[1];
  assert.match(foreground, /PollingController\.resumeAll\(\)/);
  assert.match(background, /PollingController\.pauseAll\(\)/);
  assert.doesNotMatch(background, /PollingController\.stopAll\(\)/);
});
