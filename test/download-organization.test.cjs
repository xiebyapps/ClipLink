const test = require('node:test');
const assert = require('node:assert/strict');
const { load, createDisk } = require('./cache-harness.cjs');
const { SettingsPolicy } = load('utils/SettingsPolicy.ets');

function fixture(options = {}) {
  const disk = options.disk || createDisk(); disk.files.set('/downloads', null);
  disk.lstatSync = path => { const stat = disk.statSync(path); return { ...stat, isFile: () => !stat.isDirectory() }; };
  disk.moveFile = async (a,b,mode) => {
    if (options.failMove) throw new Error('Permission denied');
    if (mode !== 1) throw new Error('must reject collisions');
    if (disk.files.has(b)) throw new Error('File exists');
    disk.renameSync(a,b);
    if (options.afterMove) options.afterMove(a,b);
  };
  const runtime = options.runtime || new Map();
  const config = options.config || { classifyDownloads: true, downloadRules: SettingsPolicy.defaultRules() };
  const service = { getConfig: () => config, copyConfig: () => ({ ...config, downloadRules: config.downloadRules.map(r => ({ ...r, extensions: [...r.extensions] })) }),
    saveConfig: async next => Object.assign(config, next),
    updateConfig: async update => { const next = service.copyConfig(); update(next); Object.assign(config, next); } };
  const mocks = { fs: disk, SettingsPolicy, ConfigService: { getInstance: () => service },
    AppStorage: { get: k => k === 'abilityContext' ? { filesDir: '/files' } : runtime.get(k), setOrCreate: (k,v) => runtime.set(k,v) },
    fileUri: { FileUri: class { constructor(uri) { this.path = uri; } } },
    picker: { DocumentSaveOptions: class {}, DocumentPickerMode: { DOWNLOAD: 1 },
      DocumentViewPicker: class { async save(options) { assert.equal(options.pickerMode, 1); return ['/downloads']; } } } };
  const { DownloadOrganizationService } = load('services/DownloadOrganizationService.ets', mocks);
  return { disk, config, runtime, manager: DownloadOrganizationService.getInstance(),
    restore: () => fixture({ disk, config, runtime }),
    put(p, data = 'content') { disk.files.set('/downloads/' + p, data); },
    get: p => disk.files.get('/downloads/' + p) };
}

test('legacy layer migrates to package root, keeps user directories, and disabling only flattens registered directories', async () => {
  const h = fixture();
  h.put('云剪', null); h.put('云剪/Documents', null); h.put('云剪/Documents/note.md', 'md');
  h.put('云剪/Sounds', null); h.put('云剪/Sounds/song.mp3', 'music'); h.put('云剪/unknown.bin', 'binary');
  h.put('云剪/personal', null); h.put('云剪/personal/keep.pdf', 'user');
  h.put('private-notes', null); h.put('private-notes/keep.md', 'other');
  await h.manager.resume();
  assert.equal(h.get('Documents/note.md'), 'md'); assert.equal(h.get('Sounds/song.mp3'), 'music');
  assert.equal(h.get('Other/unknown.bin'), 'binary'); assert.equal(h.get('云剪/personal/keep.pdf'), 'user');
  assert.equal(h.disk.files.has('/downloads/云剪/Documents'), false);
  await h.manager.configure(false, h.config.downloadRules);
  assert.equal(h.get('note.md'), 'md'); assert.equal(h.get('song.mp3'), 'music');
  assert.equal(h.get('unknown.bin'), 'binary'); assert.equal(h.get('private-notes/keep.md'), 'other');
  assert.equal(h.disk.files.has('/downloads/Documents'), false);
  assert.equal(h.get('云剪/personal/keep.pdf'), 'user');
});

