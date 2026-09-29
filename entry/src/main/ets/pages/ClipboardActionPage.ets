import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { ClipboardBackgroundActionService } from '../services/ClipboardBackgroundActionService';
import { ClipboardTaskLease } from '../services/ClipboardTaskLease';
import { RecordPreviewPanel } from '../components/RecordPreviewPanel';
import { RecordPreviewSession } from '../services/RecordPreviewSession';
import { ClipboardActionFeedback } from '../services/ClipboardActionFeedback';
import { DownloadProgressSnackBar } from '../components/DownloadProgressSnackBar';
import { DownloadNoticeService } from '../services/DownloadNoticeService';
import { ThemeUtil, ThemePalette } from '../utils/ThemeUtil';

/** A transparent window hosts only the native sheet. No Home, navigation, or clipboard polling. */
@Entry
@Component
struct ClipboardActionPage {
  @State visible: boolean = false;
  @State mode: string = '';
  @State status: string = '';
  @State viewportWidth: number = 400;
  @State panelKey: string = '';
  private panelSequence: number = 0;
  @StorageLink('clipboardActionForeground') @Watch('foregroundChanged') actionForeground: boolean = true;
  @StorageLink('clipboardActionRevision') @Watch('refresh') revision: number = 0;
  @StorageLink('downloadNoticeRevision') @Watch('downloadChanged') noticeRevision: number = 0;
  @StorageLink('appTheme') appTheme: string = 'auto';
  @StorageLink('preferPureBlackInDark') pureBlack: boolean = false;
  @StorageLink('systemColorMode') colorMode: number = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  private session: RecordPreviewSession | null = null;
  private lease?: ClipboardTaskLease;
  private closed: boolean = false;
  private noticeOpened: boolean = false;
  private notice: CustomDialogController = new CustomDialogController({ builder: DownloadProgressSnackBar(),
    alignment: DialogAlignment.Bottom, offset: { dx: 0, dy: -24 }, autoCancel: false,
    customStyle: true, isModal: false });

  private owner(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  private palette(): ThemePalette { return ThemeUtil.getPalette(this.appTheme as 'light' | 'dark' | 'auto', this.colorMode, this.pureBlack); }
  private t(value: string): string { return ClipboardActionFeedback.text(value); }

  aboutToAppear(): void {
    this.visible = true;
    this.refresh();
    if (this.closed) return;
    void ClipboardBackgroundActionService.getInstance().foreground(
      AppStorage.get<string>('clipboardActionRequestId') || '', this.getUIContext(),
      AppStorage.get<string>('clipboardActionFormId') || '', AppStorage.get<string>('clipboardActionDirectAction') || '');
  }
  private refresh(): void {
    const service = ClipboardBackgroundActionService.getInstance();
    this.mode = service.mode; this.status = service.status;
    if (this.mode === 'complete') { this.close(); return; }
    const session = service.session || null;
    if (this.session !== session) { this.session = session; this.panelKey = `${++this.panelSequence}`; }
    if (this.session) {
      this.session.onPreparation = (loading: boolean): void => {
        if (!loading) { void this.lease?.stop(); this.lease = undefined; return; }
        if (this.lease) return;
        this.lease = new ClipboardTaskLease(this.owner(), AppStorage.get<string>('clipboardActionRequestId') || '',
          (): void => ClipboardBackgroundActionService.getInstance().previewExpired());
        try { this.lease.start('foreground'); }
        catch (_) { ClipboardBackgroundActionService.getInstance().previewExpired(); }
      };
      this.session.onTransfer = (received: number, total: number): void => { void this.lease?.progress(received, total); };
    }
  }

  private foregroundChanged(): void {
    if (this.actionForeground) this.lease?.foreground();
    else this.lease?.background();
  }

  private downloadChanged(): void {
    const snapshot = DownloadNoticeService.snapshot();
    if (snapshot.visible && !this.noticeOpened) { this.noticeOpened = true; this.notice.open(); }
    if ((!snapshot.visible || snapshot.finished) && this.lease) { void this.lease.stop(); this.lease = undefined; }
    if (!snapshot.visible && this.noticeOpened) { this.noticeOpened = false; this.notice.close(); }
  }
  private close(): void {
    if (this.closed) return;
    this.closed = true;
    this.notice.close(); void this.lease?.stop();
    const owner = this.owner();
    // Form-host updates may be slow; window exit must not wait for them.
    void ClipboardBackgroundActionService.getInstance().dismiss().catch((): void => {
      console.warn('[ClipboardAction] Card status cleanup failed');
    });
    void owner.terminateSelf().catch((): void => {
      console.warn('[ClipboardAction] Window termination failed');
      void owner.moveAbilityToBackground().catch((): void => {});
    });
  }
  private sheetWillDismiss(action: DismissSheetAction): void {
    // Native close, drag, outside tap and back can precede the two-way state update.
    this.visible = false;
    action.dismiss();
    this.close();
  }
  aboutToDisappear(): void { this.notice.close(); void this.lease?.stop(); }
  onBackPress(): boolean { this.visible = false; this.close(); return true; }

  @Builder
  private panel() {
    if (this.mode === 'panel' && this.session) {
      ForEach([this.panelKey], (_key: string) => {
        RecordPreviewPanel({ session: this.session })
      }, (key: string) => key)
    } else {
      Column({ space: 20 }) {
        Text(this.t('Clipboard action')).fontSize(22).fontWeight(FontWeight.Medium).fontColor(this.palette().textPrimary)
        Text(this.t(this.status || 'Working...')).fontSize(16).fontColor(this.palette().textSecondary)
        if (this.mode === 'authorize' || this.mode === 'running') {
          LoadingProgress().width(32).height(32)
        } else {
          Button(this.t('Close')).onClick(() => { this.visible = false; this.close(); })
        }
      }.width('100%').height('100%').padding(24).justifyContent(FlexAlign.Center)
    }
  }
  build() {
    Stack() { }
      .width('100%').height('100%').backgroundColor('#00000000')
      .onAreaChange((_old, area) => { this.viewportWidth = Number(area.width); })
      .bindSheet($$this.visible, this.panel(), { height: SheetSize.MEDIUM,
        detents: [SheetSize.MEDIUM, SheetSize.LARGE], preferType: this.viewportWidth >= 600 ? SheetType.CENTER : SheetType.BOTTOM,
        showClose: true, backgroundColor: this.palette().pageSurface,
        onWillDismiss: (action: DismissSheetAction): void => { this.sheetWillDismiss(action); },
        onDisappear: () => { if (!this.visible) this.close(); } })
  }
}
