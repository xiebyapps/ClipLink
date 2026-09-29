const test = require('node:test');
const assert = require('node:assert/strict');
const { cacheFixture, record, load } = require('./cache-harness.cjs');
const MB = 1024 * 1024;
const GB = 1024 * MB;

test('threshold changes reclassify existing payloads using original completion time and update active lease deadlines', async () => {
  const h = cacheFixture({ size: 100 * MB });
  h.config.smallFileThresholdMB = 500;
  const lease = await h.cache.acquire(record('LIVE'), 'A', h.service);
  assert.equal(lease.expiresAt, 0);
  h.clock.now += 60 * 60 * 1000;
  h.config.smallFileThresholdMB = 20; h.cache.applyPolicy();
  assert.equal(lease.expiresAt, h.clock.now + 60 * 60 * 1000);
  assert.equal(h.runtime.get('largeCacheBytes'), 100 * MB);
  h.config.smallFileThresholdMB = 100; h.cache.applyPolicy();
  assert.equal(lease.expiresAt, 0); assert.equal(h.runtime.get('smallCacheBytes'), 100 * MB);
  h.clock.now += 2 * 60 * 60 * 1000;
  h.config.smallFileThresholdMB = 20; h.cache.applyPolicy();
  assert.equal(lease.isReusable(), false); assert.equal(h.disk.files.has(lease.response.path), true);
  lease.release(); assert.equal(h.disk.files.has(lease.response.path), false);
});

test('clear removes both account tiers, invalidates leases but protects readers and leaves saved files untouched', async () => {
  const h = cacheFixture({ size: 501 * MB });
  const big = await h.cache.acquire(record('BIG'), 'A', h.service);
  const small = await h.cache.acquire(record('TXT', 'Text'), 'B', h.service); small.release();
  h.disk.files.set('/public/export.mp3', 'copy');
  h.cache.clearAll();
  assert.equal(big.isReusable(), false); assert.equal(h.payloads().length, 1);
  assert.equal(h.runtime.get('smallCacheBytes'), 0);
  big.release(); assert.equal(h.payloads().length, 0);
  assert.equal(h.disk.files.get('/public/export.mp3'), 'copy');
  const renewed = await h.cache.acquire(record('TXT', 'Text'), 'B', h.service); renewed.release();
  assert.equal(h.payloads().length, 1, 'clear does not block history records from future use');
});

test('clear cancels inflight downloads and an ignored cancellation cannot publish a late cache entry', async () => {
  let finish, started;
  const ready = new Promise(resolve => { started = resolve; });
  const h = cacheFixture({ download: ({ target, disk }) => new Promise(resolve => {
    started(); finish = () => { disk.files.set(target, 'late'); resolve({ path: target, prefix: new ArrayBuffer(0) }); };
  }) });
  const request = h.cache.acquire(record('INFLIGHT'), 'A', h.service);
  const rejected = assert.rejects(request, /canceled/);
  await ready; h.cache.clearAll(); finish(); await rejected;
  assert.equal(h.payloads().length, 0);
});

test('completed payload survives release/restart, hits offline, and stays isolated by account', async () => {
  const h = cacheFixture(); const first = await h.cache.acquire(record('A'), 'A', h.service);
  const path = first.response.path; first.release(); first.release();
  const second = await h.cache.acquire(record('A'), 'A', { downloadHistoryFileToPath() { throw new Error('offline'); } });
  assert.equal(second.response.path, path); second.release(); assert.equal(h.calls.length, 1);
  const restored = h.restore(); const third = await restored.cache.acquire(record('A'), 'A', {});
  assert.equal(third.response.path, path); third.release();
  const other = await restored.cache.acquire(record('A'), 'B', restored.service);
  assert.notEqual(other.response.path, path); other.release(); assert.equal(restored.payloads().length, 2);
});

