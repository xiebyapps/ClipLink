import { ConfigurationConstant } from '@kit.AbilityKit';
import { RecordPreviewSession, PreviewState } from '../services/RecordPreviewSession';
import { LocalizationUtil } from '../utils/LocalizationUtil';
import { ThemeUtil, ThemePalette } from '../utils/ThemeUtil';

@Component
export struct RecordPreviewPanel {
  session: RecordPreviewSession | null = null;
  @State name: string = '';
  @State fullText: string = '';
  @State status: string = 'Preparing...';
  @State error: string = '';
  @State received: number = 0;
  @State total: number = 0;
  @State speed: number = 0;
  @State loading: boolean = true;
  @State ready: boolean = false;
  @State supported: boolean = false;
  @State isImage: boolean = false;
  @State busy: boolean = false;
  @StorageLink('serverRevision') @Watch('serverChanged') serverRevision: number = 0;
  @StorageLink('appLanguage') appLanguage: string = 'system';
  @StorageLink('systemLanguage') systemLanguage: string = 'en';
  @StorageLink('appTheme') appTheme: string = 'auto';
  @StorageLink('preferPureBlackInDark') preferPureBlackInDark: boolean = false;
  @StorageLink('systemColorMode') systemColorMode: number = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;

  private t(value: string): string {
    return LocalizationUtil.text(value, this.appLanguage, this.systemLanguage);
  }

  private getSession(): RecordPreviewSession {
    if (!this.session) throw new Error('Preview session is not initialized');
    return this.session;
  }

  private palette(): ThemePalette {
    return ThemeUtil.getPalette(this.appTheme as 'light' | 'dark' | 'auto',
      this.systemColorMode, this.preferPureBlackInDark);
  }

  private update(state: PreviewState): void {
    this.name = state.name;
    this.fullText = state.fullText;
    this.status = state.status;
    this.error = state.error;
    this.received = state.received;
    this.total = state.total;
    this.speed = state.speed;
    this.loading = state.loading;
    this.ready = state.ready;
    this.supported = state.supported;
    this.isImage = state.image;
    this.busy = state.busy;
  }

  aboutToAppear(): void {
    this.update(this.getSession().state);
    this.getSession().onChange = (state: PreviewState): void => this.update(state);
    void this.getSession().prepare();
  }

  aboutToDisappear(): void { this.getSession().close(); }

  private serverChanged(): void {
    this.getSession().close();
    this.ready = false;
    this.loading = false;
    this.status = 'Server changed during operation';
    this.error = '';
  }

  private async action(kind: string, authorized: boolean = false): Promise<void> {
    try {
      const message = kind === 'copy' ? await this.getSession().copy()
        : await this.getSession().save(kind === 'saveAs', authorized);
      if (!this.getSession().isActive()) return;
      this.status = message;
      this.error = '';
      this.getUIContext().getPromptAction().showToast({ message: this.t(message) });
    } catch (error) {
      if (!this.getSession().isActive()) return;
      this.status = kind === 'copy' ? 'Copy failed' : 'Save failed';
      this.error = error instanceof Error ? error.message : String(error);
    }
  }

  @Builder
  circularAction(label: string, icon: Resource, kind: string) {
    Column({ space: 4 }) {
      Button({ type: ButtonType.Circle }) {
        Image(icon).width(22).height(22).fillColor(this.palette().buttonSecondaryText)
      }
      .width(44).height(44)
      .backgroundColor(this.palette().buttonSecondaryBackground)
      .enabled(this.ready && !this.busy)
      .accessibilityText(this.t(label))
      .onClick(() => { void this.action(kind); })
      Text(this.t(label)).fontSize(12).fontColor(this.palette().textSecondary)
    }
  }

  build() {
    Column({ space: 16 }) {
      Row({ space: 12 }) {
        Text(this.getSession().record.type === 'Text' ? this.t('Text preview') : this.name)
          .fontSize(20).fontWeight(FontWeight.Medium)
          .fontColor(this.palette().textPrimary).layoutWeight(1).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.total > 0 || this.ready ? LocalizationUtil.formatBytes(this.total) : '—')
          .fontSize(12).fontColor(this.palette().textMuted).maxLines(1).flexShrink(0)
      }
      .width('100%').alignItems(VerticalAlign.Center)
      .padding({ right: 40 })
      Row({ space: 20 }) {
        if (this.getSession().record.type === 'Text' || this.isImage) {
          this.circularAction('Copy', $r('app.media.preview_copy'), 'copy')
        }
        if (this.getSession().record.type !== 'Text') {
          if (this.isImage) {
            Column({ space: 4 }) {
              SaveButton({ icon: SaveIconStyle.LINES, buttonType: ButtonType.Circle })
                .width(44).height(44).iconSize(22)
                .backgroundColor(this.palette().buttonSecondaryBackground)
                .fontColor(this.palette().buttonSecondaryText)
                .enabled(this.ready && !this.busy)
                .onClick((_event: ClickEvent, result: SaveButtonOnClickResult) => {
                  if (result === SaveButtonOnClickResult.SUCCESS) void this.action('save', true);
                  else {
                    this.status = 'Gallery authorization canceled';
                    this.error = '';
                    this.getUIContext().getPromptAction().showToast({ message: this.t(this.status) });
                  }
                })
              Text(this.t('Save')).fontSize(12).fontColor(this.palette().textSecondary)
            }
            .accessibilityGroup(true).accessibilityText(this.t('Save to Gallery'))
          } else {
            this.circularAction('Save', $r('app.media.preview_save'), 'save')
          }
          this.circularAction('Save As', $r('app.media.preview_save_as'), 'saveAs')
        }
      }
      .width('100%').justifyContent(FlexAlign.Start)
      Scroll() {
        Column({ space: 14 }) {
          if (this.error ||
            (this.ready && !this.supported && this.getSession().record.type !== 'Text')) {
            Text(this.t(this.status)).width('100%').fontSize(14).fontColor(this.palette().textSecondary)
          }
          if (this.ready && this.getSession().record.type === 'Text') {
            Text(this.fullText).width('100%').fontSize(16)
              .fontColor(this.palette().textPrimary)
              .textAlign(TextAlign.Start)
          } else if (this.ready) {
            Button(this.t('Open system preview')).enabled(this.supported && !this.busy)
              .onClick(() => { void this.getSession().openPreview(); })
          }

          if (this.error) {
            Text(this.t(this.error)).width('100%').fontSize(14).fontColor(this.palette().danger)
          }
          if (!this.loading && !this.ready) {
            Button(this.t('Retry')).onClick(() => { void this.getSession().prepare(); })
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1).width('100%')
      .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
    }
    .width('100%').height('100%').padding({ left: 24, right: 24, top: 12, bottom: 24 })
    .backgroundColor(this.palette().pageSurface)
  }
}
