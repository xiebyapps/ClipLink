import { SettingsPolicy } from '../utils/SettingsPolicy';
import dataPreferences from '@ohos.data.preferences';
import { AppConfig, ServerConfig, ServerAccount, DownloadRule } from '../types/ApiTypes';

/**
 * Config Service - manages app configuration via Preferences
 */
export class ConfigService {
  private static instance: ConfigService;
  private preferences: dataPreferences.Preferences | null = null;
  private config: AppConfig;
  private loadingPromise: Promise<AppConfig> | null = null;
  private hasLoaded: boolean = false;
  private context: Context | null = null;
  private writeQueue: Promise<void> = Promise.resolve();
  private accountObservers: Set<() => void> = new Set();
  observeAccount(observer: () => void): void { this.accountObservers.add(observer); }
  unobserveAccount(observer: () => void): void { this.accountObservers.delete(observer); }

  private readonly PREFS_NAME = 'syncclipboard_config';
  private readonly KEY_SERVER_TYPE = 'server_type';
  private readonly KEY_SERVER_URL = 'server_url';
  private readonly KEY_USERNAME = 'username';
  private readonly KEY_PASSWORD = 'password';
  private readonly KEY_SERVERS = 'servers_v2';
  private readonly KEY_ACTIVE_SERVER_ID = 'active_server_id';
  private readonly KEY_POLLING_INTERVAL = 'polling_interval';
  private readonly KEY_THEME = 'theme';
  private readonly KEY_LANGUAGE = 'language';
  private readonly KEY_PREFER_PURE_BLACK_IN_DARK = 'prefer_pure_black_in_dark';
  private readonly KEY_HISTORY_SIZE = 'history_size';
  private readonly KEY_CACHE_CAPACITY = 'cache_capacity_gb';
  private readonly KEY_SMALL_THRESHOLD = 'small_file_threshold_mb';
  private readonly KEY_CLASSIFY = 'classify_downloads';
  private readonly KEY_RULES = 'download_rules';
  private readonly KEY_SYNC_PAUSED = 'sync_paused_reason';

  private constructor() {
    this.config = this.getDefaultConfig();
  }

  static getInstance(): ConfigService {
    if (!ConfigService.instance) {
      ConfigService.instance = new ConfigService();
    }
    return ConfigService.instance;
  }

  private getDefaultConfig(): AppConfig {
    return {
      server: undefined, servers: [], activeServerId: '', pollingInterval: 10,
      theme: 'auto', language: 'system', preferPureBlackInDark: false,
      maxHistorySize: 100, cacheCapacityGB: 2, smallFileThresholdMB: 500,
      classifyDownloads: true, downloadRules: SettingsPolicy.defaultRules()
    };
  }

  private applyRuntimeConfig(config: AppConfig): void {
    AppStorage.setOrCreate('appTheme', config.theme);
    AppStorage.setOrCreate('appLanguage', config.language);
    AppStorage.setOrCreate('preferPureBlackInDark', config.preferPureBlackInDark);
    AppStorage.setOrCreate('maxHistorySize', config.maxHistorySize);
    AppStorage.setOrCreate('cacheCapacityGB', config.cacheCapacityGB);
    AppStorage.setOrCreate('pollingInterval', config.pollingInterval);
    AppStorage.setOrCreate('smallFileThresholdMB', config.smallFileThresholdMB);
    AppStorage.setOrCreate('activeServerId', config.activeServerId);
  }

  private getAbilityContext(): Context {
    if (this.context) return this.context;
    const context = AppStorage.get<Context>('abilityContext');
    if (!context) {
      throw new Error('Ability context is not initialized');
    }
    return context as Context;
  }

  /**
   * Load configuration from preferences
   */
  async loadConfig(): Promise<AppConfig> {
    if (this.hasLoaded) return this.config;
    if (this.loadingPromise) {
      return this.loadingPromise;
    }

    this.loadingPromise = this.loadConfigInternal();
    try {
      return await this.loadingPromise;
    } finally {
      this.loadingPromise = null;
    }
  }

