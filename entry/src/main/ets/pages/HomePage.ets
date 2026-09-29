import { DesktopActionService, DesktopRequest } from '../services/DesktopActionService';
import { ClipboardWidgetService } from '../services/ClipboardWidgetService';
import { fileIo as fs } from '@kit.CoreFileKit';
import { RecordCacheService } from '../services/RecordCacheService';
import { SyncCoordinator } from '../services/SyncCoordinator';
import { DownloadNoticeService } from '../services/DownloadNoticeService';
import { RecordPreviewPanel } from '../components/RecordPreviewPanel';
import { RecordPreviewSession } from '../services/RecordPreviewSession';
import { ClipboardUtil } from '../utils/ClipboardUtil';
import { SyncClipboardService } from '../services/SyncClipboardService';
import { ConfigService } from '../services/ConfigService';
import { PollingController } from '../services/PollingController';
import { ServerManager } from '../services/ServerManager';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { ThemeUtil, ThemePalette } from '../utils/ThemeUtil';
import { HistoryStorageService } from '../services/HistoryStorageService';
import { HistoryRecordDto } from '../types/ApiTypes';
import { image } from '@kit.ImageKit';
import { ImageUtil } from '../utils/ImageUtil';
import { FileRecordDisplayUtil } from '../utils/FileRecordDisplayUtil';
import { UserFileSaveUtil } from '../utils/UserFileSaveUtil';
import { picker } from '@kit.CoreFileKit';
import { FileUploadTask, UploadFile } from '../services/FileUploadService';
import { LocalizationUtil } from '../utils/LocalizationUtil';
import { InteractionEffectUtil } from '../utils/InteractionEffectUtil';
import { HdsNavigation, HdsNavigationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';
import {
  getActionButtonSpec,
  getClipboardPreviewMode,
  getSyncStatusTone
} from '../utils/PageScaffoldUtil';

@Component
export default struct HomePage {
  @State previewVisible: boolean = false;
  private previewSession?: RecordPreviewSession;
  @State currentText: string = '';
  @State currentImage?: image.PixelMap = undefined;
  @State currentClipboardMode: 'text' | 'image' = 'text';
  @State galleryRecentKey: string = '';
  @State syncStatus: string = 'Idle';
  @State isPolling: boolean = false;
  @State manualSyncBusy: boolean = false;
  @State useHdsEffects: boolean = false;
  @State pressedButton: string = '';
  @State favoriteActive: boolean = false;
  @State copyActive: boolean = false;
  @State latestHistoryItem?: HistoryRecordDto = undefined;
  @State lastServerSyncAt: number = 0;
  @State downloadActive: boolean = false;
  @State downloadSaving: boolean = false;
  @State downloadName: string = '';
  @State downloadReceived: number = 0;
  @State downloadTotal: number = 0;
  @State downloadSpeed: number = 0;
  @State uploadActive: boolean = false;
  @State uploadPhase: string = '';
  @State uploadReceived: number = 0;
  @State uploadTotal: number = 0;
  @State uploadSpeed: number = 0;
  @State viewportWidth: number = 360;
  @State viewportHeight: number = 800;
  @StorageLink('appTheme') appTheme: string = 'auto';
  @StorageLink('appLanguage') appLanguage: string = 'system';
  @StorageLink('systemLanguage') systemLanguage: string = 'en';
  @StorageLink('floatingTabsEnabled') supportsFloatingTabs: boolean = false;
  @StorageLink('safeAreaBottom') safeAreaBottom: number = 0;
  @StorageLink('preferPureBlackInDark') preferPureBlackInDark: boolean = false;
  @StorageLink('systemColorMode') systemColorMode: number =
    ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  @StorageLink('isPollingEnabled') @Watch('handlePollingEnabledChange') isPollingEnabled: boolean = false;
  @StorageLink('syncPausedReason') syncPausedReason: string = '';
  @StorageLink('automaticSyncStatus') @Watch('handleAutomaticStatusChange') automaticSyncStatus: string = 'Idle';
  @StorageLink('currentRemoteRevision') @Watch('handleCurrentRemoteChange') currentRemoteRevision: number = 0;
  @StorageLink('historyRefreshToken') @Watch('handleHistoryRefreshTokenChange')
  historyRefreshToken: number = 0;
  @StorageLink('historyMetadataRevision') @Watch('handleHistoryRefreshTokenChange')
  historyMetadataRevision: number = 0;
  @StorageLink('serverRevision') @Watch('handleServerRevisionChange') serverRevision: number = 0;
  @StorageLink('appForeground') @Watch('handleAppForegroundChange') appForeground: boolean = true;
  @StorageLink('pollingInterval') @Watch('handlePollingIntervalChange') pollingInterval: number = 10;
  @StorageLink('activeServerId') activeServerId: string = 'original';
  private pollingController: PollingController = new PollingController();
  private historyStorageService: HistoryStorageService = HistoryStorageService.getInstance();
  private syncStatusTimer: number = -1;
  private initToken: number = 0;
  private latestHistoryToken: number = 0;
  private progressTime: number = 0;
  private progressBytes: number = 0;
  private downloadNoticeId: number = 0;
  private uploadProgressTime: number = 0;
  private uploadProgressBytes: number = 0;
  private uploadTask: FileUploadTask | null = null;
  private uploadServerId: string = '';
  private readonly pageScroller: Scroller = new Scroller();
  private readonly clipboardUpdateHandler = (): void => {
    void this.loadCurrentClipboard();
    void SyncCoordinator.getInstance().request();
  };

  private getPalette(): ThemePalette {
    return ThemeUtil.getPalette(
      this.appTheme as 'light' | 'dark' | 'auto',
      this.systemColorMode,
      this.preferPureBlackInDark
    );
  }

  @Builder
  private previewPanel() {
    if (this.previewSession) {
      RecordPreviewPanel({ session: this.previewSession })
    }
  }

  private closePreviewPanel(): void {
    this.previewVisible = false;
    this.previewSession?.close();
    this.previewSession = undefined;
  }

  private t(value: string): string {
    return LocalizationUtil.text(value, this.appLanguage, this.systemLanguage);
  }

  private isWideLayout(): boolean {
    return this.viewportWidth >= 760 && this.viewportWidth > this.viewportHeight;
  }

  private clipboardDisplayText(): string {
    const placeholders = ['Empty clipboard', 'Clipboard permission denied',
      '[Clipboard data unavailable]', 'Error reading clipboard'];
    return placeholders.includes(this.currentText) ? this.t(this.currentText) : this.currentText;
  }

  private serverStatusColor(): string {
    const tone = getSyncStatusTone(this.syncStatus);
    return tone === 'danger' ? this.getPalette().danger
      : tone === 'success' ? this.getPalette().success : this.getPalette().accent;
  }

  private formatLastServerSyncTime(): string {
    if (!this.lastServerSyncAt || !Number.isFinite(this.lastServerSyncAt)) return '—';
    const date = new Date(this.lastServerSyncAt);
    const month = (date.getMonth() + 1).toString().padStart(2, '0');
    const day = date.getDate().toString().padStart(2, '0');
    const hours = date.getHours().toString().padStart(2, '0');
    const minutes = date.getMinutes().toString().padStart(2, '0');
    return `${month}/${day} ${hours}:${minutes}`;
  }

  private titleActionText(action: 'auto' | 'sync'): string {
    const chinese = LocalizationUtil.isChinese(this.appLanguage, this.systemLanguage);
    if (action === 'auto') return chinese ? '自动\n同步' : 'Auto\nSync';
    return chinese ? '立即\n同步' : 'Sync\nNow';
  }

  private recentStatusInline(): boolean {
    const cardWidth = this.viewportWidth * 0.9 * (this.isWideLayout() ? 0.49 : 1);
    return cardWidth - 40 >= 380;
  }

  private updateDownloadProgress(received: number, total: number): void {
    DownloadNoticeService.progress(this.downloadNoticeId, received, total);
    const now = Date.now();
    const elapsed = now - this.progressTime;
    if (elapsed < 350 && (total === 0 || received < total)) return;
    this.downloadSpeed = elapsed > 0 ? Math.max(0, (received - this.progressBytes) * 1000 / elapsed) : 0;
    this.downloadReceived = received;
    this.downloadTotal = total > 0 ? total : this.downloadTotal;
    this.progressTime = now;
    this.progressBytes = received;
  }

  private buttonEffect(id: string): VisualEffect | undefined {
    return InteractionEffectUtil.button(this.pressedButton === id, this.useHdsEffects);
  }

  private cardEffect(): VisualEffect | undefined {
    return InteractionEffectUtil.card(this.useHdsEffects);
  }

  private updatePress(id: string, event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.pressedButton = id;
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      if (this.pressedButton === id) this.pressedButton = '';
    }
  }

  aboutToAppear() {
    this.useHdsEffects = canIUse('SystemCapability.UIDesign.HDSComponent.Core');
    ClipboardUtil.onUpdate(this.clipboardUpdateHandler);
    void this.initializePage();
  }

  aboutToDisappear() {
    DesktopActionService.detach();
    this.closePreviewPanel();
    this.initToken++;
    this.latestHistoryToken++;
    ClipboardUtil.offUpdate(this.clipboardUpdateHandler);
    this.clearSyncStatusTimer();
    this.pollingController.dispose();
    SyncCoordinator.getInstance().invalidate();
    void this.currentImage?.release();
  }

  private clearSyncStatusTimer(): void {
    if (this.syncStatusTimer !== -1) {
      clearTimeout(this.syncStatusTimer);
      this.syncStatusTimer = -1;
    }
  }

  private resetSyncStatusLater(): void {
    this.clearSyncStatusTimer();
    this.syncStatusTimer = setTimeout((): void => {
      this.syncStatus = 'Idle';
      this.syncStatusTimer = -1;
    }, 2000);
  }

  private createSyncService(serverId?: string): SyncClipboardService {
    const config = ConfigService.getInstance().getConfig();
    const server = serverId
      ? config.servers.find((item) => item.id === serverId) || config.server : config.server;
    if (!server) throw new Error('No available server');
    return new SyncClipboardService(
      server.url,
      server.username,
      server.password
    );
  }

  private async initializePage() {
    const currentToken = ++this.initToken;
    await ConfigService.getInstance().loadConfig();
    if (currentToken !== this.initToken) {
      return;
    }
    await this.loadCurrentClipboard();
    await this.loadLatestHistory();
    if (currentToken !== this.initToken) {
      return;
    }
    DesktopActionService.attach((request: DesktopRequest): Promise<void> => this.performDesktopAction(request));
    this.isPolling = this.isPollingEnabled && !this.syncPausedReason;
    this.startAutomaticPolling();
  }

  private async loadCurrentClipboard() {
    try {
      const previousImage = this.currentImage;
      this.currentImage = undefined;
      const summary = await ClipboardUtil.getClipboardSummary();
      this.currentClipboardMode = getClipboardPreviewMode(summary);
      this.currentText = summary;
      if (this.currentClipboardMode === 'image') {
        this.currentImage = await ClipboardUtil.getClipboardImage();
      }
      if (previousImage && previousImage !== this.currentImage) {
        void previousImage.release();
      }
    } catch (error) {
      console.error('[HomePage] loadCurrentClipboard error:', JSON.stringify(error));
      if (this.currentImage) {
        void this.currentImage.release();
      }
      this.currentImage = undefined;
      this.currentClipboardMode = 'text';
      this.currentText = 'Error reading clipboard';
    }
  }

  private async handleUpload() {
    this.syncStatus = 'Uploading...';
    try {
      const serverId = ConfigService.getInstance().getConfig().activeServerId;
      const syncService = this.createSyncService(serverId);
      const text = await ClipboardUtil.getClipboardText();
      if (!text) {
        const summary = await ClipboardUtil.getClipboardSummary();
        throw new Error(summary === 'Empty clipboard' ? 'Clipboard is empty' : 'Current clipboard is not plain text');
      }
      await syncService.uploadTextContent(text);
      if (serverId !== ConfigService.getInstance().getConfig().activeServerId) return;
      await this.syncLatestHistoryFromServer();
      this.syncStatus = 'Upload Success';
      this.currentText = text;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      console.error('[HomePage] handleUpload error:', JSON.stringify(error));
      this.syncStatus = `Upload Error: ${message || 'Unknown'}`;
    }

    this.resetSyncStatusLater();
  }

  private async pickUploadFiles(photos: boolean): Promise<void> {
    try {
      const context = AppStorage.get<Context>('abilityContext') as Context;
      let files: UploadFile[] = [];
      if (photos) {
        const result = await new picker.PhotoViewPicker().select({ maxSelectNumber: 100 });
        files = result.photoUris.map((uri: string): UploadFile => ({ uri: uri, image: true }));
      } else {
        const uris = await new picker.DocumentViewPicker(context).select({ maxSelectNumber: 100 });
        files = uris.map((uri: string): UploadFile => ({ uri: uri }));
      }
      if (files.length === 0) return;
      const server = ConfigService.getInstance().getActiveServer();
      if (!server) throw new Error('No available server');
      AlertDialog.show({
        title: this.t('Upload Files'),
        message: `${files.length} → ${server.name}`,
        primaryButton: { value: this.t('Upload Files'), action: () => {
          void this.uploadSelectedFiles(files, server.id);
        } },
        secondaryButton: { value: this.t('Cancel'), action: () => {} }
      });
    } catch (error) {
      this.syncStatus = `Upload Error: ${error instanceof Error ? error.message : String(error)}`;
    }
  }

  private async uploadSelectedFiles(files: UploadFile[], serverId: string): Promise<void> {
    if (this.uploadActive) return;
    const server = ConfigService.getInstance().getConfig().servers.find((item) => item.id === serverId);
    if (!server) {
      this.syncStatus = 'No available server';
      return;
    }
    this.uploadServerId = serverId;
    this.uploadTask = new FileUploadTask();
    this.uploadActive = true;
    this.uploadPhase = 'Preparing...';
    this.uploadReceived = 0;
    this.uploadTotal = 0;
    this.uploadSpeed = 0;
    this.uploadProgressTime = Date.now();
    this.uploadProgressBytes = 0;
    try {
      await ServerManager.getInstance().select(serverId);
      const context = AppStorage.get<Context>('abilityContext') as Context;
      const uploadedRecord = await this.uploadTask.upload(files, server, context,
        (phase: string, received: number, total: number): void => {
          const now = Date.now();
          if (phase !== this.uploadPhase) {
            this.uploadProgressTime = now;
            this.uploadProgressBytes = received;
            this.uploadReceived = received;
            this.uploadTotal = total;
            this.uploadSpeed = 0;
          }
          const elapsed = now - this.uploadProgressTime;
          if (elapsed >= 350 || received === total) {
            this.uploadSpeed = elapsed > 0 ? Math.max(0,
              (received - this.uploadProgressBytes) * 1000 / elapsed) : 0;
            this.uploadProgressTime = now;
            this.uploadProgressBytes = received;
            this.uploadReceived = received;
            this.uploadTotal = total;
          }
          this.uploadPhase = phase;
        });
      if (serverId === ConfigService.getInstance().getConfig().activeServerId) {
        await this.historyStorageService.upsertRecord(uploadedRecord, serverId);
        this.lastServerSyncAt = Date.now();
        this.historyRefreshToken += 1;
      }
      this.syncStatus = 'Upload Success';
    } catch (error) {
      this.syncStatus = `Upload Error: ${error instanceof Error ? error.message : String(error)}`;
    } finally {
      this.uploadActive = false;
      this.uploadTask = null;
      this.resetSyncStatusLater();
    }
  }

  private async performDesktopAction(request: DesktopRequest): Promise<void> {
    if (request.action === 'sync') { await this.syncRemoteClipboard(); return; }
    if (request.action === 'showLocal' || request.action === 'showRemote') {
      try {
        await ClipboardWidgetService.revealInApp(request.formId,
          request.action === 'showLocal' ? 'local' : 'remote', request.token);
      } catch (error) {
        this.syncStatus = `Sync Error: ${error instanceof Error ? error.message : String(error)}`;
        this.resetSyncStatusLater();
      }
      return;
    }
    this.uploadActive = true;
    this.syncStatus = 'Uploading...';
    try {
      await SyncCoordinator.getInstance().uploadClipboard((phase: string, received: number, total: number): void => {
        this.uploadPhase = phase; this.uploadReceived = received; this.uploadTotal = total;
      });
      this.syncStatus = 'Upload Success';
      this.historyRefreshToken += 1;
    } catch (error) {
      this.syncStatus = `Upload Error: ${error instanceof Error ? error.message : String(error)}`;
    } finally {
      this.uploadActive = false;
      this.resetSyncStatusLater();
    }
  }

  private async syncRemoteClipboard(): Promise<void> {
    if (this.manualSyncBusy) return;
    this.manualSyncBusy = true;
    this.syncStatus = 'Syncing...';
    try {
      const account = ConfigService.getInstance().getConfig().activeServerId;
      const record = await SyncCoordinator.getInstance().pullNow();
      if (ConfigService.getInstance().getConfig().activeServerId !== account) throw new Error('Server changed during operation');
      if (record.type !== 'Text') {
        this.closePreviewPanel();
        this.previewSession = new RecordPreviewSession(record, false);
        this.previewVisible = true;
        const session = this.previewSession;
        await session.prepare();
        if (!session.isActive()) throw new Error('Download canceled');
        if (session.state.error) throw new Error(session.state.error);
      }
      await this.loadCurrentClipboard();
      this.syncStatus = 'Sync Success';
    } catch (error) {
      this.syncStatus = `Sync Error: ${error instanceof Error ? error.message : String(error)}`;
    } finally { this.manualSyncBusy = false; }
    this.resetSyncStatusLater();
  }

  private async toggleRecentFavorite(item?: HistoryRecordDto): Promise<void> {
    if (!item || this.favoriteActive) return;
    const serverId = ConfigService.getInstance().getConfig().activeServerId;
    this.favoriteActive = true;
    try {
      const updated = await this.createSyncService(serverId).setHistoryStarred(item, !item.starred);
      await this.historyStorageService.upsertRecord(updated, serverId);
      if (serverId === ConfigService.getInstance().getConfig().activeServerId) {
        if (this.latestHistoryItem?.type === updated.type && this.latestHistoryItem?.hash === updated.hash) {
          this.latestHistoryItem = updated;
        }
        this.syncStatus = updated.starred ? 'Added to favorites' : 'Removed from favorites';
      }
      AppStorage.setOrCreate('historyMetadataRevision',
        (AppStorage.get<number>('historyMetadataRevision') || 0) + 1);
    } catch (error) {
      this.syncStatus = `Favorite Error: ${error instanceof Error ? error.message : String(error)}`;
    } finally {
      this.favoriteActive = false;
      this.resetSyncStatusLater();
    }
  }

  private handleRecentContentClick(item?: HistoryRecordDto): void {
    if (!item || this.previewVisible || this.downloadActive || this.copyActive) return;
    this.previewSession = new RecordPreviewSession(item);
    this.previewVisible = true;
  }

  private async copyRecentText(item?: HistoryRecordDto): Promise<void> {
    if (!item || item.type !== 'Text' || this.copyActive || this.downloadActive) return;
    const serverId = ConfigService.getInstance().getConfig().activeServerId;
    this.copyActive = true;
    try {
      const cached = RecordPreviewSession.cached(item);
      if (cached) {
        await cached.copy();
      } else {
        const service = this.createSyncService(serverId);
        const lease = await RecordCacheService.getInstance().acquire(item, serverId, service);
        try {
          const text = fs.readTextSync(lease.response.path);
          if (serverId !== ConfigService.getInstance().getConfig().activeServerId) {
            throw new Error('Server changed during operation');
          }
          await ClipboardUtil.setClipboardText(text);
        } finally { lease.release(); }
      }
      this.syncStatus = 'Copied to clipboard';
    } catch (error) {
      this.syncStatus = `Copy Error: ${error instanceof Error ? error.message : String(error)}`;
    } finally {
      this.copyActive = false;
      this.resetSyncStatusLater();
    }
  }

  private async saveRecentFile(item?: HistoryRecordDto, saveAs: boolean = false,
    galleryAuthorized: boolean = false): Promise<void> {
    if (!item || this.downloadActive || this.copyActive) {
      return;
    }
    const cached = RecordPreviewSession.cached(item);
    if (cached) {
      try { this.syncStatus = await cached.save(saveAs, galleryAuthorized); }
      catch (error) { this.syncStatus = `Save Error: ${error instanceof Error ? error.message : String(error)}`; }
      this.resetSyncStatusLater();
      return;
    }
    this.downloadActive = true;
    this.downloadSaving = false;
    this.downloadName = item.text || `${item.type}-${item.hash}`;
    this.downloadReceived = 0;
    this.downloadTotal = item.size || 0;
    this.downloadSpeed = 0;
    this.downloadNoticeId = DownloadNoticeService.begin(this.downloadName, this.downloadTotal);
    this.progressTime = Date.now();
    this.progressBytes = 0;
    this.syncStatus = 'Downloading...';
    const serverId = ConfigService.getInstance().getConfig().activeServerId;
    try {
      const lease = await RecordCacheService.getInstance().acquire(item, serverId, this.createSyncService(serverId),
        (received: number, total: number): void => this.updateDownloadProgress(received, total));
      try {
        const response = lease.response;
        if (serverId !== ConfigService.getInstance().getConfig().activeServerId) {
          throw new Error('Server changed during operation');
        }
        this.downloadReceived = response.size;
        this.downloadSaving = true;
        DownloadNoticeService.progress(this.downloadNoticeId, response.size, response.size);
        DownloadNoticeService.status(this.downloadNoticeId, 'Saving...');
        const fallbackName = item.type === 'Image'
          ? `Image-${item.hash}${ImageUtil.guessImageExtension(response.prefix)}`
          : item.type === 'Group' ? `Group-${item.hash}.zip` : `File-${item.hash}.bin`;
        const fileName = UserFileSaveUtil.suggestedFileName(response, item.text, undefined, fallbackName);
        const category = UserFileSaveUtil.category(item.type, fileName, response.contentType, response.prefix);
        if (saveAs) {
          const uri = await UserFileSaveUtil.saveAs(response, item.text, undefined, fallbackName);
          this.syncStatus = uri ? 'Saved to selected folder' : 'Save canceled';
        } else if (category === 'Image') {
          if (galleryAuthorized) {
            await UserFileSaveUtil.saveToGallery(response, item.text, fallbackName);
            this.syncStatus = 'Saved to Gallery';
          } else {
            this.galleryRecentKey = `${item.type}-${item.hash}`;
            this.syncStatus = 'Tap Save to Gallery';
          }
        } else {
          const saved = await UserFileSaveUtil.saveAutomatically(
            response, item.type, item.text, undefined, fallbackName);
          this.syncStatus = UserFileSaveUtil.savedMessage(saved);
        }
      } finally {
        lease.release();
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      console.error('[HomePage] saveRecentFile error:', JSON.stringify(error));
      this.syncStatus = `Save Error: ${message || 'Unknown'}`;
    }
    DownloadNoticeService.finish(this.downloadNoticeId, this.syncStatus, this.syncStatus.startsWith('Save Error:'));
    this.downloadNoticeId = 0;
    this.downloadActive = false;
    this.resetSyncStatusLater();
  }

  private handleRecentGalleryAuthorization(item: HistoryRecordDto | undefined, result: SaveButtonOnClickResult): void {
    if (!item) {
      return;
    }
    if (result === SaveButtonOnClickResult.SUCCESS) {
      void this.saveRecentFile(item, false, true);
    } else {
      this.syncStatus = 'Gallery authorization canceled';
      this.resetSyncStatusLater();
    }
  }

  private async togglePolling(): Promise<void> {
    const coordinator = SyncCoordinator.getInstance();
    if (this.isPollingEnabled) {
      coordinator.disable();
    } else {
      try {
        await coordinator.enable();
        this.startAutomaticPolling();
      } catch (error) {
        this.syncStatus = `Sync Error: ${error instanceof Error ? error.message : String(error)}`;
      }
    }
  }

  private handlePollingIntervalChange(): void {
    this.pollingController.stop();
    this.startAutomaticPolling();
  }

  private startAutomaticPolling(): void {
    if (!this.isPollingEnabled || this.syncPausedReason || !this.appForeground || !ConfigService.getInstance().getActiveServer()) return;
    const config = ConfigService.getInstance().getConfig();
    this.pollingController.start(config.pollingInterval, async (): Promise<void> => {
      await SyncCoordinator.getInstance().request();
    });
    void SyncCoordinator.getInstance().request();
  }

  private handlePollingEnabledChange(): void {
    this.isPolling = this.isPollingEnabled && !this.syncPausedReason;
    if (!this.isPollingEnabled) this.pollingController.stop();
  }

  private handleAutomaticStatusChange(): void {
    this.clearSyncStatusTimer();
    this.syncStatus = this.automaticSyncStatus;
  }

  private handleCurrentRemoteChange(): void {
    if (AppStorage.get<string>('currentRemoteAccount') !== this.activeServerId) return;
    this.latestHistoryToken++;
    this.latestHistoryItem = AppStorage.get<HistoryRecordDto>('currentRemoteRecord');
    this.lastServerSyncAt = this.latestHistoryItem?.lastAccessed
      ? Date.parse(this.latestHistoryItem.lastAccessed) : 0;
  }

  private handleHistoryRefreshTokenChange(): void {
    void this.syncLatestHistoryFromServer();
  }

  private handleServerRevisionChange(): void {
    DesktopActionService.cancelPending();
    void ClipboardWidgetService.resetAll();
    if (this.uploadTask && !ConfigService.getInstance().getConfig().servers.some((item) => item.id === this.uploadServerId)) this.uploadTask.cancel();
    this.closePreviewPanel();
    this.pollingController.stop();
    SyncCoordinator.getInstance().invalidate(true);
    this.latestHistoryItem = undefined;
    this.lastServerSyncAt = 0;
    void this.syncLatestHistoryFromServer();
    this.startAutomaticPolling();
  }

  private handleAppForegroundChange(): void {
    if (!this.appForeground) {
      this.pollingController.stop();
      SyncCoordinator.getInstance().invalidate();
    } else {
      this.startAutomaticPolling();
    }
  }

  private async syncLatestHistoryFromServer(): Promise<void> {
    const requestToken = ++this.latestHistoryToken;
    try {
      const serverId = ConfigService.getInstance().getConfig().activeServerId;
      if (!serverId) { this.latestHistoryItem = undefined; return; }
      const service = this.createSyncService(serverId);
      const profile = await service.getProfile();
      const record = profile.hash ? await service.getHistoryRecord(`${profile.type}-${profile.hash}`) : undefined;
      if (requestToken !== this.latestHistoryToken ||
        serverId !== ConfigService.getInstance().getConfig().activeServerId) return;
      if (record && !record.isDeleted) {
        await this.historyStorageService.upsertRecord(record, serverId);
        if (requestToken !== this.latestHistoryToken ||
          serverId !== ConfigService.getInstance().getConfig().activeServerId) return;
        this.latestHistoryItem = record;
        this.lastServerSyncAt = record.lastAccessed ? Date.parse(record.lastAccessed) : 0;
      } else {
        this.latestHistoryItem = undefined;
        this.lastServerSyncAt = 0;
      }
    } catch (error) {
      console.error('[HomePage] syncLatestHistoryFromServer error:', JSON.stringify(error));
    }
  }

  private async loadLatestHistory(): Promise<void> {
    // Current server profile, rather than the first sorted history record, owns this card.
    await this.syncLatestHistoryFromServer();
  }

  @Builder
  private ServerStatusContent() {
    if (this.syncPausedReason) {
      Text(`${this.t('Automatic sync paused: unable to determine newer content')}\n${this.t(this.syncPausedReason)}`)
        .fontSize($r('sys.float.Caption_L'))
        .fontColor(this.getPalette().danger)
        .layoutWeight(1)
    } else if (this.syncStatus === 'Idle') {
      Text(ConfigService.getInstance().getActiveServer()?.url || this.t('No available server'))
        .fontSize($r('sys.float.Caption_L'))
        .fontColor(this.serverStatusColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(`· ${this.t('Idle')}`)
        .fontSize($r('sys.float.Caption_L'))
        .fontColor(this.serverStatusColor())
    } else {
      Text(this.t(this.syncStatus))
        .fontSize($r('sys.float.Caption_L'))
        .fontColor(this.serverStatusColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
  }

  @Builder
  private RecentSyncActions() {
    Row({ space: 8 }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 4 }) {
          Column()
            .width(7)
            .height(7)
            .borderRadius(4)
            .backgroundColor(this.isPolling ? this.getPalette().success : this.getPalette().textMuted)
          Text(this.titleActionText('auto'))
            .fontSize(12)
            .lineHeight(15)
            .fontWeight(FontWeight.Medium)
            .textAlign(TextAlign.Center)
            .fontColor(this.getPalette().textPrimary)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
      }
      .width(56)
      .height(56)
      .borderRadius(14)
      .backgroundColor(this.isPolling ? this.getPalette().accentSoft : this.getPalette().elevatedBackground)
      .visualEffect(this.buttonEffect('polling'))
      .onTouch((event: TouchEvent) => this.updatePress('polling', event))
      .onClick(() => this.togglePolling())

      Button({ type: ButtonType.Normal }) {
        Text(this.titleActionText('sync'))
          .fontSize(12)
          .lineHeight(15)
          .fontWeight(FontWeight.Medium)
          .textAlign(TextAlign.Center)
          .fontColor(this.getPalette().buttonSecondaryText)
      }
      .width(56)
      .height(56)
      .borderRadius(14)
      .backgroundColor(this.getPalette().buttonSecondaryBackground)
      .visualEffect(this.buttonEffect('sync'))
      .onTouch((event: TouchEvent) => this.updatePress('sync', event))
      .enabled(!this.manualSyncBusy)
      .onClick(() => this.syncRemoteClipboard())
    }
  }

  build() {
    HdsNavigation() {
      Scroll(this.pageScroller) {
        Column({ space: 18 }) {
          Flex({ direction: this.isWideLayout() ? FlexDirection.Row : FlexDirection.Column,
            justifyContent: FlexAlign.SpaceBetween, alignItems: ItemAlign.Start }) {
        Column({ space: 16 }) {
          Row() {
            Column({ space: 4 }) {
              Text(this.t('Current Clipboard'))
                .fontSize($r('sys.float.Subtitle_L'))
                .fontWeight(FontWeight.Bold)
                .fontColor(this.getPalette().textPrimary)
              Text(this.t('The latest clipboard content detected on this device.'))
                .fontSize($r('sys.float.Body_S'))
                .fontColor(this.getPalette().textSecondary)
            }
            .alignItems(HorizontalAlign.Start)
            Blank()
            Text(this.t(this.currentClipboardMode === 'image' ? 'Image' : 'Text'))
              .fontSize($r('sys.float.Caption_M'))
              .fontColor(this.getPalette().accent)
              .padding({
                left: $r('sys.float.padding_level4'),
                right: $r('sys.float.padding_level4'),
                top: $r('sys.float.padding_level2'),
                bottom: $r('sys.float.padding_level2')
              })
              .backgroundColor(this.getPalette().accentSoft)
              .borderRadius($r('sys.float.corner_radius_level6'))
          }
          .width('100%')

          if (this.currentClipboardMode === 'image' && this.currentImage) {
            Image(this.currentImage)
              .width('100%')
              .height(160)
              .objectFit(ImageFit.Contain)
              .backgroundColor(this.getPalette().elevatedBackground)
              .borderRadius(16)
          } else {
            Text(this.clipboardDisplayText())
              .fontSize($r('sys.float.Body_M'))
              .fontColor(this.getPalette().textPrimary)
              .width('100%')
              .height(160)
              .padding(16)
              .backgroundColor(this.getPalette().elevatedBackground)
              .borderRadius(16)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .maxLines(6)
          }

          Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap,
            justifyContent: FlexAlign.End, alignItems: ItemAlign.Center }) {
            Button(this.t('Select Files'), { type: ButtonType.Capsule, controlSize: ControlSize.SMALL })
              .margin({ left: 6, top: 4 })
              .visualEffect(this.buttonEffect('pickFiles'))
              .onTouch((event: TouchEvent) => this.updatePress('pickFiles', event))
              .onClick(() => { void this.pickUploadFiles(false); })
            Button(this.t('Select Photos'), { type: ButtonType.Capsule, controlSize: ControlSize.SMALL })
              .margin({ left: 6, top: 4 })
              .visualEffect(this.buttonEffect('pickPhotos'))
              .onTouch((event: TouchEvent) => this.updatePress('pickPhotos', event))
              .onClick(() => { void this.pickUploadFiles(true); })
            if (this.currentClipboardMode === 'text') {
              Button(this.t('Upload Text'), {
                type: ButtonType.Capsule,
                buttonStyle: ButtonStyleMode.NORMAL,
                controlSize: getActionButtonSpec('home-primary').controlSize === 'small'
                  ? ControlSize.SMALL
                  : ControlSize.NORMAL
              })
                .fontColor(this.getPalette().buttonPrimaryText)
                .backgroundColor(this.getPalette().buttonPrimaryBackground)
                .margin({ left: 6, top: 4 })
                .visualEffect(this.buttonEffect('upload'))
                .onTouch((event: TouchEvent) => this.updatePress('upload', event))
                .onClick(() => this.handleUpload())
            }
          }
          .width('100%')

          if (this.uploadActive) {
            Column({ space: 8 }) {
              Text(this.t(this.uploadPhase))
                .fontSize($r('sys.float.Body_S'))
                .fontColor(this.getPalette().textPrimary)
              if (this.uploadTotal > 0) {
                Progress({ value: Math.min(this.uploadReceived, this.uploadTotal),
                  total: this.uploadTotal, type: ProgressType.Linear })
                  .width('100%')
                  .color(this.getPalette().accent)
              } else {
                LoadingProgress().width(20).height(20)
              }
              Row({ space: 8 }) {
                Text(`${LocalizationUtil.formatBytes(this.uploadReceived)}` +
                  (this.uploadTotal ? ` / ${LocalizationUtil.formatBytes(this.uploadTotal)}` : '') +
                  ` · ${LocalizationUtil.formatBytes(this.uploadSpeed)}/s`)
                  .fontSize($r('sys.float.Caption_M'))
                  .fontColor(this.getPalette().textSecondary)
                Blank()
                Button(this.t('Cancel'), { controlSize: ControlSize.SMALL })
                  .onClick(() => this.uploadTask?.cancel())
              }
            }
            .width('100%')
            .padding(12)
            .backgroundColor(this.getPalette().elevatedBackground)
            .borderRadius(16)
          }
        }
        .width(this.isWideLayout() ? '49%' : '100%')
        .padding(20)
        .linearGradient({ angle: 135, colors: [
          [this.getPalette().heroStart, 0], [this.getPalette().heroEnd, 1]
        ] })
        .border({ width: 1, color: this.getPalette().borderColor })
        .borderRadius(26)
        .shadow({ radius: 20, color: this.getPalette().shadowColor, offsetX: 0, offsetY: 8 })
        .visualEffect(this.cardEffect())

        Column({ space: 16 }) {
          Row({ space: 8 }) {
            Column({ space: 4 }) {
              Text(this.t('Recent Activity'))
                .fontSize($r('sys.float.Subtitle_L'))
                .fontWeight(FontWeight.Bold)
                .fontColor(this.getPalette().textPrimary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.t('Latest item from the server.'))
                .fontSize($r('sys.float.Body_S'))
                .fontColor(this.getPalette().textSecondary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            this.RecentSyncActions()
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)



          if (this.latestHistoryItem) {
            Column({ space: 10 }) {
              Row() {
                Row() {
                  Text(this.t(this.latestHistoryItem.type))
                    .fontSize($r('sys.float.Caption_M'))
                    .fontColor(this.getPalette().accent)
                    .padding({
                      left: $r('sys.float.padding_level4'),
                      right: $r('sys.float.padding_level4'),
                      top: $r('sys.float.padding_level2'),
                      bottom: $r('sys.float.padding_level2')
                    })
                    .backgroundColor(this.getPalette().accentSoft)
                    .borderRadius($r('sys.float.corner_radius_level6'))
                }
                  .layoutWeight(1)
                Text(this.latestHistoryItem.size !== undefined
                  ? LocalizationUtil.formatBytes(this.latestHistoryItem.size) : '—')
                  .fontSize($r('sys.float.Caption_M'))
                  .fontColor(this.getPalette().textSecondary)
                  .textAlign(TextAlign.Center)
                  .layoutWeight(1)
                Row({ space: 0 }) {
                  Text(this.formatLastServerSyncTime())
                    .fontSize($r('sys.float.Caption_M'))
                    .minFontSize(10)
                    .maxFontSize($r('sys.float.Caption_M'))
                    .maxLines(1)
                    .fontColor(this.getPalette().textSecondary)
                    .textAlign(TextAlign.End)
                    .layoutWeight(1)
                  Button(this.latestHistoryItem.starred ? '★' : '☆', { type: ButtonType.Circle })
                    .width(32)
                    .height(32)
                    .fontSize(22)
                    .fontColor(this.latestHistoryItem.starred ? (this.getPalette().isDark ? '#FFD873' : '#9C6800')
                      : this.getPalette().textSecondary)
                    .backgroundColor(Color.Transparent)
                    .accessibilityText(this.t(this.latestHistoryItem.starred ? 'Remove from favorites' : 'Add to favorites'))
                    .enabled(!this.favoriteActive)
                    .visualEffect(this.buttonEffect('recent-favorite'))
                    .onTouch((event: TouchEvent) => this.updatePress('recent-favorite', event))
                    .onClick(() => { void this.toggleRecentFavorite(this.latestHistoryItem); })
                }
                .justifyContent(FlexAlign.End)
                .layoutWeight(1)
              }
              .width('100%')

              Row({ space: 12 }) {
                Image(FileRecordDisplayUtil.icon(this.latestHistoryItem))
                  .width(28)
                  .height(28)
                  .fillColor(this.getPalette().accent)
                  .accessibilityText(this.t(this.latestHistoryItem.type))
                Text(FileRecordDisplayUtil.text(this.latestHistoryItem, this.appLanguage, this.systemLanguage))
                  .fontSize($r('sys.float.Body_M'))
                  .fontColor(this.getPalette().textPrimary)
                  .layoutWeight(1)
                  .maxLines(3)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .padding(14)
              .backgroundColor(this.latestHistoryItem.starred ? Color.Transparent : this.getPalette().elevatedBackground)
              .borderRadius(16)
              .visualEffect(this.buttonEffect('recent-content'))
              .onTouch((event: TouchEvent) => this.updatePress('recent-content', event))
              .onClick(() => { void this.handleRecentContentClick(this.latestHistoryItem); })

              if (!this.recentStatusInline()) {
                Row({ space: 4 }) {
                  this.ServerStatusContent()
                }
                  .width('100%')
                  .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                  .backgroundColor(this.getPalette().elevatedBackground)
                  .borderRadius(14)
              }

              Row({ space: 8 }) {
                if (this.recentStatusInline()) {
                  Row({ space: 4 }) {
                    this.ServerStatusContent()
                  }
                    .layoutWeight(1)
                    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                    .backgroundColor(this.getPalette().elevatedBackground)
                    .borderRadius(14)
                } else {
                  Blank()
                }
                if (this.latestHistoryItem.type === 'Text') {
                  Button(this.t('Copy Text'), { type: ButtonType.Capsule, controlSize: ControlSize.SMALL })
                    .fontColor(this.getPalette().buttonPrimaryText)
                    .backgroundColor(this.getPalette().buttonPrimaryBackground)
                    .visualEffect(this.buttonEffect('copy'))
                    .onTouch((event: TouchEvent) => this.updatePress('copy', event))
                    .onClick(() => this.copyRecentText(this.latestHistoryItem))
                } else if (this.latestHistoryItem.hasData) {
                  if (UserFileSaveUtil.isLikelyImage(this.latestHistoryItem.type, this.latestHistoryItem.text) ||
                    this.galleryRecentKey === `${this.latestHistoryItem.type}-${this.latestHistoryItem.hash}`) {
                    Stack() {
                      SaveButton({
                        icon: SaveIconStyle.FULL_FILLED,
                        text: SaveDescription.SAVE_TO_GALLERY,
                        buttonType: ButtonType.Capsule
                      })
                        .height(36)
                        .fontSize(14)
                        .iconSize(16)
                        .padding({ left: 12, right: 12, top: 0, bottom: 0 })
                        .fontColor(this.getPalette().buttonPrimaryText)
                        .backgroundColor(this.getPalette().buttonPrimaryBackground)
                        .onClick((_event: ClickEvent, result: SaveButtonOnClickResult) =>
                          this.handleRecentGalleryAuthorization(this.latestHistoryItem, result))
                    }
                    .borderRadius(18)
                    .visualEffect(this.buttonEffect('gallery'))
                    .onTouch((event: TouchEvent) => this.updatePress('gallery', event))
                  } else {
                    Button(this.t('Save File'), { type: ButtonType.Capsule, controlSize: ControlSize.SMALL })
                      .height(36)
                      .fontSize(14)
                      .fontColor(this.getPalette().buttonPrimaryText)
                      .backgroundColor(this.getPalette().buttonPrimaryBackground)
                      .visualEffect(this.buttonEffect('save'))
                      .onTouch((event: TouchEvent) => this.updatePress('save', event))
                      .onClick(() => this.saveRecentFile(this.latestHistoryItem))
                  }
                  Button(this.t('Save As'), { type: ButtonType.Capsule, controlSize: ControlSize.SMALL })
                    .height(36)
                    .fontSize(14)
                    .fontColor(this.getPalette().buttonSecondaryText)
                    .backgroundColor(this.getPalette().buttonSecondaryBackground)
                    .visualEffect(this.buttonEffect('saveAs'))
                    .onTouch((event: TouchEvent) => this.updatePress('saveAs', event))
                    .onClick(() => this.saveRecentFile(this.latestHistoryItem, true))
                }
              }
              .width('100%')
              .justifyContent(FlexAlign.End)
            }
            .width('100%')
          } else {
            Column({ space: 10 }) {
              Text(this.t('No synced history item yet. Tap Sync Now to refresh.'))
                .fontSize($r('sys.float.Body_S'))
                .fontColor(this.getPalette().textSecondary)
                .width('100%')
                .padding($r('sys.float.padding_level4'))
                .backgroundColor(this.getPalette().elevatedBackground)
                .borderRadius($r('sys.float.corner_radius_level6'))
              Row({ space: 4 }) {
                this.ServerStatusContent()
              }
                .width('100%')
                .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                .backgroundColor(this.getPalette().elevatedBackground)
                .borderRadius(14)
            }
            .width('100%')
          }
        }
        .width(this.isWideLayout() ? '49%' : '100%')
        .padding(20)
        .backgroundColor(FileRecordDisplayUtil.cardBackground(this.latestHistoryItem, this.getPalette().isDark, this.getPalette().pageSurface))
        .border({ width: 1, color: this.getPalette().borderColor })
        .borderRadius(26)
        .shadow({ radius: 20, color: this.getPalette().shadowColor, offsetX: 0, offsetY: 8 })
        .visualEffect(this.cardEffect())
        .margin({ bottom: $r('sys.float.padding_level8'), top: this.isWideLayout() ? 0 : 18 })
          }
          .width('90%')
          .alignSelf(ItemAlign.Center)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .padding({ top: 16, bottom: (this.supportsFloatingTabs ? 116 : 16) + this.safeAreaBottom })
      }
      .width('100%')
      .height('100%')
      .clip(false)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: false })
    }
    .titleBar({
      enableComponentSafeArea: true,
      content: { title: {
        mainTitle: this.t('Home'),
        subTitle: this.t('Clipboard overview and quick sync')
      } },
      style: {
        scrollEffectOpts: { scrollEffectType: this.supportsFloatingTabs
          ? ScrollEffectType.IMMERSIVE_GRADIENT_BLUR : ScrollEffectType.GRADIENT_BLUR },
        originalStyle: {
          backgroundStyle: { backgroundColor: '#00000000' },
          contentStyle: { titleStyle: {
            mainTitleColor: this.getPalette().textPrimary,
            subTitleColor: this.getPalette().textSecondary
          } }
        },
        scrollEffectStyle: {
          backgroundStyle: { backgroundColor: this.getPalette().pageBackground },
          contentStyle: { titleStyle: {
            mainTitleColor: this.getPalette().textPrimary,
            subTitleColor: this.getPalette().textSecondary
          } }
        }
      }
    })
    .titleMode(HdsNavigationTitleMode.FULL)
    .hideBackButton(true)
    .mode(NavigationMode.Stack)
    .bindSheet($$this.previewVisible, this.previewPanel(), {
      height: SheetSize.MEDIUM,
      detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      preferType: this.viewportWidth >= 600 ? SheetType.CENTER : SheetType.BOTTOM,
      showClose: true,
      backgroundColor: this.getPalette().pageSurface,
      onDisappear: () => this.closePreviewPanel()
    })
    .bindToScrollable([this.pageScroller])
    .systemBarStyle(
      { statusBarContentColor: this.getPalette().isDark ? '#FFFFFF' : '#000000' },
      { statusBarContentColor: this.getPalette().isDark ? '#FFFFFF' : '#000000' }
    )
    .width('100%')
    .height('100%')
    .backgroundColor(this.getPalette().pageBackground)
    .onAreaChange((_oldArea, newArea) => {
      this.viewportWidth = Number(newArea.width);
      this.viewportHeight = Number(newArea.height);
    })
  }
}