test('exactly 500MB belongs to the small pool; one byte more gets a fixed two-hour deadline', async () => {
  for (const size of [500 * MB, 500 * MB + 1]) {
    const h = cacheFixture({ size }); const item = record('BOUNDARY');
    const lease = await h.cache.acquire(item, 'A', h.service); const path = lease.response.path;
    lease.release();
    assert.equal(h.runtime.get(size <= 500 * MB ? 'smallCacheBytes' : 'largeCacheBytes'), size);
    h.clock.now += 60 * 60 * 1000;
    const again = await h.cache.acquire(item, 'A', h.service); again.release();
    h.clock.now += 60 * 60 * 1000; h.cache.enforceLimits();
    assert.equal(h.disk.files.has(path), size <= 500 * MB);
    assert.equal(h.calls.length, 1, 'using the file does not extend the large-file deadline');
  }
});

test('one cross-account pool evicts oldest history, not last opened; history card remains downloadable', async () => {
  const h = cacheFixture({ size: 500 * MB });
  const paths = [];
  for (let i = 0; i < 4; i++) {
    const lease = await h.cache.acquire(record(String(i), 'File', i * 1000), i % 2 ? 'B' : 'A', h.service);
    paths.push(lease.response.path); lease.release();
  }
  const oldest = await h.cache.acquire(record('0', 'File', 0), 'A', h.service); oldest.release();
  const added = await h.cache.acquire(record('4', 'File', 4000), 'A', h.service); added.release();
  assert.equal(h.disk.files.has(paths[0]), false); assert.equal(h.disk.files.has(paths[1]), true);
  assert.equal(h.runtime.get('smallCacheBytes'), 2000 * MB); assert.ok(h.runtime.get('smallCacheBytes') <= 2 * GB);
  const repeated = await h.cache.acquire(record('0', 'File', 0), 'A', h.service); repeated.release();
  assert.equal(h.calls.filter(c => c[1] === 'File-0').length, 2);
});

test('eviction and expiry invalidate reuse immediately but wait for readers before physical deletion', async () => {
  const h = cacheFixture({ size: 501 * MB });
  const lease = await h.cache.acquire(record('BIG'), 'A', h.service); const old = lease.response.path;
  h.clock.now += h.RecordCacheService.LARGE_TTL; h.cache.enforceLimits();
  assert.equal(lease.isReusable(), false); assert.equal(h.disk.files.has(old), true);
  const newer = await h.cache.acquire(record('BIG'), 'A', h.service);
  assert.notEqual(newer.response.path, old); newer.release();
  lease.release(); assert.equal(h.disk.files.has(old), false);
});

test('small text uses UTF-8 bytes, survives close, and truncated database text is never copied as full body', async () => {
  const h = cacheFixture(); const item = record('TEXT', 'Text');
  const lease = await h.cache.acquire(item, 'A', h.service);
  assert.equal(h.disk.readTextSync(lease.response.path), 'full正文');
  assert.equal(h.runtime.get('smallCacheBytes'), Buffer.byteLength('full正文')); lease.release();
  const missing = await h.cache.acquire({ ...item, hash: 'MISSING', text: 'summary', textComplete: false }, 'A', h.service);
  assert.equal(h.disk.readTextSync(missing.response.path), 'complete正文'); missing.release();
  assert.deepEqual(h.calls, [['metadata', 'Text-MISSING']]);
});

test('concurrent consumers share one download; canceling one leaves the other consumer running', async () => {
  let finish; let started;
  const ready = new Promise(r => { started = r; });
  const h = cacheFixture({ download: ({ target, disk, cancellation }) => new Promise((resolve, reject) => {
    started(); cancellation.subscribe(() => reject(new Error('Download canceled')));
    finish = () => { disk.files.set(target, 'done'); resolve({ path: target, size: 4, prefix: new ArrayBuffer(0) }); };
  }) });
  const token = new h.DownloadCancellation();
  const first = h.cache.acquire(record('ONE'), 'A', h.service, undefined, token);
  const canceled = assert.rejects(first, /canceled/);
  const second = h.cache.acquire(record('ONE'), 'A', h.service);
  await ready; token.cancel(); finish(); const lease = await second; await canceled;
  assert.equal(h.calls.length, 1); assert.equal(h.disk.readTextSync(lease.response.path), 'done'); lease.release();
});

