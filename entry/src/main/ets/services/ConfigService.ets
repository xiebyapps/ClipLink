import dataPreferences from '@ohos.data.preferences';
import { AppConfig, ServerConfig } from '../types/ApiTypes';

/**
 * Config Service - manages app configuration via Preferences
 */
export class ConfigService {
  private static instance: ConfigService;
  private preferences: dataPreferences.Preferences | null = null;
  private config: AppConfig;
  private loadingPromise: Promise<AppConfig> | null = null;

  private readonly PREFS_NAME = 'syncclipboard_config';
  private readonly KEY_SERVER_TYPE = 'server_type';
  private readonly KEY_SERVER_URL = 'server_url';
  private readonly KEY_USERNAME = 'username';
  private readonly KEY_PASSWORD = 'password';
  private readonly KEY_POLLING_INTERVAL = 'polling_interval';
  private readonly KEY_THEME = 'theme';
  private readonly KEY_LANGUAGE = 'language';
  private readonly KEY_PREFER_PURE_BLACK_IN_DARK = 'prefer_pure_black_in_dark';
  private readonly KEY_HISTORY_SIZE = 'history_size';

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
      server: {
        type: 'syncclipboard',
        url: 'http://localhost:5033',
        username: '',
        password: ''
      },
      pollingInterval: 5,
      theme: 'auto',
      language: 'system',
      preferPureBlackInDark: false,
      maxHistorySize: 100
    };
  }

  private applyRuntimeConfig(config: AppConfig): void {
    AppStorage.setOrCreate('appTheme', config.theme);
    AppStorage.setOrCreate('appLanguage', config.language);
    AppStorage.setOrCreate('preferPureBlackInDark', config.preferPureBlackInDark);
    AppStorage.setOrCreate('maxHistorySize', config.maxHistorySize);
  }

  private getAbilityContext(): Context {
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
      const serverUrl = await this.preferences.get(this.KEY_SERVER_URL, 'http://localhost:5033') as string;
      const username = await this.preferences.get(this.KEY_USERNAME, '') as string;
      const password = await this.preferences.get(this.KEY_PASSWORD, '') as string;
      const pollingInterval = await this.preferences.get(this.KEY_POLLING_INTERVAL, 5) as number;
      const theme = await this.preferences.get(this.KEY_THEME, 'auto') as string;
      const storedLanguage = await this.preferences.get(this.KEY_LANGUAGE, 'system') as string;
      const language = storedLanguage === 'zh-CN' || storedLanguage === 'en-US'
        ? storedLanguage : 'system';
      const preferPureBlackInDark = await this.preferences.get(
        this.KEY_PREFER_PURE_BLACK_IN_DARK,
        false
      ) as boolean;
      const historySize = await this.preferences.get(this.KEY_HISTORY_SIZE, 100) as number;

      this.config = {
        server: {
          type: serverType as 'syncclipboard' | 'webdav',
          url: serverUrl,
          username: username,
          password: password
        },
        pollingInterval: pollingInterval,
        theme: theme as 'light' | 'dark' | 'auto',
        language: language as 'system' | 'zh-CN' | 'en-US',
        preferPureBlackInDark: preferPureBlackInDark,
        maxHistorySize: historySize
      };
      this.applyRuntimeConfig(this.config);

      console.info('[ConfigService] Config loaded:', JSON.stringify(this.config));
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
    try {
      if (!this.preferences) {
        this.preferences = await dataPreferences.getPreferences(
          this.getAbilityContext(),
          this.PREFS_NAME
        );
      }

      await this.preferences.put(this.KEY_SERVER_TYPE, config.server.type);
      await this.preferences.put(this.KEY_SERVER_URL, config.server.url);
      await this.preferences.put(this.KEY_USERNAME, config.server.username || '');
      await this.preferences.put(this.KEY_PASSWORD, config.server.password || '');
      await this.preferences.put(this.KEY_POLLING_INTERVAL, config.pollingInterval);
      await this.preferences.put(this.KEY_THEME, config.theme);
      await this.preferences.put(this.KEY_LANGUAGE, config.language);
      await this.preferences.put(this.KEY_PREFER_PURE_BLACK_IN_DARK, config.preferPureBlackInDark);
      await this.preferences.put(this.KEY_HISTORY_SIZE, config.maxHistorySize);

      await this.preferences.flush();

      this.config = config;
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
    this.config.server = server;
    await this.saveConfig(this.config);
  }
}
