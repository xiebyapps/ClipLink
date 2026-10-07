const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// These two pure modules use only this small set of TypeScript annotations.
// Execute their real source with platform globals stubbed; do not duplicate
// the encoder or polling algorithm. HAP compilation remains a separate check.
function loadPureArkts(relativePath, exportName, globals = {}) {
  const source = fs.readFileSync(path.join(__dirname, '../..', relativePath), 'utf8');
  const js = source
    .replace(/^import .*;\r?\n/gm, '')
    .replace(/\bexport\s+/g, '')
    .replace(/\b(?:private|public)\s+/g, '')
    .replace(/:\s*\(\)\s*=>\s*Promise<void>\s*\|\s*void/g, '')
    .replace(/:\s*(?:Set<PollingController>|PollingController|Promise<string>|Promise<void>|cryptoFramework\.DataBlob|Uint8Array|number\[\]|number|string|boolean|void)(?=\s*(?:[=;,){]|=>))/g, '')
    .replace(/new Set<PollingController>/g, 'new Set');
  const context = vm.createContext({ ...globals });
  vm.runInContext(js + '\nthis.loadedClass = ' + exportName + ';', context);
  return context.loadedClass;
}

function methodBody(source, name) {
  const match = source.match(new RegExp(
    'private ' + name + '\\(\\): void \\{([\\s\\S]*?)\\n  \\}'
  ));
  if (!match) throw new Error('Method fixture not found: ' + name);
  return match[1].replace(/\(\): void/g, '()');
}

module.exports = { loadPureArkts, methodBody };