  private async loadConfigInternal(): Promise<AppConfig> {
    try {
      if (!this.preferences) {
        this.preferences = await dataPreferences.getPreferences(
          this.getAbilityContext(),
          this.PREFS_NAME
        );
      }

      const serverType = await this.preferences.get(this.KEY_SERVER_TYPE, 'syncclipboard') as string;
      const serverUrl = await this.preferences.get(this.KEY_SERVER_URL, '') as string;
      const username = await this.preferences.get(this.KEY_USERNAME, '') as string;
      const password = await this.preferences.get(this.KEY_PASSWORD, '') as string;
      const pollingInterval = SettingsPolicy.normalize('polling', Number(await this.preferences.get(this.KEY_POLLING_INTERVAL, 10)), 10);
      const theme = await this.preferences.get(this.KEY_THEME, 'auto') as string;
      const storedLanguage = await this.preferences.get(this.KEY_LANGUAGE, 'system') as string;
      const language = storedLanguage === 'zh-CN' || storedLanguage === 'en-US'
        ? storedLanguage : 'system';
      const preferPureBlackInDark = await this.preferences.get(
        this.KEY_PREFER_PURE_BLACK_IN_DARK,
        false
      ) as boolean;
      const historySize = await this.preferences.get(this.KEY_HISTORY_SIZE, 100) as number;
      const capacity = await this.preferences.get(this.KEY_CACHE_CAPACITY, 2) as number;
      const cacheCapacityGB = SettingsPolicy.normalize('capacity', capacity, 2);
      const smallFileThresholdMB = SettingsPolicy.normalize('threshold', Number(await this.preferences.get(this.KEY_SMALL_THRESHOLD, 500)), 500);
      const classifyDownloads = await this.preferences.get(this.KEY_CLASSIFY, true) as boolean;
      let downloadRules = SettingsPolicy.defaultRules();
      const storedRules = await this.preferences.get(this.KEY_RULES, '') as string;
      if (storedRules) {
        try { downloadRules = SettingsPolicy.validateRules(JSON.parse(storedRules) as DownloadRule[]); }
        catch (_) { console.error('[ConfigService] Invalid download rules'); }
      }
      const storedServers = await this.preferences.get(this.KEY_SERVERS, '') as string;
      let servers: ServerAccount[] = [];
      let accountListPresent = false;
      if (storedServers) {
        try {
          const parsed = JSON.parse(storedServers) as ServerAccount[];
          if (Array.isArray(parsed)) {
            accountListPresent = true;
            servers = parsed.filter((item: ServerAccount): boolean =>
              !!item && typeof item.id === 'string' && typeof item.url === 'string')
              .map((item: ServerAccount): ServerAccount => ({
                id: item.id, name: item.name || item.url, url: item.url,
                type: item.type || 'syncclipboard', username: item.username || '',
                password: item.password || '',
                lastConnectedAt: Number(item.lastConnectedAt) || 0
              }));
          }
        } catch (error) {
          console.error('[ConfigService] Invalid account list');
        }
      }
      if (!accountListPresent && serverUrl) {
        servers = [{
          id: 'original', name: serverUrl === 'http://localhost:5033' ? 'Default server' : serverUrl,
          type: serverType as 'syncclipboard' | 'webdav', url: serverUrl,
          username: username, password: password, lastConnectedAt: 0
        }];
      }
      const storedActiveId = await this.preferences.get(this.KEY_ACTIVE_SERVER_ID, servers[0]?.id || '') as string;
      const activeServer = servers.find((item: ServerAccount): boolean => item.id === storedActiveId);

      this.config = {
        server: activeServer,
        servers: servers,
        activeServerId: activeServer?.id || '',
        pollingInterval: pollingInterval,
        theme: theme as 'light' | 'dark' | 'auto',
        language: language as 'system' | 'zh-CN' | 'en-US',
        preferPureBlackInDark: preferPureBlackInDark,
        maxHistorySize: Math.min(1000, Math.max(50, Math.floor(Number(historySize) || 100))),
        cacheCapacityGB: cacheCapacityGB, smallFileThresholdMB: smallFileThresholdMB,
        classifyDownloads: classifyDownloads, downloadRules: downloadRules
      };
      const pausedReason = await this.preferences.get(this.KEY_SYNC_PAUSED, '') as string;
      AppStorage.setOrCreate('syncPausedReason', pausedReason);
      if (pausedReason) AppStorage.setOrCreate('isPollingEnabled', false);
      this.applyRuntimeConfig(this.config);
      this.hasLoaded = true;

      console.info('[ConfigService] Config loaded');
      return this.config;
    } catch (error) {
      console.error('[ConfigService] loadConfig error:', JSON.stringify(error));
      this.applyRuntimeConfig(this.config);
      return this.config;
    }
  }

