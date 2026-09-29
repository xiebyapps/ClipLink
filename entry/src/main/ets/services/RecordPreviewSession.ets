import { RecordCacheService, CacheLease } from './RecordCacheService';
import { common } from '@kit.AbilityKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { filePreview } from '@kit.PreviewKit';
import { HistoryRecordDto } from '../types/ApiTypes';
import { ConfigService } from './ConfigService';
import { SyncClipboardService } from './SyncClipboardService';
import { DownloadCancellation, StreamedBinaryResponse } from './HttpClient';
import { UserFileSaveUtil } from '../utils/UserFileSaveUtil';
import { ImageUtil } from '../utils/ImageUtil';
import { ClipboardUtil } from '../utils/ClipboardUtil';
import { DownloadNoticeService } from './DownloadNoticeService';

export class PreviewState {
  name: string = '';
  fullText: string = '';
  status: string = 'Preparing...';
  error: string = '';
  received: number = 0;
  total: number = 0;
  speed: number = 0;
  loading: boolean = false;
  ready: boolean = false;
  supported: boolean = false;
  image: boolean = false;
  busy: boolean = false;
}

/** One account-pinned file shared by the system viewer and all panel actions. */
export class RecordPreviewSession {
  private static current?: RecordPreviewSession;
  readonly record: HistoryRecordDto;
  readonly serverId: string;
  state: PreviewState = new PreviewState();
  onChange?: (state: PreviewState) => void;
  onTransfer?: (received: number, total: number) => void;
  onPreparation?: (loading: boolean) => void;
  private context: common.UIAbilityContext;
  private service: SyncClipboardService;
  private response?: StreamedBinaryResponse;
  private cancellation: DownloadCancellation = new DownloadCancellation();
  private cacheLease?: CacheLease;
  private previousLeases: CacheLease[] = [];
  private expiryTimer: number = -1;
  private closed: boolean = false;
  private preparing: boolean = false;
  private systemOpen: boolean = false;
  private opening: boolean = false;
  private poll: number = -1;
  private previousTime: number = 0;
  private previousBytes: number = 0;
  private noticeId: number = 0;

  private autoOpenSystemPreview: boolean;

  constructor(record: HistoryRecordDto, autoOpenSystemPreview: boolean = true, context?: common.UIAbilityContext) {
    this.autoOpenSystemPreview = autoOpenSystemPreview;
    RecordPreviewSession.current?.close();
    this.record = record;
    const config = ConfigService.getInstance().getConfig();
    this.serverId = config.activeServerId;
    const server = config.servers.find((item) => item.id === this.serverId);
    if (!server) throw new Error('No available server');
    this.service = new SyncClipboardService(server.url, server.username, server.password);
    this.context = context || AppStorage.get<common.UIAbilityContext>('abilityContext')!;
    this.state.name = record.type === 'Text' ? `Text-${record.hash.slice(0, 8)}.txt`
      : UserFileSaveUtil.fileName(record.text, `${record.type}-${record.hash.slice(0, 8)}.bin`);
    this.state.total = record.size || 0;
    this.state.image = UserFileSaveUtil.isLikelyImage(record.type, record.text);
    RecordPreviewSession.current = this;
  }

  static cachePolicyChanged(): void {
    const session = RecordPreviewSession.current;
    session?.releaseExpiredIdle();
    session?.scheduleExpiry();
  }

  static cached(record: HistoryRecordDto): RecordPreviewSession | undefined {
    const session = RecordPreviewSession.current;
    return session?.valid() && session.cacheLease?.isReusable() && session.state.ready && session.record.type === record.type &&
      session.record.hash === record.hash ? session : undefined;
  }

  private valid(): boolean {
    return !this.closed && this.serverId === ConfigService.getInstance().getConfig().activeServerId;
  }

  isActive(): boolean { return this.valid(); }

  private ensureCurrent(): void {
    if (!this.valid()) throw new Error('Server changed during operation');
  }

  private emit(): void {
    if (this.valid()) this.onChange?.(this.state);
  }

  private progress(received: number, total: number): void {
    if (!this.valid()) { this.close(); return; }
    this.onTransfer?.(received, total);
    DownloadNoticeService.progress(this.noticeId, received, total);
    const now = Date.now();
    const elapsed = now - this.previousTime;
    if (elapsed < 350 && (total <= 0 || received < total)) return;
    this.state.speed = elapsed > 0 ? (received - this.previousBytes) * 1000 / elapsed : 0;
    this.state.received = received;
    if (total > 0) this.state.total = total;
    this.previousTime = now;
    this.previousBytes = received;
    this.emit();
  }

