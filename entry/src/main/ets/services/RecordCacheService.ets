import { fileIo as fs } from '@kit.CoreFileKit';
import { HistoryRecordDto } from '../types/ApiTypes';
import { ConfigService } from './ConfigService';
import { SyncClipboardService } from './SyncClipboardService';
import { DownloadCancellation, StreamedBinaryResponse } from './HttpClient';
import { HashUtil } from '../utils/HashUtil';
import { UserFileSaveUtil } from '../utils/UserFileSaveUtil';
import { ImageUtil } from '../utils/ImageUtil';
import { BusinessError } from '@kit.BasicServicesKit';

export class CacheEntry {
  key: string = '';
  serverId: string = '';
  type: string = '';
  hash: string = '';
  path: string = '';
  size: number = 0;
  lastAccessed: number = 0;
  completedAt: number = 0;
  expiresAt: number = 0;
  fileName: string = '';
  contentType: string = '';
}

class CacheIndex {
  version: number = 1;
  sequence: number = 0;
  entries: CacheEntry[] = [];
}

export class CacheLease {
  response: StreamedBinaryResponse;
  private deadline: () => number;
  get expiresAt(): number { return this.deadline(); }
  private done: boolean = false;
  private onRelease: () => void;
  private onCheck: () => boolean;
  constructor(response: StreamedBinaryResponse, onRelease: () => void, onCheck: () => boolean, expiresAt: () => number) {
    this.response = response;
    this.onRelease = onRelease;
    this.onCheck = onCheck;
    this.deadline = expiresAt;
  }
  isReusable(): boolean { return !this.done && this.onCheck(); }
  release(): void {
    if (this.done) return;
    this.done = true;
    this.onRelease();
  }
}

class CacheConsumer {
  canceled: boolean = false;
  progress?: (received: number, total: number) => void;
}

class CacheDownload {
  consumers: Set<CacheConsumer> = new Set();
  cancellation: DownloadCancellation = new DownloadCancellation();
  promise: Promise<CacheEntry> = Promise.resolve(new CacheEntry());
  entry?: CacheEntry;
  accountEpoch: number = 0;
  cacheEpoch: number = 0;
}

/** Persistent, account-isolated payloads. Leases protect native preview readers. */
export class RecordCacheService {
  static readonly SMALL_LIMIT: number = 500 * 1024 * 1024;
  static readonly LARGE_TTL: number = 2 * 60 * 60 * 1000;
  private static instance: RecordCacheService = new RecordCacheService();
  private root: string = '';
  private context?: Context;
  private entries: Map<string, CacheEntry> = new Map();
  private uses: Map<string, number> = new Map();
  private retired: Map<string, CacheEntry> = new Map();
  private downloads: Map<string, CacheDownload> = new Map();
  private accountEpochs: Map<string, number> = new Map();
  private blocked: Set<string> = new Set();
  private sequence: number = 0;
  private initialized: boolean = false;
  private timer: number = -1;
  private cacheEpoch: number = 0;

  private smallLimit(): number {
    return (ConfigService.getInstance().getConfig().smallFileThresholdMB || 500) * 1024 * 1024;
  }

  static getInstance(): RecordCacheService { return RecordCacheService.instance; }

  private key(record: HistoryRecordDto, serverId: string): string {
    return `${serverId}:${record.type}-${record.hash}`;
  }

