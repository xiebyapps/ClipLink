import { fileIo as fs } from '@kit.CoreFileKit';
import { RecordCacheService, CacheLease } from './RecordCacheService';
import { image } from '@kit.ImageKit';
import { ProfileDto, HistoryRecordDto, ServerAccount } from '../types/ApiTypes';
import { ClipboardUtil } from '../utils/ClipboardUtil';
import { ClipboardSnapshotUtil, ClipboardSnapshot } from '../utils/ClipboardSnapshotUtil';
import { ImageUtil } from '../utils/ImageUtil';
import { HashUtil } from '../utils/HashUtil';
import { ConfigService } from './ConfigService';
import { SyncClipboardService } from './SyncClipboardService';
import { FileUploadTask } from './FileUploadService';
import { SyncOperationQueue } from './SyncOperationQueue';
import { SyncDecision } from './SyncDecision';
import { PollingController } from './PollingController';
import { DownloadCancellation } from './HttpClient';
import { DownloadNoticeService } from './DownloadNoticeService';
import { HistoryStorageService } from './HistoryStorageService';
import { ServerManager } from './ServerManager';

export interface ManualOperationOptions {
  context?: Context;
  allowPrompt?: boolean;
  cancellation?: DownloadCancellation;
  onDownloadProgress?: (received: number, total: number) => void;
}

interface RemoteSnapshot {
  profile: ProfileDto;
  record?: HistoryRecordDto;
  key: string;
  time: number;
}

interface SyncBaseline {
  account: string;
  local: string;
  remote: string;
  bootEpoch: number;
}

/** A single foreground owner for automatic decisions and explicit remote pulls. */
export class SyncCoordinator {
  private static instance: SyncCoordinator = new SyncCoordinator();
  private baseline?: SyncBaseline;
  private generation: number = 0;
  private pending: Promise<void> | null = null;
  private requested: boolean = false;
  private uploadTask: FileUploadTask | null = null;
  private cancellation: DownloadCancellation | null = null;
  private imageRemoteKey: string = '';
  private imageFingerprint: string = '';
  private preparedImagePath: string = '';
  private clockOffset: number = NaN;
  private clockUncertainty: number = 0;

  static getInstance(): SyncCoordinator { return SyncCoordinator.instance; }

  invalidate(resetBaseline: boolean = false): void {
    this.generation++;
    this.uploadTask?.cancel();
    this.cancellation?.cancel();
    if (resetBaseline) {
      this.baseline = undefined;
      this.imageRemoteKey = '';
      this.imageFingerprint = '';
      this.clockOffset = NaN;
      this.clockUncertainty = 0;
    }
  }

  async enable(): Promise<void> {
    if (!ConfigService.getInstance().getActiveServer()) throw new Error('No available server');
    this.invalidate(true);
    ClipboardUtil.resetReadPermission();
    await ConfigService.getInstance().setSyncPaused('');
    AppStorage.setOrCreate('isPollingEnabled', true);
  }

  disable(): void {
    AppStorage.setOrCreate('isPollingEnabled', false);
    this.invalidate();
  }

  private enabled(): boolean {
    return AppStorage.get<boolean>('isPollingEnabled') === true &&
      AppStorage.get<boolean>('appForeground') !== false &&
      !AppStorage.get<string>('syncPausedReason') && !!ConfigService.getInstance().getActiveServer() &&
      AppStorage.get<string>('serverConnectionStatus') !== 'unverified';
  }

  request(): Promise<void> {
    if (!this.enabled()) return Promise.resolve();
    this.requested = true;
    if (this.pending) return this.pending;
    this.pending = this.drain().finally((): void => {
      this.pending = null;
      if (this.requested && this.enabled()) void this.request();
    });
    return this.pending;
  }

