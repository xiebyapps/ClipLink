import { HistoryRecordDto } from '../types/ApiTypes';
import { HistoryStorageService } from '../services/HistoryStorageService';
import { SyncClipboardService } from '../services/SyncClipboardService';
import { ConfigService } from '../services/ConfigService';
import { ClipboardUtil } from '../utils/ClipboardUtil';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { ImageUtil } from '../utils/ImageUtil';
import { UserFileSaveUtil } from '../utils/UserFileSaveUtil';
import { LocalizationUtil } from '../utils/LocalizationUtil';
import { InteractionEffectUtil } from '../utils/InteractionEffectUtil';
import { ThemeUtil, ThemePalette } from '../utils/ThemeUtil';
import { getHistoryActionFeedback, getHistoryListStyleSpec } from '../utils/PageScaffoldUtil';
import { HdsNavigation, HdsNavigationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';

interface HistoryViewItem extends HistoryRecordDto {
  previewPixelMap?: image.PixelMap;
}

const PAGE_SIZE = 30;
const PREVIEW_CONCURRENCY = 3;

@Component
export default struct HistoryPage {
  @State historyList: HistoryViewItem[] = [];
  @State isLoading: boolean = false;
  @State isRefreshing: boolean = false;
  @State isLoadingMore: boolean = false;
  @State hasMore: boolean = true;
  @State galleryFileKeys: string[] = [];
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
  @StorageLink('appTheme') appTheme: string = 'auto';
  @StorageLink('floatingTabsEnabled') supportsFloatingTabs: boolean = false;
  @StorageLink('safeAreaBottom') safeAreaBottom: number = 0;
  @StorageLink('appLanguage') appLanguage: string = 'system';
  @StorageLink('systemLanguage') systemLanguage: string = 'en';
  @StorageLink('preferPureBlackInDark') preferPureBlackInDark: boolean = false;
  @StorageLink('systemColorMode') systemColorMode: number =
    ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;

  private storageService: HistoryStorageService = HistoryStorageService.getInstance();
  private readonly listStyle = getHistoryListStyleSpec();
  private currentPage: number = 1;
  private loadSeq: number = 0;
  private progressTime: number = 0;
  private progressBytes: number = 0;
  private readonly historyScroller: Scroller = new Scroller();

  private t(value: string): string {
    return LocalizationUtil.text(value, this.appLanguage, this.systemLanguage);
  }

  private isWideLayout(): boolean {
    return this.viewportWidth >= 760 && this.viewportWidth > this.viewportHeight;
  }

  private updateDownloadProgress(received: number, total: number): void {
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
    this.releasePreviewImages();
  }

  private handleHistoryRefreshTokenChange(): void {
    void this.refresh();
  }

  private createSyncService(): SyncClipboardService {
    const config = ConfigService.getInstance().getConfig();
    return new SyncClipboardService(
      config.server.url,
      config.server.username,
      config.server.password
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
    const seq = ++this.loadSeq;
    if (!this.isRefreshing) {
      this.isLoading = true;
    }
    this.currentPage = 1;
    this.hasMore = true;

    try {
      const syncService = this.createSyncService();

      // 1. Local first for instant UI
      const localRecords = await this.storageService.queryRecords(PAGE_SIZE, 0);
      if (seq !== this.loadSeq) return;
      this.setHistoryRecords(localRecords, false);
      void this.loadImagePreviews(syncService, seq);

      // 2. Server first page
      const serverRecords = await syncService.queryHistoryPage(1);
      if (seq !== this.loadSeq) return;

      for (const record of serverRecords) {
        await this.storageService.upsertRecord(record);
      }
      if (seq !== this.loadSeq) return;

      const merged = await this.storageService.queryRecords(PAGE_SIZE, 0);
      if (seq !== this.loadSeq) return;
      this.setHistoryRecords(merged, false);
      this.hasMore = serverRecords.length >= PAGE_SIZE || merged.length >= PAGE_SIZE;
      void this.loadImagePreviews(syncService, seq);
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
    this.isLoadingMore = true;
    const seq = this.loadSeq;
    const nextPage = this.currentPage + 1;

    try {
      const syncService = this.createSyncService();
      const serverRecords = await syncService.queryHistoryPage(nextPage);
      if (seq !== this.loadSeq) return;

      if (serverRecords.length > 0) {
        for (const record of serverRecords) {
          await this.storageService.upsertRecord(record);
        }
      }
      if (seq !== this.loadSeq) return;

      const localPage = await this.storageService.queryRecords(
        PAGE_SIZE,
        this.historyList.length
      );
      if (seq !== this.loadSeq) return;

      if (localPage.length === 0 && serverRecords.length === 0) {
        this.hasMore = false;
      } else {
        this.appendHistoryRecords(localPage);
        this.currentPage = nextPage;
        if (serverRecords.length < PAGE_SIZE && localPage.length < PAGE_SIZE) {
          this.hasMore = false;
        }
        void this.loadImagePreviews(syncService, seq);
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
    const existing = new Map<string, image.PixelMap>();
    const keepKeys = new Set<string>();
    records.forEach((r: HistoryRecordDto): void => {
      keepKeys.add(`${r.type}-${r.hash}`);
    });

    this.historyList.forEach((item: HistoryViewItem): void => {
      const key = `${item.type}-${item.hash}`;
      if (item.previewPixelMap) {
        if (keepKeys.has(key) || append) {
          existing.set(key, item.previewPixelMap);
        } else {
          void item.previewPixelMap.release();
        }
      }
    });

    const mapped: HistoryViewItem[] = records.map((record: HistoryRecordDto) =>
      this.createHistoryViewItem(record, existing.get(`${record.type}-${record.hash}`))
    );

    if (append) {
      const seen = new Set<string>();
      this.historyList.forEach((item: HistoryViewItem): void => {
        seen.add(`${item.type}-${item.hash}`);
      });
      const appended: HistoryViewItem[] = [];
      mapped.forEach((item: HistoryViewItem): void => {
        const key = `${item.type}-${item.hash}`;
        if (!seen.has(key)) {
          seen.add(key);
          appended.push(item);
        }
      });
      if (appended.length > 0) {
        this.historyList = this.historyList.concat(appended);
      }
    } else {
      this.historyList = mapped;
    }
  }

  private appendHistoryRecords(records: HistoryRecordDto[]): void {
    this.setHistoryRecords(records, true);
  }

  private createHistoryViewItem(
    record: HistoryRecordDto,
    previewPixelMap?: image.PixelMap
  ): HistoryViewItem {
    return {
      hash: record.hash,
      type: record.type,
      text: record.text,
      createTime: record.createTime,
      lastModified: record.lastModified,
      lastAccessed: record.lastAccessed,
      starred: record.starred,
      pinned: record.pinned,
      size: record.size,
      hasData: record.hasData,
      version: record.version,
      isDeleted: record.isDeleted,
      previewPixelMap: previewPixelMap
    };
  }

  private async loadImagePreviews(syncService: SyncClipboardService, seq: number): Promise<void> {
    const pending: HistoryViewItem[] = this.historyList.filter((item: HistoryViewItem): boolean =>
      item.type === 'Image' && !!item.hasData && !item.previewPixelMap &&
      (!item.size || item.size <= 4 * 1024 * 1024)
    );
    if (pending.length === 0) return;

    let cursor = 0;
    const worker = async (): Promise<void> => {
      while (cursor < pending.length) {
        if (seq !== this.loadSeq) return;
        const item = pending[cursor++];
        try {
          const buffer = await syncService.downloadHistoryBinary(`${item.type}-${item.hash}`);
          if (seq !== this.loadSeq) return;
          const pixelMap = await ImageUtil.createPixelMapFromBuffer(buffer);
          if (seq !== this.loadSeq) {
            void pixelMap.release();
            return;
          }
          this.applyPreview(item.type, item.hash, pixelMap);
        } catch (error) {
          console.error('[HistoryPage] loadImagePreviews error:', JSON.stringify(error));
        }
      }
    };

    const workerCount = Math.min(PREVIEW_CONCURRENCY, pending.length);
    const workers: Promise<void>[] = [];
    for (let i = 0; i < workerCount; i++) {
      workers.push(worker());
    }
    await Promise.all(workers);
  }

  private applyPreview(type: string, hash: string, pixelMap: image.PixelMap): void {
    const idx = this.historyList.findIndex((i: HistoryViewItem): boolean =>
      i.type === type && i.hash === hash
    );
    if (idx < 0) {
      void pixelMap.release();
      return;
    }
    const current = this.historyList[idx];
    if (current.previewPixelMap) {
      void pixelMap.release();
      return;
    }
    const next: HistoryViewItem[] = this.historyList.slice();
    next[idx] = this.createHistoryViewItem(current, pixelMap);
    this.historyList = next;
  }

  private releasePreviewImages(): void {
    this.historyList.forEach((item: HistoryViewItem): void => {
      void item.previewPixelMap?.release();
    });
  }

  private async handleItemClick(item: HistoryViewItem) {
    try {
      if (item.type === 'Text') {
        const text = item.hasData
          ? await this.createSyncService().downloadHistoryText(`Text-${item.hash}`)
          : (item.text || '');
        await ClipboardUtil.setClipboardText(text);
        const feedback = getHistoryActionFeedback('copy-text', true);
        this.showActionToast(feedback.message, feedback.duration);
        return;
      }

      if (item.type === 'Image' && item.hasData) {
        const binary = await this.createSyncService().downloadHistoryBinary(`Image-${item.hash}`);
        const pixelMap = item.previewPixelMap ?? await ImageUtil.createPixelMapFromBuffer(binary);
        await ClipboardUtil.setClipboardImage(pixelMap);
        const feedback = getHistoryActionFeedback('copy-image', true);
        this.showActionToast(feedback.message, feedback.duration);
        if (!item.previewPixelMap) {
          void pixelMap.release();
        }
      }
    } catch (error) {
      console.error('[HistoryPage] handleItemClick error:', JSON.stringify(error));
      const feedback = getHistoryActionFeedback('copy-text', false);
      this.showActionToast(feedback.message, feedback.duration);
    }
  }

  private async handleFileDownload(item: HistoryViewItem, saveAs: boolean = false,
    galleryAuthorized: boolean = false): Promise<void> {
    if (this.downloadActive) return;
    this.downloadActive = true;
    this.downloadSaving = false;
    this.downloadName = item.text || `${item.type}-${item.hash}`;
    this.downloadReceived = 0;
    this.downloadTotal = item.size || 0;
    this.downloadSpeed = 0;
    this.progressTime = Date.now();
    this.progressBytes = 0;
    try {
      const temporaryPath = UserFileSaveUtil.temporaryDownloadPath();
      try {
        const response = await this.createSyncService().downloadHistoryFileToPath(
          `${item.type}-${item.hash}`, temporaryPath,
          (received: number, total: number): void => this.updateDownloadProgress(received, total));
        this.downloadReceived = response.size;
        this.downloadSaving = true;
        const fallbackName = item.type === 'Image'
          ? `Image-${item.hash}${ImageUtil.guessImageExtension(response.prefix)}`
          : item.type === 'Group' ? `Group-${item.hash}.zip` : `File-${item.hash}.bin`;
        const fileName = UserFileSaveUtil.suggestedFileName(response, item.text, undefined, fallbackName);
        const category = UserFileSaveUtil.category(item.type, fileName, response.contentType, response.prefix);
        if (saveAs) {
          const uri = await UserFileSaveUtil.saveAs(response, item.text, undefined, fallbackName);
          if (uri) {
            this.showActionToast('Saved to selected folder');
          }
        } else if (category === 'Image') {
          if (!galleryAuthorized) {
            const key = `${item.type}-${item.hash}`;
            if (!this.galleryFileKeys.includes(key)) {
              this.galleryFileKeys = this.galleryFileKeys.concat([key]);
            }
            this.showActionToast('Tap Save to Gallery');
          } else {
            await UserFileSaveUtil.saveToGallery(response, item.text, fallbackName);
            this.showActionToast('Saved to Gallery');
          }
        } else {
          const saved = await UserFileSaveUtil.saveAutomatically(
            response, item.type, item.text, undefined, fallbackName);
          this.showActionToast(`Saved to Download/com.xiebaiyuan.syncclipboard.harmony/云剪/${saved.category}`);
        }
      } finally {
        UserFileSaveUtil.removeTemporaryDownload(temporaryPath);
      }
    } catch (error) {
      console.error('[HistoryPage] handleFileDownload error:', JSON.stringify(error));
      const message = error instanceof Error ? error.message : String(error);
      this.showActionToast(`Save failed: ${message}`);
    }
    this.downloadActive = false;
  }

  private handleGalleryAuthorization(item: HistoryViewItem, result: SaveButtonOnClickResult): void {
    if (result === SaveButtonOnClickResult.SUCCESS) {
      void this.handleFileDownload(item, false, true);
    } else {
      this.showActionToast('Gallery authorization canceled');
    }
  }

  private formatDate(dateStr?: string): string {
    if (!dateStr) {
      return '';
    }
    try {
      const date = new Date(dateStr);
      return `${date.getMonth() + 1}/${date.getDate()} ${date.getHours()}:${date.getMinutes().toString().padStart(2, '0')}`;
    } catch (error) {
      return dateStr;
    }
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
            ForEach(this.historyList, (item: HistoryViewItem) => {
              ListItem() {
                Row() {
                Column({ space: 8 }) {
                  Row() {
                    Text(this.t(item.type))
                      .fontSize($r('sys.float.Body_S'))
                      .fontWeight(FontWeight.Bold)
                      .fontColor(this.getPalette().accent)
                      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                      .backgroundColor(this.getPalette().accentSoft)
                      .borderRadius(12)

                    Blank()

                    if (item.starred) {
                      Text('★')
                        .fontSize($r('sys.float.Body_L'))
                        .fontColor('#FFD700')
                    }

                    Text(this.formatDate(item.lastAccessed))
                      .fontSize($r('sys.float.Caption_M'))
                      .fontColor(this.getPalette().textSecondary)
                  }
                  .width('100%')

                  if (item.type === 'Image') {
                    if (item.previewPixelMap) {
                      Image(item.previewPixelMap)
                        .width('100%')
                        .height(this.listStyle.previewHeight)
                        .objectFit(ImageFit.Contain)
                        .borderRadius(16)
                        .backgroundColor(this.getPalette().elevatedBackground)
                        .visualEffect(this.buttonEffect(`preview-${item.type}-${item.hash}`))
                        .onTouch((event: TouchEvent) =>
                          this.updatePress(`preview-${item.type}-${item.hash}`, event))
                        .onClick(() => this.handleItemClick(item))
                    } else {
                      Text(this.t(item.hasData && item.size && item.size > 4 * 1024 * 1024
                        ? '[Preview omitted for large image]'
                        : item.hasData ? '[Image loading...]' : '[Image preview unavailable]'))
                        .fontSize($r('sys.float.Body_M'))
                        .fontColor(this.getPalette().textSecondary)
                        .width('100%')
                        .padding(14)
                        .backgroundColor(this.getPalette().elevatedBackground)
                        .borderRadius(16)
                        .visualEffect(this.buttonEffect(`preview-${item.type}-${item.hash}`))
                        .onTouch((event: TouchEvent) =>
                          this.updatePress(`preview-${item.type}-${item.hash}`, event))
                        .onClick(() => this.handleItemClick(item))
                    }
                  } else {
                      Text(item.text || this.t('[No preview]'))
                        .fontSize($r('sys.float.Body_M'))
                        .fontColor(this.getPalette().textPrimary)
                        .width('100%')
                        .padding(14)
                        .backgroundColor(this.getPalette().elevatedBackground)
                        .borderRadius(16)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .maxLines(3)
                        .visualEffect(this.buttonEffect(`preview-${item.type}-${item.hash}`))
                        .onTouch((event: TouchEvent) =>
                          this.updatePress(`preview-${item.type}-${item.hash}`, event))
                        .onClick(() => this.handleItemClick(item))
                  }

                  if (item.size) {
                    Text(LocalizationUtil.formatBytes(item.size))
                      .fontSize($r('sys.float.Caption_M'))
                      .fontColor(this.getPalette().textSecondary)
                  }

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
                .backgroundColor(this.getPalette().pageSurface)
                .border({ width: 1, color: this.getPalette().borderColor })
                .borderRadius(24)
                .shadow({ radius: 14, color: this.getPalette().shadowColor, offsetX: 0, offsetY: 5 })
                .visualEffect(this.cardEffect())
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)
              }
            }, (item: HistoryRecordDto) => `${item.type}-${item.hash}`)

            ListItem() {
              this.FooterBuilder()
            }
          }
          .width('100%')
          .height('100%')
          .lanes(this.isWideLayout() ? 2 : 1, 12)
          .contentStartOffset(this.downloadActive ? 112 : 16)
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

      if (this.downloadActive) {
        Column({ space: 6 }) {
          Text(`${this.t(this.downloadSaving ? 'Saving...' : 'Downloading...')} ${this.downloadName}`)
            .fontSize($r('sys.float.Body_S'))
            .fontColor(this.getPalette().textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          if (this.downloadTotal > 0) {
            Progress({ value: Math.min(this.downloadReceived, this.downloadTotal),
              total: this.downloadTotal, type: ProgressType.Linear })
              .width('100%')
              .color(this.getPalette().accent)
          } else {
            LoadingProgress().width(20).height(20)
          }
          Text(`${LocalizationUtil.formatBytes(this.downloadReceived)}` +
            (this.downloadTotal > 0 ? ` / ${LocalizationUtil.formatBytes(this.downloadTotal)}` : '') +
            ` · ${LocalizationUtil.formatBytes(this.downloadSpeed)}/s` +
            (this.downloadTotal > 0 ? ` · ${Math.min(100, Math.floor(this.downloadReceived * 100 / this.downloadTotal))}%` : ''))
            .fontSize($r('sys.float.Caption_M'))
            .fontColor(this.getPalette().textSecondary)
            .width('100%')
        }
        .width('90%')
        .padding(16)
        .backgroundColor(this.getPalette().elevatedBackground)
        .borderRadius(20)
        .visualEffect(this.cardEffect())
        .margin({ top: 8 })
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