  initialize(context?: Context): void {
    if (this.initialized) return;
    this.context = AppStorage.get<Context>('abilityContext') || context;
    if (!this.context) throw new Error('Ability context is not initialized');
    this.root = `${this.context.filesDir}/record-cache`;
    if (!fs.accessSync(this.root)) fs.mkdirSync(this.root);
    let latest: CacheIndex = new CacheIndex();
    for (let slot = 0; slot < 2; slot++) {
      try {
        const value = JSON.parse(fs.readTextSync(`${this.root}/index-${slot}.json`)) as CacheIndex;
        if (value.version === 1 && Array.isArray(value.entries) && value.sequence >= latest.sequence) latest = value;
      } catch (_) { }
    }
    this.sequence = latest.sequence;
    const accounts = ConfigService.getInstance().getConfig().servers;
    for (const entry of latest.entries) {
      if (!entry || typeof entry.path !== 'string' || typeof entry.key !== 'string') continue;
      // Only accept this service's own relative layout, never arbitrary paths from an index.
      const relative = entry.path.startsWith(`${this.root}/`) ? entry.path.slice(this.root.length + 1) : '';
      if (!/^[A-F0-9]{64}-[a-z0-9-]+\/payload\/[^/]+$/i.test(relative) || !Number.isFinite(entry.size) ||
        entry.size < 0 || !accounts.some((account) => account.id === entry.serverId)) continue;
      try {
        if (fs.statSync(entry.path).size === entry.size) this.entries.set(entry.key, entry);
      } catch (_) { }
    }
    this.initialized = true;
    this.enforceLimits();
    const owned = new Set<string>();
    this.entries.forEach((entry: CacheEntry): void => { owned.add(this.entryDirectory(entry)); });
    for (const name of fs.listFileSync(this.root)) {
      if (name.startsWith('index-')) {
        if (name.endsWith('.part')) this.removeFile(`${this.root}/${name}`);
      } else if (!owned.has(`${this.root}/${name}`)) {
        this.removeDirectory(`${this.root}/${name}`);
      }
    }
    this.persist();
  }

  start(context?: Context): void {
    this.initialize(context);
    this.enforceLimits();
    if (AppStorage.get<boolean>('appForeground') === false) return;
    if (this.timer === -1) this.timer = setInterval((): void => {
      try { this.enforceLimits(); } catch (error) { console.error('[RecordCache] cleanup:', String(error)); }
    }, 60000);
  }

  stop(): void {
    if (this.timer !== -1) clearInterval(this.timer);
    this.timer = -1;
  }

  private removeFile(path: string): void {
    try { if (fs.accessSync(path)) fs.unlinkSync(path); } catch (_) { }
  }

  private removeDirectory(path: string): void {
    try {
      if (!fs.accessSync(path)) return;
      if (!fs.statSync(path).isDirectory()) { this.removeFile(path); return; }
      for (const name of fs.listFileSync(path)) this.removeDirectory(`${path}/${name}`);
      fs.rmdirSync(path);
    } catch (_) { }
  }

