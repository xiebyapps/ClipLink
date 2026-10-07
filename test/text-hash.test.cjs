const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { loadPureArkts } = require('./helpers/load-pure-arkts.cjs');

function hashUtil() {
  return loadPureArkts('entry/src/main/ets/utils/HashUtil.ets', 'HashUtil', {
    console,
    cryptoFramework: {
      createMd(algorithm) {
        assert.equal(algorithm, 'SHA256');
        const hash = crypto.createHash('sha256');
        return {
          async update(blob) { hash.update(Buffer.from(blob.data)); },
          async digest() { return { data: hash.digest() }; }
        };
      }
    }
  });
}

const vectors = [
  ['empty', ''],
  ['ASCII with NUL', 'ASCII\0text'],
  ['two-byte boundary', '\u007f\u0080\u07ff'],
  ['Chinese and multiple lines', '普通中文\n第二行'],
  ['three-byte boundaries', '\u0800\ud7ff\ue000\uffff'],
  ['emoji', '😀'],
  ['astral CJK', '𠮷'],
  ['lowest and highest surrogate pairs', '\ud800\udc00\udbff\udfff'],
  ['mixed text', '中😀𠮷文'],
  ['lone high surrogate', '\ud800'],
  ['lone low surrogate', '\udc00'],
  ['high surrogate followed by ASCII', '\ud800A'],
  ['two high surrogates then low surrogate', '\ud800\ud800\udc00']
];

for (const [name, text] of vectors) {
  test('text hash uses standard UTF-8: ' + name, async () => {
    const expected = crypto.createHash('sha256')
      .update(Buffer.from(text, 'utf8')).digest('hex').toUpperCase();
    assert.equal(await hashUtil().calculateTextHash(text), expected);
  });
}
