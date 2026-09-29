const test = require('node:test');
const assert = require('node:assert/strict');
const { DatabaseSync } = require('node:sqlite');
const { cacheFixture, load, record } = require('./cache-harness.cjs');

class Predicates {
  constructor(table) { this.table = table; this.filters = []; this.order = []; this.limit = -1; this.offset = 0; }
  equalTo(key, value) { this.filters.push([key, value]); return this; }
  orderByDesc(key) { this.order.push(key); return this; }
  limitAs(value) { this.limit = value; return this; }
  offsetAs(value) { this.offset = value; return this; }
  where() { return this.filters.length ? ` WHERE ${this.filters.map(([key]) => `${key}=?`).join(' AND ')}` : ''; }
  values() { return this.filters.map(([, value]) => value); }
}
function result(rows) {
  let i = -1;
  return { rowCount: rows.length, goToFirstRow() { i = 0; return !!rows[0]; },
    goToNextRow() { return ++i < rows.length; }, getColumnIndex: key => key,
    getLong: key => Number(rows[i][key]), getString: key => String(rows[i][key] ?? ''), close() {} };
}
function fixture(legacy = false) {
  const h = cacheFixture(); const db = new DatabaseSync(':memory:');
  const store = {
    async executeSql(sql) { db.exec(sql); },
    async querySql(sql) { return result(db.prepare(sql).all()); },
    async query(p, columns = ['*']) {
      const sql = `SELECT ${columns.join(',')} FROM ${p.table}${p.where()}` +
        (p.order.length ? ` ORDER BY ${p.order.map(k => `${k} DESC`).join(',')}` : '') +
        (p.limit >= 0 ? ` LIMIT ${p.limit} OFFSET ${p.offset}` : '');
      return result(db.prepare(sql).all(...p.values()));
    },
    async insert(table, row) {
      const keys = Object.keys(row);
      db.prepare(`INSERT OR REPLACE INTO ${table} (${keys.join(',')}) VALUES (${keys.map(() => '?').join(',')})`)
        .run(...keys.map(key => row[key]));
    },
    async delete(p) { db.prepare(`DELETE FROM ${p.table}${p.where()}`).run(...p.values()); },
    async update(row, p) { const keys = Object.keys(row);
      db.prepare(`UPDATE ${p.table} SET ${keys.map(k => `${k}=?`).join(',')}${p.where()}`)
        .run(...keys.map(k => row[k]), ...p.values()); },
  };
  if (legacy) db.exec(`CREATE TABLE history (profileHash TEXT PRIMARY KEY,type TEXT,text TEXT,createTime TEXT,
    lastModified TEXT,lastAccessed TEXT,starred INTEGER,pinned INTEGER,size INTEGER,hasData INTEGER,version INTEGER,isDeleted INTEGER)`);
  const { HistoryStorageService } = load('services/HistoryStorageService.ets', {
    ConfigService: h.mocks.ConfigService, AppStorage: h.AppStorage, RecordCacheService: h.RecordCacheService,
    relationalStore: { RdbPredicates: Predicates, SecurityLevel: { S1: 1 },
      ConflictResolution: { ON_CONFLICT_REPLACE: 1 }, getRdbStore: async () => store },
  });
  return { ...h, db, store, storage: HistoryStorageService.getInstance() };
}

test('local count is per account and late history responses cannot restore an account after deletion', async () => {
  const h = fixture();
  await h.storage.upsertRecord(record('1'), 'A'); await h.storage.upsertRecord(record('2'), 'A');
  await h.storage.upsertRecord(record('3'), 'B');
  assert.equal(await h.storage.countRecords('A'), 2); assert.equal(await h.storage.countRecords('B'), 1);
  assert.equal(await h.storage.countRecords(''), 0);
  h.config.servers = h.config.servers.filter(a => a.id !== 'A');
  await Promise.all([h.storage.clearAll('A'), h.storage.upsertRecord(record('LATE'), 'A')]);
  assert.equal(await h.storage.countRecords('A'), 0); assert.equal(await h.storage.countRecords('B'), 1);
  h.db.close();
});

test('history limit is per account, includes stars, prunes both tiers, and blocks old pagination rows', async () => {
  const h = fixture(); h.config.maxHistorySize = 3;
  for (let i = 0; i < 5; i++) {
    const item = { ...record(String(i), 'File', (i + 1) * 1000), starred: i === 0 };
    await h.storage.upsertRecord(item, 'A');
    if (i === 0) { const lease = await h.cache.acquire(item, 'A', h.service); lease.release(); }
  }
  await h.storage.upsertRecord(record('B', 'File', 1000), 'B');
  assert.deepEqual(Array.from(await h.storage.queryRecords(100, 0, 'A'), r => r.hash), ['4', '3', '2']);
  assert.equal((await h.storage.queryRecords(100, 0, 'B')).length, 1);
  assert.equal((await h.storage.queryRecords(30, 3, 'A')).length, 0);
  assert.equal(h.payloads().length, 0);
  await h.storage.upsertRecord(record('0', 'File', 1000), 'A');
  assert.equal((await h.storage.queryRecords(100, 0, 'A')).length, 3);
  await assert.rejects(h.cache.acquire(record('0'), 'A', h.service), /history limit/);
  h.config.maxHistorySize = 4;
  await h.storage.upsertRecord(record('0', 'File', 1000), 'A');
  assert.equal((await h.storage.queryRecords(100, 0, 'A')).length, 4);
  const lease = await h.cache.acquire(record('0'), 'A', h.service); lease.release();
  h.db.close();
});