  private persist(): void {
    const index = new CacheIndex();
    index.sequence = ++this.sequence;
    index.entries = Array.from(this.entries.values());
    const slot = this.sequence % 2;
    const temporary = `${this.root}/index-${slot}.part`;
    const target = `${this.root}/index-${slot}.json`;
    const file = fs.openSync(temporary, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try { fs.writeSync(file.fd, JSON.stringify(index), { encoding: 'utf-8' }); }
    finally { fs.closeSync(file); }
    // The other slot remains intact if the process stops during replacement.
    if (fs.accessSync(target)) fs.unlinkSync(target);
    fs.renameSync(temporary, target);
    this.publishUsage();
  }

  private publishUsage(): void {
    let small = 0;
    let large = 0;
    this.entries.forEach((entry: CacheEntry): void => {
      if (entry.size <= this.smallLimit()) small += entry.size;
      else large += entry.size;
    });
    let pending = 0;
    this.retired.forEach((entry: CacheEntry): void => {
      pending += entry.size;
      if (entry.size > this.smallLimit()) large += entry.size;
    });
    AppStorage.setOrCreate('smallCacheBytes', small);
    AppStorage.setOrCreate('largeCacheBytes', large);
    AppStorage.setOrCreate('pendingCacheBytes', pending);
    AppStorage.setOrCreate('cacheUsageRevision', (AppStorage.get<number>('cacheUsageRevision') || 0) + 1);
  }

  private pin(entry: CacheEntry): void { this.uses.set(entry.path, (this.uses.get(entry.path) || 0) + 1); }

  private entryDirectory(entry: CacheEntry): string {
    return entry.path.substring(0, entry.path.lastIndexOf('/payload/'));
  }

  private release(entry: CacheEntry): void {
    const remaining = Math.max(0, (this.uses.get(entry.path) || 0) - 1);
    if (remaining > 0) this.uses.set(entry.path, remaining);
    else {
      this.uses.delete(entry.path);
      if (this.retired.delete(entry.path)) this.removeDirectory(this.entryDirectory(entry));
    }
    if (entry.expiresAt && entry.expiresAt <= Date.now() && this.entries.get(entry.key) === entry) {
      this.retire(entry);
      this.persist();
    }
    this.publishUsage();
  }

  private retire(entry: CacheEntry): void {
    if (this.entries.get(entry.key) === entry) this.entries.delete(entry.key);
    if ((this.uses.get(entry.path) || 0) > 0) this.retired.set(entry.path, entry);
    else this.removeDirectory(this.entryDirectory(entry));
  }

  enforceLimits(): void {
    if (!this.initialized) { this.initialize(); return; }
    let changed = false;
    for (const entry of this.entries.values()) {
      const deadline = entry.size > this.smallLimit() ? entry.completedAt + RecordCacheService.LARGE_TTL : 0;
      if (deadline !== entry.expiresAt) { entry.expiresAt = deadline; changed = true; }
    }
    for (const entry of this.entries.values()) {
      if (entry.expiresAt && entry.expiresAt <= Date.now()) { this.retire(entry); changed = true; }
    }
    const small = Array.from(this.entries.values()).filter((entry: CacheEntry): boolean =>
      entry.size <= this.smallLimit()).sort((a: CacheEntry, b: CacheEntry): number =>
      a.lastAccessed - b.lastAccessed || a.completedAt - b.completedAt || a.key.localeCompare(b.key));
    let used = small.reduce((sum: number, entry: CacheEntry): number => sum + entry.size, 0);
    const capacity = (ConfigService.getInstance().getConfig().cacheCapacityGB || 2) * 1024 * 1024 * 1024;
    for (const entry of small) {
      if (used <= capacity) break;
      used -= entry.size;
      this.retire(entry);
      changed = true;
    }
    if (changed) this.persist();
    else this.publishUsage();
  }

  clearAll(): void {
    this.initialize();
    this.cacheEpoch++;
    this.downloads.forEach((pending: CacheDownload): void => pending.cancellation.cancel());
    this.downloads.clear();
    for (const entry of this.entries.values()) this.retire(entry);
    this.persist();
    AppStorage.setOrCreate('cachePolicyRevision', (AppStorage.get<number>('cachePolicyRevision') || 0) + 1);
  }

  applyPolicy(): void {
    this.enforceLimits();
    AppStorage.setOrCreate('cachePolicyRevision', (AppStorage.get<number>('cachePolicyRevision') || 0) + 1);
  }

  removeRecords(serverId: string, profileIds: string[]): void {
    this.initialize();
    if (profileIds.length === 0) return;
    for (const id of profileIds) {
      const key = `${serverId}:${id}`;
      this.blocked.add(key);
      this.downloads.get(key)?.cancellation.cancel();
      const entry = this.entries.get(key);
      if (entry) this.retire(entry);
    }
    this.persist();
  }

  allowRecord(serverId: string, record: HistoryRecordDto): void {
    this.blocked.delete(this.key(record, serverId));
    const entry = this.entries.get(this.key(record, serverId));
    if (entry && record.lastAccessed) {
      const time = Date.parse(record.lastAccessed);
      if (Number.isFinite(time) && time !== entry.lastAccessed) {
        entry.lastAccessed = time;
        this.persist();
      }
    }
  }

  removeAccount(serverId: string): void {
    this.initialize();
    this.accountEpochs.set(serverId, (this.accountEpochs.get(serverId) || 0) + 1);
    for (const entry of this.entries.values()) if (entry.serverId === serverId) {
      this.blocked.add(entry.key);
      this.retire(entry);
    }
    this.downloads.forEach((pending: CacheDownload, key: string): void => {
      if (key.startsWith(`${serverId}:`)) pending.cancellation.cancel();
    });
    this.persist();
  }

  retainRecords(serverId: string, profileIds: string[]): void {
    this.initialize();
    const retained = new Set<string>(profileIds.map((id: string): string => `${serverId}:${id}`));
    const removed: string[] = [];
    this.entries.forEach((entry: CacheEntry): void => {
      if (entry.serverId === serverId && !retained.has(entry.key)) removed.push(`${entry.type}-${entry.hash}`);
    });
    this.removeRecords(serverId, removed);
  }

  private response(entry: CacheEntry): StreamedBinaryResponse {
    const file = fs.openSync(entry.path, fs.OpenMode.READ_ONLY);
    const buffer = new ArrayBuffer(16);
    let count = 0;
    try { count = fs.readSync(file.fd, buffer); } finally { fs.closeSync(file); }
    return { path: entry.path, size: entry.size, prefix: buffer.slice(0, count),
      fileName: entry.fileName, contentType: entry.contentType };
  }

  private lease(entry: CacheEntry): CacheLease {
    const response = this.response(entry);
    this.pin(entry);
    const epoch = this.cacheEpoch;
    return new CacheLease(response, (): void => this.release(entry), (): boolean =>
      epoch === this.cacheEpoch && !this.blocked.has(entry.key) && (!entry.expiresAt || entry.expiresAt > Date.now()) && fs.accessSync(entry.path), (): number => entry.expiresAt);
  }

  async acquire(record: HistoryRecordDto, serverId: string, service: SyncClipboardService,
    progress?: (received: number, total: number) => void, cancellation?: DownloadCancellation,
    context?: Context): Promise<CacheLease> {
    this.initialize(context);
    const key = this.key(record, serverId);
    if (this.blocked.has(key)) throw new Error('This record exceeds the local history limit');
    if (cancellation?.canceled) throw new Error('Download canceled');
    this.enforceLimits();
    const existing = this.entries.get(key);
    if (existing) {
      try { return this.lease(existing); }
      catch (_) { this.retire(existing); this.persist(); }
    }
    let pending = this.downloads.get(key);
    const consumer = new CacheConsumer();
    consumer.progress = progress;
    if (!pending) {
      pending = new CacheDownload();
      pending.cacheEpoch = this.cacheEpoch;
      pending.accountEpoch = this.accountEpochs.get(serverId) || 0;
      pending.consumers.add(consumer);
      this.downloads.set(key, pending);
      pending.promise = this.download(record, serverId, service, pending);
    } else pending.consumers.add(consumer);
    const shared = pending;
    cancellation?.subscribe((): void => {
      consumer.canceled = true;
      if (Array.from(shared.consumers).every((item: CacheConsumer): boolean => item.canceled)) shared.cancellation.cancel();
    });
    try {
      const entry = await shared.promise;
      if (shared.cacheEpoch !== this.cacheEpoch || consumer.canceled || cancellation?.canceled) throw new Error('Download canceled');
      return this.lease(entry);
    } finally {
      cancellation?.unsubscribe();
      shared.consumers.delete(consumer);
      if (shared.consumers.size === 0) {
        if (this.downloads.get(key) === shared) this.downloads.delete(key);
        if (shared.entry) this.release(shared.entry);
      }
    }
  }

  async storeInline(record: HistoryRecordDto, serverId: string, context?: Context): Promise<void> {
    if (record.type !== 'Text' || record.hasData || record.textComplete === false) return;
    const server = ConfigService.getInstance().getConfig().servers.find((item) => item.id === serverId);
    if (!server) return;
    const service = new SyncClipboardService(server.url, server.username, server.password);
    const lease = await this.acquire(record, serverId, service, undefined, undefined, context);
    lease.release();
  }

  private async download(record: HistoryRecordDto, serverId: string, service: SyncClipboardService,
    pending: CacheDownload): Promise<CacheEntry> {
    const key = this.key(record, serverId);
    const diskKey = await HashUtil.calculateTextHash(key);
    const directory = `${this.root}/${diskKey}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
    const temporary = `${directory}/download.part`;
    let committed = false;
    try {
      fs.mkdirSync(directory);
      fs.mkdirSync(`${directory}/payload`);
      let source = record;
      if (record.type === 'Text' && !record.hasData && record.textComplete === false) {
        source = await service.getHistoryRecord(`${record.type}-${record.hash}`);
        if (source.type !== record.type || source.hash !== record.hash || source.isDeleted) {
          throw new Error('File data is unavailable');
        }
      }
      if (pending.cancellation.canceled) throw new Error('Download canceled');
      let response: StreamedBinaryResponse;
      if (source.type === 'Text' && !source.hasData) {
        const file = fs.openSync(temporary, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
        try { fs.writeSync(file.fd, source.text || '', { encoding: 'utf-8' }); }
        finally { fs.closeSync(file); }
        response = { path: temporary, size: fs.statSync(temporary).size, prefix: new ArrayBuffer(0),
          contentType: 'text/plain', fileName: `Text-${record.hash.slice(0, 8)}.txt` };
      } else {
        if (!source.hasData) throw new Error('File data is unavailable');
        response = await service.downloadHistoryFileToPath(`${record.type}-${record.hash}`, temporary,
          (received: number, total: number): void => {
            pending.consumers.forEach((item: CacheConsumer): void => {
              if (!item.canceled) item.progress?.(received, total);
            });
          }, pending.cancellation);
      }
      if (pending.cancellation.canceled || this.blocked.has(key) ||
        pending.cacheEpoch !== this.cacheEpoch || pending.accountEpoch !== (this.accountEpochs.get(serverId) || 0) ||
        !ConfigService.getInstance().getConfig().servers.some((item) => item.id === serverId)) {
        throw new Error('Download canceled');
      }
      const fallback = record.type === 'Text' ? `Text-${record.hash.slice(0, 8)}.txt` :
        record.type === 'Image' ? `Image-${record.hash.slice(0, 8)}${ImageUtil.guessImageExtension(response.prefix)}` :
          record.type === 'Group' ? `Group-${record.hash.slice(0, 8)}.zip` : `${record.type}-${record.hash.slice(0, 8)}.bin`;
      const name = record.type === 'Text' ? fallback : UserFileSaveUtil.suggestedFileName(response, record.text, undefined, fallback);
      const target = `${directory}/payload/${name}`;
      fs.renameSync(temporary, target);
      const entry = new CacheEntry();
      entry.key = key;
      entry.serverId = serverId;
      entry.type = record.type;
      entry.hash = record.hash;
      entry.path = target;
      entry.size = fs.statSync(target).size;
      entry.lastAccessed = Date.parse(record.lastAccessed || '') || 0;
      entry.completedAt = Date.now();
      entry.expiresAt = entry.size > this.smallLimit() ? entry.completedAt + RecordCacheService.LARGE_TTL : 0;
      entry.fileName = name;
      entry.contentType = response.contentType || '';
      this.pin(entry); // Hold until all waiting consumers have acquired their own leases.
      pending.entry = entry;
      this.entries.set(key, entry);
      this.persist();
      this.enforceLimits();
      committed = true;
      return entry;
    } catch (error) {
      const code = (error as BusinessError)?.code;
      const message = error instanceof Error ? error.message : String(error);
      throw new Error(code === 13900025 || message.includes('13900025') || message.includes('ENOSPC') ||
        /no space left/i.test(message) ? 'Not enough storage space' : message);
    } finally {
      if (!committed) {
        const entry = pending.entry;
        if (entry) { this.retire(entry); this.release(entry); pending.entry = undefined; }
        this.removeDirectory(directory);
      }
    }
  }
}