  private async drain(): Promise<void> {
    while (this.requested && this.enabled()) {
      this.requested = false;
      const generation = this.generation;
      await SyncOperationQueue.run(async (): Promise<void> => {
        if (generation !== this.generation || !this.enabled()) return;
        try {
          await this.reconcile(generation);
          if (this.enabled()) this.status('Idle');
        } catch (error) {
          if (generation !== this.generation || !this.enabled()) return;
          const message = error instanceof Error ? error.message : String(error);
          if (message === 'Sync state changed' || message === 'Clipboard changed during read') {
            this.requested = true;
          } else {
            this.status(`Sync Error: ${message}`);
            void ServerManager.getInstance().ensureAvailable();
          }
        }
      });
    }
  }

  private status(value: string): void { AppStorage.setOrCreate('automaticSyncStatus', value); }

  private async pause(reason: string): Promise<void> {
    this.disable();
    PollingController.stopAll();
    // Publish before writing preferences so network callbacks cannot fail over meanwhile.
    AppStorage.setOrCreate('syncPausedReason', reason);
    this.status('Automatic sync paused: unable to determine newer content');
    await ConfigService.getInstance().setSyncPaused(reason);
  }

  private server(): ServerAccount {
    const server = ConfigService.getInstance().getActiveServer();
    if (!server) throw new Error('No available server');
    return server;
  }

  private async readRemote(service: SyncClipboardService): Promise<RemoteSnapshot> {
    const profile = await service.getProfile();
    let record: HistoryRecordDto | undefined = undefined;
    if (profile.hash) {
      try {
        record = await service.getHistoryRecord(`${profile.type}-${profile.hash}`);
        if (record.isDeleted || record.type !== profile.type || record.hash !== profile.hash) {
          record = undefined;
        }
      } catch (error) {
        if (!(error instanceof Error) || !error.message.includes('HTTP 404')) {
          throw error instanceof Error ? error : new Error(String(error));
        }
      }
    }
    const identity = profile.hash || (profile.type === 'Text'
      ? await HashUtil.calculateTextHash(profile.text || '') : profile.dataName || '');
    return { profile: profile, record: record,
      key: `${profile.type}-${identity}:${record?.lastAccessed || ''}`,
      time: record?.lastAccessed ? Date.parse(record.lastAccessed) : NaN };
  }

  private async publish(remote: RemoteSnapshot, account: string, context?: Context): Promise<void> {
    if (ConfigService.getInstance().getActiveServer()?.id !== account) return;
    if (remote.record) await HistoryStorageService.getInstance().upsertRecord(remote.record, account, context);
    if (ConfigService.getInstance().getActiveServer()?.id !== account) return;
    if (remote.record) AppStorage.setOrCreate('currentRemoteRecord', remote.record);
    else AppStorage.delete('currentRemoteRecord');
    AppStorage.setOrCreate('currentRemoteAccount', account);
    AppStorage.setOrCreate('currentRemoteRevision',
      (AppStorage.get<number>('currentRemoteRevision') || 0) + 1);
  }

  private check(account: string, generation: number, count: number, automatic: boolean): void {
    if (ConfigService.getInstance().getActiveServer()?.id !== account || generation !== this.generation ||
      ClipboardSnapshotUtil.changeCount() !== count || (automatic && !this.enabled())) {
      throw new Error('Sync state changed');
    }
  }

  private async validate(service: SyncClipboardService, remote: RemoteSnapshot,
    local: ClipboardSnapshot, account: string, generation: number, automatic: boolean): Promise<void> {
    this.check(account, generation, local.changeCount, automatic);
    const latest = await this.readRemote(service);
    this.check(account, generation, local.changeCount, automatic);
    if (latest.key !== remote.key) throw new Error('Sync state changed');
  }

  private acknowledge(local: ClipboardSnapshot, remote: RemoteSnapshot, account: string): void {
    this.baseline = { account: account, local: local.fingerprint, remote: remote.key,
      bootEpoch: local.bootEpoch };
  }

