import { ConfigurationConstant } from '@kit.AbilityKit';
import { DownloadNoticeService } from '../services/DownloadNoticeService';
import { LocalizationUtil } from '../utils/LocalizationUtil';
import { ThemeUtil, ThemePalette } from '../utils/ThemeUtil';

/** Snackbar-style custom content hosted in a native, non-modal dialog. */
@CustomDialog
export struct DownloadProgressSnackBar {
  controller?: CustomDialogController;
  @StorageLink('downloadNoticeRevision') @Watch('update') noticeRevision: number = 0;
  @StorageLink('appLanguage') appLanguage: string = 'system';
  @StorageLink('systemLanguage') systemLanguage: string = 'en';
  @StorageLink('appTheme') appTheme: string = 'auto';
  @StorageLink('preferPureBlackInDark') preferPureBlackInDark: boolean = false;
  @StorageLink('systemColorMode') systemColorMode: number = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  @State name: string = '';
  @State status: string = 'Downloading...';
  @State received: number = 0;
  @State total: number = 0;
  @State speed: number = 0;
  @State finished: boolean = false;
  @State failed: boolean = false;

  private update(): void {
    const snapshot = DownloadNoticeService.snapshot();
    this.name = snapshot.name;
    this.status = snapshot.status;
    this.received = snapshot.received;
    this.total = snapshot.total;
    this.speed = snapshot.speed;
    this.finished = snapshot.finished;
    this.failed = snapshot.failed;
  }

  aboutToAppear(): void { this.update(); }

  private t(value: string): string {
    return LocalizationUtil.text(value, this.appLanguage, this.systemLanguage);
  }

  private palette(): ThemePalette {
    return ThemeUtil.getPalette(this.appTheme as 'light' | 'dark' | 'auto',
      this.systemColorMode, this.preferPureBlackInDark);
  }

  build() {
    Column({ space: 8 }) {
      Text(`${this.t(this.status)} ${this.name}`)
        .width('100%').fontSize(14)
        .fontColor(this.failed ? this.palette().danger : this.palette().textPrimary)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.total > 0) {
        Progress({ value: Math.min(this.received, this.total), total: this.total, type: ProgressType.Linear })
          .width('100%').color(this.failed ? this.palette().danger : this.palette().accent)
      } else if (!this.finished) {
        LoadingProgress().width(20).height(20)
      }
      Text(`${LocalizationUtil.formatBytes(this.received)}` +
        (this.total > 0 ? ` / ${LocalizationUtil.formatBytes(this.total)}` : '') +
        ` · ${LocalizationUtil.formatBytes(this.speed)}/s` +
        (this.total > 0 ? ` · ${Math.min(100, Math.floor(this.received * 100 / this.total))}%` : ''))
        .width('100%').fontSize(12).fontColor(this.palette().textSecondary)
    }
    .padding(16).width('90%').constraintSize({ maxWidth: 480 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(this.palette().cardBackground)
    .backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR)
    .borderRadius(24)
    .border({ width: 1, color: this.palette().borderColor })
    .shadow({ radius: 16, color: this.palette().shadowColor, offsetY: 4 })
  }
}