  async prepare(): Promise<void> {
    if (!this.valid() || this.preparing || this.state.ready) return;
    this.preparing = true;
    this.onPreparation?.(true);
    this.state.loading = true;
    this.state.error = '';
    this.state.status = 'Preparing...';
    this.state.received = 0;
    this.previousBytes = 0;
    this.previousTime = Date.now();
    this.cancellation = new DownloadCancellation();
    this.emit();
    if (this.cacheLease && !this.systemOpen) { this.cacheLease.release(); this.cacheLease = undefined; }
    try {
      this.ensureCurrent();
      const responseLease = await RecordCacheService.getInstance().acquire(this.record, this.serverId, this.service,
        (received: number, total: number): void => {
          if (!this.noticeId) this.noticeId = DownloadNoticeService.begin(this.state.name, this.state.total);
          this.progress(received, total);
        }, this.cancellation, this.context);
      this.cacheLease = responseLease;
      this.scheduleExpiry();
      this.ensureCurrent();
      const response = responseLease.response;
      this.response = response;
      const target = response.path;
      this.state.name = response.fileName || this.state.name;
      this.state.image = this.record.type !== 'Text' && UserFileSaveUtil.category(this.record.type,
        this.state.name, response.contentType, response.prefix) === 'Image';
      this.state.received = response.size;
      this.state.total = response.size;
      if (this.record.type === 'Text') this.state.fullText = fs.readTextSync(target);
      this.state.ready = true;
      this.state.loading = false;
      this.state.status = 'Ready to preview';
      this.emit();
      if (this.noticeId) {
        DownloadNoticeService.progress(this.noticeId, response.size, response.size);
        DownloadNoticeService.status(this.noticeId, 'Download complete', this.state.name);
        DownloadNoticeService.finish(this.noticeId);
        this.noticeId = 0;
      }
      if (this.record.type === 'Text') return;
      if (!canIUse('SystemCapability.FileManagement.FilePreview.Core')) {
        this.state.status = 'System preview is unavailable on this device';
      } else {
        this.state.supported = await filePreview.canPreview(this.context, fileUri.getUriFromPath(target));
        this.ensureCurrent();
        if (this.state.supported) {
          if (this.autoOpenSystemPreview) await this.openPreview();
        } else this.state.status = 'This file does not support system preview';
      }
    } catch (error) {
      if (this.valid()) {
        this.state.error = error instanceof Error ? error.message : String(error);
        this.state.status = this.state.ready ? 'Unable to open system preview' : 'File preparation failed';
      }
    } finally {
      if (this.noticeId) {
        DownloadNoticeService.finish(this.noticeId, this.valid() ? 'Download failed' : 'Download canceled', this.valid());
        this.noticeId = 0;
      }
      this.preparing = false;
      this.onPreparation?.(false);
      this.state.loading = false;
      this.emit();
      this.cleanup();
    }
  }

  async openPreview(): Promise<void> {
    if (this.record.type === 'Text') return;
    if (!this.valid() || !this.response || !this.state.supported || this.opening || this.systemOpen) return;
    this.opening = true;
    this.state.error = '';
    this.state.status = 'Opening system preview...';
    this.emit();
    try {
      await this.refreshPayload();
      this.systemOpen = true;
      const contentType = (this.response.contentType || '').split(';')[0].trim().toLowerCase();
      await filePreview.openPreview(this.context, { title: this.state.name,
        uri: fileUri.getUriFromPath(this.response.path),
        mimeType: contentType === 'application/octet-stream' ? '' : contentType });
      this.state.status = 'System preview opened';
      this.pollSystemWindow();
    } catch (error) {
      this.systemOpen = false;
      this.state.status = 'Unable to open system preview';
      this.state.error = error instanceof Error ? error.message : String(error);
    } finally {
      this.opening = false;
      this.emit();
      this.cleanup();
    }
  }

  private pollSystemWindow(): void {
    if (this.poll !== -1) clearTimeout(this.poll);
    this.poll = setTimeout((): void => {
      this.poll = -1;
      void this.checkSystemWindow();
    }, 700);
  }

  private async checkSystemWindow(): Promise<void> {
    try {
      this.systemOpen = await filePreview.hasDisplayed(this.context);
      if (!this.valid() && !this.closed) this.close();
      if (!this.systemOpen) {
        this.previousLeases.forEach((lease: CacheLease): void => lease.release());
        this.previousLeases = [];
        if (this.state.status === 'System preview opened') this.state.status = 'Ready to preview';
        this.emit();
        this.cleanup();
        return;
      }
    } catch (_) {
      // An unknown window state must not delete a file still in use by the system.
    }
    this.pollSystemWindow();
  }