  private async reconcile(generation: number): Promise<void> {
    const server = this.server();
    const service = new SyncClipboardService(server.url, server.username, server.password);
    let local: ClipboardSnapshot;
    try {
      local = await ClipboardSnapshotUtil.capture();
    } catch (error) {
      if (error instanceof Error && error.message === 'Clipboard changed during read') throw error;
      if (generation === this.generation && this.enabled()) await this.pause('Clipboard could not be read');
      return;
    }
    try {
      const remote = await this.readRemote(service);
      this.check(server.id, generation, local.changeCount, true);
      await this.publish(remote, server.id);
      let equal = local.kind === 'Text' && remote.profile.type === 'Text' &&
        local.fingerprint === `Text-${remote.profile.hash || await HashUtil.calculateTextHash(remote.profile.text || '')}`;
      if (local.kind === 'Empty' && remote.profile.type === 'Text' &&
        !remote.profile.hasData && !remote.profile.text) equal = true;
      if (local.kind === 'Image' && remote.profile.type === 'Image') {
        if (this.imageRemoteKey !== remote.key) {
          await this.inspectRemoteImage(service, remote, server.id, generation, local, true, false);
        }
        equal = local.fingerprint === this.imageFingerprint;
      }
      const baseline = this.baseline?.account === server.id ? this.baseline : undefined;
      const localChanged = !baseline || baseline.local !== local.fingerprint;
      const remoteChanged = !baseline || baseline.remote !== remote.key;
      let adjustedRemoteTime = NaN;
      let uncertainty = Infinity;
      let stable = !baseline || Math.abs(baseline.bootEpoch - local.bootEpoch) <= 250;
      // Also calibrate the initial equal baseline so a later server clock jump
      // can be detected when competing changes require timestamp comparison.
      if (!baseline || (!equal && localChanged && remoteChanged)) {
        const before = Date.now();
        const epochBefore = ClipboardSnapshotUtil.bootEpoch();
        try {
          const serverTime = Date.parse(await service.getServerTime());
          const after = Date.now();
          const epochAfter = ClipboardSnapshotUtil.bootEpoch();
          stable = stable && Math.abs(epochAfter - epochBefore) <= 250 &&
            Math.abs(epochAfter - local.bootEpoch) <= 250;
          uncertainty = Math.max(0, after - before) / 2 + 100;
          const offset = serverTime - (before + after) / 2;
          if (Number.isFinite(this.clockOffset) &&
            Math.abs(offset - this.clockOffset) > uncertainty + this.clockUncertainty + 250) {
            stable = false;
          }
          if (Number.isFinite(offset)) {
            this.clockOffset = offset;
            this.clockUncertainty = uncertainty;
          }
          adjustedRemoteTime = remote.time - offset;
          if (remote.time > serverTime + uncertainty) adjustedRemoteTime = NaN;
        } catch (error) {
          adjustedRemoteTime = NaN;
        }
      }
      this.check(server.id, generation, local.changeCount, true);
      const direction = SyncDecision.decide({ equal: equal, hasBaseline: !!baseline,
        localChanged: localChanged, remoteChanged: remoteChanged, localTime: local.time,
        remoteTime: adjustedRemoteTime, uncertainty: uncertainty, clockStable: stable });
      if (direction === 'pause') {
        await this.pause('Content times are missing, ambiguous, or the clock changed');
        return;
      }
      if (direction === 'local' && (local.kind === 'Text' || local.kind === 'Image')) {
        this.status('Uploading...');
        const guard = async (): Promise<void> => {
          await this.validate(service, remote, local, server.id, generation, true);
        };
        if (local.kind === 'Text') {
          await service.uploadTextContentExclusive(local.text, guard);
        } else {
          this.uploadTask = new FileUploadTask();
          try {
            const context = AppStorage.get<Context>('abilityContext') as Context;
            await this.uploadTask.uploadExclusive([{ uri: local.imagePath,
              name: `Clipboard-${local.fingerprint.slice(6)}.png`, image: true }],
              server, context, (): void => {}, guard);
          } finally {
            this.uploadTask = null;
          }
        }
        const confirmed = await this.readRemote(service);
        this.check(server.id, generation, local.changeCount, true);
        const expectedHash = local.kind === 'Text' ? local.fingerprint.slice(5) :
          await HashUtil.calculateTextHash(`Clipboard-${local.fingerprint.slice(6)}.png|${local.fingerprint.slice(6)}`);
        if (confirmed.profile.type !== local.kind || confirmed.profile.hash !== expectedHash) {
          throw new Error('Sync state changed');
        }
        if (local.kind === 'Image') {
          this.imageRemoteKey = confirmed.key;
          this.imageFingerprint = local.fingerprint;
        }
        this.acknowledge(local, confirmed, server.id);
        await this.publish(confirmed, server.id);
      } else if (direction === 'remote') {
        await this.pull(service, remote, server.id, generation, local, true);
      } else {
        if (remote.profile.type === 'Text' && remote.profile.hasData && remote.record) {
          await this.cachedRemoteText(service, remote, server.id, generation, local, true, false);
        }
        this.acknowledge(local, remote, server.id);
      }
    } finally {
      await ClipboardSnapshotUtil.remove(local.imagePath);
      await ClipboardSnapshotUtil.remove(this.preparedImagePath);
      this.preparedImagePath = '';
    }
  }