  /**
   * Save configuration to preferences
   */
  async saveConfig(config: AppConfig): Promise<void> {
    const operation = this.writeQueue.then((): Promise<void> => this.saveConfigInternal(config));
    this.writeQueue = operation.catch((): void => {});
    return operation;
  }

  async updateConfig(update: (config: AppConfig) => void): Promise<void> {
    const operation = this.writeQueue.then(async (): Promise<void> => {
      const next = this.copyConfig();
      update(next);
      await this.saveConfigInternal(next);
    });
    this.writeQueue = operation.catch((): void => {});
    return operation;
  }

  private async saveConfigInternal(config: AppConfig): Promise<void> {
    try {
      if (!this.preferences) {
        this.preferences = await dataPreferences.getPreferences(
          this.getAbilityContext(),
          this.PREFS_NAME
        );
      }

      SettingsPolicy.parse('polling', String(config.pollingInterval));
      SettingsPolicy.parse('history', String(config.maxHistorySize));
      config.cacheCapacityGB = config.cacheCapacityGB ?? this.config.cacheCapacityGB ?? 2;
      config.smallFileThresholdMB = config.smallFileThresholdMB ?? this.config.smallFileThresholdMB ?? 500;
      config.classifyDownloads = config.classifyDownloads ?? this.config.classifyDownloads ?? true;
      config.downloadRules = SettingsPolicy.validateRules(config.downloadRules || this.config.downloadRules);
      SettingsPolicy.parse('capacity', String(config.cacheCapacityGB));
      SettingsPolicy.parse('threshold', String(config.smallFileThresholdMB));
      const active = config.servers.find((item: ServerAccount): boolean => item.id === config.activeServerId);
      config.activeServerId = active?.id || '';
      config.server = active;
      await this.preferences.put(this.KEY_SERVERS, JSON.stringify(config.servers));
      await this.preferences.put(this.KEY_ACTIVE_SERVER_ID, config.activeServerId);
      await this.preferences.put(this.KEY_SERVER_TYPE, active?.type || 'syncclipboard');
      await this.preferences.put(this.KEY_SERVER_URL, active?.url || '');
      await this.preferences.put(this.KEY_USERNAME, active?.username || '');
      await this.preferences.put(this.KEY_PASSWORD, active?.password || '');
      await this.preferences.put(this.KEY_POLLING_INTERVAL, config.pollingInterval);
      await this.preferences.put(this.KEY_THEME, config.theme);
      await this.preferences.put(this.KEY_LANGUAGE, config.language);
      await this.preferences.put(this.KEY_PREFER_PURE_BLACK_IN_DARK, config.preferPureBlackInDark);
      await this.preferences.put(this.KEY_HISTORY_SIZE, config.maxHistorySize);
      await this.preferences.put(this.KEY_CACHE_CAPACITY, config.cacheCapacityGB);

      await this.preferences.put(this.KEY_SMALL_THRESHOLD, config.smallFileThresholdMB);
      await this.preferences.put(this.KEY_CLASSIFY, config.classifyDownloads);
      await this.preferences.put(this.KEY_RULES, JSON.stringify(config.downloadRules));
      await this.preferences.flush();

      this.config = config;
      this.hasLoaded = true;
      this.applyRuntimeConfig(this.config);
      console.info('[ConfigService] Config saved');
    } catch (error) {
      console.error('[ConfigService] saveConfig error:', JSON.stringify(error));
      throw new Error('Failed to save config');
    }
  }

  /**
   * Get current configuration
   */
  getConfig(): AppConfig {
    return this.config;
  }