test('network failure, disk failure and full cancellation never create usable cache entries', async () => {
  for (const kind of ['network', 'disk', 'cancel']) {
    let started; const ready = new Promise(r => { started = r; });
    const h = cacheFixture({ download: async ({ target, disk, cancellation }) => {
      disk.files.set(target, 'partial'); started();
      if (kind === 'cancel') await new Promise((_, reject) => cancellation.subscribe(() => reject(new Error('Download canceled'))));
      if (kind === 'network') throw new Error('network failed');
      return { path: target, size: 7, prefix: new ArrayBuffer(0) };
    } });
    if (kind === 'disk') {
      const rename = h.disk.renameSync;
      h.disk.renameSync = (a, b) => { if (a.endsWith('/download.part')) throw new Error('ENOSPC'); return rename(a, b); };
    }
    const token = new h.DownloadCancellation();
    const pending = h.cache.acquire(record('FAIL'), 'A', h.service, undefined, token);
    const rejected = assert.rejects(pending);
    await ready; if (kind === 'cancel') token.cancel(); await rejected;
    assert.equal(h.payloads().length, 0); assert.equal(h.runtime.get('smallCacheBytes'), 0);
  }
});

test('startup removes partial/orphan payloads and expires large files while preserving valid small files', async () => {
  const h = cacheFixture({ size: 501 * MB });
  const large = await h.cache.acquire(record('BIG'), 'A', h.service); large.release();
  h.disk.files.set('/files/record-cache/orphan', null);
  h.disk.files.set('/files/record-cache/orphan/download.part', 'partial');
  h.clock.now += h.RecordCacheService.LARGE_TTL;
  const restored = h.restore(); restored.cache.initialize();
  assert.equal(restored.payloads().length, 0); assert.equal(h.disk.files.has('/files/record-cache/orphan'), false);
  assert.equal(restored.runtime.get('largeCacheBytes'), 0);
});

test('history removal revokes both tiers; account removal cannot be undone by a late download', async () => {
  const h = cacheFixture(); const lease = await h.cache.acquire(record('OLD'), 'A', h.service);
  h.cache.removeRecords('A', ['File-OLD']); assert.equal(lease.isReusable(), false);
  assert.equal(h.disk.files.has(lease.response.path), true); lease.release();
  await assert.rejects(h.cache.acquire(record('OLD'), 'A', h.service), /history limit/);
  h.cache.allowRecord('A', record('OLD')); const restored = await h.cache.acquire(record('OLD'), 'A', h.service); restored.release();
  let finish, started; const ready = new Promise(r => { started = r; });
  const pendingFixture = cacheFixture({ download: ({ target, disk }) => new Promise(resolve => {
    started(); finish = () => { disk.files.set(target, 'done'); resolve({ path: target, size: 4, prefix: new ArrayBuffer(0) }); };
  }) });
  const pending = pendingFixture.cache.acquire(record('LATE'), 'A', pendingFixture.service);
  const rejected = assert.rejects(pending, /canceled/); await ready;
  pendingFixture.cache.removeAccount('A'); finish(); await rejected;
  assert.equal(pendingFixture.payloads().length, 0);
});

test('lower capacity cleans immediately and public saved copies stay untouched', async () => {
  const h = cacheFixture({ size: 400 * MB });
  for (let i = 0; i < 3; i++) { const lease = await h.cache.acquire(record(String(i), 'File', i * 1000), 'A', h.service); lease.release(); }
  h.disk.files.set('/Download/export.pdf', 'saved'); h.config.cacheCapacityGB = 0.5; h.cache.enforceLimits();
  assert.equal(h.payloads().length, 1); assert.equal(h.runtime.get('smallCacheBytes'), 400 * MB);
  assert.equal(h.disk.files.get('/Download/export.pdf'), 'saved');
});
