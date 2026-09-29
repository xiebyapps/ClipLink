import { RecordCacheService } from '../services/RecordCacheService';
import { DownloadNoticeService } from '../services/DownloadNoticeService';
import { RecordPreviewPanel } from '../components/RecordPreviewPanel';
import { RecordPreviewSession } from '../services/RecordPreviewSession';
import { HistoryRecordDto } from '../types/ApiTypes';
import { HistoryStorageService } from '../services/HistoryStorageService';
import { SyncClipboardService } from '../services/SyncClipboardService';
import { ConfigService } from '../services/ConfigService';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { ImageUtil } from '../utils/ImageUtil';
import { UserFileSaveUtil } from '../utils/UserFileSaveUtil';
import { LocalizationUtil } from '../utils/LocalizationUtil';
import { InteractionEffectUtil } from '../utils/InteractionEffectUtil';
import { ThemeUtil, ThemePalette } from '../utils/ThemeUtil';
import { FileRecordDisplayUtil } from '../utils/FileRecordDisplayUtil';
import { HdsNavigation, HdsNavigationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';

const PAGE_SIZE = 30;

@Component
export default struct HistoryPage {
  @State previewVisible: boolean = false;
  private previewSession?: RecordPreviewSession;
  @State historyList: HistoryRecordDto[] = [];
  @State isLoading: boolean = false;
  @State isRefreshing: boolean = false;
  @State isLoadingMore: boolean = false;
  @State hasMore: boolean = true;
  @State galleryFileKeys: string[] = [];
  @State copyActive: boolean = false;
  @State favoriteKeys: string[] = [];
  @State downloadActive: boolean = false;
  @State downloadSaving: boolean = false;
  @State downloadName: string = '';
  @State downloadReceived: number = 0;
  @State downloadTotal: number = 0;
  @State downloadSpeed: number = 0;
  @State viewportWidth: number = 360;
  @State viewportHeight: number = 800;
  @State useHdsEffects: boolean = false;
  @State pressedButton: string = '';
  @StorageLink('historyRefreshToken') @Watch('handleHistoryRefreshTokenChange')
  historyRefreshToken: number = 0;
  @StorageLink('historyMetadataRevision') @Watch('handleHistoryMetadataChange')
  historyMetadataRevision: number = 0;
  @StorageLink('serverRevision') @Watch('handleServerRevisionChange') serverRevision: number = 0;
  @StorageLink('maxHistorySize') @Watch('handleHistoryLimitChange') maxHistorySize: number = 100;
  @StorageLink('appTheme') appTheme: string = 'auto';
  @StorageLink('floatingTabsEnabled') supportsFloatingTabs: boolean = false;
  @StorageLink('safeAreaBottom') safeAreaBottom: number = 0;
  @StorageLink('appLanguage') appLanguage: string = 'system';
  @StorageLink('systemLanguage') systemLanguage: string = 'en';
  @StorageLink('preferPureBlackInDark') preferPureBlackInDark: boolean = false;
  @StorageLink('systemColorMode') systemColorMode: number =
    ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;

  private storageService: HistoryStorageService = HistoryStorageService.getInstance();
  private currentPage: number = 1;
  private loadSeq: number = 0;
  private progressTime: number = 0;
  private progressBytes: number = 0;
  private downloadNoticeId: number = 0;
  private readonly historyScroller: Scroller = new Scroller();

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

  private activeServerId(): string {
    return ConfigService.getInstance().getConfig().activeServerId;
  }

  private isWideLayout(): boolean {
    return this.viewportWidth >= 760 && this.viewportWidth > this.viewportHeight;
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

  private getPalette(): ThemePalette {
    return ThemeUtil.getPalette(
      this.appTheme as 'light' | 'dark' | 'auto',
      this.systemColorMode,
      this.preferPureBlackInDark
    );
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

  private showActionToast(message: string, duration: number = 1600): void {
    this.getUIContext().getPromptAction().showToast({
      message: this.t(message),
      duration: duration
    });
  }

  aboutToAppear() {
    this.useHdsEffects = canIUse('SystemCapability.UIDesign.HDSComponent.Core');
    void this.initializePage();
  }

  aboutToDisappear() {
    this.closePreviewPanel();
    this.loadSeq++;
  }

  private handleHistoryRefreshTokenChange(): void {
    void this.refresh();
  }

  private handleServerRevisionChange(): void {
    this.closePreviewPanel();
    this.loadSeq++;
    this.isLoadingMore = false;
    this.historyList = [];
    void this.refresh();
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
    await ConfigService.getInstance().loadConfig();
    await this.refresh();
  }

  private async refresh(): Promise<void> {
    if (this.isLoadingMore) {
      return;
    }
    if (!ConfigService.getInstance().getActiveServer()) {
      this.historyList = []; this.hasMore = false; this.isLoading = false; this.isRefreshing = false; return;
    }
    const seq = ++this.loadSeq;
    const serverId = ConfigService.getInstance().getConfig().activeServerId;
    if (!this.isRefreshing) {
      this.isLoading = true;
    }
    this.currentPage = 1;
    this.hasMore = true;

    try {
      const syncService = this.createSyncService(serverId);

      // 1. Local first for instant UI
      const localRecords = await this.storageService.queryRecords(PAGE_SIZE, 0, serverId);
      if (seq !== this.loadSeq || serverId !== ConfigService.getInstance().getConfig().activeServerId) return;
      this.setHistoryRecords(localRecords, false);

      // 2. Server first page
      const serverRecords = await syncService.queryHistoryPage(1);
      if (seq !== this.loadSeq || serverId !== ConfigService.getInstance().getConfig().activeServerId) return;

      for (const record of serverRecords) {
        await this.storageService.upsertRecord(record, serverId);
      }
      if (seq !== this.loadSeq) return;

      const merged = await this.storageService.queryRecords(PAGE_SIZE, 0, serverId);
      if (seq !== this.loadSeq) return;
      this.setHistoryRecords(merged, false);
      this.hasMore = merged.length < this.maxHistorySize &&
        (serverRecords.length >= PAGE_SIZE || merged.length >= PAGE_SIZE);
    } catch (error) {
      console.error('[HistoryPage] refresh error:', JSON.stringify(error));
    } finally {
      if (seq === this.loadSeq) {
        this.isLoading = false;
        this.isRefreshing = false;
      }
    }
  }

  private async loadMore(): Promise<void> {
    if (this.isLoadingMore || this.isRefreshing || !this.hasMore) {
      return;
    }
    if (this.historyList.length >= this.maxHistorySize) { this.hasMore = false; return; }
    this.isLoadingMore = true;
    const seq = this.loadSeq;
    const serverId = ConfigService.getInstance().getConfig().activeServerId;
    const nextPage = this.currentPage + 1;

    try {
      const syncService = this.createSyncService(serverId);
      const serverRecords = await syncService.queryHistoryPage(nextPage);
      if (seq !== this.loadSeq || serverId !== ConfigService.getInstance().getConfig().activeServerId) return;

      if (serverRecords.length > 0) {
        for (const record of serverRecords) {
          await this.storageService.upsertRecord(record, serverId);
        }
      }
      if (seq !== this.loadSeq) return;

      const localPage = await this.storageService.queryRecords(
        PAGE_SIZE,
        this.historyList.length,
        serverId
      );
      if (seq !== this.loadSeq) return;

      if (localPage.length === 0 && serverRecords.length === 0) {
        this.hasMore = false;
      } else {
        this.appendHistoryRecords(localPage);
        this.currentPage = nextPage;
        if (this.historyList.length >= this.maxHistorySize ||
          (serverRecords.length < PAGE_SIZE && localPage.length < PAGE_SIZE)) {
          this.hasMore = false;
        }
      }
    } catch (error) {
      console.error('[HistoryPage] loadMore error:', JSON.stringify(error));
    } finally {
      if (seq === this.loadSeq) {
        this.isLoadingMore = false;
      }
    }
  }

  private setHistoryRecords(records: HistoryRecordDto[], append: boolean): void {
    const mapped = records.slice(0, this.maxHistorySize);

    if (append) {
      const seen = new Set<string>();
      this.historyList.forEach((item: HistoryRecordDto): void => {
        seen.add(`${item.type}-${item.hash}`);
      });
      const appended: HistoryRecordDto[] = [];
      mapped.forEach((item: HistoryRecordDto): void => {
        const key = `${item.type}-${item.hash}`;
        if (!seen.has(key)) {
          seen.add(key);
          appended.push(item);
        }
      });
      if (appended.length > 0) {
        this.historyList = this.historyList.concat(appended).slice(0, this.maxHistorySize);
      }
    } else {
      this.historyList = mapped;
    }
  }

  private appendHistoryRecords(records: HistoryRecordDto[]): void {
    this.setHistoryRecords(records, true);
  }

  private async handleHistoryMetadataChange(): Promise<void> {
    const serverId = ConfigService.getInstance().getConfig().activeServerId;
    const seq = this.loadSeq;
    const records = await this.storageService.queryRecords(Math.max(PAGE_SIZE, this.historyList.length), 0, serverId);
    if (seq !== this.loadSeq || serverId !== ConfigService.getInstance().getConfig().activeServerId) return;
    this.setHistoryRecords(records, false);
  }

  private handleHistoryLimitChange(): void {
    this.loadSeq++;
    this.isLoadingMore = false;
    void this.refresh();
  }

  private async toggleFavorite(item: HistoryRecordDto): Promise<void> {
    const serverId = ConfigService.getInstance().getConfig().activeServerId;
    const key = `${serverId}:${item.type}-${item.hash}`;
    if (this.favoriteKeys.includes(key)) return;
    this.favoriteKeys = this.favoriteKeys.concat([key]);
    try {
      const updated = await this.createSyncService(serverId).setHistoryStarred(item, !item.starred);
      await this.storageService.upsertRecord(updated, serverId);
      if (serverId === ConfigService.getInstance().getConfig().activeServerId) {
        this.historyList = this.historyList.map((record: HistoryRecordDto): HistoryRecordDto =>
          record.type === updated.type && record.hash === updated.hash ? updated : record);
        this.showActionToast(updated.starred ? 'Added to favorites' : 'Removed from favorites');
      }
      AppStorage.setOrCreate('historyMetadataRevision',
        (AppStorage.get<number>('historyMetadataRevision') || 0) + 1);
    } catch (error) {
      this.showActionToast(`Favorite Error: ${error instanceof Error ? error.message : String(error)}`);
    } finally {
      this.favoriteKeys = this.favoriteKeys.filter((pending: string): boolean => pending !== key);
    }
  }

  private handleItemClick(item: HistoryRecordDto): void {
    if (this.previewVisible || this.downloadActive || this.copyActive) return;
    this.previewSession = new RecordPreviewSession(item);
    this.previewVisible = true;
  }

  private async handleFileDownload(item: HistoryRecordDto, saveAs: boolean = false,
    galleryAuthorized: boolean = false): Promise<void> {
    if (this.downloadActive || this.copyActive) return;
    const cached = RecordPreviewSession.cached(item);
    if (cached) {
      try { this.showActionToast(await cached.save(saveAs, galleryAuthorized)); }
      catch (error) { this.showActionToast(`Save failed: ${error instanceof Error ? error.message : String(error)}`); }
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
    const serverId = ConfigService.getInstance().getConfig().activeServerId;
    let downloadResult: string = 'Download complete';
    let downloadFailed: boolean = false;
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
          downloadResult = uri ? 'Saved to selected folder' : 'Save canceled';
          if (uri) {
            this.showActionToast('Saved to selected folder');
          }
        } else if (category === 'Image') {
          if (!galleryAuthorized) {
            const key = `${item.type}-${item.hash}`;
            if (!this.galleryFileKeys.includes(key)) {
              this.galleryFileKeys = this.galleryFileKeys.concat([key]);
            }
            downloadResult = 'Tap Save to Gallery';
            this.showActionToast(downloadResult);
          } else {
            await UserFileSaveUtil.saveToGallery(response, item.text, fallbackName);
            downloadResult = 'Saved to Gallery';
            this.showActionToast(downloadResult);
          }
        } else {
          const saved = await UserFileSaveUtil.saveAutomatically(
            response, item.type, item.text, undefined, fallbackName);
          downloadResult = UserFileSaveUtil.savedMessage(saved);
          this.showActionToast(downloadResult);
        }
      } finally {
        lease.release();
      }
    } catch (error) {
      console.error('[HistoryPage] handleFileDownload error:', JSON.stringify(error));
      const message = error instanceof Error ? error.message : String(error);
      downloadFailed = true;
      downloadResult = `Save failed: ${message}`;
      this.showActionToast(downloadResult);
    }
    DownloadNoticeService.finish(this.downloadNoticeId, downloadResult, downloadFailed);
    this.downloadNoticeId = 0;
    this.downloadActive = false;
  }

  private handleGalleryAuthorization(item: HistoryRecordDto, result: SaveButtonOnClickResult): void {
    if (result === SaveButtonOnClickResult.SUCCESS) {
      void this.handleFileDownload(item, false, true);
    } else {
      this.showActionToast('Gallery authorization canceled');
    }
  }

  private formatDate(dateStr?: string): string {
    if (!dateStr) {
      return '—';
    }
    const date = new Date(dateStr);
    if (Number.isNaN(date.getTime())) return '—';
    const month = (date.getMonth() + 1).toString().padStart(2, '0');
    const day = date.getDate().toString().padStart(2, '0');
    const hours = date.getHours().toString().padStart(2, '0');
    const minutes = date.getMinutes().toString().padStart(2, '0');
    return `${month}/${day} ${hours}:${minutes}`;
  }

  @Builder
  private FooterBuilder() {
    if (this.isLoadingMore) {
      Row() {
        LoadingProgress().width(24).height(24)
        Text(this.t('Loading more...'))
          .fontSize($r('sys.float.Caption_M'))
          .fontColor(this.getPalette().textSecondary)
          .margin({ left: 8 })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: 12, bottom: 12 })
    } else if (!this.hasMore && this.historyList.length > 0) {
      Text(this.t('No more items'))
        .fontSize($r('sys.float.Caption_M'))
        .fontColor(this.getPalette().textSecondary)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 12, bottom: 12 })
    }
  }

  build() {
    HdsNavigation() {
      Stack({ alignContent: Alignment.Top }) {
      if (this.isLoading) {
        LoadingProgress().width(50).height(50).margin({ top: 30 })
      } else if (this.historyList.length === 0) {
        Text(this.t('No history items'))
          .fontSize($r('sys.float.Body_M'))
          .fontColor(this.getPalette().textSecondary)
          .margin({ top: 30 })
      } else {
        Refresh({ refreshing: $$this.isRefreshing }) {
          List({ space: 12, scroller: this.historyScroller }) {
            ForEach(this.historyList, (item: HistoryRecordDto) => {
              ListItem() {
                Row() {
                Column({ space: 8 }) {
                  Row() {
                    Row() {
                      Text(this.t(item.type))
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
                    Text(item.size !== undefined ? LocalizationUtil.formatBytes(item.size) : '—')
                      .fontSize($r('sys.float.Caption_M'))
                      .fontColor(this.getPalette().textSecondary)
                      .textAlign(TextAlign.Center)
                      .layoutWeight(1)
                    Row({ space: 0 }) {
                      Text(this.formatDate(item.lastAccessed))
                        .fontSize($r('sys.float.Caption_M'))
                        .minFontSize(10)
                        .maxFontSize($r('sys.float.Caption_M'))
                        .maxLines(1)
                        .fontColor(this.getPalette().textSecondary)
                        .textAlign(TextAlign.End)
                        .layoutWeight(1)
                      Button(item.starred ? '★' : '☆', { type: ButtonType.Circle })
                        .width(32)
                        .height(32)
                        .fontSize(22)
                        .fontColor(item.starred ? (this.getPalette().isDark ? '#FFD873' : '#9C6800')
                          : this.getPalette().textSecondary)
                        .backgroundColor(Color.Transparent)
                        .accessibilityText(this.t(item.starred ? 'Remove from favorites' : 'Add to favorites'))
                        .enabled(!this.favoriteKeys.includes(`${this.activeServerId()}:${item.type}-${item.hash}`))
                        .visualEffect(this.buttonEffect(`favorite-${item.type}-${item.hash}`))
                        .onTouch((event: TouchEvent) => this.updatePress(`favorite-${item.type}-${item.hash}`, event))
                        .onClick(() => { void this.toggleFavorite(item); })
                    }
                    .justifyContent(FlexAlign.End)
                    .layoutWeight(1)
                  }
                  .width('100%')

                  Row({ space: 12 }) {
                    Image(FileRecordDisplayUtil.icon(item))
                      .width(28)
                      .height(28)
                      .fillColor(this.getPalette().accent)
                      .accessibilityText(this.t(item.type))
                    Text(FileRecordDisplayUtil.text(item, this.appLanguage, this.systemLanguage))
                      .fontSize($r('sys.float.Body_M'))
                      .fontColor(this.getPalette().textPrimary)
                      .layoutWeight(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .maxLines(3)
                  }
                  .width('100%')
                  .padding(14)
                  .backgroundColor(item.starred ? Color.Transparent : this.getPalette().elevatedBackground)
                  .borderRadius(16)
                  .visualEffect(this.buttonEffect(`content-${item.type}-${item.hash}`))
                  .onTouch((event: TouchEvent) => this.updatePress(`content-${item.type}-${item.hash}`, event))
                  .onClick(() => { void this.handleItemClick(item); })

                  if (item.type !== 'Text' && item.hasData) {
                    Row({ space: 8 }) {
                      Blank()
                      if (UserFileSaveUtil.isLikelyImage(item.type, item.text) ||
                        this.galleryFileKeys.includes(`${item.type}-${item.hash}`)) {
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
                              this.handleGalleryAuthorization(item, result))
                        }
                        .borderRadius(18)
                        .visualEffect(this.buttonEffect(`gallery-${item.type}-${item.hash}`))
                        .onTouch((event: TouchEvent) =>
                          this.updatePress(`gallery-${item.type}-${item.hash}`, event))
                      } else {
                        Button(this.t('Save'), {
                          type: ButtonType.Capsule,
                          buttonStyle: ButtonStyleMode.NORMAL,
                          controlSize: ControlSize.SMALL
                        })
                          .height(36)
                          .fontSize(14)
                          .fontColor(this.getPalette().buttonPrimaryText)
                          .backgroundColor(this.getPalette().buttonPrimaryBackground)
                          .visualEffect(this.buttonEffect(`save-${item.type}-${item.hash}`))
                          .onTouch((event: TouchEvent) =>
                            this.updatePress(`save-${item.type}-${item.hash}`, event))
                          .onClick(() => this.handleFileDownload(item))
                      }
                      Button(this.t('Save As'), { type: ButtonType.Capsule, controlSize: ControlSize.SMALL })
                        .height(36)
                        .fontSize(14)
                        .fontColor(this.getPalette().buttonSecondaryText)
                        .backgroundColor(this.getPalette().buttonSecondaryBackground)
                        .visualEffect(this.buttonEffect(`saveAs-${item.type}-${item.hash}`))
                        .onTouch((event: TouchEvent) =>
                          this.updatePress(`saveAs-${item.type}-${item.hash}`, event))
                        .onClick(() => this.handleFileDownload(item, true))
                    }
                    .width('100%')
                  }
                }
                .width('90%')
                .padding(16)
                .backgroundColor(FileRecordDisplayUtil.cardBackground(item, this.getPalette().isDark, this.getPalette().pageSurface))
                .border({ width: 1, color: this.getPalette().borderColor })
                .borderRadius(24)
                .shadow({ radius: 14, color: this.getPalette().shadowColor, offsetX: 0, offsetY: 5 })
                .visualEffect(this.cardEffect())
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)
              }
            }, (item: HistoryRecordDto) =>
              `${item.type}-${item.hash}-${item.version || 0}-${item.lastAccessed || ''}-${item.starred ? 1 : 0}`)

            ListItem() {
              this.FooterBuilder()
            }
          }
          .width('100%')
          .height('100%')
          .lanes(this.isWideLayout() ? 2 : 1, 12)
          // Keep cards behind the translucent title bar drawing outside the List viewport.
          .cachedCount(4, true)
          .contentStartOffset(16)
          .contentEndOffset((this.supportsFloatingTabs ? 116 : 16) + this.safeAreaBottom)
          .clip(false)
          .onReachEnd(() => {
            void this.loadMore();
          })
        }
        .width('100%')
        .height('100%')
        .clip(false)
        .onRefreshing(() => {
          void this.refresh();
        })
      }


      }
      .width('100%')
      .height('100%')
    }
    .titleBar({
      enableComponentSafeArea: true,
      content: { title: {
        mainTitle: this.t('History'),
        subTitle: this.t('Browse and save synced items')
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
    .bindToScrollable([this.historyScroller])
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
