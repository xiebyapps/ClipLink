import { ConfigService } from '../services/ConfigService';
import { AppConfig, ServerConfig } from '../types/ApiTypes';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { ThemeUtil, ThemePalette } from '../utils/ThemeUtil';
import { getActionButtonSpec, getSettingsSectionSpecs } from '../utils/PageScaffoldUtil';
import { LocalizationUtil } from '../utils/LocalizationUtil';
import { InteractionEffectUtil } from '../utils/InteractionEffectUtil';
import { SyncClipboardService } from '../services/SyncClipboardService';
import { HdsNavigation, HdsNavigationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';

@Component
export default struct SettingsPage {
  @State serverUrl: string = '';
  @State username: string = '';
  @State password: string = '';
  @State pollingInterval: number = 5;
  @State theme: string = 'auto';
  @State languagePreference: string = 'system';
  @State preferPureBlackInDark: boolean = false;
  @State historySize: number = 100;
  @State saveStatus: string = '';
  @State connectionVerified: boolean = false;
  @State connectionChecking: boolean = false;
  @State viewportWidth: number = 360;
  @State viewportHeight: number = 800;
  @State useHdsEffects: boolean = false;
  @State pressedButton: string = '';
  @StorageLink('appTheme') appTheme: string = 'auto';
  @StorageLink('appLanguage') appLanguage: string = 'system';
  @StorageLink('systemLanguage') systemLanguage: string = 'en';
  @StorageLink('floatingTabsEnabled') supportsFloatingTabs: boolean = false;
  @StorageLink('safeAreaBottom') safeAreaBottom: number = 0;
  @StorageLink('preferPureBlackInDark') storedPureBlackPreference: boolean = false;
  @StorageLink('systemColorMode') systemColorMode: number =
    ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  private saveStatusTimer: number = -1;
  private connectionEpoch: number = 0;
  private readonly pageScroller: Scroller = new Scroller();
  private readonly sectionSpecs = getSettingsSectionSpecs();

  private configService: ConfigService = ConfigService.getInstance();

  private t(value: string): string {
    return LocalizationUtil.text(value, this.appLanguage, this.systemLanguage);
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

  private isWideLayout(): boolean {
    return this.viewportWidth >= 760 && this.viewportWidth > this.viewportHeight;
  }

  private invalidateConnection(): void {
    this.connectionEpoch++;
    this.connectionVerified = false;
    this.connectionChecking = false;
  }

  private async verifyConnection(server: ServerConfig, epoch: number, reportResult: boolean): Promise<void> {
    this.connectionVerified = false;
    this.connectionChecking = false;
    if (!server.url.trim()) {
      if (reportResult) {
        this.saveStatus = 'Saved, but connection failed';
      }
      return;
    }
    this.connectionChecking = true;
    try {
      await new SyncClipboardService(server.url, server.username, server.password).queryHistoryPage(1);
      if (epoch !== this.connectionEpoch) return;
      this.connectionVerified = true;
      if (reportResult) {
        this.saveStatus = 'Saved successfully';
        this.resetSaveStatusLater();
      }
    } catch (error) {
      if (epoch !== this.connectionEpoch) return;
      console.error('[SettingsPage] verifyConnection error:', JSON.stringify(error));
      this.connectionVerified = false;
      if (reportResult) {
        this.saveStatus = 'Saved, but connection failed';
      }
    } finally {
      if (epoch === this.connectionEpoch) this.connectionChecking = false;
    }
  }

  aboutToAppear() {
    this.useHdsEffects = canIUse('SystemCapability.UIDesign.HDSComponent.Core');
    void this.initializePage();
  }

  aboutToDisappear() {
    this.clearSaveStatusTimer();
  }

  private async initializePage() {
    await this.configService.loadConfig();
    this.loadConfig();
    const server = this.configService.getConfig().server;
    const epoch = ++this.connectionEpoch;
    await this.verifyConnection(server, epoch, false);
  }

  private loadConfig() {
    const config = this.configService.getConfig();
    this.serverUrl = config.server.url;
    this.username = config.server.username || '';
    this.password = config.server.password || '';
    this.pollingInterval = config.pollingInterval;
    this.theme = config.theme;
    this.languagePreference = config.language;
    this.preferPureBlackInDark = config.preferPureBlackInDark;
    this.historySize = config.maxHistorySize;
  }

  private clearSaveStatusTimer() {
    if (this.saveStatusTimer !== -1) {
      clearTimeout(this.saveStatusTimer);
      this.saveStatusTimer = -1;
    }
  }

  private resetSaveStatusLater() {
    this.clearSaveStatusTimer();
    this.saveStatusTimer = setTimeout(() => {
      this.saveStatus = '';
      this.saveStatusTimer = -1;
    }, 2000);
  }

  private async handleThemeSelect(index: number): Promise<void> {
    const selectedTheme = index === 0 ? 'light' : index === 1 ? 'dark' : 'auto';
    this.theme = selectedTheme;
    this.appTheme = selectedTheme;
    await ThemeUtil.applyTheme(
      selectedTheme as 'light' | 'dark' | 'auto',
      this.systemColorMode,
      this.preferPureBlackInDark
    );
    try {
      const currentConfig = this.configService.getConfig();
      await this.configService.saveConfig({
        server: currentConfig.server,
        pollingInterval: currentConfig.pollingInterval,
        theme: selectedTheme as 'light' | 'dark' | 'auto',
        language: currentConfig.language,
        preferPureBlackInDark: this.preferPureBlackInDark,
        maxHistorySize: currentConfig.maxHistorySize
      });
      this.storedPureBlackPreference = this.preferPureBlackInDark;
      this.saveStatus = 'Theme updated';
      this.resetSaveStatusLater();
    } catch (error) {
      console.error('[SettingsPage] handleThemeSelect error:', JSON.stringify(error));
      this.saveStatus = 'Theme update failed';
    }
  }

  private async handlePureBlackToggle(isOn: boolean): Promise<void> {
    this.preferPureBlackInDark = isOn;
    this.storedPureBlackPreference = isOn;
    await ThemeUtil.applyTheme(
      this.theme as 'light' | 'dark' | 'auto',
      this.systemColorMode,
      isOn
    );
    try {
      const currentConfig = this.configService.getConfig();
      await this.configService.saveConfig({
        server: currentConfig.server,
        pollingInterval: currentConfig.pollingInterval,
        theme: this.theme as 'light' | 'dark' | 'auto',
        language: currentConfig.language,
        preferPureBlackInDark: isOn,
        maxHistorySize: currentConfig.maxHistorySize
      });
      this.saveStatus = isOn ? 'Pure black enabled' : 'Pure black disabled';
      this.resetSaveStatusLater();
    } catch (error) {
      console.error('[SettingsPage] handlePureBlackToggle error:', JSON.stringify(error));
      this.saveStatus = 'Theme update failed';
    }
  }

  private async handleLanguageSelect(index: number): Promise<void> {
    const selected: 'system' | 'zh-CN' | 'en-US' = index === 1 ? 'zh-CN' : index === 2 ? 'en-US' : 'system';
    const currentConfig = this.configService.getConfig();
    try {
      await this.configService.saveConfig({
        server: currentConfig.server,
        pollingInterval: currentConfig.pollingInterval,
        theme: currentConfig.theme,
        language: selected,
        preferPureBlackInDark: currentConfig.preferPureBlackInDark,
        maxHistorySize: currentConfig.maxHistorySize
      });
      this.languagePreference = selected;
      this.appLanguage = selected;
      this.saveStatus = 'Language updated';
      this.resetSaveStatusLater();
    } catch (error) {
      console.error('[SettingsPage] handleLanguageSelect error:', JSON.stringify(error));
      this.saveStatus = 'Language update failed';
    }
  }

  private async handleSave() {
    const epoch = ++this.connectionEpoch;
    this.connectionVerified = false;
    this.connectionChecking = false;
    try {
      const config: AppConfig = {
        server: {
          type: 'syncclipboard',
          url: this.serverUrl,
          username: this.username,
          password: this.password
        },
        pollingInterval: this.pollingInterval,
        theme: this.theme as 'light' | 'dark' | 'auto',
        language: this.languagePreference as 'system' | 'zh-CN' | 'en-US',
        preferPureBlackInDark: this.preferPureBlackInDark,
        maxHistorySize: this.historySize
      };

      await this.configService.saveConfig(config);
      this.appTheme = config.theme;
      this.appLanguage = config.language;
      this.storedPureBlackPreference = config.preferPureBlackInDark;
      await ThemeUtil.applyTheme(config.theme, this.systemColorMode, config.preferPureBlackInDark);
      if (epoch === this.connectionEpoch) {
        this.saveStatus = 'Checking connection...';
        await this.verifyConnection(config.server, epoch, true);
      }
    } catch (error) {
      console.error('[SettingsPage] handleSave error:', JSON.stringify(error));
      this.saveStatus = 'Save failed';
    }
  }

  @Builder
  private Stepper(id: string, value: number, onDec: () => void, onInc: () => void) {
    Row({ space: 8 }) {
      Button('-', {
        type: ButtonType.Capsule,
        buttonStyle: ButtonStyleMode.NORMAL,
        controlSize: ControlSize.SMALL
      })
        .fontColor(this.getPalette().buttonSecondaryText)
        .backgroundColor(this.getPalette().buttonSecondaryBackground)
        .visualEffect(this.buttonEffect(`${id}-dec`))
        .onTouch((event: TouchEvent) => this.updatePress(`${id}-dec`, event))
        .onClick(onDec)

      Text(value.toString())
        .fontSize($r('sys.float.Body_M'))
        .fontWeight(FontWeight.Medium)
        .fontColor(this.getPalette().textPrimary)
        .width(36)
        .textAlign(TextAlign.Center)

      Button('+', {
        type: ButtonType.Capsule,
        buttonStyle: ButtonStyleMode.NORMAL,
        controlSize: ControlSize.SMALL
      })
        .fontColor(this.getPalette().buttonSecondaryText)
        .backgroundColor(this.getPalette().buttonSecondaryBackground)
        .visualEffect(this.buttonEffect(`${id}-inc`))
        .onTouch((event: TouchEvent) => this.updatePress(`${id}-inc`, event))
        .onClick(onInc)
    }
    .padding({
      left: $r('sys.float.padding_level2'),
      right: $r('sys.float.padding_level2'),
      top: $r('sys.float.padding_level2'),
      bottom: $r('sys.float.padding_level2')
    })
    .backgroundColor(this.getPalette().elevatedBackground)
    .borderRadius($r('sys.float.corner_radius_level8'))
    .visualEffect(this.cardEffect())
  }

  build() {
    HdsNavigation() {
      Scroll(this.pageScroller) {
        Column({ space: 18 }) {
          Flex({ direction: this.isWideLayout() ? FlexDirection.Row : FlexDirection.Column,
            justifyContent: FlexAlign.SpaceBetween, alignItems: ItemAlign.Start }) {
        Column({ space: 16 }) {
          Row({ space: 8 }) {
            Text(this.t(this.sectionSpecs[0].title))
              .fontSize($r('sys.float.Subtitle_L'))
              .fontWeight(FontWeight.Bold)
              .fontColor(this.connectionVerified ? this.getPalette().success : this.getPalette().textPrimary)
            if (this.connectionVerified || this.connectionChecking) {
              Text(this.t(this.connectionVerified ? 'Connected' : 'Checking connection...'))
                .fontSize($r('sys.float.Caption_M'))
                .fontColor(this.getPalette().success)
            }
          }
          Text(this.t(this.sectionSpecs[0].description))
            .fontSize($r('sys.float.Body_S'))
            .fontColor(this.getPalette().textSecondary)

          Column({ space: 12 }) {
            Column({ space: 6 }) {
              Text(this.t('Server URL'))
                .fontSize($r('sys.float.Body_M'))
                .fontColor(this.getPalette().textSecondary)
                .alignSelf(ItemAlign.Start)
              TextInput({ text: this.serverUrl })
                .width('100%')
                .height(48)
                .backgroundColor(this.getPalette().inputBackground)
                .fontColor(this.getPalette().textPrimary)
                .border({ width: 1, color: this.getPalette().borderColor })
                .borderRadius(16)
                .onChange((value: string) => {
                  this.serverUrl = value;
                  this.invalidateConnection();
                })
            }

            Column({ space: 6 }) {
              Text(this.t('Username'))
                .fontSize($r('sys.float.Body_M'))
                .fontColor(this.getPalette().textSecondary)
                .alignSelf(ItemAlign.Start)
              TextInput({ text: this.username })
                .width('100%')
                .height(48)
                .backgroundColor(this.getPalette().inputBackground)
                .fontColor(this.getPalette().textPrimary)
                .border({ width: 1, color: this.getPalette().borderColor })
                .borderRadius(16)
                .onChange((value: string) => {
                  this.username = value;
                  this.invalidateConnection();
                })
            }

            Column({ space: 6 }) {
              Text(this.t('Password'))
                .fontSize($r('sys.float.Body_M'))
                .fontColor(this.getPalette().textSecondary)
                .alignSelf(ItemAlign.Start)
              TextInput({ text: this.password })
                .width('100%')
                .type(InputType.Password)
                .height(48)
                .backgroundColor(this.getPalette().inputBackground)
                .fontColor(this.getPalette().textPrimary)
                .border({ width: 1, color: this.getPalette().borderColor })
                .borderRadius(16)
                .onChange((value: string) => {
                  this.password = value;
                  this.invalidateConnection();
                })
            }
          }
          .width('100%')

          Button(this.t('Save Connection'), {
            type: ButtonType.Capsule,
            buttonStyle: ButtonStyleMode.NORMAL,
            controlSize: getActionButtonSpec('settings-save').controlSize === 'small'
              ? ControlSize.SMALL
              : ControlSize.NORMAL
          })
            .alignSelf(ItemAlign.End)
            .height(44)
            .fontColor(this.getPalette().buttonPrimaryText)
            .backgroundColor(this.getPalette().buttonPrimaryBackground)
            .visualEffect(this.buttonEffect('saveConnection'))
            .onTouch((event: TouchEvent) => this.updatePress('saveConnection', event))
            .onClick(() => this.handleSave())
        }
        .width(this.isWideLayout() ? '49%' : '100%')
        .padding(20)
        .backgroundColor(this.connectionVerified ? this.getPalette().successSurface : this.getPalette().pageSurface)
        .border({ width: 1,
          color: this.connectionVerified ? this.getPalette().successBorder : this.getPalette().borderColor })
        .borderRadius(26)
        .shadow({ radius: 20, color: this.getPalette().shadowColor, offsetX: 0, offsetY: 8 })
        .visualEffect(this.cardEffect())

        Column({ space: 16 }) {
          Text(this.t(this.sectionSpecs[1].title))
            .fontSize($r('sys.float.Subtitle_L'))
            .fontWeight(FontWeight.Bold)
            .fontColor(this.getPalette().textPrimary)
          Text(this.t(this.sectionSpecs[1].description))
            .fontSize($r('sys.float.Body_S'))
            .fontColor(this.getPalette().textSecondary)

          Column() {
            Row() {
              Column({ space: 2 }) {
                Text(this.t('Polling Interval'))
                  .fontSize($r('sys.float.Body_M'))
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.getPalette().textPrimary)
                Text(this.t('How often the app pulls from the server when auto sync is enabled.'))
                  .fontSize($r('sys.float.Caption_M'))
                  .fontColor(this.getPalette().textSecondary)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              this.Stepper(
                'polling',
                this.pollingInterval,
                () => {
                  if (this.pollingInterval > 1) {
                    this.pollingInterval--;
                  }
                },
                () => {
                  if (this.pollingInterval < 60) {
                    this.pollingInterval++;
                  }
                }
              )
            }
            .width('100%')
            .padding({ top: 6, bottom: 6 })

            Divider()
              .strokeWidth(1)
              .color(this.getPalette().borderColor)

            Row() {
              Column({ space: 2 }) {
                Text(this.t('Theme'))
                  .fontSize($r('sys.float.Body_M'))
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.getPalette().textPrimary)
                Text(this.t('Applies immediately, including dark mode.'))
                  .fontSize($r('sys.float.Caption_M'))
                  .fontColor(this.getPalette().textSecondary)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Select([
                { value: this.t('Light') },
                { value: this.t('Dark') },
                { value: this.t('Auto') }
              ])
                .selected(this.theme === 'light' ? 0 : this.theme === 'dark' ? 1 : 2)
                .value(this.t(this.theme === 'light' ? 'Light' : this.theme === 'dark' ? 'Dark' : 'Auto'))
                .backgroundColor(this.getPalette().elevatedBackground)
                .borderRadius(14)
                .visualEffect(this.buttonEffect('theme'))
                .onTouch((event: TouchEvent) => this.updatePress('theme', event))
                .onSelect((index: number) => {
                  void this.handleThemeSelect(index);
                })
            }
            .width('100%')
            .padding({ top: 12, bottom: 12 })

            Divider()
              .strokeWidth(1)
              .color(this.getPalette().borderColor)

            Row() {
              Column({ space: 2 }) {
                Text(this.t('Language'))
                  .fontSize($r('sys.float.Body_M'))
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.getPalette().textPrimary)
                Text(this.t('Choose the language used on these pages.'))
                  .fontSize($r('sys.float.Caption_M'))
                  .fontColor(this.getPalette().textSecondary)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Select([
                { value: this.t('System') },
                { value: '简体中文' },
                { value: 'English' }
              ])
                .selected(this.languagePreference === 'zh-CN' ? 1 : this.languagePreference === 'en-US' ? 2 : 0)
                .value(this.languagePreference === 'zh-CN' ? '简体中文'
                  : this.languagePreference === 'en-US' ? 'English' : this.t('System'))
                .backgroundColor(this.getPalette().elevatedBackground)
                .borderRadius(14)
                .visualEffect(this.buttonEffect('language'))
                .onTouch((event: TouchEvent) => this.updatePress('language', event))
                .onSelect((index: number) => {
                  void this.handleLanguageSelect(index);
                })
            }
            .width('100%')
            .padding({ top: 12, bottom: 12 })

            Divider()
              .strokeWidth(1)
              .color(this.getPalette().borderColor)

            Row() {
              Column({ space: 2 }) {
                Text(this.t('Use Pure Black in Dark'))
                  .fontSize($r('sys.float.Body_M'))
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.getPalette().textPrimary)
                Text(this.t('Affects Dark mode directly, and Auto mode whenever the system switches to dark.'))
                  .fontSize($r('sys.float.Caption_M'))
                  .fontColor(this.getPalette().textSecondary)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Toggle({ type: ToggleType.Switch, isOn: this.preferPureBlackInDark })
                .onChange((isOn: boolean) => {
                  void this.handlePureBlackToggle(isOn);
                })
            }
            .width('100%')
            .padding({ top: 12, bottom: 12 })

            Divider()
              .strokeWidth(1)
              .color(this.getPalette().borderColor)

            Row() {
              Column({ space: 2 }) {
                Text(this.t('Max History Size'))
                  .fontSize($r('sys.float.Body_M'))
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.getPalette().textPrimary)
                Text(this.t('Controls how many recent items stay available locally.'))
                  .fontSize($r('sys.float.Caption_M'))
                  .fontColor(this.getPalette().textSecondary)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              this.Stepper(
                'history',
                this.historySize,
                () => {
                  if (this.historySize > 50) {
                    this.historySize -= 50;
                  }
                },
                () => {
                  if (this.historySize < 1000) {
                    this.historySize += 50;
                  }
                }
              )
            }
            .width('100%')
            .padding({ top: 12, bottom: 6 })
          }
          .width('100%')
        }
        .width(this.isWideLayout() ? '49%' : '100%')
        .padding(20)
        .backgroundColor(this.getPalette().pageSurface)
        .border({ width: 1, color: this.getPalette().borderColor })
        .borderRadius(26)
        .shadow({ radius: 20, color: this.getPalette().shadowColor, offsetX: 0, offsetY: 8 })
        .visualEffect(this.cardEffect())
        .margin({ top: this.isWideLayout() ? 0 : 18 })

          }
          .width('90%')
          .alignSelf(ItemAlign.Center)

        if (this.saveStatus) {
          Text(this.t(this.saveStatus))
            .fontSize($r('sys.float.Body_M'))
            .fontColor(this.saveStatus.includes('failed') ? this.getPalette().danger : this.getPalette().success)
            .margin({ bottom: 10 })
        }
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
        mainTitle: this.t('Settings'),
        subTitle: this.t('Manage your server and app preferences.')
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
