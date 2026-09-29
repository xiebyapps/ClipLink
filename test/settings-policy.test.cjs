const test = require('node:test');
const assert = require('node:assert/strict');
const { load } = require('./cache-harness.cjs');
const { SettingsPolicy } = load('utils/SettingsPolicy.ets');

test('numeric inputs accept arbitrary in-range integers and one decimal, with stable increments and boundaries', () => {
  for (const [key, valid, low, high] of [['polling', '17', 10, 7200], ['threshold', '237', 20, 1000],
    ['history', '123', 50, 1000], ['capacity', '2.3', 0.5, 10]]) {
    assert.equal(SettingsPolicy.parse(key, valid), Number(valid));
    assert.equal(SettingsPolicy.adjust(key, low, -1), low);
    assert.equal(SettingsPolicy.adjust(key, high, 1), high);
    for (const invalid of ['', 'NaN', 'Infinity', String(low - 0.1), String(high + 1), '2e2', '-10']) {
      assert.throws(() => SettingsPolicy.parse(key, invalid));
    }
  }
  assert.throws(() => SettingsPolicy.parse('polling', '10.5'));
  assert.throws(() => SettingsPolicy.parse('capacity', '2.35'));
  let value = 0.5;
  for (let i = 0; i < 95; i++) value = SettingsPolicy.adjust('capacity', value, 1);
  assert.equal(value, 10);
  assert.equal(SettingsPolicy.normalize('polling', 5, 10), 10);
});

test('classification rules are editable, normalize extensions, reject duplicates and prevent path traversal', () => {
  const rules = SettingsPolicy.validateRules([{ id: 'custom', folder: 'txtfiles', extensions: ['.MD', ' TXT '] }]);
  assert.equal(SettingsPolicy.folderFor('note.Md', rules), 'txtfiles');
  assert.equal(SettingsPolicy.folderFor('archive.tar.gz', rules), 'Other');
  assert.equal(SettingsPolicy.folderFor('noextension', rules), 'Other');
  assert.equal(SettingsPolicy.folderFor('test.mp3', SettingsPolicy.defaultRules()), 'Sounds');
  for (const folder of ['../outside', 'a/b', 'a\\b', '..', '云剪', 'name.', ' name', 'a:']) {
    assert.throws(() => SettingsPolicy.validateRules([{ id: '1', folder, extensions: ['md'] }]));
  }
  assert.throws(() => SettingsPolicy.validateRules([{ id: '1', folder: 'a', extensions: ['md'] },
    { id: '2', folder: 'b', extensions: ['.MD'] }]), /more than one/);
  assert.throws(() => SettingsPolicy.validateRules([{ id: '1', folder: 'a', extensions: [] }]));
});

function configFixture(saved = new Map()) {
  const runtime = new Map([['abilityContext', {}]]);
  const mocks = { SettingsPolicy, AppStorage: { get: k => runtime.get(k), setOrCreate: (k,v) => runtime.set(k,v), delete: k => runtime.delete(k) },
    dataPreferences: { getPreferences: async () => ({ get: async (k,d) => saved.has(k) ? saved.get(k) : d,
      put: async (k,v) => saved.set(k,v), flush: async () => {} }) } };
  const { ConfigService } = load('services/ConfigService.ets', mocks);
  return { saved, runtime, mocks, ConfigService, config: ConfigService.getInstance() };
}

test('legacy settings migrate into new ranges while preserving accounts, and an explicitly empty list remains empty', async () => {
  const h = configFixture(new Map([['server_url', 'https://legacy.invalid'], ['username', 'user'],
    ['polling_interval', 5], ['cache_capacity_gb', 20], ['history_size', 100]]));
  const config = await h.config.loadConfig();
  assert.equal(config.servers.length, 1); assert.equal(config.server.username, 'user');
  assert.equal(config.pollingInterval, 10); assert.equal(config.cacheCapacityGB, 10); assert.equal(config.smallFileThresholdMB, 500);
  await h.config.deleteServer('original');
  assert.equal(h.config.getActiveServer(), undefined); assert.equal(h.runtime.get('isPollingEnabled'), false);
  const restored = configFixture(h.saved); await restored.config.loadConfig();
  assert.equal(restored.config.getConfig().servers.length, 0); assert.equal(restored.config.getActiveServer(), undefined);
  const preferences = restored.config.copyConfig(); preferences.theme = 'dark'; preferences.pollingInterval = 7200;
  await restored.config.saveConfig(preferences);
  assert.equal(restored.config.getConfig().theme, 'dark', 'appearance works with no server');
});

test('saving a new server never selects it, numeric changes preserve rules and passwords, and deleted accounts do not return', async () => {
  const h = configFixture(); await h.config.loadConfig();
  await h.config.upsertServer({ id: 'A', name: 'one', type: 'syncclipboard', url: 'https://a.invalid', username: 'u', password: 'secret', lastConnectedAt: 0 });
  assert.equal(h.config.getActiveServer(), undefined);
  await h.config.switchServer('A');
  const next = h.config.copyConfig(); next.smallFileThresholdMB = 20; next.cacheCapacityGB = 0.7;
  next.downloadRules = [{ id: 'md', folder: 'txtfiles', extensions: ['md'] }]; await h.config.saveConfig(next);
  const restored = configFixture(h.saved); await restored.config.loadConfig();
  assert.equal(restored.config.getActiveServer().password, 'secret');
  assert.equal(restored.config.getConfig().cacheCapacityGB, 0.7);
  assert.equal(restored.config.getConfig().downloadRules[0].folder, 'txtfiles');
  const bad = restored.config.copyConfig(); bad.pollingInterval = 9;
  await assert.rejects(restored.config.saveConfig(bad));
  assert.equal(restored.config.getConfig().pollingInterval, 10);
});

test('concurrent connection timestamps and preference changes serialize without overwriting each other', async () => {
  const h = configFixture(); await h.config.loadConfig();
  await h.config.upsertServer({ id: 'A', name: 'one', type: 'syncclipboard', url: 'https://a.invalid', username: 'u', password: 'secret', lastConnectedAt: 0 });
  await h.config.switchServer('A');
  const revision = h.runtime.get('serverRevision');
  await h.config.switchServer('A'); assert.equal(h.runtime.get('serverRevision'), revision, 'same server does not reset sync baseline');
  await Promise.all([h.config.markConnected('A'), h.config.updateConfig(next => { next.pollingInterval = 123; }),
    h.config.updateConfig(next => { next.language = 'zh-CN'; next.smallFileThresholdMB = 20; })]);
  assert.equal(h.config.getConfig().pollingInterval, 123); assert.equal(h.config.getConfig().language, 'zh-CN');
  assert.equal(h.config.getConfig().smallFileThresholdMB, 20); assert.ok(h.config.getActiveServer().lastConnectedAt > 0);
  await Promise.all([h.config.deleteServer('A'), h.config.markConnected('A')]);
  assert.equal(h.config.getConfig().servers.length, 0, 'late timestamp cannot revive a deleted account');
});
