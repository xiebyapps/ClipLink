import { NumericSettingRow } from '../components/NumericSettingRow';
import { SettingsPolicy, NumericSettingKey } from '../utils/SettingsPolicy';
import { ConfigService } from '../services/ConfigService';
import { ServerManager } from '../services/ServerManager';
import { SyncCoordinator } from '../services/SyncCoordinator';
import { SyncClipboardService } from '../services/SyncClipboardService';
import { HistoryStorageService } from '../services/HistoryStorageService';
import { RecordCacheService } from '../services/RecordCacheService';
import { RecordPreviewSession } from '../services/RecordPreviewSession';
import { DownloadOrganizationService } from '../services/DownloadOrganizationService';
import { AppConfig, ServerAccount, DownloadRule } from '../types/ApiTypes';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { ThemeUtil, ThemePalette } from '../utils/ThemeUtil';
import { LocalizationUtil } from '../utils/LocalizationUtil';
import { InteractionEffectUtil } from '../utils/InteractionEffectUtil';
import { HdsNavigation, HdsNavigationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';

class RuleDraft {
  id: string = '';
  folder: string = '';
  extensions: string = '';
}

@Component
export default struct SettingsPage {
  @State accounts: ServerAccount[] = [];
  @State pollingInterval: number = 10;
  @State smallThreshold: number = 500;
  @State cacheCapacityGB: number = 2;
  @State historySize: number = 100;
  @State historyCount: number = 0;
  @State classifyDownloads: boolean = true;
  @State failedIds: string[] = [];
  @State switchingId: string = '';
  @State sheetVisible: boolean = false;
  @State sheetKind: string = 'server';
  @State editingId: string = '';
  @State draftName: string = '';
  @State draftUrl: string = '';
  @State draftUsername: string = '';
  @State draftPassword: string = '';
  @State draftTested: boolean = false;
  @State draftStatus: string = '';
  @State sheetBusy: boolean = false;
  @State ruleDrafts: RuleDraft[] = [];
  @State classificationBusy: boolean = false;
  @State viewportWidth: number = 360;
  @State viewportHeight: number = 800;
  @State pressedButton: string = '';
  @StorageLink('appTheme') appTheme: string = 'auto';
  @StorageLink('appLanguage') appLanguage: string = 'system';
  @StorageLink('systemLanguage') systemLanguage: string = 'en';
  @StorageLink('preferPureBlackInDark') pureBlack: boolean = false;
  @StorageLink('systemColorMode') colorMode: number = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  @StorageLink('floatingTabsEnabled') supportsFloatingTabs: boolean = false;
  @StorageLink('safeAreaBottom') safeAreaBottom: number = 0;
  @StorageLink('serverListRevision') @Watch('accountsChanged') serverListRevision: number = 0;
  @StorageLink('serverRevision') @Watch('accountsChanged') serverRevision: number = 0;
  @StorageLink('serverHealthRevision') serverHealthRevision: number = 0;
  @StorageLink('serverConnectionStatus') connectionStatus: string = '';
  @StorageLink('activeServerId') @Watch('updateCount') activeServerId: string = '';
  @StorageLink('historyCountRevision') @Watch('updateCount') countRevision: number = 0;
  @StorageLink('historyMetadataRevision') @Watch('updateCount') historyRevision: number = 0;
  @StorageLink('appForeground') @Watch('foregroundChanged') foreground: boolean = true;
  @StorageLink('smallCacheBytes') smallCacheBytes: number = 0;
  @StorageLink('largeCacheBytes') largeCacheBytes: number = 0;
  @StorageLink('pendingCacheBytes') pendingCacheBytes: number = 0;
  @StorageLink('downloadOrganizationError') organizationError: string = '';
  private settingsQueue: Promise<void> = Promise.resolve();
  private draftEpoch: number = 0;
  private selectionEpoch: number = 0;
  private countEpoch: number = 0;
  private alive: boolean = false;
  private failureTimers: Map<string, number> = new Map();
  private readonly pageScroller: Scroller = new Scroller();
  private config: ConfigService = ConfigService.getInstance();

  private t(text: string): string { return LocalizationUtil.text(text, this.appLanguage, this.systemLanguage); }
  private palette(): ThemePalette { return ThemeUtil.getPalette(this.appTheme as 'auto' | 'light' | 'dark', this.colorMode, this.pureBlack); }
  private isWideLayout(): boolean { return this.viewportWidth >= 760 && this.viewportWidth > this.viewportHeight; }
  private toast(text: string): void { this.getUIContext().getPromptAction().showToast({ message: this.t(text) }); }
  private message(error: Object): string { return error instanceof Error ? error.message : String(error); }

  aboutToAppear(): void {
    this.alive = true;
    void this.initialize();
  }
  aboutToDisappear(): void {
    this.alive = false; this.draftEpoch++; this.selectionEpoch++; this.countEpoch++;
    this.failureTimers.forEach((timer: number): void => clearTimeout(timer));
    this.failureTimers.clear(); this.failedIds = []; this.sheetVisible = false;
  }
  private async initialize(): Promise<void> {
    await this.config.loadConfig();
    if (!this.alive) return;
    const config = this.config.getConfig();
    this.accounts = config.servers.slice();
    this.pollingInterval = config.pollingInterval;
    this.smallThreshold = config.smallFileThresholdMB;
    this.cacheCapacityGB = config.cacheCapacityGB;
    this.historySize = config.maxHistorySize;
    this.classifyDownloads = config.classifyDownloads;
    this.updateCount();
    void ServerManager.getInstance().refreshHealth();
  }
  private accountsChanged(): void { this.accounts = this.config.getConfig().servers.slice(); this.updateCount(); }
  private foregroundChanged(): void { if (this.foreground && this.alive) { void ServerManager.getInstance().refreshHealth(); this.updateCount(); } }
  private updateCount(): void {
    const epoch = ++this.countEpoch;
    const account = this.config.getConfig().activeServerId;
    void HistoryStorageService.getInstance().countRecords(account).then((count: number): void => {
      if (this.alive && epoch === this.countEpoch) this.historyCount = count;
    }).catch((error: Error): void => console.error('[Settings] history count:', error.message));
  }

  private commitNumber(key: NumericSettingKey, value: number): void {
    if (key === 'polling') this.pollingInterval = value;
    if (key === 'threshold') this.smallThreshold = value;
    if (key === 'capacity') this.cacheCapacityGB = value;
    if (key === 'history') this.historySize = value;
    this.settingsQueue = this.settingsQueue.then(async (): Promise<void> => {
      await this.config.updateConfig((next: AppConfig): void => {
        if (key === 'polling') next.pollingInterval = value;
        if (key === 'threshold') next.smallFileThresholdMB = value;
        if (key === 'capacity') next.cacheCapacityGB = value;
        if (key === 'history') next.maxHistorySize = value;
      });
      if (key !== 'polling') {
        RecordCacheService.getInstance().applyPolicy();
        RecordPreviewSession.cachePolicyChanged();
        await HistoryStorageService.getInstance().applyLimits();
        this.updateCount();
      }
    }).catch((error: Error): void => { if (this.alive) { this.toast(`Save failed: ${error.message}`); void this.initialize(); } });
  }

  private clearCache(): void {
    AlertDialog.show({ title: this.t('Clear cache'),
      message: this.t('Clear downloaded caches for all accounts? History and saved files will remain. Active downloads will be canceled; open files will be removed after use.'),
      primaryButton: { value: this.t('Clear'), fontColor: this.palette().danger, action: (): void => {
        this.settingsQueue = this.settingsQueue.then(async (): Promise<void> => {
          RecordCacheService.getInstance().clearAll(); RecordPreviewSession.cachePolicyChanged(); this.toast('Cache cleared');
        }).catch((error: Error): void => this.toast(error.message));
      } }, secondaryButton: { value: this.t('Cancel'), action: (): void => {} } });
  }

  private serverBackground(account: ServerAccount, revision: number): string {
    if (this.failedIds.includes(account.id)) return this.palette().isDark ? '#493919' : '#FFF1CD';
    if (ServerManager.getInstance().isOnline(account.id)) {
      if (account.id === this.activeServerId && this.connectionStatus === 'connected') return this.palette().successSurface;
      return this.palette().accentSoft;
    }
    return this.palette().pageSurface;
  }
  private async switchAccount(account: ServerAccount): Promise<void> {
    const epoch = ++this.selectionEpoch;
    this.switchingId = account.id;
    try { await ServerManager.getInstance().select(account.id); if (this.alive && epoch === this.selectionEpoch) this.toast('Connected'); }
    catch (error) {
      if (!this.alive || epoch !== this.selectionEpoch || !this.config.getConfig().servers.some((item: ServerAccount): boolean => item.id === account.id)) return;
      const old = this.failureTimers.get(account.id); if (old !== undefined) clearTimeout(old);
      this.failedIds = this.failedIds.filter((id: string): boolean => id !== account.id).concat([account.id]);
      this.failureTimers.set(account.id, setTimeout((): void => {
        this.failedIds = this.failedIds.filter((id: string): boolean => id !== account.id); this.failureTimers.delete(account.id);
      }, 2000));
      this.toast(this.message(error));
    } finally { if (epoch === this.selectionEpoch) this.switchingId = ''; }
  }

  private openServer(account?: ServerAccount): void {
    this.draftEpoch++;
    this.sheetKind = 'server'; this.sheetBusy = false; this.draftStatus = ''; this.draftTested = false;
    this.editingId = account?.id || `server-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    this.draftName = account?.name || ''; this.draftUrl = account?.url || '';
    this.draftUsername = account?.username || ''; this.draftPassword = account?.password || '';
    this.sheetVisible = true;
  }
  private invalidateTest(): void { this.draftEpoch++; this.draftTested = false; this.draftStatus = ''; this.sheetBusy = false; }
  private draftAccount(): ServerAccount {
    const address = this.draftUrl.trim().replace(/\/+$/, '');
    if (!/^https?:\/\/[^\s\/?#@]+(?:\/[^\s]*)?$/i.test(address)) throw new Error('Enter a valid HTTP or HTTPS server address');
    const old = this.accounts.find((item: ServerAccount): boolean => item.id === this.editingId);
    return { id: this.editingId, name: this.draftName.trim() || address, type: 'syncclipboard', url: address,
      username: this.draftUsername, password: this.draftPassword, lastConnectedAt: old?.lastConnectedAt || 0 };
  }
  private async testDraft(): Promise<void> {
    const epoch = ++this.draftEpoch;
    try {
      const account = this.draftAccount(); this.sheetBusy = true; this.draftTested = false; this.draftStatus = 'Checking connection...';
      await new SyncClipboardService(account.url, account.username, account.password).probe();
      if (epoch !== this.draftEpoch || !this.sheetVisible) return;
      this.draftTested = true; this.draftStatus = 'Test successful';
    } catch (error) { if (epoch === this.draftEpoch) this.draftStatus = `Test failed: ${this.message(error)}`; }
    finally { if (epoch === this.draftEpoch) this.sheetBusy = false; }
  }
  private async saveDraft(): Promise<void> {
    try {
      const account = this.draftAccount(); const tested = this.draftTested;
      const old = this.accounts.find((item: ServerAccount): boolean => item.id === account.id);
      const changed = !old || old.url !== account.url || old.username !== account.username || old.password !== account.password;
      this.sheetBusy = true;
      if (changed) { ServerManager.getInstance().invalidate(account.id); if (account.id === this.activeServerId) SyncCoordinator.getInstance().invalidate(true); }
      await this.config.upsertServer(account);
      if (changed || tested) ServerManager.getInstance().recordTest(account, tested);
      this.accounts = this.config.getConfig().servers.slice(); this.sheetVisible = false; this.toast('Saved successfully');
    } catch (error) { this.draftStatus = `Save failed: ${this.message(error)}`; }
    finally { this.sheetBusy = false; }
  }
  private confirmDelete(account: ServerAccount): void {
    AlertDialog.show({ title: this.t('Delete Server'), message: `${this.t('Delete this server and its local history and cache?')}\n${account.name}`,
      primaryButton: { value: this.t('Delete'), fontColor: this.palette().danger, action: (): void => { void this.deleteAccount(account); } },
      secondaryButton: { value: this.t('Cancel'), action: (): void => {} } });
  }
  private async deleteAccount(account: ServerAccount): Promise<void> {
    try {
      ServerManager.getInstance().invalidate(account.id); SyncCoordinator.getInstance().invalidate(true);
      await this.config.deleteServer(account.id); await HistoryStorageService.getInstance().clearAll(account.id);
      this.accounts = this.config.getConfig().servers.slice(); this.updateCount(); this.toast('Server removed');
      if (this.accounts.length) await ServerManager.getInstance().ensureAvailable();
    } catch (error) { this.toast(this.message(error)); }
  }

  private openRules(): void {
    this.sheetKind = 'rules'; this.sheetBusy = false; this.draftStatus = '';
    this.ruleDrafts = this.config.getConfig().downloadRules.map((rule: DownloadRule): RuleDraft =>
      ({ id: rule.id, folder: rule.folder, extensions: rule.extensions.join(', ') }));
    this.sheetVisible = true;
  }
  private editRule(id: string, folder: string, extensions: string): void {
    this.ruleDrafts = this.ruleDrafts.map((rule: RuleDraft): RuleDraft =>
      rule.id === id ? { id: id, folder: folder, extensions: extensions } : rule);
  }
  private async saveRules(): Promise<void> {
    this.sheetBusy = true;
    try {
      const rules = this.ruleDrafts.map((draft: RuleDraft): DownloadRule => ({ id: draft.id, folder: draft.folder.trim(),
        extensions: draft.extensions.split(/[,，;；\s]+/).filter((item: string): boolean => !!item) }));
      await DownloadOrganizationService.getInstance().configure(this.config.getConfig().classifyDownloads, rules);
      this.sheetVisible = false; this.toast('Saved successfully');
    } catch (error) { this.draftStatus = `Save failed: ${this.message(error)}`; }
    finally { this.sheetBusy = false; }
  }
  private async setClassification(enabled: boolean): Promise<void> {
    if (this.classificationBusy) return;
    this.classificationBusy = true;
    this.classifyDownloads = enabled;
    try { await DownloadOrganizationService.getInstance().configure(enabled, this.config.getConfig().downloadRules); }
    catch (error) { this.toast(this.message(error)); }
    finally { this.classifyDownloads = this.config.getConfig().classifyDownloads; this.classificationBusy = false; }
  }

  private saveAppearance(kind: string, value: string): void {
    this.settingsQueue = this.settingsQueue.then(async (): Promise<void> => {
      await this.config.updateConfig((next: AppConfig): void => {
        if (kind === 'language') next.language = value as 'system' | 'zh-CN' | 'en-US';
        if (kind === 'theme') next.theme = value as 'auto' | 'light' | 'dark';
        if (kind === 'background') next.preferPureBlackInDark = value === 'true';
      });
      const latest = this.config.getConfig();
      await ThemeUtil.applyTheme(latest.theme, this.colorMode, latest.preferPureBlackInDark);
    }).catch((error: Error): void => this.toast(`Save failed: ${error.message}`));
  }
  private updatePress(id: string, event: TouchEvent): void {
    if (event.type === TouchType.Down) this.pressedButton = id;
    else if (event.type === TouchType.Up || event.type === TouchType.Cancel) this.pressedButton = '';
  }

  @Builder
  private action(label: string, id: string, callback: () => void, danger: boolean = false) {
    Button(this.t(label), { controlSize: ControlSize.SMALL }).fontSize(11).layoutWeight(1).height(32).padding({ left: 4, right: 4 })
      .fontColor(danger ? this.palette().buttonDangerText : this.palette().buttonSecondaryText)
      .backgroundColor(danger ? this.palette().buttonDangerBackground : this.palette().buttonSecondaryBackground)
      .visualEffect(InteractionEffectUtil.button(this.pressedButton === id, canIUse('SystemCapability.UIDesign.HDSComponent.Core')))
      .onTouch((event: TouchEvent): void => this.updatePress(id, event)).onClick(callback)
  }
  @Builder
  private sectionTitle(text: string) {
    Text(this.t(text)).fontSize($r('sys.float.Subtitle_L')).fontWeight(FontWeight.Bold)
      .fontColor(this.palette().textPrimary).width('100%').textAlign(TextAlign.Start)
  }
  @Builder
  private separator() { Divider().color(this.palette().borderColor).strokeWidth(1) }
  @Builder
  private serverSection() {
    Column({ space: 16 }) {
      this.sectionTitle('Server settings')
      if (!this.accounts.length) { Text(this.t('No servers configured')).fontColor(this.palette().textSecondary).width('100%') }
      Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
        ForEach(this.accounts, (account: ServerAccount) => {
          Column({ space: 8 }) {
            Text(account.name).fontWeight(FontWeight.Medium).fontSize(16).fontColor(this.palette().textPrimary)
              .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(account.url).fontSize(12).fontColor(this.palette().textSecondary).width('100%').maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(account.username || '—').fontSize(12).fontColor(this.palette().textSecondary).width('100%').maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Row({ space: 4 }) {
              this.action(this.switchingId === account.id ? 'Checking' : 'Switch', `switch-${account.id}`, (): void => { void this.switchAccount(account); })
              this.action('Edit', `edit-${account.id}`, (): void => this.openServer(account))
              this.action('Delete', `delete-${account.id}`, (): void => this.confirmDelete(account), true)
            }.width('100%')
          }.width('48%').padding(10).margin({ bottom: 12 }).borderRadius(18)
            .backgroundColor(this.serverBackground(account, this.serverHealthRevision))
            .border({ width: 1, color: this.palette().borderColor })
        }, (account: ServerAccount): string => account.id)
      }.width('100%')
      Button(this.t('Add Server')).width('100%').fontColor(this.palette().accent)
        .backgroundColor(this.palette().accentSoft).onClick((): void => this.openServer())
    }.width(this.isWideLayout() ? '49%' : '100%').padding(16).borderRadius(26).margin({ bottom: 18 })
      .backgroundColor(this.palette().pageSurface).border({ width: 1, color: this.palette().borderColor })
      .visualEffect(InteractionEffectUtil.card(canIUse('SystemCapability.UIDesign.HDSComponent.Core')))
  }
  @Builder
  private appSection() {
    Column({ space: 4 }) {
      this.sectionTitle('App settings')
      NumericSettingRow({ settingKey: 'polling', title: this.t('Polling interval (seconds)'), value: this.pollingInterval,
        help: this.t('Checks the server only while the app is in the foreground. Shorter intervals check more often.'),
        onCommit: (value: number): void => this.commitNumber('polling', value) })
      this.separator()
      NumericSettingRow({ settingKey: 'threshold', title: this.t('Small file boundary (MB)'), value: this.smallThreshold,
        help: this.t('Files at or below this size share the small file pool. Larger files expire two hours after download; opening them does not extend the deadline.'),
        onCommit: (value: number): void => this.commitNumber('threshold', value) })
      this.separator()
      NumericSettingRow({ settingKey: 'capacity', title: this.t('Small file pool capacity (GB)'), value: this.cacheCapacityGB,
        details: `${this.t('Used')}: ${LocalizationUtil.formatBytes(this.smallCacheBytes)}`,
        help: this.t('Small files stay cached until the pool fills, then the oldest history caches are removed. History and saved files remain. A file larger than the pool cannot stay cached after use.'),
        clearAvailable: true, onClear: (): void => this.clearCache(), onCommit: (value: number): void => this.commitNumber('capacity', value) })
      Text(`${this.t('Large file cache')}: ${LocalizationUtil.formatBytes(this.largeCacheBytes)}`)
        .fontSize(12).fontColor(this.palette().textSecondary).width('100%')
      if (this.pendingCacheBytes > 0) {
        Text(`${this.t('Waiting for open files to close')}: ${LocalizationUtil.formatBytes(this.pendingCacheBytes)}`)
          .fontSize(12).fontColor(this.palette().textSecondary).width('100%')
      }
      this.separator()
      NumericSettingRow({ settingKey: 'history', title: `${this.t('History records')} · ${this.t('Stored')} ${this.historyCount} / ${this.t('Limit')} ${this.historySize}`,
        value: this.historySize, help: this.t('Each account has its own limit, including favorites. Exceeding it removes old local records and caches, never server history. The count shows the current account.'),
        onCommit: (value: number): void => this.commitNumber('history', value) })
      this.separator()
      Row({ space: 8 }) {
        Text(this.t('Classify saved files')).fontSize(16).fontColor(this.palette().textPrimary).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.classifyDownloads }).enabled(!this.classificationBusy)
          .onChange((enabled: boolean): void => { void this.setClassification(enabled); })
      }.width('100%').padding({ top: 12, bottom: 8 })
      Row() {
        Text(this.t('Download/application package')).fontSize(12).fontColor(this.palette().textSecondary).layoutWeight(1)
        Button(this.t('Classification rules'), { controlSize: ControlSize.SMALL })
          .fontColor(this.palette().accent).backgroundColor(this.palette().accentSoft)
          .enabled(!this.classificationBusy).onClick((): void => this.openRules())
      }.width('100%')
      if (this.organizationError) {
        Text(`${this.t('File organization failed')}: ${this.t(this.organizationError)}`).fontSize(12)
          .fontColor(this.palette().danger).width('100%')
        Button(this.t('Retry'), { controlSize: ControlSize.SMALL }).onClick((): void => { void DownloadOrganizationService.getInstance().resume(); })
      }
    }.width(this.isWideLayout() ? '49%' : '100%').alignItems(HorizontalAlign.Start).padding(16)
      .borderRadius(26).margin({ bottom: 18 }).backgroundColor(this.palette().pageSurface)
      .border({ width: 1, color: this.palette().borderColor })
      .visualEffect(InteractionEffectUtil.card(canIUse('SystemCapability.UIDesign.HDSComponent.Core')))
  }
  @Builder
  private appearanceSection() {
    Column({ space: 16 }) {
      this.sectionTitle('Interface settings')
      Row({ space: 12 }) {
        Text(this.t('Language')).fontSize(16).fontColor(this.palette().textPrimary).layoutWeight(1)
        Select([{ value: this.t('Follow System') }, { value: '简体中文' }, { value: 'English' }])
          .selected(this.appLanguage === 'zh-CN' ? 1 : this.appLanguage === 'en-US' ? 2 : 0)
          .value(this.appLanguage === 'zh-CN' ? '简体中文' : this.appLanguage === 'en-US' ? 'English' : this.t('Follow System'))
          .fontColor(this.palette().textPrimary).backgroundColor(this.palette().inputBackground)
          .optionFontColor(this.palette().textPrimary).selectedOptionFontColor(this.palette().accent)
          .optionBgColor(this.palette().elevatedBackground).selectedOptionBgColor(this.palette().accentSoft)
          .menuBackgroundColor(this.palette().elevatedBackground).divider({ strokeWidth: 1, color: this.palette().borderColor })
          .onSelect((index: number): void => this.saveAppearance('language', index === 1 ? 'zh-CN' : index === 2 ? 'en-US' : 'system'))
      }.width('100%')
      this.separator()
      Row({ space: 12 }) {
        Text(this.t('Theme')).fontSize(16).fontColor(this.palette().textPrimary).layoutWeight(1)
        Select([{ value: this.t('Light') }, { value: this.t('Dark') }, { value: this.t('Follow System') }])
          .selected(this.appTheme === 'light' ? 0 : this.appTheme === 'dark' ? 1 : 2)
          .value(this.t(this.appTheme === 'light' ? 'Light' : this.appTheme === 'dark' ? 'Dark' : 'Follow System'))
          .fontColor(this.palette().textPrimary).backgroundColor(this.palette().inputBackground)
          .optionFontColor(this.palette().textPrimary).selectedOptionFontColor(this.palette().accent)
          .optionBgColor(this.palette().elevatedBackground).selectedOptionBgColor(this.palette().accentSoft)
          .menuBackgroundColor(this.palette().elevatedBackground).divider({ strokeWidth: 1, color: this.palette().borderColor })
          .onSelect((index: number): void => this.saveAppearance('theme', index === 0 ? 'light' : index === 1 ? 'dark' : 'auto'))
      }.width('100%')
      this.separator()
      Row({ space: 12 }) {
        Text(this.t('Pure black background')).fontSize(16).fontColor(this.palette().textPrimary).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.pureBlack })
          .onChange((enabled: boolean): void => this.saveAppearance('background', String(enabled)))
      }.width('100%')
    }.width(this.isWideLayout() ? '49%' : '100%').padding(16).borderRadius(26).margin({ bottom: 18 })
      .backgroundColor(this.palette().pageSurface).border({ width: 1, color: this.palette().borderColor })
      .visualEffect(InteractionEffectUtil.card(canIUse('SystemCapability.UIDesign.HDSComponent.Core')))
  }

  @Builder
  private serverSheet() {
    Column({ space: 16 }) {
      Text(this.t('Server Name')).fontColor(this.palette().textSecondary).width('100%')
      TextInput({ text: this.draftName, placeholder: this.t('Server Name') }).fontColor(this.palette().textPrimary)
        .backgroundColor(this.palette().inputBackground).enabled(!this.sheetBusy).onChange((value: string): void => { this.draftName = value; })
      Text(this.t('Server URL')).fontColor(this.palette().textSecondary).width('100%')
      TextInput({ text: this.draftUrl, placeholder: 'https://example.com' }).fontColor(this.palette().textPrimary)
        .backgroundColor(this.palette().inputBackground).enabled(!this.sheetBusy).onChange((value: string): void => { this.draftUrl = value; this.invalidateTest(); })
      Text(this.t('Username')).fontColor(this.palette().textSecondary).width('100%')
      TextInput({ text: this.draftUsername, placeholder: this.t('Username') }).fontColor(this.palette().textPrimary)
        .backgroundColor(this.palette().inputBackground).enabled(!this.sheetBusy).onChange((value: string): void => { this.draftUsername = value; this.invalidateTest(); })
      Text(this.t('Password')).fontColor(this.palette().textSecondary).width('100%')
      TextInput({ text: this.draftPassword, placeholder: this.t('Password') }).type(InputType.Password)
        .fontColor(this.palette().textPrimary).backgroundColor(this.palette().inputBackground)
        .enabled(!this.sheetBusy).onChange((value: string): void => { this.draftPassword = value; this.invalidateTest(); })
      Row({ space: 12 }) {
        Button(this.t('Test')).layoutWeight(1).enabled(!this.sheetBusy)
          .fontColor(this.palette().accent).backgroundColor(this.palette().accentSoft).onClick((): void => { void this.testDraft(); })
        Button(this.t('Save')).layoutWeight(1).enabled(!this.sheetBusy)
          .fontColor(this.palette().buttonPrimaryText).backgroundColor(this.palette().buttonPrimaryBackground).onClick((): void => { void this.saveDraft(); })
      }.width('100%')
      if (this.draftStatus) { Text(this.t(this.draftStatus)).fontColor(this.draftTested ? this.palette().success : this.palette().textSecondary).width('100%') }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  @Builder
  private rulesSheet() {
    Column({ space: 16 }) {
      Text(this.t('Match extensions to a folder. Unmatched files go to Other.')).fontSize(13).fontColor(this.palette().textSecondary).width('100%')
      ForEach(this.ruleDrafts, (rule: RuleDraft) => {
        Column({ space: 10 }) {
          TextInput({ text: rule.extensions, placeholder: this.t('Extensions, for example md, txt') })
            .fontColor(this.palette().textPrimary).backgroundColor(this.palette().inputBackground).enabled(!this.sheetBusy)
            .onChange((value: string): void => this.editRule(rule.id, rule.folder, value))
          Row({ space: 8 }) {
            TextInput({ text: rule.folder, placeholder: this.t('Folder name') }).layoutWeight(1)
              .fontColor(this.palette().textPrimary).backgroundColor(this.palette().inputBackground).enabled(!this.sheetBusy)
              .onChange((value: string): void => this.editRule(rule.id, value, rule.extensions))
            Button(this.t('Delete'), { controlSize: ControlSize.SMALL }).enabled(!this.sheetBusy)
              .fontColor(this.palette().buttonDangerText).backgroundColor(this.palette().buttonDangerBackground)
              .onClick((): void => { this.ruleDrafts = this.ruleDrafts.filter((item: RuleDraft): boolean => item.id !== rule.id); })
          }.width('100%')
        }.width('100%').padding(12).borderRadius(16).backgroundColor(this.palette().elevatedBackground)
      }, (rule: RuleDraft): string => rule.id)
      Button(this.t('Add rule')).enabled(!this.sheetBusy).width('100%')
        .fontColor(this.palette().accent).backgroundColor(this.palette().accentSoft)
        .onClick((): void => { this.ruleDrafts = this.ruleDrafts.concat([{ id: `rule-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`, folder: '', extensions: '' }]); })
      if (this.draftStatus) { Text(this.t(this.draftStatus)).fontColor(this.palette().danger).width('100%') }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  @Builder
  private sheetContent() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Text(this.t(this.sheetKind === 'rules' ? 'Classification rules' :
          this.accounts.some((item: ServerAccount): boolean => item.id === this.editingId) ? 'Edit Server' : 'Add Server'))
          .fontSize(22).fontWeight(FontWeight.Bold).fontColor(this.palette().textPrimary).layoutWeight(1)
        if (this.sheetKind === 'rules') {
          Button(this.t('Save'), { controlSize: ControlSize.SMALL }).enabled(!this.sheetBusy)
            .fontColor(this.palette().buttonPrimaryText).backgroundColor(this.palette().buttonPrimaryBackground)
            .onClick((): void => { void this.saveRules(); })
        }
      }.width('100%').padding({ left: 20, right: 64, top: 12 })
      Scroll() {
        Column() { if (this.sheetKind === 'server') { this.serverSheet() } else { this.rulesSheet() } }
          .width('100%').padding({ left: 20, right: 20, bottom: 28 })
      }.width('100%').layoutWeight(1).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: false })
    }.width('100%').height('100%').backgroundColor(this.palette().pageSurface)
  }

  build() {
    HdsNavigation() {
      Scroll(this.pageScroller) {
        Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween, alignItems: ItemAlign.Start }) {
          this.serverSection()
          this.appSection()
          this.appearanceSection()
        }.width('92%').padding({ top: 16, bottom: (this.supportsFloatingTabs ? 116 : 16) + this.safeAreaBottom })
      }.width('100%').height('100%').clip(false).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: false })
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
            mainTitleColor: this.palette().textPrimary,
            subTitleColor: this.palette().textSecondary
          } }
        },
        scrollEffectStyle: {
          backgroundStyle: { backgroundColor: this.palette().pageBackground },
          contentStyle: { titleStyle: {
            mainTitleColor: this.palette().textPrimary,
            subTitleColor: this.palette().textSecondary
          } }
        }
      }
    })
    .titleMode(HdsNavigationTitleMode.FULL)
    .hideBackButton(true)
    .bindSheet($$this.sheetVisible, this.sheetContent(), {
      height: SheetSize.LARGE, detents: [SheetSize.LARGE],
      preferType: this.viewportWidth >= 600 ? SheetType.CENTER : SheetType.BOTTOM,
      showClose: true, backgroundColor: this.palette().pageSurface,
      onDisappear: (): void => { this.sheetVisible = false; this.draftEpoch++; this.sheetBusy = false; }
    })
    .mode(NavigationMode.Stack)
    .bindToScrollable([this.pageScroller])
    .systemBarStyle(
      { statusBarContentColor: this.palette().isDark ? '#FFFFFF' : '#000000' },
      { statusBarContentColor: this.palette().isDark ? '#FFFFFF' : '#000000' }
    )
    .width('100%')
    .height('100%')
    .backgroundColor(this.palette().pageBackground)
    .onAreaChange((_oldArea, newArea) => {
      this.viewportWidth = Number(newArea.width);
      this.viewportHeight = Number(newArea.height);
    })
  }
}
