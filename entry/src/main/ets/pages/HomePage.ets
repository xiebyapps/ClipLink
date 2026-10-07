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
import { hdsEffect } from '@kit.UIDesignKit';
import {
  getActionButtonSpec,
  getAutoSyncIndicatorSpec,
  getCardEffectMode,
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
  @State syncStatus: string = 'Idle';
  @State isPolling: boolean = false;
  @State useHdsEffects: boolean = false;
  @State latestHistoryItem?: HomeHistoryPreviewItem = undefined;
  @StorageLink('appTheme') appTheme: string = 'auto';
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

  private getCardLightEffect(): VisualEffect {
    return new hdsEffect.HdsEffectBuilder().pointLight({
      illuminatedType: hdsEffect.PointLightIlluminatedType.DEFAULT_FEATHERING_BORDER
    }).buildEffect();
  }

  private getCardEffect(): VisualEffect | undefined {
    if (!this.useHdsEffects || getCardEffectMode(this.getPalette().isDark) === 'none') {
      return undefined;
    }
    return this.getCardLightEffect();
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
    if (this.syncStatus.startsWith('Upload Error:') || this.syncStatus.startsWith('Download Error:')) {
      return;
    }
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
        await this.handleDownload();
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

  private async handleDownload() {
    this.syncStatus = 'Downloading...';
    try {
      const syncService = this.createSyncService();
      const text = await syncService.downloadTextContent();
      await ClipboardUtil.setClipboardText(text);
      await this.syncLatestHistoryFromServer();
      this.currentText = text || 'Empty clipboard';
      this.syncStatus = 'Download Success';
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      console.error('[HomePage] handleDownload error:', JSON.stringify(error));
      this.syncStatus = `Download Error: ${message || 'Unknown'}`;
    }

    this.resetSyncStatusLater();
  }

  private togglePolling() {
    if (this.isPolling) {
      this.pollingController.stop();
      this.isPolling = false;
      this.isPollingEnabled = false;
    } else {
      const config = ConfigService.getInstance().getConfig();
      this.pollingController.start(config.pollingInterval, async () => {
        await this.handleDownload();
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

      if (nextItem.type === 'Image' && nextItem.hasData && !nextItem.previewPixelMap) {
        const buffer = await this.createSyncService().downloadHistoryBinary(`Image-${nextItem.hash}`);
        nextItem.previewPixelMap = await ImageUtil.createPixelMapFromBuffer(buffer);
      }

      this.latestHistoryItem = nextItem;
    } catch (error) {
      console.error('[HomePage] loadLatestHistory error:', JSON.stringify(error));
    }
  }

  build() {
    Scroll() {
      Column({ space: 14 }) {
        Row() {
          Column({ space: 4 }) {
            Text('Home')
              .fontSize($r('sys.float.Title_L'))
              .fontWeight(FontWeight.Bold)
              .fontColor(this.getPalette().textPrimary)
            Text('Clipboard overview and quick sync')
              .fontSize($r('sys.float.Body_S'))
              .fontColor(this.getPalette().textSecondary)
          }
          .alignItems(HorizontalAlign.Start)
          Blank()
        }
        .width('90%')
        .margin({ top: $r('sys.float.padding_level8') })

        Text(this.syncStatus)
          .fontSize($r('sys.float.Caption_L'))
          .fontColor(
            getSyncStatusTone(this.syncStatus) === 'danger'
              ? this.getPalette().danger
              : getSyncStatusTone(this.syncStatus) === 'success'
                ? this.getPalette().success
                : this.getPalette().textSecondary
          )
          .padding({
            left: $r('sys.float.padding_level4'),
            right: $r('sys.float.padding_level4'),
            top: $r('sys.float.padding_level2'),
            bottom: $r('sys.float.padding_level2')
          })
          .backgroundColor(this.getPalette().pageSurface)
          .borderRadius($r('sys.float.corner_radius_level6'))
          .width('90%')

        Column({ space: 14 }) {
          Row() {
            Column({ space: 4 }) {
              Text('Current Clipboard')
                .fontSize($r('sys.float.Subtitle_L'))
                .fontWeight(FontWeight.Medium)
                .fontColor(this.getPalette().textPrimary)
              Text('The latest clipboard content detected on this device.')
                .fontSize($r('sys.float.Body_S'))
                .fontColor(this.getPalette().textSecondary)
            }
            .alignItems(HorizontalAlign.Start)
            Blank()
            Text(this.currentClipboardMode === 'image' ? 'Image' : 'Text')
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
              .height(140)
              .objectFit(ImageFit.Contain)
              .backgroundColor(this.getPalette().elevatedBackground)
              .borderRadius($r('sys.float.corner_radius_level6'))
          } else {
            Text(this.currentText)
              .fontSize($r('sys.float.Body_M'))
              .fontColor(this.getPalette().textPrimary)
              .width('100%')
              .height(140)
              .padding($r('sys.float.padding_level4'))
              .backgroundColor(this.getPalette().elevatedBackground)
              .borderRadius($r('sys.float.corner_radius_level6'))
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .maxLines(6)
          }

          Row({ space: 8 }) {
            Button('Upload', {
              type: ButtonType.Capsule,
              buttonStyle: ButtonStyleMode.NORMAL,
              controlSize: getActionButtonSpec('home-primary').controlSize === 'small'
                ? ControlSize.SMALL
                : ControlSize.NORMAL
            })
              .fontColor(this.getPalette().buttonPrimaryText)
              .backgroundColor(this.getPalette().buttonPrimaryBackground)
              .onClick(() => this.handleUpload())

            Button('Download', {
              type: ButtonType.Capsule,
              buttonStyle: ButtonStyleMode.NORMAL,
              controlSize: getActionButtonSpec('home-secondary').controlSize === 'small'
                ? ControlSize.SMALL
                : ControlSize.NORMAL
            })
              .fontColor(this.getPalette().buttonSecondaryText)
              .backgroundColor(this.getPalette().buttonSecondaryBackground)
              .onClick(() => this.handleDownload())
          }
          .width('100%')
          .justifyContent(FlexAlign.End)
        }
        .width('90%')
        .padding($r('sys.float.padding_level6'))
        .backgroundColor(this.getPalette().pageSurface)
        .borderRadius($r('sys.float.corner_radius_level8'))
        .shadow({ radius: 16, color: this.getPalette().shadowColor, offsetX: 0, offsetY: 6 })
        .visualEffect(this.getCardEffect())

        Column({ space: 12 }) {
          Row() {
            Column({ space: 4 }) {
              Text('Recent Activity')
                .fontSize($r('sys.float.Subtitle_L'))
                .fontWeight(FontWeight.Medium)
                .fontColor(this.getPalette().textPrimary)
              Text('Latest synced item and automation controls.')
                .fontSize($r('sys.float.Body_S'))
                .fontColor(this.getPalette().textSecondary)
            }
            .alignItems(HorizontalAlign.Start)
            Blank()
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
              Text(getAutoSyncIndicatorSpec(this.isPolling).label)
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
              .onClick(() => this.togglePolling())
          }
          .width('100%')

          if (this.latestHistoryItem) {
            Column({ space: 10 }) {
              Row() {
                Text('Latest History')
                  .fontSize($r('sys.float.Body_M'))
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.getPalette().textPrimary)
                Blank()
                Text(this.latestHistoryItem.type)
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
                  .borderRadius($r('sys.float.corner_radius_level6'))
                  .backgroundColor(this.getPalette().elevatedBackground)
              } else {
                Text(this.latestHistoryItem.text || '[No preview]')
                  .fontSize($r('sys.float.Body_M'))
                  .fontColor(this.getPalette().textPrimary)
                  .width('100%')
                  .padding($r('sys.float.padding_level4'))
                  .backgroundColor(this.getPalette().elevatedBackground)
                  .borderRadius($r('sys.float.corner_radius_level6'))
                  .maxLines(3)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }

              Row() {
                Text(this.latestHistoryItem.size ? `${this.latestHistoryItem.size} bytes` : 'Updated from history')
                  .fontSize($r('sys.float.Caption_M'))
                  .fontColor(this.getPalette().textSecondary)
                Blank()
                Text(this.isPolling ? 'Polling is active' : 'Manual sync mode')
                  .fontSize($r('sys.float.Caption_M'))
                  .fontColor(this.getPalette().textSecondary)
              }
              .width('100%')
            }
            .width('100%')
          } else {
            Text('No synced history item yet. Upload or download once to populate this section.')
              .fontSize($r('sys.float.Body_S'))
              .fontColor(this.getPalette().textSecondary)
              .width('100%')
              .padding($r('sys.float.padding_level4'))
              .backgroundColor(this.getPalette().elevatedBackground)
              .borderRadius($r('sys.float.corner_radius_level6'))
          }
        }
        .width('90%')
        .padding($r('sys.float.padding_level6'))
        .backgroundColor(this.getPalette().pageSurface)
        .borderRadius($r('sys.float.corner_radius_level8'))
        .shadow({ radius: 16, color: this.getPalette().shadowColor, offsetX: 0, offsetY: 6 })
        .visualEffect(this.getCardEffect())
        .margin({ bottom: $r('sys.float.padding_level8') })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.getPalette().pageBackground)
  }
}