  async copy(): Promise<string> {
    this.ensureCurrent();
    if (!this.response || this.state.busy) throw new Error('File is not ready');
    this.state.busy = true;
    this.emit();
    try {
      await this.refreshPayload();
      if (this.record.type === 'Text') {
        const text = fs.readTextSync(this.response.path);
        this.ensureCurrent();
        await ClipboardUtil.setClipboardText(text);
      } else if (this.state.image) {
        const pixelMap = await ImageUtil.createPixelMapFromPath(this.response.path);
        try { this.ensureCurrent(); await ClipboardUtil.setClipboardImage(pixelMap); }
        finally { await pixelMap.release(); }
      } else throw new Error('Copy is not supported for this file');
      return 'Copied to clipboard';
    } finally { this.state.busy = false; this.emit(); this.cleanup(); }
  }

  async save(saveAs: boolean, galleryAuthorized: boolean = false): Promise<string> {
    this.ensureCurrent();
    if (!this.response || this.state.busy) throw new Error('File is not ready');
    if (this.record.type === 'Text') throw new Error('Copy is not supported for this file');
    this.state.busy = true;
    this.emit();
    try {
      await this.refreshPayload();
      if (saveAs) {
        const uri = await UserFileSaveUtil.saveAs(this.response, this.state.name, undefined, this.state.name, this.context);
        return uri ? 'Saved to selected folder' : 'Save canceled';
      }
      if (this.state.image) {
        if (!galleryAuthorized) return 'Tap Save to Gallery';
        await UserFileSaveUtil.saveToGallery(this.response, this.state.name, this.state.name, this.context);
        return 'Saved to Gallery';
      }
      const saved = await UserFileSaveUtil.saveAutomatically(this.response, this.record.type,
        this.state.name, undefined, this.state.name, this.context);
      return UserFileSaveUtil.savedMessage(saved);
    } finally { this.state.busy = false; this.emit(); this.cleanup(); }
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.onChange = undefined;
    this.onPreparation?.(false);
    this.onPreparation = undefined;
    this.onTransfer = undefined;
    this.cancellation.cancel();
    if (RecordPreviewSession.current === this) RecordPreviewSession.current = undefined;
    this.cleanup();
  }

  private async refreshPayload(): Promise<void> {
    if (this.cacheLease?.isReusable()) return;
    this.onPreparation?.(true);
    let replacement: CacheLease | undefined = undefined;
    let succeeded = false;
    this.cancellation = new DownloadCancellation();
    try {
      replacement = await RecordCacheService.getInstance().acquire(this.record, this.serverId, this.service,
        (received: number, total: number): void => {
          if (!this.noticeId) this.noticeId = DownloadNoticeService.begin(this.state.name, this.state.total);
          this.progress(received, total);
        }, this.cancellation, this.context);
      this.ensureCurrent();
      if (this.cacheLease) {
        if (this.systemOpen) this.previousLeases.push(this.cacheLease);
        else this.cacheLease.release();
      }
      this.cacheLease = replacement;
      this.response = replacement.response;
      this.state.total = replacement.response.size;
      this.scheduleExpiry();
      if (this.record.type === 'Text') this.state.fullText = fs.readTextSync(this.response.path);
      succeeded = true;
    } finally {
      this.onPreparation?.(false);
      if (replacement && this.cacheLease !== replacement) replacement.release();
      if (this.noticeId) {
        DownloadNoticeService.finish(this.noticeId, succeeded ? 'Download complete' :
          this.valid() ? 'Download failed' : 'Download canceled', !succeeded && this.valid());
        this.noticeId = 0;
      }
    }
  }

  private scheduleExpiry(): void {
    if (this.expiryTimer !== -1) clearTimeout(this.expiryTimer);
    this.expiryTimer = -1;
    const lease = this.cacheLease;
    if (!lease?.expiresAt) return;
    this.expiryTimer = setTimeout((): void => {
      this.expiryTimer = -1;
      this.releaseExpiredIdle();
      if (this.cacheLease?.isReusable()) this.scheduleExpiry();
    }, Math.max(1, lease.expiresAt - Date.now()));
  }

  private releaseExpiredIdle(): void {
    if (this.record.type !== 'Text' && !this.systemOpen && !this.opening && !this.state.busy &&
      this.cacheLease && !this.cacheLease.isReusable()) {
      this.cacheLease.release();
      this.cacheLease = undefined;
    }
  }

  private cleanup(): void {
    this.releaseExpiredIdle();
    if (!this.closed || this.preparing || this.opening || this.systemOpen || this.state.busy) return;
    if (this.expiryTimer !== -1) clearTimeout(this.expiryTimer);
    this.expiryTimer = -1;
    if (this.poll !== -1) { clearTimeout(this.poll); this.poll = -1; }
    this.cacheLease?.release();
    this.cacheLease = undefined;
    this.previousLeases.forEach((lease: CacheLease): void => lease.release());
    this.previousLeases = [];
  }
}
