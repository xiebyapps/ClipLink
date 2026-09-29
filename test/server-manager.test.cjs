const test = require('node:test');
const assert = require('node:assert/strict');
const { load } = require('./cache-harness.cjs');

function fixture(probe) {
  const config = { activeServerId: 'A', servers: ['A','B','C'].map(id => ({ id, name: id, url: id,
    username: 'user', password: 'pass', lastConnectedAt: 0 })) };
  const runtime = new Map(); const calls = [];
  const settings = { loadConfig: async () => config, getConfig: () => config,
    switchServer: async id => { calls.push(['switch',id]); config.activeServerId = id; },
    markConnected: async id => { calls.push(['connected',id]); } };
  const { ServerManager } = load('services/ServerManager.ets', {
    ConfigService: { getInstance: () => settings },
    AppStorage: { get: k => runtime.get(k), setOrCreate: (k,v) => runtime.set(k,v) }, connection: {},
    SyncClipboardService: class { constructor(url,user,pass) { this.url = url; this.user = user; this.pass = pass; }
      async probe() { calls.push(['probe',this.url,this.user,this.pass]); if (probe) await probe(this.url); } } });
  return { manager: ServerManager.getInstance(), config, runtime, calls };
}

test('health authenticates every account, successful test does not select, and failed switch preserves active server', async () => {
  const h = fixture(async url => { if (url === 'C') throw new Error('HTTP 401'); });
  await h.manager.refreshHealth();
  assert.equal(h.manager.isOnline('A'), true); assert.equal(h.manager.isOnline('B'), true); assert.equal(h.manager.isOnline('C'), false);
  h.manager.recordTest(h.config.servers[1], true); assert.equal(h.config.activeServerId, 'A');
  await assert.rejects(h.manager.select('C'), /unavailable/); assert.equal(h.config.activeServerId, 'A');
  await h.manager.select('B'); assert.equal(h.config.activeServerId, 'B'); assert.equal(h.runtime.get('serverConnectionStatus'), 'connected');
  assert.deepEqual(h.calls.find(c => c[0] === 'probe'), ['probe','A','user','pass']);
});

test('out-of-order selection cannot commit stale account and changed credentials invalidate health', async () => {
  let release;
  const h = fixture(url => url === 'B' ? new Promise(resolve => { release = resolve; }) : Promise.resolve());
  const old = h.manager.select('B'); const rejected = assert.rejects(old, /changed/);
  await new Promise(resolve => setImmediate(resolve));
  await h.manager.select('C'); release(); await rejected;
  assert.equal(h.config.activeServerId, 'C'); assert.equal(h.calls.filter(c => c[0] === 'switch').length, 1);
  h.config.servers[2] = { ...h.config.servers[2], password: 'new' };
  assert.equal(h.manager.isOnline('C'), false);
});

test('editing or deleting account suppresses late probes and selection; empty accounts make no network request', async () => {
  let finish;
  const h = fixture(url => url === 'B' ? new Promise(resolve => { finish = resolve; }) : Promise.resolve());
  const pending = h.manager.select('B'); const rejected = assert.rejects(pending, /changed/);
  await new Promise(resolve => setImmediate(resolve));
  h.manager.invalidate('B'); h.config.servers = h.config.servers.filter(a => a.id !== 'B'); finish(); await rejected;
  assert.equal(h.manager.isOnline('B'), false); assert.equal(h.config.activeServerId, 'A');
  h.config.servers = []; h.config.activeServerId = ''; h.calls.length = 0;
  assert.equal(await h.manager.ensureAvailable(), null); assert.equal(h.calls.length, 0);
  assert.equal(h.runtime.get('serverConnectionStatus'), 'unconfigured');
});

test('automatic failover prefers current available server and respects ambiguous-sync pause', async () => {
  const h = fixture(async url => { if (url === 'A') throw new Error('offline'); });
  assert.equal(await h.manager.ensureAvailable(), 'B');
  h.runtime.set('syncPausedReason','ambiguous'); h.calls.length = 0;
  assert.equal(await h.manager.ensureAvailable(), null); assert.equal(h.calls.length, 0);
});