  private async inspectRemoteImage(service: SyncClipboardService, remote: RemoteSnapshot,
    account: string, generation: number, local: ClipboardSnapshot, automatic: boolean,
    write: boolean): Promise<void> {
    // The equality check already downloaded and normalized this image. Reuse it
    // if arbitration subsequently selects the server, rather than downloading twice.
    if (write && this.preparedImagePath && this.imageRemoteKey === remote.key) {
      const preparedMap = await ImageUtil.createPixelMapFromPath(this.preparedImagePath);
      try {
        await this.validate(service, remote, local, account, generation, automatic);
        await ClipboardUtil.setClipboardImage(preparedMap);
        local.changeCount = ClipboardSnapshotUtil.changeCount();
        local.fingerprint = this.imageFingerprint;
        local.kind = 'Image';
      } finally {
        await preparedMap.release();
      }
      return;
    }
    let cacheLease: CacheLease | undefined = undefined;
    const canonical = ClipboardSnapshotUtil.tempPath();
    let pixelMap: image.PixelMap | undefined = undefined;
    const notice = DownloadNoticeService.begin(remote.profile.dataName || 'Image', remote.profile.size || 0);
    let success = false;
    let retainCanonical = false;
    this.cancellation = new DownloadCancellation();
    try {
      const record = remote.record || { type: remote.profile.type, hash: remote.profile.hash || '',
        text: remote.profile.dataName || remote.profile.text, hasData: remote.profile.hasData,
        size: remote.profile.size } as HistoryRecordDto;
      cacheLease = await RecordCacheService.getInstance().acquire(record, account, service,
        (received: number, total: number): void => DownloadNoticeService.progress(notice, received, total), this.cancellation);
      const path = cacheLease.response.path;
      this.check(account, generation, local.changeCount, automatic);
      pixelMap = await ImageUtil.createPixelMapFromPath(path);
      const fingerprint = `Image-${await ClipboardSnapshotUtil.packImage(pixelMap, canonical)}`;
      await this.validate(service, remote, local, account, generation, automatic);
      this.imageRemoteKey = remote.key;
      this.imageFingerprint = fingerprint;
      if (write) {
        await ClipboardUtil.setClipboardImage(pixelMap);
        // Capture count immediately, before any further asynchronous work.
        local.changeCount = ClipboardSnapshotUtil.changeCount();
        local.fingerprint = fingerprint;
        local.kind = 'Image';
      } else {
        this.preparedImagePath = canonical;
        retainCanonical = true;
      }
      success = true;
    } finally {
      this.cancellation = null;
      if (pixelMap) await pixelMap.release();
      cacheLease?.release();
      if (!retainCanonical) await ClipboardSnapshotUtil.remove(canonical);
      DownloadNoticeService.finish(notice, success ? 'Download complete' : 'Download failed', !success);
    }
  }