test('database keeps excerpts while full UTF-8 text lives in the pool, including offline reuse', async () => {
  const h = fixture(); const text = '完整正文中文'.repeat(1000);
  const item = { ...record('TEXT', 'Text', 1000), text };
  await h.storage.upsertRecord(item, 'A');
  const [local] = await h.storage.queryRecords(1, 0, 'A');
  assert.equal(local.text.length, 1024); assert.equal(local.textComplete, false);
  const lease = await h.cache.acquire(local, 'A', {});
  assert.equal(h.disk.readTextSync(lease.response.path), text); lease.release();
  await h.storage.upsertRecord({ ...record('DATA', 'Text', 2000), hasData: true, text: '摘要' }, 'A');
  assert.equal(h.calls.length, 0, 'refreshing data-backed historical text never downloads its body');
  h.db.close();
});

test('legacy global history table migrates full text safely before storing a short excerpt', async () => {
  const h = fixture(true); h.config.servers.push({ id: 'original', url: 'legacy' });
  const text = '旧版完整内容'.repeat(1000);
  h.db.prepare('INSERT INTO history (profileHash,type,text,lastAccessed,hasData,isDeleted) VALUES (?,?,?,?,?,?)')
    .run('Text-LEGACY', 'Text', text, '2026-09-27T01:00:00Z', 0, 0);
  await h.storage.init();
  const [item] = await h.storage.queryRecords(1, 0, 'original');
  assert.equal(item.text.length, 1024); assert.equal(item.textComplete, false);
  const lease = await h.cache.acquire(item, 'original', {});
  assert.equal(h.disk.readTextSync(lease.response.path), text); lease.release();
  assert.equal(h.db.prepare("SELECT COUNT(*) AS n FROM sqlite_master WHERE name='history'").get().n, 0);
  h.db.close();
});

test('existing multi-account schema gains completeness column and preserves inline bodies', async () => {
  const h = fixture();
  h.db.exec(`CREATE TABLE history_by_server (serverId TEXT, profileHash TEXT,type TEXT,text TEXT,createTime TEXT,
    lastModified TEXT,lastAccessed TEXT,starred INTEGER,pinned INTEGER,size INTEGER,hasData INTEGER,
    version INTEGER,isDeleted INTEGER,PRIMARY KEY(serverId,profileHash))`);
  h.db.prepare('INSERT INTO history_by_server (serverId,profileHash,type,text,lastAccessed,hasData,isDeleted) VALUES (?,?,?,?,?,?,?)')
    .run('A', 'Text-EXISTING', 'Text', '已有完整正文', '2026-09-27T01:00:00Z', 0, 0);
  await h.storage.init(); const [item] = await h.storage.queryRecords(1, 0, 'A');
  assert.equal(item.textComplete, false);
  const lease = await h.cache.acquire(item, 'A', {});
  assert.equal(h.disk.readTextSync(lease.response.path), '已有完整正文'); lease.release();
  h.db.close();
});

test('lowering history limit cleans immediately; clearing one account leaves the other intact', async () => {
  const h = fixture(); h.config.maxHistorySize = 5;
  for (let i = 0; i < 5; i++) await h.storage.upsertRecord(record(String(i), 'Text', i * 1000), 'A');
  await h.storage.upsertRecord(record('B', 'Text', 1000), 'B');
  h.config.maxHistorySize = 2; await h.storage.applyLimits();
  assert.equal((await h.storage.queryRecords(10, 0, 'A')).length, 2);
  assert.equal(h.payloads().length, 3);
  await h.storage.clearAll('A'); assert.equal(h.payloads().length, 1);
  assert.equal((await h.storage.queryRecords(10, 0, 'B')).length, 1); h.db.close();
});

test('deleted server history removes its local body and is never returned as an active record', async () => {
  const h = fixture(); const item = record('DEL', 'Text', 1000);
  await h.storage.upsertRecord(item, 'A'); assert.equal(h.payloads().length, 1);
  await h.storage.upsertRecord({ ...item, isDeleted: true }, 'A');
  assert.equal(h.payloads().length, 0); assert.equal((await h.storage.queryRecords(10, 0, 'A')).length, 0);
  h.db.close();
});