test('editing and removing rules preserves directory registration so older custom folders can be flattened', async () => {
  const h = fixture(); await h.manager.resume();
  await h.manager.configure(true, [{ id: 'custom', folder: 'txtfiles', extensions: ['md'] }]);
  const saved = await h.manager.save('note.MD', async path => h.disk.files.set(path, 'body'));
  assert.equal(saved.folder, 'txtfiles'); assert.equal(h.get('txtfiles/note.MD'), 'body');
  await h.manager.configure(true, [{ id: 'new', folder: 'writing', extensions: ['md'] }]);
  assert.equal(h.get('writing/note.MD'), 'body'); assert.equal(h.disk.files.has('/downloads/txtfiles'), false);
  await h.manager.configure(false, []);
  assert.equal(h.get('note.MD'), 'body'); assert.equal(h.disk.files.has('/downloads/writing'), false);
  const restored = h.restore(); await restored.manager.configure(true, [{ id: 'again', folder: 'txtfiles', extensions: ['md'] }]);
  assert.equal(h.get('txtfiles/note.MD'), 'body');
});

test('unmanaged same-name directories are rejected before settings change, and traversal never reaches outside root', async () => {
  const h = fixture(); await h.manager.resume();
  h.put('txtfiles', null); h.put('txtfiles/user.md', 'keep');
  await assert.rejects(h.manager.configure(true, [{ id: 'md', folder: 'txtfiles', extensions: ['md'] }]), /not managed/);
  assert.equal(h.config.downloadRules[0].folder, 'Sounds'); assert.equal(h.get('txtfiles/user.md'), 'keep');
  await assert.rejects(h.manager.configure(true, [{ id: 'bad', folder: '../outside', extensions: ['md'] }]));
});

test('save and reorganization share a queue, preserve same-name originals, and return actual folder or root', async () => {
  const h = fixture(); await h.manager.resume();
  const [a,b] = await Promise.all([h.manager.save('doc.pdf', async path => h.disk.files.set(path, 'first')),
    h.manager.save('doc.pdf', async path => h.disk.files.set(path, 'second'))]);
  assert.equal(a.name, 'doc.pdf'); assert.equal(b.name, 'doc (1).pdf');
  assert.equal(h.get('Documents/doc.pdf'), 'first'); assert.equal(h.get('Documents/doc (1).pdf'), 'second');
  h.put('doc.pdf', 'user root');
  await h.manager.configure(false, h.config.downloadRules);
  assert.equal(h.get('doc.pdf'), 'user root'); assert.equal(h.get('doc (1).pdf'), 'first');
  const c = await h.manager.save('doc.pdf', async path => h.disk.files.set(path, 'third'));
  assert.equal(c.folder, ''); assert.equal(h.disk.files.get(c.path), 'third');
});

test('permission failure leaves sources intact and persisted journal resumes after restart', async () => {
  const h = fixture({ failMove: true }); h.put('cloud.md', 'keep');
  await h.manager.resume(); assert.equal(h.get('cloud.md'), 'keep');
  assert.match(h.runtime.get('downloadOrganizationError'), /Permission/);
  const restored = h.restore(); await restored.manager.resume();
  assert.equal(h.get('Documents/cloud.md'), 'keep'); assert.equal(h.runtime.get('downloadOrganizationError'), '');
});

test('interruption after atomic move is recovered without duplicating a completed file; failed save leaves no valid export', async () => {
  const h = fixture(); h.put('one.md', 'body');
  const originalWrite = h.disk.writeSync;
  let moved = false;
  h.disk.moveFile = async (a,b,mode) => { assert.equal(mode, 1); h.disk.renameSync(a,b); moved = true; };
  h.disk.writeSync = (path,data) => { if (moved) throw new Error('simulated process exit'); return originalWrite(path,data); };
  await h.manager.resume(); h.disk.writeSync = originalWrite;
  const restored = h.restore(); await restored.manager.resume();
  assert.equal(restored.get('Documents/one.md'), 'body');
  assert.equal([...restored.disk.files.keys()].filter(k => /one.*\.md$/.test(k)).length, 1);
  await assert.rejects(restored.manager.save('failed.pdf', async path => { restored.disk.files.set(path, 'partial'); throw new Error('No space left on device'); }));
  assert.equal(restored.disk.files.has('/downloads/Documents/failed.pdf'), false);
  assert.equal([...restored.disk.files.keys()].some(p => /\.cliplink-.*\.part$/.test(p)), false);
});