  private async pull(service: SyncClipboardService, remote: RemoteSnapshot, account: string,
    generation: number, local: ClipboardSnapshot, automatic: boolean): Promise<void> {
    this.status('Syncing...');
    if (remote.profile.type === 'Text') {
      const text = await this.cachedRemoteText(service, remote, account, generation, local, automatic, true);
      await this.validate(service, remote, local, account, generation, automatic);
      await ClipboardUtil.setClipboardText(text);
      local.changeCount = ClipboardSnapshotUtil.changeCount();
      local.fingerprint = `Text-${await HashUtil.calculateTextHash(text)}`;
      local.kind = 'Text';
    } else if (remote.profile.type === 'Image') {
      await this.inspectRemoteImage(service, remote, account, generation, local, automatic, true);
    } else {
      await this.validate(service, remote, local, account, generation, automatic);
    }
    this.acknowledge(local, remote, account);
    await this.publish(remote, account);
  }

  private async cachedRemoteText(service: SyncClipboardService, remote: RemoteSnapshot, account: string,
    generation: number, local: ClipboardSnapshot, automatic: boolean, readBody: boolean): Promise<string> {
    const record = remote.record || { type: remote.profile.type, hash: remote.profile.hash || '',
      text: remote.profile.text, hasData: remote.profile.hasData, size: remote.profile.size } as HistoryRecordDto;
    let lease: CacheLease | undefined = undefined;
    let notice = 0;
    let success = false;
    this.cancellation = new DownloadCancellation();
    try {
      lease = await RecordCacheService.getInstance().acquire(record, account, service,
        (received: number, total: number): void => {
          if (!notice) notice = DownloadNoticeService.begin('Text', total);
          DownloadNoticeService.progress(notice, received, total);
        }, this.cancellation);
      this.check(account, generation, local.changeCount, automatic);
      const text = readBody ? fs.readTextSync(lease.response.path) : '';
      success = true;
      return text;
    } finally {
      lease?.release();
      this.cancellation = null;
      if (notice) DownloadNoticeService.finish(notice, success ? 'Download complete' :
        generation !== this.generation ? 'Download canceled' : 'Download failed', !success && generation === this.generation);
    }
  }

  private checkManual(server: ServerAccount, revision: number, count: number,
    options: ManualOperationOptions = {}): void {
    if (options.cancellation?.canceled || revision !== (AppStorage.get<number>('serverRevision') || 0) ||
      ClipboardSnapshotUtil.changeCount() !== count || ConfigService.getInstance().getActiveServer()?.id !== server.id) {
      throw new Error('Sync state changed');
    }
    const current = this.server();
    if (current.url !== server.url || current.username !== server.username || current.password !== server.password) {
      throw new Error('Sync state changed');
    }
  }

  private manualRecord(remote: RemoteSnapshot): HistoryRecordDto {
    return remote.record || { type: remote.profile.type, hash: remote.profile.hash || '',
      text: remote.profile.type === 'Text' ? remote.profile.text : remote.profile.dataName || remote.profile.text,
      hasData: remote.profile.hasData, size: remote.profile.size,
      textComplete: remote.profile.type === 'Text' && !remote.profile.hasData };
  }

  private async validateManual(service: SyncClipboardService, remote: RemoteSnapshot,
    local: ClipboardSnapshot, server: ServerAccount, revision: number, options: ManualOperationOptions): Promise<void> {
    this.checkManual(server, revision, local.changeCount, options);
    const latest = await this.readRemote(service);
    this.checkManual(server, revision, local.changeCount, options);
    if (latest.key !== remote.key) throw new Error('Sync state changed');
  }