  /**
   * Update server config
   */
  async updateServerConfig(server: ServerConfig): Promise<void> {
    const active = this.getActiveServer();
    if (!active) throw new Error('No available server');
    active.type = server.type;
    active.url = server.url;
    active.username = server.username;
    active.password = server.password;
    await this.saveConfig(this.config);
  }

  async setSyncPaused(reason: string): Promise<void> {
    AppStorage.setOrCreate('syncPausedReason', reason);
    await this.loadConfig();
    AppStorage.setOrCreate('syncPausedReason', reason);
    if (!this.preferences) throw new Error('Preferences are unavailable');
    await this.preferences.put(this.KEY_SYNC_PAUSED, reason);
    await this.preferences.flush();
  }

  setContext(context: Context): void {
    this.context = context;
  }

  copyConfig(): AppConfig {
    return { server: this.config.server, servers: this.config.servers.map((server: ServerAccount): ServerAccount =>
      ({ id: server.id, name: server.name, type: server.type, url: server.url,
        username: server.username, password: server.password, lastConnectedAt: server.lastConnectedAt })), activeServerId: this.config.activeServerId,
      pollingInterval: this.config.pollingInterval, theme: this.config.theme, language: this.config.language,
      preferPureBlackInDark: this.config.preferPureBlackInDark, maxHistorySize: this.config.maxHistorySize,
      cacheCapacityGB: this.config.cacheCapacityGB, smallFileThresholdMB: this.config.smallFileThresholdMB,
      classifyDownloads: this.config.classifyDownloads,
      downloadRules: this.config.downloadRules.map((rule: DownloadRule): DownloadRule =>
        ({ id: rule.id, folder: rule.folder, extensions: rule.extensions.slice() })) };
  }

  getActiveServer(): ServerAccount | undefined {
    return this.config.servers.find((item: ServerAccount): boolean => item.id === this.config.activeServerId);
  }

  async upsertServer(account: ServerAccount): Promise<void> {
    const wasActive = this.config.activeServerId === account.id;
    await this.updateConfig((next: AppConfig): void => {
      const index = next.servers.findIndex((item: ServerAccount): boolean => item.id === account.id);
      if (index >= 0) next.servers[index] = account;
      else next.servers.push(account);
    });
    AppStorage.setOrCreate('serverListRevision', (AppStorage.get<number>('serverListRevision') || 0) + 1);
    if (wasActive) this.notifyServerChange();
  }

  async switchServer(id: string, valid?: () => boolean): Promise<void> {
    let changed = false;
    await this.updateConfig((next: AppConfig): void => {
      if (valid && !valid()) throw new Error('Server changed during operation');
      if (!next.servers.some((item: ServerAccount): boolean => item.id === id)) throw new Error('Server not found');
      changed = next.activeServerId !== id;
      next.activeServerId = id;
    });
    if (changed) this.notifyServerChange();
  }

  async markConnected(id: string): Promise<void> {
    await this.updateConfig((next: AppConfig): void => {
      const account = next.servers.find((item: ServerAccount): boolean => item.id === id);
      if (account) account.lastConnectedAt = Date.now();
    });
  }

  async deleteServer(id: string): Promise<void> {
    const wasActive = this.config.activeServerId === id;
    await this.updateConfig((next: AppConfig): void => {
      next.servers = next.servers.filter((item: ServerAccount): boolean => item.id !== id);
      if (next.activeServerId === id) next.activeServerId = '';
    });
    AppStorage.setOrCreate('serverListRevision', (AppStorage.get<number>('serverListRevision') || 0) + 1);
    if (wasActive) this.notifyServerChange();
    if (this.config.servers.length === 0) {
      AppStorage.setOrCreate('isPollingEnabled', false);
      AppStorage.setOrCreate('serverConnectionStatus', 'unconfigured');
      AppStorage.delete('currentRemoteRecord');
    }
  }

  private notifyServerChange(): void {
    this.accountObservers.forEach((observer: () => void): void => observer());
    AppStorage.setOrCreate('activeServerId', this.config.activeServerId);
    AppStorage.setOrCreate('serverRevision', (AppStorage.get<number>('serverRevision') || 0) + 1);
  }
}
