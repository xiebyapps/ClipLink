import { SettingsPolicy, NumericSettingKey } from '../utils/SettingsPolicy';
import { ThemeUtil, ThemePalette } from '../utils/ThemeUtil';
import { LocalizationUtil } from '../utils/LocalizationUtil';
import { InteractionEffectUtil } from '../utils/InteractionEffectUtil';
import { ConfigurationConstant } from '@kit.AbilityKit';

@Component
export struct NumericSettingRow {
  @Prop settingKey: NumericSettingKey = 'polling';
  @Prop title: string = '';
  @Prop help: string = '';
  @Prop details: string = '';
  @Prop @Watch('syncValue') value: number = 10;
  @Prop clearAvailable: boolean = false;
  onCommit: (value: number) => void = (): void => {};
  onClear: () => void = (): void => {};
  @State input: string = '';
  @State showHelp: boolean = false;
  @State pressed: string = '';
  @StorageLink('appTheme') appTheme: string = 'auto';
  @StorageLink('appLanguage') appLanguage: string = 'system';
  @StorageLink('systemLanguage') systemLanguage: string = 'en';
  @StorageLink('preferPureBlackInDark') pureBlack: boolean = false;
  @StorageLink('systemColorMode') colorMode: number = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;

  private palette(): ThemePalette { return ThemeUtil.getPalette(this.appTheme as 'auto' | 'light' | 'dark', this.colorMode, this.pureBlack); }
  private t(text: string): string { return LocalizationUtil.text(text, this.appLanguage, this.systemLanguage); }
  aboutToAppear(): void { this.syncValue(); }
  private syncValue(): void { this.input = String(this.value); }

  private commit(): void {
    try {
      const value = SettingsPolicy.parse(this.settingKey, this.input);
      this.input = String(value);
      if (value !== this.value) this.onCommit(value);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      const spec = SettingsPolicy.numeric(this.settingKey);
      this.getUIContext().getPromptAction().showToast({ message: `${this.t(message)} (${spec.min}–${spec.max})` });
      this.syncValue();
    }
  }

  private adjust(direction: number): void {
    let base = this.value;
    try { base = SettingsPolicy.parse(this.settingKey, this.input); } catch (_) { }
    const next = SettingsPolicy.adjust(this.settingKey, base, direction);
    this.input = String(next);
    if (next !== this.value) this.onCommit(next);
  }

  private press(id: string, event: TouchEvent): void {
    if (event.type === TouchType.Down) this.pressed = id;
    else if (event.type === TouchType.Up || event.type === TouchType.Cancel) this.pressed = '';
  }

  @Builder
  private helpContent() {
    Text(this.help).fontSize(14).fontColor(this.palette().textPrimary).padding(16).constraintSize({ maxWidth: 300 })
  }

  @Builder
  private adjustment(label: string, direction: number) {
    Button(label, { type: ButtonType.Circle }).width(36).height(36).fontSize(20)
      .fontColor(this.palette().buttonSecondaryText).backgroundColor(this.palette().buttonSecondaryBackground)
      .enabled(direction < 0 ? this.value > SettingsPolicy.numeric(this.settingKey).min : this.value < SettingsPolicy.numeric(this.settingKey).max)
      .visualEffect(InteractionEffectUtil.button(this.pressed === label, canIUse('SystemCapability.UIDesign.HDSComponent.Core')))
      .onTouch((event: TouchEvent): void => this.press(label, event))
      .accessibilityText(this.t(direction < 0 ? 'Decrease' : 'Increase'))
      .onClick((): void => this.adjust(direction))
  }

  build() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text(this.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.palette().textPrimary).layoutWeight(1)
        Button('?', { type: ButtonType.Circle }).width(28).height(28).fontSize(14)
          .fontColor(this.palette().accent).backgroundColor(this.palette().accentSoft)
          .accessibilityText(`${this.title} ${this.t('Help')}`)
          .onClick((): void => { this.showHelp = !this.showHelp; })
          .bindPopup(this.showHelp, { builder: this.helpContent, popupColor: this.palette().elevatedBackground,
            onStateChange: (event): void => { this.showHelp = event.isVisible; } })
        if (this.clearAvailable) {
          Button(this.t('Clear cache'), { controlSize: ControlSize.SMALL })
            .fontColor(this.palette().danger).backgroundColor(this.palette().buttonSecondaryBackground)
            .onClick(this.onClear)
        }
      }.width('100%')
      Row({ space: 8 }) {
        if (this.details) {
          Text(this.details).fontSize(12).fontColor(this.palette().textSecondary).layoutWeight(1)
        } else { Blank() }
        this.adjustment('−', -1)
        TextInput({ text: this.input }).type(this.settingKey === 'capacity' ? InputType.NUMBER_DECIMAL : InputType.Number)
          .width(84).height(40).textAlign(TextAlign.Center).fontSize(16)
          .fontColor(this.palette().textPrimary).backgroundColor(this.palette().inputBackground)
          .enterKeyType(EnterKeyType.Done).selectAll(true)
          .accessibilityText(this.title)
          .onChange((value: string): void => { this.input = value; })
          .onSubmit((): void => this.commit()).onBlur((): void => this.commit())
        this.adjustment('+', 1)
      }.width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 12, bottom: 12 })
  }
}