  /** Manual operations have their own cancellation; leaving Home only invalidates automatic work. */
  async pullNow(options: ManualOperationOptions = {}): Promise<HistoryRecordDto> {
    const server = this.server();
    const revision = AppStorage.get<number>('serverRevision') || 0;
    return await SyncOperationQueue.run(async (): Promise<HistoryRecordDto> => {
      this.checkManual(server, revision, ClipboardSnapshotUtil.changeCount(), options);
      const service = new SyncClipboardService(server.url, server.username, server.password);
      const remote = await this.readRemote(service);
      this.checkManual(server, revision, ClipboardSnapshotUtil.changeCount(), options);
      if (remote.profile.type === 'Text') {
        const local = await ClipboardSnapshotUtil.capture(options.context, options.allowPrompt !== false);
        let lease: CacheLease | undefined;
        let notice = 0;
        let success = false;
        try {
          this.checkManual(server, revision, local.changeCount, options);
          lease = await RecordCacheService.getInstance().acquire(this.manualRecord(remote), server.id, service,
            (received: number, total: number): void => {
              options.onDownloadProgress?.(received, total);
              if (!notice) notice = DownloadNoticeService.begin('Text', total);
              DownloadNoticeService.progress(notice, received, total);
            }, options.cancellation, options.context);
          const text = fs.readTextSync(lease.response.path);
          await this.validateManual(service, remote, local, server, revision, options);
          await ClipboardUtil.setClipboardText(text);
          local.changeCount = ClipboardSnapshotUtil.changeCount();
          local.fingerprint = `Text-${await HashUtil.calculateTextHash(text)}`;
          local.kind = 'Text';
          this.checkManual(server, revision, local.changeCount, options);
          this.acknowledge(local, remote, server.id);
          await this.publish(remote, server.id, options.context);
          success = true;
        } finally {
          lease?.release(); await ClipboardSnapshotUtil.remove(local.imagePath);
          if (notice) DownloadNoticeService.finish(notice, success ? 'Download complete' :
            options.cancellation?.canceled ? 'Download canceled' : 'Download failed', !success);
        }
      } else {
        this.checkManual(server, revision, ClipboardSnapshotUtil.changeCount(), options);
        await this.publish(remote, server.id, options.context);
      }
      this.checkManual(server, revision, ClipboardSnapshotUtil.changeCount(), options);
      return this.manualRecord(remote);
    });
  }

  async uploadClipboard(onProgress: (phase: string, received: number, total: number) => void =
    (): void => {}, options: ManualOperationOptions = {}): Promise<void> {
    const server = this.server();
    const revision = AppStorage.get<number>('serverRevision') || 0;
    await SyncOperationQueue.run(async (): Promise<void> => {
      this.checkManual(server, revision, ClipboardSnapshotUtil.changeCount(), options);
      const local = await ClipboardSnapshotUtil.capture(options.context, options.allowPrompt !== false);
      try {
        if (local.kind === 'Empty' || (local.kind === 'Text' && !local.text)) throw new Error('Empty clipboard');
        if (local.kind === 'Unsupported') throw new Error('Only clipboard text and copied images can be uploaded');
        const service = new SyncClipboardService(server.url, server.username, server.password);
        const remote = await this.readRemote(service);
        const guard = async (): Promise<void> => {
          await this.validateManual(service, remote, local, server, revision, options);
        };
        onProgress('Uploading...', 0, 0);
        if (local.kind === 'Text') {
          await service.uploadTextContentExclusive(local.text, guard);
        } else {
          const task = new FileUploadTask();
          options.cancellation?.subscribe((): void => task.cancel());
          try {
            const context = options.context || AppStorage.get<Context>('abilityContext') as Context;
            await task.uploadExclusive([{ uri: local.imagePath,
              name: `Clipboard-${local.fingerprint.slice(6)}.png`, image: true }], server, context, onProgress, guard);
          } finally { options.cancellation?.unsubscribe(); }
        }
        const confirmed = await this.readRemote(service);
        this.checkManual(server, revision, local.changeCount, options);
        const expectedHash = local.kind === 'Text' ? local.fingerprint.slice(5) :
          await HashUtil.calculateTextHash(`Clipboard-${local.fingerprint.slice(6)}.png|${local.fingerprint.slice(6)}`);
        if (confirmed.profile.type !== local.kind || confirmed.profile.hash !== expectedHash) {
          throw new Error('Server clipboard changed before upload could be confirmed');
        }
        if (local.kind === 'Image') {
          this.imageRemoteKey = confirmed.key;
          this.imageFingerprint = local.fingerprint;
        }
        this.acknowledge(local, confirmed, server.id);
        await this.publish(confirmed, server.id, options.context);
      } finally { await ClipboardSnapshotUtil.remove(local.imagePath); }
    });
  }
}
