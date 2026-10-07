const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { methodBody } = require('./helpers/load-pure-arkts.cjs');
const source = fs.readFileSync(path.join(__dirname,
  '../entry/src/main/ets/pages/HomePage.ets'), 'utf8');

function fixture(status) {
  const timers = new Map(); let id = 0;
  const context = vm.createContext({
    setTimeout(fn) { timers.set(++id, fn); return id; },
    clearTimeout(timer) { timers.delete(timer); }
  });
  const reset = vm.runInContext('(function(){' +
    methodBody(source, 'resetSyncStatusLater') + '})', context);
  const clear = vm.runInContext('(function(){' +
    methodBody(source, 'clearSyncStatusTimer') + '})', context);
  const page = { syncStatus: status, syncStatusTimer: -1,
    clearSyncStatusTimer: clear, resetSyncStatusLater: reset };
  return { page, timers, flush() {
    for (const fn of [...timers.values()]) fn();
    timers.clear();
  } };
}

for (const direction of ['Upload', 'Download']) {
  test(direction + ' error keeps its complete code and multiline message', () => {
    const message = direction + ' Error: REQUEST_FIXTURE\n' + 'detail\n'.repeat(40);
    const f = fixture('Download Success');
    f.page.resetSyncStatusLater();
    assert.equal(f.timers.size, 1);
    f.page.syncStatus = message; f.page.resetSyncStatusLater();
    assert.equal(f.timers.size, 0);
    f.flush(); assert.equal(f.page.syncStatus, message);
  });
}

test('later success restores the normal transient status timer', () => {
  const f = fixture('Upload Error: fixture');
  f.page.resetSyncStatusLater(); assert.equal(f.timers.size, 0);
  f.page.syncStatus = 'Upload Success'; f.page.resetSyncStatusLater();
  f.flush(); assert.equal(f.page.syncStatus, 'Idle');
});

test('the scrollable page gives status its own width without a line cap', () => {
  assert.match(source, /Scroll\(\)/);
  const status = source.slice(source.indexOf('Text(this.syncStatus)'),
    source.indexOf('Column({ space: 14 })', source.indexOf('Text(this.syncStatus)')));
  assert.match(status, /\.width\('90%'\)/);
  assert.doesNotMatch(status, /\.maxLines\(|\.height\(/);
});
