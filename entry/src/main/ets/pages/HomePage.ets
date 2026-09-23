import { ClipboardUtil } from '../utils/ClipboardUtil';
import { SyncClipboardService } from '../services/SyncClipboardService';
import { ConfigService } from '../services/ConfigService';
import { PollingController } from '../services/PollingController';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { ThemeUtil, ThemePalette } from '../utils/ThemeUtil';
import { HistoryStorageService } from '../services/HistoryStorageService';
import { HistoryRecordDto } from '../types/ApiTypes';
import { image } from '@kit.ImageKit';
import { ImageUtil } from '../utils/ImageUtil';
import { UserFileSaveUtil } from '../utils/UserFileSaveUtil';
import { LocalizationUtil } from '../utils/LocalizationUtil';
import { InteractionEffectUtil } from '../utils/InteractionEffectUtil';
import { HdsNavigation, HdsNavigationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';
import {
  getActionButtonSpec,
  getAutoSyncIndicatorSpec,
  getClipboardPreviewMode,
  getSyncStatusTone
} from '../utils/PageScaffoldUtil';

interface HomeHistoryPreviewItem extends HistoryRecordDto {
  previewPixelMap?: image.PixelMap;
}

@Component
export default struct HomePage {
  @State currentText: string = '';
  @State currentImage?: image.PixelMap = undefined;
  @State currentClipboardMode: 'text' | 'image' = 'text';
  @State galleryRecentKey: string = '';
  @State syncStatus: string = 'Idle';
  @State isPolling: boolean = false;
  @State useHdsEffects: boolean = false;
  @State pressedButton: string = '';
  @State latestHistoryItem?: HomeHistoryPreviewItem = undefined;
  @State downloadActive: boolean = false;
  @State downloadSaving: boolean = false;
  @State downloadName: string = '';
  @State downloadReceived: number = 0;
  @State downloadTotal: number = 0;
  @State downloadSpeed: number = 0;
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
  @StorageLink('isPollingEnabled') isPollingEnabled: boolean = false;
  @StorageLink('historyRefreshToken') @Watch('handleHistoryRefreshTokenChange')
  historyRefreshToken: number = 0;
  private pollingController: PollingController = new PollingController();
  private historyStorageService: HistoryStorageService = HistoryStorageService.getInstance();
  private syncStatusTimer: number = -1;
  private initToken: number = 0;
  private progressTime: number = 0;
  private progressBytes: number = 0;
  private readonly pageScroller: Scroller = new Scroller();
  private readonly clipboardUpdateHandler = (): void => {
    void this.loadCurrentClipboard();
  };

  private getPalette(): ThemePalette {
    return ThemeUtil.getPalette(
      this.appTheme as 'light' | 'dark' | 'auto',
      this.systemColorMode,
      this.preferPureBlackInDark
    );
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
    this.initToken++;
    ClipboardUtil.offUpdate(this.clipboardUpdateHandler);
    this.clearSyncStatusTimer();
    this.pollingController.dispose();
    void this.currentImage?.release();
    void this.latestHistoryItem?.previewPixelMap?.release();
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

  private createSyncService(): SyncClipboardService {
    const config = ConfigService.getInstance().getConfig();
    return new SyncClipboardService(
      config.server.url,
      config.server.username,
      config.server.password
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
    void this.syncLatestHistoryFromServer();
    if (currentToken !== this.initToken) {
      return;
    }
    this.isPolling = this.isPollingEnabled;
    if (this.isPollingEnabled) {
      const config = ConfigService.getInstance().getConfig();
      if (currentToken !== this.initToken) {
        return;
      }
      this.pollingController.start(config.pollingInterval, async () => {
        await this.syncRemoteClipboard();
      });
    }
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
      const syncService = this.createSyncService();
      const text = await ClipboardUtil.getClipboardText();
      if (!text) {
        const summary = await ClipboardUtil.getClipboardSummary();
        throw new Error(summary === 'Empty clipboard' ? 'Clipboard is empty' : 'Current clipboard is not plain text');
      }
      await syncService.uploadTextContent(text);
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

  private async syncRemoteClipboard(): Promise<void> {
    this.syncStatus = 'Syncing...';
    try {
      const syncService = this.createSyncService();
      const profile = await syncService.getProfile();
      if (profile.type === 'Text') {
        const text = await syncService.downloadTextFromProfile(profile);
        await ClipboardUtil.setClipboardText(text);
        this.currentText = text || 'Empty clipboard';
        this.syncStatus = 'Text synced to clipboard';
      } else {
        this.syncStatus = 'File available in Recent Activity';
      }
      await this.syncLatestHistoryFromServer();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      console.error('[HomePage] syncRemoteClipboard error:', JSON.stringify(error));
      this.syncStatus = `Sync Error: ${message || 'Unknown'}`;
    }
    this.resetSyncStatusLater();
  }

  private async copyRecentText(item?: HomeHistoryPreviewItem): Promise<void> {
    if (!item) {
      return;
    }
    try {
      const text = item.hasData
        ? await this.createSyncService().downloadHistoryText(`Text-${item.hash}`)
        : item.text || '';
      await ClipboardUtil.setClipboardText(text);
      this.syncStatus = 'Copied to clipboard';
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.syncStatus = `Copy Error: ${message}`;
    }
    this.resetSyncStatusLater();
  }

  private async saveRecentFile(item?: HomeHistoryPreviewItem, saveAs: boolean = false,
    galleryAuthorized: boolean = false): Promise<void> {
    if (!item || this.downloadActive) {
      return;
    }
    this.downloadActive = true;
    this.downloadSaving = false;
    this.downloadName = item.text || `${item.type}-${item.hash}`;
    this.downloadReceived = 0;
    this.downloadTotal = item.size || 0;
    this.downloadSpeed = 0;
    this.progressTime = Date.now();
    this.progressBytes = 0;
    this.syncStatus = 'Downloading...';
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
          this.syncStatus = `Saved to Download/com.xiebaiyuan.syncclipboard.harmony/云剪/${saved.category}`;
        }
      } finally {
        UserFileSaveUtil.removeTemporaryDownload(temporaryPath);
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      console.error('[HomePage] saveRecentFile error:', JSON.stringify(error));
      this.syncStatus = `Save Error: ${message || 'Unknown'}`;
    }
    this.downloadActive = false;
    this.resetSyncStatusLater();
  }

  private handleRecentGalleryAuthorization(item: HomeHistoryPreviewItem | undefined, result: SaveButtonOnClickResult): void {
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

  private togglePolling() {
    if (this.isPolling) {
      this.pollingController.stop();
      this.isPolling = false;
      this.isPollingEnabled = false;
    } else {
      const config = ConfigService.getInstance().getConfig();
      this.pollingController.start(config.pollingInterval, async () => {
        await this.syncRemoteClipboard();
      });
      this.isPolling = true;
      this.isPollingEnabled = true;
    }
  }

  private handleHistoryRefreshTokenChange(): void {
    void this.loadLatestHistory();
  }

  private async syncLatestHistoryFromServer(): Promise<void> {
    try {
      const records = await this.createSyncService().queryHistoryPages(1);
      if (records.length > 0) {
        await this.historyStorageService.upsertRecord(records[0]);
      }
    } catch (error) {
      console.error('[HomePage] syncLatestHistoryFromServer error:', JSON.stringify(error));
    } finally {
      this.historyRefreshToken += 1;
    }
  }

  private async loadLatestHistory(): Promise<void> {
    try {
      const records = await this.historyStorageService.queryRecords(1);
      const nextRecord = records.length > 0 ? records[0] : undefined;
      const previousPixelMap = this.latestHistoryItem?.previewPixelMap;
      if (!nextRecord) {
        if (previousPixelMap) {
          void previousPixelMap.release();
        }
        this.latestHistoryItem = undefined;
        return;
      }

      const nextItem: HomeHistoryPreviewItem = {
        hash: nextRecord.hash,
        type: nextRecord.type,
        text: nextRecord.text,
        createTime: nextRecord.createTime,
        lastModified: nextRecord.lastModified,
        lastAccessed: nextRecord.lastAccessed,
        starred: nextRecord.starred,
        pinned: nextRecord.pinned,
        size: nextRecord.size,
        hasData: nextRecord.hasData,
        version: nextRecord.version,
        isDeleted: nextRecord.isDeleted
      };

      if (
        previousPixelMap &&
        this.latestHistoryItem &&
        this.latestHistoryItem.type === nextItem.type &&
        this.latestHistoryItem.hash === nextItem.hash
      ) {
        nextItem.previewPixelMap = previousPixelMap;
      } else if (previousPixelMap) {
        void previousPixelMap.release();
      }

      if (nextItem.type === 'Image' && nextItem.hasData && !nextItem.previewPixelMap &&
        (!nextItem.size || nextItem.size <= 4 * 1024 * 1024)) {
        const buffer = await this.createSyncService().downloadHistoryBinary(`Image-${nextItem.hash}`);
        nextItem.previewPixelMap = await ImageUtil.createPixelMapFromBuffer(buffer);
      }

      this.latestHistoryItem = nextItem;
    } catch (error) {
      console.error('[HomePage] loadLatestHistory error:', JSON.stringify(error));
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

          if (this.currentClipboardMode === 'text') {
            Row() {
              Button(this.t('Upload Text'), {
                type: ButtonType.Capsule,
                buttonStyle: ButtonStyleMode.NORMAL,
                controlSize: getActionButtonSpec('home-primary').controlSize === 'small'
                  ? ControlSize.SMALL
                  : ControlSize.NORMAL
              })
                .fontColor(this.getPalette().buttonPrimaryText)
                .backgroundColor(this.getPalette().buttonPrimaryBackground)
                .visualEffect(this.buttonEffect('upload'))
                .onTouch((event: TouchEvent) => this.updatePress('upload', event))
                .onClick(() => this.handleUpload())
            }
            .width('100%')
            .justifyContent(FlexAlign.End)
          } else {
            Text(this.t('Only text can be uploaded from this screen.'))
              .fontSize($r('sys.float.Caption_M'))
              .fontColor(this.getPalette().textSecondary)
              .width('100%')
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
          Column({ space: 4 }) {
            Text(this.t('Recent Activity'))
              .fontSize($r('sys.float.Subtitle_L'))
              .fontWeight(FontWeight.Bold)
              .fontColor(this.getPalette().textPrimary)
            Text(this.t('Recent server item and sync controls.'))
              .fontSize($r('sys.float.Body_S'))
              .fontColor(this.getPalette().textSecondary)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          Row({ space: 8 }) {
            Text(this.t(this.syncStatus))
              .fontSize($r('sys.float.Caption_L'))
              .fontColor(getSyncStatusTone(this.syncStatus) === 'danger'
                ? this.getPalette().danger
                : getSyncStatusTone(this.syncStatus) === 'success'
                  ? this.getPalette().success
                  : this.getPalette().accent)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor(this.getPalette().elevatedBackground)
              .borderRadius(14)
            Row({ space: 8 }) {
              Column()
                .width(8)
                .height(8)
                .borderRadius(4)
                .backgroundColor(
                  getAutoSyncIndicatorSpec(this.isPolling).tone === 'success'
                    ? this.getPalette().success
                    : this.getPalette().textMuted
                )
              Text(this.t(getAutoSyncIndicatorSpec(this.isPolling).label))
                .fontSize($r('sys.float.Body_S'))
                .fontWeight(FontWeight.Medium)
                .fontColor(this.getPalette().textPrimary)
            }
              .padding({
                left: $r('sys.float.padding_level4'),
                right: $r('sys.float.padding_level4'),
                top: $r('sys.float.padding_level2'),
                bottom: $r('sys.float.padding_level2')
              })
              .backgroundColor(this.isPolling ? this.getPalette().accentSoft : this.getPalette().elevatedBackground)
              .borderRadius($r('sys.float.corner_radius_level12'))
              .visualEffect(this.buttonEffect('polling'))
              .onTouch((event: TouchEvent) => this.updatePress('polling', event))
              .onClick(() => this.togglePolling())
          }
          .width('100%')

          Row() {
            Blank()
            Button(this.t('Sync Now'), {
              type: ButtonType.Capsule,
              buttonStyle: ButtonStyleMode.NORMAL,
              controlSize: getActionButtonSpec('home-secondary').controlSize === 'small'
                ? ControlSize.SMALL
                : ControlSize.NORMAL
            })
              .fontColor(this.getPalette().buttonSecondaryText)
              .backgroundColor(this.getPalette().buttonSecondaryBackground)
              .visualEffect(this.buttonEffect('sync'))
              .onTouch((event: TouchEvent) => this.updatePress('sync', event))
              .onClick(() => this.syncRemoteClipboard())
          }
          .width('100%')

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
            .width('100%')
            .padding($r('sys.float.padding_level4'))
            .backgroundColor(this.getPalette().elevatedBackground)
            .borderRadius($r('sys.float.corner_radius_level6'))
            .visualEffect(this.cardEffect())
          }

          if (this.latestHistoryItem) {
            Column({ space: 10 }) {
              Row() {
                Text(this.t('Latest History'))
                  .fontSize($r('sys.float.Body_M'))
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.getPalette().textPrimary)
                Blank()
                Text(this.t(this.latestHistoryItem.type))
                  .fontSize($r('sys.float.Caption_M'))
                  .fontColor(this.getPalette().accent)
                  .padding({
                    left: $r('sys.float.padding_level3'),
                    right: $r('sys.float.padding_level3'),
                    top: $r('sys.float.padding_level1'),
                    bottom: $r('sys.float.padding_level1')
                  })
                  .backgroundColor(this.getPalette().accentSoft)
                  .borderRadius($r('sys.float.corner_radius_level4'))
              }
              .width('100%')

              if (this.latestHistoryItem.type === 'Image' && this.latestHistoryItem.previewPixelMap) {
                Image(this.latestHistoryItem.previewPixelMap)
                  .width('100%')
                  .height(132)
                  .objectFit(ImageFit.Contain)
                  .borderRadius(16)
                  .backgroundColor(this.getPalette().elevatedBackground)
              } else {
                Text(this.latestHistoryItem.type === 'Image' && this.latestHistoryItem.size &&
                  this.latestHistoryItem.size > 4 * 1024 * 1024
                  ? this.t('[Preview omitted for large image]')
                  : this.latestHistoryItem.text || this.t('[No preview]'))
                  .fontSize($r('sys.float.Body_M'))
                  .fontColor(this.getPalette().textPrimary)
                  .width('100%')
                  .padding(14)
                  .backgroundColor(this.getPalette().elevatedBackground)
                  .borderRadius(16)
                  .maxLines(3)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }

              Row() {
                Text(this.latestHistoryItem.size ? LocalizationUtil.formatBytes(this.latestHistoryItem.size)
                  : this.t('Updated from history'))
                  .fontSize($r('sys.float.Caption_M'))
                  .fontColor(this.getPalette().textSecondary)
                Blank()
                Text(this.t(this.isPolling ? 'Polling is active' : 'Manual sync mode'))
                  .fontSize($r('sys.float.Caption_M'))
                  .fontColor(this.getPalette().textSecondary)
              }
              .width('100%')

              Row({ space: 8 }) {
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
            Text(this.t('No synced history item yet. Tap Sync Now to refresh.'))
              .fontSize($r('sys.float.Body_S'))
              .fontColor(this.getPalette().textSecondary)
              .width('100%')
              .padding($r('sys.float.padding_level4'))
              .backgroundColor(this.getPalette().elevatedBackground)
              .borderRadius($r('sys.float.corner_radius_level6'))
          }
        }
        .width(this.isWideLayout() ? '49%' : '100%')
        .padding(20)
        .backgroundColor(this.getPalette().pageSurface)
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
